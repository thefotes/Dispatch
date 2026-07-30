# herdr-worklouder-micro

A [Herdr](https://herdr.dev) plugin that connects a Work Louder **Creator Micro 2**
to your running coding agents:

- the pad's light reflects agent status, so you can tell at a glance whether
  anything needs you
- the top six keys jump straight to agents 1-6 in Herdr

## Per-key colours: solved

**Each key can be set individually.** The channel is a vendor RPC the Input app
never calls, recovered from `@worklouder/device-kit-oai` - a *different* SDK that
ships inside the Codex desktop app.

```
v.oai.thstatus   params = ARRAY of { id, c, b, e, s, sk, sa }
v.oai.rgbcfg     params = { ambient: {e,b,s,m,c}, keys: {e,b,s,m,c} }
```

| field | meaning |
|---|---|
| `id` | key index, **0-based, row-major** over the pad's `[2,4,4,3]` matrix |
| `c` | packed RGB integer |
| `b` | brightness, 0..1 |
| `e` | effect **as a number**: 0 off, 1 solid, 2 snake, 3 rainbow, 4 breath, 5 gradient, 6 shallowBreath |
| `s` | speed, 0..1 |
| `sk` / `sa` | 1/0 - mirror this thread onto the keys / ambient zone |

Two things make this easy to miss, and both cause silent no-ops rather than
errors, because the firmware answers `{"ok":1}` to any payload including
malformed ones:

1. **Field names are abbreviated on the wire.** `c`/`b`/`e`/`s`/`m`, not the full
   names `lights.preview` uses.
2. **`effect` is an integer**, not one of the effect strings `lights.preview` takes.

Verified on hardware (firmware v0.6.0-rc.10): sending one thread lit and the
rest off lights exactly one key, and walking a single lit thread through ids
0..12 moves one lit key across the pad. Thread ids 1..6 light keys 1..6 and
leave key 0 dark, confirming 0-based indexing. Sync flags are optional - colours
apply without them. **Thread state overrides the zones**, so turning the pad off
means clearing threads *and* zones (see `bin/lights-off.js`).

Also useful: `v.oai.hid` and `v.oai.rad` are device-to-host **notifications**, not
callable methods - key events (`{k, act, ag}`) and joystick position (`{a, d}`).

### The keymap is not optional

A key can only be lit if it is bound to a `KV_OAI_AG*` keycode **on the active
layer**. Parking the codes on a spare layer does nothing. Nothing reports the
mismatch: `v.oai.thstatus` still answers `{"ok":1}` for a key it cannot light,
so a wrong keymap is indistinguishable from a working one from the host side.

The trade-off is real: **an AG-bound key stops being an input.** It sends no
keystroke, and on this variant it pushes no `v.oai.hid` notification either. A
key is a status light or an input, not both.

This plugin binds the top six keys (rows 1-2) and leaves rows 3-4 alone, so
those still send `KC_F19`..`KC_F24` if you want them for shortcuts.

### What did not work

For the record, since these cost time: `lights.preview` with `keys`/`ambient`
sections; any full-field-name payload to `v.oai.rgbcfg`; AG keycodes on a
non-active layer; and both Input app versions, which ship only
`lights.preview`.

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

`bin/leds.js` is a long-running bridge. It gives **each agent its own key** and
keeps an aggregate on the underglow:

| agent status | its key |
|---|---|
| blocked / waiting on you | red, breathing |
| working | amber |
| idle or done | green |
| no agent in that slot | off |

Agent slot N takes key N — the same physical keys that send F13–F18, so the key
you look at is the key you press. The **underglow** carries the worst state
across all agents, so "does anything need me?" is readable from across the room
without counting keys.

Set `drive_backlight: true` to also wash the key *zone* with the aggregate
colour, though it competes with the per-agent colours.

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

The bridge binds them on startup (`manage_keymap: true`). To do it by hand:

```bash
node bin/apply-ag-keymap.js     # bind the six agent keys for lighting
node bin/restore-keymap.js      # put your original keymap back
```

Slots are ordered by workspace, then tab, then pane, so a key keeps pointing at
the same agent as long as the set of agents does not change:

```bash
herdr agent list
```

### Jumping to an agent

The six lit keys **cannot** also send keystrokes — see the trade-off above — so
there are no key bindings for them. If you want to jump from the pad, use rows
3-4, which still send `KC_F19`..`KC_F24`, bound to the plugin actions in
`~/.config/herdr/config.toml`:

```toml
[[keys.command]]
key = "f19"
type = "plugin_action"
command = "worklouder.micro.focus1"
description = "focus agent 1"
```

Or drive it from the keyboard with Herdr's own `next_agent` / `previous_agent`
bindings. The six `focus1`..`focus6` actions stay available either way.

## Known conflict

Work Louder's Input app drives the underglow from the focused desktop app
("AppSense" colour cues), and the Codex desktop app drives the same vendor
thread API this plugin uses. Either will fight the bridge for the lighting.
Quit them, or turn those features off, while using the bridge.

## Tests

```bash
npm test
```

Covers the status-to-colour mapping, per-key thread assignment, config merging,
slot ordering, and colour encoding — everything that does not need hardware.

Hardware-in-the-loop tools:

| command | purpose |
|---|---|
| `npm run probe` | which RPC methods this firmware registers |
| `node bin/oai-test.js` | exercise the per-key API end to end |
| `node bin/interactive-lab.js` | 12 lighting experiments, prompting after each |
| `node bin/lights-off.js` | clear threads *and* zones |
| `node bin/restore-keymap.js` | put `backup/keymap.json` back on the device |

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
