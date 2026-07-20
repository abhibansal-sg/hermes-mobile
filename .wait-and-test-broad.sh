#!/usr/bin/env bash
# Wait for mutex, then run the BROADER touched+affected test set (no rebuild if
# the .wait-and-build.sh already produced a test bundle — just test-without-building).
set -uo pipefail
LOCK_DIR="$HOME/.hermes/ios-build.lock"
REPO="/Volumes/MainData/Developer/hermes-tmp/worktrees/qa2-taskdock"
LOG="/Volumes/MainData/Developer/hermes-tmp/evidence/daily-driver-qa2/taskdock/taskdock-broad-tests.log"
mkdir -p "$(dirname "$LOG")"
attempts=0
while [ -d "$LOCK_DIR" ]; do
  attempts=$((attempts+1))
  [ "$attempts" -gt 240 ] && { echo "BROAD-TESTS: timed out waiting for mutex" | tee -a "$LOG"; exit 2; }
  sleep 5
done
echo "BROAD-TESTS: mutex free at $(date), running broader suites" | tee -a "$LOG"
cd "$REPO"
xcrun xcodebuild test-without-building \
  -project "$REPO/apps/ios/HermesMobile.xcodeproj" \
  -scheme HermesMobile \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -derivedDataPath "$REPO/apps/ios/.derivedData" \
  -only-testing:HermesMobileTests/TaskDockLifecycleTests \
  -only-testing:HermesMobileTests/TurnDockTests \
  -only-testing:HermesMobileTests/RelayTaskListBridgeTests \
  -only-testing:HermesMobileTests/RenderConformanceTests \
  -only-testing:HermesMobileTests/RelayGateBridgeTests \
  2>&1 | tail -40 >> "$LOG"
RC=${PIPESTATUS[0]}
echo "BROAD-TESTS: rc=$RC at $(date)" | tee -a "$LOG"
