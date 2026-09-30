# Dispatch product behavior

This document defines the first releasable behavior independently of any
previous implementation. Architecture belongs in ADR 0001; Creator Micro wire
facts belong in the protocol specification.

## Primary loop

Dispatch runs as a macOS menu-bar application. When enabled, it connects to a
Creator Micro 2, checks the active keymap after consent, observes the
configured provider, converts pad input into configured actions, and renders
provider and runtime state onto the pad.

Turning Dispatch off stops action execution and darkens the surfaces it owns.
Quitting performs the same cleanup before terminating.

## Keymap

The pad connects for lighting without changing its keymap. If the active
profile's first layer already emits Dispatch's codes, input works at once and
nothing is written. Codex's Creator Micro support sets up the same codes, so a
pad used with Codex is usually already ready. Otherwise Dispatch input is
unavailable until the user allows keymap setup in the panel. Consent covers
writing the keymap only, and is an app setting, separate from the
pad-independent configuration. The panel explains that setup replaces every
key, the dial directions, and the joystick directions on the active profile's
first layer. Before each write, Dispatch saves the
current user layout to `keymap.dispatch-backup.json` on the pad and verifies the
backup. If the current layer still contains Dispatch codes, it preserves the
existing backup instead. A missing or unsafe backup prevents a keymap write.

After setup, a changed layout is reported on reconnect without being overwritten.
The user may apply Dispatch's layout again or keep their layout and turn setup
off. The panel and `dispatch-probe keymap-restore --write` can restore the
on-device backup; restore verifies the read-back and leaves the backup in place.
Restoring through the panel turns setup off. Dispatch input stays disabled until
the prepared layout is confirmed, while lighting remains available.

## Configuration

The active configuration is versioned JSON at
`~/.config/dispatch/config.json`. A missing file uses documented defaults. A
valid edit replaces the current immutable snapshot atomically. An invalid edit
does not alter active behavior and is reported with a path-specific diagnostic
in the menu-bar panel and logs. If the configuration is invalid when Dispatch starts, Dispatch
stays on without connecting the pad and reports the error; the first reload
that installs a valid configuration connects the pad.

Every input behavior is a binding. No key number, dial direction, or joystick
direction has an action embedded in the Creator Micro driver. The default
configuration may provide the behaviors below, and users may remove or replace
each one.

## Provider slots

The first six physical keys in reading order are provider slots. For the
Creator Micro 2 their firmware indices are `0` through `5`.

The initial provider presents one active agent on each key bound to an agent
slot; the default binds six. Pressing a configured slot invokes the adapter action associated with that slot. For Herdr, the
default action focuses the agent and raises its associated terminal
application. Routing across provider instance and machine boundaries belongs
to the provider integration, not the device driver.

Agents take slots by status priority, most urgent first, so the slots go to
the agents that need the user: with the default priority, every blocked agent
comes before any done agent, then working, unknown, and idle. Agents with the
same status keep the provider's order. The priority is configuration policy,
and the order that lights a key is the order a press of that key uses. No more
agents are rendered than the connected presentation device supports.

## Other controls

The default configuration can assign:

- dial rotation to a provider-specific navigation or reasoning-effort action;
- joystick directions to provider-specific pane navigation;
- the wide key, index 10 (its two switches act as one key), to a voice-tool
  shortcut;
- a standard key to close a focused provider pane;
- remaining keys to keyboard shortcuts, text macros, application activation,
  or provider actions.

These are defaults, not driver behavior. An unbound event performs no action.
One event may invoke an ordered list of actions. Actions that must not overlap
declare an execution policy and reject or coalesce concurrent invocations.

## Presentation

Each visible agent slot is rendered from provider status. Initial semantic
states are blocked, done, working, unknown, and idle. Colors, brightness,
effects, ordering policy, and aggregate priority are configurable.

Ambient lighting represents the highest-priority visible state. The default
priority is:

```text
blocked > done > working > unknown > idle
```

Special controls may have configured appearances. Presentation is calculated
as a complete desired frame. The runtime coalesces intermediate frames and the
device layer sends only meaningful differences.

Disconnecting, disabling, or quitting clears every owned per-key thread and
both lighting zones. Failure to clear is reported but does not prevent
shutdown.

## Lifecycle

Dispatch distinguishes at least these health conditions:

- disabled;
- starting;
- connected and operational;
- device absent;
- Input Monitoring permission missing;
- device transport wedged or inaccessible;
- keymap incompatible or provisioning failed;
- provider unavailable;
- configuration invalid; and
- degraded, where input or presentation works but another subsystem does not.

The device connection is supervised with bounded exponential backoff and
reopened after disconnect or system wake. Provider observation retries
independently so a provider outage does not churn the HID connection. Default
provider polling is approximately 2.5 seconds and the device liveness check is
approximately 15 seconds; both are injectable in tests.

Sleep cancels or suspends work that cannot complete. Wake creates a new
connection generation. Results from an older generation are ignored.

## Menu-bar application

The menu-bar icon communicates broad runtime state without requiring the panel
to be open. The panel provides:

- enabled state;
- device and provider health;
- the active configuration location and reload result;
- actionable permission guidance;
- a concise view of current slot assignments, each labeled with its key (the
  first six agents unlabeled when no key is bound to a slot);
- diagnostics suitable for a bug report; and
- quit.

The UI observes runtime state and sends runtime intents. It does not call the
HID driver or external integrations directly.

## Diagnostics

`dispatch-probe` exercises device discovery and explicitly requested vendor
calls without starting the menu-bar application. It supports at least firmware
version, device status, keymap read, event observation, and a lighting test.
`dispatch-probe rpc <method> [params] [--hold N] [--write]` sends one raw call
and prints the response; it refuses methods whose names suggest changing the
pad unless `--write` is given.
Operations that write flash or alter the keymap require an explicit flag and
create a backup first.

Normal logs never include typed macro text, secrets, full provider payloads, or
unredacted configuration values. Event recording is opt-in and records the
stable Dispatch event model rather than raw user text.

## Acceptance without physical hardware

Ordinary CI proves:

- HID message framing and assembly;
- vendor response correlation and notification decoding;
- keymap analysis and deterministic provisioning plans;
- event serialization and replay;
- configuration validation and atomic replacement;
- event-to-action resolution;
- action execution through recording adapters;
- provider state decoding from fixtures produced for this repository;
- deterministic presentation rendering and coalescing;
- reconnection and stale-generation rejection with a controlled clock; and
- menu-bar view models derived from runtime health.

Live acceptance additionally verifies device discovery, permission messaging,
keymap backup/provisioning, every physical control, lighting, sleep/wake
recovery, provider focus behavior, and signed-build permission persistence.
