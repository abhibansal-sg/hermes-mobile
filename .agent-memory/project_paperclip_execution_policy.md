---
name: Paperclip executionPolicy stages (Flow A as first-class feature)
description: Paperclip 2026.416.0+ supports executionPolicy.stages with review/approval types and participants. Use instead of hand-rolled assignee chains. UI shows Reviewers/Approvers.
type: project
originSessionId: 247467c5-73b8-4f37-81f3-a0f202fdaeca
---
Paperclip 2026.416.0 (since PR #3222 merged 2026-04-09) has a first-class workflow engine: **`executionPolicy`** on issues, with ordered **stages** of type `review` or `approval`, each with a list of **participants**. The UI labels review-stage participants as **Reviewers** and approval-stage participants as **Approvers**. Server-side, only the currentParticipant of the active stage can "advance" it (`approved` or `changes_requested`); non-participants get "Only the active reviewer or approver can advance the current execution stage".

**Schema:**
```
executionPolicy: { mode: "normal"|"auto", commentRequired: bool, stages: [{type: "review"|"approval", approvalsNeeded: 1, participants: [{type:"agent",agentId}]}] }
executionState: { status: "idle"|"pending"|"changes_requested"|"completed", currentStageId, currentStageIndex, currentStageType, currentParticipant, returnAssignee, lastDecisionOutcome: "approved"|"changes_requested" }
```

**Git Factory Flow A templates** (per Hermes ruling 2026-04-20, revised to 5-stage same day):

**5-stage (default for executable code issues):**
- assigneeAgentId = Impl (79137c46)
- stages:
  1. review → Staff (ec24a92f) — pre-landing code audit
  2. review → Release (7474991e) — actual merge-to-master via `/ship`
  3. review → QA (9ac62bfd) — `/qa-only` post-ship verification
  4. approval → CTO (c721ce3b) — final technical verdict
  5. approval → CEO (0b54e8a9) — executive acceptance

**3-stage (for doc-only / policy / process issues):**
- stages: Staff review → CTO approval → CEO approval (skip Release + QA)

**No executionPolicy:** plan/master/coordinator issues — tracking artifacts, close manually when children done.

**Bounce rules (returnAssignee on `changes_requested`):**
- Staff/Release/QA → Impl (default)
- CTO → Impl for code defects; Staff if review-gap/rework
- CEO → CTO (NOT Impl — CEO challenges the verdict, not the code)
- commentRequired: true throughout

**Why:** this replaces hand-rolled Staff→CTO→CEO assignee chains. Benefits: UI clarity, server-enforced participant checks (prevents the "CEO loop on GIT-1044" class of failures), automatic changes_requested bounce-back to Impl, machine-queryable state via currentStageType.

**How to apply:**
- When CTO locks a plan and spawns child issues, every child gets the Flow A executionPolicy template — no exceptions for executable work.
- Masters/plans/coordinator issues: no executionPolicy (they're tracking artifacts, not work).
- Retrofit only if the issue is materially active (mid-chain); do not churn near-finish issues.
- The `## Issue hygiene (MANDATORY)` section in every AGENTS.md at `~/.paperclip/instances/default/companies/f136c8e0-4343-4b0c-9d6b-ff4f05b4e8e1/agents/<id>/instructions/AGENTS.md` has the full template inline with agent UUIDs hardcoded.
- Approvals subsystem (`hire_agent`, `budget_override_required`, etc.) is SEPARATE — that's governance gates, not code review. Don't conflate.

**Lesson recorded:** First audit of this claimed "no reviewer/approver field on issues" because I searched field names like `reviewerAgentIds`. Abhi pointed to PR #3222 and I found the `executionPolicy.stages.participants` model immediately. Always check recent merged PRs for the feature by name before concluding absence — search the changelog, not just the field list.
