# TLA+ specifications

These specs model concurrency-sensitive parts of Dispatch so that the TLC
model checker can explore every interleaving, not just the ones a test
happens to hit.

| Spec | Models |
| --- | --- |
| `RuntimeLifecycle.tla` | `DispatchRuntime`: start, stop, reload, apply, and its start, event, heartbeat, and reconnect tasks |

A config named `Module.cfg` or `Module.anything.cfg` checks `Module.tla`.
`RuntimeLifecycle.cfg` checks safety invariants, and
`RuntimeLifecycle.liveness.cfg` checks that `stop()` always returns and that
a failed lighting write recovers by itself.
`scripts/check.sh` and CI run every config.

## Running

```sh
brew install openjdk                      # once
scripts/tla.sh                            # every config in specs/
scripts/tla.sh RuntimeLifecycle.liveness  # one config
```

The script downloads a pinned `tla2tools.jar` into `DISPATCH_BUILD_DIR` and
verifies its SHA-256 on every run, including CI cache restores. It keeps TLC's
state files there, out of the repository. When TLC finds a
violation it prints the shortest sequence of steps that reaches it. Each
step is named after the Swift method and the `await` it resumes from.

## Keeping the model honest

A spec proves things about the model, not about the Swift code. It is only
useful while the two agree:

- Each action corresponds to code between two `await`s in an actor method or
  task. When you add, remove, or move an `await` in `DispatchRuntime.swift`,
  update the matching action.
- Behaviour that depends on hardware or files (connect, health checks,
  configuration loads, lighting writes, actions) is a nondeterministic
  choice in the model. Record any assumption about it in a comment, as the
  spec does for a failed connect.
- When TLC finds a violation, reproduce it with a Swift test through the
  runtime's public interface before fixing it. Then fix the Swift code and
  the model together and rerun both.
- A spec that passes may just have weak properties. When you add or change
  a guard, check that removing it from the model makes TLC fail.

## History

The first version of this model, of the runtime as it was, found that
`stop()` during `start()` left Dispatch running and that overlapping
`start()` calls left two event consumers running every binding twice. Both
came from an in-flight start not being part of the runtime's state. The
`Lifecycle` enum now holds every task, including the start attempt, and
`stop()` waits for an in-flight start or reconnect before it disconnects.
`testStopWhileStartIsConnectingLeavesRuntimeStopped` and
`testOverlappingStartsHandleEachEventOnce` cover the two traces.

On 2026-09-30 the pad timed out on one lighting write while Herdr switched
machines, and the lights stayed off until Dispatch was turned off and on. The
model had no property about recovery, so it could not notice. The new
`LightingRecovers` property failed on the model as it was: a failed write left
`issue = "presentation"` forever while the heartbeat and events kept running,
because only another `apply` cleared it and AppModel had stopped applying.
The heartbeat now writes the latest requested lighting again while that issue
shows. `testHeartbeatRetriesFailedLightingOnceThePadAnswers` covers the trace.
