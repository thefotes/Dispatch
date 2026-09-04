import XCTest
@testable import WLKit

/// The dial's `agent` and `space` modes: step the focused agent or workspace
/// one place along, wrapping, in whichever direction the encoder turned.
final class HerdrAgentCycleTests: XCTestCase {

    private func agent(_ pane: String, focused: Bool = false) -> HerdrAgent {
        HerdrAgent(status: "idle", paneID: pane, focused: focused)
    }

    func testAdvancesToTheNextAgentInListOrder() {
        let agents = [agent("p1", focused: true), agent("p2"), agent("p3")]
        XCTAssertEqual(HerdrClient.adjacentAgent(in: agents, step: 1)?.paneID, "p2")
    }

    func testStepsBackwardWithANegativeStep() {
        let agents = [agent("p1"), agent("p2", focused: true), agent("p3")]
        XCTAssertEqual(HerdrClient.adjacentAgent(in: agents, step: -1)?.paneID, "p1")
    }

    func testWrapsForwardPastTheEnd() {
        let agents = [agent("p1"), agent("p2"), agent("p3", focused: true)]
        XCTAssertEqual(HerdrClient.adjacentAgent(in: agents, step: 1)?.paneID, "p1")
    }

    func testWrapsBackwardPastTheStart() {
        let agents = [agent("p1", focused: true), agent("p2")]
        XCTAssertEqual(HerdrClient.adjacentAgent(in: agents, step: -1)?.paneID, "p2")
    }

    /// `agent.list` order is sidebar order and is never re-sorted; the ids here
    /// are deliberately out of alphabetical order to prove it.
    func testKeepsListOrderAndNeverResorts() {
        let agents = [agent("z"), agent("a", focused: true), agent("m")]
        XCTAssertEqual(HerdrClient.adjacentAgent(in: agents, step: 1)?.paneID, "m")
    }

    func testNoFocusedAgentDoesNothing() {
        XCTAssertNil(HerdrClient.adjacentAgent(in: [agent("p1"), agent("p2")], step: 1))
    }

    func testASingleAgentHasNowhereToGo() {
        XCTAssertNil(HerdrClient.adjacentAgent(in: [agent("p1", focused: true)], step: 1))
    }

    func testEmptyListIsSafe() {
        XCTAssertNil(HerdrClient.adjacentAgent(in: [], step: 1))
    }
}

final class HerdrWorkspaceCycleTests: XCTestCase {

    func testAdvancesToTheNextWorkspaceByNumber() {
        let spaces = [
            HerdrWorkspace(workspaceID: "w1", number: 1, focused: true),
            HerdrWorkspace(workspaceID: "w2", number: 2),
            HerdrWorkspace(workspaceID: "w3", number: 3),
        ]
        XCTAssertEqual(HerdrClient.adjacentWorkspace(in: spaces, step: 1)?.workspaceID, "w2")
    }

    func testStepsBackwardWithANegativeStep() {
        let spaces = [
            HerdrWorkspace(workspaceID: "w1", number: 1),
            HerdrWorkspace(workspaceID: "w2", number: 2, focused: true),
        ]
        XCTAssertEqual(HerdrClient.adjacentWorkspace(in: spaces, step: -1)?.workspaceID, "w1")
    }

    func testWrapsFromTheLastWorkspaceToTheFirst() {
        let spaces = [
            HerdrWorkspace(workspaceID: "w1", number: 1),
            HerdrWorkspace(workspaceID: "w2", number: 2, focused: true),
        ]
        XCTAssertEqual(HerdrClient.adjacentWorkspace(in: spaces, step: 1)?.workspaceID, "w1")
    }

    /// `workspace.list` order is not guaranteed to be display order; `number` is.
    func testCyclesInNumberOrderNotListOrder() {
        let spaces = [
            HerdrWorkspace(workspaceID: "w3", number: 3),
            HerdrWorkspace(workspaceID: "w1", number: 1, focused: true),
            HerdrWorkspace(workspaceID: "w2", number: 2),
        ]
        XCTAssertEqual(HerdrClient.adjacentWorkspace(in: spaces, step: 1)?.workspaceID, "w2")
    }

    func testNoFocusedWorkspaceDoesNothing() {
        let spaces = [
            HerdrWorkspace(workspaceID: "w1", number: 1),
            HerdrWorkspace(workspaceID: "w2", number: 2),
        ]
        XCTAssertNil(HerdrClient.adjacentWorkspace(in: spaces, step: 1))
    }

    func testASingleWorkspaceHasNowhereToGo() {
        let spaces = [HerdrWorkspace(workspaceID: "w1", number: 1, focused: true)]
        XCTAssertNil(HerdrClient.adjacentWorkspace(in: spaces, step: 1))
    }
}
