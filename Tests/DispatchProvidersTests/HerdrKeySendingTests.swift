import DispatchCore
import DispatchProviders
import Foundation
import XCTest

/// Configured actions reach a Herdr-like socket without using macOS automation.
final class HerdrKeySendingTests: XCTestCase {
    func testConfiguredBindingSendsKeysToThePaneFocusedAtPressTime() async throws {
        let (adapter, herdr, server) = try makeAdapter()
        defer { server.stop() }
        try await adapter.refresh()
        herdr.focus("right")
        let registry = try ActionRegistry(registrations: HerdrActions.registrations(controller: adapter))
        let actions = try configuredActions(#"[{"id":"herdr.pane.sendKeys","arguments":{"keys":["ctrl+z"]}}]"#)

        try await registry.execute(try XCTUnwrap(actions.first))

        XCTAssertEqual(herdr.sentInputs, [["pane_id": .string("right"), "keys": .array([.string("ctrl+z")])]])
        XCTAssertEqual(herdr.methods, ["session.snapshot", "session.snapshot", "pane.send_keys", "session.snapshot"])
        XCTAssertEqual(herdr.focusedPane, "right")
    }

    func testConfiguredMacroTargetsExplicitPanesAndPreservesKeyOrder() async throws {
        let (adapter, herdr, server) = try makeAdapter()
        defer { server.stop() }
        try await adapter.refresh()
        let registry = try ActionRegistry(registrations: HerdrActions.registrations(controller: adapter))
        let actions = try configuredActions("""
        [
          {"id":"herdr.pane.sendKeys","arguments":{"paneID":"right","keys":["esc","ctrl+z"]}},
          {"id":"herdr.pane.sendKeys","arguments":{"paneID":"left","keys":["ctrl+z"]}}
        ]
        """)

        for action in actions {
            try await registry.execute(action)
        }

        XCTAssertEqual(herdr.sentInputs, [
            ["pane_id": .string("right"), "keys": .array([.string("esc"), .string("ctrl+z")])],
            ["pane_id": .string("left"), "keys": .array([.string("ctrl+z")])]
        ])
        XCTAssertEqual(herdr.methods, [
            "session.snapshot", "pane.send_keys", "session.snapshot", "pane.send_keys", "session.snapshot"
        ])
        XCTAssertEqual(herdr.focusedPane, "left")
    }

    func testMissingFocusedPaneFailsWithoutSendingKeys() async throws {
        let (adapter, herdr, server) = try makeAdapter()
        defer { server.stop() }
        herdr.focus(nil)

        do {
            try await adapter.execute(invocation(arguments: ["keys": .array([.string("ctrl+z")])]))
            XCTFail("Expected a missing focus error")
        } catch let error as HerdrIntegrationError {
            XCTAssertEqual(error, .unavailableState("Herdr has no focused pane."))
        }

        XCTAssertTrue(herdr.sentInputs.isEmpty)
        XCTAssertEqual(herdr.methods, ["session.snapshot"])
    }

    func testHerdrKeyErrorReachesTheRegistryAndLeavesHerdrAvailable() async throws {
        let (adapter, herdr, server) = try makeAdapter()
        defer { server.stop() }
        try await adapter.refresh()
        herdr.rejectInput(code: "invalid_params", message: "Unsupported key")
        let registry = try ActionRegistry(registrations: HerdrActions.registrations(controller: adapter))
        let action = try registry.catalog.makeInvocation(
            id: HerdrActions.sendKeys,
            arguments: ["paneID": .string("left"), "keys": .array([.string("invalid-key")])]
        )

        do {
            try await registry.execute(action)
            XCTFail("Expected Herdr's key validation error")
        } catch let error as ActionExecutionError {
            guard case let .failed(id, message) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(id, HerdrActions.sendKeys)
            XCTAssertTrue(message.contains("Unsupported key"))
        }

        let available = await adapter.isAvailable()
        XCTAssertTrue(available)
        XCTAssertEqual(herdr.methods, ["session.snapshot", "pane.send_keys"])
    }

    func testMissingExplicitPaneDoesNotFallBackToFocus() async throws {
        let (adapter, herdr, server) = try makeAdapter()
        defer { server.stop() }
        herdr.rejectInput(code: "not_found", message: "No pane")

        do {
            try await adapter.execute(invocation(arguments: [
                "paneID": .string("gone"), "keys": .array([.string("ctrl+z")])
            ]))
            XCTFail("Expected a missing pane error")
        } catch let error as HerdrAPIError {
            XCTAssertEqual(error, .remote(code: "not_found", message: "No pane"))
        }

        XCTAssertEqual(herdr.methods, ["pane.send_keys"])
        XCTAssertEqual(herdr.sentInputs.first?["pane_id"], .string("gone"))
    }

    func testDecoderRejectsMalformedKeyArraysAndEmptyPaneID() async throws {
        let (adapter, herdr, server) = try makeAdapter()
        defer { server.stop() }
        let invalidKeys: [JSONValue] = [.array([]), .array([.integer(1)]), .array([.string("")]), .string("ctrl+z")]
        for keys in invalidKeys {
            let action = try invocation(arguments: ["keys": keys])
            XCTAssertThrowsError(try HerdrActions.decode(action)) { error in
                XCTAssertEqual(
                    error as? HerdrIntegrationError,
                    .invalidArgument(action: HerdrActions.sendKeys, name: "keys")
                )
            }
            do {
                try await adapter.execute(action)
                XCTFail("Expected invalid keys")
            } catch let error as HerdrIntegrationError {
                XCTAssertEqual(error, .invalidArgument(action: HerdrActions.sendKeys, name: "keys"))
            }
        }
        XCTAssertThrowsError(try HerdrActions.decode(invocation(arguments: [
            "keys": .array([.string("ctrl+z")]), "paneID": .string("")
        ]))) { error in
            XCTAssertEqual(
                error as? HerdrIntegrationError,
                .invalidArgument(action: HerdrActions.sendKeys, name: "paneID")
            )
        }
        XCTAssertTrue(herdr.methods.isEmpty)
    }

    func testCatalogRequiresKeysAndRejectsWrongTypesAndUnknownArguments() throws {
        let catalog = try ActionCatalog(definitions: HerdrActions.definitions)
        XCTAssertThrowsError(try catalog.makeInvocation(id: HerdrActions.sendKeys)) { error in
            XCTAssertEqual(error as? ActionValidationError, .missingArgument("keys"))
        }
        XCTAssertThrowsError(try catalog.makeInvocation(id: HerdrActions.sendKeys, arguments: ["keys": .string("esc")]))
        XCTAssertThrowsError(try catalog.makeInvocation(id: HerdrActions.sendKeys, arguments: [
            "keys": .array([.string("esc")]), "paneID": .integer(1)
        ]))
        XCTAssertThrowsError(try catalog.makeInvocation(id: HerdrActions.sendKeys, arguments: [
            "keys": .array([.string("esc")]), "all": .boolean(true)
        ])) { error in
            XCTAssertEqual(error as? ActionValidationError, .unknownArgument("all"))
        }
    }

    func testFocusedKeysRequireResolutionBeforeWireEncoding() throws {
        let action = try HerdrActions.decode(invocation(arguments: ["keys": .array([.string("ctrl+z")])]))
        XCTAssertEqual(action, .sendFocusedKeys(keys: ["ctrl+z"]))
        XCTAssertThrowsError(try HerdrProtocol22Codec().request(for: action)) { error in
            XCTAssertEqual(error as? HerdrProtocol22Error, .semanticActionRequiresState)
        }
    }

    func testDisconnectedRegistryReportsKeySendingUnavailable() async throws {
        let controller = RecordingHerdrController()
        let registry = try ActionRegistry(registrations: HerdrActions.registrations(controller: controller))
        let action = try registry.catalog.makeInvocation(
            id: HerdrActions.sendKeys, arguments: ["keys": .array([.string("esc")])]
        )
        do {
            try await registry.execute(action)
            XCTFail("Expected unavailable key sending")
        } catch let error as ActionExecutionError {
            XCTAssertEqual(error, .unavailable(HerdrActions.sendKeys))
        }
    }

    private func configuredActions(_ actionsJSON: String) throws -> [ActionInvocation] {
        let json = """
        {"version":1,"bindings":[{
          "when":{"control":{"type":"key","index":9},"gesture":{"type":"pressed"}},
          "actions":\(actionsJSON)
        }]}
        """
        let configuration = try JSONDecoder().decode(DispatchConfiguration.self, from: Data(json.utf8))
        let resolver = BindingResolver(bindings: try CompiledBindings.compile(
            configuration, catalog: ActionCatalog(definitions: HerdrActions.definitions)
        ))
        return resolver.resolve(DispatchEvent(
            source: DeviceIdentity(rawValue: "test-pad"), control: .key(9), gesture: .pressed, timestamp: Date()
        ))
    }

    private func invocation(arguments: [String: JSONValue]) throws -> ActionInvocation {
        let json: JSONValue = .object(["id": .string(HerdrActions.sendKeys.rawValue), "arguments": .object(arguments)])
        return try JSONDecoder().decode(ActionInvocation.self, from: JSONEncoder().encode(json))
    }

    private func makeAdapter() throws -> (HerdrAdapter, KeySendingSession, OneShotUnixServer) {
        let path = "/tmp/dispatch-keys-\(UUID().uuidString).sock"
        let herdr = KeySendingSession()
        let server: OneShotUnixServer
        do {
            server = try OneShotUnixServer(path: path, requestCount: 20) { herdr.respond(to: $0) }
        } catch let error as POSIXError where error.code == .EPERM {
            throw XCTSkip("The test host sandbox does not permit binding a Unix-domain socket.")
        }
        return (HerdrAdapter(
            client: HerdrUnixSocketClient(configuration: .init(socketPath: path, timeout: .seconds(1))),
            encoder: HerdrProtocol22Codec()
        ), herdr, server)
    }
}

/// A session whose focus can move outside Dispatch between polls and key presses.
private final class KeySendingSession: @unchecked Sendable {
    private let lock = NSLock()
    private var focused: String? = "left"
    private var requests: [[String: JSONValue]] = []
    private var inputError: JSONValue?

    var focusedPane: String? { lock.withLock { focused } }
    var methods: [String] {
        lock.withLock {
            requests.compactMap {
                guard case let .string(method)? = $0["method"] else { return nil }
                return method
            }
        }
    }
    var sentInputs: [[String: JSONValue]] {
        lock.withLock {
            requests.filter { $0["method"] == .string("pane.send_keys") }.compactMap {
                guard case let .object(params)? = $0["params"] else { return nil }
                return params
            }
        }
    }

    func focus(_ pane: String?) { lock.withLock { focused = pane } }

    func rejectInput(code: String, message: String) {
        lock.withLock { inputError = .object(["code": .string(code), "message": .string(message)]) }
    }

    func respond(to request: [String: JSONValue]) -> [String: JSONValue] {
        lock.withLock {
            requests.append(request)
            if request["method"] == .string("pane.send_keys") {
                if let inputError { return ["id": request["id"] ?? .null, "error": inputError] }
                return ["id": request["id"] ?? .null, "result": .object([:])]
            }
            return ["id": request["id"] ?? .null, "result": .object([
                "type": .string("session_snapshot"),
                "snapshot": .object([
                    "version": .string("0.9.3"), "protocol": .integer(22),
                    "focused_pane_id": focused.map(JSONValue.string) ?? .null,
                    "panes": .array([.object(["pane_id": .string("left")]), .object(["pane_id": .string("right")])]),
                    "tabs": .array([]), "agents": .array([])
                ])
            ])]
        }
    }
}
