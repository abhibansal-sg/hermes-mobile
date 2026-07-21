#!/usr/bin/env bash
# scripts/r4-void-evidence.sh — R4 W0b I7/I19 void-geometry evidence: bring up
# an ISOLATED mock gateway (never 9119; OS-assigned port) SEEDED with a 72-row
# tall session (sess-tall-0001) and a history-bearing streaming longturn
# session (sess-stream-0001, ~48 word-deltas @ 0.15 s), plus the worktree relay
# against it (9140+ band, temp HERMES_HOME on /Volumes/MainData), wipe the sim
# app container for a true cold start, and run VoidGeometryUITests — the
# render-layer oracle that scrolling a tall transcript (through the windowed
# VStack's grow/paging seams) and detaching mid-turn NEVER paints a blank
# viewport band sandwiched between content.
#
# Usage:
#   scripts/r4-void-evidence.sh
#   SIM_DEST='platform=iOS Simulator,name=iPhone 17 Pro' scripts/r4-void-evidence.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EVID="/Volumes/MainData/Developer/hermes-tmp/evidence/round4"
mkdir -p "$EVID"
PY="${E2E_PYTHON:-/Volumes/MainData/Developer/hermes-tmp/e2e-venv/bin/python}"
SIM_DEST="${SIM_DEST:-platform=iOS Simulator,name=iPhone Air}"
BUNDLE_ID="ai.hermes.app"

mkdir -p /Volumes/MainData/Developer/hermes-tmp/e2e_daily_driver
HERMES_HOME="$(mktemp -d /Volumes/MainData/Developer/hermes-tmp/e2e_daily_driver/r4-void-home.XXXXXX)"
export HERMES_HOME

pids=()
cleanup() {
  for p in "${pids[@]:-}"; do kill -TERM "$p" 2>/dev/null || true; done
}
trap cleanup EXIT

log() { printf '[r4-void] %s\n' "$*" >&2; }

# ---- 1. SEEDED mock gateway (tall transcript + streaming longturn) ----------
rm -f "$EVID/void-gateway.json"
"$PY" - "$ROOT" "$EVID/void-gateway.json" >"$EVID/void-mock-gateway.log" 2>&1 <<'PYEOF' &
import asyncio, json, pathlib, sys
root, out = sys.argv[1], sys.argv[2]
sys.path.insert(0, root + "/tests/e2e_daily_driver")
from mock_gateway.server import MockGateway, MockSession, Script

PAIRS = 36  # 72 rows — comfortably taller than any viewport window.

def tall_history():
    rows = []
    for i in range(PAIRS):
        rows.append({"role": "user", "content": f"tall question {i:02d}"})
        # Every 4th answer is long (multi-line) so row heights vary — the
        # condition lazy/estimated-height voids breed in.
        pad = "detailed answer content. " * (6 if i % 4 == 0 else 1)
        rows.append({"role": "assistant",
                     "content": f"tall-msg-{i:02d} " + pad.strip()})
    return rows

def stream_history():
    rows = []
    for i in range(12):  # 24 settled rows so the viewport is full pre-stream
        rows.append({"role": "user", "content": f"stream backfill {i:02d}"})
        rows.append({"role": "assistant",
                     "content": f"stream-settled-{i:02d} prior reply text."})
    return rows

async def main():
    gw = MockGateway()
    await gw.start()
    tall = MockSession(sid="sess-tall-0001", title="r4 tall transcript",
                       script=Script(name="simple", kwargs={}))
    tall.history = tall_history()
    gw.sessions[tall.sid] = tall
    stream = MockSession(
        sid="sess-stream-0001", title="r4 streaming turn",
        script=Script(name="longturn", kwargs={
            "text": " ".join(f"w{i}" for i in range(48)),
            "delta_delay_s": 0.15,   # ~7.2 s of live stream to scroll inside
        }),
    )
    stream.history = stream_history()
    gw.sessions[stream.sid] = stream
    pathlib.Path(out).write_text(json.dumps({"port": gw.port, "token": gw.token}))
    print(f"mock gateway on {gw.port}: tall=72 rows, stream=24 rows + 48w longturn",
          flush=True)
    await asyncio.Event().wait()

asyncio.run(main())
PYEOF
pids+=($!)
for _ in $(seq 1 150); do [ -s "$EVID/void-gateway.json" ] && break; sleep 0.1; done
[ -s "$EVID/void-gateway.json" ] || { log "seeded mock gateway failed to start"; cat "$EVID/void-mock-gateway.log" >&2; exit 1; }
GW_PORT="$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1]))["port"])' "$EVID/void-gateway.json")"
TOKEN="$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1]))["token"])' "$EVID/void-gateway.json")"
log "seeded mock gateway up on 127.0.0.1:$GW_PORT"

# ---- 2. worktree relay against the mock gateway (isolated band) -------------
RELAY_PORT="${RELAY_PORT:-9150}"
while lsof -nP -iTCP:"$RELAY_PORT" -sTCP:LISTEN >/dev/null 2>&1; do
  RELAY_PORT=$((RELAY_PORT + 1))
  [ "$RELAY_PORT" -gt 9199 ] && { log "no free port in 9150-9199"; exit 1; }
done
PYTHONPATH="$ROOT/relay" \
HERMES_RELAY_GATEWAY_TOKEN="$TOKEN" \
HERMES_RELAY_PLUGIN_DIR="$ROOT/plugins/hermes-mobile" \
"$PY" -m hermes_relay \
  --gateway-host 127.0.0.1 --gateway-port "$GW_PORT" \
  --listen "127.0.0.1:$RELAY_PORT" --health-path /healthz \
  >"$EVID/void-relay.log" 2>&1 &
pids+=($!)
for _ in $(seq 1 200); do
  curl -fs "http://127.0.0.1:$RELAY_PORT/healthz" >/dev/null 2>&1 && break
  sleep 0.1
done
curl -fs "http://127.0.0.1:$RELAY_PORT/healthz" >/dev/null \
  || { log "relay failed to become healthy"; cat "$EVID/void-relay.log" >&2; exit 1; }
log "relay up on 127.0.0.1:$RELAY_PORT (healthz OK)"

# ---- 3. true cold-start state: wipe the app container ------------------------
# COORDINATION: the container wipe mutates the SHARED simulator — never do it
# while another lane's build/test run holds the machine-global iOS mutex (an
# in-progress XCUITest run would lose its app under test). Wait for the lock
# to be FREE (holder dead ⇒ stale, treat as free — ios-build.sh reclaims it),
# then wipe; ios-build.sh below re-acquires the lock for the actual run.
LOCK_DIR="$HOME/.hermes/ios-build.lock"
log "waiting for the iOS build mutex to free up (never wipe under a live run)…"
for _ in $(seq 1 240); do   # up to ~60 min of polite waiting
  if [ ! -d "$LOCK_DIR" ]; then break; fi
  holder="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
    log "lock holder pid $holder is dead (stale) — proceeding"
    break
  fi
  sleep 15
done
[ -d "$LOCK_DIR" ] && holder="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)" && \
  { [ -z "$holder" ] || kill -0 "$holder" 2>/dev/null; } && \
  { log "iOS mutex still held after 60 min — aborting (retry later)"; exit 3; }
BOOTED="$(xcrun simctl list devices booted 2>/dev/null | grep -c Booted || true)"
if [ "$BOOTED" -eq 0 ]; then
  UDID="$(xcrun simctl list devices available | sed -n "s/^ *iPhone Air (\([0-9A-F-]*\)).*/\1/p" | head -1)"
  if [ -n "$UDID" ]; then xcrun simctl boot "$UDID" 2>/dev/null || true; fi
fi
xcrun simctl uninstall booted "$BUNDLE_ID" 2>/dev/null || true
log "app container wiped (cold-start state)"

# ---- 4. run the void-geometry suite (via the mutexed build wrapper) ----------
export TEST_RUNNER_HERMES_URL="http://127.0.0.1:$GW_PORT"
export TEST_RUNNER_HERMES_TOKEN="$TOKEN"
export TEST_RUNNER_HERMES_RELAY_URL="ws://127.0.0.1:$RELAY_PORT"
log "running VoidGeometryUITests → $EVID/void-geometry.xcresult"
rm -rf "$EVID/void-geometry.xcresult"
cd "$ROOT"
HERMES_BUILD_LOG="$EVID/void-uitest-xcodebuild.log" HERMES_BUILD_TIMEOUT=2700 \
  scripts/ios-build.sh test \
  -scheme HermesMobile \
  -destination "$SIM_DEST" \
  -only-testing:HermesMobileUITests/VoidGeometryUITests \
  -resultBundlePath "$EVID/void-geometry.xcresult" 2>&1 | tail -40
RC=$?
# Vacuous-pass guard (mirrors run_gate.sh): xcodebuild exits 0 when
# -only-testing matches NOTHING — that is NOT a green gate. Require the CLASS
# suite line, not just the target name (the target string appears in every
# build log line; the suite line only when tests actually ran — the r4-w0b
# run-1 hole: fresh file not in project.pbxproj ⇒ bundle without the class ⇒
# "Executed 0 tests" + TEST SUCCEEDED).
if [ "$RC" -eq 0 ] && ! grep -q "Test Suite 'VoidGeometryUITests'" "$EVID/void-uitest-xcodebuild.log"; then
  log "VOID GATE VACUOUS — VoidGeometryUITests never ran (regenerate the project: cd apps/ios && xcodegen generate)."
  exit 1
fi
log "done rc=$RC: xcresult=$EVID/void-geometry.xcresult log=$EVID/void-uitest-xcodebuild.log"
exit "$RC"
