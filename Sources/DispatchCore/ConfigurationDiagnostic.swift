import Foundation

/// Describes a configuration error in one plain sentence that says where in
/// `config.json` the problem is, as a path such as
/// `bindings[2].actions[0].arguments`, for the menu-bar panel. Logs keep the
/// full error.
public enum ConfigurationDiagnostic {
    public static func message(for error: any Error) -> String {
        switch error {
        case let error as DecodingError:
            message(for: error)
        case let error as ConfigurationError:
            message(for: error)
        default:
            (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private static func message(for error: DecodingError) -> String {
        switch error {
        case let .dataCorrupted(context) where context.codingPath.isEmpty && context.underlyingError != nil:
            let detail = (context.underlyingError as? NSError)?
                .userInfo[NSDebugDescriptionErrorKey] as? String
            return detail.map { "The file isn't valid JSON: \($0)" } ?? "The file isn't valid JSON."
        case let .dataCorrupted(context):
            return at(context.codingPath, context.debugDescription)
        case let .keyNotFound(key, context):
            return at(context.codingPath, "Missing field \"\(key.stringValue)\".")
        case let .typeMismatch(type, context), let .valueNotFound(type, context):
            return at(context.codingPath, "Expected \(expectation(for: type)).")
        @unknown default:
            return error.localizedDescription
        }
    }

    private static func message(for error: ConfigurationError) -> String {
        switch error {
        case let .unsupportedVersion(version):
            "At version: Dispatch reads version \(DispatchConfiguration.currentVersion), not \(version)."
        case let .emptyMacro(binding):
            "At bindings[\(binding)].actions: List at least one action."
        case let .ambiguousBindings(first, second):
            "At bindings[\(first)] and bindings[\(second)]: Both respond to the same input. Change or remove one."
        case let .unsupportedAction(binding, action, id):
            "At bindings[\(binding)].actions[\(action)].id: Unknown action \"\(id.rawValue)\"."
        case let .missingArgument(binding, action, name):
            "At bindings[\(binding)].actions[\(action)].arguments: Missing argument \"\(name)\"."
        case let .unknownArgument(binding, action, name):
            "At bindings[\(binding)].actions[\(action)].arguments: Unknown argument \"\(name)\"."
        case let .invalidArgumentType(binding, action, name, expected):
            "At bindings[\(binding)].actions[\(action)].arguments.\(name): Expected \(expectation(for: expected))."
        }
    }

    private static func at(_ codingPath: [any CodingKey], _ problem: String) -> String {
        "At \(path(codingPath)): \(problem)"
    }

    /// `bindings[0].when.gesture`, or "the top level" for an empty path.
    private static func path(_ codingPath: [any CodingKey]) -> String {
        guard !codingPath.isEmpty else { return "the top level" }
        return codingPath.reduce(into: "") { path, key in
            if let index = key.intValue {
                path += "[\(index)]"
            } else {
                path += path.isEmpty ? key.stringValue : ".\(key.stringValue)"
            }
        }
    }

    private static func expectation(for type: Any.Type) -> String {
        switch type {
        case is any BinaryInteger.Type: "a whole number"
        case is any BinaryFloatingPoint.Type: "a number"
        case is String.Type: "text in quotes"
        case is Bool.Type: "true or false"
        default: String(describing: type).hasPrefix("Array") ? "a list" : "an object"
        }
    }

    private static func expectation(for type: ActionArgumentType) -> String {
        switch type {
        case .boolean: "true or false"
        case .integer: "a whole number"
        case .number: "a number"
        case .string: "text in quotes"
        case .array: "a list"
        case .object: "an object"
        }
    }
}
