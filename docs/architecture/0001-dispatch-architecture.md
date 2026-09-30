# ADR 0001: Dispatch architecture

- Status: accepted
- Date: 2026-09-23

## Context

Dispatch converts input from a physical control surface into user-configured
operations on a Mac. It also projects provider and runtime state back onto the
device as lighting. Hardware behavior, user intent, integration behavior, and
application lifecycle change for different reasons and must remain testable in
isolation.

The first supported device is the Work Louder Creator Micro 2. The first
provider integration is Herdr, but neither is part of the core event or binding
model.

## Decision

Dispatch uses an event-to-action architecture with a separate state-to-
presentation path. The runtime coordinates these paths; it does not absorb
their implementations.

```text
HID transport -> Creator Micro driver -> DispatchEvent
                                            |
                                            v
                                      BindingResolver
                                            |
                                            v
                                     ActionInvocation
                                            |
                                            v
                                       ActionRegistry
                                      /       |       \
                              provider     macOS     other
                               adapter     adapter   adapters

provider/runtime state + configuration
                    |
                    v
          presentation renderer
                    |
                    v
            desired presentation
                    |
                    v
          Creator Micro driver
```

This is a graph, not a single linear pipeline. Integrations may produce state,
execute actions, or both. They never interpret physical input.

## Core invariants

1. The HID transport knows bytes, framing, request correlation, connection
   lifecycle, and transport errors. It knows no controls or actions.
2. The Creator Micro driver translates vendor messages into stable
   `DispatchEvent` values. It never reads bindings or chooses an action.
3. A `DispatchEvent` contains a logical control and gesture, never vendor names
   such as `AG09` or `v.oai.hid`.
4. The binding resolver is pure. It maps an event through an immutable,
   validated configuration snapshot to zero or more action invocations.
5. An action invocation is data: a namespaced action identifier plus validated
   arguments. It has no captured executable closure.
6. An adapter knows how to interact with an external system. It knows neither
   the originating event nor the user's configuration.
7. Protocols are introduced only at useful substitution boundaries. A
   protocol may group a coherent integration surface; there is no protocol per
   individual action.
8. Integration-specific semantics remain specific. For example, closing a
   focused Herdr pane is a Herdr action unless another provider has proven
   equivalent semantics.
9. Lighting is rendered from state and configuration. Input handlers do not
   directly set LEDs.
10. `DispatchCore` imports no hardware, provider, macOS UI, Accessibility, or
    AppKit implementation target.

## Input path

### HID transport

The transport owns device discovery, nonexclusive opening, byte reports,
message assembly, request identifiers, timeouts, disconnect detection, and an
ordered notification stream. One actor exclusively owns each live transport
session and its pending request table.

The transport exposes vendor messages to the device driver, not to the rest of
the application.

### Creator Micro driver

The driver owns the Creator Micro wire vocabulary, physical geometry, firmware
capability detection, keymap provisioning, and lighting encoding. It converts
vendor notifications to logical events and publishes them as an asynchronous
sequence.

The runtime-facing device boundary is intentionally small:

```swift
protocol PadDevice: Sendable {
    func events() -> AsyncStream<DispatchEvent>

    func connect() async throws
    func disconnect() async
    func checkHealth() async throws
    func apply(_ presentation: PadPresentation) async throws
}
```

The precise stream and lifecycle signatures may evolve during implementation,
but vendor values must not cross this boundary. The health check is a
side-effect-free device round trip; it exists so lifecycle supervision can be
tested without depending on the concrete HID transport.

`events()` returns a new subscription on every call, and the runtime
subscribes once per connection. Never share one stored `AsyncStream` across
connections. Cancelling the task that iterates an `AsyncStream` ends that
stream permanently, so after the first reconnect or stop/start, a shared stream
delivers no input while lighting output keeps working. `EventBroadcast`
provides per-subscriber streams; the RPC session's notifications use it too.

### Event model

The core event model represents source identity, logical control, gesture, and
time. It is `Sendable` and serializable so events can be recorded and replayed
in tests and diagnostics.

Initial logical controls are numbered keys, a dial, and a joystick. Initial
gestures include press, release, signed rotation steps, and directional
movement with magnitude. The model may grow without exposing hardware codes.

## Binding and action path

### Configuration

The first configuration format is versioned JSON at
`~/.config/dispatch/config.json`. Configuration refers to stable logical
controls and namespaced action identifiers. It never contains vendor keycodes.

Configuration is decoded, semantically validated against the action catalog,
and compiled into an immutable binding table before it becomes active. Reload
is atomic: an invalid edit reports precise diagnostics and leaves the previous
valid snapshot active. Unknown fields and unsupported actions are errors.

The initial resolver performs deterministic matching against the event and
active configuration only. Modes, conditions, and a general expression
language are deferred until a demonstrated need exists.

### Binding resolver

The binding resolver answers only: "What configured intent corresponds to
this event?"

```text
DispatchEvent + CompiledBindings -> [ActionInvocation]
```

Zero results mean an unbound event. One is the common case. Multiple results
support an ordered macro. Resolution performs no I/O.

### Action catalog and registry

An action definition describes a supported action identifier, its argument
schema, and user-facing metadata. An action invocation supplies concrete,
already-validated arguments.

At composition time, integrations register definitions and executable
handlers in the action registry. Configuration is reconciled with this catalog
when it is loaded, not on every input event. The registry distinguishes:

- unsupported: no implementation exists, making the configuration invalid;
- unavailable: an implementation exists but cannot currently execute, such as
  a disconnected provider;
- failed: execution was attempted and returned an error.

Action identifiers describe shared intent only when semantics genuinely match.
Generic identifiers such as `keyboard.shortcut` are appropriate. A uniquely
Herdr operation uses a Herdr namespace rather than a speculative provider-wide
protocol.

### Adapters

An adapter translates an action into an external system operation. A Herdr
adapter may register several Herdr actions behind one coherent integration
boundary. A macOS automation adapter may register keyboard and application
actions behind another. These are grouping and substitution decisions, not a
requirement to invent a protocol for every category.

Tests substitute recording adapters at boundaries where execution would
otherwise control the computer or contact an external process.

## Presentation path

A pure renderer maps provider state, runtime state, and presentation
configuration to a complete desired `PadPresentation`. The Creator Micro
driver translates that model into vendor lighting operations.

The presentation reconciler remembers the last successfully applied frame,
coalesces rapid updates, and sends only meaningful differences. The newest
desired frame supersedes stale queued frames.

## Runtime

`DispatchRuntime` is the composition coordinator. It:

- consumes device events;
- resolves bindings and executes action invocations;
- supervises configuration snapshots;
- observes provider and health state;
- requests presentation renders;
- coordinates connection, reconnection, sleep, wake, cancellation, and
  shutdown; and
- publishes typed health state for the menu-bar application.

It delegates transport, matching, execution, rendering, and integration work
to focused components. Connection supervision is an explicit state machine
with bounded backoff. Each connection generation is identified so callbacks
from an obsolete session cannot mutate current state.

While connected, the runtime performs an injectable, approximately 15-second
health check. A failed check tears down the stale session and enters the same
bounded reconnect path as an initial connection failure.

No blocking device, file, provider, or Accessibility work runs on the main
actor.

## Target boundaries

The repository begins as one Swift package with these targets:

- `DispatchCore`: events, controls, gestures, actions, configuration models,
  binding resolution, presentation models, and pure rendering;
- `DispatchCreatorMicro`: HID transport, vendor protocol, keymap provisioning,
  geometry, and lighting;
- `DispatchProviders`: Herdr and existing provider integrations;
- `DispatchMacOS`: keyboard synthesis, Accessibility, and app/window focus;
- `DispatchRuntime`: lifecycle supervision and orchestration;
- `DispatchApp`: menu-bar UI and composition root;
- `dispatch-probe`: hardware inspection and diagnostics; and
- `DispatchTestSupport`: deterministic transports, devices, adapters, clocks,
  recording, and replay.

Targets may be combined when implementation shows that a boundary adds no
value, but dependency direction and the core invariants remain mandatory.

## Testing strategy

Two distinct device fakes prevent abstraction leakage:

- a fake HID transport exercises framing, correlation, timeout, foreign
  response, notification, and disconnect behavior in the real driver;
- a fake `PadDevice` exercises the runtime without simulating firmware.

Pure tests cover configuration validation, compiled binding lookup, geometry,
and presentation rendering. Recording adapters verify action execution without
controlling the computer. Serialized event traces cover ordering and replay.
Live hardware and live Herdr tests are opt-in and never required for ordinary
CI.

Tests assert observable behavior through public interfaces, not source text.
An already decoded input event should reach its registered handler without
filesystem or network work on the event path and with an internal latency goal
well below 10 milliseconds.

## Consequences

The design introduces explicit event, invocation, and presentation models, but
keeps the hardware, configuration, and integrations independently replaceable
and testable. It also prevents the menu-bar application or Herdr behavior from
becoming embedded in a device controller.

The action registry is extensible without requiring a plugin system now.
Declarative configuration remains inspectable and validatable. Integration-
specific operations may look less uniform, intentionally avoiding false
abstractions.
