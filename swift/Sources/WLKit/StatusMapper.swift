import Foundation
import SwiftUI

/// Maps a set of Herdr agents to device lighting.
///
/// Keys are individually addressable, so each agent gets its own key. The
/// underglow keeps a worst-state-wins aggregate, which is the part you can read
/// from across the room without counting keys.
///
/// Kept in step with `lib/status.js`; the defaults below are that file's.
public struct BridgeConfig: Sendable {
    /// Highest priority first: the first state present across all agents wins
    /// the underglow.
    public var priority: [String] = ["blocked", "working", "unknown", "idle", "done"]
    public var colors: [String: Int] = [
        "blocked": 0xFF2D2D,
        "working": 0xFFA000,
        "idle": 0x00C853,
        "done": 0x00C853,
        "unknown": 0x00C853,
    ]
    public var effects: [String: OAI.Effect] = [
        "blocked": .breath,
        "working": .solid,
        "idle": .solid,
        "done": .solid,
        "unknown": .solid,
    ]
    public var brightness: Double = 1
    public var speed: Double = 0.5
    /// Leave the key-backlight ZONE alone: keys are painted per-agent instead,
    /// and a zone colour would only compete with them.
    public var driveBacklight = false
    /// Bind the six agent keys to `KV_OAI_AG00..AG05` on startup. Required for
    /// per-key colour to work at all.
    public var manageKeymap = true
    public var pollInterval: TimeInterval = 2.5
    public var debounce: TimeInterval = 0.1

    public init() {}

    public func color(for state: String) -> Int { colors[state] ?? 0xFFFFFF }
    public func effect(for state: String) -> OAI.Effect { effects[state] ?? .solid }
}

public enum StatusMapper {

    /// The winning state across all agents, or nil when none are running.
    public static func aggregate(_ agents: [HerdrAgent], _ cfg: BridgeConfig = BridgeConfig()) -> String? {
        guard !agents.isEmpty else { return nil }
        let present = Set(agents.map(\.status))
        for state in cfg.priority where present.contains(state) { return state }
        return "unknown"
    }

    /// One thread entry per agent key: agent slot N takes key N, unused keys go
    /// dark. Always returns exactly `Pad.agentKeyIDs.count` entries, so a
    /// vanished agent actively clears its key rather than leaving it stale.
    public static func threads(
        for agents: [HerdrAgent],
        _ cfg: BridgeConfig = BridgeConfig()
    ) -> [OAI.Thread] {
        Pad.agentKeyIDs.enumerated().map { slot, id in
            guard slot < agents.count else {
                return OAI.Thread(id: id, brightness: 0, effect: .off)
            }
            let state = agents[slot].status
            return OAI.Thread(
                id: id,
                color: cfg.color(for: state),
                brightness: cfg.brightness,
                effect: cfg.effect(for: state),
                speed: cfg.speed
            )
        }
    }

    /// The underglow zone for an aggregate state, or nil to switch it off.
    public static func zone(for state: String?, _ cfg: BridgeConfig = BridgeConfig()) -> OAI.Zone? {
        guard let state else { return nil }
        return OAI.Zone(
            effect: cfg.effect(for: state),
            brightness: cfg.brightness,
            speed: cfg.speed,
            magic: 1,
            color: cfg.color(for: state)
        )
    }
}
