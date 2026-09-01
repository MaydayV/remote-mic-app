import Testing

@testable import RemoteMic

struct SystemRemoteRuntimeLifecycleTests {
    @Test func sleepWakeUsesGracePeriodAndResumesOnce() {
        var state = SystemRemoteRuntimeLifecycleState()
        #expect(state.handle(.systemWillSleep) == .suspend)
        #expect(state.phase == .sleeping)
        guard case let .scheduleResume(generation) = state.handle(.systemDidWake) else {
            Issue.record("wake should schedule a resume")
            return
        }
        #expect(state.wakeGraceElapsed(generation: generation) == .resume)
        #expect(state.phase == .active)
        #expect(state.wakeGraceElapsed(generation: generation) == .none)
    }

    @Test func userVisibleWakeCanResumeImmediately() {
        var state = SystemRemoteRuntimeLifecycleState()
        _ = state.handle(.systemWillSleep)
        _ = state.handle(.systemDidWake)
        #expect(state.confirmUserVisibleWake() == .resume)
        #expect(state.phase == .active)
    }

    @Test func staleGenerationCannotResumeAfterAnotherSleep() {
        var state = SystemRemoteRuntimeLifecycleState()
        _ = state.handle(.systemWillSleep)
        guard case let .scheduleResume(generation) = state.handle(.systemDidWake) else {
            Issue.record("wake should schedule a resume")
            return
        }
        _ = state.handle(.systemWillSleep)
        #expect(state.wakeGraceElapsed(generation: generation) == .none)
        #expect(state.phase == .sleeping)
    }

    @Test(arguments: [
        (true, false, false, true),
        (true, true, false, false),
        (true, false, true, false),
        (false, false, false, false),
    ])
    func userVisiblePolicy(
        displayActive: Bool,
        displayAsleep: Bool,
        clamshellClosed: Bool,
        expected: Bool
    ) {
        #expect(SystemWakeVisibilityPolicy.isUserVisible(
            displayActive: displayActive,
            displayAsleep: displayAsleep,
            clamshellClosed: clamshellClosed
        ) == expected)
    }
}
