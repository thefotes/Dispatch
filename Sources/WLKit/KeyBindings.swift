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
///         "10+11": "Summarize what you are working on"
///       },
///       "dial":   "effort",
///       "claude": { "models": ["fable", "opus"], "efforts": ["low", "high"] },
///       "codex":  { "models": ["gpt-5.6-sol", "gpt-5.6-codex"] }
///     }
///
/// A bound string is injected into the focused agent's prompt, unsubmitted.
/// A key can also be bound to a system-wide keyboard shortcut instead —
/// `{"shortcut": "cmd+shift+5"}` — synthesised regardless of what Herdr is
/// doing. `"10+11"` addresses the wide key as one; `"10"` and `"11"` address
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

    /// The models the joystick cycles through in Claude Code, in order.
    /// Overridable with a top-level `"claude": {"models": [...]}` object.
    public private(set) var claudeModels: [String]

    /// The effort ladder the dial climbs in Claude Code.
    public private(set) var claudeEfforts: [String]

    /// Codex's own `/model` menu, in the order it lists them, from a
    /// `"codex": {"models": [...]}` object. The joystick steers that menu
    /// rather than owning it, so this is the user's copy of what it offers —
    /// there is nothing to read it from, and no sensible default. Empty means
    /// the panel shows the steering guide alone.
    public private(set) var codexModels: [String]

    /// What the knob does. Set with a top-level `"dial"` string.
    public private(set) var dialSelection: DialSelection

    /// Which provider to use, if not the in-process default.
    public private(set) var providerSpec: ProviderSpec?

    /// Set when `"dial"` was present but the wrong JSON shape (not a string,
    /// or an empty one) — a name that is simply unrecognized by the active
    /// provider is a `BridgeController`-time concern, not this file's.
    public private(set) var dialWarning: String?

    public static let defaults: [Int: KeyAction] = [
        9: .text("Open PRs for all active GitButler branches"),
        12: .text("Run but pull"),
    ]
    public static let defaultClaudeModels = ["fable", "opus", "sonnet", "haiku"]
    public static let defaultClaudeEfforts = ["low", "medium", "high", "xhigh", "max"]

    public init(
        actions: [Int: KeyAction] = KeyBindings.defaults,
        claudeModels: [String] = KeyBindings.defaultClaudeModels,
        claudeEfforts: [String] = KeyBindings.defaultClaudeEfforts,
        codexModels: [String] = [],
        dialSelection: DialSelection = .effort,
        dialWarning: String? = nil,
        providerSpec: ProviderSpec? = nil
    ) {
        self.actions = actions
        self.claudeModels = claudeModels
        self.claudeEfforts = claudeEfforts
        self.codexModels = codexModels
        self.dialSelection = dialSelection
        self.dialWarning = dialWarning
        self.providerSpec = providerSpec
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
        let models = (claude?["models"] as? [String])?.filter { !$0.isEmpty }
        let efforts = (claude?["efforts"] as? [String])?.filter { !$0.isEmpty }
        let codex = json["codex"] as? [String: Any]
        let codexModels = (codex?["models"] as? [String])?.filter { !$0.isEmpty }

        let (dialSelection, dialWarning) = dial(from: json["dial"])

        return KeyBindings(
            actions: actions,
            claudeModels: models?.isEmpty == false ? models! : defaultClaudeModels,
            claudeEfforts: efforts?.isEmpty == false ? efforts! : defaultClaudeEfforts,
            codexModels: codexModels ?? [],
            dialSelection: dialSelection,
            dialWarning: dialWarning,
            providerSpec: providerSpec(from: json["provider"])
        )
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
        if let object = value as? [String: Any], let shortcut = object["shortcut"] as? String {
            return shortcut.isEmpty ? nil : .shortcut(shortcut)
        }
        return nil
    }

    private static func keyIDs(for name: String) -> [Int] {
        if name == "10+11" { return Pad.voiceKeyIDs }
        guard let id = Int(name) else { return [] }
        return [id]
    }
}
