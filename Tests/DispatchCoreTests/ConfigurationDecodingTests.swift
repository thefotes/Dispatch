import Foundation
import XCTest
@testable import DispatchCore

final class ConfigurationDecodingTests: XCTestCase {
    func testDecodesVersionedConfigurationAndDefaultsArguments() throws {
        let configuration = try decode(
            #"""
            {
              "version": 1,
              "bindings": [{
                "when": {
                  "control": {"type": "key", "index": 9},
                  "gesture": {"type": "pressed"}
                },
                "actions": [{"id": "herdr.closeFocusedPane"}]
              }]
            }
            """#
        )

        XCTAssertEqual(configuration.version, 1)
        XCTAssertEqual(configuration.bindings.count, 1)
        XCTAssertEqual(configuration.bindings[0].event.control, .key(9))
        XCTAssertEqual(configuration.bindings[0].actions[0].arguments, [:])
    }

    func testConfigurationRoundTripsThroughJSON() throws {
        let original = DispatchConfiguration(
            bindings: [
                BindingDefinition(
                    event: EventPattern(control: .dial, gesture: .rotated(direction: .counterclockwise)),
                    actions: [ConfiguredAction(id: "herdr.adjust", arguments: ["amount": .integer(-1)])]
                )
            ],
            statusPalette: StatusPalette(
                appearances: [
                    "working": ControlAppearance(color: RGBColor(red: 1, green: 2, blue: 3), brightness: 0.5)
                ],
                ambientPriority: ["working"]
            ),
            integrations: ["example": .object(["setting": .string("value")])]
        )

        let decoded = try JSONDecoder().decode(
            DispatchConfiguration.self,
            from: JSONEncoder().encode(original)
        )

        XCTAssertEqual(decoded, original)
    }

    func testRejectsUnknownFieldsAtEveryConfigurationLevel() {
        let documents = [
            #"{"version":1,"bindings":[],"surprise":true}"#,
            validJSON.replacingOccurrences(of: #""actions""#, with: #""extra":1,"actions""#),
            validJSON.replacingOccurrences(of: #""control""#, with: #""extra":1,"control""#),
            validJSON.replacingOccurrences(of: #""type":"key""#, with: #""extra":1,"type":"key""#),
            validJSON.replacingOccurrences(of: #""type":"pressed""#, with: #""extra":1,"type":"pressed""#),
            validJSON.replacingOccurrences(
                of: #""id":"herdr.closeFocusedPane""#,
                with: #""extra":1,"id":"herdr.closeFocusedPane""#
            )
        ]

        for document in documents {
            XCTAssertThrowsError(try decode(document), "Expected rejection for: \(document)")
        }
    }

    func testRejectsMalformedDocuments() {
        let documents = [
            "{}",
            #"{"version":"one","bindings":[]}"#,
            #"{"version":1,"bindings":{}}"#,
            #"{"version":1,"bindings":[{"when":{},"actions":[]}]}"#,
            #"""
            {"version":1,"bindings":[{
              "when":{"control":{"type":"key"},"gesture":{"type":"pressed"}},"actions":[]
            }]}
            """#,
            #"""
            {"version":1,"bindings":[{
              "when":{
                "control":{"type":"key","index":1},
                "gesture":{"type":"pressed","direction":"up"}
              },
              "actions":[]
            }]}
            """#
        ]

        for document in documents {
            XCTAssertThrowsError(try decode(document), "Expected rejection for: \(document)")
        }
    }

    func testRejectsInvalidOrUnknownPaletteFields() {
        let invalidBrightness = #"""
        {"version":1,"bindings":[],"statusPalette":{
          "appearances":{"working":{"color":{"red":1,"green":2,"blue":3},"brightness":2}},
          "ambientPriority":["working"]
        }}
        """#
        let unknownPaletteField = #"""
        {"version":1,"bindings":[],"statusPalette":{
          "appearances":{},"ambientPriority":[],"surprise":true
        }}
        """#

        XCTAssertThrowsError(try decode(invalidBrightness))
        XCTAssertThrowsError(try decode(unknownPaletteField))
    }

    private let validJSON = #"""
    {"version":1,"bindings":[{
      "when":{"control":{"type":"key","index":1},"gesture":{"type":"pressed"}},
      "actions":[{"id":"herdr.closeFocusedPane"}]
    }]}
    """#

    func testAgentLabelIsOptionalAndRejectsUnknownStyles() throws {
        XCTAssertNil(try decode(#"{"version":1,"bindings":[]}"#).agentLabel)
        XCTAssertEqual(
            try decode(#"{"version":1,"bindings":[],"agentLabel":"terminalTitle"}"#).agentLabel,
            .terminalTitle
        )
        XCTAssertEqual(
            try decode(#"{"version":1,"bindings":[],"agentLabel":"workspaceAndAgent"}"#).agentLabel,
            .workspaceAndAgent
        )
        XCTAssertThrowsError(try decode(#"{"version":1,"bindings":[],"agentLabel":"title"}"#))
    }

    func testLightsAreOptionalAndDecodeEachControlsAppearance() throws {
        XCTAssertNil(try decode(#"{"version":1,"bindings":[]}"#).lights)

        let configuration = try decode(#"""
        {"version":1,"bindings":[],"lights":[
          {"control":{"type":"key","index":9},
           "appearance":{"color":{"red":210,"green":55,"blue":70},"effect":"breath","speed":0.3}}
        ]}
        """#)

        XCTAssertEqual(configuration.lights, [
            ControlLight(
                control: .key(9),
                appearance: ControlAppearance(
                    color: RGBColor(red: 210, green: 55, blue: 70),
                    effect: .breath,
                    speed: 0.3
                )
            )
        ])
        let roundTripped = try JSONDecoder().decode(
            DispatchConfiguration.self,
            from: JSONEncoder().encode(configuration)
        )
        XCTAssertEqual(roundTripped, configuration)
    }

    func testTwoLightsForOneControlNameTheSecond() {
        let json = #"""
        {"version":1,"bindings":[],"lights":[
          {"control":{"type":"key","index":9},"appearance":{"color":{"red":1,"green":2,"blue":3}}},
          {"control":{"type":"key","index":8},"appearance":{"color":{"red":1,"green":2,"blue":3}}},
          {"control":{"type":"key","index":9},"appearance":{"color":{"red":4,"green":5,"blue":6}}}
        ]}
        """#

        XCTAssertThrowsError(try decode(json)) { error in
            XCTAssertEqual(
                ConfigurationDiagnostic.message(for: error),
                "At lights[2]: key 9 already has a light. Give each control one entry."
            )
        }
    }

    func testLightRejectsUnknownFields() {
        let json = #"""
        {"version":1,"bindings":[],"lights":[
          {"control":{"type":"key","index":9},"color":{"red":1,"green":2,"blue":3}}
        ]}
        """#

        XCTAssertThrowsError(try decode(json)) { error in
            XCTAssertEqual(ConfigurationDiagnostic.message(for: error), #"At lights[0]: Unknown field "color"."#)
        }
    }

    private func decode(_ json: String) throws -> DispatchConfiguration {
        try JSONDecoder().decode(DispatchConfiguration.self, from: Data(json.utf8))
    }
}
