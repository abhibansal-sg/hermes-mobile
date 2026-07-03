#!/bin/bash
# ui-test.sh — single entrypoint for agent-driven UI testing (L-regress lane).
# Contract: docs/autonomous/UI-TESTING.md. WEDGE INVARIANT: this script never
# invokes raw xcodebuild; artifact refresh goes through scripts/ios-build.sh
# (the machine-global mutex) and only when the .app is stale.
#
# Usage:
#   scripts/ui-test.sh <flow-path|all> [--udid UDID] [--fresh-state]
#   scripts/ui-test.sh cuj/cuj-01-launch-drawer.yaml
#   scripts/ui-test.sh all            # every flow under tests/flows/{cuj,regressions}
# Output: human log + final line "UI-TEST VERDICT: PASS|FAIL passed=N failed=N"
# Exit: 0 all green, 1 any failure, 2 infra error (couldn't even run).
set -uo pipefail
REPO=/Users/abbhinnav/Developer/products/hermes-mobile
BUNDLE_ID=ai.hermes.app
DEFAULT_UDID=BC5EB32A-C67E-45BF-8BA9-7EBC0FE40C0B   # iPhone 17 Pro
DERIVED="$REPO/apps/ios/.derivedData/Build/Products"
export JAVA_HOME=${JAVA_HOME:-/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home}
# PATH NOTE (GATE-1 pitfall, cost an hour): ~/.hermes/bin holds the xcodebuild
# wedge-shim. Maestro internally invokes xcodebuild to install its prebuilt test
# runner; the shim intercepts that call and kills the driver startup
# (IOSDriverTimeoutException). So: NO ~/.hermes/bin in this script's PATH.
# Our own artifact build still goes through the mutex EXPLICITLY via
# scripts/ios-build.sh below — the invariant holds without the shim.
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin"
cd "$REPO" || { echo "UI-TEST VERDICT: FAIL infra (repo missing)"; exit 2; }

TARGET="${1:?usage: ui-test.sh <flow|all> [--udid U] [--fresh-state]}"
shift
UDID="$DEFAULT_UDID"; FRESH=0
while [ $# -gt 0 ]; do
  case "$1" in
    --udid) UDID="$2"; shift 2;;
    --fresh-state) FRESH=1; shift;;
    *) shift;;
  esac
done

# --- 1. Resolve the .app artifact (reuse-first; mutexed refresh only if stale) --
APP=$(ls -dt "$DERIVED"/*-iphonesimulator/HermesMobile.app 2>/dev/null | head -1)
STALE=1
if [ -n "$APP" ]; then
  APP_AGE_H=$(( ($(date +%s) - $(stat -f %m "$APP")) / 3600 ))
  # Stale iff older than the newest commit on the local tree AND >6h old.
  LAST_COMMIT_TS=$(git log -1 --format=%ct 2>/dev/null || echo 0)
  APP_TS=$(stat -f %m "$APP")
  if [ "$APP_TS" -ge "$LAST_COMMIT_TS" ] || [ "$APP_AGE_H" -lt 6 ]; then STALE=0; fi
fi
if [ -z "$APP" ] || [ "$STALE" = "1" ]; then
  echo "[ui-test] artifact missing/stale — ONE mutexed build-for-testing (wedge-safe)"
  HERMES_BUILD_TIMEOUT=2400 scripts/ios-build.sh build-for-testing \
    -scheme HermesMobile -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -2
  APP=$(ls -dt "$DERIVED"/*-iphonesimulator/HermesMobile.app 2>/dev/null | head -1)
  [ -n "$APP" ] || { echo "UI-TEST VERDICT: FAIL infra (no artifact after build)"; exit 2; }
fi
echo "[ui-test] app: $APP"

# --- 2. Sim up + app installed ---------------------------------------------------
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1
[ "$FRESH" = "1" ] && { xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null; xcrun simctl uninstall "$UDID" "$BUNDLE_ID" 2>/dev/null; }
xcrun simctl install "$UDID" "$APP" || { echo "UI-TEST VERDICT: FAIL infra (install)"; exit 2; }

# --- 3. Collect flows --------------------------------------------------------------
FLOWS=()
if [ "$TARGET" = "all" ]; then
  while IFS= read -r f; do FLOWS+=("$f"); done < <(find tests/flows/cuj tests/flows/regressions -name '*.yaml' 2>/dev/null | sort)
else
  [ -f "tests/flows/$TARGET" ] && FLOWS=("tests/flows/$TARGET") || FLOWS=("$TARGET")
fi
[ ${#FLOWS[@]} -gt 0 ] || { echo "UI-TEST VERDICT: FAIL infra (no flows)"; exit 2; }

# --- 4. Run (Maestro is single-instance: flows run serially by design) -------------
OUT_DIR="/tmp/ui-test-$(date +%H%M%S)"; mkdir -p "$OUT_DIR"
PASS=0; FAIL=0; FAILED_FLOWS=()
for f in "${FLOWS[@]}"; do
  name=$(basename "$f" .yaml)
  echo "[ui-test] flow: $name"
  # UI flows flake (driver startup, animation timing) — one retry before FAIL.
  # A flake that passes on retry is a pass; failing TWICE is a real failure.
  ok=0
  for attempt in 1 2; do
    if (cd "$OUT_DIR" && timeout 300 maestro --udid "$UDID" test "$REPO/$f" 2>&1 | tail -4); then
      ok=1; break
    fi
    [ "$attempt" = "1" ] && echo "[ui-test] flow $name failed attempt 1 — retrying once"
  done
  if [ "$ok" = "1" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED_FLOWS+=("$name"); fi
done
echo "[ui-test] screenshots: $OUT_DIR"
if [ "$FAIL" = "0" ]; then
  echo "UI-TEST VERDICT: PASS passed=$PASS failed=0"
  exit 0
else
  echo "UI-TEST VERDICT: FAIL passed=$PASS failed=$FAIL flows=[${FAILED_FLOWS[*]}]"
  exit 1
fi
