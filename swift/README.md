# Work Louder Swift tools

Two macOS apps over a shared `WLKit` library:

| product | what it is |
|---|---|
| `WLMicroManager` | the menu-bar app that runs the Herdr bridge in the background |
| `WLInspector` | a debug UI for watching traffic and driving lighting by hand |

---

# Micro Manager

A menu-bar app that lights each running Herdr agent on its own pad key, and
jumps to that agent when you press the key. It is the bridge itself — no Node
at runtime.

```bash
./scripts/bundle.sh --install     # build, sign, install to /Applications, launch
```

The first launch asks for Input Monitoring. Grant it, then toggle the manager
off and on.

**The icon** shows state at a glance: dimmed when off, a coloured dot when
running — green all idle, amber something working, red something needs you —
and a badge when the pad is missing or permission is denied.

**The panel** draws the pad in its real shape with the six agent keys showing
their live colour, then one row per agent. Click a key or a row to jump to that
agent. It also carries the on/off switch, an "Open at login" toggle, and a
warning when another app is fighting for the device.

**Off** clears the lights and stops driving, but deliberately leaves the device
keymap alone: rebinding is a flash write, and the keys light instantly on the
way back in if the bindings are still there.

## Why it must be bundled and signed

`swift run` works for development because it inherits your terminal's Input
Monitoring grant. A background app needs its own, and macOS keys that grant to
the **code signature** — so an ad-hoc signature, whose hash changes on every
build, forces you to re-grant after every rebuild. `bundle.sh` prefers a real
Apple Development or Developer ID identity from your keychain, which gives a
stable designated requirement and makes the grant stick. It also sets
`LSUIElement` so there is no Dock icon, and gives `SMAppService` a bundle it
will actually register as a login item.

## Only one bridge at a time

The Node bridge (`node bin/leds.js`), Work Louder's Input app and the Codex
desktop app all drive this same pad. Running two at once means they overwrite
each other. The panel detects this — a shared HID open means we receive other
clients' replies, so a response id we never issued is a reliable tell.

---

# Inspector

A macOS app for watching the traffic to and from a Work Louder pad, and for
driving its lighting by hand.

```bash
cd swift
swift run WLInspector
```

Run it **from your terminal**, not by double-clicking a built binary: macOS
attributes Input Monitoring to the responsible process, so launching from a
terminal that already has the grant means the app inherits it. A standalone
unbundled binary launched from Finder will be refused.

## What it shows

The log pane records every message in both directions:

| tag | meaning |
|---|---|
| `TX` | a JSON-RPC call sent to the device, with its call id |
| `RX` | the matching response |
| `NOTIFY` | a device-pushed notification — `v.oai.hid` key events, `v.oai.rad` joystick |
| `DEVICE` | firmware log lines, from HID channel 1 |
| `INFO` / `ERROR` | connection and transport events |

Notifications are decoded as well as shown raw, since their fields are
abbreviated: `v.oai.hid` carries `{k, act, ag}` (key, action, agent) and
`v.oai.rad` carries `{a, d}` (angle, distance).

Filter by tag with the checkboxes, `Pretty` to expand JSON, `Follow` to pin to
the newest line, `Copy` for the visible entries.

## What it can drive

**Individual keys.** The pad is drawn as its real `[2, 4, 4, 3]` matrix; click
keys to select them. Key indices are 0-based and row-major, so the six agent
keys are 0–5. Pick a colour, effect, brightness and speed, then *Apply to
selected*.

Effects are the firmware's own set: off, solid, snake, rainbow, breathing,
gradient, shallow breath.

**The underglow.** Its own colour, effect, brightness and speed, applied
independently of the keys.

**The keys zone.** A single colour across the whole key plate. Note that
per-key colour paints *over* zone colour, so the zone only shows through where
no key colour is set.

**All lights off** clears every key *and* both zones. Clearing zones alone is
not enough — that was a real bug worth encoding in a button.

**Walk keys 0→12** lights one key at a time across the pad. This is the test
that proves a thread id maps to a physical key.

## Raw calls

The bottom panel sends arbitrary JSON-RPC. Presets cover the common shapes.
Two things to remember, because the firmware answers `{"ok":1}` to anything —
a wrong payload looks exactly like a right one:

- field names are **abbreviated**: `c` colour, `b` brightness, `e` effect,
  `s` speed, `m` magic
- `effect` is a **number** (0 off, 1 solid, 2 snake, 3 rainbow, 4 breath,
  5 gradient, 6 shallow breath), not one of the strings `lights.preview` takes

```jsonc
// v.oai.thstatus — params are a bare ARRAY, one entry per key
[{ "id": 0, "c": 16711680, "b": 1, "e": 1, "s": 0.5 }]

// v.oai.rgbcfg — the two zones
{ "keys":    { "e": 0, "b": 0, "s": 0.5, "m": 1, "c": 0 },
  "ambient": { "e": 1, "b": 1, "s": 0.5, "m": 1, "c": 51283 } }
```

## Two IOKit traps

**Hold the manager.** `IOHIDManagerCreate` must be retained for the lifetime of
the connection. If it goes out of scope, the devices it opened are torn down
with it and every later `IOHIDDeviceSetReport` fails with
`kIOReturnNotOpen` (`0xE00002CD`) — while `IOHIDDeviceOpen` still returned
success, so nothing looks wrong at connect time.

**Find the vendor collection.** On both USB and Bluetooth this pad presents a
single `IOHIDDevice` whose *primary* usage is keyboard, with the vendor
collection listed in `DeviceUsagePairs`. Match on usage page `0xFF00` there,
not on primary usage. The app logs which interface it chose on connect.

## Notes

The device is opened **non-exclusively**. Its vendor collection shares an
`IOHIDDevice` with a keyboard collection, and macOS refuses to let anything
seize a keyboard — a seizing open fails with `0xE00002C1`, which reads exactly
like a missing permission and is not. Opening shared also means this app
coexists with the Input and Codex desktop apps rather than fighting them for
the device, though all three writing lighting at once will contend.
