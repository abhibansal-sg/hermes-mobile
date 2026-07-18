#!/bin/bash
# Launch the hermes-relay service (`python -m hermes_relay`) co-located with the
# isolated stock gateway from launch_isolated_gateway.sh. This is the phone-facing
# half of the Wave-2 convergence stack:
#
#   gateway  ws://127.0.0.1:9127/api/ws?token=   (upstream, stock, isolated)
#   relay    ws://127.0.0.1:8788                 (downstream, phone-facing)
#
# The iOS app (flag ON) connects to the DOWNSTREAM port; the relay dials the
# gateway UP, reframes raw events into the ratified item envelope
# (docs/RELAY-PHONE-PROTOCOL.md), and serves seq/ack/replay frames to the phone.
#
# Env consumed by hermes_relay.__main__:
#   HERMES_RELAY_GATEWAY_TOKEN     (required) — the loopback ?token=
#   HERMES_RELAY_GATEWAY_PORT      — upstream gateway port (9127 here)
#   HERMES_RELAY_DOWNSTREAM_PORT   — phone-facing WS port (8788 here)
# plugin_bridge auto-discovers plugins/hermes-mobile by walking up from the
# package, so no HERMES_REPO_ROOT is needed when run from the worktree.
set -euo pipefail

RELAY=/Volumes/MainData/Developer/hermes-tmp/worktrees/convergence/relay
EVID=/Volumes/MainData/Developer/hermes-tmp/evidence/convergence
VENV=/Volumes/MainData/Developer/hermes-tmp/r0-relay-spike/venv

if [ ! -s "$EVID/.gwtoken" ]; then
  echo "launch_relay: $EVID/.gwtoken missing — start launch_isolated_gateway.sh first." >&2
  exit 2
fi

source "$VENV/bin/activate"
export HERMES_RELAY_GATEWAY_TOKEN="$(cat "$EVID/.gwtoken")"
export HERMES_RELAY_GATEWAY_PORT="${HERMES_RELAY_GATEWAY_PORT:-9127}"
export HERMES_RELAY_DOWNSTREAM_PORT="${HERMES_RELAY_DOWNSTREAM_PORT:-8788}"

# `python -m hermes_relay` needs the package importable → run from relay/.
cd "$RELAY"
exec python -m hermes_relay
