# Wave Pipeline — the autonomous dev loop's operating contract

Status: foundation locked 2026-07-01 (Abhi). Cron engine deferred (see Rollout).

This is the in-repo, machine-and-human operating contract for Hermes Mobile's
autonomous development loop. It supersedes the older per-step effort matrix and
the hand-built `reviewer-opus`/`reviewer-codex` roster in
`profile-contracts.md`. Where the two disagree, THIS file wins.

Two design docs sit above it and stay true:
- `docs/autonomous-development-loops.md` — Linear-planned, feature-sliced loops.
- `docs/autonomous/PROJECT.yaml` — project manifest (paths, states, wave ledger).

---

## 1. The core idea: two model layers

Every unit of work has **two models**, and conflating them is what makes these
systems bloated and expensive.

- **Profile (driver)** — a full Hermes agent. It does the *judgment*: reads the
  Kanban card, decides what to ask for, launches the worker, watches it, runs
  the tests **itself**, rules the output real or garbage, retries with a
  different approach or escalates. The profile is a manager who cannot be fooled
  by a confident junior. This needs real intelligence.
- **Worker** — the model inside the external coding CLI (Claude Code, OpenCode,
  Codex). It *generates a candidate*: code, a review, a plan. It does not know
  what "done" means, it will claim success when it failed, and it fixates. The
  profile is what makes its output trustworthy.

The split is **not** "profile 5%, worker 95%." It is two different kinds of
thinking: the worker generates; the profile judges, verifies, and decides what
happens next.

---

## 2. The locked roster

**One model per profile. No per-task branching.** If a task needs a stronger
brain, you route it to a *different profile* — you never mutate a profile's
model mid-task. This is what keeps the system from exploding into unmanageable
permutations at build-out.

| Profile | Model | Why this profile carries this brain |
|---|---|---|
| **scout** | Sonnet 5 | Breadth-scan for bugs/ideas. Volume, cheap, no deep single call. |
| **architect** | Opus 4.8 | *It* decides how to slice the wave — the highest-leverage judgment in the system and the #1 documented risk. Done directly. |
| **engineer** | GPT-5.5 | Supervises a worker: stage the ask, watch it, run tests, judge the diff, accept/reject/retry. Adversarial judgment — is this diff real or is the worker bluffing. |
| **verifier** | GPT-5.5 | Catches false-greens ("test passes but doesn't exercise the thing"). Conceptual, not mechanical. |
| **reviewer** | GPT-5.5 | Renders the verdict directly: conceptual errors, blast radius, spec fit. This IS the thinking, not delegated. |
| **orchestrator** | Opus 4.8 | Routes cards, reconciles conflicting reviews, decides what escalates to Abhi. Judgment at the turning points. |

All four providers are used across the system. Profiles carry real brains
because they do real judgment; workers are fixed so there are zero per-task
model decisions.

### Worker lanes — fixed, zero per-task choice

The tool determines the worker. The engineer profile picks a lane by the slice's
module, then launches it with a fixed model + effort:

| CLI spawned | Always runs | Launch note |
|---|---|---|
| **Claude Code** | Opus 4.8 + **ultracode** | `claude --settings '{"ultracode": true}'` (session-only; needs Max/Team/Enterprise plan — confirmed present). ultracode = xhigh + dynamic multi-agent workflow. |
| **OpenCode** | GLM-5.2 **max** | `env -u SSL_CERT_FILE opencode run -m zai-coding-plan/glm-5.2 …` (SSL_CERT_FILE breaks GLM streaming under Hermes; PATH must include `~/.opencode/bin`). |
| **Codex** | GPT-5.5 **high** | codex CLI; auth at `~/.codex/auth.json`. Isolated worktree per the `codex-lane.md` contract. |

`ultracode` is xhigh + swarm — best for large multi-step build slices.
`max` is the deepest *single-pass* reasoning — that's why the architect and any
Opus review use `--effort max`, not ultracode.

### Cross-provider review — one rule

At least one verdict-carrying reviewer must be a different provider than the
builder. The fixed worker lanes make this a simple table, not a 15-cell matrix:

| Built with | Binding reviewer |
|---|---|
| Claude Code (Opus 4.8) | **GPT-5.5** |
| Codex (GPT-5.5) | **Opus 4.8** |
| OpenCode (GLM-5.2) | GPT-5.5 first → Opus if high-risk |

### Single-point-of-failure guard

3 of 6 profiles (engineer, verifier, reviewer) ride GPT-5.5. If the OpenAI lane
is unavailable, **Opus 4.8 is the named fallback for verifier and reviewer** so
review capacity degrades gracefully instead of hard-stalling. The engineer's
worker lane can also fall back Codex→Claude Code per the builder table.

---

## 3. The universal 6-step loop

Every profile runs the **same** loop. A profile is just this loop plus its
config (model + toolset + skills). New capability = new config, not new code.

```
1. CLAIM    read the Kanban card + governor.json (the rules of the cycle)
2. STAGE    build the worker prompt: inject acceptance criteria, safety limits,
            forbidden actions, and the fixed launch flags for the chosen lane
3. DRIVE    launch the external CLI with the fixed worker model + effort
4. MONITOR  heartbeat each cycle; watch kill-conditions (spin, out-of-scope,
            secrets request, wedge, timeout)
5. COLLECT  pull the hard evidence: diff, test output + exit code, screenshots.
            Self-report is never evidence.
6. HANDOFF  write evidence to Kanban + Linear, then transition the card OR
            block+escalate. No transition without an artifact (evidence gate).
```

One loop = one failure surface. When something breaks it is always in one of
these six steps — you debug a contract, not six bespoke flows.

---

## 4. The pipeline: 6 buffered baskets

The conveyor moves left to right, but **every arrow is a buffer, not a
handcuff.** Each stage runs at its own speed, drops output on a shelf, and pulls
from the shelf behind it. Nothing upstream ever waits on anything downstream.
Throughput is set by the slowest *stage*, never by the *most-blocked item*.

```
[0 INTAKE]   scout → Linear Backlog                     ← always running, never blocks
   │ buffer: Backlog
[1 PLAN]     architect assembles the NEXT wave          ← rolling; always building wave N+1
   │ buffer: approved-for-execution, wave-tagged
[2 BUILD]    engineer → worker; verifier; reviewer      ← current execution wave
   │ buffer: merged, awaiting-ship
[3 SHIP]     archive + upload → TestFlight              ← Abhi-gated release action
   │ buffer: shipped, awaiting-device-verify            ← Abhi's parking lot
[4 VERIFY]   Abhi smoke-tests on the phone              ← drains at HIS pace, async
   │ buffer: verify results
[5 FEEDBACK] pass → close; fail → new fix issues → [0]  ← loop closes
```

Wave 53 can sit in basket 4 (Abhi's phone) for a week while wave 54 is in
basket 2 (building) and wave 55 in basket 1 (planning). Three+ waves in flight,
none blocking the others.

---

## 5. The three rules that make the chain unbreakable

1. **The wave pointer advances on SHIP, not on VERIFY.** The moment a wave
   uploads to TestFlight, the active-execution pointer moves to N+1.
   Verification is a *separate async consumer* reading from the parking-lot
   buffer. This single rule is what stops basket 4 (human) from blocking
   basket 2 (build). Encoded as the wave ledger in `PROJECT.yaml` — each wave
   carries its own `stage`, so multiple waves coexist.

2. **Blocked slices get BUMPED, not waited on.** Inside a wave, a slice that
   hits `loop:blocked-human` does NOT hold the wave hostage. It ejects into the
   next wave's candidate pool; the current wave closes with its unblocked
   slices. A blocked task falls *out* of the moving basket into a side basket —
   the basket keeps rolling.

3. **Anything pending on Abhi is a parking-lot item, never a chain link.** Every
   human gate (merge approval, device-verify, direction fork) writes to a
   `pending-abhi` queue he drains whenever. The orchestrator never idles waiting
   on it — it returns to basket 0 and pulls the next thing.

### Backpressure — the one safety valve

Unbounded pipelining stacks N unverified builds. Each buffer gets a **WIP cap**
(default: max 2 shipped-but-unverified builds). At the cap, the SHIP stage
*throttles* — stops uploading new builds — but BUILD and PLAN keep running into
their buffers. Soft slowdown at one stage, never a chain break. Draining a
verify un-throttles ship automatically.

---

## 6. gstack as the per-basket toolkit

gstack skills are the muscle inside each basket, not a parallel system. Any
profile with terminal access can shell the `browse` binary + `gstack` CLI;
Claude-driven work gets the full slash-command suite natively; non-Claude lanes
bridge the heavy skills via `gstack-claude`.

| Basket | gstack skills |
|---|---|
| 0 Intake | `/qa-only`, `/investigate`, `/dogfood`, `/office-hours` |
| 1 Plan | `/autoplan`, `/plan-eng-review`, `/plan-ceo-review`, `/plan-devex-review` |
| 2 Build/Verify | `browse`, `/qa`, `/benchmark`, `/health` |
| 2 Review | `/review`, `/cso`, `/codex` |
| 4/5 Post-ship | `/canary`, `/document-release`, `/retro` |

**Banned from the auto-path:** `/ship` and `/land-and-deploy` (they auto-merge +
deploy). Merge and TestFlight ship stay Abhi's gated 5% — the release runbook
owns the actual ship. Set `OPENCLAW_SESSION` on every spawn so gstack runs
non-interactive (auto-picks recommended options, no AskUserQuestion hang).

---

## 7. Operating rules that bite (verified gotchas)

- **Loop profile spawns run in non-interactive shells.** They do NOT source
  `.zshrc`, so they cannot rely on interactive PATH. Every worker launch must
  set its own `PATH` (e.g. prepend `~/.opencode/bin`) and `env -u SSL_CERT_FILE`
  for the GLM lane inline. Verified: opencode is installed but off the
  non-interactive PATH; the GLM smoke test only passes with both fixes applied.
- **iOS builds run ONLY via `scripts/ios-build.sh`** (machine-global mutex,
  wedge-safe). Never raw `xcodebuild`. Never `kill -9` a wedged build.
- **The evidence gate is non-negotiable** (governor.json). No card advances to a
  passed/done state without a hard artifact: screenshot path, log line, DB row,
  exit code, or test summary.

---

## 8. The 5% that is never autonomous

Merge to a shared/trunk branch · TestFlight upload / release · edits to stock
NousResearch core · device-repro needing Abhi's iPhone · destructive
(`rm -rf`) / force-push / push to upstream · any direction fork the issue spec
is silent on. These escalate to the `pending-abhi` parking lot via push + Linear.

---

## 9. Rollout (trust ladder)

Locked now (this doc + the two files below). Cron engine deferred until the
joints are seen to move.

1. **Now:** wave-ledger in `PROJECT.yaml`; the two core rules
   (ship-advances-pointer, bump-on-block) + WIP caps in `governor.json`; this
   doc as the contract.
2. **Next:** a read-only `pipeline-status.mjs` (sibling to `asc-poll.mjs`) that
   prints the whole conveyor — what's in each basket, what's parked on Abhi,
   what's throttled.
3. **Then:** the orchestrator cron tick (the clock: pull each basket → respect
   WIP caps → bump blocked → advance pointers → escalate the 5%). First ticks
   run in shadow mode. Escalations deliver to Telegram (a TUI-scheduled cron's
   output is NOT delivered back into the TUI session).

No rung is skipped.

---

## 10. Chaining stages onto an existing branch (verify/review after build)

Learned 2026-07-02 (cost 3 failed verifier cards). To hand a committed branch
from one stage to the next (engineer → verifier → reviewer) so the downstream
profile sees the actual code:

- CORRECTION (2026-07-02, orchestrator tick — cost 3 archived scratch cards): a
  bare `hermes kanban create ... --assignee engineer` does NOT auto-anchor a repo
  worktree. It lands `workspace_kind: scratch` at
  `~/.hermes/kanban/boards/<board>/workspaces/<task_id>` — NOT a git checkout — so
  the engineer cannot edit repo files or commit a branch downstream stages can see.
  And plain `--workspace worktree` (no path) resolves to
  `~/Developer/worktrees`, which is NOT inside this repo ("not inside a git repo"
  spawn_failed — the same class as the reaped-worktree failure below).
  THE WORKING RECIPE for the FIRST (engineer) card, matching the last green build
  (ABH-204 t_2d912bf7): pass BOTH an in-repo absolute worktree path AND a branch:
    `hermes kanban --board hermes-mobile create "<title> (engineer)" \
       --body "<card>" --assignee engineer \
       --workspace worktree:/ABS/REPO/.worktrees/<slug> \
       --branch wt/<slug>`
  This creates a real `git worktree` at `.worktrees/<slug>` branched off the base
  tip. Verify with `git worktree list` before dispatch, and `hermes kanban dispatch
  --dry-run` should list the card as spawnable.
- The builder MUST `git commit` its work to that branch before blocking — an
  uncommitted worktree is invisible to downstream stages. (Engineer contract gap:
  it verified but did not commit; patch the engineer prompt to commit-before-block.)
- Downstream stages point at that SAME worktree with:
    `--workspace worktree:<ABSOLUTE_PATH_to_.worktrees/<builder_task_id>>`
  The path MUST be absolute (relative fails: "non-absolute worktree path").
- Do NOT pass `--project` (not a real `kanban create` flag — silently ignored).
- Do NOT use bare `--branch <name>` expecting it to check out an existing branch;
  it lands on the base tip, not the builder's commit.
- Sharing the builder's worktree is safe once the builder is DONE (verifier/reviewer
  are read-only). For parallel stages that both write, give each its own worktree.
- `hermes kanban link <parent> <child>` creates the dependency edge so the child
  auto-promotes when the parent completes (the hands-off auto-advance primitive).
- **The board REAPS the builder's worktree once a downstream stage completes**
  (learned 2026-07-02: an ABH-205 reviewer card spawn_failed twice → auto-blocked
  because the shared `workspaces/<builder_task_id>` dir it pointed at had been pruned
  after the verifier finished — `git worktree list` showed it `prunable`). The
  committed BRANCH survives; only the checkout dir is reaped. So: chain each
  downstream stage on a **freshly (re)created** worktree of the builder's branch, not
  on the previous stage's worktree path. Recipe: `git worktree prune` →
  `git worktree add "$(pwd)/.worktrees/<slug>" <builder_branch>` → point the card at
  that absolute path. One-stage-at-a-time is safest (each stage recreates before it
  runs); don't assume the path a prior stage used still exists.

---

## 11. Two failure modes that bit a real tick (2026-07-03)

**Kanban DB index corruption (`wrong # of entries in index idx_*`).** The
`hermes kanban` tool refuses to open a DB failing `PRAGMA integrity_check` and
auto-renames it to `kanban.db.corrupt.<hash>.bak` on each open until it passes.
This corruption class is **index-only** — the table rows are intact — so it is
**losslessly recoverable**: back up the file, then
`sqlite3 ~/.hermes/kanban/boards/<board>/kanban.db "REINDEX;"` and re-check
`PRAGMA integrity_check;` (expect `ok`). WATCH-OUT: a `kanban create` that races
the corrupt window **silently rolls back** — the card returns an id but never
persists (verify with `sqlite3 ... "SELECT id FROM tasks WHERE id='t_...';"` and
recreate if empty). Its worktree also won't materialize.

**SWBBuildService wedge is a lane-wide gate, and you must not chain into it.**
When `scripts/ios-build.sh` exits 75 (watchdog reaps at ~240s: 0 swift-frontend,
xcodebuild parked at CreateBuildDescription), the Xcode-26 per-user build daemon
is wedged and the ONLY fix is Abhi logout/login (the 5%; file p1 blocked-human).
It gates the **entire iOS build-evidence lane** — every verify and every ship.
Engineers can still write Swift + tests and `git commit` into the buffer (only
the final build-verify step wedges), so the buffered-basket keeps rolling. But
do **NOT** chain a verifier onto a committed-but-unbuilt branch while wedged: the
verifier hits the identical exit-75 and burns the `retries_per_stage: 1` budget
for nothing. Hold the branch in the buffer; the verify→review→merge cascade
resumes automatically once the wedge clears. Do the mechanical scope-check
(`git diff --name-only` vs SCOPE, zero fenced paths) and CUJ-entry check while
waiting — those need no build and pre-clear the branch for a fast post-unwedge
cascade. GOTCHA: a bogus ios-build.sh verb (e.g. `preflight`) returns rc=64
usage-error, which is NOT a wedge-clear signal — only a real `build` reaching
swift-frontend progress proves the wedge lifted.

**Base-moved-mid-tick → false fenced-path FAIL (bit twice on 2026-07-03).** The
fork base (`environment-and-workflows-overview`) can advance WHILE a chain is
in flight (an upstream-sync or soak beat merges a commit mid-tick). If you then
compute a branch's scope with `git diff --name-only origin/<base>..HEAD`, git
shows *base's own new commits* as if the branch deleted/added them — e.g. a soak
beat that landed `.claude/loops/governor.json` + `scripts/promote-to-live.sh` on
base made a clean 1-file widget branch LOOK like it edited two fenced paths. This
produced a false verifier FAIL + a bogus "remove those files" retry card, and
separately fooled the orchestrator's own eyeball read. THE FIX (mandatory for any
scope/fenced-path check): diff against the **merge-base**, never the moving tip:
  `MB=$(git merge-base HEAD origin/<base>); git diff --name-only $MB..HEAD`
Cross-check with `git show <branch_tip> --stat` (a squash-style single commit
shows its true file set). When a branch's committed-diff-vs-tip disagrees with
its merge-base-diff, the base MOVED — REBASE the branch onto the new tip
(`git rebase origin/<base>`, resolve only genuine overlaps — usually just the
Xcode `project.pbxproj` additive conflict; take BOTH sides' new entries but drop
any the base already added, then `plutil -lint` the pbxproj), force-push with
lease, and re-chain the downstream stage on the rebased tip. Every verifier/
reviewer card body MUST instruct the merge-base diff so the artifact can't
recur. This is why downstream cards should always carry the explicit
`git merge-base` recipe, not a bare `diff origin/<base>..HEAD`.
