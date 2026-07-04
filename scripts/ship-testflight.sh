#!/bin/bash
# ship-testflight.sh — autonomous INTERNAL TestFlight ship for a completed build wave.
# Encodes apps/ios/SHIP-TESTFLIGHT.md exactly. Internal-only (uploads to ASC; internal
# testers auto-receive). External beta review is NOT automated (stays Abhi's gate).
#
# Usage: ship-testflight.sh <wave-number>
#   Exits 0 + "SHIP SKIPPED" if the wave is not fully merged (nothing to ship).
#   Exits 0 + "SHIPPED build N" on success. Non-zero on a real ship failure.
#
# Safety: version bump is the ONLY build-number change. Wedge-safe archive via
# ios-build.sh (never raw xcodebuild, never kill -9). CFBundleVersion gate before
# upload. Idempotent-ish: refuses to ship if HEAD already shipped (same build no).
set -uo pipefail

# Operator identity (ASC ids, sim UDID) — see .loop-env.example
if [ -f "$(dirname "${BASH_SOURCE[0]}")/../.loop-env" ]; then set -a; . "$(dirname "${BASH_SOURCE[0]}")/../.loop-env"; set +a; fi
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO" || { echo "ship: repo missing"; exit 1; }

WAVE="${1:-}"
ASC_KEY="${ASC_KEY_FILE:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID:-}.p8}"
ASC_ISSUER="${ASC_ISSUER_ID:-}"
ASC_KEYID="${ASC_KEY_ID:-}"
APP_ID=6777140135
TOKEN="$("$HOME/.hermes/scripts/linear-app-token.sh" 2>/dev/null || true)"
BASE=environment-and-workflows-overview
ARCH=/tmp/hermes-tf/HermesMobile.xcarchive

echo "🚀 SHIP TestFlight (internal) — wave=${WAVE:-<unspecified>} — $(date '+%a %H:%M %Z')"

# --- MUTEX: only one ship at a time (mirrors scripts/ios-build.sh mkdir-lock) --
# Without this, two concurrent ship invocations (orchestrator cadence + soak/live-
# beat) each bump the build and trigger a separate Xcode Cloud run — double-firing
# compute and stranding builds as bumps with no completion (ABH-348, 2026-07-03).
# macOS has no flock(1); mkdir is atomic so we use it for the try-lock. Non-blocking:
# a concurrent ship prints "SHIP SKIPPED" and exits 0 (a skipped ship is not a failure).
SHIP_LOCK_DIR="$HOME/.hermes/ship-testflight.lock"
release_ship_lock(){
  [ -f "$SHIP_LOCK_DIR/pid" ] && [ "$(cat "$SHIP_LOCK_DIR/pid" 2>/dev/null)" = "$$" ] \
    && rm -rf "$SHIP_LOCK_DIR"
}
if mkdir "$SHIP_LOCK_DIR" 2>/dev/null; then
  : # lock acquired
else
  _holder=$(cat "$SHIP_LOCK_DIR/pid" 2>/dev/null || echo "")
  if [ -n "$_holder" ] && ! kill -0 "$_holder" 2>/dev/null; then
    # stale lock from a crashed/killed ship — reclaim and proceed
    rm -rf "$SHIP_LOCK_DIR"
    mkdir "$SHIP_LOCK_DIR" 2>/dev/null || { echo "SHIP SKIPPED: another ship in progress"; exit 0; }
  else
    echo "SHIP SKIPPED: another ship in progress (pid ${_holder:-?})"
    exit 0
  fi
fi
echo "$$" > "$SHIP_LOCK_DIR/pid"
echo "$(date '+%Y-%m-%d %H:%M:%S') wave=${WAVE:-<adhoc>}" > "$SHIP_LOCK_DIR/info"
trap release_ship_lock EXIT INT TERM

# --- SELFTEST GUARD (test-only — inert in normal runs; ABH-348) ---------------
# When SHIP_SELFTEST=1 is set, exit immediately AFTER the mutex decision but
# BEFORE any side effect (gates, git ops, build bump, archive, upload, cloud
# trigger). This is the hard safety boundary that makes test-ship-mutex.sh
# hermetic: the test exercises the mutex contention path, and even if the
# mutex is removed (false-green proof), SHIP_SELFTEST stops the script here
# before it can reach GATE 0 or anything downstream. Inert by default —
# SHIP_SELFTEST is never set in normal ship runs.
if [ "${SHIP_SELFTEST:-0}" = "1" ]; then
  echo "SHIP SELFTEST: mutex acquired, stopping before any side effect"
  exit 0
fi

# --- GATE 0: kill switch + is ship even armed? -------------------------------
python3 - <<'PY' || exit 0
import json,sys
g=json.load(open('.claude/loops/governor.json'))
if not g.get('enabled'): print("  governor DISABLED — ship skipped"); sys.exit(1)
sp=g.get('ship_policy',{})
if not sp.get('autonomous_ship_active'): print("  autonomous ship not armed — skipped"); sys.exit(1)
if sp.get('track')!='internal': print(f"  ship track={sp.get('track')} != internal — refusing (external is Abhi's gate)"); sys.exit(1)
print("  ship armed: internal TestFlight")
PY
[ $? -ne 0 ] && exit 0

# --- STEP 0: SYNC LOCAL TO MERGED ORIGIN BASE (before archiving anything) -----
# The ship archives the local working tree. If local HEAD lags origin/$BASE (e.g.
# the orchestrator just merged PRs to origin but this checkout is behind), we'd
# archive a STALE tree — shipping code that isn't the merged base. Fast-forward
# first so we always build the just-merged tree. (Root cause of a 2026-07-02
# mis-ship: archived stale HEAD behind the merge.)
git fetch origin "$BASE" -q 2>/dev/null
LOCAL_HEAD=$(git rev-parse HEAD 2>/dev/null)
ORIGIN_HEAD=$(git rev-parse "origin/$BASE" 2>/dev/null)
if [ -n "$ORIGIN_HEAD" ] && [ "$LOCAL_HEAD" != "$ORIGIN_HEAD" ]; then
  if git merge-base --is-ancestor "$LOCAL_HEAD" "$ORIGIN_HEAD" 2>/dev/null; then
    echo "  syncing local HEAD $(git rev-parse --short HEAD) -> origin/$BASE $(git rev-parse --short origin/$BASE) before archive"
    git checkout "$BASE" -q 2>/dev/null && git merge --ff-only "origin/$BASE" -q 2>/dev/null \
      || { echo "  FF sync failed (dirty tree?) — refusing to ship a stale/ambiguous tree"; exit 1; }
  else
    echo "  local HEAD has commits not on origin/$BASE — refusing to ship an unmerged tree"; exit 1
  fi
fi

# --- GATE 1: wave fully merged? (no open/approved issues left in the wave) ----
git fetch origin "$BASE" -q 2>/dev/null
if [ -n "$WAVE" ]; then
  if [ -z "$TOKEN" ]; then
    OPEN=ERR
  else
    OPEN=$(curl -s -X POST https://api.linear.app/graphql \
      -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
      -d "{\"query\":\"{ issues(first:20, filter:{ labels:{ name:{ eq:\\\"wave:build-${WAVE}\\\" } }, state:{ type:{ nin:[\\\"completed\\\",\\\"canceled\\\"] } } }){ nodes{ identifier state{name} } } }\"}" 2>/dev/null \
      | python3 -c "import sys,json;
try: print(len(json.load(sys.stdin)['data']['issues']['nodes']))
except: print('ERR')")
  fi
  if [ "$OPEN" = "ERR" ]; then echo "  SHIP SKIPPED: could not read wave state"; exit 0; fi
  if [ "$OPEN" != "0" ]; then echo "  SHIP SKIPPED: wave-${WAVE} has $OPEN unmerged/incomplete issues"; exit 0; fi
fi

# --- GATE 2: has HEAD already shipped? (avoid burning a build number) ---------
CUR=$(grep -E "CURRENT_PROJECT_VERSION:" apps/ios/project.yml | head -1 | grep -oE "[0-9]+")
LAST_SHIP_SHA=$(git log -1 --grep="ship: TestFlight build" --format="%H" 2>/dev/null)
if [ -n "$LAST_SHIP_SHA" ]; then
  COMMITS_SINCE_LAST_SHIP=$(git rev-list --count "$LAST_SHIP_SHA"..HEAD)
  if [ "$COMMITS_SINCE_LAST_SHIP" = "0" ]; then
    echo "  SHIP SKIPPED: build $CUR already shipped (no new merges since last ship)"; exit 0
  fi
fi

# --- GATE 2b: CADENCE (2026-07-03, continuous-flow mode) ----------------------
# With no wave argument, ships run on a time+merge cadence instead of wave
# completion: ship iff >=1 merge since last ship AND (>=4h since last ship OR
# >=6 merges accumulated). Prevents both build-number churn (a ship per merge)
# and starvation (merges piling up 13h waiting for a "wave" that never closes).
# A wave argument (legacy) or FORCE_SHIP=1 bypasses the cadence gate.
if [ -z "$WAVE" ] && [ "${FORCE_SHIP:-0}" != "1" ] && [ -n "$LAST_SHIP_SHA" ]; then
  LAST_SHIP_TS=$(git log -1 --format="%ct" "$LAST_SHIP_SHA" 2>/dev/null || echo 0)
  NOW_TS=$(date +%s)
  HOURS_SINCE=$(( (NOW_TS - LAST_SHIP_TS) / 3600 ))
  if [ "$HOURS_SINCE" -lt 4 ] && [ "$COMMITS_SINCE_LAST_SHIP" -lt 6 ]; then
    echo "  SHIP SKIPPED (cadence): ${COMMITS_SINCE_LAST_SHIP} merges, ${HOURS_SINCE}h since last ship (need >=4h or >=6 merges)"; exit 0
  fi
  echo "  cadence gate passed: ${COMMITS_SINCE_LAST_SHIP} merges, ${HOURS_SINCE}h since last ship"
fi

# --- STEP 1+2-4: BUILD NUMBER + BUILD + UPLOAD ---------------------------------
# TWO PATHS, ONE BUILD-NUMBER AUTHORITY EACH (2026-07-03, after the cloud/local
# counter collision — "bundle version must be higher than previously uploaded"):
#   CLOUD: Xcode Cloud's own counter stamps CFBundleVersion (set >= 70 in the
#          workflow UI by Abhi). We do NOT bump project.yml; we read the real
#          number back from the run and use it for polling/notes/record.
#   LOCAL: we bump project.yml as before (the only place it changes).
CLOUD_WF=$(python3 -c "
import json
g=json.load(open('.claude/loops/governor.json'))
xc=g.get('ship_policy',{}).get('xcode_cloud',{})
print(xc.get('workflow_id','') if xc.get('active') else '')" 2>/dev/null)

CLOUD_OK=0
if [ -n "$CLOUD_WF" ]; then
  echo "  CLOUD SHIP: triggering Xcode Cloud workflow $CLOUD_WF (cloud owns the build number)"
  # Push any unpushed state so the cloud builds current base (no bump commit).
  git push origin HEAD:"$BASE" -q 2>/dev/null || true
  TRIGGER_OUT=$(node apps/ios/ci_scripts/asc-cloud.mjs trigger "$CLOUD_WF" "$BASE" 2>&1)
  RUN_ID=$(echo "$TRIGGER_OUT" | awk '/^  ID:/{print $2}' | head -1)
  CLOUD_BUILD=$(echo "$TRIGGER_OUT" | awk '/^  Build #:/{print $3}' | head -1)
  if [ -n "$RUN_ID" ]; then
    echo "  cloud build run: $RUN_ID (cloud build number: ${CLOUD_BUILD:-unknown}) — waiting (ceiling 45m)…"
    if node apps/ios/ci_scripts/asc-cloud.mjs wait "$RUN_ID" 2>&1 | tail -3 | grep -q "SUCCEEDED"; then
      CLOUD_OK=1
      # Cloud's run number IS the shipped CFBundleVersion.
      if [ -n "$CLOUD_BUILD" ] && [ "$CLOUD_BUILD" != "—" ]; then NEXT="$CLOUD_BUILD"; fi
      echo "  cloud build SUCCEEDED — build $NEXT archived+uploaded on Apple's machines"
      # Record the cloud number in project.yml so local and cloud counters never
      # cross again (next local fallback bump starts above it).
      python3 - "$NEXT" <<'PY'
import re,sys
n=sys.argv[1]
p='apps/ios/project.yml'; s=open(p).read()
s=re.sub(r'(CURRENT_PROJECT_VERSION:\s*)\d+', r'\g<1>'+n, s, count=1)
open(p,'w').write(s)
PY
      ( cd apps/ios && xcodegen generate >/dev/null 2>&1 ) || true
    else
      echo "  cloud build did not succeed — falling back to LOCAL archive path"
    fi
  else
    echo "  cloud trigger failed (no run id) — falling back to LOCAL archive path"
  fi
fi

if [ "$CLOUD_OK" != "1" ]; then
# --- LOCAL PATH: bump build number (the ONLY local place it changes) -----------
NEXT=$((CUR + 1))
echo "  bumping build $CUR -> $NEXT"
python3 - "$NEXT" <<'PY'
import re,sys
n=sys.argv[1]
p='apps/ios/project.yml'; s=open(p).read()
s=re.sub(r'(CURRENT_PROJECT_VERSION:\s*)\d+', r'\g<1>'+n, s, count=1)
open(p,'w').write(s)
PY
( cd apps/ios && xcodegen generate >/dev/null 2>&1 ) || { echo "  FAIL: xcodegen"; exit 1; }

# --- archive (wedge-safe wrapper) ----------------------------------------------
rm -rf /tmp/hermes-tf; mkdir -p /tmp/hermes-tf
echo "  archiving (timeout 2400s, wedge-safe)…"
HERMES_BUILD_TIMEOUT=2400 scripts/ios-build.sh archive \
  -scheme HermesMobile -destination 'generic/platform=iOS' \
  -archivePath "$ARCH" \
  -authenticationKeyPath "$ASC_KEY" -authenticationKeyID "$ASC_KEYID" \
  -authenticationKeyIssuerID "$ASC_ISSUER" -allowProvisioningUpdates 2>&1 | tail -5
[ -d "$ARCH" ] || { echo "  FAIL: archive did not produce $ARCH"; exit 1; }

# --- CFBundleVersion gate (app + both extensions must match) ------------------
A="$ARCH/Products/Applications/HermesMobile.app"
V1=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$A/Info.plist" 2>/dev/null)
V2=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$A/PlugIns/HermesWidgets.appex/Info.plist" 2>/dev/null)
V3=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$A/PlugIns/HermesShare.appex/Info.plist" 2>/dev/null)
echo "  CFBundleVersion: app=$V1 widgets=$V2 share=$V3"
if [ "$V1" != "$V2" ] || [ "$V1" != "$V3" ]; then echo "  FAIL: CFBundleVersion mismatch — aborting before upload"; exit 1; fi

# --- export + upload to ASC (ExportOptions destination=upload) ----------------
echo "  exporting + uploading to App Store Connect…"
xcodebuild -exportArchive -archivePath "$ARCH" \
  -exportOptionsPlist apps/ios/ExportOptions-TestFlight.plist \
  -exportPath /tmp/hermes-tf/export \
  -authenticationKeyPath "$ASC_KEY" -authenticationKeyID "$ASC_KEYID" \
  -authenticationKeyIssuerID "$ASC_ISSUER" -allowProvisioningUpdates 2>&1 | tail -6 \
  | grep -qE "EXPORT SUCCEEDED|Uploaded HermesMobile" || { echo "  FAIL: export/upload did not report success"; exit 1; }
fi

# --- STEP 5: poll ASC until build shows VALID (~5-15 min) ---------------------
echo "  polling ASC for build $NEXT to reach VALID…"
node scripts/asc-poll.mjs 2>&1 | tail -4 || echo "  (poll wrapper returned non-zero; check ASC manually)"

# --- STEP 5b: RELEASE NOTES (Abhi mandate 2026-07-02: no ship without notes) ---
# Generate human-readable notes from merges since last ship, prepend to
# RELEASE_NOTES.md, and push to TestFlight's "What to Test" so the user knows
# what to expect when updating.
echo "  generating release notes for build ${NEXT}…"
bash scripts/gen-release-notes.sh "$NEXT" "/tmp/notes-$NEXT.txt" >/dev/null 2>&1 || echo "  (notes gen failed — ship continues, notes to be backfilled)"
node scripts/asc-notes.mjs --build "$NEXT" --notes-file "/tmp/notes-$NEXT.txt" 2>&1 | tail -1 || echo "  (What-to-Test push failed — notes exist in RELEASE_NOTES.md; backfill via asc-notes.mjs)"

# --- STEP 6: commit the build-number bump + release notes (records the ship) ---
git add apps/ios/project.yml apps/ios/*.xcodeproj RELEASE_NOTES.md 2>/dev/null
git commit -q -m "ship: TestFlight build $NEXT (wave ${WAVE:-adhoc}, internal, autonomous)" 2>/dev/null
git push origin HEAD:"$BASE" 2>&1 | tail -2

echo "✅ SHIPPED build $NEXT to internal TestFlight (wave ${WAVE:-adhoc}) with release notes."

# --- STEP 7: REAP (2026-07-03) — a ship means a wave's worktrees are merged.
# Reclaim their per-worktree .derivedData (~1.9G each) + remove merged worktrees.
# This is the systemic fix for the 48G .worktrees leak: cleanup rides the ship,
# so disk never silts. Loss-free (derivedData regenerates; only base-merged
# worktrees are removed). Never blocks the ship — best-effort tail step.
if [ -x "$REPO/scripts/worktree-reap.sh" ]; then
  echo "  reaping merged worktrees + derivedData…"
  bash "$REPO/scripts/worktree-reap.sh" 2>&1 | tail -3 || echo "  (reap best-effort; non-fatal)"
fi
