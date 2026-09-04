import AppKit

/// Posts a synthesised key chord while preserving the modifiers the user is
/// physically holding.
///
/// This is the one place that turns config into real system keystrokes, shared
/// by `ShortcutController` (a spare key's bound shortcut) and
/// `VoiceController` (the wide key's right-command tap). It exists as one
/// primitive because the subtleties here were each found the hard way:
///
/// * A modifier carries its own flag — set on its own keydown, cleared on its
///   own keyup. Stamping the flag on the base key alone satisfies a listener
///   that reads `event.flags`, but not one that also tracks each modifier's
///   own press (which is what lets an app offer "tap a bare modifier" as a
///   trigger, as Superwhisper's hotkey settings do).
/// * The chord's events must never clear a modifier the user is genuinely
///   holding. A synthetic keyup with no flags drops the real key until it is
///   pressed again — the classic stuck shift/cmd. So the user's physical
///   modifier state is snapshotted up front and OR'd into every posted event.
/// * Every event is built before any is posted: posting a down whose matching
///   up fails to construct would strand a modifier down system-wide.
@MainActor
enum SyntheticChord {

    /// Posts `chord` down in order, then `base` down and up (if given), then
    /// the chord back up in reverse — the cadence a real hardware chord
    /// reports. Returns false, having posted nothing, if any event fails to
    /// construct; `onError` explains.
    @discardableResult
    static func post(
        chord: [(code: CGKeyCode, flag: CGEventFlags)],
        base: (code: CGKeyCode, flag: CGEventFlags?)?,
        onError: (String) -> Void
    ) -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)

        // Snapshot before posting anything: the chord's own downs show up in
        // this state from here on, and the ups must not clear what the user
        // physically holds.
        let physical = CGEventSource.flagsState(.hidSystemState)

        var held: CGEventFlags = []
        var downs: [CGEvent] = []
        for (code, flag) in chord {
            held.insert(flag)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
            else {
                onError("Could not synthesise that keystroke.")
                return false
            }
            down.flags = held.union(physical)
            downs.append(down)
        }

        var baseDown: CGEvent?
        var baseUp: CGEvent?
        if let base {
            guard
                let down = CGEvent(keyboardEventSource: source, virtualKey: base.code, keyDown: true),
                let up = CGEvent(keyboardEventSource: source, virtualKey: base.code, keyDown: false)
            else {
                onError("Could not synthesise that keystroke.")
                return false
            }
            down.flags = held.union(physical)
            up.flags = held.union(physical)   // modifiers still held — their ups come after
            baseDown = down
            baseUp = up
        }

        // Built in release order, so each up's flags are what remains held at
        // that point in the release — plus whatever the user is physically
        // holding, which survives the synthetic release.
        var remaining = held
        var ups: [CGEvent] = []
        for (code, flag) in chord.reversed() {
            remaining.remove(flag)
            guard let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
            else {
                onError("Could not synthesise that keystroke.")
                return false
            }
            up.flags = remaining.union(physical)
            ups.append(up)
        }

        // Everything constructed — only now is it safe to post any of it.
        for down in downs { down.post(tap: .cghidEventTap) }
        baseDown?.post(tap: .cghidEventTap)
        baseUp?.post(tap: .cghidEventTap)
        for up in ups { up.post(tap: .cghidEventTap) }
        return true
    }
}
