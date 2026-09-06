import XCTest
@testable import WLKit

/// Pins `HerdrProvider.describe()` to `BridgeConfig`'s own hardcoded
/// defaults — the two are independently defined, so the numbers here must
/// match `StatusMapper`'s literals exactly, not just "look reasonable," or
/// the pad repaints differently depending on which one wins.
final class HerdrProviderTests: XCTestCase {

    func testDescribesTheSameStatePaletteBridgeConfigUsedToHardcode() async {
        let description = await HerdrProvider().describe()
        let cfg = BridgeConfig()
        for state in ["blocked", "working", "done", "idle", "unknown"] {
            XCTAssertEqual(description.statePalette[state]?.color, cfg.colors[state], state)
            XCTAssertEqual(description.statePalette[state]?.effect, cfg.effects[state], state)
        }
    }

    func testDescribesTheSameStatePriorityBridgeConfigUsedToHardcode() async {
        let description = await HerdrProvider().describe()
        XCTAssertEqual(description.statePriority, BridgeConfig().priority)
    }

    /// "effort" is a Micromanager feature, never a provider one.
    func testDialModesNeverIncludeEffort() async {
        let description = await HerdrProvider().describe()
        XCTAssertFalse(description.dialModes.map(\.id).contains("effort"))
    }

    func testDialModesAreAgentTabAndSpace() async {
        let description = await HerdrProvider().describe()
        XCTAssertEqual(Set(description.dialModes.map(\.id)), ["agent", "tab", "space"])
    }

    /// Agent and space bring the terminal forward, the way an agent key
    /// does; tab stays within the pane you are already looking at.
    func testAgentAndSpaceRaiseTheHostButTabDoesNot() async {
        let modes = await HerdrProvider().describe().dialModes
        XCTAssertEqual(modes.first { $0.id == "agent" }?.raisesHost, true)
        XCTAssertEqual(modes.first { $0.id == "space" }?.raisesHost, true)
        XCTAssertEqual(modes.first { $0.id == "tab" }?.raisesHost, false)
    }

    /// `perform`'s ids and the dial's are the provider's own vocabulary; pin
    /// the action set so a rename can't silently orphan a `{"action": ...}`
    /// binding.
    func testActionsAreWorkspaceSplitAndCycle() async {
        let ids = await HerdrProvider().describe().actions.map(\.id)
        XCTAssertEqual(ids, ["new_workspace", "split_pane", "cycle_prompt"])
    }

    // MARK: - Prompt-tool cycle

    private let tools = ["opencode", "claude", "codex"]

    func testFirstPressTypesTheFirstToolAndErasesNothing() {
        let (previous, next) = HerdrProvider.plannedCycle(
            paneID: "p1", tools: tools, lastPaneID: nil, lastTool: nil)
        XCTAssertNil(previous)
        XCTAssertEqual(next, "opencode")
    }

    func testASecondPressInTheSamePaneAdvancesAndErasesThePrevious() {
        let (previous, next) = HerdrProvider.plannedCycle(
            paneID: "p1", tools: tools, lastPaneID: "p1", lastTool: "opencode")
        XCTAssertEqual(previous, "opencode")
        XCTAssertEqual(next, "claude")
    }

    func testTheCycleWrapsPastTheEndOfTheList() {
        let (previous, next) = HerdrProvider.plannedCycle(
            paneID: "p1", tools: tools, lastPaneID: "p1", lastTool: "codex")
        XCTAssertEqual(previous, "codex")
        XCTAssertEqual(next, "opencode")
    }

    /// Focus moved since the last press: the other pane's text is not ours
    /// to backspace, so this press erases nothing and starts at the front.
    func testAPressInADifferentPaneErasesNothingAndStartsOver() {
        let (previous, next) = HerdrProvider.plannedCycle(
            paneID: "p2", tools: tools, lastPaneID: "p1", lastTool: "claude")
        XCTAssertNil(previous)
        XCTAssertEqual(next, "opencode")
    }

    /// The remembered tool is no longer in a (reconfigured) list: it was
    /// still typed, so it is still erased, then the cycle restarts.
    func testAToolNoLongerInTheListIsErasedThenTheCycleRestarts() {
        let (previous, next) = HerdrProvider.plannedCycle(
            paneID: "p1", tools: tools, lastPaneID: "p1", lastTool: "aider")
        XCTAssertEqual(previous, "aider")
        XCTAssertEqual(next, "opencode")
    }

    // MARK: - Joystick pane wrap

    private func pane(_ id: String, tab: String = "t1", focused: Bool = false) -> HerdrAgent {
        HerdrAgent(status: "idle", paneID: id, tabID: tab, focused: focused)
    }

    func testDeflectingOffTheLastPaneWrapsToTheFirst() {
        let panes = [pane("a"), pane("b"), pane("c", focused: true)]
        XCTAssertEqual(HerdrProvider.wrapTarget(.east, panes: panes), "a")
        XCTAssertEqual(HerdrProvider.wrapTarget(.south, panes: panes), "a")
    }

    func testDeflectingOffTheFirstPaneWrapsToTheLast() {
        let panes = [pane("a", focused: true), pane("b"), pane("c")]
        XCTAssertEqual(HerdrProvider.wrapTarget(.west, panes: panes), "c")
        XCTAssertEqual(HerdrProvider.wrapTarget(.north, panes: panes), "c")
    }

    /// A deflection from the middle of the list is an ordinary one-pane-over
    /// move — no wrap, whatever the direction.
    func testAMidListDeflectionNeverWraps() {
        let panes = [pane("a"), pane("b", focused: true), pane("c")]
        for direction: Pad.JoystickDirection in [.north, .south, .east, .west] {
            XCTAssertNil(HerdrProvider.wrapTarget(direction, panes: panes))
        }
    }

    func testALonePaneNeverWraps() {
        XCTAssertNil(HerdrProvider.wrapTarget(.east, panes: [pane("a", focused: true)]))
        XCTAssertNil(HerdrProvider.wrapTarget(.east, panes: []))
    }

    /// Only the panes sharing the focused pane's tab are wrap candidates —
    /// a deflection never jumps to another tab.
    func testPanesInFocusedTabIgnoresOtherTabs() {
        let agents = [
            pane("a", tab: "t1", focused: true),
            pane("b", tab: "t1"),
            pane("c", tab: "t2")
        ]
        XCTAssertEqual(HerdrProvider.panesInFocusedTab(agents).map(\.paneID), ["a", "b"])
    }
}
