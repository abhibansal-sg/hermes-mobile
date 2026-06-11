---
name: Scan vs Pickup Discipline
description: Paperclip agents must separate scanning (detect) from picking up (own). Scan broadly within lane, pick up narrowly with evidence gates.
type: feedback
originSessionId: 247467c5-73b8-4f37-81f3-a0f202fdaeca
---
Agents scan broadly but pick up narrowly. Detection is broad. Ownership is strict.

**Why:** Git Factory agents with heartbeats were grabbing issues across lanes (Staff work grabbed by Release, QA work grabbed by CEO), causing persistent assignment drift. Root cause: AGENTS.md had "ALSO scan for issues" language without lane constraints. Compared to GStack template which had no scan language at all.

**How to apply:**
- scan = inspect and detect (allowed broadly within your lane)
- pick up = accept ownership and act (narrow, lane-constrained, evidence-gated)
- Unassigned alone is not enough — issue must be at the correct pipeline stage for that role
- Evidence is a gate, not a courtesy: QA without Staff evidence = invalid pickup; Release without QA PASS = invalid pickup
- If assigned to another agent: flag/escalate to COO, never self-assign
- Stalled = no pickup after 1 heartbeat cycle (30 min)
- Decided 2026-04-16 via three-way discussion (Oppusy + Hermes + Kai)
