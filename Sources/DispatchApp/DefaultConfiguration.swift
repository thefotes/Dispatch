import DispatchCore
import DispatchCreatorMicro
import DispatchMacOS
import DispatchProviders

enum DefaultConfiguration {
    static let value = DispatchConfiguration(
        bindings: agentBindings + otherBindings,
        statusPalette: HerdrPresentationRenderer.defaultPalette,
        lights: [
            // Close pane, in red, and the voice key, in purple.
            ControlLight(
                control: .key(9),
                appearance: ControlAppearance(color: RGBColor(red: 210, green: 55, blue: 70), brightness: 0.45)
            ),
            ControlLight(
                control: .key(10),
                appearance: ControlAppearance(color: RGBColor(red: 145, green: 90, blue: 255), brightness: 0.55)
            )
        ]
    )

    private static let agentBindings: [BindingDefinition] =
        CreatorMicroGeometry.initialAgentSlots.enumerated().map { slot, key in
            binding(
                control: .key(key),
                gesture: .pressed,
                action: HerdrActions.focusAgentSlot,
                arguments: ["slot": .integer(slot + 1)]
            )
        }

    private static let otherBindings: [BindingDefinition] = [
        binding(
            control: .dial,
            gesture: .rotated(direction: .clockwise),
            action: HerdrActions.cycleWorkspace,
            arguments: ["delta": .integer(1)]
        ),
        binding(
            control: .dial,
            gesture: .rotated(direction: .counterclockwise),
            action: HerdrActions.cycleWorkspace,
            arguments: ["delta": .integer(-1)]
        ),
        directionalBinding(.up),
        directionalBinding(.down),
        directionalBinding(.left),
        directionalBinding(.right),
        binding(
            control: .key(6),
            gesture: .pressed,
            action: HerdrActions.createWorkspace
        ),
        binding(
            control: .key(7),
            gesture: .pressed,
            action: HerdrActions.splitFocusedPane,
            arguments: ["direction": .string("right")]
        ),
        binding(
            control: .key(8),
            gesture: .pressed,
            action: HerdrActions.cycleText,
            arguments: ["options": .array([.string("claude"), .string("codex"), .string("opencode")])]
        ),
        binding(
            control: .key(9),
            gesture: .pressed,
            action: HerdrActions.closeFocusedPane
        ),
        binding(
            control: .key(10),
            gesture: .pressed,
            action: MacOSActions.shortcut,
            arguments: ["key": .string(KeyboardKey.rightCommand.rawValue)]
        )
    ]

    private static func directionalBinding(_ direction: Direction) -> BindingDefinition {
        binding(
            control: .joystick,
            gesture: .moved(direction: direction),
            action: HerdrActions.focusPaneDirection,
            arguments: ["direction": .string(direction.rawValue)]
        )
    }

    private static func binding(
        control: LogicalControl,
        gesture: GesturePattern,
        action: ActionID,
        arguments: [String: JSONValue] = [:]
    ) -> BindingDefinition {
        BindingDefinition(
            event: EventPattern(control: control, gesture: gesture),
            actions: [ConfiguredAction(id: action, arguments: arguments)]
        )
    }
}
