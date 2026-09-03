import Foundation
import Testing
@testable import RemoteMic

@Suite("Siri Remote native microphone capture")
struct SiriRemoteNativeMicCaptureTests {
    @Test func parsesVoiceNotificationFromReassembledACLFragments() {
        let frame = makeVoiceFrame(sequence: 7, attributeHandle: 0x0036)
        let extractor = SiriRemotePacketLoggerVoiceExtractor()

        var result: [SiriRemoteNativeVoiceFrame] = []
        // Deliberately split records at arbitrary byte boundaries to model a tailing file.
        var offset = 0
        while offset < frame.count {
            let end = min(offset + 7, frame.count)
            result.append(contentsOf: extractor.ingest(Data(frame[offset..<end])))
            offset = end
        }

        #expect(result.count == 1)
        #expect(result.first?.connectionHandle == "0x0406")
        #expect(result.first?.attributeHandle == 0x0036)
        #expect(result.first?.sequence == 7)
        #expect(result.first?.opusPayload == Data([0xB8, 0x01, 0x02]))
    }

    @Test func rejectsNonVoiceATTNotifications() {
        let bytes: [UInt8] = [
            0x04, 0x00, 0x1B, 0x36, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x03, 0x01, 0x02, 0x03,
        ]
        #expect(
            SiriRemoteNativeVoiceFrameParser.parse(
                bytes: bytes,
                connectionHandle: "0x0406"
            ) == nil
        )
    }

    @Test func packetLoggerLocatorReturnsNilOrExecutableURL() {
        let url = SiriRemoteNativeMicCapture.packetLoggerURL()
        #expect(url == nil || FileManager.default.isExecutableFile(atPath: url!.path))
    }

    @Test func jitterBufferPrimesBeforePublishingAndKeepsFrameOrder() {
        let buffer = SiriRemoteNativeJitterBuffer()
        let frame = [Float](repeating: 0.25, count: 960)
        #expect(buffer.append(frame).isEmpty)
        #expect(buffer.append(frame).isEmpty)
        let primed = buffer.append(frame)
        #expect(primed.count == 1)
        #expect(primed[0].count == 2_880)
        #expect(primed[0].allSatisfy { $0 == 0.25 })
        let next = buffer.append([Float](repeating: -0.5, count: 960))
        #expect(next == [[Float](repeating: -0.5, count: 960)])
    }

    @Test func nativeSetupStatusIsReadOnlyAndDoesNotClaimPacketLoggerAvailability() {
        // CI/test hosts may not have Additional Tools installed. The status
        // query must remain safe and independent from the executable lookup.
        let traceConfigured = SiriRemoteNativeMicCapture.hciTraceConfigurationPresent()
        let packetLogger = SiriRemoteNativeMicCapture.packetLoggerURL()
        #expect(traceConfigured == SiriRemoteNativeMicCapture.hciTraceConfigurationPresent())
        #expect(packetLogger == nil || FileManager.default.isExecutableFile(atPath: packetLogger!.path))
    }

    @Test func nativeAvailabilityOnlyReportsReadyWhenBothPrerequisitesExist() {
        #expect(SiriRemoteNativeMicAvailability(packetLoggerAvailable: true, traceConfigured: true).ready)
        #expect(!SiriRemoteNativeMicAvailability(packetLoggerAvailable: false, traceConfigured: true).ready)
        #expect(!SiriRemoteNativeMicAvailability(packetLoggerAvailable: true, traceConfigured: false).ready)
    }

    @Test func builtinVoiceFallbackWaitsForRemoteGraceAndStaleness() {
        let started = Date(timeIntervalSince1970: 1_000)
        #expect(!SiriRemoteVoiceFallbackPolicy.shouldUseBuiltin(
            now: started.addingTimeInterval(0.34),
            voiceStartedAt: started,
            lastRemoteAudioAt: nil
        ))
        #expect(SiriRemoteVoiceFallbackPolicy.shouldUseBuiltin(
            now: started.addingTimeInterval(0.35),
            voiceStartedAt: started,
            lastRemoteAudioAt: nil
        ))
        #expect(!SiriRemoteVoiceFallbackPolicy.shouldUseBuiltin(
            now: started.addingTimeInterval(0.50),
            voiceStartedAt: started,
            lastRemoteAudioAt: started.addingTimeInterval(0.40)
        ))
        #expect(SiriRemoteVoiceFallbackPolicy.shouldUseBuiltin(
            now: started.addingTimeInterval(0.71),
            voiceStartedAt: started,
            lastRemoteAudioAt: started.addingTimeInterval(0.40)
        ))
    }

    @Test func nativeSetupGuidesAreBundledForBothLocales() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for locale in ["en.lproj", "zh-Hans.lproj"] {
            let guide = root.appendingPathComponent("Resources/\(locale)/SiriRemoteNativeMic.md")
            #expect(FileManager.default.fileExists(atPath: guide.path))
        }
    }

    @Test func sharedRingWriterKeepsReferenceIPCNamesAndABI() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SiriRemoteMicSharedRingWriter.swift"),
            encoding: .utf8
        )
        #expect(source.contains("/SiriRemoteMicAudio"))
        #expect(source.contains("/SiriRemoteMicBuiltin"))
        #expect(source.contains("ringOffset = 40"))
        #expect(source.contains("writeRemote"))
        #expect(source.contains("writeBuiltin"))
    }

    @Test func nativeSetupEnablesEveryTraceFlagUsedByTheReferencePipeline() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SiriRemoteNativeMicSetup.swift"),
            encoding: .utf8
        )
        for flag in ["HCISkipAuth", "HCILiveTraces", "HCIFileTraces", "StackDebugEnabled", "RawAudioTrace", "HIDTrace"] {
            #expect(source.contains(flag))
        }
    }

    private func makeVoiceFrame(sequence: UInt16, attributeHandle: UInt16) -> [UInt8] {
        let opus: [UInt8] = [0xB8, 0x01, 0x02]
        let attValue: [UInt8] = [
            0x00, 0x00,
            UInt8(truncatingIfNeeded: sequence),
            UInt8(truncatingIfNeeded: sequence >> 8),
            UInt8(opus.count),
        ] + opus
        let att: [UInt8] = [
            0x1B,
            UInt8(truncatingIfNeeded: attributeHandle),
            UInt8(truncatingIfNeeded: attributeHandle >> 8),
        ] + attValue
        let l2capLength = UInt16(att.count)
        let l2cap: [UInt8] = [
            UInt8(truncatingIfNeeded: l2capLength),
            UInt8(truncatingIfNeeded: l2capLength >> 8),
            0x04, 0x00,
        ] + att

        // First ACL fragment carries the L2CAP header and the first half of ATT.
        let firstCount = 8
        let firstData = Array(l2cap.prefix(firstCount))
        let continuationData = Array(l2cap.dropFirst(firstCount))
        let handle: UInt16 = 0x0406
        let firstHeader = handle | 0x2000 // PB=0b10, first fragment
        let continuationHeader = handle | 0x1000 // PB=0b01, continuation
        let firstACL = aclPayload(header: firstHeader, data: firstData)
        let continuationACL = aclPayload(header: continuationHeader, data: continuationData)
        return makeRecord(payload: firstACL) + makeRecord(payload: continuationACL)
    }

    private func aclPayload(header: UInt16, data: [UInt8]) -> [UInt8] {
        [
            UInt8(truncatingIfNeeded: header),
            UInt8(truncatingIfNeeded: header >> 8),
            UInt8(truncatingIfNeeded: data.count),
            UInt8(truncatingIfNeeded: data.count >> 8),
        ] + data
    }

    private func makeRecord(payload: [UInt8]) -> [UInt8] {
        let length = UInt32(9 + payload.count)
        return [
            UInt8(truncatingIfNeeded: length >> 24),
            UInt8(truncatingIfNeeded: length >> 16),
            UInt8(truncatingIfNeeded: length >> 8),
            UInt8(truncatingIfNeeded: length),
            0, 0, 0, 0, // seconds
            0, 0, 0, 0, // microseconds
            0x03,       // ACL received
        ] + payload
    }
}
