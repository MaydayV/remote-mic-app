import CoreGraphics
import Testing
@testable import RemoteMic

@Suite("Voice key modes")
struct VoiceKeyModeTests {
    @Test func keepsFnDefaultAndExposesRightOption() {
        #expect(VoiceKeyMode.function.rawValue == "fn")
        #expect(VoiceKeyMode.function.keyCode == 63)
        #expect(VoiceKeyMode.leftCommand.keyCode == 55)
        #expect(VoiceKeyMode.rightCommand.keyCode == 54)
        #expect(VoiceKeyMode.rightOption.rawValue == "right_option")
        #expect(VoiceKeyMode.rightOption.keyCode == 61)
        #expect(!VoiceKeyMode.function.requiresAccessibility)
        #expect(VoiceKeyMode.rightOption.requiresAccessibility)
        #expect(VoiceKeyMode.rightOption.localizationKey == "connection.voice_key.mode.right_option")
    }

    @Test func rightOptionInjectsAlternateModifierAndReleasesCleanly() {
        var events: [(CGKeyCode, Bool, CGEventFlags)] = []
        let poster: KeyboardInjector.KeyStatePoster = { code, isDown, flags in
            events.append((code, isDown, flags))
            return true
        }
        #expect(KeyboardInjector.setVoiceKeyPressed(
            mode: .rightOption,
            isPressed: true,
            accessibilityTrusted: { true },
            keyStatePoster: poster
        ))
        #expect(KeyboardInjector.setVoiceKeyPressed(
            mode: .rightOption,
            isPressed: false,
            accessibilityTrusted: { true },
            keyStatePoster: poster
        ))
        #expect(events.count == 2)
        #expect(events[0].0 == 61)
        #expect(events[0].1)
        #expect(events[0].2 == .maskAlternate)
        #expect(events[1].0 == 61)
        #expect(!events[1].1)
        #expect(events[1].2.isEmpty)
    }
}
