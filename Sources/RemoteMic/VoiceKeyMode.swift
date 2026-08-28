import Foundation

/// Key emitted while a voice session is active. Fn remains the default for
/// backwards compatibility; Command modes provide a dedicated trigger for
/// input methods that do not support Fn.
enum VoiceKeyMode: String, Codable, CaseIterable, Identifiable {
    case function = "fn"
    case leftCommand = "left_command"
    case rightCommand = "right_command"

    var id: String { rawValue }

    var keyCode: UInt16 {
        switch self {
        case .function: return 63
        case .leftCommand: return 55
        case .rightCommand: return 54
        }
    }

    var requiresAccessibility: Bool { self != .function }
    var usesHardwareMapping: Bool { self == .function }

    var localizationKey: String {
        "connection.voice_key.mode.\(rawValue)"
    }
}
