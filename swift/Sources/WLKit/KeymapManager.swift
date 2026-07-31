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

    public static let agCodes = [
        "KV_OAI_AG00", "KV_OAI_AG01", "KV_OAI_AG02",
        "KV_OAI_AG03", "KV_OAI_AG04", "KV_OAI_AG05",
    ]

    /// Rows are [2, 4, 4, 3]; the six agent keys are rows 0 and 1.
    static let agentRows: [(row: Int, codes: [String])] = [
        (0, Array(agCodes[0..<2])),
        (1, Array(agCodes[2..<6])),
    ]

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

    /// True when the six agent keys are bound to AG keycodes on the active layer.
    public static func isAgentKeymapApplied(_ config: [String: Any]) -> Bool {
        guard let keymap = activeLayerKeymap(config) else { return false }
        for (row, codes) in agentRows {
            guard row < keymap.count else { return false }
            let actual = keymap[row]
            guard actual.count >= codes.count else { return false }
            for (i, code) in codes.enumerated() where actual[i] != code { return false }
        }
        return true
    }

    /// Rebinds the six agent keys, leaving every other key, layer, encoder,
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

        for (row, codes) in agentRows where row < keymap.count {
            keymap[row] = codes
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
