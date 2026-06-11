# Linear Backfill Spec — Hermes Mobile Engineering history

Execute exactly. You are creating the historical record of this project in
Linear (team "Abhinav Bansal", key ABH) via the Linear MCP tools. All content
below is pre-authored — do NOT invent, embellish, or summarize differently.
Your only judgment calls: filling in commit hashes marked `<hash: …>` by
finding them in `git log --oneline` on branch hermes-mobile, and matching
dates from commit timestamps.

## Hard rules

1. Do NOT modify, comment on, or restructure the existing project
   "Hermes Mobile Launch" or any of its issues (ABH-5 … ABH-29).
2. Create everything below in a NEW project. If a step fails, stop and report
   — do not improvise an alternative structure.
3. No git writes, no file edits. You only read the repo and write to Linear.

## Step 1 — Project

Create project "Hermes Mobile — Engineering" on team "Abhinav Bansal":

> Engineering record for Hermes Mobile: a native SwiftUI iOS/iPadOS client
> for hermes-agent (local fork, branch `hermes-mobile`; upstream
> NousResearch/hermes-agent — never pushed). Topology: shared persistent
> dashboard (launchd, 127.0.0.1:9119) + Tailscale Serve :9443; clients:
> desktop (remote mode) + iOS app at `apps/ios`. Execution model: dual-lane —
> Codex implements backend Python, Claude implements frontend Swift, Claude
> reviews/tests/commits all work (see CODEX-LANE.md). Launch program tracked
> separately in "Hermes Mobile Launch".

## Step 2 — Team labels

Create labels: `lane:codex`, `lane:claude`, `area:server`, `area:ios`,
`type:backfill`.

## Step 3 — Backfill issues

Create each issue in "Hermes Mobile — Engineering", status **Done**, with
labels `type:backfill` + the listed area label(s). Put the stated completion
date in the description body. Titles and descriptions verbatim from below
(fill `<hash: …>` placeholders from git log first; if a hash cannot be found,
write "commit not isolated — see branch history" instead of guessing).

### Issue 1 — Shared dashboard service + Tailscale topology
Labels: area:server. Completed 2026-06-05.
> Persistent shared backend replacing per-app spawned dashboards: launchd
> `ai.hermes.dashboard` on 127.0.0.1:9119; wrapper
> `~/.hermes/bin/hermes-dashboard-service` sources the session token from
> `~/.hermes/dashboard.token` (0600 — no secrets in plists), sets
> HERMES_GATEWAY_BROADCAST=1, APNs env, and ulimit -n 4096 (holographic
> memory provider leaks 2 FDs/session; launchd default 256 caused REST 500s —
> upstream leak documented, not fixed here). Tailscale Serve :9443 → 9119
> (tailnet-only). Clients must send `Host: 127.0.0.1` (loopback Host check;
> Mac-local MagicDNS resolves ts.net to public Funnel IPs — broken — but
> iPhone/iPad resolve correctly). Desktop switched to remote mode against the
> shared service. Evidence: curl + WS smoke through Serve; desktop full chat
> turn verified.

### Issue 2 — Wave 1: native iOS/iPadOS app (~30 features)
Labels: area:ios. Completed 2026-06-05.
> `apps/ios` HermesMobile (XcodeGen, Swift 6 strict, iOS 17 base, zero
> third-party deps). JSON-RPC WS client actor + @Observable stores + chat UI
> with delta coalescing; reconnect/backfill; voice dictation + TTS;
> edit/retry via truncate ordinals; offline outbox; syntax-highlighted code +
> ANSI; session search/pin/rename/archive/export; approval inbox; Siri App
> Intents; Face ID lock; VisionKit scanner; Spotlight; deep links; widgets +
> Live Activity + share extension (3 targets); iPad 3-column; QR pairing
> (`hermes mobile-pair`). Evidence: 95 unit tests green at wave close; live
> UI test performs a real turn against the shared dashboard.

### Issue 3 — Multi-client broadcast + upload endpoint (server patches)
Labels: area:server. Completed 2026-06-05.
> Branch-only gateway patches enabling true cross-client sync: live-transport
> registry in `tui_gateway/ws.py` + `_broadcast_event` fan-out in
> `server.py._emit`, opt-in via HERMES_GATEWAY_BROADCAST=1, frames enriched
> with stored_session_id; `POST /api/upload` in `hermes_cli/web_server.py`
> (multipart → ~/.hermes/uploads, feeds path-based image.attach). Evidence:
> cross-client live mirror verified both directions (desktop↔iOS); F1 probe
> later confirmed mirrored clients receive identical event streams incl.
> tool.* (2026-06-06).

### Issue 4 — Push v1: APNs end-to-end
Labels: area:server, area:ios. Completed 2026-06-05.
> `hermes_cli/push_notify.py`: ES256 provider JWT, alert payload builder,
> token registry (~/.hermes/push_tokens.json) with per-token
> sandbox/production env routing; `/api/push/register` REST;
> `_push_hook` in tui_gateway pushes approval.request, clarify.request, and
> >30s message.complete. iOS PushRegistrar reads the embedded profile's
> aps-environment VALUE (TestFlight builds carry production). Evidence:
> lock-screen push verified cross-continent (gateway in Singapore, phone in
> Dar es Salaam).

### Issue 5 — UI batches A–D: themes, drawer, chat surface, polish
Labels: area:ios. Completed 2026-06-05.
> Theme engine with 6 desktop themes (nous adaptive default) applied as
> accent tints; ChatGPT-style drawer navigation (chat-as-home, fresh-chat
> landing, local-until-first-message sessions); chat surface with hybrid tool
> rows (live→collapse), agent gutter, mic-in-field composer; screens polish
> pass. Contracts at `apps/ios/CONTRACT-UI-B…D.md`.

### Issue 6 — UI batches E–F: stock-server compatibility + Claude-iOS layering
Labels: area:ios. Completed 2026-06-05/06.
> E: graceful degradation against stock hermes-agent servers
> (ServerCapabilities probing; custom extensions hidden by default) —
> verified against a merge-base worktree dashboard. F: layering/motion match
> to the Claude iOS app studied live via iPhone Mirroring (computer use).

### Issue 7 — session.create latency fix
Labels: area:server. Completed 2026-06-06. Commit `<hash: session.create / _git_branch_fast>`.
> Root cause of chat-open stalls: inline git forks on the session.create
> path. `_git_branch_fast` non-blocking branch read; p95 43ms → 7.6ms.
> Evidence: 296/296 server tests green. This fix is PR0 of the upstream
> series (tracked in launch project, ABH-15).

### Issue 8 — HTTP client consolidation
Labels: area:ios. Completed 2026-06-06.
> RestClient absorbed SessionsAPI + RestControlClient (3 HTTP clients → 1,
> −300 duplicate lines, unified decode(strategy:) + decodeJSONValue).
> Found/driven by /review + /simplify pass. Regression caught during
> consolidation era: appendingPathComponent percent-encoded "?" → 404 with
> silent WS fallback masking it — fixed with percentEncodedQuery + live
> regression test.

### Issue 9 — P1 hotfixes: Settings hit-targets, chat full-bleed geometry, drawer fade
Labels: area:ios. Completed 2026-06-06.
> Settings Appearance row dead (zero-size NavigationLink in ZStack) →
> full-width Buttons + contentShape. Chat card not full-bleed (clipShape cut
> backgrounds at safe-area frame; user-reported twice) → chatCardSurface:
> ignoresSafeArea rounded-rect fill as bottom layer, radius 0 at rest / 28
> displaced, content-only clip; pixel-verified on iPhone 17 Pro + iPhone Air
> sims. Drawer fade reinvention replaced with system
> scrollEdgeEffectStyle(.soft) (iOS 26) + mask fallback 17–25. Process
> lesson recorded: P1 hotfixes get full workflow rigor (the one quality
> failure of the project came from a single-agent shortcut here).

### Issue 10 — UI batches H–I: context meter, glass chrome, full-native rebuild
Labels: area:ios. Completed 2026-06-06.
> H: realtime context-window meter, workspace grouping, glass chrome. I: FULL
> NATIVE rebuild per user direction — system toolbar/List/buttons everywhere,
> Liquid Glass via system components (glassEffect, .glass button styles,
> scrollEdgeEffectStyle), themes expressed as tints on glass; custom code
> survives only where iOS has no component. House standard established:
> SDK-verify every newer API against the iPhoneSimulator26.5 swiftinterface
> before coding.

### Issue 11 — TestFlight pipeline + builds 1–4
Labels: area:ios. Completed 2026-06-06. Version commits `<hash: CFBundleVersion stamp>` + `<hash: version 1.0.1 build 4>`.
> App Store Connect record "Hermes Mobile Gateway" (bundle ai.hermes.app,
> team 6J4Y9NKRQ2). Cloud signing blocked at App Manager role → permanent
> manual path: Apple Distribution cert + 3 IOS_APP_STORE profiles via ASC
> API; worktree archive → PlistBuddy version verification → manual-signing
> exportArchive → poll /v1/builds to VALID. Gotchas fixed: XcodeGen static
> Info.plists recorded build "1" → $(CURRENT_PROJECT_VERSION) references at
> project level; accidental 1.0 > 0.1.0 version-line collision → leapfrog to
> 1.0.1 (4). Build 1.0.1 (4) VALID and delivered to internal testers.

### Issue 12 — UI-G: gstack debug bridge (DEBUG-only)
Labels: area:ios. Completed 2026-06-06. Commit `<hash: gstack debug bridge>`.
> Local SPM package DebugBridge (Core/Touch/UI products) per ios-qa/ios-sync
> skills: loopback StateServer, @Snapshotable accessors over 4 stores,
> KIF-derived touch synthesis, DebugOverlay. Fully #if DEBUG-gated; release
> purity proven on the stripped binary (zero bridge symbols/strings).
> Evidence: 125 unit tests green; bridge-driven QA loop sent a prompt via
> synthesized touch and verified the live gateway's reply on screen.

### Issue 13 — F1: tool-execution verification (suspected P0 cleared)
Labels: area:server. Completed 2026-06-06.
> Suspicion from Batch C: dashboard-hosted sessions might lack toolsets /
> fabricate terminal output. Three live probes against the shared dashboard:
> (1) explicit terminal prompt → tool.generating/start/complete + side-effect
> file on disk with exact nonce; (2) casual phrasing → real read_file +
> exact secret reported; (3) two-client broadcast → mirror received the
> identical 17-event stream incl. all tool.*. Verdict: NOT a P0; tool
> execution real and fully broadcast. Probe scripts kept at /tmp/hermes-f1/.

### Issue 14 — F2 modules: notifications v2 (integration gate pending)
Labels: area:ios, area:server. Modules completed 2026-06-06; gate tracked in ABH-9.
> Contract `apps/ios/CONTRACT-F2.md` (interface pinned). F2-A (app, commit
> `<hash: F2-A>`): notification categories with Approve/Deny actions
> (authenticationRequired), per-decision LAContext gate on destructive
> approvals, Live Activity pushType .token + token registration lifecycle,
> Settings per-event toggles; suite 125 → 147 green, Debug+Release builds
> clean. F2-S (server, commit `<hash: F2-S>`): REST /api/approvals/respond
> (mirrors WS approval.respond), aps.category + payload enrichment, Live
> Activity token registry + liveactivity push sender with ≥3s throttle,
> per-event recipient filtering. NOTE: marked Done as a modules-shipped
> milestone; the end-to-end integration gate + prod rollout are open work
> tracked in launch issues ABH-9 / ABH-10 — do not duplicate them here.

## Step 4 — Report

Reply with: project URL, label list, the 14 issue identifiers with titles,
which hash placeholders you filled (hash → issue), and any step that failed.
