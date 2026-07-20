#!/usr/bin/env bash
# scripts/qa1-cold-open-evidence.sh — QA-1 resume-lane A1/A7 instrumented
# evidence: bring up an ISOLATED mock gateway (never 9119; OS-assigned port) +
# the worktree relay against it (9140+ band, temp HERMES_HOME on
# /Volumes/MainData), wipe the sim app container for a true cold-start state,
# and run QA1ColdOpenRelayUITests — five cold opens asserting zero modal
# alerts, ≤2s composer interactivity, instant cache paint, drawer-closes-on-tap.
#
# Usage:
#   scripts/qa1-cold-open-evidence.sh
#   SIM_DEST='platform=iOS Simulator,name=iPhone 17 Pro' scripts/qa1-cold-open-evidence.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EVID="/Volumes/MainData/Developer/hermes-tmp/evidence/daily-driver-qa1/resume-lane"
mkdir -p "$EVID"
PY="${E2E_PYTHON:-/Volumes/MainData/Developer/hermes-tmp/e2e-venv/bin/python}"
SIM_DEST="${SIM_DEST:-platform=iOS Simulator,name=iPhone Air}"
BUNDLE_ID="ai.hermes.app"

mkdir -p /Volumes/MainData/Developer/hermes-tmp/e2e_daily_driver
HERMES_HOME="$(mktemp -d /Volumes/MainData/Developer/hermes-tmp/e2e_daily_driver/qa1-resume-home.XXXXXX)"
export HERMES_HOME

pids=()
cleanup() {
  for p in "${pids[@]:-}"; do kill -TERM "$p" 2>/dev/null || true; done
}
trap cleanup EXIT

log() { printf '[qa1-evidence] %s\n' "$*" >&2; }

# ---- 1. mock gateway (scripted echo; the e2e harness upstream) --------------
rm -f "$EVID/gateway.json"
"$PY" - "$ROOT" "$EVID/gateway.json" >"$EVID/mock-gateway.log" 2>&1 <<'PYEOF' &
import asyncio, json, pathlib, sys
root, out = sys.argv[1], sys.argv[2]
sys.path.insert(0, root + "/tests/e2e_daily_driver")
from mock_gateway.server import MockGateway

async def main():
    gw = MockGateway()
    await gw.start()
    pathlib.Path(out).write_text(json.dumps({"port": gw.port, "token": gw.token}))
    print(f"mock gateway listening on {gw.port}", flush=True)
    await asyncio.Event().wait()

asyncio.run(main())
PYEOF
pids+=($!)
for _ in $(seq 1 150); do [ -s "$EVID/gateway.json" ] && break; sleep 0.1; done
[ -s "$EVID/gateway.json" ] || { log "mock gateway failed to start"; cat "$EVID/mock-gateway.log" >&2; exit 1; }
GW_PORT="$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1]))["port"])' "$EVID/gateway.json")"
TOKEN="$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1]))["token"])' "$EVID/gateway.json")"
log "mock gateway up on 127.0.0.1:$GW_PORT"

# ---- 2. worktree relay against the mock gateway (isolated band) -------------
RELAY_PORT="${RELAY_PORT:-9141}"
while lsof -nP -iTCP:"$RELAY_PORT" -sTCP:LISTEN >/dev/null 2>&1; do
  RELAY_PORT=$((RELAY_PORT + 1))
  [ "$RELAY_PORT" -gt 9199 ] && { log "no free port in 9141-9199"; exit 1; }
done
PYTHONPATH="$ROOT/relay" \
HERMES_RELAY_GATEWAY_TOKEN="$TOKEN" \
HERMES_RELAY_PLUGIN_DIR="$ROOT/plugins/hermes-mobile" \
"$PY" -m hermes_relay \
  --gateway-host 127.0.0.1 --gateway-port "$GW_PORT" \
  --listen "127.0.0.1:$RELAY_PORT" --health-path /healthz \
  >"$EVID/relay.log" 2>&1 &
pids+=($!)
for _ in $(seq 1 200); do
  curl -fs "http://127.0.0.1:$RELAY_PORT/healthz" >/dev/null 2>&1 && break
  sleep 0.1
done
curl -fs "http://127.0.0.1:$RELAY_PORT/healthz" >/dev/null \
  || { log "relay failed to become healthy"; cat "$EVID/relay.log" >&2; exit 1; }
log "relay up on 127.0.0.1:$RELAY_PORT (healthz OK)"

# ---- 3. true cold-start state: wipe the app container ------------------------
BOOTED="$(xcrun simctl list devices booted 2>/dev/null | grep -c Booted || true)"
if [ "$BOOTED" -eq 0 ]; then
  UDID="$(xcrun simctl list devices available | sed -n "s/^ *iPhone Air (\([0-9A-F-]*\)).*/\1/p" | head -1)"
  if [ -n "$UDID" ]; then xcrun simctl boot "$UDID" 2>/dev/null || true; fi
fi
xcrun simctl uninstall booted "$BUNDLE_ID" 2>/dev/null || true
log "app container wiped (cold-start state)"

# ---- 4. run the cold-open suite (via the mutexed build wrapper) -------------
export TEST_RUNNER_HERMES_URL="http://127.0.0.1:$GW_PORT"
export TEST_RUNNER_HERMES_TOKEN="$TOKEN"
export TEST_RUNNER_HERMES_RELAY_URL="ws://127.0.0.1:$RELAY_PORT"
log "running QA1ColdOpenRelayUITests (5 cold opens) → $EVID/coldopens.xcresult"
rm -rf "$EVID/coldopens.xcresult"
cd "$ROOT"
HERMES_BUILD_LOG="$EVID/uitest-xcodebuild.log" HERMES_BUILD_TIMEOUT=2400 \
  scripts/ios-build.sh test \
  -scheme HermesMobile \
  -destination "$SIM_DEST" \
  -only-testing:HermesMobileUITests/QA1ColdOpenRelayUITests \
  -resultBundlePath "$EVID/coldopens.xcresult" 2>&1 | tail -40
log "done: xcresult=$EVID/coldopens.xcresult log=$EVID/uitest-xcodebuild.log"
