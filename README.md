# herdr-worklouder-micro

A [Herdr](https://herdr.dev) plugin that connects a Work Louder **Creator Micro 2**
to your running coding agents:

- the pad's light reflects agent status, so you can tell at a glance whether
  anything needs you
- the top six keys jump straight to agents 1-6 in Herdr

## Per-key colours: investigated, not available

Short version: **the host cannot address individual keys on a Creator Micro 2.**
The pad exposes exactly two controllable lighting surfaces. This was worth
chasing hard, because the hardware really does have per-key LEDs and the
firmware really does contain an agent-status bridge — neither is reachable.

What the hardware has: QMK's v1 Creator Micro board declares an `rgb_matrix`
of 12 positioned per-key LEDs plus 8 underglow. The LEDs exist.

What the firmware contains, found by pulling `cm-v2-fw-releases` and reading
its strings:

| method | notes |
|---|---|
| `lights.preview` | sections `backlight` + `underglow`, one `{effect,brightness,speed,magic,color}` each |
| `v.oai.rgbcfg` | same vocabulary plus sections **`keys`** and **`ambient`** |
| `v.oai.thstatus` | `"OAI BRIDGE: init, ... registered on all variants"` (`src/oai/wl_oai_bridge.cpp`), alongside `syncKeysLighting` / `syncAmbientLighting` |
| `v.oai.hid`, `v.oai.rad` | not registered on this variant |

`oai` is OpenAI — this is the Codex Micro's integration, shipped in the same
image. Its default profile maps the top six keys to `KV_OAI_AG00`..`AG05`
(`AG` is *action group*, not *agent*).

Tested against real hardware on firmware **v0.6.0-rc.10**:

- `v.oai.rgbcfg` is registered but **inert** on the Creator Micro 2 — it
  answers `{"ok":1}` to every payload, including malformed ones, and changes
  nothing visible under any of the per-key encodings tried.
- `v.oai.thstatus` behaves the same way. `v.oai.hid` / `v.oai.rad` return
  `Method not found`.
- `lights.preview` with `backlight`/`underglow` **works**: the two surfaces are
  independent and `effect` is honoured (rainbow animates).
- The device's own `keymap.json` persists lighting as exactly those two
  surfaces per layer, with no per-key colour field.

Everything tried, and what it showed:

| avenue | result |
|---|---|
| `lights.preview` (`backlight`/`underglow`) | **works** — two independent surfaces, effects honoured |
| `v.oai.rgbcfg`, every per-key encoding | registered, accepts anything, **no visible effect** |
| `v.oai.thstatus`, 8 payload shapes | registered, accepts anything, **no visible effect** |
| `v.oai.thstatus` + top six keys bound to `KV_OAI_AG00..AG05` | firmware **accepts and persists** the OAI keycodes; still **nothing lights** |
| `v.oai.hid`, `v.oai.rad` | `Method not found` — so handler sets really do differ by variant |
| device `keymap.json` | lighting persisted as exactly two surfaces per layer |
| Input app 0.17.3 **and** 0.18.0-rc.8 | identical `wl-device-kit` 0.1.28, `lights.preview` only, no `v.oai.*` |
| public docs / forum | no API; an unanswered feedback post asks exactly this |

The LEDs are individually addressable in hardware — the Codex Micro shows five
per-key agent states (idle, thinking, complete, needs input, error) from the
same firmware image. On the Creator Micro 2 that path is gated off by board
identity, which the firmware reads from eFuse (or `/fs/board_info.json`, which
does not exist on this device). The remaining untried lever is writing that file
to declare a different vendor/variant; it is deliberately not attempted here,
because the correct integers are unknown and a wrong pair makes the pad identify
as hardware it is not.

The probe tools are kept so this can be re-checked on future firmware:

```bash
npm run probe          # which methods exist, and what they answer
node bin/lighttest.js  # visual: does lights.preview reach the pad
node bin/keytest.js    # visual: can individual keys ever differ
```

If a later firmware makes `v.oai.rgbcfg` live, `bin/leds.js` can be extended to
light one key per agent instead of one aggregate colour.

## Requirements

- Node 18+
- A running Herdr server (`herdr status`)
- **macOS:** Input Monitoring permission for whatever process runs the bridge
  (System Settings → Privacy & Security → Input Monitoring). Without it, opening
  the HID interface fails with `privilege violation`.
- **Linux:** a udev rule granting access to the `303a:` HID device.

## Install

```bash
npm install --omit=dev
herdr plugin link /path/to/herdr-worklouder-micro
```

## The status light

`bin/leds.js` is a long-running bridge. It watches Herdr and pushes a colour to
both the key backlight and the underglow:

| condition | colour |
|---|---|
| any agent blocked / waiting on you | red, breathing |
| else any agent working | amber |
| else agents running but idle | green |
| no agents | off |

Worst state wins, because with one colour the useful question is "does anything
need me?". Set `drive_backlight: false` to leave the key backlight alone and
use only the underglow.

Run it in a pane to watch it work:

```bash
herdr plugin pane open worklouder.micro.leds
```

Or in the background (see `launchd/` for a macOS agent). To develop without the
hardware present:

```bash
WL_FAKE_DEVICE=1 npm run leds
```

### Configuring colours

Drop a `config.json` into the plugin's config dir
(`herdr plugin config-dir worklouder.micro`):

```json
{
  "colors": { "blocked": "#FF0055", "working": "#FFAA00", "idle": "#003311" },
  "brightness": 0.6,
  "drive_backlight": true
}
```

Keys you omit keep their defaults. `priority` reorders which state wins.

## The six keys

Map the pad's top six keys to **F13-F18** in Work Louder's Input app, then bind
them in `~/.config/herdr/config.toml`:

```toml
[[keys.command]]
key = "f13"
type = "plugin_action"
command = "worklouder.micro.focus1"
description = "focus agent 1"

# ... f14 -> focus2, through f18 -> focus6
```

Slots are ordered by workspace, then tab, then pane, so a key keeps pointing at
the same agent as long as the set of agents does not change. Check the current
mapping with:

```bash
herdr agent list
```

## Known conflict

Work Louder's Input app drives the underglow from the focused desktop app
("AppSense" colour cues). If it is running it will fight this bridge for the
light. Turn that feature off, or quit Input, while using the bridge.

## Tests

```bash
npm test
```

Covers the status-to-colour mapping, config merging, slot ordering, and colour
encoding — everything that does not need hardware.

## Protocol notes

The device speaks JSON-RPC 2.0 over raw HID on usage page `0xFF00`, usage `1`:

```
byte 0      report id, always 0x06
byte 1      channel: 1 = firmware debug log, 2 = JSON-RPC
byte 2      payload length in this report, <= 61
bytes 3..   UTF-8 fragment of the JSON message
```

Requests are split across as many 64-byte reports as needed; responses are
reassembled by scanning for balanced braces. Colours go on the wire as a
`0xRRGGBB` integer; `brightness`, `speed`, and `magic` are 0..1 floats. Call ids
must be under 1000.
