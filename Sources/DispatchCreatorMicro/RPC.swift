import DispatchCore
import Foundation

public struct CreatorMicroRPCCall: Sendable, Equatable, Codable {
    public let id: Int
    public let method: String
    public let parameters: JSONValue?

    public init(id: Int, method: String, parameters: JSONValue? = nil) {
        self.id = id
        self.method = method
        self.parameters = parameters
    }

    private enum CodingKeys: String, CodingKey { case id, method = "m", parameters = "p" }
}

public enum CreatorMicroRPCMessage: Sendable, Equatable {
    case response(id: Int, result: JSONValue?, error: RemoteError?)
    case notification(method: String, parameters: JSONValue?)

    public struct RemoteError: Sendable, Equatable, Codable {
        public let code: Int?
        public let message: String

        public init(code: Int? = nil, message: String) {
            self.code = code
            self.message = message
        }
    }

    public static func decode(_ data: Data) throws -> CreatorMicroRPCMessage {
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw CreatorMicroError.invalidJSON(error.localizedDescription)
        }
        guard let object = value.objectValue else {
            throw CreatorMicroError.malformedEnvelope("Envelope is not an object")
        }
        if let id = object["id"]?.intValue {
            let remoteError: RemoteError?
            if let errorObject = object["error"]?.objectValue {
                remoteError = RemoteError(
                    code: errorObject["code"]?.intValue,
                    message: errorObject["message"]?.stringValue ?? "Remote error"
                )
            } else {
                remoteError = nil
            }
            return .response(id: id, result: object["result"] ?? object["r"], error: remoteError)
        }
        guard let method = object["m"]?.stringValue else {
            throw CreatorMicroError.malformedEnvelope("Envelope has neither id nor method")
        }
        return .notification(method: method, parameters: object["p"])
    }
}

public struct RequestIDAllocator: Sendable {
    public static let validIDs = 0..<1000
    private var next = 0
    private var allocated: Set<Int> = []

    public init(startingAt: Int = 0) {
        next = Self.validIDs.contains(startingAt) ? startingAt : 0
    }

    public mutating func allocate() throws -> Int {
        guard allocated.count < Self.validIDs.count else {
            throw CreatorMicroError.requestIdentifiersExhausted
        }
        for _ in Self.validIDs {
            let candidate = next
            next = (next + 1) % Self.validIDs.count
            if allocated.insert(candidate).inserted { return candidate }
        }
        throw CreatorMicroError.requestIdentifiersExhausted
    }

    public mutating func release(_ id: Int) {
        allocated.remove(id)
    }

    public func owns(_ id: Int) -> Bool { allocated.contains(id) }
}
