# Autonomous Development Loops — Hermes Mobile

Status: foundation design, not yet enabled.

This document defines the long-term architecture for autonomous development on
Hermes Mobile. It supersedes the earlier “one loop per lifecycle stage” mental
model with the design Abhi settled on in-session: **feature-sliced autonomous
loops**.

The core idea: an approved idea is decomposed into small, safe feature slices.
Each slice can run end-to-end — spec → build → verify → review → PR — in its
own worktree. Multiple slices run in parallel only when their module/file
boundaries do not collide.

## Non-negotiables

1. **Hermes is the orchestrator.** Conductor is no longer the operating center
   for this project. Hermes owns routing, evidence, state, and escalation.
2. **Coding happens in dedicated coding CLIs.** Engineer profiles drive Claude
   Code, OpenCode, or Codex. Hermes profiles do not write production code
   directly with raw file tools except for tiny scaffolding/metadata tasks.
3. **Builder and reviewer should be different providers.** Model diversity is a
   quality feature; same-provider self-review is weaker.
4. **The user owns the 5%.** Merge, TestFlight, force-push/destructive actions,
   stock-core edits, device-only repro, and direction forks remain human-gated.
5. **No green without evidence.** A stage cannot advance on self-report; it
   needs test output, logs, screenshots, PR links, or other hard artifacts.
6. **Design before scaling.** Prove one profile/loop before adding parallelism.

## Runtime split

Production Hermes gateway:

- owns Kanban dispatch,
- owns profiles,
- owns Linear/GitHub orchestration,
- drives external coding CLIs in worktrees,
- sends notifications/escalations.

Dev Hermes gateway (`:9200`, `.hermes-dev`):

- is a test target for the iOS app,
- is used by verifier/smoke tests,
- should not be the central loop controller.

## Profile roster

### orchestrator

- Model: Opus 4.8
- Tooling: Kanban + notification/state tools only; no code-editing role.
- Job:
  - read the board,
  - route cards,
  - enforce governor gates,
  - create verify/review cards,
  - reconcile reviewer disagreement,
  - escalate the 5% to Abhi.
- Does not build, verify, or review code.

### scout

- Model: Sonnet 4.6
- Job:
  - propose product ideas/features/bug-investigation leads,
  - ground proposals in codebase/product context,
  - create triage cards only.
- Human gate: Abhi approves/rejects proposals before architecture begins.

### architect

- Model: Opus 4.8 primary; GLM-5.2 fallback when cost/availability demands.
- Job:
  - convert approved ideas/bugs into full build plans,
  - decompose into slices,
  - assign module/file ownership,
  - declare dependencies,
  - identify collision risk,
  - recommend engineer profile per slice.
- Human gate: Abhi reviews build plan before child slices become ready.

### engineers

Engineer profiles are Hermes workers that drive external coding CLIs.

| Profile | Model | Coding CLI | Default work |
|---|---|---|---|
| iossonnet | Sonnet 4.6 | Claude Code | mechanical iOS/Swift work |
| engopus | Opus 4.8 | Claude Code | complex iOS, cross-cutting, sensitive logic |
| pythonglm | GLM-5.2 | OpenCode | Python/plugin/backend work |
| engcodex | GPT-5.5/Codex | Codex CLI | fallback/alternate build lane |

Engineer responsibilities:

1. read the assigned card/spec,
2. create an isolated worktree under `~/Developer/worktrees/`,
3. launch the coding CLI with the right prompt/model,
4. heartbeat while it runs,
5. collect diff, tests, logs, and PR link,
6. post evidence to Kanban/Linear,
7. block for review.

External CLIs are not Kanban workers. They are tools invoked by engineer
profiles.

### verifier

- Model: Sonnet 4.6
- Job:
  - run deterministic evidence checks,
  - build/test/smoke against the real dev rig,
  - capture screenshots/logs/exit codes,
  - pass/fail with evidence.
- Does not modify source.

### reviewer-opus

- Model: Opus 4.8
- Job: adversarial correctness, architecture, security/performance review.

### reviewer-glm

- Model: GLM-5.2
- Job: independent adversarial review from a different provider/model family.

## Card lifecycle

```text
Scout proposal / user idea
  ↓ user approves
Architect creates build plan and slice cards
  ↓ user approves decomposition
Orchestrator routes ready slices to engineer profiles
  ↓
Engineer drives external CLI in isolated worktree
  ↓ PR + evidence
Verifier runs hard evidence checks
  ↓
Reviewer Opus + Reviewer GLM run in parallel
  ↓
Orchestrator reconciles:
  - both approve → escalate to Abhi for merge
  - one rejects → return to engineer or escalate if ambiguous
  - both reject → return to engineer with both review reports
  ↓
Abhi merges / ships / decides the 5%
```

## Decomposition protocol

Every architect output must include, per slice:

- title,
- user-facing goal,
- exact module/file boundary,
- suggested engineer profile,
- dependencies/parents,
- collision risk,
- acceptance criteria,
- required tests/evidence,
- explicit non-goals.

Parallelism rule:

- two slices touching the same production file are serial, not parallel;
- two slices touching independent modules can run in parallel;
- stock-core or direction-fork slices are blocked for human review.

## Governor mapping

Existing `.claude/loops/governor.json` remains the safety contract for now, but
its old stage-loop language must be adapted to Kanban feature-sliced loops.

Required mappings:

- `enabled=false`: all loop profiles exit without action.
- `shadow_mode=true`: create proposed cards/comments only; no PRs or transitions.
- `max_concurrent_action_loops`: max engineer profiles running at once.
- `retries_per_stage`: max retries per card/profile before escalation.
- spin detector: same failure signature twice means stop and escalate.
- evidence gate: no transition without artifact.
- 5% list: always `kanban_block(reason="review-required: ...")`.

## Trust ladder

1. Foundation docs + manifest only.
2. Create profiles, but do not enable dispatcher automation.
3. Run one architect decomposition manually; Abhi judges quality.
4. Run one engineer slice manually via Kanban in shadow mode.
5. Allow one engineer profile to act on one low-risk slice.
6. Add verifier.
7. Add two reviewers.
8. Add orchestrator routing.
9. Add scout.
10. Add parallelism.

No rung is skipped.

## Known risks

- Decomposition quality is the highest-risk part.
- 9+ profiles may be over-engineered if not introduced gradually.
- Verification can false-green if tests/smokes are weak.
- Review can become the bottleneck if slices are too large.
- External coding CLIs each need their own robust lane skill.
- Production Hermes gateway should have upstream AsyncSessionDB/concurrency
  improvements before large parallel runs.

## Immediate next build tasks

1. Add `.hermes/PROJECT.yaml` to define project-specific routing.
2. Create Hermes profiles with clear descriptions.
3. Create/verify coding-lane skills:
   - existing: `glm-opencode-coding-lane`,
   - needed: `claude-code-coding-lane`,
   - needed: `codex-coding-lane`.
4. Create a Kanban proof card for one small slice in shadow mode.
5. Run the first true Kanban-dispatched profile manually and evaluate.
