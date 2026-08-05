# Micro Manager

A macOS menu-bar app that lights each running [Herdr](https://herdr.dev) agent
on its own key of a Work Louder
**[Creator Micro 2](https://worklouder.cc/creator-micro-2)**, and jumps to that agent
when you press the key.

It is the bridge itself — no Node, no daemon, nothing to install on the Herdr
side. It reads Herdr's socket directly and drives the pad over raw HID.

**[Download the latest release](https://github.com/schacon/micro-manager/releases/latest/download/MicroManager.zip)**
· [website](https://schacon.github.io/micro-manager/)
· [hacking guide](docs/hacking.md)

---

## Install

Download, unzip, drag `MicroManager.app` to Applications, and launch it. macOS
will ask for **Input Monitoring** — grant it, then toggle the manager off and on
from the menu-bar panel so it reconnects with the permission.

Or build it yourself:

```bash
./scripts/bundle.sh --install     # build, sign, install to /Applications, launch
```

You will also need a Creator Micro 2 and a running Herdr server with agents in
it. Quit Work Louder's Input app and the Codex desktop app while you use this —
all three drive the same lighting and will overwrite each other.

## What the pad does

**The icon** shows state at a glance: dimmed when off, a coloured dot when
running — green all idle, amber something working, red something needs you —
and a badge when the pad is missing or permission is denied.

**The top six keys** are one agent each, in the order Herdr's own panel lists
them. Colours are red (blocked, breathing), amber (working), blue (done —
finished but not yet looked at) and green (idle — finished and seen). Herdr
distinguishes done from idle by whether you have focused the pane yet, so blue
means something is waiting to be read and green means quiet. The **underglow**
carries the worst state across all agents, so "does anything need me?" is
readable from across the room.

Pressing an agent key focuses that agent in Herdr **and brings the terminal
forward** — Herdr selects the pane but leaves the window where it was, so an
agent key pressed from a browser used to move a cursor you could not see. Set
`WL_TERMINAL_BUNDLE_ID` if your panes do not live in Ghostty.

**Row 3** is actions:

| key | what it does |
|---|---|
| stack | floats the GitButler stack for the focused agent |
| tabs | cycles the tabs of the focused Herdr window |
| land | lands the focused agent's branches, bottom first |
| macro | types a configured string into the agent's prompt |

**Row 4** is the wide key — voice input for the focused agent — and one more
macro key.

**The dial** tunes reasoning effort. **The joystick** switches model: it puts
the model list on screen, north and south move, east confirms, west cancels.

### The stack key

It floats `but status` in the middle of the screen; press again to put it away.
The window never takes focus — you are reading it *from* the terminal you were
already typing in, and a read-only view that steals the keyboard would cost two
keystrokes to undo. Click the output to select text, click anywhere else to
dismiss.

`but` is found by search, not by `PATH`: an app launched by launchd inherits
`/usr/bin:/bin:/usr/sbin:/sbin`, so the binary your terminal finds instantly is
invisible here. Homebrew and Cargo locations are checked directly, then your
login shell is asked. Set `WL_BUT_PATH` to skip all of it.

## The panel

Click the menu-bar icon. It draws the pad in its real shape with every key
showing its live colour, then one row per agent. Click a key or a row to jump to
that agent. It also carries the on/off switch, an "Open at login" toggle, a
warning when another app is fighting for the device, and the **Inspector**
button.

**Off** clears the lights and stops driving, but deliberately leaves the device
keymap alone: rebinding is a flash write, and the keys light instantly on the
way back in if the bindings are still there.

## The Inspector

The debug UI ships inside the app — the **Inspector** button in the panel opens
it. It logs every message in both directions (`TX`, `RX`, `NOTIFY`, `DEVICE`),
decodes the device's abbreviated notifications, and drives the lighting by hand:
per-key colours and effects, the two zones, a key walk, and a raw JSON-RPC
console with presets.

It lives at `MicroManager.app/Contents/Library/Inspector.app`, signed by the
same identity as its host, so it is one download and one trust decision. During
development there is no surrounding bundle, so run it directly:

```bash
swift run WLInspector
```

Run that **from your terminal**, not from Finder: macOS attributes Input
Monitoring to the responsible process, so a terminal that already has the grant
passes it on.

## No pad to hand

Tick **Emulate the pad** in the panel and a window opens with a virtual Creator
Micro 2 in it. The bridge drives its lights exactly as it drives the hardware,
and clicking a key — or the dial, or the joystick — sends the same
`v.oai.hid` report back, so the whole loop works with nothing plugged in.

```bash
WL_EMULATE=1 swift run WLMicroManager    # start emulated, no clicking required
```

It is a stand-in for the firmware rather than a picture of one, and it
reproduces the firmware's more awkward habits deliberately, because those are
the ones that cost time on real hardware:

- it answers `{"ok":1}` to any lighting payload, right or wrong;
- it boots on the **stock F-key keymap**, so the app has to bind the keys
  before anything can light — and a key that is not bound to `KV_OAI_AG*`
  accepts its colour in silence and stays dark;
- an unbound key reports nothing when pressed, because on the pad it would be
  sending a keystroke instead.

The window also shows the RPC traffic, and **Reset** puts a factory pad back.

The emulator lives inside the app, so it stands in for the device for Micro
Manager only — the Inspector is a separate process and still needs hardware.

## Configuration

Everything works without a config file. To rebind the macro keys or change what
the dial and joystick offer, drop a `config.json` into
`~/.config/micromanager/`:

```json
{
  "keys": {
    "9":     "Open PRs for all active GitButler branches",
    "12":    "Run but pull",
    "10+11": "Summarise what you are working on"
  },
  "claude": { "models": ["fable", "opus"], "efforts": ["low", "high"] },
  "codex":  { "models": ["gpt-5.6-sol", "gpt-5.6-codex"] }
}
```

A bound string is injected into the focused agent's prompt, unsubmitted — you
still read it and press enter. `"10+11"` addresses the wide key as one; `"10"`
and `"11"` address its halves. Keys the file does not mention keep their
defaults, and an empty string unbinds a key outright. Binding the wide key to
text replaces its voice role.

`codex.models` is your copy of what Codex's own `/model` menu offers, in its
order — the joystick steers that menu rather than owning it, so there is nothing
to read it from.

| variable | what it overrides |
|---|---|
| `WL_TERMINAL_BUNDLE_ID` | the terminal to raise (default Ghostty) |
| `WL_BUT_PATH` | the GitButler binary, skipping the search |
| `HERDR_SOCKET_PATH` | the Herdr socket |
| `WL_SIGN_IDENTITY` | the signing identity `bundle.sh` uses |

## Why it must be bundled and signed

`swift run` works for development because it inherits your terminal's Input
Monitoring grant. A background app needs its own, and macOS keys that grant to
the **code signature** — so an ad-hoc signature, whose hash changes on every
build, forces you to re-grant after every rebuild. `bundle.sh` prefers a real
Apple Development or Developer ID identity from your keychain, which gives a
stable designated requirement and makes the grant stick. It also sets
`LSUIElement` so there is no Dock icon, and gives `SMAppService` a bundle it
will actually register as a login item.

Released builds are Developer ID signed and notarized by
[the release workflow](.github/workflows/release.yml), which lists the repository
secrets it needs.

## Only one bridge at a time

Work Louder's Input app and the Codex desktop app drive this same pad. Running
two at once means they overwrite each other. The panel detects this — the device
is opened shared, so we receive other clients' replies, and a response id we
never issued is a reliable tell.

## Development

```bash
swift build            # both apps and the shared library
swift test             # live tests skip themselves without hardware
swift run WLInspector  # the debug UI
./scripts/bundle.sh    # assemble build/MicroManager.app, unsigned install
```

| | |
|---|---|
| `Sources/WLKit` | device transport, vendor protocol, Herdr client, bridge engine |
| `Sources/WLMicroManager` | the menu-bar app and its panels |
| `Sources/WLInspector` | the debug UI |
| `docs/hacking.md` | how the pad protocol works, and how to drive it yourself |
| `docs/index.html` | the website, served by GitHub Pages from `docs/` |

The device protocol — raw-HID JSON-RPC, per-key colour, key and joystick events,
and the keymap binding that makes per-key lighting possible at all — is written
up in full in **[docs/hacking.md](docs/hacking.md)**.

---

An independent interoperability tool for hardware I own. Not affiliated with
Work Louder.
