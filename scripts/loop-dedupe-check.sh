#!/bin/bash
# loop-dedupe-check.sh — dispatch-time duplicate gate for the autonomous loop.
# Answers: is this issue's work ALREADY-LANDED on base, IN-FLIGHT (open PR or
# running/blocked kanban card), or CLEAR to dispatch?
#
# Usage: loop-dedupe-check.sh ABH-<n> "<issue title>"
# Exit codes: 0 = CLEAR, 10 = ALREADY-LANDED, 20 = IN-FLIGHT.
# Always prints a one-line verdict first, then evidence lines.
#
# Why this exists (2026-07-03): duplicate chains burned full engineer->verifier->
# reviewer cycles — "widget voiceover labels" merged as BOTH #123 and #126, iPad
# keyboard HUD labels landed twice. 30 seconds of checking beats a wasted chain.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE=environment-and-workflows-overview
GH_REPO=ab0991-oss/hermes-mobile

REF="${1:?usage: loop-dedupe-check.sh ABH-<n> \"<title>\"}"
TITLE="${2:-}"
cd "$REPO" || { echo "VERDICT: ERROR repo missing"; exit 1; }
git fetch origin "$BASE" -q 2>/dev/null || true

evidence=()

# --- 1. Already on base? Search commit messages for the ABH ref ---------------
HITS=$(git log "origin/$BASE" --since="14 days ago" --oneline --grep="$REF" 2>/dev/null | head -5)
if [ -n "$HITS" ]; then
  echo "VERDICT: ALREADY-LANDED ($REF found in base commit messages)"
  echo "$HITS" | sed 's/^/  base-commit: /'
  exit 10
fi

# --- 2. Title-keyword match against recent base commits -----------------------
# Extract 3+ char meaningful words from the title, require most of them to hit
# the same commit subject (guards against re-building the same fix filed twice
# under different ABH numbers — the #123/#126 class).
if [ -n "$TITLE" ]; then
  WORDS=$(echo "$TITLE" | tr 'A-Z' 'a-z' | tr -cs 'a-z0-9' '\n' \
    | grep -vE '^(the|and|for|not|with|from|into|ios|fix|add|make|that|does|when|are)$' \
    | awk 'length($0)>=4' | head -6)
  NWORDS=$(echo "$WORDS" | grep -c . || true)
  if [ "$NWORDS" -ge 2 ]; then
    BEST=""
    BESTSCORE=0
    while IFS= read -r line; do
      subj=$(echo "$line" | cut -d' ' -f2- | tr 'A-Z' 'a-z')
      score=0
      while IFS= read -r w; do
        case "$subj" in *"$w"*) score=$((score+1));; esac
      done <<< "$WORDS"
      if [ "$score" -gt "$BESTSCORE" ]; then BESTSCORE=$score; BEST="$line"; fi
    done <<< "$(git log "origin/$BASE" --since="7 days ago" --oneline 2>/dev/null)"
    # Threshold: >= 70% of keywords matched one commit subject
    THRESH=$(( (NWORDS * 7 + 9) / 10 ))
    if [ "$BESTSCORE" -ge "$THRESH" ]; then
      echo "VERDICT: ALREADY-LANDED (title matches recent base commit, $BESTSCORE/$NWORDS keywords)"
      echo "  base-commit: $BEST"
      exit 10
    fi
  fi
fi

# --- 3. Open PR mentioning the ref or title? ----------------------------------
if command -v gh >/dev/null 2>&1; then
  PRS=$(gh pr list --repo "$GH_REPO" --state open --json number,title,headRefName \
        --jq '.[] | "\(.number) \(.title) [\(.headRefName)]"' 2>/dev/null || true)
  if [ -n "$PRS" ]; then
    HIT=$(echo "$PRS" | grep -iF "$REF" || true)
    [ -z "$HIT" ] && [ -n "$TITLE" ] && HIT=$(echo "$PRS" | grep -iF "$(echo "$TITLE" | cut -c1-30)" || true)
    if [ -n "$HIT" ]; then
      echo "VERDICT: IN-FLIGHT (open PR)"
      echo "$HIT" | sed 's/^/  open-pr: /'
      exit 20
    fi
  fi
fi

# --- 4. Running/ready/blocked kanban card for this ref? -----------------------
CARDS=$(hermes kanban list 2>/dev/null | grep -iE 'running|ready|claimed|blocked' | grep -iF "$REF" || true)
if [ -n "$CARDS" ]; then
  echo "VERDICT: IN-FLIGHT (active kanban card)"
  echo "$CARDS" | sed 's/^/  card: /'
  exit 20
fi

# --- 5. Un-merged wt/ branch with commits mentioning the ref ------------------
WT=$(git branch -a 2>/dev/null | grep -iF "$(echo "$REF" | tr 'A-Z' 'a-z')" | head -3 || true)
if [ -n "$WT" ]; then
  echo "VERDICT: IN-FLIGHT (existing worktree branch — inspect before dispatching)"
  echo "$WT" | sed 's/^/  branch: /'
  exit 20
fi

echo "VERDICT: CLEAR"
exit 0
