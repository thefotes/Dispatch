import Foundation

/// User-configurable text macros for the spare keys.
///
/// Read from `$XDG_CONFIG_HOME/micromanager/config.json`
/// (`~/.config/micromanager/config.json` by default):
///
///     {
///       "keys": {
///         "9": "Open PRs for all active GitButler branches",
///         "12": "Run but pull",
///         "10+11": "Summarize what you are working on",
///         "6": { "action": "new_workspace" },
///         "7": { "action": "split_pane" },
///         "8": { "action": "cycle_prompt" }
///       },
///       "herdr":  { "tools": ["opencode", "claude", "codex"],
///                   "split_direction": "right",
///                   "instances": [
///                     { "id": "local",  "name": "Mac Mini",
///                       "socket_path": "~/.config/herdr/herdr.sock" },
///                     { "id": "jarvis", "name": "Jarvis",
///                       "socket_path": "$TMPDIR/jarvis-herdr.sock" }
///                   ] },
///       "dial":   "effort",
///       "claude": { "efforts": ["low", "high"] },
///       "agent_keys": "priority"
///     }
///
/// `"agent_keys"` is `"sidebar"` (the default) or `"priority"`. Sidebar
/// order lights the first six agents Herdr lists; `"priority"` instead
/// lights the six that most want attention — a blocked or unread agent
/// keeps a key even when it would have sorted past the sixth. The
/// trade-off is that a key then points at a different agent as statuses
/// change, so it is opt-in. Any other value falls back to `"sidebar"`.
///
/// `"agent_keys_drop_idle"` (boolean) drops idle agents from the key slots
/// so only agents that want attention light a key. With more than one
/// Herdr instance configured it defaults to on — five idle remote shells
/// otherwise eat the whole pad — and off with a single instance.
///
/// A bound string is injected into the focused agent's prompt, unsubmitted.
/// A key can also be bound to a system-wide keyboard shortcut instead —
/// `{"shortcut": "cmd+shift+5"}` — synthesised regardless of what Herdr is
/// doing, or to a named provider action — `{"action": "..."}` — resolved
/// against what the active provider advertised through `describe()` and
/// dispatched through `Provider.perform`, exactly the way `"dial"` names
/// are resolved. What the names mean is entirely the provider's business;
/// the knobs a provider's actions read (for the shipped Herdr provider:
/// the `"tools"` list the cycle action rotates through and the
/// `"split_direction"` its split action takes) live in that provider's own
/// config section and are its to interpret. `"10+11"` addresses the
/// wide key as one; `"10"` and `"11"` address
/// its halves separately. Keys the file does not mention keep their
/// defaults — 9 and 12 default to the text macros below, the wide key
/// defaults to the voice key, and 6/7/8 default to stack/tabs/land. Binding
/// any of those overrides its default. An empty string (or
/// `{"shortcut":""}`) is a no-op, indistinguishable from the key being
/// unmentioned, matching older configs where it behaved that way; `false`
/// unbinds a key outright.
///
/// A top-level `"dial"` string repurposes the knob: `"effort"` (the default)
/// climbs the reasoning-effort ladder — the one dial behavior built into
/// Micromanager itself, handled in the app layer, never reaching a
/// provider. Any other name is passed through verbatim to whichever
/// provider is active, resolved against what `Provider.describe()` actually
/// offers once the bridge starts — this file has no opinion on what names
/// are valid, since that is entirely up to the provider. An unresolvable
/// name falls back to `"effort"` and surfaces itself in `BridgeController`,
/// the same way an unrecognized shortcut does.
///
/// A top-level `"provider"` object swaps the in-process `HerdrProvider` for
/// one reached over a socket: `{"provider": {"connect": "/path/to.sock"}}`
/// for one already running, or `{"provider": {"launch": "cmd", "args":
/// [...]}}` for one Micromanager should start itself. Unmentioned — the
/// ordinary case — keeps the in-process default.
public struct KeyBindings: Sendable, Equatable {

    /// What the dial's config selects. `.effort` is the one mode WLKit
    /// understands natively; `.provider` is an opaque name whose validity
    /// isn't knowable here — only `BridgeController`, once it has a
    /// provider's `describe()` in hand, can say whether it means anything.
    public enum DialSelection: Equatable, Sendable {
        case effort
        case provider(String)
    }

    /// What a bound key does. `.shortcut` carries the raw config string —
    /// `ShortcutSpec.parse` validates it at dispatch time, so a typo shows up
    /// as an error in the panel rather than silently dropping the binding.
    ///
    /// `.off` is deliberately not the same thing as a key going unmentioned:
    /// an unmentioned stack/tabs/land/voice key keeps its built-in job, but
    /// `.off` is a real, present binding that beats it — how you silence a
    /// built-in you don't want. (Named `off`, not `none`, so it can never be
    /// confused with `Optional.none` when matched against `KeyAction?`.)
    public enum KeyAction: Equatable, Sendable {
        case text(String)
        case shortcut(String)
        /// A named provider action — `{"action": "..."}` — resolved against
        /// what the active provider offered through `describe()` and handed
        /// to `Provider.perform`. This file has no opinion on what the
        /// names mean, exactly like `"dial"`.
        case action(String)
        case off
    }

    /// Which `Provider` the bridge should use instead of the in-process
    /// `HerdrProvider` default. Set with a top-level `"provider"` object:
    /// `{"connect": "/path/to.sock"}` for one already running (Herdr's own
    /// pattern — it always runs a server), or `{"launch": "cmd", "args":
    /// [...]}` for one Micromanager should start and own the lifecycle of.
    /// Unmentioned — the ordinary case — means the in-process default.
    public enum ProviderSpec: Equatable, Sendable {
        case connect(socketPath: String)
        case launch(command: String, args: [String])
    }

    public private(set) var actions: [Int: KeyAction]

    /// The effort ladder the dial climbs in Claude Code.
    public private(set) var claudeEfforts: [String]

    /// What the knob does. Set with a top-level `"dial"` string.
    public private(set) var dialSelection: DialSelection

    /// The prompt names the `{"herdr": "cycle"}` key rotates through, in
    /// order. Set with a top-level `"herdr": {"tools": [...]}` object.
    public private(set) var herdrTools: [String]

    /// Which side of the focused pane the `{"herdr": "pane"}` key's split
    /// puts the new one on: "right", "down", "left" or "up". Set with a
    /// top-level `"herdr": {"split_direction": ...}` string.
    public private(set) var herdrSplitDirection: String

    /// The Herdr instances the pad talks to, in config order — the order
    /// merged status is built in and `herdr.next_instance` cycles through.
    /// Set with `"herdr": {"instances": [{"id": ..., "name": ...,
    /// "socket_path": ...}, ...]}`. Absent or empty means one default local
    /// instance, so every existing config keeps working unchanged.
    public private(set) var herdrInstances: [HerdrInstance]

    /// Which provider to use, if not the in-process default.
    public private(set) var providerSpec: ProviderSpec?

    /// Whether the six agent keys light the highest-priority agents rather
    /// than the first six in sidebar order. Set with a top-level
    /// `"agent_keys": "priority"`; anything else means sidebar order.
    /// `BridgeController` copies this into `BridgeConfig.prioritizeAgentKeys`
    /// on every `start()`.
    public private(set) var prioritizeAgentKeys: Bool

    /// Whether idle agents are dropped from the six agent key slots entirely,
    /// so a key only ever lights an agent that wants attention. Set with
    /// `"agent_keys_drop_idle": false` to keep idle agents on keys;
    /// unmentioned, it follows the instance count — **on** with more than one
    /// machine, where five idle remote shells can otherwise eat the whole
    /// pad, and off with one, where the keys mirroring the sidebar is the
    /// whole point. `BridgeController` copies this into
    /// `BridgeConfig.dropIdleAgentKeys` on every `start()`.
    public private(set) var dropIdleAgentKeys: Bool

    /// Whether a dial turn that runs off the end of the active machine's
    /// list spills onto the next machine. Set with `"herdr":
    /// {"dial_crosses_machines": true}`; **off by default**, and off is the
    /// honest default on Herdr 0.9.
    ///
    /// The navigation itself works — the focus call reaches the other
    /// machine's server and moves its focus. What is missing is any way to
    /// make the *client* show it. 0.9's socket API has no concept of a
    /// machine (111 methods, none of them machine-aware), and machine
    /// grouping in the sidebar is client-side state with no API surface. So
    /// a crossing turn changes focus on a machine the window will not
    /// switch to, and reads as a dial that swallowed the turn.
    ///
    /// Kept behind a flag rather than deleted: the logic is correct and
    /// tested, and the day Herdr exposes a machine focus this becomes a
    /// one-line default change. See `docs/herdr-machine-focus-request.md`.
    public private(set) var dialCrossesMachines: Bool

    /// Set when `"dial"` was present but the wrong JSON shape (not a string,
    /// or an empty one) — a name that is simply unrecognized by the active
    /// provider is a `BridgeController`-time concern, not this file's.
    public private(set) var dialWarning: String?

    public static let defaults: [Int: KeyAction] = [
        9: .text("Open PRs for all active GitButler branches"),
        12: .text("Run but pull")
    ]
    public static let defaultClaudeEfforts = ["low", "medium", "high", "xhigh", "max"]
    public static let defaultHerdrTools = ["opencode", "claude", "codex"]
    public static let defaultHerdrSplitDirection = "right"
    public static let defaultHerdrInstances = [HerdrInstance.local()]

    public init(
        actions: [Int: KeyAction] = KeyBindings.defaults,
        claudeEfforts: [String] = KeyBindings.defaultClaudeEfforts,
        herdrTools: [String] = KeyBindings.defaultHerdrTools,
        herdrSplitDirection: String = KeyBindings.defaultHerdrSplitDirection,
        herdrInstances: [HerdrInstance] = KeyBindings.defaultHerdrInstances,
        dialSelection: DialSelection = .effort,
        dialWarning: String? = nil,
        providerSpec: ProviderSpec? = nil,
        prioritizeAgentKeys: Bool = false,
        dropIdleAgentKeys: Bool = false,
        dialCrossesMachines: Bool = false
    ) {
        self.actions = actions
        self.claudeEfforts = claudeEfforts
        self.herdrTools = herdrTools
        self.herdrSplitDirection = herdrSplitDirection
        self.herdrInstances = herdrInstances
        self.dialSelection = dialSelection
        self.dialWarning = dialWarning
        self.providerSpec = providerSpec
        self.prioritizeAgentKeys = prioritizeAgentKeys
        self.dropIdleAgentKeys = dropIdleAgentKeys
        self.dialCrossesMachines = dialCrossesMachines
    }

    /// The action bound to a key, or nil when the key does whatever it does
    /// by default (an agent key, or — unless overridden — stack/tabs/land/voice).
    public func action(for key: Int) -> KeyAction? {
        actions[key]
    }

    /// The text bound to a key, or nil when it is unbound or bound to a
    /// shortcut instead.
    public func text(for key: Int) -> String? {
        guard case .text(let text) = actions[key] else { return nil }
        return text
    }

    public static func configPath() -> String {
        let env = ProcessInfo.processInfo.environment
        let base = env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".config")
        return (base as NSString).appendingPathComponent("micromanager/config.json")
    }

    public static func load() -> KeyBindings {
        guard let data = FileManager.default.contents(atPath: configPath()) else {
            return KeyBindings()
        }
        return parse(data)
    }

    /// A malformed file falls back to the defaults rather than a dead pad.
    static func parse(_ data: Data) -> KeyBindings {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return KeyBindings() }

        var actions = defaults
        if let keys = json["keys"] as? [String: Any] {
            for (name, value) in keys {
                guard let action = keyAction(from: value) else { continue }
                for key in keyIDs(for: name) {
                    actions[key] = action
                }
            }
        }

        let claude = json["claude"] as? [String: Any]
        let efforts = (claude?["efforts"] as? [String])?.filter { !$0.isEmpty }

        let herdr = json["herdr"] as? [String: Any]
        let tools = (herdr?["tools"] as? [String])?.filter { !$0.isEmpty }
        let splitDirection = herdr?["split_direction"] as? String
        let direction = (splitDirection?.isEmpty == false) ? splitDirection! : defaultHerdrSplitDirection
        let instances = herdrInstances(from: herdr?["instances"])

        let (dialSelection, dialWarning) = dial(from: json["dial"])

        return KeyBindings(
            actions: actions,
            claudeEfforts: efforts?.isEmpty == false ? efforts! : defaultClaudeEfforts,
            herdrTools: tools?.isEmpty == false ? tools! : defaultHerdrTools,
            herdrSplitDirection: direction,
            herdrInstances: instances,
            dialSelection: dialSelection,
            dialWarning: dialWarning,
            providerSpec: providerSpec(from: json["provider"]),
            prioritizeAgentKeys: agentKeyOrderIsPriority(json["agent_keys"],
                                                           instanceCount: instances.count),
            dropIdleAgentKeys: dropIdleAgentKeys(json["agent_keys_drop_idle"],
                                                  instanceCount: instances.count),
            dialCrossesMachines: herdr?["dial_crosses_machines"] as? Bool ?? false
        )
    }

    /// `"priority"` (case-insensitive) turns on priority ordering for the
    /// agent keys; `"sidebar"` forces the order the pad has always used.
    ///
    /// When the key is absent the default follows the number of machines,
    /// because the right answer genuinely differs. With one instance,
    /// sidebar order is stable and predictable — keys stay put as statuses
    /// change. With two, sidebar order is actively harmful: the merged list
    /// is active-instance-first, there are only six agent key slots
    /// (`Pad.agentKeyIDs`), and a machine with six or more agents therefore
    /// takes every slot and renders the other machine invisible. Priority
    /// order is what keeps both machines on the keys, so it is the default
    /// exactly when more than one is configured.
    private static func agentKeyOrderIsPriority(_ value: Any?, instanceCount: Int) -> Bool {
        guard let raw = (value as? String)?.lowercased() else { return instanceCount > 1 }
        return raw == "priority"
    }

    /// `"agent_keys_drop_idle": false` keeps idle agents on the keys even on
    /// a multi-machine setup; `true` drops them on a single one too. Absent,
    /// the default follows the instance count for the same reason
    /// `agentKeyOrderIsPriority` does: on one machine the keys mirroring the
    /// sidebar is the point, but on several, idle agents crowd out the
    /// machines that actually need attention.
    ///
    /// Anything `as? Bool` refuses — a string, an object — falls back to
    /// that default, exactly like the cross-machine dial's flag. JSON `1`
    /// and `0` do bridge to booleans and are taken at face value; that is
    /// `JSONSerialization`'s doing, not a decision made here, and pinned by
    /// `testANumericDropIdleFlagIsTakenAsABoolean` so it stays deliberate.
    private static func dropIdleAgentKeys(_ value: Any?, instanceCount: Int) -> Bool {
        value as? Bool ?? (instanceCount > 1)
    }

    /// Shape-level only: is this a non-empty string? Content — whether the
    /// name means anything — is not decidable here at all, since that
    /// depends on which provider ends up active. `value` is `Any?` because
    /// that's what `JSONSerialization` handed back for `json["dial"]` —
    /// same as `keyAction(from:)` and `providerSpec(from:)` below, the only
    /// honest type at this boundary.
    private static func dial(from value: Any?) -> (selection: DialSelection, warning: String?) {
        guard let value else { return (.effort, nil) }
        guard let raw = value as? String else {
            return (.effort, "\"dial\" must be a string — keeping \"effort\".")
        }
        let name = raw.lowercased()
        guard !name.isEmpty else {
            return (.effort, "\"dial\" must not be empty — keeping \"effort\".")
        }
        return name == "effort" ? (.effort, nil) : (.provider(name), nil)
    }

    /// The `"herdr": {"instances": [...]}` list. Absent or empty is the
    /// single default local instance; malformed entries are skipped rather
    /// than failing the whole file. `socket_path` values have `~` and
    /// `$TMPDIR` expanded — forwarded remote sockets belong under `$TMPDIR`,
    /// since macOS caps `sun_path` at 104 bytes.
    private static func herdrInstances(from value: Any?) -> [HerdrInstance] {
        guard let raw = value as? [[String: Any]], !raw.isEmpty else {
            return defaultHerdrInstances
        }
        var parsed: [HerdrInstance] = []
        for entry in raw {
            guard let id = entry["id"] as? String, !id.isEmpty,
                  let path = entry["socket_path"] as? String, !path.isEmpty
            else { continue }
            // A duplicate id would make focus-target namespaces ambiguous —
            // the first entry in config order wins.
            guard !parsed.contains(where: { $0.id == id }) else { continue }
            let name = (entry["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
            parsed.append(HerdrInstance(id: id, name: name, socketPath: expandingPath(path)))
        }
        return parsed.isEmpty ? defaultHerdrInstances : parsed
    }

    /// Expands a leading `~` to the home directory and `$TMPDIR` to the
    /// per-user temporary directory. Both are the forms the config examples
    /// use; nothing else is interpreted.
    static func expandingPath(_ path: String) -> String {
        if path == "~" || path.hasPrefix("~/") {
            return (NSHomeDirectory() as NSString).appendingPathComponent(String(path.dropFirst(2)))
        }
        if path.hasPrefix("$TMPDIR"), let tmpdir = ProcessInfo.processInfo.environment["TMPDIR"] {
            return tmpdir + path.dropFirst("$TMPDIR".count)
        }
        return path
    }

    /// `{"connect": "path"}`, `{"launch": "cmd"}` (optionally with `"args"`),
    /// or anything else — missing, malformed, both fields present — falls
    /// back to nil, the in-process default. `connect` wins if a config
    /// mistakenly sets both.
    private static func providerSpec(from value: Any?) -> ProviderSpec? {
        guard let object = value as? [String: Any] else { return nil }
        if let path = object["connect"] as? String, !path.isEmpty {
            return .connect(socketPath: path)
        }
        if let command = object["launch"] as? String, !command.isEmpty {
            let args = (object["args"] as? [String]) ?? []
            return .launch(command: command, args: args)
        }
        return nil
    }

    /// A key's value is a bare string (a text macro; an empty one is a no-op,
    /// matching the pre-`.off` behavior so existing configs keep working),
    /// an object with a `"shortcut"` string (same empty-string rule), or
    /// `false` (turns it off outright — the unambiguous choice for a
    /// stack/tabs/land key, where an empty string could read as "leave it
    /// alone"). Anything else — `true`, a shortcut object missing its field,
    /// a number — binds nothing, same as leaving the key unmentioned.
    private static func keyAction(from value: Any) -> KeyAction? {
        // `value as? Bool` alone is not enough: Foundation bridges a JSON `0`
        // or `1` to `Bool` too on this platform, so a config author's numeric
        // `0` would silently turn a key off instead of being ignored like any
        // other number. CFGetTypeID tells an actual JSON true/false (backed
        // by CFBoolean) apart from a bridged NSNumber.
        if CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID(), let flag = value as? Bool {
            return flag ? nil : .off
        }
        if let text = value as? String { return text.isEmpty ? nil : .text(text) }
        if let object = value as? [String: Any] {
            if let shortcut = object["shortcut"] as? String {
                return shortcut.isEmpty ? nil : .shortcut(shortcut)
            }
            // Shape-level only: a non-empty action name. Whether the active
            // provider actually offers it is `BridgeController`'s concern,
            // resolved against `describe()` the way dial names are.
            if let name = object["action"] as? String, !name.isEmpty {
                return .action(name)
            }
        }
        return nil
    }

    private static func keyIDs(for name: String) -> [Int] {
        if name == "10+11" { return Pad.voiceKeyIDs }
        guard let id = Int(name) else { return [] }
        return [id]
    }
}
