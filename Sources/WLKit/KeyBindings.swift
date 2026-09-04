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
///         "10+11": "Summarise what you are working on"
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
/// climbs the reasoning-effort ladder, `"agent"` steps the focused agent,
/// `"tab"` cycles tabs in the focused workspace, `"space"` (or `"workspace"`)
/// steps the focused workspace. Anything else keeps `"effort"` and surfaces
/// itself in `dialWarning`, so a typo shows up the way an unrecognised
/// shortcut does instead of silently changing nothing.
public struct KeyBindings: Sendable, Equatable {

    /// What a dial detent does. `effort` is handled in the app layer; the rest
    /// are Herdr navigation and run through `BridgeController.cycleDial`.
    public enum DialMode: String, Sendable {
        case effort, agent, tab, space

        /// nil when the string is present but unrecognised, so the caller can
        /// fall back to `.effort` and say so.
        init?(config: String?) {
            switch config?.lowercased() {
            case "agent": self = .agent
            case "tab": self = .tab
            case "space", "workspace": self = .space
            case "effort": self = .effort
            default: return nil
            }
        }

        /// The name this mode crosses the `Provider` protocol as. `nil` for
        /// `.effort`, which never reaches a provider at all — it is a
        /// Micromanager feature (Claude Code / Codex reasoning effort), not
        /// something any provider implements.
        public var wireMode: String? {
            switch self {
            case .effort: return nil
            case .agent: return "agent"
            case .tab: return "tab"
            case .space: return "space"
            }
        }
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
    public private(set) var dialMode: DialMode

    /// Set when `"dial"` was present but unrecognised — a typo, or the wrong
    /// JSON type. The knob keeps working on `"effort"`; this says why.
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
        dialMode: DialMode = .effort,
        dialWarning: String? = nil
    ) {
        self.actions = actions
        self.claudeModels = claudeModels
        self.claudeEfforts = claudeEfforts
        self.codexModels = codexModels
        self.dialMode = dialMode
        self.dialWarning = dialWarning
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

        let dialMode: DialMode
        let dialWarning: String?
        if let raw = json["dial"] as? String {
            if let mode = DialMode(config: raw) {
                dialMode = mode
                dialWarning = nil
            } else {
                dialMode = .effort
                dialWarning = "Unrecognised dial mode \"\(raw)\" — keeping \"effort\"."
            }
        } else if json["dial"] != nil {
            dialMode = .effort
            dialWarning = "\"dial\" must be a string (\"effort\", \"agent\", \"tab\", or \"space\") — keeping \"effort\"."
        } else {
            dialMode = .effort
            dialWarning = nil
        }

        return KeyBindings(
            actions: actions,
            claudeModels: models?.isEmpty == false ? models! : defaultClaudeModels,
            claudeEfforts: efforts?.isEmpty == false ? efforts! : defaultClaudeEfforts,
            codexModels: codexModels ?? [],
            dialMode: dialMode,
            dialWarning: dialWarning
        )
    }

    /// A key's value is a bare string (a text macro; an empty one is a no-op,
    /// matching the pre-`.off` behaviour so existing configs keep working),
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
