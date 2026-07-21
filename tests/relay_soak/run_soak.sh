#!/usr/bin/env bash
# run_soak.sh — relay soak entry point.
#
#   run_soak.sh <relay_source_path> <mode> [scenario ...]
#
#     <relay_source_path>  root of the relay tree under test (contains relay/
#                          and plugins/hermes-mobile). The harness re-soaks ANY
#                          source tree: the QA-3 tip, origin/main, a PR branch.
#     <mode>               short (2-5 min/scenario, CI) | soak (spec durations).
#     [scenario ...]       optional filter — a glob token matched uniquely
#                          against scenarios/test_*.py (full suffix, unique
#                          prefix, or infix): smoke t1_connect_churn
#                          t2_foreground_flap t3_multi_session t4_kill_loop
#                          t5_gateway_abuse t6_fuzz t7_marathon t8_replay_ring
#                          z_injected_fault. 't6' / 't8' work too (unique
#                          prefixes). Omit to run the whole matrix.
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
# Resolve each scenario token to its test file by GLOB (unique match required):
# the committed file suffixes don't all equal the documented short names
# (test_t1_connect_churn.py vs 't1_churn', test_t8_replay_ring.py vs 't8_ring'),
# so a literal test_${s}.py lookup fails for 6 of 10 scenarios. A token may be
# the full suffix (t8_replay_ring), a unique prefix (t8 -> test_t8_replay_ring),
# or an infix (connect_churn). Ambiguous / unmatched tokens are rejected loudly.
ARGS=()
if [[ ${#SCENARIOS[@]} -gt 0 ]]; then
  shopt -s nullglob
  for s in "${SCENARIOS[@]}"; do
    matches=( "$SCRIPT_DIR/scenarios/test_${s}"*.py )           # prefix: t6_fuzz, t8
    if [[ ${#matches[@]} -eq 0 ]]; then
      matches=( "$SCRIPT_DIR/scenarios"/test_*"${s}"*.py )      # infix: connect_churn
    fi
    if [[ ${#matches[@]} -eq 0 ]]; then
      echo "error: no scenario matching '${s}' in $SCRIPT_DIR/scenarios/" >&2
      exit 2
    fi
    if [[ ${#matches[@]} -gt 1 ]]; then
      echo "error: scenario '${s}' is ambiguous:" >&2
      printf '  %s\n' "${matches[@]##*/}" >&2
      exit 2
    fi
    ARGS+=( "${matches[0]}" )
  done
  shopt -u nullglob
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
# H7 (soak consolidation): snapshot the run-* dirs that exist BEFORE this
# pytest starts so the post-run summarizer can pick THIS run's dir. Summarizing
# "the freshest dir" raced: a sibling lane finishing mid-run wrote its SUMMARY
# into this lane's in-flight dir (observed: an empty scenarios_run=0 SUMMARY in
# run-20260721-130921-soak-seed34) and stole the sibling's own summarize.
PRE_RUNS="$(mktemp "${TMPDIR:-/tmp}/soak_preruns.XXXXXX")"
ls -d "$EVIDENCE"/run-* 2>/dev/null > "$PRE_RUNS" || true
set +e
( cd "$HARNESS_ROOT" && \
  SOAK_MODE="$MODE" \
  SOAK_RELAY_SOURCE="$RELAY_SRC" \
  SOAK_PYTHON="$VENV/bin/python" \
  nice -n 10 "$VENV/bin/python" -m pytest "${ARGS[@]}" \
      -v -p no:cacheprovider )
PYTEST_RC=$?
set -e

# --- summarize THIS run's dir (H7) -----------------------------------------
# The freshest run-* dir NOT in the pre-run snapshot is the one this pytest
# created. Fallback to the freshest overall if nothing new appeared (pytest
# died before creating its dir).
RUN_DIR=""
while IFS= read -r d; do
  [[ -z "$d" ]] && continue
  if ! grep -qxF "$d" "$PRE_RUNS"; then RUN_DIR="$d"; break; fi
done < <(ls -dt "$EVIDENCE"/run-* 2>/dev/null)
if [[ -z "$RUN_DIR" ]]; then
  RUN_DIR="$(ls -dt "$EVIDENCE"/run-* 2>/dev/null | head -1 || true)"
fi
rm -f "$PRE_RUNS"
if [[ -n "$RUN_DIR" ]]; then
  "$VENV/bin/python" "$SCRIPT_DIR/summarize.py" "$RUN_DIR" || true
fi

exit "$PYTEST_RC"
