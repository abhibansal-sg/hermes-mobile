#!/usr/bin/env bash
# ci_pre_xcodebuild.sh — Xcode Cloud pre-xcodebuild helper for gateway-dependent UI tests
#
# PURPOSE
# -------
# CrossClientSyncUITests and RemoteURLModeUITests require a live Hermes
# gateway running inside the CI VM. Without it they XCTSkip (not fail), so
# the build stays green — but skip-always means they never actually run.
#
# This script starts an isolated, in-VM gateway instance on port :9123,
# seeds one session row so the drawer is non-empty, waits for /health to
# return 200, then exports TEST_RUNNER_HERMES_URL and TEST_RUNNER_HERMES_TOKEN
# into the environment so Xcode Cloud surfaces them as HERMES_URL /
# HERMES_TOKEN inside the test-runner process (via the scheme's
# environmentVariables → $(TEST_RUNNER_HERMES_URL) substitution).
#
# HOW IT IS INVOKED
# -----------------
# Add this script as a "Pre-xcodebuild" custom script in the Xcode Cloud
# workflow Test action (not the Build action). Xcode Cloud runs it
# immediately before xcodebuild test. The exported vars persist into the
# xcodebuild process Xcode Cloud spawns next.
#
# SECRETS INJECTION (no secrets in this file)
# -------------------------------------------
# Two Xcode Cloud environment variables must be configured in App Store
# Connect (Xcode → Manage Workflows → Environment Variables):
#
#   HERMES_CI_MODEL_KEY  — the LLM API key the gateway uses for model calls
#                          (e.g. an Anthropic key). Mark as SECRET so it is
#                          never printed in logs. The gateway reads this as
#                          ANTHROPIC_API_KEY (we re-export it below).
#
#   HERMES_CI_TOKEN      — a fixed bearer token the CI gateway will accept.
#                          The test runner will present this as its credential.
#                          Mark as SECRET. Generate once with:
#                            python3 -c "import secrets; print(secrets.token_urlsafe(32))"
#                          Store the output in the Xcode Cloud env var and
#                          keep a copy in your password manager (for rotation).
#
# If either variable is absent the script exits 0 (tests will XCTSkip).
#
# ISOLATION GUARANTEES
# --------------------
#   - HERMES_HOME is a fresh temp directory created per CI run — no state
#     leaks between builds.
#   - Port :9123 is chosen to never collide with :9119 (the live dashboard).
#   - HERMES_GATEWAY_BROADCAST=1 enables the multi-client mirror path that
#     CrossClientSyncUITests exercises.
#   - The gateway is bound to 127.0.0.1:9123 (loopback) — the simulator
#     and the test runner share the same OS network namespace on CI VMs.
#   - The gateway PID is recorded and cleaned up by a trap on exit.

set -euo pipefail

log() { printf '[ci_pre_xcodebuild] %s\n' "$*"; }

# --------------------------------------------------------------------------
# 0. Guard: skip gracefully if secrets are absent
# --------------------------------------------------------------------------
if [ -z "${HERMES_CI_TOKEN:-}" ]; then
    log "HERMES_CI_TOKEN not set — gateway-dependent tests will XCTSkip. Exiting 0."
    exit 0
fi

# --------------------------------------------------------------------------
# 1. Locate repo root (script lives at apps/ios/ci_scripts/)
# --------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$IOS_DIR/../.." && pwd)"

log "REPO_ROOT: $REPO_ROOT"

# --------------------------------------------------------------------------
# 2. Set up an isolated HERMES_HOME in a temp directory
# --------------------------------------------------------------------------
CI_HERMES_HOME="$(mktemp -d /tmp/hermes-ci-home-XXXXXX)"
log "CI HERMES_HOME: $CI_HERMES_HOME"
export HERMES_HOME="$CI_HERMES_HOME"

# --------------------------------------------------------------------------
# 3. Check Python is available (Xcode Cloud VMs ship Python 3.x)
# --------------------------------------------------------------------------
PYTHON="${PYTHON:-python3}"
if ! command -v "$PYTHON" &>/dev/null; then
    log "ERROR: python3 not found. Cannot start gateway."
    exit 1
fi
log "Python: $("$PYTHON" --version 2>&1)"

# --------------------------------------------------------------------------
# 4. Install gateway Python deps into the CI_HERMES_HOME venv
#    The repo ships a pyproject.toml; we install in editable mode so all
#    gateway imports resolve from the checked-out source.
# --------------------------------------------------------------------------
VENV_DIR="$CI_HERMES_HOME/venv"
log "Creating venv at $VENV_DIR..."
"$PYTHON" -m venv "$VENV_DIR"
# shellcheck source=/dev/null
source "$VENV_DIR/bin/activate"

log "Installing hermes-agent package (editable) + web deps..."
pip install --quiet -e "$REPO_ROOT[web]" 2>&1 | tail -5 || \
    pip install --quiet -e "$REPO_ROOT" 2>&1 | tail -5
# fastapi + uvicorn are needed by the web server (hermes dashboard / web cmd)
pip install --quiet fastapi uvicorn 2>&1 | tail -3

# --------------------------------------------------------------------------
# 5. Export secrets into the gateway's environment
#    ANTHROPIC_API_KEY is what the hermes gateway reads for model calls.
#    HERMES_DASHBOARD_SESSION_TOKEN pins the bearer token so the test runner
#    can authenticate without guessing the randomly-generated default.
# --------------------------------------------------------------------------
export ANTHROPIC_API_KEY="${HERMES_CI_MODEL_KEY:-}"   # may be empty → gateway won't run LLM calls
export HERMES_DASHBOARD_SESSION_TOKEN="$HERMES_CI_TOKEN"
export HERMES_GATEWAY_BROADCAST=1

GATEWAY_PORT=9123
GATEWAY_HOST="127.0.0.1"
GATEWAY_URL="http://${GATEWAY_HOST}:${GATEWAY_PORT}"

log "Starting isolated gateway on ${GATEWAY_URL}..."

# --------------------------------------------------------------------------
# 6. Start the gateway in the background
#    `python -m hermes_cli.main web --port 9123 --no-open` starts the
#    FastAPI/uvicorn dashboard that the iOS app connects to over WebSocket.
#    We redirect all output to a log file for post-mortem inspection.
# --------------------------------------------------------------------------
GATEWAY_LOG="$CI_HERMES_HOME/gateway.log"
"$PYTHON" -m hermes_cli.main web \
    --host "$GATEWAY_HOST" \
    --port "$GATEWAY_PORT" \
    --no-open \
    >"$GATEWAY_LOG" 2>&1 &
GATEWAY_PID=$!
log "Gateway PID: $GATEWAY_PID"

# Cleanup on exit (covers both success and error paths)
cleanup() {
    if kill -0 "$GATEWAY_PID" 2>/dev/null; then
        log "Stopping gateway (PID $GATEWAY_PID)..."
        kill -TERM "$GATEWAY_PID" 2>/dev/null || true
    fi
    log "Gateway log (last 30 lines):"
    tail -30 "$GATEWAY_LOG" 2>/dev/null || true
}
trap cleanup EXIT

# --------------------------------------------------------------------------
# 7. Wait for /health to return 200 (up to 60 s)
# --------------------------------------------------------------------------
log "Waiting for gateway /health..."
HEALTH_URL="${GATEWAY_URL}/health"
max_wait=60
waited=0
while true; do
    if curl -sf -o /dev/null "${HEALTH_URL}"; then
        log "/health OK after ${waited}s"
        break
    fi
    if [ "$waited" -ge "$max_wait" ]; then
        log "ERROR: gateway did not become healthy in ${max_wait}s"
        log "Gateway log:"
        cat "$GATEWAY_LOG" || true
        exit 1
    fi
    sleep 2; waited=$((waited + 2))
done

# --------------------------------------------------------------------------
# 8. Seed a session row so the drawer is non-empty for UI tests
#    POST /api/sessions with the bearer token.
# --------------------------------------------------------------------------
log "Seeding a CI session row..."
SESSION_RESP=$(curl -sf \
    -X POST \
    -H "Authorization: Bearer ${HERMES_CI_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"title": "CI Seed Session"}' \
    "${GATEWAY_URL}/api/sessions" 2>/dev/null || echo "{}")
log "Session seed response: $SESSION_RESP"

# --------------------------------------------------------------------------
# 9. Export env vars for xcodebuild
#    Xcode Cloud propagates exported env vars from ci scripts into the
#    subsequent xcodebuild invocation. The scheme's TEST_RUNNER_* macros
#    then surface them as HERMES_URL / HERMES_TOKEN inside the test runner.
# --------------------------------------------------------------------------
export TEST_RUNNER_HERMES_URL="${GATEWAY_URL}"
export TEST_RUNNER_HERMES_TOKEN="${HERMES_CI_TOKEN}"

log "Exported:"
log "  TEST_RUNNER_HERMES_URL  = ${TEST_RUNNER_HERMES_URL}"
log "  TEST_RUNNER_HERMES_TOKEN = <set, not printed>"

# --------------------------------------------------------------------------
# 10. Prevent trap from killing the gateway before xcodebuild finishes.
#     We reset the trap here; the gateway stays alive for the duration of
#     the xcodebuild run. Xcode Cloud cleans up orphan processes when the
#     action completes.
# --------------------------------------------------------------------------
trap - EXIT
log "ci_pre_xcodebuild.sh done. Gateway running at ${GATEWAY_URL}."
