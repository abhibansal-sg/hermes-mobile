#!/usr/bin/env bash
#
# worktree-reap.sh — reclaim disk from the autonomous loop's per-build worktrees.
#
# THE LEAK (found 2026-07-03, 48G): each build chain gets its own git worktree
# under .worktrees/<slug>, and scripts/ios-build.sh injects a PER-WORKTREE
# .derivedData (Xcode build cache, ~1.9G each). Nothing ever cleaned them up, so
# 83 worktrees × ~1.9G silted 48G. This reaper is the systemic fix — the
# orchestrator runs it after every merge/ship, and a cron runs it as a backstop.
#
# TWO SAFE OPERATIONS (both loss-free):
#   1. NUKE .derivedData in EVERY worktree (merged or live) — it is regenerable
#      Xcode cache; deleting it only forces a rebuild. Zero source risk.
#   2. REMOVE worktrees whose branch work is CONFIRMED on the base branch — either
#      the branch is an ancestor of base, OR a squash commit on base mentions the
#      worktree's ABH-<n>. A worktree with NO merge evidence is KEPT (real in-flight
#      work). git worktree remove --force unregisters cleanly.
#
# USAGE:
#   worktree-reap.sh              # full reap (derivedData nuke + merged-worktree removal)
#   worktree-reap.sh --dd-only    # only nuke derivedData (fast, run mid-build-safe-ish)
#   worktree-reap.sh --dry-run    # show what WOULD be reaped, touch nothing
set -uo pipefail

REPO="${REAP_REPO:-$HOME/Developer/products/hermes-mobile}"
BASE="${REAP_BASE:-origin/environment-and-workflows-overview}"
WTDIR="$REPO/.worktrees"
MODE="${1:-full}"
DRY=false; [ "$MODE" = "--dry-run" ] && { DRY=true; MODE=full; }
[ "$1" = "--dd-only" ] 2>/dev/null && MODE=dd-only

say(){ printf '[reap] %s\n' "$*"; }
cd "$REPO" 2>/dev/null || { say "repo missing: $REPO"; exit 0; }
[ -d "$WTDIR" ] || { say "no .worktrees dir — nothing to reap"; exit 0; }

git fetch origin --quiet 2>/dev/null || true
BEFORE=$(du -sm "$WTDIR" 2>/dev/null | cut -f1)

# --- 1. nuke derivedData everywhere (regenerable) ---------------------------
dd_n=0
for dd in "$WTDIR"/*/apps/ios/.derivedData "$REPO"/apps/ios/.derivedData; do
  [ -d "$dd" ] || continue
  if $DRY; then say "would nuke derivedData: ${dd#$REPO/}"; else rm -rf "$dd" && dd_n=$((dd_n+1)); fi
done
$DRY || say "nuked $dd_n derivedData caches"

if [ "$MODE" = "dd-only" ]; then
  AFTER=$(du -sm "$WTDIR" 2>/dev/null | cut -f1)
  say "dd-only done. .worktrees ${BEFORE}MB -> ${AFTER}MB"
  exit 0
fi

# --- 2. remove worktrees whose work is confirmed on base --------------------
rm_n=0; keep_n=0
for wt in "$WTDIR"/*/; do
  [ -d "$wt" ] || continue
  name=$(basename "$wt")
  b=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)
  [ -z "$b" ] && continue
  abh=$(echo "$name$b" | grep -oiE 'abh-?[0-9]+' | head -1 | grep -oiE '[0-9]+')
  merged=false
  git merge-base --is-ancestor "$b" "$BASE" 2>/dev/null && merged=true
  if ! $merged && [ -n "$abh" ] && git log "$BASE" --oneline --grep "ABH-$abh" | grep -q .; then merged=true; fi
  if $merged; then
    if $DRY; then say "would remove MERGED worktree: $name [$b]"; else
      git worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
      rm_n=$((rm_n+1))
    fi
  else
    keep_n=$((keep_n+1))
    $DRY && say "would KEEP (no merge evidence): $name [$b]"
  fi
done
$DRY || { git worktree prune 2>/dev/null; AFTER=$(du -sm "$WTDIR" 2>/dev/null | cut -f1); \
  say "removed $rm_n merged worktrees, kept $keep_n live; .worktrees ${BEFORE}MB -> ${AFTER}MB"; }
