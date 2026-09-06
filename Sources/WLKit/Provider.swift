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

    /// Carries out one of the actions this provider offered through
    /// `describe()` — `action` is an opaque id from `ProviderAction`, the
    /// same way `dial(_:mode:)` takes a dial-mode id. The protocol never
    /// knows what "create a workspace" means; whichever provider offered
    /// the id is the one that decides what it concretely does. A press of a
    /// key bound to `{"action": ...}` in config.json lands here.
    func perform(_ action: String) async throws

    /// Moves focus one pane over — one joystick deflection. The four
    /// directions are all the hardware can express, so this is an enum, not
    /// a string; a provider that has no notion of panes implements it as a
    /// no-op and nothing else in the app needs to know.
    func joystick(_ direction: Pad.JoystickDirection) async throws

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
    /// short label. `BridgeController` resolves `config.json`'s `"dial"`
    /// string against these ids — a name that isn't here falls back to the
    /// effort ladder with a warning, the same way an unrecognized shortcut
    /// reports itself. Never includes `"effort"`, which is handled entirely
    /// in the app layer and never reaches a provider.
    public var dialModes: [ProviderDialMode]

    /// Named actions this provider can `perform`, in menu order, each with
    /// a short label. `BridgeController` checks a key's `{"action": ...}`
    /// binding against these ids — a binding naming an action the active
    /// provider never offered is a panel error, the same way an
    /// unrecognized dial name is. Ids are the provider's own vocabulary:
    /// the protocol knows nothing about what any of them do.
    public var actions: [ProviderAction]

    public init(
        statePalette: [String: ProviderStateStyle] = [:],
        statePriority: [String] = [],
        dialModes: [ProviderDialMode] = [],
        actions: [ProviderAction] = []
    ) {
        self.statePalette = statePalette
        self.statePriority = statePriority
        self.dialModes = dialModes
        self.actions = actions
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
    /// Whether landing on this mode should bring the host app forward, the
    /// way an agent key does — a per-mode fact only the provider can know
    /// (Herdr's `"agent"`/`"space"` do; `"tab"` does not, since you are
    /// already looking at the pane it stays within).
    public var raisesHost: Bool

    public init(id: String, label: String, raisesHost: Bool) {
        self.id = id
        self.label = label
        self.raisesHost = raisesHost
    }
}

/// One named action a provider offers through `perform`. The id is opaque
/// to everything above the provider — the label is what the menu panel
/// shows, and `raisesHost` is whether running the action should bring the
/// host app forward, the same per-action fact `ProviderDialMode` carries
/// for dial detents (creating a pane does; cycling a prompt does not).
public struct ProviderAction: Sendable, Equatable {
    public var id: String
    public var label: String
    public var raisesHost: Bool

    public init(id: String, label: String, raisesHost: Bool) {
        self.id = id
        self.label = label
        self.raisesHost = raisesHost
    }
}

/// Cancellation handle for `Provider.subscribe`. Canceling twice, or letting
/// it deinit uncanceled, is safe — both just run `onCancel` once.
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
