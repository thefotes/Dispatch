import Foundation

/// What Micromanager needs from an external tool to drive the pad's
/// agent-key row, dial, and macro keys. `BridgeController` depends on this
/// protocol only, never on a concrete backend; `HerdrProvider` is the
/// implementation shipped today, and nothing in this file mentions Herdr.
///
/// The one Herdr-specific leak: entities are typed as `HerdrAgent` rather
/// than something fully generic, since it is also `StatusMapper`'s input and
/// the two share the same UI surface.
public protocol Provider: Sendable {
    /// Static capabilities: the state palette entities report through
    /// `status()`, and the dial modes this provider understands. Called once
    /// at bridge start, not on a hot path — async so a remote provider can
    /// answer over the wire without a sync-over-async bridge.
    func describe() async -> ProviderDescription
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

/// A provider's static capabilities: its lighting palette and the dial
/// modes it supports.
public struct ProviderDescription: Sendable, Equatable {
    /// Color + effect per state name `status()` can report an entity as.
    /// Applied over `BridgeConfig`'s palette at bridge start.
    public var statePalette: [String: ProviderStateStyle]
    /// Highest priority first: the first state present across all entities
    /// wins the aggregate underglow. Also applied over `BridgeConfig`.
    public var statePriority: [String]
    /// Dial modes this provider understands, in menu order, each with a
    /// short label — informational today (nothing reads it yet; a settings
    /// UI is the obvious next reader), never including `"effort"`, which is
    /// a Micromanager feature and never reaches a provider.
    public var dialModes: [ProviderDialMode]

    public init(
        statePalette: [String: ProviderStateStyle] = [:],
        statePriority: [String] = [],
        dialModes: [ProviderDialMode] = []
    ) {
        self.statePalette = statePalette
        self.statePriority = statePriority
        self.dialModes = dialModes
    }
}

/// One state's lighting, keyed by the state name `status()` reports.
public struct ProviderStateStyle: Sendable, Equatable {
    public var color: Int
    public var effect: OAI.Effect

    public init(color: Int, effect: OAI.Effect) {
        self.color = color
        self.effect = effect
    }
}

/// One dial mode a provider offers.
public struct ProviderDialMode: Sendable, Equatable {
    public var id: String
    public var label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
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
