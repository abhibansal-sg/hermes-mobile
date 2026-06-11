#!/usr/bin/env bash
# scripts/ios-build.sh — serialized, wedge-safe wrapper around `xcodebuild` for the
# HermesMobile iOS app.
#
# WHY THIS EXISTS:
#   Xcode's SWBBuildService wedges the ENTIRE login session if two iOS builds run
#   at once, or if a build is force-killed (kill -9). Once wedged, every xcodebuild
#   on the machine — across unrelated projects — deadlocks at "Constructing build
#   description" (0 swift-frontend, 0% CPU) and ONLY a reboot/logout clears it.
#   This cost a ~2.5h diagnosis + a reboot on 2026-06-08. In Conductor's
#   parallel-worktree model the trigger (concurrent builds) is far easier to hit.
#   See memory: ops_swbbuildservice_wedge.
#
# GUARANTEES BY CONSTRUCTION:
#   1. Only ONE iOS build runs at a time across ALL worktrees on this machine
#      (machine-global mutex at ~/.hermes/ios-build.lock, stale-lock aware).
#   2. Per-worktree DerivedData (never shared between worktrees) — auto-injected.
#   3. A hung build is reaped with SIGTERM, NEVER SIGKILL. kill -9 is patient zero
#      for the session-wide wedge.
#   4. Pre-flight detection of an already-wedged build service, so you reboot
#      instead of stacking another frozen build.
#
# USAGE:
#   scripts/ios-build.sh build   -scheme HermesMobile -destination 'generic/platform=iOS Simulator'
#   scripts/ios-build.sh archive -scheme HermesMobile -archivePath /tmp/x.xcarchive ...
#   HERMES_BUILD_TIMEOUT=2400 scripts/ios-build.sh archive ...   # watchdog secs (default 1200)
#   HERMES_BUILD_LOG=/tmp/my.log scripts/ios-build.sh build ...  # full xcodebuild log path
#
# Auto-injects `-project apps/ios/HermesMobile.xcodeproj` and a per-worktree
# `-derivedDataPath` unless you pass your own -project/-workspace/-derivedDataPath.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJ="$REPO_ROOT/apps/ios/HermesMobile.xcodeproj"
DEFAULT_DD="$REPO_ROOT/apps/ios/.derivedData"
LOCK_DIR="$HOME/.hermes/ios-build.lock"          # machine-global; stable across worktrees + sessions
TIMEOUT="${HERMES_BUILD_TIMEOUT:-1200}"
LOG="${HERMES_BUILD_LOG:-/tmp/hermes-ios-build-$$.log}"

log(){ printf '[ios-build] %s\n' "$*" >&2; }
usage(){ sed -n '2,33p' "${BASH_SOURCE[0]}" >&2; }

[ "$#" -eq 0 ] && { usage; exit 2; }

# ---- pre-flight: is the build service ALREADY wedged? ------------------------
preflight_wedge_check(){
  local swb sf
  swb=$(pgrep -x SWBBuildService 2>/dev/null | wc -l | tr -d ' ')
  sf=$(pgrep -x swift-frontend 2>/dev/null | wc -l | tr -d ' ')
  if [ "${swb:-0}" -gt 0 ] && [ "${sf:-0}" -eq 0 ] && pgrep -x xcodebuild >/dev/null 2>&1; then
    log "WARNING: SWBBuildService is up with 0 swift-frontend AND a live xcodebuild —"
    log "         this is the SESSION-WIDE BUILD WEDGE signature (ops_swbbuildservice_wedge)."
    log "         If this build hangs at 'Constructing build description', the fix is a REBOOT."
    log "         Do NOT kill -9 anything. Continuing, but watch for the hang."
  fi
}

# ---- machine-global mutex (mkdir is atomic; pid file enables stale reclaim) --
acquire_lock(){
  mkdir -p "$(dirname "$LOCK_DIR")" 2>/dev/null || true
  local waited=0 holder
  while true; do
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      echo "$$" > "$LOCK_DIR/pid"
      echo "$(date '+%Y-%m-%d %H:%M:%S') $REPO_ROOT" > "$LOCK_DIR/info"
      trap release_lock EXIT INT TERM
      return 0
    fi
    holder=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")
    if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
      log "stale lock from dead pid $holder — reclaiming"
      rm -rf "$LOCK_DIR"; continue
    fi
    [ $((waited % 15)) -eq 0 ] && \
      log "another iOS build holds the lock (pid ${holder:-?}: $(cat "$LOCK_DIR/info" 2>/dev/null)); waiting…"
    sleep 3; waited=$((waited+3))
  done
}
release_lock(){
  [ -f "$LOCK_DIR/pid" ] && [ "$(cat "$LOCK_DIR/pid" 2>/dev/null)" = "$$" ] && rm -rf "$LOCK_DIR"
}

# ---- inject -project / -derivedDataPath if absent ---------------------------
args=("$@")
have_dd=false; have_proj=false
for a in "${args[@]}"; do
  case "$a" in
    -derivedDataPath) have_dd=true ;;
    -project|-workspace) have_proj=true ;;
  esac
done
$have_proj || args=("-project" "$PROJ" "${args[@]}")
$have_dd   || args+=("-derivedDataPath" "$DEFAULT_DD")

# ---- run under watchdog (SIGTERM on timeout, NEVER -9) -----------------------
preflight_wedge_check
acquire_lock
log "lock acquired. building: xcodebuild ${args[*]}"
log "derivedData=${DEFAULT_DD} (unless overridden) | timeout=${TIMEOUT}s | log=$LOG"

xcodebuild "${args[@]}" >"$LOG" 2>&1 &
BUILD_PID=$!

( slept=0
  while kill -0 "$BUILD_PID" 2>/dev/null; do
    if [ "$slept" -ge "$TIMEOUT" ]; then
      log "TIMEOUT ${TIMEOUT}s — SIGTERM to $BUILD_PID (NEVER -9)."
      log "If it was wedged (0 swift-frontend at CreateBuildDescription), a REBOOT is required."
      kill -TERM "$BUILD_PID" 2>/dev/null
      sleep 10; kill -TERM "$BUILD_PID" 2>/dev/null    # one polite nudge; still no -9
      break
    fi
    sleep 5; slept=$((slept+5))
  done ) &
WATCHDOG_PID=$!

wait "$BUILD_PID"; rc=$?
kill "$WATCHDOG_PID" 2>/dev/null

if grep -qE "BUILD SUCCEEDED|ARCHIVE SUCCEEDED|EXPORT SUCCEEDED|TEST SUCCEEDED|TEST EXECUTE SUCCEEDED" "$LOG"; then
  log "SUCCESS (rc=$rc):"; grep -E "SUCCEEDED" "$LOG" | tail -3 >&2
else
  log "NOT successful (rc=$rc). last 15 log lines:"; tail -15 "$LOG" >&2
fi
exit "$rc"
