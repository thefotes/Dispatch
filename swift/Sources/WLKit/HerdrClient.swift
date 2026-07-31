import Foundation

/// Client for the Herdr socket API: newline-delimited JSON over a Unix socket.
///
/// The server handles **exactly one request per connection** and then closes,
/// with one exception: `events.subscribe` takes over the stream and pushes
/// events until the client disconnects. So a request opens a short-lived
/// connection, and each subscription owns a dedicated long-lived one. A client
/// that reuses a connection for a second request simply never hears back.

public struct HerdrAgent: Equatable, Sendable {
    public var terminalID: String?
    public var paneID: String?
    public var tabID: String?
    public var workspaceID: String?
    public var agent: String
    public var status: String
    public var cwd: String?
    public var foregroundCwd: String?
    public var focused: Bool

    /// The target to hand to `agent.focus`.
    public var focusTarget: String? { terminalID ?? paneID }

    /// Where the agent is actually working. `foreground_cwd` follows a `cd`
    /// inside the pane; `cwd` is only where the pane started.
    public var workingDirectory: String? {
        [foregroundCwd, cwd].compactMap { $0 }.first { !$0.isEmpty }
    }

    /// Last path component of the working directory, which is what a person
    /// recognises the agent by.
    public var shortName: String {
        guard let directory = workingDirectory else { return agent }
        return (directory as NSString).lastPathComponent
    }

    init(json: [String: Any]) {
        terminalID = json["terminal_id"] as? String
        paneID = json["pane_id"] as? String
        tabID = json["tab_id"] as? String
        workspaceID = json["workspace_id"] as? String
        agent = json["agent"] as? String ?? "agent"
        status = json["agent_status"] as? String ?? "unknown"
        cwd = json["cwd"] as? String
        foregroundCwd = json["foreground_cwd"] as? String
        focused = json["focused"] as? Bool ?? false
    }

    /// For tests.
    public init(
        agent: String = "claude",
        status: String,
        paneID: String? = nil,
        tabID: String? = nil,
        workspaceID: String? = nil,
        terminalID: String? = nil,
        cwd: String? = nil,
        foregroundCwd: String? = nil,
        focused: Bool = false
    ) {
        self.agent = agent
        self.status = status
        self.paneID = paneID
        self.tabID = tabID
        self.workspaceID = workspaceID
        self.terminalID = terminalID
        self.cwd = cwd
        self.foregroundCwd = foregroundCwd
        self.focused = focused
    }

    /// Key index N maps positionally to agent N, so this ordering is what makes
    /// a physical key keep pointing at the same agent. It must match
    /// `sortAgents` in lib/herdr-client.js exactly.
    var sortKey: String {
        "\(workspaceID ?? "") \(tabID ?? "") \(paneID ?? "")"
    }
}

public struct HerdrTab: Equatable, Sendable {
    public var tabID: String
    public var workspaceID: String
    /// Display position within the workspace, which is the order tabs cycle in.
    public var number: Int
    public var focused: Bool

    init(json: [String: Any]) {
        tabID = json["tab_id"] as? String ?? ""
        workspaceID = json["workspace_id"] as? String ?? ""
        number = json["number"] as? Int ?? 0
        focused = json["focused"] as? Bool ?? false
    }

    /// For tests.
    public init(tabID: String, workspaceID: String = "ws", number: Int, focused: Bool = false) {
        self.tabID = tabID
        self.workspaceID = workspaceID
        self.number = number
        self.focused = focused
    }
}

public enum HerdrError: LocalizedError {
    case cannotConnect(String, String)
    case timeout(String)
    case api(String)
    case closed(String)
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .cannotConnect(let path, let reason):
            return "Cannot reach the Herdr server at \(path): \(reason)"
        case .timeout(let method): return "Timed out waiting for \(method)."
        case .api(let message): return message
        case .closed(let method): return "Connection closed before \(method) responded."
        case .badResponse(let detail): return "Bad response: \(detail)"
        }
    }
}

public enum HerdrClient {

    public static func socketPath() -> String {
        let env = ProcessInfo.processInfo.environment
        if let explicit = env["HERDR_SOCKET_PATH"], !explicit.isEmpty { return explicit }
        let base = env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".config")
        return (base as NSString).appendingPathComponent("herdr/herdr.sock")
    }

    // MARK: - Requests

    public static func request(
        _ method: String,
        params: [String: Any] = [:],
        timeout: TimeInterval = 5
    ) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            let conn = SocketConnection(path: socketPath())
            var finished = false
            let finish: (Result<[String: Any], Error>) -> Void = { result in
                guard !finished else { return }
                finished = true
                conn.close()
                continuation.resume(with: result)
            }

            conn.onLine = { line in
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    finish(.failure(HerdrError.badResponse(line)))
                    return
                }
                if let error = object["error"] as? [String: Any] {
                    finish(.failure(HerdrError.api(error["message"] as? String ?? "api error")))
                } else {
                    finish(.success(object["result"] as? [String: Any] ?? [:]))
                }
            }
            conn.onClosed = { error in
                finish(.failure(error ?? HerdrError.closed(method)))
            }

            do {
                try conn.open()
            } catch {
                finish(.failure(error))
                return
            }

            let envelope: [String: Any] = ["id": nextID(), "method": method, "params": params]
            guard let payload = try? JSONSerialization.data(withJSONObject: envelope) else {
                finish(.failure(HerdrError.badResponse("could not encode params")))
                return
            }
            conn.write(payload + Data("\n".utf8))

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                finish(.failure(HerdrError.timeout(method)))
            }
        }
    }

    public static func listAgents() async throws -> [HerdrAgent] {
        let result = try await request("agent.list")
        let raw = result["agents"] as? [[String: Any]] ?? []
        return raw.map(HerdrAgent.init(json:)).sorted { $0.sortKey < $1.sortKey }
    }

    /// The agent whose pane has focus in Herdr, if any. Fetched fresh rather
    /// than read off the bridge's poll, since focus is exactly the thing that
    /// changes between polls.
    public static func focusedAgent() async throws -> HerdrAgent? {
        try await listAgents().first(where: \.focused)
    }

    public static func focusAgent(_ target: String) async throws {
        _ = try await request("agent.focus", params: ["target": target])
    }

    public static func listTabs(workspaceID: String? = nil) async throws -> [HerdrTab] {
        var params: [String: Any] = [:]
        if let workspaceID { params["workspace_id"] = workspaceID }
        let result = try await request("tab.list", params: params)
        let raw = result["tabs"] as? [[String: Any]] ?? []
        return raw.map(HerdrTab.init(json:))
    }

    public static func focusTab(_ tabID: String) async throws {
        _ = try await request("tab.focus", params: ["tab_id": tabID])
    }

    /// Focuses the tab after the focused one in its workspace, wrapping at the
    /// end. Tabs in other workspaces are left alone: cycling is a
    /// within-window gesture, not a window switcher.
    public static func cycleTabs() async throws {
        guard let next = nextTab(in: try await listTabs()) else { return }
        try await focusTab(next.tabID)
    }

    /// The tab `cycleTabs` would focus, or nil when there is nothing to do —
    /// no focused tab, or a workspace with a single tab.
    public static func nextTab(in tabs: [HerdrTab]) -> HerdrTab? {
        guard let focused = tabs.first(where: \.focused) else { return nil }
        let siblings = tabs
            .filter { $0.workspaceID == focused.workspaceID }
            .sorted { $0.number < $1.number }
        guard siblings.count > 1,
              let index = siblings.firstIndex(of: focused)
        else { return nil }
        return siblings[(index + 1) % siblings.count]
    }

    private static let counter = Counter()
    private static func nextID() -> String { "wl_\(counter.next())" }

    private final class Counter: @unchecked Sendable {
        private var value = 0
        private let lock = NSLock()
        func next() -> Int {
            lock.lock(); defer { lock.unlock() }
            value += 1
            return value
        }
    }
}

// MARK: - Event streams

/// One subscription, on its own connection. The first line is the
/// acknowledgement; everything after it is a pushed event.
public final class HerdrEventStream {
    public var onReady: (() -> Void)?
    public var onEvent: (([String: Any]) -> Void)?
    public var onClosed: ((Error?) -> Void)?

    private let subscriptions: [[String: Any]]
    private let conn: SocketConnection
    private var ready = false
    private var stopped = false

    public init(subscriptions: [[String: Any]]) {
        self.subscriptions = subscriptions
        self.conn = SocketConnection(path: HerdrClient.socketPath())
    }

    @discardableResult
    public func start() -> HerdrEventStream {
        conn.onLine = { [weak self] line in
            guard let self, !self.stopped else { return }
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            if !self.ready {
                self.ready = true
                DispatchQueue.main.async { self.onReady?() }
                return
            }
            DispatchQueue.main.async { self.onEvent?(object) }
        }
        conn.onClosed = { [weak self] error in
            guard let self, !self.stopped else { return }
            DispatchQueue.main.async { self.onClosed?(error) }
        }

        do {
            try conn.open()
        } catch {
            DispatchQueue.main.async { [weak self] in self?.onClosed?(error) }
            return self
        }

        let envelope: [String: Any] = [
            "id": "wl_sub",
            "method": "events.subscribe",
            "params": ["subscriptions": subscriptions],
        ]
        if let payload = try? JSONSerialization.data(withJSONObject: envelope) {
            conn.write(payload + Data("\n".utf8))
        }
        return self
    }

    public func stop() {
        stopped = true
        conn.close()
    }

    deinit { conn.close() }
}

// MARK: - Socket plumbing

/// A blocking read loop on its own queue. Deliberately plain POSIX: the
/// alternative is Network.framework, which adds ceremony for no benefit on a
/// local Unix socket.
final class SocketConnection: @unchecked Sendable {
    var onLine: ((String) -> Void)?
    var onClosed: ((Error?) -> Void)?

    private let path: String
    private var fd: Int32 = -1
    private let queue = DispatchQueue(label: "cc.worklouder.herdr-socket")
    private var buffer = Data()
    private var closed = false
    private let lock = NSLock()

    init(path: String) { self.path = path }

    func open() throws {
        let handle = socket(AF_UNIX, SOCK_STREAM, 0)
        guard handle >= 0 else {
            throw HerdrError.cannotConnect(path, String(cString: strerror(errno)))
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < maxLength else {
            Darwin.close(handle)
            throw HerdrError.cannotConnect(path, "socket path too long")
        }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
            path.withCString { source in
                strncpy(UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self), source, maxLength - 1)
            }
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(handle, $0, size) }
        }
        guard result == 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(handle)
            throw HerdrError.cannotConnect(path, reason)
        }

        fd = handle
        queue.async { [weak self] in self?.readLoop() }
    }

    func write(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard fd >= 0 else { return }
        data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                if n <= 0 { break }
                sent += n
            }
        }
    }

    func close() {
        lock.lock()
        let handle = fd
        fd = -1
        closed = true
        lock.unlock()
        if handle >= 0 { Darwin.close(handle) }
    }

    private func readLoop() {
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            lock.lock(); let handle = fd; lock.unlock()
            guard handle >= 0 else { break }

            let n = Darwin.read(handle, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])

            while let index = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = buffer.prefix(upTo: index)
                buffer = buffer.suffix(from: buffer.index(after: index))
                if let line = String(data: lineData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty {
                    onLine?(line)
                }
            }
        }
        lock.lock(); let wasClosed = closed; lock.unlock()
        if !wasClosed { onClosed?(nil) }
    }
}
