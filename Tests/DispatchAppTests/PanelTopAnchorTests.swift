@testable import DispatchApp
import CoreGraphics
import XCTest

final class PanelTopAnchorTests: XCTestCase {
    func testShrunkContentShortensTheWindowFromTheBottom() {
        // The panel opened at y 200...1000 with a 780-point content area
        // under 20 points of window chrome; its content is now 480 tall.
        let window = CGRect(x: 40, y: 200, width: 340, height: 800)

        let fitted = PanelTopAnchor.frame(
            fitting: 480,
            window: window,
            currentContentHeight: 780,
            keepingTopAt: 1000
        )

        XCTAssertEqual(fitted, CGRect(x: 40, y: 500, width: 340, height: 500))
    }

    func testGrownContentLengthensTheWindowFromTheBottom() {
        let window = CGRect(x: 40, y: 500, width: 340, height: 500)

        let fitted = PanelTopAnchor.frame(
            fitting: 780,
            window: window,
            currentContentHeight: 480,
            keepingTopAt: 1000
        )

        XCTAssertEqual(fitted, CGRect(x: 40, y: 200, width: 340, height: 800))
    }

    func testFittedWindowReturnsToTheAnchorWhenItHasMoved() {
        let moved = CGRect(x: 40, y: 150, width: 340, height: 500)

        let fitted = PanelTopAnchor.frame(
            fitting: 480,
            window: moved,
            currentContentHeight: 480,
            keepingTopAt: 1000
        )

        XCTAssertEqual(fitted.maxY, 1000)
        XCTAssertEqual(fitted.size, moved.size)
    }
}
