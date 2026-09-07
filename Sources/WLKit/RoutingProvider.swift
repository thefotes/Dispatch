import Foundation

/// One Herdr server the pad can talk to: a stable id used inside focus
/// targets, a display name for panels, and the socket path to reach it.
public struct HerdrInstance: Sendable, Equatable {
    /// Stable identifier — "local", "jarvis" — used in namespaced focus
    /// targets and as the routing key for every switch. Never shown raw.
    public var id: String
    /// Display name for the panel.
    public var name: String
    /// The Unix socket speaking Herdr's API. A remote instance's path is a
    /// forwarded socket (see README); keep those under `$TMPDIR`, since
    /// macOS caps `sun_path` at 104 bytes.
    public var socketPath: String

    public init(id: String, name: String, socketPath: String) {
        self.id = id
        self.name = name
        self.socketPath = socketPath
    }

    /// The single default instance every existing config gets: the usual
    /// socket, local, exactly the pre-multi-instance behaviour.
    public static func local() -> HerdrInstance {
        HerdrInstance(id: "local", name: "Local", socketPath: HerdrClient.defaultSocketPath())
    }

    /// The window title `ForegroundInstanceDetector` stamps on a terminal
    /// window to learn which instance it belongs to. Briefly visible during
    /// calibration, then cleared.
    public var calibrationMarker: String {
        "⟦wl:\(id)⟧"
    }
}

/// A `Provider` that fronts two or more `HerdrProvider`s — a local Herdr and
/// a remote one behind a forwarded socket, typically — and routes pad input
/// to whichever instance is active, while merging their statuses so the
/// underglow reflects both machines at once.
///
/// `BridgeController` is never taught that more than one Herdr exists: this
/// is one long-lived provider, and the routing happens inside it. The active
/// instance changes two ways — the `herdr.next_instance` action bound from
/// `config.json`, or `setActiveInstance` driven by the app layer's
/// `ForegroundInstanceDetector`, which tracks the frontmost terminal window.
///
/// Per-child failure isolation is a requirement, not a nicety: a dead remote
/// (its tunnel down, or worse, wedged — accepting connections but never
/// answering) must never blank the local pad. `status()` catches per child
/// and treats a failure as an empty agent list, surfacing the reason through
/// `lastError` rather than throwing; an instance whose polls time out backs
/// off rather than costing its timeout on every refresh.
public final class RoutingProvider: Provider, @unchecked Sendable {
    /// The action `perform` handles itself instead of forwarding to a child.
    /// Offered through `describe()` so it is bindable from config.json's
    /// `{"action": ...}` like any other provider action.
    public static let nextInstanceActionID = "herdr.next_instance"

    private struct Child {
        let instance: HerdrInstance
        let provider: Provider
        /// Skip this child's status polls until this instant — a timed-out
        /// instance backs off rather than paying its timeout every refresh.
        var backoffUntil: Date?
        /// Consecutive timeouts, driving the backoff doubling.
        var timeoutStreak: Int
    }

    private let lock = NSLock()
    private var children: [Child]
    private var activeIndex: Int
    private let changeNotifier = ProviderChangeNotifier()

    /// Called after a namespaced focus target routed to a specific instance —
    /// the app layer uses this to bring *that instance's* terminal window
    /// forward, since raising the terminal app alone cannot discriminate two
    /// Ghostty windows. AppKit lives in the app layer; this stays a hook.
    public var onFocusInstance: (@Sendable (String) -> Void)?

    /// The most recent per-child failure from `status()`, phrased for the
    /// panel. Nil when every child answered on the last refresh.
    public private(set) var lastError: String? {
        get { lock.lock(); defer { lock.unlock() }; return _lastError }
        set { lock.lock(); _lastError = newValue; lock.unlock() }
    }

    private var _lastError: String?

    /// `children` is config order; the first is the default active instance.
    public init(children: [(instance: HerdrInstance, provider: Provider)]) {
        precondition(!children.isEmpty, "RoutingProvider needs at least one instance")
        self.children = children.map {
            Child(instance: $0.instance, provider: $0.provider, backoffUntil: nil, timeoutStreak: 0)
        }
        self.activeIndex = 0
    }

    // MARK: - Active instance

    public var activeInstanceID: String {
        lock.lock(); defer { lock.unlock() }
        return children[activeIndex].instance.id
    }

    public var instances: [HerdrInstance] {
        lock.lock(); defer { lock.unlock() }
        return children.map(\.instance)
    }

    /// Switches the instance pad input drives. Unknown ids are ignored —
    /// silently retargeting the pad on a typo would be worse than no-op.
    /// This is also the manual override: when foreground detection cannot
    /// decide (no Accessibility, no known window frontmost), the active
    /// instance stays wherever the last positive identification or this
    /// call put it.
    public func setActiveInstance(_ id: String) {
        let changed: Bool = lock.withLock {
            guard let index = children.firstIndex(where: { $0.instance.id == id }),
                  index != activeIndex else { return false }
            activeIndex = index
            return true
        }
        if changed { changeNotifier.notify() }
    }

    /// One step around the instances in config order, wrapping. The
    /// `herdr.next_instance` action's implementation.
    public func cycleInstance() {
        lock.lock()
        activeIndex = (activeIndex + 1) % children.count
        lock.unlock()
        changeNotifier.notify()
    }

    // MARK: - Provider

    public func describe() async -> ProviderDescription {
        // All children are Herdr, so descriptions are identical; take the
        // first child's and do not attempt a merge. The switch action is
        // appended so `{"action": "herdr.next_instance"}` binds like any
        // other.
        var description = await children[0].provider.describe()
        if children.count > 1 {
            description.actions.append(
                ProviderAction(id: Self.nextInstanceActionID, label: "Next Herdr instance", raisesHost: false)
            )
        }
        return description
    }

    /// Every instance's agents — the active instance's first (they take the
    /// agent keys first), the rest in config order — each stamped with its
    /// instance id so its focus target is namespaced. The aggregate
    /// underglow folds over the whole list, so "does anything on either box
    /// need me?" works no matter how many agents fit on keys.
    ///
    /// A child that fails — or is backing off — contributes nothing rather
    /// than throwing: a dead remote never blanks the local pad. Ordering is
    /// stable at every instant (reported order, never sorted by status), so
    /// keys only move when the active instance moves.
    public func status() async throws -> [HerdrAgent] {
        var merged: [HerdrAgent] = []
        var failure: String?

        for index in children.indices {
            let (instance, provider, backedOff) = lock.withLock {
                (children[index].instance, children[index].provider,
                 children[index].backoffUntil.map { $0 > Date() } ?? false)
            }
            if backedOff { continue }
            do {
                let agents = try await provider.status()
                clearBackoff(at: index)
                merged.append(contentsOf: agents.map { agent in
                    var stamped = agent
                    stamped.instanceID = instance.id
                    return stamped
                })
            } catch {
                recordFailure(at: index, error: error)
                failure = failure ?? "\(instance.name): \(error.localizedDescription)"
            }
        }

        lastError = failure
        // Active instance first — its agents take the pad's key slots — then
        // the remaining instances in config order.
        let activeID = activeInstanceID
        return merged.filter { $0.instanceID == activeID }
            + merged.filter { $0.instanceID != activeID }
    }

    private func clearBackoff(at index: Int) {
        lock.lock()
        children[index].backoffUntil = nil
        children[index].timeoutStreak = 0
        lock.unlock()
    }

    /// A timeout means the tunnel is wedged — accepts, never answers — and
    /// costs the full request timeout every refresh if retried blindly. Back
    /// off with doubling gaps (30s first, capped at 5 minutes); any other
    /// failure retries next refresh, since a refused connection is cheap.
    private func recordFailure(at index: Int, error: Error) {
        lock.lock()
        defer { lock.unlock() }
        guard children.indices.contains(index) else { return }
        if case HerdrError.timeout = error {
            children[index].timeoutStreak += 1
            let seconds = min(30.0 * pow(2, Double(children[index].timeoutStreak - 1)), 300)
            children[index].backoffUntil = Date().addingTimeInterval(seconds)
        }
    }

    public func focus(_ target: String) async throws {
        let (instanceID, raw) = HerdrAgent.splitFocusTarget(target)
        guard let instanceID else {
            // Never namespaced: whoever produced it meant the active
            // instance — the single-instance shape, unchanged.
            try await activeChild().provider.focus(raw)
            return
        }
        // A namespaced target names its owner, and pane ids collide freely
        // across instances — that collision is the whole reason for the
        // namespace. A target whose owner is no longer configured (the
        // instance was renamed or removed while a merged list is in memory)
        // is therefore not addressable anywhere: dispatching its raw id to
        // the active child could focus an unrelated pane on the wrong
        // machine. The press is dropped, loudly enough to surface.
        guard let child = child(named: instanceID) else {
            throw HerdrError.api("No Herdr instance named \"\(instanceID)\" is configured — its agent can no longer be focused.")
        }
        try await child.provider.focus(raw)
        onFocusInstance?(instanceID)
    }

    public func dial(_ step: Int, mode: String) async throws {
        try await activeChild().provider.dial(step, mode: mode)
    }

    public func inject(_ text: String) async throws {
        try await activeChild().provider.inject(text)
    }

    public func joystick(_ direction: Pad.JoystickDirection) async throws {
        try await activeChild().provider.joystick(direction)
    }

    public func perform(_ action: String) async throws {
        if action == Self.nextInstanceActionID {
            cycleInstance()
            return
        }
        try await activeChild().provider.perform(action)
    }

    /// Fans out to every child's stream plus this provider's own change
    /// signal (active-instance switches repaint too). Any of them firing
    /// fires the caller's `onChange`.
    public func subscribe(_ onChange: @escaping @Sendable () -> Void) -> ProviderSubscription {
        let own = changeNotifier.subscribe(onChange, onTeardown: {})
        let childSubscriptions = children.map { $0.provider.subscribe(onChange) }
        return ProviderSubscription { [own, childSubscriptions] in
            own.cancel()
            childSubscriptions.forEach { $0.cancel() }
        }
    }

    // MARK: - Internals

    private func activeChild() -> Child {
        lock.lock(); defer { lock.unlock() }
        return children[activeIndex]
    }

    private func child(named id: String) -> Child? {
        lock.lock(); defer { lock.unlock() }
        return children.first { $0.instance.id == id }
    }
}
