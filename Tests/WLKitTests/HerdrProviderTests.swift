import XCTest
@testable import WLKit

/// Pins `HerdrProvider.describe()` to the values `BridgeConfig`'s defaults
/// hardcoded before phase 2 — the migration is only safe if nothing repaints
/// differently, so the numbers here must match `StatusMapper`'s old literals
/// exactly, not just "look reasonable."
final class HerdrProviderTests: XCTestCase {

    func testDescribesTheSameStatePaletteBridgeConfigUsedToHardcode() {
        let description = HerdrProvider().describe()
        let cfg = BridgeConfig()
        for state in ["blocked", "working", "done", "idle", "unknown"] {
            XCTAssertEqual(description.statePalette[state]?.color, cfg.colors[state], state)
            XCTAssertEqual(description.statePalette[state]?.effect, cfg.effects[state], state)
        }
    }

    func testDescribesTheSameStatePriorityBridgeConfigUsedToHardcode() {
        XCTAssertEqual(HerdrProvider().describe().statePriority, BridgeConfig().priority)
    }

    /// "effort" is a Micromanager feature, never a provider one.
    func testDialModesNeverIncludeEffort() {
        XCTAssertFalse(HerdrProvider().describe().dialModes.map(\.id).contains("effort"))
    }

    func testDialModesAreAgentTabAndSpace() {
        XCTAssertEqual(
            Set(HerdrProvider().describe().dialModes.map(\.id)),
            ["agent", "tab", "space"]
        )
    }
}
