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

**Row 3** is actions — all four are overridable from `config.json`, stack/tabs/land included:

| key | what it does |
|---|---|
| stack | floats the GitButler stack for the focused agent |
| tabs | cycles the tabs of the focused Herdr window |
| land | lands the focused agent's branches, bottom first |
| macro | types a configured string into the agent's prompt |

**Row 4** is the wide key — it taps right command, which starts and stops
Superwhisper — and one more
macro key.

**The dial** tunes reasoning effort by default; the `"dial"` config key can
point it at Herdr navigation instead — stepping the focused agent, tab, or
workspace. **The joystick** switches model: it puts the model list on screen,
north and south move, east confirms, west cancels.

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
    "10+11": "Summarise what you are working on",
    "6":     { "shortcut": "cmd+shift+5" },
    "7":     { "shortcut": "f13" }
  },
  "dial":   "effort",
  "claude": { "models": ["fable", "opus"], "efforts": ["low", "high"] },
  "codex":  { "models": ["gpt-5.6-sol", "gpt-5.6-codex"] }
}
```

A bound string is injected into the focused agent's prompt, unsubmitted — you
still read it and press enter. A key can be bound to a keyboard shortcut
instead — `{ "shortcut": "cmd+shift+5" }` — which is synthesised system-wide
regardless of what Herdr is doing: launch an app's own hotkey, take a
screenshot, trigger Mission Control, anything a physical key combo can do.
Modifiers (`cmd`/`command`, `shift`, `opt`/`option`/`alt`, `ctrl`/`control`) go
in any order, `+`-joined, with exactly one base key — a letter, digit, named
punctuation key (`equal`, `minus`, `comma`, …), or a named key (`space`,
`tab`, `return`, `escape`, `delete`, `up`/`down`/`left`/`right`, `f1`–`f19`).
An unrecognised shortcut string does nothing and reports itself as an error
the next time you press that key. A synthesised shortcut needs the
**Accessibility** permission, same as the wide key's right-command tap.

`"10+11"` addresses the wide key as one; `"10"` and `"11"` address its
halves. **Every spare key is overridable this way, including the stack (6),
tabs (7), and land (8) keys** — binding one replaces its built-in job
entirely. Keys the file does not mention keep their defaults: 9 and 12 type
their text macros, the wide key taps right-command, and 6/7/8 stay
stack/tabs/land. To unbind a key outright, back to nothing, bind it to
`false`. An empty string (or `{"shortcut": ""}`) is a no-op — the key
keeps its default, matching how older configs behaved.

`"dial"` sets what the knob does. `"effort"` (the default) climbs the
reasoning-effort ladder for the focused agent; `"agent"` steps focus through
the agents in sidebar order; `"tab"` cycles the tabs of the focused workspace;
`"space"` (or `"workspace"`) steps through workspaces. All four wrap at the
ends and follow the turn direction. An unrecognised value falls back to
`"effort"`.

`codex.models` is your copy of what Codex's own `/model` menu offers, in its
order — the joystick steers that menu rather than owning it, so there is nothing
to read it from.

### Providers

Herdr is not wired into the app directly: `BridgeController` talks to a small
`Provider` protocol (agent status, focus, dial navigation, prompt injection),
and Herdr is the one implementation shipped today (`HerdrProvider`), running
in-process by default. A `"provider"` object in `config.json` swaps it for one
reached over a socket instead — the same JSON-RPC-over-Unix-socket shape
Herdr's own API already uses:

```json
{ "provider": { "connect": "/path/to/a/running/bridge.sock" } }
```

for a provider already running (Herdr's own pattern — it always runs a
server), or

```json
{ "provider": { "launch": "provider-bridge", "args": [] } }
```

for one Micromanager should start itself and terminate on quit. This repo
ships `provider-bridge`, a standalone binary that wraps `HerdrProvider` behind
a socket server — proof the protocol does not need to run in-process, useful
for running Micromanager and its Herdr integration as separate processes, or
as a template for a non-Herdr provider written in any language. A `"provider"`
change needs a full relaunch, not just an off/on toggle — unlike the rest of
this file, it is read once at launch. Unmentioned (the ordinary case) keeps
the in-process default.

| variable | what it overrides |
|---|---|
| `WL_TERMINAL_BUNDLE_ID` | the terminal to raise (default Ghostty) |
| `WL_BUT_PATH` | the GitButler binary, skipping the search |
| `HERDR_SOCKET_PATH` | the Herdr socket |
| `WL_PROVIDER_BRIDGE_SOCKET` | where `provider-bridge` listens / `RemoteProvider` connects |
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

Every push to main republishes the **`latest`** release, so the download link
above always points at the current build; tagging `v*` cuts a permanent
versioned release alongside it. Both go through
[the release workflow](.github/workflows/release.yml).

That workflow signs with a Developer ID and notarizes when the repository has
the secrets for it — the file lists them — and falls back to an ad-hoc
signature when it does not, rather than failing. An ad-hoc build works, but
macOS stops it until you right-click → Open, and because the grant is keyed to
the signature and an ad-hoc one changes every build, Input Monitoring has to be
granted again after each update. The release notes say which kind you are
downloading.

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
