import Foundation
import Testing
@testable import RemoteMic

/// Siri Remote usage → RemoteButton 映射表测试（纯逻辑，无需硬件）。
/// 映射表移植自 VibeRemote 真机验证数据。
@MainActor
struct SiriRemoteBackendTests {
    @Test func mapsConsumerPageButtons() {
        // Consumer Page (0x0C)
        #expect(SiriRemoteBackend.identifyButton(page: 0x0C, usage: 0x04) == .voice)      // Siri
        #expect(SiriRemoteBackend.identifyButton(page: 0x0C, usage: 0x60) == .tv)          // TV
        #expect(SiriRemoteBackend.identifyButton(page: 0x0C, usage: 0x223) == .tv)         // TV alt
        #expect(SiriRemoteBackend.identifyButton(page: 0x0C, usage: 0x80) == .ok)          // Select
        #expect(SiriRemoteBackend.identifyButton(page: 0x0C, usage: 0x41) == .ok)          // Menu Pick
        #expect(SiriRemoteBackend.identifyButton(page: 0x0C, usage: 0x42) == .up)
        #expect(SiriRemoteBackend.identifyButton(page: 0x0C, usage: 0x43) == .down)
        #expect(SiriRemoteBackend.identifyButton(page: 0x0C, usage: 0x44) == .left)
        #expect(SiriRemoteBackend.identifyButton(page: 0x0C, usage: 0x45) == .right)
        #expect(SiriRemoteBackend.identifyButton(page: 0x0C, usage: 0xCD) == .playPause)
        #expect(SiriRemoteBackend.identifyButton(page: 0x0C, usage: 0xE9) == .volumeUp)
        #expect(SiriRemoteBackend.identifyButton(page: 0x0C, usage: 0xEA) == .volumeDown)
        #expect(SiriRemoteBackend.identifyButton(page: 0x0C, usage: 0xE2) == .mute)
        #expect(SiriRemoteBackend.identifyButton(page: 0x0C, usage: 0x20) == .mute)        // Mute alt
        #expect(SiriRemoteBackend.identifyButton(page: 0x0C, usage: 0x30) == .power)
        #expect(SiriRemoteBackend.identifyButton(page: 0x0C, usage: 0x40) == .menu)
        #expect(SiriRemoteBackend.identifyButton(page: 0x0C, usage: 0x224) == .back)
    }

    @Test func mapsGenericDesktopAndButtonPages() {
        #expect(SiriRemoteBackend.identifyButton(page: 0x01, usage: 0x86) == .menu)        // System Menu
        #expect(SiriRemoteBackend.identifyButton(page: 0x01, usage: 0x40) == .menu)
        #expect(SiriRemoteBackend.identifyButton(page: 0x09, usage: 0x01) == .ok)          // Button 1
    }

    @Test func mapsVendorAndTelephonySiriUsages() {
        #expect(SiriRemoteBackend.identifyButton(page: 0xFF00, usage: 0x01) == .voice)
        #expect(SiriRemoteBackend.identifyButton(page: 0xFF00, usage: 0x02) == .voice)
        #expect(SiriRemoteBackend.identifyButton(page: 0xFF00, usage: 0x03) == .voice)
        #expect(SiriRemoteBackend.identifyButton(page: 0x0B, usage: 0x21) == .voice)
        #expect(SiriRemoteBackend.identifyButton(page: 0x0B, usage: 0x2F) == .voice)
    }

    @Test func ignoresUnmappedAndTrackUsages() {
        // nextTrack/prevTrack 在 SayAll 无对应键 → 忽略
        #expect(SiriRemoteBackend.identifyButton(page: 0x0C, usage: 0xB5) == nil)
        #expect(SiriRemoteBackend.identifyButton(page: 0x0C, usage: 0xB6) == nil)
        // 无关 usage
        #expect(SiriRemoteBackend.identifyButton(page: 0x01, usage: 0x01) == nil)
        #expect(SiriRemoteBackend.identifyButton(page: 0xFF00, usage: 0x99) == nil)
    }

    @Test func siriRemoteSupportedButtonsExcludeNothingEssential() {
        let backendButtons = Set(SiriRemoteBackend().supportedButtons)
        // Siri Remote 必须覆盖统一事件的全部核心键
        for required in [RemoteButton.up, .down, .left, .right, .ok, .back, .homeOrMenu,
                         .playPause, .volumeUp, .volumeDown, .mute, .power, .voice] {
            #expect(backendButtons.contains(required), Comment(rawValue: required.rawValue))
        }
    }

    @Test func persistedSiriSelectionRequiresBackendAtStartup() {
        #expect(RemoteBackendRuntimePolicy.shouldRunSiriRemote(activeKind: .siriRemote))
        #expect(!RemoteBackendRuntimePolicy.shouldRunSiriRemote(activeKind: .xiaomi))
    }

    @Test func keepsSystemCriticalConsumerCollectionsShared() {
        #expect(SiriRemoteBackend.requiresSharedSystemAccess(usagePage: 0x0C, usage: 0x04))
        #expect(SiriRemoteBackend.requiresSharedSystemAccess(usagePage: 0x0C, usage: 0x01))
        #expect(!SiriRemoteBackend.requiresSharedSystemAccess(usagePage: 0x0D, usage: 0x05))
    }

    @Test func batteryReaderRecognizesAppleRemoteNames() {
        #expect(SiriRemoteBatteryReader.isLikelyRemoteName("Apple TV Remote"))
        #expect(SiriRemoteBatteryReader.isLikelyRemoteName("Marcus Siri Remote"))
        #expect(!SiriRemoteBatteryReader.isLikelyRemoteName("Magic Mouse"))
    }
}

private extension RemoteButton {
    /// 测试辅助：Siri Remote 的 menu 键承担 SayAll 的 menu（home 键 Siri Remote 无）
    static let homeOrMenu = RemoteButton.menu
}

// MARK: - 0xFA 音频报告解析器测试

extension SiriRemoteBackendTests {
    @Test func parsesGen3DirectHID99ByteLayout() {
        // 99-byte 布局: 2 字节前缀 + LE 序号 + 1 字节长度 + Opus 包 + 零填充
        var bytes = [UInt8](repeating: 0, count: 99)
        bytes[0] = 0x01
        bytes[1] = 0x02
        bytes[2] = 0x34
        bytes[3] = 0x12          // LE 序号 0x1234
        bytes[4] = 5             // 包长度 5
        bytes[5] = 0x41
        bytes[6] = 0x42
        bytes[7] = 0x43
        bytes[8] = 0x44
        bytes[9] = 0x45
        let events = SiriRemoteAudioReportParser.events(from: bytes)
        #expect(events == [.packet(Data([0x41, 0x42, 0x43, 0x44, 0x45]))])
    }

    @Test func stripsSynthetic0xFFReportIDPrefix() {
        var bytes = [UInt8](repeating: 0, count: 100)
        bytes[0] = 0xFF           // macOS 合成的 report ID
        bytes[5] = 3
        bytes[6] = 0x61
        bytes[7] = 0x62
        bytes[8] = 0x63
        let events = SiriRemoteAudioReportParser.events(from: bytes)
        #expect(events == [.packet(Data([0x61, 0x62, 0x63]))])
    }

    @Test func zeroLengthReportIsReleaseSentinel() {
        let bytes = [UInt8](repeating: 0, count: 99)
        #expect(SiriRemoteAudioReportParser.events(from: bytes) == [.ended])
    }

    @Test func ignoresAllZeroPacket() {
        var bytes = [UInt8](repeating: 0, count: 99)
        bytes[4] = 5              // 有长度但包内容全零
        bytes[5] = 0
        bytes[6] = 0
        bytes[7] = 0
        bytes[8] = 0
        bytes[9] = 0
        #expect(SiriRemoteAudioReportParser.events(from: bytes) == [])
    }

    @Test func rejectsOversizedPacketLength() {
        var bytes = [UInt8](repeating: 0, count: 99)
        bytes[4] = 95             // 超过 94 上限
        #expect(SiriRemoteAudioReportParser.events(from: bytes) == [])
    }

    @Test func parsesLegacy1B35Encapsulation() {
        // 旧代 1B 35 封装: 0x1B 0x35 + 5 字节头 + 1 字节长度 + Opus 包
        let bytes: [UInt8] = [0x00, 0x1B, 0x35, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x71, 0x72, 0x73]
        let events = SiriRemoteAudioReportParser.events(from: bytes)
        #expect(events == [.packet(Data([0x71, 0x72, 0x73]))])
    }
}

// MARK: - 电量解析测试

extension SiriRemoteBackendTests {
    @Test func resolvesBatteryFromBatteryLevelKey() {
        #expect(SiriRemoteBackend.resolveBatteryLevel(from: { key in
            key == "BatteryLevel" ? 80 : nil
        }) == 80)
    }

    @Test func batteryZeroIsValidLevel() {
        #expect(SiriRemoteBackend.resolveBatteryLevel(from: { _ in 0 }) == 0)
    }

    @Test func fallsBackToBatteryPercentKey() {
        // BatteryLevel 缺失 → 回退 BatteryPercent
        #expect(SiriRemoteBackend.resolveBatteryLevel(from: { key in
            key == "BatteryPercent" ? 42 : nil
        }) == 42)
    }

    @Test func batteryUnavailableWhenBothKeysMissing() {
        #expect(SiriRemoteBackend.resolveBatteryLevel(from: { _ in nil }) == nil)
    }

    @Test func batteryRejectsOutOfRangeValues() {
        #expect(SiriRemoteBackend.resolveBatteryLevel(from: { _ in 255 }) == nil)
        #expect(SiriRemoteBackend.resolveBatteryLevel(from: { _ in -5 }) == nil)
        #expect(SiriRemoteBackend.resolveBatteryLevel(from: { _ in 101 }) == nil)
    }

    @Test func batteryRejectsNonNumericValues() {
        #expect(SiriRemoteBackend.resolveBatteryLevel(from: { _ in "80" as NSString }) == nil)
    }
}
