import XCTest
@testable import WLKit

final class HerdrTabCycleTests: XCTestCase {

    func testAdvancesToTheNextTabByNumber() {
        let tabs = [
            HerdrTab(tabID: "t1", number: 1, focused: true),
            HerdrTab(tabID: "t2", number: 2),
            HerdrTab(tabID: "t3", number: 3),
        ]
        XCTAssertEqual(HerdrClient.nextTab(in: tabs)?.tabID, "t2")
    }

    func testWrapsFromTheLastTabToTheFirst() {
        let tabs = [
            HerdrTab(tabID: "t1", number: 1),
            HerdrTab(tabID: "t2", number: 2, focused: true),
        ]
        XCTAssertEqual(HerdrClient.nextTab(in: tabs)?.tabID, "t1")
    }

    /// `tab.list` order is not guaranteed to be display order; `number` is.
    func testCyclesInNumberOrderNotListOrder() {
        let tabs = [
            HerdrTab(tabID: "t3", number: 3),
            HerdrTab(tabID: "t1", number: 1, focused: true),
            HerdrTab(tabID: "t2", number: 2),
        ]
        XCTAssertEqual(HerdrClient.nextTab(in: tabs)?.tabID, "t2")
    }

    func testStaysInsideTheFocusedWorkspace() {
        let tabs = [
            HerdrTab(tabID: "a1", workspaceID: "a", number: 1),
            HerdrTab(tabID: "a2", workspaceID: "a", number: 2, focused: true),
            HerdrTab(tabID: "b1", workspaceID: "b", number: 1),
            HerdrTab(tabID: "b2", workspaceID: "b", number: 2),
        ]
        XCTAssertEqual(HerdrClient.nextTab(in: tabs)?.tabID, "a1")
    }

    func testSingleTabHasNowhereToGo() {
        XCTAssertNil(HerdrClient.nextTab(in: [HerdrTab(tabID: "t1", number: 1, focused: true)]))
    }

    func testNoFocusedTabDoesNothing() {
        let tabs = [
            HerdrTab(tabID: "t1", number: 1),
            HerdrTab(tabID: "t2", number: 2),
        ]
        XCTAssertNil(HerdrClient.nextTab(in: tabs))
    }
}
