# VISION — Hermes Mobile (iOS) north star + "done" criteria

Loop anchor file (per Boris Cherny's loop framework: the durable north-star the
loop re-reads each tick). The `/loop` driver + every teammate reads this to know
WHERE we're going and what "done" means — so intent survives context resets,
compaction, and session switches. Pair with `CLAUDE.md` (rules) + `.claude/TEAM-BOOTSTRAP.md` (live state).

## North star
A native iOS Hermes that is **mature, stable, and feature-rich** — progressively
closing the gap to **Hermes Desktop feature-parity** — so a self-hoster gets a
first-class mobile client. Built **plugin-clean** (the plugin is the upstreamable
unit; endgame = NousResearch adopts it natively as a toggle). Every feature
**verified end-to-end**. Quality and stability are NEVER traded for speed.

## What "done" means for ANY increment (the thing that can say "no")
An increment is DONE only when ALL hold — anything short of this is NOT done:
1. Builds green via `scripts/ios-build.sh` (never raw xcodebuild; never kill -9).
2. Every CONTRACT success-criterion test actually RUNS and passes — **skipped ≠ passed**.
3. Verified with **hard evidence** (build/test output, screenshots, xcresult), not self-report.
4. Opus-reviewed (correctness + security/perf gates) before merge.
5. Cloud **full test plan** green (local `-only-testing` green ≠ cloud green).
6. **Stock NousResearch core untouched** (`tui_gateway/`, `hermes_cli/` core, `ui-tui/`, `apps/desktop/`); all work in `apps/ios/` + `plugins/hermes-mobile/`.
7. No secrets in source; no new flaky tests (fix the whole flaky CLASS, not one case).
8. No regressions: the tip stays green; stability is not mortgaged for a feature.

## What "mature & stable" means (the bar, not just feature count)
- Crash-free + no hangs; unreachable endpoints give actionable errors, never silent stalls.
- Reconnect/restart resilience (connection survives app + gateway restart where the address+token are stable).
- Smooth chat/transcript performance (no jank under streaming bursts).
- Accessibility + Dynamic Type respected.
- Flexible connection modes (local desktop / remote URL / shared dashboard) all regression-free.
- Notifications / Live Activity reliable.

## Direction (re-derive the backlog from the gap each cycle)
1. Finish the connection-modes thread (Inc-4 restart survival + the 2 hardening items). [ABH-169]
2. Then rank the parity/maturity/stability gap vs Hermes Desktop (features desktop has that iOS lacks, open KNOWN-ISSUES, crash/perf/flake signals) and ship the highest value/stability-impact increments.
3. Periodically cut a TestFlight build when a stable batch lands (checkpoint before any version bump / external release).

## Stop / escalate (the human owns the 5%)
Pause + ask before: choosing the next MAJOR feature area or re-prioritizing the roadmap;
any TestFlight version bump / external release; touching the live `:9119` deploy; anything
that appears to need a stock-core edit (red flag); a repeated wall (≥2 diverse approaches
failed); or any irreversible action. Otherwise proceed autonomously on execution, bug-fixes,
stability, and polish — pacing off `~/bin/cc-usage`.
