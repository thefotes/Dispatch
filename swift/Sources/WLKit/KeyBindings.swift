import Foundation

/// User-configurable text macros for the spare keys.
///
/// Read from `$XDG_CONFIG_HOME/micromanager/config.json`
/// (`~/.config/micromanager/config.json` by default):
///
///     {
///       "keys": {
///         "8": "Open PRs for all active GitButler branches",
///         "12": "Run but pull",
///         "10+11": "Summarise what you are working on"
///       }
///     }
///
/// A bound string is injected into the focused agent's prompt, unsubmitted.
/// `"10+11"` addresses the wide key as one; `"10"` and `"11"` address its
/// halves separately. Keys the file does not mention keep their defaults —
/// 8 and 12 have the defaults below, the wide key defaults to voice input.
/// An empty string unbinds a key outright.
public struct KeyBindings: Sendable, Equatable {

    public private(set) var texts: [Int: String]

    public static let defaults: [Int: String] = [
        8: "Open PRs for all active GitButler branches",
        12: "Run but pull",
    ]

    public init(texts: [Int: String] = KeyBindings.defaults) {
        self.texts = texts
    }

    /// The string bound to a key, or nil when the key does something else.
    public func text(for key: Int) -> String? {
        guard let text = texts[key], !text.isEmpty else { return nil }
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
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let keys = json["keys"] as? [String: Any]
        else { return KeyBindings() }

        var texts = defaults
        for (name, value) in keys {
            guard let text = value as? String else { continue }
            for key in keyIDs(for: name) {
                if text.isEmpty {
                    texts.removeValue(forKey: key)
                } else {
                    texts[key] = text
                }
            }
        }
        return KeyBindings(texts: texts)
    }

    private static func keyIDs(for name: String) -> [Int] {
        if name == "10+11" { return Pad.voiceKeyIDs }
        guard let id = Int(name) else { return [] }
        return [id]
    }
}
