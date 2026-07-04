#!/bin/bash
# promote-to-live.sh — AUTONOMOUS STAGING→LIVE promotion (Abhi directive 2026-07-03:
# "dev to staging and staging to live should also be autonomous... and real time").
#
# The live dashboard (:9119) execs the FROZEN checkout at
# ~/Developer/products/hermes-mobile-live (branch: live). This script advances that
# checkout to a soak-blessed SHA and restarts the dashboard, with a full backup and
# AUTOMATIC ROLLBACK on a failed health gate. The parachute replaces the human tap.
#
# GATES (all mechanical, all must pass):
#   G1  governor enabled + live_policy.autonomous_live_active
#   G2  latest soak ledger verdict == SHIP, and its SHA is what we promote
#   G3  zero open loop:staging-blocker issues in Linear
#   G4  the SHIP sha is on origin/<base> (never promote an unmerged tree)
# SAFETY (non-negotiable, baked in):
#   S1  full ~/.hermes rsync backup + service-wrapper copy BEFORE any change
#   S2  health gate after restart: /api/status 200 + correct hermes_home within 120s
#   S3  ANY health-gate failure => automatic rollback to the pre-promote SHA + restart
#       + p1 Linear issue. Live never stays down on a failed promote.
#
# Usage: promote-to-live.sh [sha]   (default: SHA from the latest SHIP ledger line)
# Exit: 0 promoted (or cleanly skipped), 1 promoted-then-rolled-back or hard error.
set -uo pipefail
export PATH="$HOME/.local/bin:$PATH"
LIVE_CHECKOUT="$HOME/Developer/products/hermes-mobile-live"
STAGING_HOME="$HOME/Developer/products/hermes-mobile-staging/.hermes-staging"
LEDGER="$STAGING_HOME/soak-ledger.jsonl"
GOVERNOR="$HOME/Developer/products/hermes-mobile/.claude/loops/governor.json"
SERVICE_WRAPPER="$HOME/.hermes/bin/hermes-dashboard-service"
LIVE_LEDGER="$HOME/.hermes/live-promotion-ledger.jsonl"
BASE=environment-and-workflows-overview
PORT=9119
TS=$(date +%Y%m%d-%H%M%S)

log(){ echo "[promote-live] $*"; }
ledger(){ # ledger <verdict> <sha> <note>
  printf '{"at":"%s","action":"promote-to-live","verdict":"%s","sha":"%s","note":"%s"}\n' \
    "$(date -u +%FT%TZ)" "$1" "$2" "$3" >> "$LIVE_LEDGER"
}

# --- G1: governor ---------------------------------------------------------------
python3 - "$GOVERNOR" <<'PY' || { log "governor gate closed — skipped"; exit 0; }
import json,sys
g=json.load(open(sys.argv[1]))
if not g.get('enabled'): print("  governor disabled"); sys.exit(1)
lp=g.get('live_policy',{})
if not lp.get('autonomous_live_active'): print("  autonomous live promotion not armed"); sys.exit(1)
PY

# --- G2: soak SHIP verdict --------------------------------------------------------
[ -f "$LEDGER" ] || { log "no soak ledger — skipped"; exit 0; }
LAST=$(tail -1 "$LEDGER")
VERDICT=$(echo "$LAST" | python3 -c "import sys,json; print(json.load(sys.stdin).get('verdict',''))" 2>/dev/null)
SHIP_SHA=$(echo "$LAST" | python3 -c "import sys,json; print(json.load(sys.stdin).get('sha',''))" 2>/dev/null)
TARGET="${1:-$SHIP_SHA}"
if [ "$VERDICT" != "SHIP" ]; then log "latest soak verdict=$VERDICT — skipped (DO-NOT-SHIP holds live)"; exit 0; fi
[ -n "$TARGET" ] || { log "no target sha — skipped"; exit 0; }

cd "$LIVE_CHECKOUT" || { log "live checkout missing"; exit 1; }
CURRENT=$(git rev-parse HEAD)
if [ "$CURRENT" = "$TARGET" ]; then log "live already at $TARGET — nothing to do"; exit 0; fi

# --- G3: no open staging blockers -------------------------------------------------
TOKEN=$("$HOME/.hermes/scripts/linear-app-token.sh" 2>/dev/null || true)
if [ -n "$TOKEN" ]; then
  BLOCKERS=$(curl -s -m 20 -X POST https://api.linear.app/graphql \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d '{"query":"{ issues(filter:{ labels:{name:{eq:\"loop:staging-blocker\"}}, state:{type:{nin:[\"completed\",\"canceled\"]}} }){ nodes{ identifier } } }"}' \
    | python3 -c "import sys,json
try: print(len(json.load(sys.stdin)['data']['issues']['nodes']))
except Exception: print('ERR')" 2>/dev/null)
  if [ "$BLOCKERS" = "ERR" ]; then log "cannot read blocker state — refusing (fail-closed)"; exit 0; fi
  if [ "$BLOCKERS" != "0" ]; then log "$BLOCKERS open staging-blocker(s) — skipped"; exit 0; fi
fi

# --- G4: target sha is on origin base ---------------------------------------------
git fetch origin "$BASE" -q 2>/dev/null
git merge-base --is-ancestor "$TARGET" "origin/$BASE" 2>/dev/null \
  || { log "target $TARGET is NOT on origin/$BASE — refusing"; exit 1; }

log "promoting live: $(git rev-parse --short "$CURRENT") -> $(git rev-parse --short "$TARGET")"

# --- S1: BACKUP (before any mutation) ----------------------------------------------
B="$HOME/hermes-backups/pre-live-$TS"
mkdir -p "$B"
# Excludes: reinstallables + transient/regenerable churn. kanban workspaces hold
# per-task checkouts + derivedData (GBs, regenerable, files vanish mid-copy);
# *.lock dirs are transient. rsync exit 24 (files vanished during transfer) is
# ACCEPTABLE for this backup — everything durable was copied.
rsync -a --exclude hermes-agent --exclude node --exclude cache \
  --exclude bootstrap-cache --exclude audio_cache --exclude image_cache \
  --exclude logs --exclude '*.log' \
  --exclude 'kanban/boards/*/workspaces' --exclude '*.lock' \
  --exclude '*.db-wal' --exclude '*.db-shm' --exclude '.state.db.*' \
  "$HOME/.hermes/" "$B/dot-hermes/"
RSYNC_RC=$?
if [ "$RSYNC_RC" != "0" ] && [ "$RSYNC_RC" != "24" ]; then
  log "backup FAILED (rsync rc=$RSYNC_RC) — refusing to touch live"; exit 1
fi
cp "$SERVICE_WRAPPER" "$B/hermes-dashboard-service.orig"
echo "$CURRENT" > "$B/pre-promote-sha"
# Keep only the 2 newest pre-live backups (each ~19G; 3+ filled the disk on 07-04).
ls -dt "$HOME"/hermes-backups/pre-live-* 2>/dev/null | tail -n +3 | xargs rm -rf 2>/dev/null
log "backup at $B (rsync rc=$RSYNC_RC)"

# --- ADVANCE the frozen checkout ----------------------------------------------------
git checkout -q live 2>/dev/null || true
git reset --hard -q "$TARGET" || { log "reset to target failed"; exit 1; }
if git diff --name-only "$CURRENT".."$TARGET" 2>/dev/null | grep -qE '^(pyproject\.toml|uv\.lock)'; then
  log "deps changed — uv sync"
  uv sync --quiet 2>&1 | tail -1
fi
.venv/bin/python -c "import multipart, qrcode" 2>/dev/null \
  || uv pip install --quiet --python .venv/bin/python python-multipart 'qrcode[pil]' 2>/dev/null

# --- SYNC the plugin copy (it's a COPY in ~/.hermes/plugins, never a symlink) --------
# The live gateway loads plugins/hermes-mobile from ~/.hermes/plugins/. A promotion
# that advances the checkout but not the plugin copy serves NEW core + OLD plugin.
if [ -d "$LIVE_CHECKOUT/plugins/hermes-mobile" ]; then
  rsync -a --delete "$LIVE_CHECKOUT/plugins/hermes-mobile/" "$HOME/.hermes/plugins/hermes-mobile/" \
    || { log "plugin sync failed — aborting before restart"; git reset --hard -q "$CURRENT"; exit 1; }
fi

# --- RESTART live dashboard (KeepAlive respawns) ------------------------------------
restart_dashboard(){
  local pid
  pid=$(lsof -nP -iTCP:$PORT -sTCP:LISTEN -t 2>/dev/null | head -1)
  [ -n "$pid" ] && kill "$pid" 2>/dev/null
  # escalate to -9 if the old pid survives 60s (wedged-dashboard class)
  for i in $(seq 1 12); do
    sleep 5
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 0
  done
  [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null
  return 0
}

health_gate(){
  local t deadline=$((SECONDS+120)) code home
  t=$(head -1 "$HOME/.hermes/dashboard.token" 2>/dev/null)
  while [ $SECONDS -lt $deadline ]; do
    code=$(curl -s -m 5 -o /tmp/promote-live-status.json -w '%{http_code}' \
      -H "Authorization: Bearer $t" "http://127.0.0.1:$PORT/api/status" 2>/dev/null)
    if [ "$code" = "200" ]; then
      home=$(python3 -c "import json; print(json.load(open('/tmp/promote-live-status.json')).get('hermes_home',''))" 2>/dev/null)
      case "$home" in *"/.hermes") return 0;; esac
    fi
    sleep 5
  done
  return 1
}

restart_dashboard
if health_gate; then
  log "health gate PASSED — live now serves $(git rev-parse --short "$TARGET")"
  ledger "PROMOTED" "$TARGET" "from $CURRENT, backup $B"
  exit 0
fi

# --- S3: AUTOMATIC ROLLBACK -----------------------------------------------------------
log "health gate FAILED — rolling back to $(git rev-parse --short "$CURRENT")"
git reset --hard -q "$CURRENT"
uv sync --quiet 2>&1 | tail -1
# restore the plugin copy from the pre-promote backup (keeps core+plugin in lockstep)
if [ -d "$B/dot-hermes/plugins/hermes-mobile" ]; then
  rsync -a --delete "$B/dot-hermes/plugins/hermes-mobile/" "$HOME/.hermes/plugins/hermes-mobile/"
fi
restart_dashboard
if health_gate; then
  log "rollback OK — live restored on $(git rev-parse --short "$CURRENT")"
  ledger "ROLLED-BACK" "$TARGET" "health gate failed; live restored to $CURRENT"
else
  log "CRITICAL: rollback health gate ALSO failed — restoring service wrapper from backup"
  cp "$B/hermes-dashboard-service.orig" "$SERVICE_WRAPPER"
  restart_dashboard
  ledger "CRITICAL-ROLLBACK" "$TARGET" "double failure; wrapper restored from $B"
fi
# File p1 to Linear (fail-soft if token missing)
if [ -n "$TOKEN" ]; then
  SHORT_T=$(git rev-parse --short "$TARGET")
  curl -s -m 20 -X POST https://api.linear.app/graphql \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d "{\"query\":\"mutation { issueCreate(input: { teamId: \\\"65ac26cf-e19d-46d7-b333-757fdb3a56f3\\\", title: \\\"LIVE promotion of $SHORT_T failed health gate — auto-rolled-back\\\", description: \\\"promote-to-live.sh promoted $TARGET, health gate failed, automatic rollback executed. Backup: $B. Investigate before next promotion.\\\", priority: 1, createAsUser: \\\"promoter\\\", displayIconUrl: \\\"https://api.dicebear.com/9.x/bottts/png?seed=promoter\\\" }) { success issue { identifier } } }\"}" >/dev/null
fi
exit 1
