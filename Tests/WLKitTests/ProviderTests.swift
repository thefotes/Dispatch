import XCTest
@testable import WLKit

/// `BridgeController` only ever reaches Herdr through the `Provider` seam —
/// these pin that by proving every dispatch path calls a fake instead.
@MainActor
final class ProviderTests: XCTestCase {

    private func makeBridge(_ provider: FakeProvider) async -> BridgeController {
        // Fixed bindings, not the developer's config.json: a real
        // two-machine config would flip `dropIdleAgentKeys` on and change
        // what the key slots hold under tests that never mention them.
        let bridge = BridgeController(provider: provider, loadBindings: { KeyBindings() })
        await bridge.useEmulator(true)
        return bridge
    }

    /// The two agent-key settings are parsed in `KeyBindings` but read out
    /// of `BridgeConfig`; `start()` is the only thing that carries them
    /// across. Untested, a config edit could stop reaching the pad without
    /// a single parsing test noticing.
    func testStartCarriesTheAgentKeySettingsIntoTheConfig() async {
        let bindings = KeyBindings(prioritizeAgentKeys: true, dropIdleAgentKeys: true)
        let bridge = BridgeController(provider: FakeProvider(), loadBindings: { bindings })
        await bridge.useEmulator(true)
        XCTAssertTrue(bridge.config.prioritizeAgentKeys, "applied at init, before any start()")
        XCTAssertTrue(bridge.config.dropIdleAgentKeys)
        await bridge.start()
        XCTAssertTrue(bridge.config.prioritizeAgentKeys)
        XCTAssertTrue(bridge.config.dropIdleAgentKeys)
        await bridge.stop()
    }

    /// The same seam the other way: nothing turns the key filters on by
    /// itself. This is what the rest of the suite leans on when it puts an
    /// `idle` agent in a key slot.
    func testStartLeavesTheAgentKeySettingsOffWithoutConfig() async {
        let fake = FakeProvider()
        fake.agentsToReturn = [HerdrAgent(status: "idle", paneID: "pane-1")]
        let bridge = await makeBridge(fake)
        await bridge.start()
        XCTAssertFalse(bridge.config.dropIdleAgentKeys)
        XCTAssertEqual(bridge.agents.map(\.paneID), ["pane-1"],
                       "an idle agent still holds its slot with the flag off")
        await bridge.stop()
    }

    /// And with the flag on, the idle agent is gone from the slots before a
    /// press can land on it — the multi-machine default, end to end.
    func testDropIdleBindingRemovesIdleAgentsFromTheSlots() async {
        let fake = FakeProvider()
        fake.agentsToReturn = [HerdrAgent(status: "idle", paneID: "quiet"),
                               HerdrAgent(status: "blocked", paneID: "loud")]
        let bridge = BridgeController(provider: fake,
                                      loadBindings: { KeyBindings(dropIdleAgentKeys: true) })
        await bridge.useEmulator(true)
        await bridge.start()
        XCTAssertEqual(bridge.agents.map(\.paneID), ["loud"])
        await bridge.stop()
    }

    func testTheTabsKeyCallsProviderDialOneStepForward() async {
        let fake = FakeProvider()
        let bridge = await makeBridge(fake)
        await bridge.cycleTabs()
        XCTAssertEqual(fake.dialCalls.map(\.mode), ["tab"])
        XCTAssertEqual(fake.dialCalls.map(\.step), [1])
    }

    /// `config.json`'s `"dial"` name crosses to the provider as whatever
    /// string it was — no closed Swift enum in the middle, and no vocabulary
    /// this file (or `KeyBindings`) has any opinion about.
    func testAResolvedProviderDialModeCrossesAsItsOwnWireName() async {
        let fake = FakeProvider()
        fake.descriptionToReturn = ProviderDescription(
            dialModes: [ProviderDialMode(id: "queue", label: "Queue", raisesHost: false)]
        )
        let bridge = await makeBridge(fake)
        await bridge.start()
        bridge.setKeyBindingsForTesting(KeyBindings(dialSelection: .provider("queue")))

        await bridge.cycleDial(1)
        await bridge.cycleDial(-1)

        XCTAssertEqual(fake.dialCalls.map(\.mode), ["queue", "queue"])
        XCTAssertEqual(fake.dialCalls.map(\.step), [1, -1])
        await bridge.stop()
    }

    /// `.effort` is never a provider mode — it must never reach `dial()` at
    /// all, since `resolvedDialMode` stays nil for it.
    func testEffortNeverReachesTheProvider() async {
        let fake = FakeProvider()
        let bridge = await makeBridge(fake)
        await bridge.start()
        bridge.setKeyBindingsForTesting(KeyBindings(dialSelection: .effort))

        await bridge.cycleDial(1)

        XCTAssertTrue(fake.dialCalls.isEmpty)
        await bridge.stop()
    }

    /// A configured name the provider doesn't offer falls back to effort —
    /// same "don't brick the pad over a typo" rule an unrecognized shortcut
    /// follows — and says why, the way an unrecognized shortcut does too.
    func testAnUnofferedDialModeFallsBackToEffortAndWarns() async {
        let fake = FakeProvider()
        fake.descriptionToReturn = ProviderDescription(
            dialModes: [ProviderDialMode(id: "queue", label: "Queue", raisesHost: false)]
        )
        let bridge = await makeBridge(fake)
        await bridge.start()
        bridge.setKeyBindingsForTesting(KeyBindings(dialSelection: .provider("banana")))

        XCTAssertNil(bridge.resolvedDialMode)
        XCTAssertEqual(bridge.lastError, "The dial's mode \"banana\" isn't offered by this provider (available: queue) — keeping the reasoning-effort ladder.")

        await bridge.cycleDial(1)
        XCTAssertTrue(fake.dialCalls.isEmpty)
        await bridge.stop()
    }

    func testInjectPromptCallsProviderInject() async {
        let fake = FakeProvider()
        let bridge = await makeBridge(fake)
        await bridge.injectPrompt("hello")
        XCTAssertEqual(fake.injectedTexts, ["hello"])
    }

    /// A deflection reaches the provider as the typed direction — the
    /// provider maps it onto whatever its own vocabulary is.
    func testAMoveJoystickReachesTheProvider() async {
        let fake = FakeProvider()
        let bridge = await makeBridge(fake)
        await bridge.start()
        await bridge.moveJoystick(.west)
        await bridge.moveJoystick(.south)
        XCTAssertEqual(fake.joystickCalls, [.west, .south])
        await bridge.stop()
    }

    /// Pressing an agent key focuses the entity at that slot by whatever
    /// target `status()` reported for it.
    func testFocusSlotCallsProviderFocusWithTheEntitysTarget() async {
        let fake = FakeProvider()
        fake.agentsToReturn = [HerdrAgent(status: "idle", paneID: "pane-1")]
        let bridge = await makeBridge(fake)
        await bridge.start()
        await bridge.focusSlot(0)
        XCTAssertEqual(fake.focusCalls, ["pane-1"])
        await bridge.stop()
    }

    /// A provider failure surfaces the same way any other bridge error does.
    func testAProviderErrorSurfacesAsLastError() async {
        let fake = FakeProvider()
        fake.injectError = HerdrError.api("nothing focused")
        let bridge = await makeBridge(fake)
        await bridge.injectPrompt("hi")
        XCTAssertEqual(bridge.lastError, "nothing focused")
    }

    // MARK: - describe() → BridgeConfig

    /// Starting the bridge pulls the provider's palette and priority into
    /// `config` — a provider's lighting vocabulary is no longer a
    /// `BridgeConfig` default `BridgeController` hardcodes.
    func testStartingAppliesTheProvidersPaletteAndPriorityToConfig() async {
        let fake = FakeProvider()
        fake.descriptionToReturn = ProviderDescription(
            statePalette: ["waiting": ProviderStateStyle(color: 0x123456, effect: .rainbow)],
            statePriority: ["waiting"],
            dialModes: [ProviderDialMode(id: "queue", label: "Queue", raisesHost: false)]
        )
        let bridge = await makeBridge(fake)
        await bridge.start()
        XCTAssertEqual(bridge.config.colors["waiting"], 0x123456)
        XCTAssertEqual(bridge.config.effects["waiting"], .rainbow)
        XCTAssertEqual(bridge.config.priority, ["waiting"])
        await bridge.stop()
    }

    // MARK: - resolveDialSelection (pure)

    private let sampleModes = [
        ProviderDialMode(id: "agent", label: "Agent", raisesHost: true),
        ProviderDialMode(id: "tab", label: "Tab", raisesHost: false)
    ]

    func testEffortResolvesToNilWithNoWarning() {
        let (mode, warning) = BridgeController.resolveDialSelection(.effort, offeredBy: sampleModes)
        XCTAssertNil(mode)
        XCTAssertNil(warning)
    }

    func testAMatchingNameResolvesToThatMode() {
        let (mode, warning) = BridgeController.resolveDialSelection(.provider("tab"), offeredBy: sampleModes)
        XCTAssertEqual(mode, sampleModes[1])
        XCTAssertNil(warning)
    }

    func testAnUnmatchedNameResolvesToNilWithAWarningListingWhatIsAvailable() {
        let (mode, warning) = BridgeController.resolveDialSelection(.provider("banana"), offeredBy: sampleModes)
        XCTAssertNil(mode)
        XCTAssertEqual(warning, "The dial's mode \"banana\" isn't offered by this provider (available: agent, tab) — keeping the reasoning-effort ladder.")
    }

    func testAnUnmatchedNameAgainstNoModesSaysNoneAreAvailable() {
        let (mode, warning) = BridgeController.resolveDialSelection(.provider("anything"), offeredBy: [])
        XCTAssertNil(mode)
        XCTAssertEqual(warning, "The dial's mode \"anything\" isn't offered by this provider (available: none) — keeping the reasoning-effort ladder.")
    }
}
