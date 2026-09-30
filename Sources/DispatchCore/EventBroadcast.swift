import Foundation

/// Fans each value out to every current subscriber, one `AsyncStream` each.
///
/// Hand out a fresh stream per consumer instead of sharing one stored
/// `AsyncStream`. Cancelling the task that iterates an `AsyncStream`
/// terminates that stream for good: later iterators finish immediately and
/// `yield` returns `.terminated`. With one shared stream, the first
/// reconnect or stop/start that cancels its consumer silently ends all
/// input while output such as lighting keeps working.
public final class EventBroadcast<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var subscribers: [UUID: AsyncStream<Element>.Continuation] = [:]
    private var isFinished = false

    public init() {}

    /// Values yielded before this call are not delivered to the new stream.
    /// Ending the stream, including by cancelling its consumer, affects no
    /// other subscriber.
    public func subscribe() -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream<Element>.makeStream()
        let id = UUID()
        let accepted = lock.withLock {
            guard !isFinished else { return false }
            subscribers[id] = continuation
            return true
        }
        guard accepted else {
            continuation.finish()
            return stream
        }
        continuation.onTermination = { [weak self] _ in
            self?.unsubscribe(id)
        }
        return stream
    }

    private func unsubscribe(_ id: UUID) {
        lock.withLock { _ = subscribers.removeValue(forKey: id) }
    }

    public func yield(_ element: Element) {
        for continuation in lock.withLock({ Array(subscribers.values) }) {
            continuation.yield(element)
        }
    }

    /// Ends current subscriptions while allowing a later connection to
    /// subscribe again.
    public func finishCurrentSubscribers() {
        let continuations = lock.withLock {
            defer { subscribers.removeAll() }
            return Array(subscribers.values)
        }
        for continuation in continuations {
            continuation.finish()
        }
    }

    /// Ends every current stream; later subscriptions finish immediately.
    public func finish() {
        let continuations = lock.withLock {
            isFinished = true
            defer { subscribers.removeAll() }
            return Array(subscribers.values)
        }
        for continuation in continuations {
            continuation.finish()
        }
    }
}
