import Foundation
import WLKit

/// The model list, on screen while the joystick cycles it.
///
/// Changing model from the pad is otherwise blind: the joystick fires
/// `/model <name>` at Claude or steers Codex's picker, and what comes back is a
/// numbered line in a TUI — a number you have to already know the meaning of.
/// This puts the list itself up, numbered from one, so the number in the
/// terminal has something to be read against. It closes itself a few seconds
/// after the last deflection; no key has to dismiss it.
@MainActor
final class TunePanelController {

    static let shared = TunePanelController()

    /// Long enough to read four lines and deflect again, short enough that it
    /// is gone by the time you have forgotten you asked for it. Every
    /// deflection restarts it.
    private static let linger: TimeInterval = 6

    private let panel = FloatingPanel()
    /// Bumped by every show and every hide, so a pending auto-close belonging
    /// to an earlier deflection knows it has been superseded.
    private var generation = 0

    private init() {
        panel.preferredWidth = 460
        panel.onDismissRequested = { [weak self] in self?.hide() }
    }

    /// Shows `models` numbered from one, marking `current` when we know it.
    /// Codex's list is the user's own copy of what its picker offers, so it can
    /// be empty and its selection is never ours to claim.
    func showModels(
        _ models: [String],
        current: Int?,
        agent: String,
        hint: String
    ) {
        panel.present()
        panel.render(
            title: "Model",
            subtitle: agent,
            body: Self.list(models, current: current),
            footer: hint
        )
        scheduleHide()
    }

    func hide() {
        generation += 1
        panel.close()
    }

    private func scheduleHide() {
        generation += 1
        let generation = generation
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.linger * 1_000_000_000))
            guard let self, self.generation == generation else { return }
            self.panel.close()
        }
    }

    /// One row per model, in a `pre` so the numbers line up under each other
    /// however long the names are. The current row is marked twice — a caret
    /// and bold — because a glance from the keyboard catches weight before it
    /// catches a glyph.
    private static func list(_ models: [String], current: Int?) -> String {
        guard !models.isEmpty else {
            return PanelHTML.note(
                "No model list configured for this agent. Add one to "
                + PanelHTML.abbreviate(KeyBindings.configPath())
                + " to see it here."
            )
        }
        let pad = String(models.count).count
        let rows = models.enumerated().map { index, name -> String in
            let number = String(index + 1)
            let text = AnsiHTML.escapeHTML(
                (index == current ? "▸ " : "  ")
                + String(repeating: " ", count: pad - number.count) + number
                + "  " + name
            )
            return index == current ? "<span class=\"b\">\(text)</span>" : text
        }
        return "<pre>\(rows.joined(separator: "\n"))</pre>"
    }
}
