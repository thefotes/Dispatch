import Darwin
import Dispatch
import DispatchCore
import DispatchProviders
import Foundation
import XCTest

final class HerdrIntegrationTests: XCTestCase {
    func testDefinitionsRemainHerdrNamespaced() {
        XCTAssertEqual(
            HerdrActions.definitions.map(\.id.rawValue),
            [
                "herdr.agent.focusSlot",
                "herdr.agent.focus",
                "herdr.pane.closeFocused",
                "herdr.pane.close",
                "herdr.tab.cycle",
                "herdr.pane.focusDirection",
                "herdr.tab.focus",
                "herdr.agent.cycle",
                "herdr.workspace.cycle",
                "herdr.workspace.create",
                "herdr.pane.splitFocused",
                "herdr.pane.cycleText"
            ]
        )
    }

    func testDecodesTypedHerdrActions() throws {
        XCTAssertEqual(
            try HerdrActions.decode(invocation(
                id: "herdr.pane.focusDirection",
                arguments: ["direction": .string("left"), "paneID": .string("pane-7")]
            )),
            .focusPane(direction: .left, fromPaneID: "pane-7")
        )
        XCTAssertEqual(
            try HerdrActions.decode(invocation(
                id: "herdr.agent.focus",
                arguments: ["target": .string("agent-1")]
            )),
            .focusAgent(target: "agent-1")
        )
        XCTAssertEqual(
            try HerdrActions.decode(invocation(id: "herdr.pane.close", arguments: ["paneID": .string("pane-1")])),
            .closePane(id: "pane-1")
        )
    }

    func testDecodesWorkspaceSplitAndTextCycleActions() throws {
        XCTAssertEqual(try HerdrActions.decode(invocation(id: "herdr.workspace.create")), .createWorkspace)
        XCTAssertEqual(
            try HerdrActions.decode(invocation(
                id: "herdr.pane.splitFocused", arguments: ["direction": .string("right")]
            )),
            .splitFocusedPane(direction: .right)
        )
        XCTAssertEqual(
            try HerdrActions.decode(invocation(
                id: "herdr.pane.cycleText",
                arguments: ["options": .array([.string("claude"), .string("codex")])]
            )),
            .cycleText(options: ["claude", "codex"])
        )
        XCTAssertThrowsError(try HerdrActions.decode(invocation(
            id: "herdr.pane.splitFocused", arguments: ["direction": .string("left")]
        )))
        XCTAssertThrowsError(try HerdrActions.decode(invocation(
            id: "herdr.pane.cycleText", arguments: ["options": .array([])]
        )))
        XCTAssertThrowsError(try HerdrActions.decode(invocation(
            id: "herdr.pane.cycleText", arguments: ["options": .array([.integer(1)])]
        )))
    }

    func testRejectsInvalidHerdrArgumentsAndForeignActions() throws {
        XCTAssertThrowsError(try HerdrActions.decode(invocation(id: "herdr.agent.focus"))) { error in
            XCTAssertEqual(
                error as? HerdrIntegrationError,
                .missingArgument(action: HerdrActions.focusAgent, name: "target")
            )
        }
        XCTAssertThrowsError(try HerdrActions.decode(invocation(id: "keyboard.shortcut")))
    }

    func testRecordingControllerNeverContactsExternalProcess() async throws {
        let controller = RecordingHerdrController(initialState: .init(availability: .available))
        await controller.execute(.focusTab(id: "tab-2"))
        await controller.execute(.focusPane(direction: .right, fromPaneID: "pane-a"))
        let actions = await controller.actions()
        XCTAssertEqual(actions, [.focusTab(id: "tab-2"), .focusPane(direction: .right, fromPaneID: "pane-a")])

        let stream = await controller.states()
        var iterator = stream.makeAsyncIterator()
        let state = await iterator.next()
        XCTAssertEqual(state?.availability, .available)
    }

    func testRegistrationsExecuteThroughRecordingBoundary() async throws {
        let controller = RecordingHerdrController(initialState: .init(availability: .available))
        let registry = try ActionRegistry(registrations: HerdrActions.registrations(controller: controller))
        try await registry.execute(invocation(id: "herdr.pane.close", arguments: ["paneID": .string("pane-1")]))
        let actions = await controller.actions()
        XCTAssertEqual(actions, [.closePane(id: "pane-1")])
    }

    func testRegistrationsReportDisconnectedControllerAsUnavailable() async throws {
        let controller = RecordingHerdrController()
        let registry = try ActionRegistry(registrations: HerdrActions.registrations(controller: controller))
        do {
            try await registry.execute(invocation(id: "herdr.tab.focus", arguments: ["tabID": .string("tab-1")]))
            XCTFail("Expected unavailable action")
        } catch let error as ActionExecutionError {
            XCTAssertEqual(error, .unavailable(HerdrActions.focusTab))
        }
    }

    func testProtocol22CodecProducesDocumentedRequests() throws {
        let codec = HerdrProtocol22Codec()
        XCTAssertEqual(try codec.request(for: .focusAgent(target: "agent-a")), [
            "method": .string("agent.focus"),
            "params": .object(["target": .string("agent-a")])
        ])
        XCTAssertEqual(try codec.request(for: .closePane(id: "pane-a")), [
            "method": .string("pane.close"),
            "params": .object(["pane_id": .string("pane-a")])
        ])
        XCTAssertEqual(try codec.request(for: .focusPane(direction: .down, fromPaneID: nil)), [
            "method": .string("pane.focus_direction"),
            "params": .object(["direction": .string("down"), "pane_id": .null])
        ])
        XCTAssertEqual(try codec.request(for: .focusTab(id: "tab-a")), [
            "method": .string("tab.focus"),
            "params": .object(["tab_id": .string("tab-a")])
        ])
        XCTAssertEqual(try codec.request(for: .createWorkspace), [
            "method": .string("workspace.create"),
            "params": .object(["focus": .boolean(true)])
        ])
        XCTAssertEqual(try codec.request(for: .splitPane(id: "pane-a", direction: .right)), [
            "method": .string("pane.split"),
            "params": .object([
                "target_pane_id": .string("pane-a"),
                "direction": .string("right"),
                "focus": .boolean(true)
            ])
        ])
        XCTAssertEqual(try codec.request(for: .sendText(paneID: "pane-a", text: "codex")), [
            "method": .string("pane.send_text"),
            "params": .object(["pane_id": .string("pane-a"), "text": .string("codex")])
        ])
        XCTAssertEqual(try codec.request(for: .sendKeys(paneID: "pane-a", keys: ["backspace"])), [
            "method": .string("pane.send_keys"),
            "params": .object(["pane_id": .string("pane-a"), "keys": .array([.string("backspace")])])
        ])
        XCTAssertEqual(codec.readPaneRequest(paneID: "pane-a"), [
            "method": .string("pane.read"),
            "params": .object(["pane_id": .string("pane-a"), "source": .string("visible")])
        ])
        XCTAssertEqual(
            try codec.decodePaneText(from: ["result": .object([
                "type": .string("pane_read"),
                "read": .object(["text": .string("$ claude\n")])
            ])]),
            "$ claude\n"
        )
        XCTAssertEqual(codec.snapshotRequest(), [
            "method": .string("session.snapshot"),
            "params": .object([:])
        ])
    }

    func testSemanticActionsReportMissingOrOutOfBoundsState() throws {
        let state = HerdrState(availability: .available)

        XCTAssertThrowsError(try resolveFromCurrentState(.focusAgentSlot(1), state: state)) {
            XCTAssertEqual($0 as? HerdrIntegrationError, .slotOutOfBounds(slot: 1, available: 0))
        }
        XCTAssertThrowsError(try resolveFromCurrentState(.closeFocusedPane, state: state)) {
            XCTAssertEqual($0 as? HerdrIntegrationError, .unavailableState("Herdr has no focused pane."))
        }
        XCTAssertThrowsError(try resolveFromCurrentState(.cycleTab(delta: 1), state: state)) {
            XCTAssertEqual($0 as? HerdrIntegrationError, .unavailableState("Herdr has no tabs."))
        }
    }

    func testSemanticActionsResolveAgainstCurrentOrderedState() throws {
        let state = HerdrState(
            availability: .available,
            tabs: [
                .init(id: "tab-1", label: "One", focused: false),
                .init(id: "tab-2", label: "Two", focused: true),
                .init(id: "tab-3", label: "Three", focused: false)
            ],
            agents: [
                .init(paneID: "pane-1", name: "alpha", status: "idle", focused: false),
                .init(paneID: "pane-2", name: nil, status: "working", focused: true)
            ],
            focusedPaneID: "pane-2",
            focusedTabID: "tab-2"
        )

        XCTAssertEqual(
            try resolveFromCurrentState(.focusAgentSlot(1), state: state),
            .focusAgent(target: "alpha")
        )
        XCTAssertEqual(
            try resolveFromCurrentState(.focusAgentSlot(2), state: state),
            .focusAgent(target: "pane-2")
        )
        XCTAssertEqual(
            try resolveFromCurrentState(.closeFocusedPane, state: state),
            .closePane(id: "pane-2")
        )
        XCTAssertEqual(
            try resolveFromCurrentState(.cycleTab(delta: 1), state: state),
            .focusTab(id: "tab-3")
        )
        XCTAssertEqual(
            try resolveFromCurrentState(.cycleTab(delta: -1), state: state),
            .focusTab(id: "tab-1")
        )
    }

    func testSplitResolvesAgainstTheFocusedPane() throws {
        let focused = HerdrState(availability: .available, focusedPaneID: "pane-2")
        XCTAssertEqual(
            try resolveFromCurrentState(.splitFocusedPane(direction: .right), state: focused),
            .splitPane(id: "pane-2", direction: .right)
        )
        XCTAssertThrowsError(try resolveFromCurrentState(
            .splitFocusedPane(direction: .down), state: HerdrState(availability: .available)
        ))
    }

    func testProtocol22CodecDecodesSessionSnapshot() throws {
        let codec = HerdrProtocol22Codec()
        let response: [String: JSONValue] = [
            "id": .string("request-id"),
            "result": .object([
                "type": .string("session_snapshot"),
                "snapshot": .object([
                    "version": .string("0.9.1"),
                    "protocol": .integer(22),
                    "focused_pane_id": .string("pane-1"),
                    "focused_tab_id": .string("tab-1"),
                    "panes": .array([.object([
                        "pane_id": .string("pane-1"),
                        "title": .string("Editor")
                    ])]),
                    "tabs": .array([.object([
                        "tab_id": .string("tab-1"),
                        "label": .string("Main"),
                        "focused": .boolean(true)
                    ])]),
                    "agents": .array([.object([
                        "pane_id": .string("pane-1"),
                        "agent": .string("codex"),
                        "terminal_title": .string("Codex | Fix the build"),
                        "terminal_title_stripped": .string("Fix the build"),
                        "agent_status": .string("working"),
                        "workspace_id": .string("w1"),
                        "focused": .boolean(true)
                    ])])
                ])
            ])
        ]
        let snapshot = try codec.decodeSnapshot(from: response)
        XCTAssertEqual(snapshot.protocolVersion, 22)
        XCTAssertEqual(snapshot.focusedPaneID, "pane-1")
        XCTAssertEqual(snapshot.panes, [.init(id: "pane-1", title: "Editor")])
        XCTAssertEqual(snapshot.tabs, [.init(id: "tab-1", label: "Main", focused: true)])
        XCTAssertEqual(
            snapshot.agents,
            [.init(
                paneID: "pane-1",
                name: nil,
                terminalTitle: "Fix the build",
                agentKind: "codex",
                workspaceID: "w1",
                status: "working",
                focused: true
            )]
        )
    }

    func testAgentLabelsUseWorkspaceAndAgentKindOrTerminalTitle() throws {
        let codec = HerdrProtocol22Codec()
        let response: [String: JSONValue] = [
            "id": .string("request-id"),
            "result": .object([
                "type": .string("session_snapshot"),
                "snapshot": .object([
                    "version": .string("0.9.1"),
                    "protocol": .integer(22),
                    "panes": .array([]),
                    "tabs": .array([]),
                    "workspaces": .array([.object([
                        "workspace_id": .string("w1"),
                        "number": .integer(1),
                        "label": .string("Dispatch"),
                        "focused": .boolean(true)
                    ])]),
                    "agents": .array([
                        .object([
                            "pane_id": .string("w1:p1"),
                            "agent": .string("claude"),
                            "terminal_title_stripped": .string("Fix the build"),
                            "agent_status": .string("idle"),
                            "workspace_id": .string("w1"),
                            "focused": .boolean(false)
                        ]),
                        .object([
                            "pane_id": .string("w2:p1"),
                            "agent": .string("codex"),
                            "agent_status": .string("idle"),
                            "workspace_id": .string("w2"),
                            "focused": .boolean(false)
                        ]),
                        .object([
                            "pane_id": .string("w2:p2"),
                            "agent_status": .string("idle"),
                            "focused": .boolean(false)
                        ])
                    ])
                ])
            ])
        ]
        let snapshot = try codec.decodeSnapshot(from: response)
        let state = HerdrState(
            availability: .available,
            workspaces: snapshot.workspaces ?? [],
            agents: snapshot.agents
        )

        XCTAssertEqual(
            snapshot.agents.map { state.label(for: $0, style: .workspaceAndAgent) },
            ["Dispatch · claude", "codex", "w2:p2"]
        )
        XCTAssertEqual(
            snapshot.agents.map { state.label(for: $0, style: .terminalTitle) },
            ["Fix the build", "codex", "w2:p2"]
        )
    }

    func testHerdrErrorsDescribeThemselvesReadably() {
        XCTAssertEqual(
            String(describing: HerdrIntegrationError.unavailableState("Herdr has no focused pane.")),
            "Herdr has no focused pane."
        )
        XCTAssertEqual(
            String(describing: HerdrIntegrationError.slotOutOfBounds(slot: 7, available: 6)),
            "Agent slot 7 is empty; Herdr has 6 agents."
        )
        XCTAssertEqual(String(describing: HerdrSocketError.disconnected), "Herdr closed the connection.")
        XCTAssertEqual(
            String(describing: HerdrAPIError.remote(code: "not_found", message: "No pane")),
            "Herdr rejected the request: No pane (not_found)"
        )
    }

    private func invocation(id: String, arguments: [String: JSONValue] = [:]) throws -> ActionInvocation {
        let data = try JSONEncoder().encode(InvocationPayload(id: id, arguments: arguments))
        return try JSONDecoder().decode(ActionInvocation.self, from: data)
    }
}

private struct InvocationPayload: Encodable {
    let id: String
    let arguments: [String: JSONValue]
}

/// Resolves an action the adapter must resolve against a press-time snapshot,
/// failing when `plan(for:)` does not classify it that way.
private func resolveFromCurrentState(_ action: HerdrAction, state: HerdrState) throws -> HerdrAction {
    guard case let .fromCurrentState(resolve) = HerdrSemanticResolver.plan(for: action) else {
        XCTFail("\(action) should resolve against Herdr's current state")
        return action
    }
    return try resolve(state)
}
