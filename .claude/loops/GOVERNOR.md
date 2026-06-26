# The Governor — runbook for the Hermes autonomous loop system

**This file is the contract every loop skill obeys.** Numbers live in `governor.json`
(the single source of truth) — read it at the start of **every** cycle. This document is
the *how* and *why*. It exists to deliver the user's mandate: **tightly controlled, output
measured, no doom cycle.** Local-only working file (commit to origin; NEVER upstream).

> One-line rule: **a loop does NOTHING unless `governor.enabled` is true and the cycle is
> within every cap — otherwise it logs why and exits.** When in doubt, stop and escalate.

## Design (settled with the user)
- **No master loop.** Loops are surgical, one per lifecycle **stage**.
- **Linear is the bus AND the state store.** The issue is the surgical atom (one issue =
  one bounded change). Attempt/bounce counts + stage live as Linear **labels** + a
  structured worklog comment — durable, human-visible, survives any context reset.
- **Areas/modules = Linear filters**, not separate daemons. Aim ONE pipeline at one
  swimlane (e.g. `area:ios`), drain it, move on.
- **The human owns two seats:** the spec/success-criteria up front, and the irreversible 5%.

## The pipeline (issue flows by Linear status; one focused loop per stage)
| Stage | Agent (tier) | Pulls | Surgical job | Writes |
|---|---|---|---|---|
| **plan** | planner (Opus) | `Backlog` | spec + explicit success criteria + unblock plan | `Todo` + spec comment |
| **build** | ios / plugin-eng (Sonnet) | `Todo` | implement in a worktree, local full-plan green, open PR | `In Review` |
| **verify** | verify-loop (Sonnet) | `In Review` (unverified) | RUN/USE/PROVE on the :9200 rig + sim; device items → escalate | evidence comment; pass → `loop:verified`, fail → `In Progress` (+`bounce`) |
| **review** | reviewer-correctness + reviewer-security-perf (Opus) | `In Review` + `loop:verified` | adversarial correctness + security/perf | `loop:approved` or changes-requested |
| **release** | release + asc-poll | `loop:approved` **+ user-merged** | ship to TestFlight, poll ASC to VALID, post link | `Done` |

## Per-cycle checklist — every loop skill runs these in order
1. **Preflight (abort the cycle if any fails):**
   - `governor.enabled` is true? else log + exit.
   - `cc-usage` headroom ≥ `caps.min_cc_usage_headroom_pct`? else defer + exit.
   - For an action loop: am I within `caps.max_concurrent_action_loops`? Register in
     `concurrency_state.active_action_loops`.
2. **Pull ONE issue** from this stage's input filter (status + area swimlane). One issue per cycle.
3. **Read its governor state** from labels (`attempts:N`, `bounce:N`, `blocked:needs-human`).
   If `blocked:needs-human` is set → skip (it's the user's). If attempts/bounce already at cap → escalate, don't work it.
4. **Do the one surgical job**, bounded by `caps.max_iterations_per_cycle` /
   `max_wallclock_min_per_cycle` / `max_output_tokens_per_cycle`.
   - **Spin check:** if this iteration's failure signature equals the previous one → STOP (don't burn the retry).
5. **Gate on evidence:** advance the issue ONLY with a hard-evidence artifact attached
   (see `evidence_gate.accepted_kinds`). No evidence → no transition.
6. **Transition + label** the Linear issue per `stage_to_status`. In **shadow mode**, write
   the *proposed* transition + evidence as a comment instead of acting.
7. **Worklog + heartbeat:** one structured comment — what was done, evidence links, the
   transition, tokens/iterations used. This is the status board.
8. **Deregister** from `concurrency_state`; exit cleanly.

## Hard stops (values in `governor.json` → `caps` + `spin_detector`)
- **Spin:** same failure signature twice → stop + escalate. Never retry the same approach.
- **Retries:** ≤ `caps.retries_per_stage` per stage; then `blocked:needs-human` + escalate with a decision.
- **Bounces:** ≤ `caps.max_build_verify_bounces` Verify→Build round-trips; then freeze + escalate.
- **Budget:** ≤ iterations / wallclock / output-tokens per cycle; any breach → stop + escalate.
- **Headroom:** don't start below `caps.min_cc_usage_headroom_pct`.
- **Build wedge:** detector at `build.wedge_detect_seconds`; alert, **never `kill -9`**; build only via `scripts/ios-build.sh`.
- **Heartbeat:** silence past `heartbeat.silence_alert_min` → alert (loop presumed crashed; reap from concurrency_state).
- **Kill switch:** set `governor.enabled=false` to pause ALL loops instantly.

## No false green (the evidence gate)
A stage may not mark anything passed/done on self-report. The transition is gated on an
artifact attached to the issue. This is the single failure mode the whole system fights.

## The 5% — never autonomous (see `the_5_percent_never_autonomous`)
Merge, TestFlight ship, any stock-core edit, device-repro, destructive/force-push/upstream,
and direction forks. Loops STOP at these and **escalate via push + Linear** (channels in
`escalation`) with a decision ("tried A/B/C; here's the wall"), not a debugging dump. The
`.claude/hooks/guard.sh` PreToolUse hook is the backstop that blocks the dangerous commands.

## Shadow mode first (the biggest insurance)
Every new action loop runs propose-only (`shadow_mode` / `loop:shadow`) for its first day —
it writes what it WOULD do; the user reviews its judgment; only then is it flipped to act.

## Measured output (the dashboard)
A read-only digest (scheduled) posts a one-screen board from Linear + cc-usage:
- **Throughput** — issues advanced per stage / day.
- **Quality** — first-try-green %, mean attempts-to-green, false-greens caught (target 0).
- **Cost** — output-tokens per shipped issue; tokens/day vs the cc-usage cap.
- **Friction** — mean time-in-stage; build-mutex wait; count of `blocked:needs-human`.

## The trust ladder (one rung at a time; never skip)
1. **Read-only watchers only** — `asc-poll` + CI/nightly + the digest. Prove stable; clear the
   4-part validation gate (this also completes the OS pilot, ABH-164).
2. **ONE action loop in shadow mode** on ONE sim-verifiable swimlane (start with `verify`). Review ~1 day.
3. **Flip it to act**, governor live, user on the 5%. Watch the dashboard.
4. Add the next stage-loop only after the prior is trusted; graduate stable loops to cloud Routines (`/schedule`).

## Proof obligations before `enabled` goes true (the validation gate)
- A deliberately-spinning task is **caught + escalated** (not run forever).
- The **kill switch** pauses everything.
- **No green without evidence** (a stage refuses to transition with no artifact).
- `guard.sh` **actually blocks** a risky command; **zero secrets** in any committed file/plist.
