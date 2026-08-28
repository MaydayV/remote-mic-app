import AppKit
import Carbon
import Foundation

enum OnboardingInputSourceSwitchResult: String, Equatable {
    case notApplicable
    case selected
    case unavailable
    case failed
}

enum OnboardingVoiceToolAvailability: String, Equatable {
    case available
    case notInstalled
}

enum OnboardingInputSourceSwitcher {
    static func availability(for voiceTool: OnboardingVoiceTool) -> OnboardingVoiceToolAvailability {
        guard let inputSourceID = voiceTool.preferredInputSourceID else { return .available }
        return inputSource(withID: inputSourceID, includeAllInstalled: true) == nil
            ? .notInstalled : .available
    }

    static func prepareForVoiceSession(
        _ voiceTool: OnboardingVoiceTool
    ) -> OnboardingInputSourceSwitchResult {
        guard let targetID = voiceTool.preferredInputSourceID else { return .notApplicable }
        guard currentInputSourceID() != targetID else { return .selected }
        guard let source = inputSource(withID: targetID, includeAllInstalled: false) else {
            return .unavailable
        }
        return TISSelectInputSource(source) == noErr ? .selected : .failed
    }

    static func currentInputSourceID() -> String? {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        return stringProperty(kTISPropertyInputSourceID, from: source)
    }

    static func selectEnabledInputSource(withID targetID: String) -> OnboardingInputSourceSwitchResult {
        guard let source = inputSource(withID: targetID, includeAllInstalled: false) else {
            return .unavailable
        }
        return TISSelectInputSource(source) == noErr ? .selected : .failed
    }

    private static func inputSource(withID targetID: String, includeAllInstalled: Bool) -> TISInputSource? {
        let sources = TISCreateInputSourceList(nil, includeAllInstalled).takeRetainedValue() as NSArray
        for object in sources {
            let source = object as! TISInputSource
            if stringProperty(kTISPropertyInputSourceID, from: source) == targetID { return source }
        }
        return nil
    }

    private static func stringProperty(_ key: CFString, from source: TISInputSource) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue() as? String
    }
}
