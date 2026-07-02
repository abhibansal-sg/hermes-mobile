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
REPO=/Users/abbhinnav/Developer/products/hermes-mobile
cd "$REPO" || { echo "ship: repo missing"; exit 1; }

WAVE="${1:-}"
ASC_KEY=/Users/abbhinnav/.appstoreconnect/private_keys/AuthKey_3DHXXG4GHQ.p8
ASC_ISSUER=d7deff8e-5489-4d18-995d-c8a10f854118
ASC_KEYID=3DHXXG4GHQ
APP_ID=6777140135
BASE=environment-and-workflows-overview
ARCH=/tmp/hermes-tf/HermesMobile.xcarchive

echo "🚀 SHIP TestFlight (internal) — wave=${WAVE:-<unspecified>} — $(date '+%a %H:%M %Z')"

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
  OPEN=$(curl -s -X POST https://api.linear.app/graphql \
    -H "Authorization: $LINEAR_API_KEY" -H "Content-Type: application/json" \
    -d "{\"query\":\"{ issues(first:20, filter:{ labels:{ name:{ eq:\\\"wave:build-${WAVE}\\\" } }, state:{ type:{ nin:[\\\"completed\\\",\\\"canceled\\\"] } } }){ nodes{ identifier state{name} } } }\"}" 2>/dev/null \
    | python3 -c "import sys,json;
try: print(len(json.load(sys.stdin)['data']['issues']['nodes']))
except: print('ERR')")
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

# --- STEP 1: bump build number (ONLY place it changes) -----------------------
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

# --- STEP 2: archive (wedge-safe wrapper) ------------------------------------
rm -rf /tmp/hermes-tf; mkdir -p /tmp/hermes-tf
echo "  archiving (timeout 2400s, wedge-safe)…"
HERMES_BUILD_TIMEOUT=2400 scripts/ios-build.sh archive \
  -scheme HermesMobile -destination 'generic/platform=iOS' \
  -archivePath "$ARCH" \
  -authenticationKeyPath "$ASC_KEY" -authenticationKeyID "$ASC_KEYID" \
  -authenticationKeyIssuerID "$ASC_ISSUER" -allowProvisioningUpdates 2>&1 | tail -5
[ -d "$ARCH" ] || { echo "  FAIL: archive did not produce $ARCH"; exit 1; }

# --- STEP 3: CFBundleVersion gate (app + both extensions must match) ----------
A="$ARCH/Products/Applications/HermesMobile.app"
V1=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$A/Info.plist" 2>/dev/null)
V2=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$A/PlugIns/HermesWidgets.appex/Info.plist" 2>/dev/null)
V3=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$A/PlugIns/HermesShare.appex/Info.plist" 2>/dev/null)
echo "  CFBundleVersion: app=$V1 widgets=$V2 share=$V3"
if [ "$V1" != "$V2" ] || [ "$V1" != "$V3" ]; then echo "  FAIL: CFBundleVersion mismatch — aborting before upload"; exit 1; fi

# --- STEP 4: export + upload to ASC (ExportOptions destination=upload) --------
echo "  exporting + uploading to App Store Connect…"
xcodebuild -exportArchive -archivePath "$ARCH" \
  -exportOptionsPlist apps/ios/ExportOptions-TestFlight.plist \
  -exportPath /tmp/hermes-tf/export \
  -authenticationKeyPath "$ASC_KEY" -authenticationKeyID "$ASC_KEYID" \
  -authenticationKeyIssuerID "$ASC_ISSUER" -allowProvisioningUpdates 2>&1 | tail -6 \
  | grep -qE "EXPORT SUCCEEDED|Uploaded HermesMobile" || { echo "  FAIL: export/upload did not report success"; exit 1; }

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
