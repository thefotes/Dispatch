import XCTest
import SwiftUI
@testable import WLKit

/// Mirrors test/status.test.js so the two implementations cannot drift.
final class StatusMapperTests: XCTestCase {

    private func agent(_ status: String, pane: String = "w1:p1") -> HerdrAgent {
        HerdrAgent(status: status, paneID: pane)
    }

    // MARK: - Aggregate

    func testNoAgentsMeansNoState() {
        XCTAssertNil(StatusMapper.aggregate([]))
    }

    func testBlockedOutranksWorkingAndIdle() {
        let state = StatusMapper.aggregate([
            agent("idle", pane: "w1:p1"),
            agent("working", pane: "w1:p2"),
            agent("blocked", pane: "w1:p3"),
        ])
        XCTAssertEqual(state, "blocked")
        XCTAssertEqual(StatusMapper.zone(for: state)?.color, 0xFF2D2D)
    }

    func testWorkingOutranksIdleAndDone() {
        let state = StatusMapper.aggregate([agent("done"), agent("idle"), agent("working")])
        XCTAssertEqual(state, "working")
        XCTAssertEqual(StatusMapper.zone(for: state)?.color, 0xFFA000)
    }

    func testUnrecognisedStatusStillYieldsAState() {
        XCTAssertEqual(StatusMapper.aggregate([agent("wat")]), "unknown")
    }

    func testBlockedBreathesSoItReadsDifferently() {
        XCTAssertEqual(StatusMapper.zone(for: "blocked")?.effect, .breath)
        XCTAssertEqual(StatusMapper.zone(for: "working")?.effect, .solid)
    }

    // MARK: - Per-key

    func testEachAgentGetsItsOwnKeyInSlotOrder() {
        let threads = StatusMapper.threads(for: [
            agent("working"), agent("blocked"), agent("idle"),
        ])
        XCTAssertEqual(threads.count, 6, "one entry per agent key")
        XCTAssertEqual(threads.map(\.id), [0, 1, 2, 3, 4, 5], "ids are 0-based key indices")
        XCTAssertEqual(threads[0].color, 0xFFA000)
        XCTAssertEqual(threads[1].color, 0xFF2D2D)
        XCTAssertEqual(threads[2].color, 0x00C853)
    }

    func testKeysWithNoAgentAreSwitchedOffNotLeftStale() {
        let threads = StatusMapper.threads(for: [agent("working")])
        for thread in threads.dropFirst() {
            XCTAssertEqual(thread.effect, .off)
            XCTAssertEqual(thread.brightness, 0)
            XCTAssertNil(thread.color, "no colour on an unused key")
        }
    }

    func testBlockedAgentBreathesOnItsOwnKey() {
        let threads = StatusMapper.threads(for: [agent("idle"), agent("blocked")])
        XCTAssertEqual(threads[0].effect, .solid)
        XCTAssertEqual(threads[1].effect, .breath)
    }

    func testMoreAgentsThanKeysDoesNotOverflow() {
        let many = (0..<9).map { _ in agent("working") }
        XCTAssertEqual(StatusMapper.threads(for: many).count, 6)
    }

    func testConfigOverridesAreHonoured() {
        var cfg = BridgeConfig()
        cfg.colors["working"] = 0x123456
        cfg.brightness = 0.3
        let thread = StatusMapper.threads(for: [agent("working")], cfg)[0]
        XCTAssertEqual(thread.color, 0x123456)
        XCTAssertEqual(thread.brightness, 0.3)
    }

    // MARK: - Wire encoding

    func testThreadWireUsesAbbreviatedKeysAndNumericEffect() {
        let wire = OAI.Thread(id: 0, color: 0xFF0000, brightness: 1, effect: .solid, speed: 0.5).wire
        XCTAssertEqual(wire["id"] as? Int, 0)
        XCTAssertEqual(wire["c"] as? Int, 0xFF0000)
        XCTAssertEqual(wire["b"] as? Double, 1)
        XCTAssertEqual(wire["e"] as? Int, 1, "effect is a NUMBER, not a string")
        XCTAssertEqual(wire["s"] as? Double, 0.5)
        XCTAssertNil(wire["color"], "full field names are ignored by the firmware")
    }

    func testUnsetThreadFieldsAreOmittedSoTheyStayUnchanged() {
        let wire = OAI.Thread(id: 3, brightness: 0, effect: .off).wire
        XCTAssertNil(wire["c"])
        XCTAssertNil(wire["s"])
    }

    func testColourRoundTrip() {
        XCTAssertEqual(packedRGB(fromHex: "#FF2D2D"), 0xFF2D2D)
        XCTAssertEqual(packedRGB(fromHex: "00C853"), 0x00C853)
        XCTAssertEqual(packedRGB(fromHex: "#0f0"), 0x00FF00)
        XCTAssertEqual(hexString(0xFF2D2D), "#FF2D2D")
    }

    func testAgentSortMatchesTheNodeOrdering() {
        let a = HerdrAgent(status: "idle", paneID: "w1:p1", tabID: "w1:t1", workspaceID: "w1")
        let b = HerdrAgent(status: "idle", paneID: "w1:p2", tabID: "w1:t2", workspaceID: "w1")
        let c = HerdrAgent(status: "idle", paneID: "w2:p1", tabID: "w2:t1", workspaceID: "w2")
        let expected = [a, b, c].sorted { $0.sortKey < $1.sortKey }.map(\.paneID)
        XCTAssertEqual([c, a, b].sorted { $0.sortKey < $1.sortKey }.map(\.paneID), expected)
        XCTAssertEqual([b, c, a].sorted { $0.sortKey < $1.sortKey }.map(\.paneID), expected)
    }

    // MARK: - AG key names

    func testAGNamesMapToKeyIndices() {
        XCTAssertEqual(OAI.agIndex("AG00"), 0)
        XCTAssertEqual(OAI.agIndex("AG05"), 5)
        XCTAssertEqual(OAI.agIndex("AG12"), 12)
        XCTAssertNil(OAI.agIndex("KC_F13"))
        XCTAssertNil(OAI.agIndex(nil))
    }
}

// MARK: - Status colours must stay distinguishable

extension StatusMapperTests {

    func testDoneAndIdleAreToldApartByColour() {
        // "done" means finished and not yet looked at; "idle" means finished
        // and seen. Different signals, so they must not share a colour.
        let cfg = BridgeConfig()
        XCTAssertNotEqual(
            cfg.color(for: "done"),
            cfg.color(for: "idle"),
            "a finished-but-unread agent must be distinguishable from a quiet one"
        )
        XCTAssertEqual(cfg.color(for: "idle"), 0x00C853)
        XCTAssertEqual(cfg.color(for: "done"), 0x00B0FF)
    }

    func testAttentionStatesAllHaveDistinctColours() {
        let cfg = BridgeConfig()
        var seen: [Int: String] = [:]
        for state in ["blocked", "working", "done", "idle"] {
            let color = cfg.color(for: state)
            XCTAssertNil(seen[color], "\(state) reuses the colour of \(seen[color] ?? "")")
            seen[color] = state
        }
    }

    func testDoneAndIdleAgentsGetDifferentKeys() {
        let threads = StatusMapper.threads(for: [
            HerdrAgent(status: "done", paneID: "w1:p1"),
            HerdrAgent(status: "idle", paneID: "w1:p2"),
        ])
        XCTAssertEqual(threads[0].color, 0x00B0FF)
        XCTAssertEqual(threads[1].color, 0x00C853)
    }

    /// Guards the two implementations against drifting apart.
    func testColoursMatchTheNodeImplementation() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lib/status.js")
        let source = try String(contentsOf: url, encoding: .utf8)
        let cfg = BridgeConfig()
        for state in ["blocked", "working", "done", "idle", "unknown"] {
            let hex = hexString(cfg.color(for: state))
            XCTAssertTrue(
                source.contains("\(state): \"\(hex)\""),
                "lib/status.js has a different colour for \(state) than \(hex)"
            )
        }
    }
}
