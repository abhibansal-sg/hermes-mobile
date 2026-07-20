#!/usr/bin/env bash
# run_gate.sh — ONE entry script that runs the entire device-shaped E2E gate.
#
# Spec N8: "One entry script runs all. This is the merge gate."
#
# Default mode: deterministic mock-gateway (no model key required). Asserts
# A3/A4/A5/A6/A8 byte-identically.
#
# Opt-in: E2E_USE_LIVE_GATEWAY=1 launches the stock gateway via
# launch_gateway.sh (needs ~/.hermes/.env model key). In live mode the
# byte-identical chaos assertion (A4) is informational only — the live model's
# output is non-deterministic — so the gate stays on the mock by default.
#
# Hard-rule compliance: never touches the primary tree; never dials 9119; all
# artifacts under /Volumes/MainData; SIGTERM only (never kill -9); relay loaded
# from THIS worktree via PYTHONPATH.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BRANCH_ROOT="$(cd "$HERE/../.." && pwd)"
PYTHON="${E2E_PYTHON:-/Volumes/MainData/Developer/hermes-tmp/e2e-venv/bin/python}"
EVIDENCE_ROOT="/Volumes/MainData/Developer/hermes-tmp/evidence/daily-driver/e2e"
mkdir -p "$EVIDENCE_ROOT"

# Hermetic venv sanity check.
if [ ! -x "$PYTHON" ]; then
  echo "run_gate.sh: e2e venv python not found at $PYTHON" >&2
  echo "  create it with: /opt/homebrew/bin/python3.13 -m venv /Volumes/MainData/Developer/hermes-tmp/e2e-venv" >&2
  echo "  then: $PYTHON -m pip install websockets httpx pyyaml pytest pytest-asyncio psutil" >&2
  exit 2
fi

# Report mode.
if [ "${E2E_USE_LIVE_GATEWAY:-0}" = "1" ]; then
  echo "run_gate.sh: LIVE gateway mode (informational A4; deterministic scenarios use mock)." >&2
  if [ ! -f "${HOME}/.hermes/.env" ]; then
    echo "run_gate.sh: E2E_USE_LIVE_GATEWAY=1 but ~/.hermes/.env absent — no model key." >&2
    exit 2
  fi
else
  echo "run_gate.sh: MOCK gateway mode (deterministic, default merge gate)." >&2
fi

# Build the PYTHONPATH the relay subprocess + pytest need:
#  - relay/  so `python -m hermes_relay` resolves to THIS worktree's relay
#  - tests/e2e_daily_driver/(mock_gateway)  so tests import the driver + mock gw
PYP="${BRANCH_ROOT}/relay:${HERE}:${HERE}/mock_gateway"

echo "run_gate.sh: branch root = $BRANCH_ROOT"
echo "run_gate.sh: python      = $PYTHON"
echo "run_gate.sh: evidence    = $EVIDENCE_ROOT"
echo

# Run the gate.
PYTHONPATH="$PYP" "$PYTHON" -m pytest "$HERE" \
  -v \
  --tb=short \
  -p asyncio \
  --asyncio-mode=auto \
  "$@"

RC=$?
echo
echo "run_gate.sh: pytest exit code = $RC"
echo "run_gate.sh: evidence at $EVIDENCE_ROOT (per-test *.json + relay logs)"
exit $RC
