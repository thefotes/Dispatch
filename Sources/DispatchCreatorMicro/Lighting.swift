import DispatchCore
import Foundation

public struct CreatorMicroColor: Sendable, Equatable, Codable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public var packedRGB: Int { Int(red) << 16 | Int(green) << 8 | Int(blue) }
    public static let black = CreatorMicroColor(red: 0, green: 0, blue: 0)
}

/// The firmware's `e` values, with what each did on firmware 0.6.2
/// (observed 2026-09-24; see docs/protocol/creator-micro-2.md).
public enum CreatorMicroLightingEffect: Int, Sendable, Codable {
    case off = 0
    case solid = 1
    /// Underglow only: a pattern moving around the pad. Nothing on a key.
    case snake = 2
    /// Cycles through colors, pulsing on a key and moving on the underglow.
    case rainbow = 3
    /// Pulses; needs a speed above zero.
    case breath = 4
    /// Underglow only: one steady color, or every color with `m` 255.
    case gradient = 5
    /// Pulses like `breath`; no difference was visible side by side.
    case shallowBreath = 6
}

public struct CreatorMicroLight: Sendable, Equatable, Codable {
    public var color: CreatorMicroColor
    public var brightness: UInt8
    public var effect: CreatorMicroLightingEffect
    public var speed: UInt8
    public var magic: UInt8

    public init(
        color: CreatorMicroColor,
        brightness: UInt8 = 255,
        effect: CreatorMicroLightingEffect = .solid,
        speed: UInt8 = 0,
        magic: UInt8 = 0
    ) {
        self.color = color
        self.brightness = brightness
        self.effect = effect
        self.speed = speed
        self.magic = magic
    }

    public static let off = CreatorMicroLight(color: .black, brightness: 0, effect: .off)
}

public struct CreatorMicroLightingFrame: Sendable, Equatable {
    public var threads: [Int: CreatorMicroLight]
    public var keyZone: CreatorMicroLight
    public var ambientZone: CreatorMicroLight

    public init(
        threads: [Int: CreatorMicroLight] = [:],
        keyZone: CreatorMicroLight = .off,
        ambientZone: CreatorMicroLight = .off
    ) {
        self.threads = threads
        self.keyZone = keyZone
        self.ambientZone = ambientZone
    }

    public static let cleared = CreatorMicroLightingFrame()
}

public struct CreatorMicroLightingUpdate: Sendable, Equatable {
    public let threadParameters: JSONValue?
    public let zoneParameters: JSONValue?

    public init(threadParameters: JSONValue?, zoneParameters: JSONValue?) {
        self.threadParameters = threadParameters
        self.zoneParameters = zoneParameters
    }
}

public enum CreatorMicroLightingEncoder {
    public static func update(
        from previous: CreatorMicroLightingFrame?,
        to desired: CreatorMicroLightingFrame
    ) -> CreatorMicroLightingUpdate {
        let old = previous ?? .cleared
        let ids: Set<Int>
        if previous == nil {
            ids = Set(CreatorMicroGeometry.lightThreads).union(desired.threads.keys)
        } else {
            ids = Set(old.threads.keys).union(desired.threads.keys)
        }
        let changes = ids.sorted().compactMap { id -> JSONValue? in
            let oldLight = old.threads[id] ?? .off
            let newLight = desired.threads[id] ?? .off
            guard previous == nil || oldLight != newLight else { return nil }
            return thread(id: id, light: newLight)
        }
        let zonesChanged = previous == nil || old.keyZone != desired.keyZone || old.ambientZone != desired.ambientZone
        return CreatorMicroLightingUpdate(
            threadParameters: changes.isEmpty ? nil : .array(changes),
            zoneParameters: zonesChanged ? .object([
                "keys": light(desired.keyZone),
                "ambient": light(desired.ambientZone)
            ]) : nil
        )
    }

    /// Clearing is deliberately exhaustive because thread colors override zones.
    public static func clearAll() -> CreatorMicroLightingUpdate {
        CreatorMicroLightingUpdate(
            threadParameters: .array(CreatorMicroGeometry.lightThreads.map { thread(id: $0, light: .off) }),
            zoneParameters: .object(["keys": light(.off), "ambient": light(.off)])
        )
    }

    private static func thread(id: Int, light value: CreatorMicroLight) -> JSONValue {
        var object = light(value).objectValue!
        object["id"] = .number(Double(id))
        return .object(object)
    }

    private static func light(_ value: CreatorMicroLight) -> JSONValue {
        .object([
            "c": .number(Double(value.color.packedRGB)),
            "b": .number(Double(value.brightness)),
            "e": .number(Double(value.effect.rawValue)),
            "s": .number(Double(value.speed)),
            "m": .number(Double(value.magic))
        ])
    }
}

public struct CreatorMicroLightingReconciler: Sendable {
    public private(set) var lastApplied: CreatorMicroLightingFrame?

    public init() {}

    public mutating func prepare(_ desired: CreatorMicroLightingFrame) -> CreatorMicroLightingUpdate {
        CreatorMicroLightingEncoder.update(from: lastApplied, to: desired)
    }

    public mutating func recordSuccessfulApplication(_ frame: CreatorMicroLightingFrame) {
        lastApplied = frame
    }
}
