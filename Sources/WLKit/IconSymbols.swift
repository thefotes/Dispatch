import Foundation

/// The SF Symbols the menu-bar icon draws.
///
/// Gathered here rather than written inline at the draw site so a test can
/// check they all still exist. A symbol name that is not on the running system
/// resolves to nil, and the drawing code has nowhere to go but a blank image,
/// so the icon quietly loses its glyph on exactly the machines where the symbol
/// was withdrawn or never shipped.
public enum IconSymbols {

    /// Running, nothing to report.
    public static let idle = "keyboard"

    /// Agents are doing something worth a colour.
    public static let active = "keyboard.fill"

    /// No pad, or no permission to reach it.
    ///
    /// Not `keyboard.badge.exclamationmark`, which reads better but is not on
    /// every system - where it is absent the icon drew as a bare dot with no
    /// keyboard at all, in the two states where you most need to see it.
    public static let problem = "keyboard.badge.ellipsis"

    public static let all = [idle, active, problem]
}
