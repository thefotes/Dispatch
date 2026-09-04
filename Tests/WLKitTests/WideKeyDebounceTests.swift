import XCTest
@testable import WLKit

/// The wide key's two switches reporting one physical press as two
/// notifications, milliseconds apart — this is the pure "are these close
/// enough to be the same press" check `BridgeController.handleKeyPress`
/// uses to collapse them into one.
final class WideKeyDebounceTests: XCTestCase {

    private func time(_ nanoseconds: UInt64) -> DispatchTime {
        DispatchTime(uptimeNanoseconds: nanoseconds)
    }

    func testNotificationsMillisecondsApartAreTheSamePress() {
        XCTAssertTrue(WideKeyDebounce.isSamePress(time(0), time(5_000_000)))   // 5ms
    }

    func testNotificationsWellOverAThresholdApartAreDifferentPresses() {
        XCTAssertFalse(WideKeyDebounce.isSamePress(time(0), time(500_000_000)))   // 500ms
    }

    /// Exactly at the threshold is still a different press — the boundary
    /// belongs to "these are separate," not "collapse them."
    func testExactlyAtTheThresholdIsADifferentPress() {
        XCTAssertFalse(WideKeyDebounce.isSamePress(time(0), time(150_000_000), thresholdMs: 150))
    }

    func testJustUnderTheThresholdIsTheSamePress() {
        XCTAssertTrue(WideKeyDebounce.isSamePress(time(0), time(149_000_000), thresholdMs: 150))
    }

    /// Order of the two timestamps must not matter — a real caller always
    /// compares "now" against "last," which is earlier, but the check itself
    /// should not assume which argument is which.
    func testOrderOfArgumentsDoesNotMatter() {
        XCTAssertTrue(WideKeyDebounce.isSamePress(time(5_000_000), time(0)))
        XCTAssertEqual(
            WideKeyDebounce.isSamePress(time(0), time(5_000_000)),
            WideKeyDebounce.isSamePress(time(5_000_000), time(0))
        )
    }

    func testTheSameInstantIsTheSamePress() {
        XCTAssertTrue(WideKeyDebounce.isSamePress(time(1_000), time(1_000)))
    }
}
