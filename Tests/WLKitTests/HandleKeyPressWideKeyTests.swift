import XCTest
@testable import WLKit

/// `handleKeyPress` is what a real HID notification reaches — these drive it
/// directly with the exact sequence the wide key's two switches produce for
/// one physical press, to pin the double-fire fix at the level a regression
/// would actually reappear.
@MainActor
final class HandleKeyPressWideKeyTests: XCTestCase {

    func testPressingBothHalvesOfTheWideKeyFiresTheVoiceCallbackOnce() {
        let bridge = BridgeController()
        // Explicit defaults, not whatever config.json happens to be on this
        // machine — the built-in voice tap only fires when 10/11 are
        // unbound.
        bridge.setKeyBindingsForTesting(KeyBindings())
        var fireCount = 0
        bridge.onVoiceKey = { fireCount += 1 }

        // The two switches under one keycap, milliseconds apart — exactly
        // what one physical press of the wide key produces.
        bridge.handleKeyPress(Pad.voiceKeyIDs[0])
        bridge.handleKeyPress(Pad.voiceKeyIDs[1])

        XCTAssertEqual(fireCount, 1)
    }

    /// Two genuinely separate presses — a real double-tap — must still both
    /// register once the debounce window has passed.
    func testTwoDeliberatePressesFarApartBothFire() {
        let bridge = BridgeController()
        bridge.setKeyBindingsForTesting(KeyBindings())
        var fireCount = 0
        bridge.onVoiceKey = { fireCount += 1 }

        bridge.handleKeyPress(Pad.voiceKeyIDs[0])
        Thread.sleep(forTimeInterval: 0.2)   // past the 150ms debounce window
        bridge.handleKeyPress(Pad.voiceKeyIDs[0])

        XCTAssertEqual(fireCount, 2)
    }

    /// The same collapse has to apply to a config-bound shortcut, not just
    /// the built-in voice tap — that is what OpenSuperWhisper's ctrl+t
    /// binding actually exercises.
    func testPressingBothHalvesFiresAConfiguredShortcutOnce() {
        var bindings: [Int: KeyBindings.KeyAction] = KeyBindings.defaults
        bindings[Pad.voiceKeyIDs[0]] = .shortcut("ctrl+t")
        bindings[Pad.voiceKeyIDs[1]] = .shortcut("ctrl+t")
        let bridge = BridgeController()
        bridge.setKeyBindingsForTesting(KeyBindings(actions: bindings))
        var fireCount = 0
        bridge.onShortcut = { _ in fireCount += 1 }

        bridge.handleKeyPress(Pad.voiceKeyIDs[0])
        bridge.handleKeyPress(Pad.voiceKeyIDs[1])

        XCTAssertEqual(fireCount, 1)
    }
}
