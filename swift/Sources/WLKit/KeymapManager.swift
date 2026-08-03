import Foundation

/// Device keymap handling.
///
/// Per-key lighting only works on keys bound to `KV_OAI_AG*` keycodes, and only
/// when those bindings are on the ACTIVE layer — parking them on a spare layer
/// does nothing. Nothing reports a mismatch: `v.oai.thstatus` still answers
/// `{"ok":1}` for a key it cannot light, so a wrong keymap looks exactly like a
/// working one from the host side. Hence checking rather than assuming.
///
/// The file itself is double-encoded: `fs.read` returns `{"data": "<json>"}`
/// where the inner string is the real config.
public enum KeymapManager {

    /// Indexed by key: key N is bound to `agCodes[N]`.
    public static let agCodes = [
        "KV_OAI_AG00", "KV_OAI_AG01", "KV_OAI_AG02",
        "KV_OAI_AG03", "KV_OAI_AG04", "KV_OAI_AG05",
        "KV_OAI_AG06", "KV_OAI_AG07", "KV_OAI_AG08",
        "KV_OAI_AG09", "KV_OAI_AG10", "KV_OAI_AG11",
        "KV_OAI_AG12",
    ]

    /// The dial: clockwise, counter-clockwise. Its press keeps whatever it
    /// already does — that click is not this app's to take.
    static let dialCodes = ["KV_OAI_AG13", "KV_OAI_AG14"]

    /// The joystick's four cardinal sectors, matched by the angle at their
    /// centre in the radial map. Diagonal sectors are left alone.
    static let joystickCodes: [(centre: Double, code: String)] = [
        (0.25, "KV_OAI_AG15"),
        (0.50, "KV_OAI_AG16"),
        (0.75, "KV_OAI_AG17"),
        (0.00, "KV_OAI_AG18"),
    ]

    /// A sector's centre angle, handling the one that wraps through zero.
    static func sectorCentre(_ a1: Double, _ a2: Double) -> Double {
        let centre = a2 >= a1 ? (a1 + a2) / 2 : ((a1 + a2 + 1) / 2)
        return centre.truncatingRemainder(dividingBy: 1)
    }

    /// The keycode each managed key must carry, addressed by its position in
    /// the [2, 4, 4, 3] matrix. Bindings are per key rather than per row: the
    /// stack key shares row 2 with three keys this app has no business
    /// touching, and rewriting the row would take their keycodes with it.
    static var bindings: [(row: Int, column: Int, code: String)] {
        Pad.boundKeyIDs.compactMap { key in
            guard key < agCodes.count, let at = Pad.position(of: key) else { return nil }
            return (at.row, at.column, agCodes[key])
        }
    }

    public enum Failure: LocalizedError {
        case noProfiles
        case notAccepted
        case unreadable(String)

        public var errorDescription: String? {
            switch self {
            case .noProfiles: return "Device keymap has no profiles."
            case .notAccepted: return "The device did not accept the agent keymap."
            case .unreadable(let detail): return "Could not read the device keymap: \(detail)"
            }
        }
    }

    // MARK: - Parsing

    /// Unwraps the `{"data": "<json string>"}` envelope.
    public static func parse(_ raw: Any?) throws -> [String: Any] {
        guard let dict = raw as? [String: Any] else {
            throw Failure.unreadable("unexpected response shape")
        }
        guard let inner = dict["data"] as? String,
              let data = inner.data(using: .utf8),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw Failure.unreadable("missing or malformed `data` field")
        }
        return config
    }

    /// `layer_index` from `device.status` is 1-based against this list, so the
    /// active layer is the first one.
    static func activeLayerKeymap(_ config: [String: Any]) -> [[String]]? {
        let index = config["activeProfileId"] as? Int ?? 0
        guard let profiles = config["profiles"] as? [[String: Any]] else { return nil }
        let profile = index < profiles.count ? profiles[index] : profiles.first
        guard let layers = profile?["layers"] as? [[String: Any]],
              let layer = layers.first,
              let layout = layer["layout"] as? [String: Any],
              let keymap = layout["keymap"] as? [[String]]
        else { return nil }
        return keymap
    }

    static func activeLayerLayout(_ config: [String: Any]) -> [String: Any]? {
        let index = config["activeProfileId"] as? Int ?? 0
        guard let profiles = config["profiles"] as? [[String: Any]] else { return nil }
        let profile = index < profiles.count ? profiles[index] : profiles.first
        guard let layers = profile?["layers"] as? [[String: Any]],
              let layer = layers.first
        else { return nil }
        return layer["layout"] as? [String: Any]
    }

    /// True when every managed key, the dial and the joystick's cardinal
    /// sectors carry their AG codes on the active layer.
    public static func isAgentKeymapApplied(_ config: [String: Any]) -> Bool {
        guard let keymap = activeLayerKeymap(config) else { return false }
        for binding in bindings {
            guard binding.row < keymap.count,
                  binding.column < keymap[binding.row].count,
                  keymap[binding.row][binding.column] == binding.code
            else { return false }
        }

        guard let layout = activeLayerLayout(config) else { return false }
        if let encoders = layout["encoders"] as? [[String]], let dial = encoders.first {
            guard dial.count >= 2, dial[0] == dialCodes[0], dial[1] == dialCodes[1] else {
                return false
            }
        }
        if let joystick = layout["joystick"] as? [String: Any],
           let sectors = joystick["sectors"] as? [[String: Any]] {
            for (centre, code) in joystickCodes {
                let bound = sectors.contains { sector in
                    guard let a1 = sector["a1"] as? Double,
                          let a2 = sector["a2"] as? Double
                    else { return false }
                    return abs(sectorCentre(a1, a2) - centre) < 0.01
                        && sector["k"] as? String == code
                }
                if !bound { return false }
            }
        }
        return true
    }

    /// Rebinds the managed keys, leaving every other key, layer, encoder,
    /// joystick and lighting setting untouched.
    public static func withAgentKeymap(_ config: [String: Any]) throws -> [String: Any] {
        var next = config
        let index = next["activeProfileId"] as? Int ?? 0
        guard var profiles = next["profiles"] as? [[String: Any]], !profiles.isEmpty else {
            throw Failure.noProfiles
        }
        let profileIndex = index < profiles.count ? index : 0
        var profile = profiles[profileIndex]
        guard var layers = profile["layers"] as? [[String: Any]], !layers.isEmpty else {
            throw Failure.noProfiles
        }
        var layer = layers[0]
        guard var layout = layer["layout"] as? [String: Any],
              var keymap = layout["keymap"] as? [[String]]
        else { throw Failure.noProfiles }

        for binding in bindings
        where binding.row < keymap.count && binding.column < keymap[binding.row].count {
            keymap[binding.row][binding.column] = binding.code
        }

        // The dial's two rotation slots; its press stays untouched.
        if var encoders = layout["encoders"] as? [[String]],
           var dial = encoders.first, dial.count >= 2 {
            dial[0] = dialCodes[0]
            dial[1] = dialCodes[1]
            encoders[0] = dial
            layout["encoders"] = encoders
        }

        // The joystick's cardinal sectors; diagonals keep their keycodes.
        if var joystick = layout["joystick"] as? [String: Any],
           var sectors = joystick["sectors"] as? [[String: Any]] {
            for index in sectors.indices {
                guard let a1 = sectors[index]["a1"] as? Double,
                      let a2 = sectors[index]["a2"] as? Double
                else { continue }
                let centre = sectorCentre(a1, a2)
                if let match = joystickCodes.first(where: { abs($0.centre - centre) < 0.01 }) {
                    sectors[index]["k"] = match.code
                }
            }
            joystick["sectors"] = sectors
            layout["joystick"] = joystick
        }

        layout["keymap"] = keymap
        layer["layout"] = layout
        layers[0] = layer
        profile["layers"] = layers
        profiles[profileIndex] = profile
        next["profiles"] = profiles
        return next
    }

    // MARK: - Device I/O

    public static func read(_ device: WLDevice) async throws -> [String: Any] {
        let raw = try await device.callAsync("fs.read", params: ["file": "keymap.json"])
        return try parse(raw)
    }

    /// Returns true when it had to change something.
    @discardableResult
    public static func apply(_ device: WLDevice) async throws -> Bool {
        let config = try await read(device)
        if isAgentKeymapApplied(config) { return false }

        let next = try withAgentKeymap(config)
        let encoded = try JSONSerialization.data(withJSONObject: next)
        guard let text = String(data: encoded, encoding: .utf8) else {
            throw Failure.unreadable("could not encode keymap")
        }
        _ = try await device.callAsync("fs.write", params: ["file": "keymap.json", "data": text])

        let after = try await read(device)
        guard isAgentKeymapApplied(after) else { throw Failure.notAccepted }
        return true
    }
}
