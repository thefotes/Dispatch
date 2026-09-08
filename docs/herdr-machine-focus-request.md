# Feature request: expose machine focus over the socket API

**Herdr version:** 0.9.0 (protocol 22)

## Summary

0.9 groups local and remote machines into one client window, but the socket
API has no concept of a machine. A client-side integration can therefore read
state across machines, yet cannot move the user's view to another machine.

## Evidence

`herdr api schema --json` on 0.9.0 lists 111 methods. The substring `machine`
appears nowhere in the schema. There is no `machine.list`, no `machine.focus`,
and no field on any existing method identifying which machine a workspace,
pane, or agent belongs to.

Meanwhile `herdr machine list` reports saved machines, and the client keeps a
per-machine socket at `$TMPDIR/herdr-ssh-<client-pid>-<machine-id>.sock` — so
the information exists in the client, just not over the API.

## Behaviour

Focus is per-server, and two servers report a focused entity simultaneously:

    LOCAL  focused_workspace_id: wB     (micro-manager)
    JARVIS focused workspace:    w1K    (SparkRun)

Calling `workspace.focus` or `agent.focus` against the remote server succeeds
and moves that server's focus:

    agent.focus w1J:p1 on Jarvis  ->  ok, Jarvis focus w1Z:p1 -> w1J:p1
    local snapshot, same moment   ->  focused_pane_id still wB:p1

The client never switches its displayed machine, so from the user's seat the
command silently does nothing.

## Why it matters

We drive a Work Louder Creator Micro macropad from Herdr. Reading state across
machines works well — the pad's underglow and per-key colors reflect agents on
both boxes, because that needs no view change. But:

- turning the dial past the end of one machine's spaces cannot land on the
  next machine's, and
- pressing a key bound to a remote agent cannot bring that agent on screen

Both issue the correct call, both succeed server-side, and neither is visible.
Any external controller — Stream Deck, macropad, editor plugin, script — hits
this the moment it tries to navigate rather than observe.

## Requested

Some way to ask the client to change the machine it is displaying. Either:

1. `machine.list` + `machine.focus <machine-id>`, using the ids already
   returned by `herdr machine list`; or
2. an optional `machine_id` parameter on the existing `workspace.focus` and
   `agent.focus`, so one call both selects the machine and focuses within it.

(2) is probably less surface area and would make existing integrations
machine-aware without new call sequencing.

Also useful: a `machine_id` field on `workspace.list` / `agent.list` results,
so a client can attribute entities without maintaining its own socket-to-machine
mapping.
