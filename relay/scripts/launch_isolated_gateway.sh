#!/bin/bash
# Launch the STOCK Hermes gateway on an isolated loopback port for the
# Wave-2 convergence E2E. ZERO CORE PATCH: runs the unpatched `hermes_cli.main
# serve` straight from THIS worktree (never the products working tree, never the
# live gateway on 9119). All state lives under a throwaway HERMES_HOME on the
# external volume so no repo tree is written.
#
#   Port : 127.0.0.1:$GATEWAY_PORT  (must be 9130+; NEVER 9119)
#   Home : $EVID/gwhome     (temp; wiped by the E2E driver between runs)
#   Token: $EVID/.gwtoken   (loopback ?token= auth; consumed by launch_relay.sh)
#
# Model turns use the z.ai/GLM key that worked in R0 (Anthropic key is
# billing-blocked). Nothing here is echoed.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE="${WORKTREE:-$(cd "$HERE/../.." && pwd)}"
EVID="${EVID:-/Volumes/MainData/Developer/hermes-tmp/evidence/relay-migration-gate}"
VENV="${GATEWAY_VENV:-/Volumes/MainData/Developer/hermes-tmp/r0-relay-spike/venv}"
GATEWAY_PORT="${GATEWAY_PORT:-9133}"

if [ "$GATEWAY_PORT" -lt 9130 ]; then
  echo "launch_isolated_gateway: GATEWAY_PORT must be 9130 or above" >&2
  exit 2
fi

mkdir -p "$EVID/gwhome"
source "$VENV/bin/activate"

export HERMES_HOME="$EVID/gwhome"
# Stable loopback token so the relay's GatewayClient can auth via ?token=.
if [ ! -s "$EVID/.gwtoken" ]; then
  python -c "import secrets;print(secrets.token_hex(16))" > "$EVID/.gwtoken"
  chmod 600 "$EVID/.gwtoken"
fi
export HERMES_DASHBOARD_SESSION_TOKEN="$(cat "$EVID/.gwtoken")"

# Run the stock gateway from the WORKTREE (its own hermes_cli — products tree untouched).
cd "$WORKTREE"
exec python -m hermes_cli.main serve \
  --host 127.0.0.1 --port "$GATEWAY_PORT" --isolated --no-open
