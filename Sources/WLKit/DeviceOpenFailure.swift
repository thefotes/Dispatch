import Foundation

/// Why the pad would not open, in terms someone can act on.
///
/// `IOHIDDeviceOpen` returns `kIOReturnNotPermitted` (0xE00002E2) for a missing
/// Input Monitoring grant *and* for a device that is already held or has got
/// itself wedged, so reading the code alone gets it wrong half the time. The
/// original check only recognised the older 0xE00002C1, so on current systems a
/// permissions failure fell through and the menu simply said it was looking for
/// the pad, which sends you hunting for a cable when the answer is a checkbox.
public enum DeviceOpenFailure: Equatable {
    case permissionMissing
    case deviceUnavailable(String)

    /// `accessGranted` comes from `IOHIDCheckAccess`, the only caller that
    /// actually knows the state of the grant. An error that names a permission
    /// outright is still believed, in case the check itself is stale.
    public static func classify(accessGranted: Bool, message: String) -> DeviceOpenFailure {
        if message.contains("0xE00002C1") || message.contains("Input Monitoring") {
            return .permissionMissing
        }
        return accessGranted ? .deviceUnavailable(message) : .permissionMissing
    }

    public var message: String {
        switch self {
        case .permissionMissing:
            return "Input Monitoring is not granted. System Settings › Privacy & Security › Input Monitoring, then switch the manager off and on."
        case .deviceUnavailable(let underlying):
            return "The pad did not open. Something else may be holding it, or it needs a reconnect - unplug it, wait a moment, plug it back in. (\(underlying))"
        }
    }
}
