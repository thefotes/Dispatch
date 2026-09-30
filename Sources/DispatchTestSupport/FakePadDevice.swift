import DispatchCore
import Foundation

public enum FakePadError: Error, Equatable, Sendable {
    case connectionFailed
    case healthCheckFailed
    case presentationFailed
}

public final class FakePadDevice: PadDevice, @unchecked Sendable {
    private let lock = NSLock()
    private let broadcast = EventBroadcast<DispatchEvent>()
    private var connectionError: FakePadError?
    private var healthCheckError: FakePadError?
    private var presentationError: FakePadError?
    private var connected = false
    private var connectionCount = 0
    private var healthCheckCount = 0
    private var presentations: [PadPresentation] = []

    public init() {}

    deinit {
        broadcast.finish()
    }

    public func events() -> AsyncStream<DispatchEvent> {
        broadcast.subscribe()
    }

    public func connect() async throws {
        try lock.withLock {
            if let connectionError { throw connectionError }
            connected = true
            connectionCount += 1
        }
    }

    public func disconnect() async {
        lock.withLock { connected = false }
    }

    public func checkHealth() async throws {
        try lock.withLock {
            healthCheckCount += 1
            if let healthCheckError { throw healthCheckError }
        }
    }

    public func apply(_ presentation: PadPresentation) async throws {
        try lock.withLock {
            if let presentationError { throw presentationError }
            presentations.append(presentation)
        }
    }

    public func emit(_ event: DispatchEvent) {
        broadcast.yield(event)
    }

    public func endEvents() {
        broadcast.finish()
    }

    public func setConnectionError(_ error: FakePadError?) {
        lock.withLock { connectionError = error }
    }

    public func setHealthCheckError(_ error: FakePadError?) {
        lock.withLock { healthCheckError = error }
    }

    public func setPresentationError(_ error: FakePadError?) {
        lock.withLock { presentationError = error }
    }

    public func isConnected() -> Bool {
        lock.withLock { connected }
    }

    public func recordedConnectionCount() -> Int {
        lock.withLock { connectionCount }
    }

    public func recordedHealthCheckCount() -> Int {
        lock.withLock { healthCheckCount }
    }

    public func recordedPresentations() -> [PadPresentation] {
        lock.withLock { presentations }
    }
}
