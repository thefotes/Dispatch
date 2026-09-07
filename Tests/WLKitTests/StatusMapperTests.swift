import XCTest
import SwiftUI
@testable import WLKit

/// Tracks test/status.test.js so the two implementations cannot drift —
/// except the aggregate priority order, which deliberately ranks "done"
/// above "working" here (see `testDoneOutranksWorkingWhichOutranksIdle`).
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
            agent("blocked", pane: "w1:p3")
        ])
        XCTAssertEqual(state, "blocked")
        XCTAssertEqual(StatusMapper.zone(for: state)?.color, 0xFF2D2D)
    }

    /// Diverges from `test/status.test.js` on purpose: an unread "done" agent
    /// (blue, "look at me") outranks a "working" one (amber, "busy, leave me
    /// alone"), which in turn outranks "idle".
    func testDoneOutranksWorkingWhichOutranksIdle() {
        let state = StatusMapper.aggregate([agent("idle"), agent("working"), agent("done")])
        XCTAssertEqual(state, "done")
        XCTAssertEqual(StatusMapper.zone(for: state)?.color, 0x00B0FF)

        let noneUnread = StatusMapper.aggregate([agent("idle"), agent("working")])
        XCTAssertEqual(noneUnread, "working")
        XCTAssertEqual(StatusMapper.zone(for: noneUnread)?.color, 0xFFA000)
    }

    func testUnrecognizedStatusStillYieldsAState() {
        XCTAssertEqual(StatusMapper.aggregate([agent("wat")]), "unknown")
    }

    func testBlockedBreathesSoItReadsDifferently() {
        XCTAssertEqual(StatusMapper.zone(for: "blocked")?.effect, .breath)
        XCTAssertEqual(StatusMapper.zone(for: "working")?.effect, .solid)
    }

    // MARK: - Per-key

    func testEachAgentGetsItsOwnKeyInReadingOrder() {
        let threads = StatusMapper.threads(for: [
            agent("working"), agent("blocked"), agent("idle")
        ])
        XCTAssertEqual(threads.count, 6, "one entry per agent key")
        // The pad's top row is wired right to left, so reading order starts
        // at key 1: the first agent lights the top-LEFT key.
        XCTAssertEqual(threads.map(\.id), [1, 0, 2, 3, 4, 5], "keys in reading order")
        XCTAssertEqual(threads[0].color, 0xFFA000)
        XCTAssertEqual(threads[1].color, 0xFF2D2D)
        XCTAssertEqual(threads[2].color, 0x00C853)
    }

    func testKeysWithNoAgentAreSwitchedOffNotLeftStale() {
        let threads = StatusMapper.threads(for: [agent("working")])
        for thread in threads.dropFirst() {
            XCTAssertEqual(thread.effect, .off)
            XCTAssertEqual(thread.brightness, 0)
            XCTAssertNil(thread.color, "no color on an unused key")
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

    // MARK: - Agent key order

    private func named(_ status: String, _ pane: String) -> HerdrAgent {
        HerdrAgent(status: status, paneID: pane)
    }

    func testKeyOrderIsSidebarOrderByDefault() {
        let input = [named("idle", "a"), named("blocked", "b"), named("working", "c")]
        XCTAssertEqual(StatusMapper.agentsInKeyOrder(input).map(\.paneID),
                       ["a", "b", "c"], "no reordering unless asked for")
    }

    func testPriorityOrderFloatsAttentionAgentsToTheFront() {
        var cfg = BridgeConfig()
        cfg.prioritizeAgentKeys = true
        // Seven agents: the blocked and done ones sit past the sixth slot in
        // sidebar order and would never light a key today.
        let input = [
            named("idle", "s0"), named("working", "s1"), named("idle", "s2"),
            named("idle", "s3"), named("working", "s4"), named("idle", "s5"),
            named("blocked", "s6"), named("done", "s7")
        ]
        let order = StatusMapper.agentsInKeyOrder(input, cfg).map(\.paneID)
        XCTAssertEqual(Array(order.prefix(4)), ["s6", "s7", "s1", "s4"],
                       "blocked, then done, then working — in sidebar order within each tier")
        XCTAssertEqual(order.count, input.count, "every agent is still returned")
    }

    func testPriorityOrderIsStableWithinAState() {
        var cfg = BridgeConfig()
        cfg.prioritizeAgentKeys = true
        let input = (0..<5).map { named("working", "w\($0)") }
        XCTAssertEqual(StatusMapper.agentsInKeyOrder(input, cfg).map(\.paneID),
                       ["w0", "w1", "w2", "w3", "w4"])
    }

    func testPriorityOrderSendsUnknownStatusesLast() {
        var cfg = BridgeConfig()
        cfg.prioritizeAgentKeys = true
        let input = [named("mystery", "m"), named("idle", "i"), named("blocked", "b")]
        XCTAssertEqual(StatusMapper.agentsInKeyOrder(input, cfg).map(\.paneID),
                       ["b", "i", "m"])
    }

    func testConfigOverridesAreHonored() {
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

    func testColorRoundTrip() {
        XCTAssertEqual(packedRGB(fromHex: "#FF2D2D"), 0xFF2D2D)
        XCTAssertEqual(packedRGB(fromHex: "00C853"), 0x00C853)
        XCTAssertEqual(packedRGB(fromHex: "#0f0"), 0x00FF00)
        XCTAssertEqual(hexString(0xFF2D2D), "#FF2D2D")
    }

    /// Slots follow the pad's reading order, so a slot must always resolve to
    /// the key that lights it and back.
    func testAgentSlotAndKeyAreInverses() {
        for (slot, key) in Pad.agentKeyIDs.enumerated() {
            XCTAssertEqual(Pad.agentSlot(for: key), slot)
        }
        XCTAssertNil(Pad.agentSlot(for: Pad.stackKeyID))
        XCTAssertNil(Pad.agentSlot(for: Pad.landKeyID))
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

// MARK: - Status colors must stay distinguishable

extension StatusMapperTests {

    func testDoneAndIdleAreToldApartByColor() {
        // "done" means finished and not yet looked at; "idle" means finished
        // and seen. Different signals, so they must not share a color.
        let cfg = BridgeConfig()
        XCTAssertNotEqual(
            cfg.color(for: "done"),
            cfg.color(for: "idle"),
            "a finished-but-unread agent must be distinguishable from a quiet one"
        )
        XCTAssertEqual(cfg.color(for: "idle"), 0x00C853)
        XCTAssertEqual(cfg.color(for: "done"), 0x00B0FF)
    }

    func testAttentionStatesAllHaveDistinctColors() {
        let cfg = BridgeConfig()
        var seen: [Int: String] = [:]
        for state in ["blocked", "working", "done", "idle"] {
            let color = cfg.color(for: state)
            XCTAssertNil(seen[color], "\(state) reuses the color of \(seen[color] ?? "")")
            seen[color] = state
        }
    }

    func testDoneAndIdleAgentsGetDifferentKeys() {
        let threads = StatusMapper.threads(for: [
            HerdrAgent(status: "done", paneID: "w1:p1"),
            HerdrAgent(status: "idle", paneID: "w1:p2")
        ])
        XCTAssertEqual(threads[0].color, 0x00B0FF)
        XCTAssertEqual(threads[1].color, 0x00C853)
    }

    /// Pins every status color. These are the whole point of the pad — a
    /// silent change to one is a bug you find by looking at hardware, which is
    /// the slowest possible way to find it.
    func testEveryStatusColorIsPinned() {
        let cfg = BridgeConfig()
        XCTAssertEqual(cfg.color(for: "blocked"), 0xFF2D2D)
        XCTAssertEqual(cfg.color(for: "working"), 0xFFA000)
        XCTAssertEqual(cfg.color(for: "done"), 0x00B0FF)
        XCTAssertEqual(cfg.color(for: "idle"), 0x00C853)
        XCTAssertEqual(cfg.color(for: "unknown"), 0x00C853)
    }
}
