import DispatchCore
import DispatchProviders
import Foundation
import XCTest

final class HerdrSlotOrderTests: XCTestCase {
    private let triage = ["blocked", "done", "working", "unknown", "idle"]

    func testAgentsTakeSlotsByStatusPriorityThenHerdrOrder() async throws {
        let client = SnapshotHerdrClient(agents: [
            ("a", "idle"), ("b", "working"), ("c", "blocked"), ("d", "done"),
            ("e", "idle"), ("f", "blocked"), ("g", "stalled")
        ])
        let adapter = HerdrAdapter(client: client, encoder: HerdrProtocol22Codec(), slotPriority: triage)

        try await adapter.refresh()

        let panes = await currentState(of: adapter).agents.map(\.paneID)
        XCTAssertEqual(panes, ["c", "f", "d", "b", "g", "a", "e"])
    }

    func testSlotsBeyondTheFirstSixCanStillReachAnUrgentAgent() async throws {
        let idle = (1...10).map { ("idle-\($0)", "idle") }
        let client = SnapshotHerdrClient(agents: idle + [("late", "working")])
        let adapter = HerdrAdapter(client: client, encoder: HerdrProtocol22Codec(), slotPriority: triage)

        try await adapter.execute(.focusAgentSlot(1))

        let focused = await client.focusTargets()
        XCTAssertEqual(focused, ["late"])
    }

    func testChangingThePriorityReordersWithoutAnotherRefresh() async throws {
        let client = SnapshotHerdrClient(agents: [("a", "working"), ("b", "done")])
        let adapter = HerdrAdapter(client: client, encoder: HerdrProtocol22Codec(), slotPriority: triage)
        try await adapter.refresh()
        let requestsAfterRefresh = await client.requestCount

        await adapter.setSlotPriority(["working", "done"])

        let panes = await currentState(of: adapter).agents.map(\.paneID)
        XCTAssertEqual(panes, ["a", "b"])
        let requestsAfterChange = await client.requestCount
        XCTAssertEqual(requestsAfterChange, requestsAfterRefresh)
    }

    func testStatusesMissingFromAPriorityWithoutUnknownRankLast() async throws {
        let client = SnapshotHerdrClient(agents: [("a", "stalled"), ("b", "idle"), ("c", "blocked")])
        let adapter = HerdrAdapter(
            client: client,
            encoder: HerdrProtocol22Codec(),
            slotPriority: ["blocked", "idle"]
        )

        try await adapter.refresh()

        let panes = await currentState(of: adapter).agents.map(\.paneID)
        XCTAssertEqual(panes, ["c", "b", "a"])
    }

    func testAnEmptyPriorityKeepsHerdrOrder() async throws {
        let client = SnapshotHerdrClient(agents: [("a", "idle"), ("b", "blocked"), ("c", "done")])
        let adapter = HerdrAdapter(client: client, encoder: HerdrProtocol22Codec())

        try await adapter.refresh()

        let panes = await currentState(of: adapter).agents.map(\.paneID)
        XCTAssertEqual(panes, ["a", "b", "c"])
    }

    private func currentState(of adapter: HerdrAdapter) async -> HerdrState {
        var iterator = await adapter.states().makeAsyncIterator()
        return await iterator.next() ?? .disconnected
    }
}

/// Answers every snapshot with the same agents and records focus requests.
private actor SnapshotHerdrClient: HerdrConnecting {
    private let agents: [(paneID: String, status: String)]
    private var focused: [String] = []
    private(set) var requestCount = 0

    init(agents: [(String, String)]) {
        self.agents = agents
    }

    func focusTargets() -> [String] { focused }

    func request(_ body: [String: JSONValue]) async throws -> [String: JSONValue] {
        requestCount += 1
        switch body["method"] {
        case .string("session.snapshot"):
            return ["result": .object([
                "type": .string("session_snapshot"),
                "snapshot": .object([
                    "version": .string("0.9.1"),
                    "protocol": .integer(22),
                    "panes": .array([]),
                    "tabs": .array([]),
                    "agents": .array(agents.map { agent in
                        .object([
                            "pane_id": .string(agent.paneID),
                            "agent_status": .string(agent.status),
                            "focused": .boolean(false)
                        ])
                    })
                ])
            ])]
        case .string("agent.focus"):
            if case let .object(params)? = body["params"], case let .string(target)? = params["target"] {
                focused.append(target)
            }
            return ["result": .object([:])]
        default:
            return ["result": .object([:])]
        }
    }
}
