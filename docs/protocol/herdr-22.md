# Herdr API protocol 22 subset

This integration contract was derived from the installed Herdr JSON Schema
produced by `herdr api schema` on 2026-09-23. Dispatch deliberately implements
only the operations it uses.

Herdr exchanges newline-delimited JSON objects over its Unix socket. Requests
contain a client-generated string `id`, a `method`, and a `params` object.
Success responses echo `id` and contain `result`; error responses echo `id`
and contain an error code and message. A client must reject a mismatched
response identifier and bound both response size and wait time.

Herdr answers one request per connection and then closes it; a second request
written to the same connection receives no response (observed with Herdr
0.9.1). A client therefore opens a new connection for each request.

The implemented protocol-22 methods are:

| Method | Parameters | Use |
| --- | --- | --- |
| `session.snapshot` | `{}` | Read workspaces, tabs, panes, and agents |
| `agent.focus` | `target` | Focus an agent by live name or pane ID |
| `pane.close` | `pane_id` | Close a specific pane |
| `pane.focus_direction` | `direction`, optional `pane_id` | Navigate pane focus |
| `tab.focus` | `tab_id` | Focus a specific tab |
| `workspace.create` | `focus` | Create a workspace |
| `pane.split` | `target_pane_id`, `direction` (`right` or `down`), `focus` | Split a pane |
| `pane.send_text` | `pane_id`, `text` | Type text without submitting it |
| `pane.send_keys` | `pane_id`, `keys` | Send named keys, such as `backspace` |
| `pane.read` | `pane_id`, `source` (`visible`) | Read the pane's visible text (`result.read.text`) |

Observed with Herdr 0.9.1: `backspace` is an accepted key name and several
keys may be sent in one request; closing a workspace's last pane also closes
the workspace.

Pane directions are `left`, `right`, `up`, and `down`. Public Herdr identifiers
are opaque strings and must never be derived from display order.

Dispatch also exposes semantic, Herdr-specific actions such as focusing an
agent slot or closing the focused pane. Each press first takes a fresh
`session.snapshot`, because focus can move inside Herdr between polls, and
resolves against it before encoding one of the concrete API methods above.
They remain in the `herdr.*` action namespace because their semantics have not
been generalized to other providers.

The configurable `herdr.pane.sendKeys` action encodes `pane.send_keys` with
`pane_id` and the ordered `keys` array. Its optional `paneID` is resolved from a
fresh snapshot's focused pane when omitted; an explicit ID is sent directly.
Keys use Herdr's key-combo syntax (for example `esc`, `ctrl+z`, or `shift+tab`),
validated by Herdr. Key sending controls terminal input and provides no
agent-independent pause or resume operation.

Observed with Herdr 0.9.1: the snapshot's `workspaces` entries carry
`workspace_id` and a display `label`, and each `agents` entry carries its
`workspace_id`, its `agent` kind (such as `claude`, `codex`, or `opencode`),
and `terminal_title_stripped`, the title the agent program set for its
terminal.

Herdr's window, not its server, decides which connected machine it shows.
Local, saved SSH machines, and their combined agent and workspace lists exist
only in the window, and protocol 22 has no method that moves it (Herdr's
"Connecting machines" documentation, 0.9.1). The window's unbound-by-default
`previous_agent`, `next_agent`, `previous_workspace`, and `next_workspace`
key bindings walk every connected machine in sidebar order, so Dispatch's
`herdr.agent.cycle` and `herdr.workspace.cycle` press those keys instead of
sending a request. `herdr --machine <label> ...` reaches a saved machine's
server but never moves the window.

Observed with Herdr 0.9.1, not documented: the window records the machine it
shows in `~/.local/state/herdr/client/endpoint-selection.json` and rewrites it
as the window switches. `selected_profile` is `null` for Local, or the ID of a
saved machine listed with its SSH `target` and `session` in `endpoints.json`
in the same directory. Dispatch reads it before every request and sends the
request to that machine's server, forwarding the remote socket
(`${XDG_CONFIG_HOME:-$HOME/.config}/herdr/herdr.sock` for the default session)
over one long-lived `ssh -N -L`. A snapshot through the forward takes about
0.1 s, against about 2 s for `herdr --machine`. A missing selection file
means Local; one that exists but cannot be read fails the request, because
guessing Local would act on the wrong machine.

Observed on 2026-09-24 with Herdr 0.9.1 and the F16–F19 bindings above:
Dispatch's synthetic F17 and F18 move Herdr's workspace in Ghostty and in
iTerm2. In Terminal.app (macOS 26.6), the same F18 reaches the terminal, and
`cat -v` shows it as `ESC [ 3 2 ~`, but Herdr does not act on it.

Herdr agent states are `idle`, `working`, `blocked`, `done`, and `unknown`.
Snapshot reads do not mark an agent seen. Explicit focus operations may affect
Herdr's seen state.
