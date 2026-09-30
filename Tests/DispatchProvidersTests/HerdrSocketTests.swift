import Darwin
import Dispatch
import DispatchCore
import DispatchProviders
import Foundation
import XCTest

/// Exercises the Unix-socket client and adapter against an in-process server
/// that behaves like Herdr: one request per connection.
final class HerdrSocketTests: XCTestCase {
    func testSocketClientFramesNDJSONAndCorrelatesResponse() async throws {
        let path = "/tmp/dispatch-herdr-\(UUID().uuidString).sock"
        let server = try unixServer(path: path) { request in request }
        defer { server.stop() }
        let client = HerdrUnixSocketClient(configuration: .init(socketPath: path, timeout: .seconds(1)))

        let response = try await client.request(["command": .string("ping")])
        XCTAssertEqual(response["command"], .string("ping"))
        XCTAssertNotNil(response["id"])
        XCTAssertEqual(server.receivedLineCount, 1)
    }

    func testSocketClientReadsResponseSplitAcrossWrites() async throws {
        let path = "/tmp/dispatch-herdr-\(UUID().uuidString).sock"
        let server = try unixServer(path: path) { $0 } responseChunks: { data in
            let bytes = Array(data)
            return [Data(bytes.prefix(5)), Data(bytes.dropFirst(5).dropLast()), Data([0x0A])]
        }
        defer { server.stop() }
        let client = HerdrUnixSocketClient(configuration: .init(socketPath: path, timeout: .seconds(1)))

        let response = try await client.request(["command": .string("split")])
        XCTAssertEqual(response["command"], .string("split"))
    }

    func testSocketClientReadsResponseLargerThanOneReadBuffer() async throws {
        let path = "/tmp/dispatch-herdr-\(UUID().uuidString).sock"
        let content = String(repeating: "x", count: 20_000)
        let server = try unixServer(path: path) { request in
            ["id": request["id"] ?? .null, "content": .string(content)]
        }
        defer { server.stop() }
        let client = HerdrUnixSocketClient(configuration: .init(socketPath: path, timeout: .seconds(1)))

        let response = try await client.request(["command": .string("chunked")])
        XCTAssertEqual(response["content"], .string(content))
    }

    func testSocketClientRejectsOversizeResponseAcrossChunks() async throws {
        let path = "/tmp/dispatch-herdr-\(UUID().uuidString).sock"
        let server = try unixServer(path: path) { $0 } responseChunks: { data in
            let bytes = Array(data)
            return [Data(bytes.prefix(20)), Data(bytes.dropFirst(20))]
        }
        defer { server.stop() }
        let client = HerdrUnixSocketClient(configuration: .init(
            socketPath: path, timeout: .seconds(1), maximumLineBytes: 32
        ))

        do {
            _ = try await client.request(["command": .string("oversize")])
            XCTFail("Expected an oversize response")
        } catch let error as HerdrSocketError {
            XCTAssertEqual(error, .responseTooLarge)
        }
    }

    func testSocketClientReportsDisconnectBeforeCompleteLine() async throws {
        let path = "/tmp/dispatch-herdr-\(UUID().uuidString).sock"
        let server = try unixServer(path: path) { $0 } responseChunks: { data in
            [Data(data.prefix(5))]
        }
        defer { server.stop() }
        let client = HerdrUnixSocketClient(configuration: .init(socketPath: path, timeout: .seconds(1)))

        do {
            _ = try await client.request(["command": .string("disconnect")])
            XCTFail("Expected a disconnect")
        } catch let error as HerdrSocketError {
            XCTAssertEqual(error, .disconnected)
        }
    }

    func testSocketClientRejectsMismatchedCorrelation() async throws {
        let path = "/tmp/dispatch-herdr-\(UUID().uuidString).sock"
        let server = try unixServer(path: path) { request in
            var response = request
            response["id"] = .string("wrong")
            return response
        }
        defer { server.stop() }
        let client = HerdrUnixSocketClient(configuration: .init(socketPath: path, timeout: .seconds(1)))

        do {
            _ = try await client.request(["command": .string("ping")])
            XCTFail("Expected correlation failure")
        } catch let error as HerdrSocketError {
            guard case .unexpectedCorrelationID = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testSocketClientSurfacesDocumentedRemoteError() async throws {
        let path = "/tmp/dispatch-herdr-\(UUID().uuidString).sock"
        let server = try unixServer(path: path) { request in
            [
                "id": request["id"] ?? .null,
                "error": .object(["code": .string("not_found"), "message": .string("No pane")])
            ]
        }
        defer { server.stop() }
        let client = HerdrUnixSocketClient(configuration: .init(socketPath: path, timeout: .seconds(1)))

        do {
            _ = try await client.request(["method": .string("pane.close"), "params": .object([:])])
            XCTFail("Expected remote error")
        } catch let error as HerdrAPIError {
            XCTAssertEqual(error, .remote(code: "not_found", message: "No pane"))
        }
    }

    func testConsecutiveTabCyclesEachAdvanceFromTheNewlyFocusedTab() async throws {
        let path = "/tmp/dispatch-herdr-\(UUID().uuidString).sock"
        let herdr = FakeHerdrTabs(ids: ["tab-1", "tab-2", "tab-3"])
        let server = try unixServer(path: path, requestCount: 7) { herdr.respond(to: $0) }
        defer { server.stop() }
        let adapter = HerdrAdapter(
            client: HerdrUnixSocketClient(configuration: .init(socketPath: path, timeout: .seconds(1))),
            encoder: HerdrProtocol22Codec()
        )

        try await adapter.refresh()
        try await adapter.execute(.cycleTab(delta: 1))
        try await adapter.execute(.cycleTab(delta: 1))

        XCTAssertEqual(herdr.focusedTab, "tab-3")
    }

    func testClosingTheFocusedPaneClosesThePaneHerdrFocusesNow() async throws {
        let path = "/tmp/dispatch-herdr-\(UUID().uuidString).sock"
        let herdr = FakeHerdrPanes(ids: ["left", "right"], focused: "left")
        let server = try unixServer(path: path, requestCount: 4) { herdr.respond(to: $0) }
        defer { server.stop() }
        let adapter = HerdrAdapter(
            client: HerdrUnixSocketClient(configuration: .init(socketPath: path, timeout: .seconds(1))),
            encoder: HerdrProtocol22Codec()
        )

        try await adapter.refresh()
        herdr.focus("right")
        try await adapter.execute(.closeFocusedPane)

        XCTAssertEqual(herdr.remainingPanes, ["left"])
    }

    func testTabCycleAdvancesFromTheTabHerdrFocusesNow() async throws {
        let path = "/tmp/dispatch-herdr-\(UUID().uuidString).sock"
        let herdr = FakeHerdrTabs(ids: ["tab-1", "tab-2", "tab-3"])
        let server = try unixServer(path: path, requestCount: 4) { herdr.respond(to: $0) }
        defer { server.stop() }
        let adapter = HerdrAdapter(
            client: HerdrUnixSocketClient(configuration: .init(socketPath: path, timeout: .seconds(1))),
            encoder: HerdrProtocol22Codec()
        )

        try await adapter.refresh()
        herdr.focus("tab-2")
        try await adapter.execute(.cycleTab(delta: 1))

        XCTAssertEqual(herdr.focusedTab, "tab-3")
    }

    func testRepeatedTextCycleReplacesTheWordItTyped() async throws {
        let (adapter, prompt, server) = try makePromptAdapter()
        defer { server.stop() }
        let options = ["claude", "codex", "opencode"]

        var lines: [String] = []
        for _ in 0..<4 {
            try await adapter.execute(.cycleText(options: options))
            lines.append(prompt.line)
        }

        XCTAssertEqual(lines, ["$ claude", "$ codex", "$ opencode", "$ claude"])
    }

    func testFirstTextCyclePressUsesOneSnapshotAndOneTypingRequest() async throws {
        let (adapter, prompt, server) = try makePromptAdapter()
        defer { server.stop() }

        try await adapter.execute(.cycleText(options: ["claude", "codex"]))

        XCTAssertEqual(prompt.line, "$ claude")
        XCTAssertEqual(server.receivedLineCount, 2)
    }

    func testTextCycleRestartsWithoutErasingOnceThePromptChanged() async throws {
        let (adapter, prompt, server) = try makePromptAdapter()
        defer { server.stop() }
        let options = ["claude", "codex", "opencode"]

        try await adapter.execute(.cycleText(options: options))
        try await adapter.execute(.cycleText(options: options))
        prompt.pressReturn()
        try await adapter.execute(.cycleText(options: options))

        XCTAssertEqual(prompt.line, "$ claude")
        XCTAssertEqual(prompt.history, ["$ codex"])
    }

    private func makePromptAdapter() throws -> (HerdrAdapter, FakeHerdrPrompt, OneShotUnixServer) {
        let path = "/tmp/dispatch-herdr-\(UUID().uuidString).sock"
        let prompt = FakeHerdrPrompt(paneID: "pane-1")
        let server = try unixServer(path: path, requestCount: 100) { prompt.respond(to: $0) }
        let adapter = HerdrAdapter(
            client: HerdrUnixSocketClient(configuration: .init(socketPath: path, timeout: .seconds(1))),
            encoder: HerdrProtocol22Codec()
        )
        return (adapter, prompt, server)
    }

    func testRemoteActionErrorLeavesHerdrAvailable() async throws {
        let path = "/tmp/dispatch-herdr-\(UUID().uuidString).sock"
        let server = try unixServer(path: path, requestCount: 3) { request in
            guard request["method"] == .string("session.snapshot") else {
                return [
                    "id": request["id"] ?? .null,
                    "error": .object(["code": .string("not_found"), "message": .string("No tab")])
                ]
            }
            return ["id": request["id"] ?? .null, "result": Self.minimalSnapshot]
        }
        defer { server.stop() }
        let adapter = HerdrAdapter(
            client: HerdrUnixSocketClient(configuration: .init(socketPath: path, timeout: .seconds(1))),
            encoder: HerdrProtocol22Codec()
        )

        try await adapter.refresh()
        do {
            try await adapter.execute(.focusTab(id: "gone"))
            XCTFail("Expected remote error")
        } catch let error as HerdrAPIError {
            XCTAssertEqual(error, .remote(code: "not_found", message: "No tab"))
        }
        let availableAfterRemoteError = await adapter.isAvailable()
        XCTAssertTrue(availableAfterRemoteError)
    }

    func testRefreshingAnAvailableHerdrDoesNotReportItUnavailable() async throws {
        let path = "/tmp/dispatch-herdr-\(UUID().uuidString).sock"
        let server = try unixServer(path: path, requestCount: 2) { request in
            ["id": request["id"] ?? .null, "result": Self.minimalSnapshot]
        }
        defer { server.stop() }
        let adapter = HerdrAdapter(
            client: HerdrUnixSocketClient(configuration: .init(socketPath: path, timeout: .seconds(1))),
            encoder: HerdrProtocol22Codec()
        )
        let states = await adapter.states()
        try await adapter.refresh()
        try await adapter.refresh()

        let collector = Task { () -> [HerdrAvailability] in
            var observed: [HerdrAvailability] = []
            for await state in states {
                observed.append(state.availability)
            }
            return observed
        }
        try await Task.sleep(for: .milliseconds(50))
        collector.cancel()
        let observed = await collector.value
        XCTAssertEqual(observed, [.disconnected, .connecting, .available])
    }

    func testRepeatedFailedPollsEmitOneUnavailableStateUntilRecovery() async throws {
        let path = "/tmp/dispatch-herdr-\(UUID().uuidString).sock"
        let adapter = HerdrAdapter(
            client: HerdrUnixSocketClient(configuration: .init(socketPath: path, timeout: .seconds(1))),
            encoder: HerdrProtocol22Codec()
        )
        let states = await adapter.states()

        for _ in 0..<3 {
            do {
                try await adapter.refresh()
                XCTFail("Expected the absent socket to fail")
            } catch let error as HerdrSocketError {
                guard case .connectionFailed = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }

        let server = try unixServer(path: path) { request in
            ["id": request["id"] ?? .null, "result": Self.minimalSnapshot]
        }
        try await adapter.refresh()
        server.stop()
        for _ in 0..<2 {
            try? await adapter.refresh()
        }

        let collector = Task { () -> [HerdrAvailability] in
            var observed: [HerdrAvailability] = []
            for await state in states {
                observed.append(state.availability)
            }
            return observed
        }
        try await Task.sleep(for: .milliseconds(50))
        collector.cancel()
        let observed = await collector.value
        XCTAssertEqual(observed, [.disconnected, .connecting, .disconnected, .available, .disconnected])
    }

    private static let minimalSnapshot: JSONValue = .object([
        "type": .string("session_snapshot"),
        "snapshot": .object([
            "version": .string("1.0.0"),
            "protocol": .integer(22),
            "focused_tab_id": .string("tab-1"),
            "panes": .array([]),
            "agents": .array([]),
            "tabs": .array([.object(["tab_id": .string("tab-1"), "label": .string("1"), "focused": .boolean(true)])])
        ])
    ])

    func testSocketClientSendsSequentialRequestsAfterTheServerClosesEachConnection() async throws {
        let path = "/tmp/dispatch-herdr-\(UUID().uuidString).sock"
        let server = try unixServer(path: path, requestCount: 3) { request in request }
        defer { server.stop() }
        let client = HerdrUnixSocketClient(configuration: .init(socketPath: path, timeout: .seconds(1)))

        for sequence in 1...3 {
            let response = try await client.request(["sequence": .integer(sequence)])
            XCTAssertEqual(response["sequence"], .integer(sequence))
        }
        XCTAssertEqual(server.receivedLineCount, 3)
    }

    func testSocketClientAnswersConcurrentRequests() async throws {
        let path = "/tmp/dispatch-herdr-\(UUID().uuidString).sock"
        let server = try unixServer(path: path, requestCount: 2) { request in
            [
                "id": request["id"] ?? .null,
                "sequence": request["sequence"] ?? .null
            ]
        }
        defer { server.stop() }
        let client = HerdrUnixSocketClient(configuration: .init(socketPath: path, timeout: .seconds(1)))

        async let first = client.request(["sequence": .integer(1)])
        async let second = client.request(["sequence": .integer(2)])
        let responses = try await [first, second]

        XCTAssertEqual(responses[0]["sequence"], .integer(1))
        XCTAssertEqual(responses[1]["sequence"], .integer(2))
        XCTAssertEqual(server.receivedLineCount, 2)
    }

    private func unixServer(
        path: String,
        requestCount: Int = 1,
        response: @escaping @Sendable ([String: JSONValue]) -> [String: JSONValue],
        responseChunks: @escaping @Sendable (Data) -> [Data] = { [$0] }
    ) throws -> OneShotUnixServer {
        do {
            return try OneShotUnixServer(
                path: path, requestCount: requestCount, response: response, responseChunks: responseChunks
            )
        } catch let error as POSIXError where error.code == .EPERM {
            throw XCTSkip("The test host sandbox does not permit binding a Unix-domain socket.")
        }
    }
}

final class OneShotUnixServer: @unchecked Sendable {
    private let path: String
    private let descriptor: Int32
    private let queue = DispatchQueue(label: "dev.dispatch.tests.herdr-server")
    private let lock = NSLock()
    private var lineCount = 0
    private let requestCount: Int
    private let response: @Sendable ([String: JSONValue]) -> [String: JSONValue]
    private let responseChunks: @Sendable (Data) -> [Data]

    var receivedLineCount: Int { lock.withLock { lineCount } }

    init(
        path: String,
        requestCount: Int = 1,
        response: @escaping @Sendable ([String: JSONValue]) -> [String: JSONValue],
        responseChunks: @escaping @Sendable (Data) -> [Data] = { [$0] }
    ) throws {
        self.path = path
        self.requestCount = requestCount
        self.response = response
        self.responseChunks = responseChunks
        descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        unlink(path)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0
        let length = socklen_t(pathOffset + path.utf8.count + 1)
        address.sun_len = UInt8(length)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            _ = path.utf8.withContiguousStorageIfAvailable { buffer.copyBytes(from: $0) }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, length) }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        guard Darwin.listen(descriptor, 4) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        queue.async { [self] in serve() }
    }

    func stop() {
        Darwin.close(descriptor)
        unlink(path)
    }

    /// Like Herdr, answers exactly one request per connection and then closes it.
    private func serve() {
        for _ in 0..<requestCount {
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else { return }
            defer { Darwin.close(client) }
            var data = Data()
            var byte: UInt8 = 0
            while Darwin.read(client, &byte, 1) == 1, byte != 0x0A { data.append(byte) }
            lock.withLock { lineCount += 1 }
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: data),
                  case let .object(request) = value,
                  let encoded = try? JSONEncoder().encode(JSONValue.object(response(request))) else { return }
            for chunk in responseChunks(encoded + Data([0x0A])) {
                var sent = 0
                while sent < chunk.count {
                    let count = chunk.withUnsafeBytes { bytes in
                        Darwin.write(client, bytes.baseAddress! + sent, chunk.count - sent)
                    }
                    guard count > 0 else { return }
                    sent += count
                }
            }
        }
    }
}

/// Answers snapshots and `tab.focus` like Herdr, remembering the focused tab.
private final class FakeHerdrTabs: @unchecked Sendable {
    private let lock = NSLock()
    private let ids: [String]
    private var focused: String

    init(ids: [String]) {
        self.ids = ids
        focused = ids[0]
    }

    var focusedTab: String { lock.withLock { focused } }

    /// Focus moved inside Herdr, such as by a click, without Dispatch.
    func focus(_ id: String) {
        lock.withLock { focused = id }
    }

    func respond(to request: [String: JSONValue]) -> [String: JSONValue] {
        lock.withLock {
            if request["method"] == .string("tab.focus"),
               case let .object(params)? = request["params"],
               case let .string(id)? = params["tab_id"] {
                focused = id
                return ["id": request["id"] ?? .null, "result": .object([:])]
            }
            let tabs = ids.map { id -> JSONValue in
                .object(["tab_id": .string(id), "label": .string(id), "focused": .boolean(id == focused)])
            }
            return ["id": request["id"] ?? .null, "result": .object([
                "type": .string("session_snapshot"),
                "snapshot": .object([
                    "version": .string("1.0.0"),
                    "protocol": .integer(22),
                    "focused_tab_id": .string(focused),
                    "panes": .array([]),
                    "agents": .array([]),
                    "tabs": .array(tabs)
                ])
            ])]
        }
    }
}

/// Answers snapshots and `pane.close` like Herdr for one tab's panes.
private final class FakeHerdrPanes: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String]
    private var focused: String

    init(ids: [String], focused: String) {
        self.ids = ids
        self.focused = focused
    }

    var remainingPanes: [String] { lock.withLock { ids } }

    /// Focus moved inside Herdr, such as by a click, without Dispatch.
    func focus(_ id: String) {
        lock.withLock { focused = id }
    }

    func respond(to request: [String: JSONValue]) -> [String: JSONValue] {
        lock.withLock {
            if request["method"] == .string("pane.close"),
               case let .object(params)? = request["params"],
               case let .string(id)? = params["pane_id"] {
                ids.removeAll { $0 == id }
                if focused == id, let first = ids.first { focused = first }
                return ["id": request["id"] ?? .null, "result": .object([:])]
            }
            let panes = ids.map { id -> JSONValue in .object(["pane_id": .string(id)]) }
            return ["id": request["id"] ?? .null, "result": .object([
                "type": .string("session_snapshot"),
                "snapshot": .object([
                    "version": .string("1.0.0"),
                    "protocol": .integer(22),
                    "focused_pane_id": .string(focused),
                    "panes": .array(panes),
                    "agents": .array([]),
                    "tabs": .array([])
                ])
            ])]
        }
    }
}

/// A focused shell pane: `pane.send_text` appends to the prompt line,
/// `backspace` removes a character, and `pane.read` returns the screen.
private final class FakeHerdrPrompt: @unchecked Sendable {
    private let lock = NSLock()
    private let paneID: String
    private var input = ""
    private var finishedLines: [String] = []

    init(paneID: String) { self.paneID = paneID }

    var line: String { lock.withLock { "$ " + input } }
    var history: [String] { lock.withLock { finishedLines } }

    func pressReturn() {
        lock.withLock {
            finishedLines.append("$ " + input)
            input = ""
        }
    }

    func respond(to request: [String: JSONValue]) -> [String: JSONValue] {
        lock.withLock {
            let id = request["id"] ?? .null
            let params: [String: JSONValue]
            if case let .object(object)? = request["params"] { params = object } else { params = [:] }
            switch request["method"] {
            case .string("pane.send_text"):
                if case let .string(text)? = params["text"] { input += text }
                return ["id": id, "result": .object(["type": .string("ok")])]
            case .string("pane.send_keys"):
                if case let .array(keys)? = params["keys"] {
                    for key in keys where key == .string("backspace") && !input.isEmpty { input.removeLast() }
                }
                return ["id": id, "result": .object(["type": .string("ok")])]
            case .string("pane.read"):
                let screen = (finishedLines + ["$ " + input]).joined(separator: "\n") + "\n"
                return ["id": id, "result": .object([
                    "type": .string("pane_read"),
                    "read": .object(["text": .string(screen)])
                ])]
            default:
                return ["id": id, "result": .object([
                    "type": .string("session_snapshot"),
                    "snapshot": .object([
                        "version": .string("1.0.0"),
                        "protocol": .integer(22),
                        "focused_pane_id": .string(paneID),
                        "panes": .array([]),
                        "agents": .array([]),
                        "tabs": .array([])
                    ])
                ])]
            }
        }
    }
}
