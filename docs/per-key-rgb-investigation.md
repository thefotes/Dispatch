# Creator Micro 2: can a host app set per-key RGB?

A write-up of what I wanted to build, what I tried, and where it stopped.
Hardware: Creator Micro 2 Pro, connected over BLE. Firmware tested: **v0.4.0**
and **v0.6.0-rc.10**. Input app tested: **0.17.3** and **0.18.0-rc.8**.

## What I wanted to build

I run several coding agents in parallel in a terminal workspace manager. Each
agent is in one of a few states: working, blocked waiting on my input, idle, or
done. I wanted the pad to be a physical dashboard for them:

- one agent per key on the top six keys
- each key's colour showing that agent's live status
- pressing a key jumps my terminal to that agent's session

Essentially what the Codex Micro's Agent Keys do — idle / thinking / complete /
needs input / error — but driven by my own local tool instead of Codex.

## What works today

**Key presses → actions.** Trivial. The pad sends F13–F24; the host binds them.
Working end to end.

**Lighting, as two whole-device surfaces.** `lights.preview` over raw HID drives
`backlight` and `underglow` independently, and honours `effect`. Confirmed
visually: colours apply, the two surfaces are distinct, `rainbow` animates.

So I built the useful subset: one aggregate colour across both surfaces —
red-breathing when any agent needs me, amber while any is working, green when
all idle. That answers "does anything need me?" at a glance, which is most of
the value. It just isn't per-agent.

## What does not work: per-key colour

The LEDs are individually addressable in hardware, and the same firmware image
drives the Codex Micro's per-key Agent Keys. On a Creator Micro 2 I could not
reach them by any route.

### The transport (for reference)

JSON-RPC 2.0 over raw HID, usage page `0xFF00` / usage `1`:

```
byte 0      report id, 0x06
byte 1      channel: 1 = firmware debug log, 2 = JSON-RPC
byte 2      payload length in this report, <= 61
bytes 3..   UTF-8 fragment of the JSON message
```

Messages split across as many 64-byte reports as needed. Colours are
`0xRRGGBB` integers; `brightness`/`speed`/`magic` are 0..1 floats; call ids
must be < 1000. Note the device must be opened **non-exclusively** — its vendor
collection shares an `IOHIDDevice` with a keyboard collection, and macOS
refuses to let anyone seize a keyboard.

### What I tried

| # | Attempt | Result |
|---|---|---|
| 1 | `lights.preview` with `backlight` / `underglow` | **Works.** Two surfaces, one colour each. |
| 2 | `lights.preview` with `keys` / `ambient` sections | Accepted, no visible effect. |
| 3 | `v.oai.rgbcfg` — bare colour array, `keys.color`, `keys.colors`, `keys.leds`, `[{index,color}]`, `[{i,c}]` | Every shape returns `{"ok":1}`. No visible effect. |
| 4 | `v.oai.thstatus` — 8 payload shapes (per-slot arrays, indexed objects, `act`, `ag` maps, scalars) | Every shape returns `{"ok":1}`. No visible effect. |
| 5 | Bound the top six keys to `KV_OAI_AG00`..`AG05` via `fs.write` of `keymap.json`, then drove `v.oai.thstatus` again | Firmware **accepts and persists** the OAI keycodes. Still nothing lights. |
| 6 | Same as 5, with the key backlight pre-lit in case the bridge needs an active surface | No effect. |
| 7 | Read the device's own `keymap.json` | Lighting persisted as exactly `backlight` + `underglow` per layer. No per-key colour field exists. |
| 8 | Firmware debug channel (channel 1) while calling the above | Silent — no parse trace to learn from. |
| 9 | Input app 0.17.3 and 0.18.0-rc.8 | Both ship `wl-device-kit` 0.1.28, whose entire method list is `lights.preview` for lighting. No `v.oai.*` at all. |

### Why I think it is gated, not missing

- `v.oai.rgbcfg` and `v.oai.thstatus` **are** registered on this device — they
  return `{"ok":1}`, not `Method not found`.
- `v.oai.hid` and `v.oai.rad` return `Method not found` on the same device.

So the firmware registers **different handler sets per variant**, and this
variant gets stubs where the Codex Micro gets working ones. The handlers accept
any payload, including malformed ones, which is consistent with a no-op stub.

Board identity comes from eFuse, or from `/fs/board_info.json` when present
(`"%s not found, falling back to eFuse"`). That file does not exist on my
device. Writing one to declare a different vendor/variant is the only untried
lever, and I deliberately stopped there: the correct integers are undocumented,
and a wrong pair makes the pad identify as hardware it is not.

## The ask

1. Is there, or could there be, a supported way for a third-party host app to
   set per-key RGB on a Creator Micro 2 — a documented report format, an Input
   API, or a local socket?
2. If `v.oai.rgbcfg` / `v.oai.thstatus` are intentionally variant-gated, is
   there any prospect of a generic equivalent for non-Codex hardware?

Even a minimal, unsupported, "you're on your own" documented report format
would be enough. The hardware clearly does this already; only permission and a
schema are missing.

## Notes

Everything above was done against my own device for interoperability, using the
publicly downloadable firmware images and the shipped Input app. No firmware was
modified. The device keymap was backed up before any write and restored after.
