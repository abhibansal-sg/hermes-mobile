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
# QA-1 A9: this gate now has TWO halves that run together:
#   1. WIRE   — the pytest scenarios below (relay protocol, phone-driver shaped);
#      the LAST scenario (test_z_record_render_fixtures.py) also RECORDS the
#      relay frame streams the render half replays, into
#      tests/render_conformance/fixtures/ (committed; refreshed every run).
#   2. RENDER — RenderConformanceTests (XCTest): replays the recorded frames
#      through the real iOS render lane (RelayItemStore -> ChatStore) and
#      asserts render-model invariants (spec A9). Built/run via
#      scripts/ios-build.sh (machine mutex; SIGTERM never kill-9).
# Set RENDER_GATE=0 to run the wire half only (logged explicitly — a merge
# gate run leaves it at the default 1).
RENDER_GATE="${RENDER_GATE:-1}"
QA1_EVIDENCE="/Volumes/MainData/Developer/hermes-tmp/evidence/daily-driver-qa1"

PYTHONPATH="$PYP" "$PYTHON" -m pytest "$HERE" \
  -v \
  --tb=short \
  -p asyncio \
  --asyncio-mode=auto \
  "$@"

RC=$?
echo
echo "run_gate.sh: wire-gate (pytest) exit code = $RC"
echo "run_gate.sh: evidence at $EVIDENCE_ROOT (per-test *.json + relay logs)"

if [ "$RC" -ne 0 ]; then
  echo "run_gate.sh: wire gate FAILED — skipping the render half." >&2
  exit "$RC"
fi

if [ "$RENDER_GATE" != "1" ]; then
  echo "run_gate.sh: RENDER_GATE=$RENDER_GATE — render half (XCTest) skipped by request."
  exit "$RC"
fi
# Extra pytest args (e.g. a single scenario path) mean a partial wire run —
# do not couple the expensive XCTest half to a partial invocation.
if [ "$#" -gt 0 ]; then
  echo "run_gate.sh: partial wire run (extra args) — render half skipped."
  exit "$RC"
fi
if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "run_gate.sh: xcodebuild not found — render half cannot run here." >&2
  exit "$RC"
fi

echo
echo "run_gate.sh: RENDER GATE — RenderConformanceTests (recorded frames -> RelayItemStore -> ChatStore)"
mkdir -p "$QA1_EVIDENCE"
RENDER_RESULT="$QA1_EVIDENCE/render-gate.xcresult"
rm -rf "$RENDER_RESULT"
RENDER_LOG="$QA1_EVIDENCE/render-gate-run.log"
RENDER_XC_LOG="$QA1_EVIDENCE/render-gate-xcodebuild.log"

(cd "$BRANCH_ROOT" && HERMES_BUILD_TIMEOUT=3000 HERMES_BUILD_LOG="$RENDER_XC_LOG" \
  "$BRANCH_ROOT/scripts/ios-build.sh" test -scheme HermesMobile \
    -destination 'platform=iOS Simulator,name=iPhone Air' \
    -only-testing:HermesMobileTests/RenderConformanceTests \
    -resultBundlePath "$RENDER_RESULT") >>"$RENDER_LOG" 2>&1
RENDER_RC=$?
echo "run_gate.sh: render-gate (XCTest) exit code = $RENDER_RC"
# Vacuous-pass guard: xcodebuild exits 0 when -only-testing matches NOTHING
# (e.g. the class was renamed or unbundled) — that is NOT a green gate.
if [ "$RENDER_RC" -eq 0 ] && ! grep -q "Test Suite 'RenderConformanceTests'" "$RENDER_XC_LOG"; then
  echo "run_gate.sh: RENDER GATE VACUOUS — RenderConformanceTests never ran (check project.yml bundling)." >&2
  exit 1
fi
echo "run_gate.sh: render evidence: $RENDER_LOG (console) + $RENDER_XC_LOG (xcodebuild) + $RENDER_RESULT"
if [ "$RENDER_RC" -ne 0 ]; then
  echo "run_gate.sh: RENDER GATE FAILED — a render-model invariant regressed (see log above)." >&2
  exit "$RENDER_RC"
fi

echo "run_gate.sh: wire + render gates BOTH green."
exit 0
