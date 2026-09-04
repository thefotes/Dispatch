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
            let down = CGEvent(keyboardEventSource: source,
                               virtualKey: CGKeyCode(spec.keyCode), keyDown: true),
            let up = CGEvent(keyboardEventSource: source,
                             virtualKey: CGKeyCode(spec.keyCode), keyDown: false)
        else {
            onError?("Could not synthesise that shortcut.")
            return
        }

        // The modifier goes on as a flag on the key event itself, exactly as
        // the voice key's right-command tap does — cleared on the way up so
        // nothing is left holding a modifier down.
        down.flags = spec.modifiers.cgEventFlags
        up.flags = []
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

private extension ShortcutSpec.Modifiers {
    var cgEventFlags: CGEventFlags {
        var flags: CGEventFlags = []
        if contains(.command) { flags.insert(.maskCommand) }
        if contains(.shift) { flags.insert(.maskShift) }
        if contains(.option) { flags.insert(.maskAlternate) }
        if contains(.control) { flags.insert(.maskControl) }
        return flags
    }
}
