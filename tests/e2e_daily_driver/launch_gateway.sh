#!/usr/bin/env bash
# launch_gateway.sh — bring up an ISOLATED stock hermes gateway ( NEVER 9119 ).
#
# Spec hard-rule: never run tests against the live 9119 gateway. This script is
# the launch_gateway.sh-pattern referenced in DAILY-DRIVER-SPEC.md N8. It picks
# a free loopback port in 9130+, sets a temp HERMES_HOME on /Volumes/MainData,
# sources the model key from ~/.hermes/.env if present, and execs the stock
# gateway from the e2e worktree (read-only against the primary tree).
#
# Usage:
#   launch_gateway.sh                  # auto port from 9134 up, temp HOME
#   PORT=9134 launch_gateway.sh
#   E2E_USE_LIVE_GATEWAY=1 launch_gateway.sh   # the live-gateway path
#
# Output: prints the chosen PORT and HERMES_HOME on stdout as two lines:
#   PORT=<n>
#   HERMES_HOME=<path>
# and the gateway's own logs go to $LOG_PATH (stderr).
#
# Degrade gracefully: if no model key is present the script still execs the
# gateway; the relay/phone-driver use the scripted-echo MOCK gateway by default
# (see conftest.py). Live-gateway mode is opt-in via E2E_USE_LIVE_GATEWAY=1.
set -euo pipefail

BRANCH_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="/Volumes/MainData/Developer/hermes-tmp/e2e_daily_driver"
mkdir -p "$TMP_ROOT"
HERMES_HOME="$(mktemp -d "$TMP_ROOT/gateway-home.XXXXXX")"
export HERMES_HOME

PORT="${PORT:-9134}"
# Bump until free (cap at 9199 to stay in the isolated band).
while lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; do
  PORT=$((PORT + 1))
  if [ "$PORT" -gt 9199 ]; then
    echo "no free port in 9130-9199" >&2; exit 1
  fi
done

# Source the model key if present (NEVER echo it).
ENV_FILE="${HOME}/.hermes/.env"
KEY_PRESENT=0
if [ -f "$ENV_FILE" ]; then
  if grep -qE '^(ANTHROPIC_API_KEY|GLM_API_KEY)=' "$ENV_FILE"; then
    KEY_PRESENT=1
    # shellcheck disable=SC1090
    set -a; . "$ENV_FILE"; set +a
  fi
fi

LOG_PATH="${LOG_PATH:-$TMP_ROOT/gateway-$PORT.log}"

echo "PORT=$PORT"
echo "HERMES_HOME=$HERMES_HOME"
echo "LOG_PATH=$LOG_PATH"
echo "KEY_PRESENT=$KEY_PRESENT"
echo "MODE=${E2E_USE_LIVE_GATEWAY:-0}" >&2

if [ "${E2E_USE_LIVE_GATEWAY:-0}" != "1" ]; then
  echo "launch_gateway.sh: E2E_USE_LIVE_GATEWAY not set; nothing to launch" \
       "(default mode uses the in-process scripted-echo mock)." >&2
  exit 0
fi

if [ "$KEY_PRESENT" -ne 1 ]; then
  echo "launch_gateway.sh: E2E_USE_LIVE_GATEWAY=1 but no model key in $ENV_FILE;" \
       "the live gateway would refuse to serve model calls. Re-run with a key." >&2
  exit 2
fi

# Live mode: exec the stock gateway from the branch root (read-only against the
# primary tree — it reads the same package source via the worktree checkout).
cd "$BRANCH_ROOT"
exec python3 -m hermes_cli.main serve \
  --host 127.0.0.1 --port "$PORT" --isolated --no-open
