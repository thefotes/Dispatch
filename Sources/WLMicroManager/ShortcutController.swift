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

        let source = CGEventSource(stateID: .hidSystemState)
        guard
            let baseDown = CGEvent(keyboardEventSource: source,
                                   virtualKey: CGKeyCode(spec.keyCode), keyDown: true),
            let baseUp = CGEvent(keyboardEventSource: source,
                                 virtualKey: CGKeyCode(spec.keyCode), keyDown: false)
        else {
            onError?("Could not synthesise that shortcut.")
            return
        }

        // Real hardware reports a modifier key's own press as a distinct HID
        // event — a keyboard never sends "T with the control flag set"
        // without also sending control's own keydown. Stamping the flag on
        // the base key alone (an earlier version of this did only that)
        // satisfies a listener that reads event.flags on the base key, but
        // not one that also tracks each modifier's own press independently —
        // which is exactly what lets an app offer "tap a bare modifier" as
        // its own trigger, as OpenSuperWhisper's hotkey settings do. So each
        // modifier gets a real keydown/keyup here too, building the flag set
        // up one key at a time the way an actual chord's reports would.
        var held: CGEventFlags = []
        let chords = ShortcutSpec.Modifiers.chord.filter { spec.modifiers.contains($0.modifier) }

        for (_, code, flag) in chords {
            held.insert(flag)
            let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
            down?.flags = held
            down?.post(tap: .cghidEventTap)
        }

        baseDown.flags = held
        baseUp.flags = held   // still held on release — the modifier ups come after
        baseDown.post(tap: .cghidEventTap)
        baseUp.post(tap: .cghidEventTap)

        for (_, code, flag) in chords.reversed() {
            held.remove(flag)
            let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
            up?.flags = held
            up?.post(tap: .cghidEventTap)
        }
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
        (.command, 0x37, .maskCommand),
    ]
}
