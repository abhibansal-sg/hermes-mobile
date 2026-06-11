---
name: model-tiering-policy
description: "Standing policy (user-approved 2026-06-07; reinforced 2026-06-10): NEVER default-inherit the session model for subagents/workflows — explicitly pick the model per task. Sonnet builders, Opus judgment nodes, escalate on gate failure. Quality must not degrade."
metadata: 
  node_type: memory
  type: feedback
  originSessionId: c6271256-6b41-4b30-a2e2-057a9325db34
---

**NEVER INHERIT BY DEFAULT (user directive, 2026-06-10):** when spawning ANY
subagent — Workflow `agent()` calls, the Agent tool, sub-sub-agents — set the
`model` explicitly per task instead of letting it inherit the session's model.
Sessions often run on the heaviest model (Opus/Fable); silently inheriting puts
that model on every mechanical node. Omitting `model:` is only correct when the
node genuinely needs the session-tier model (judgment nodes below). Apply the
tiers below to every fan-out, every time.

For dynamic workflows and subagent fleets (approved on [[project-hermes-mobile]], applies generally):

- **Opus (inherit, no override):** contract authors, adversarial gates/integrators, root-cause forensics, synthesis agents, and anything touching concurrency-sensitive machinery (ChatStore-class ownership/race code).
- **`model: 'sonnet'`:** builders implementing a pinned contract, recon/verify/mapping sweeps, narrow-dimension reviewers, doc/Linear hygiene, test scaffolding.
- **`model: 'haiku'`:** purely mechanical sweeps (log scans, file inventories).
- **Escalation rule (mandatory):** a module refused by the gate twice re-runs on Opus. Cheap by default, expensive on evidence of difficulty.
- **Coverage vs depth:** for coverage tasks, more Sonnet agents beat fewer Opus agents at equal spend; for depth tasks, the reverse.

**Why:** user asked for better token economy (2026-06-07) but conditioned it explicitly on "best quality of work and no degradation in actual performance and deliverables — be mindful and careful."

**SPEED BIAS (user, 2026-06-08):** "Use Sonnet wherever Sonnet is the perfect model — NOT to save tokens, but because Sonnet is way faster than Opus." Speed is a first-class reason. So DEFAULT to Sonnet and reserve Opus only where its judgment genuinely changes the outcome: novel-architecture contracts, subtle-bug/race forensics, and correctness-critical gates on the CORE ENGINE (ChatStore/transcript model/connection). Mechanical work that was reflexively Opus — fast-mode integrators applying DISJOINT batches, recon/audit synthesis, doc/Linear hygiene — should be SONNET (faster, sufficient). When unsure whether Opus is needed, try Sonnet first; escalate only on evidence.

**How to apply:** encode tiers in every Workflow script via per-agent `model` opts. Default Sonnet; Opus only for the high-judgment nodes above. Gates on core-engine stay Opus; fast-mode disjoint-batch integration can be Sonnet. Monitor: if Sonnet starts producing noticeably worse results at a node, narrow its scope there and tell the user — don't silently absorb quality loss.

**Test-gateway turns (2026-06-10):** live E2E tests' agent turns use the gateway's configured DEFAULT model — the user's global default (Opus). Do NOT switch it via `POST /api/model/set scope=main` on a test instance: the test gateway shares `~/.hermes/config.yaml` with the LIVE dashboard (`_save_cfg` writes global), so it would silently change the user's real default. Instead, launch test gateways with an ISOLATED config home so the default can be pinned to Sonnet/Haiku. A handful of one-liner Opus turns is acceptable; a big E2E matrix is not.
