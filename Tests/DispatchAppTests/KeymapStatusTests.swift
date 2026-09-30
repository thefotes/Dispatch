@testable import DispatchApp
import DispatchRuntime
import XCTest

@MainActor
final class KeymapStatusTests: XCTestCase {
    func testConfigurationErrorAtLaunchKeepsWaitingForThePad() {
        let status = AppModel.KeymapStatus.waitingForPad
            .afterRuntimeChange(to: RuntimeSnapshot(phase: .degraded, issue: .configuration("Unknown field")))

        XCTAssertEqual(status, .waitingForPad)
    }

    func testConfigurationErrorWhileRunningKeepsTheCheckedStatus() {
        let status = AppModel.KeymapStatus.ready
            .afterRuntimeChange(to: RuntimeSnapshot(phase: .degraded, issue: .configuration("Unknown field")))

        XCTAssertEqual(status, .ready)
    }

    func testLosingThePadWaitsForItAgain() {
        let lost = RuntimeSnapshot(phase: .degraded, issue: .device("Unplugged"))

        XCTAssertEqual(AppModel.KeymapStatus.ready.afterRuntimeChange(to: lost), .waitingForPad)
        XCTAssertEqual(AppModel.KeymapStatus.checking.afterRuntimeChange(to: lost), .waitingForPad)
        XCTAssertEqual(
            AppModel.KeymapStatus.consentNeeded.afterRuntimeChange(to: RuntimeSnapshot(phase: .disabled)),
            .waitingForPad
        )
    }

    func testTurningKeymapSetupOffSurvivesDisconnecting() {
        let status = AppModel.KeymapStatus.disabled.afterRuntimeChange(to: RuntimeSnapshot(phase: .connecting))

        XCTAssertEqual(status, .disabled)
    }

    func testConnectedPadKeepsTheCurrentStatus() {
        let status = AppModel.KeymapStatus.checking.afterRuntimeChange(to: RuntimeSnapshot(phase: .operational))

        XCTAssertEqual(status, .checking)
    }
}
