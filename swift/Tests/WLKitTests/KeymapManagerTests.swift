import XCTest
@testable import WLKit

/// Uses the real backed-up device keymap, so the double-encoded envelope and
/// the layer layout are exercised against genuine data rather than a fixture I
/// invented to match my own parser.
final class KeymapManagerTests: XCTestCase {

    private func backupKeymap() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // WLKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // swift
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("backup/keymap.json")
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try KeymapManager.parse(raw)
    }

    func testParsesTheDoubleEncodedEnvelope() throws {
        let config = try backupKeymap()
        XCTAssertNotNil(config["profiles"], "inner JSON string must be decoded")
    }

    func testStockKeymapIsNotAgentBound() throws {
        let config = try backupKeymap()
        XCTAssertFalse(
            KeymapManager.isAgentKeymapApplied(config),
            "the backup is the stock F-key map"
        )
        XCTAssertEqual(KeymapManager.activeLayerKeymap(config)?[0], ["KC_F13", "KC_F14"])
    }

    func testApplyingBindsTheAgentKeysAndTheStackKey() throws {
        let config = try backupKeymap()
        let next = try KeymapManager.withAgentKeymap(config)
        XCTAssertTrue(KeymapManager.isAgentKeymapApplied(next))

        let keymap = try XCTUnwrap(KeymapManager.activeLayerKeymap(next))
        XCTAssertEqual(keymap[0], ["KV_OAI_AG00", "KV_OAI_AG01"])
        XCTAssertEqual(keymap[1], ["KV_OAI_AG02", "KV_OAI_AG03", "KV_OAI_AG04", "KV_OAI_AG05"])
        // The stack key is key 6 — row 2, column 0.
        XCTAssertEqual(keymap[2][0], "KV_OAI_AG06")
    }

    /// The stack key shares a row with three keys this app has no business
    /// touching, so binding it must not take the rest of the row with it.
    func testApplyingLeavesTheRestOfTheKeymapAlone() throws {
        let config = try backupKeymap()
        let next = try KeymapManager.withAgentKeymap(config)

        let original = try XCTUnwrap(KeymapManager.activeLayerKeymap(config))
        let keymap = try XCTUnwrap(KeymapManager.activeLayerKeymap(next))
        XCTAssertEqual(Array(keymap[2].dropFirst()), Array(original[2].dropFirst()))
        XCTAssertEqual(keymap[3], original[3])
    }

    /// A pad bound the old way — six agent keys, stack key still on its F-key —
    /// has to report as *not* applied, or the rebind never happens.
    func testAgentOnlyKeymapIsNotConsideredApplied() throws {
        var config = try backupKeymap()
        var profiles = try XCTUnwrap(config["profiles"] as? [[String: Any]])
        var layers = try XCTUnwrap(profiles[0]["layers"] as? [[String: Any]])
        var layout = try XCTUnwrap(layers[0]["layout"] as? [String: Any])
        var keymap = try XCTUnwrap(layout["keymap"] as? [[String]])
        keymap[0] = ["KV_OAI_AG00", "KV_OAI_AG01"]
        keymap[1] = ["KV_OAI_AG02", "KV_OAI_AG03", "KV_OAI_AG04", "KV_OAI_AG05"]
        layout["keymap"] = keymap
        layers[0]["layout"] = layout
        profiles[0]["layers"] = layers
        config["profiles"] = profiles

        XCTAssertFalse(KeymapManager.isAgentKeymapApplied(config))
        XCTAssertTrue(KeymapManager.isAgentKeymapApplied(try KeymapManager.withAgentKeymap(config)))
    }

    func testApplyingIsIdempotent() throws {
        let once = try KeymapManager.withAgentKeymap(try backupKeymap())
        let twice = try KeymapManager.withAgentKeymap(once)
        XCTAssertTrue(KeymapManager.isAgentKeymapApplied(twice))
    }

    func testEverythingElseSurvivesTheRewrite() throws {
        let config = try backupKeymap()
        let next = try KeymapManager.withAgentKeymap(config)

        let profiles = try XCTUnwrap(next["profiles"] as? [[String: Any]])
        let layers = try XCTUnwrap(profiles[0]["layers"] as? [[String: Any]])
        XCTAssertEqual(layers.count, 3, "the other layers are preserved")

        let layout = try XCTUnwrap(layers[0]["layout"] as? [String: Any])
        XCTAssertNotNil(layout["encoders"], "encoders survive")
        XCTAssertNotNil(layout["joystick"], "joystick survives")
        XCTAssertNotNil(layers[0]["lights"], "per-layer lighting survives")
    }

    func testMalformedInputIsRejectedRatherThanSilentlyAccepted() {
        XCTAssertThrowsError(try KeymapManager.parse(["nope": 1]))
        XCTAssertThrowsError(try KeymapManager.parse(["data": "not json"]))
        XCTAssertFalse(KeymapManager.isAgentKeymapApplied([:]))
    }
}
