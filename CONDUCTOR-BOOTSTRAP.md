# Conductor bootstrap — Hermes Mobile

Paste the block below into a fresh Claude Code session (Conductor) opened on this
repo to resume with full continuity. The repo `CLAUDE.md` also auto-loads the
hard rules and points at `.agent-memory/`, so much of this is belt-and-suspenders.

---

You're continuing an in-flight project in this repo. You own BOTH lanes as the
single executor: the iOS app (apps/ios/, SwiftUI + Swift 6 strict, iOS 17 floor,
XcodeGen) and the Python gateway (tui_gateway/, hermes_cli/, hermes_state.py).
The repo CLAUDE.md auto-loads — read it first; it holds the hard rules.

LOAD SHARED MEMORY (now travels with the repo):
Read `.agent-memory/MEMORY.md` and the entries it indexes — especially
project_hermes_mobile.md (continuity), ops_swbbuildservice_wedge.md (build-wedge
gotcha), and the feedback_* entries (working style, model tiering, root-cause
discipline). To make auto-memory + writes land in the repo on THIS device,
symlink your Claude project memory dir to `.agent-memory` (see CLAUDE.md), and
commit/push memory changes so devices stay in sync.

LINEAR IS THE SOURCE OF TRUTH FOR TASKS (use mcp__linear-server__*):
- Workspace linear.app/abhinav-bansal, team key ABH (issues ABH-NNN).
- iOS app + gateway-patch engineering = project "Hermes Mobile — Engineering".
  Query it live for open/in-progress issues; move issues to the right status as
  you ship (don't rely on a hardcoded list).
- Review/feedback boards (convert accepted feedback into focused fix issues, don't
  code into them): "Hermes Mobile — UX Review Gameboard", "Hermes iOS Product
  Inventory & Review". Direction: "Pocket Agent — Agentic OS", "Weave — Branching
  Turns for Hermes", "Hermes Mobile Launch".

WHERE THINGS STAND (2026-06-09):
- TestFlight build 22 (1.0.1) is VALID and on device. Shipped: model-pill session
  hot-swap (shows on first open, reads the per-session model, half-sheet/swipe-up
  picker), drawer "a moment ago" timestamps, and review-wave a11y/P1 fixes.
- Trunk = feat/group-collapse-pin @ 3edeffeca. The gateway session.info emit after
  a session model switch (tui_gateway/server.py) is LIVE (dashboard redeployed
  2026-06-09).
- Phase: finalize/consolidation (feature freeze). Open threads: build-22 device QA
  → close ABH-84/86/89; ABH-90 polish ledger; ABH-55 offline attachments; ABH-85
  native swipe (was reverted). ABH-88 gateway additive-minimization deferred to
  PR-series time.

GIT REMOTES (topology set 2026-06-08):
- origin = github.com/ab0991-oss/hermes-mobile = PRIVATE backup mirror. Push here
  is allowed/encouraged (git push origin <branch>). Keep it private.
- upstream = github.com/NousResearch/hermes-agent = FETCH-ONLY, NEVER push (push
  URL is a dead DISABLED:// value). PRs to upstream only via the explicit launch
  process.

HARD RULES (also in CLAUDE.md — never violate):
- NEVER push to upstream (NousResearch). Pushing to origin (private) is fine.
  Don't touch git stashes. No API keys in code or plists.
- The live dashboard runs on 127.0.0.1:9119 — coordinate redeploys with the user
  (launchctl kickstart -k gui/$(id -u)/ai.hermes.dashboard). Own test gateways on
  port 9123+ and kill them when done.
- Build the iOS app ONLY via scripts/ios-build.sh (build-wedge guard: machine-global
  mutex, per-worktree DerivedData, SIGTERM-not-SIGKILL). Never run two iOS builds at
  once; never kill -9 a build — it wedges SWBBuildService session-wide (reboot-only
  recovery; see .agent-memory/ops_swbbuildservice_wedge.md).
- iOS simulator via xcrun simctl + DebugBridge, NEVER the computer-use MCP. Web
  browsing via the /browse skill, never mcp__claude-in-chrome__*.

SHIP PIPELINE (TestFlight): bump CURRENT_PROJECT_VERSION in apps/ios/project.yml →
xcodegen generate --spec apps/ios/project.yml --project apps/ios → archive (ASC
auth: keyID 3DHXXG4GHQ, issuer d7deff8e-5489-4d18-995d-c8a10f854118, .p8 at
~/.appstoreconnect/private_keys/AuthKey_3DHXXG4GHQ.p8) → PlistBuddy CFBundleVersion
gate across app+extensions → exportArchive ExportOptions-TestFlight.plist
(destination=upload) → poll ASC (app id 6777140135) for VALID.
NOTE: the ASC .p8 signing key + provisioning profiles live OUTSIDE the repo
(secrets). On a NEW device you must set those up before you can build/ship — they
do NOT clone with the code. See .agent-memory/project_hermes_mobile.md for IDs.

FIRST ACTIONS:
1) Read CLAUDE.md + .agent-memory/MEMORY.md and its key entries.
2) Pull Linear (team ABH, project "Hermes Mobile — Engineering") for open work.
3) Confirm the build env is healthy:
   scripts/ios-build.sh build -scheme HermesMobile -destination 'generic/platform=iOS Simulator'
4) git status + git remote -v (origin=private, upstream=fetch-only).
Then report what you'd pick up next — build-22 QA findings + open Linear issues
are the likely top priority.
