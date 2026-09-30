@testable import DispatchApp
import DispatchCore
import DispatchProviders
import Foundation
import XCTest

final class HerdrPresentationTests: XCTestCase {
    private let renderer = HerdrPresentationRenderer()
    private let red = ControlAppearance(color: RGBColor(red: 200, green: 0, blue: 0))

    func testAgentLightsFollowTheKeysBoundToTheirSlots() throws {
        let configuration = try decode(#"""
        {"version":1,"bindings":[
          \#(slotBinding(key: 6, slot: 1)),
          \#(slotBinding(key: 12, slot: 2)),
          \#(slotBinding(key: 3, slot: 2))
        ]}
        """#)

        let presentation = renderer.render(agents(["blocked", "working", "idle"]), configuration: configuration)

        let palette = HerdrPresentationRenderer.defaultPalette
        XCTAssertEqual(presentation.controls, [
            .key(6): palette.appearances["blocked"],
            .key(3): palette.appearances["working"],
            .key(12): palette.appearances["working"]
        ])
    }

    func testKeysWithoutSlotBindingsStayDarkEvenWhereTheDefaultPutsSlots() throws {
        let configuration = try decode(#"{"version":1,"bindings":[\#(slotBinding(key: 9, slot: 1))]}"#)

        let presentation = renderer.render(agents(["working", "working"]), configuration: configuration)

        XCTAssertEqual(Array(presentation.controls.keys), [.key(9)])
    }

    func testConfiguredLightsShowUntilAnAgentTakesTheirKey() throws {
        let configuration = try decode(#"""
        {"version":1,
         "bindings":[\#(slotBinding(key: 0, slot: 1))],
         "lights":[
           {"control":{"type":"key","index":0},"appearance":{"color":{"red":200,"green":0,"blue":0}}},
           {"control":{"type":"key","index":7},"appearance":{"color":{"red":200,"green":0,"blue":0}}}
         ]}
        """#)

        let empty = renderer.render(agents([]), configuration: configuration)
        let occupied = renderer.render(agents(["done"]), configuration: configuration)

        XCTAssertEqual(empty.controls, [.key(0): red, .key(7): red])
        XCTAssertEqual(occupied.controls[.key(0)], HerdrPresentationRenderer.defaultPalette.appearances["done"])
        XCTAssertEqual(occupied.controls[.key(7)], red)
    }

    func testWithoutConfiguredLightsOnlySlotKeysLight() throws {
        let configuration = try decode(#"{"version":1,"bindings":[]}"#)

        let presentation = renderer.render(agents(["working"]), configuration: configuration)

        XCTAssertEqual(presentation.controls, [:])
    }

    func testUnderglowShowsTheMostUrgentAgentEvenWithoutSlotKeys() throws {
        let configuration = try decode(#"{"version":1,"bindings":[]}"#)

        let presentation = renderer.render(agents(["idle", "blocked"]), configuration: configuration)

        XCTAssertEqual(presentation.ambient, HerdrPresentationRenderer.defaultPalette.appearances["blocked"])
    }

    func testDefaultConfigurationLightsTheCloseAndVoiceKeys() {
        let presentation = renderer.render(.disconnected)

        XCTAssertEqual(presentation.controls[.key(9)]?.color, RGBColor(red: 210, green: 55, blue: 70))
        XCTAssertEqual(presentation.controls[.key(10)]?.color, RGBColor(red: 145, green: 90, blue: 255))
        XCTAssertEqual(presentation.controls.count, 2)
    }

    func testSlotKeysLabelEachAgentWithTheLowestKeyForItsSlot() throws {
        let configuration = try decode(#"""
        {"version":1,"bindings":[
          \#(slotBinding(key: 8, slot: 1)),
          \#(slotBinding(key: 2, slot: 1)),
          \#(slotBinding(key: 4, slot: 3))
        ]}
        """#)

        let keys = HerdrSlotKeys(configuration)

        XCTAssertEqual((0..<4).map(keys.key(forAgentAt:)), [2, nil, 4, nil])
    }

    private func slotBinding(key: Int, slot: Int) -> String {
        #"""
        {"when":{"control":{"type":"key","index":\#(key)},"gesture":{"type":"pressed"}},
         "actions":[{"id":"herdr.agent.focusSlot","arguments":{"slot":\#(slot)}}]}
        """#
    }

    private func agents(_ statuses: [String]) -> HerdrState {
        HerdrState(
            availability: .available,
            agents: statuses.enumerated().map { index, status in
                HerdrAgent(paneID: "p\(index)", name: nil, status: status, focused: false)
            }
        )
    }

    private func decode(_ json: String) throws -> DispatchConfiguration {
        try JSONDecoder().decode(DispatchConfiguration.self, from: Data(json.utf8))
    }
}
