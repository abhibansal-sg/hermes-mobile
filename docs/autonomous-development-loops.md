# Autonomous Development Loops — Hermes Mobile

Status: foundation design, not yet enabled.

This document defines the long-term architecture for autonomous development on
Hermes Mobile. It supersedes the earlier “one loop per lifecycle stage” mental
model with the design Abhi settled on in-session: **Linear-planned,
feature-sliced autonomous loops**.

The core idea: **Linear is the product/source-of-truth layer; Kanban is the
execution layer.** We plan build-wise waves in Linear, with each wave describing
the features/fixes intended for a build. Only when a Linear issue/slice is
approved to start does it get promoted into Hermes Kanban for execution. Once in
Kanban, each slice can run end-to-end — spec → build → verify → review → PR — in
its own worktree. Multiple slices run in parallel only when their module/file
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

- reads Linear as the roadmap/wave source of truth,
- promotes approved Linear work into Kanban,
- owns Kanban dispatch for active execution,
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

### reviewer-codex

- Model: GPT-5.5 / Codex
- Job: independent adversarial review from a different provider/model family.
- Default second reviewer paired with `reviewer-opus` / `reviewopus`.

### reviewer-glm

- Model: GLM-5.2
- Job: backup adversarial reviewer when Codex is unavailable or when Abhi explicitly wants a GLM cross-check.

## Linear ↔ Kanban lifecycle

Linear is the durable project-management system:

- Linear Project = product/build track, e.g. “Hermes Mobile”.
- Linear Cycle or custom wave label = build wave, e.g. “Build 18”.
- Linear Issues = features/fixes/bugs that may eventually become execution
  slices.
- Linear status/labels own planning state: proposed, scoped, approved for wave,
  ready for execution, in progress, done.

Hermes Kanban is the short-lived execution board:

- Kanban cards are created only for work that is about to start or is actively
  being decomposed for start.
- Kanban carries execution state: assigned worker, worktree, run evidence,
  verifier/reviewer handoffs, and stop conditions.
- Kanban cards must reference their Linear issue identifiers and post evidence
  back to Linear.
- Closed/archived Kanban cards do not replace Linear history; Linear remains the
  durable record.

Promotion rule:

```text
Linear wave issue approved for execution
  ↓
Orchestrator/Abhi promotes it to Kanban as an unassigned gate card
  ↓ explicit approval to run
Kanban card gets an assignee/profile and may dispatch
```

## Execution lifecycle

```text
Linear wave / issue / user idea
  ↓ user approves scope for the build wave
Architect creates build plan and execution slices linked to Linear issues
  ↓ user approves decomposition and promotion to execution
Orchestrator creates unassigned Kanban gate cards for approved slices
  ↓ user approves assignment/profile
Kanban routes ready slices to engineer profiles
  ↓
Engineer drives external CLI in isolated worktree
  ↓ PR + evidence
Verifier runs hard evidence checks
  ↓
Reviewer Opus + Reviewer Codex run in parallel
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
- 5% list: stock Kanban human gates are represented as **unassigned cards**,
  not as `blocked+assignee` or `triage` cards at creation time.

## Stock Kanban gate policy

We are keeping the production Hermes gateway and Kanban implementation stock.
Do not modify core/gateway semantics just to support this loop system. The loop
architecture must fit the installed Kanban primitives.

Operational rule:

- Human-gated cards start with no assignee.
- A card gets an assignee only when it is approved to run.
- Do not create approval-gated cards as `--initial-status blocked --assignee ...`.
- Do not use `triage` as a parking state on a live board where auto-specifier
  or auto-decomposer is active; stock Hermes may specify/promote triage cards.
- Use `blocked` only after a worker/run has already started and needs to stop
  for real input, capability, dependency, or review.
- The transition from proposal/spec to execution is explicit:
  `unassigned -> assign/promote -> dispatcher may run`.

This preserves stock behavior and gives us reliable human gates without carrying
a local Kanban patch. Planning gates should normally live in Linear; Kanban gates
exist only when work is being promoted into execution.

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

1. Define the Linear wave schema for Hermes Mobile builds: project/cycle/labels,
   issue templates, and the “approved for execution” transition.
2. Add Linear identifiers/wave metadata to `docs/autonomous/PROJECT.yaml`.
3. Create Hermes profiles with clear descriptions.
4. Create/verify coding-lane skills:
   - existing: `glm-opencode-coding-lane`,
   - needed: `claude-code-coding-lane`,
   - needed: `codex-coding-lane`.
5. Create one Linear build wave and one approved issue, then promote that issue
   into a Kanban proof card in shadow mode.
6. Run the first true Kanban-dispatched profile manually and evaluate.
