import XCTest
@testable import WLKit

/// Pins `RoutingProvider`'s contract: routing to the active instance,
/// merged status with namespaced focus targets, per-child failure
/// isolation, and the `herdr.next_instance` action. All children are
/// fakes — nothing here touches a socket.
final class RoutingProviderTests: XCTestCase {

    private let local = HerdrInstance(id: "local", name: "Mac Mini", socketPath: "/tmp/local.sock")
    private let jarvis = HerdrInstance(id: "jarvis", name: "Jarvis", socketPath: "/tmp/jarvis.sock")

    /// A thread-safe counter for `@Sendable` subscribe callbacks.
    private final class Tally: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bump() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    /// A thread-safe last-value box for `@Sendable` callbacks.
    private final class Box<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T?
        func set(_ value: T) { lock.lock(); self.value = value; lock.unlock() }
        var current: T? { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func agent(_ pane: String, status: String = "idle") -> HerdrAgent {
        HerdrAgent(status: status, paneID: pane, terminalID: "t-\(pane)")
    }

    private func makeRouting(
        localAgents: [HerdrAgent] = [],
        jarvisAgents: [HerdrAgent] = []
    ) -> (routing: RoutingProvider, local: FakeProvider, jarvis: FakeProvider) {
        let localFake = FakeProvider()
        localFake.agentsToReturn = localAgents
        let jarvisFake = FakeProvider()
        jarvisFake.agentsToReturn = jarvisAgents
        let routing = RoutingProvider(children: [
            (instance: local, provider: localFake),
            (instance: jarvis, provider: jarvisFake)
        ])
        return (routing, localFake, jarvisFake)
    }

    // MARK: - describe

    func testDescribeIsTheFirstChildsWithTheSwitchActionAppended() async {
        let (routing, local, _) = makeRouting()
        local.descriptionToReturn = ProviderDescription(
            dialModes: [ProviderDialMode(id: "agent", label: "Agent", raisesHost: true)]
        )
        let description = await routing.describe()
        XCTAssertEqual(description.dialModes.map(\.id), ["agent"])
        XCTAssertEqual(description.actions.last?.id, "herdr.next_instance")
    }

    // MARK: - Active instance

    func testTheFirstChildIsActiveByDefault() {
        let (routing, _, _) = makeRouting()
        XCTAssertEqual(routing.activeInstanceID, "local")
    }

    func testDialJoystickInjectAndPerformGoToTheActiveChildOnly() async throws {
        let (routing, local, jarvis) = makeRouting()
        try await routing.dial(1, mode: "agent")
        try await routing.joystick(.east)
        try await routing.inject("hello")
        try await routing.perform("new_workspace")
        XCTAssertEqual(local.dialCalls.count, 1)
        XCTAssertEqual(local.joystickCalls, [.east])
        XCTAssertEqual(local.injectedTexts, ["hello"])
        XCTAssertEqual(local.performedActions, ["new_workspace"])
        XCTAssertTrue(jarvis.dialCalls.isEmpty)
        XCTAssertTrue(jarvis.joystickCalls.isEmpty)
        XCTAssertTrue(jarvis.injectedTexts.isEmpty)
        XCTAssertTrue(jarvis.performedActions.isEmpty)
    }

    func testSetActiveInstanceRoutesSubsequentInputToTheNewChild() async throws {
        let (routing, local, jarvis) = makeRouting()
        routing.setActiveInstance("jarvis")
        XCTAssertEqual(routing.activeInstanceID, "jarvis")
        try await routing.dial(1, mode: "agent")
        XCTAssertTrue(local.dialCalls.isEmpty)
        XCTAssertEqual(jarvis.dialCalls.count, 1)
    }

    func testAnUnknownInstanceIdIsIgnored() async throws {
        let (routing, _, _) = makeRouting()
        routing.setActiveInstance("typo")
        XCTAssertEqual(routing.activeInstanceID, "local")
    }

    func testSettingTheSameActiveInstanceDoesNotNotify() {
        let (routing, _, _) = makeRouting()
        let notifications = Tally()
        let subscription = routing.subscribe { notifications.bump() }
        routing.setActiveInstance("local")
        XCTAssertEqual(notifications.value, 0)
        subscription.cancel()
    }

    func testAnUnknownActionIsForwardedButTheSwitchActionIsNot() async throws {
        let (routing, local, jarvis) = makeRouting()
        try await routing.perform("explode")
        XCTAssertEqual(local.performedActions, ["explode"])
        routing.setActiveInstance("jarvis")
        try await routing.perform("herdr.next_instance")
        XCTAssertTrue(jarvis.performedActions.isEmpty, "the switch action is RoutingProvider's own")
        XCTAssertEqual(routing.activeInstanceID, "local", "two instances cycle back to the first")
    }

    // MARK: - Merged status

    func testStatusMergesEveryChildStampsInstanceIDsAndPutsTheActiveFirst() async throws {
        let (routing, _, _) = makeRouting(
            localAgents: [agent("w1:p1"), agent("w1:p2")],
            jarvisAgents: [agent("w13:p1")]
        )
        let agents = try await routing.status()
        XCTAssertEqual(agents.map(\.paneID), ["w1:p1", "w1:p2", "w13:p1"])
        XCTAssertEqual(agents.map(\.instanceID), ["local", "local", "jarvis"])
        XCTAssertEqual(agents.map(\.focusTarget),
                       ["local\u{1}w1:p1", "local\u{1}w1:p2", "jarvis\u{1}w13:p1"])
    }

    func testSwitchingInstancesMovesThatInstancesAgentsToTheFront() async throws {
        let (routing, _, _) = makeRouting(
            localAgents: [agent("w1:p1")],
            jarvisAgents: [agent("w13:p1"), agent("w13:p2")]
        )
        routing.setActiveInstance("jarvis")
        let agents = try await routing.status()
        XCTAssertEqual(agents.map(\.paneID), ["w13:p1", "w13:p2", "w1:p1"])
    }

    func testEachInstancesAgentsKeepTheirReportedOrder() async throws {
        let (routing, _, _) = makeRouting(
            jarvisAgents: [agent("b"), agent("a")]
        )
        let agents = try await routing.status()
        XCTAssertEqual(agents.filter { $0.instanceID == "jarvis" }.map(\.paneID), ["b", "a"],
                       "reported order is never re-sorted")
    }

    // MARK: - Failure isolation

    func testADeadRemoteNeverBlanksTheLocalPad() async throws {
        let (routing, local, jarvis) = makeRouting(localAgents: [agent("w1:p1")])
        jarvis.statusError = HerdrError.cannotConnect("/tmp/jarvis.sock", "no such file")
        let agents = try await routing.status()
        XCTAssertEqual(agents.map(\.paneID), ["w1:p1"], "the local pad survives a dead remote")
        XCTAssertEqual(routing.lastError, "Jarvis: Cannot reach the Herdr server at /tmp/jarvis.sock: no such file")
    }

    func testAnErrorFreeRefreshClearsTheLastError() async throws {
        let (routing, local, jarvis) = makeRouting()
        jarvis.statusError = HerdrError.cannotConnect("/tmp/jarvis.sock", "no such file")
        _ = try await routing.status()
        XCTAssertNotNil(routing.lastError)
        jarvis.statusError = nil
        _ = try await routing.status()
        XCTAssertNil(routing.lastError)
    }

    func testEveryChildFailingAnswersEmptyRatherThanThrowing() async throws {
        let (routing, local, jarvis) = makeRouting()
        local.statusError = HerdrError.cannotConnect("/tmp/local.sock", "no such file")
        jarvis.statusError = HerdrError.cannotConnect("/tmp/jarvis.sock", "no such file")
        let agents = try await routing.status()
        XCTAssertTrue(agents.isEmpty)
        XCTAssertNotNil(routing.lastError)
    }

    /// A wedged tunnel accepts connections but never answers, so retrying
    /// it on every refresh costs its timeout each time. A timed-out instance
    /// backs off instead of being polled; a refused connection — cheap — is
    /// retried every refresh.
    func testATimedOutInstanceBacksOff() async throws {
        let (routing, _, jarvis) = makeRouting(localAgents: [agent("w1:p1")])
        jarvis.statusError = HerdrError.timeout("agent.list")
        _ = try await routing.status()
        XCTAssertEqual(jarvis.statusCallCount, 1)
        let held = routing.lastError
        XCTAssertNotNil(held)
        _ = try await routing.status()
        XCTAssertEqual(jarvis.statusCallCount, 1, "backed off — not retried immediately")
        XCTAssertEqual(routing.lastError, held,
                       "a backed-off instance is skipped, but still says why it is down")
    }

    /// Backoff exists for the wedged tunnel, which is exactly the failure you
    /// cannot spot by looking at the terminal. Skipping its poll must not
    /// also silence it, or the panel claims a healthy pad for the whole
    /// backoff window — which doubles up to five minutes.
    func testABackedOffInstanceKeepsReportingUntilItAnswers() async throws {
        let (routing, _, jarvis) = makeRouting(localAgents: [agent("w1:p1")])
        jarvis.statusError = HerdrError.timeout("agent.list")
        _ = try await routing.status()

        // Several refreshes deep into the backoff, still saying why.
        for _ in 0..<3 { _ = try await routing.status() }
        XCTAssertEqual(jarvis.statusCallCount, 1, "still backed off")
        XCTAssertEqual(routing.lastError, "Jarvis: Timed out waiting for agent.list.")

        // The local instance is untouched throughout — a wedged remote
        // reports itself without ever blanking the pad.
        let agents = try await routing.status()
        XCTAssertEqual(agents.map(\.paneID), ["w1:p1"])
    }

    func testARefusedConnectionIsRetriedEveryRefresh() async throws {
        let (routing, _, jarvis) = makeRouting(localAgents: [agent("w1:p1")])
        jarvis.statusError = HerdrError.cannotConnect("/tmp/jarvis.sock", "no such file")
        _ = try await routing.status()
        XCTAssertEqual(jarvis.statusCallCount, 1)
        _ = try await routing.status()
        XCTAssertEqual(jarvis.statusCallCount, 2, "a refused connection is cheap — retried next refresh")
        XCTAssertEqual(routing.lastError, "Jarvis: Cannot reach the Herdr server at /tmp/jarvis.sock: no such file")
    }

    // MARK: - Focus routing

    func testANamespacedFocusGoesToItsOwnInstanceAndRaisesIt() async throws {
        let (routing, local, jarvis) = makeRouting()
        let raisedFor = Box<String>()
        routing.onFocusInstance = { raisedFor.set($0) }
        try await routing.focus("jarvis\u{1}w13:p1")
        XCTAssertTrue(local.focusCalls.isEmpty)
        XCTAssertEqual(jarvis.focusCalls, ["w13:p1"], "the namespace prefix is stripped before agent.focus")
        XCTAssertEqual(raisedFor.current, "jarvis")
    }

    func testAnUnnamespacedFocusGoesToTheActiveChildUnchanged() async throws {
        let (routing, local, jarvis) = makeRouting()
        try await routing.focus("w3:p1")
        XCTAssertEqual(local.focusCalls, ["w3:p1"])
        XCTAssertTrue(jarvis.focusCalls.isEmpty)
    }

    /// A namespaced target names its owner, and pane ids collide across
    /// instances — a target whose owner is gone is not addressable anywhere,
    /// so the press is dropped rather than handed to the active child, where
    /// the raw id could match an unrelated pane on the wrong machine.
    func testAFocusForAnUnknownInstanceIsDroppedWithAnError() async throws {
        let (routing, local, _) = makeRouting()
        do {
            try await routing.focus("ghost\u{1}w1:p1")
            XCTFail("a ghost-instance target must not silently route anywhere")
        } catch let error as HerdrError {
            guard case .api(let message) = error else { return XCTFail("unexpected error: \(error)") }
            XCTAssertTrue(message.contains("ghost"), message)
        }
        XCTAssertTrue(local.focusCalls.isEmpty, "the raw id never reaches any child")
    }

    // MARK: - Subscribe fan-out

    func testAnyChildChangingFiresTheBridge() {
        let (routing, local, jarvis) = makeRouting()
        let notifications = Tally()
        // Retained, the way `BridgeController` retains its subscription —
        // an uncanceled-but-discarded token cancels itself on deinit.
        let subscription = routing.subscribe { notifications.bump() }
        local.fireChange()
        XCTAssertEqual(notifications.value, 1)
        jarvis.fireChange()
        XCTAssertEqual(notifications.value, 2)
        subscription.cancel()
    }

    func testCancelingStopsTheFanOut() {
        let (routing, local, _) = makeRouting()
        let notifications = Tally()
        let subscription = routing.subscribe { notifications.bump() }
        subscription.cancel()
        local.fireChange()
        XCTAssertEqual(notifications.value, 0)
    }
}
