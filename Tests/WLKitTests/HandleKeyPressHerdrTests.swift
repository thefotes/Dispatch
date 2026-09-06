import XCTest
@testable import WLKit

/// The `{"action": ...}` bindings route key presses through the provider —
/// these pin the dispatch from a real `handleKeyPress` to a recorded fake,
/// so a refactor of the key switch cannot drop the wiring unnoticed.
@MainActor
final class HandleKeyPressHerdrTests: XCTestCase {

    private func makeBridge(_ action: String, key: Int) -> (BridgeController, FakeProvider) {
        let provider = FakeProvider()
        let bridge = BridgeController(provider: provider)
        bridge.setKeyBindingsForTesting(KeyBindings(actions: [key: .action(action)]))
        return (bridge, provider)
    }

    func testAWorkspaceActionReachesTheProvider() async {
        let (bridge, provider) = makeBridge("new_workspace", key: Pad.stackKeyID)
        bridge.handleKeyPress(Pad.stackKeyID)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(provider.performedActions, ["new_workspace"])
    }

    func testAPaneActionReachesTheProvider() async {
        let (bridge, provider) = makeBridge("split_pane", key: Pad.tabCycleKeyID)
        bridge.handleKeyPress(Pad.tabCycleKeyID)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(provider.performedActions, ["split_pane"])
    }

    func testACycleActionReachesTheProvider() async {
        let (bridge, provider) = makeBridge("cycle_prompt", key: Pad.landKeyID)
        bridge.handleKeyPress(Pad.landKeyID)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(provider.performedActions, ["cycle_prompt"])
    }

    /// A name the provider never offered must not reach the provider — it
    /// surfaces as a panel error instead, the way an unrecognized dial name
    /// does.
    func testAnUnofferedActionIsRefusedAtTheBridge() async {
        let provider = FakeProvider()
        provider.descriptionToReturn = ProviderDescription(actions: [
            ProviderAction(id: "new_workspace", label: "New workspace", raisesHost: true)
        ])
        let bridge = BridgeController(provider: provider)
        bridge.setKeyBindingsForTesting(KeyBindings(actions: [Pad.stackKeyID: .action("explode")]))
        bridge.applyDescriptionForTesting(provider.descriptionToReturn)

        bridge.handleKeyPress(Pad.stackKeyID)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(provider.performedActions, [])
        XCTAssertNotNil(bridge.lastError)
    }

    /// Two presses in a row must reach the provider twice — the chain
    /// serializes them, it never collapses them the way the wide key's
    /// debounce collapses one physical press's two switches.
    func testTwoActionPressesBothReachTheProvider() async {
        let (bridge, provider) = makeBridge("cycle_prompt", key: Pad.landKeyID)

        bridge.handleKeyPress(Pad.landKeyID)
        bridge.handleKeyPress(Pad.landKeyID)
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(provider.performedActions.count, 2)
    }
}
