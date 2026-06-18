#!/usr/bin/env bash
# PreToolUse guard for the Hermes worktree (installed by the Claude Code OS substrate).
# Receives the tool-call JSON on stdin. exit 2 = BLOCK (message to stderr); exit 0 = allow.
# Keeps the human on the irreversible / launch-risky 5%. If a block is truly intended,
# run the command yourself in a terminal — the guard only stops the agent.
set -uo pipefail
input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -z "$cmd" ] && exit 0

block(){ printf 'BLOCKED by .claude/hooks/guard.sh: %s\n' "$1" >&2
         printf 'If this is genuinely intended, run it yourself in a terminal.\n' >&2
         exit 2; }

# Irreversible delete
case "$cmd" in
  *"rm -rf"*|*"rm -fr"*|*"rm -r -f"*|*"rm -f -r"*) block "rm -rf (irreversible recursive delete)";;
esac
# Force-push (history rewrite on a shared branch)
printf '%s' "$cmd" | grep -Eq 'git[[:space:]]+push([[:space:]]+[^;|&]*)?[[:space:]](-f|--force)([[:space:]]|$)' \
  && block "git push --force (rewrites shared history)"
# Pushing to upstream — NousResearch is FETCH-ONLY, never push
printf '%s' "$cmd" | grep -Eq 'git[[:space:]]+push[[:space:]][^;|&]*upstream' \
  && block "git push to upstream (NousResearch is fetch-only; PRs go via the explicit launch process)"
# The HELD trunk merge — must stay a human decision
printf '%s' "$cmd" | grep -Eq 'git[[:space:]]+merge[^;|&]*(feat/group-collapse-pin|phase2-upstream-rebase)' \
  && block "git merge of the trunk/work branches (the trunk merge is intentionally HELD — confirm with the user)"

exit 0
