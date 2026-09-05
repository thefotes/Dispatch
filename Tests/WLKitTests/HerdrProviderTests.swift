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

    /// Herdr can move pane focus, so the app hands the joystick to it
    /// instead of running its own model cycling.
    func testDescribesJoystickNavigation() async {
        let description = await HerdrProvider().describe()
        XCTAssertTrue(description.joystickNavigation)
    }
}
