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
enum OAI {

    /// Per-key lighting. Params are a bare ARRAY, one entry per key.
    static let methodThreads = "v.oai.thstatus"
    /// Zone lighting: the keys plate and the ambient ring.
    static let methodRGBConfig = "v.oai.rgbcfg"
    /// The documented two-surface call, kept for comparison.
    static let methodPreview = "lights.preview"

    /// Device → host notification channels. These are pushed by the device and
    /// are not callable methods; calling them returns "Method not found".
    static let notifyHID = "v.oai.hid"
    static let notifyJoystick = "v.oai.rad"

    enum Effect: Int, CaseIterable, Identifiable {
        case off = 0
        case solid = 1
        case snake = 2
        case rainbow = 3
        case breath = 4
        case gradient = 5
        case shallowBreath = 6

        var id: Int { rawValue }

        var label: String {
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
    struct Thread {
        var id: Int
        var color: Int?
        var brightness: Double?
        var effect: Effect?
        var speed: Double?
        var syncKeys: Bool?
        var syncAmbient: Bool?

        /// Only `id` is required; omitted fields leave that aspect unchanged.
        var wire: [String: Any] {
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
    struct Zone {
        var effect: Effect = .solid
        var brightness: Double = 1
        var speed: Double = 0.5
        var magic: Double = 1
        var color: Int = 0

        var wire: [String: Any] {
            ["e": effect.rawValue, "b": brightness, "s": speed, "m": magic, "c": color]
        }

        static let dark = Zone(effect: .off, brightness: 0, speed: 0.5, magic: 1, color: 0)
    }

    /// An AG key reports itself by name, "AG00".."AG19"; the number is the key
    /// index, the same one used as a thread id for lighting.
    static func agIndex(_ name: String?) -> Int? {
        guard let name, name.hasPrefix("AG") else { return nil }
        return Int(name.dropFirst(2))
    }

    static func threadsParams(_ threads: [Thread]) -> [[String: Any]] {
        threads.map(\.wire)
    }

    static func rgbConfigParams(keys: Zone, ambient: Zone) -> [String: Any] {
        ["keys": keys.wire, "ambient": ambient.wire]
    }
}

// MARK: - Pad geometry

/// The pad's physical key rows, matching the firmware's [2, 4, 4, 3] matrix.
/// Key index runs row-major from 0, so the six agent keys are 0...5.
enum Pad {
    static let rows: [[Int]] = [
        [0, 1],
        [2, 3, 4, 5],
        [6, 7, 8, 9],
        [10, 11, 12],
    ]
    static let keyCount = 13
    /// The firmware's keycode table goes to AG19, so clear the whole id space
    /// when turning everything off, not just the visible keys.
    static let maxThreadID = 19

    static func row(of key: Int) -> Int? {
        rows.firstIndex { $0.contains(key) }
    }
}

// MARK: - Colour helpers

extension Color {
    /// Packed 0xRRGGBB, which is how colours go on the wire.
    var packedRGB: Int {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .black
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return (r << 16) | (g << 8) | b
    }

    init(packedRGB: Int) {
        self.init(
            .sRGB,
            red: Double((packedRGB >> 16) & 0xFF) / 255,
            green: Double((packedRGB >> 8) & 0xFF) / 255,
            blue: Double(packedRGB & 0xFF) / 255
        )
    }
}

func hexString(_ packed: Int) -> String {
    String(format: "#%06X", packed & 0xFFFFFF)
}
