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

    /// Herdr-specific knobs for the actions `perform` serves, injected at
    /// construction (from `config.json`'s `"herdr"` section, via
    /// `ProviderFactory`) rather than reaching into `KeyBindings` here —
    /// this file owns what the knobs mean, not where they come from.
    public struct Options: Sendable {
        /// The prompt names the cycle action rotates through, in order.
        public var tools: [String]
        /// Which side of the focused pane the split action puts the new one
        /// on: "right", "down", "left" or "up" — Herdr's own vocabulary,
        /// passed through verbatim.
        public var splitDirection: String

        public init(
            tools: [String] = Options.defaultTools,
            splitDirection: String = Options.defaultSplitDirection
        ) {
            self.tools = tools
            self.splitDirection = splitDirection
        }

        public static let defaultTools = ["opencode", "claude", "codex"]
        public static let defaultSplitDirection = "right"
    }

    private let options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    /// Herdr's status vocabulary, the agent/tab/space navigation the dial
    /// offers, and the named actions its keys can be bound to — pinned
    /// against `BridgeConfig`'s own defaults by `HerdrProviderTests`, so the
    /// two cannot silently drift apart.
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
            ],
            actions: [
                ProviderAction(id: "new_workspace", label: "New Herdr workspace", raisesHost: true),
                ProviderAction(id: "split_pane", label: "Split Herdr pane", raisesHost: true),
                // Cycling types into a prompt you are already looking at.
                ProviderAction(id: "cycle_prompt", label: "Cycle prompt tool", raisesHost: false)
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

    public func perform(_ action: String) async throws {
        switch action {
        case "new_workspace":
            try await HerdrClient.createWorkspace()
        case "split_pane":
            try await HerdrClient.splitPane(direction: options.splitDirection)
        case "cycle_prompt":
            try await cyclePromptTools(options.tools)
        default:
            break   // not ours to run — callers resolve ids against describe()
        }
    }

    /// The tool-cycler's memory: the pane last written and what was typed
    /// there, so the next press knows both what to erase and what comes
    /// next. Guarded by `lock`, like every other mutable state here.
    private var lastPromptPaneID: String?
    private var lastPromptTool: String?

    private func cyclePromptTools(_ tools: [String]) async throws {
        let ordered = tools.filter { !$0.isEmpty }
        guard !ordered.isEmpty else { return }
        guard let agent = try await HerdrClient.focusedAgent(), let pane = agent.paneID else {
            throw HerdrError.api("Nothing has focus in Herdr right now.")
        }

        let previous: String?, next: String
        do {
            lock.lock(); defer { lock.unlock() }
            (previous, next) = Self.plannedCycle(
                paneID: pane, tools: ordered,
                lastPaneID: lastPromptPaneID, lastTool: lastPromptTool
            )
        }

        if let previous, !previous.isEmpty {
            try await HerdrClient.sendKeys(
                paneID: pane,
                keys: Array(repeating: "backspace", count: previous.count)
            )
        }
        try await HerdrClient.sendText(paneID: pane, text: next)

        // Commit the memory only now that the pane actually holds `next`. A
        // Herdr failure between the plan and here would otherwise leave the
        // cycler believing it typed something it did not, and the following
        // press would backspace the wrong count into whatever the pane
        // really holds. Presses are serialized by `BridgeController`'s action
        // chain, so the next `plannedCycle` sees this write.
        lock.lock()
        lastPromptPaneID = pane
        lastPromptTool = next
        lock.unlock()
    }

    /// The cycler's pure core: given the memory of the last press, what this
    /// press should erase (nil unless the *same* pane still holds it — the
    /// human may have moved focus or cleared the prompt by hand, and
    /// backspacing there would eat their text) and what it should type next,
    /// wrapping at the end of the list. A tool no longer in the list is
    /// still erased — it was still typed — before starting over at the front.
    static func plannedCycle(
        paneID: String,
        tools: [String],
        lastPaneID: String?,
        lastTool: String?
    ) -> (previous: String?, next: String) {
        let previous = paneID == lastPaneID ? lastTool : nil
        let index = previous.flatMap { tools.firstIndex(of: $0) }
            .map { ($0 + 1) % tools.count } ?? 0
        return (previous, tools[index])
    }

    /// One joystick deflection, one pane over — Herdr's `pane.focus_direction`,
    /// the same move its own prefix+h/j/k/l make — with a wrap at the edge:
    /// deflecting off the last pane of the focused tab lands on the first,
    /// off the first lands on the last.
    ///
    /// The layout snapshot up front tells us whether the focused pane even
    /// sits at the end of its tab's list; only then is a wrap possible, and
    /// only then do we spend a second round-trip confirming focus stayed put
    /// (a lone pane or a true edge answers `pane.focus_direction` with a
    /// `no_neighbor` result — older Herdr builds phrase it as an error, both
    /// land here the same). A deflection with nowhere to go and nothing to
    /// wrap to is a no-op, never a surfaced `lastError`. The wrap itself is
    /// a single `agent.focus`, never a walk pane-by-pane — walking would
    /// mark every pane it passed through "seen" in Herdr.
    public func joystick(_ direction: Pad.JoystickDirection) async throws {
        let before = (try? await HerdrClient.listAgents()) ?? []
        let fromPane = before.first(where: \.focused)?.paneID
        let wrapTarget = Self.wrapTarget(direction, panes: Self.panesInFocusedTab(before))

        do {
            try await HerdrClient.focusPane(direction: HerdrClient.PaneDirection(direction))
        } catch HerdrError.api(let message)
            where message.contains("no_neighbor") || message.contains("no neighbor") {
            // Treated as "did not move" — the wrap check below handles it.
        }

        guard let fromPane, let wrapTarget,
              (try? await HerdrClient.focusedAgent())?.paneID == fromPane
        else { return }
        try await HerdrClient.focusAgent(wrapTarget)
    }

    /// The panes sharing the focused pane's tab, in Herdr's own list order.
    /// Just the focused entry when tabs aren't reported, which leaves
    /// `wrapTarget` a no-op (it needs two or more).
    static func panesInFocusedTab(_ agents: [HerdrAgent]) -> [HerdrAgent] {
        guard let focused = agents.first(where: \.focused) else { return [] }
        guard let tab = focused.tabID else { return [focused] }
        return agents.filter { $0.tabID == tab }
    }

    /// The pane a deflection wraps to once it has run off the edge: east or
    /// south off the last pane lands on the first, west or north off the
    /// first lands on the last. Nil — no wrap, the deflection just stays put
    /// — for a tab with fewer than two panes, or a focused pane that isn't
    /// at the matching end (a genuine `no_neighbor` mid-layout).
    static func wrapTarget(_ direction: Pad.JoystickDirection, panes: [HerdrAgent]) -> String? {
        guard panes.count > 1, let index = panes.firstIndex(where: \.focused) else { return nil }
        switch direction {
        case .east, .south:
            return index == panes.count - 1 ? panes.first?.focusTarget : nil
        case .west, .north:
            return index == 0 ? panes.last?.focusTarget : nil
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
