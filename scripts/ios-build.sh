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
# Early SWBBuildService-wedge detection (Xcode 26 made SWBBuildService a per-user
# SINGLETON Mach service — concurrent xcodebuilds race to register on the same XPC
# name and the loser parks forever at CreateBuildDescription; -derivedDataPath does
# NOT isolate the daemon. Corroborated externally: manaflow-ai/cmux#2980 / PR#2981.)
# We detect the wedge ~WEDGE_GRACE+2·WEDGE_TICK seconds in (default ~270s) instead of
# waiting the full TIMEOUT, and exit WEDGE_EXIT so callers/loops can branch to "needs
# human logout/login" rather than treating it as a normal build failure.
WEDGE_GRACE="${HERMES_WEDGE_GRACE:-240}"          # builds legitimately sit at CreateBuildDescription early; only judge after this
WEDGE_TICK="${HERMES_WEDGE_TICK:-15}"             # watchdog sample interval (secs)
WEDGE_EXIT=75                                      # distinct rc: wedge detected (vs a normal non-zero build failure)
# Set HERMES_BUILD_ALLOW_WEDGED=1 to downgrade a pre-flight wedge signature to a warning
# (default: ABORT before stacking another frozen build on a poisoned daemon).

log(){ printf '[ios-build] %s\n' "$*" >&2; }
usage(){ sed -n '2,33p' "${BASH_SOURCE[0]}" >&2; }

[ "$#" -eq 0 ] && { usage; exit 2; }

# True iff the log tail still shows we never got PAST build-description construction
# (the precise wedge locus: CreateBuildDescription / the toolchain version+macro
# probes). A healthy late-stage build [linking/packaging] will NOT match these, so
# this gate keeps the 0-swift-frontend wedge test from false-firing on a legit build
# that has simply finished compiling.
_stuck_at_build_description(){
  tail -6 "$LOG" 2>/dev/null | grep -qE \
    'CreateBuildDescription|swiftc --version|clang -v -E -dM|Constructing build description'
}

# ---- pre-flight: is the build service ALREADY wedged, or a foreign build racing it? ----
preflight_wedge_check(){
  local swb sf foreign
  swb=$(pgrep -x SWBBuildService 2>/dev/null | wc -l | tr -d ' ')
  sf=$(pgrep -x swift-frontend 2>/dev/null | wc -l | tr -d ' ')
  # (1) Already-wedged signature: SWBBuildService up, 0 swift-frontend, a live xcodebuild
  #     parked. Starting another build now just stacks a second frozen process on the
  #     poisoned per-user daemon. ABORT (override with HERMES_BUILD_ALLOW_WEDGED=1).
  if [ "${swb:-0}" -gt 0 ] && [ "${sf:-0}" -eq 0 ] && pgrep -x xcodebuild >/dev/null 2>&1; then
    if [ "${HERMES_BUILD_ALLOW_WEDGED:-0}" = "1" ]; then
      log "WARNING: SWBBuildService WEDGE signature present (0 swift-frontend + live xcodebuild)."
      log "         HERMES_BUILD_ALLOW_WEDGED=1 set — continuing anyway; watch for the hang."
    else
      log "ABORT: SWBBuildService WEDGE signature (0 swift-frontend + a parked xcodebuild) —"
      log "       the session-wide build daemon is already poisoned (ops_swbbuildservice_wedge;"
      log "       Xcode-26 per-user-singleton race, cf. manaflow-ai/cmux#2980)."
      log "       FIX: log out + back in (resets the per-user SWBBuildService), then re-run."
      log "       Do NOT kill -9 anything. Override (not advised): HERMES_BUILD_ALLOW_WEDGED=1."
      exit "$WEDGE_EXIT"
    fi
  fi
  # (2) Foreign xcodebuild concurrency race: a build we DON'T own is running (e.g.
  #     xcodebuildmcp from another worktree, or a manual xcodebuild) — the exact
  #     trigger for the per-user-singleton deadlock. Our mutex can't serialize a
  #     non-wrapper build, so surface it loudly (the lock wait below will also queue us).
  foreign=$(pgrep -x xcodebuild 2>/dev/null | wc -l | tr -d ' ')
  if [ "${foreign:-0}" -gt 0 ]; then
    log "NOTE: a foreign xcodebuild is already running (not via this wrapper). Concurrent"
    log "      xcodebuilds race the Xcode-26 SWBBuildService singleton — the wedge trigger."
    log "      Prefer routing ALL builds through scripts/ios-build.sh. Continuing under the mutex."
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

# Watchdog: two triggers, both SIGTERM-only (NEVER -9).
#   (A) EARLY WEDGE DETECT — after WEDGE_GRACE, if the build is parked with 0
#       swift-frontend AND the log tail is still at CreateBuildDescription/toolchain
#       probes AND no new .o is being produced AND xcodebuild is ~idle, it's the
#       SWBBuildService wedge. Reap now (~270s) instead of waiting out TIMEOUT, and
#       leave a WEDGE marker in the log so the parent returns WEDGE_EXIT.
#   (B) HARD TIMEOUT — the original backstop for a genuinely slow-but-alive build.
WEDGE_MARKER="$LOG.WEDGED"
rm -f "$WEDGE_MARKER" 2>/dev/null
( slept=0
  while kill -0 "$BUILD_PID" 2>/dev/null; do
    if [ "$slept" -ge "$WEDGE_GRACE" ] && _stuck_at_build_description; then
      sf=$(pgrep -x swift-frontend 2>/dev/null | wc -l | tr -d ' ')
      # objects compiled in the last ~2·WEDGE_TICK secs (real progress = NOT wedged)
      recent_o=$(find "$DEFAULT_DD" -name '*.o' -newermt "-$((WEDGE_TICK*2)) seconds" 2>/dev/null | head -1)
      bcpu=$(ps -o %cpu= -p "$BUILD_PID" 2>/dev/null | tr -d ' ')
      if [ "${sf:-0}" -eq 0 ] && [ -z "$recent_o" ] && \
         awk "BEGIN{exit !(${bcpu:-0} < 3)}" 2>/dev/null; then
        log "EARLY WEDGE DETECT (~${slept}s): 0 swift-frontend, no recent .o, xcodebuild idle,"
        log "  log still at CreateBuildDescription → SWBBuildService is wedged (Xcode-26 per-user"
        log "  singleton; ops_swbbuildservice_wedge / cmux#2980). SIGTERM $BUILD_PID (NEVER -9)."
        log "  RECOVERY: log out + back in to reset the per-user daemon, then re-run. No reboot needed."
        echo "WEDGE" > "$WEDGE_MARKER"
        kill -TERM "$BUILD_PID" 2>/dev/null
        sleep 8; kill -TERM "$BUILD_PID" 2>/dev/null
        break
      fi
    fi
    if [ "$slept" -ge "$TIMEOUT" ]; then
      log "TIMEOUT ${TIMEOUT}s — SIGTERM to $BUILD_PID (NEVER -9)."
      log "If it was wedged (0 swift-frontend at CreateBuildDescription), log out/in to recover."
      kill -TERM "$BUILD_PID" 2>/dev/null
      sleep 10; kill -TERM "$BUILD_PID" 2>/dev/null    # one polite nudge; still no -9
      break
    fi
    sleep "$WEDGE_TICK"; slept=$((slept+WEDGE_TICK))
  done ) &
WATCHDOG_PID=$!

wait "$BUILD_PID"; rc=$?
kill "$WATCHDOG_PID" 2>/dev/null

if [ -f "$WEDGE_MARKER" ]; then
  rm -f "$WEDGE_MARKER" 2>/dev/null
  log "RESULT: SWBBuildService WEDGE (rc->$WEDGE_EXIT). The build was reaped, not failed."
  log "        Recover with logout/login, then re-run this exact command."
  exit "$WEDGE_EXIT"
fi
if grep -qE "BUILD SUCCEEDED|ARCHIVE SUCCEEDED|EXPORT SUCCEEDED|TEST SUCCEEDED|TEST EXECUTE SUCCEEDED" "$LOG"; then
  log "SUCCESS (rc=$rc):"; grep -E "SUCCEEDED" "$LOG" | tail -3 >&2
else
  log "NOT successful (rc=$rc). last 15 log lines:"; tail -15 "$LOG" >&2
fi
exit "$rc"
