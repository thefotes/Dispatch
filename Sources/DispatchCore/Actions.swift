import Foundation

public struct ActionID: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum ActionArgumentType: String, Codable, Hashable, Sendable {
    case boolean
    case integer
    case number
    case string
    case array
    case object
}

public struct ActionArgumentDefinition: Codable, Equatable, Sendable {
    public let name: String
    public let type: ActionArgumentType
    public let required: Bool
    public let summary: String

    public init(name: String, type: ActionArgumentType, required: Bool = true, summary: String) {
        self.name = name
        self.type = type
        self.required = required
        self.summary = summary
    }
}

/// User-facing metadata and the argument contract for one supported action.
public struct ActionDefinition: Codable, Equatable, Sendable {
    public let id: ActionID
    public let title: String
    public let summary: String
    public let arguments: [ActionArgumentDefinition]

    public init(
        id: ActionID,
        title: String,
        summary: String,
        arguments: [ActionArgumentDefinition] = []
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.arguments = arguments
    }
}

/// A concrete action request whose arguments have been validated against a catalog.
public struct ActionInvocation: Codable, Equatable, Sendable {
    public let id: ActionID
    public let arguments: [String: JSONValue]
}

public enum ActionCatalogError: Error, Equatable, Sendable {
    case duplicateAction(ActionID)
    case invalidActionID(ActionID)
    case duplicateArgument(action: ActionID, argument: String)
}

public enum ActionValidationError: Error, Equatable, Sendable {
    case unsupportedAction(ActionID)
    case missingArgument(String)
    case unknownArgument(String)
    case invalidArgumentType(name: String, expected: ActionArgumentType)
}

/// An immutable catalog used to reconcile configuration with installed integrations.
public struct ActionCatalog: Sendable {
    private let definitionsByID: [ActionID: ActionDefinition]

    public var definitions: [ActionDefinition] {
        definitionsByID.values.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    public init(definitions: [ActionDefinition]) throws {
        var indexed: [ActionID: ActionDefinition] = [:]
        for definition in definitions {
            guard Self.isValid(definition.id) else {
                throw ActionCatalogError.invalidActionID(definition.id)
            }
            guard indexed[definition.id] == nil else {
                throw ActionCatalogError.duplicateAction(definition.id)
            }
            let names = definition.arguments.map(\.name)
            var seenNames = Set<String>()
            if let duplicate = names.first(where: { !seenNames.insert($0).inserted }) {
                throw ActionCatalogError.duplicateArgument(action: definition.id, argument: duplicate)
            }
            indexed[definition.id] = definition
        }
        definitionsByID = indexed
    }

    public func definition(for id: ActionID) -> ActionDefinition? {
        definitionsByID[id]
    }

    public func makeInvocation(
        id: ActionID,
        arguments: [String: JSONValue] = [:]
    ) throws -> ActionInvocation {
        guard let definition = definitionsByID[id] else {
            throw ActionValidationError.unsupportedAction(id)
        }
        let argumentDefinitions = Dictionary(
            uniqueKeysWithValues: definition.arguments.map { ($0.name, $0) }
        )
        for argument in definition.arguments where argument.required && arguments[argument.name] == nil {
            throw ActionValidationError.missingArgument(argument.name)
        }
        for (name, value) in arguments {
            guard let argument = argumentDefinitions[name] else {
                throw ActionValidationError.unknownArgument(name)
            }
            guard argument.type.accepts(value) else {
                throw ActionValidationError.invalidArgumentType(
                    name: name,
                    expected: argument.type
                )
            }
        }
        return ActionInvocation(id: id, arguments: arguments)
    }

    private static func isValid(_ id: ActionID) -> Bool {
        let components = id.rawValue.split(separator: ".", omittingEmptySubsequences: false)
        return components.count >= 2 && components.allSatisfy { component in
            !component.isEmpty && component.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        }
    }
}

/// An executable integration capability paired with its declarative definition.
///
/// Registrations belong at the composition boundary. Their handlers receive only a
/// validated invocation and therefore cannot inspect the originating device event or
/// user configuration.
public struct ActionRegistration: Sendable {
    public typealias Availability = @Sendable () async -> Bool
    public typealias Handler = @Sendable (ActionInvocation) async throws -> Void

    public let definition: ActionDefinition
    private let availability: Availability
    private let handler: Handler

    public init(
        definition: ActionDefinition,
        isAvailable: @escaping Availability = { true },
        handler: @escaping Handler
    ) {
        self.definition = definition
        availability = isAvailable
        self.handler = handler
    }

    func canExecute() async -> Bool {
        await availability()
    }

    func execute(_ invocation: ActionInvocation) async throws {
        try await handler(invocation)
    }
}

public enum ActionExecutionError: Error, Equatable, Sendable {
    case unsupported(ActionID)
    case unavailable(ActionID)
    case invalidInvocation(action: ActionID, message: String)
    case failed(action: ActionID, message: String)
}

/// Descriptions omit the action identifier, which callers already show beside them.
extension ActionExecutionError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .unsupported: "No integration handles this action."
        case .unavailable: "The integration is not available right now."
        case let .invalidInvocation(_, message): "Invalid arguments: \(message)"
        case let .failed(_, message): message
        }
    }
}

/// A coherent execution boundary assembled from integration registrations.
public actor ActionRegistry {
    nonisolated public let catalog: ActionCatalog
    private let registrations: [ActionID: ActionRegistration]

    public init(registrations: [ActionRegistration]) throws {
        catalog = try ActionCatalog(definitions: registrations.map(\.definition))
        self.registrations = Dictionary(
            uniqueKeysWithValues: registrations.map { ($0.definition.id, $0) }
        )
    }

    public func execute(_ invocation: ActionInvocation) async throws {
        guard let registration = registrations[invocation.id] else {
            throw ActionExecutionError.unsupported(invocation.id)
        }
        guard await registration.canExecute() else {
            throw ActionExecutionError.unavailable(invocation.id)
        }
        do {
            _ = try catalog.makeInvocation(id: invocation.id, arguments: invocation.arguments)
        } catch {
            throw ActionExecutionError.invalidInvocation(
                action: invocation.id,
                message: String(describing: error)
            )
        }
        do {
            try await registration.execute(invocation)
        } catch let error as ActionExecutionError {
            throw error
        } catch {
            throw ActionExecutionError.failed(
                action: invocation.id,
                message: String(describing: error)
            )
        }
    }
}

extension ActionArgumentType {
    func accepts(_ value: JSONValue) -> Bool {
        switch (self, value) {
        case (.boolean, .boolean), (.integer, .integer), (.string, .string),
             (.array, .array), (.object, .object):
            true
        case (.number, .integer), (.number, .number):
            true
        default:
            false
        }
    }
}
