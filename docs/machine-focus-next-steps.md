# Cross-machine navigation: where it stands, and what to do next

Written 2026-09-08, after live-testing PR #14 against Herdr 0.9.0
(protocol 22) with two machines: Local (Mac mini) and Jarvis (Linux).

## The one-sentence version

Reading across machines works and is shipped; **navigating** to another
machine is blocked on a Herdr API that does not exist, so the dial crossing
is gated off behind a config flag until it does.

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

## Next session

### 1. File the upstream request

`docs/herdr-machine-focus-request.md` is written and ready. It asks for
either `machine.focus` or a `machine_id` parameter on the existing focus
calls, plus `machine_id` on `workspace.list` / `agent.list` results.

Send it to the Herdr project. Everything downstream waits on the answer.

### 2. When the API lands

Roughly a day's work, in this order:

1. **Teach `HerdrClient` the new call.** Add it to `HerdrServicing` so the
   fake in `HerdrProviderStepTests` can exercise it.
2. **Call it from `HerdrProvider.landFromOtherMachine`**, before the focus.
   Landing already returns `Bool` — return false if the machine switch
   fails, and `RoutingProvider` will walk past that machine exactly as it
   does a dead one. The plumbing for this is already in place.
3. **Route remote agent keys through it too.** `RoutingProvider.focus`
   already de-namespaces the target and picks the child; it needs the same
   machine switch first. This fixes remote agent keys, which are blocked by
   the same gap and are arguably the more valuable half.
4. **Flip the default.** `dialCrossesMachines` becomes true, and the flag
   turns into an escape hatch rather than an opt-in.
5. **Delete the dead window-raising path** — see below.

### 3. Independent of upstream: retire the two-window machinery

`ForegroundInstanceDetector` exists to tell **two Ghostty windows** apart by
stamping marker titles and reading them back over Accessibility. Herdr 0.9
put every machine in one window, so:

- `activate(instanceID:)` can never find a window to raise and silently
  no-ops,
- `onFocusInstance` is fire-and-forget and cannot report that,
- calibration has nothing to discriminate.

It is dead weight under 0.9 and actively misleading — it makes a failed
raise look like a successful landing. Either delete it, or keep it behind an
explicit "one window per machine" config for anyone still on 0.8. Worth
doing on its own; it does not depend on the API request.

### 4. Sharpen the six-key ceiling

Eleven agents, six keys. Priority order is the current answer and it works,
but idle slots still go to the active machine first. Worth considering:
drop idle agents from key slots entirely when more than one machine is
configured, so the keys only ever show what wants attention. Cheap, and it
would have made the difference in testing — five idle remote shells were
eating the whole pad.

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
