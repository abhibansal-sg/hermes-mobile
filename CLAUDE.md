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

**WHERE THINGS STAND (2026-06-16, NIGHT — current):** Work branch
`phase2-upstream-rebase` @ `a574c270d` (build 48 committed + pushed origin).
TestFlight **builds 44–47 VALID** (1.0.1); **build 48 ARCHIVED, gate-green,
upload PENDING user go** (the SHIP-TESTFLIGHT runbook gates the upload as a
release action). Deploy `~/.hermes/hermes-agent` (trunk `feat/group-collapse-pin`)
live on `:9119`, healthy.
- **BUILD 48 — three iOS-only fixes (no gateway edits), each root-caused via a
  grounded live investigation (3-lens workflow) + adversarially reviewed (5-lens
  workflow, SHIP-AFTER-MUSTFIX) before commit:**
  - **Bug C (drawer not sorted by recency + STALE TIMESTAMP for desktop-active
    sessions — ONE root, both symptoms):** `noteActivity` bumped `lastActive` to the
    DEVICE clock and `mergeSessionPage` carried the higher local value forward
    UNCONDITIONALLY (`max(local,server)`); under normal device>gateway clock skew the
    bump NEVER converged → an idle local session outranked a fresher desktop one AND
    showed a stale (future) timestamp (sort + displayDate both key on `lastActive`).
    FIX: gate the carry-forward on the LIVE WINDOW (`lastActivityAt` within
    `liveWindow`) so a settled bump decays to server authority; unify the bump with
    the live stamp in `noteActivity(storedId:)`. + `exclude_source`→`exclude_sources`
    (iOS sent the SINGULAR key; gateway reads PLURAL `exclude_sources` at
    web_server.py:2208 → cron was never server-filtered). 2 new SessionStore tests.
  - **Bug D (mirrored turn's USER prompt didn't appear until force-quit, both
    directions):** gateway broadcasts ONLY assistant frames (user text persisted to DB,
    never `_emit`'d), so the mirror's only user-row delivery was the fragile
    complete-time backfill (missed when `message.complete` dropped/late). FIX:
    `ChatStore.mergeForeignUserRows()` at foreign `.messageStart` — append-only via the
    SAME `toChatMessages` transform → deterministic id → complete-time `reconcileMessages`
    matches in place (no dup, stable identity); never calls cancelStreaming/seed;
    streaming row located by id so insert can't corrupt the live stream. 2 new
    foreign-mirror tests. (Live :9119 emits wireId → immune to the stock-gateway
    positional-id nit the review flagged.)
- **THE BIG FIX — desktop-touched sessions wouldn't accept iOS messages (user-
  confirmed FIXED):** gateway provider-resolution bug, NOT iOS. A session the
  desktop touched is stored `billing_provider="custom"` + empty `model_config`;
  `_stored_session_runtime_overrides` forced `provider="custom"` (a billing label,
  not a resolvable provider) with no `base_url` → `_make_agent` failed `session.resume`
  with **5000 "No LLM provider configured"** → iOS `activeRuntimeId` stayed nil →
  queue-mode + "No active session". A fresh `session.create` on the global
  `hermes-anthropic-proxy` (:18802) provider builds fine — only RESUME of custom-
  billing sessions failed. FIX: `if provider == "custom" and not base_url: provider=""`
  → fall back to global. Deploy commit `b22d22ff5` (live, proven via WS probe);
  worktree `d71f7f04e` + 3 tests. Upstream-PR candidate. (Earlier theories —
  broadcast/ownership/compression/profile/foreign-mirror — were ALL WRONG.)
- **Build 44 (drawer flick):** velocity hand-off (interpolatingSpring + DragGesture
  velocity) — flick open/close no longer snaps.
- **Build 45 (queue self-heal):** ChatStore.send re-resumes on demand + auto-drain +
  chain-tip restamp + supersession guard. (Couldn't fix the desktop-send bug because
  the resume itself failed — see provider fix.)
- **Build 46 (drawer, user-confirmed GOOD):** `geometryGroup()` on the chat content
  (transcript rides the card rigidly — fixes the OLD detached-transcript) + drawer
  parallax (glides in 30%, Telegram ratio).
- **Build 47 (cold-launch stale data, FIXED):** `startHydration` raced the session
  refresh vs an 8s timeout and cancelled the loser — with 5,874 sessions the refresh
  always lost → drawer stuck on stale cache despite "connected". Added a background
  safety-net refresh in `finishHydration` (the model probe already had one).
- **S1 broadcast / mirroring:** RE-ENABLED on `:9119` (deploy `a9be71317`); provider
  fix intact. Sends + mirroring both working.
- **OPEN — Bug A (foreground-after-long-background stuck on "reconnecting") — build-48
  escalation TRIED then REVERTED (adversarial review):** the fix idea (handleScenePhase
  `.reconnecting` → `configure()`) reuses the SAME frozen ephemeral `URLSession`
  (HermesGatewayClient `session`+`client` created ONCE, never recreated), so on a
  genuinely-wedged socket `configure()`→`client.connect()` re-triggers the same 15s
  `awaitReady` stall → `.offline` flash → bounces back to `.reconnecting`. Cold launch
  works only because force-quit = a fresh PROCESS = a fresh URLSession. CORRECT FIX:
  (a) device-repro proving a fresh `webSocketTask` on the reused session recovers, OR
  (b) recreate the HermesGatewayClient/URLSession on escalation (`invalidateAndCancel`
  old + new) = replicate force-quit. Also uncovered: the silent-`.connected`-dead-socket
  tail (foreground hits the `.connected` branch → only REST backfill, never probes the
  dead WS) — wants a liveness ping. Touches fragile reconnect/stream code → DEVICE REPRO
  FIRST (task #51). Workaround: force-quit → reopen.
- **C-PRIMARY follow-up (not a blocker, build-49 candidate):** the carry-forward gate
  reuses `liveWindow` (10s live-DOT) as a "turn-in-progress" proxy; a long agent turn
  with a >10s SILENT inter-frame gap + a refresh landing in the gap can flicker the row
  down mid-turn (self-corrects at message.complete; strictly better than the never-
  converge bug it replaces). Cleaner: gate on an explicit per-id turn-in-progress flag
  set on message.start / cleared on message.complete.
- **DEBUG LESSON (in memory):** reproduce the iOS RPC directly over WS against the live
  gateway (`~/.hermes/hermes-agent/venv/bin/python` + `websockets`; auth = the desktop
  `connection.json` token) FIRST — surfaced the 5000 error in 2 min after many wrong
  code-theories. And: ADVERSARIALLY REVIEW fragile-path fixes (reconnect/foreign-mirror/
  merge) before ship — the build-48 review caught the unproven Bug-A escalation.
NEXT: (1) user go for the build-48 TestFlight upload (archived + CFBundleVersion-48-gated,
ready); (2) user device-verify build 48 (drawer sort + timestamp now correct; user msg
mirrors live); (3) Bug A — device repro, then URLSession-recreation fix.

**BUILD 41 (history):** TestFlight build 41 (1.0.1) was VALID; work
branch = `phase2-upstream-rebase` @ `a1ab20c63`, pushed to origin backup mirror;
trunk = `feat/group-collapse-pin`. Build 41 = the research-driven build-out: studied
11 open-source chat apps (`~/chat-research/REPORT.md` + `REPORT-DATA.md`) →
`PROPOSAL.md`/`PLAN.md` → built. SHIPPED in 41: **A1 per-bubble `Equatable`
short-circuit on MessageBubble** (settled bubbles stop re-evaluating; streaming
~150 body-evals/40ms → 1) + **A2 finalize anim-suppress** (no turn-end flash) —
the chat-view smoothness win; **plugin-side transcript DELTA** route
(`/api/plugins/hermes-mobile/sessions/{id}/messages?after_id&prefix_count&shape`,
read-only generation guard, 14 pytests) + iOS delta-aware fetch w/ safe full-fetch
fallback; **skeleton/light payload shaping** (backend). **ZERO stock-gateway edits**
(all backend plugin-side, `SessionDB(read_only=True)`). iOS build + full test suite
GREEN. Linear **ABH-154** (build-out), ABH-153 (smoothness saga). Full writeup
`~/chat-research/BUILDOUT-SUMMARY.md`. **DELTA ACTIVATION:** only fires once the
gateway runs the updated plugin (redeploy :9119 or a test instance) — until then iOS
falls back to full fetch (safe). DEFERRED (need device loop): iOS skeleton client
tiering (backend ready), keyboard rewrite (works on iPhone fleet), Phase-5 offline
outbox. DECIDED: keep eager VStack (A1 validated it), keep drawer. NEXT: user's
device verdict on build 41 smoothness; then optionally redeploy gateway to activate
delta + tackle deferred items device-verified. See
`.agent-memory/project_hermes_mobile.md` for the live detail.
