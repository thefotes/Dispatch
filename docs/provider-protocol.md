# The Micromanager provider protocol

How to write a provider — anything that tells Micromanager what to show on
the agent-key row, what the dial does, and what a macro key types — without
touching Swift. `HerdrProvider` is one implementation of this, shipped
in-process by default; this document is the contract any other one needs to
meet, and [`examples/reference-provider.py`](../examples/reference-provider.py)
is a complete second implementation, in Python, that meets it.

If you only want to *run* a provider out of process, see
["Providers"](../README.md#providers) in the README — this document is for
*writing* one.

---

## Contents

1. [Why a protocol, not a Swift protocol](#1-why-a-protocol-not-a-swift-protocol)
2. [Transport](#2-transport)
3. [Envelope](#3-envelope)
4. [Methods](#4-methods)
5. [`events.subscribe`](#5-eventssubscribe)
6. [Worked example](#6-worked-example)
7. [Writing your own](#7-writing-your-own)

---

## 1. Why a protocol, not a Swift protocol

WLKit has a Swift `Provider` protocol (`Sources/WLKit/Provider.swift`) that
`BridgeController` actually talks to. That is not what this document
describes. `RemoteProvider` is the WLKit type that *implements* the Swift
protocol by speaking the wire protocol below to a socket — so a provider
written in any language only ever needs to implement what's here, never the
Swift side.

## 2. Transport

A Unix domain socket, newline-delimited JSON, one JSON object per line — the
same shape [Herdr's own socket API](hacking.md) uses, and the same shape
`HerdrClient.swift` already speaks to it.

**Every method except `events.subscribe` is one request per connection**:
the client connects, writes one line, reads one line back, and closes the
connection. Do not expect a second request on a connection that has already
answered one — `ProviderBridgeServer` does not support it, matching Herdr's
own server, which the "second request on a fresh connection" trap in
[`hacking.md`](hacking.md) already documents for exactly this reason.

`events.subscribe` is the one exception: that connection stays open. See
[§5](#5-eventssubscribe).

## 3. Envelope

Request:

```json
{"id": "req", "method": "provider.status", "params": {}}
```

`id` can be any string — round-tripped back in the response, but nothing
in this repo's client reads it for correlation, since only one request is
ever in flight per connection. `params` is always an object, `{}` when a
method takes none.

Response, success:

```json
{"id": "req", "result": {}}
```

Response, failure:

```json
{"id": "req", "error": {"message": "nothing has focus right now"}}
```

`error.message` is the only field read — it becomes the string
`BridgeController.lastError` shows in the menu. There is no error code
scheme; message text is the whole contract.

## 4. Methods

### `provider.describe`

Params: `{}`. Called once, at bridge start.

```json
{
  "statePalette": {
    "<state name>": {"color": <0xRRGGBB packed int>, "effect": <int, OAI.Effect.rawValue>}
  },
  "statePriority": ["<state name>", "..."],
  "dialModes": [{"id": "<mode>", "label": "<menu label>", "raisesHost": <bool>}]
}
```

- `statePalette` / `statePriority` become `BridgeConfig`'s colors, effects,
  and aggregate-underglow priority order — see `ProviderStateStyle` and
  `ProviderDescription` in `Sources/WLKit/Provider.swift` for the exact
  fields, and `HerdrProvider.describe()` for a real example.
- `effect` is `OAI.Effect`'s raw `Int`: `0` off, `1` solid, `2` snake, `3`
  rainbow, `4` breath, `5` gradient, `6` shallow breath.
- `config.json`'s `"dial"` string is resolved against `dialModes`' `id`s at
  `BridgeController` — this file has no built-in vocabulary of mode names
  at all; whatever a provider declares here is what a user can select.
- `raisesHost` says whether landing on that mode should bring the host app
  forward, the way pressing an agent key does — Herdr's `"agent"`/`"space"`
  do, `"tab"` does not. Missing on an older provider's response decodes as
  `false`, not a decode failure.
- `dialModes` never includes `"effort"` — that mode is a Micromanager
  feature (Claude Code / Codex reasoning effort), handled entirely in the
  app layer, and never reaches a provider at all.
- A malformed or unreachable response is not fatal: `RemoteProvider`
  answers an empty `ProviderDescription()` rather than throwing, since
  `describe()` has no throwing variant in the Swift protocol.

### `provider.status`

Params: `{}`.

```json
{"agents": [
  {
    "agent": "claude",
    "agent_status": "working",
    "focused": true,
    "pane_id": "p1",
    "terminal_id": "t1",
    "tab_id": "tab1",
    "workspace_id": "ws1",
    "cwd": "/path",
    "foreground_cwd": "/path/subdir"
  }
]}
```

One entry per entity for the agent-key row, in display order. Only `agent`,
`agent_status`, and `focused` are required; the rest are optional (omit
fields you have nothing to report — see `HerdrAgent.wire` in
`Sources/WLKit/ProviderWire.swift` for the exact optional-field handling).
`agent_status` is one of the state names `provider.describe` put a palette
entry under — an unrecognized one is not an error, it just paints
unstyled. `pane_id` (or, failing that, `terminal_id`) is what `focus`
expects back.

### `provider.focus`

Params: `{"target": "<a pane_id or terminal_id status() reported>"}`.
Result: `{}`. Focuses that entity — whatever "focus" means for you.

### `provider.dial`

Params: `{"step": <±N, usually ±1>, "mode": "<one of the ids describe() offered>"}`.
Result: `{}`. One dial detent, or one press of a key wired to "dial one step
forward" (the tabs key calls this with `mode: "tab", step: 1"`, for example).

### `provider.inject`

Params: `{"text": "<the configured macro string>"}`. Result: `{}`. Put this
text wherever "the focused thing's input" is — unsubmitted, so a human
still reviews it before it goes anywhere.

### `provider.joystick`

Params: `{"direction": "<north|south|east|west>"}`. Result: `{}`. One
joystick deflection — move focus one pane over in that direction. A
provider with no notion of panes just answers `{}`: a deflection that
cannot move focus anywhere is a no-op, never an error.

## 5. `events.subscribe`

Params: `{}`. Unlike the others, **the connection stays open.**

1. Client connects, sends the request line.
2. Server replies immediately with one ack line: `{"id": "...", "result": {}}`.
3. From then on, the server sends **one line per change** — content is
   never read, so any non-empty JSON object works; this repo sends
   `{"event": true}`. A poll loop, an agent finishing, a focus change:
   anything worth a repaint is one line.
4. The client closes the connection (or stops reading) when it wants to
   unsubscribe. There is no explicit unsubscribe message — closing the
   socket is the signal.

Debounce on the client side, not here — `BridgeController` already
debounces every notification into one `refresh()`, so a provider that fires
several events in a burst does not need to coalesce them first.

## 6. Worked example

```
$ printf '{"id":"1","method":"provider.status","params":{}}\n' | nc -U /tmp/provider.sock
{"id":"1","result":{"agents":[{"agent":"claude","agent_status":"working","focused":true,"pane_id":"p1"}]}}
```

Verified against both `HerdrProvider` (via `provider-bridge`, this repo's
own companion binary) and against
[`examples/reference-provider.py`](../examples/reference-provider.py) — the
line above works unmodified against either one.

## 7. Writing your own

The whole surface is seven methods and one envelope shape. The reference
provider is under 150 lines of dependency-free Python — a template you can
copy and modify, not a toy that stops working past a demo. To try it:

```
python3 examples/reference-provider.py /tmp/reference-provider.sock
```

then point Micromanager's `config.json` at it:

```json
{ "provider": { "connect": "/tmp/reference-provider.sock" } }
```

or, more realistically, have Micromanager start it for you:

```json
{ "provider": { "launch": "python3", "args": ["/path/to/reference-provider.py"] } }
```
