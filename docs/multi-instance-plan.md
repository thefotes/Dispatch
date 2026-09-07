# Driving two Herdr instances from one pad

A plan for making Micro Manager talk to more than one Herdr server — a local
one (`herdr`) and a remote one (`herdr --remote jarvis`) — routing pad input to
whichever instance's terminal window is frontmost, and lighting the underglow
from both at once.

This document is a handoff spec. The investigation behind it is already done;
**§1 is verified fact, do not re-derive it.**

---

## 1. Verified findings

Everything in this section was confirmed live against a running local Herdr
0.8.2 and a remote one on `jarvis` (Ubuntu, Herdr 0.8.2, protocol 20).

### 1.1 The remote server is reachable, with full API parity

`herdr --remote jarvis` creates `$TMPDIR/herdr-remote-<pid>-jarvis-default.sock`,
but **that socket is not the JSON API** — it is the client-bridge transport
feeding the terminal UI (the SSH child runs `herdr remote-client-bridge`).
Sending it `agent.list` connects and then hangs forever with no reply. Do not
try to use it.

The remote server's real API socket lives on the remote box at
`/home/pfoti/.config/herdr/herdr.sock`. OpenSSH forwards a Unix socket to a Unix
socket, which yields a local path speaking the byte-identical protocol:

```bash
ssh -f -N -o ExitOnForwardFailure=yes \
  -L "${TMPDIR}jarvis-herdr.sock:/home/pfoti/.config/herdr/herdr.sock" jarvis
```

Confirmed working through that forwarded path:

| Call | Result |
|---|---|
| `agent.list` | returns jarvis's agents |
| `pane.current` | reads focused pane |
| `agent.focus` | **writes work** — focused `w13:p1`, verified, restored |
| `events.subscribe` | held open 13s, 24 live events streamed |

No protocol shim is needed. It is the same server, so `HerdrClient` works
against it unmodified once it can be pointed at a different path.

**Socket path length matters.** macOS caps `sun_path` at 104 bytes. A path under
the repo or a scratch dir will exceed it and fail with `AF_UNIX path too long`.
Keep forwarded sockets in `$TMPDIR`.

### 1.2 `HERDR_SOCKET_PATH` is a first-class Herdr env var

Confirmed present in the shipped binary's env table and honoured by the CLI:
`HERDR_SOCKET_PATH=… herdr status` reports the *remote* server. `HerdrClient.socketPath()`
(`Sources/WLKit/HerdrClient.swift:144`) already reads it. Note this is a
process-wide override and therefore **not** the mechanism for this feature — the
app needs two paths at once — but it is the right escape hatch to keep honouring
as the default instance's path.

### 1.3 Herdr cannot tell you which terminal window is focused

All 26 event types in `herdr api schema --json` were enumerated. There are
`pane_focused`, `tab_focused`, `workspace_focused` — all *inside* Herdr. Nothing
reports the client's own terminal focus. The server has no concept of macOS
window focus.

`ClientWindowTitleReason` contains `no_foreground_client`, which looks like a
focus oracle but is not: it means "a client is attached". Both instances report
attached regardless of which window is front. Confirmed by setting a title on
both simultaneously — both returned `changed:true, reason:"set"`.

### 1.4 Window-level detection: what is and isn't available

- Both Herdr clients run inside **one** Ghostty process (pid 1189, `ttys000` and
  `ttys019`). App-level frontmost detection cannot discriminate them.
- `CGWindowListCopyWindowInfo` gives front-to-back order, window numbers, and
  owner pid with **no permission**, but `kCGWindowName` comes back `nil` without
  Screen Recording. Verified.
- Ghostty exposes no window/surface query in its CLI (`+list-actions` checked).
- **Accessibility works and costs nothing new.** `README.md:175` states the app
  already requires Accessibility for the wide key's right-command tap. AX returns
  the window titles that `CGWindowList` withholds.
- **`client.window_title.set` / `.clear` exist and work on both instances.** This
  turns window→instance mapping from title-guessing into an exact match.

### 1.5 The static socket path is shallow

`HerdrClient.socketPath()` has exactly **two** call sites:

- `Sources/WLKit/HerdrClient.swift:160` — inside `request()`
- `Sources/WLKit/HerdrClient.swift:424` — `HerdrEventStream.init`

Every other static (`listAgents`, `focusAgent`, `sendText`, …) funnels through
`request()`. The pure helpers (`adjacentTab`, `nextTab`, `adjacentAgent`,
`adjacentWorkspace`, `PaneDirection`) take data and hold no connection — they
stay static permanently.

### 1.6 The 6-key limit does not constrain the underglow

`StatusMapper.threads` (`Sources/WLKit/StatusMapper.swift:78`) maps agents onto
`Pad.agentKeyIDs` by slot and returns an off thread past the end — agents beyond
the sixth are silently invisible on the keys. But `StatusMapper.aggregate`
(`:67`) folds over **every** agent it is given.

This is load-bearing for the design: merged `status()` produces a correct
cross-machine underglow *regardless* of how many agents fit on keys. "Does
anything on either box need me?" works even with twelve agents. The key-slot
allocation policy is a separate and much smaller decision.

### 1.7 The provider seam is already in the right place

`BridgeController` holds `private let provider: Provider` (`:113`, set in
`init` at `:125`) and depends on the protocol only. The agent flow is:

- `:378` `fetched = try await provider.status()`
- `:384` `agents = fetched` — **array order determines key assignment**
- `:386` `StatusMapper.aggregate(fetched, config)` → underglow
- `:409` `StatusMapper.threads(for: fetched, config)` → per-key colors
- `:712` `agents[index].focusTarget` → `provider.focus(target)`

`focusTarget` is the *only* identity that crosses back into the provider, and
`BridgeController` treats it as opaque. That makes namespacing it inside a
routing provider a fully contained change.

---

## 2. Scope

### In scope

- Multiple Herdr instances, each with its own socket path.
- Pad input (agent keys, dial, joystick, macro/inject, provider actions) routed
  to whichever instance's terminal window is frontmost.
- Merged status so the underglow reflects both machines.

### Out of scope

`LandPanel`, `StackPanel`, and `TuneController` call `HerdrClient` statics
directly, predating the `Provider` protocol. **Leave them alone.** They will
keep talking to the default (local) instance, which is the correct behaviour for
now — `StackPanel` and `LandPanel` shell out to `but` against
`agent.workingDirectory`, and a jarvis agent's `/home/pfoti/...` does not exist
locally, so pointing them at a remote instance would break them anyway. They
need re-implementing as provider actions someday; that is a separate job.

**This constrains the refactor in §3.1:** the `HerdrClient` statics must keep
working exactly as they do today, so those three files are not touched.

### Not yet decided

Managing the SSH tunnel from inside the app (see §5, slice 4). For slices 0–3
the tunnel is set up outside the app.

---

## 3. Architecture

```
BridgeController                        (unchanged)
  └── RoutingProvider : Provider        (new)
        ├── HerdrProvider(socketPath: ~/.config/herdr/herdr.sock)      id "local"
        └── HerdrProvider(socketPath: $TMPDIR/jarvis-herdr.sock)       id "jarvis"
        └── ForegroundInstanceDetector  (new) — decides which child is active
```

`BridgeController` is never taught that more than one Herdr exists. Nothing
swaps at runtime, so the `ProviderFactory` note about a provider swap needing a
relaunch stops applying — routing happens *inside* a single long-lived provider.

### 3.1 `HerdrClient` becomes instance-based, statics preserved

Convert `public enum HerdrClient` to a `public struct` holding
`public let socketPath: String`. A struct can carry both instance and static
methods, so every existing `HerdrClient.listAgents()` call site keeps compiling.

```swift
public struct HerdrClient {
    public let socketPath: String

    public init(socketPath: String = HerdrClient.defaultSocketPath()) {
        self.socketPath = socketPath
    }

    /// The former `socketPath()`, unchanged: HERDR_SOCKET_PATH, then
    /// XDG_CONFIG_HOME, then ~/.config/herdr/herdr.sock.
    public static func defaultSocketPath() -> String { … }

    /// Backs every static below, so out-of-scope callers keep working.
    public static let shared = HerdrClient()

    public func request(_ method: String, params: [String: Any] = [:],
                        timeout: TimeInterval = 5) async throws -> [String: Any] { … }

    public static func listAgents() async throws -> [HerdrAgent] {
        try await shared.listAgents()
    }
    // …one forwarding static per existing static
}
```

- Move the request/subscribe bodies to instance methods; `request()` uses
  `self.socketPath` instead of calling `socketPath()`.
- Keep `adjacentTab`, `nextTab`, `adjacentAgent`, `adjacentWorkspace`, and
  `PaneDirection` as statics — they are pure.
- `HerdrEventStream.init` gains `socketPath: String = HerdrClient.defaultSocketPath()`.
- Rename the static `socketPath()` to `defaultSocketPath()` and update
  `Tests/WLKitTests/LiveHerdrTests.swift:9,13`.

**Acceptance:** no behaviour change; the full suite passes untouched apart from
that test rename.

### 3.2 `HerdrProvider` takes a socket path

Add to `HerdrProvider.Options` (`Sources/WLKit/HerdrProvider.swift:23`):

```swift
public var socketPath: String = HerdrClient.defaultSocketPath()
```

Store `private let client: HerdrClient` built from it, and replace the ~13
`HerdrClient.` static calls in that file with `client.`. Pass
`options.socketPath` into both `HerdrEventStream` constructions (`:274`, `:313`).

`describe()` returns literals and touches no socket — so a dead instance still
describes correctly. Keep it that way.

### 3.3 Instance identity and config

```swift
public struct HerdrInstance: Sendable, Equatable {
    public var id: String          // "local", "jarvis" — stable, used in focus targets
    public var name: String        // display name for the panel
    public var socketPath: String
}
```

Extend `config.json`'s existing `"herdr"` section, parsed in `KeyBindings`
(around `:196`):

```json
{
  "herdr": {
    "tools": ["opencode", "claude", "codex"],
    "instances": [
      { "id": "local",  "name": "Mac Mini", "socket_path": "~/.config/herdr/herdr.sock" },
      { "id": "jarvis", "name": "Jarvis",   "socket_path": "$TMPDIR/jarvis-herdr.sock" }
    ]
  }
}
```

- Absent or empty `instances` → one instance, id `"local"`, path
  `HerdrClient.defaultSocketPath()`. **Existing configs must keep working.**
- Expand `~` and `$TMPDIR` in `socket_path`.
- Exactly one instance → `ProviderFactory` returns a plain `HerdrProvider` as it
  does today. Only build a `RoutingProvider` when there are two or more.

### 3.4 `RoutingProvider`

New file `Sources/WLKit/RoutingProvider.swift`. Holds the ordered children and
an active instance id, guarded by a lock (it is `@unchecked Sendable`, same
pattern as `RemoteProvider`).

| `Provider` method | Behaviour |
|---|---|
| `describe()` | First child's `describe()`. All children are Herdr, so descriptions are identical; do not attempt a merge. |
| `status()` | Slice 1: active child only. Slice 3: all children, concatenated in **config order**, each agent tagged and its focus target namespaced. |
| `focus(target)` | Split the namespace prefix off `target`, dispatch to that child, then bring that instance's terminal window forward. |
| `dial`, `joystick`, `inject`, `perform` | **Active child only**, always. This is what makes the pad "work as it does today" for whichever Herdr you are looking at. |
| `subscribe` | Fan out to every child, plus the detector's own change signal. Any of them fires the caller's `onChange`. |

**Per-child failure isolation is a requirement, not a nicety.** If the jarvis
tunnel dies, `status()` on that child throws. `RoutingProvider.status()` must
catch per child and treat a failure as an empty agent list, so a dead remote
never blanks the local pad. Surface it once through `lastError` rather than
throwing.

### 3.5 Namespaced focus targets (slice 3 only)

Pane ids collide across instances — local has `w3:p1`, jarvis has `w13:p1`, and
both will eventually mint a `w1:p1`. Merged status therefore needs namespacing.

Add to `HerdrAgent`:

```swift
public var instanceID: String?
```

and make `focusTarget` include it when set:

```swift
public var focusTarget: String? {
    guard let raw = paneID ?? terminalID else { return nil }
    guard let instanceID else { return raw }
    return "\(instanceID)\u{1}\(raw)"
}
```

`RoutingProvider.status()` stamps `instanceID` on each agent as it collects
them; `focus()` splits on `\u{1}` and dispatches. `BridgeController` passes
`focusTarget` back opaquely (`:712`), so nothing else changes. A target with no
separator routes to the active child, which keeps single-instance behaviour
identical.

**Ordering must be stable.** `agents = fetched` at `:384` assigns pad keys by
array index, so a wobbling order makes keys jump under the user's fingers.
Concatenate in config order, each instance's agents in the order that instance
reported them. Never sort by status.

### 3.6 `ForegroundInstanceDetector`

New file in `Sources/WLMicroManager/` (it needs AppKit/AX, so it belongs in the
app layer, not `WLKit` — mirror how `BridgeController:93` notes the CGEvent
post is app-layer).

**Signal.** An `AXObserver` on the Ghostty pid for
`kAXFocusedWindowChangedNotification`, plus
`NSWorkspace.didActivateApplicationNotification` to catch app switches. Poll only
as a fallback. Resolve the terminal pid from the bundle id the app already uses
(`WL_TERMINAL_BUNDLE_ID`, `BridgeController:732`).

**Mapping window → instance, by calibration.** Do not stamp marker titles
permanently — that would clobber the agent titles the user reads. Calibrate on
demand:

1. For each instance, `client.window_title.set("⟦wl:<id>⟧")`.
2. Read `AXTitle` of every Ghostty window; the window carrying the marker is
   that instance's.
3. `client.window_title.clear()`.
4. Cache the window → instance id mapping.

Run calibration at start and whenever the focused window is not in the cache.
Steady-state focus changes are then a cache lookup with no title churn.

**Window identity for the cache.** Try `CFEqual`/`CFHash` on the `AXUIElement`
first — it should stay valid and comparable for the window's lifetime.
**This needs verifying before it is relied on.** If it proves unstable, fall
back to the private `_AXUIElementGetWindow(_:UnsafeMutablePointer<CGWindowID>)`
to get a `CGWindowID` and key the cache on that instead; window numbers are
stable for a window's lifetime and `CGWindowListCopyWindowInfo` gives them
without any permission.

**Switch only on a positive identification.** If the frontmost window is some
unrelated Ghostty window, or the frontmost app is not a terminal at all, keep
the current active instance. Never fall back to a default on ambiguity — that
would make the pad silently drive the wrong machine.

**Degrade honestly.** If Accessibility is not granted, `AXUIElementCopyAttributeValue`
returns `-25211` (`kAXErrorAPIDisabled`). Detection then reports "cannot
determine", the active instance stays where the manual action last put it, and
the panel shows a warning. The pad must stay useful without AX.

---

## 4. Slices

Ship in this order. Each slice is independently useful and leaves the app
working.

### Slice 0 — instance-based client, no behaviour change

§3.1 and §3.2. Nothing multi-instance yet.

*Done when:* the suite passes, the app behaves identically, and
`HerdrProvider(options:.init(socketPath: <forwarded jarvis sock>))` demonstrably
lists jarvis's agents in a test.

### Slice 1 — routing with a manual switch

§3.3, §3.4, and a `RoutingProvider` action `herdr.next_instance` bindable from
`config.json` via the existing `{"action": …}` mechanism. `status()` returns the
active child only. No AX yet.

Doing the manual switch first is deliberate de-risking: it proves routing
end-to-end independently of AX, and it leaves a working fallback if detection
turns out to be unreliable on the user's setup.

*Done when:* with two instances configured, a bound key flips which Herdr the
agent keys, dial, and joystick drive, and killing the jarvis tunnel leaves the
local instance fully working.

### Slice 2 — foreground follows the frontmost window

§3.6. The active instance now tracks the frontmost Ghostty window. Keep the
manual action as an override.

*Done when:* switching between the two Ghostty windows changes which instance
the dial and joystick drive, with no perceptible lag, and revoking Accessibility
degrades to slice 1 behaviour rather than breaking.

### Slice 3 — merged status and cross-machine underglow

§3.5. `status()` returns all instances' agents. Per §1.6 the underglow is
already correct over the full list, so this is where the ambient-awareness
payoff lands.

Decide the key-slot policy here, now that it is isolated: with more than six
agents across two machines, the recommended default is to give the active
instance's agents the slots first and let the remainder fill from the other
instance in config order — the underglow still covers everything, so nothing is
lost from the "does anything need me?" signal.

*Done when:* an agent going red on jarvis turns the underglow red while the Mac
Mini's Herdr is frontmost, and pressing that agent's key focuses it on jarvis and
brings the jarvis window forward.

### Slice 4 — optional, app-managed tunnel

Let an instance declare how to establish its own transport, e.g.
`"ssh": "jarvis:/home/pfoti/.config/herdr/herdr.sock"`, so the app spawns and
supervises the `ssh -N -L …` child and reconnects when it drops. Until this
lands, document the manual command from §1.1 in the README and let the user run
it from a launchd agent.

---

## 5. Risks

- **`AXUIElement` cache-key stability** is the one unverified assumption in the
  design. Verify early in slice 2; the `CGWindowID` fallback is known-good.
- **A stale tunnel that accepts connections but never answers** looks different
  from a missing socket: `HerdrClient.request` has a 5s default timeout, so a
  wedged tunnel costs 5s per call. Use a shorter timeout for non-active
  instances' `status()` polls, and back off an instance that has timed out
  rather than retrying it on every refresh.
- **Calibration races a user who is actively switching windows.** Title set and
  clear are two round trips per instance. Keep calibration off the hot path,
  never run it more than once concurrently, and always clear the marker even on
  failure so a crash mid-calibration cannot leave a stamped title behind.
- **Marker titles are user-visible while calibrating.** Brief, but real. If the
  flicker is objectionable, calibrate once at launch and on unknown-window only,
  which is what §3.6 already specifies.
