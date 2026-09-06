import XCTest
@testable import WLKit

/// The JSON shapes `RemoteProvider` and `ProviderBridgeServer` speak to each
/// other — pure encode/decode, no socket needed to test them.
final class ProviderWireTests: XCTestCase {

    func testDescriptionRoundTrips() {
        let original = ProviderDescription(
            statePalette: [
                "blocked": ProviderStateStyle(color: 0xFF2D2D, effect: .breath),
                "idle": ProviderStateStyle(color: 0x00C853, effect: .solid)
            ],
            statePriority: ["blocked", "idle"],
            dialModes: [ProviderDialMode(id: "agent", label: "Agent", raisesHost: true)]
        )
        let decoded = ProviderWire.decodeDescription(ProviderWire.encode(original))
        XCTAssertEqual(decoded, original)
    }

    func testEmptyDescriptionRoundTrips() {
        let decoded = ProviderWire.decodeDescription(ProviderWire.encode(ProviderDescription()))
        XCTAssertEqual(decoded, ProviderDescription())
    }

    func testAgentListRoundTrips() {
        let original = [
            HerdrAgent(agent: "claude", status: "working", paneID: "p1", tabID: "t1",
                       workspaceID: "w1", cwd: "/tmp", focused: true),
            HerdrAgent(agent: "codex", status: "idle", paneID: "p2")
        ]
        let decoded = ProviderWire.decodeAgents(ProviderWire.encode(original))
        XCTAssertEqual(decoded, original)
    }

    func testEmptyAgentListRoundTrips() {
        XCTAssertEqual(ProviderWire.decodeAgents(ProviderWire.encode([])), [])
    }

    /// A malformed palette entry is dropped rather than crashing the decode —
    /// the same "fall back, don't brick the pad" rule `KeyBindings` follows.
    func testDecodeIgnoresAMalformedPaletteEntry() {
        let json: [String: Any] = [
            "statePalette": ["blocked": ["color": 0xFF0000, "effect": 999]],   // no such effect
            "statePriority": ["blocked"],
            "dialModes": [] as [[String: Any]]
        ]
        let decoded = ProviderWire.decodeDescription(json)
        XCTAssertNil(decoded.statePalette["blocked"])
    }
}
