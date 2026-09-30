import Foundation
import IOKit.hid

public enum InputMonitoringPermission: Sendable, Equatable {
    case granted
    case denied
}

/// Input Monitoring is a process-wide TCC grant, so callers can check and
/// request it independently of any live HID transport. Production talks to
/// IOHID; tests provide a recording double.
public protocol InputMonitoringPermissionRequesting: Sendable {
    func check() async -> InputMonitoringPermission
    func request() async -> InputMonitoringPermission
}

/// The production requester. `IOHIDRequestAccess` presents the system prompt
/// and must run on the main thread; checking is harmless anywhere but is kept
/// there too so the answer is read consistently.
public struct IOHIDInputMonitoringPermissionRequester: InputMonitoringPermissionRequesting {
    public init() {}

    public func check() async -> InputMonitoringPermission {
        await MainActor.run {
            IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted ? .granted : .denied
        }
    }

    public func request() async -> InputMonitoringPermission {
        await MainActor.run {
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) ? .granted : .denied
        }
    }
}

extension InputMonitoringPermissionRequesting {
    /// Checks first and only prompts when the grant is missing, so repeated
    /// calls never re-raise the system dialog.
    public func requestIfNeeded() async -> InputMonitoringPermission {
        let current = await check()
        guard current == .denied else { return current }
        return await request()
    }
}
