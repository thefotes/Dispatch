#!/bin/bash
# Keep a local unix socket forwarded to a remote machine's Herdr server
# socket over SSH, so Micromanager can treat that machine as a second
# Herdr instance (config.json's `herdr.instances`).
#
#   ./scripts/herdr-tunnel.sh                  # forward "jarvis"
#   ./scripts/herdr-tunnel.sh <host> [remote-socket-path] [local-socket-path]
#
# Installed as a LaunchAgent (see the plist snippet in docs or the
# install flags below) it survives sleep, restarts, and SSH drops: ssh
# exits on any interruption and the loop reconnects after a short pause.
#
#   ./scripts/herdr-tunnel.sh --install        # install + start the agent
#   ./scripts/herdr-tunnel.sh --uninstall      # stop + remove the agent
#
# The local socket lives under $TMPDIR because macOS caps sockaddr_un at
# 104 bytes and the per-user temp dir is already deep.

set -u

cd "$(dirname "$0")/.."

LABEL="cc.worklouder.herdr-tunnel"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

default_local_path() {
    echo "${TMPDIR:-/tmp}/herdr-${1//\//_}.sock"
}

uninstall() {
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
    rm -f "$PLIST"
    echo "Removed $LABEL"
}

if [[ "${1:-}" == "--uninstall" ]]; then
    uninstall
    exit 0
fi

if [[ "${1:-}" == "--install" ]]; then
    HOST="${2:-${HERDR_TUNNEL_HOST:-jarvis}}"
    REMOTE="${3:-${HERDR_TUNNEL_REMOTE:-}}"
    LOCAL="${4:-$(default_local_path "$HOST")}"
    # LaunchAgents cannot execute from TCC-protected folders (Documents,
    # Desktop, Downloads), and a repo usually lives in one — so the script
    # is copied somewhere launchd can run.
    INSTALL_DIR="$HOME/.local/bin"
    SCRIPT="$INSTALL_DIR/herdr-tunnel.sh"
    mkdir -p "$INSTALL_DIR"
    cp "$(cd "$(dirname "$0")" && pwd)/herdr-tunnel.sh" "$SCRIPT"
    chmod +x "$SCRIPT"
    mkdir -p "$(dirname "$PLIST")"
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$SCRIPT</string>
        <string>$HOST</string>
        <string>$REMOTE</string>
        <string>$LOCAL</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>$TMPDIR/herdr-tunnel.log</string>
    <key>StandardErrorPath</key><string>$TMPDIR/herdr-tunnel.log</string>
</dict>
</plist>
EOF
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    echo "Installed $LABEL — forwarding $HOST to $LOCAL"
    echo 'Add this machine as an instance in ~/.config/micromanager/config.json:'
    echo "  { \"id\": \"$HOST\", \"name\": \"$HOST\", \"socket_path\": \"$LOCAL\" }"
    exit 0
fi

HOST="${1:-${HERDR_TUNNEL_HOST:-jarvis}}"
REMOTE="${2:-${HERDR_TUNNEL_REMOTE:-}}"
LOCAL="${3:-$(default_local_path "$HOST")}"

# Default remote path: Herdr's socket in the remote account's config dir.
# The path is resolved on the remote, so ask it for its own home rather
# than assuming it matches the local one. Failure returns nonzero and
# leaves $REMOTE empty — the caller retries, because a remote that is
# down when launchd starts the agent (the common case after a reboot)
# must not poison the path for every reconnect forever after.
resolve_remote() {
    [[ -n "$REMOTE" ]] && return 0
    local home
    home="$(ssh -o ConnectTimeout=10 "$HOST" 'echo -n $HOME' 2>/dev/null)" || return 1
    [[ -n "$home" ]] || return 1
    REMOTE="$home/.config/herdr/herdr.sock"
    echo "$(date '+%F %T') resolved remote socket: $HOST:$REMOTE" >&2
}

while true; do
    if ! resolve_remote; then
        echo "$(date '+%F %T') cannot reach $HOST to resolve its socket path; retrying in 5s" >&2
        sleep 5
        continue
    fi
    rm -f "$LOCAL"
    # -N no remote command; -L local unix socket -> remote unix socket.
    # ExitOnForwardFailure so a bind failure loops into a retry instead of
    # idling with no forward at all. ServerAliveInterval notices a dead
    # connection within ~45s instead of hanging until TCP gives up.
    ssh -N \
        -o ExitOnForwardFailure=yes \
        -o ServerAliveInterval=15 \
        -o ServerAliveCountMax=3 \
        -o ConnectTimeout=10 \
        -L "$LOCAL:$REMOTE" \
        "$HOST"
    # The remote's home could differ next time (account moved, Herdr's
    # config path changed) — re-resolve rather than trusting the old one.
    REMOTE=""
    echo "$(date '+%F %T') tunnel to $HOST dropped; reconnecting in 5s" >&2
    sleep 5
done
