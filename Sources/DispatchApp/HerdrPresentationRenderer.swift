import DispatchCore
import DispatchCreatorMicro
import DispatchProviders

/// The keys that show each Herdr agent slot, read from the bindings: a key
/// shows slot N when pressing it runs `herdr.agent.focusSlot` for slot N. So
/// the lights stay on the keys that focus the agents they show, whichever
/// keys the user binds.
struct HerdrSlotKeys: Equatable, Sendable {
    /// Keys by one-based slot. A slot may be bound to several keys.
    let keysBySlot: [Int: [Int]]

    init(_ configuration: DispatchConfiguration) {
        var keysBySlot: [Int: [Int]] = [:]
        for binding in configuration.bindings where binding.event.gesture == .pressed {
            guard case let .key(key) = binding.event.control else { continue }
            let slots = binding.actions.compactMap { action -> Int? in
                guard action.id == HerdrActions.focusAgentSlot,
                      case let .integer(slot)? = action.arguments["slot"] else { return nil }
                return slot
            }
            for slot in Set(slots) {
                keysBySlot[slot, default: []].append(key)
            }
        }
        self.keysBySlot = keysBySlot
    }

    /// The first key bound to the agent at `index` in slot order, for labels.
    func key(forAgentAt index: Int) -> Int? {
        keysBySlot[index + 1]?.min()
    }
}

struct HerdrPresentationRenderer: Sendable {
    private static let unknownFallback = ControlAppearance(
        color: RGBColor(red: 255, green: 175, blue: 35),
        brightness: 0.7
    )
    static let defaultPalette = StatusPalette(
        appearances: [
            "blocked": ControlAppearance(
                color: RGBColor(red: 255, green: 45, blue: 65),
                effect: .breath,
                speed: 0.4
            ),
            "done": ControlAppearance(color: RGBColor(red: 55, green: 220, blue: 105)),
            "working": ControlAppearance(
                color: RGBColor(red: 30, green: 145, blue: 255),
                effect: .shallowBreath,
                speed: 0.25
            ),
            "unknown": unknownFallback,
            "idle": ControlAppearance(
                color: RGBColor(red: 120, green: 135, blue: 150),
                brightness: 0.3
            )
        ],
        ambientPriority: ["blocked", "done", "working", "unknown", "idle"]
    )

    /// Configured lights come first; an agent's status replaces the light of
    /// each key bound to its slot. The underglow shows the most urgent agent,
    /// whether or not it has a key.
    func render(
        _ state: HerdrState,
        configuration: DispatchConfiguration = DefaultConfiguration.value
    ) -> PadPresentation {
        let palette = configuration.statusPalette ?? Self.defaultPalette
        var controls: [LogicalControl: ControlAppearance] = [:]
        for light in configuration.lights ?? [] {
            controls[light.control] = light.appearance
        }
        let slotKeys = HerdrSlotKeys(configuration)
        for (index, agent) in state.agents.enumerated() {
            for key in slotKeys.keysBySlot[index + 1] ?? [] {
                controls[.key(key)] = appearance(for: agent.status, palette: palette)
            }
        }
        let ambient = state.agents
            .map(\.status)
            .min(by: { priority(for: $0, palette: palette) < priority(for: $1, palette: palette) })
            .map { appearance(for: $0, palette: palette) }
        return PadPresentation(controls: controls, ambient: ambient)
    }

    private func appearance(for status: String, palette: StatusPalette) -> ControlAppearance {
        palette.appearances[status]
            ?? palette.appearances["unknown"]
            ?? Self.unknownFallback
    }

    private func priority(for status: String, palette: StatusPalette) -> Int {
        palette.ambientPriority.firstIndex(of: status)
            ?? palette.ambientPriority.firstIndex(of: "unknown")
            ?? palette.ambientPriority.count
    }
}
