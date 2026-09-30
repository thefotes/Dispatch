# Worked example: dictation and Herdr

This directory holds complete configuration files that compile against
Dispatch's built-in actions. Copy one to `~/.config/dispatch/config.json`
and reload from the menu-bar panel. `dictation-and-herdr.json` is the
annotated walkthrough below.

## dictation-and-herdr.json

A real working setup: six agent-slot keys, workspace and pane navigation,
pane management, a dictation key, and status lights. JSON has no
comments, so each binding is explained here in file order.

- **Keys 0–5, pressed → `herdr.agent.focusSlot` (slots 1–6).** The top two
  rows of keys focus Herdr agent slots 1 through 6 in visual reading order.
- **Dial rotated clockwise → `herdr.workspace.cycle` with `delta` 1.**
  Turning the dial right moves to the next workspace in Herdr's window.
- **Dial rotated counterclockwise → `herdr.workspace.cycle` with `delta`
  -1.** Turning left moves to the previous workspace. The two dial entries
  do not overlap because their directions differ.
- **Joystick moved up/down/left/right → `herdr.pane.focusDirection`.**
  Each direction focuses the neighboring pane in Herdr's window.
- **Key 6, pressed → `herdr.workspace.create`.** Creates a workspace and
  focuses it.
- **Key 7, pressed → `herdr.pane.splitFocused` with `direction` `right`.**
  Splits the focused pane side by side and focuses the new pane.
- **Key 8, pressed → `herdr.pane.cycleText` with `options`
  `claude`, `codex`, `opencode`.** Repeated presses cycle the typed agent
  command in the focused pane; submitted or hand-edited text is never
  erased.
- **Key 9, pressed → `herdr.pane.closeFocused`.** Closes the focused pane;
  Herdr closes a workspace with its last pane.
- **Wide key 10, pressed → `keyboard.shortcut` `rightCommand`.** The wide
  key taps right Command, which triggers the configured voice workflow.
- **Key 12, pressed → `keyboard.shortcut` `f13`.** The bottom-right key
  presses F13, which toggles macOS dictation after you set the dictation
  shortcut to F13 in System Settings (Keyboard > Dictation). A single press
  toggles it on and off, so a repeated press never turns dictation straight
  back off. F16–F19 are Herdr's default window keys, so do not use them here
  unless you move those with `integrations.herdr.windowKeys`.
- **`agentLabel` `terminalTitle`.** The menu-bar panel names each agent row
  by its terminal title instead of workspace and kind.
- **`statusPalette`.** Status lights: red breath while blocked, blue
  shallow breath while working, green when done, dim gray when idle, amber
  for unknown states. `ambientPriority` picks which state drives the
  underglow, and which agents get the slot keys first.
- **`lights`.** Key 9 glows dim red as a warning that it closes a pane, and
  the wide key glows purple for the voice workflow. The slot keys need no entry: they
  show their agent's status.

Herdr still needs the F16–F19 window bindings from
[configuration.md](../configuration.md) for the workspace-cycle actions to
work.
