import Foundation

/// A parsed keyboard shortcut, e.g. `"cmd+shift+5"` — the modifier flags and
/// virtual keycode `CGEvent` needs to synthesise it. Parsing lives here, with
/// no AppKit dependency, so it can be tested on its own; posting the event is
/// app-layer, the same split `VoiceController` uses for the wide key's tap.
public struct ShortcutSpec: Equatable, Sendable {
    public var keyCode: UInt16
    public var modifiers: Modifiers

    public struct Modifiers: OptionSet, Sendable, Equatable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1 << 0)
        public static let shift   = Modifiers(rawValue: 1 << 1)
        public static let option  = Modifiers(rawValue: 1 << 2)
        public static let control = Modifiers(rawValue: 1 << 3)
    }

    /// Parses a `"+"`-separated spec like `"cmd+shift+5"` or `"ctrl+alt+u"`:
    /// modifiers in any order, case-insensitive, exactly one base key. Nil for
    /// anything that isn't exactly that — no base key, more than one, or a
    /// name this table doesn't know.
    public static func parse(_ spec: String) -> ShortcutSpec? {
        let parts = spec
            .lowercased()
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }

        var modifiers: Modifiers = []
        var keyCode: UInt16?
        for part in parts {
            switch part {
            case "cmd", "command": modifiers.insert(.command)
            case "shift": modifiers.insert(.shift)
            case "opt", "option", "alt": modifiers.insert(.option)
            case "ctrl", "control": modifiers.insert(.control)
            default:
                // A second base key, or an unrecognised name, both fail —
                // reporting silence rather than guessing which one you meant.
                guard keyCode == nil, let code = keyCodes[part] else { return nil }
                keyCode = code
            }
        }
        guard let keyCode else { return nil }
        return ShortcutSpec(keyCode: keyCode, modifiers: modifiers)
    }

    /// Standard US-ANSI virtual keycodes (the Carbon `kVK_*` table). Named
    /// keys only need to cover what a macro key would plausibly bind —
    /// letters, digits, punctuation, function keys, arrows.
    private static let keyCodes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "equal": 24, "9": 25, "7": 26,
        "minus": 27, "8": 28, "0": 29, "rightbracket": 30, "o": 31, "u": 32,
        "leftbracket": 33, "i": 34, "p": 35, "return": 36, "l": 37, "j": 38,
        "quote": 39, "k": 40, "semicolon": 41, "backslash": 42, "comma": 43,
        "slash": 44, "n": 45, "m": 46, "period": 47, "tab": 48, "space": 49,
        "grave": 50, "delete": 51, "escape": 53,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98,
        "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        "f13": 105, "f14": 107, "f15": 113, "f16": 106, "f17": 64, "f18": 79, "f19": 80,
        "left": 123, "right": 124, "down": 125, "up": 126
    ]
}
