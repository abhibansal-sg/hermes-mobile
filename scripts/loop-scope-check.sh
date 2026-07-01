#!/usr/bin/env bash
# loop-scope-check.sh — mechanical scope-fence gate for dispatched worker cards.
#
# The verifier runs this BEFORE reading any test result. It answers one question:
# did the worker touch a file OUTSIDE its authorized SCOPE (or inside the
# governor's forbidden_paths)? If yes -> exit non-zero -> automatic REJECT.
#
# This is the fix for the Slice B run: an engineer worker built its plugin task
# correctly but also edited tui_gateway/server.py (stock core). That edit would
# have been auto-rejected here.
#
#   scripts/loop-scope-check.sh <worktree_dir> "<allowed glob> <allowed glob> ..."
#
# Example:
#   scripts/loop-scope-check.sh .worktrees/t_abc123 \
#     "plugins/hermes-mobile/relay_client.py plugins/hermes-mobile/push_engine.py tests/plugins/hermes_mobile/**"
#
# Exit codes:
#   0 = clean: every changed file is inside an allowed glob AND none hit forbidden_paths
#   3 = a changed file is OUTSIDE the allowed scope
#   4 = a changed file matches a governor forbidden_paths glob (hard block)
#   2 = usage / not a git worktree
set -euo pipefail

WORKTREE="${1:-}"
ALLOWED="${2:-}"
if [ -z "$WORKTREE" ] || [ -z "$ALLOWED" ]; then
  echo "usage: $0 <worktree_dir> \"<allowed glob> ...\"" >&2
  exit 2
fi
cd "$WORKTREE" 2>/dev/null || { echo "not a dir: $WORKTREE" >&2; exit 2; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "not a git worktree: $WORKTREE" >&2; exit 2; }

# Governor forbidden paths (must match .claude/loops/governor.json forbidden_paths.block_globs)
FORBIDDEN=(
  "tui_gateway/" "hermes_cli/" "gateway/" "run_agent.py" "hermes_state.py"
  "model_tools.py" "apps/desktop/" "ui-tui/" ".claude/loops/" "docs/autonomous/PROJECT.yaml"
)

# All changed files vs HEAD (staged + unstaged + untracked), excluding venvs/caches
CHANGED=()
while IFS= read -r line; do
  [ -n "$line" ] && CHANGED+=("$line")
done < <(git status --porcelain --untracked-files=all \
  | awk '{print $2}' \
  | grep -vE '(^|/)\.venv|__pycache__|\.pytest_cache|\.db$' || true)

if [ "${#CHANGED[@]}" -eq 0 ]; then
  echo "scope-check: no changes."; exit 0
fi

# 1) forbidden-paths hard block
forbidden_hit=0
for f in "${CHANGED[@]}"; do
  for fp in "${FORBIDDEN[@]}"; do
    case "$f" in
      "$fp"*) echo "❌ FORBIDDEN PATH: $f (matches governor block '$fp')"; forbidden_hit=1 ;;
    esac
  done
done
[ "$forbidden_hit" -eq 1 ] && { echo "REJECT: worker edited a stock-core / forbidden path."; exit 4; }

# 2) allowed-scope check (simple glob prefix match; ** and trailing / both handled)
in_scope() {
  local file="$1" g
  for g in $ALLOWED; do
    local pat="${g%/**}"; pat="${pat%/*}"
    case "$file" in
      $g) return 0 ;;                 # literal/glob match
      "${g%\*\*}"*) return 0 ;;       # dir/** prefix
      "$pat"/*) return 0 ;;           # dir prefix
    esac
  done
  return 1
}

out=0
for f in "${CHANGED[@]}"; do
  if in_scope "$f"; then
    echo "  ✅ in scope: $f"
  else
    echo "  ❌ OUT OF SCOPE: $f"; out=1
  fi
done

if [ "$out" -eq 1 ]; then
  echo "REJECT: worker changed files outside the card's declared SCOPE."; exit 3
fi
echo "✅ scope-check PASS: all changes within SCOPE, no forbidden paths."
exit 0
