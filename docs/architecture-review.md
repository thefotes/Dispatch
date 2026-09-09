# Architecture Review Notes

> Research notes from a code-reading session, recorded so they can be picked up
> in a future session. Everything below reflects the codebase as of
> September 2026. File:line references are relative to the repo root and will
> drift as the code changes — the structure should remain recognizable.
>
> Since these notes were taken, `ForegroundInstanceDetector` and its support
> plumbing (`calibrationMarker`, `onFocusInstance`, `HerdrClient.setWindowTitle`)
> have been deleted — Herdr 0.9 puts every machine in one window, so it could
> never work (see `docs/machine-focus-next-steps.md` §3).

---

## 1. Project shape

Four SwiftPM targets in `Package.swift` — all **first-party** (none are
third-party dependencies; the only external package is SwiftLint, used as a
build-time lint plugin, from https://github.com/realm/SwiftLint). In SwiftPM
terminology a "target" is a compilable unit of this repo's own source under
`Sources/`, not a downloaded dependency.

| Target | Kind | Role |
|---|---|---|
| `WLKit` | library | Shared engine: HID device transport, vendor protocol, Herdr client, providers, keymap, status→light mapping, `BridgeController` |
| `WLMicroManager` | executable | The menu-bar app — the real product |
| `WLInspector` | executable | Debug UI; separate process that opens the same HID device directly (no config involvement) |
| `WLProviderBridge` | executable | Standalone binary wrapping `HerdrProvider` behind a Unix socket — proves the provider can run out of process |

Dependency graph: `WLInspector`, `WLMicroManager`, `WLProviderBridge` all
depend on `WLKit`; they do not depend on each other.

## 2. Primary entry points

- **`MicroManagerApp`** — `Sources/WLMicroManager/MicroManagerApp.swift:24`. `@main`
  MenuBarExtra app. `init()` calls `ProviderFactory.make()` (reads
  `config.json` once, decides provider topology) and builds a `BridgeController`.
  The real startup wiring is the `.task` block at `:39–158`: joins panel
  windows (Stack/Land) to bridge callbacks, wires `VoiceController`,
  `ShortcutController`, `TuneController`, joystick routing, emulator setup
  (`useEmulator`), starts `ForegroundInstanceDetector` when 2+ Herdr instances
  are configured, a 2.5 s error-relay poll loop, and auto-starts the bridge if
  previously enabled (`BridgeSettings` / UserDefaults).
- **`WLInspectorApp`** — `Sources/WLInspector/WLInspectorApp.swift:16`. Owns its
  own `WLDevice`; `AppModel` (`Sources/WLInspector/AppModel.swift:44`) logs
  TX/RX/NOTIFY traffic, decodes notifications, drives lighting manually, has a
  raw JSON-RPC console.
- **`WLProviderBridge/main.swift`** — script-style top-level code (`:12–33`,
  no `@main`): socket path from argv[1] or `WL_PROVIDER_BRIDGE_SOCKET` or
  `ProviderBridgePaths.defaultSocketPath()`; wraps `HerdrProvider()` in a
  `ProviderBridgeServer`; SIGINT/SIGTERM → exit(0); `RunLoop.main.run()` forever.

## 3. Important classes

### WLKit

| Type | Where | Responsibility |
|---|---|---|
| `BridgeController` | `Sources/WLKit/BridgeController.swift:19–748` | The core engine. @MainActor ObservableObject. Owns device + provider, publishes all UI state (isRunning, deviceConnected, keyColors, agents, lastError, contendingClient, resolvedDialMode…). `handleKeyPress` (`:490–519`) is the single dispatch point for every pad input. Also `start/stop/toggle`, `useEmulator`, `perform`, `runProviderAction/injectPrompt/cycleTabs/cycleDial/moveJoystick/focusSlot`, `ensureKeymap`, `refresh`, `raiseTerminal`. App-extension hooks: `onStackKey`, `onLandKey`, `onVoiceKey`, `onShortcut`, `onDial`, `onJoystick`, `onKeyIntercept`. |
| `WLDevice` | `Sources/WLKit/WLDevice.swift:22–449` | Raw-HID JSON-RPC transport (64-byte reports, report id 0x06). `connect()` (`:118`), `call()` (`:256`), `drainRPC()` (`:367`). |
| `PadEmulator` | `Sources/WLKit/PadEmulator.swift:21–271` | Virtual pad answering the same RPC; reproduces firmware quirks (keymap-bound lighting, `{"ok":1}` acceptance). |
| `Provider` protocol | `Sources/WLKit/Provider.swift:11–158` | The main seam: `describe()`, `status()`, `focus()`, `dial()`, `inject()`, `perform()`, `joystick()`, `subscribe()`. |
| `HerdrProvider` | `Sources/WLKit/HerdrProvider.swift:12–349` | Default in-process implementation; wraps `HerdrClient`. Lifecycle + per-pane event streams with restart/backoff; prompt-tool cycler; joystick wrap logic. |
| `RemoteProvider` | `Sources/WLKit/RemoteProvider.swift:9–130` | Provider over a Unix socket speaking the `provider.*` line protocol. |
| `RoutingProvider` | `Sources/WLKit/RoutingProvider.swift:53–301` | Fan-in front for 2+ Herdr instances: merged status, active-instance routing, namespaced focus targets, per-child timeout backoff, `herdr.next_instance` action. |
| `ProviderBridgeServer` | `Sources/WLKit/ProviderBridgeServer.swift:13–259` | POSIX Unix-socket server; `dispatch()` (`:131`). |
| `HerdrClient` | `Sources/WLKit/HerdrClient.swift:181–553` | Newline-JSON-over-Unix-socket client. Carries a full static facade (`:464–539`) backed by `HerdrClient.shared` (`:205`) that mirrors its instance methods one-to-one. |
| `KeyBindings` | `Sources/WLKit/KeyBindings.swift:72–363` | **The entire config system** (see §5). |
| `KeymapManager` | `Sources/WLKit/KeymapManager.swift:13–222` | Reads/writes the device's flash `keymap.json`; agent-keymap detection and apply. |
| `StatusMapper` + `BridgeConfig` | `Sources/WLKit/StatusMapper.swift:11–221` | Palette/priority knobs and agent→light mapping (`aggregate`, `agentsInKeyOrder`, per-flex-key threads, zones). |
| `OAI` + `Pad` | `Sources/WLKit/OAIProtocol.swift` | Vendor protocol constants and pad geometry. Note: agent key order is `[1, 0, 2, 3, 4, 5]` because the top row is wired right-to-left. |
| `GitButler` | `Sources/WLKit/GitButler.swift` | `but` binary locator (`WL_BUT_PATH`, search paths, login-shell fallback) + `status`/`land`. |
| `ShortcutSpec` | `Sources/WLKit/ShortcutSpec.swift` | Parses `"cmd+shift+5"`-style strings to keycode+modifiers (US-ANSI table). |
| `WideKeyDebounce` | `Sources/WLKit/WideKeyDebounce.swift` | 150 ms collapse for the two switches under the wide keycap. |
| `DeviceOpenFailure` | `Sources/WLKit/DeviceOpenFailure.swift` | Classifies HID-open failures (permission vs. wedged device). |

### WLMicroManager

| Type | Where | Responsibility |
|---|---|---|
| `ProviderFactory` | `Sources/WLMicroManager/ProviderFactory.swift:9–110` | Chooses provider from `config.json` `"provider"`: `.connect` → `RemoteProvider`; `.launch` → spawn process, wait for socket → `RemoteProvider`; default → `HerdrProvider` or `RoutingProvider` for 2+ instances. Also owns terminating a launched process on app quit. |
| `BridgeSettings` | `Sources/WLMicroManager/MicroManagerApp.swift:167–190` | UserDefaults persistence of `bridgeEnabled` / `emulatePad` (+ `WL_EMULATE` env). |
| `TuneController` | `Sources/WLMicroManager/TuneController.swift` | The built-in `"effort"` dial mode: Claude `/effort` ladder, Codex `ctrl+alt+u/d`. |
| `VoiceController` | `Sources/WLMicroManager/VoiceController.swift` | Wide-key default: taps right-command (0x36) for Superwhisper; tracks take state for the light. |
| `ShortcutController` | `Sources/WLMicroManager/ShortcutController.swift` | Posts config-bound shortcuts as synthetic CGEvents (Accessibility). |
| `SyntheticChord` | `Sources/WLMicroManager/SyntheticChord.swift` | The one chord primitive: modifier down/up cadence preserving the user's physical modifiers. |
| `StackPanelController` / `LandPanelController` | `Sources/WLMicroManager/StackPanel.swift`, `LandPanel.swift` | Row-3 features: floating `but status` window; two-press confirm land. Both built on `FloatingPanel`. |
| `FloatingPanel` | `Sources/WLMicroManager/FloatingPanel.swift` | Shared non-activating WKWebView NSPanel chrome + self-sizing HTML shell. |
| `ForegroundInstanceDetector` | `Sources/WLMicroManager/ForegroundInstanceDetector.swift:27–279` | AX-based "which Herdr terminal window is frontmost"; calibration via `⟦wl:id⟧` title markers; `activate(instanceID:)` raise hook; `_AXUIElementGetWindow` (`:278`). |
| `MenuBarIcon`, `MenuPanelView`, `EmulatorWindowController`, `InspectorLauncher` | various | UI: icon state machine, the menu panel (pad mirror + agent list + login item + emulator toggle), emulator window, Inspector launch (serialized to avoid HID contention). |

## 4. Data flow: keypress → action

1. **Hardware/emu**: pad press → HID report → `WLDevice.handleReport` →
   `drainRPC` extracts `{"m": "v.oai.hid", "p": {"k": "AG07", "act": 1}}` →
   `onNotification` → `BridgeController.handleKeyPress(index)`.
2. **Dispatch** (`BridgeController.swift:490–519`, order matters):
   (a) `onKeyIntercept` — land-confirmation cancels everything but the land key;
   (b) wide-key debounce for keys 10/11;
   (c) **config binding wins** (`keyBindings.action(for:)` over
   `Pad.overridableKeyIDs`) → `perform`: `.text` → `provider.inject`;
   `.shortcut` → `ShortcutSpec` → `ShortcutController.post` (synthetic CGEvent);
   `.action` → `runProviderAction` → `provider.perform`; `.off` → inert;
   (d) built-ins otherwise: stack → `StackPanelController.toggle()`;
   tabs → `provider.dial(1, mode: "tab")`; land → `LandPanelController`;
   voice → right-command tap; dial → `TuneController` or `bridge.cycleDial`;
   joystick → `provider.joystick`; agent keys → `provider.focus` +
   `raiseTerminal()`.
3. **Provider layer**: `HerdrProvider` → `HerdrClient` calls over the socket;
   `RoutingProvider` intercepts focus targets and fires `onFocusInstance` →
   AX-raise of the right window; `RemoteProvider` → bridge socket →
   `ProviderBridgeServer.dispatch`.
4. **Reverse (status → lights)**: provider events + 2.5 s poll → debounced
   `refresh()` → `StatusMapper` → dedupe by fingerprint → `device.callAsync`
   lighting calls; app mirrors state via `setStackPanelOpen/setLandPanelOpen/
   setVoiceActive`.

## 5. How configuration works

One mechanism: **`KeyBindings`** (`Sources/WLKit/KeyBindings.swift:72–363`).

- **Path**: `~/.config/micromanager/config.json` (respects `XDG_CONFIG_HOME`) — `:197`.
- **Read-only**: there is no save path anywhere in the codebase; users edit by
  hand. Parsed with hand-rolled `JSONSerialization` — **no Codable/JSONDecoder
  is used anywhere in the project**.
- **Malformed file → silent fallback to defaults** (`:213`). Validation is
  mostly soft and deferred: dial names, provider actions, and shortcuts are
  only validated at *press time* against `provider.describe()` / `ShortcutSpec`,
  surfacing as panel errors.
- **Schema**:
  - `keys`: keyed by pad id (`"9"`, `"12"`, `"10+11"` for the wide key as one,
    `"6"`/`"7"`/`"8"` for stack/tabs/land). Values: bare string = text macro
    (empty string = no-op, key keeps default), `false` = unbind outright,
    `{"shortcut": "cmd+shift+5"}` = system-wide synthetic chord,
    `{"action": "..."}` = provider action.
  - `dial`: `"effort"` (built-in) or any provider mode name (unrecognized →
    fallback to effort with a panel warning).
  - `agent_keys`: `"sidebar"` (default) or `"priority"`.
  - `provider`: `{"connect": "/path.sock"}` or `{"launch": "cmd", "args": []}`
    (connect wins over launch).
  - `herdr`: `tools`, `split_direction`, `instances` (`id`/`name`/`socket_path`;
    `~` and `$TMPDIR` expanded; duplicate ids dropped first-wins).
  - `claude`: `efforts` ladder.
- **Defaults**: macros on keys 9/12; efforts ladder; herdr tools; split
  "right"; one local instance (`HERDR_SOCKET_PATH` or
  `~/.config/herdr/herdr.sock`).
- **Non-config persistence**: `UserDefaults` (`BridgeSettings`), `SMAppService`
  login item, and the device's own flash-written `keymap.json`.
- **Env knobs**: `WL_EMULATE`, `WL_TERMINAL_BUNDLE_ID`, `WL_BUT_PATH`,
  `HERDR_SOCKET_PATH`, `WL_PROVIDER_BRIDGE_SOCKET`, `XDG_CONFIG_HOME`.

## 6. Architectural concerns / tensions (the reason for this review)

Ranked roughly by bug-producing potential:

1. **Config read twice with different lifetimes.** `ProviderFactory` reads
   `config.json` once at launch; `BridgeController.start()` re-reads it
   (`BridgeController.swift:184`). Editing keys/dial takes effect on an
   off/on toggle, but provider topology needs a full relaunch — two freshness
   rules over one file, only documented in the README, not in code.
2. **Out-of-process provider loses config.** `WLProviderBridge/main.swift:17`
   hard-constructs `HerdrProvider()` with defaults — the `"herdr"` config keys
   (tools, split_direction) only apply in-process and silently don't reach a
   launched bridge.
3. **Static vs. instance `HerdrClient`.** `HerdrClient.shared` is a full
   duplicate facade of its instance methods, and app-layer panels
   (`StackPanel`, `LandPanel`, `TuneController`) always use it — so with 2+
   Herdr instances, panel data always comes from the *local* instance even
   when the *active* one (per `RoutingProvider`) is remote. Structural
   mismatch; acknowledged in the `shared` doc comment.
4. **Dial split-brain.** Dial handling forks in `MicroManagerApp.swift:80–87`
   between `TuneController.handleDial` (built-in "effort") and
   `bridge.cycleDial` (provider mode), keyed off `bridge.resolvedDialMode`
   which only exists after `describe()` lands — before that, provider dial
   names silently fall back to effort behavior.
5. **Error-channel multiplicity.** `BridgeController.lastError` + controller
   `onError` callbacks + `RoutingProvider.lastError` bridged by a 2.5 s poll
   all converge on one published string, with documented fight risks.
6. **Foreground detection vs. manual switching.** `ForegroundInstanceDetector`
   auto-follow and manual `herdr.next_instance` both write the same active
   index; detection deliberately never fires on ambiguity so the manual choice
   survives — subtle invariant, easy to break.
7. **Two raise paths.** Agent-key focus raises the terminal via
   `BridgeController.raiseTerminal` (app-level, can't discriminate windows),
   while `RoutingProvider.onFocusInstance` raises a *specific* window via the
   detector's AX hook — two mechanisms for conceptually the same act.
8. **Two apps fighting over the HID device.** Micro Manager and Inspector both
   open the pad; contention is only detectable via leaked response ids
   (`contendingClient`), and `InspectorLauncher` exists just to serialize
   Inspector instances.

## 7. Duplication inventory

1. **Three implementations** of newline-JSON-over-Unix-socket framing:
   `SocketConnection` (`HerdrClient.swift:692–713`), `RemoteProvider.request`
   (`RemoteProvider.swift:76–129`), and `ProviderBridgeServer.readLine/
   writeLine` + bind code. All hand-rolled, with near-identical continuation/
   lock/timeout guards and duplicated `finish`-race comments.
2. **`HerdrClient` static facade** (`:464–539`) mirrors its instance methods
   one-to-one — large deliberate boilerplate layer.
3. **Per-key color state in three places**: `BridgeController.keyColors/
   keyEffects`, WLInspector's `KeyState`/`AppModel.keys`, `PadEmulator.keys`.
4. **`allOff()` duplicated**: `BridgeController.allLightsOff` vs. Inspector
   `AppModel.allOff` — nearly identical code.
5. **Status fetch duplicated**: `BridgeController.openDevice` vs. Inspector
   `AppModel.refreshStatus` — same `sys.version`/`device.status` calls and
   battery formatting.
6. **Key-role logic mirrored in UI**: `MenuPanelView.keyView` re-derives
   isStackKey/isTabCycleKey/isLandKey/isVoiceKey, with a comment admitting it
   must "stay in sync" with `BridgeController.handleKeyPress`.
7. **Focused-agent lookup in four places**: `TuneController.focusedPane`,
   `StackPanelController.buildPayload`, `LandPanelController.prepare`,
   `HerdrProvider.inject` — slightly different phrasing each time.
8. **Panel controller scaffolding**: `StackPanelController` and
   `LandPanelController` both own a `FloatingPanel`, a visibility forwarder,
   and a generation/orphan counter that `FloatingPanel` doesn't absorb.
9. **Two identically-named `AppDelegate` classes**, one per executable, with
   mirrored (opposite-direction) activation-policy logic.
10. **Terminal bundle-id resolution duplicated** (`WL_TERMINAL_BUNDLE_ID ??`
    default) in `BridgeController.raiseTerminal` and
    `ForegroundInstanceDetector.terminalApp`.
11. **AX-trust prompt duplicated** in `ShortcutController.post` and
    `VoiceController.tapTriggerKey`.

## 8. Suggested refactor priorities (from the session)

- Highest user-visible-bug risk: **#1** (config lifetimes) and **#3**
  (`HerdrClient.shared` vs. `RoutingProvider`).
- Biggest maintenance tax: **duplication items 1, 2, 3** — extract a shared
  socket/JSON-RPC layer and a single focused-agent resolver.
- Medium: consolidate config reading behind one owner so there is one
  freshness rule; consider passing full config into a launched bridge binary.

## 9. Operational trivia worth keeping

- Building: `swift build`, `swift test` (live tests skip without hardware),
  `swift run WLInspector`, `./scripts/bundle.sh --install`.
- `swift run` works for dev because it inherits the terminal's Input
  Monitoring grant; a bundled app needs a stable code signature for the grant
  to stick (ad-hoc signatures force re-granting every build).
- A wedged HID session (`0xE00002E2` with permission already granted) survives
  re-enumeration; only a restart clears it (docs/hacking.md §14).
- Work Louder's Input app and the Codex desktop app fight over the same pad;
  the panel detects contention because the device is opened shared and a
  response id we never issued leaks in.
