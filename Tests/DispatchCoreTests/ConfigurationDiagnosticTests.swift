import DispatchCore
import Foundation
import XCTest

final class ConfigurationDiagnosticTests: XCTestCase {
    func testUnknownTopLevelFieldNamesTheField() {
        XCTAssertEqual(
            message(decoding: #"{"version": 1, "bindings": [], "x": 1}"#),
            #"At the top level: Unknown field "x"."#
        )
    }

    func testUnknownNestedFieldNamesItsLocation() {
        let json = #"""
        {"version": 1, "bindings": [
          {"when": {"control": {"type": "dial"}, "gesture": {"type": "rotated", "spin": 1}},
           "actions": [{"id": "herdr.workspace.cycle"}]}
        ]}
        """#

        XCTAssertEqual(message(decoding: json), #"At bindings[0].when.gesture: Unknown field "spin"."#)
    }

    func testMissingFieldNamesTheField() {
        XCTAssertEqual(
            message(decoding: #"{"version": 1, "bindings": [{"actions": []}]}"#),
            #"At bindings[0]: Missing field "when"."#
        )
    }

    func testWrongValueTypeSaysWhatWasExpected() {
        XCTAssertEqual(
            message(decoding: #"{"version": "one", "bindings": []}"#),
            "At version: Expected a whole number."
        )
    }

    func testMalformedJSONSaysSoWithTheParserDetail() {
        let text = message(decoding: "{\"version\": 1,\n \"bindings\": [}")

        XCTAssertTrue(text.hasPrefix("The file isn't valid JSON"), text)
        XCTAssertTrue(text.contains("line 2"), text)
    }

    func testCompilationErrorsNameTheBindingAndAction() {
        let cases: [(ConfigurationError, String)] = [
            (.unsupportedVersion(2), "At version: Dispatch reads version 1, not 2."),
            (.emptyMacro(binding: 3), "At bindings[3].actions: List at least one action."),
            (
                .ambiguousBindings(first: 1, second: 4),
                "At bindings[1] and bindings[4]: Both respond to the same input. Change or remove one."
            ),
            (
                .unsupportedAction(binding: 2, action: 0, id: "herdr.nope"),
                #"At bindings[2].actions[0].id: Unknown action "herdr.nope"."#
            ),
            (
                .missingArgument(binding: 2, action: 1, name: "slot"),
                #"At bindings[2].actions[1].arguments: Missing argument "slot"."#
            ),
            (
                .unknownArgument(binding: 0, action: 0, name: "slots"),
                #"At bindings[0].actions[0].arguments: Unknown argument "slots"."#
            ),
            (
                .invalidArgumentType(binding: 5, action: 0, name: "delta", expected: .integer),
                "At bindings[5].actions[0].arguments.delta: Expected a whole number."
            )
        ]

        for (error, expected) in cases {
            XCTAssertEqual(ConfigurationDiagnostic.message(for: error), expected)
        }
    }

    private func message(decoding json: String) -> String {
        do {
            _ = try JSONDecoder().decode(DispatchConfiguration.self, from: Data(json.utf8))
            XCTFail("Expected decoding to fail")
            return ""
        } catch {
            return ConfigurationDiagnostic.message(for: error)
        }
    }
}
