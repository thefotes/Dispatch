import Foundation
import WLKit

/// The dial and joystick: effort and model for whichever agent has focus.
///
/// Claude Code takes orders directly — `/effort <level>` and `/model <name>`
/// are commands, so the dial climbs an effort ladder and the joystick cycles
/// a model list, both configurable. Codex has bindable effort commands but
/// only a picker for models, so its dial sends the chords bound in
/// `[tui.keymap]` and its joystick drives the `/model` picker: north opens
/// it, north/south move, east confirms, west cancels.
///
/// Either way the joystick is working a list you cannot see from the pad, so
/// every deflection also puts that list on screen — see `TunePanelController`.
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

    /// Where each Claude pane sits on the effort ladder and model list. Blind
    /// state: it starts at the defaults and follows our own commands, so a
    /// change made by hand inside the session drifts it until the next nudge.
    private var claudeEffortIndex: [String: Int] = [:]
    private var claudeModelIndex: [String: Int] = [:]

    /// The codex pane whose `/model` picker we opened, if any. Deflections
    /// steer the picker only while this is fresh; a stale entry means the
    /// picker was dealt with by hand.
    private var codexPickerPane: String?
    private var codexPickerOpened: Date?
    private static let pickerLifetime: TimeInterval = 30

    // MARK: - Dial: effort

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

    // MARK: - Joystick: model

    func handleJoystick(_ direction: Pad.JoystickDirection) {
        Task { await joystick(direction) }
    }

    private func joystick(_ direction: Pad.JoystickDirection) async {
        guard let (agent, pane) = await focusedPane() else { return }
        let kind = agent.agent.lowercased()
        do {
            if kind.contains("claude") {
                try await claudeModel(direction, pane: pane, agent: agent.shortName)
            } else if kind.contains("codex") {
                try await codexModel(direction, pane: pane, agent: agent.shortName)
            } else {
                onError?("No model control for \(agent.agent).")
            }
        } catch {
            onError?(error.localizedDescription)
        }
    }

    /// Models cycle with wraparound — unlike effort, a list of names has no
    /// natural top or bottom.
    private func claudeModel(
        _ direction: Pad.JoystickDirection,
        pane: String,
        agent: String
    ) async throws {
        let models = bindings().claudeModels
        let step: Int
        switch direction {
        case .north: step = -1
        case .south: step = 1
        case .east, .west: return
        }
        let index = ((claudeModelIndex[pane] ?? 0) + step + models.count) % models.count
        claudeModelIndex[pane] = index
        // Up before the command goes out: the panel is the answer to "what did
        // I just land on", and waiting for the TUI to echo would show it late.
        TunePanelController.shared.showModels(
            models,
            current: index,
            agent: agent,
            hint: "north and south cycle the list"
        )
        try await send(command: "/model \(models[index])", to: pane)
    }

    private func codexModel(
        _ direction: Pad.JoystickDirection,
        pane: String,
        agent: String
    ) async throws {
        let pickerOpen = codexPickerPane == pane
            && Date().timeIntervalSince(codexPickerOpened ?? .distantPast) < Self.pickerLifetime

        guard pickerOpen else {
            // Any vertical deflection opens the picker; the rest is steering.
            guard direction == .north || direction == .south else { return }
            try await send(command: "/model", to: pane)
            codexPickerPane = pane
            codexPickerOpened = Date()
            showCodexModels(agent: agent)
            return
        }

        switch direction {
        case .north:
            try await HerdrClient.sendKeys(paneID: pane, keys: ["up"])
            showCodexModels(agent: agent)
        case .south:
            try await HerdrClient.sendKeys(paneID: pane, keys: ["down"])
            showCodexModels(agent: agent)
        case .east:
            try await HerdrClient.sendKeys(paneID: pane, keys: ["enter"])
            codexPickerPane = nil
            TunePanelController.shared.hide()
        case .west:
            try await HerdrClient.sendKeys(paneID: pane, keys: ["esc"])
            codexPickerPane = nil
            TunePanelController.shared.hide()
        }
        codexPickerOpened = Date()
    }

    /// Codex's picker is its own; we push arrow keys at it without being told
    /// where the cursor sits, so the panel is a numbered reading of the list
    /// and nothing is marked as current.
    private func showCodexModels(agent: String) {
        TunePanelController.shared.showModels(
            bindings().codexModels,
            current: nil,
            agent: agent,
            hint: "north and south move · east confirms · west cancels"
        )
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
