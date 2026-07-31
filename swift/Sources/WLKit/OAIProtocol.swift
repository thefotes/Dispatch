import Foundation
import SwiftUI

/// The Work Louder vendor lighting API, recovered from
/// `@worklouder/device-kit-oai` (which ships inside the Codex desktop app —
/// not the Input configurator, whose SDK only knows `lights.preview`).
///
/// Two details are easy to get wrong, and both fail *silently* because the
/// firmware answers `{"ok":1}` to any payload it is handed:
///
///   1. Field names are abbreviated on the wire: `c b e s m`, not the full
///      names `lights.preview` uses.
///   2. `effect` is an integer here, not one of the effect strings.
public enum OAI {

    /// Per-key lighting. Params are a bare ARRAY, one entry per key.
    public static let methodThreads = "v.oai.thstatus"
    /// Zone lighting: the keys plate and the ambient ring.
    public static let methodRGBConfig = "v.oai.rgbcfg"
    /// The documented two-surface call, kept for comparison.
    public static let methodPreview = "lights.preview"

    /// Device → host notification channels. These are pushed by the device and
    /// are not callable methods; calling them returns "Method not found".
    public static let notifyHID = "v.oai.hid"
    public static let notifyJoystick = "v.oai.rad"

    public enum Effect: Int, CaseIterable, Identifiable, Sendable {
        case off = 0
        case solid = 1
        case snake = 2
        case rainbow = 3
        case breath = 4
        case gradient = 5
        case shallowBreath = 6

        public var id: Int { rawValue }

        public var label: String {
            switch self {
            case .off: return "Off"
            case .solid: return "Solid"
            case .snake: return "Snake"
            case .rainbow: return "Rainbow"
            case .breath: return "Breathing"
            case .gradient: return "Gradient"
            case .shallowBreath: return "Shallow breath"
            }
        }
    }

    /// One key. `id` is a key index: 0-based, row-major over the pad's
    /// [2, 4, 4, 3] matrix, so the top two rows are ids 0...5.
    public struct Thread: Equatable, Sendable {
        public var id: Int
        public var color: Int?
        public var brightness: Double?
        public var effect: Effect?
        public var speed: Double?
        public var syncKeys: Bool?
        public var syncAmbient: Bool?

        public init(
            id: Int,
            color: Int? = nil,
            brightness: Double? = nil,
            effect: Effect? = nil,
            speed: Double? = nil,
            syncKeys: Bool? = nil,
            syncAmbient: Bool? = nil
        ) {
            self.id = id
            self.color = color
            self.brightness = brightness
            self.effect = effect
            self.speed = speed
            self.syncKeys = syncKeys
            self.syncAmbient = syncAmbient
        }

        /// Only `id` is required; omitted fields leave that aspect unchanged.
        public var wire: [String: Any] {
            var out: [String: Any] = ["id": id]
            if let color { out["c"] = color }
            if let brightness { out["b"] = brightness }
            if let effect { out["e"] = effect.rawValue }
            if let speed { out["s"] = speed }
            if let syncKeys { out["sk"] = syncKeys ? 1 : 0 }
            if let syncAmbient { out["sa"] = syncAmbient ? 1 : 0 }
            return out
        }
    }

    /// One zone.
    public struct Zone: Equatable, Sendable {
        public var effect: Effect = .solid
        public var brightness: Double = 1
        public var speed: Double = 0.5
        public var magic: Double = 1
        public var color: Int = 0

        public init(
            effect: Effect = .solid,
            brightness: Double = 1,
            speed: Double = 0.5,
            magic: Double = 1,
            color: Int = 0
        ) {
            self.effect = effect
            self.brightness = brightness
            self.speed = speed
            self.magic = magic
            self.color = color
        }

        public var wire: [String: Any] {
            ["e": effect.rawValue, "b": brightness, "s": speed, "m": magic, "c": color]
        }

        public static let dark = Zone(effect: .off, brightness: 0, speed: 0.5, magic: 1, color: 0)
    }

    /// An AG key reports itself by name, "AG00".."AG19"; the number is the key
    /// index, the same one used as a thread id for lighting.
    public static func agIndex(_ name: String?) -> Int? {
        guard let name, name.hasPrefix("AG") else { return nil }
        return Int(name.dropFirst(2))
    }

    public static func threadsParams(_ threads: [Thread]) -> [[String: Any]] {
        threads.map(\.wire)
    }

    public static func rgbConfigParams(keys: Zone, ambient: Zone) -> [String: Any] {
        ["keys": keys.wire, "ambient": ambient.wire]
    }
}

// MARK: - Pad geometry

/// The pad's physical key rows, matching the firmware's [2, 4, 4, 3] matrix.
/// Key index runs row-major from 0, so the six agent keys are 0...5.
public enum Pad {
    public static let rows: [[Int]] = [
        [0, 1],
        [2, 3, 4, 5],
        [6, 7, 8, 9],
        [10, 11, 12],
    ]
    public static let keyCount = 13
    /// The firmware's keycode table goes to AG19, so clear the whole id space
    /// when turning everything off, not just the visible keys.
    public static let maxThreadID = 19
    /// Key N shows agent N's status and jumps to it.
    public static let agentKeyIDs = [0, 1, 2, 3, 4, 5]
    /// Toggles the GitButler stack for the focused agent's directory. First key
    /// of row 3, so the agent block above it stays whole.
    public static let stackKeyID = 6
    /// Cycles the tabs of the focused tab's workspace in Herdr. Second key of
    /// row 3, next to the stack key.
    public static let tabCycleKeyID = 7
    /// The keys bound to `KV_OAI_AG*`, and so the only ones that can be lit.
    /// Everything else keeps whatever keycode is already on it.
    public static let boundKeyIDs = agentKeyIDs + [stackKeyID, tabCycleKeyID]

    public static func row(of key: Int) -> Int? {
        rows.firstIndex { $0.contains(key) }
    }

    /// Where a key sits in `rows`, which is the shape the device keymap uses.
    public static func position(of key: Int) -> (row: Int, column: Int)? {
        for (row, keys) in rows.enumerated() {
            if let column = keys.firstIndex(of: key) { return (row, column) }
        }
        return nil
    }
}

// MARK: - Colour helpers

extension Color {
    /// Packed 0xRRGGBB, which is how colours go on the wire.
    public var packedRGB: Int {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .black
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return (r << 16) | (g << 8) | b
    }

    public init(packedRGB: Int) {
        self.init(
            .sRGB,
            red: Double((packedRGB >> 16) & 0xFF) / 255,
            green: Double((packedRGB >> 8) & 0xFF) / 255,
            blue: Double(packedRGB & 0xFF) / 255
        )
    }
}

public func hexString(_ packed: Int) -> String {
    String(format: "#%06X", packed & 0xFFFFFF)
}

/// `"#RRGGBB"` / `"#RGB"` → packed int. Mirrors `toColorInt` in lib/oai.js.
public func packedRGB(fromHex hex: String) -> Int? {
    var text = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
    guard text.count == 6 else { return nil }
    return Int(text, radix: 16)
}
