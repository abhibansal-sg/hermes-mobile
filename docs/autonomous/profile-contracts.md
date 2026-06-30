# Autonomous Profile Contracts — Hermes Mobile

Status: proposed operating contract; profiles exist, full automation not enabled.
Last reviewed: 2026-06-30.

This document defines what every Hermes Mobile autonomous-development profile is
allowed to do, what model it runs, how fallback works, and which loop it owns.
It is intentionally stricter than a role description: if a task is not explicitly
inside a profile's contract, the profile must block or escalate rather than
improvise.

## Non-negotiable system rules

1. **Linear is planning/source of truth; Kanban is execution state.** Work starts
   in Linear and is promoted into Kanban only when execution is about to begin.
2. **Human gates are unassigned cards.** Do not create approval gates as
   `blocked+assignee` or `triage` cards on the live board.
3. **The 5% is Abhi-owned.** Merge, release/TestFlight, force-push/destructive
   git, stock-core direction changes, and device-only judgment calls require
   explicit human approval.
4. **Engineers drive coding CLIs; they do not hand-edit production code with
   raw Hermes file tools except tiny metadata/scaffolding.** Claude Code,
   OpenCode, and Codex are the coding engines.
5. **At least one verdict-carrying reviewer must be a different provider than
   the builder.** A PR may never be approved by a same-provider reviewer alone.
   The default review pair is Opus + Codex; whichever reviewer differs from the
   builder's provider is the mandatory diversity reviewer and cannot be dropped.
   A same-provider reviewer is a second opinion, never the sole gate. If every
   available reviewer shares the builder's provider, block and escalate — do not
   approve.
6. **No green without evidence.** A transition can advance only with artifacts:
   exact commands, exit codes, logs, screenshots, PR URLs, diff stats, or review
   comments.
7. **Fallback changes the approach, not just the label.** Repeated provider
   failures or repeated same-signature failures must switch lane or escalate; do
   not burn retries doing the same thing.
8. **All autonomous writes are project-scoped.** Worktrees live under
   `~/Developer/worktrees`; the permanent checkout lives under
   `~/Developer/products/hermes-mobile`.

## Profile roster summary

| Profile | Class | Primary model/provider | Default fallback | Owns loop | Writes code? |
|---|---|---|---|---|---|
| `orchestrator` | control | Opus 4.8 / Anthropic | Codex for mechanical board work; otherwise Abhi | `orchestrator-routing-loop` | No |
| `scout` | planning | Sonnet 4.6 / Anthropic | Codex; GLM for cheap scan only | `scout-discovery-loop` | No |
| `architect` | planning | Opus 4.8 / Anthropic | GLM draft + Codex structure; otherwise Abhi | `architect-decomposition-loop` | No |
| `iossonnet` | execution | Sonnet 4.6 / Anthropic via Claude Code | `engcodex`; route complex work to `engopus` | `ios-engineer-loop` | Via Claude Code only |
| `pythonglm` | execution | GLM-5.2 / ZAI via OpenCode | `engcodex`; route sensitive work to `engopus` | `python-engineer-loop` | Via OpenCode only |
| `engopus` | execution | Opus 4.8 / Anthropic via Claude Code | Codex for non-architectural rescue; otherwise Abhi | `senior-engineer-loop` | Via Claude Code only |
| `engcodex` | execution | GPT-5.5 / OpenAI Codex | Sonnet mechanical, Opus complex | `codex-engineer-fallback-loop` | Via Codex only |
| `verifier` | evidence | Sonnet 4.6 / Anthropic | Codex for deterministic command-running | `verification-loop` | No |
| `reviewopus` | evidence | Opus 4.8 / Anthropic | None equivalent; wait/escalate | `opus-review-loop` | No |
| `reviewcodex` | evidence | GPT-5.5 / OpenAI Codex | `reviewglm` if Codex unavailable | `codex-review-loop` | No |
| `reviewglm` | evidence | GLM-5.2 / ZAI | None; use Opus+Codex instead | `glm-backup-review-loop` | No |

Optional future profiles are reserved but should not be enabled until the core
loop is proven: `releasekeeper`, `linearcurator`.

## Binding reviewer pairing by builder

The default review pair remains `reviewopus` + `reviewcodex`, but the binding
diversity gate depends on who built the PR. This table is what the orchestrator
should enforce mechanically.

| Builder profile/provider | Mandatory diversity reviewer | Optional/advisory second opinion | Rule |
|---|---|---|---|
| `iossonnet` / Anthropic | `reviewcodex` / OpenAI | `reviewopus` / Anthropic or `reviewglm` / ZAI | Codex carries the cross-provider verdict; Opus can add architecture judgment but cannot alone approve. |
| `engopus` / Anthropic | `reviewcodex` / OpenAI | `reviewopus` / Anthropic or `reviewglm` / ZAI | Codex carries the cross-provider verdict; Opus cannot self-gate Opus-built code. |
| `pythonglm` / ZAI | `reviewopus` / Anthropic and/or `reviewcodex` / OpenAI | both default reviewers are diverse | Opus+Codex is fully provider-diverse. |
| `engcodex` / OpenAI | `reviewopus` / Anthropic | `reviewglm` / ZAI or `reviewcodex` / OpenAI mechanical pass | Opus carries the cross-provider verdict; Codex same-provider review is advisory only unless Abhi explicitly waives the conflict. |

If the mandatory diversity reviewer is unavailable, switch to another different
provider reviewer where available. If no different-provider reviewer is
available, block and create an unassigned human gate.

## Control-plane profiles

### `orchestrator`

**Purpose:** Board brain. Routes work, creates follow-up cards, reconciles
review outcomes, and escalates human decisions. It owns state transitions, not
implementation.

**Primary model:** Opus 4.8.

**Fallback policy:**

- Codex/GPT-5.5 may perform mechanical board hygiene: copying evidence into
  Linear, creating obvious child cards from a completed card, or closing a card
  whose outcome is already unambiguous.
- No model fallback is equivalent for high-judgment routing, review disagreement,
  or stock-core/release decisions. In those cases the profile must create an
  unassigned human gate for Abhi.

**Allowed tools/actions:**

- Read Linear, GitHub PR metadata, Kanban state, and project docs.
- Create Kanban cards and Linear comments.
- Assign already-approved execution cards.
- Subscribe the originating session to child-card notifications.
- Complete administrative gates when the approval/evidence is already explicit.

**Forbidden actions:**

- Build, edit, or review production code.
- Merge PRs, upload releases, force-push, or delete branches.
- Turn an unapproved Linear issue into an assigned Kanban worker card.
- Resolve reviewer disagreement without surfacing the judgment call.

**Loop: `orchestrator-routing-loop`**

Input:

- completed/blocked Kanban card, Linear issue state, or explicit user command.

Process:

1. Read current Kanban card, parent/child links, runs, and latest evidence.
2. Read linked Linear issue and PR state where present.
3. Check human-gate policy, governor constraints, module boundaries, and current
   wave label.
4. Decide the next state: architect, engineer, verifier, dual-review,
   rework/fallback, final human gate, or done.
5. Create or update the next Kanban/Linear object with exact evidence and
   explicit assignee policy.

Output:

- next actionable card, unassigned human gate, or completed administrative card.

Escalate when:

- reviewer verdicts disagree,
- stock-core/release/destructive action is requested,
- evidence is ambiguous,
- a provider/lane fails twice with the same signature,
- the requested next step would violate a profile contract.

### `scout`

**Purpose:** Discovery/profile for possible product or engineering work. Scout is
allowed to propose; it is not allowed to start execution.

**Primary model:** Sonnet 4.6.

**Fallback policy:**

- Codex/GPT-5.5 may replace Sonnet for structured backlog analysis.
- GLM-5.2 may perform cheap broad codebase scans, but final prioritization and
  wording should be Sonnet/Codex or human-reviewed.

**Allowed tools/actions:**

- Read repo/docs/Linear/GitHub.
- Create Linear proposal comments or draft issues where allowed.
- Suggest labels, areas, risks, and acceptance criteria.

**Forbidden actions:**

- Create execution Kanban cards.
- Assign profiles.
- Edit code or open PRs.
- Mark work as approved for execution.

**Loop: `scout-discovery-loop`**

Input:

- repo state, Linear backlog, product notes, recent failures, user goals.

Process:

1. Scan product/code context.
2. Identify opportunities, bugs, stale areas, or missing acceptance criteria.
3. Group proposals by value, urgency, and risk.
4. Draft Linear-ready issue bodies with evidence and suggested labels.

Output:

- Linear proposals/drafts only. No Kanban execution state.

Escalate when:

- proposal touches sensitive relationships, legal/financial commitments, release
  policy, or a major product-direction fork.

### `architect`

**Purpose:** Convert approved work into safe, executable slices. This is the
highest-leverage and highest-risk planning role.

**Primary model:** Opus 4.8.

**Fallback policy:**

- GLM-5.2 can produce a draft decomposition when Opus is unavailable or cost is
  a concern.
- Codex/GPT-5.5 can normalize the draft into structured task cards and check
  internal consistency.
- High-judgment decompositions are not final without Opus or Abhi approval.

**Allowed tools/actions:**

- Read approved Linear issue, project manifest, code paths, tests, and docs.
- Produce implementation plan and slice graph.
- Create unassigned Kanban gate cards for approved decomposition only.
- Recommend engineer/verifier/reviewer profiles.

**Forbidden actions:**

- Build code.
- Assign execution cards without human approval.
- Collapse multiple collision-prone slices into parallel execution.
- Treat stock-core or direction-fork work as routine.

**Loop: `architect-decomposition-loop`**

Input:

- approved Linear issue with wave label, acceptance criteria, and module area.

Process:

1. Read `docs/autonomous/PROJECT.yaml` and relevant code/docs/tests.
2. Identify impacted modules and exact file boundaries.
3. Decompose into slices with dependencies and collision analysis.
4. Assign suggested engineer profile per slice.
5. Define non-goals, evidence commands, and review requirements.
6. Create unassigned execution gates only after Abhi approves decomposition.

Output:

- slice plan and/or unassigned Kanban gates with Linear backlinks.

Escalate when:

- file/module ownership is unclear,
- two slices must touch the same file,
- acceptance criteria are weak,
- stock core, release, or device-only behavior is involved.

## Execution profiles

All execution profiles share these rules:

- Use an isolated worktree.
- Launch an external coding CLI; do not edit production code natively.
- Heartbeat while running and respect the per-wave concurrency cap from governor
  `max_concurrent_action_loops`.
- Under `shadow_mode=true`, produce the planned comments/cards but open no PR and
  make no execution transition.
- Capture diff/stat, exact test commands, exit codes, PR URL, and residual risks.
- Redact secrets before posting evidence; never paste `.env`, tokens, API keys,
  or credential material into Kanban, Linear, or PR comments.
- Block for verifier/review; do not self-approve.
- Never merge or ship.

### `iossonnet`

**Purpose:** Mechanical iOS/Swift engineering.

**Primary model/tool:** Sonnet 4.6 via Claude Code.

**Fallback policy:**

- `engcodex` for mechanical Codex retry.
- `engopus` for complex iOS state, concurrency, persistence, auth/session, or
  cross-cutting behavior. Do not keep this work in `iossonnet` just because it
  started there.

**Default module scope:** `apps/ios/`.

**Allowed work:**

- UI wiring, small Swift state changes, view-model glue, copy/layout tweaks,
  straightforward tests, and simulator-verifiable behavior.

**Forbidden work:**

- complex concurrency/session/auth/persistence,
- stock Hermes core,
- release/TestFlight,
- device-only judgment without Abhi.

**Loop: `ios-engineer-loop`**

Input:

- assigned iOS Kanban card with acceptance criteria and evidence requirements.

Process:

1. Create project-anchored worktree.
2. Stage prompt for Claude Code/Sonnet.
3. Run coding CLI and monitor.
4. Run iOS build/tests/smoke or document exact blocker.
5. Capture screenshot/video if UI-visible.
6. Open/update PR and post evidence.
7. Block for verifier and reviewers. Because Sonnet built this PR (Anthropic),
   the mandatory diversity reviewer is `reviewcodex` (OpenAI) and it carries the
   binding verdict. `reviewopus` may add architecture/security judgment but
   cannot alone approve Anthropic-built code. If Codex is unavailable, use
   `reviewglm` (ZAI) as the diversity reviewer; if neither is available, block
   and escalate.

Output:

- PR + evidence, or a blocked card with precise failure.

### `pythonglm`

**Purpose:** Default Python/plugin/backend engineer.

**Primary model/tool:** GLM-5.2 via OpenCode.

**Required command pattern:**

```bash
env -u SSL_CERT_FILE opencode run -m zai-coding-plan/glm-5.2 "$(cat PROMPT_FILE)"
```

**Fallback policy:**

- Retry GLM once for transient provider failure if the failure signature changes
  or is plausibly transient.
- Switch to `engcodex` after repeated GLM provider/auth/429/stream failures.
- Route to `engopus` for sensitive architecture, auth/security, stock-core, or
  cross-cutting work.

**Default module scope:** `plugins/hermes-mobile/`, docs/governance, low-risk
Python backend slices.

**Forbidden work:**

- autonomous stock-core edits,
- repeated same-approach retries,
- merge/release,
- final review of GLM-built code by GLM as the only reviewer.

**Loop: `python-engineer-loop`**

Input:

- assigned Python/plugin Kanban card with exact scope and tests.

Process:

1. Create project-anchored worktree.
2. Prepare OpenCode prompt and unset `SSL_CERT_FILE`.
3. Run GLM-5.2 coding lane.
4. Run targeted tests, `py_compile`, lint, and any module-specific checks.
5. Open/update PR, post evidence to Kanban/Linear.
6. Block for verifier and dual review.

Output:

- PR + evidence, or fallback/blocker with exact provider/tool failure.

### `engopus`

**Purpose:** Senior engineer for complex, sensitive, or rescue work.

**Primary model/tool:** Opus 4.8 via Claude Code.

**Fallback policy:**

- Codex/GPT-5.5 can handle non-architectural rescue or mechanical patching.
- If the reason for `engopus` was judgment sensitivity, fallback is Abhi/Opus
  availability, not a weaker model.

**Default module scope:** complex iOS, cross-cutting Python+iOS, auth/security,
concurrency, persistence, stock-core-adjacent work after explicit approval.

**Forbidden work:**

- becoming the default engineer for cost/convenience,
- self-review,
- stock-core edits without explicit approval,
- merge/release.

**Loop: `senior-engineer-loop`**

Input:

- assigned high-complexity card or failed-slice rescue card.

Process:

1. Inspect prior attempts and avoid repeating failed strategy.
2. Create project-anchored worktree.
3. Run Claude Code/Opus with risk-specific prompt.
4. Run broad-enough tests/smokes.
5. Produce PR and risk memo.
6. Block for verifier and dual review. Because Opus built this PR (Anthropic),
   the mandatory diversity reviewer is `reviewcodex` (OpenAI) and it carries the
   binding verdict. `reviewopus` may add an architecture-only second opinion but
   does not count as the independent gate and cannot, on its own, approve
   Opus-built code. If Codex is unavailable, use `reviewglm` (ZAI) as the
   diversity reviewer; if neither is available, block and escalate.

Output:

- PR + risk memo + evidence, or escalated blocker.

### `engcodex`

**Purpose:** Fallback/alternate engineering lane, especially when GLM or Claude
lanes fail.

**Primary model/tool:** GPT-5.5 via Codex CLI.

**Fallback policy:**

- Sonnet/Claude Code for mechanical Swift retry.
- Opus/Claude Code for complex rescue.
- Block if neither fallback changes the approach.

**Default module scope:** fallback builds, rebases, PR updates, structured
mechanical fixes, provider-outage rescue.

**Forbidden work:**

- defaulting to Codex when primary lane is healthy,
- final reviewing its own build as if independent,
- merge/release,
- hiding why fallback was used.

**Loop: `codex-engineer-fallback-loop`**

Input:

- failed/stalled engineer card, explicit fallback card, or mechanical rebase/update card.

Process:

1. Inspect prior runs and identify failed signature.
2. State why Codex fallback is being used.
3. Create/update worktree.
4. Run Codex CLI.
5. Run tests/lint and open/update PR.
6. Post evidence and route to verifier/reviewers.

Output:

- PR/evidence, or precise blocker.

## Evidence profiles

### `verifier`

**Purpose:** Evidence gate. It proves claims against the real repo/dev rig.

**Primary model:** Sonnet 4.6.

**Fallback policy:**

- Codex/GPT-5.5 for deterministic command-running and log summarization.
- Device-only or unavailable-rig checks must become a human/device evidence gate.

**Allowed actions:**

- Checkout PR/branch in clean worktree.
- Run tests, builds, lint, smokes, scripts, health checks.
- Capture logs/screenshots.
- Compare engineer claims with real artifacts.
- Pass/fail with exact evidence.

**Forbidden actions:**

- edit source,
- fix while verifying,
- approve based on self-report,
- mark done without command output/artifacts.

**Loop: `verification-loop`**

Input:

- PR URL/branch + engineer evidence + acceptance criteria.

Process:

1. Create or reuse clean verification worktree.
2. Read engineer evidence and required checks.
3. Run exact commands; capture exit codes and logs.
4. Run additional minimal checks needed to verify acceptance criteria.
5. Mark pass/fail with evidence and residual gaps.

Output:

- verified card, blocked card, or human/device evidence gate.

### `reviewopus`

**Purpose:** Architecture/security/high-judgment adversarial reviewer.

**Primary model:** Opus 4.8.

**Fallback policy:**

- No equivalent fallback for final high-judgment review.
- Codex may produce an interim review, but it does not replace the Opus review
  unless Abhi explicitly waives the Opus gate.

**Allowed actions:**

- Inspect PR diff and surrounding code.
- Review architecture, security, hidden coupling, stock-core boundary, and
  “should we do this at all?” concerns.
- Post APPROVE / REQUEST_CHANGES / ESCALATE with concrete findings.

**Forbidden actions:**

- edit code,
- merge/release,
- rubber-stamp verifier or engineer claims,
- focus only on mechanical style while missing system risk.

**Loop: `opus-review-loop`**

Input:

- PR + verifier evidence + project context.

Process:

1. Inspect diff and affected architecture.
2. Verify safety/security assumptions against source where possible.
3. Identify blocking findings, non-blocking risks, and human judgment calls.
4. Produce verdict.

Output:

- review verdict and risk memo.

### `reviewcodex`

**Purpose:** Default second reviewer for mechanical, regression, and test-coverage
review. This is the standard pair with `reviewopus`.

**Primary model:** GPT-5.5 via Codex/OpenAI.

**Fallback policy:**

- `reviewglm` if Codex is unavailable or Abhi explicitly wants GLM as second reviewer.
- If Codex built the PR, Codex can still run an interim mechanical review, but
  the final verdict-carrying diversity reviewer must be another provider: usually
  `reviewopus`, or `reviewglm` if Opus is unavailable. `reviewcodex` is advisory
  only on Codex-built code unless Abhi explicitly waives the conflict for that PR.

**Allowed actions:**

- Inspect diff line-by-line.
- Run/read tests and static checks.
- Check regression risk, edge cases, and implementation completeness.
- Post APPROVE / REQUEST_CHANGES / ESCALATE.

**Forbidden actions:**

- edit code,
- merge/release,
- override Opus disagreement,
- conceal same-provider builder/reviewer conflict.

**Loop: `codex-review-loop`**

Input:

- PR + verifier evidence.

Process:

1. Inspect changed files and diff against base.
2. Check tests, error handling, edge cases, and code hygiene.
3. Re-run targeted checks if needed.
4. Produce verdict with concrete file/line findings.

Output:

- review verdict + findings.

### `reviewglm`

**Purpose:** Backup or optional third reviewer. Not the default second reviewer.

**Primary model:** GLM-5.2.

**Fallback policy:**

- None. If GLM is unavailable, use Opus+Codex or wait.

**Allowed actions:**

- Independent adversarial diff review when Codex unavailable or requested.
- Optional third opinion on contentious PRs.

**Forbidden actions:**

- replacing Codex as default second reviewer,
- being the only reviewer for GLM-built work,
- merge/release,
- edit code.

**Loop: `glm-backup-review-loop`**

Input:

- PR + verifier evidence + explicit trigger.

Process:

1. Inspect diff independently.
2. Focus on provider-diverse critique.
3. Produce verdict and risks.

Output:

- backup review verdict.

## Optional future profiles

These names are reserved. Do not enable them until the core loop has multiple
successful runs.

### `releasekeeper`

**Purpose:** Release readiness and TestFlight/App Store Connect gatekeeper.

**Primary model:** Sonnet 4.6.

**Fallback:** Codex/GPT-5.5 for checklist execution.

**Loop:** `release-readiness-loop`.

Allowed output is a release checklist and unassigned human release gate. It must
not upload, release, or change public-facing release state without Abhi.

### `linearcurator`

**Purpose:** Linear hygiene: labels, waves, stale issues, missing acceptance
criteria, project taxonomy.

**Primary model:** Sonnet 4.6.

**Fallback:** Codex/GPT-5.5.

**Loop:** `linear-hygiene-loop`.

Start as read-only/propose-first. Orchestrator can absorb this role until Linear
noise becomes a bottleneck.


## Failure and escalation cases

These cases are part of the contract, not after-the-fact judgment calls.

| Failure case | Required behavior |
|---|---|
| Coding CLI hang or heartbeat death | Kill or stop the stuck process after the configured run timeout, capture partial logs/diff, and block the card with stall evidence. Do not silently retry. |
| Engineer claims green but verifier fails | Verifier artifacts win. Return to engineer with exact command-output discrepancy. A second false-green on the same card escalates to Abhi. |
| Repeated same-signature failure | Align with stock Kanban `failure_limit` (default 2 consecutive non-success runs): auto-block and switch approach/provider or escalate. |
| Mandatory diversity reviewer unavailable | Use another different-provider reviewer if available. If none is available, block/wait or create a human waiver gate; never approve via same-provider review alone. |
| Dev gateway `:9200` unavailable during verification | Verifier blocks or creates a human/device evidence gate. Do not pass connectivity/iOS work on partial evidence. |
| Runtime file collision between parallel slices | Abort or block the later-started slice and serialize. Architect should prevent this, but verifier/orchestrator must enforce it if discovered at runtime. |
| Evidence commit mismatch | Verifier records exact base/head SHA; reviewers must review the same SHA. If the PR changes after verification, rerun required verification. |
| Lost Linear/Kanban backlink | Orchestrator blocks and reconciles before allowing further execution. Source-of-truth integrity beats speed. |

## Routing matrix

| Work type | Default profile | Escalate/fallback |
|---|---|---|
| Product/backlog discovery | `scout` | Codex; human for sensitive direction |
| Approved feature decomposition | `architect` | GLM draft + Codex structure; Abhi/Opus for final judgment |
| Mechanical iOS | `iossonnet` | `engcodex`; `engopus` if complex |
| Complex iOS/session/concurrency | `engopus` | Abhi/Opus if judgment-sensitive; Codex only for mechanical rescue |
| Python/plugin/backend | `pythonglm` | `engcodex`; `engopus` if sensitive |
| Stock Hermes core | `engopus` only after explicit human gate | Abhi/upstream-safety review |
| Docs/governance | `pythonglm` or `engcodex` | Opus review for strategy docs |
| Verification | `verifier` | Codex command-runner; human/device gate |
| Architecture/security review | `reviewopus` | wait/escalate; no true fallback |
| Mechanical/regression review | `reviewcodex` | `reviewglm` if Codex unavailable |
| Final merge/release | Abhi | no autonomous fallback |

## Fallback decision tree

1. Is the primary provider temporarily unavailable?
   - Retry once if transient and not destructive.
   - If same failure repeats, switch provider/lane or block.
2. Does fallback preserve role independence?
   - If builder and reviewer would become same provider, mark conflict and add a
     different-provider reviewer or human waiver.
3. Is the work judgment-sensitive?
   - If yes, do not silently downgrade from Opus to cheaper models.
4. Would fallback change the approach?
   - If not, escalation beats another retry.
5. Is the requested action in the 5%?
   - If yes, create an unassigned human gate.

## Loop handoff contracts

### Planning to execution

```text
Linear issue approved for execution
  -> architect decomposition
  -> Abhi approves decomposition
  -> orchestrator creates unassigned Kanban execution gates
  -> Abhi/profile assignment approval
  -> engineer dispatch
```

### Execution to evidence

```text
engineer PR + evidence
  -> verifier card
  -> verifier passes/fails with real artifacts
  -> if pass, dual review cards
```

### Review to merge

```text
reviewopus + reviewcodex in parallel
  -> apply the binding reviewer pairing table for the builder's provider
  -> both approve: orchestrator creates final unassigned human merge gate
  -> one rejects: return to engineer or escalate if ambiguous
  -> both reject: return to engineer with both reports
  -> Abhi approves merge
  -> merge + post-merge verification + Linear Done
```

## Minimum evidence required per card class

| Card class | Minimum evidence |
|---|---|
| Architect | slice graph, file/module boundaries, deps, acceptance criteria, tests, profile routing |
| Engineer | branch/worktree, diff/stat, changed files, test/lint commands + exit codes, PR URL, residual risks |
| Verifier | clean verification context, exact base/head SHA, exact commands + exit codes, logs/screenshots when relevant, pass/fail verdict |
| Reviewer | exact base/head SHA reviewed, changed files, findings, verdict, residual risks, Linear/Kanban comment IDs |
| Orchestrator | source card, decision rule applied, created/updated card IDs, human-gate status |
| Final merge | explicit Abhi approval, PR URL, merge commit, post-merge verification, Linear Done update |

## Current activation status

- Profiles exist: `orchestrator`, `scout`, `architect`, `iossonnet`, `pythonglm`,
  `engopus`, `engcodex`, `verifier`, `reviewopus`, `reviewcodex`, `reviewglm`.
- Proven execution path: ABH-185 used `engcodex`, `reviewopus`, `reviewcodex`,
  final human gate, merge, post-merge verification, and Linear Done. On ABH-185
  the binding diversity reviewer was `reviewopus` (Anthropic, cross-provider to
  the Codex build). `reviewcodex` ran a same-provider mechanical pass and did not,
  by itself, satisfy the diversity gate. This is the canonical shape for
  Codex-built PRs.
- Still needed before broad automation:
  - `claude-code-coding-lane` skill,
  - `codex-coding-lane` skill,
  - one high-quality architect decomposition proof,
  - verifier proof against the real iOS/dev-gateway rig,
  - dispatcher/autonomy rollout only after trust ladder rung approval.
