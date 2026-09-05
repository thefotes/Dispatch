import Foundation

/// The JSON shapes `RemoteProvider` (client) and `ProviderBridgeServer`
/// (server) speak over the wire — plain functions, not methods, since both
/// sides need both directions (the server encodes results and decodes
/// requests; the client does the reverse).
enum ProviderWire {

    static func encode(_ description: ProviderDescription) -> [String: Any] {
        [
            "statePalette": description.statePalette.mapValues {
                ["color": $0.color, "effect": $0.effect.rawValue]
            },
            "statePriority": description.statePriority,
            "dialModes": description.dialModes.map {
                ["id": $0.id, "label": $0.label, "raisesHost": $0.raisesHost]
            },
            "joystickNavigation": description.joystickNavigation,
        ]
    }

    static func decodeDescription(_ json: [String: Any]) -> ProviderDescription {
        var palette: [String: ProviderStateStyle] = [:]
        if let raw = json["statePalette"] as? [String: [String: Any]] {
            for (state, style) in raw {
                guard let color = style["color"] as? Int,
                      let effectRaw = style["effect"] as? Int,
                      let effect = OAI.Effect(rawValue: effectRaw)
                else { continue }
                palette[state] = ProviderStateStyle(color: color, effect: effect)
            }
        }
        let priority = json["statePriority"] as? [String] ?? []
        let modes = (json["dialModes"] as? [[String: Any]] ?? []).compactMap { entry -> ProviderDialMode? in
            guard let id = entry["id"] as? String, let label = entry["label"] as? String else { return nil }
            // Defaults to false for a provider written before this field
            // existed — "does not raise the host" is the safer guess than
            // dropping the mode outright over one missing field.
            let raisesHost = entry["raisesHost"] as? Bool ?? false
            return ProviderDialMode(id: id, label: label, raisesHost: raisesHost)
        }
        return ProviderDescription(
            statePalette: palette,
            statePriority: priority,
            dialModes: modes,
            // False for a provider written before this field existed — the
            // app keeps running its own joystick behaviour, which is the
            // safer guess than claiming navigation a provider never
            // promised.
            joystickNavigation: json["joystickNavigation"] as? Bool ?? false
        )
    }

    static func encode(_ agents: [HerdrAgent]) -> [String: Any] {
        ["agents": agents.map(\.wire)]
    }

    static func decodeAgents(_ json: [String: Any]) -> [HerdrAgent] {
        (json["agents"] as? [[String: Any]] ?? []).map(HerdrAgent.init(json:))
    }
}

extension HerdrAgent {
    /// The same field names `init(json:)` reads, so a `HerdrAgent` can cross
    /// the provider-bridge socket and come back unchanged.
    var wire: [String: Any] {
        var out: [String: Any] = ["agent": agent, "agent_status": status, "focused": focused]
        if let terminalID { out["terminal_id"] = terminalID }
        if let paneID { out["pane_id"] = paneID }
        if let tabID { out["tab_id"] = tabID }
        if let workspaceID { out["workspace_id"] = workspaceID }
        if let cwd { out["cwd"] = cwd }
        if let foregroundCwd { out["foreground_cwd"] = foregroundCwd }
        return out
    }
}
