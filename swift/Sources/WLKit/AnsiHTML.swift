import Foundation

/// Turns terminal output into HTML.
///
/// `but status` draws a stack with box characters and SGR colour, so rendering
/// it faithfully means honouring the escapes rather than stripping them. Only
/// SGR (`ESC [ ... m`) carries meaning here; every other escape sequence is
/// dropped rather than printed, because a stray `ESC [?25l` shown literally is
/// worse than no cursor control at all.
public enum AnsiHTML {

    /// One span's worth of styling. `nil` colour means the document default.
    struct Style: Equatable {
        var foreground: String?
        var background: String?
        var bold = false
        var dim = false
        var italic = false
        var underline = false

        var isPlain: Bool { self == Style() }

        /// Bold is a class rather than `font-weight`, so the theme decides
        /// whether it brightens the colour as well.
        var attribute: String {
            var classes: [String] = []
            if bold { classes.append("b") }
            if dim { classes.append("d") }
            if italic { classes.append("i") }
            if underline { classes.append("u") }

            var css: [String] = []
            if let foreground { css.append("color:\(foreground)") }
            if let background { css.append("background:\(background)") }

            var out = ""
            if !classes.isEmpty { out += " class=\"\(classes.joined(separator: " "))\"" }
            if !css.isEmpty { out += " style=\"\(css.joined(separator: ";"))\"" }
            return out
        }
    }

    /// xterm's first 16 entries, darkened to stay readable on a light panel.
    static let palette = [
        "#3d434f", "#c93a44", "#18985a", "#a87d1c",
        "#2b6fd4", "#8f50c9", "#0d8fa3", "#3a4150",
        "#8a919e", "#e0525e", "#2fa96b", "#bd9430",
        "#4a8ae8", "#a873dd", "#2aa2b8", "#1a1f28",
    ]

    public static func render(_ text: String) -> String {
        var out = ""
        var style = Style()
        var open = false
        var scanner = text.startIndex

        func closeSpan() {
            if open { out += "</span>"; open = false }
        }
        func openSpan() {
            guard !style.isPlain else { return }
            out += "<span\(style.attribute)>"
            open = true
        }

        while scanner < text.endIndex {
            let character = text[scanner]
            guard character == "\u{1B}" else {
                out += escapeHTML(character)
                scanner = text.index(after: scanner)
                continue
            }

            guard let sequence = readEscape(text, from: scanner) else {
                // A lone ESC with nothing parseable after it: drop it rather
                // than emit a control character into the document.
                scanner = text.index(after: scanner)
                continue
            }
            scanner = sequence.end
            guard sequence.isSGR else { continue }

            closeSpan()
            apply(sequence.parameters, to: &style)
            openSpan()
        }

        closeSpan()
        return out
    }

    // MARK: - Escape parsing

    private struct Escape {
        var parameters: [Int]
        var isSGR: Bool
        var end: String.Index
    }

    /// Consumes `ESC [ params final`. Anything that is not a CSI — `ESC ]`
    /// title strings, single-character escapes — is consumed to a best guess
    /// and discarded.
    private static func readEscape(_ text: String, from start: String.Index) -> Escape? {
        var index = text.index(after: start)
        guard index < text.endIndex else { return nil }

        // OSC: a string terminated by BEL or ST. Window titles come this way,
        // and printing one literally would drop a stray title into the stack.
        if text[index] == "]" {
            var scan = text.index(after: index)
            while scan < text.endIndex {
                if text[scan] == "\u{7}" {
                    return Escape(parameters: [], isSGR: false, end: text.index(after: scan))
                }
                if text[scan] == "\u{1B}" {
                    let next = text.index(after: scan)
                    if next < text.endIndex, text[next] == "\\" {
                        return Escape(parameters: [], isSGR: false, end: text.index(after: next))
                    }
                }
                scan = text.index(after: scan)
            }
            return Escape(parameters: [], isSGR: false, end: text.endIndex)
        }

        guard text[index] == "[" else {
            // Not a CSI. Skip the escape and its one-character selector.
            return Escape(parameters: [], isSGR: false, end: text.index(after: index))
        }
        index = text.index(after: index)

        var digits = ""
        var parameters: [Int] = []
        while index < text.endIndex {
            let character = text[index]
            if character.isNumber {
                digits.append(character)
            } else if character == ";" || character == ":" {
                parameters.append(Int(digits) ?? 0)
                digits = ""
            } else if character.isLetter {
                if !digits.isEmpty || !parameters.isEmpty {
                    parameters.append(Int(digits) ?? 0)
                }
                return Escape(
                    parameters: parameters,
                    isSGR: character == "m",
                    end: text.index(after: index)
                )
            } else if character == "?" || character == ">" || character == "!" {
                // Private-mode introducer: still a CSI, never an SGR.
            } else {
                break
            }
            index = text.index(after: index)
        }
        return Escape(parameters: [], isSGR: false, end: index)
    }

    // MARK: - SGR

    private static func apply(_ parameters: [Int], to style: inout Style) {
        // A bare `ESC[m` is a reset.
        guard !parameters.isEmpty else { style = Style(); return }

        var index = 0
        while index < parameters.count {
            let code = parameters[index]
            switch code {
            case 0: style = Style()
            case 1: style.bold = true
            case 2: style.dim = true
            case 3: style.italic = true
            case 4: style.underline = true
            case 22: style.bold = false; style.dim = false
            case 23: style.italic = false
            case 24: style.underline = false
            case 30...37: style.foreground = palette[code - 30]
            case 39: style.foreground = nil
            case 40...47: style.background = palette[code - 40]
            case 49: style.background = nil
            case 90...97: style.foreground = palette[code - 90 + 8]
            case 100...107: style.background = palette[code - 100 + 8]
            case 38, 48:
                let extended = readExtendedColor(parameters, from: &index)
                if code == 38 { style.foreground = extended } else { style.background = extended }
            default: break
            }
            index += 1
        }
    }

    /// `38;5;n` (256-colour) and `38;2;r;g;b` (truecolour). Advances `index`
    /// past the arguments it consumed.
    private static func readExtendedColor(_ parameters: [Int], from index: inout Int) -> String? {
        guard index + 1 < parameters.count else { return nil }
        let mode = parameters[index + 1]
        if mode == 5, index + 2 < parameters.count {
            let value = parameters[index + 2]
            index += 2
            return xterm256(value)
        }
        if mode == 2, index + 4 < parameters.count {
            let (r, g, b) = (parameters[index + 2], parameters[index + 3], parameters[index + 4])
            index += 4
            return String(format: "#%02X%02X%02X", r & 0xFF, g & 0xFF, b & 0xFF)
        }
        index = parameters.count
        return nil
    }

    static func xterm256(_ value: Int) -> String? {
        switch value {
        case 0..<16:
            return palette[value]
        case 16..<232:
            let offset = value - 16
            let levels = [0, 95, 135, 175, 215, 255]
            return String(
                format: "#%02X%02X%02X",
                levels[(offset / 36) % 6],
                levels[(offset / 6) % 6],
                levels[offset % 6]
            )
        case 232..<256:
            let grey = 8 + (value - 232) * 10
            return String(format: "#%02X%02X%02X", grey, grey, grey)
        default:
            return nil
        }
    }

    // MARK: - Escaping

    public static func escapeHTML(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text { out += escapeHTML(character) }
        return out
    }

    private static func escapeHTML(_ character: Character) -> String {
        switch character {
        case "&": return "&amp;"
        case "<": return "&lt;"
        case ">": return "&gt;"
        case "\"": return "&quot;"
        case "\r": return ""
        default: return String(character)
        }
    }
}
