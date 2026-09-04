import Foundation

/// A `Provider` reached over a socket instead of in-process. Speaks the same
/// envelope shape `HerdrClient` already uses to talk to Herdr — one request
/// per connection, closed after the reply — against a `ProviderBridgeServer`
/// on the other end. `events.subscribe` is the one exception: that
/// connection stays open, an ack line immediately, then one line per change
/// until cancelled.
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
    /// say is a valid, if uninteresting, answer.
    public func describe() async -> ProviderDescription {
        guard let result = try? await request("provider.describe", params: [:]) else {
            return ProviderDescription()
        }
        return ProviderWire.decodeDescription(result)
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
            var finished = false
            let finish: (Result<[String: Any], Error>) -> Void = { result in
                guard !finished else { return }
                finished = true
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

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                finish(.failure(HerdrError.timeout(method)))
            }
        }
    }
}
