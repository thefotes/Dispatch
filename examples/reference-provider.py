#!/usr/bin/env python3
"""A complete Micromanager provider — no Herdr, no Swift.

Proves the provider protocol (docs/provider-protocol.md) is not
Swift-specific: this is under 150 lines of dependency-free Python, and it
answers every method HerdrProvider does. What it drives is a toy — a single
fake entity that alternates between two states on a timer, "focus" that just
prints, "inject" that just prints — but the wire behaviour is real, not a
mock: point config.json at this file and the agent-key row actually lights
up from it.

Run:
    python3 examples/reference-provider.py [socket-path]

With no socket-path argument, listens wherever WL_PROVIDER_BRIDGE_SOCKET
says, or ~/.config/micromanager/provider-bridge.sock — the same default
Swift's ProviderBridgePaths.defaultSocketPath() resolves to, so a
config.json {"provider": {"launch": "python3", "args": ["reference-provider.py"]}}
finds it with no extra wiring.
"""
import json
import os
import socket
import sys
import threading
import time

# Same effect numbering as OAI.Effect's rawValue in Sources/WLKit/OAIProtocol.swift.
EFFECT_SOLID = 1
EFFECT_BREATH = 4


def default_socket_path():
    explicit = os.environ.get("WL_PROVIDER_BRIDGE_SOCKET")
    if explicit:
        return explicit
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(base, "micromanager", "provider-bridge.sock")


class ReferenceProvider:
    """The toy behaviour: one entity, ticking between two states every 2s."""

    def __init__(self):
        self._lock = threading.Lock()
        self._subscribers = []   # list of callables, one per open events.subscribe connection
        self._tick = False
        threading.Thread(target=self._ticker, daemon=True).start()

    def _ticker(self):
        while True:
            time.sleep(2)
            with self._lock:
                self._tick = not self._tick
                subscribers = list(self._subscribers)
            for notify in subscribers:
                notify()

    def describe(self):
        return {
            "statePalette": {
                "tick": {"color": 0x00C853, "effect": EFFECT_SOLID},
                "tock": {"color": 0x2962FF, "effect": EFFECT_BREATH},
            },
            "statePriority": ["tock", "tick"],
            "dialModes": [{"id": "seconds", "label": "Seconds", "raisesHost": False}],
        }

    def status(self):
        with self._lock:
            state = "tock" if self._tick else "tick"
        return {"agents": [{"agent": "reference", "agent_status": state, "focused": True, "pane_id": "ref-1"}]}

    def focus(self, params):
        print(f"[reference-provider] focus: {params.get('target')}", file=sys.stderr)
        return {}

    def dial(self, params):
        print(f"[reference-provider] dial: step={params.get('step')} mode={params.get('mode')}", file=sys.stderr)
        return {}

    def inject(self, params):
        print(f"[reference-provider] inject: {params.get('text')!r}", file=sys.stderr)
        return {}

    def joystick(self, params):
        # The toy has no panes to move between, so a deflection is a no-op —
        # the protocol's answer for a provider without pane navigation.
        return {}

    def subscribe(self, notify):
        with self._lock:
            self._subscribers.append(notify)

        def unsubscribe():
            with self._lock:
                if notify in self._subscribers:
                    self._subscribers.remove(notify)

        return unsubscribe


def handle_connection(conn, provider):
    with conn:
        rfile = conn.makefile("r", encoding="utf-8")
        line = rfile.readline()
        if not line:
            return
        try:
            request = json.loads(line)
        except json.JSONDecodeError:
            return
        request_id = request.get("id", "req")
        method = request.get("method", "")
        params = request.get("params", {}) or {}

        if method == "events.subscribe":
            handle_subscription(conn, rfile, provider, request_id)
            return

        try:
            if method == "provider.describe":
                result = provider.describe()
            elif method == "provider.status":
                result = provider.status()
            elif method == "provider.focus":
                result = provider.focus(params)
            elif method == "provider.dial":
                result = provider.dial(params)
            elif method == "provider.inject":
                result = provider.inject(params)
            elif method == "provider.joystick":
                result = provider.joystick(params)
            else:
                raise ValueError(f"unknown method {method}")
            write_line(conn, {"id": request_id, "result": result})
        except Exception as error:  # noqa: BLE001 - a bad request should answer, not crash the server
            write_line(conn, {"id": request_id, "error": {"message": str(error)}})


def handle_subscription(conn, rfile, provider, request_id):
    write_line(conn, {"id": request_id, "result": {}})   # ack
    closed = threading.Event()

    def notify():
        if closed.is_set():
            return
        try:
            write_line(conn, {"event": True})
        except OSError:
            closed.set()

    unsubscribe = provider.subscribe(notify)
    try:
        rfile.readline()   # blocks until the peer disconnects; content is never sent
    except OSError:
        pass
    finally:
        closed.set()
        unsubscribe()


def write_line(conn, obj):
    conn.sendall((json.dumps(obj) + "\n").encode("utf-8"))


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else default_socket_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass

    provider = ReferenceProvider()
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(path)
    server.listen(8)
    print(f"reference-provider: listening at {path}", file=sys.stderr)

    try:
        while True:
            conn, _ = server.accept()
            threading.Thread(target=handle_connection, args=(conn, provider), daemon=True).start()
    except KeyboardInterrupt:
        pass
    finally:
        server.close()
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass


if __name__ == "__main__":
    main()
