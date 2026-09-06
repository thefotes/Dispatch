import XCTest
@testable import WLKit

/// `RemoteProvider` talking to a real `ProviderBridgeServer` over a real Unix
/// socket, both ends in this process — unlike Herdr's own socket, we own
/// both sides, so this needs no "skip if no server running" escape hatch.
final class ProviderBridgeRoundTripTests: XCTestCase {

    private func makePair(_ fake: FakeProvider) throws -> (RemoteProvider, ProviderBridgeServer, String) {
        // `sun_path` is capped at ~104 bytes on macOS, so this needs to stay
        // short — NSTemporaryDirectory()'s per-app path is already too long
        // on its own with a UUID appended.
        let path = "/tmp/pbt-\(UUID().uuidString.prefix(8)).sock"
        let server = ProviderBridgeServer(provider: fake, socketPath: path)
        try server.start()
        return (RemoteProvider(socketPath: path, timeout: 3), server, path)
    }

    /// `start()` used to unlink unconditionally, so a second server on the
    /// same path silently stole the socket file out from under a live one —
    /// the first kept running but became unreachable. `start()` must now
    /// refuse instead, and the first server must still answer afterward.
    func testStartingASecondServerOnALivePathRefusesRatherThanHijackingIt() async throws {
        let first = FakeProvider()
        let (remote, server, path) = try makePair(first)
        defer { server.stop() }

        let second = ProviderBridgeServer(provider: FakeProvider(), socketPath: path)
        XCTAssertThrowsError(try second.start())

        // The original server is still the one answering.
        _ = try await remote.status()
    }

    /// A stale socket file left behind by a crashed previous run — nothing
    /// listening on it — must not block a fresh `start()`.
    func testStartingOverAStaleSocketFileStillWorks() throws {
        let path = "/tmp/pbt-\(UUID().uuidString.prefix(8)).sock"
        // A plain file at the path, not a socket anything is listening on —
        // stands in for a stale file from a process that never cleaned up.
        FileManager.default.createFile(atPath: path, contents: Data())
        defer { try? FileManager.default.removeItem(atPath: path) }

        let server = ProviderBridgeServer(provider: FakeProvider(), socketPath: path)
        defer { server.stop() }
        XCTAssertNoThrow(try server.start())
    }

    func testDescribeRoundTrips() async throws {
        let fake = FakeProvider()
        fake.descriptionToReturn = ProviderDescription(
            statePalette: ["blocked": ProviderStateStyle(color: 0xFF2D2D, effect: .breath)],
            statePriority: ["blocked"],
            dialModes: [ProviderDialMode(id: "agent", label: "Agent", raisesHost: true)]
        )
        let (remote, server, _) = try makePair(fake)
        defer { server.stop() }

        let description = await remote.describe()
        XCTAssertEqual(description, fake.descriptionToReturn)
    }

    func testStatusRoundTrips() async throws {
        let fake = FakeProvider()
        fake.agentsToReturn = [HerdrAgent(agent: "claude", status: "working", paneID: "p1", focused: true)]
        let (remote, server, _) = try makePair(fake)
        defer { server.stop() }

        let agents = try await remote.status()
        XCTAssertEqual(agents, fake.agentsToReturn)
    }

    func testFocusForwardsTheTarget() async throws {
        let fake = FakeProvider()
        let (remote, server, _) = try makePair(fake)
        defer { server.stop() }

        try await remote.focus("pane-7")
        XCTAssertEqual(fake.focusCalls, ["pane-7"])
    }

    func testDialForwardsStepAndMode() async throws {
        let fake = FakeProvider()
        let (remote, server, _) = try makePair(fake)
        defer { server.stop() }

        try await remote.dial(-1, mode: "space")
        XCTAssertEqual(fake.dialCalls.map(\.step), [-1])
        XCTAssertEqual(fake.dialCalls.map(\.mode), ["space"])
    }

    func testJoystickForwardsTheDirection() async throws {
        let fake = FakeProvider()
        let (remote, server, _) = try makePair(fake)
        defer { server.stop() }

        try await remote.joystick(.north)
        XCTAssertEqual(fake.joystickCalls, [.north])
    }

    func testInjectForwardsTheText() async throws {
        let fake = FakeProvider()
        let (remote, server, _) = try makePair(fake)
        defer { server.stop() }

        try await remote.inject("ship it")
        XCTAssertEqual(fake.injectedTexts, ["ship it"])
    }

    func testPerformForwardsTheActionName() async throws {
        let fake = FakeProvider()
        let (remote, server, _) = try makePair(fake)
        defer { server.stop() }

        try await remote.perform("new_workspace")
        XCTAssertEqual(fake.performedActions, ["new_workspace"])
    }

    func testPerformWithoutAnActionIsRejected() async throws {
        let fake = FakeProvider()
        let (remote, server, path) = try makePair(fake)
        defer { server.stop() }

        // Hand-crafted envelope: the wire method exists but the required
        // parameter is missing, which the server must refuse rather than
        // forward an empty action to the provider. The reply is read
        // before the connection closes — a write to a socket the peer has
        // already dropped raises SIGPIPE, which kills the whole test run.
        let reply = try Self.roundTripOnFreshConnection(
            path: path,
            envelope: ["id": "t", "method": "provider.perform", "params": [String: Any]()]
        )
        XCTAssertTrue(reply.contains("needs an action"), "unexpected reply: \(reply)")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(fake.performedActions, [])
    }

    /// One request on its own connection, the same shape the server expects,
    /// returning the reply line — the plain-socket stand-in for what
    /// `RemoteProvider.request` does, for envelopes its API cannot express.
    private static func roundTripOnFreshConnection(path: String, envelope: [String: Any]) throws -> String {
        let payload = try JSONSerialization.data(withJSONObject: envelope) + Data("\n".utf8)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HerdrError.cannotConnect(path, "socket() failed") }
        defer { Darwin.close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < maxLength else {
            throw HerdrError.cannotConnect(path, "socket path too long")
        }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
            path.withCString { source in
                strncpy(UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self), source, maxLength - 1)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, size) }
        }
        guard result == 0 else { throw HerdrError.cannotConnect(path, String(cString: strerror(errno))) }

        var sent = 0
        while sent < payload.count {
            let n = payload.withUnsafeBytes { raw in
                Darwin.write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
            }
            guard n > 0 else { throw HerdrError.closed("roundTripOnFreshConnection") }
            sent += n
        }

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Darwin.read(fd, &chunk, chunk.count)
            guard n > 0 else { break }
            buffer.append(contentsOf: chunk[0..<n])
            if buffer.contains(UInt8(ascii: "\n")) { break }
        }
        guard let line = String(data: buffer, encoding: .utf8), !line.isEmpty else {
            throw HerdrError.closed("roundTripOnFreshConnection")
        }
        return line
    }

    /// A thrown provider error crosses the socket as a message, same as any
    /// other `Provider` error `BridgeController` surfaces as `lastError`.
    func testAThrownErrorCrossesTheSocketAsAMessage() async throws {
        let fake = FakeProvider()
        fake.injectError = HerdrError.api("nothing focused")
        let (remote, server, _) = try makePair(fake)
        defer { server.stop() }

        do {
            try await remote.inject("hi")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "nothing focused")
        }
    }

    /// `subscribe` acks immediately, then a change the fake provider fires
    /// (the server forwards whatever `Provider.subscribe`'s callback does)
    /// reaches the client as one call.
    func testSubscribeDeliversAChangeNotification() async throws {
        let fake = FakeProvider()
        let (remote, server, _) = try makePair(fake)
        defer { server.stop() }

        let changed = expectation(description: "change notification received")
        let subscription = remote.subscribe { changed.fulfill() }
        // Give the ack a moment to land before triggering a change, the way
        // a real provider's first event always arrives after its ack.
        try await Task.sleep(nanoseconds: 200_000_000)
        fake.fireChange()
        await fulfillment(of: [changed], timeout: 3)
        subscription.cancel()
    }
}
