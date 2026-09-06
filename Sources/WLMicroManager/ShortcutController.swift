import AppKit
import WLKit

/// Posts a config-bound `ShortcutSpec` as a real system keystroke, so a spare
/// key can drive anything a hotkey can — a screenshot tool, Mission Control,
/// an app's own shortcut — regardless of what Herdr is doing.
///
/// Same technique as `VoiceController`'s right-command tap: a synthesised
/// `CGEvent`, which needs the Accessibility grant on top of the pad's own
/// Input Monitoring grant.
@MainActor
final class ShortcutController {

    static let shared = ShortcutController()

    var onError: ((String) -> Void)?

    func post(_ spec: ShortcutSpec) {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        guard AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary) else {
            onError?("Keyboard shortcuts need the Accessibility permission: "
                + "System Settings → Privacy & Security → Accessibility → Micro Manager.")
            return
        }

        let chords = ShortcutSpec.Modifiers.chord
            .filter { spec.modifiers.contains($0.modifier) }
            .map { (code: $0.keyCode, flag: $0.flag) }

        SyntheticChord.post(chord: chords, base: (spec.keyCode, nil)) { onError?($0) }
    }
}

private extension ShortcutSpec.Modifiers {
    /// Left-hand virtual keycode and `CGEventFlags` bit for each modifier,
    /// in a fixed press order. The order is arbitrary — a listener never
    /// cares which modifier's HID report arrived first — but fixed, so a
    /// chord presses and releases the same way every time.
    static let chord: [(modifier: Self, keyCode: CGKeyCode, flag: CGEventFlags)] = [
        (.control, 0x3B, .maskControl),
        (.option, 0x3A, .maskAlternate),
        (.shift, 0x38, .maskShift),
        (.command, 0x37, .maskCommand)
    ]
}
