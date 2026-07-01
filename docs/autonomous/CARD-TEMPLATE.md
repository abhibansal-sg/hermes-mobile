# Kanban card template — dispatched worker cards

Every card dispatched to an engineer profile MUST be built from this template.
The SCOPE FENCE is non-negotiable: it's the fix for the Slice B run where a
worker drifted from a plugin task into editing `tui_gateway/server.py` (stock
core). The fence turns `governor.json → forbidden_paths` from prose into an
instruction the worker actually reads and the verifier mechanically checks.

## Card body template

```
SLICE <X> — <title> for <LINEAR-ID>.

Linear: <LINEAR-ID> <url>
Plan: docs/autonomous/<plan>.md (Slice <X> section)
Base: <branch/PR dependency, or "base branch">

GOAL: <one sentence, user-facing>

SCOPE — you may CREATE/EDIT only these paths:
  - <exact path 1>
  - <exact path 2>
Anything not listed here is OUT OF SCOPE.

━━━ SCOPE FENCE (hard block — governor.json forbidden_paths) ━━━
You MUST NOT create or edit any of these, even if a test there is failing:
  tui_gateway/**  hermes_cli/**  gateway/**  run_agent.py  hermes_state.py
  model_tools.py  apps/desktop/**  ui-tui/**  .claude/loops/**  docs/autonomous/PROJECT.yaml
You MAY read them for context. If the task seems to REQUIRE editing one, STOP and
block with `needs-human`, naming the file. Do NOT chase an unrelated failing test
into a fenced file. Do NOT "helpfully" fix things outside SCOPE.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

ACCEPTANCE / EVIDENCE:
  - <test command + expected>
  - git diff --stat + changed files (MUST be a subset of SCOPE)

FORBIDDEN WITHOUT ABHI APPROVAL: merging, force-push, destructive git, editing any
SCOPE FENCE path, changing default/existing behavior the card didn't name.

NEXT ON SUCCESS: <verifier card> -> <reviewer card (cross-provider)>
NEXT ON FAILURE: return to engineer with the failing evidence.
```

## Verifier gate (mechanical — run before any accept)

The verifier runs `scripts/loop-scope-check.sh <worktree> "<space-separated allowed globs>"`.
Exit 0 = every changed file is inside SCOPE. Non-zero = REJECT, regardless of
test results. This is the check that would have auto-rejected the Slice B
`tui_gateway/server.py` edit.

## Dispatch checklist (creating a card)

1. Build the body from the template above; fill SCOPE with EXACT paths.
2. `hermes kanban --board hermes-mobile create "<title>" --body "<body>" --assignee engineer --project hermes-mobile`
   (ALWAYS `--project`, never bare `--workspace worktree` — the latter has no repo
   anchor and blocks on "not inside a git repo". Learned in the Slice B run.)
3. The gateway-embedded dispatcher claims it on the next tick (~60s), creates a
   worktree under `.worktrees/<task_id>/`, spawns the profile.
4. On completion: run the verifier scope-gate BEFORE reading test results.
