import XCTest
@testable import WLKit

/// Telling "you have not granted permission" apart from "the pad is not
/// reachable", which look identical from the error code alone.
///
/// `IOHIDDeviceOpen` answers `kIOReturnNotPermitted` (0xE00002E2) both when the
/// Input Monitoring grant is missing and when the device is already held or
/// wedged, so the code cannot be the thing that decides. `IOHIDCheckAccess` is
/// the only source that actually knows about the grant, so it casts the vote.
final class DeviceOpenFailureTests: XCTestCase {

    private let notPermitted = "IOHIDDeviceOpen failed (0xE00002E2)"

    func testMissingGrantIsReportedAsAPermissionProblem() {
        let failure = DeviceOpenFailure.classify(accessGranted: false, message: notPermitted)
        XCTAssertEqual(failure, .permissionMissing)
    }

    /// The case that sent us in circles: the same error code with the grant
    /// already in place is a device problem, and calling it a permission
    /// problem sends someone back to System Settings for nothing.
    func testSameErrorWithTheGrantInPlaceIsADeviceProblem() {
        let failure = DeviceOpenFailure.classify(accessGranted: true, message: notPermitted)
        XCTAssertEqual(failure, .deviceUnavailable(notPermitted))
    }

    /// Whatever we say next has to name the thing to try, because the error
    /// code on its own has already proved useless to a reader.
    func testTheDeviceMessageSuggestsSomethingToDo() {
        let advice = DeviceOpenFailure.deviceUnavailable(notPermitted).message
        XCTAssertTrue(advice.contains("reconnect") || advice.contains("unplug"),
                      "a wedged pad is fixed by reseating it, so say so: \(advice)")
        XCTAssertTrue(advice.contains(notPermitted), "keep the raw error for anyone diagnosing")
    }

    func testThePermissionMessageNamesTheSettingToLookFor() {
        let advice = DeviceOpenFailure.permissionMissing.message
        XCTAssertTrue(advice.contains("Input Monitoring"), advice)
    }

    /// Older systems phrase the denial differently, and that reading should
    /// still win over a stale access check.
    func testAnExplicitPermissionErrorIsBelievedRegardless() {
        let legacy = "IOHIDDeviceOpen failed (0xE00002C1)"
        XCTAssertEqual(DeviceOpenFailure.classify(accessGranted: true, message: legacy), .permissionMissing)
    }
}
