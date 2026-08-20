//
//  SiriRemoteBackend.swift
//  RemoteMic
//
//  Apple TV Siri Remote（第三代 · USB-C）后端。
//
//  按键链路：IOHID 发现 Apple 遥控器（vendor 0x004C）→ 打开接口 → 写 0xAF input-enable
//  → 0xFB/usage 按键事件 → RemoteButton 统一事件。
//
//  音频链路（M3）：0xFA 99-byte Opus CELT 报告（48 kHz mono, 960 samples/frame）
//  → Opus 解码 → 48 kHz PCM → onAudioSamples。
//
//  协议参数来自 VibeRemote（已真机验证）与 siri-remote 项目交叉确认。
//  平台限制：macOS 对第三方 App 隐藏 GATT HID 服务（0x1812），Direct HID 音频路径的
//  可用性需真机验证（见需求文档风险声明）。
//

import AppKit
import Foundation
import IOKit
import IOKit.hid

/// Siri Remote 后端。
///
/// IOHID 回调在主 RunLoop 投递，因此本类标记 @MainActor，避免 teardown 与事件竞态
/// （与 VibeRemote RemoteInputHandler 相同模型）。
@MainActor
final class SiriRemoteBackend: RemoteBackend {
    /// nonisolated：HID 发现/回调均注册在主 RunLoop，对象创建可在任意执行器完成
    nonisolated init() {}

    let deviceName = "Apple Siri Remote"

    /// Siri Remote 支持的全部按键（含 Clickpad 点击 → .ok）
    let supportedButtons: [RemoteButton] = [
        .power, .up, .left, .ok, .right, .down, .back,
        .volumeUp, .volumeDown, .menu, .tv,
        .playPause, .mute, .voice,
    ]

    private(set) var batteryLevel: Int? {
        didSet {
            if oldValue != batteryLevel {
                onBatteryLevelChange?(batteryLevel)
            }
        }
    }

    var onAudioSamples: (([Float], Double) -> Void)?
    var onButton: ((RemoteButton, Bool) -> Void)?
    /// 电量变化回调（读取到电量或设备断开时触发）
    var onBatteryLevelChange: ((Int?) -> Void)?
    /// 连接状态变化回调（HID 设备匹配/移除时触发）
    var onConnectionStateChange: ((Bool) -> Void)?

    /// 是否已检测到并持有遥控器 HID 设备
    var isConnected: Bool { !devices.isEmpty }

    // MARK: - HID 状态

    private let appleVendorID = 0x004C

    /// 已知 Siri Remote / Apple TV Remote 产品 ID（VibeRemote 实测；产品名优先于 ID，
    /// 因为 Apple 在相近配件上复用 ID）
    private static let knownProductIDs: Set<Int> = [
        0x0221, 0x0255, 0x0266, 0x0267, 0x026D,
        0x0C4E, 0x0C4F, 0x030D, 0x030E, 0x0314, 0x0315,
    ]

    private var hidManager: IOHIDManager?
    private var devices: [ObjectIdentifier: IOHIDDevice] = [:]
    private var deviceNames: [ObjectIdentifier: String] = [:]
    private var started = false

    /// 音频报告回调注册（M3 使用；按键接口在 M2 可用）
    private var audioReportRegistrations: [ObjectIdentifier: (buffer: UnsafeMutablePointer<UInt8>, size: Int)] = [:]

    /// Opus CELT 解码器（系统 AudioToolbox；初始化失败则音频链路禁用）
    private var opusDecoder: OpusDecoder?
    /// 当前是否处于语音会话（0xFA 流活跃）
    private var voiceActive = false
    /// 按键状态去重：Siri Remote 会在多个镜像接口重复报告同一按键，只在状态翻转时发出
    private var buttonState: [RemoteButton: Bool] = [:]

    // MARK: - 生命周期

    func start() {
        guard !started else { return }
        started = true
        startDetection()
    }

    func stop() {
        guard started else { return }
        started = false
        disconnectAll()
    }

    // MARK: - 麦克风（M3 实现）

    func startMicrophone() {
        // 0xAF input-enable 已在接口打开时写入；首次使用时初始化解码器
        if opusDecoder == nil {
            opusDecoder = try? OpusDecoder()
        }
        voiceActive = true
    }

    func stopMicrophone() {
        voiceActive = false
    }

    // MARK: - 设备发现

    private func startDetection() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        hidManager = manager

        // 匹配 Apple 遥控器的各 HID 接口（Consumer / Telephony / Digitizer / Sensor / Vendor）
        let matchingDicts: [[String: Any]] = [
            [kIOHIDVendorIDKey: appleVendorID, kIOHIDPrimaryUsagePageKey: 0x0C],
            [kIOHIDVendorIDKey: appleVendorID, kIOHIDPrimaryUsagePageKey: 0x0B],
            [kIOHIDVendorIDKey: appleVendorID, kIOHIDPrimaryUsagePageKey: 0x0D],
            [kIOHIDVendorIDKey: appleVendorID, kIOHIDPrimaryUsagePageKey: 0x20],
            [kIOHIDVendorIDKey: appleVendorID, kIOHIDPrimaryUsagePageKey: 0xFF00],
            [kIOHIDVendorIDKey: appleVendorID, kIOHIDPrimaryUsagePageKey: 0xFF01],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matchingDicts as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, result, sender, device in
            guard let context else { return }
            let backend = Unmanaged<SiriRemoteBackend>.fromOpaque(context).takeUnretainedValue()
            backend.handleDeviceMatched(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, result, sender, device in
            guard let context else { return }
            let backend = Unmanaged<SiriRemoteBackend>.fromOpaque(context).takeUnretainedValue()
            backend.handleDeviceRemoved(device)
        }, context)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    private func disconnectAll() {
        // 卸载全部设备回调（含非音频接口的 input value 回调），防止悬挂回调访问已释放状态
        for (id, registration) in audioReportRegistrations {
            if let device = devices[id] {
                IOHIDDeviceRegisterInputReportCallback(
                    device,
                    registration.buffer,
                    registration.size,
                    nil,
                    nil
                )
            }
            registration.buffer.deallocate()
        }
        for device in devices.values {
            IOHIDDeviceRegisterInputValueCallback(device, nil, nil)
        }
        audioReportRegistrations.removeAll()
        devices.removeAll()
        deviceNames.removeAll()
        if let manager = hidManager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        hidManager = nil
        batteryLevel = nil
        onConnectionStateChange?(false)
    }

    // MARK: - 设备事件

    private func handleDeviceMatched(_ device: IOHIDDevice) {
        let id = ObjectIdentifier(device)
        guard devices[id] == nil else { return }

        let vendor = Self.property(kIOHIDVendorIDKey, of: device) ?? 0
        let product = Self.property(kIOHIDProductIDKey, of: device) ?? 0
        let productName = Self.stringProperty(kIOHIDProductKey, of: device)
        let usagePage = Self.property(kIOHIDPrimaryUsagePageKey, of: device) ?? 0
        let usage = Self.property(kIOHIDPrimaryUsageKey, of: device) ?? 0

        // 产品名优先：Apple 在相近配件上复用 product ID
        let isLikelyRemote: Bool
        if let productName, !productName.isEmpty {
            isLikelyRemote = Self.isLikelyRemoteName(productName)
        } else {
            isLikelyRemote = Self.knownProductIDs.contains(product)
        }
        guard vendor == appleVendorID, isLikelyRemote else { return }

        devices[id] = device
        deviceNames[id] = productName ?? String(format: "0x%04X", product)

        // 打开接口（优先 Seize 获取独占，失败则降级为监听）
        var openOptions: IOOptionBits = IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
        var openResult = IOHIDDeviceOpen(device, openOptions)
        if openResult != kIOReturnSuccess {
            openOptions = IOOptionBits(kIOHIDOptionsTypeNone)
            openResult = IOHIDDeviceOpen(device, openOptions)
        }
        guard openResult == kIOReturnSuccess else {
            devices.removeValue(forKey: id)
            return
        }

        // 注册输入值回调（按键 usage 事件）
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputValueCallback(device, { context, result, sender, value in
            guard let context else { return }
            let backend = Unmanaged<SiriRemoteBackend>.fromOpaque(context).takeUnretainedValue()
            backend.handleInputValue(value)
        }, context)

        // 音频接口（usage page 0x0C + 特定 usage / vendor 接口）：注册 input report 回调（M3 解码）
        if Self.isAudioInterface(usagePage: usagePage, usage: usage) {
            let maxReportSize = max(1, Self.property(kIOHIDMaxInputReportSizeKey, of: device) ?? 99)
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: maxReportSize)
            buffer.initialize(repeating: 0, count: maxReportSize)
            audioReportRegistrations[id] = (buffer, maxReportSize)
            IOHIDDeviceRegisterInputReportCallback(
                device,
                buffer,
                maxReportSize,
                { context, result, sender, type, reportID, report, reportLength in
                    guard type == kIOHIDReportTypeInput, let context else { return }
                    let backend = Unmanaged<SiriRemoteBackend>.fromOpaque(context).takeUnretainedValue()
                    backend.handleAudioReport(
                        reportID: reportID,
                        bytes: report,
                        length: reportLength
                    )
                },
                context
            )
        }

        // 0xAF input-enable：让 Gen-3 遥控器开始输出 HID 报告（含音频）
        enableRemoteInputStreaming(on: device)

        // 读取电量（系统可能稍后才同步属性，内部带延迟重试）
        readBatteryLevel(from: device)
        onConnectionStateChange?(true)
    }

    private func handleDeviceRemoved(_ device: IOHIDDevice) {
        let id = ObjectIdentifier(device)
        guard devices[id] != nil else { return }
        if let registration = audioReportRegistrations.removeValue(forKey: id) {
            registration.buffer.deallocate()
        }
        devices.removeValue(forKey: id)
        deviceNames.removeValue(forKey: id)
        if devices.isEmpty {
            onConnectionStateChange?(false)
        }
    }

    // MARK: - 按键事件

    private func handleInputValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let isPressed = IOHIDValueGetIntegerValue(value) != 0

        guard let button = Self.identifyButton(page: usagePage, usage: usage) else { return }
        // 折叠镜像接口的重复报告：仅在真实状态翻转时对外发出
        if buttonState[button] == isPressed {
            return
        }
        buttonState[button] = isPressed
        onButton?(button, isPressed)
    }

    /// usage → 统一按键映射（移植自 VibeRemote 真机验证表，映射到 SayAll 按键集）。
    /// Siri Remote 的 nextTrack/prevTrack 在 SayAll 无对应键，忽略。
    nonisolated static func identifyButton(page: UInt32, usage: UInt32) -> RemoteButton? {
        switch (page, usage) {
        // Generic Desktop
        case (0x01, 0x86), (0x01, 0x40): return .menu
        // Consumer
        case (0x0C, 0x04): return .voice          // Siri（实际）
        case (0x0C, 0x60), (0x0C, 0x223): return .tv
        case (0x0C, 0x80), (0x0C, 0x41): return .ok          // Clickpad 中心
        case (0x0C, 0x42): return .up
        case (0x0C, 0x43): return .down
        case (0x0C, 0x44): return .left
        case (0x0C, 0x45): return .right
        case (0x0C, 0xCD): return .playPause
        case (0x0C, 0xE9): return .volumeUp
        case (0x0C, 0xEA): return .volumeDown
        case (0x0C, 0xE2), (0x0C, 0x20): return .mute
        case (0x0C, 0x30): return .power
        case (0x0C, 0x40): return .menu
        case (0x0C, 0x224): return .back
        // Button Page
        case (0x09, 0x01): return .ok
        // Apple Vendor（仅 Siri 相关 usage，避免误映射无关传感器）
        case (0xFF00, 0x01), (0xFF00, 0x02), (0xFF00, 0x03): return .voice
        // Telephony
        case (0x0B, 0x21), (0x0B, 0x2F): return .voice
        default: return nil
        }
    }

    // MARK: - 音频报告（M3）

    private func handleAudioReport(reportID: UInt32, bytes: UnsafePointer<UInt8>, length: Int) {
        // 本回调仅注册在 0x0C:0x04 音频接口；报告布局由 parser 校验（99-byte / 100-byte / 1B35）
        guard length > 0 else { return }
        let raw = Array(UnsafeBufferPointer(start: bytes, count: length))
        for event in SiriRemoteAudioReportParser.events(from: raw) {
            switch event {
            case .packet(let packet):
                guard let decoder = opusDecoder, voiceActive,
                      let samples = try? decoder.decode(packet)
                else { continue }
                onAudioSamples?(samples, 48_000)
            case .ended:
                voiceActive = false
            }
        }
    }

    // MARK: - 0xAF input-enable

    /// Gen-3 Siri Remote 在所有 HID 报告（含麦克风音频）静默前，需要主机写入 0xAF
    /// 到可写的 HID Feature report（siri-remote 逆向确认；Gen-1/2 用 Output report，
    /// macOS 不暴露）。macOS 把每个 HID-over-GATT Report characteristic 呈现为独立
    /// IOHIDDevice 并把 report ID 重映射为 0xFF，因此对每个接口都尝试写入，
    /// 遥控器会忽略非 input-enable 的接口。
    private func enableRemoteInputStreaming(on device: IOHIDDevice) {
        guard Self.property(kIOHIDVendorIDKey, of: device) == appleVendorID,
              (Self.property(kIOHIDMaxFeatureReportSizeKey, of: device) ?? 0) >= 1 else {
            return
        }
        // 两种 framing 都试（IOHID 是否剥离 report-ID 字节依传输而异；错误的会被忽略）
        for payload in [[0xFF, 0xAF], [0xAF]] {
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: payload.count)
            for (index, byte) in payload.enumerated() {
                buffer[index] = UInt8(byte)
            }
            let result = IOHIDDeviceSetReport(
                device,
                kIOHIDReportTypeFeature,
                0xFF,
                buffer,
                payload.count
            )
            buffer.deallocate()
            if result != kIOReturnSuccess {
                AppLogger.shared.write(
                    "SIRI REMOTE 0xAF write failed result=0x\(String(result, radix: 16))"
                )
            }
        }
    }

    // MARK: - 电量

    /// 读取设备电量：立即尝试，若系统尚未同步 HID 属性则 2 秒后重试一次。
    private func readBatteryLevel(from device: IOHIDDevice) {
        let attempt: () -> Void = { [weak self] in
            guard let self,
                  let level = Self.resolveBatteryLevel(from: { key in
                      Self.property(key, of: device)
                  })
            else { return }
            self.batteryLevel = level
        }
        attempt()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self,
                  self.devices.keys.contains(ObjectIdentifier(device)),
                  self.batteryLevel == nil
            else { return }
            attempt()
        }
    }

    /// 从 HID 设备属性解析电量百分比。macOS 对 HID-over-BLE 遥控器暴露
    /// `BatteryLevel`；部分设备/驱动使用 `BatteryPercent`。
    /// 只接受 0-100 范围内的整数值，其余视为不可读（返回 nil）。
    nonisolated static func resolveBatteryLevel(
        from provider: (String) -> Any?
    ) -> Int? {
        for key in ["BatteryLevel", "BatteryPercent"] {
            guard let raw = provider(key) else { continue }
            let value: Int
            if let number = raw as? NSNumber {
                value = number.intValue
            } else if let int = raw as? Int {
                value = int
            } else {
                continue
            }
            if (0...100).contains(value) {
                return value
            }
        }
        return nil
    }

    // MARK: - 工具

    nonisolated static func isAudioInterface(usagePage: Int, usage: Int) -> Bool {
        // Consumer Page 0x0C:0x04 = Siri 键所在音频集合（VibeRemote 真机验证）。
        // 该接口同时承载 0xFA 音频 input report 与 Siri 键 input value 事件。
        usagePage == 0x0C && usage == 0x04
    }

    nonisolated static func isLikelyRemoteName(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered.contains("remote") || lowered.contains("siri")
    }

    nonisolated static func property(_ key: String, of device: IOHIDDevice) -> Int? {
        let value = IOHIDDeviceGetProperty(device, key as CFString)
        return value as? Int
    }

    nonisolated static func stringProperty(_ key: String, of device: IOHIDDevice) -> String? {
        let value = IOHIDDeviceGetProperty(device, key as CFString)
        return value as? String
    }
}
