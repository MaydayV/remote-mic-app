import Testing
@testable import RemoteMic

struct VoiceSamplePresentationPolicyTests {
    @Test func publishesOnlyTheFirstNonEmptyBatchPerSession() {
        #expect(VoiceSamplePresentationPolicy.shouldPublishReceipt(
            hasReceivedSamples: false,
            sampleCount: 160
        ))
        #expect(!VoiceSamplePresentationPolicy.shouldPublishReceipt(
            hasReceivedSamples: true,
            sampleCount: 160
        ))
        #expect(!VoiceSamplePresentationPolicy.shouldPublishReceipt(
            hasReceivedSamples: false,
            sampleCount: 0
        ))
    }
}
