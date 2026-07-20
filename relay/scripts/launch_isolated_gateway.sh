#!/bin/bash
# Launch the STOCK hermes gateway, isolated on loopback 127.0.0.1:9127, for the
# Wave-2 convergence E2E. ZERO CORE PATCH: runs the unpatched `hermes_cli.main
# serve` straight from THIS worktree (never the products working tree, never the
# live gateway on 9119). All state lives under a throwaway HERMES_HOME on the
# external volume so no repo tree is written.
#
#   Port : 127.0.0.1:9127  (isolated range; NEVER 9119)
#   Home : $EVID/gwhome     (temp; wiped by the E2E driver between runs)
#   Token: $EVID/.gwtoken   (loopback ?token= auth; consumed by launch_relay.sh)
#
# Model turns use the z.ai/GLM key that worked in R0 (Anthropic key is
# billing-blocked). Nothing here is echoed.
set -euo pipefail

WORKTREE=/Volumes/MainData/Developer/hermes-tmp/worktrees/convergence
EVID=/Volumes/MainData/Developer/hermes-tmp/evidence/convergence
VENV=/Volumes/MainData/Developer/hermes-tmp/r0-relay-spike/venv

mkdir -p "$EVID/gwhome"
source "$VENV/bin/activate"

export HERMES_HOME="$EVID/gwhome"
# Stable loopback token so the relay's GatewayClient can auth via ?token=.
if [ ! -s "$EVID/.gwtoken" ]; then
  python -c "import secrets;print(secrets.token_hex(16))" > "$EVID/.gwtoken"
  chmod 600 "$EVID/.gwtoken"
fi
export HERMES_DASHBOARD_SESSION_TOKEN="$(cat "$EVID/.gwtoken")"

# z.ai / GLM (Coding Plan) — the account with live credit (R0 finding). Loaded
# quietly from ~/.hermes/.env; never printed.
GLMLINE="$(grep -m1 '^GLM_API_KEY=' "$HOME/.hermes/.env" || true)"
if [ -n "$GLMLINE" ]; then
  export GLM_API_KEY="${GLMLINE#GLM_API_KEY=}"
  export GLM_API_KEY="${GLM_API_KEY%\"}"; export GLM_API_KEY="${GLM_API_KEY#\"}"
fi
export GLM_BASE_URL="https://api.z.ai/api/coding/paas/v4"

# Run the stock gateway from the WORKTREE (its own hermes_cli — products tree untouched).
cd "$WORKTREE"
exec python -m hermes_cli.main serve \
  --host 127.0.0.1 --port 9127 --isolated --no-open
