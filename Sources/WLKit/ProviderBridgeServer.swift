import Foundation

/// Serves a `Provider` over a Unix domain socket, so it can run as a
/// separate process from the app driving the pad. One request per
/// connection, closed after the reply — same shape Herdr's own API uses —
/// except `events.subscribe`, whose connection stays open and gets one line
/// per change until the peer disconnects.
///
/// This is what `provider-bridge` (a separate executable target) wraps
/// around `HerdrProvider` to run out of process; it is also what makes the
/// round trip fully testable in-process, since both ends of the socket are
/// ordinary library code here, unlike Herdr's own server.
public final class ProviderBridgeServer: @unchecked Sendable {
    private let provider: Provider
    private let socketPath: String
    private let acceptQueue = DispatchQueue(label: "cc.worklouder.provider-bridge.accept")
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var running = false

    public init(provider: Provider, socketPath: String) {
        self.provider = provider
        self.socketPath = socketPath
    }

    /// Binds and starts accepting connections on a background queue. Throws
    /// rather than unlinking a socket path something is already listening
    /// on — plain `unlink` cannot tell a stale file (safe to remove) apart
    /// from a live server's (would silently steal the path out from under
    /// it, leaving the first server running but unreachable). Connecting as
    /// a client first can: a stale file refuses the connection, a live
    /// server accepts it.
    public func start() throws {
        if Self.somethingIsListening(at: socketPath) {
            throw HerdrError.cannotConnect(socketPath, "a provider is already listening here")
        }
        unlink(socketPath)   // a stale file from a crashed previous run, or nothing at all

        let handle = socket(AF_UNIX, SOCK_STREAM, 0)
        guard handle >= 0 else {
            throw HerdrError.cannotConnect(socketPath, String(cString: strerror(errno)))
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: addr.sun_path)
        guard socketPath.utf8.count < maxLength else {
            Darwin.close(handle)
            throw HerdrError.cannotConnect(socketPath, "socket path too long")
        }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
            socketPath.withCString { source in
                strncpy(UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self), source, maxLength - 1)
            }
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(handle, $0, size) }
        }
        guard bound == 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(handle)
            throw HerdrError.cannotConnect(socketPath, reason)
        }
        guard listen(handle, 8) == 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(handle)
            throw HerdrError.cannotConnect(socketPath, reason)
        }

        lock.lock(); listenFD = handle; running = true; lock.unlock()
        acceptQueue.async { [weak self] in self?.acceptLoop() }
    }

    public func stop() {
        lock.lock()
        running = false
        let handle = listenFD
        listenFD = -1
        lock.unlock()
        if handle >= 0 { Darwin.close(handle) }
        unlink(socketPath)
    }

    private func acceptLoop() {
        while true {
            lock.lock(); let handle = listenFD; let stillRunning = running; lock.unlock()
            guard stillRunning, handle >= 0 else { return }
            let client = accept(handle, nil, nil)
            guard client >= 0 else {
                lock.lock(); let stop = !running; lock.unlock()
                if stop { return }
                continue
            }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.handle(connection: client)
            }
        }
    }

    private func handle(connection fd: Int32) {
        defer { Darwin.close(fd) }
        guard let line = Self.readLine(fd: fd),
              let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let method = object["method"] as? String
        else { return }
        let id = object["id"] as? String ?? "req"
        let params = object["params"] as? [String: Any] ?? [:]

        if method == "events.subscribe" {
            handleSubscription(fd: fd, id: id)
            return
        }

        let semaphore = DispatchSemaphore(value: 0)
        var response: [String: Any] = ["id": id]
        Task {
            do {
                response["result"] = try await self.dispatch(method: method, params: params)
            } catch {
                response["error"] = ["message": error.localizedDescription]
            }
            semaphore.signal()
        }
        semaphore.wait()
        Self.writeLine(fd: fd, object: response)
    }

    private func dispatch(method: String, params: [String: Any]) async throws -> [String: Any] {
        switch method {
        case "provider.describe":
            return ProviderWire.encode(await provider.describe())
        case "provider.status":
            return ProviderWire.encode(try await provider.status())
        case "provider.focus":
            guard let target = params["target"] as? String else {
                throw HerdrError.badResponse("provider.focus needs a target")
            }
            try await provider.focus(target)
            return [:]
        case "provider.dial":
            guard let step = params["step"] as? Int, let mode = params["mode"] as? String else {
                throw HerdrError.badResponse("provider.dial needs step and mode")
            }
            try await provider.dial(step, mode: mode)
            return [:]
        case "provider.inject":
            guard let text = params["text"] as? String else {
                throw HerdrError.badResponse("provider.inject needs text")
            }
            try await provider.inject(text)
            return [:]
        case "provider.joystick":
            guard let direction = params["direction"] as? String else {
                throw HerdrError.badResponse("provider.joystick needs a direction")
            }
            try await provider.joystick(direction)
            return [:]
        default:
            throw HerdrError.badResponse("unknown provider-bridge method \(method)")
        }
    }

    /// Acks immediately, then forwards whatever `Provider.subscribe`'s
    /// callback does as a line per change, until the peer disconnects.
    private func handleSubscription(fd: Int32, id: String) {
        Self.writeLine(fd: fd, object: ["id": id, "result": [String: Any]()])

        let done = DoneFlag()
        let semaphore = DispatchSemaphore(value: 0)
        let finish = {
            if !done.setAndWasAlreadySet() { semaphore.signal() }
        }

        let subscription = provider.subscribe {
            guard !done.isSet else { return }
            if !Self.writeLine(fd: fd, object: ["event": true]) { finish() }
        }

        // The peer never sends a second line, so a background read just
        // blocks until it disconnects — the only way to notice with no
        // events in flight.
        DispatchQueue.global(qos: .utility).async {
            _ = Self.readLine(fd: fd)
            finish()
        }

        semaphore.wait()
        subscription.cancel()
    }

    // MARK: - Liveness probe

    /// True only when a `connect()` to `path` actually succeeds — the one
    /// reliable way to tell a live listener apart from a stale socket file
    /// (which refuses the connection) or nothing at all (which fails to
    /// resolve). Closes the probe connection immediately either way.
    private static func somethingIsListening(at path: String) -> Bool {
        let handle = socket(AF_UNIX, SOCK_STREAM, 0)
        guard handle >= 0 else { return false }
        defer { Darwin.close(handle) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < maxLength else { return false }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
            path.withCString { source in
                strncpy(UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self), source, maxLength - 1)
            }
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(handle, $0, size) }
        }
        return result == 0
    }

    // MARK: - Line I/O

    private static func readLine(fd: Int32) -> String? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n <= 0 { return nil }
            if let newlineIndex = chunk[0..<n].firstIndex(of: UInt8(ascii: "\n")) {
                buffer.append(contentsOf: chunk[0..<newlineIndex])
                return String(data: buffer, encoding: .utf8)
            }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }

    @discardableResult
    private static func writeLine(fd: Int32, object: [String: Any]) -> Bool {
        guard var payload = try? JSONSerialization.data(withJSONObject: object) else { return false }
        payload.append(UInt8(ascii: "\n"))
        return payload.withUnsafeBytes { raw -> Bool in
            var sent = 0
            while sent < raw.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }
}

/// A boolean two concurrent closures need to agree on exactly once — a
/// dedicated `@unchecked Sendable` box, since a plain captured `var` is a
/// data race under Swift 6's strict concurrency checking even behind a lock.
private final class DoneFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    /// Sets it, returning whether it was already set.
    func setAndWasAlreadySet() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let was = value
        value = true
        return was
    }
}
