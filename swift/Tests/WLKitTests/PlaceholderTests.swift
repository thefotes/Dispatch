import XCTest
@testable import WLKit

final class PlaceholderTests: XCTestCase {
    func testPadGeometry() {
        XCTAssertEqual(Pad.rows.flatMap { $0 }.count, Pad.keyCount)
        XCTAssertEqual(Pad.agentKeyIDs, [0, 1, 2, 3, 4, 5])
    }
}
