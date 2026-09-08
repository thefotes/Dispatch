import XCTest
@testable import WLKit

/// `HerdrProvider`'s cross-machine dial seam, tested against a fake
/// `HerdrServicing` rather than a live socket — the boundary math here
/// decides which machine a dial turn lands on, and the empty-list case in
/// particular must report "nothing here" rather than absorb the turn and
/// wedge the dial on a machine with nothing to focus.
final class HerdrProviderStepTests: XCTestCase {

    /// A `HerdrServicing` that replays canned lists and records focuses.
    private final class FakeHerdr: HerdrServicing, @unchecked Sendable {
        var agents: [HerdrAgent] = []
        var workspaces: [HerdrWorkspace] = []
        private(set) var focusedAgents: [String] = []
        private(set) var focusedWorkspaces: [String] = []

        func listAgents(timeout: TimeInterval) async throws -> [HerdrAgent] { agents }
        func listWorkspaces() async throws -> [HerdrWorkspace] { workspaces }
        func focusAgent(_ target: String) async throws { focusedAgents.append(target) }
        func focusWorkspace(_ workspaceID: String) async throws { focusedWorkspaces.append(workspaceID) }
        func focusedAgent() async throws -> HerdrAgent? { agents.first(where: \.focused) }
        func focusedPaneID() async throws -> String? { nil }
        func focusPane(direction: HerdrClient.PaneDirection) async throws {}
        func createWorkspace() async throws {}
        func cycleTabs(_ step: Int) async throws {}
        func splitPane(direction: String) async throws {}
        func sendText(paneID: String, text: String) async throws {}
        func sendKeys(paneID: String, keys: [String]) async throws {}
    }

    private func agent(_ pane: String, focused: Bool = false) -> HerdrAgent {
        HerdrAgent(status: "idle", paneID: pane, focused: focused)
    }

    private func space(_ id: String, _ number: Int, focused: Bool = false) -> HerdrWorkspace {
        HerdrWorkspace(workspaceID: id, number: number, focused: focused)
    }

    private func makeProvider(_ fake: FakeHerdr) -> HerdrProvider {
        HerdrProvider(options: .init(), client: fake)
    }

    // MARK: - stepWithinMachine: agent

    func testSteppingForwardFocusesTheNextAgent() async throws {
        let fake = FakeHerdr()
        fake.agents = [agent("p1", focused: true), agent("p2"), agent("p3")]
        let landed = try await makeProvider(fake).stepWithinMachine(1, mode: "agent")
        XCTAssertTrue(landed)
        XCTAssertEqual(fake.focusedAgents, ["p2"])
    }

    func testSteppingOffTheAgentEndReportsExhausted() async throws {
        let fake = FakeHerdr()
        fake.agents = [agent("p1"), agent("p2", focused: true)]
        let landed = try await makeProvider(fake).stepWithinMachine(1, mode: "agent")
        XCTAssertFalse(landed, "off the end is the spill signal, not a wrap")
        XCTAssertTrue(fake.focusedAgents.isEmpty)
    }

    func testSteppingBackwardOffTheAgentStartReportsExhausted() async throws {
        let fake = FakeHerdr()
        fake.agents = [agent("p1", focused: true), agent("p2")]
        let landed = try await makeProvider(fake).stepWithinMachine(-1, mode: "agent")
        XCTAssertFalse(landed)
        XCTAssertTrue(fake.focusedAgents.isEmpty)
    }

    /// An agent with neither pane id nor terminal id cannot be focused;
    /// it must not be mistaken for the end of the list — the walk skips
    /// it and focuses the next addressable agent.
    func testAnUnfocusableAgentMidListIsSkipped() async throws {
        let fake = FakeHerdr()
        fake.agents = [agent("p1", focused: true),
                       HerdrAgent(status: "idle", focused: false),
                       agent("p3")]
        let landed = try await makeProvider(fake).stepWithinMachine(1, mode: "agent")
        XCTAssertTrue(landed)
        XCTAssertEqual(fake.focusedAgents, ["p3"])
    }

    /// Nothing focused means the turn is entering this machine: the first
    /// (or last) agent is focused — but an empty list reports "nothing
    /// here" rather than a success that focused nothing, which would
    /// absorb the turn and wedge the dial.
    func testEnteringWithNoFocusedAgentLandsOnItsFirst() async throws {
        let fake = FakeHerdr()
        fake.agents = [agent("p1"), agent("p2")]
        let landed = try await makeProvider(fake).stepWithinMachine(1, mode: "agent")
        XCTAssertTrue(landed)
        XCTAssertEqual(fake.focusedAgents, ["p1"])
    }

    func testEnteringWithNoFocusedAgentBackwardLandsOnItsLast() async throws {
        let fake = FakeHerdr()
        fake.agents = [agent("p1"), agent("p2")]
        let landed = try await makeProvider(fake).stepWithinMachine(-1, mode: "agent")
        XCTAssertTrue(landed)
        XCTAssertEqual(fake.focusedAgents, ["p2"])
    }

    func testAnEmptyAgentListReportsNothingHere() async throws {
        let fake = FakeHerdr()
        let landed = try await makeProvider(fake).stepWithinMachine(1, mode: "agent")
        XCTAssertFalse(landed, "an empty list must not read as a successful entry")
        XCTAssertTrue(fake.focusedAgents.isEmpty)
    }

    // MARK: - stepWithinMachine: space

    func testSteppingForwardFocusesTheNextWorkspaceByNumber() async throws {
        let fake = FakeHerdr()
        fake.workspaces = [space("w1", 1, focused: true), space("w2", 2)]
        let landed = try await makeProvider(fake).stepWithinMachine(1, mode: "space")
        XCTAssertTrue(landed)
        XCTAssertEqual(fake.focusedWorkspaces, ["w2"])
    }

    func testSteppingOffTheWorkspaceEndReportsExhausted() async throws {
        let fake = FakeHerdr()
        fake.workspaces = [space("w1", 1, focused: true)]
        let landed = try await makeProvider(fake).stepWithinMachine(1, mode: "space")
        XCTAssertFalse(landed)
        XCTAssertTrue(fake.focusedWorkspaces.isEmpty)
    }

    func testAnEmptyWorkspaceListReportsNothingHere() async throws {
        let fake = FakeHerdr()
        let landed = try await makeProvider(fake).stepWithinMachine(1, mode: "space")
        XCTAssertFalse(landed)
        XCTAssertTrue(fake.focusedWorkspaces.isEmpty)
    }

    func testEnteringWithNoFocusedWorkspaceLandsOnItsFirst() async throws {
        let fake = FakeHerdr()
        fake.workspaces = [space("w1", 1), space("w2", 2)]
        let landed = try await makeProvider(fake).stepWithinMachine(1, mode: "space")
        XCTAssertTrue(landed)
        XCTAssertEqual(fake.focusedWorkspaces, ["w1"])
    }

    // MARK: - landFromOtherMachine

    func testLandingForwardFocusesTheFirstWorkspace() async throws {
        let fake = FakeHerdr()
        fake.workspaces = [space("w1", 1), space("w2", 2)]
        let landed = try await makeProvider(fake).landFromOtherMachine(1, mode: "space")
        XCTAssertTrue(landed)
        XCTAssertEqual(fake.focusedWorkspaces, ["w1"])
    }

    func testLandingBackwardFocusesTheLastAgent() async throws {
        let fake = FakeHerdr()
        fake.agents = [agent("p1"), agent("p2")]
        let landed = try await makeProvider(fake).landFromOtherMachine(-1, mode: "agent")
        XCTAssertTrue(landed)
        XCTAssertEqual(fake.focusedAgents, ["p2"])
    }

    /// The wedge the review caught: an empty list must report "nothing
    /// here" so the routing layer walks past, not "landed" with nothing
    /// focused — which would make this machine active and absorb every
    /// later turn.
    func testLandingOnAnEmptyListReportsNothingHere() async throws {
        let fake = FakeHerdr()
        let provider = makeProvider(fake)
        let agents = try await provider.landFromOtherMachine(1, mode: "agent")
        let spaces = try await provider.landFromOtherMachine(1, mode: "space")
        XCTAssertFalse(agents)
        XCTAssertFalse(spaces)
        XCTAssertTrue(fake.focusedAgents.isEmpty)
        XCTAssertTrue(fake.focusedWorkspaces.isEmpty)
    }

    func testLandingOnAListWithOnlyUnfocusableAgentsReportsNothingHere() async throws {
        let fake = FakeHerdr()
        fake.agents = [HerdrAgent(status: "idle")]
        let landed = try await makeProvider(fake).landFromOtherMachine(1, mode: "agent")
        XCTAssertFalse(landed)
        XCTAssertTrue(fake.focusedAgents.isEmpty)
    }

    func testAnUnrecognizedModeReportsNothingHere() async throws {
        let fake = FakeHerdr()
        let landed = try await makeProvider(fake).landFromOtherMachine(1, mode: "effort")
        XCTAssertFalse(landed)
    }
}
