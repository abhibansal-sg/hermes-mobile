#!/usr/bin/env python3
"""watcher.py — external polling fallback for the hermes-mobile push pipeline.

THE FALLBACK PATH, not the preferred one. On cores that ship the tui-gateway
observer hooks (``post_emit_event`` et al., see CONTRACT-DEPATCH.md), the
plugin receives events in-process with zero latency and this script is
unnecessary. Run it only against a host whose core predates the hooks.

Expected latency = the poll interval (default 5s): an approval push can
arrive up to ``--interval`` seconds after the agent blocks. The in-process
hook path delivers in milliseconds.

What it polls (all plugin-owned REST, no core endpoints):
  - GET  /api/plugins/hermes-mobile/sessions                 (session list)
  - GET  /api/plugins/hermes-mobile/sessions/{sid}/messages  (max_id delta)
What it fires on delta:
  - POST /api/plugins/hermes-mobile/notify                   (push pipeline)

Auth: the same ``X-Hermes-Session-Token`` header the plugin's other
endpoints accept. Pass the token via the HERMES_WATCHER_TOKEN environment
variable — NEVER on the command line (visible in `ps`). The token is never
logged.

Usage:
    HERMES_WATCHER_TOKEN=... python3 watcher.py --base http://127.0.0.1:9119 [--interval 5]

Stdlib only: urllib, json, time, argparse, os, sys.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

SESSION_HEADER = "X-Hermes-Session-Token"  # hermes_cli/web_server.py:275
PLUGIN_BASE = "/api/plugins/hermes-mobile"


def build_headers(token: str) -> dict:
    """Auth headers for every request. Token comes from env, never argv."""
    return {SESSION_HEADER: token, "Content-Type": "application/json"}


def fetch_json(base: str, path: str, token: str, timeout: float = 10.0):
    req = urllib.request.Request(base + path, headers=build_headers(token))
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def post_json(base: str, path: str, token: str, body: dict, timeout: float = 10.0):
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        base + path, data=data, headers=build_headers(token), method="POST"
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def detect_deltas(prev: dict, current: dict) -> list:
    """Diff two {session_id: max_id} snapshots into notify events.

    A session whose max_id advanced produced new messages since the last
    poll → one ``turn_complete`` notify per changed session (the push
    engine's own event de-dup handles over-notification).
    New sessions are recorded but NOT notified on first sight — their
    baseline is unknown, and pushing for pre-existing history would spam.
    """
    events = []
    for sid, max_id in current.items():
        if sid in prev and max_id != prev[sid]:
            events.append(
                {
                    "event": "turn_complete",
                    "session_id": sid,
                    "payload": {"max_id": max_id, "source": "watcher"},
                }
            )
    return events


def snapshot(base: str, token: str) -> dict:
    """Build {session_id: max_id} for every listed session."""
    sessions = fetch_json(base, f"{PLUGIN_BASE}/sessions", token)
    items = sessions.get("sessions", sessions) if isinstance(sessions, dict) else sessions
    snap = {}
    for s in items or []:
        sid = s.get("session_id") or s.get("id")
        if not sid:
            continue
        try:
            delta = fetch_json(
                base, f"{PLUGIN_BASE}/sessions/{sid}/messages?prefix_count=0", token
            )
            snap[sid] = delta.get("max_id")
        except urllib.error.HTTPError:
            continue
    return snap


def run_loop(base: str, token: str, interval: float) -> None:
    prev: dict = {}
    first = True
    while True:
        try:
            current = snapshot(base, token)
            if not first:
                for event in detect_deltas(prev, current):
                    try:
                        post_json(base, f"{PLUGIN_BASE}/notify", token, event)
                        print(
                            f"notified: {event['event']} session={event['session_id']}",
                            flush=True,
                        )
                    except urllib.error.HTTPError as exc:
                        print(f"notify failed: HTTP {exc.code}", file=sys.stderr, flush=True)
            prev = current
            first = False
        except urllib.error.URLError as exc:
            print(f"poll failed: {exc.reason}", file=sys.stderr, flush=True)
        except Exception as exc:  # noqa: BLE001 — watcher must never die mid-loop
            print(f"poll error: {type(exc).__name__}", file=sys.stderr, flush=True)
        time.sleep(interval)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="hermes-mobile external polling watcher (fallback path)"
    )
    parser.add_argument("--base", default="http://127.0.0.1:9119", help="gateway base URL")
    parser.add_argument("--interval", type=float, default=5.0, help="poll interval seconds")
    args = parser.parse_args()

    token = os.environ.get("HERMES_WATCHER_TOKEN", "")
    if not token:
        print("HERMES_WATCHER_TOKEN not set (pass the token via env, never argv)", file=sys.stderr)
        return 2

    print(
        f"watcher: polling {args.base} every {args.interval}s "
        "(fallback path — prefer the in-process gateway hooks when available)",
        flush=True,
    )
    run_loop(args.base, token, args.interval)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
