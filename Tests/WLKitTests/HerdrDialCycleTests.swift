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
            HerdrWorkspace(workspaceID: "w3", number: 3)
        ]
        XCTAssertEqual(HerdrClient.adjacentWorkspace(in: spaces, step: 1)?.workspaceID, "w2")
    }

    func testStepsBackwardWithANegativeStep() {
        let spaces = [
            HerdrWorkspace(workspaceID: "w1", number: 1),
            HerdrWorkspace(workspaceID: "w2", number: 2, focused: true)
        ]
        XCTAssertEqual(HerdrClient.adjacentWorkspace(in: spaces, step: -1)?.workspaceID, "w1")
    }

    func testWrapsFromTheLastWorkspaceToTheFirst() {
        let spaces = [
            HerdrWorkspace(workspaceID: "w1", number: 1),
            HerdrWorkspace(workspaceID: "w2", number: 2, focused: true)
        ]
        XCTAssertEqual(HerdrClient.adjacentWorkspace(in: spaces, step: 1)?.workspaceID, "w1")
    }

    /// `workspace.list` order is not guaranteed to be display order; `number` is.
    func testCyclesInNumberOrderNotListOrder() {
        let spaces = [
            HerdrWorkspace(workspaceID: "w3", number: 3),
            HerdrWorkspace(workspaceID: "w1", number: 1, focused: true),
            HerdrWorkspace(workspaceID: "w2", number: 2)
        ]
        XCTAssertEqual(HerdrClient.adjacentWorkspace(in: spaces, step: 1)?.workspaceID, "w2")
    }

    func testNoFocusedWorkspaceDoesNothing() {
        let spaces = [
            HerdrWorkspace(workspaceID: "w1", number: 1),
            HerdrWorkspace(workspaceID: "w2", number: 2)
        ]
        XCTAssertNil(HerdrClient.adjacentWorkspace(in: spaces, step: 1))
    }

    func testASingleWorkspaceHasNowhereToGo() {
        let spaces = [HerdrWorkspace(workspaceID: "w1", number: 1, focused: true)]
        XCTAssertNil(HerdrClient.adjacentWorkspace(in: spaces, step: 1))
    }
}

/// The non-wrapping twins the cross-machine dial is built on: nil here is
/// the spill signal that sends the turn to the next machine, so the
/// boundary cases — off either end, single element, empty list, nothing
/// focused — are exactly what must not silently wrap.
final class SteppedAgentTests: XCTestCase {

    private func agent(_ pane: String, focused: Bool = false) -> HerdrAgent {
        HerdrAgent(status: "idle", paneID: pane, focused: focused)
    }

    func testAdvancesToTheNextAgentInListOrder() {
        let agents = [agent("p1", focused: true), agent("p2"), agent("p3")]
        XCTAssertEqual(HerdrClient.steppedAgent(in: agents, step: 1)?.paneID, "p2")
    }

    func testStepsBackwardWithANegativeStep() {
        let agents = [agent("p1"), agent("p2", focused: true), agent("p3")]
        XCTAssertEqual(HerdrClient.steppedAgent(in: agents, step: -1)?.paneID, "p1")
    }

    func testSteppingOffTheEndReturnsNilInsteadOfWrapping() {
        let agents = [agent("p1"), agent("p2"), agent("p3", focused: true)]
        XCTAssertNil(HerdrClient.steppedAgent(in: agents, step: 1),
                     "off the end must read as exhausted, not wrap to the first")
    }

    func testSteppingBackwardOffTheStartReturnsNilInsteadOfWrapping() {
        let agents = [agent("p1", focused: true), agent("p2")]
        XCTAssertNil(HerdrClient.steppedAgent(in: agents, step: -1))
    }

    func testKeepsListOrderAndNeverResorts() {
        let agents = [agent("z"), agent("a", focused: true), agent("m")]
        XCTAssertEqual(HerdrClient.steppedAgent(in: agents, step: 1)?.paneID, "m")
    }

    func testNoFocusedAgentReturnsNil() {
        XCTAssertNil(HerdrClient.steppedAgent(in: [agent("p1"), agent("p2")], step: 1))
    }

    func testASingleFocusedAgentReturnsNilBothWays() {
        XCTAssertNil(HerdrClient.steppedAgent(in: [agent("p1", focused: true)], step: 1))
        XCTAssertNil(HerdrClient.steppedAgent(in: [agent("p1", focused: true)], step: -1))
    }

    func testEmptyListIsSafe() {
        XCTAssertNil(HerdrClient.steppedAgent(in: [], step: 1))
        XCTAssertNil(HerdrClient.steppedAgent(in: [], step: -1))
    }
}

final class SteppedWorkspaceTests: XCTestCase {

    private func space(_ id: String, _ number: Int, focused: Bool = false) -> HerdrWorkspace {
        HerdrWorkspace(workspaceID: id, number: number, focused: focused)
    }

    func testAdvancesToTheNextWorkspaceByNumber() {
        let spaces = [space("w1", 1, focused: true), space("w2", 2), space("w3", 3)]
        XCTAssertEqual(HerdrClient.steppedWorkspace(in: spaces, step: 1)?.workspaceID, "w2")
    }

    func testSortsByNumberNotListOrder() {
        let spaces = [space("w9", 9, focused: true), space("w1", 1), space("w5", 5)]
        XCTAssertEqual(HerdrClient.steppedWorkspace(in: spaces, step: -1)?.workspaceID, "w5")
    }

    func testSteppingOffTheEndReturnsNilInsteadOfWrapping() {
        let spaces = [space("w1", 1), space("w2", 2, focused: true)]
        XCTAssertNil(HerdrClient.steppedWorkspace(in: spaces, step: 1))
    }

    func testSteppingBackwardOffTheStartReturnsNilInsteadOfWrapping() {
        let spaces = [space("w1", 1, focused: true), space("w2", 2)]
        XCTAssertNil(HerdrClient.steppedWorkspace(in: spaces, step: -1))
    }

    func testNoFocusedWorkspaceReturnsNil() {
        XCTAssertNil(HerdrClient.steppedWorkspace(in: [space("w1", 1), space("w2", 2)], step: 1))
    }

    func testASingleFocusedWorkspaceReturnsNilBothWays() {
        let spaces = [space("w1", 1, focused: true)]
        XCTAssertNil(HerdrClient.steppedWorkspace(in: spaces, step: 1))
        XCTAssertNil(HerdrClient.steppedWorkspace(in: spaces, step: -1))
    }

    func testEmptyListIsSafe() {
        XCTAssertNil(HerdrClient.steppedWorkspace(in: [], step: 1))
        XCTAssertNil(HerdrClient.steppedWorkspace(in: [], step: -1))
    }
}
