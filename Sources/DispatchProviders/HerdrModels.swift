import Foundation
import DispatchCore

public enum HerdrAction: Sendable, Equatable {
    case focusAgentSlot(Int)
    case focusAgent(target: String)
    case closeFocusedPane
    case closePane(id: String)
    case focusPane(direction: HerdrPaneDirection, fromPaneID: String?)
    case cycleTab(delta: Int)
    case focusTab(id: String)
    /// Moves through the agent list in Herdr's window, which spans every
    /// connected machine.
    case cycleAgent(delta: Int)
    /// Moves through the workspace list in Herdr's window, which spans every
    /// connected machine.
    case cycleWorkspace(delta: Int)
    case createWorkspace
    case splitFocusedPane(direction: HerdrSplitDirection)
    case splitPane(id: String, direction: HerdrSplitDirection)
    /// Types the next option into the focused pane, replacing the previous
    /// option when it is still at the end of the pane's prompt.
    case cycleText(options: [String])
    case sendText(paneID: String, text: String)
    /// Resolves Herdr's focused pane from a fresh snapshot before sending keys.
    case sendFocusedKeys(keys: [String])
    case sendKeys(paneID: String, keys: [String])

    public var identifier: String {
        switch self {
        case .focusAgentSlot: "herdr.agent.focusSlot"
        case .focusAgent: "herdr.agent.focus"
        case .closeFocusedPane: "herdr.pane.closeFocused"
        case .closePane: "herdr.pane.close"
        case .focusPane: "herdr.pane.focusDirection"
        case .cycleTab: "herdr.tab.cycle"
        case .focusTab: "herdr.tab.focus"
        case .cycleAgent: "herdr.agent.cycle"
        case .cycleWorkspace: "herdr.workspace.cycle"
        case .createWorkspace: "herdr.workspace.create"
        case .splitFocusedPane: "herdr.pane.splitFocused"
        case .splitPane: "herdr.pane.split"
        case .cycleText: "herdr.pane.cycleText"
        case .sendText: "herdr.pane.sendText"
        case .sendFocusedKeys, .sendKeys: "herdr.pane.sendKeys"
        }
    }
}

/// Herdr splits place the new pane to the right of, or below, the target.
public enum HerdrSplitDirection: String, Sendable, Equatable, Codable {
    case right
    case down
}

public enum HerdrPaneDirection: String, Sendable, Equatable, Codable {
    case left
    case right
    case up
    case down
}

public struct HerdrPane: Sendable, Equatable, Codable, Identifiable {
    public let id: String
    public let title: String?

    public init(id: String, title: String? = nil) {
        self.id = id
        self.title = title
    }

    private enum CodingKeys: String, CodingKey {
        case id = "pane_id"
        case title
    }
}

public struct HerdrAgent: Sendable, Equatable, Codable {
    public let paneID: String
    public let name: String?
    /// Herdr's `terminal_title_stripped`.
    public let terminalTitle: String?
    /// Herdr's `agent` kind, such as "claude".
    public let agentKind: String?
    public let workspaceID: String?
    public let status: String
    public let focused: Bool

    public init(
        paneID: String,
        name: String? = nil,
        terminalTitle: String? = nil,
        agentKind: String? = nil,
        workspaceID: String? = nil,
        status: String,
        focused: Bool
    ) {
        self.paneID = paneID
        self.name = name
        self.terminalTitle = terminalTitle
        self.agentKind = agentKind
        self.workspaceID = workspaceID
        self.status = status
        self.focused = focused
    }

    private enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case name
        case terminalTitle = "terminal_title_stripped"
        case agentKind = "agent"
        case workspaceID = "workspace_id"
        case status = "agent_status"
        case focused
    }
}

public struct HerdrWorkspace: Sendable, Equatable, Codable, Identifiable {
    public let id: String
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }

    private enum CodingKeys: String, CodingKey {
        case id = "workspace_id"
        case label
    }
}

public struct HerdrTab: Sendable, Equatable, Codable, Identifiable {
    public let id: String
    public let label: String
    public let focused: Bool

    public init(id: String, label: String, focused: Bool) {
        self.id = id
        self.label = label
        self.focused = focused
    }

    private enum CodingKeys: String, CodingKey {
        case id = "tab_id"
        case label
        case focused
    }
}

public struct HerdrSnapshot: Sendable, Equatable, Codable {
    public let version: String
    public let protocolVersion: Int
    public let panes: [HerdrPane]
    public let tabs: [HerdrTab]
    public let workspaces: [HerdrWorkspace]?
    public let agents: [HerdrAgent]
    public let focusedPaneID: String?
    public let focusedTabID: String?

    private enum CodingKeys: String, CodingKey {
        case version
        case protocolVersion = "protocol"
        case panes
        case tabs
        case workspaces
        case agents
        case focusedPaneID = "focused_pane_id"
        case focusedTabID = "focused_tab_id"
    }
}

public enum HerdrAvailability: String, Sendable, Equatable, Codable {
    case disconnected
    case connecting
    case available
}

public struct HerdrState: Sendable, Equatable, Codable {
    public var availability: HerdrAvailability
    public var panes: [HerdrPane]
    public var tabs: [HerdrTab]
    public var workspaces: [HerdrWorkspace]
    /// In slot order when published by `HerdrAdapter`: slot N is `agents[N - 1]`.
    public var agents: [HerdrAgent]
    public var focusedPaneID: String?
    public var focusedTabID: String?

    public init(
        availability: HerdrAvailability,
        panes: [HerdrPane] = [],
        tabs: [HerdrTab] = [],
        workspaces: [HerdrWorkspace] = [],
        agents: [HerdrAgent] = [],
        focusedPaneID: String? = nil,
        focusedTabID: String? = nil
    ) {
        self.availability = availability
        self.panes = panes
        self.tabs = tabs
        self.workspaces = workspaces
        self.agents = agents
        self.focusedPaneID = focusedPaneID
        self.focusedTabID = focusedTabID
    }

    public static let disconnected = HerdrState(availability: .disconnected)

    /// A readable row label for `agent`. Missing parts are left out, and the
    /// pane ID is the last resort.
    public func label(for agent: HerdrAgent, style: AgentLabelStyle) -> String {
        switch style {
        case .workspaceAndAgent:
            let workspace = workspaces.first { $0.id == agent.workspaceID }?.label
            let parts = [workspace, agent.agentKind].compactMap { $0 }
            return parts.isEmpty ? agent.paneID : parts.joined(separator: " · ")
        case .terminalTitle:
            return agent.terminalTitle ?? agent.agentKind ?? agent.paneID
        }
    }
}

/// Coherent substitution boundary for the Herdr integration.
public protocol HerdrControlling: Sendable {
    func execute(_ action: HerdrAction) async throws
    func states() async -> AsyncStream<HerdrState>
    func isAvailable() async -> Bool
}

/// One step through a list in Herdr's window. Herdr keeps which machine the
/// window shows in the window itself, not in any server, so only the window
/// can move between machines.
public enum HerdrClientNavigation: Sendable, Equatable {
    case nextAgent
    case previousAgent
    case nextWorkspace
    case previousWorkspace
}

/// Moves Herdr's window. Herdr 0.9.1 has no API for this, so the production
/// implementation drives the window's own key bindings; a Herdr API can
/// replace it without changing any binding.
public protocol HerdrClientNavigating: Sendable {
    func navigate(_ step: HerdrClientNavigation) async throws
}

/// Encodes Herdr actions without baking an undocumented wire schema into Dispatch.
/// A concrete codec should be added when the Herdr request contract is documented.
public protocol HerdrWireActionEncoding: Sendable {
    func request(for action: HerdrAction) throws -> [String: JSONValue]
    func snapshotRequest() -> [String: JSONValue]
    func decodeSnapshot(from response: [String: JSONValue]) throws -> HerdrSnapshot
    func readPaneRequest(paneID: String) -> [String: JSONValue]
    func decodePaneText(from response: [String: JSONValue]) throws -> String
}

public enum HerdrIntegrationError: Error, Sendable, Equatable {
    case unsupportedAction(ActionID)
    case missingArgument(action: ActionID, name: String)
    case invalidArgument(action: ActionID, name: String)
    case unavailableState(String)
    case slotOutOfBounds(slot: Int, available: Int)
}

extension HerdrIntegrationError: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .unsupportedAction(id): "Herdr does not support \(id.rawValue)."
        case let .missingArgument(action, name): "\(action.rawValue) is missing argument \(name)."
        case let .invalidArgument(action, name): "\(action.rawValue) has an invalid argument \(name)."
        case let .unavailableState(message): message
        case let .slotOutOfBounds(slot, available): "Agent slot \(slot) is empty; Herdr has \(available) agents."
        }
    }
}

public enum HerdrActions {
    public static let focusAgentSlot: ActionID = "herdr.agent.focusSlot"
    public static let focusAgent: ActionID = "herdr.agent.focus"
    public static let closeFocusedPane: ActionID = "herdr.pane.closeFocused"
    public static let closePane: ActionID = "herdr.pane.close"
    public static let focusPaneDirection: ActionID = "herdr.pane.focusDirection"
    public static let cycleTab: ActionID = "herdr.tab.cycle"
    public static let focusTab: ActionID = "herdr.tab.focus"
    public static let cycleAgent: ActionID = "herdr.agent.cycle"
    public static let cycleWorkspace: ActionID = "herdr.workspace.cycle"
    public static let createWorkspace: ActionID = "herdr.workspace.create"
    public static let splitFocusedPane: ActionID = "herdr.pane.splitFocused"
    public static let cycleText: ActionID = "herdr.pane.cycleText"
    public static let sendKeys: ActionID = "herdr.pane.sendKeys"

    public static let definitions: [ActionDefinition] = [
        ActionDefinition(
            id: focusAgentSlot,
            title: "Focus Herdr Agent Slot",
            summary: "Focuses a one-based agent slot. Agents take slots by status priority, most urgent first.",
            arguments: [.init(name: "slot", type: .integer, summary: "One-based agent slot.")]
        ),
        ActionDefinition(
            id: focusAgent,
            title: "Focus Herdr Agent",
            summary: "Focuses the Herdr agent matching a target.",
            arguments: [.init(name: "target", type: .string, summary: "Herdr agent target.")]
        ),
        ActionDefinition(
            id: closeFocusedPane,
            title: "Close Focused Herdr Pane",
            summary: "Closes the pane currently focused in Herdr."
        ),
        ActionDefinition(
            id: closePane,
            title: "Close Herdr Pane",
            summary: "Closes the specified Herdr pane.",
            arguments: [.init(name: "paneID", type: .string, summary: "Herdr pane identifier.")]
        ),
        ActionDefinition(
            id: cycleTab,
            title: "Cycle Herdr Tab",
            summary: "Moves through Herdr's current ordered tab list by a signed delta.",
            arguments: [.init(name: "delta", type: .integer, summary: "Signed tab offset.")]
        ),
        ActionDefinition(
            id: focusPaneDirection,
            title: "Focus Herdr Pane Direction",
            summary: "Moves pane focus in a direction, optionally from a specified pane.",
            arguments: [
                .init(name: "direction", type: .string, summary: "left, right, up, or down."),
                .init(name: "paneID", type: .string, required: false, summary: "Optional starting pane identifier.")
            ]
        ),
        ActionDefinition(
            id: focusTab,
            title: "Focus Herdr Tab",
            summary: "Focuses the specified Herdr tab.",
            arguments: [.init(name: "tabID", type: .string, summary: "Herdr tab identifier.")]
        ),
        ActionDefinition(
            id: cycleAgent,
            title: "Cycle Herdr Agent",
            summary: "Moves through the agents in Herdr's window, across all connected machines, by a delta.",
            arguments: [.init(name: "delta", type: .integer, summary: "Signed, nonzero agent offset.")]
        ),
        ActionDefinition(
            id: cycleWorkspace,
            title: "Cycle Herdr Workspace",
            summary: "Moves through the workspaces in Herdr's window, across all connected machines, by a delta.",
            arguments: [.init(name: "delta", type: .integer, summary: "Signed, nonzero workspace offset.")]
        ),
        ActionDefinition(
            id: createWorkspace,
            title: "Create Herdr Workspace",
            summary: "Creates a Herdr workspace and focuses it."
        ),
        ActionDefinition(
            id: splitFocusedPane,
            title: "Split Focused Herdr Pane",
            summary: "Splits the focused Herdr pane and focuses the new pane.",
            arguments: [.init(name: "direction", type: .string, summary: "right (side by side) or down (stacked).")]
        ),
        ActionDefinition(
            id: cycleText,
            title: "Cycle Text in Focused Herdr Pane",
            summary: "Types the next option into the focused pane, replacing the option typed by the previous press.",
            arguments: [.init(name: "options", type: .array, summary: "Non-empty array of strings to cycle through.")]
        ),
        ActionDefinition(
            id: sendKeys,
            title: "Send Keys to Herdr Pane",
            summary: "Sends terminal keys over Herdr's socket to an explicit pane or the currently focused pane.",
            arguments: [
                .init(name: "keys", type: .array, summary: "Non-empty array of Herdr key-combo strings, in order."),
                .init(name: "paneID", type: .string, required: false, summary: "Omit to use Herdr's focused pane.")
            ]
        )
    ]

    public static func decode(_ invocation: ActionInvocation) throws -> HerdrAction {
        switch invocation.id {
        case focusAgentSlot:
            return .focusAgentSlot(try integer("slot", in: invocation))
        case focusAgent:
            return .focusAgent(target: try string("target", in: invocation))
        case closeFocusedPane:
            return .closeFocusedPane
        case closePane:
            return .closePane(id: try string("paneID", in: invocation))
        case focusPaneDirection:
            let rawDirection = try string("direction", in: invocation)
            guard let direction = HerdrPaneDirection(rawValue: rawDirection) else {
                throw HerdrIntegrationError.invalidArgument(action: invocation.id, name: "direction")
            }
            return .focusPane(direction: direction, fromPaneID: try optionalString("paneID", in: invocation))
        case cycleTab:
            return .cycleTab(delta: try integer("delta", in: invocation))
        case focusTab:
            return .focusTab(id: try string("tabID", in: invocation))
        default:
            return try decodeWorkspaceAction(invocation)
        }
    }

    private static func decodeWorkspaceAction(_ invocation: ActionInvocation) throws -> HerdrAction {
        switch invocation.id {
        case cycleAgent:
            return .cycleAgent(delta: try nonzeroInteger("delta", in: invocation))
        case cycleWorkspace:
            return .cycleWorkspace(delta: try nonzeroInteger("delta", in: invocation))
        case createWorkspace:
            return .createWorkspace
        case splitFocusedPane:
            guard let direction = HerdrSplitDirection(rawValue: try string("direction", in: invocation)) else {
                throw HerdrIntegrationError.invalidArgument(action: invocation.id, name: "direction")
            }
            return .splitFocusedPane(direction: direction)
        case cycleText:
            return .cycleText(options: try nonEmptyStrings("options", in: invocation))
        case sendKeys:
            let keys = try nonEmptyStrings("keys", in: invocation)
            if let paneID = try optionalString("paneID", in: invocation) {
                guard !paneID.isEmpty else {
                    throw HerdrIntegrationError.invalidArgument(action: invocation.id, name: "paneID")
                }
                return .sendKeys(paneID: paneID, keys: keys)
            }
            return .sendFocusedKeys(keys: keys)
        default:
            throw HerdrIntegrationError.unsupportedAction(invocation.id)
        }
    }

    public static func registrations(controller: any HerdrControlling) -> [ActionRegistration] {
        definitions.map { definition in
            ActionRegistration(
                definition: definition,
                isAvailable: { await controller.isAvailable() },
                handler: { invocation in
                    try await controller.execute(decode(invocation))
                }
            )
        }
    }

    private static func string(_ name: String, in invocation: ActionInvocation) throws -> String {
        guard let value = invocation.arguments[name] else {
            throw HerdrIntegrationError.missingArgument(action: invocation.id, name: name)
        }
        guard case let .string(value) = value else {
            throw HerdrIntegrationError.invalidArgument(action: invocation.id, name: name)
        }
        return value
    }

    private static func optionalString(_ name: String, in invocation: ActionInvocation) throws -> String? {
        guard let value = invocation.arguments[name] else { return nil }
        guard case let .string(value) = value else {
            throw HerdrIntegrationError.invalidArgument(action: invocation.id, name: name)
        }
        return value
    }

    private static func nonEmptyStrings(_ name: String, in invocation: ActionInvocation) throws -> [String] {
        guard let value = invocation.arguments[name] else {
            throw HerdrIntegrationError.missingArgument(action: invocation.id, name: name)
        }
        guard case let .array(items) = value, !items.isEmpty else {
            throw HerdrIntegrationError.invalidArgument(action: invocation.id, name: name)
        }
        return try items.map { item in
            guard case let .string(text) = item, !text.isEmpty else {
                throw HerdrIntegrationError.invalidArgument(action: invocation.id, name: name)
            }
            return text
        }
    }

    private static func nonzeroInteger(_ name: String, in invocation: ActionInvocation) throws -> Int {
        let value = try integer(name, in: invocation)
        guard value != 0 else {
            throw HerdrIntegrationError.invalidArgument(action: invocation.id, name: name)
        }
        return value
    }

    private static func integer(_ name: String, in invocation: ActionInvocation) throws -> Int {
        guard let value = invocation.arguments[name] else {
            throw HerdrIntegrationError.missingArgument(action: invocation.id, name: name)
        }
        guard case let .integer(value) = value else {
            throw HerdrIntegrationError.invalidArgument(action: invocation.id, name: name)
        }
        return value
    }
}
