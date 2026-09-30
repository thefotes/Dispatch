import DispatchCore
import Foundation
import XCTest

final class JSONValueTests: XCTestCase {
    func testDecodingPreservesTheMostSpecificJSONType() throws {
        let cases: [(String, JSONValue)] = [
            ("null", .null),
            ("true", .boolean(true)),
            ("1", .integer(1)),
            ("1.5", .number(1.5)),
            (#""1""#, .string("1")),
            ("[false,2,2.5]", .array([.boolean(false), .integer(2), .number(2.5)])),
            (#"{"enabled":true,"count":3}"#, .object(["enabled": .boolean(true), "count": .integer(3)]))
        ]

        for (json, expected) in cases {
            XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)), expected, json)
        }
    }
}
