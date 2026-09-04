import XCTest
@testable import WLKit

/// A provider `BridgeController` never touches Herdr through — records every
/// call so these tests can assert on dispatch, not on a live socket.
private final class FakeProvider: Provider, @unchecked Sendable {
    var agentsToReturn: [HerdrAgent] = []
    var focusCalls: [String] = []
    var dialCalls: [(step: Int, mode: String)] = []
    var injectedTexts: [String] = []
    var injectError: Error?
    var descriptionToReturn = ProviderDescription()

    func describe() -> ProviderDescription { descriptionToReturn }

    func status() async throws -> [HerdrAgent] { agentsToReturn }

    func focus(_ target: String) async throws { focusCalls.append(target) }

    func dial(_ step: Int, mode: String) async throws {
        dialCalls.append((step, mode))
    }

    func inject(_ text: String) async throws {
        if let injectError { throw injectError }
        injectedTexts.append(text)
    }

    func subscribe(_ onChange: @escaping @Sendable () -> Void) -> ProviderSubscription {
        ProviderSubscription {}
    }
}

/// `BridgeController` used to import `HerdrClient` directly; these pin that
/// it now only ever reaches Herdr through the `Provider` seam, by proving
/// every dispatch path calls a fake instead.
@MainActor
final class ProviderTests: XCTestCase {

    private func makeBridge(_ provider: FakeProvider) async -> BridgeController {
        let bridge = BridgeController(provider: provider)
        await bridge.useEmulator(true)
        return bridge
    }

    func testTheTabsKeyCallsProviderDialOneStepForward() async {
        let fake = FakeProvider()
        let bridge = await makeBridge(fake)
        await bridge.cycleTabs()
        XCTAssertEqual(fake.dialCalls.map(\.mode), ["tab"])
        XCTAssertEqual(fake.dialCalls.map(\.step), [1])
    }

    /// The dial's Herdr-navigation modes each map to the string the protocol
    /// carries them as — not a Swift enum crossing the seam.
    func testDialModesMapToProviderStrings() async {
        let fake = FakeProvider()
        let bridge = await makeBridge(fake)
        await bridge.cycleDial(1, mode: .agent)
        await bridge.cycleDial(-1, mode: .tab)
        await bridge.cycleDial(1, mode: .space)
        XCTAssertEqual(fake.dialCalls.map(\.mode), ["agent", "tab", "space"])
        XCTAssertEqual(fake.dialCalls.map(\.step), [1, -1, 1])
    }

    /// `.effort` is a Micromanager feature, not a Herdr one — it must never
    /// reach the provider at all.
    func testEffortDialModeNeverReachesTheProvider() async {
        let fake = FakeProvider()
        let bridge = await makeBridge(fake)
        await bridge.cycleDial(1, mode: .effort)
        XCTAssertTrue(fake.dialCalls.isEmpty)
    }

    func testInjectPromptCallsProviderInject() async {
        let fake = FakeProvider()
        let bridge = await makeBridge(fake)
        await bridge.injectPrompt("hello")
        XCTAssertEqual(fake.injectedTexts, ["hello"])
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
            dialModes: [ProviderDialMode(id: "queue", label: "Queue")]
        )
        let bridge = await makeBridge(fake)
        await bridge.start()
        XCTAssertEqual(bridge.config.colors["waiting"], 0x123456)
        XCTAssertEqual(bridge.config.effects["waiting"], .rainbow)
        XCTAssertEqual(bridge.config.priority, ["waiting"])
        await bridge.stop()
    }
}
