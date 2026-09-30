/// The single runtime-facing substitution boundary for a physical control surface.
/// Device implementations translate their wire protocols before yielding events.
public protocol PadDevice: Sendable {
    /// Returns a new, independent subscription to the pad's events. Callers
    /// subscribe once per connection. Ending a subscription, including by
    /// cancelling the task that iterates it, must not affect later ones.
    /// Never hand every caller one stored `AsyncStream`: see `EventBroadcast`.
    func events() -> AsyncStream<DispatchEvent>

    func connect() async throws
    func disconnect() async
    /// Performs a side-effect-free round trip to verify that the device is responsive.
    func checkHealth() async throws
    func apply(_ presentation: PadPresentation) async throws
}
