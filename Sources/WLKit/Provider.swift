import Foundation

/// What Micromanager needs from an external tool to drive the pad's
/// agent-key row, dial, and macro keys — the generic seam `HerdrClient` used
/// to be hardcoded behind. `BridgeController` depends on this protocol only;
/// `HerdrProvider` is the one implementation shipped today, and nothing in
/// this file mentions Herdr.
///
/// The entity type is still `HerdrAgent` for now — that generalises alongside
/// `StatusMapper`'s state palette in a later pass, since the two changes
/// share the same UI surface. The seam this phase is after is narrower:
/// `BridgeController` no longer imports `HerdrClient` directly.
public protocol Provider: Sendable {
    /// Entities for the agent-key row, in display order.
    func status() async throws -> [HerdrAgent]
    /// Focuses one entity, by the id `status()` reported for it.
    func focus(_ target: String) async throws
    /// Steps `mode` by `step` (+1 clockwise / -1 counter-clockwise from the
    /// dial, or +1 from a single key press). `mode` is a string, not a closed
    /// enum, so a future provider can offer its own without a protocol change.
    func dial(_ step: Int, mode: String) async throws
    /// Injects text into whatever "focused" means for this provider.
    func inject(_ text: String) async throws
    /// Subscribes to change notifications — a new entity, a status flip, a
    /// focus change — debounced by the caller, not here. Call `cancel()` on
    /// the returned token to stop.
    func subscribe(_ onChange: @escaping @Sendable () -> Void) -> ProviderSubscription
}

/// Cancellation handle for `Provider.subscribe`. Cancelling twice, or letting
/// it deinit uncancelled, is safe — both just run `onCancel` once.
public final class ProviderSubscription: @unchecked Sendable {
    private let lock = NSLock()
    private var onCancel: (() -> Void)?

    public init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    public func cancel() {
        lock.lock()
        let callback = onCancel
        onCancel = nil
        lock.unlock()
        callback?()
    }

    deinit { cancel() }
}
