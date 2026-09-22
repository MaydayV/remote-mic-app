import Foundation
import Testing
@testable import RemoteMic

@Suite("Bluetooth wake recovery pending state")
struct BluetoothWakeRecoveryPendingTests {
    @Test func systemSleepArmsRecoveryUntilResume() {
        #expect(BluetoothWakeRecoveryPolicy.pendingRecovery(
            after: .systemWillSleep,
            current: false
        ))
        #expect(BluetoothWakeRecoveryPolicy.pendingRecovery(
            after: .screenDidWake,
            current: true
        ))
    }

    @Test func systemWakeArmsRecoveryWithoutObservedSleep() {
        #expect(BluetoothWakeRecoveryPolicy.pendingRecovery(
            after: .systemDidWake,
            current: false
        ))
    }

    @Test func displayOnlyWakeDoesNotArmRecovery() {
        #expect(!BluetoothWakeRecoveryPolicy.pendingRecovery(
            after: .screenDidWake,
            current: false
        ))
        #expect(!BluetoothWakeRecoveryPolicy.pendingRecovery(
            after: .screenDidSleep,
            current: false
        ))
    }

    @Test func recoveryRunsOnlyWhenArmedAndNoBridgeIsReady() {
        #expect(BluetoothWakeRecoveryPolicy.shouldForceReconnect(
            pendingRecovery: true,
            started: true,
            readyBridgeCount: 0
        ))
        #expect(!BluetoothWakeRecoveryPolicy.shouldForceReconnect(
            pendingRecovery: true,
            started: true,
            readyBridgeCount: 1
        ))
        #expect(!BluetoothWakeRecoveryPolicy.shouldForceReconnect(
            pendingRecovery: false,
            started: true,
            readyBridgeCount: 0
        ))
    }
}
