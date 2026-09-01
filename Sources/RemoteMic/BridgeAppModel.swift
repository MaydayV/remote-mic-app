import AppKit
import Combine
import CoreAudio
import Foundation

private struct ManagedDefaultInputTransition {
    let virtualUID: String
    let fallbackUID: String
}

private struct RemoteButtonGestureKey: Hashable {
    let source: UsageEventSource
    let button: RemoteButton
}

enum BluetoothVoiceStopPolicy {
    /// Remote stop ends capture but must not discard PCM already scheduled for playback.
    static func shouldFlushAudio(handledByFnTapMode _: Bool) -> Bool {
        false
    }
}

enum HIDMappingRecoveryPolicy {
    /// HID services may lag Bluetooth readiness after wake. Keep retries
    /// finite and back off so a missing/unsupported device cannot spin.
    static let retryDelays: [TimeInterval] = [0.5, 1, 2, 4, 8]

    static func retryDelay(
        forAttempt attempt: Int,
        started: Bool,
        readyBridgeCount: Int,
        hasMatchingServices: Bool
    ) -> TimeInterval? {
        guard started, readyBridgeCount > 0, !hasMatchingServices,
              retryDelays.indices.contains(attempt) else { return nil }
        return retryDelays[attempt]
    }

    /// A missing HID service is usually a discovery timing issue (for example
    /// after wake), not a failed mapping write. Keep the user's Fn-tap choice
    /// while the bounded recovery loop waits for macOS to expose the service.
    static func shouldPreserveFnTapPreferenceAfterMappingFailure(
        hasMatchingServices: Bool
    ) -> Bool {
        !hasMatchingServices
    }
}

/// The onboarding view only needs to know that audio has arrived once per voice session.
/// Keeping the monotonically increasing sample counter for diagnostics while publishing this
/// edge-triggered receipt avoids invalidating the whole SwiftUI tree for every audio packet.
enum VoiceSamplePresentationPolicy {
    static func shouldPublishReceipt(
        hasReceivedSamples: Bool,
        sampleCount: Int
    ) -> Bool {
        sampleCount > 0 && !hasReceivedSamples
    }
}

final class BridgeAppModel: ObservableObject, XiaomiBluetoothBridgeDelegate {
    private static let longRecordingOpenTimeout: TimeInterval = 5
    private static let longRecordingCloseTimeout: TimeInterval = 2

    let settings: AppSettings

    @Published private(set) var connectionStatus = LocalizedMessage("bluetooth.status.initializing")
    @Published private(set) var hidStatus = LocalizedMessage("button_mapping.status.disabled")
    @Published private(set) var audioStatus = LocalizedMessage("audio.output.none_selected")
    @Published private(set) var doubaoAudioStatus = LocalizedMessage("audio.compatibility.checking")
    @Published private(set) var isStreaming = false
    @Published private(set) var isMouseModeActive = false
    @Published private(set) var isConnected = false
    @Published private(set) var isVoiceTriggerEnabled = false
    @Published private(set) var activeRemoteButtons = Set<RemoteButton>()
    @Published private(set) var activeSiriRemoteButtons = Set<RemoteButton>()
    @Published private(set) var lastRemoteButtonPress: RemoteButton?
    @Published private(set) var connectedRemoteProfileIDs = Set<UUID>()
    @Published private(set) var remoteBatteryLevels: [UUID: Int] = [:]
    @Published private(set) var remotePowerStates: [UUID: RemotePowerState] = [:]
    @Published private(set) var audioDevices: [AudioDeviceInfo] = []
    @Published private(set) var testToneStatus = LocalizedMessage("audio.output.none_selected")
    @Published private(set) var isPlayingTestTone = false
    @Published private(set) var isAudioOutputReady = false
    @Published private(set) var currentVoiceSampleCount: UInt64 = 0
    @Published private(set) var hasReceivedCurrentVoiceSamples = false
    @Published private(set) var voiceShortcutStatus = LocalizedMessage("voice_button.status.preparing")

    private let audioOutput = VirtualAudioOutput()
    private let karaokeAudioOutput = VirtualAudioOutput()
    /// 小米遥控器后端适配层（事件镜像；小米链路仍由本类直接管理）
    private let xiaomiRemoteBackend = XiaomiRemoteBackend()
    /// Siri Remote 后端（设置页选择后启用；底层连接可并存，同一时刻只接收所选后端的语音）
    /// 懒加载：@MainActor 初始化器在首次访问（主线程路径）时执行
    private lazy var siriRemoteBackend = SiriRemoteBackend()
    /// 当前选中的遥控器后端（设置页"连接设备"）
    @Published private(set) var activeBackendKind: RemoteBackendKind = .xiaomi

    /// Siri Remote 电量（后端读取 HID 属性后更新）
    @Published private(set) var siriRemoteBatteryLevel: Int?
    /// Siri Remote 是否已连接（后端检测到遥控器 HID 设备）
    @Published private(set) var isSiriRemoteConnected = false
    private let voiceFunctionMapper = RemoteVoiceFunctionMapper()
    private lazy var mouseModeController: MouseModeController = {
        let controller = MouseModeController()
        controller.onStateChange = { [weak self] active in
            self?.isMouseModeActive = active
            self?.hidMonitors.values.forEach { $0.flushInFlightInputState() }
            self?.discoveryHIDMonitor?.flushInFlightInputState()
        }
        return controller
    }()
    private lazy var voiceInputDestinationCoordinator = VoiceInputDestinationCoordinator(
        onStateChange: { [weak self] state in
            self?.handleVoiceInputDestinationState(state)
        }
    )
    private lazy var voiceFnTapSession = VoiceFnTapSessionController(
        destinationReadiness: { [weak self] completion in
            self?.voiceInputDestinationCoordinator.waitUntilReady(completion: completion) ?? .immediate
        },
        setFunctionKeyPressed: { KeyboardInjector.setFunctionKeyPressed($0) },
        enqueueAudioWithSampleRate: { [weak self] samples, sampleRate in
            _ = self?.enqueueVoiceAudio(samples: samples, sampleRate: sampleRate)
        },
        drainAudio: { [weak self] completion in
            guard let self else {
                completion()
                return
            }
            self.audioOutput.endSessionAfterDraining(completion: completion)
        },
        onFailure: { [weak self] failure in
            self?.handleVoiceFnTapFailure(failure)
        }
    )
    private lazy var preferredInputSourceMonitor = PreferredInputSourceMonitor(
        voiceTool: { [weak self] in self?.settings.onboardingVoiceTool ?? .other }
    )
    private var voiceKeyIsHeld = false
    private var heldVoiceKeyMode: VoiceKeyMode?
    private var testToneGeneration = 0
    private var voiceSessionStartedAt: Date?
    private var voiceSessionUsageSource: UsageEventSource?
    private var bluetoothVoiceActive = false
    private var siriRemoteVoiceActive = false
    private var loggedBluetoothVoiceAudioDeviceIdentifier: UUID?
    private var longRecordingRequested = false
    private var longRecordingGeneration: UInt64 = 0
    private var longRecordingOpenTimer: DispatchSourceTimer?
    private var longRecordingCloseTimer: DispatchSourceTimer?
    private var remoteButtonGestureRecognizers: [UsageEventSource: RemoteButtonGestureRecognizer] = [:]
    private var remoteButtonDoubleClickTimers: [RemoteButtonGestureKey: DispatchSourceTimer] = [:]
    private var remoteButtonLongPressTimers: [RemoteButtonGestureKey: DispatchSourceTimer] = [:]
    private var bluetoothBridges: [UUID: XiaomiBluetoothBridge] = [:]
    private var bluetoothBridgeStates: [ObjectIdentifier: BluetoothBridgeState] = [:]
    private var discoveryBluetoothBridge: XiaomiBluetoothBridge?
    private var activeBluetoothVoiceDeviceIdentifier: UUID?
    private var bluetoothVoiceTraceCounter: UInt64 = 0
    private var activeBluetoothVoiceTraceID: UInt64?
    private var bluetoothVoiceTraceStartedAt: Date?
    private var bluetoothVoiceTraceModel: XiaomiRemoteModel = .unknown
    private var bluetoothVoiceDecodedBatchCount = 0
    private var bluetoothVoiceDecodedSampleCount = 0
    private var bluetoothVoiceEnqueueFailureCount = 0
    private var bluetoothVoiceTraceRoute = "none"
    private let hidEventSuppressor = KeyboardEventSuppressor()
    private var hidMonitors: [String: HIDRemoteMonitor] = [:]
    private var discoveryHIDMonitor: HIDRemoteMonitor?
    private var hidPowerKeySuppressed = false
    private var hidAllowedLocationIDs: Set<UInt32>?
    private var systemRemoteRuntimeState = SystemRemoteRuntimeLifecycleState()
    private var remoteWakeResumeWorkItem: DispatchWorkItem?
    private static let remoteWakeResumeGrace: TimeInterval = 15
    private let isUserVisibleWake: () -> Bool
    private var started = false
    private var terminationObserver: NSObjectProtocol?
    private var completedUpdateHIDRecoveryWorkItem: DispatchWorkItem?
    private var hidMappingRecoveryWorkItem: DispatchWorkItem?
    private var hidMappingRecoveryAttempt = 0
    private var hidMappingRecoveryGeneration: UInt64 = 0
    private let audioPreparationQueue = DispatchQueue(label: "RemoteMic.audioPreparation", qos: .userInitiated)
    private var audioStartupGeneration: UInt64 = 0
    private var audioDeviceRefreshGeneration: UInt64 = 0
    private var audioStartupPending = false
    private let audioHardwareListenerQueue = DispatchQueue(label: "RemoteMic.audioHardware")
    private var observedAudioHardwareAddresses: [AudioObjectPropertyAddress] = []
    private var audioRecoveryWorkItem: DispatchWorkItem?
    private var audioRecoveryGeneration: UInt64 = 0
    private var virtualAudioReleaseGeneration: UInt64 = 0
    private var pendingVirtualAudioRelease: (generation: UInt64, reason: String)?
    private let virtualAudioKeepAliveEnabled: Bool
    private var onDemandVirtualAudioReleaseWorkItem: DispatchWorkItem?
    private var onDemandVirtualAudioReleaseGeneration: UInt64 = 0
    static let onDemandVirtualAudioReleaseDelay: TimeInterval = 2.0
    private var systemAudioSuspensionState = SystemAudioSuspensionState()
    private var managedDefaultInputTransition: ManagedDefaultInputTransition?
    private lazy var audioHardwareListener: AudioObjectPropertyListenerBlock = { [weak self] count, addresses in
        let properties = Self.audioHardwarePropertyNames(count: count, addresses: addresses)
        self?.scheduleAudioRecovery(reason: "hardware_change", details: "properties=\(properties)")
    }

    var isVirtualAudioKeepAliveEnabled: Bool {
        virtualAudioKeepAliveEnabled
    }

    init(
        settings: AppSettings = AppSettings(),
        initialAudioDevices: [AudioDeviceInfo] = [],
        virtualAudioKeepAliveEnabled: Bool =
            ProcessInfo.processInfo.arguments.contains("--virtual-audio-keep-alive") ||
            UserDefaults.standard.bool(forKey: "VirtualAudioKeepAliveEnabled"),
        isUserVisibleWake: @escaping () -> Bool = { SystemWakeEnvironment.isUserVisibleWake }
    ) {
        self.settings = settings
        self.virtualAudioKeepAliveEnabled = virtualAudioKeepAliveEnabled
        self.isUserVisibleWake = isUserVisibleWake
        activeBackendKind = RemoteBackendKind(rawValue: settings.activeBackendKindRawValue)
            ?? .xiaomi
        audioDevices = initialAudioDevices
        audioOutput.onConfigurationChange = { [weak self] in
            self?.scheduleAudioRecovery(reason: "engine_configuration_change")
        }
    }

    func startIfNeeded() {
        guard !started else { return }
        started = true
        systemRemoteRuntimeState.reset()
        configureSiriRemoteBackend()
        if RemoteBackendRuntimePolicy.shouldRunSiriRemote(activeKind: activeBackendKind) {
            MainActor.assumeIsolated {
                siriRemoteBackend.start()
            }
        }
        startAudioSubsystem()
        applyHIDSettings()
        preferredInputSourceMonitor.start()
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.stop()
        }
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "development"
        AppLogger.shared.write("APP START version=\(version)")
    }

    func stop() {
        finishSiriRemoteVoice(reason: "app_stop")
        MainActor.assumeIsolated {
            siriRemoteBackend.stop()
        }
        guard started else { return }
        started = false
        remoteWakeResumeWorkItem?.cancel()
        remoteWakeResumeWorkItem = nil
        systemRemoteRuntimeState.reset()
        cancelHIDMappingRecovery(reason: "app_stop")
        completedUpdateHIDRecoveryWorkItem?.cancel()
        completedUpdateHIDRecoveryWorkItem = nil
        audioStartupGeneration &+= 1
        audioDeviceRefreshGeneration &+= 1
        let shouldStopAudioOnPreparationQueue = audioStartupPending
        audioStartupPending = false
        audioRecoveryGeneration &+= 1
        audioRecoveryWorkItem?.cancel()
        audioRecoveryWorkItem = nil
        cancelScheduledOnDemandVirtualAudioRelease(trigger: "app_stop")
        stopObservingAudioHardware()
        cancelTestToneIfNeeded(
            statusMessage: LocalizedMessage("app.status.stopped"),
            logReason: "app_stop"
        )
        stopLongRecording(reason: "app_stop")
        voiceInputDestinationCoordinator.shutdown()
        voiceFnTapSession.shutdown()
        preferredInputSourceMonitor.stop()
        releaseVoiceKeyIfNeeded()
        bluetoothBridges.values.forEach { $0.stop() }
        discoveryBluetoothBridge?.stop()
        bluetoothBridges.removeAll()
        bluetoothBridgeStates.removeAll()
        discoveryBluetoothBridge = nil
        activeBluetoothVoiceDeviceIdentifier = nil
        bluetoothVoiceActive = false
        voiceSessionUsageSource = nil
        stopHIDMonitors()
        isAudioOutputReady = false
        virtualAudioReleaseGeneration &+= 1
        pendingVirtualAudioRelease = nil
        managedDefaultInputTransition = nil
        if shouldStopAudioOnPreparationQueue {
            audioPreparationQueue.async { [weak self] in
                self?.audioOutput.stop()
                self?.karaokeAudioOutput.stop()
            }
        } else {
            audioOutput.stop()
            karaokeAudioOutput.stop()
        }
        voiceFunctionMapper.restore()
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
            self.terminationObserver = nil
        }
        AppLogger.shared.write("APP STOP")
    }

    static func shouldRecoverHIDAfterCompletedUpdate(
        completedUpdate: Bool,
        customMappingEnabled: Bool
    ) -> Bool {
        completedUpdate && customMappingEnabled
    }

    func recoverHIDAfterCompletedUpdate(delay: TimeInterval = 2) {
        guard started, systemRemoteRuntimeState.isActive, settings.customMappingEnabled else { return }
        completedUpdateHIDRecoveryWorkItem?.cancel()
        stopHIDMonitors()
        AppLogger.shared.write("HID UPDATE RECOVERY scheduled delay_ms=\(Int(delay * 1_000))")
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.started, self.systemRemoteRuntimeState.isActive,
                  self.settings.customMappingEnabled else { return }
            self.completedUpdateHIDRecoveryWorkItem = nil
            self.applyHIDSettings()
            AppLogger.shared.write("HID UPDATE RECOVERY applied")
        }
        completedUpdateHIDRecoveryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func reconnect() {
        guard started, systemRemoteRuntimeState.isActive else {
            AppLogger.shared.write("BLE RECONNECT deferred reason=system_remote_suspended")
            return
        }
        cancelHIDMappingRecovery(reason: "manual_reconnect")
        if activeBackendKind == .siriRemote {
            finishSiriRemoteVoice(reason: "manual_reconnect")
            MainActor.assumeIsolated {
                siriRemoteBackend.stop()
                siriRemoteBackend.start()
            }
            AppLogger.shared.write("SIRI REMOTE manual reconnect")
            return
        }
        if bluetoothBridges.isEmpty && discoveryBluetoothBridge == nil {
            AppLogger.shared.write("BLE RECONNECT starting_missing_bridges")
            startBluetoothConnections()
            return
        }
        if let selectedBluetoothBridge {
            selectedBluetoothBridge.reconnectNow()
        } else {
            bluetoothBridges.values.forEach { $0.reconnectNow() }
            discoveryBluetoothBridge?.reconnectNow()
        }
    }

    private func recoverBluetoothAfterSystemWake() {
        guard systemRemoteRuntimeState.isActive else {
            AppLogger.shared.write("BLE WAKE recovery_deferred reason=system_remote_suspended")
            return
        }
        let targets: [XiaomiBluetoothBridge]
        if let selectedBluetoothBridge {
            targets = [selectedBluetoothBridge]
        } else {
            targets = Array(bluetoothBridges.values)
        }
        AppLogger.shared.write(
            "BLE WAKE recovery_begin target_bridges=\(targets.count) " +
                "discovery=\(discoveryBluetoothBridge != nil) " +
                "ready_bridges=\(readyBluetoothBridgeCount)"
        )
        if targets.isEmpty, discoveryBluetoothBridge == nil {
            startBluetoothConnections()
            AppLogger.shared.write("BLE WAKE recovery_started_missing_bridges")
            return
        }
        targets.forEach { $0.recoverAfterSystemWake() }
        discoveryBluetoothBridge?.recoverAfterSystemWake()
        scheduleHIDMappingRecoveryIfNeeded()
    }

    func refreshRemoteDiscovery() {
        guard started, systemRemoteRuntimeState.isActive else {
            AppLogger.shared.write("BLE DISCOVERY deferred reason=system_remote_suspended")
            return
        }
        if discoveryBluetoothBridge == nil {
            startBluetoothDiscoveryIfNeeded()
        } else {
            discoveryBluetoothBridge?.reconnectNow()
        }
        AppLogger.shared.write("BLE DISCOVERY refreshed_from_foreground")
    }

    func refreshAudioDevices() {
        audioDeviceRefreshGeneration &+= 1
        let generation = audioDeviceRefreshGeneration
        AppLogger.shared.write("AUDIO DEVICES refresh_requested id=\(generation)")
        audioPreparationQueue.async { [weak self] in
            let devices = CoreAudioDeviceCatalog.outputDevices()
            let diagnostic = Self.audioDevicesDiagnostic(devices)
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.started,
                      self.audioDeviceRefreshGeneration == generation
                else { return }
                self.publishAudioDevices(devices)
                AppLogger.shared.write("AUDIO DEVICES refreshed id=\(generation) \(diagnostic)")
            }
        }
    }

    private func startAudioSubsystem() {
        audioStartupGeneration &+= 1
        let generation = audioStartupGeneration
        let selectedDeviceUID = settings.selectedAudioDeviceUID
        audioStartupPending = true
        AppLogger.shared.write("AUDIO STARTUP scheduled id=\(generation)")
        audioPreparationQueue.async { [weak self] in
            guard let self else { return }
            let devices = CoreAudioDeviceCatalog.outputDevices()
            let devicesDiagnostic = Self.audioDevicesDiagnostic(devices)
            AppLogger.shared.write("AUDIO DEVICES startup id=\(generation) \(devicesDiagnostic)")
            AppLogger.shared.write(
                "AUDIO REBIND begin reason=startup state={\(self.audioOutput.diagnosticState())}"
            )
            let configured = self.audioOutput.configure(deviceUID: selectedDeviceUID)
            _ = self.configureKaraokeOutput()
            let audioStatus = self.audioOutput.status
            let isAudioOutputReady = self.audioOutput.isReadyForTestTone
            let testToneStatus = isAudioOutputReady
                ? LocalizedMessage("audio.test_tone.ready")
                : LocalizedMessage("audio.output.none_or_unavailable")
            let outputState = self.audioOutput.diagnosticState()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.started, self.audioStartupGeneration == generation else {
                    self.audioPreparationQueue.async { [weak self] in
                        self?.audioOutput.stop()
                    }
                    return
                }
                self.audioStartupPending = false
                self.publishAudioDevices(devices)
                self.audioStatus = audioStatus
                self.isAudioOutputReady = isAudioOutputReady
                self.testToneStatus = testToneStatus
                self.startObservingAudioHardware()
                if self.systemAudioSuspensionState.isSuspended {
                    AppLogger.shared.write(
                        "SYSTEM AUDIO startup_release reasons=\(self.systemAudioSuspensionState.diagnostic) " +
                            "state={\(outputState)}"
                    )
                    self.releaseVirtualAudioOutputIfUnused(reason: "startup_system_suspended")
                } else if !self.virtualAudioKeepAliveEnabled {
                    AppLogger.shared.write(
                        "AUDIO ON_DEMAND startup_release state={\(outputState)}"
                    )
                    self.releaseVirtualAudioOutputIfUnused(reason: "startup_on_demand_idle")
                }
                self.startBluetoothConnections()
                AppLogger.shared.write(
                    "AUDIO REBIND finished reason=startup success=\(configured) status=\(audioStatus.key) " +
                        "state={\(outputState)}"
                )
            }
        }
    }

    private func publishAudioDevices(_ devices: [AudioDeviceInfo]) {
        audioDevices = devices
        doubaoAudioStatus = DoubaoAudioDevicePolicy.status(in: devices)
    }

    private static func audioDevicesDiagnostic(_ devices: [AudioDeviceInfo]) -> String {
        "outputs={\(CoreAudioDeviceCatalog.outputDevicesDiagnostic(devices))} " +
            CoreAudioDeviceCatalog.routeDiagnostic()
    }

    var hasDoubaoAudioDevice: Bool {
        DoubaoAudioDevicePolicy.device(in: audioDevices) != nil
    }

    func selectDoubaoAudioDevice() {
        guard let device = DoubaoAudioDevicePolicy.device(in: audioDevices) else {
            doubaoAudioStatus = LocalizedMessage(
                "audio.compatibility.device_missing",
                arguments: [DoubaoAudioDevicePolicy.deviceName]
            )
            return
        }
        settings.selectedAudioDeviceUID = device.uid
        applyAudioSettings(reason: "doubao_device_selected")
        doubaoAudioStatus = LocalizedMessage(
            "audio.compatibility.device_selected",
            arguments: [device.name]
        )
    }

    func openDoubaoDriverInstructions(using localization: LocalizationStore) {
        guard let instructions = localization.localizedURL(
            forResource: "DoubaoInputMethodCompatibility",
            withExtension: "md"
        ) else {
            return
        }
        NSWorkspace.shared.open(instructions)
    }

    func applyAudioSettings(reason: String = "settings_change") {
        stopLongRecording(reason: "audio_reconfigure")
        guard shouldKeepVirtualAudioActive else {
            releaseVirtualAudioOutputIfUnused(reason: reason)
            return
        }
        _ = configureVirtualAudioOutput(reason: reason)
    }

    @discardableResult
    private func configureVirtualAudioOutput(reason: String) -> Bool {
        cancelVirtualAudioReleaseIfPending(trigger: "rebind_\(reason)")
        virtualAudioReleaseGeneration &+= 1
        AppLogger.shared.write("AUDIO REBIND begin reason=\(reason) state={\(audioOutput.diagnosticState())}")
        cancelTestToneIfNeeded(
            statusMessage: LocalizedMessage("audio.test_tone.cancelled_device_changed"),
            logReason: "device_reconfigure"
        )
        let configured = audioOutput.configure(deviceUID: settings.selectedAudioDeviceUID)
        _ = configureKaraokeOutput()
        audioStatus = audioOutput.status
        isAudioOutputReady = audioOutput.isReadyForTestTone
        testToneStatus = isAudioOutputReady
            ? LocalizedMessage("audio.test_tone.ready")
            : LocalizedMessage("audio.output.none_or_unavailable")
        AppLogger.shared.write(
            "AUDIO REBIND finished reason=\(reason) success=\(configured) status=\(audioStatus.key) " +
                "state={\(audioOutput.diagnosticState())}"
        )
        if configured {
            restoreManagedDefaultInputIfAppropriate(reason: reason)
        }
        return configured
    }

    @discardableResult
    private func ensureVirtualAudioOutputReady(reason: String) -> Bool {
        cancelScheduledOnDemandVirtualAudioRelease(trigger: "ensure_\(reason)")
        isAudioOutputReady = audioOutput.isReadyForTestTone
        guard !isAudioOutputReady else { return true }
        AppLogger.shared.write(
            "AUDIO HEALTH stale reason=\(reason) state={\(audioOutput.diagnosticState())}"
        )
        return configureVirtualAudioOutput(reason: reason)
    }

    @discardableResult
    private func configureKaraokeOutput() -> Bool {
        let uid = settings.karaokeOutputDeviceUID
        guard !uid.isEmpty, uid != settings.selectedAudioDeviceUID else {
            karaokeAudioOutput.stop()
            return false
        }
        return karaokeAudioOutput.configure(deviceUID: uid)
    }

    @discardableResult
    private func enqueueVoiceAudio(samples: [Int16], sampleRate: Double) -> Bool {
        let primary = audioOutput.enqueue(samples: samples, sampleRate: sampleRate)
        if !settings.karaokeOutputDeviceUID.isEmpty {
            if !karaokeAudioOutput.isReadyForTestTone {
                _ = configureKaraokeOutput()
            }
            _ = karaokeAudioOutput.enqueue(samples: samples, sampleRate: sampleRate)
        }
        return primary
    }

    @discardableResult
    private func enqueueVoiceAudio(samples: [Float], sampleRate: Double) -> Bool {
        let primary = audioOutput.enqueue(samples: samples, sampleRate: sampleRate)
        if !settings.karaokeOutputDeviceUID.isEmpty {
            if !karaokeAudioOutput.isReadyForTestTone { _ = configureKaraokeOutput() }
            _ = karaokeAudioOutput.enqueue(samples: samples, sampleRate: sampleRate)
        }
        return primary
    }

    private func startObservingAudioHardware() {
        guard observedAudioHardwareAddresses.isEmpty else { return }
        rememberCurrentUserInputDeviceIfNeeded(reason: "audio_monitor_start")
        for selector in [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyDefaultSystemOutputDevice,
        ] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let result = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                audioHardwareListenerQueue,
                audioHardwareListener
            )
            if result == noErr {
                observedAudioHardwareAddresses.append(address)
            } else {
                AppLogger.shared.write("AUDIO RECOVERY listener_failed selector=\(selector) error=\(result)")
            }
        }
        AppLogger.shared.write("AUDIO ROUTE_MONITOR started properties=\(Self.audioHardwarePropertyNames(for: observedAudioHardwareAddresses))")
    }

    private func stopObservingAudioHardware() {
        for var address in observedAudioHardwareAddresses {
            _ = AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                audioHardwareListenerQueue,
                audioHardwareListener
            )
        }
        if !observedAudioHardwareAddresses.isEmpty {
            AppLogger.shared.write("AUDIO ROUTE_MONITOR stopped properties=\(Self.audioHardwarePropertyNames(for: observedAudioHardwareAddresses))")
        }
        observedAudioHardwareAddresses.removeAll()
    }

    private func scheduleAudioRecovery(reason: String, details: String = "") {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.started else { return }
            if details == "properties=default_input" {
                self.rememberCurrentUserInputDeviceIfNeeded(reason: "hardware_change")
            }
            guard !self.settings.selectedAudioDeviceUID.isEmpty else {
                AppLogger.shared.write("AUDIO RECOVERY ignored reason=\(reason) detail=\(details) no_selected_device")
                return
            }
            let configurationHealthy = self.audioOutput.isConfigurationHealthyForDiagnostics
            guard !VirtualAudioRecoveryPolicy.shouldIgnoreDefaultSystemOutputChange(
                details: details,
                configurationHealthy: configurationHealthy
            ) else {
                self.refreshAudioDevices()
                AppLogger.shared.write(
                    "AUDIO RECOVERY ignored reason=\(reason) detail=\(details) " +
                        "explicit_output_healthy=true state={\(self.audioOutput.diagnosticState())}"
                )
                return
            }
            guard details != "properties=default_input" else {
                self.refreshAudioDevices()
                AppLogger.shared.write(
                    "AUDIO RECOVERY ignored reason=\(reason) detail=\(details) explicit_output_unchanged"
                )
                return
            }
            guard self.shouldKeepVirtualAudioActive else {
                self.refreshAudioDevices()
                AppLogger.shared.write(
                    "AUDIO RECOVERY ignored reason=\(reason) detail=\(details) virtual_audio_inactive"
                )
                return
            }
            self.audioRecoveryGeneration &+= 1
            let generation = self.audioRecoveryGeneration
            let replacedPendingRecovery = self.audioRecoveryWorkItem != nil
            self.audioRecoveryWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self,
                      self.started,
                      self.audioRecoveryGeneration == generation
                else { return }
                AppLogger.shared.write(
                    "AUDIO RECOVERY begin id=\(generation) reason=\(reason) detail=\(details) " +
                        "state={\(self.audioOutput.diagnosticState())}"
                )
                self.refreshAudioDevices()
                self.applyAudioSettings(reason: "recovery_\(reason)")
                AppLogger.shared.write(
                    "AUDIO RECOVERY completed id=\(generation) reason=\(reason) " +
                        "state={\(self.audioOutput.diagnosticState())}"
                )
                self.audioRecoveryWorkItem = nil
            }
            self.audioRecoveryWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
            AppLogger.shared.write(
                "AUDIO RECOVERY scheduled id=\(generation) reason=\(reason) detail=\(details) " +
                    "replaced_pending=\(replacedPendingRecovery) state={\(self.audioOutput.diagnosticState())}"
            )
        }
    }

    private static func audioHardwarePropertyNames(
        count: UInt32,
        addresses: UnsafePointer<AudioObjectPropertyAddress>
    ) -> String {
        guard count > 0 else { return "none" }
        return (0..<Int(count))
            .map { audioHardwarePropertyName(addresses[$0].mSelector) }
            .joined(separator: ",")
    }

    private static func audioHardwarePropertyNames(
        for addresses: [AudioObjectPropertyAddress]
    ) -> String {
        addresses.map { audioHardwarePropertyName($0.mSelector) }.joined(separator: ",")
    }

    private static func audioHardwarePropertyName(
        _ selector: AudioObjectPropertySelector
    ) -> String {
        switch selector {
        case kAudioHardwarePropertyDevices:
            return "devices"
        case kAudioHardwarePropertyDefaultInputDevice:
            return "default_input"
        case kAudioHardwarePropertyDefaultOutputDevice:
            return "default_output"
        case kAudioHardwarePropertyDefaultSystemOutputDevice:
            return "default_system_output"
        default:
            return "selector_\(selector)"
        }
    }

    var canSendTestTone: Bool {
        TestToneGate.canPlay(
            hasSelectedDevice: selectedAudioDeviceIsAvailable,
            isStreaming: isStreaming,
            isPlaying: isPlayingTestTone
        )
    }

    func sendTestTone() {
        guard TestToneGate.canPlay(
            hasSelectedDevice: selectedAudioDeviceIsAvailable,
            isStreaming: isStreaming,
            isPlaying: isPlayingTestTone
        ) else {
            if isStreaming {
                testToneStatus = LocalizedMessage("audio.test_tone.blocked_voice_active")
                AppLogger.shared.write("AUDIO TEST_TONE rejected_streaming")
            } else if isPlayingTestTone {
                testToneStatus = LocalizedMessage("audio.test_tone.already_playing")
            } else {
                testToneStatus = LocalizedMessage("audio.output.none_or_unavailable")
            }
            return
        }

        cancelVirtualAudioReleaseIfPending(trigger: "test_tone_start")
        guard ensureVirtualAudioOutputReady(reason: "test_tone") else {
            testToneStatus = LocalizedMessage("audio.test_tone.device_not_ready")
            releaseVirtualAudioOutputIfUnused(reason: "test_tone_configure_failed")
            return
        }

        testToneGeneration &+= 1
        let generation = testToneGeneration
        let started = audioOutput.playTestTone { [weak self] finished in
            DispatchQueue.main.async {
                self?.handleTestToneCompletion(generation: generation, finished: finished)
            }
        }
        guard started else {
            testToneStatus = LocalizedMessage("audio.test_tone.device_not_ready")
            releaseVirtualAudioOutputIfUnused(reason: "test_tone_start_failed")
            return
        }
        isPlayingTestTone = true
        testToneStatus = LocalizedMessage("audio.test_tone.playing")
        AppLogger.shared.write("AUDIO TEST_TONE played")
    }

    private func handleTestToneCompletion(generation: Int, finished: Bool) {
        guard generation == testToneGeneration, isPlayingTestTone else { return }
        isPlayingTestTone = false
        testToneStatus = LocalizedMessage(finished ? "audio.test_tone.completed" : "audio.test_tone.cancelled")
        AppLogger.shared.write("AUDIO TEST_TONE \(finished ? "finished" : "cut_short")")
        releaseVirtualAudioOutputIfUnused(reason: "test_tone_finished")
    }

    private func cancelTestToneIfNeeded(statusMessage: LocalizedMessage, logReason: String) {
        guard isPlayingTestTone else { return }
        testToneGeneration &+= 1
        isPlayingTestTone = false
        audioOutput.cancelTestTone()
        testToneStatus = statusMessage
        AppLogger.shared.write("AUDIO TEST_TONE cancelled reason=\(logReason)")
    }

    static func canFallbackVoiceKeyMode(
        isStreaming: Bool,
        allowVoiceKeyModeFallback: Bool
    ) -> Bool {
        !isStreaming && allowVoiceKeyModeFallback
    }

    func applyHIDSettings(allowVoiceKeyModeFallback: Bool = true) {
        guard systemRemoteRuntimeState.isActive else {
            AppLogger.shared.write("HID APPLY deferred reason=system_remote_suspended")
            return
        }
        if !settings.customMappingEnabled {
            cancelHIDMappingRecovery(reason: "mapping_disabled")
            stopLongRecording(reason: "mapping_disabled")
        }
        if !settings.experimentalContinuousRecordingEnabled {
            stopLongRecording(reason: "feature_disabled")
        }

        var requestedVoiceKeyMode = settings.voiceKeyMode
        if requestedVoiceKeyMode.requiresAccessibility && !KeyboardInjector.isAccessibilityTrusted {
            requestedVoiceKeyMode = .function
            if settings.voiceKeyMode != .function { settings.voiceKeyMode = .function }
        }
        if !requestedVoiceKeyMode.usesHardwareMapping, settings.voiceFnTapModeEnabled {
            settings.voiceFnTapModeEnabled = false
        }
        let requestedFnTapMode = requestedVoiceKeyMode == .function && settings.voiceFnTapModeEnabled
        if !requestedFnTapMode, voiceFnTapSession.requiresCleanupBeforeMapping {
            voiceFnTapSession.setEnabled(false) { [weak self] in
                self?.applyHIDSettings(
                    allowVoiceKeyModeFallback: allowVoiceKeyModeFallback
                )
            }
            return
        }
        requestNextHIDPermissionIfNeeded(
            voiceFnTapModeRequested: requestedFnTapMode,
            voiceKeyMode: requestedVoiceKeyMode
        )
        var powerKeySuppressed: Bool
        let canFallbackVoiceKeyMode = Self.canFallbackVoiceKeyMode(
            isStreaming: isStreaming,
            allowVoiceKeyModeFallback: allowVoiceKeyModeFallback
        )
        if requestedVoiceKeyMode != .function {
            voiceFnTapSession.setEnabled(false)
            powerKeySuppressed = applyVoiceFunctionMapping(neutralizeVoiceKey: true)
            if !voiceFunctionMapper.isVoiceKeyNeutralized, canFallbackVoiceKeyMode {
                settings.voiceKeyMode = .function
                powerKeySuppressed = applyVoiceFunctionMapping(neutralizeVoiceKey: false)
            }
        } else if requestedFnTapMode, KeyboardInjector.isAccessibilityTrusted {
            powerKeySuppressed = applyVoiceFunctionMapping(neutralizeVoiceKey: true)
            if voiceFunctionMapper.isVoiceKeyNeutralized {
                voiceFnTapSession.setEnabled(true)
            } else if HIDMappingRecoveryPolicy.shouldPreserveFnTapPreferenceAfterMappingFailure(
                hasMatchingServices: voiceFunctionMapper.hasMatchingServices
            ) {
                voiceFnTapSession.setEnabled(false)
                AppLogger.shared.write(
                    "VOICE FN TAP mode_pending_mapping reason=no_matching_service"
                )
                scheduleHIDMappingRecoveryIfNeeded()
                powerKeySuppressed = !settings.customMappingEnabled ||
                    voiceFunctionMapper.isPowerKeySuppressed
            } else if canFallbackVoiceKeyMode {
                settings.voiceFnTapModeEnabled = false
                voiceFnTapSession.setEnabled(false)
                powerKeySuppressed = applyVoiceFunctionMapping(neutralizeVoiceKey: false)
            } else {
                AppLogger.shared.write(
                    "VOICE FN TAP mode_preserved reason=voice_start_mapping_failed"
                )
                powerKeySuppressed = !settings.customMappingEnabled ||
                    voiceFunctionMapper.isPowerKeySuppressed
            }
        } else {
            if requestedFnTapMode {
                settings.voiceFnTapModeEnabled = false
            }
            voiceFnTapSession.setEnabled(false)
            if canFallbackVoiceKeyMode {
                powerKeySuppressed = applyVoiceFunctionMapping(neutralizeVoiceKey: false)
            } else {
                voiceShortcutStatus = LocalizedMessage("voice_button.status.waiting")
                AppLogger.shared.write(
                    "VOICE KEY mode_preserved reason=voice_start_mapping_failed"
                )
                powerKeySuppressed = !settings.customMappingEnabled ||
                    voiceFunctionMapper.isPowerKeySuppressed
            }
        }
        startHIDMonitors(powerKeySuppressed: powerKeySuppressed)
        completeHIDMappingRecoveryIfNeeded()
    }

    private func scheduleHIDMappingRecoveryIfNeeded() {
        guard systemRemoteRuntimeState.isActive else { return }
        guard settings.customMappingEnabled else { return }
        guard hidMappingRecoveryWorkItem == nil else { return }
        guard let delay = HIDMappingRecoveryPolicy.retryDelay(
            forAttempt: hidMappingRecoveryAttempt,
            started: started,
            readyBridgeCount: readyBluetoothBridgeCount,
            hasMatchingServices: voiceFunctionMapper.hasMatchingServices
        ) else {
            if hidMappingRecoveryAttempt == HIDMappingRecoveryPolicy.retryDelays.count {
                AppLogger.shared.write(
                    "HID MAPPING RECOVERY exhausted attempts=\(hidMappingRecoveryAttempt)"
                )
            }
            return
        }

        hidMappingRecoveryAttempt += 1
        hidMappingRecoveryGeneration &+= 1
        let generation = hidMappingRecoveryGeneration
        let attempt = hidMappingRecoveryAttempt
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.hidMappingRecoveryGeneration == generation else { return }
            self.hidMappingRecoveryWorkItem = nil
            guard self.started,
                  self.readyBluetoothBridgeCount > 0,
                  !self.voiceFunctionMapper.hasMatchingServices
            else {
                self.cancelHIDMappingRecovery(reason: "conditions_changed")
                return
            }
            AppLogger.shared.write("HID MAPPING RECOVERY applying attempt=\(attempt)")
            self.applyHIDSettings()
            if !self.voiceFunctionMapper.hasMatchingServices {
                self.scheduleHIDMappingRecoveryIfNeeded()
            }
        }
        hidMappingRecoveryWorkItem = workItem
        AppLogger.shared.write(
            "HID MAPPING RECOVERY scheduled attempt=\(attempt) delay_ms=\(Int(delay * 1_000))"
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func completeHIDMappingRecoveryIfNeeded() {
        guard voiceFunctionMapper.hasMatchingServices,
              hidMappingRecoveryWorkItem != nil || hidMappingRecoveryAttempt > 0 else { return }
        let attempts = hidMappingRecoveryAttempt
        hidMappingRecoveryGeneration &+= 1
        hidMappingRecoveryWorkItem?.cancel()
        hidMappingRecoveryWorkItem = nil
        hidMappingRecoveryAttempt = 0
        AppLogger.shared.write("HID MAPPING RECOVERY completed attempts=\(attempts)")
    }

    private func cancelHIDMappingRecovery(reason: String) {
        guard hidMappingRecoveryWorkItem != nil || hidMappingRecoveryAttempt > 0 else { return }
        let attempts = hidMappingRecoveryAttempt
        hidMappingRecoveryGeneration &+= 1
        hidMappingRecoveryWorkItem?.cancel()
        hidMappingRecoveryWorkItem = nil
        hidMappingRecoveryAttempt = 0
        AppLogger.shared.write(
            "HID MAPPING RECOVERY cancelled reason=\(reason) attempts=\(attempts)"
        )
    }

    private func startHIDMonitors(powerKeySuppressed: Bool) {
        guard systemRemoteRuntimeState.isActive else { return }
        stopHIDMonitors()
        let backOnlyMode = !settings.customMappingEnabled &&
            settings.remoteDeviceProfiles.contains { $0.hidFingerprint != nil }
        hidPowerKeySuppressed = powerKeySuppressed
        hidAllowedLocationIDs = settings.customMappingEnabled
            ? voiceFunctionMapper.powerSuppressedLocationIDs
            : nil
        guard settings.customMappingEnabled || backOnlyMode else {
            hidStatus = LocalizedMessage("button_mapping.status.system_managed")
            return
        }
        if settings.customMappingEnabled { _ = hidEventSuppressor.start() }
        for profile in settings.remoteDeviceProfiles {
            guard let fingerprint = profile.hidFingerprint else { continue }
            let monitor = makeHIDMonitor(
                profileID: profile.id,
                targetFingerprint: fingerprint
            )
            hidMonitors[fingerprint] = monitor
            monitor.start(
                powerKeySuppressed: powerKeySuppressed,
                allowedLocationIDs: hidAllowedLocationIDs,
                allowBackOnly: backOnlyMode
            )
        }
        startHIDDiscoveryIfNeeded(allowBackOnly: backOnlyMode)
    }

    private func stopHIDMonitors() {
        hidMonitors.values.forEach { $0.stop() }
        discoveryHIDMonitor?.stop()
        hidMonitors.removeAll()
        discoveryHIDMonitor = nil
        hidEventSuppressor.stop()
        activeRemoteButtons = []
    }

    private func startHIDDiscoveryIfNeeded(allowBackOnly: Bool = false) {
        guard systemRemoteRuntimeState.isActive,
              (settings.customMappingEnabled || allowBackOnly),
              discoveryHIDMonitor == nil
        else { return }
        let monitor = makeHIDMonitor(
            profileID: nil,
            targetFingerprint: nil,
            excludedFingerprints: { [weak self] in
                guard let self else { return [] }
                return Set(self.hidMonitors.keys)
            }
        )
        discoveryHIDMonitor = monitor
        monitor.start(
            powerKeySuppressed: hidPowerKeySuppressed,
            allowedLocationIDs: hidAllowedLocationIDs,
            allowBackOnly: allowBackOnly
        )
    }

    private func makeHIDMonitor(
        profileID: UUID?,
        targetFingerprint: String?,
        excludedFingerprints: @escaping () -> Set<String> = { [] }
    ) -> HIDRemoteMonitor {
        let monitor = HIDRemoteMonitor(
            settings: settings,
            profileID: profileID,
            targetFingerprint: targetFingerprint,
            excludedFingerprints: excludedFingerprints,
            eventSuppressor: hidEventSuppressor,
            ownsEventSuppressor: false,
            actionPerformer: { [weak self] _, _, configured in
                self?.performExternalConfiguredAction(configured) ?? false
            }
        )
        monitor.mouseModeEdgeHandler = { [weak self] button, edge in
            self?.mouseModeController.handle(button: button, edge: edge) ?? false
        }
        monitor.onStatus = { [weak self, weak monitor] value in
            guard let self, let monitor else { return }
            if monitor.profileID == self.settings.selectedRemoteProfileID || monitor.profileID == nil {
                self.hidStatus = value
            }
        }
        monitor.onActiveButtons = { [weak self] profileID, buttons in
            guard let self, profileID == self.settings.selectedRemoteProfileID else { return }
            self.activeRemoteButtons = buttons
        }
        monitor.onButtonPressed = { [weak self, weak monitor] profileID, fingerprint, button in
            guard let self, let monitor else {
                return profileID.map { ($0, true) }
            }
            self.lastRemoteButtonPress = button
            let existingProfileID = profileID
                ?? self.settings.profileID(forHIDFingerprint: fingerprint)
            let resolvedProfileID = existingProfileID
                ?? self.settings.registerHIDRemote(fingerprint: fingerprint)
            let isNewBinding = existingProfileID == nil
            if isNewBinding {
                monitor.assignProfileID(resolvedProfileID)
                self.hidMonitors[fingerprint] = monitor
                if self.discoveryHIDMonitor === monitor {
                    self.discoveryHIDMonitor = nil
                    self.startHIDDiscoveryIfNeeded()
                }
            }
            self.selectRemoteProfile(resolvedProfileID)
            self.xiaomiRemoteBackend.forwardButton(button, isPressed: true)
            self.settings.recordButtonPress(
                control: .remoteButton(button),
                source: .bluetoothRemote
            )
            return (resolvedProfileID, true)
        }
        monitor.onInternalAction = { [weak self] profileID, action in
            guard let self else { return }
            if let profileID { self.selectRemoteProfile(profileID) }
            self.performInternalAction(action)
        }
        return monitor
    }

    func setExperimentalContinuousRecordingEnabled(_ enabled: Bool) {
        if !enabled {
            stopLongRecording(reason: "feature_disabled")
        }
        settings.setExperimentalContinuousRecordingEnabled(enabled)
        applyHIDSettings()
    }

    func setVoiceFnTapModeEnabled(_ enabled: Bool) {
        if enabled {
            enableVoiceFnTapMode()
            return
        }
        settings.voiceFnTapModeEnabled = false
        voiceFnTapSession.setEnabled(false) { [weak self] in
            self?.applyHIDSettings()
        }
    }

    func setVoiceKeyMode(_ mode: VoiceKeyMode) {
        guard mode != settings.voiceKeyMode else { return }
        guard !isStreaming else { return }
        releaseVoiceKeyIfNeeded()
        settings.voiceKeyMode = mode
        if mode != .function { settings.voiceFnTapModeEnabled = false }
        applyHIDSettings()
    }

    private func enableVoiceFnTapMode() {
        guard KeyboardInjector.isAccessibilityTrusted else {
            settings.voiceFnTapModeEnabled = false
            requestNextHIDPermissionIfNeeded(voiceFnTapModeRequested: true)
            applyHIDSettings()
            return
        }

        var powerKeySuppressed = applyVoiceFunctionMapping(neutralizeVoiceKey: true)
        guard voiceFunctionMapper.isVoiceKeyNeutralized else {
            settings.voiceFnTapModeEnabled = false
            voiceFnTapSession.setEnabled(false)
            powerKeySuppressed = applyVoiceFunctionMapping(neutralizeVoiceKey: false)
            startHIDMonitors(powerKeySuppressed: powerKeySuppressed)
            return
        }
        settings.voiceFnTapModeEnabled = true
        voiceFnTapSession.setEnabled(true)
        startHIDMonitors(powerKeySuppressed: powerKeySuppressed)
    }

    private func handleVoiceFnTapFailure(_ failure: VoiceFnTapFailure) {
        AppLogger.shared.write("VOICE FN TAP failed reason=\(failure.rawValue) fallback=hardware_fn")
        settings.voiceFnTapModeEnabled = false
        voiceFnTapSession.setEnabled(false)
        applyHIDSettings()
    }

    private func requestNextHIDPermissionIfNeeded(
        voiceFnTapModeRequested: Bool? = nil,
        voiceKeyMode: VoiceKeyMode? = nil
    ) {
        let request = HIDPermissionGate.nextPermissionRequest(
            mappingEnabled: settings.customMappingEnabled,
            voiceFnTapModeEnabled: voiceFnTapModeRequested ?? settings.voiceFnTapModeEnabled,
            voiceKeyMode: voiceKeyMode ?? settings.voiceKeyMode,
            inputMonitoringGranted: HIDRemoteMonitor.isInputMonitoringGranted,
            accessibilityGranted: KeyboardInjector.isAccessibilityTrusted
        )
        switch request {
        case .none:
            break
        case .inputMonitoring:
            _ = HIDRemoteMonitor.requestInputMonitoringAccess()
        case .accessibility:
            _ = KeyboardInjector.requestAccessibilityAccess()
        }
    }

    private func updateVoiceKeyState(streaming: Bool) {
        let mode = settings.voiceKeyMode
        // Fn remains the existing hardware/software path. Only Command modes
        // need an explicit synthetic key pair; injecting Fn here would
        // duplicate the mapped remote event.
        guard mode != .function else { return }
        if streaming {
            guard !voiceKeyIsHeld else { return }
            guard KeyboardInjector.setVoiceKeyPressed(mode: mode, isPressed: true) else {
                AppLogger.shared.write("VOICE KEY press_failed mode=\(mode.rawValue)")
                return
            }
            voiceKeyIsHeld = true
            heldVoiceKeyMode = mode
            if mode != .function { preferredInputSourceMonitor.beginVoiceSession() }
        } else {
            releaseVoiceKeyIfNeeded()
        }
    }

    private func releaseVoiceKeyIfNeeded() {
        guard voiceKeyIsHeld, let mode = heldVoiceKeyMode else { return }
        _ = KeyboardInjector.setVoiceKeyPressed(mode: mode, isPressed: false)
        voiceKeyIsHeld = false
        heldVoiceKeyMode = nil
        if mode != .function { preferredInputSourceMonitor.endVoiceSession() }
    }

    func requestInputMonitoringPermission() {
        _ = HIDRemoteMonitor.requestInputMonitoringAccess()
        openPrivacyPane("Privacy_ListenEvent")
    }

    func requestAccessibilityPermission() {
        _ = KeyboardInjector.requestAccessibilityAccess()
        openPrivacyPane("Privacy_Accessibility")
    }

    func openLogFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([AppLogger.shared.logURL])
    }

    func openProjectFolder() {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        var candidate = executable.deletingLastPathComponent()
        if candidate.path.contains(".app/Contents/MacOS") {
            candidate.deleteLastPathComponent()
            candidate.deleteLastPathComponent()
            candidate.deleteLastPathComponent()
        }
        NSWorkspace.shared.open(candidate)
    }

    private func openPrivacyPane(_ pane: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private var selectedBluetoothBridge: XiaomiBluetoothBridge? {
        guard let identifier = settings.selectedRemoteProfile?.bluetoothIdentifier else { return nil }
        return bluetoothBridges[identifier]
    }

    private func configureSiriRemoteBackend() {
        MainActor.assumeIsolated {
            siriRemoteBackend.onButton = { [weak self] button, isPressed in
                DispatchQueue.main.async {
                    self?.handleSiriRemoteButton(button, isPressed: isPressed)
                }
            }
            siriRemoteBackend.onAudioSamples = { [weak self] samples, sampleRate in
                DispatchQueue.main.async {
                    self?.receiveSiriRemoteAudio(samples, sampleRate: sampleRate)
                }
            }
            siriRemoteBackend.onBatteryLevelChange = { [weak self] level in
                DispatchQueue.main.async {
                    self?.siriRemoteBatteryLevel = level
                }
            }
            siriRemoteBackend.onConnectionStateChange = { [weak self] connected in
                DispatchQueue.main.async {
                    self?.handleSiriRemoteConnectionChange(connected)
                }
            }
            siriRemoteBackend.onVoiceStreamEnded = { [weak self] in
                DispatchQueue.main.async {
                    self?.finishSiriRemoteVoice(reason: "remote_stream_ended")
                }
            }
        }
    }

    /// 切换设置页选中的遥控器后端。小米底层连接保持运行以便快速切回，
    /// 但语音只接受当前后端，避免 16 kHz 与 48 kHz 会话互相污染。
    func setActiveBackend(_ kind: RemoteBackendKind) {
        guard kind != activeBackendKind else { return }
        activeBackendKind = kind
        settings.setActiveBackendKind(kind)
        switch kind {
        case .xiaomi:
            finishSiriRemoteVoice(reason: "backend_switched")
            resetRemoteButtonGestures(source: .siriRemote)
            activeSiriRemoteButtons.removeAll()
            MainActor.assumeIsolated {
                siriRemoteBackend.stop()
            }
            if isConnected {
                voiceFnTapSession.resume()
            }
        case .siriRemote:
            if let identifier = activeBluetoothVoiceDeviceIdentifier,
               let bridge = bluetoothBridges[identifier] {
                _ = bridge.requestMicrophoneClose()
                bluetoothBridgeDidStopVoice(bridge)
                AppLogger.shared.write("ATVV STREAM stopped reason=backend_switched")
            }
            MainActor.assumeIsolated {
                siriRemoteBackend.start()
            }
        }
        AppLogger.shared.write("BACKEND switched kind=\(kind.rawValue)")
    }

    /// Siri Remote 按键：复用移动端手势体系（单击/双击/长按 → 配置动作）。
    /// voice 键特判：控制麦克风语音会话（0xFA 音频流），不产生按键动作。
    private func handleSiriRemoteButton(_ button: RemoteButton, isPressed: Bool) {
        if isPressed {
            activeSiriRemoteButtons.insert(button)
        } else {
            activeSiriRemoteButtons.remove(button)
        }
        if button == .voice {
            MainActor.assumeIsolated {
                if isPressed {
                    siriRemoteBackend.startMicrophone()
                } else {
                    siriRemoteBackend.stopMicrophone()
                }
            }
            if isPressed {
                startSiriRemoteVoice()
            } else {
                finishSiriRemoteVoice(reason: "button_released")
            }
            return
        }
        _ = handleRemoteButtonEvent(
            button,
            phase: isPressed ? .press : .release,
            source: .siriRemote
        )
    }

    private func startSiriRemoteVoice() {
        guard activeBackendKind == .siriRemote, !siriRemoteVoiceActive else { return }
        cancelScheduledOnDemandVirtualAudioRelease(trigger: "siri_voice_start")
        guard isAudioOutputReady || configureVirtualAudioOutput(reason: "siri_voice_start") else {
            MainActor.assumeIsolated {
                siriRemoteBackend.stopMicrophone()
            }
            AppLogger.shared.write("SIRI REMOTE voice rejected reason=audio_unavailable")
            return
        }
        siriRemoteVoiceActive = true
        currentVoiceSampleCount = 0
        hasReceivedCurrentVoiceSamples = false
        voiceFnTapSession.resume()
        _ = voiceFnTapSession.startVoice()
        beginVoiceSessionIfNeeded()
        updateVoiceKeyState(streaming: true)
        AppLogger.shared.write("SIRI REMOTE voice started")
    }

    private func receiveSiriRemoteAudio(_ samples: [Float], sampleRate: Double) {
        guard siriRemoteVoiceActive, !samples.isEmpty else { return }
        let int16Samples = samples.map { sample -> Int16 in
            let scaled = max(-1, min(1, sample)) * Float(Int16.max)
            return Int16(scaled.rounded())
        }
        let handledByFnTapMode = voiceFnTapSession.receive(
            int16Samples,
            sampleRate: sampleRate
        )
        let enqueued = handledByFnTapMode
            || enqueueVoiceAudio(samples: samples, sampleRate: sampleRate)
        if enqueued {
            currentVoiceSampleCount &+= UInt64(samples.count)
            publishCurrentVoiceSampleReceiptIfNeeded(sampleCount: samples.count)
        }
    }

    private func finishSiriRemoteVoice(reason: String) {
        guard siriRemoteVoiceActive else { return }
        siriRemoteVoiceActive = false
        updateVoiceKeyState(streaming: false)
        _ = voiceFnTapSession.stopVoice()
        endVoiceSessionIfNeeded(flushAudio: false)
        if !shouldKeepVirtualAudioActive {
            scheduleOnDemandVirtualAudioRelease(reason: "siri_voice_\(reason)")
        } else {
            releaseVirtualAudioOutputIfUnused(reason: "siri_voice_\(reason)")
        }
        AppLogger.shared.write(
            "SIRI REMOTE voice stopped reason=\(reason) samples=\(currentVoiceSampleCount)"
        )
    }

    private func handleSiriRemoteConnectionChange(_ connected: Bool) {
        isSiriRemoteConnected = connected
        if connected, activeBackendKind == .siriRemote {
            voiceFnTapSession.resume()
            if shouldKeepVirtualAudioActive {
                cancelScheduledOnDemandVirtualAudioRelease(trigger: "siri_remote_ready")
                _ = ensureVirtualAudioOutputReady(reason: "siri_remote_ready")
            } else if !isAudioOutputReady {
                AppLogger.shared.write(
                    "AUDIO REBIND deferred reason=siri_remote_ready on_demand_idle=true"
                )
            }
            return
        }
        if !connected {
            activeSiriRemoteButtons.removeAll()
            resetRemoteButtonGestures(source: .siriRemote)
            finishSiriRemoteVoice(reason: "disconnected")
        }
        guard !isConnected else { return }
        voiceFnTapSession.suspend { [weak self] in
            self?.releaseVirtualAudioOutputIfUnused(reason: "siri_remote_not_ready")
        }
    }

    private func startBluetoothConnections() {
        guard systemRemoteRuntimeState.isActive else { return }
        let identifiers = Set(settings.remoteDeviceProfiles.compactMap(\.bluetoothIdentifier))
        for identifier in identifiers where bluetoothBridges[identifier] == nil {
            let bridge = XiaomiBluetoothBridge(
                settings: settings,
                delegate: self,
                targetIdentifier: identifier
            )
            bluetoothBridges[identifier] = bridge
            bridge.start()
        }
        startBluetoothDiscoveryIfNeeded()
    }

    private func startBluetoothDiscoveryIfNeeded() {
        guard started, systemRemoteRuntimeState.isActive, discoveryBluetoothBridge == nil else { return }
        let bridge = XiaomiBluetoothBridge(
            settings: settings,
            delegate: self,
            excludedIdentifiers: { [weak self] in
                guard let self else { return [] }
                return Set(self.bluetoothBridges.keys)
            }
        )
        discoveryBluetoothBridge = bridge
        bridge.start()
    }

    private func registerBluetoothBridgeIfNeeded(_ bridge: XiaomiBluetoothBridge) -> UUID? {
        guard let identifier = bluetoothIdentifier(for: bridge) else { return nil }
        let profileID = settings.profileID(forBluetoothIdentifier: identifier)
            ?? settings.registerBluetoothRemote(identifier: identifier)
        if discoveryBluetoothBridge === bridge {
            discoveryBluetoothBridge = nil
            bluetoothBridges[identifier] = bridge
            startBluetoothDiscoveryIfNeeded()
        } else if bluetoothBridges[identifier] == nil {
            bluetoothBridges[identifier] = bridge
        }
        return profileID
    }

    private func bluetoothIdentifier(for bridge: XiaomiBluetoothBridge) -> UUID? {
        bridge.deviceIdentifier ?? bluetoothBridges.first(where: { $0.value === bridge })?.key
    }

    private func remoteProfileID(for bridge: XiaomiBluetoothBridge) -> UUID? {
        guard let identifier = bluetoothIdentifier(for: bridge) else { return nil }
        return settings.profileID(forBluetoothIdentifier: identifier)
            ?? settings.registerBluetoothRemote(identifier: identifier)
    }

    func selectRemoteProfile(_ profileID: UUID) {
        settings.selectRemoteProfile(profileID)
        refreshBluetoothPresentation()
    }

    private func activateRemoteProfile(for bridge: XiaomiBluetoothBridge) -> UUID? {
        guard let profileID = registerBluetoothBridgeIfNeeded(bridge) else { return nil }
        selectRemoteProfile(profileID)
        return profileID
    }

    private func refreshBluetoothPresentation() {
        let allStates = bluetoothBridgeStates.values
        connectedRemoteProfileIDs = Set(bluetoothBridges.compactMap { identifier, bridge in
            guard let profileID = settings.profileID(forBluetoothIdentifier: identifier),
                  let state = bluetoothBridgeStates[ObjectIdentifier(bridge)],
                  case .ready = state
            else { return nil }
            return profileID
        })
        isConnected = allStates.contains { state in
            if case .ready = state { return true }
            return false
        }
        if let selectedBluetoothBridge,
           let state = bluetoothBridgeStates[ObjectIdentifier(selectedBluetoothBridge)] {
            connectionStatus = state.message
        } else if let ready = allStates.first(where: { state in
            if case .ready = state { return true }
            return false
        }) {
            connectionStatus = ready.message
        } else if let state = allStates.first {
            connectionStatus = state.message
        } else {
            connectionStatus = LocalizedMessage("connection.status.searching")
        }
    }

    func bluetoothBridge(
        _ bridge: XiaomiBluetoothBridge,
        didChange state: BluetoothBridgeState
    ) {
        let hadReadyBridge = bluetoothBridgeStates.values.contains { existingState in
            if case .ready = existingState { return true }
            return false
        }
        bluetoothBridgeStates[ObjectIdentifier(bridge)] = state
        guard systemRemoteRuntimeState.isActive else {
            refreshBluetoothPresentation()
            return
        }
        if case .ready = state {
            _ = registerBluetoothBridgeIfNeeded(bridge)
            voiceFnTapSession.resume()
            if !hadReadyBridge {
                applyHIDSettings()
            }
            scheduleHIDMappingRecoveryIfNeeded()
        } else {
            let identifier = bluetoothIdentifier(for: bridge)
            if let identifier,
               let profileID = settings.profileID(forBluetoothIdentifier: identifier) {
                remoteBatteryLevels.removeValue(forKey: profileID)
                remotePowerStates.removeValue(forKey: profileID)
            }
            let voiceWasActive = identifier == activeBluetoothVoiceDeviceIdentifier
            if voiceWasActive {
                bluetoothVoiceActive = false
                activeBluetoothVoiceDeviceIdentifier = nil
                endVoiceSessionIfNeeded(flushAudio: false)
            }
            if readyBluetoothBridgeCount == 0 {
                cancelHIDMappingRecovery(reason: "bluetooth_not_ready")
            }
            if longRecordingRequested {
                finishLongRecording(reason: "bluetooth_not_ready")
            }
        }
        refreshBluetoothPresentation()
        if isConnected {
            voiceFnTapSession.resume()
            if shouldKeepVirtualAudioActive {
                cancelVirtualAudioReleaseIfPending(trigger: "bluetooth_ready")
                _ = ensureVirtualAudioOutputReady(reason: "bluetooth_ready")
            } else if !isAudioOutputReady {
                AppLogger.shared.write(
                    "AUDIO REBIND deferred reason=bluetooth_ready " +
                        "system_suspended=\(systemAudioSuspensionState.isSuspended) " +
                        "reasons=\(systemAudioSuspensionState.diagnostic)"
                )
            }
        } else if !(activeBackendKind == .siriRemote && isSiriRemoteConnected) {
            voiceFnTapSession.suspend { [weak self] in
                self?.releaseVirtualAudioOutputIfUnused(reason: "bluetooth_not_ready")
            }
        }
    }

    func bluetoothBridgeDidStartVoice(_ bridge: XiaomiBluetoothBridge) {
        guard systemRemoteRuntimeState.isActive else {
            _ = bridge.requestMicrophoneClose()
            AppLogger.shared.write("ATVV STREAM rejected reason=system_remote_suspended")
            return
        }
        guard activeBackendKind == .xiaomi else {
            _ = bridge.requestMicrophoneClose()
            AppLogger.shared.write("ATVV STREAM rejected reason=inactive_backend")
            return
        }
        guard let identifier = bridge.deviceIdentifier else { return }
        let profileID = activateRemoteProfile(for: bridge)
        if let activeBluetoothVoiceDeviceIdentifier,
           activeBluetoothVoiceDeviceIdentifier != identifier {
            _ = bridge.requestMicrophoneClose()
            AppLogger.shared.write("ATVV STREAM rejected_busy")
            return
        }
        if settings.voiceFnTapModeEnabled {
            applyHIDSettings(allowVoiceKeyModeFallback: false)
        }
        guard ensureVirtualAudioOutputReady(reason: "bluetooth_voice_start") else {
            _ = bridge.requestMicrophoneClose()
            AppLogger.shared.write("ATVV STREAM rejected reason=audio_not_ready")
            return
        }
        activeBluetoothVoiceDeviceIdentifier = identifier
        loggedBluetoothVoiceAudioDeviceIdentifier = nil
        bluetoothVoiceActive = true
        let model = profileID
            .flatMap { id in settings.remoteDeviceProfiles.first(where: { $0.id == id })?.model }
            ?? .unknown
        bluetoothVoiceTraceCounter &+= 1
        activeBluetoothVoiceTraceID = bluetoothVoiceTraceCounter
        bluetoothVoiceTraceStartedAt = Date()
        bluetoothVoiceTraceModel = model
        bluetoothVoiceDecodedBatchCount = 0
        bluetoothVoiceDecodedSampleCount = 0
        currentVoiceSampleCount = 0
        hasReceivedCurrentVoiceSamples = false
        bluetoothVoiceEnqueueFailureCount = 0
        bluetoothVoiceTraceRoute = "none"
        AppLogger.shared.write(
            "ATVV STREAM accepted trace=\(bluetoothVoiceTraceCounter) model=\(model.rawValue)"
        )
        if longRecordingRequested {
            longRecordingOpenTimer?.cancel()
            longRecordingOpenTimer = nil
            AppLogger.shared.write("LONG RECORDING started")
        }
        _ = voiceFnTapSession.startVoice()
        beginVoiceSessionIfNeeded()
        updateVoiceKeyState(streaming: true)
    }

    func bluetoothBridgeDidStopVoice(_ bridge: XiaomiBluetoothBridge) {
        guard bridge.deviceIdentifier == activeBluetoothVoiceDeviceIdentifier else { return }
        activeBluetoothVoiceDeviceIdentifier = nil
        loggedBluetoothVoiceAudioDeviceIdentifier = nil
        bluetoothVoiceActive = false
        if longRecordingRequested {
            finishLongRecording(reason: "remote_stop")
        } else if longRecordingCloseTimer != nil {
            longRecordingCloseTimer?.cancel()
            longRecordingCloseTimer = nil
            AppLogger.shared.write("LONG RECORDING close_confirmed")
        }
        let handledByFnTapMode = voiceFnTapSession.stopVoice()
        updateVoiceKeyState(streaming: false)
        let shouldFlushAudio = BluetoothVoiceStopPolicy.shouldFlushAudio(
            handledByFnTapMode: handledByFnTapMode
        )
        let traceID = activeBluetoothVoiceTraceID ?? 0
        let durationMilliseconds = bluetoothVoiceTraceStartedAt.map {
            max(0, Int(Date().timeIntervalSince($0) * 1_000))
        } ?? 0
        let pendingBuffers = audioOutput.pendingVoiceBufferCountForDiagnostics
        AppLogger.shared.write(
            "ATVV STREAM summary trace=\(traceID) model=\(bluetoothVoiceTraceModel.rawValue) " +
                "duration_ms=\(durationMilliseconds) batches=\(bluetoothVoiceDecodedBatchCount) " +
                "samples=\(bluetoothVoiceDecodedSampleCount) " +
                "enqueue_failures=\(bluetoothVoiceEnqueueFailureCount) " +
                "route=\(bluetoothVoiceTraceRoute) pending_buffers=\(pendingBuffers) " +
                "flush=\(shouldFlushAudio)"
        )
        audioOutput.logWhenPendingVoiceAudioDrains(
            context: "trace=\(traceID) model=\(bluetoothVoiceTraceModel.rawValue)"
        )
        activeBluetoothVoiceTraceID = nil
        bluetoothVoiceTraceStartedAt = nil
        endVoiceSessionIfNeeded(flushAudio: shouldFlushAudio)
        if systemAudioSuspensionState.isSuspended {
            releaseVirtualAudioOutputIfUnused(reason: "system_suspended_after_bluetooth_voice")
        } else if !shouldKeepVirtualAudioActive {
            scheduleOnDemandVirtualAudioRelease(reason: "bluetooth_voice_stopped")
        }
    }

    func bluetoothBridge(_ bridge: XiaomiBluetoothBridge, didDecode samples: [Int16]) {
        guard systemRemoteRuntimeState.isActive,
              activeBackendKind == .xiaomi,
              let identifier = bridge.deviceIdentifier,
              identifier == activeBluetoothVoiceDeviceIdentifier
        else { return }
        let handledByFnTapMode = voiceFnTapSession.receive(samples)
        let enqueued = handledByFnTapMode || enqueueVoiceAudio(
            samples: samples,
            sampleRate: RemoteAudioFormat.xiaomiSampleRate
        )
        xiaomiRemoteBackend.forwardAudio(samples: samples)
        bluetoothVoiceDecodedBatchCount += 1
        bluetoothVoiceDecodedSampleCount += samples.count
        currentVoiceSampleCount &+= UInt64(samples.count)
        publishCurrentVoiceSampleReceiptIfNeeded(sampleCount: samples.count)
        if !enqueued {
            bluetoothVoiceEnqueueFailureCount += 1
        }
        bluetoothVoiceTraceRoute = handledByFnTapMode ? "fn_tap" : "virtual_audio"
        if loggedBluetoothVoiceAudioDeviceIdentifier != identifier {
            loggedBluetoothVoiceAudioDeviceIdentifier = identifier
            let model = settings.profileID(forBluetoothIdentifier: identifier)
                .flatMap { id in settings.remoteDeviceProfiles.first(where: { $0.id == id })?.model }
                ?? .unknown
            AppLogger.shared.write(
                "ATVV AUDIO routed trace=\(activeBluetoothVoiceTraceID ?? 0) " +
                    "model=\(model.rawValue) route=\(bluetoothVoiceTraceRoute) " +
                    "accepted=\(enqueued) first_batch_samples=\(samples.count) " +
                    "pending_buffers=\(audioOutput.pendingVoiceBufferCountForDiagnostics)"
            )
        }
    }

    private func publishCurrentVoiceSampleReceiptIfNeeded(sampleCount: Int) {
        guard VoiceSamplePresentationPolicy.shouldPublishReceipt(
            hasReceivedSamples: hasReceivedCurrentVoiceSamples,
            sampleCount: sampleCount
        ) else { return }
        hasReceivedCurrentVoiceSamples = true
    }

    func bluetoothBridge(_ bridge: XiaomiBluetoothBridge, didUpdateBatteryLevel level: Int?) {
        xiaomiRemoteBackend.updateBatteryLevel(level)
        guard let profileID = remoteProfileID(for: bridge) else { return }
        if let level {
            remoteBatteryLevels[profileID] = min(100, max(0, level))
        } else {
            remoteBatteryLevels.removeValue(forKey: profileID)
        }
    }

    func bluetoothBridge(
        _ bridge: XiaomiBluetoothBridge,
        didIdentifyRemoteModel model: XiaomiRemoteModel
    ) {
        guard let profileID = remoteProfileID(for: bridge) else { return }
        settings.updateRemoteProfileModel(profileID, model: model)
    }

    func bluetoothBridge(
        _ bridge: XiaomiBluetoothBridge,
        didUpdatePowerState state: RemotePowerState?
    ) {
        guard let profileID = remoteProfileID(for: bridge) else { return }
        if let state {
            remotePowerStates[profileID] = state
        } else {
            remotePowerStates.removeValue(forKey: profileID)
        }
    }

    func batteryLevel(for profileID: UUID) -> Int? {
        remoteBatteryLevels[profileID]
    }

    func powerState(for profileID: UUID) -> RemotePowerState? {
        remotePowerStates[profileID]
    }

    func isRemoteConnected(_ profileID: UUID) -> Bool {
        connectedRemoteProfileIDs.contains(profileID)
    }

    private func handleRemoteButtonEvent(
        _ button: RemoteButton,
        phase: RemoteButtonPhase,
        source: UsageEventSource
    ) -> Bool {
        let recognizesDoubleClick = settings.configuredAction(
            for: button,
            trigger: .doubleClick
        ).action != .disabled
        let recognizesLongPress = settings.configuredAction(
            for: button,
            trigger: .longPress
        ).action != .disabled

        var recognizer = remoteButtonGestureRecognizers[source] ?? RemoteButtonGestureRecognizer()
        if phase == .press,
           !recognizesDoubleClick,
           !recognizesLongPress,
           !recognizer.isTracking(button) {
            return performConfiguredAction(
                for: button,
                trigger: .singleClick,
                source: source
            )
        }

        let commands = recognizer.handle(
            phase,
            button: button,
            recognizesDoubleClick: recognizesDoubleClick,
            recognizesLongPress: recognizesLongPress
        )
        remoteButtonGestureRecognizers[source] = recognizer
        return processRemoteGestureCommands(commands, source: source)
    }

    private func processRemoteGestureCommands(
        _ commands: [RemoteButtonGestureRecognizer.Command],
        source: UsageEventSource
    ) -> Bool {
        for command in commands {
            switch command {
            case let .scheduleDoubleClickTimeout(button):
                scheduleRemoteDoubleClickTimeout(for: button, source: source)
            case let .cancelDoubleClickTimeout(button):
                remoteButtonDoubleClickTimers.removeValue(forKey: .init(
                    source: source,
                    button: button
                ))?.cancel()
            case let .scheduleLongPressTimeout(button):
                scheduleRemoteLongPressTimeout(for: button, source: source)
            case let .cancelLongPressTimeout(button):
                remoteButtonLongPressTimers.removeValue(forKey: .init(
                    source: source,
                    button: button
                ))?.cancel()
            case let .trigger(button, trigger):
                guard performConfiguredAction(
                    for: button,
                    trigger: trigger,
                    source: source
                ) else { return false }
            }
        }
        return true
    }

    private func scheduleRemoteDoubleClickTimeout(
        for button: RemoteButton,
        source: UsageEventSource
    ) {
        let key = RemoteButtonGestureKey(source: source, button: button)
        remoteButtonDoubleClickTimers.removeValue(forKey: key)?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(300))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.remoteButtonDoubleClickTimers.removeValue(forKey: key)
            guard var recognizer = self.remoteButtonGestureRecognizers[source] else { return }
            let commands = recognizer.doubleClickTimedOut(button)
            self.remoteButtonGestureRecognizers[source] = recognizer
            _ = self.processRemoteGestureCommands(commands, source: source)
        }
        remoteButtonDoubleClickTimers[key] = timer
        timer.resume()
    }

    private func scheduleRemoteLongPressTimeout(
        for button: RemoteButton,
        source: UsageEventSource
    ) {
        let key = RemoteButtonGestureKey(source: source, button: button)
        remoteButtonLongPressTimers.removeValue(forKey: key)?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(550))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.remoteButtonLongPressTimers.removeValue(forKey: key)
            guard var recognizer = self.remoteButtonGestureRecognizers[source] else { return }
            let commands = recognizer.longPressTimedOut(button)
            self.remoteButtonGestureRecognizers[source] = recognizer
            _ = self.processRemoteGestureCommands(commands, source: source)
        }
        remoteButtonLongPressTimers[key] = timer
        timer.resume()
    }

    private func resetRemoteButtonGestures(source: UsageEventSource) {
        remoteButtonDoubleClickTimers.keys
            .filter { $0.source == source }
            .forEach { remoteButtonDoubleClickTimers.removeValue(forKey: $0)?.cancel() }
        remoteButtonLongPressTimers.keys
            .filter { $0.source == source }
            .forEach { remoteButtonLongPressTimers.removeValue(forKey: $0)?.cancel() }
        remoteButtonGestureRecognizers.removeValue(forKey: source)
    }

    private func performConfiguredAction(
        for button: RemoteButton,
        trigger: ButtonTrigger,
        source: UsageEventSource
    ) -> Bool {
        let configured = settings.configuredAction(for: button, trigger: trigger)
        if configured.action.isAppInternal {
            let handled = performInternalAction(configured.action)
            if handled {
                settings.recordButtonPress(control: .remoteButton(button), source: source)
            }
            AppLogger.shared.write(
                "REMOTE BUTTON button=\(button.rawValue) trigger=\(trigger.rawValue) " +
                    "action=\(configured.action.rawValue) handled=\(handled)"
            )
            return handled
        }
        guard KeyboardInjector.isAccessibilityTrusted else {
            _ = KeyboardInjector.requestAccessibilityAccess()
            return false
        }
        guard performExternalConfiguredAction(configured) else { return false }
        settings.recordButtonPress(control: .remoteButton(button), source: source)
        AppLogger.shared.write(
            "REMOTE BUTTON button=\(button.rawValue) trigger=\(trigger.rawValue) " +
                "action=\(configured.action.rawValue)"
        )
        return true
    }

    private func performExternalConfiguredAction(_ configured: ConfiguredButtonAction) -> Bool {
        let applicationProfile = settings.customApplicationProfile(
            id: configured.applicationProfileID
        )
        let requestID = settings.voiceFnTapModeEnabled
            ? VoiceInputDestinationIntent.resolve(
                configured: configured,
                applicationProfile: applicationProfile
            ).map { voiceInputDestinationCoordinator.beginTargetSwitch(intent: $0) }
            : nil
        let handled = KeyboardInjector.send(
            configured.action,
            shortcut: configured.shortcut,
            applicationProfile: applicationProfile
        )
        if !handled, let requestID {
            voiceInputDestinationCoordinator.cancel(requestID: requestID, reason: .actionFailed)
        }
        return handled
    }

    private func handleVoiceInputDestinationState(_ state: VoiceInputDestinationState) {
        guard settings.voiceFnTapModeEnabled else { return }
        switch state {
        case .waiting:
            voiceShortcutStatus = LocalizedMessage("voice_button.status.waiting_for_input")
        case .ready:
            voiceShortcutStatus = LocalizedMessage("voice_button.status.input_ready")
        case .cancelled:
            voiceShortcutStatus = LocalizedMessage("voice_button.status.input_unavailable")
        }
    }

    @discardableResult
    private func performInternalAction(_ action: ButtonAction) -> Bool {
        if action == .toggleMouseMode {
            return mouseModeController.toggle()
        }
        guard action == .toggleLongRecording else { return false }
        guard action.isEnabled(
            experimentalContinuousRecordingEnabled: settings.experimentalContinuousRecordingEnabled
        ) else {
            AppLogger.shared.write("LONG RECORDING ignored feature_enabled=false")
            return false
        }
        return toggleLongRecording()
    }

    private func toggleLongRecording() -> Bool {
        if longRecordingRequested {
            stopLongRecording(reason: "button_toggle")
            return true
        }
        guard isConnected,
              isAudioOutputReady,
              !bluetoothVoiceActive
        else {
            AppLogger.shared.write(
                "LONG RECORDING rejected connected=\(isConnected) audio_ready=\(isAudioOutputReady) " +
                    "bluetooth_voice=\(bluetoothVoiceActive)"
            )
            return false
        }

        longRecordingGeneration &+= 1
        let generation = longRecordingGeneration
        longRecordingRequested = true
        guard let selectedBluetoothBridge,
              selectedBluetoothBridge.requestMicrophoneOpen()
        else {
            finishLongRecording(reason: "open_rejected")
            return false
        }
        scheduleLongRecordingOpenTimeout(generation: generation)
        AppLogger.shared.write("LONG RECORDING opening generation=\(generation)")
        return true
    }

    private func scheduleLongRecordingOpenTimeout(generation: UInt64) {
        longRecordingOpenTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.longRecordingOpenTimeout)
        timer.setEventHandler { [weak self] in
            guard let self,
                  self.longRecordingRequested,
                  self.longRecordingGeneration == generation,
                  !self.bluetoothVoiceActive
            else { return }
            self.stopLongRecording(reason: "open_timeout")
        }
        longRecordingOpenTimer = timer
        timer.resume()
    }

    private func stopLongRecording(reason: String) {
        guard longRecordingRequested else { return }
        longRecordingRequested = false
        longRecordingGeneration &+= 1
        cancelLongRecordingTimers()
        let closeWritten = selectedBluetoothBridge?.requestMicrophoneClose() ?? false
        if bluetoothVoiceActive {
            scheduleLongRecordingCloseTimeout(generation: longRecordingGeneration)
        }
        AppLogger.shared.write(
            "LONG RECORDING stopping reason=\(reason) close_written=\(closeWritten)"
        )
    }

    private func scheduleLongRecordingCloseTimeout(generation: UInt64) {
        longRecordingCloseTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.longRecordingCloseTimeout)
        timer.setEventHandler { [weak self] in
            guard let self,
                  self.longRecordingGeneration == generation,
                  !self.longRecordingRequested,
                  self.bluetoothVoiceActive
            else { return }
            self.longRecordingCloseTimer = nil
            AppLogger.shared.write("LONG RECORDING close_timeout reconnecting=true")
            self.selectedBluetoothBridge?.reconnectNow()
        }
        longRecordingCloseTimer = timer
        timer.resume()
    }

    private func finishLongRecording(reason: String) {
        longRecordingRequested = false
        longRecordingGeneration &+= 1
        cancelLongRecordingTimers()
        AppLogger.shared.write("LONG RECORDING finished reason=\(reason)")
    }

    private func cancelLongRecordingTimers() {
        longRecordingOpenTimer?.cancel()
        longRecordingOpenTimer = nil
        longRecordingCloseTimer?.cancel()
        longRecordingCloseTimer = nil
    }

    private var readyBluetoothBridgeCount: Int {
        bluetoothBridgeStates.values.reduce(into: 0) { count, state in
            if case .ready = state {
                count += 1
            }
        }
    }

    private var shouldKeepVirtualAudioActive: Bool {
        VirtualAudioConnectionLifecyclePolicy.shouldBeActive(
            readyBluetoothBridgeCount: readyBluetoothBridgeCount,
            siriRemoteReady: activeBackendKind == .siriRemote && isSiriRemoteConnected,
            siriRemoteVoiceActive: siriRemoteVoiceActive,
            bluetoothVoiceActive: bluetoothVoiceActive,
            testToneActive: isPlayingTestTone,
            systemSuspended: systemAudioSuspensionState.isSuspended,
            keepAliveWhileConnected: virtualAudioKeepAliveEnabled
        )
    }

    private var hasActiveVirtualAudioSource: Bool {
        bluetoothVoiceActive || isPlayingTestTone || siriRemoteVoiceActive
    }

    private func scheduleOnDemandVirtualAudioRelease(reason: String) {
        guard !virtualAudioKeepAliveEnabled else { return }
        cancelScheduledOnDemandVirtualAudioRelease(trigger: "reschedule_\(reason)")
        onDemandVirtualAudioReleaseGeneration &+= 1
        let generation = onDemandVirtualAudioReleaseGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.started,
                  self.onDemandVirtualAudioReleaseGeneration == generation
            else { return }
            self.onDemandVirtualAudioReleaseWorkItem = nil
            AppLogger.shared.write(
                "AUDIO ON_DEMAND release_due reason=\(reason) generation=\(generation) " +
                    "state={\(self.audioOutput.diagnosticState())}"
            )
            self.releaseVirtualAudioOutputIfUnused(reason: reason)
        }
        onDemandVirtualAudioReleaseWorkItem = work
        AppLogger.shared.write(
            "AUDIO ON_DEMAND release_scheduled reason=\(reason) generation=\(generation) " +
                "delay_s=\(Self.onDemandVirtualAudioReleaseDelay)"
        )
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.onDemandVirtualAudioReleaseDelay,
            execute: work
        )
    }

    private func cancelScheduledOnDemandVirtualAudioRelease(trigger: String) {
        guard onDemandVirtualAudioReleaseWorkItem != nil else { return }
        onDemandVirtualAudioReleaseGeneration &+= 1
        onDemandVirtualAudioReleaseWorkItem?.cancel()
        onDemandVirtualAudioReleaseWorkItem = nil
        AppLogger.shared.write(
            "AUDIO ON_DEMAND release_cancelled trigger=\(trigger) " +
                "generation=\(onDemandVirtualAudioReleaseGeneration)"
        )
    }

    private func resumeVirtualAudioOutputIfNeeded(reason: String) {
        guard shouldKeepVirtualAudioActive else {
            AppLogger.shared.write(
                "SYSTEM AUDIO resume_skipped reason=\(reason) required=false " +
                    "ready_bridges=\(readyBluetoothBridgeCount) selected=\(!settings.selectedAudioDeviceUID.isEmpty)"
            )
            return
        }
        cancelVirtualAudioReleaseIfPending(trigger: "resume_\(reason)")
        guard !settings.selectedAudioDeviceUID.isEmpty else {
            AppLogger.shared.write("SYSTEM AUDIO resume_skipped reason=\(reason) selected=false")
            return
        }
        isAudioOutputReady = audioOutput.isReadyForTestTone
        guard !isAudioOutputReady else {
            AppLogger.shared.write(
                "SYSTEM AUDIO resume_skipped reason=\(reason) already_ready=true " +
                    "state={\(audioOutput.diagnosticState())}"
            )
            return
        }
        let configured = configureVirtualAudioOutput(reason: reason)
        AppLogger.shared.write(
            "SYSTEM AUDIO resume_completed reason=\(reason) configured=\(configured) " +
                "selected_available=\(selectedAudioDeviceIsAvailable) " +
                "state={\(audioOutput.diagnosticState())}"
        )
    }

    func handleSystemAudioLifecycle(_ event: SystemAudioLifecycleEvent) {
        let remoteWakeManaged = handleSystemRemoteRuntimeLifecycle(event)
        let changed = systemAudioSuspensionState.apply(event)
        AppLogger.shared.write(
            "SYSTEM AUDIO event=\(event.rawValue) changed=\(changed) " +
                "suspended=\(systemAudioSuspensionState.isSuspended) " +
                "reasons=\(systemAudioSuspensionState.diagnostic) started=\(started) " +
                "ready_bridges=\(readyBluetoothBridgeCount) " +
                "bluetooth_voice=\(bluetoothVoiceActive) " +
                "test_tone=\(isPlayingTestTone) audio_ready=\(isAudioOutputReady)"
        )
        guard started, changed else { return }
        guard !audioStartupPending else {
            AppLogger.shared.write(
                "SYSTEM AUDIO lifecycle_deferred event=\(event.rawValue) cause=audio_startup_pending " +
                    "suspended=\(systemAudioSuspensionState.isSuspended)"
            )
            return
        }

        if event.isSuspending {
            if hasActiveVirtualAudioSource {
                AppLogger.shared.write(
                    "SYSTEM AUDIO suspend_deferred event=\(event.rawValue) " +
                        "bluetooth_voice=\(bluetoothVoiceActive) " +
                        "test_tone=\(isPlayingTestTone)"
                )
                return
            }
            releaseVirtualAudioOutputIfUnused(reason: "system_\(event.rawValue)")
            return
        }

        guard !systemAudioSuspensionState.isSuspended else {
            AppLogger.shared.write(
                "SYSTEM AUDIO resume_deferred event=\(event.rawValue) " +
                    "remaining_reasons=\(systemAudioSuspensionState.diagnostic)"
            )
            return
        }
        resumeVirtualAudioOutputIfNeeded(reason: "system_\(event.rawValue)")
        if !remoteWakeManaged,
           BluetoothWakeRecoveryPolicy.shouldForceReconnect(event: event, started: started) {
            recoverBluetoothAfterSystemWake()
        }
    }

    @discardableResult
    private func handleSystemRemoteRuntimeLifecycle(_ event: SystemAudioLifecycleEvent) -> Bool {
        let wasManagedSystemWake = event == .systemDidWake &&
            systemRemoteRuntimeState.phase == .sleeping
        let remoteEvent: SystemRemoteRuntimeEvent
        switch event {
        case .systemWillSleep:
            remoteEvent = .systemWillSleep
        case .systemDidWake:
            remoteEvent = .systemDidWake
        case .sessionDidBecomeActive:
            remoteEvent = .sessionDidBecomeActive
        case .screenDidSleep, .screenDidWake, .sessionDidResignActive:
            remoteEvent = .unrelated
        }
        let action = systemRemoteRuntimeState.handle(remoteEvent)
        AppLogger.shared.write(
            "SYSTEM REMOTE event=\(event.rawValue) action=\(String(describing: action)) " +
                "phase=\(systemRemoteRuntimeState.phase.rawValue) " +
                "generation=\(systemRemoteRuntimeState.generation)"
        )
        switch action {
        case .none:
            break
        case .suspend:
            suspendRemoteRuntime(reason: event.rawValue)
        case .scheduleResume(let generation):
            scheduleRemoteRuntimeResume(generation: generation)
        case .cancelPendingResume:
            remoteWakeResumeWorkItem?.cancel()
            remoteWakeResumeWorkItem = nil
        case .resume:
            remoteWakeResumeWorkItem?.cancel()
            remoteWakeResumeWorkItem = nil
            resumeRemoteRuntime(reason: event.rawValue)
        }

        if systemRemoteRuntimeState.phase == .wakePending,
           (event == .systemDidWake || event == .screenDidWake),
           isUserVisibleWake(),
           systemRemoteRuntimeState.confirmUserVisibleWake() == .resume {
            remoteWakeResumeWorkItem?.cancel()
            remoteWakeResumeWorkItem = nil
            resumeRemoteRuntime(reason: "user_visible_\(event.rawValue)")
        }
        return wasManagedSystemWake
    }

    private func suspendRemoteRuntime(reason: String) {
        remoteWakeResumeWorkItem?.cancel()
        remoteWakeResumeWorkItem = nil
        cancelHIDMappingRecovery(reason: "system_sleep")
        completedUpdateHIDRecoveryWorkItem?.cancel()
        completedUpdateHIDRecoveryWorkItem = nil
        stopLongRecording(reason: "system_sleep")
        preferredInputSourceMonitor.stop()
        if siriRemoteVoiceActive {
            finishSiriRemoteVoice(reason: "system_sleep")
        }
        let bluetoothVoiceWasActive = bluetoothVoiceActive
        releaseVoiceKeyIfNeeded()
        bluetoothVoiceActive = false
        activeBluetoothVoiceDeviceIdentifier = nil
        loggedBluetoothVoiceAudioDeviceIdentifier = nil
        voiceFnTapSession.shutdown()
        if bluetoothVoiceWasActive {
            endVoiceSessionIfNeeded(flushAudio: false)
            AppLogger.shared.write("ATVV STREAM interrupted reason=system_sleep")
        }
        stopHIDMonitors()
        bluetoothBridges.values.forEach { $0.suspendForSystemSleep() }
        discoveryBluetoothBridge?.suspendForSystemSleep()
        AppLogger.shared.write("SYSTEM REMOTE suspended reason=\(reason)")
    }

    private func scheduleRemoteRuntimeResume(generation: UInt64) {
        remoteWakeResumeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.started else { return }
            self.remoteWakeResumeWorkItem = nil
            guard self.systemRemoteRuntimeState.wakeGraceElapsed(generation: generation) == .resume else {
                AppLogger.shared.write("SYSTEM REMOTE resume_skipped reason=stale_wake_generation")
                return
            }
            self.resumeRemoteRuntime(reason: "wake_grace_elapsed")
        }
        remoteWakeResumeWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.remoteWakeResumeGrace,
            execute: workItem
        )
        AppLogger.shared.write("SYSTEM REMOTE resume_scheduled delay_s=\(Self.remoteWakeResumeGrace)")
    }

    private func resumeRemoteRuntime(reason: String) {
        guard started, systemRemoteRuntimeState.isActive else { return }
        applyHIDSettings()
        bluetoothBridges.values.forEach { $0.start() }
        discoveryBluetoothBridge?.start()
        startBluetoothConnections()
        voiceFnTapSession.resume()
        AppLogger.shared.write("SYSTEM REMOTE resumed reason=\(reason)")
    }

    private var selectedAudioDeviceIsAvailable: Bool {
        let selectedUID = settings.selectedAudioDeviceUID
        return !selectedUID.isEmpty && audioDevices.contains { $0.uid == selectedUID }
    }

    private func releaseVirtualAudioOutputIfUnused(reason: String) {
        cancelScheduledOnDemandVirtualAudioRelease(trigger: "release_\(reason)")
        guard !shouldKeepVirtualAudioActive else {
            AppLogger.shared.write(
                "AUDIO RELEASE skipped reason=\(reason) still_required=true " +
                    "system_suspended=\(systemAudioSuspensionState.isSuspended) " +
                    "bluetooth_voice=\(bluetoothVoiceActive) " +
                    "test_tone=\(isPlayingTestTone)"
            )
            return
        }
        cancelVirtualAudioReleaseIfPending(trigger: "superseded_\(reason)", cause: "superseded")
        virtualAudioReleaseGeneration &+= 1
        let generation = virtualAudioReleaseGeneration
        pendingVirtualAudioRelease = (generation, reason)
        AppLogger.shared.write(
            "AUDIO RELEASE requested reason=\(reason) generation=\(generation) " +
                "system_suspended=\(systemAudioSuspensionState.isSuspended) " +
                "pending_buffers=\(audioOutput.pendingVoiceBufferCountForDiagnostics) " +
                "state={\(audioOutput.diagnosticState())}"
        )
        switchDefaultInputToFallbackIfNeeded(reason: reason)
        audioOutput.endSessionAfterDraining { [weak self] in
            guard let self else { return }
            guard self.virtualAudioReleaseGeneration == generation else {
                return
            }
            self.pendingVirtualAudioRelease = nil
            guard !self.shouldKeepVirtualAudioActive else {
                AppLogger.shared.write(
                    "AUDIO RELEASE cancelled reason=\(reason) generation=\(generation) " +
                        "cause=required_again system_suspended=\(self.systemAudioSuspensionState.isSuspended) " +
                        "bluetooth_voice=\(self.bluetoothVoiceActive) " +
                        "test_tone=\(self.isPlayingTestTone)"
                )
                return
            }
            self.audioOutput.stop()
            self.karaokeAudioOutput.stop()
            self.isAudioOutputReady = false
            self.testToneStatus = LocalizedMessage("audio.output.none_or_unavailable")
            AppLogger.shared.write(
                "AUDIO RELEASE completed reason=\(reason) generation=\(generation) " +
                    "system_suspended=\(self.systemAudioSuspensionState.isSuspended) " +
                    "ready_bridges=\(self.readyBluetoothBridgeCount) " +
                    "state={\(self.audioOutput.diagnosticState())}"
            )
        }
    }

    private func cancelVirtualAudioReleaseIfPending(
        trigger: String,
        cause: String = "required_again"
    ) {
        guard let pendingVirtualAudioRelease else { return }
        virtualAudioReleaseGeneration &+= 1
        self.pendingVirtualAudioRelease = nil
        audioOutput.cancelPendingDrain()
        karaokeAudioOutput.cancelPendingDrain()
        AppLogger.shared.write(
            "AUDIO RELEASE cancelled reason=\(pendingVirtualAudioRelease.reason) " +
                "generation=\(pendingVirtualAudioRelease.generation) " +
                "current_generation=\(virtualAudioReleaseGeneration) cause=\(cause) " +
                "trigger=\(trigger) system_suspended=\(systemAudioSuspensionState.isSuspended) " +
                "ready_bridges=\(readyBluetoothBridgeCount) " +
                "bluetooth_voice=\(bluetoothVoiceActive) " +
                "test_tone=\(isPlayingTestTone)"
        )
    }

    private func switchDefaultInputToFallbackIfNeeded(reason: String) {
        guard managedDefaultInputTransition == nil else { return }
        let selectedUID = settings.selectedAudioDeviceUID
        guard !selectedUID.isEmpty,
              CoreAudioDeviceCatalog.defaultInputDevice()?.uid == selectedUID
        else { return }
        guard let fallback = preferredFallbackInput(excludingUID: selectedUID) else {
            AppLogger.shared.write("AUDIO DEFAULT_INPUT fallback_failed reason=\(reason) no_candidate")
            return
        }
        let result = CoreAudioDeviceCatalog.setDefaultInputDevice(fallback)
        guard result == noErr else {
            AppLogger.shared.write(
                "AUDIO DEFAULT_INPUT fallback_failed reason=\(reason) " +
                    "target={\(CoreAudioDeviceCatalog.deviceDiagnostic(fallback))} error=\(result)"
            )
            return
        }
        managedDefaultInputTransition = ManagedDefaultInputTransition(
            virtualUID: selectedUID,
            fallbackUID: fallback.uid
        )
        AppLogger.shared.write(
            "AUDIO DEFAULT_INPUT fallback_applied reason=\(reason) " +
                "target={\(CoreAudioDeviceCatalog.deviceDiagnostic(fallback))}"
        )
    }

    private func preferredFallbackInput(excludingUID: String) -> AudioDeviceInfo? {
        CoreAudioDeviceCatalog.preferredFallbackInput(
            excludingUID: excludingUID,
            preferredUID: settings.lastUserSelectedInputDeviceUID
        )
    }

    private func rememberCurrentUserInputDeviceIfNeeded(reason: String) {
        guard managedDefaultInputTransition == nil,
              let current = CoreAudioDeviceCatalog.defaultInputDevice(),
              current.uid != settings.selectedAudioDeviceUID,
              current.uid != settings.lastUserSelectedInputDeviceUID
        else { return }
        settings.lastUserSelectedInputDeviceUID = current.uid
        AppLogger.shared.write(
            "AUDIO DEFAULT_INPUT remembered reason=\(reason) target={\(CoreAudioDeviceCatalog.deviceDiagnostic(current))}"
        )
    }

    private func restoreManagedDefaultInputIfAppropriate(reason: String) {
        guard let transition = managedDefaultInputTransition else { return }
        let currentDefault = CoreAudioDeviceCatalog.defaultInputDevice()
        guard DefaultInputFallbackPolicy.shouldRestoreVirtualInput(
            managedVirtualUID: transition.virtualUID,
            selectedVirtualUID: settings.selectedAudioDeviceUID,
            managedFallbackUID: transition.fallbackUID,
            currentDefaultUID: currentDefault?.uid
        ) else {
            managedDefaultInputTransition = nil
            AppLogger.shared.write(
                "AUDIO DEFAULT_INPUT restore_skipped reason=\(reason) current={\(CoreAudioDeviceCatalog.deviceDiagnostic(currentDefault))}"
            )
            return
        }
        guard let virtualInput = CoreAudioDeviceCatalog.inputDevices().first(where: {
            $0.uid == transition.virtualUID
        }) else {
            AppLogger.shared.write("AUDIO DEFAULT_INPUT restore_failed reason=\(reason) virtual_unavailable")
            return
        }
        let result = CoreAudioDeviceCatalog.setDefaultInputDevice(virtualInput)
        if result == noErr {
            managedDefaultInputTransition = nil
            AppLogger.shared.write(
                "AUDIO DEFAULT_INPUT restore_applied reason=\(reason) " +
                    "target={\(CoreAudioDeviceCatalog.deviceDiagnostic(virtualInput))}"
            )
        } else {
            AppLogger.shared.write(
                "AUDIO DEFAULT_INPUT restore_failed reason=\(reason) " +
                    "target={\(CoreAudioDeviceCatalog.deviceDiagnostic(virtualInput))} error=\(result)"
            )
        }
    }

    private func beginVoiceSessionIfNeeded() {
        guard !isStreaming else { return }
        cancelTestToneIfNeeded(
            statusMessage: LocalizedMessage("audio.test_tone.blocked_voice_active"),
            logReason: "voice_start"
        )
        let startedAt = Date()
        let source = currentVoiceUsageSource
        settings.recordButtonPress(control: .voice, source: source, at: startedAt)
        voiceSessionStartedAt = startedAt
        voiceSessionUsageSource = source
        isStreaming = true
    }

    private func endVoiceSessionIfNeeded(flushAudio: Bool = true) {
        guard !bluetoothVoiceActive,
              !siriRemoteVoiceActive,
              isStreaming
        else { return }
        if let voiceSessionStartedAt {
            let endedAt = Date()
            settings.recordVoiceDuration(
                endedAt.timeIntervalSince(voiceSessionStartedAt),
                startedAt: voiceSessionStartedAt,
                source: voiceSessionUsageSource ?? .unknown,
                applicationName: NSWorkspace.shared.frontmostApplication?.localizedName,
                at: endedAt
            )
            self.voiceSessionStartedAt = nil
        }
        voiceSessionUsageSource = nil
        isStreaming = false
        if flushAudio {
            audioOutput.endSession()
            karaokeAudioOutput.endSession()
        }
    }

    private var currentVoiceUsageSource: UsageEventSource {
        if bluetoothVoiceActive { return .bluetoothRemote }
        if siriRemoteVoiceActive { return .siriRemote }
        return .unknown
    }

    @discardableResult
    private func applyVoiceFunctionMapping(neutralizeVoiceKey: Bool) -> Bool {
        let applied = voiceFunctionMapper.apply(
            suppressPowerKey: settings.customMappingEnabled,
            neutralizeVoiceKey: neutralizeVoiceKey
        )
        if !isStreaming {
            isVoiceTriggerEnabled = applied
            voiceShortcutStatus = LocalizedMessage(
                applied ? "voice_button.status.fn_enabled" : "voice_button.status.waiting"
            )
        }
        return !settings.customMappingEnabled || voiceFunctionMapper.isPowerKeySuppressed
    }

}
