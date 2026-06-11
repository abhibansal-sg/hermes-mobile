---
name: feedback-token-budget-discipline
description: "User hits Anthropic usage restrictions — limit parallel agent fan-outs, prefer lean/inline work, fix known bugs over discovering more"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: c9fa813c-3db6-4153-a0bd-dc40c62fd958
---

User instruction (2026-06-06, during Hermes Mobile R1): "I keep getting an anthropic restriction error. We need to limit the work so that we don't hit that restriction and fix the bugs that are already discovered."

**Why:** The overnight ultracode conveyor (multi-agent workflows, loop-until-dry hunts with 3-lens judging, parallel fleets) burned enough usage to hit Anthropic plan restrictions repeatedly.

**How to apply:**
- Default to INLINE work and single sequential agents; no parallel fan-outs or multi-round discovery loops unless the user explicitly re-authorizes scale.
- Prefer fixing already-confirmed findings over launching new discovery (review engines, bug hunts, census sweeps).
- Local compute (xcodebuild, pytest, curl) is token-free — drive it inline rather than wrapping it in agents.
- Even when /effort ultracode is set, this user constraint overrides its "token cost is not a constraint" stance until the user says otherwise.
- Related: [[project-hermes-mobile]]

**UPDATE (2026-06-09): CONSTRAINT LIFTED — user said "max speed."** Asked directly where we stand on token budget vs the ultracode/max-parallel posture, the user answered "max speed." So the 2026-06-06 Anthropic-restriction throttle is NO LONGER in force: fan out aggressively, treat ultracode literally (token cost is not a constraint), prefer parallel workflows/sub-agent fleets where they buy quality or speed. Quality bar still non-negotiable per [[velocity-model]] + [[model-tiering-policy]]. If the user hits plan restrictions again they'll say so — until then, default to max throughput.
