import Foundation

/// Wraps `HerdrClient` behind `Provider`. The one implementation Micromanager
/// ships today, and the only file that imports `HerdrClient` — `BridgeController`
/// depends on `Provider` only.
///
/// Owns the event-stream bookkeeping: a lifecycle stream that restarts
/// itself on close, and one dedicated per-pane status stream, reconciled
/// against whatever `status()` last fetched — `status()` triggers its own
/// reconciliation on every call, so nothing else needs to hand it a fresh
/// agent list.
public final class HerdrProvider: Provider, @unchecked Sendable {
    private let lock = NSLock()
    private let changeNotifier = ProviderChangeNotifier()
    private var lifecycle: HerdrEventStream?
    private var statusStreams: [String: HerdrEventStream] = [:]
    private var stopped = true

    public init() {}

    /// Herdr's status vocabulary and the agent/tab/space navigation the dial
    /// offers — pinned against `BridgeConfig`'s own defaults by
    /// `HerdrProviderTests`, so the two cannot silently drift apart.
    public func describe() async -> ProviderDescription {
        ProviderDescription(
            statePalette: [
                "blocked": ProviderStateStyle(color: 0xFF2D2D, effect: .breath),
                "working": ProviderStateStyle(color: 0xFFA000, effect: .solid),
                // "done" is an agent that finished and has not been looked at
                // yet; "idle" is finished and seen. A real difference, so a
                // different color.
                "done": ProviderStateStyle(color: 0x00B0FF, effect: .solid),
                "idle": ProviderStateStyle(color: 0x00C853, effect: .solid),
                "unknown": ProviderStateStyle(color: 0x00C853, effect: .solid)
            ],
            statePriority: ["blocked", "working", "unknown", "idle", "done"],
            dialModes: [
                // Agent and space bring the terminal forward, the way an
                // agent key does; tab does not, since you are already
                // looking at the pane it stays within.
                ProviderDialMode(id: "agent", label: "Agent", raisesHost: true),
                ProviderDialMode(id: "tab", label: "Tab", raisesHost: false),
                ProviderDialMode(id: "space", label: "Space", raisesHost: true)
            ]
        )
    }

    public func status() async throws -> [HerdrAgent] {
        let agents = try await HerdrClient.listAgents()
        reconcileStatusStreams(agents)
        return agents
    }

    public func focus(_ target: String) async throws {
        try await HerdrClient.focusAgent(target)
    }

    public func dial(_ step: Int, mode: String) async throws {
        switch mode {
        case "agent":
            guard let next = HerdrClient.adjacentAgent(in: try await HerdrClient.listAgents(), step: step),
                  let target = next.focusTarget
            else { return }
            try await HerdrClient.focusAgent(target)
        case "tab":
            try await HerdrClient.cycleTabs(step)
        case "space", "workspace":
            guard let next = HerdrClient.adjacentWorkspace(in: try await HerdrClient.listWorkspaces(), step: step)
            else { return }
            try await HerdrClient.focusWorkspace(next.workspaceID)
        default:
            break   // an unrecognized mode does nothing, same as `.effort` never reaching here
        }
    }

    public func inject(_ text: String) async throws {
        guard let agent = try await HerdrClient.focusedAgent(), let pane = agent.paneID else {
            throw HerdrError.api("Nothing has focus in Herdr right now.")
        }
        try await HerdrClient.sendText(paneID: pane, text: text)
    }

    /// One joystick deflection, one pane over — Herdr's `pane.focus_direction`,
    /// the same moves its own prefix+h/j/k/l make. A deflection with nowhere
    /// to go (a lone pane, or the edge of the layout) is a no-op, not an
    /// error: Herdr answers it with a plain `no_neighbor` result, and if a
    /// Herdr version ever words it as an error instead, that too is
    /// swallowed here — a deflection into empty space should never surface
    /// `lastError`.
    public func joystick(_ direction: Pad.JoystickDirection) async throws {
        do {
            try await HerdrClient.focusPane(direction: HerdrClient.PaneDirection(direction))
        } catch HerdrError.api(let message) where message.contains("no_neighbor") || message.contains("no neighbor") {
            return
        }
    }

    public func subscribe(_ onChange: @escaping @Sendable () -> Void) -> ProviderSubscription {
        lock.lock()
        stopped = false
        lock.unlock()
        startLifecycleStream()
        return changeNotifier.subscribe(onChange) { [weak self] in self?.teardown() }
    }

    private func teardown() {
        lock.lock()
        stopped = true
        let lifecycleToStop = lifecycle
        let streamsToStop = statusStreams
        lifecycle = nil
        statusStreams.removeAll()
        lock.unlock()
        lifecycleToStop?.stop()
        streamsToStop.values.forEach { $0.stop() }
    }

    private func startLifecycleStream() {
        let stream = HerdrEventStream(subscriptions: [
            ["type": "pane.created"],
            ["type": "pane.closed"],
            ["type": "pane.exited"],
            ["type": "pane.agent_detected"]
        ])
        stream.onEvent = { [weak self] _ in self?.changeNotifier.notify() }
        stream.onClosed = { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            let wasStopped = self.stopped
            self.lifecycle = nil
            self.lock.unlock()
            guard !wasStopped else { return }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self?.startLifecycleStream()
            }
        }
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        lifecycle = stream.start()
        lock.unlock()
    }

    /// One dedicated stream per agent pane: a subscription owns its connection
    /// and cannot be extended after the fact.
    private func reconcileStatusStreams(_ agents: [HerdrAgent]) {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        let wanted = Set(agents.compactMap(\.paneID))
        for (paneID, stream) in statusStreams where !wanted.contains(paneID) {
            stream.stop()
            statusStreams.removeValue(forKey: paneID)
        }
        let toStart = wanted.filter { statusStreams[$0] == nil }
        lock.unlock()

        for paneID in toStart {
            let stream = HerdrEventStream(subscriptions: [
                ["type": "pane.agent_status_changed", "pane_id": paneID]
            ])
            stream.onEvent = { [weak self] _ in self?.changeNotifier.notify() }
            stream.onClosed = { [weak self] _ in
                guard let self else { return }
                self.lock.lock(); self.statusStreams.removeValue(forKey: paneID); self.lock.unlock()
            }
            lock.lock()
            if stopped {
                lock.unlock()
                stream.stop()
            } else {
                statusStreams[paneID] = stream.start()
                lock.unlock()
            }
        }
    }
}
