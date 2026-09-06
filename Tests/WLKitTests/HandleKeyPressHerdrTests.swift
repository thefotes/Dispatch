import XCTest
@testable import WLKit

/// The `{"herdr": ...}` bindings route key presses through the provider —
/// these pin the dispatch from a real `handleKeyPress` to a recorded fake,
/// so a refactor of the key switch cannot drop the wiring unnoticed.
@MainActor
final class HandleKeyPressHerdrTests: XCTestCase {

    private func makeBridge(_ action: KeyBindings.HerdrKeyAction, key: Int) -> (BridgeController, FakeProvider) {
        let provider = FakeProvider()
        let bridge = BridgeController(provider: provider)
        bridge.setKeyBindingsForTesting(KeyBindings(actions: [key: .herdr(action)]))
        return (bridge, provider)
    }

    func testTheWorkspaceKeyCreatesAWorkspace() async {
        let (bridge, provider) = makeBridge(.workspace, key: Pad.stackKeyID)
        bridge.handleKeyPress(Pad.stackKeyID)
        await Task.yield()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(provider.createWorkspaceCalls, 1)
    }

    func testThePaneKeySplitsInTheConfiguredDirection() async {
        let provider = FakeProvider()
        let bridge = BridgeController(provider: provider)
        bridge.setKeyBindingsForTesting(KeyBindings(
            actions: [Pad.tabCycleKeyID: .herdr(.pane)],
            herdrSplitDirection: "down"
        ))
        bridge.handleKeyPress(Pad.tabCycleKeyID)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(provider.splitPaneCalls, ["down"])
    }

    func testTheCycleKeyCyclesTheConfiguredTools() async {
        let provider = FakeProvider()
        let bridge = BridgeController(provider: provider)
        bridge.setKeyBindingsForTesting(KeyBindings(
            actions: [Pad.landKeyID: .herdr(.cycle)],
            herdrTools: ["opencode", "claude", "codex"]
        ))
        bridge.handleKeyPress(Pad.landKeyID)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(provider.cycleToolCalls, [["opencode", "claude", "codex"]])
    }

    /// Two presses in a row must reach the provider twice — the chain
    /// serializes them, it never collapses them the way the wide key's
    /// debounce collapses one physical press's two switches.
    func testTwoCyclePressesBothReachTheProvider() async {
        let provider = FakeProvider()
        let bridge = BridgeController(provider: provider)
        bridge.setKeyBindingsForTesting(KeyBindings(actions: [Pad.landKeyID: .herdr(.cycle)]))

        bridge.handleKeyPress(Pad.landKeyID)
        bridge.handleKeyPress(Pad.landKeyID)
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(provider.cycleToolCalls.count, 2)
    }
}
