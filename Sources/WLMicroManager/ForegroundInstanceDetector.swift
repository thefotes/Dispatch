import AppKit
import ApplicationServices
import WLKit

/// Tracks which Herdr instance's terminal window is frontmost, so
/// `RoutingProvider` can route pad input to the Herdr you are looking at.
///
/// Herdr cannot report macOS window focus (none of its 26 event types
/// describe the client's own terminal), and both Ghostty windows share one
/// process, so app-level frontmost checks cannot discriminate them.
/// Accessibility is what works: AX window titles are readable without Screen
/// Recording, and `window_title.set`/`.clear` on each instance turn
/// window→instance mapping from title-guessing into an exact match.
///
/// Mapping by calibration, not by permanent markers — stamping titles
/// permanently would clobber the agent titles the user reads. On demand:
/// for each instance, set the marker title, find the Ghostty window that
/// carries it, clear the title, and cache window→instance. Calibration runs
/// at start and whenever the focused window is not in the cache; steady-state
/// focus changes are a cache lookup with no title churn.
///
/// Degrades honestly: without Accessibility, AX answers `kAXErrorAPIDisabled`
/// and detection reports "cannot determine" — the active instance stays
/// wherever the manual `herdr.next_instance` action last put it, the panel
/// gets a warning through `onWarning`, and the pad stays useful.
@MainActor
final class ForegroundInstanceDetector {

    /// Fired when the frontmost window was positively identified as an
    /// instance's. Never fired on ambiguity: an unrelated Ghostty window or
    /// a non-terminal frontmost app keeps the current instance — falling
    /// back to a default would silently drive the wrong machine.
    var onActiveInstanceChange: ((String) -> Void)?

    /// Fired when detection degrades (Accessibility refused), phrased for
    /// the panel.
    var onWarning: ((String) -> Void)?

    private var instances: [HerdrInstance] = []
    private var clients: [String: HerdrClient] = [:]
    /// Focused window → instance id, keyed by `CGWindowID` — stable for a
    /// window's lifetime and obtainable without any permission.
    private var windowCache: [CGWindowID: String] = [:]
    /// The AX element behind each cached window id, kept so a remote agent
    /// key press can raise exactly the right window.
    private var windowElements: [CGWindowID: AXUIElement] = [:]
    private var observer: AXObserver?
    private var runLoopSource: CFRunLoopSource?
    private var workspaceObserver: NSObjectProtocol?
    private var pollTimer: Timer?
    private var calibrating = false
    private var warnedAXDisabled = false
    /// The instance id last reported active, so an unchanged window does not
    /// re-fire `onActiveInstanceChange` on every poll.
    private var lastReported: String?

    func start(instances: [HerdrInstance]) {
        stop()
        self.instances = instances
        clients = Dictionary(uniqueKeysWithValues: instances.map { ($0.id, HerdrClient(socketPath: $0.socketPath)) })
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        // The AX observer is the primary signal; app switches and this slow
        // poll are the fallbacks.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        if let app = terminalApp() {
            installObserver(for: app.processIdentifier)
        }
        poll()
    }

    func stop() {
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
        runLoopSource = nil
        observer = nil
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
        workspaceObserver = nil
        pollTimer?.invalidate()
        pollTimer = nil
        Self.live = nil
        instances = []
        clients = [:]
        windowCache = [:]
        windowElements = [:]
    }

    /// Brings an instance's terminal window forward — the hook
    /// `RoutingProvider.onFocusInstance` calls after a namespaced focus, so
    /// pressing a remote agent's key lands you on that machine's window.
    func activate(instanceID: String) {
        guard let windowID = windowCache.first(where: { $0.value == instanceID })?.key,
              let element = windowElements[windowID]
        else { return }
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        _ = terminalApp()?.activate(options: [])
    }

    // MARK: - Detection

    private func terminalApp() -> NSRunningApplication? {
        let identifier = ProcessInfo.processInfo.environment["WL_TERMINAL_BUNDLE_ID"]
            .flatMap { $0.isEmpty ? nil : $0 } ?? BridgeController.defaultTerminalBundleID
        return NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first
    }

    private func poll() {
        guard !instances.isEmpty, !calibrating else { return }
        guard let app = terminalApp(), let element = appElement(pid: app.processIdentifier) else { return }

        var focused: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &focused)
        if error == .apiDisabled {
            reportAXDisabled()
            return
        }
        guard error == .success, let focused else { return }
        let axWindow = unsafeDowncast(focused, to: AXUIElement.self)

        var windowID: CGWindowID = 0
        guard _AXUIElementGetWindow(axWindow, &windowID) == .success else { return }
        windowElements[windowID] = axWindow

        if let known = windowCache[windowID] {
            reportActive(known)
            return
        }
        // Unknown window in front — it may be a new instance window, or an
        // unrelated one. Calibrate to find out; the switch itself happens
        // only on a positive identification.
        Task { await self.calibrate(focusedWindowID: windowID) }
    }

    private func reportActive(_ id: String) {
        guard lastReported != id else { return }
        lastReported = id
        onActiveInstanceChange?(id)
    }

    private func reportAXDisabled() {
        guard !warnedAXDisabled else { return }
        warnedAXDisabled = true
        onWarning?("Accessibility is off, so the pad cannot follow which terminal window is frontmost — use the \"Next Herdr instance\" action to switch manually.")
    }

    /// Stamps each instance's marker title, finds which Ghostty window
    /// carries it, and clears the title again — always, even on failure, so
    /// a crash mid-calibration cannot leave a stamped title behind. Only one
    /// calibration at a time (off the hot path: two socket round trips per
    /// instance); a user switching windows concurrently just makes the next
    /// poll recalibrate.
    private func calibrate(focusedWindowID: CGWindowID) async {
        guard !calibrating else { return }
        calibrating = true
        defer { calibrating = false }

        var discovered = windowCache
        for instance in instances {
            guard let client = clients[instance.id] else { continue }
            do {
                try await client.setWindowTitle(instance.calibrationMarker)
            } catch {
                continue   // the instance is unreachable; nothing to map yet
            }
            if let (windowID, element) = windowCarrying(title: instance.calibrationMarker) {
                discovered[windowID] = instance.id
                windowElements[windowID] = element
                if windowID == focusedWindowID { reportActive(instance.id) }
            }
            // The clear is unconditional: calibration must never leave the
            // marker behind, whatever the window search did.
            try? await client.clearWindowTitle()
        }
        windowCache = discovered
    }

    /// Reads the AX title of every window of the terminal app, looking for
    /// the one a marker landed on.
    private func windowCarrying(title marker: String) -> (CGWindowID, AXUIElement)? {
        guard let app = terminalApp(), let appEl = appElement(pid: app.processIdentifier),
              let windows = attribute(appEl, kAXWindowsAttribute as String) as? [AXUIElement]
        else { return nil }
        for window in windows {
            if let title = attribute(window, kAXTitleAttribute as String) as? String,
               title.contains(marker) {
                var id: CGWindowID = 0
                if _AXUIElementGetWindow(window, &id) == .success {
                    return (id, window)
                }
            }
        }
        return nil
    }

    // MARK: - AX plumbing

    private func appElement(pid: pid_t) -> AXUIElement? {
        AXUIElementCreateApplication(pid)
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func installObserver(for pid: pid_t) {
        var newObserver: AXObserver?
        // No context survives a C function pointer, and the callback's
        // parameters identify neither this detector nor the window — so the
        // callback just nudges the live detector, which re-reads the focused
        // window itself.
        let result = AXObserverCreate(pid, { _, _, _, _ in
            Task { @MainActor in ForegroundInstanceDetector.live?.poll() }
        }, &newObserver)
        guard result == .success, let newObserver else { return }
        observer = newObserver
        runLoopSource = AXObserverGetRunLoopSource(newObserver)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        if let element = appElement(pid: pid) {
            AXObserverAddNotification(newObserver, element, kAXFocusedWindowChangedNotification as CFString, nil)
        }
        Self.live = self
    }
}

/// The AXObserver callback cannot capture `self`, so the installed detector
/// registers itself here. One menu-bar app means at most one detector is
/// live.
private extension ForegroundInstanceDetector {
    nonisolated(unsafe) static var live: ForegroundInstanceDetector?
}

/// Private-but-stable HIToolbox symbol: the `CGWindowID` behind an
/// `AXUIElement`. Chosen over `CFHash`-on-the-element as the cache key
/// because window numbers are stable for a window's lifetime by contract,
/// and `CGWindowListCopyWindowInfo` confirms them without any permission —
/// no live verification needed.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError
