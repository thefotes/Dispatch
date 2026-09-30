import Foundation

public struct CreatorMicroHIDReport: Sendable, Equatable {
    public static let byteCount = 64
    public static let reportIdentifier: UInt8 = 0x06
    public static let maximumPayloadCount = 61

    public let channel: UInt8
    public let payload: [UInt8]

    public init(channel: UInt8, payload: [UInt8]) throws {
        guard payload.count <= Self.maximumPayloadCount else {
            throw CreatorMicroError.invalidPayloadLength(payload.count)
        }
        self.channel = channel
        self.payload = payload
    }

    public init(bytes: [UInt8]) throws {
        guard bytes.count == Self.byteCount else {
            throw CreatorMicroError.invalidReportLength(bytes.count)
        }
        guard bytes[0] == Self.reportIdentifier else {
            throw CreatorMicroError.invalidReportIdentifier(bytes[0])
        }
        let payloadCount = Int(bytes[2])
        guard payloadCount <= Self.maximumPayloadCount else {
            throw CreatorMicroError.invalidPayloadLength(payloadCount)
        }
        channel = bytes[1]
        payload = Array(bytes[3..<(3 + payloadCount)])
    }

    public var bytes: [UInt8] {
        var result = [UInt8](repeating: 0, count: Self.byteCount)
        result[0] = Self.reportIdentifier
        result[1] = channel
        result[2] = UInt8(payload.count)
        result.replaceSubrange(3..<(3 + payload.count), with: payload)
        return result
    }

    public static func fragment(_ data: Data, channel: UInt8 = 2) throws -> [CreatorMicroHIDReport] {
        if data.isEmpty { return [try CreatorMicroHIDReport(channel: channel, payload: [])] }
        return try stride(from: 0, to: data.count, by: maximumPayloadCount).map { offset in
            let end = min(offset + maximumPayloadCount, data.count)
            return try CreatorMicroHIDReport(channel: channel, payload: Array(data[offset..<end]))
        }
    }
}

/// Finds complete top-level JSON objects while respecting strings and escapes.
/// A single report may finish one object and begin another.
public struct JSONMessageAssembler: Sendable {
    public static let maximumMessageBytes = 65_536
    private var bytes: [UInt8] = []
    private var depth = 0
    private var inString = false
    private var escaped = false
    private var collecting = false
    private var utf8ContinuationsNeeded = 0

    public init() {}

    public mutating func append(_ fragment: [UInt8]) throws -> [Data] {
        do {
            return try appendFragment(fragment)
        } catch {
            reset()
            throw error
        }
    }

    private mutating func appendFragment(_ fragment: [UInt8]) throws -> [Data] {
        var messages: [Data] = []
        for byte in fragment {
            if !collecting {
                try beginObject(with: byte)
                continue
            }

            try validateUTF8Byte(byte)
            guard bytes.count < Self.maximumMessageBytes else {
                throw CreatorMicroError.messageTooLarge
            }
            bytes.append(byte)
            if inString {
                consumeStringByte(byte)
            } else if try consumeStructuralByte(byte) {
                messages.append(try finishObject())
            }
        }
        return messages
    }

    public mutating func reset() {
        self = JSONMessageAssembler()
    }

    private mutating func validateUTF8Byte(_ byte: UInt8) throws {
        if utf8ContinuationsNeeded > 0 {
            guard byte & 0xC0 == 0x80 else { throw CreatorMicroError.invalidUTF8 }
            utf8ContinuationsNeeded -= 1
        } else if byte >= 0x80 {
            utf8ContinuationsNeeded = switch byte {
            case 0xC2...0xDF: 1
            case 0xE0...0xEF: 2
            case 0xF0...0xF4: 3
            default: throw CreatorMicroError.invalidUTF8
            }
        }
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private mutating func beginObject(with byte: UInt8) throws {
        guard !Self.isWhitespace(byte) else { return }
        guard byte == 0x7B else {
            throw CreatorMicroError.invalidJSON("Expected a top-level object")
        }
        collecting = true
        depth = 1
        bytes = [byte]
    }

    private mutating func consumeStringByte(_ byte: UInt8) {
        if escaped {
            escaped = false
        } else if byte == 0x5C {
            escaped = true
        } else if byte == 0x22 {
            inString = false
        }
    }

    private mutating func consumeStructuralByte(_ byte: UInt8) throws -> Bool {
        if byte == 0x22 {
            inString = true
        } else if byte == 0x7B {
            depth += 1
        } else if byte == 0x7D {
            depth -= 1
            guard depth >= 0 else { throw CreatorMicroError.invalidJSON("Unbalanced object") }
        }
        return depth == 0
    }

    private mutating func finishObject() throws -> Data {
        guard String(bytes: bytes, encoding: .utf8) != nil else {
            throw CreatorMicroError.invalidUTF8
        }
        let message = Data(bytes)
        bytes.removeAll(keepingCapacity: true)
        collecting = false
        return message
    }
}
