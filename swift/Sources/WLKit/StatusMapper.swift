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
        // Herdr reports "done" for an agent that has finished and that you
        // have not looked at yet, and "idle" once it is focused. That is a
        // real difference - one is waiting to be read, the other is just
        // quiet - so give them different colours.
        "done": 0x00B0FF,
        "idle": 0x00C853,
        "unknown": 0x00C853,
    ]
    public var effects: [String: OAI.Effect] = [
        "blocked": .breath,
        "working": .solid,
        "idle": .solid,
        "done": .solid,
        "unknown": .solid,
    ]
    /// The stack key is not an agent, so it gets a colour of its own rather
    /// than borrowing one of the status colours.
    public var stackColor: Int = 0x7C4DFF
    /// Same reasoning for the tab-cycle key, in a colour of its own so the two
    /// action keys read as different things.
    public var tabCycleColor: Int = 0x00BFA5
    public var brightness: Double = 1
    public var speed: Double = 0.5
    /// Leave the key-backlight ZONE alone: keys are painted per-agent instead,
    /// and a zone colour would only compete with them.
    public var driveBacklight = false
    /// Bind the keys this app drives to `KV_OAI_AG*` on startup. Required for
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

    /// The stack key's own thread. It stays lit whenever the bridge is
    /// running: binding it to an AG keycode took away the keystroke it used to
    /// send, so an unlit key would just read as broken. Breathing while the
    /// stack is on screen, since the same key is what dismisses it.
    public static func stackThread(
        open: Bool,
        _ cfg: BridgeConfig = BridgeConfig()
    ) -> OAI.Thread {
        OAI.Thread(
            id: Pad.stackKeyID,
            color: cfg.stackColor,
            brightness: open ? cfg.brightness : cfg.brightness * 0.3,
            effect: open ? .breath : .solid,
            speed: cfg.speed
        )
    }

    /// The tab-cycle key's thread. Dimly lit whenever the bridge runs, for the
    /// same reason as the stack key: a bound-but-dark key reads as broken.
    public static func tabCycleThread(_ cfg: BridgeConfig = BridgeConfig()) -> OAI.Thread {
        OAI.Thread(
            id: Pad.tabCycleKeyID,
            color: cfg.tabCycleColor,
            brightness: cfg.brightness * 0.3,
            effect: .solid,
            speed: cfg.speed
        )
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
