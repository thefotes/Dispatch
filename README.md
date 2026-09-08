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

**The icon** shows state at a glance: dimmed when off, a colored dot when
running — green all idle, amber something working, red something needs you —
and a badge when the pad is missing or permission is denied.

**The top six keys** are one agent each, in the order Herdr's own panel lists
them. Colors are red (blocked, breathing), amber (working), blue (done —
finished but not yet looked at) and green (idle — finished and seen). Herdr
distinguishes done from idle by whether you have focused the pane yet, so blue
means something is waiting to be read and green means quiet. The **underglow**
carries the worst state across all agents — red beats blue beats amber beats
green — so "does anything need me?" is readable from across the room.

Herdr often has more than six agents (one per pane, across every workspace),
and the extra ones fall off the end of the key row. By default that end is
"whatever sorted past the sixth slot" in Herdr's order. Set `"agent_keys":
"priority"` in `config.json` to instead light the six that most want
attention — a blocked or unread agent keeps a key even when a quiet one would
have taken it. The trade-off is that a key then points at a different agent
as statuses change, which is why it is off by default.

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
workspace. **The joystick** moves pane focus, the same moves Herdr's own
prefix+h/j/k/l make: north is up, south is down, east is right, west is
left. It wraps at the edges of the layout — deflecting off the last pane of
a tab lands on the first.

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
showing its live color, then one row per agent. Click a key or a row to jump to
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
per-key colors and effects, the two zones, a key walk, and a raw JSON-RPC
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
  accepts its color in silence and stays dark;
- an unbound key reports nothing when pressed, because on the pad it would be
  sending a keystroke instead.

The window also shows the RPC traffic, and **Reset** puts a factory pad back.

The emulator lives inside the app, so it stands in for the device for Micro
Manager only — the Inspector is a separate process and still needs hardware.

## Configuration

Everything works without a config file. To rebind the macro keys or change what
the dial offers, drop a `config.json` into `~/.config/micromanager/`. The
joystick is not configurable — it moves pane focus through the active provider:

```json
{
  "keys": {
    "9":     "Open PRs for all active GitButler branches",
    "12":    "Run but pull",
    "10+11": "Summarize what you are working on",
    "6":     { "shortcut": "cmd+shift+5" },
    "7":     { "shortcut": "f13" }
  },
  "dial":   "effort",
  "claude": { "efforts": ["low", "high"] }
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
An unrecognized shortcut string does nothing and reports itself as an error
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
reasoning-effort ladder for the focused agent — the one mode built into
Micromanager itself. Any other name is handed to the active provider
as-is; with the default Herdr provider that's `"agent"` (steps focus
through the agents in sidebar order), `"tab"` (cycles the tabs of the
focused workspace), or `"space"`/`"workspace"` (steps through workspaces),
all wrapping and following the turn direction. A name the active provider
doesn't recognize falls back to `"effort"` and says so in the panel, the
same way an unrecognized shortcut does.

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

Writing your own provider — in Swift or anything else — is documented in
**[docs/provider-protocol.md](docs/provider-protocol.md)**, alongside
[`examples/reference-provider.py`](examples/reference-provider.py): a
complete second implementation in dependency-free Python, under 150 lines,
proving the protocol is not Swift-specific.

### Multiple Herdr instances

The pad can talk to more than one Herdr server at once — a local one and a
remote one, say. List them under `"herdr": {"instances": [...]}`; absent or
empty keeps the single default instance every older config already uses:

```json
{
  "herdr": {
    "tools": ["opencode", "claude", "codex"],
    "instances": [
      { "id": "local",  "name": "Mac Mini", "socket_path": "~/.config/herdr/herdr.sock" },
      { "id": "jarvis", "name": "Jarvis",   "socket_path": "$TMPDIR/jarvis-herdr.sock" }
    ]
  }
}
```

With two or more instances:

- The underglow reflects **both** machines — an agent going red on either box
  turns it red, no matter which one you are looking at.
- Pad input (agent keys, dial, joystick, macros, provider actions) goes to
  whichever instance's terminal window is frontmost. Detection uses
  **Accessibility** (already required for the wide key) to tell two Ghostty
  windows apart; without that grant it degrades to manual switching. Under
  Herdr 0.9, which groups every machine into one window, there are no two
  windows to tell apart — so detection cannot fire and switching is manual.
- The `{"action": "herdr.next_instance"}` binding flips between instances by
  hand. On 0.9 it is not a fallback but **the** way to change which machine
  the pad drives, so bind it if you run more than one.
- `"agent_keys"` defaults to `"priority"` once a second instance is
  configured, and to `"sidebar"` before that. This matters: the pad has six
  agent key slots, the merged list is active-instance-first, and a machine
  with six or more agents would otherwise take every slot and leave the
  other machine dark. Priority order keeps what needs attention on the keys
  no matter which box it is on. Set `"agent_keys"` explicitly to override.
- Six keys is a real ceiling. With two busy machines the **underglow** is
  the only thing that sees every agent; the keys show the best six.
- A dead remote never blanks the local pad: its agents drop out and the
  panel names the failure, while the local instance keeps working.

### What does not work on Herdr 0.9

Reading across machines works. **Navigating** to another machine does not,
and cannot be fixed from this side.

0.9's socket API has no concept of a machine — 111 methods, not one of them
machine-aware — and the sidebar's machine grouping is client-side state with
no API surface. Focus is per-server, so both servers report a focused entity
at once. A remote `agent.focus` or `workspace.focus` succeeds and moves that
server's focus, but nothing can ask the client to switch the machine it
displays. The command lands; the window never follows.

That affects two things:

- **Remote agent keys.** A key bound to an agent on another machine lights
  correctly and issues the right call, but will not bring that agent on
  screen.
- **The cross-machine dial**, which is therefore **off by default**. Turn it
  on with `"herdr": {"dial_crosses_machines": true}` and a turn past the end
  of the active machine's spaces (or agents) spills onto the next machine in
  config order, landing on its first entry — backwards walks the other way
  onto the previous machine's last. Tab cycling never crosses. With it off,
  the dial stays within the active machine, which is what you want until the
  view can follow: otherwise the turn changes a machine you cannot see and
  reads as a dial that did nothing.

`docs/herdr-machine-focus-request.md` is the upstream request that would
unblock both. When it lands, the flag becomes the default.

A remote instance's socket has to be forwarded locally before the app can
speak to it. Herdr 0.9 already forwards one per machine, at
`$TMPDIR/herdr-ssh-<client-pid>-<machine-id>.sock` (the id is the one
`herdr machine list` prints) — but the client pid is in the path, so it
changes every restart and cannot be written into `config.json`.
`scripts/herdr-tunnel.sh` gives you a **stable** path instead, and keeps it
up across sleep, restarts, and SSH drops as a LaunchAgent:

```bash
./scripts/herdr-tunnel.sh --install jarvis
# forwards jarvis:$HOME/.config/herdr/herdr.sock to $TMPDIR/herdr-jarvis.sock,
# then prints the "instances" entry to paste into config.json
```

The one-command alternative, without keepalive:

```bash
ssh -f -N -o ExitOnForwardFailure=yes \
  -L "${TMPDIR}jarvis-herdr.sock:/home/you/.config/herdr/herdr.sock" jarvis
```

Keep forwarded sockets under `$TMPDIR` — macOS caps Unix socket paths at 104
bytes, so a path under the repo will fail to connect.

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

## When the pad stops responding

Lit but inert — the dial and keys do nothing, usually after a sleep/wake.

**The app handles this itself now, and should need nothing from you.** It
closes the HID session on the way into a sleep and opens a fresh one on the way
out, a heartbeat catches any other kind of wedge within ~15 s, and a session
that opens but does not answer is refused rather than reported as connected —
which is what used to make toggling the bridge off and on useless while a quit
and relaunch "fixed" it. Where the pad is on USB and also paired over
Bluetooth, the cable wins; the Bluetooth node is the one that comes back from a
sleep opening happily and answering nothing.

So if the panel says connected, it has had an answer out of the pad. If it says
disconnected, it will keep retrying every 3 s and will name what it last saw.

That leaves the case the app cannot fix from inside: a session wedged
kernel-side. The panel names the error; if it ends in `0xE00002E2`, that is
`kIOReturnNotPermitted`, which means either Input Monitoring is not granted or
the session has wedged.

If Input Monitoring is already granted, it is a wedged session, and **only
restarting the Mac clears it**. Power-cycling the pad, toggling Bluetooth,
re-pairing, switching to USB and replugging the cable have all been tried and
none of them work — the state survives re-enumeration on either transport. Quit
Work Louder Input and the Codex app first in case one of them is simply holding
the pad, try one replug, then restart.

Full write-up, including how to confirm the fix took:
**[docs/hacking.md §14](docs/hacking.md#14-when-the-pad-stops-responding)**.

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

The device protocol — raw-HID JSON-RPC, per-key color, key and joystick events,
and the keymap binding that makes per-key lighting possible at all — is written
up in full in **[docs/hacking.md](docs/hacking.md)**.

---

An independent interoperability tool for hardware I own. Not affiliated with
Work Louder.
