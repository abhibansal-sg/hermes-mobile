#!/usr/bin/env bash
# Wait for the machine-global iOS mutex to free, then build+test the taskdock lane.
set -uo pipefail
LOCK_DIR="$HOME/.hermes/ios-build.lock"
REPO="/Volumes/MainData/Developer/hermes-tmp/worktrees/qa2-taskdock"
LOG="/Volumes/MainData/Developer/hermes-tmp/evidence/daily-driver-qa2/taskdock-ios-build.log"
mkdir -p "$(dirname "$LOG")"

attempts=0
while [ -d "$LOCK_DIR" ]; do
  attempts=$((attempts+1))
  if [ "$attempts" -gt 240 ]; then
    echo "TASKDOCK-BUILD: timed out after ~20min waiting for mutex" | tee -a "$LOG"
    exit 2
  fi
  sleep 5
done

echo "TASKDOCK-BUILD: mutex free at $(date), starting build+test" | tee -a "$LOG"
cd "$REPO"
HERMES_BUILD_TIMEOUT=3000 HERMES_BUILD_LOG="$LOG" \
  scripts/ios-build.sh build-for-testing \
  -scheme HermesMobile \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -derivedDataPath "$REPO/apps/ios/.derivedData" 2>&1 | tail -60 >> "$LOG"
RC=${PIPESTATUS[0]}
echo "TASKDOCK-BUILD: build-for-testing rc=$RC at $(date)" | tee -a "$LOG"

if [ "$RC" -eq 0 ]; then
  echo "TASKDOCK-BUILD: running touched test suites" | tee -a "$LOG"
  xcrun xcodebuild test-without-building \
    -project "$REPO/apps/ios/HermesMobile.xcodeproj" \
    -scheme HermesMobile \
    -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
    -derivedDataPath "$REPO/apps/ios/.derivedData" \
    -only-testing:HermesMobileTests/TaskDockLifecycleTests \
    -only-testing:HermesMobileTests/TurnDockTests \
    -only-testing:HermesMobileTests/RelayTaskListBridgeTests \
    2>&1 | tail -120 >> "$LOG"
  TRC=${PIPESTATUS[0]}
  echo "TASKDOCK-BUILD: test rc=$TRC at $(date)" | tee -a "$LOG"
  exit $TRC
fi
exit $RC
