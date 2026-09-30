import Foundation
import XCTest
@testable import DispatchCore

final class EventModelTests: XCTestCase {
    func testEveryEventShapeRoundTripsThroughJSON() throws {
        let source = DeviceIdentity(rawValue: "desk-pad")
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000.125)
        let events = [
            DispatchEvent(source: source, control: .key(9), gesture: .pressed, timestamp: timestamp),
            DispatchEvent(source: source, control: .key(9), gesture: .released, timestamp: timestamp),
            DispatchEvent(source: source, control: .dial, gesture: .rotated(steps: 3), timestamp: timestamp),
            DispatchEvent(source: source, control: .dial, gesture: .rotated(steps: -2), timestamp: timestamp),
            DispatchEvent(
                source: source,
                control: .joystick,
                gesture: .moved(direction: .left, magnitude: 0.75),
                timestamp: timestamp
            )
        ]

        let data = try JSONEncoder().encode(events)
        let decoded = try JSONDecoder().decode([DispatchEvent].self, from: data)

        XCTAssertEqual(decoded, events)
    }

    func testEventEncodingUsesStableLogicalVocabulary() throws {
        let event = DispatchEvent(
            source: DeviceIdentity(rawValue: "creator-micro-1"),
            control: .key(4),
            gesture: .pressed,
            timestamp: Date(timeIntervalSince1970: 0)
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any]
        )
        let control = try XCTUnwrap(object["control"] as? [String: Any])
        let gesture = try XCTUnwrap(object["gesture"] as? [String: Any])

        XCTAssertEqual(control["type"] as? String, "key")
        XCTAssertEqual(control["index"] as? Int, 4)
        XCTAssertEqual(gesture["type"] as? String, "pressed")
        XCTAssertNil(String(data: try JSONEncoder().encode(event), encoding: .utf8)?.range(of: "AG"))
    }

    func testDecodingRejectsInvalidAssociatedValues() {
        assertDecodeFails(LogicalControl.self, json: #"{"type":"dial","index":4}"#)
        assertDecodeFails(LogicalControl.self, json: #"{"type":"key","index":-1}"#)
        assertDecodeFails(Gesture.self, json: #"{"type":"rotated","steps":0}"#)
        assertDecodeFails(Gesture.self, json: #"{"type":"pressed","direction":"up"}"#)
        assertDecodeFails(
            Gesture.self,
            json: #"{"type":"moved","direction":"up","magnitude":-0.1}"#
        )
    }

    private func assertDecodeFails<T: Decodable>(_ type: T.Type, json: String) {
        XCTAssertThrowsError(try JSONDecoder().decode(type, from: Data(json.utf8)))
    }
}
