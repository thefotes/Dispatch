import Foundation
import WLKit

/// The dial: the reasoning-effort ladder for whichever agent has focus.
///
/// Claude Code takes orders directly — `/effort <level>` is a command, so
/// the dial climbs a configurable effort ladder. Codex has bindable effort
/// commands, so its dial sends the chords bound in `[tui.keymap]`.
///
/// The joystick used to live here too, cycling model lists you could not
/// see from the pad; it now belongs to the provider (`Provider.joystick`),
/// which navigates panes for Herdr.
@MainActor
final class TuneController {

    static let shared = TuneController()

    /// The chords `~/.codex/config.toml` binds to
    /// `chat.increase_reasoning_effort` / `chat.decrease_reasoning_effort`.
    static let codexEffortUpChord = "ctrl+alt+u"
    static let codexEffortDownChord = "ctrl+alt+d"

    var onError: ((String) -> Void)?
    /// The bridge owns the loaded config; this reads through to it.
    var bindings: () -> KeyBindings = { KeyBindings() }

    /// Where each Claude pane sits on the effort ladder. Blind state: it
    /// starts at the default and follows our own commands, so a change made
    /// by hand inside the session drifts it until the next nudge.
    private var claudeEffortIndex: [String: Int] = [:]

    func handleDial(_ step: Int) {
        Task { await dial(step) }
    }

    private func dial(_ step: Int) async {
        guard let (agent, pane) = await focusedPane() else { return }
        let kind = agent.agent.lowercased()
        do {
            if kind.contains("claude") {
                let ladder = bindings().claudeEfforts
                let index = climb(claudeEffortIndex[pane] ?? ladder.count / 2,
                                  by: step, within: ladder.count)
                claudeEffortIndex[pane] = index
                try await send(command: "/effort \(ladder[index])", to: pane)
            } else if kind.contains("codex") {
                try await HerdrClient.sendKeys(
                    paneID: pane,
                    keys: [step > 0 ? Self.codexEffortUpChord : Self.codexEffortDownChord]
                )
            } else {
                onError?("No effort control for \(agent.agent).")
            }
        } catch {
            onError?(error.localizedDescription)
        }
    }

    /// Clamped, not wrapping: turning past the top should pin at max, not
    /// jump to low — a dial has ends even when the hardware spins freely.
    private func climb(_ index: Int, by step: Int, within count: Int) -> Int {
        max(0, min(count - 1, index + step))
    }

    // MARK: - Plumbing

    private func focusedPane() async -> (HerdrAgent, String)? {
        guard let agent = try? await HerdrClient.focusedAgent(), let pane = agent.paneID else {
            onError?("Nothing has focus in Herdr right now.")
            return nil
        }
        return (agent, pane)
    }

    /// Slash commands go in as text plus enter: typed, then submitted.
    private func send(command: String, to pane: String) async throws {
        try await HerdrClient.sendText(paneID: pane, text: command)
        try await HerdrClient.sendKeys(paneID: pane, keys: ["enter"])
    }
}
