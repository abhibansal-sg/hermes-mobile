#!/bin/bash
# run-relay.sh — the canonical, self-contained launcher for the hermes-relay
# service (`python -m hermes_relay`). It provisions an isolated venv on the
# external volume, installs the relay (editable) with its runtime deps, and
# starts the relay with the new CLI:
#
#   gateway  ws://$GATEWAY_HOST:$GATEWAY_PORT   (upstream, stock/isolated)
#   relay    ws://$LISTEN                       (downstream, phone-facing)
#   health   http://$LISTEN$HEALTH_PATH         (GET -> JSON status)
#
# The iOS app connects to the DOWNSTREAM address; the relay authenticates and
# forwards stock WS/HTTP traffic without parsing or translating it.
#
# SAFETY: the live production gateway on port 9119 is refused by the entrypoint.
# Point this at an isolated/stock gateway only (e.g. launch_isolated_gateway.sh,
# default 9127). ZERO CORE PATCH — this only runs the relay CLIENT.
#
# Config (all overridable from the environment; CLI flags below win):
#   GATEWAY_HOST   default 127.0.0.1
#   GATEWAY_PORT   default 9127   (isolated E2E range; NEVER 9119)
#   LISTEN         default 127.0.0.1:8788   (phone-facing bind)
#   HEALTH_PATH    default /healthz
#   TOKEN_FILE     default $EVID/.gwtoken (written by launch_isolated_gateway.sh)
#   HERMES_RELAY_GATEWAY_TOKEN  used if TOKEN_FILE is absent
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # relay/scripts
RELAY_PKG="$(cd "$HERE/.." && pwd)"                    # relay/ (has pyproject)
EVID="${EVID:-/Volumes/MainData/Developer/hermes-tmp/evidence/convergence}"
VENV="${RELAY_VENV:-/Volumes/MainData/Developer/hermes-tmp/convergence-lanes/relay-venv}"

GATEWAY_HOST="${GATEWAY_HOST:-127.0.0.1}"
GATEWAY_PORT="${GATEWAY_PORT:-9127}"
LISTEN="${LISTEN:-127.0.0.1:8788}"
HEALTH_PATH="${HEALTH_PATH:-/healthz}"
TOKEN_FILE="${TOKEN_FILE:-$EVID/.gwtoken}"

# 1) Provision the venv (idempotent) on the external volume.
if [ ! -x "$VENV/bin/python" ]; then
  /opt/homebrew/bin/python3.13 -m venv "$VENV"
fi
"$VENV/bin/python" -m pip install --quiet --upgrade pip
"$VENV/bin/python" -m pip install --quiet -e "$RELAY_PKG"

# 2) Resolve the gateway token: prefer a token file (keeps it out of argv).
TOKEN_ARGS=()
if [ -s "$TOKEN_FILE" ]; then
  TOKEN_ARGS=(--token-file "$TOKEN_FILE")
elif [ -n "${HERMES_RELAY_GATEWAY_TOKEN:-}" ]; then
  : # entrypoint reads it from the environment
else
  echo "run-relay: no token — set TOKEN_FILE ($TOKEN_FILE) or HERMES_RELAY_GATEWAY_TOKEN." >&2
  echo "           (launch_isolated_gateway.sh writes $EVID/.gwtoken)" >&2
  exit 2
fi

# 3) Run. `python -m hermes_relay` needs the package importable -> run from relay/.
cd "$RELAY_PKG"
exec "$VENV/bin/python" -m hermes_relay \
  --gateway-host "$GATEWAY_HOST" \
  --gateway-port "$GATEWAY_PORT" \
  --listen "$LISTEN" \
  --health-path "$HEALTH_PATH" \
  "${TOKEN_ARGS[@]}" \
  "$@"
