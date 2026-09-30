-------------------------- MODULE RuntimeLifecycle --------------------------
(***************************************************************************)
(* A model of DispatchRuntime's lifecycle, from                           *)
(* Sources/DispatchRuntime/DispatchRuntime.swift.                          *)
(*                                                                         *)
(* DispatchRuntime is a Swift actor. Code between two `await`s runs        *)
(* without interruption, but every `await` lets another call or task run   *)
(* on the actor first. Each action below is one such uninterrupted         *)
(* segment, named after the method and the await it resumes from.          *)
(*                                                                         *)
(* Callers stand for the app's own Tasks (the enable toggle, configuration *)
(* reload, and presentation refresh), which call into the runtime          *)
(* concurrently. The runtime's own Tasks (start attempt, event consumer,   *)
(* heartbeat, reconnect) run off the actor and hop onto it to report back. *)
(* An actor method called from a task runs on that task, so its            *)
(* `Task.isCancelled` checks see that task's cancellation.                 *)
(*                                                                         *)
(* The model keeps only what affects the lifecycle: the `Lifecycle` case   *)
(* and the tasks it holds, which tasks are still running, whether the pad  *)
(* is connected, and the published phase and issue. Outcomes that depend   *)
(* on hardware or files (connect, health check, configuration load,        *)
(* lighting writes, actions) are chosen nondeterministically, so TLC       *)
(* explores both.                                                          *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Callers,    \* concurrent callers into the runtime
    MaxCalls,   \* bound on public calls, to keep the state space finite
    MaxTasks    \* bound on Tasks the runtime may create

NoTask == 0
TaskIds == 1..MaxTasks

Phases == {"disabled", "starting", "connecting", "operational", "degraded", "stopping"}
Issues == {"none", "configuration", "device", "action", "presentation"}
Lifecycles == {"idle", "awaitingConfig", "starting", "running", "reconnecting", "stopping"}
Kinds == {"unused", "start", "event", "heartbeat", "reconnect"}

CallerStates == {"idle", "startWait", "stopWait", "stopApply", "stopDisconnect",
                 "reloadLoad", "applyApply"}
TaskStates == {"unused", "done",
               \* start attempt (loadAndConnect): awaiting the configuration
               \* load or pad.connect(). "cleanup" is shared with reconnect:
               \* disconnecting after a connect that finished once cancelled.
               "loading", "connecting", "cleanup",
               \* event consumer: waiting for an event or stream completion,
               \* hopping onto the actor, or awaiting an action inside it
               "listening", "hopping", "executing",
               \* heartbeat: sleeping, awaiting checkHealth(), hopping onto
               \* the actor to call handleDeviceLoss(_:) or
               \* retryFailedPresentation(), or awaiting a retried write
               "sleeping", "checking", "lost", "retrying", "writing",
               \* reconnect: "sleeping" and "connecting" are shared;
               \* disconnecting after a device loss, hopping to
               \* recordReconnectFailure, or hopping to resumeAfterReconnect
               "disconnecting", "recording", "resuming"}

VARIABLES
    phase,          \* snapshot.phase
    issue,          \* snapshot.issue
    configured,     \* resolver != nil
    padConnected,   \* the device's connection, as the driver sees it
    lifecycle,      \* the Lifecycle case
    held,           \* the tasks that case holds
    kind,           \* what each task id was created as
    tpc,            \* where each task is suspended
    cancelled,      \* task ids that have been cancelled
    nextTask,       \* next unused task id
    pc,             \* where each caller is suspended
    waitFor,        \* the task a caller is awaiting `.value` of
    calls,          \* public calls made so far
    stopped         \* history: a stop() finished and no start() came since

taskVars == <<lifecycle, held, kind, tpc, cancelled, nextTask>>
callerVars == <<pc, waitFor, calls, stopped>>
vars == <<phase, issue, configured, padConnected, taskVars, callerVars>>

TypeOK ==
    /\ phase \in Phases
    /\ issue \in Issues
    /\ configured \in BOOLEAN
    /\ padConnected \in BOOLEAN
    /\ lifecycle \in Lifecycles
    /\ held \subseteq TaskIds
    /\ kind \in [TaskIds -> Kinds]
    /\ tpc \in [TaskIds -> TaskStates]
    /\ cancelled \subseteq TaskIds
    /\ nextTask \in 1..(MaxTasks + 1)
    /\ pc \in [Callers -> CallerStates]
    /\ waitFor \in [Callers -> TaskIds \cup {NoTask}]
    /\ calls \in 0..MaxCalls
    /\ stopped \in BOOLEAN

Init ==
    /\ phase = "disabled"
    /\ issue = "none"
    /\ configured = FALSE
    /\ padConnected = FALSE
    /\ lifecycle = "idle"
    /\ held = {}
    /\ kind = [t \in TaskIds |-> "unused"]
    /\ tpc = [t \in TaskIds |-> "unused"]
    /\ cancelled = {}
    /\ nextTask = 1
    /\ pc = [c \in Callers |-> "idle"]
    /\ waitFor = [c \in Callers |-> NoTask]
    /\ calls = 0
    /\ stopped = FALSE

HeldOfKind(k) == {t \in held : kind[t] = k}

(***************************************************************************)
(* Shared private methods. Each takes the task program counters the        *)
(* calling step has already updated, so the step can also finish itself.   *)
(***************************************************************************)

\* beginConsumingEvents()
BeginConsuming(tpcBase) ==
    /\ nextTask + 1 <= MaxTasks
    /\ LET e == nextTask
           h == nextTask + 1
       IN /\ phase' = "operational"
          /\ issue' = "none"
          /\ lifecycle' = "running"
          /\ held' = {e, h}
          /\ kind' = [kind EXCEPT ![e] = "event", ![h] = "heartbeat"]
          /\ tpc' = [tpcBase EXCEPT ![e] = "listening", ![h] = "sleeping"]
          /\ nextTask' = nextTask + 2

\* scheduleReconnect(disconnectingFirst:)
ScheduleReconnect(tpcBase, disconnectingFirst) ==
    /\ nextTask <= MaxTasks
    /\ lifecycle' = "reconnecting"
    /\ held' = {nextTask}
    /\ kind' = [kind EXCEPT ![nextTask] = "reconnect"]
    /\ tpc' = [tpcBase EXCEPT ![nextTask] =
                 IF disconnectingFirst THEN "disconnecting" ELSE "sleeping"]
    /\ nextTask' = nextTask + 1

\* The phase to report once nothing is wrong (settledPhase).
SettledPhase ==
    CASE lifecycle = "idle" -> "disabled"
      [] lifecycle = "running" -> "operational"
      [] lifecycle = "reconnecting" -> "connecting"
      [] OTHER -> phase

(***************************************************************************)
(* start()                                                                 *)
(***************************************************************************)

StartInvoke(c) ==
    /\ pc[c] = "idle"
    /\ calls < MaxCalls
    /\ calls' = calls + 1
    /\ stopped' = FALSE
    /\ IF lifecycle = "idle" /\ nextTask <= MaxTasks
       THEN LET s == nextTask
            IN /\ phase' = "starting"
               /\ issue' = "none"
               /\ lifecycle' = "starting"
               /\ held' = {s}
               /\ kind' = [kind EXCEPT ![s] = "start"]
               /\ tpc' = [tpc EXCEPT ![s] = "loading"]
               /\ nextTask' = nextTask + 1
               /\ pc' = [pc EXCEPT ![c] = "startWait"]
               /\ waitFor' = [waitFor EXCEPT ![c] = s]
       ELSE UNCHANGED <<phase, issue, taskVars, pc, waitFor>>
    /\ UNCHANGED <<configured, padConnected, cancelled>>

\* `await attempt.value` returns.
StartReturn(c) ==
    /\ pc[c] = "startWait"
    /\ tpc[waitFor[c]] = "done"
    /\ pc' = [pc EXCEPT ![c] = "idle"]
    /\ waitFor' = [waitFor EXCEPT ![c] = NoTask]
    /\ UNCHANGED <<phase, issue, configured, padConnected, taskVars, calls, stopped>>

\* loadAndConnect() resumes from `await configurationLoader.load()`.
\* installConfiguration() installs a loaded configuration before the
\* cancellation check.
StartLoaded(s) ==
    /\ kind[s] = "start"
    /\ tpc[s] = "loading"
    /\ \/ /\ s \in cancelled
          /\ tpc' = [tpc EXCEPT ![s] = "done"]
          /\ \/ UNCHANGED configured
             \/ configured' = TRUE
          /\ UNCHANGED <<phase, issue, lifecycle, held>>
       \* No valid configuration: stay on and wait for a reload.
       \/ /\ s \notin cancelled
          /\ tpc' = [tpc EXCEPT ![s] = "done"]
          /\ phase' = "degraded"
          /\ issue' = "configuration"
          /\ lifecycle' = "awaitingConfig"
          /\ held' = {}
          /\ UNCHANGED configured
       \/ /\ s \notin cancelled
          /\ tpc' = [tpc EXCEPT ![s] = "connecting"]
          /\ configured' = TRUE
          /\ phase' = "connecting"
          /\ issue' = "none"
          /\ UNCHANGED <<lifecycle, held>>
    /\ UNCHANGED <<padConnected, kind, cancelled, nextTask, callerVars>>

\* loadAndConnect() resumes from `await pad.connect()`. A failed connect is
\* assumed to leave the driver's connection as it was.
StartConnected(s) ==
    /\ kind[s] = "start"
    /\ tpc[s] = "connecting"
    /\ \/ /\ s \in cancelled
          /\ tpc' = [tpc EXCEPT ![s] = "done"]
          /\ UNCHANGED <<phase, issue, padConnected, lifecycle, held, kind, nextTask>>
       \/ /\ s \in cancelled
          /\ padConnected' = TRUE
          /\ tpc' = [tpc EXCEPT ![s] = "cleanup"]
          /\ UNCHANGED <<phase, issue, lifecycle, held, kind, nextTask>>
       \/ /\ s \notin cancelled
          /\ phase' = "degraded"
          /\ issue' = "device"
          /\ ScheduleReconnect([tpc EXCEPT ![s] = "done"], FALSE)
          /\ UNCHANGED padConnected
       \/ /\ s \notin cancelled
          /\ padConnected' = TRUE
          /\ BeginConsuming([tpc EXCEPT ![s] = "done"])
    /\ UNCHANGED <<configured, cancelled, callerVars>>

\* `await pad.disconnect()` after a connect that finished once cancelled.
Cleanup(t) ==
    /\ kind[t] \in {"start", "reconnect"}
    /\ tpc[t] = "cleanup"
    /\ padConnected' = FALSE
    /\ tpc' = [tpc EXCEPT ![t] = "done"]
    /\ UNCHANGED <<phase, issue, configured, lifecycle, held, kind, cancelled,
                   nextTask, callerVars>>

(***************************************************************************)
(* stop()                                                                  *)
(***************************************************************************)

StopInvoke(c) ==
    /\ pc[c] = "idle"
    /\ calls < MaxCalls
    /\ calls' = calls + 1
    /\ IF lifecycle = "stopping" \/ (lifecycle = "idle" /\ phase = "disabled")
       THEN UNCHANGED <<phase, issue, lifecycle, held, cancelled, pc, waitFor, stopped>>
       ELSE /\ phase' = "stopping"
            /\ issue' = "none"
            /\ lifecycle' = "stopping"
            /\ held' = {}
            /\ cancelled' = cancelled \cup held
            /\ stopped' = FALSE
            /\ IF lifecycle \in {"starting", "reconnecting"}
               THEN /\ pc' = [pc EXCEPT ![c] = "stopWait"]
                    /\ waitFor' = [waitFor EXCEPT ![c] = CHOOSE t \in held : TRUE]
               ELSE /\ pc' = [pc EXCEPT ![c] = "stopApply"]
                    /\ UNCHANGED waitFor
    /\ UNCHANGED <<configured, padConnected, kind, tpc, nextTask>>

\* `await task.value` for the start attempt or reconnect task returns.
StopWaited(c) ==
    /\ pc[c] = "stopWait"
    /\ tpc[waitFor[c]] = "done"
    /\ pc' = [pc EXCEPT ![c] = "stopApply"]
    /\ waitFor' = [waitFor EXCEPT ![c] = NoTask]
    /\ UNCHANGED <<phase, issue, configured, padConnected, taskVars, calls, stopped>>

\* Resumes from `await pad.apply(PadPresentation())`.
StopApplied(c) ==
    /\ pc[c] = "stopApply"
    /\ pc' = [pc EXCEPT ![c] = "stopDisconnect"]
    /\ \/ UNCHANGED <<phase, issue>>
       \/ /\ phase' = "degraded"
          /\ issue' = "presentation"
    /\ UNCHANGED <<configured, padConnected, taskVars, waitFor, calls, stopped>>

\* Resumes from `await pad.disconnect()`.
StopDisconnected(c) ==
    /\ pc[c] = "stopDisconnect"
    /\ pc' = [pc EXCEPT ![c] = "idle"]
    /\ padConnected' = FALSE
    /\ configured' = FALSE
    /\ lifecycle' = "idle"
    /\ phase' = "disabled"
    /\ issue' = "none"
    /\ stopped' = TRUE
    /\ UNCHANGED <<held, kind, tpc, cancelled, nextTask, waitFor, calls>>

(***************************************************************************)
(* reloadConfiguration()                                                   *)
(***************************************************************************)

ReloadInvoke(c) ==
    /\ pc[c] = "idle"
    /\ calls < MaxCalls
    /\ calls' = calls + 1
    /\ pc' = [pc EXCEPT ![c] = "reloadLoad"]
    /\ UNCHANGED <<phase, issue, configured, padConnected, taskVars, waitFor, stopped>>

\* Resumes from `await configurationLoader.load()`.
ReloadLoaded(c) ==
    /\ pc[c] = "reloadLoad"
    /\ \/ /\ pc' = [pc EXCEPT ![c] = "idle"]
          /\ phase' = "degraded"
          /\ issue' = "configuration"
          /\ UNCHANGED <<configured, taskVars, waitFor>>
       \/ /\ lifecycle /= "awaitingConfig"
          /\ pc' = [pc EXCEPT ![c] = "idle"]
          /\ configured' = TRUE
          /\ phase' = SettledPhase
          /\ issue' = "none"
          /\ UNCHANGED <<taskVars, waitFor>>
       \* start() was waiting for a configuration: finish starting on a new
       \* attempt task running connectPad(), and await it as start() does.
       \* The task begins at `await pad.connect()`; its cancellation check
       \* before connecting is StartConnected's cancelled, unconnected case.
       \/ /\ lifecycle = "awaitingConfig"
          /\ nextTask <= MaxTasks
          /\ LET s == nextTask
             IN /\ configured' = TRUE
                /\ phase' = "connecting"
                /\ issue' = "none"
                /\ lifecycle' = "starting"
                /\ held' = {s}
                /\ kind' = [kind EXCEPT ![s] = "start"]
                /\ tpc' = [tpc EXCEPT ![s] = "connecting"]
                /\ nextTask' = nextTask + 1
                /\ pc' = [pc EXCEPT ![c] = "startWait"]
                /\ waitFor' = [waitFor EXCEPT ![c] = s]
                /\ UNCHANGED cancelled
    /\ UNCHANGED <<padConnected, calls, stopped>>

(***************************************************************************)
(* apply(_:)                                                               *)
(***************************************************************************)

ApplyInvoke(c) ==
    /\ pc[c] = "idle"
    /\ calls < MaxCalls
    /\ calls' = calls + 1
    /\ IF lifecycle = "running"
       THEN pc' = [pc EXCEPT ![c] = "applyApply"]
       ELSE UNCHANGED pc
    /\ UNCHANGED <<phase, issue, configured, padConnected, taskVars, waitFor, stopped>>

\* Resumes from `await pad.apply(presentation)`. A lighting write can only
\* succeed while the pad is connected.
ApplyDone(c) ==
    /\ pc[c] = "applyApply"
    /\ pc' = [pc EXCEPT ![c] = "idle"]
    /\ \/ /\ padConnected
          /\ IF lifecycle = "running" /\ issue = "presentation"
             THEN phase' = "operational" /\ issue' = "none"
             ELSE UNCHANGED <<phase, issue>>
       \/ /\ lifecycle = "running"
          /\ phase' = "degraded"
          /\ issue' = "presentation"
       \/ /\ lifecycle /= "running"
          /\ UNCHANGED <<phase, issue>>
    /\ UNCHANGED <<configured, padConnected, taskVars, waitFor, calls, stopped>>

(***************************************************************************)
(* Event consumer task                                                     *)
(***************************************************************************)

TaskOnly == <<phase, issue, configured, padConnected, lifecycle, held, kind,
              cancelled, nextTask, callerVars>>

\* `for await event in events`: a cancelled consumer's stream ends; a live
\* one may receive an event or see its stream end. Stream completion reports
\* device loss even if the pad still appears connected to the runtime.
EventNext(t) ==
    /\ kind[t] = "event"
    /\ tpc[t] = "listening"
    /\ \/ /\ t \in cancelled
          /\ tpc' = [tpc EXCEPT ![t] = "done"]
       \/ /\ t \notin cancelled
          /\ padConnected
          /\ tpc' = [tpc EXCEPT ![t] = "hopping"]
       \/ /\ t \notin cancelled
          /\ tpc' = [tpc EXCEPT ![t] = "lost"]
    /\ UNCHANGED TaskOnly

\* handle(_:) up to `await registry.execute(action)`.
HandleBegin(t) ==
    /\ kind[t] = "event"
    /\ tpc[t] = "hopping"
    /\ tpc' = [tpc EXCEPT ![t] = IF configured THEN "executing" ELSE "listening"]
    /\ UNCHANGED TaskOnly

\* recordHandledEvent(executedAction:failure:) once the actions finish or
\* one fails. Only a running runtime lets the outcome change the phase.
HandleEnd(t) ==
    /\ kind[t] = "event"
    /\ tpc[t] = "executing"
    /\ tpc' = [tpc EXCEPT ![t] = "listening"]
    /\ IF lifecycle /= "running"
       THEN UNCHANGED <<phase, issue>>
       ELSE \/ /\ phase' = "degraded"
               /\ issue' = "action"
            \/ /\ issue = "action"
               /\ phase' = "operational"
               /\ issue' = "none"
            \/ /\ issue /= "action"
               /\ phase' = IF phase = "degraded" THEN "degraded" ELSE "operational"
               /\ UNCHANGED issue
    /\ UNCHANGED <<configured, padConnected, lifecycle, held, kind, cancelled,
                   nextTask, callerVars>>

(***************************************************************************)
(* Heartbeat task: monitorDeviceHealth() and handleDeviceLoss(_:)          *)
(***************************************************************************)

\* `try await Task.sleep` throws CancellationError once cancelled; otherwise
\* the task passes its guard and calls checkHealth().
HeartbeatWake(t) ==
    /\ kind[t] = "heartbeat"
    /\ tpc[t] = "sleeping"
    /\ tpc' = [tpc EXCEPT ![t] = IF t \in cancelled THEN "done" ELSE "checking"]
    /\ UNCHANGED TaskOnly

\* Resumes from `await pad.checkHealth()`. It succeeds only while connected;
\* it may fail at any time (the pad was unplugged). A cancelled check may
\* also end with CancellationError.
HeartbeatChecked(t) ==
    /\ kind[t] = "heartbeat"
    /\ tpc[t] = "checking"
    /\ \/ /\ padConnected
          /\ tpc' = [tpc EXCEPT ![t] = "retrying"]
       \/ tpc' = [tpc EXCEPT ![t] = "lost"]
       \/ /\ t \in cancelled
          /\ tpc' = [tpc EXCEPT ![t] = "done"]
    /\ UNCHANGED TaskOnly

\* retryFailedPresentation() on the actor, up to write(_:)'s
\* `try await pad.apply(presentation)`. A presentation issue while running
\* comes from a failed write, so a requested presentation exists.
HeartbeatRetry(t) ==
    /\ kind[t] = "heartbeat"
    /\ tpc[t] = "retrying"
    /\ tpc' = [tpc EXCEPT ![t] =
                 IF t \notin cancelled /\ issue = "presentation" /\ lifecycle = "running"
                 THEN "writing"
                 ELSE "sleeping"]
    /\ UNCHANGED TaskOnly

\* Resumes from the retried write, which ends as ApplyDone's does. A write
\* can only succeed while the pad is connected.
HeartbeatWriteSucceeded(t) ==
    /\ kind[t] = "heartbeat"
    /\ tpc[t] = "writing"
    /\ padConnected
    /\ tpc' = [tpc EXCEPT ![t] = "sleeping"]
    /\ IF lifecycle = "running" /\ issue = "presentation"
       THEN phase' = "operational" /\ issue' = "none"
       ELSE UNCHANGED <<phase, issue>>
    /\ UNCHANGED <<configured, padConnected, lifecycle, held, kind, cancelled,
                   nextTask, callerVars>>

HeartbeatWriteFailed(t) ==
    /\ kind[t] = "heartbeat"
    /\ tpc[t] = "writing"
    /\ tpc' = [tpc EXCEPT ![t] = "sleeping"]
    /\ IF lifecycle = "running"
       THEN phase' = "degraded" /\ issue' = "presentation"
       ELSE UNCHANGED <<phase, issue>>
    /\ UNCHANGED <<configured, padConnected, lifecycle, held, kind, cancelled,
                   nextTask, callerVars>>

\* handleDeviceLoss(_:) on the actor, on the heartbeat or event task.
DeviceLoss(t) ==
    /\ kind[t] \in {"heartbeat", "event"}
    /\ tpc[t] = "lost"
    /\ IF t \in cancelled \/ lifecycle /= "running"
       THEN /\ tpc' = [tpc EXCEPT ![t] = "done"]
            /\ UNCHANGED <<phase, issue, lifecycle, held, kind, cancelled, nextTask>>
       ELSE /\ cancelled' = cancelled \cup held
            /\ phase' = "degraded"
            /\ issue' = "device"
            /\ ScheduleReconnect([tpc EXCEPT ![t] = "done"], TRUE)
    /\ UNCHANGED <<configured, padConnected, callerVars>>

(***************************************************************************)
(* Reconnect task: scheduleReconnect(disconnectingFirst:)'s loop           *)
(***************************************************************************)

ReconnectDisconnected(t) ==
    /\ kind[t] = "reconnect"
    /\ tpc[t] = "disconnecting"
    /\ padConnected' = FALSE
    /\ tpc' = [tpc EXCEPT ![t] = "sleeping"]
    /\ UNCHANGED <<phase, issue, configured, lifecycle, held, kind, cancelled,
                   nextTask, callerVars>>

ReconnectWake(t) ==
    /\ kind[t] = "reconnect"
    /\ tpc[t] = "sleeping"
    /\ tpc' = [tpc EXCEPT ![t] = IF t \in cancelled THEN "done" ELSE "connecting"]
    /\ UNCHANGED TaskOnly

\* Resumes from `try await pad.connect()`.
ReconnectConnected(t) ==
    /\ kind[t] = "reconnect"
    /\ tpc[t] = "connecting"
    /\ \/ /\ padConnected' = TRUE
          /\ tpc' = [tpc EXCEPT ![t] = "resuming"]
       \/ /\ tpc' = [tpc EXCEPT ![t] = "recording"]
          /\ UNCHANGED padConnected
    /\ UNCHANGED <<phase, issue, configured, lifecycle, held, kind, cancelled,
                   nextTask, callerVars>>

\* recordReconnectFailure(_:) on the actor, then back to the loop.
ReconnectRecordFailure(t) ==
    /\ kind[t] = "reconnect"
    /\ tpc[t] = "recording"
    /\ tpc' = [tpc EXCEPT ![t] = "sleeping"]
    /\ IF t \in cancelled
       THEN UNCHANGED <<phase, issue>>
       ELSE phase' = "degraded" /\ issue' = "device"
    /\ UNCHANGED <<configured, padConnected, lifecycle, held, kind, cancelled,
                   nextTask, callerVars>>

\* resumeAfterReconnect() on the actor.
ReconnectResume(t) ==
    /\ kind[t] = "reconnect"
    /\ tpc[t] = "resuming"
    /\ IF t \in cancelled
       THEN /\ tpc' = [tpc EXCEPT ![t] = "cleanup"]
            /\ UNCHANGED <<phase, issue, lifecycle, held, kind, nextTask>>
       ELSE BeginConsuming([tpc EXCEPT ![t] = "done"])
    /\ UNCHANGED <<configured, padConnected, cancelled, callerVars>>

(***************************************************************************)

TaskStep(t) ==
    \/ StartLoaded(t) \/ StartConnected(t) \/ Cleanup(t)
    \/ EventNext(t) \/ HandleBegin(t) \/ HandleEnd(t)
    \/ HeartbeatWake(t) \/ HeartbeatChecked(t) \/ DeviceLoss(t)
    \/ HeartbeatRetry(t) \/ HeartbeatWriteSucceeded(t) \/ HeartbeatWriteFailed(t)
    \/ ReconnectDisconnected(t) \/ ReconnectWake(t) \/ ReconnectConnected(t)
    \/ ReconnectRecordFailure(t) \/ ReconnectResume(t)

Next ==
    \/ \E c \in Callers :
        \/ StartInvoke(c) \/ StartReturn(c)
        \/ StopInvoke(c) \/ StopWaited(c) \/ StopApplied(c) \/ StopDisconnected(c)
        \/ ReloadInvoke(c) \/ ReloadLoaded(c)
        \/ ApplyInvoke(c) \/ ApplyDone(c)
    \/ \E t \in TaskIds : TaskStep(t)

Spec == Init /\ [][Next]_vars

(***************************************************************************)
(* Properties the runtime should keep in every reachable state.            *)
(***************************************************************************)

Running(k) == {t \in TaskIds : kind[t] = k /\ tpc[t] \notin {"unused", "done"}}
Live(k) == Running(k) \ cancelled

\* Two live consumers would run every binding twice.
AtMostOneEventConsumer == Cardinality(Live("event")) <= 1

\* Every live task is one the lifecycle holds, so stop() can cancel it.
NoOrphanTasks ==
    \A k \in Kinds \ {"unused"} : Live(k) \subseteq held

\* The lifecycle holds exactly the tasks its case describes.
HeldMatchesLifecycle ==
    CASE lifecycle \in {"idle", "awaitingConfig", "stopping"} -> held = {}
      [] lifecycle = "starting" -> Cardinality(HeldOfKind("start")) = 1 /\ held = HeldOfKind("start")
      [] lifecycle = "reconnecting" -> Cardinality(HeldOfKind("reconnect")) = 1 /\ held = HeldOfKind("reconnect")
      [] lifecycle = "running" -> Cardinality(HeldOfKind("event")) = 1
                                  /\ Cardinality(HeldOfKind("heartbeat")) = 1
                                  /\ held = HeldOfKind("event") \cup HeldOfKind("heartbeat")

\* The menu bar never shows Operational unless a connection is consumed.
OperationalIsTruthful == phase = "operational" => lifecycle = "running"

\* While start() waits for a valid configuration, the panel says why.
AwaitingShowsConfigurationError ==
    lifecycle = "awaitingConfig" => phase = "degraded" /\ issue = "configuration"

\* Once stop() finishes, nothing brings the runtime or the pad back until
\* the next start(). A configuration error from a reload may still show.
StoppedStaysStopped ==
    stopped =>
        /\ lifecycle = "idle"
        /\ ~padConnected
        /\ \/ phase = "disabled"
           \/ phase = "degraded" /\ issue = "configuration"

(***************************************************************************)
(* Liveness. Both properties assume every suspended caller and task        *)
(* eventually resumes, which holds while the pad's calls time out.         *)
(* LightingRecovers also assumes a pad that stays connected eventually     *)
(* accepts a retried lighting write: a pad that rejects every write stays  *)
(* degraded, which is the truthful report.                                 *)
(***************************************************************************)

StopStep(c) == StopWaited(c) \/ StopApplied(c) \/ StopDisconnected(c)

FairSpec ==
    /\ Spec
    /\ \A c \in Callers : WF_vars(StopStep(c))
    /\ \A t \in TaskIds : WF_vars(TaskStep(t))
    /\ \A t \in TaskIds : SF_vars(HeartbeatWriteSucceeded(t))

\* stop() always returns, so the app can always quit.
StopReturns ==
    \A c \in Callers : pc[c] \in {"stopWait", "stopApply", "stopDisconnect"} ~> pc[c] = "idle"

\* A failed lighting write does not leave the pad dark. While the runtime
\* stays running, the presentation issue clears by itself, without relying
\* on a caller to apply again: AppModel applies again only once Herdr's
\* state changes, which may not happen for a long time.
\*
\* A behavior that spends its task budget ends there: a lost pad cannot
\* schedule its reconnect task, so the model stops in a state the runtime,
\* which has no such budget, never stops in.
LightingRecovers ==
    lifecycle = "running" /\ issue = "presentation"
        ~> \/ issue /= "presentation"
           \/ lifecycle /= "running"
           \/ nextTask > MaxTasks

=============================================================================
