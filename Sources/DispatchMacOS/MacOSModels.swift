import Foundation
import DispatchCore

public enum ShortcutModifier: String, Sendable, Codable, CaseIterable {
    case command
    case option
    case control
    case shift
    case function
}

// Single-character cases deliberately match the stable user-facing configuration spelling.
// swiftlint:disable identifier_name
public enum KeyboardKey: String, Sendable, Codable, CaseIterable {
    case a, b, c, d, e, f, g, h, i, j, k, l, m
    case n, o, p, q, r, s, t, u, v, w, x, y, z
    case zero, one, two, three, four, five, six, seven, eight, nine
    case returnKey = "return"
    case escape, tab, space, delete
    case leftArrow, rightArrow, downArrow, upArrow
    case rightCommand
    case f13, f14, f15, f16, f17, f18, f19
}
// swiftlint:enable identifier_name

public struct KeyboardShortcut: Sendable, Equatable, Codable {
    public var key: KeyboardKey
    public var modifiers: Set<ShortcutModifier>

    public init(key: KeyboardKey, modifiers: Set<ShortcutModifier> = []) {
        self.key = key
        self.modifiers = modifiers
    }
}

public struct ApplicationTarget: Sendable, Equatable, Codable {
    public var bundleIdentifier: String

    public init(bundleIdentifier: String) {
        self.bundleIdentifier = bundleIdentifier
    }
}

public struct WindowTarget: Sendable, Equatable, Codable {
    public var application: ApplicationTarget
    public var title: String

    public init(application: ApplicationTarget, title: String) {
        self.application = application
        self.title = title
    }
}

public indirect enum MacOSOperation: Sendable, Equatable {
    case shortcut(KeyboardShortcut)
    case typeText(String)
    case activate(ApplicationTarget)
    case focusWindow(WindowTarget)
    case wait(Duration)
    case macro([MacOSOperation])

    public var identifier: String {
        switch self {
        case .shortcut: "keyboard.shortcut"
        case .typeText: "keyboard.typeText"
        case .activate: "application.activate"
        case .focusWindow: "application.focusWindow"
        case .wait: "macro.wait"
        case .macro: "macro.sequence"
        }
    }
}

public enum AccessibilityPermission: Sendable, Equatable {
    case granted
    case denied
}

/// One useful substitution boundary for automation that can control the Mac.
public protocol MacOSAutomating: Sendable {
    func perform(_ operation: MacOSOperation) async throws
    func accessibilityPermission(promptIfNeeded: Bool) async -> AccessibilityPermission
}

public enum MacOSAutomationError: Error, Sendable, Equatable {
    case accessibilityPermissionDenied
    case eventCreationFailed
    case applicationNotRunning(String)
    case windowNotFound(String)
    case accessibilityFailure(Int32)
}

public enum MacOSIntegrationError: Error, Sendable, Equatable {
    case unsupportedAction(ActionID)
    case missingArgument(action: ActionID, name: String)
    case invalidArgument(action: ActionID, name: String)
}

public enum MacOSActions {
    public static let shortcut: ActionID = "keyboard.shortcut"
    public static let typeText: ActionID = "keyboard.typeText"
    public static let activateApplication: ActionID = "application.activate"
    public static let focusWindow: ActionID = "application.focusWindow"
    public static let macroSequence: ActionID = "macro.sequence"

    public static let definitions: [ActionDefinition] = [
        .init(
            id: shortcut,
            title: "Keyboard Shortcut",
            summary: "Sends a keyboard shortcut through macOS.",
            arguments: [
                .init(name: "key", type: .string, summary: "Key name."),
                .init(name: "modifiers", type: .array, required: false, summary: "Modifier names.")
            ]
        ),
        .init(
            id: typeText,
            title: "Type Text",
            summary: "Types Unicode text through macOS.",
            arguments: [.init(name: "text", type: .string, summary: "Text to type.")]
        ),
        .init(
            id: activateApplication,
            title: "Activate Application",
            summary: "Activates a running application.",
            arguments: [.init(name: "bundleIdentifier", type: .string, summary: "Application bundle identifier.")]
        ),
        .init(
            id: focusWindow,
            title: "Focus Application Window",
            summary: "Focuses a window with an exact title in a running application.",
            arguments: [
                .init(name: "bundleIdentifier", type: .string, summary: "Application bundle identifier."),
                .init(name: "title", type: .string, summary: "Exact window title.")
            ]
        ),
        .init(
            id: macroSequence,
            title: "Automation Macro",
            summary: "Executes an ordered sequence of macOS automation operations.",
            arguments: [.init(name: "operations", type: .array, summary: "Ordered operation objects.")]
        )
    ]

    public static func decode(_ invocation: ActionInvocation) throws -> MacOSOperation {
        switch invocation.id {
        case shortcut:
            let keyName = try string("key", in: invocation)
            guard let key = KeyboardKey(rawValue: keyName) else {
                throw MacOSIntegrationError.invalidArgument(action: invocation.id, name: "key")
            }
            let modifiers = try optionalStringArray("modifiers", in: invocation).map { values in
                Swift.Set<ShortcutModifier>(try values.map { value in
                    guard let modifier = ShortcutModifier(rawValue: value) else {
                        throw MacOSIntegrationError.invalidArgument(action: invocation.id, name: "modifiers")
                    }
                    return modifier
                })
            } ?? []
            return .shortcut(.init(key: key, modifiers: modifiers))
        case typeText:
            return .typeText(try string("text", in: invocation))
        case activateApplication:
            return .activate(.init(bundleIdentifier: try string("bundleIdentifier", in: invocation)))
        case focusWindow:
            return .focusWindow(.init(
                application: .init(bundleIdentifier: try string("bundleIdentifier", in: invocation)),
                title: try string("title", in: invocation)
            ))
        case macroSequence:
            guard case let .array(values)? = invocation.arguments["operations"] else {
                throw MacOSIntegrationError.missingArgument(action: invocation.id, name: "operations")
            }
            return .macro(try values.map { try decodeOperation($0, action: invocation.id) })
        default:
            throw MacOSIntegrationError.unsupportedAction(invocation.id)
        }
    }

    public static func registrations(automation: any MacOSAutomating) -> [ActionRegistration] {
        definitions.map { definition in
            ActionRegistration(
                definition: definition,
                isAvailable: {
                    if definition.id == activateApplication { return true }
                    return await automation.accessibilityPermission(promptIfNeeded: false) == .granted
                },
                handler: { invocation in
                    try await automation.perform(decode(invocation))
                }
            )
        }
    }

    private static func string(_ name: String, in invocation: ActionInvocation) throws -> String {
        guard let value = invocation.arguments[name] else {
            throw MacOSIntegrationError.missingArgument(action: invocation.id, name: name)
        }
        guard case let .string(string) = value else {
            throw MacOSIntegrationError.invalidArgument(action: invocation.id, name: name)
        }
        return string
    }

    private static func optionalStringArray(_ name: String, in invocation: ActionInvocation) throws -> [String]? {
        guard let value = invocation.arguments[name] else { return nil }
        guard case let .array(values) = value else {
            throw MacOSIntegrationError.invalidArgument(action: invocation.id, name: name)
        }
        return try values.map {
            guard case let .string(value) = $0 else {
                throw MacOSIntegrationError.invalidArgument(action: invocation.id, name: name)
            }
            return value
        }
    }

    // Each supported declarative macro operation is intentionally handled explicitly.
    // swiftlint:disable:next cyclomatic_complexity
    private static func decodeOperation(_ value: JSONValue, action: ActionID) throws -> MacOSOperation {
        guard case let .object(object) = value,
              case let .string(kind)? = object["action"] else {
            throw MacOSIntegrationError.invalidArgument(action: action, name: "operations")
        }
        switch kind {
        case "keyboard.shortcut":
            guard case let .string(keyName)? = object["key"], let key = KeyboardKey(rawValue: keyName) else {
                throw MacOSIntegrationError.invalidArgument(action: action, name: "operations")
            }
            let values: [String]
            if case let .array(items)? = object["modifiers"] {
                values = try items.map {
                    guard case let .string(value) = $0 else {
                        throw MacOSIntegrationError.invalidArgument(action: action, name: "operations")
                    }
                    return value
                }
            } else { values = [] }
            let modifiers = Swift.Set<ShortcutModifier>(try values.map {
                guard let value = ShortcutModifier(rawValue: $0) else {
                    throw MacOSIntegrationError.invalidArgument(action: action, name: "operations")
                }
                return value
            })
            return .shortcut(.init(key: key, modifiers: modifiers))
        case "keyboard.typeText":
            guard case let .string(text)? = object["text"] else {
                throw MacOSIntegrationError.invalidArgument(action: action, name: "operations")
            }
            return .typeText(text)
        case "application.activate":
            guard case let .string(id)? = object["bundleIdentifier"] else {
                throw MacOSIntegrationError.invalidArgument(action: action, name: "operations")
            }
            return .activate(.init(bundleIdentifier: id))
        case "macro.wait":
            guard case let .integer(milliseconds)? = object["milliseconds"], milliseconds >= 0 else {
                throw MacOSIntegrationError.invalidArgument(action: action, name: "operations")
            }
            return .wait(.milliseconds(milliseconds))
        default:
            throw MacOSIntegrationError.invalidArgument(action: action, name: "operations")
        }
    }
}
