---
name: Git Factory Label Taxonomy
description: 11 labels (wave/lane/risk) established 2026-04-20 for paperclip board hygiene; retroactively applied to GIT-1035 tree. AGENTS.md now enforces hygiene rules across all 6 agents.
type: project
originSessionId: 247467c5-73b8-4f37-81f3-a0f202fdaeca
---
Paperclip's issue labels were previously unused. Established a three-dimension taxonomy on 2026-04-20 per Hermes ruling:

**Waves** (milestone/feature family): `wave:rebase`, `wave:action-brain`, `wave:infra`, `wave:upstream-merge`

**Lanes** (current role owner): `lane:ceo-plan`, `lane:cto`, `lane:impl`, `lane:ship`, `lane:qa` — note `lane:cto` added explicitly so CTO gates are visible on the board, not only implied in assignee flow.

**Risks** (surface blockers): `risk:blocked-on-human`, `risk:env-debt`

**Why:** The failure mode was execution drift and board hygiene, not lack of formal approval gates. Labels give fast-scan answers to: what wave, whose lane, blocked on env vs human. No first-class reviewer field exists in paperclip — the assignee chain (Staff→CTO→CEO) IS the review system. Approvals subsystem (`hire_agent`, `budget_override_required`, `request_board_approval`) reserved for governance only.

**How to apply:**
- When creating any new issue, always apply one `wave:*` + one `lane:*` + any `risk:*` labels via `PATCH /api/issues/<id> {"labelIds":[...]}`
- On handoff, update `lane:*` alongside `assigneeAgentId` in the same PATCH
- Master issues get only `wave:*` (lane reflects current ownership which may not apply to master)
- Each agent's AGENTS.md at `~/.paperclip/instances/default/companies/f136c8e0-4343-4b0c-9d6b-ff4f05b4e8e1/agents/<id>/instructions/AGENTS.md` has a `## Issue hygiene (MANDATORY)` section enforcing these rules — do not remove or weaken without CEO ruling.
- At retro, judge success: can board questions be answered in under 5 seconds? If not, simplify before adding governance approvals.

Strategy-approval gates (`approve_ceo_strategy`) were explicitly deferred by Hermes to avoid adding friction before the labeling layer is validated.
