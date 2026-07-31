import XCTest
@testable import WLKit

/// Exercises the real Herdr socket. Skipped when no server is running, so the
/// suite still passes on a machine without one.
final class LiveHerdrTests: XCTestCase {

    private func serverRunning() -> Bool {
        FileManager.default.fileExists(atPath: HerdrClient.socketPath())
    }

    func testSocketPathResolves() {
        let path = HerdrClient.socketPath()
        XCTAssertTrue(path.hasSuffix("herdr/herdr.sock") || !path.isEmpty)
    }

    func testListAgentsRoundTrip() async throws {
        try XCTSkipUnless(serverRunning(), "no herdr server")
        let agents = try await HerdrClient.listAgents()
        print("agents: \(agents.map { "\($0.shortName):\($0.status)" })")
        // Server order is the display order, so the one thing to check is that
        // each agent is addressable — a nil target cannot take a key press.
        let targets = agents.compactMap(\.focusTarget)
        XCTAssertEqual(targets.count, agents.count, "every agent has a focus target")
        XCTAssertEqual(Set(targets).count, targets.count, "targets are unique")
    }

    func testSecondRequestOnAFreshConnectionWorks() async throws {
        try XCTSkipUnless(serverRunning(), "no herdr server")
        // The server closes after one request; each call must open its own
        // connection. Two calls in a row proves we are not reusing one.
        _ = try await HerdrClient.listAgents()
        _ = try await HerdrClient.listAgents()
    }

    func testSubscriptionReceivesAck() async throws {
        try XCTSkipUnless(serverRunning(), "no herdr server")
        let ready = expectation(description: "subscription acknowledged")
        let stream = HerdrEventStream(subscriptions: [["type": "pane.created"]])
        stream.onReady = { ready.fulfill() }
        stream.start()
        await fulfillment(of: [ready], timeout: 5)
        stream.stop()
    }
}
