import Foundation

/// A `Provider` reached over a socket instead of in-process. Speaks the same
/// envelope shape `HerdrClient` already uses to talk to Herdr — one request
/// per connection, closed after the reply — against a `ProviderBridgeServer`
/// on the other end. `events.subscribe` is the one exception: that
/// connection stays open, an ack line immediately, then one line per change
/// until canceled.
public final class RemoteProvider: Provider, @unchecked Sendable {
    private let socketPath: String
    private let timeout: TimeInterval

    public init(socketPath: String, timeout: TimeInterval = 5) {
        self.socketPath = socketPath
        self.timeout = timeout
    }

    /// A remote `describe()` that fails (bridge not reachable yet, still
    /// starting up) answers with an empty description rather than throwing —
    /// `describe()` has no throwing variant, since a provider with nothing to
    /// say is a valid, if uninteresting, answer. The failure still goes to
    /// stderr, since silent-forever is a bad answer to a misconfigured
    /// `"connect"` path — `BridgeController.lastError` is not reachable from
    /// here (`describe()` predates it, called before a bridge exists).
    public func describe() async -> ProviderDescription {
        do {
            return ProviderWire.decodeDescription(try await request("provider.describe", params: [:]))
        } catch {
            FileHandle.standardError.write(Data("RemoteProvider: describe() failed at \(socketPath): \(error)\n".utf8))
            return ProviderDescription()
        }
    }

    public func status() async throws -> [HerdrAgent] {
        ProviderWire.decodeAgents(try await request("provider.status", params: [:]))
    }

    public func focus(_ target: String) async throws {
        _ = try await request("provider.focus", params: ["target": target])
    }

    public func dial(_ step: Int, mode: String) async throws {
        _ = try await request("provider.dial", params: ["step": step, "mode": mode])
    }

    public func inject(_ text: String) async throws {
        _ = try await request("provider.inject", params: ["text": text])
    }

    public func perform(_ action: String) async throws {
        _ = try await request("provider.perform", params: ["action": action])
    }

    public func joystick(_ direction: Pad.JoystickDirection) async throws {
        _ = try await request("provider.joystick", params: ["direction": direction.rawValue])
    }

    public func subscribe(_ onChange: @escaping @Sendable () -> Void) -> ProviderSubscription {
        let conn = SocketConnection(path: socketPath)
        var receivedAck = false
        conn.onLine = { _ in
            // The first line is always the subscribe ack; every line after
            // it means "something changed" — the payload carries no useful
            // detail, so it is not even parsed.
            if !receivedAck { receivedAck = true; return }
            onChange()
        }
        guard (try? conn.open()) != nil else { return ProviderSubscription {} }
        let envelope: [String: Any] = ["id": "sub", "method": "events.subscribe", "params": [String: Any]()]
        if let payload = try? JSONSerialization.data(withJSONObject: envelope) {
            conn.write(payload + Data("\n".utf8))
        }
        return ProviderSubscription { conn.close() }
    }

    private func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            let conn = SocketConnection(path: socketPath)
            // `finish` races: the connection's callbacks and the timeout
            // closure below can both reach it from different threads, and
            // resuming a continuation twice is undefined behavior — same
            // hazard `HerdrClient.request` has, guarded the same way.
            let finishLock = NSLock()
            var finished = false
            // Kept as a work item so an early finish can cancel it —
            // otherwise it pins `conn` and this request's captured state on
            // the global queue for the whole timeout past completion.
            var timeoutWork: DispatchWorkItem?
            let finish: (Result<[String: Any], Error>) -> Void = { result in
                finishLock.lock()
                guard !finished else { finishLock.unlock(); return }
                finished = true
                finishLock.unlock()
                timeoutWork?.cancel()
                conn.close()
                continuation.resume(with: result)
            }

            conn.onLine = { line in
                guard let data = line.data(using: .utf8),
                      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                else { finish(.failure(HerdrError.badResponse(line))); return }
                if let error = object["error"] as? [String: Any] {
                    finish(.failure(HerdrError.api(error["message"] as? String ?? "provider error")))
                } else {
                    finish(.success(object["result"] as? [String: Any] ?? [:]))
                }
            }
            conn.onClosed = { error in finish(.failure(error ?? HerdrError.closed(method))) }

            do {
                try conn.open()
            } catch {
                finish(.failure(error))
                return
            }

            let envelope: [String: Any] = ["id": "req", "method": method, "params": params]
            guard let payload = try? JSONSerialization.data(withJSONObject: envelope) else {
                finish(.failure(HerdrError.badResponse("could not encode params")))
                return
            }
            conn.write(payload + Data("\n".utf8))

            let work = DispatchWorkItem { finish(.failure(HerdrError.timeout(method))) }
            timeoutWork = work
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: work)
        }
    }
}
