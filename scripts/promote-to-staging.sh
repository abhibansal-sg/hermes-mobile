#!/usr/bin/env bash
#
# promote-to-staging.sh — advance the STAGING gateway to the current dev base.
#
# This is the DEV -> STAGING rung of the promotion pipeline (Abhi, locked
# 2026-07-02; built 2026-07-03):
#
#   DEV   (:9200, ai.hermes.dev-gateway,     branch environment-and-workflows-overview)
#   STAGE (:9300, ai.hermes.staging-gateway, branch staging, own checkout + HOME)
#   LIVE  (~/.hermes, ai.hermes.gateway)     <- promoted ONLY on Abhi's explicit tap
#
# What it does (idempotent, refuses on any divergence):
#   1. fast-forwards origin/staging to origin/<base> (no merge commits, ff-only)
#   2. fast-forwards the staging CHECKOUT to origin/staging (refuses if local
#      has commits not on origin — a dirty staging checkout is a broken invariant)
#   3. re-syncs the venv if pyproject/uv.lock changed
#   4. restarts the staging gateway (kill PID; launchd KeepAlive respawns)
#   5. health-checks :9300 and prints PROMOTED <sha> or FAILED
#
# Who runs it: the SOAK beat at the start of each soak run (so it always soaks
# the current base), or a human. Never touches dev or live.
set -uo pipefail

BASE_BRANCH="${STAGING_BASE:-environment-and-workflows-overview}"
DEV_REPO="$HOME/Developer/products/hermes-mobile"
STG_REPO="$HOME/Developer/products/hermes-mobile-staging"
STG_PORT=9300
LABEL="ai.hermes.staging-gateway"

say(){ printf '[promote] %s\n' "$*"; }
fail(){ printf '[promote] FAILED: %s\n' "$*" >&2; exit 1; }

[ -d "$STG_REPO/.git" ] || fail "staging checkout missing at $STG_REPO"

# 1. move origin/staging to the current base tip (ff-only on the remote ref).
say "syncing origin/staging -> origin/$BASE_BRANCH"
git -C "$DEV_REPO" fetch origin --quiet || fail "fetch failed in dev repo"
BASE_SHA=$(git -C "$DEV_REPO" rev-parse "origin/$BASE_BRANCH") || fail "no origin/$BASE_BRANCH"
STG_SHA=$(git -C "$DEV_REPO" rev-parse origin/staging 2>/dev/null || echo "")
if [ "$BASE_SHA" = "$STG_SHA" ]; then
  say "origin/staging already at base tip ${BASE_SHA:0:9}"
else
  # ff-only: staging must be an ancestor of base (it always is — staging never
  # gets its own commits; if it somehow did, REFUSE and demand a human).
  if [ -n "$STG_SHA" ] && ! git -C "$DEV_REPO" merge-base --is-ancestor "$STG_SHA" "$BASE_SHA"; then
    fail "origin/staging has commits not on $BASE_BRANCH — staging must never diverge; human needed"
  fi
  git -C "$DEV_REPO" push origin "$BASE_SHA:refs/heads/staging" --quiet || fail "push to origin/staging failed"
  say "origin/staging -> ${BASE_SHA:0:9}"
fi

# 2. fast-forward the staging checkout.
git -C "$STG_REPO" fetch origin staging --quiet || fail "fetch failed in staging checkout"
LOCAL=$(git -C "$STG_REPO" rev-parse HEAD)
REMOTE=$(git -C "$STG_REPO" rev-parse origin/staging)
if [ "$LOCAL" != "$REMOTE" ]; then
  git -C "$STG_REPO" merge-base --is-ancestor "$LOCAL" "$REMOTE" \
    || fail "staging checkout has local commits not on origin/staging — refusing (fix by hand)"
  [ -z "$(git -C "$STG_REPO" status --porcelain --untracked-files=no)" ] \
    || fail "staging checkout has uncommitted tracked changes — refusing"
  git -C "$STG_REPO" merge --ff-only origin/staging --quiet || fail "ff merge failed"
  say "checkout fast-forwarded ${LOCAL:0:9} -> ${REMOTE:0:9}"
else
  say "checkout already at ${LOCAL:0:9}"
fi

# 3. re-sync venv only when deps changed.
if ! git -C "$STG_REPO" diff --quiet "$LOCAL" "$REMOTE" -- pyproject.toml uv.lock 2>/dev/null; then
  say "deps changed — uv sync"
  (cd "$STG_REPO" && uv sync --quiet) || fail "uv sync failed"
fi

# 4. restart the staging gateway (never touches dev :9200 or live).
PID=$(lsof -nP -iTCP:$STG_PORT -sTCP:LISTEN -t 2>/dev/null | head -1)
if [ -n "${PID:-}" ]; then
  kill "$PID" 2>/dev/null && say "gateway pid $PID terminated; launchd respawning"
fi
sleep 12

# 5. health gate.
if curl -fsS --max-time 5 "http://127.0.0.1:$STG_PORT/" >/dev/null 2>&1; then
  NEW_PID=$(lsof -nP -iTCP:$STG_PORT -sTCP:LISTEN -t 2>/dev/null | head -1)
  say "PROMOTED ${REMOTE:0:9} — staging gateway healthy on :$STG_PORT (pid ${NEW_PID:-?})"
else
  fail "staging gateway did not come back on :$STG_PORT — check $STG_REPO/.hermes-staging/logs/"
fi
