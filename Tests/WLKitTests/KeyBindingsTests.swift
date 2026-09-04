import XCTest
@testable import WLKit

final class KeyBindingsTests: XCTestCase {

    private func parse(_ json: String) -> KeyBindings {
        KeyBindings.parse(Data(json.utf8))
    }

    func testMissingFileMeansDefaults() {
        let bindings = KeyBindings()
        XCTAssertEqual(bindings.text(for: 9), "Open PRs for all active GitButler branches")
        XCTAssertEqual(bindings.text(for: 12), "Run but pull")
        XCTAssertNil(bindings.text(for: 10), "the wide key defaults to voice, not text")
        XCTAssertNil(bindings.text(for: 11))
    }

    /// The defaults are meaningless on a key the pad does not route to a macro,
    /// so the two lists have to keep agreeing.
    func testDefaultsSitOnTheMacroKeys() {
        XCTAssertEqual(KeyBindings.defaults.keys.sorted(), Pad.macroKeyIDs.sorted())
        XCTAssertFalse(Pad.macroKeyIDs.contains(Pad.landKeyID),
                       "the land key answers before any macro on it would")
    }

    func testFileOverridesAKeyAndKeepsTheOtherDefault() {
        let bindings = parse(#"{"keys": {"9": "Ship it"}}"#)
        XCTAssertEqual(bindings.text(for: 9), "Ship it")
        XCTAssertEqual(bindings.text(for: 12), "Run but pull")
    }

    /// "10+11" is the wide key spoken of as one: both halves get the string.
    func testWideKeyBindsBothHalvesTogether() {
        let bindings = parse(#"{"keys": {"10+11": "Summarise your progress"}}"#)
        XCTAssertEqual(bindings.text(for: 10), "Summarise your progress")
        XCTAssertEqual(bindings.text(for: 11), "Summarise your progress")
    }

    func testWideKeyHalvesCanDiffer() {
        let bindings = parse(#"{"keys": {"10": "left half", "11": "right half"}}"#)
        XCTAssertEqual(bindings.text(for: 10), "left half")
        XCTAssertEqual(bindings.text(for: 11), "right half")
    }

    /// An empty string is a no-op, not an unbind — `false` is the unbind.
    /// Kept this way for anyone upgrading with an existing "" already in
    /// config.json, from before an empty string meant anything at all.
    func testEmptyStringIsANoOpNotAnUnbind() {
        let bindings = parse(#"{"keys": {"12": ""}}"#)
        XCTAssertEqual(bindings.text(for: 12), "Run but pull")
        XCTAssertEqual(bindings.text(for: 9), "Open PRs for all active GitButler branches")
    }

    func testMalformedFileFallsBackToDefaults() {
        XCTAssertEqual(parse("not json"), KeyBindings())
        XCTAssertEqual(parse(#"{"keys": "nope"}"#), KeyBindings())
    }

    func testClaudeModelAndEffortListsHaveDefaults() {
        let bindings = KeyBindings()
        XCTAssertEqual(bindings.claudeModels, ["fable", "opus", "sonnet", "haiku"])
        XCTAssertEqual(bindings.claudeEfforts, ["low", "medium", "high", "xhigh", "max"])
    }

    func testClaudeListsAreOverridable() {
        let bindings = parse(#"{"claude": {"models": ["opus", "sonnet"], "efforts": ["low", "high"]}}"#)
        XCTAssertEqual(bindings.claudeModels, ["opus", "sonnet"])
        XCTAssertEqual(bindings.claudeEfforts, ["low", "high"])
        XCTAssertEqual(bindings.text(for: 9), "Open PRs for all active GitButler branches",
                       "key defaults survive a claude-only config")
    }

    func testEmptyClaudeListsFallBackToDefaults() {
        let bindings = parse(#"{"claude": {"models": []}}"#)
        XCTAssertEqual(bindings.claudeModels, KeyBindings.defaultClaudeModels)
    }

    /// Codex's list has no default to fall back on: it is a copy of what that
    /// TUI offers, and guessing it would put wrong names next to the numbers.
    func testCodexModelsAreEmptyUntilConfigured() {
        XCTAssertEqual(KeyBindings().codexModels, [])
        XCTAssertEqual(parse(#"{"codex": {"models": []}}"#).codexModels, [])
    }

    func testCodexModelsComeFromTheFile() {
        let bindings = parse(#"{"codex": {"models": ["gpt-5.6-sol", "gpt-5.6-codex"]}}"#)
        XCTAssertEqual(bindings.codexModels, ["gpt-5.6-sol", "gpt-5.6-codex"])
        XCTAssertEqual(bindings.claudeModels, KeyBindings.defaultClaudeModels,
                       "a codex-only config leaves the claude side alone")
    }

    // MARK: - Dial mode

    /// With nothing in the file the dial keeps its original job: effort.
    func testDialModeDefaultsToEffort() {
        XCTAssertEqual(KeyBindings().dialMode, .effort)
        XCTAssertEqual(parse("{}").dialMode, .effort)
    }

    func testDialModeComesFromTheFile() {
        XCTAssertEqual(parse(#"{"dial": "agent"}"#).dialMode, .agent)
        XCTAssertEqual(parse(#"{"dial": "tab"}"#).dialMode, .tab)
        XCTAssertEqual(parse(#"{"dial": "space"}"#).dialMode, .space)
        XCTAssertEqual(parse(#"{"dial": "effort"}"#).dialMode, .effort)
    }

    /// `space` is the pad-facing word; `workspace` is the socket API's. Take both.
    func testDialModeAcceptsWorkspaceAsAnAliasForSpace() {
        XCTAssertEqual(parse(#"{"dial": "workspace"}"#).dialMode, .space)
    }

    func testDialModeIsCaseInsensitive() {
        XCTAssertEqual(parse(#"{"dial": "AGENT"}"#).dialMode, .agent)
    }

    /// A typo or the wrong type should not brick the dial — fall back to effort.
    func testUnknownDialModeFallsBackToEffort() {
        XCTAssertEqual(parse(#"{"dial": "banana"}"#).dialMode, .effort)
        XCTAssertEqual(parse(#"{"dial": 5}"#).dialMode, .effort)
    }

    func testDialModeSurvivesAKeysOnlyConfig() {
        XCTAssertEqual(parse(#"{"keys": {"9": "Ship it"}}"#).dialMode, .effort)
    }

    // MARK: - Key actions (text and shortcut)

    func testAKeyCanBeBoundToAShortcut() {
        let bindings = parse(#"{"keys": {"6": {"shortcut": "cmd+shift+5"}}}"#)
        XCTAssertEqual(bindings.action(for: 6), .shortcut("cmd+shift+5"))
        XCTAssertNil(bindings.text(for: 6), "a shortcut binding is not a text binding")
    }

    /// Stack, tabs, and land used to be fixed; a bound key now overrides them.
    func testStackTabAndLandKeysAreOverridable() {
        let bindings = parse(#"""
            {"keys": {"6": {"shortcut": "cmd+shift+5"}, "7": "note", "8": ""}}
            """#)
        XCTAssertEqual(bindings.action(for: 6), .shortcut("cmd+shift+5"))
        XCTAssertEqual(bindings.action(for: 7), .text("note"))
        XCTAssertNil(bindings.action(for: 8), "empty string is a no-op — false is what unbinds")
    }

    func testUnmentionedStackTabAndLandKeysHaveNoActionByDefault() {
        // nil here means "unmentioned, keep the built-in job" — not the same
        // as `.off`, which is an explicit override that beats the built-in.
        XCTAssertNil(KeyBindings().action(for: Pad.stackKeyID))
        XCTAssertNil(KeyBindings().action(for: Pad.tabCycleKeyID))
        XCTAssertNil(KeyBindings().action(for: Pad.landKeyID))
    }

    func testMacroKeyDefaultsComeBackAsTextActions() {
        XCTAssertEqual(KeyBindings().action(for: 9),
                       .text("Open PRs for all active GitButler branches"))
    }

    /// A shortcut object with no recognised field binds nothing, same as a
    /// malformed value anywhere else in the file — the key stays unmentioned.
    func testAShortcutObjectMissingItsFieldIsIgnored() {
        let bindings = parse(#"{"keys": {"6": {}}}"#)
        XCTAssertNil(bindings.action(for: 6))
    }

    func testWideKeyShortcutBindsBothHalves() {
        let bindings = parse(#"{"keys": {"10+11": {"shortcut": "cmd+shift+5"}}}"#)
        XCTAssertEqual(bindings.action(for: 10), .shortcut("cmd+shift+5"))
        XCTAssertEqual(bindings.action(for: 11), .shortcut("cmd+shift+5"))
    }

    /// An empty shortcut string turns the key off too, same rule as text.
    /// Same no-op rule as a bare empty string.
    func testEmptyShortcutIsANoOp() {
        let bindings = parse(#"{"keys": {"9": {"shortcut": ""}}}"#)
        XCTAssertEqual(bindings.action(for: 9), .text("Open PRs for all active GitButler branches"))
    }

    /// `false` is the explicit, no-ambiguity way to turn a key off — the
    /// value to reach for on 6/7/8, whose built-in job would otherwise run.
    func testFalseExplicitlyTurnsAKeyOff() {
        let bindings = parse(#"{"keys": {"6": false, "8": false}}"#)
        XCTAssertEqual(bindings.action(for: 6), .off)
        XCTAssertEqual(bindings.action(for: 8), .off)
    }

    /// `.off` beats the built-in even though it is a real, present binding —
    /// unlike an unmentioned key, it is not nil.
    func testOffIsARealBindingNotAnAbsentOne() {
        let bindings = parse(#"{"keys": {"6": false}}"#)
        XCTAssertNotNil(bindings.action(for: 6))
        XCTAssertEqual(bindings.action(for: 6), .off)
    }

    /// `true` has no meaning for a key binding — ignored like any other
    /// malformed value, leaving the key at its default.
    func testTrueIsIgnored() {
        let bindings = parse(#"{"keys": {"6": true}}"#)
        XCTAssertNil(bindings.action(for: 6))
    }

    /// `0`/`1` bridge to `Bool` on this platform same as a literal
    /// true/false, so a naive `as? Bool` check would treat a config
    /// author's numeric `0` as `false` and turn the key off — verify the
    /// type check actually tells them apart.
    func testNumericZeroAndOneAreIgnoredNotTreatedAsBooleans() {
        XCTAssertNil(parse(#"{"keys": {"8": 0}}"#).action(for: 8))
        XCTAssertNil(parse(#"{"keys": {"8": 1}}"#).action(for: 8))
    }

    // MARK: - Provider spec

    func testMissingProviderMeansTheInProcessDefault() {
        XCTAssertNil(KeyBindings().providerSpec)
        XCTAssertNil(parse("{}").providerSpec)
    }

    func testConnectSpecifiesASocketPathToDialInto() {
        let bindings = parse(#"{"provider": {"connect": "/tmp/bridge.sock"}}"#)
        XCTAssertEqual(bindings.providerSpec, .connect(socketPath: "/tmp/bridge.sock"))
    }

    func testLaunchSpecifiesACommandAndArgs() {
        let bindings = parse(#"{"provider": {"launch": "provider-bridge", "args": ["--foo"]}}"#)
        XCTAssertEqual(bindings.providerSpec, .launch(command: "provider-bridge", args: ["--foo"]))
    }

    func testLaunchWithoutArgsDefaultsToNone() {
        let bindings = parse(#"{"provider": {"launch": "provider-bridge"}}"#)
        XCTAssertEqual(bindings.providerSpec, .launch(command: "provider-bridge", args: []))
    }

    /// A config that sets both wins on `connect` rather than picking
    /// arbitrarily or refusing to parse.
    func testBothFieldsPresentPrefersConnect() {
        let bindings = parse(#"{"provider": {"connect": "/tmp/a.sock", "launch": "cmd"}}"#)
        XCTAssertEqual(bindings.providerSpec, .connect(socketPath: "/tmp/a.sock"))
    }

    func testEmptyConnectPathIsIgnored() {
        let bindings = parse(#"{"provider": {"connect": ""}}"#)
        XCTAssertNil(bindings.providerSpec)
    }

    func testMalformedProviderValueIsIgnored() {
        XCTAssertNil(parse(#"{"provider": "connect"}"#).providerSpec)
        XCTAssertNil(parse(#"{"provider": {}}"#).providerSpec)
    }

    func testProviderSpecSurvivesAKeysOnlyConfig() {
        XCTAssertNil(parse(#"{"keys": {"9": "Ship it"}}"#).providerSpec)
    }
}
