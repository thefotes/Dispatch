import XCTest
@testable import WLKit

/// Pins the namespaced focus-target scheme: with several Herdr instances
/// merged into one status list, pane ids collide across instances and every
/// target must name its owner. The separator is a control character no
/// Herdr id can contain, so no instance can be mistaken for another.
final class FocusTargetNamespacingTests: XCTestCase {

    func testAnAgentWithoutAnInstanceIsUnnamespaced() {
        let agent = HerdrAgent(status: "idle", paneID: "w3:p1")
        XCTAssertEqual(agent.focusTarget, "w3:p1")
    }

    func testAnInstanceIDPrefixesTheTarget() {
        var agent = HerdrAgent(status: "idle", paneID: "w13:p1")
        agent.instanceID = "jarvis"
        XCTAssertEqual(agent.focusTarget, "jarvis\u{1}w13:p1")
    }

    func testTheNamespaceSurvivesTheTerminalIDFallback() {
        var agent = HerdrAgent(status: "idle", terminalID: "t7")
        agent.instanceID = "jarvis"
        XCTAssertEqual(agent.focusTarget, "jarvis\u{1}t7")
    }

    func testNoTargetMeansNoTargetEvenNamespaced() {
        var agent = HerdrAgent(status: "idle")
        agent.instanceID = "jarvis"
        XCTAssertNil(agent.focusTarget)
    }

    func testSplitRoundTripsANamespacedTarget() {
        let (instance, raw) = HerdrAgent.splitFocusTarget("jarvis\u{1}w13:p1")
        XCTAssertEqual(instance, "jarvis")
        XCTAssertEqual(raw, "w13:p1")
    }

    func testSplitRoundTripsAnUnnamespacedTarget() {
        let (instance, raw) = HerdrAgent.splitFocusTarget("w3:p1")
        XCTAssertNil(instance)
        XCTAssertEqual(raw, "w3:p1")
    }

    func testAMalformedTargetIsReturnedIntact() {
        // A leading or trailing separator would make one half empty — no
        // honest instance id or target looks like that, so the whole string
        // is handed to the active child rather than split badly.
        XCTAssertEqual(HerdrAgent.splitFocusTarget("\u{1}w1:p1").instanceID, nil)
        XCTAssertEqual(HerdrAgent.splitFocusTarget("jarvis\u{1}").instanceID, nil)
        XCTAssertEqual(HerdrAgent.splitFocusTarget("jarvis\u{1}").raw, "jarvis\u{1}")
    }

    func testOnlyTheFirstSeparatorSplits() {
        let (instance, raw) = HerdrAgent.splitFocusTarget("a\u{1}b\u{1}c")
        XCTAssertEqual(instance, "a")
        XCTAssertEqual(raw, "b\u{1}c")
    }

    /// Slice 0 acceptance, in test form: a provider pointed at a different
    /// socket path really does target that path. Nothing live is contacted
    /// — a nonexistent path fails with that path in the error, which is the
    /// proof.
    func testASecondClientTargetsItsOwnSocket() async {
        let remote = HerdrClient(socketPath: "/tmp/definitely-not-a-socket-test.sock")
        do {
            _ = try await remote.request("agent.list", timeout: 1)
            XCTFail("nothing is listening there")
        } catch {
            guard case .cannotConnect(let path, _) = error as? HerdrError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(path, "/tmp/definitely-not-a-socket-test.sock")
        }
    }

    func testTheDefaultClientStillTargetsTheDefaultSocket() {
        XCTAssertEqual(HerdrClient().socketPath, HerdrClient.defaultSocketPath())
        XCTAssertEqual(HerdrClient.shared.socketPath, HerdrClient.defaultSocketPath())
        XCTAssertTrue(HerdrClient.defaultSocketPath().hasSuffix("herdr.sock"))
    }
}
