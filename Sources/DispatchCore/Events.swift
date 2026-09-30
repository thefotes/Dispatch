import Foundation

/// A stable identifier for an input device instance or source.
public struct DeviceIdentity: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
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

/// A logical control, independent of any vendor key code or wire representation.
public enum LogicalControl: Hashable, Sendable {
    case key(Int)
    case dial
    case joystick
}

public enum Direction: String, Codable, CaseIterable, Hashable, Sendable {
    case up
    case down
    case left
    case right
}

/// A user gesture decoded by a device driver.
public enum Gesture: Equatable, Sendable {
    case pressed
    case released
    case rotated(steps: Int)
    case moved(direction: Direction, magnitude: Double)
}

extension LogicalControl: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .key(index): "key \(index)"
        case .dial: "dial"
        case .joystick: "joystick"
        }
    }
}

extension Gesture: CustomStringConvertible {
    public var description: String {
        switch self {
        case .pressed: "pressed"
        case .released: "released"
        case let .rotated(steps): "rotated \(steps)"
        case let .moved(direction, magnitude): "moved \(direction.rawValue) \(magnitude)"
        }
    }
}

/// A device-independent input event suitable for recording and replay.
public struct DispatchEvent: Codable, Equatable, Sendable {
    public let source: DeviceIdentity
    public let control: LogicalControl
    public let gesture: Gesture
    public let timestamp: Date

    public init(
        source: DeviceIdentity,
        control: LogicalControl,
        gesture: Gesture,
        timestamp: Date
    ) {
        self.source = source
        self.control = control
        self.gesture = gesture
        self.timestamp = timestamp
    }
}

extension LogicalControl: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case index
    }

    private enum Kind: String, Codable {
        case key
        case dial
        case joystick
    }

    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(["type", "index"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .type)
        switch kind {
        case .key:
            let index = try container.decode(Int.self, forKey: .index)
            guard index >= 0 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .index,
                    in: container,
                    debugDescription: "A key index must be nonnegative."
                )
            }
            self = .key(index)
        case .dial:
            guard !container.contains(.index) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .index,
                    in: container,
                    debugDescription: "A dial does not have a key index."
                )
            }
            self = .dial
        case .joystick:
            guard !container.contains(.index) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .index,
                    in: container,
                    debugDescription: "A joystick does not have a key index."
                )
            }
            self = .joystick
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .key(index):
            try container.encode(Kind.key, forKey: .type)
            try container.encode(index, forKey: .index)
        case .dial:
            try container.encode(Kind.dial, forKey: .type)
        case .joystick:
            try container.encode(Kind.joystick, forKey: .type)
        }
    }
}

extension Gesture: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case steps
        case direction
        case magnitude
    }

    private enum Kind: String, Codable {
        case pressed
        case released
        case rotated
        case moved
    }

    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(["type", "steps", "direction", "magnitude"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .type)
        switch kind {
        case .pressed:
            try Self.rejectAssociatedValues(in: container, except: [])
            self = .pressed
        case .released:
            try Self.rejectAssociatedValues(in: container, except: [])
            self = .released
        case .rotated:
            try Self.rejectAssociatedValues(in: container, except: [.steps])
            let steps = try container.decode(Int.self, forKey: .steps)
            guard steps != 0 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .steps,
                    in: container,
                    debugDescription: "Rotation steps must be nonzero."
                )
            }
            self = .rotated(steps: steps)
        case .moved:
            try Self.rejectAssociatedValues(in: container, except: [.direction, .magnitude])
            let direction = try container.decode(Direction.self, forKey: .direction)
            let magnitude = try container.decode(Double.self, forKey: .magnitude)
            guard magnitude.isFinite, magnitude >= 0 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .magnitude,
                    in: container,
                    debugDescription: "Movement magnitude must be finite and nonnegative."
                )
            }
            self = .moved(direction: direction, magnitude: magnitude)
        }
    }

    private static func rejectAssociatedValues(
        in container: KeyedDecodingContainer<CodingKeys>,
        except allowed: Set<CodingKeys>
    ) throws {
        for key in [CodingKeys.steps, .direction, .magnitude]
            where container.contains(key) && !allowed.contains(key) {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "Field '\(key.stringValue)' is not valid for this gesture type."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pressed:
            try container.encode(Kind.pressed, forKey: .type)
        case .released:
            try container.encode(Kind.released, forKey: .type)
        case let .rotated(steps):
            try container.encode(Kind.rotated, forKey: .type)
            try container.encode(steps, forKey: .steps)
        case let .moved(direction, magnitude):
            try container.encode(Kind.moved, forKey: .type)
            try container.encode(direction, forKey: .direction)
            try container.encode(magnitude, forKey: .magnitude)
        }
    }
}
