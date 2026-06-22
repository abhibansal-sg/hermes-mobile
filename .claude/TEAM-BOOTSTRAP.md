# TEAM-BOOTSTRAP — Agent Teams handoff (Hermes Mobile)

Paste-ready context for the FIRST agent-team session. Agent Teams is enabled
project-local (`.claude/settings.local.json` → `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`),
so launching `claude` from this worktree starts a team-capable session.

## The team (roster)
Lead = you (Opus): converse with the human, own the plan + the shared task list,
synthesize, take the irreversible/judgment 5%. Set **teammate default model to Sonnet**
(`/model`), escalate gate/judgment nodes to Opus.

Teammate agent types (in `.claude/agents/`):
- **ios-engineer** (Sonnet) — owns `apps/ios/` (UI/iOS). Builds via `scripts/ios-build.sh` only.
- **gateway-plugin-engineer** (Sonnet) — owns `plugins/hermes-mobile/` (server/plugin). pytest. NEVER stock core.
- **verifier** (Sonnet) — runs the verify-loop, returns hard evidence.
- **reviewer-correctness** + **reviewer-security-perf** (Opus) — judgment gates before merge.
- **planner** (Opus) — intent → verifiable spec.

How to drive: `Ctrl+T` shared task list · `Shift+Down` cycle teammates · direct-message any
teammate · teammates message each other (no relay). Quality gates via TaskCompleted/
TeammateIdle hooks (exit 2 = reject + feedback). Cost ≈ linear with team size — pace off
`~/bin/cc-usage status` (authoritative rate-limit %; NOT ccusage $).

## Non-negotiables (every teammate)
- Stock NousResearch core UNTOUCHED (`tui_gateway/`, `hermes_cli/` core, `ui-tui/`, `apps/desktop/`).
  All mobile work in `apps/ios/` + `plugins/hermes-mobile/`. The plugin is the upstreamable unit.
- Build iOS ONLY via `scripts/ios-build.sh` (mutex; SIGTERM-never-`kill -9` → SWBBuildService wedge = logout/login).
- NEVER test against live `:9119`; isolated gateway `:9123+`, kill when done.
- Branch → PR (origin private mirror) → squash-merge to `phase2-upstream-rebase`. PreToolUse guard blocks force-push/rm-rf/protected-merge.
- Verify with HARD EVIDENCE, never self-report. Skipped ≠ passed. Local `-only-testing` green ≠ cloud full-plan green. Fix flaky CLASSES, not single failures. (OS LEARNINGS L1–L5.)
- **GIT ISOLATION (L6):** a git worktree has ONE HEAD — two teammates that branch+commit in the SAME worktree race and cross-contaminate branches (happened 2026-06-18: a plugin PR inherited a CI commit). So a teammate that branches+commits MUST work in its own git worktree (`git worktree add /tmp/<feature> -b <branch> phase2-upstream-rebase`, or Agent `isolation:"worktree"`), OR the team serializes merges through the lead. Read-only teammates may share the worktree. Lead must check `git log <base>..<branch>` shows ONLY that lane's commits before trusting/merging a teammate PR.

## Active follow-ups (2026-06-19) — current handover items
1. **URGENT — red Cloud gate fix (in flight):** Xcode Cloud was red ~13h on the Inc-4 reconnect convergence tests — a FLAKY test (fixed-sleep racing `recoverActiveSession()`'s real REST awaits on the success path before `phase = .connected`), NOT a product bug. Fix = a DEBUG `lastReconnectTask` + `waitForReconnectForTesting()` await seam in `ConnectionStore`, and switch the convergence tests off `settle()`/`Task.sleep` onto that await (+ `reconnectBackoffOverride = 0`). HALT feature merges until green. (Full prompt handed over separately.)
2. **CI strategy → hybrid gate:** per-PR gate = LOCAL full-plan (`scripts/ios-build.sh test -scheme HermesMobile`, all gateway-dependent tests skip-guarded); demote Xcode Cloud to **pre-ship + nightly** clean-room only (stop per-PR triggers). Honor the gate; never merge past red. (Full prompt handed over separately.)
3. **Criterion #3 — real-gateway E2E (deeper proof; do after #1+#2):** the Local-desktop path is only rig-verified (:9123 stand-in). Prove CONTRACT criterion #3 against a REAL gateway. **Tier 1 (team-doable, safe):** real :9123 gateway + a TEST `connection.json` via an additive discovery path-override → discover → pair (manual-token for local mode) → create a session on the gateway → confirm it appears + round-trips on the phone → restart → confirm reconnect (`reauthRequired == false`). **Tier 2 (gold standard):** an ISOLATED real Hermes Desktop app instance (separate userData dir) — **human-coordinated, do NOT run blind.** SAFETY: never touch live `:9119` or clobber the live `~/Library/Application Support/Hermes/connection.json`. (Full note handed over separately.)

## State at handoff (2026-06-18 — HISTORICAL; tip advanced overnight, see Linear + `asc-latest` for current)
- **Tip:** `phase2-upstream-rebase @ 115479b10`. Merged in order: #16 (red-tip Cancel-UITest fix — cloud build #11 GREEN), #17 (ASC driver trigger fix), #18 (Inc-4 lane 4a plugin address-stability). Local valencia synced. A fresh cloud build for `115479b10` triggers on the #18 push — confirm it's green (app code unchanged from the green tip; #18 is plugin Python only).
- **Verify build status:** `node apps/ios/ci_scripts/asc-cloud.mjs status <buildRunId>`, or `node $CLAUDE_JOB_DIR/tmp/asc-latest.mjs 3`. Default workflow `1979B5F8-32DA-491C-BA92-289EC875D83C` (duplicate "Claude" workflow deleted). The `trigger` command now works (PR #17) for pre-merge branch builds.
- **Open PRs:** none of ours outstanding (only dependabot #4–#8). #17 + #18 merged.
- **Inc-4 spec:** `apps/ios/SPEC-INC4-RESTART-SURVIVAL.md`. Lane 4a (plugin) = MERGED (#18). **Lane 4b (iOS) = REMAINING:** deterministic `ConnectionStore` reconnect test proving a gateway restart at a stable address+token → `.connected`, `reauthRequired == false`, no re-pair. → **ios-engineer**. (iOS reconnect ALREADY re-resolves the URL each attempt — 4b is mostly PROOF + small hardening, not a rewrite.)
- **Hardening queued (2 iOS tasks):** (1) restrict `manual_token` pair payloads to loopback/RFC1918 hosts + make the displayed discovered URL non-truncatable; (2) "this replaces your current connection" note when already connected. → **ios-engineer**, each verify→review→PR→merge.
- **Usage monitor:** durable at `~/bin/cc-usage` (source in `claude-code-os` repo). The standing poll-monitor from the previous session does NOT transfer — re-arm one on `cc-usage --alert` if you want proactive breach alerts.
- **Trackers:** Linear ABH-169 (connection modes), ABH-168 (agent-teams decision — now DONE: enabled). Keep updated as PRs land.

## First moves for the team
1. Confirm tip green (#11/#12). If green, mark the red-tip fix task done; merge PR #17 + the 4a PR after review.
2. Spawn ios-engineer + gateway-plugin-engineer. Populate the shared task list: Inc-4 lane 4b (ios), finalize 4a (plugin), hardening #1 + #2 (ios).
3. Drive each through verify (verifier/Sonnet) → review (Opus gates) → PR → squash-merge, pacing off `cc-usage`. Lead stays free for the human.
