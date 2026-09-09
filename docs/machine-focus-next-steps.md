# Cross-machine navigation: where it stands, and why it stops here

Written 2026-09-08, after live-testing PR #14 against Herdr 0.9.0
(protocol 22) with two machines: Local (Mac mini) and Jarvis (Linux).

**Closed out 2026-09-09.** The two items that did not need upstream are
done (§A, §B). The rest is blocked by a decision, not a delay: the API it
needs was requested upstream and declined as `NOT_PLANNED` the same day —
see "Status" below. This document is now a record and a resume path, not a
plan.

## The one-sentence version

Reading across machines works and is shipped; **navigating** to another
machine needs a client-level Herdr API that upstream has declined to
expose, so the dial crossing stays gated off behind a config flag.

## What is true today

| capability | needs the view to move? | state |
|---|---|---|
| merged agent status across machines | no | **works** |
| underglow folding in every agent | no | **works** |
| per-key lighting for remote agents | no | **works** (six-key ceiling) |
| remote agent keys (press to focus) | yes | **blocked** |
| cross-machine dial | yes | **blocked**, gated off |

### Why the blocked ones are blocked

Herdr 0.9 groups every machine into one client window. Its socket API does
not model that at all:

- `herdr api schema --json` lists **111 methods**; the substring `machine`
  appears nowhere in the schema.
- Focus is **per-server**, and two servers report a focused entity at the
  same time.
- The machine a client is *displaying* is client-side state with no API.

So a remote `agent.focus` / `workspace.focus` genuinely succeeds — it moves
that server's focus — and the local client never switches to show it.

Reproduce in one minute:

```bash
# Jarvis's focus moves...
echo '{"id":"1","method":"agent.focus","params":{"target":"<remote-pane>"}}' \
  | nc -U "$TMPDIR/herdr-jarvis.sock"

# ...while the local server, which owns the window, has not moved.
echo '{"id":"2","method":"session.snapshot","params":{}}' \
  | nc -U ~/.config/herdr/herdr.sock | grep -o '"focused_pane_id":"[^"]*"'
```

This is not a bug in this repo. No amount of work here fixes it.

## What was gated, and where

- `KeyBindings.dialCrossesMachines` — parsed from
  `"herdr": {"dial_crosses_machines": true}`, defaults **false**.
- `RoutingProvider.init(children:crossesMachines:)` — stores it; `dial`
  returns to plain single-machine dialling when it is false.
- The spill logic itself is untouched and fully tested. Nothing was deleted.

`KeyBindings.prioritizeAgentKeys` now defaults to **true** whenever more
than one instance is configured, because sidebar order is
active-instance-first and six slots mean a busy active machine hides the
other one entirely.

## Status: blocked upstream, and upstream has answered

**Asked and declined, 2026-09-09.** The client-level API this needs was
requested in [herdrdev/herdr#3820][3820] — "Expose client-level aggregate
agent list, events, and focus for multi-machine plugins", filed by
@edvinasbartkus for the same Creator Micro 2 use case this repo has. It was
closed the same day as `NOT_PLANNED`:

> The current CLI/API is server-scoped, as documented in Connecting
> machines. Exposing the TUI's cross-machine agent list, events, and
> client-targeted focus to plugins would add a new supported interface
> rather than restore existing behavior. Please continue this proposal in
> Ideas discussions. Closing as a feature request.

So this is not "the API has not shipped yet". It is a deliberate scoping
decision, and the route back is an Ideas discussion gaining support, not a
release landing. No such discussion is open as of 2026-09-09.

### What upstream *is* building, and why it does not help

Cross-machine work is genuinely active on the 0.9.x line — all of it inside
Herdr's own TUI, none of it exposed:

| upstream | state | what it gives |
|---|---|---|
| [#3670][3670] manage multiple SSH machines from one client | merged | the foundation |
| [#3755][3755] navigate and highlight workspaces across machines | merged 2026-09-08 | sidebar navigate mode, Enter activates across machines |
| [#3781][3781] collapse worktree groups with saved machines | merged | sidebar polish |
| [#3784][3784] scope agent views to the selected machine | open | makes the client's *own* view correct; exposes nothing |

Herdr is building the cross-machine experience for its own sidebar and
declining to open that surface to plugins. Reading across machines is
already ours (`agent.list` per server, merged in `RoutingProvider`);
*navigating* stays theirs.

### Verified against 0.9.0, not assumed

Re-checked on 2026-09-09 against the installed binary rather than from these
notes, since the last check was a day old:

- `herdr api schema --json` — protocol 22, **111 methods**, zero matches for
  machine, client, window, view, host, remote, peer, instance, switch or
  display. Focus is `agent.focus` / `pane.focus` / `tab.focus` /
  `workspace.focus`, all per-server.
- The keybinding action list in the binary has **no machine action** — no
  `next_machine`, no `switch_machine`. There is no keystroke to bind.
- `herdr machine` is `list/add/rename/remove/enable/disable`: profile
  management, not selection.
- Upstream docs for v0.9.0 confirm the design: *"Choose a machine or one of
  its workspaces in the sidebar"*, and *"Workspace, tab, pane IDs, and agent
  names are scoped to one server."*

### The workaround, and why it is not taken

Once #3755 ships there is a keyboard path — prefix, navigate across
machines, Enter — which MicroManager could synthesize, since it already
posts shortcuts through `onShortcut`.

**Do not.** It is `ForegroundInstanceDetector` again one layer up: it
depends on sidebar scroll position and which row is highlighted, it cannot
confirm it landed, and it fails silently. That failure mode — a miss that
looks like a success — is what cost most of the PR #14 debugging time and is
exactly what §A below deleted. A blind keystroke sequence is not worth
re-acquiring it.

### If it unblocks: the resume path

Nothing needs rebuilding. The spill logic is written and fully tested behind
a gate:

1. `dialCrossesMachines` flips from opt-in to default — one line in
   `KeyBindings.dropIdleAgentKeys`'s neighbour, `dial_crosses_machines`.
2. Teach `HerdrClient` the new call, added to `HerdrServicing` so the fake in
   `HerdrProviderStepTests` can exercise it.
3. Call it from `HerdrProvider.landFromOtherMachine` before the focus.
   Landing already returns `Bool`, so a failed switch makes `RoutingProvider`
   walk past that machine exactly as it does a dead one.
4. Route remote agent keys through it too — `RoutingProvider.focus` already
   de-namespaces the target and picks the child, it just needs the switch
   first. This is arguably the more valuable half.

`RoutingProvider.setActiveInstance` is kept for steps 3 and 4 and says so.

[3670]: https://github.com/herdrdev/herdr/pull/3670
[3755]: https://github.com/herdrdev/herdr/pull/3755
[3781]: https://github.com/herdrdev/herdr/pull/3781
[3784]: https://github.com/herdrdev/herdr/pull/3784
[3820]: https://github.com/herdrdev/herdr/issues/3820

## Done without upstream

### A. Retire the two-window machinery

**Done 2026-09-08.** `ForegroundInstanceDetector` is deleted.

It existed to tell **two Ghostty windows** apart by stamping marker titles
and reading them back over Accessibility. Herdr 0.9 put every machine in
one window, so it was dead weight and actively misleading — a failed raise
looked like a successful landing, and that cost most of the debugging time.

Removed along with it, all of it existing only to serve the detector:

- `HerdrInstance.calibrationMarker` (`⟦wl:id⟧`)
- `RoutingProvider.onFocusInstance` and both call sites
- `HerdrClient.setWindowTitle` / `clearWindowTitle` (`window_title.set/clear`)
- The detector wiring in `MicroManagerApp`. The active instance now moves
  only through `herdr.next_instance` and the dial spill, both via
  `RoutingProvider.activate(index:)`. `setActiveInstance` has no caller and
  is kept, documented, for steps 3 and 4 of the resume path above.

### B. Sharpen the six-key ceiling

**Done 2026-09-08.** Idle agents are dropped from the key slots whenever
more than one Herdr instance is configured — `"agent_keys_drop_idle": false`
in config.json opts back in. With one machine nothing changes. Five idle
remote shells no longer eat the whole pad; the keys only light agents that
want attention, while the underglow still folds over every agent.

## Environment notes that cost time

- **Ad-hoc signing revokes TCC grants on every rebuild.** There are no
  codesigning identities on this Mac, so Input Monitoring *and*
  Accessibility drop on each `bundle.sh --install`, and re-granting one can
  disturb the other. Getting an Apple Development cert into the keychain
  removes an entire class of false debugging. `bundle.sh` already prefers a
  real identity.
- **Running `swift test` while the app is live** trips the panel's "Another
  app is also driving this pad" warning: `LiveDeviceTests` shares the HID
  open, so the app sees replies to ids it never issued. Harmless, clears on
  the next manager toggle.
- **`swift test --filter LiveDeviceTests`** distinguishes an app-side
  failure from a kernel HID wedge. If it opens the pad, the hardware is
  fine and the problem is the app or its permissions.
