import Foundation

public enum RotationDirection: String, Codable, Hashable, Sendable {
    case clockwise
    case counterclockwise
}

/// A gesture matcher used by configuration. Associated event values remain available
/// to diagnostics but are deliberately not an expression language for arguments.
public enum GesturePattern: Hashable, Sendable {
    case pressed
    case released
    case rotated(direction: RotationDirection?)
    case moved(direction: Direction?)

    public func matches(_ gesture: Gesture) -> Bool {
        switch (self, gesture) {
        case (.pressed, .pressed), (.released, .released):
            true
        case let (.rotated(expected), .rotated(steps)):
            steps != 0 && (expected == nil || expected == (steps > 0 ? .clockwise : .counterclockwise))
        case let (.moved(expected), .moved(actual, _)):
            expected == nil || expected == actual
        default:
            false
        }
    }

    func overlaps(_ other: GesturePattern) -> Bool {
        switch (self, other) {
        case (.pressed, .pressed), (.released, .released):
            true
        case let (.rotated(left), .rotated(right)):
            left == nil || right == nil || left == right
        case let (.moved(left), .moved(right)):
            left == nil || right == nil || left == right
        default:
            false
        }
    }
}

extension GesturePattern: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case direction
    }

    private enum Kind: String, Codable {
        case pressed
        case released
        case rotated
        case moved
    }

    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(["type", "direction"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .type)
        switch kind {
        case .pressed:
            guard !container.contains(.direction) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .direction,
                    in: container,
                    debugDescription: "A pressed pattern cannot have a direction."
                )
            }
            self = .pressed
        case .released:
            guard !container.contains(.direction) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .direction,
                    in: container,
                    debugDescription: "A released pattern cannot have a direction."
                )
            }
            self = .released
        case .rotated:
            self = .rotated(
                direction: try container.decodeIfPresent(RotationDirection.self, forKey: .direction)
            )
        case .moved:
            self = .moved(
                direction: try container.decodeIfPresent(Direction.self, forKey: .direction)
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pressed:
            try container.encode(Kind.pressed, forKey: .type)
        case .released:
            try container.encode(Kind.released, forKey: .type)
        case let .rotated(direction):
            try container.encode(Kind.rotated, forKey: .type)
            try container.encodeIfPresent(direction, forKey: .direction)
        case let .moved(direction):
            try container.encode(Kind.moved, forKey: .type)
            try container.encodeIfPresent(direction, forKey: .direction)
        }
    }
}

public struct EventPattern: Codable, Hashable, Sendable {
    public let control: LogicalControl
    public let gesture: GesturePattern

    public init(control: LogicalControl, gesture: GesturePattern) {
        self.control = control
        self.gesture = gesture
    }

    public func matches(_ event: DispatchEvent) -> Bool {
        control == event.control && gesture.matches(event.gesture)
    }

    private enum CodingKeys: String, CodingKey {
        case control
        case gesture
    }

    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(["control", "gesture"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        control = try container.decode(LogicalControl.self, forKey: .control)
        gesture = try container.decode(GesturePattern.self, forKey: .gesture)
    }
}

public struct ConfiguredAction: Codable, Equatable, Sendable {
    public let id: ActionID
    public let arguments: [String: JSONValue]

    public init(id: ActionID, arguments: [String: JSONValue] = [:]) {
        self.id = id
        self.arguments = arguments
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case arguments
    }

    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(["id", "arguments"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ActionID.self, forKey: .id)
        arguments = try container.decodeIfPresent(
            [String: JSONValue].self,
            forKey: .arguments
        ) ?? [:]
    }
}

public struct BindingDefinition: Codable, Equatable, Sendable {
    public let event: EventPattern
    public let actions: [ConfiguredAction]

    public init(event: EventPattern, actions: [ConfiguredAction]) {
        self.event = event
        self.actions = actions
    }

    private enum CodingKeys: String, CodingKey {
        case event = "when"
        case actions
    }

    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(["when", "actions"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        event = try container.decode(EventPattern.self, forKey: .event)
        actions = try container.decode([ConfiguredAction].self, forKey: .actions)
    }
}

/// How the menu names each agent row.
public enum AgentLabelStyle: String, Codable, Equatable, Sendable {
    /// The agent's workspace and kind, such as "Dispatch · claude".
    case workspaceAndAgent
    /// The title the agent program sets for its terminal.
    case terminalTitle
}

public struct DispatchConfiguration: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let bindings: [BindingDefinition]
    public let statusPalette: StatusPalette?
    public let agentLabel: AgentLabelStyle?
    /// Fixed lights for controls. A provider's live state, such as an agent's
    /// status on a slot key, is drawn over them.
    public let lights: [ControlLight]?
    /// Integration-owned settings; each integration validates its own entries.
    public let integrations: [String: JSONValue]?

    public init(
        version: Int = currentVersion,
        bindings: [BindingDefinition],
        statusPalette: StatusPalette? = nil,
        agentLabel: AgentLabelStyle? = nil,
        lights: [ControlLight]? = nil,
        integrations: [String: JSONValue]? = nil
    ) {
        self.version = version
        self.bindings = bindings
        self.statusPalette = statusPalette
        self.agentLabel = agentLabel
        self.lights = lights
        self.integrations = integrations
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case bindings
        case statusPalette
        case agentLabel
        case lights
        case integrations
    }

    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys([
            "version", "bindings", "statusPalette", "agentLabel", "lights", "integrations"
        ])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        bindings = try container.decode([BindingDefinition].self, forKey: .bindings)
        statusPalette = try container.decodeIfPresent(StatusPalette.self, forKey: .statusPalette)
        agentLabel = try container.decodeIfPresent(AgentLabelStyle.self, forKey: .agentLabel)
        lights = try container.decodeIfPresent([ControlLight].self, forKey: .lights)
        if let lights {
            var seen = Set<LogicalControl>()
            for (index, light) in lights.enumerated() where !seen.insert(light.control).inserted {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: container.codingPath + [CodingKeys.lights, AnyCodingKey(intValue: index)!],
                    debugDescription: "\(light.control) already has a light. Give each control one entry."
                ))
            }
        }
        integrations = try container.decodeIfPresent([String: JSONValue].self, forKey: .integrations)
    }
}

public enum ConfigurationError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
    case emptyMacro(binding: Int)
    case ambiguousBindings(first: Int, second: Int)
    case unsupportedAction(binding: Int, action: Int, id: ActionID)
    case missingArgument(binding: Int, action: Int, name: String)
    case unknownArgument(binding: Int, action: Int, name: String)
    case invalidArgumentType(
        binding: Int,
        action: Int,
        name: String,
        expected: ActionArgumentType
    )
}

public struct CompiledBindings: Sendable {
    struct Entry: Sendable {
        let pattern: EventPattern
        let actions: [ActionInvocation]
    }

    let entriesByControl: [LogicalControl: [Entry]]

    public static func compile(
        _ configuration: DispatchConfiguration,
        catalog: ActionCatalog
    ) throws -> CompiledBindings {
        guard configuration.version == DispatchConfiguration.currentVersion else {
            throw ConfigurationError.unsupportedVersion(configuration.version)
        }
        try validateUnambiguous(configuration.bindings)

        var indexed: [LogicalControl: [Entry]] = [:]
        for (bindingIndex, binding) in configuration.bindings.enumerated() {
            guard !binding.actions.isEmpty else {
                throw ConfigurationError.emptyMacro(binding: bindingIndex)
            }
            let actions = try binding.actions.enumerated().map { actionIndex, action in
                try validate(
                    action,
                    bindingIndex: bindingIndex,
                    actionIndex: actionIndex,
                    catalog: catalog
                )
            }
            indexed[binding.event.control, default: []].append(
                Entry(pattern: binding.event, actions: actions)
            )
        }
        return CompiledBindings(entriesByControl: indexed)
    }

    private static func validateUnambiguous(_ bindings: [BindingDefinition]) throws {
        for firstIndex in bindings.indices {
            for secondIndex in bindings.indices where secondIndex > firstIndex {
                let first = bindings[firstIndex].event
                let second = bindings[secondIndex].event
                if first.control == second.control, first.gesture.overlaps(second.gesture) {
                    throw ConfigurationError.ambiguousBindings(
                        first: firstIndex,
                        second: secondIndex
                    )
                }
            }
        }
    }

    private static func validate(
        _ action: ConfiguredAction,
        bindingIndex: Int,
        actionIndex: Int,
        catalog: ActionCatalog
    ) throws -> ActionInvocation {
        do {
            return try catalog.makeInvocation(id: action.id, arguments: action.arguments)
        } catch let error as ActionValidationError {
            switch error {
            case let .unsupportedAction(id):
                throw ConfigurationError.unsupportedAction(
                    binding: bindingIndex,
                    action: actionIndex,
                    id: id
                )
            case let .missingArgument(name):
                throw ConfigurationError.missingArgument(
                    binding: bindingIndex,
                    action: actionIndex,
                    name: name
                )
            case let .unknownArgument(name):
                throw ConfigurationError.unknownArgument(
                    binding: bindingIndex,
                    action: actionIndex,
                    name: name
                )
            case let .invalidArgumentType(name, expected):
                throw ConfigurationError.invalidArgumentType(
                    binding: bindingIndex,
                    action: actionIndex,
                    name: name,
                    expected: expected
                )
            }
        }
    }
}

public struct BindingResolver: Sendable {
    public let bindings: CompiledBindings

    public init(bindings: CompiledBindings) {
        self.bindings = bindings
    }

    public func resolve(_ event: DispatchEvent) -> [ActionInvocation] {
        bindings.entriesByControl[event.control]?
            .first(where: { $0.pattern.matches(event) })?
            .actions ?? []
    }
}
