import DispatchCore
import Foundation

/// Herdr protocol 22 request and snapshot codec, derived from `herdr api schema`.
public struct HerdrProtocol22Codec: HerdrWireActionEncoding {
    public init() {}

    public func request(for action: HerdrAction) throws -> [String: JSONValue] {
        switch action {
        case .focusAgentSlot, .closeFocusedPane, .cycleTab, .splitFocusedPane, .cycleText, .sendFocusedKeys:
            throw HerdrProtocol22Error.semanticActionRequiresState
        case .cycleAgent, .cycleWorkspace:
            throw HerdrProtocol22Error.clientActionHasNoRequest
        case let .focusAgent(target):
            request(method: "agent.focus", params: ["target": .string(target)])
        case let .closePane(id):
            request(method: "pane.close", params: ["pane_id": .string(id)])
        case let .focusPane(direction, paneID):
            request(
                method: "pane.focus_direction",
                params: [
                    "direction": .string(direction.rawValue),
                    "pane_id": paneID.map(JSONValue.string) ?? .null
                ]
            )
        case let .focusTab(id):
            request(method: "tab.focus", params: ["tab_id": .string(id)])
        case .createWorkspace:
            request(method: "workspace.create", params: ["focus": .boolean(true)])
        case let .splitPane(id, direction):
            request(method: "pane.split", params: [
                "target_pane_id": .string(id),
                "direction": .string(direction.rawValue),
                "focus": .boolean(true)
            ])
        case let .sendText(paneID, text):
            request(method: "pane.send_text", params: ["pane_id": .string(paneID), "text": .string(text)])
        case let .sendKeys(paneID, keys):
            request(method: "pane.send_keys", params: [
                "pane_id": .string(paneID),
                "keys": .array(keys.map(JSONValue.string))
            ])
        }
    }

    public func readPaneRequest(paneID: String) -> [String: JSONValue] {
        request(method: "pane.read", params: ["pane_id": .string(paneID), "source": .string("visible")])
    }

    public func decodePaneText(from response: [String: JSONValue]) throws -> String {
        guard case let .object(result)? = response["result"],
              case let .object(read)? = result["read"],
              case let .string(text)? = read["text"] else {
            throw HerdrProtocol22Error.invalidPaneReadResponse
        }
        return text
    }

    public func snapshotRequest() -> [String: JSONValue] {
        request(method: "session.snapshot", params: [:])
    }

    public func decodeSnapshot(from response: [String: JSONValue]) throws -> HerdrSnapshot {
        guard case let .object(result)? = response["result"],
              result["type"] == .string("session_snapshot"),
              let snapshot = result["snapshot"] else {
            throw HerdrProtocol22Error.invalidSnapshotResponse
        }
        let data = try JSONEncoder().encode(snapshot)
        return try JSONDecoder().decode(HerdrSnapshot.self, from: data)
    }

    private func request(method: String, params: [String: JSONValue]) -> [String: JSONValue] {
        ["method": .string(method), "params": .object(params)]
    }
}

public enum HerdrProtocol22Error: Error, Sendable, Equatable {
    case invalidSnapshotResponse
    case invalidPaneReadResponse
    case semanticActionRequiresState
    /// Herdr's window, not its server, carries out the action.
    case clientActionHasNoRequest
}
