import Darwin
import Dispatch
import Foundation
import DispatchCore

public enum HerdrSocketError: Error, Sendable, Equatable {
    case invalidSocketPath
    case connectionFailed(Int32)
    case writeFailed(Int32)
    case readFailed(Int32)
    case disconnected
    case timedOut
    case responseTooLarge
    case malformedResponse
    case missingCorrelationID
    case unexpectedCorrelationID(expected: String, actual: String)
}

extension HerdrSocketError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalidSocketPath: "The Herdr socket path is invalid."
        case let .connectionFailed(code): "Could not connect to Herdr: \(String(cString: strerror(code)))."
        case let .writeFailed(code): "Could not send to Herdr: \(String(cString: strerror(code)))."
        case let .readFailed(code): "Could not read from Herdr: \(String(cString: strerror(code)))."
        case .disconnected: "Herdr closed the connection."
        case .timedOut: "Herdr did not answer in time."
        case .responseTooLarge: "Herdr's response was too large."
        case .malformedResponse: "Herdr's response was not a JSON object."
        case .missingCorrelationID: "Herdr's response had no request identifier."
        case .unexpectedCorrelationID: "Herdr answered a different request."
        }
    }
}

public enum HerdrAPIError: Error, Sendable, Equatable {
    case remote(code: String, message: String)
}

extension HerdrAPIError: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .remote(code, message): "Herdr rejected the request: \(message) (\(code))"
        }
    }
}

/// A newline-delimited JSON client. Each request uses its own connection, and
/// exchanges run on one serial I/O queue. Requests receive a fresh correlation
/// identifier and a mismatched response is rejected.
public actor HerdrUnixSocketClient {
    public struct Configuration: Sendable, Equatable {
        public var socketPath: String
        public var correlationField: String
        public var timeout: Duration
        public var maximumLineBytes: Int

        public init(
            socketPath: String,
            correlationField: String = "id",
            timeout: Duration = .seconds(2),
            maximumLineBytes: Int = 1_048_576
        ) {
            self.socketPath = socketPath
            self.correlationField = correlationField
            self.timeout = timeout
            self.maximumLineBytes = maximumLineBytes
        }
    }

    private let configuration: Configuration
    private let queue = DispatchQueue(label: "dev.dispatch.herdr-socket", qos: .userInitiated)

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// Herdr answers one request per connection and then closes it, so every
    /// request opens and closes its own connection.
    public func request(_ body: [String: JSONValue]) async throws -> [String: JSONValue] {
        let requestID = UUID().uuidString
        var correlatedBody = body
        correlatedBody[configuration.correlationField] = .string(requestID)
        let payload = try JSONEncoder().encode(JSONValue.object(correlatedBody)) + Data([0x0A])
        let fd = try connect()
        defer { Darwin.close(fd) }
        let configuration = configuration

        let data = try await performIO {
            try Self.exchange(
                descriptor: fd,
                payload: payload,
                timeout: configuration.timeout,
                maximumLineBytes: configuration.maximumLineBytes
            )
        }
        guard case let .object(response) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            throw HerdrSocketError.malformedResponse
        }
        guard case let .string(actualID)? = response[configuration.correlationField] else {
            throw HerdrSocketError.missingCorrelationID
        }
        guard actualID == requestID else {
            throw HerdrSocketError.unexpectedCorrelationID(expected: requestID, actual: actualID)
        }
        if case let .object(error)? = response["error"],
           case let .string(code)? = error["code"],
           case let .string(message)? = error["message"] {
            throw HerdrAPIError.remote(code: code, message: message)
        }
        return response
    }

    private func connect() throws -> Int32 {
        guard !configuration.socketPath.utf8.contains(0),
              configuration.socketPath.utf8.count < MemoryLayout<sockaddr_un>.size - 2 else {
            throw HerdrSocketError.invalidSocketPath
        }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HerdrSocketError.connectionFailed(errno) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0
        let length = socklen_t(pathOffset + configuration.socketPath.utf8.count + 1)
        address.sun_len = UInt8(length)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            _ = configuration.socketPath.utf8.withContiguousStorageIfAvailable { source in
                buffer.copyBytes(from: source)
            }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, length)
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(fd)
            throw HerdrSocketError.connectionFailed(code)
        }
        return fd
    }

    private func performIO<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    nonisolated private static func exchange(
        descriptor: Int32,
        payload: Data,
        timeout: Duration,
        maximumLineBytes: Int
    ) throws -> Data {
        let milliseconds = Int32(clamping: timeout.components.seconds * 1_000
            + Int64(timeout.components.attoseconds / 1_000_000_000_000_000))
        var sent = 0
        while sent < payload.count {
            try wait(descriptor: descriptor, events: Int16(POLLOUT), timeout: milliseconds)
            let count = payload.withUnsafeBytes { bytes in
                Darwin.write(descriptor, bytes.baseAddress! + sent, payload.count - sent)
            }
            guard count > 0 else { throw HerdrSocketError.writeFailed(errno) }
            sent += count
        }

        var result = Data()
        let chunkSize = 16 * 1_024
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while result.count <= maximumLineBytes {
            try wait(descriptor: descriptor, events: Int16(POLLIN), timeout: milliseconds)
            let count = Darwin.recv(descriptor, &buffer, buffer.count, MSG_PEEK)
            if count == 0 { throw HerdrSocketError.disconnected }
            guard count > 0 else { throw HerdrSocketError.readFailed(errno) }

            let available = buffer.prefix(count)
            let newlineOffset = available.firstIndex(of: 0x0A)
            let consumeCount = newlineOffset.map { $0 + 1 } ?? count
            let payloadCount = newlineOffset ?? count
            guard result.count + payloadCount <= maximumLineBytes else {
                throw HerdrSocketError.responseTooLarge
            }

            let consumed = Darwin.read(descriptor, &buffer, consumeCount)
            if consumed == 0 { throw HerdrSocketError.disconnected }
            guard consumed > 0 else { throw HerdrSocketError.readFailed(errno) }
            let received = buffer.prefix(consumed)
            if let newline = received.firstIndex(of: 0x0A) {
                result.append(contentsOf: received.prefix(upTo: newline))
                return result
            }
            result.append(contentsOf: received)
        }
        throw HerdrSocketError.responseTooLarge
    }

    nonisolated private static func wait(descriptor: Int32, events: Int16, timeout: Int32) throws {
        var pollDescriptor = pollfd(fd: descriptor, events: events, revents: 0)
        let result = Darwin.poll(&pollDescriptor, 1, timeout)
        if result == 0 { throw HerdrSocketError.timedOut }
        guard result > 0 else {
            throw events == Int16(POLLOUT) ? HerdrSocketError.writeFailed(errno) : HerdrSocketError.readFailed(errno)
        }
        if pollDescriptor.revents & events != 0 {
            return
        }
        if pollDescriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
            throw HerdrSocketError.disconnected
        }
        throw HerdrSocketError.disconnected
    }
}
