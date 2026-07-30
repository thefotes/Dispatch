# Work Louder Inspector

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

## Picking the right interface

Over Bluetooth the pad is a single `IOHIDDevice` whose *primary* usage is
keyboard, with the vendor collection listed alongside it in
`DeviceUsagePairs`. Over USB each interface is its own `IOHIDDevice`, so
matching on vendor id and taking the first hit lands on the keyboard, and every
report-id-6 write is silently dropped.

The app selects the device that actually carries usage page `0xFF00`, by
primary usage first and `DeviceUsagePairs` second, and logs which one it chose
on connect.

## Notes

The device is opened **non-exclusively**. Its vendor collection shares an
`IOHIDDevice` with a keyboard collection, and macOS refuses to let anything
seize a keyboard — a seizing open fails with `0xE00002C1`, which reads exactly
like a missing permission and is not. Opening shared also means this app
coexists with the Input and Codex desktop apps rather than fighting them for
the device, though all three writing lighting at once will contend.
