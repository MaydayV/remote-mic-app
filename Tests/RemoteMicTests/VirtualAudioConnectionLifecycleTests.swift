import CoreAudio
import Testing
@testable import RemoteMic

@Suite("Virtual audio connection lifecycle")
struct VirtualAudioConnectionLifecycleTests {
    @Test func lastReadyBluetoothBridgeDisconnectsAndReleasesAudio() {
        #expect(!VirtualAudioConnectionLifecyclePolicy.shouldBeActive(
            readyBluetoothBridgeCount: 0,
            testToneActive: false
        ))
    }

    @Test func anotherReadyBluetoothBridgeKeepsAudioActive() {
        #expect(VirtualAudioConnectionLifecyclePolicy.shouldBeActive(
            readyBluetoothBridgeCount: 1,
            testToneActive: false
        ))
        #expect(VirtualAudioConnectionLifecyclePolicy.shouldBeActive(
            readyBluetoothBridgeCount: 2,
            testToneActive: false
        ))
    }

    @Test func testToneKeepsAudioActiveWithoutBluetooth() {
        #expect(VirtualAudioConnectionLifecyclePolicy.shouldBeActive(
            readyBluetoothBridgeCount: 0,
            testToneActive: true
        ))
    }

    @Test func siriRemoteConnectionOrActiveVoiceKeepsAudioReadyWithoutXiaomi() {
        #expect(VirtualAudioConnectionLifecyclePolicy.shouldBeActive(
            readyBluetoothBridgeCount: 0,
            siriRemoteReady: true,
            siriRemoteVoiceActive: false,
            testToneActive: false
        ))
        #expect(VirtualAudioConnectionLifecyclePolicy.shouldBeActive(
            readyBluetoothBridgeCount: 0,
            siriRemoteReady: false,
            siriRemoteVoiceActive: true,
            testToneActive: false
        ))
    }

    @Test func onDemandModeReleasesIdleConnectedAudioButKeepsActiveVoiceReady() {
        #expect(!VirtualAudioConnectionLifecyclePolicy.shouldBeActive(
            readyBluetoothBridgeCount: 1,
            testToneActive: false,
            keepAliveWhileConnected: false
        ))
        #expect(!VirtualAudioConnectionLifecyclePolicy.shouldBeActive(
            readyBluetoothBridgeCount: 0,
            siriRemoteReady: true,
            testToneActive: false,
            keepAliveWhileConnected: false
        ))
        #expect(VirtualAudioConnectionLifecyclePolicy.shouldBeActive(
            readyBluetoothBridgeCount: 1,
            bluetoothVoiceActive: true,
            testToneActive: false,
            keepAliveWhileConnected: false
        ))
        #expect(VirtualAudioConnectionLifecyclePolicy.shouldBeActive(
            readyBluetoothBridgeCount: 0,
            siriRemoteVoiceActive: true,
            testToneActive: false,
            keepAliveWhileConnected: false
        ))
    }

    @Test func bridgeDefaultsToOnDemandVirtualAudioAndAllowsExplicitKeepAlive() {
        #expect(!BridgeAppModel(virtualAudioKeepAliveEnabled: false).isVirtualAudioKeepAliveEnabled)
        #expect(BridgeAppModel(virtualAudioKeepAliveEnabled: true).isVirtualAudioKeepAliveEnabled)
        #expect(BridgeAppModel.onDemandVirtualAudioReleaseDelay >= 1)
        #expect(BridgeAppModel.onDemandVirtualAudioReleaseDelay <= 5)
    }

    @Test func remoteAudioSampleRatePolicySwitchesInBothDirections() {
        #expect(RemoteAudioFormat.needsReconfiguration(
            current: RemoteAudioFormat.xiaomiSampleRate,
            incoming: RemoteAudioFormat.siriRemoteSampleRate
        ))
        #expect(RemoteAudioFormat.needsReconfiguration(
            current: RemoteAudioFormat.siriRemoteSampleRate,
            incoming: RemoteAudioFormat.xiaomiSampleRate
        ))
        #expect(!RemoteAudioFormat.needsReconfiguration(
            current: RemoteAudioFormat.xiaomiSampleRate,
            incoming: RemoteAudioFormat.xiaomiSampleRate
        ))
    }

    @Test func healthyExplicitOutputIgnoresDefaultSystemOutputNotifications() {
        #expect(VirtualAudioRecoveryPolicy.shouldIgnoreDefaultSystemOutputChange(
            details: "properties=default_system_output",
            configurationHealthy: true
        ))
        #expect(!VirtualAudioRecoveryPolicy.shouldIgnoreDefaultSystemOutputChange(
            details: "properties=default_system_output",
            configurationHealthy: false
        ))
        #expect(!VirtualAudioRecoveryPolicy.shouldIgnoreDefaultSystemOutputChange(
            details: "properties=devices",
            configurationHealthy: true
        ))
    }

    @Test func fallbackPrefersBuiltInInputAndExcludesVirtualDevice() {
        let virtual = AudioDeviceInfo(id: 1, uid: "virtual", name: "MiRemoteV 2ch")
        let usb = AudioDeviceInfo(id: 2, uid: "usb", name: "USB Microphone")
        let builtIn = AudioDeviceInfo(id: 3, uid: "built-in", name: "MacBook Microphone")

        let fallback = DefaultInputFallbackPolicy.preferredFallback(
            in: [virtual, usb, builtIn],
            excludingUID: virtual.uid,
            builtInDeviceIDs: [builtIn.id]
        )

        #expect(fallback == builtIn)
    }

    @Test func fallbackUsesAnotherInputWhenBuiltInInputIsUnavailable() {
        let virtual = AudioDeviceInfo(id: 1, uid: "virtual", name: "MiRemoteV 2ch")
        let usb = AudioDeviceInfo(id: 2, uid: "usb", name: "USB Microphone")

        let fallback = DefaultInputFallbackPolicy.preferredFallback(
            in: [virtual, usb],
            excludingUID: virtual.uid,
            builtInDeviceIDs: []
        )

        #expect(fallback == usb)
    }

    @Test func fallbackPrefersTheUsersRememberedPhysicalInput() {
        let virtual = AudioDeviceInfo(id: 1, uid: "virtual", name: "MiRemoteV 2ch")
        let builtIn = AudioDeviceInfo(id: 2, uid: "built-in", name: "MacBook Microphone")
        let usb = AudioDeviceInfo(id: 3, uid: "usb", name: "USB Microphone")

        let fallback = DefaultInputFallbackPolicy.preferredFallback(
            in: [virtual, builtIn, usb],
            excludingUID: virtual.uid,
            builtInDeviceIDs: [builtIn.id],
            preferredUID: usb.uid
        )

        #expect(fallback == usb)
    }

    @Test func reconnectRestoresOnlyTheFallbackManagedByTheApp() {
        #expect(DefaultInputFallbackPolicy.shouldRestoreVirtualInput(
            managedVirtualUID: "virtual",
            selectedVirtualUID: "virtual",
            managedFallbackUID: "built-in",
            currentDefaultUID: "built-in"
        ))
        #expect(!DefaultInputFallbackPolicy.shouldRestoreVirtualInput(
            managedVirtualUID: "virtual",
            selectedVirtualUID: "virtual",
            managedFallbackUID: "built-in",
            currentDefaultUID: "usb-user-choice"
        ))
        #expect(!DefaultInputFallbackPolicy.shouldRestoreVirtualInput(
            managedVirtualUID: "virtual",
            selectedVirtualUID: "another-virtual",
            managedFallbackUID: "built-in",
            currentDefaultUID: "built-in"
        ))
    }
}
