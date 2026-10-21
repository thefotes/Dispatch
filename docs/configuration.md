# Dispatch configuration

Dispatch reads versioned JSON from `~/.config/dispatch/config.json`. If the
file is missing, the menu-bar application writes its default configuration.
Reload is atomic: an invalid edit is reported and the last valid bindings stay
active.

Unknown fields, unknown actions, missing arguments, wrong argument types, empty
macros, overlapping bindings, and keys the pad does not have are errors. This strictness catches spelling
mistakes instead of silently changing a physical control's behavior.

## Shape

Each binding matches one logical control and gesture, then invokes one or more
actions in order:

```json
{
  "version": 1,
  "bindings": [
    {
      "when": {
        "control": { "type": "key", "index": 12 },
        "gesture": { "type": "pressed" }
      },
      "actions": [
        {
          "id": "keyboard.shortcut",
          "arguments": {
            "key": "k",
            "modifiers": ["command", "shift"]
          }
        }
      ]
    }
  ]
}
```

Logical controls are:

- `{ "type": "key", "index": N }`, where N is 0 through 10 or 12
- `{ "type": "dial" }`
- `{ "type": "joystick" }`

Keys are numbered in reading order, as in the README's
[layout diagram](../README.md#default-controls). The wide key on the bottom row
spans two switches and is key 10, so there is no key 11.

Gesture patterns are:

- `{ "type": "pressed" }`
- `{ "type": "released" }`
- `{ "type": "rotated", "direction": "clockwise" }`
- `{ "type": "rotated", "direction": "counterclockwise" }`
- `{ "type": "rotated" }` for either direction
- `{ "type": "moved", "direction": "up" }`, with `down`, `left`, and
  `right` also supported
- `{ "type": "moved" }` for any joystick direction

Only one binding may match a particular event. Put several entries in one
`actions` array to create an ordered macro.

## Built-in actions

Herdr semantic actions resolve live identifiers from the newest session
snapshot:

- `herdr.agent.focusSlot` — integer `slot`, one-based; agents take slots in
  `statusPalette.ambientPriority` order (see [Status colors](#status-colors))
- `herdr.pane.closeFocused` — no arguments
- `herdr.pane.focusDirection` — string `direction`; optional string `paneID`
- `herdr.pane.sendKeys` — non-empty array of non-empty strings `keys`; optional
  string `paneID`. Sends the keys in order over Herdr's socket. Without `paneID`,
  takes a fresh snapshot at press time and targets Herdr's focused pane. An
  explicit `paneID` targets that pane without changing focus.
- `herdr.tab.cycle` — signed integer `delta`
- `herdr.workspace.create` — no arguments; creates a workspace and focuses it
- `herdr.pane.splitFocused` — string `direction`: `right` (side by side) or
  `down` (stacked); focuses the new pane
- `herdr.pane.cycleText` — non-empty array of strings `options`; types the
  next option into the focused pane. A repeated press erases the option it
  typed and types the next one, but only while the pane's last line still ends
  with that option, so submitted or hand-typed text is never erased.

Herdr window actions move through the lists in Herdr's own window, which span
Local and every connected SSH machine:

- `herdr.agent.cycle` — signed, nonzero integer `delta`
- `herdr.workspace.cycle` — signed, nonzero integer `delta`

Herdr 0.9.1 has no API for its window, so Dispatch brings the configured
terminal forward and presses the key that Herdr binds to each step. Ghostty is
the default. To use another terminal, add its macOS bundle identifier at the
top level of `config.json`, for example:

```json
{
  "version": 1,
  "bindings": [],
  "integrations": {
    "herdr": { "terminalBundleIdentifier": "com.apple.Terminal" }
  }
}
```

Keep your existing `bindings` when adding the `integrations` property.
Invalid identifiers are rejected with a diagnostic naming
`integrations.herdr.terminalBundleIdentifier`; the previous valid configuration
stays active. Automatic detection of the terminal running Herdr is not supported.

Add these bindings to Herdr's
`~/.config/herdr/config.toml`, then reload Herdr's configuration:

```toml
[keys]
previous_agent = "f16"
previous_workspace = "f17"
next_workspace = "f18"
next_agent = "f19"
```

Verified with Herdr 0.9.1 on 2026-09-24:

| Terminal | Bundle identifier | Window actions |
| --- | --- | --- |
| Ghostty | `com.mitchellh.ghostty` (default) | Work |
| iTerm2 | `com.googlecode.iterm2` | Work |
| Terminal.app | `com.apple.Terminal` | Do not work |

Terminal.app comes forward and receives the key, but Herdr does not act on it
(see `docs/protocol/herdr-22.md`). Every other Herdr action goes through
Herdr's socket and works whatever terminal Herdr runs in. Whether other
window keys (below) work in Terminal.app has not been tested.

### Window keys

If F16–F19 already mean something on your Mac, choose other keys with
`windowKeys`. Each step takes the same `key` and optional `modifiers` as
`keyboard.shortcut`; a step you leave out keeps its default:

```json
{
  "integrations": {
    "herdr": {
      "windowKeys": {
        "previousAgent": { "key": "f13", "modifiers": ["control"] },
        "previousWorkspace": { "key": "f14", "modifiers": ["control"] },
        "nextWorkspace": { "key": "f15", "modifiers": ["control"] },
        "nextAgent": { "key": "f19", "modifiers": ["control"] }
      }
    }
  }
}
```

Bind the same keys to `previous_agent`, `previous_workspace`,
`next_workspace`, and `next_agent` in Herdr's `config.toml`, using Herdr's own
key syntax. Changing only one side breaks the window actions. Two steps cannot
share a key.

Herdr runs one client window at a time: starting `herdr` in another terminal
moves the session there. Close the other terminal's Herdr window, or quit that
terminal, so the configured terminal is the one Dispatch brings forward.

Herdr also exposes explicit identifier-based actions:

- `herdr.agent.focus` — string `target`
- `herdr.pane.close` — string `paneID`
- `herdr.tab.focus` — string `tabID`

macOS actions are:

- `keyboard.shortcut` — string `key`; optional array `modifiers`
- `keyboard.typeText` — string `text`
- `application.activate` — string `bundleIdentifier`
- `application.focusWindow` — strings `bundleIdentifier` and `title`
- `macro.sequence` — array `operations`

Shortcut modifiers are `command`, `option`, `control`, `shift`, and `function`.
Keys include letters, number words such as `one`, navigation keys, `return`,
`rightCommand`, and `f13` through `f19`. Text and macro contents are never written to normal logs.

## Send terminal keys over the Herdr socket

`herdr.pane.sendKeys` uses Herdr's terminal key syntax, including `esc`, `enter`,
`ctrl+c`, `ctrl+z`, `shift+tab`, and `f1`. Herdr validates the key names; invalid
names fail the action. These are keys for the program inside the pane, not
Herdr's `prefix+` bindings or macOS `keyboard.shortcut` key names. The terminal
window does not need to be in front, and this action needs no Accessibility
permission.

For example, bind key 9 to send `Ctrl+Z` to Herdr's focused pane:

```json
{
  "version": 1,
  "bindings": [
    {
      "when": {
        "control": { "type": "key", "index": 9 },
        "gesture": { "type": "pressed" }
      },
      "actions": [
        {
          "id": "herdr.pane.sendKeys",
          "arguments": { "keys": ["ctrl+z"] }
        }
      ]
    }
  ]
}
```

Merge the binding into your existing file, replacing any existing binding for
that event. `Ctrl+Z` suspends Claude Code on macOS/Linux, where `fg` at the shell
resumes it; other programs can handle it differently. Sending a key does not
promise that an agent, its child processes, or its background tasks have all
paused. See the [Claude Code keyboard reference](https://code.claude.com/docs/en/interactive-mode).

To target specific panes, use one action per pane in the binding's `actions`:

```json
[
  { "id": "herdr.pane.sendKeys", "arguments": { "paneID": "w1:p1", "keys": ["ctrl+z"] } },
  { "id": "herdr.pane.sendKeys", "arguments": { "paneID": "w1:p2", "keys": ["ctrl+z"] } }
]
```

Read live pane IDs from `herdr pane list`; they can change when panes are closed,
recreated, or moved. IDs belong to the machine Herdr currently shows, which
Dispatch selects before each request. The macro executes in order and stops
if an action fails; it does not discover all working agents or broadcast across
machines. If Herdr has no focused pane, a binding without `paneID` fails without
sending keys. Herdr reports a missing explicit pane as an action error.

See [Herdr's socket API](https://herdr.dev/docs/socket-api/) for supported key
syntax and input semantics.

## Agent row labels

The optional `agentLabel` string sets how the menu-bar panel names each agent
row:

- `workspaceAndAgent` (the default): the agent's workspace and kind, such as
  `Dispatch · claude`.
- `terminalTitle`: the title the agent program sets for its terminal, such as
  a summary of its current task. It falls back to the agent kind.

Either style falls back to the pane ID when nothing else is known.

```json
{
  "agentLabel": "terminalTitle"
}
```

## Status colors

The optional `statusPalette` object configures provider-state colors,
brightness, effects, effect speed, and ambient priority. RGB components are
integers from 0 through 255; brightness and speed are numbers from 0 through 1.

```json
{
  "statusPalette": {
    "appearances": {
      "blocked": {
        "color": { "red": 255, "green": 45, "blue": 65 },
        "brightness": 1,
        "effect": "breath",
        "speed": 0.4
      },
      "working": {
        "color": { "red": 30, "green": 145, "blue": 255 },
        "brightness": 0.8,
        "effect": "shallowBreath",
        "speed": 0.25
      },
      "unknown": {
        "color": { "red": 255, "green": 175, "blue": 35 },
        "brightness": 0.7
      }
    },
    "ambientPriority": ["blocked", "done", "working", "unknown", "idle"]
  }
}
```

This object belongs beside `version` and `bindings` in the complete file. An
unrecognized provider status uses the configured `unknown` appearance, then
the built-in unknown appearance if no fallback was supplied.

`ambientPriority` also decides which agents get the slot keys. Agents are
sorted by it, most urgent first: the first agent takes slot 1, the second slot
2, and so on. A slot's agent lights every key bound to `herdr.agent.focusSlot`
for that slot, so the lights move with your bindings. With the default layout,
six blocked agents fill keys `0` through `5` even if others are done or
working. Agents with the same status keep Herdr's order. A status not in the
list ranks as `unknown`, or last if `unknown` is not listed.

The same appearance lights the agent's key and, for the most urgent agent, the
underglow. What each effect did on firmware 0.6.2:

| Effect | On a key | On the underglow |
| --- | --- | --- |
| `off` | Dark | Dark |
| `solid` | Steady | Steady |
| `breath` | Pulses; needs `speed` above 0 | Not yet observed |
| `shallowBreath` | Looked the same as `breath` | Not yet observed |
| `rainbow` | Pulses through colors | Colors moving around the pad |
| `snake` | Dark | A pattern moving around the pad |
| `gradient` | Dark | Steady |

On a key, `speed` only switches pulsing on: `breath` at speed 0 stays dark,
and on 2026-09-30 six keys set from 1/255 to 1 pulsed in sync at the same
rate, and the underglow's pulse kept the same rate too. Whether `speed` affects
the underglow's moving effects (`snake`, `rainbow`) has not been measured. An
effect runs for as long as the status lasts.

## Key lights

The optional `lights` list gives keys a fixed light, for example to mark a
destructive key. Each entry takes a control and an appearance with the same
fields as a status color:

```json
{
  "lights": [
    {
      "control": { "type": "key", "index": 9 },
      "appearance": { "color": { "red": 210, "green": 55, "blue": 70 }, "brightness": 0.45 }
    }
  ]
}
```

Keys 0 through 10 have lights; key 12, the dial, and the joystick do not, and
are rejected. A key may appear once. On a slot key, an agent's status replaces
the fixed light while an agent holds that slot, so a fixed light there marks an
empty slot. Without `lights`, only slot keys light up.

## Default physical layout

The default file maps Creator Micro keys `0` through `5` to Herdr agent slots
1 through 6 in visual reading order. The dial cycles workspaces in Herdr's
window and the joystick navigates panes. On the third row, key 6 creates a Herdr workspace, key 7
splits the focused pane side by side, key 8 cycles the typed command through
`claude`, `codex`, and `opencode`, and key 9 closes the focused pane (Herdr
closes a workspace with its last pane). Wide key 10 taps right Command for the
configured voice workflow. Other keys remain unbound until configured. Key 9
has a dim red light and key 10 a purple one, set in `lights`.

## Worked examples

Complete example files with per-binding notes live in
[docs/examples/](examples/README.md). Start with
[dictation-and-herdr.json](examples/dictation-and-herdr.json).
