# hermes-agent (local fork — trunk: feat/group-collapse-pin)

- Remote policy (updated 2026-06-08):
  - `upstream` = NousResearch/hermes-agent — **FETCH-ONLY, NEVER push.** Its push
    URL is deliberately set to a dead `DISABLED://` value. PRs go out only via the
    explicit launch process, never ad hoc.
  - `origin` = github.com/ab0991-oss/hermes-mobile — **PRIVATE backup mirror.**
    Pushing here is allowed (it's the user's own private repo). Keep it private;
    never make it public (it carries proprietary app + gateway work on top of the
    fork). The local-only files below are fine in this private mirror but must
    still never reach `upstream`.
- The user's LIVE shared dashboard runs on 127.0.0.1:9119 (launchd
  ai.hermes.dashboard) — never restart, stop, or point test traffic at it without
  the user's go-ahead. Own test instances: port 9123+, kill when done.
- **Single-executor (user ruling, 2026-06-07): Claude owns BOTH lanes** —
  backend Python (tui_gateway/, hermes_cli/, tools/, tests/) and frontend
  (apps/ios/) alike. The dual-executor split is retired; CODEX-LANE.md is
  kept for history only. Codex is no longer dispatched work in this repo.
- iOS app: apps/ios (XcodeGen — regenerate after project.yml changes). Swift 6
  strict, iOS 17 base, SDK-verify newer APIs against the 26.5 swiftinterface.
  No version bumps outside TestFlight ship commits.
- TestFlight ship runbook (credentials map + exact archive/upload commands):
  **`apps/ios/SHIP-TESTFLIGHT.md`**. The ASC API key lives machine-global at
  `~/.appstoreconnect/private_keys/` (altool's default path) — never commit it.
- **Build the iOS app ONLY via `scripts/ios-build.sh`** — it holds a machine-global
  build mutex (one iOS build at a time across ALL worktrees), uses per-worktree
  DerivedData, and reaps a hung build with SIGTERM, NEVER `kill -9`. Two concurrent
  iOS builds or a force-killed build wedge Xcode's SWBBuildService session-wide
  (cost a 2.5h debug + reboot on 2026-06-08). See `.agent-memory/ops_swbbuildservice_wedge.md`.
- This file and CODEX-LANE.md / CONTRACT-*.md / .agent-memory/ are local working
  files — never include them in upstream-bound patches.

## Continuity & memory (fresh clone / new device)

Cross-session memory now travels with the repo in **`.agent-memory/`**. A new
Claude Code / Conductor session on this repo should FIRST read
`.agent-memory/MEMORY.md` and the entries it indexes — especially
`project_hermes_mobile.md` (continuity), `ops_swbbuildservice_wedge.md`
(build-wedge gotcha), and the `feedback_*` files (working style, model tiering,
root-cause discipline). A full paste-ready continuity prompt is in
**`CONDUCTOR-BOOTSTRAP.md`**.

To unify this device's live memory with the repo copy (so Claude's auto-memory
loads it and memory writes land in-repo), symlink this device's Claude project
memory dir to `.agent-memory`, then commit + push memory changes so other devices
stay in sync. (The project key is the path-encoded dir under
`~/.claude/projects/`; e.g. on this Mac it is `-Users-abbhinnav--hermes-hermes-agent`.)

**LINEAR** (team ABH, project "Hermes Mobile — Engineering") is the cloud source
of truth for tasks — nothing to clone; just sign in.

**WHERE THINGS STAND (2026-06-09):** TestFlight build 22 (1.0.1) is VALID and on
device; trunk = `feat/group-collapse-pin` @ `3edeffeca`; the gateway `session.info`
emit (model hot-swap) is live. Phase = finalize/consolidation. See
`.agent-memory/project_hermes_mobile.md` for the live detail.
