import Foundation
import DispatchCore

public actor RecordingMacOSAutomation: MacOSAutomating {
    private var operations: [MacOSOperation] = []
    private let permission: AccessibilityPermission
    private var permissionPrompts: [Bool] = []

    public init(permission: AccessibilityPermission = .granted) {
        self.permission = permission
    }

    public func perform(_ operation: MacOSOperation) {
        operations.append(operation)
    }

    public func perform(_ invocation: ActionInvocation) throws {
        operations.append(try MacOSActions.decode(invocation))
    }

    public func accessibilityPermission(promptIfNeeded: Bool) -> AccessibilityPermission {
        permissionPrompts.append(promptIfNeeded)
        return permission
    }

    public func recordedOperations() -> [MacOSOperation] { operations }
    public func recordedPermissionChecks() -> [Bool] { permissionPrompts }
}
