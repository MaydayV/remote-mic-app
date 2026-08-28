import AppKit

/// Temporarily selects the configured voice input source during voice capture,
/// then restores the user's source unless they changed it themselves.
final class PreferredInputSourceMonitor {
    private let voiceTool: () -> OnboardingVoiceTool
    private var monitor: Any?
    private var functionKeyIsPressed = false
    private var session: (previous: String, target: String, owners: Set<String>)?

    init(voiceTool: @escaping () -> OnboardingVoiceTool) {
        self.voiceTool = voiceTool
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFunctionKeyPressed(event.modifierFlags.contains(.function))
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        finish(owner: nil)
        functionKeyIsPressed = false
    }

    func beginVoiceSession() { begin(owner: "voice") }
    func endVoiceSession() { finish(owner: "voice") }

    private func handleFunctionKeyPressed(_ pressed: Bool) {
        guard pressed != functionKeyIsPressed else { return }
        functionKeyIsPressed = pressed
        pressed ? begin(owner: "fn") : finish(owner: "fn")
    }

    private func begin(owner: String) {
        guard let target = voiceTool().preferredInputSourceID else { return }
        if var session {
            session.owners.insert(owner)
            self.session = session
            return
        }
        guard let previous = OnboardingInputSourceSwitcher.currentInputSourceID(), previous != target else {
            return
        }
        guard OnboardingInputSourceSwitcher.prepareForVoiceSession(voiceTool()) == .selected else {
            AppLogger.shared.write("VOICE INPUT source_prepare failed tool=\(voiceTool().rawValue)")
            return
        }
        session = (previous, target, [owner])
    }

    private func finish(owner: String?) {
        guard var session else { return }
        if let owner {
            session.owners.remove(owner)
            guard session.owners.isEmpty else { self.session = session; return }
        }
        self.session = nil
        guard OnboardingInputSourceSwitcher.currentInputSourceID() == session.target else { return }
        _ = OnboardingInputSourceSwitcher.selectEnabledInputSource(withID: session.previous)
    }

    deinit { stop() }
}
