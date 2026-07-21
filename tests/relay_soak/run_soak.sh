#!/usr/bin/env bash
# run_soak.sh — relay soak entry point.
#
#   run_soak.sh <relay_source_path> <mode> [scenario ...]
#
#     <relay_source_path>  root of the relay tree under test (contains relay/
#                          and plugins/hermes-mobile). The harness re-soaks ANY
#                          source tree: the QA-3 tip, origin/main, a PR branch.
#     <mode>               short (2-5 min/scenario, CI) | soak (spec durations).
#     [scenario ...]       optional filter, by short name without the test_
#                          prefix: smoke t1_churn t2_flap t3_multi t4_kill
#                          t5_gateway t6_fuzz t7_marathon t8_ring
#                          z_injected_fault. Omit to run the whole matrix.
#
# Provisions an isolated python3.13 venv on /Volumes/MainData from THAT source
# (relay deps + harness extras), runs the scenarios against a relay imported
# from the source (never the primary tree, never a live gateway/relay), writes
# per-scenario verdict JSON + resource curves under the evidence dir, then rolls
# them into one SUMMARY.json. Long runs are niced — the QA-3 swarm shares this
# box. SOAK_SCALE compresses every duration (proof runs use ~0.1).
#
# Binding rules enforced here: isolated gateways only on 9140-9160 with temp
# HERMES_HOME under the evidence dir; NEVER 9119/8788 (live) or 9130-9139 (QA-3);
# mock APNs only; no iOS builds.
set -euo pipefail

RELAY_SRC="${1:-}"
MODE="${2:-short}"
if [[ -z "$RELAY_SRC" ]]; then
  echo "usage: run_soak.sh <relay_source_path> <mode> [scenario ...]" >&2
  echo "  mode: short | soak    (SOAK_SCALE env compresses durations)" >&2
  exit 2
fi
shift 2 || true
SCENARIOS=("$@")

RELAY_SRC="$(cd "$RELAY_SRC" && pwd)"
if [[ ! -d "$RELAY_SRC/relay" ]]; then
  echo "error: $RELAY_SRC/relay not found — not a relay source tree" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # tests/relay_soak
HARNESS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"               # worktree root
PY=/opt/homebrew/bin/python3.13
EVIDENCE=/Volumes/MainData/Developer/hermes-tmp/evidence/relay-soak
mkdir -p "$EVIDENCE"

# --- venv (on /Volumes/MainData; internal disk is tight) -------------------
# One venv per source tree (hash of the path) so re-soaking different tips
# doesn't cross-contaminate. Provisioned FROM the source: its declared relay
# deps + the harness extras (hypothesis for T6, psutil for I6).
VENV_ROOT=/Volumes/MainData/Developer/hermes-tmp/venvs
VENV_HASH="$(printf '%s' "$RELAY_SRC" | shasum | cut -c1-10)"
VENV="$VENV_ROOT/soak-$VENV_HASH"

if [[ ! -x "$VENV/bin/python" ]]; then
  echo ">> creating venv $VENV (python3.13)"
  "$PY" -m venv "$VENV"
fi
echo ">> provisioning venv from $RELAY_SRC"
"$VENV/bin/pip" install -q --upgrade pip >/dev/null
# Relay runtime + harness extras (the relay's own deps come along too).
"$VENV/bin/pip" install -q \
  "websockets>=12" "httpx[http2]>=0.27" "pyyaml>=6" "pyjwt[crypto]>=2.8" \
  "cryptography>=42" "pytest>=8" "pytest-asyncio>=0.23" "hypothesis>=6" \
  "psutil>=5"
# Install the relay under test from the SOURCE so `import hermes_relay`
# resolves there (conftest also pins RELAY_SOURCE on sys.path — belt+braces).
if ! "$VENV/bin/pip" install -q -e "$RELAY_SRC/relay" 2>/dev/null; then
  echo "   (editable install failed; conftest sys.path fallback will resolve the relay)" >&2
fi

# --- scenario selection ----------------------------------------------------
ARGS=()
if [[ ${#SCENARIOS[@]} -gt 0 ]]; then
  for s in "${SCENARIOS[@]}"; do
    f="$SCRIPT_DIR/scenarios/test_${s}.py"
    if [[ ! -f "$f" ]]; then echo "error: no scenario test_${s}.py" >&2; exit 2; fi
    ARGS+=("$f")
  done
else
  ARGS+=("$SCRIPT_DIR/scenarios")
fi

echo ">> relay source : $RELAY_SRC"
echo ">> mode         : $MODE (SOAK_SCALE=${SOAK_SCALE:-1.0}, SOAK_SEED=${SOAK_SEED:-0})"
echo ">> venv         : $VENV"
echo ">> evidence     : $EVIDENCE"
echo ">> scenarios    : ${SCENARIOS[*]:-ALL}"
echo

# --- run (niced — QA-3 swarm shares this machine) --------------------------
# Relay-under-test resolution is via env: SOAK_RELAY_SOURCE points conftest's
# sys.path + plugin dir at the source; SOAK_PYTHON runs the relay subprocess.
set +e
( cd "$HARNESS_ROOT" && \
  SOAK_MODE="$MODE" \
  SOAK_RELAY_SOURCE="$RELAY_SRC" \
  SOAK_PYTHON="$VENV/bin/python" \
  nice -n 10 "$VENV/bin/python" -m pytest "${ARGS[@]}" \
      -v -p no:cacheprovider )
PYTEST_RC=$?
set -e

# --- summarize the freshest run dir ----------------------------------------
RUN_DIR="$(ls -dt "$EVIDENCE"/run-* 2>/dev/null | head -1 || true)"
if [[ -n "$RUN_DIR" ]]; then
  "$VENV/bin/python" "$SCRIPT_DIR/summarize.py" "$RUN_DIR" || true
fi

exit "$PYTEST_RC"
