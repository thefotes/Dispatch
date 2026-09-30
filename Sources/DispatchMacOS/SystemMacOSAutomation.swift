@preconcurrency import AppKit
@preconcurrency import ApplicationServices
import Foundation
import DispatchCore

public actor SystemMacOSAutomation: MacOSAutomating {
    public init() {}

    public func perform(_ operation: MacOSOperation) async throws {
        switch operation {
        case let .shortcut(shortcut):
            try post(shortcut)
        case let .typeText(text):
            try type(text)
        case let .activate(target):
            try await activate(target)
        case let .focusWindow(target):
            try await focusWindow(target)
        case let .wait(duration):
            try await Task.sleep(for: duration)
        case let .macro(operations):
            for operation in operations { try await perform(operation) }
        }
    }

    public func perform(_ invocation: ActionInvocation) async throws {
        try await perform(MacOSActions.decode(invocation))
    }

    public func accessibilityPermission(promptIfNeeded: Bool) -> AccessibilityPermission {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: promptIfNeeded] as CFDictionary
        return AXIsProcessTrustedWithOptions(options) ? .granted : .denied
    }

    private func post(_ shortcut: KeyboardShortcut) throws {
        guard accessibilityPermission(promptIfNeeded: false) == .granted else {
            throw MacOSAutomationError.accessibilityPermissionDenied
        }
        let keyCode = shortcut.key.keyCode
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            throw MacOSAutomationError.eventCreationFailed
        }
        let flags = shortcut.modifiers.eventFlags
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func type(_ text: String) throws {
        guard accessibilityPermission(promptIfNeeded: false) == .granted else {
            throw MacOSAutomationError.accessibilityPermissionDenied
        }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
            throw MacOSAutomationError.eventCreationFailed
        }
        let characters = Array(text.utf16)
        characters.withUnsafeBufferPointer {
            down.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: $0.baseAddress)
            up.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: $0.baseAddress)
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func activate(_ target: ApplicationTarget) async throws {
        let app = await MainActor.run {
            NSRunningApplication.runningApplications(withBundleIdentifier: target.bundleIdentifier).first
        }
        guard let app else { throw MacOSAutomationError.applicationNotRunning(target.bundleIdentifier) }
        guard await !MainActor.run(body: { app.isActive }) else { return }
        await MainActor.run { _ = app.activate(options: [.activateAllWindows]) }
        // Activation completes asynchronously; keys posted before it finishes
        // reach the previously active application.
        for _ in 0..<50 {
            if await MainActor.run(body: { app.isActive }) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func focusWindow(_ target: WindowTarget) async throws {
        try await activate(target.application)
        let app = await MainActor.run {
            NSRunningApplication.runningApplications(withBundleIdentifier: target.application.bundleIdentifier).first
        }
        guard let app else {
            throw MacOSAutomationError.applicationNotRunning(target.application.bundleIdentifier)
        }
        guard accessibilityPermission(promptIfNeeded: false) == .granted else {
            throw MacOSAutomationError.accessibilityPermissionDenied
        }

        var value: CFTypeRef?
        let applicationElement = AXUIElementCreateApplication(app.processIdentifier)
        let result = AXUIElementCopyAttributeValue(applicationElement, kAXWindowsAttribute as CFString, &value)
        guard result == .success else { throw MacOSAutomationError.accessibilityFailure(result.rawValue) }
        let windows = value as? [AXUIElement] ?? []
        for window in windows {
            var titleValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue) == .success,
                  let title = titleValue as? String,
                  title == target.title else { continue }
            let focused = kCFBooleanTrue as CFTypeRef
            let focusResult = AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, focused)
            guard focusResult == .success else {
                throw MacOSAutomationError.accessibilityFailure(focusResult.rawValue)
            }
            _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            return
        }
        throw MacOSAutomationError.windowNotFound(target.title)
    }
}

private extension KeyboardKey {
    var keyCode: CGKeyCode {
        switch self {
        case .a: 0
        case .s: 1
        case .d: 2
        case .f: 3
        case .h: 4
        case .g: 5
        case .z: 6
        case .x: 7
        case .c: 8
        case .v: 9
        case .b: 11
        case .q: 12
        case .w: 13
        case .e: 14
        case .r: 15
        case .y: 16
        case .t: 17
        case .one: 18
        case .two: 19
        case .three: 20
        case .four: 21
        case .six: 22
        case .five: 23
        case .nine: 25
        case .seven: 26
        case .eight: 28
        case .zero: 29
        case .o: 31
        case .u: 32
        case .i: 34
        case .p: 35
        case .l: 37
        case .j: 38
        case .k: 40
        case .n: 45
        case .m: 46
        case .returnKey: 36
        case .tab: 48
        case .space: 49
        case .delete: 51
        case .escape: 53
        case .rightCommand: 54
        case .leftArrow: 123
        case .rightArrow: 124
        case .downArrow: 125
        case .upArrow: 126
        case .f13: 105
        case .f14: 107
        case .f15: 113
        case .f16: 106
        case .f17: 64
        case .f18: 79
        case .f19: 80
        }
    }
}

private extension Set where Element == ShortcutModifier {
    var eventFlags: CGEventFlags {
        reduce(into: CGEventFlags()) { flags, modifier in
            switch modifier {
            case .command: flags.insert(.maskCommand)
            case .option: flags.insert(.maskAlternate)
            case .control: flags.insert(.maskControl)
            case .shift: flags.insert(.maskShift)
            case .function: flags.insert(.maskSecondaryFn)
            }
        }
    }
}
