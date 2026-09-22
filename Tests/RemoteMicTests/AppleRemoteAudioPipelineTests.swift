import Foundation
import Testing
import AppleRemoteHCIProtocol
@testable import RemoteMic

struct AppleRemoteAudioPipelineTests {
    @Test func captureGenerationGateRejectsStaleCallbacksAfterStop() {
        var gate = AppleRemoteAudioCaptureGenerationGate()
        let firstGeneration = gate.begin()
        #expect(gate.isCapturing)
        #expect(gate.accepts(firstGeneration))

        let stoppedGeneration = gate.stop()
        #expect(stoppedGeneration != firstGeneration)
        #expect(!gate.isCapturing)
        #expect(!gate.accepts(firstGeneration))
    }

    @Test func captureGenerationGateCanResumeOnlyWhileClosing() {
        var gate = AppleRemoteAudioCaptureGenerationGate()
        #expect(gate.resume() == nil)
        let generation = gate.begin()
        #expect(gate.beginClosing() == generation)
        #expect(gate.resume() == generation)
        #expect(gate.accepts(generation))
    }

    @Test func upstreamHCITraceConfigurationPreservesExistingPreferences() throws {
        let original = try PropertyListSerialization.data(
            fromPropertyList: ["Existing": "keep"],
            format: .binary,
            options: 0
        )
        let enabled = try AppleRemoteHCITraceConfiguration.enabledPreferencesData(
            from: original
        )
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: enabled, format: nil)
                as? [String: Any]
        )
        #expect(plist["Existing"] as? String == "keep")
        let traces = try #require(plist["HCITraces"] as? [String: Bool])
        #expect(Set(traces.keys) == Set(AppleRemoteHCITraceConfiguration.requiredTraceKeys))
        #expect(traces.values.allSatisfy { $0 })
    }
}
