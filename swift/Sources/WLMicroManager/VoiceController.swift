import AppKit
import WLKit

/// The wide bottom key: voice input for whichever agent has focus.
///
/// Claude Code has a real voice mode, so it gets the real thing — a key chord
/// injected into its pane that its keybindings map to `voice:pushToTalk` in
/// tap mode (start on the first press, transcribe and send on the second).
/// Codex's and pi's terminal UIs have no voice of their own, so for every
/// other harness the key triggers macOS dictation aimed at the same composer.
@MainActor
final class VoiceController {

    static let shared = VoiceController()

    /// The chord Claude's `~/.claude/keybindings.json` maps to
    /// `voice:pushToTalk`. Sent as terminal input, so it must be a chord a
    /// terminal can encode.
    static let claudeVoiceChord = "ctrl+alt+v"

    /// Mirrors an open Claude voice take, for the key light.
    var onActiveChange: ((Bool) -> Void)?
    var onError: ((String) -> Void)?

    /// Which half of Claude's start/stop cycle we are in. Only the light
    /// cares. Cancelling voice inside Claude (esc) makes this drift; the
    /// next press resynchronises it.
    private var claudeTakeOpen = false

    func handleVoiceKey() {
        Task { await trigger() }
    }

    private func trigger() async {
        do {
            guard let agent = try await HerdrClient.focusedAgent() else {
                onError?("Nothing has focus in Herdr right now.")
                return
            }
            if agent.agent.lowercased().contains("claude"), let pane = agent.paneID {
                try await HerdrClient.sendKeys(paneID: pane, keys: [Self.claudeVoiceChord])
                claudeTakeOpen.toggle()
                onActiveChange?(claudeTakeOpen)
            } else {
                try await triggerDictation()
            }
        } catch {
            onError?(error.localizedDescription)
        }
    }

    /// Posts the macOS dictation shortcut — fn pressed twice, the system
    /// default — as real key events. Dictated text lands in the focused
    /// composer, whichever harness owns it. Needs the Accessibility grant on
    /// top of Input Monitoring; the guard below shows the system prompt.
    private func triggerDictation() async throws {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        guard AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary) else {
            throw VoiceFailure.accessibilityDenied
        }

        let source = CGEventSource(stateID: .hidSystemState)
        let fn: CGKeyCode = 0x3F
        for press in 0..<2 {
            if press > 0 { try? await Task.sleep(nanoseconds: 90_000_000) }
            CGEvent(keyboardEventSource: source, virtualKey: fn, keyDown: true)?
                .post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: source, virtualKey: fn, keyDown: false)?
                .post(tap: .cghidEventTap)
        }
    }

    enum VoiceFailure: LocalizedError {
        case accessibilityDenied

        var errorDescription: String? {
            "Dictation needs the Accessibility permission: System Settings → "
                + "Privacy & Security → Accessibility → Micro Manager."
        }
    }
}
