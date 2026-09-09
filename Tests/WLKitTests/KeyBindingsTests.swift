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
        let bindings = parse(#"{"keys": {"10+11": "Summarize your progress"}}"#)
        XCTAssertEqual(bindings.text(for: 10), "Summarize your progress")
        XCTAssertEqual(bindings.text(for: 11), "Summarize your progress")
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

    func testClaudeEffortListHasADefault() {
        let bindings = KeyBindings()
        XCTAssertEqual(bindings.claudeEfforts, ["low", "medium", "high", "xhigh", "max"])
    }

    func testClaudeEffortsAreOverridable() {
        let bindings = parse(#"{"claude": {"efforts": ["low", "high"]}}"#)
        XCTAssertEqual(bindings.claudeEfforts, ["low", "high"])
        XCTAssertEqual(bindings.text(for: 9), "Open PRs for all active GitButler branches",
                       "key defaults survive a claude-only config")
    }

    func testAnEmptyClaudeEffortListFallsBackToDefaults() {
        let bindings = parse(#"{"claude": {"efforts": []}}"#)
        XCTAssertEqual(bindings.claudeEfforts, KeyBindings.defaultClaudeEfforts)
    }

    // MARK: - Dial selection

    /// With nothing in the file the dial keeps its original job: effort.
    func testDialSelectionDefaultsToEffort() {
        XCTAssertEqual(KeyBindings().dialSelection, .effort)
        XCTAssertEqual(parse("{}").dialSelection, .effort)
    }

    /// This file has no opinion on what names are valid — any non-empty
    /// string besides `"effort"` passes straight through. Whether "agent"
    /// (or "banana") means anything is a question only the active
    /// provider's `describe()` can answer, at `BridgeController`.
    func testANonEffortStringBecomesAProviderSelectionVerbatim() {
        XCTAssertEqual(parse(#"{"dial": "agent"}"#).dialSelection, .provider("agent"))
        XCTAssertEqual(parse(#"{"dial": "banana"}"#).dialSelection, .provider("banana"))
        XCTAssertEqual(parse(#"{"dial": "workspace"}"#).dialSelection, .provider("workspace"))
    }

    func testEffortStringResolvesToEffort() {
        XCTAssertEqual(parse(#"{"dial": "effort"}"#).dialSelection, .effort)
    }

    func testDialSelectionIsCaseInsensitive() {
        XCTAssertEqual(parse(#"{"dial": "AGENT"}"#).dialSelection, .provider("agent"))
        XCTAssertEqual(parse(#"{"dial": "EFFORT"}"#).dialSelection, .effort)
    }

    /// The wrong JSON shape is the one thing this file can judge on its own,
    /// with no provider in the picture — falls back to effort and warns.
    func testWrongShapeFallsBackToEffortAndWarns() {
        let wrongType = parse(#"{"dial": 5}"#)
        XCTAssertEqual(wrongType.dialSelection, .effort)
        XCTAssertEqual(wrongType.dialWarning, "\"dial\" must be a string — keeping \"effort\".")

        let empty = parse(#"{"dial": ""}"#)
        XCTAssertEqual(empty.dialSelection, .effort)
        XCTAssertEqual(empty.dialWarning, "\"dial\" must not be empty — keeping \"effort\".")
    }

    func testDialSelectionSurvivesAKeysOnlyConfig() {
        XCTAssertEqual(parse(#"{"keys": {"9": "Ship it"}}"#).dialSelection, .effort)
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

    /// A shortcut object with no recognized field binds nothing, same as a
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

    // MARK: - Provider action key bindings

    /// The tool cycle action ships with the three tools actually in rotation.
    /// The knobs are Herdr-specific config consumed by `HerdrProvider` via
    /// `ProviderFactory`; the binding itself (`{"action": ...}`) is generic.
    func testHerdrToolsHaveADefault() {
        XCTAssertEqual(KeyBindings().herdrTools, ["opencode", "claude", "codex"])
    }

    func testHerdrSplitDirectionDefaultsToRight() {
        XCTAssertEqual(KeyBindings().herdrSplitDirection, "right")
    }

    func testActionBindingsParse() {
        let bindings = parse(#"{"keys": {"6": {"action": "new_workspace"}, "7": {"action": "split_pane"}, "8": {"action": "cycle_prompt"}}}"#)
        XCTAssertEqual(bindings.action(for: 6), .action("new_workspace"))
        XCTAssertEqual(bindings.action(for: 7), .action("split_pane"))
        XCTAssertEqual(bindings.action(for: 8), .action("cycle_prompt"))
    }

    /// This file has no opinion on what names mean — anything non-empty is
    /// a binding, however nonsensical, and validation is the bridge's job
    /// against `describe()`, exactly like `"dial"`.
    func testAnUnknownActionNameStillBinds() {
        XCTAssertEqual(parse(#"{"keys": {"6": {"action": "explode"}}}"#).action(for: 6), .action("explode"))
    }

    /// The override wins over a built-in: key 7's tab cycle is exactly the
    /// case this binding exists to replace.
    func testAnActionBindingOverridesTheTabCycleDefault() {
        let bindings = parse(#"{"keys": {"7": {"action": "split_pane"}}}"#)
        XCTAssertEqual(bindings.action(for: 7), .action("split_pane"))
    }

    /// An empty action name binds nothing — the key keeps whatever job it
    /// had, matching the empty-shortcut and empty-string no-op rules.
    func testAnEmptyActionNameIsIgnored() {
        XCTAssertNil(parse(#"{"keys": {"6": {"action": ""}}}"#).action(for: 6))
    }

    func testHerdrToolsAreOverridable() {
        let bindings = parse(#"{"herdr": {"tools": ["aider", "amp"]}}"#)
        XCTAssertEqual(bindings.herdrTools, ["aider", "amp"])
    }

    /// An empty or missing list falls back to the default rotation rather
    /// than a cycle key that presses into nothing.
    func testAnEmptyHerdrToolListFallsBackToDefaults() {
        XCTAssertEqual(parse(#"{"herdr": {"tools": []}}"#).herdrTools, KeyBindings.defaultHerdrTools)
        XCTAssertEqual(parse(#"{"herdr": {}}"#).herdrTools, KeyBindings.defaultHerdrTools)
    }

    func testHerdrSplitDirectionIsOverridable() {
        XCTAssertEqual(parse(#"{"herdr": {"split_direction": "down"}}"#).herdrSplitDirection, "down")
    }

    func testAnEmptyHerdrSplitDirectionFallsBackToRight() {
        XCTAssertEqual(parse(#"{"herdr": {"split_direction": ""}}"#).herdrSplitDirection, "right")
    }

    func testHerdrSectionSurvivesAKeysOnlyConfig() {
        let bindings = parse(#"{"keys": {"9": "Ship it"}}"#)
        XCTAssertEqual(bindings.herdrTools, KeyBindings.defaultHerdrTools)
        XCTAssertEqual(bindings.herdrSplitDirection, "right")
    }

    // MARK: - agent_keys

    func testAgentKeyOrderDefaultsToSidebar() {
        XCTAssertFalse(KeyBindings().prioritizeAgentKeys)
        XCTAssertFalse(parse(#"{"agent_keys": "sidebar"}"#).prioritizeAgentKeys)
    }

    func testAgentKeyOrderPriorityIsRecognized() {
        XCTAssertTrue(parse(#"{"agent_keys": "priority"}"#).prioritizeAgentKeys)
        XCTAssertTrue(parse(#"{"agent_keys": "Priority"}"#).prioritizeAgentKeys)
    }

    func testAgentKeyOrderIgnoresJunkAndFallsBackToSidebar() {
        XCTAssertFalse(parse(#"{"agent_keys": true}"#).prioritizeAgentKeys)
        XCTAssertFalse(parse(#"{"agent_keys": "nonsense"}"#).prioritizeAgentKeys)
        XCTAssertFalse(parse(#"{"keys": {"9": "Ship it"}}"#).prioritizeAgentKeys)
    }

    // MARK: - Herdr instances

    /// Absent or empty `instances` must keep every existing config working:
    /// one default local instance, exactly the pre-multi-instance shape.
    func testMissingInstancesMeanOneDefaultLocalInstance() {
        XCTAssertEqual(KeyBindings().herdrInstances, [HerdrInstance.local()])
        XCTAssertEqual(parse("{}").herdrInstances, [HerdrInstance.local()])
        XCTAssertEqual(parse(#"{"herdr": {}}"#).herdrInstances, [HerdrInstance.local()])
        XCTAssertEqual(parse(#"{"herdr": {"instances": []}}"#).herdrInstances, [HerdrInstance.local()])
    }

    func testInstancesParseInConfigOrder() {
        let bindings = parse(#"""
            {"herdr": {"instances": [
                {"id": "local",  "name": "Mac Mini", "socket_path": "~/.config/herdr/herdr.sock"},
                {"id": "jarvis", "name": "Jarvis",   "socket_path": "$TMPDIR/jarvis-herdr.sock"}
            ]}}
            """#)
        XCTAssertEqual(bindings.herdrInstances.map(\.id), ["local", "jarvis"])
        XCTAssertEqual(bindings.herdrInstances.map(\.name), ["Mac Mini", "Jarvis"])
    }

    func testSocketPathHomeIsExpanded() {
        let bindings = parse(#"{"herdr": {"instances": [{"id": "l", "socket_path": "~/.config/herdr/herdr.sock"}]}}"#)
        XCTAssertTrue(bindings.herdrInstances[0].socketPath.hasSuffix("/.config/herdr/herdr.sock"))
        XCTAssertFalse(bindings.herdrInstances[0].socketPath.hasPrefix("~"))
    }

    func testSocketPathTMPDIRIsExpanded() {
        let bindings = parse(#"{"herdr": {"instances": [{"id": "j", "socket_path": "$TMPDIR/jarvis-herdr.sock"}]}}"#)
        XCTAssertTrue(bindings.herdrInstances[0].socketPath.hasSuffix("jarvis-herdr.sock"))
        XCTAssertFalse(bindings.herdrInstances[0].socketPath.hasPrefix("$"))
    }

    /// A name is display-only; falling back to the id keeps a minimal config
    /// honest in the panel.
    func testAMissingNameFallsBackToTheID() {
        let bindings = parse(#"{"herdr": {"instances": [{"id": "jarvis", "socket_path": "/tmp/x.sock"}]}}"#)
        XCTAssertEqual(bindings.herdrInstances[0].name, "jarvis")
    }

    /// Malformed entries are skipped, not fatal — but if nothing valid
    /// remains, the default single instance wins rather than a dead pad.
    func testMalformedEntriesAreSkippedAndAnAllBadListFallsBackToDefault() {
        let skipped = parse(#"""
            {"herdr": {"instances": [
                {"name": "no id"},
                {"id": "j", "socket_path": "/tmp/x.sock"}
            ]}}
            """#)
        XCTAssertEqual(skipped.herdrInstances.map(\.id), ["j"])

        let allBad = parse(#"{"herdr": {"instances": [{"id": "j"}]}}"#)
        XCTAssertEqual(allBad.herdrInstances, [HerdrInstance.local()])
    }

    /// An id that is not unique would make focus-target namespaces ambiguous;
    /// later duplicates are dropped.
    func testDuplicateIDsKeepOnlyTheFirst() {
        let bindings = parse(#"""
            {"herdr": {"instances": [
                {"id": "local", "socket_path": "/tmp/a.sock"},
                {"id": "local", "socket_path": "/tmp/b.sock"}
            ]}}
            """#)
        XCTAssertEqual(bindings.herdrInstances.map(\.socketPath), ["/tmp/a.sock"])
    }

    func testInstanceExpansionHandlesABareTilde() {
        XCTAssertEqual(KeyBindings.expandingPath("~"), NSHomeDirectory())
        XCTAssertEqual(KeyBindings.expandingPath("/plain/path"), "/plain/path")
    }

    // MARK: - agent_keys default, and the cross-machine dial gate

    /// One machine keeps sidebar order: it is stable, and keys do not move
    /// as statuses change.
    func testAgentKeysDefaultToSidebarOrderWithOneInstance() {
        XCTAssertFalse(parse("{}").prioritizeAgentKeys)
        let one = parse(#"{"herdr": {"instances": [{"id": "l", "socket_path": "/tmp/a.sock"}]}}"#)
        XCTAssertFalse(one.prioritizeAgentKeys)
    }

    /// Two machines default to priority order. Sidebar order is
    /// active-instance-first and there are only six agent key slots, so a
    /// machine with six or more agents would take every one and hide the
    /// other machine entirely.
    func testAgentKeysDefaultToPriorityWithMoreThanOneInstance() {
        let two = parse(#"""
            {"herdr": {"instances": [
                {"id": "local",  "socket_path": "/tmp/a.sock"},
                {"id": "jarvis", "socket_path": "/tmp/b.sock"}
            ]}}
        """#)
        XCTAssertTrue(two.prioritizeAgentKeys)
    }

    /// An explicit setting always wins over the instance-count default,
    /// both ways.
    func testExplicitAgentKeysBeatsTheDefault() {
        let forced = parse(#"""
            {"agent_keys": "sidebar", "herdr": {"instances": [
                {"id": "local",  "socket_path": "/tmp/a.sock"},
                {"id": "jarvis", "socket_path": "/tmp/b.sock"}
            ]}}
        """#)
        XCTAssertFalse(forced.prioritizeAgentKeys, "explicit sidebar survives two instances")
        XCTAssertTrue(parse(#"{"agent_keys": "priority"}"#).prioritizeAgentKeys,
                      "explicit priority survives one instance")
    }

    // MARK: - agent_keys_drop_idle

    /// One machine keeps idle agents on the keys — the keys mirroring the
    /// sidebar is the whole point there.
    func testIdleKeysAreKeptWithOneInstance() {
        XCTAssertFalse(parse("{}").dropIdleAgentKeys)
        let one = parse(#"{"herdr": {"instances": [{"id": "l", "socket_path": "/tmp/a.sock"}]}}"#)
        XCTAssertFalse(one.dropIdleAgentKeys)
    }

    /// More than one machine drops them by default: idle agents on the
    /// active instance would otherwise crowd the other machine off the six
    /// slots entirely.
    func testIdleKeysAreDroppedWithMoreThanOneInstance() {
        let two = parse(#"""
            {"herdr": {"instances": [
                {"id": "local",  "socket_path": "/tmp/a.sock"},
                {"id": "jarvis", "socket_path": "/tmp/b.sock"}
            ]}}
        """#)
        XCTAssertTrue(two.dropIdleAgentKeys)
    }

    /// An explicit boolean wins over the instance-count default, both ways.
    func testExplicitDropIdleBeatsTheDefault() {
        let kept = parse(#"""
            {"agent_keys_drop_idle": false, "herdr": {"instances": [
                {"id": "local",  "socket_path": "/tmp/a.sock"},
                {"id": "jarvis", "socket_path": "/tmp/b.sock"}
            ]}}
        """#)
        XCTAssertFalse(kept.dropIdleAgentKeys, "explicit keep survives two instances")
        XCTAssertTrue(parse(#"{"agent_keys_drop_idle": true}"#).dropIdleAgentKeys,
                      "explicit drop survives one instance")
    }

    /// A non-boolean falls back to the instance-count default, like the
    /// cross-machine dial's flag — both ways, so a typo on a two-machine
    /// setup does not quietly put five idle shells back on the pad.
    func testANonBooleanDropIdleFallsBackToTheDefault() {
        XCTAssertFalse(parse(#"{"agent_keys_drop_idle": "yes"}"#).dropIdleAgentKeys)
        XCTAssertFalse(parse(#"{"agent_keys_drop_idle": {"on": true}}"#).dropIdleAgentKeys)
        let two = parse(#"""
            {"agent_keys_drop_idle": "no", "herdr": {"instances": [
                {"id": "local",  "socket_path": "/tmp/a.sock"},
                {"id": "jarvis", "socket_path": "/tmp/b.sock"}
            ]}}
        """#)
        XCTAssertTrue(two.dropIdleAgentKeys, "a typo keeps the two-machine default")
    }

    /// `JSONSerialization` hands back one `NSNumber` for both `true` and
    /// `1`, so `1`/`0` read as booleans here. Pinned rather than guarded
    /// against: someone writing `1` means true, and pretending otherwise
    /// would cost a type check that cannot actually tell the two apart.
    func testANumericDropIdleFlagIsTakenAsABoolean() {
        XCTAssertTrue(parse(#"{"agent_keys_drop_idle": 1}"#).dropIdleAgentKeys)
        let two = parse(#"""
            {"agent_keys_drop_idle": 0, "herdr": {"instances": [
                {"id": "local",  "socket_path": "/tmp/a.sock"},
                {"id": "jarvis", "socket_path": "/tmp/b.sock"}
            ]}}
        """#)
        XCTAssertFalse(two.dropIdleAgentKeys)
    }

    func testDialDoesNotCrossMachinesUnlessAsked() {
        XCTAssertFalse(parse("{}").dialCrossesMachines)
        XCTAssertFalse(parse(#"{"herdr": {"tools": ["claude"]}}"#).dialCrossesMachines)
    }

    func testDialCrossesMachinesWhenConfigured() {
        XCTAssertTrue(parse(#"{"herdr": {"dial_crosses_machines": true}}"#).dialCrossesMachines)
    }

    /// A non-boolean is not an opt-in — the flag stays off rather than
    /// being coerced from a truthy-looking string.
    func testANonBooleanCrossFlagIsIgnored() {
        XCTAssertFalse(parse(#"{"herdr": {"dial_crosses_machines": "yes"}}"#).dialCrossesMachines)
    }

}
