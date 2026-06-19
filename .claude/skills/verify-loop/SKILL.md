---
name: verify-loop
description: >-
  Self-improving end-to-end verification for the Hermes app + gateway. Hand the
  agent the four moves — RUN the app, USE it like a real user/client, PROVE it
  works with hard evidence (screenshots / logs / DB rows / exit codes, NEVER
  self-report), UNBLOCK with auth + seeded state — then hill-climb
  run→detect-failure→fix→repeat to a real green state. FIRE when the user says:
  "verify this works", "prove the change works", "run the verification loop",
  "check it actually works end-to-end", "verify-loop", "confirm the fix on the
  sim/device", "make it work and verify", or after writing code that must be
  exercised against a live running app before it can be called done. Do NOT fire
  for pure unit-test-only edits, docs, or planning.
---

# verify-loop — Hermes

The unit of leverage. A PR/feature that emerges from a closed loop actually works.

## The four moves

- **RUN** — iOS: build+boot+launch on the sim **only via `scripts/ios-build.sh`** (machine-global mutex; **let builds finish — never `kill -9`**; a force-killed build wedges `SWBBuildService` session-wide, recovery is logout/login). Server: start behind a readiness probe (`/health` 200).
- **USE** — iOS: drive it via `xcrun simctl` + the DebugBridge / XCUITest (tap, type, deep-link) — **never computer-use**. Server: hit the real WS/REST endpoints (curl / a foreign WS client).
- **PROVE** — hard evidence only: `simctl io screenshot` before/after, log lines, a DB/REST row, an exit code, an XCUITest assertion. **Never accept "it should work."**
- **UNBLOCK** — inject a test identity (DEBUG bridge / launch args / `?token=`) and seed state via a debug deep link or REST; reset between iterations so runs are deterministic.

## CI gate model (ABH-189 — hybrid)

**LOCAL FULL PLAN is the per-PR gate.** Run `scripts/ios-build.sh test -scheme HermesMobile` (all unit + UITests, no `-only-testing`). Gateway-dependent tests skip-guard on missing `TEST_RUNNER_HERMES_URL`/`TEST_RUNNER_HERMES_TOKEN`, so the gate is gateway-free and passes deterministically on any dev machine or CI node. A PR merges only when this full local plan is green.

**Xcode Cloud = nightly + pre-ship clean-room only** (NOT per-PR). Trigger manually before archiving: `node apps/ios/ci_scripts/asc-cloud.mjs trigger <workflowId> <branch>`. Red nightly = halt + escalate. Rationale: the blocking gate must be fast enough to be honored — per-PR cloud (15–20 min) accumulated 13h of ignored red before ABH-188.

## The rig (gateway-dependent UITests)

1. Isolated gateway on **port 9123** — `HERMES_GATEWAY_BROADCAST=1`, own token. **NEVER point test traffic at the live `:9119` dashboard.** Poll `/health` for 200; SIGTERM-kill it when done.
2. `xcodegen generate` in `apps/ios`.
3. `TEST_RUNNER_HERMES_URL=http://127.0.0.1:9123 TEST_RUNNER_HERMES_TOKEN=<tok> HERMES_BUILD_TIMEOUT=2400 scripts/ios-build.sh test -scheme HermesMobile -destination 'platform=iOS Simulator,id=<booted-sim>' -only-testing:<Suite/Test>`
4. Pull evidence from the `.xcresult` (`xcrun xcresulttool`): attachments + screenshots.

## Hill-climb, don't spin

Each iteration must produce a **new** signal (different error, closer to green, new evidence). **Never retry the same approach twice** — when an approach stalls, switch strategy. Root-cause, don't patch symptoms. Isolate long debugging into a subagent so it doesn't poison the main thread. Checkpoint working states; keep a worklog.

## Escalate only the 5%

Stop and bring the lead/user a **decision** (not a mess) for: irreversible/outward actions (merge, deploy, push, force-push, delete — the PreToolUse guard also blocks these), a genuine direction fork the spec is silent on, or a wall after genuinely-different approaches are exhausted. Everything else: keep going.

## Known-Blockers ledger (append on every NEW blocker)

- **Build wedge** (`SWBBuildService`, every xcodebuild hangs at "Constructing build description", 0 swift-frontend): recovery is **logout/login** (not reboot-first; FileVault). Prevent it: build only via `scripts/ios-build.sh`, never `kill -9`, never two concurrent iOS builds.
- **F3 "MIRROR BUG"** (cross-client assistant text never rendered, 3/3 in F3): **FIXED in build 50** by Bug D (`ChatStore.mergeForeignUserRows()` on foreign `message.start`). Verified 2026-06-18: MIRRORTEST renders ~1.07s after `message.complete`. `F3-VERDICT.md`/`F3-FACTS.md` are historical — do not re-open.
