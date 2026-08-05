import AppKit

/// The wide bottom key: taps **right command**, which is Superwhisper's
/// start/stop.
///
/// Superwhisper is system-wide and types into whatever holds focus, so this
/// deliberately does not care which agent Herdr has focused, or whether Herdr
/// is running at all. That is the difference from what this key used to do: it
/// asked Herdr for the focused agent and forked — Claude Code got a chord
/// injected into its pane for its own voice mode, everything else got macOS
/// dictation. One transcriber for every harness is simpler, and it is the one
/// press that has to work when you are mid-thought.
///
/// Posting a key event needs the **Accessibility** grant, on top of the Input
/// Monitoring grant the pad needs. The check below raises the system prompt the
/// first time.
@MainActor
final class VoiceController {

    static let shared = VoiceController()

    /// Right command. Its left twin is a different key code, and Superwhisper
    /// distinguishes them, so this must be the right-hand one.
    static let triggerKey: CGKeyCode = 0x36

    /// Mirrors an open take, for the key light.
    var onActiveChange: ((Bool) -> Void)?
    var onError: ((String) -> Void)?

    /// Which half of the start/stop cycle we are in. Only the light cares —
    /// stopping a take from the keyboard makes this drift, and the next press
    /// resynchronises it.
    private var takeOpen = false

    func handleVoiceKey() {
        do {
            try tapTriggerKey()
            takeOpen.toggle()
            onActiveChange?(takeOpen)
        } catch {
            onError?(error.localizedDescription)
        }
    }

    private func tapTriggerKey() throws {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        guard AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary) else {
            throw VoiceFailure.accessibilityDenied
        }

        let source = CGEventSource(stateID: .hidSystemState)
        guard
            let down = CGEvent(keyboardEventSource: source,
                               virtualKey: Self.triggerKey, keyDown: true),
            let up = CGEvent(keyboardEventSource: source,
                             virtualKey: Self.triggerKey, keyDown: false)
        else { throw VoiceFailure.eventFailed }

        // A modifier carries its own flag: set on the way down, cleared on the
        // way up. Skip that and listeners see a command key that never
        // releases, which leaves the whole machine holding a modifier down.
        down.flags = .maskCommand
        up.flags = []
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    enum VoiceFailure: LocalizedError {
        case accessibilityDenied
        case eventFailed

        var errorDescription: String? {
            switch self {
            case .accessibilityDenied:
                return "Pressing right command needs the Accessibility permission: "
                    + "System Settings → Privacy & Security → Accessibility → Micro Manager."
            case .eventFailed:
                return "Could not synthesise the right command key press."
            }
        }
    }
}
