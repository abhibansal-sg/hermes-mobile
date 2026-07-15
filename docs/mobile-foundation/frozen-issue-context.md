# Frozen Paperclip Issue Context — spec-relevant extraction

Source: paperclip-20260713-093233.sql.gz (final backup before shutdown). Full open list: frozen-open-issues.tsv


---

## STR-969 [blocked/high] parent=none

**[origin:abhi] SMOOTHNESS: WhatsApp-grade reconnect, mid-turn resume, reliable notifications, delta list sync (parent intent)**

Direct Board feedback (Abhi, 2026-07-07, daily-driving the app): the app is not smooth — visible reconnecting/error flashes on open, dead air after reconnect mid-turn, NO notification when a turn finishes while the phone is off, heavy session-list refresh. Bar: WhatsApp — reconnection invisible, near-real-time always.

Full spec (evidence-based, from three first-hand code audits + live gateway checks): docs/SMOOTHNESS-SPEC.md in the product repo (committed). Six workstreams WS-1..WS-6 with M0/M1/M2 sequencing already proposed.

ARCHITECT: refine per the spec's sequencing — M0 items are small diffs with outsized feel-impact (grace-window reconnect UI, decode the already-server-supported `inflight` field, replace the 30s turn_complete duration gate with an attention gate, apns-expiration 4h, wire shape=skeleton). M2 (seq/replay resumable stream) needs its own protocol spec before any code.

KEY AUDIT FACTS the WUs must not rediscover: server already returns `inflight` on resume and iOS drops it (ProtocolTypes.swift:173); push suppresses turns <30s (push_engine.py:1582) which is exactly Abhi's failing scenario; `/api/sessions` has no updated_since; shape tiering built server-side with zero Swift call sites; APNs IS armed on live with 6 tokens registered.

Acceptance (Board bar): open app → instant paint from cache, silent heal, running turn resumes mid-sentence, phone-off turn completion ALWAYS notifies. Reconnect chaos test (ws_flap x10 as XCUITest) required on WS-1/WS-2 units. UI-evidence law applies.


---

## STR-975 [blocked/high] parent=STR-969

**[STR-969 WU-C / WS-3.1+3.4 / M0] Attention gate replaces 30s push gate + apns-expiration 4h**

**Parent:** STR-969 SMOOTHNESS. **Workstream:** WS-3.1 + WS-3.4. **Milestone:** M0. **Size:** M. **Surface:** plugin (`plugins/hermes-mobile/**`, unfenced) + iOS.

## Problem (audit + live check — do NOT rediscover)
APNs IS armed on :9119, 6 tokens registered, broadcast on. Abhi's EXACT failing scenario: turn running → phone off/locked → turn ends → NO notification. Two confirmed root causes shipping together in this unit:

1. **<30s duration gate is wrong-shaped.** `plugins/hermes-mobile/push_engine.py:~1588` — the `message.complete` branch does `if started is None or (now - started) < 30: return`, suppressing turn_complete for turns under 30s. Abhi's quick turns produce NOTHING **by design**. This is the failing scenario.
2. **`apns-expiration` not set for offline storage.** A phone that is off never receives a push with expiration 0 (APNs discards immediately). Setting `apns-expiration` to 4h lets APNs store-and-forward for an offline phone — this alone may fix "phone off" misses.

## Change intent (from spec WS-3.1 + WS-3.4)
1. **Replace the duration gate with an ATTENTION gate.** Push turn_complete whenever NO live transport holds the session foregrounded (phone off / locked / app killed = always push), regardless of turn length — 5s turn or 5min turn alike. When a live foreground transport IS attached (app open on that session), suppress (the user is watching). Preserve the existing kanban-worker suppression (`_is_kanban_worker()` → no spam) and the approval-request branch (already pushes).
2. **Set `apns-expiration` to 4h** (14400s) on turn_complete/attention sends so APNs stores for an offline device.

## Scope files (developer worktree fence)
- `plugins/hermes-mobile/push_engine.py` (gate + apns-expiration)
- `tests/plugins/hermes_mobile/test_push_engine.py` (gate-behavior tests)

## Acceptance evidence
- **Live device test (the Board scenario):** running turn → lock/turn phone off → turn finishes → notification LANDS. Recording or device screenshot of the lock-screen banner. Test both a <30s turn and a >30s turn.
- Unit tests (`ws_flap`-independent): (a) turn_complete with NO foreground transport → push fired for a 5s turn (previously suppressed); (b) turn_complete WITH a foreground transport attached → suppressed; (c) kanban-worker turn → still suppressed; (d) send carries `apns-expiration=14400`.
- Regression: approval-request push branch unaffected.

## Attention-signal source (developer must confirm the seam)
"No live transport holds the session foregrounded" must map to a REAL signal the plugin already has (foreground WS attach / session `_push_turn_started` lifecycle / connection registry). Developer confirms the exact predicate in `push_engine.py` before wiring — do NOT invent a signal. If no clean foreground-attach signal exists plugin-side, spec bounces to the engineer to define it (small server-adjacent seam, still plugin-scoped) rather than guessing.

## Wiring check
Behavior change on an existing push path; no new client surface required. iOS receipt is validated by the live device test above.


---

## STR-987 [blocked/high] parent=STR-969

**[STR-975 build] Attention gate + apns-expiration=14400 in push_engine.py**

**Parent:** STR-975 (architect gate PASSED — seam confirmed, predicate locked). **Workstream:** WS-3.1 + WS-3.4. **Milestone:** M0. **Size:** M. **Surface:** plugin (`plugins/hermes-mobile/**`, unfenced).

## What to build (predicate already confirmed by architect — do NOT re-derive the signal)

### 1. Replace the 30s duration gate with an attention gate
File: `plugins/hermes-mobile/push_engine.py`, `_process_push_event` `message.complete` branch (currently push_engine.py:1576-1603).

Add a helper (module scope, near `_gw_sessions`):

    def _session_holds_foreground(session) -> bool:
        """True iff a live client WS still holds this session foregrounded.
        A locked/off/killed/backgrounded phone uses a background URLSession with
        NO WS attached (dashboard/api.py:334 + relay.register_device_background),
        so it returns False and turn_complete pushes."""
        t = (session or {}).get("transport")
        return t is not None and not getattr(t, "_closed", False)

Then in the `message.complete` branch, replace:

    if started is None or (now - started) < 30:
        return

with:

    if _session_holds_foreground(session):
        return

KEEP unchanged in that branch:
- the `_push_turn_started` pop (registry hygiene) — but note it currently sits AFTER the 30s guard; move the pop to run regardless so a foregrounded turn still clears its start stamp. Guard the pop with the existing `session.get("_push_turn_started") == started` check.
- the `_is_kanban_worker()` suppression (was line 1589) — worker turns still never push.
- the approval-request branch (1517-1529) — untouched.

Note: `started`/`now` computation can be dropped from this branch since duration no longer gates. `session = _gw_sessions().get(sid)` is already fetched at the top of the branch (line 1577) — reuse it for both the pop and the foreground check.

### 2. Set apns-expiration to 4h (14400s) on the turn_complete/attention alert send
`build_push_headers` already accepts `expiration` (default 0, push_engine.py:203/216). `_notify_direct_apns` calls it with the default (line 878). Plumb an `expiration` param through `notify` -> `_notify_direct_apns` -> `build_push_headers` and pass `14400` on the turn_complete notify call (line ~1597). Approval/clarify/error/background sends keep `expiration=0` (time-sensitive, no store benefit). For the relay path (`relay_client.send_event_background`), carry expiration if the relay contract supports it; if not, note it and leave the direct-APNs path as the store-and-forward guarantee (relay is a separate transport — do not block on it).

## Scope files (developer worktree fence)
- `plugins/hermes-mobile/push_engine.py`
- `tests/plugins/hermes_mobile/test_push_engine.py`

## Unit tests (add to tests/plugins/hermes_mobile/test_push_engine.py — assert behavior, not literals)
Drive `push_engine._process_push_event("message.complete", sid, payload, event_time=..., turn_started=...)` with a monkeypatched `notify` capture and a monkeypatched `_gw_sessions` returning a session dict:
- (a) session has NO `transport` (or a `transport` with `_closed=True`) => `notify` called once for a 5s turn (turn_started = now-5). Previously suppressed by the 30s gate — this is the failing-scenario regression guard.
- (b) session `transport` is a live stub (`_closed=False`) => `notify` NOT called (user is watching).
- (c) `_is_kanban_worker()` monkeypatched True => `notify` NOT called even with no transport.
- (d) apns-expiration: assert the turn_complete path produces headers with `apns-expiration == "14400"` (unit-test `build_push_headers`/`notify` plumbing with a mocked httpx client, or assert the value passed to `_send_one`). Approval path still `"0"`.
Regression: existing approval-request test stays green.

## Acceptance evidence required before in_review
- Unit tests (a)-(d) green via `scripts/run_tests.sh tests/plugins/hermes_mobile/test_push_engine.py -q`.
- Diff touches only the two fenced files.
- Hand to verifier for the live device test: running turn -> lock/turn phone off -> turn finishes -> lock-screen banner LANDS. Test BOTH a sub-30s turn and an over-30s turn. Recording or device screenshot attached.

## Handoff
Engineer builds; verifier owns the live device test (evidence gate). Do not close as done without the device screenshot/recording — the Board scenario (Abhi: quick turn, phone off, no notification) is the whole point of this unit.



---

## STR-953 [blocked/high] parent=none

**[reconnect-offline] session.status wire mismatch makes live-turn re-entry UI a production no-op**

Origin: STR-944 bug-scout reconnect-offline audit, junior-bugs child STR-946; scout-bugs re-verified source first-hand and deduped against current Paperclip issue set.

## What is broken
The iOS live-turn re-entry feature calls gateway RPC `session.status` and decodes it as structured JSON, but the live server handler returns a text-only TUI status block.

Source evidence:
- `apps/ios/HermesMobile/Stores/ChatStore.swift:1168-1178` calls `resolvedLiveTurnStatusFetch`, then only restores in-flight UI when `status?.running == true`.
- `apps/ios/HermesMobile/Stores/ChatStore.swift:1184-1194` implements the live path by calling JSON-RPC `session.status` and decoding into `SessionStatusResult`.
- `apps/ios/HermesMobile/Models/ProtocolTypes.swift:223-229` defines `SessionStatusResult` as optional `running`, `model`, `provider`, `usage` fields, so a payload lacking those keys decodes successfully with `running == nil`.
- `tui_gateway/server.py:7591-7645` handles `session.status` by returning `{ "output": "Hermes TUI Status
...Agent Running: Yes/No" }`, not structured `running/model/provider/usage` keys.
- `tests/test_tui_gateway_server.py:4324-4355` pins that text-output contract by asserting `resp["result"]["output"]` contains `Agent Running: Yes`.
- `apps/ios/HermesMobileTests/LiveTurnReentryTests.swift:72,98,130` injects `chat.liveTurnStatusFetch` directly, bypassing the real RPC wire shape, so tests can pass while production is dead.

## User-visible failure
When a user re-enters a session whose server-side turn is still running (after app backgrounding, switching away/back, or stale-session recovery), the app should show the streaming placeholder/Stop state. Instead `running` is always nil on the live path, so the guard returns and the session looks idle even while the turn is still in flight.

## Why this is not intentional
Commit `f6efdc810 fix(ABH-371): live-turn UI restored on session re-entry (#152)` and CUJ-30 explicitly require this behavior. The mismatch breaks the feature's own acceptance path.

## Dedupe
First-hand search of current Paperclip issues and hermes-loop notes found no existing filing for `session.status` / `resolvedLiveTurnStatusFetch` / `ABH-371` wire mismatch. STR-260 is a different status-string bug (`complete` vs `completed`). STR-23/257/258 are session-control ownership issues, not this live-turn re-entry no-op.

## Acceptance criteria
- Live iOS path consumes a structured running state that matches the server response contract (either server returns structured fields or iOS calls/parses the correct endpoint).
- Focused regression covers the real RPC shape, not only an injected `liveTurnStatusFetch` closure.
- Re-entering a still-running session restores streaming UI/Stop state and does not show the session as idle.



---

## STR-1125 [blocked/medium] parent=none

**Cold-start turn-complete push tap can dead-end before REST bootstrap**

Bug-scout finding from STR-1119 / junior STR-1120, verified first-hand from source (all 8 steps trace to current main @ 15f7830b6).

## What breaks
Tapping a "turn finished" push while the app is FULLY TERMINATED and the tapped session is NOT in the local cache opens the app but neither opens the session nor shows any fallback — a silent dead-end.

## Root cause (confirmed at source)
- HermesMobileApp.swift:128 installs NotificationService.setTapHandler BEFORE `await connectionStore.bootstrap()` (:147). iOS delivers the pending response immediately.
- The handler routes via HermesURLRouter.routePushTap; .turnComplete routes with surfaceInboxIfMissing: false (HermesURLRouter.swift:461).
- openForPush (:499-521): the warm path (:508) resolves synchronously from cache and is CORRECT. The miss path spawns `Task { await sessions.refresh(); ... }` (:512).
- That Task races bootstrap(). On cold start ConnectionStore.rest is nil until configure() assigns currentToken (ConnectionStore.swift:403-404); SessionStore.refresh() returns after cache-paint only when both REST and WS client are nil (:1464-1518). The tap's Task loses the race, the session is not cached, and surfaceInboxIfMissing:false means no inbox fallback → dead-end. No retry is scheduled after bootstrap finishes.

## Not a duplicate
The prior clean push-tap verdict covered warm/resolvable sessions. STR-10 = relay payload misdecoded as turn-complete. STR-248 = cold-launch composer. This is a cold-start lifecycle race for a correctly-shaped turnComplete tap.

## THE SEAM (this is the risk, not the decode)
routePushTap today receives only `sessions` + `inbox` — it has NO handle on connection readiness. The fix MUST make the miss-path resolution wait for (or be re-driven after) bootstrap, WITHOUT altering the warm synchronous branch and WITHOUT double-firing.

Adoption contract (the build seat must satisfy all):
1. Preserve the warm path exactly: a cached session at openForPush:508 still opens SYNCHRONOUSLY with zero added latency — do not await readiness before the cache check.
2. Thread a readiness signal into the miss path. Prefer exposing an async readiness primitive on ConnectionStore (an awaitable that completes once rest/client is non-nil after bootstrap — build on the existing isBootstrapping flag / phase enum; do NOT poll). The miss-path Task awaits readiness, THEN refreshes and resolves. Alternative: buffer the unresolved tap and have bootstrap()'s completion replay it. Either is acceptable; pick one and state which.
3. Bound the wait: if readiness never arrives (offline / unconfigured / phase == .needsSetup), fall through to a SAFE surface — present the inbox even for turnComplete rather than dead-ending, OR post a "couldn't open, tap to retry" affordance. No indefinite hang.
4. Fix the class: apply the SAME fix to .attention taps. Today surfaceInboxIfMissing:true masks the race (it surfaces inbox on miss), but a pre-bootstrap attention tap still cannot resolve the actual session — it should resolve once ready, not fall straight to inbox.

Acceptance assertions:
- NET-0-DUPLICATE: a warm tap (session cached) opens the session EXACTLY ONCE — the readiness/buffer machinery must not also re-open it after bootstrap. Add a test asserting sessions.open is called once for the warm path.
- COLD-RESOLVE: terminated launch + turnComplete tap for an uncached-but-server-resident session → after bootstrap completes, the session opens (not the inbox). New test with a stubbed ConnectionStore that flips to ready mid-flight.
- COLD-OFFLINE: terminated launch + tap + bootstrap ends .needsSetup/offline → the safe fallback surfaces (inbox or retry affordance), never a silent dead-end.

## Size / blast
M. Surfaces: push + cold-start lifecycle (risky). Files: HermesURLRouter.swift (openForPush signature + miss-path), ConnectionStore.swift (readiness primitive), HermesMobileApp.swift (wiring — pass connection into routePushTap), tests in NotificationActionTests.swift. apps/ios/ is UNFENCED. Existing test infra: HermesMobileTests/NotificationActionTests.swift.

## iPad
No layout surface — degradation is identical on iPhone/iPad (pure routing/lifecycle logic).



---

## STR-1126 [done/high] parent=STR-973

**[STR-973A] iOS silent reconnect grace state machine**

## Child A — STR-973A core state machine / silent grace

Seat: dev-ios-claude.

Files allowed: `apps/ios/HermesMobile/Stores/ConnectionStore.swift`, `apps/ios/HermesMobile/Stores/ChatStore.swift` only if needed for grace/send-path integration, and focused tests under `apps/ios/HermesMobileTests/**`.

Contract:
1. Introduce a UI-observable silent reconnect/grace state without surfacing the amber banner immediately. The public contract must expose named constants for 5s cold-open and 10s transient grace; the DEBUG `phaseLabel` must include a stable label for the silent/grace state so StateServer/gstack can assert it.
2. On transport `.closed/.failed` after `hasConnected`, invert the current order: start/probe/reconnect optimistically first; do NOT call `chatStore.handleConnectionDrop()` or clear turn-in-progress during grace. If attempt-0 heals before grace expiry, cancel grace and return `.connected` with no transcript warning.
3. If grace expires while retries still fail, then and only then call `chatStore.handleConnectionDrop()`, clear stuck turns, and escalate to a visible `.reconnecting`/post-grace state.
4. Preserve explicit user `disconnect()` behavior: deliberate disconnect may still finalize in-flight state and go `.needsSetup`.
5. Preserve hard auth failure behavior: after existing 401/403 / `probeIsAuthRevoked` path, `reauthRequired == true` and `.needsSetup` still fire. Grace must never swallow re-pair.
6. Send path during grace must enqueue to the existing outbox/queue path rather than returning a visible send error.

Required tests/evidence:
- Focused XCTest covering named grace constants and DEBUG phaseLabel.
- Deterministic reconnect tests proving attempt-0 success inside grace produces no `Connection lost` warning and no `.reconnecting` banner-visible phase.
- Deterministic expiry test proving post-grace failure stamps exactly one transcript warning and escalates.
- Auth revoke regression still routes re-pair.
- Wrapper command only, no raw xcodebuild: `HERMES_BUILD_TIMEOUT=2400 scripts/ios-build.sh test -scheme HermesMobile -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:HermesMobileTests/ConnectionStoreReconnectTests -only-testing:HermesMobileTests/ConnectionPhaseTests -only-testing:HermesMobileTests/ChatStoreBatchBTests`.

Non-goals: no server changes, no new gateway protocol, no broad transcript refactor, no new animation primitive.

Parent: STR-973. Spec artifact: /Users/abbhinnav/Developer/products/hermes-loop/work-products/STR-973-child-specs.md



---

## STR-1127 [in_review/high] parent=STR-969

**[STR-973B] iOS reconnect grace UI pulse and banner suppression**

## Child B — STR-973B UI surfacing / drawer pulse

Seat: dev-ios-glm. Blocked on Child A.

Files allowed: `apps/ios/HermesMobile/Views/Drawer/**`, `apps/ios/HermesMobile/Views/Shell/RootView.swift` only if needed to pass grace state into the header, and focused tests under `apps/ios/HermesMobileTests/**`.

Contract:
1. During the silent grace state, `ConnectionStatusBanner` renders `EmptyView()` — no amber strip, no red strip, no `Connection lost`, no `Still reconnecting` copy.
2. After grace expiry, the visible surface is a calm amber `Reconnecting…` pill/strip; remove the immediate-loss wording from this path. Offline/retry behavior remains for true offline state.
3. Drawer header shows only a subtle pulsing dot while `isInGrace`; reuse/extract the existing `DrawerSessionRow` reduce-motion-aware pulse. Do not author a second animation.
4. iPad regular/split-view must use the same treatment; no compact-only branch.
5. Cached content remains interactive; do not route a saved/previously connected user back through Welcome/hydration just because grace is active.

Required tests/evidence:
- Focused rendering/unit tests for banner hidden during grace and visible after grace.
- Focused test or snapshot-level seam proving reduce-motion disables the pulse loop consistently with `DrawerSessionRow`.
- Wrapper command only: `HERMES_BUILD_TIMEOUT=2400 scripts/ios-build.sh test -scheme HermesMobile -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:HermesMobileTests/RenderingTests -only-testing:HermesMobileTests/ConnectionPhaseTests` (adjust only if the touched test file differs; explain).

Non-goals: no server surface, no new theme tokens unless needed to reuse existing midground dot, no broad drawer redesign.

Parent: STR-973. Spec artifact: /Users/abbhinnav/Developer/products/hermes-loop/work-products/STR-973-child-specs.md



---

## STR-510 [in_review/high] parent=none

**[auth-pairing] Self-revoke is not an immediate durable sign-out; close events can return the app to reconnecting chat shell**

Origin: STR-505 auth-pairing scout run; junior-bugs STR-506 surfaced as VERIFIED/LEAD, scout-bugs re-verified first-hand against current source before filing.

## User-visible failure
When the user revokes the current device from Settings -> Devices, the app can briefly show the re-pair screen and then silently fall back into the chat shell/reconnecting state. That contradicts the destructive confirmation copy: "Revoking it signs you out immediately -- you'll need to scan a new pairing code."

## Root cause evidence
- `apps/ios/HermesMobile/Views/Settings/DevicesView.swift:313-324` calls `connection.requireRepairAfterCurrentDeviceRevoked()` only when `wasCurrent` is true.
- `apps/ios/HermesMobile/Stores/ConnectionStore.swift:1305-1313` sets `phase = .needsSetup`, but does not set `hasConnected = false`, does not call `chatStore.handleConnectionDrop()`, and does not clear turn-in-progress flags.
- `ConnectionStore.swift:1160-1174` handles a later `.closed/.failed` socket state by calling `chatStore.handleConnectionDrop()` and then `guard hasConnected, reconnectTask == nil else { return }`; because self-revoke left `hasConnected` true, the async close event can call `startReconnectLoop()`.
- `ConnectionStore.swift:1185-1191` makes that reconnect loop set `phase = .reconnecting(attempt:)`, replacing the re-pair state with the connected chat shell until auth re-probe reaches its threshold.
- Existing `DevicesTests.swift::testSuccessfulSelfRevokeDrivesRepairStateSynchronouslyFromWasCurrent` only proves the immediate transition; it does not simulate the follow-up close event or assert `hasConnected == false`.

## Additional verified edge in the same user promise
The silent shared-token -> device-token auto-upgrade intentionally does not rebuild the open socket (`ConnectionStore.swift:1336-1344`). If the current socket was opened with the shared token before auto-upgrade, it was never registered under the new `device_id`; the server's `get_device_sockets(device_id)` live-cut returns no iOS socket. That is acceptable for migration until self-revoke, where the UI promises immediate sign-out.

## Dedupe
Adjacent but distinct from STR-22 (server live-cut index race), STR-150/STR-436 (device-limit retry UX), and STR-151 (CLI device-limit copy). This is the current-device self-revoke fast path violating its own `hasConnected` invariant.

## Fix direction
Make `requireRepairAfterCurrentDeviceRevoked()` behave like an auth teardown: cancel reconnect/hydration, set `hasConnected = false`, finalize/drop streaming turn state, and ensure later socket close events cannot overwrite `.needsSetup`. Add a unit test that calls self-revoke repair, then feeds `.closed`, and asserts phase remains `.needsSetup`.


---

## STR-520 [in_review/high] parent=STR-510

**[STR-510 child] iOS self-revoke auth teardown blocks reconnect close race**

Parent: STR-510 — [auth-pairing] Self-revoke is not an immediate durable sign-out.

Tech-lead first-hand source check (2026-07-06):
- DevicesView.applySuccessfulRevokeSideEffects(...): apps/ios/HermesMobile/Views/Settings/DevicesView.swift:313-324 clears recorded device_id and calls ConnectionStore.requireRepairAfterCurrentDeviceRevoked() only for wasCurrent.
- ConnectionStore.requireRepairAfterCurrentDeviceRevoked(): apps/ios/HermesMobile/Stores/ConnectionStore.swift:1305-1313 cancels reconnect/hydration and sets reauthRequired + phase .needsSetup, but leaves hasConnected true and does not drop chat/session turn state.
- ConnectionStore.handle(state:): apps/ios/HermesMobile/Stores/ConnectionStore.swift:1160-1174 starts reconnect on later .closed/.failed when hasConnected is still true, so .reconnecting(attempt: 0) can overwrite the re-pair state.
- Existing DevicesTests.swift:559-576 only asserts immediate self-revoke transition, not the follow-up close event or hasConnected invariant.

Work unit: implement the self-revoke auth-teardown fix and regression test.

Files in scope:
- Modify: apps/ios/HermesMobile/Stores/ConnectionStore.swift
- Modify: apps/ios/HermesMobileTests/DevicesTests.swift
- Do not touch unrelated app UI, server, plugin, docs, CI config, or generated files.

Required behavior contract:
1. requireRepairAfterCurrentDeviceRevoked() must be an immediate durable sign-out path for the current device.
2. It must cancel reconnect/hydration, set reauthRequired true, set hasConnected false, reset consecutiveReconnectFailures, and leave phase .needsSetup.
3. It must finalize/drop any in-flight streaming turn state just like an auth/transport teardown: call chatStore.handleConnectionDrop() and clear sessionStore turn-in-progress flags so the UI cannot keep a spinner/turn lock after self-revoke.
4. A later GatewayConnectionState.closed or .failed delivered through the production handler must not start reconnect and must not replace .needsSetup.

Required regression test:
- Add/extend a DevicesTests test that seeds a connected self-revoke precondition, calls DevicesView.applySuccessfulRevokeSideEffects(wasCurrent: true,...), then injects a follow-up close event through ConnectionStore._handleGatewayStateForTesting(.closed) or .failed.
- Assert all of these after the close event: DefaultsKeys.deviceId(server:) is nil, connection.reauthRequired is true, connection.phase == .needsSetup, connection.hasConnected == false.
- If the test needs a DEBUG seam already present, use _seedConnectedForTesting and _handleGatewayStateForTesting; do not add a production-only test hook unless unavoidable.

Verification required before handback:
- Run the smallest iOS test command that executes DevicesTests (use the repo’s existing iOS test harness/commands if documented; otherwise report the exact xcodebuild command attempted and its result).
- Run a scope check before handoff if the script exists; otherwise include `git diff --stat` and `git diff -- apps/ios/HermesMobile/Stores/ConnectionStore.swift apps/ios/HermesMobileTests/DevicesTests.swift` summary.

Non-goals:
- Do not change server live-cut indexing.
- Do not rebuild the socket during silent shared-token -> device-token auto-upgrade.
- Do not alter other-device revoke behavior.
- Do not broaden reconnect-loop auth re-probe semantics.

Handback must include: commit hash or explicit uncommitted diff path, exact tests run + output summary, and any blocker.


---

## STR-509 [blocked/high] parent=none

**[auth-pairing] Revoking a device does not cut console/pub/events sockets; only pty/ws are indexed**

Origin: STR-505 auth-pairing scout run; junior-bugs STR-506 surfaced as VERIFIED, scout-bugs re-verified first-hand against current source before filing.

## User/security impact
A paired-device token can keep an already-open `/api/console`, `/api/pub`, or `/api/events` WebSocket alive after the user revokes that device. The UI/copy and endpoint contract say revoke signs a device out immediately, but live-cut only reaches sockets that registered with the token-auth observer.

## Evidence
- `plugins/hermes-mobile/dashboard/api.py:669-680` closes only sockets returned by `device_tokens.get_device_sockets(device_id)`.
- `plugins/hermes-mobile/device_tokens.py:53-59` documents `_ws_device_sockets` as the live socket index used for immediate revoke cuts.
- `hermes_cli/web_server.py:13818-13822` and `13901-13910` register/deregister `_ws_active_identity` via `notify_socket` for `/api/pty` and `/api/ws`.
- `hermes_cli/web_server.py:13303-13334` (`/api/console`), `13925-13947` (`/api/pub`), and `13956-13978` (`/api/events`) authenticate and call `_close_if_ws_device_revoked` only at connect time, but never call `notify_socket("register", ...)`, so they are invisible to the revoke live-cut.

## Dedupe
Distinct from STR-22/ABH-243: STR-22 is the accept-then-register race for `/api/ws` and `/api/pty`; this is a permanent never-registered gap for `/api/console`, `/api/pub`, and `/api/events`. Dedupe searched auth/device/revoke/live-cut/socket issue titles before filing.

## Fix direction
Register/deregister token-auth identities around all device-token-capable long-lived WS handlers, or explicitly reject device-token auth on routes that cannot be safely live-cut. Add tests mirroring `test_device_tokens_ws.py::test_revoke_endpoint_closes_live_socket_with_4401` for console/pub/events.


---

## STR-512 [blocked/high] parent=none

**[auth-pairing] Concurrent auto-upgrade calls can mint orphan device tokens and consume the 64-device cap invisibly**

Origin: STR-505 auth-pairing scout run; junior-bugs STR-506 surfaced as VERIFIED, scout-bugs re-verified first-hand against current source before filing.

## User-visible failure
One physical phone can silently consume multiple server device-token slots during flaky reconnect/backgrounding. The user only sees the later device-limit failure, with no indication that duplicate orphaned tokens were minted by this app instance.

## Evidence
- `ConnectionStore.autoUpgradeToDeviceTokenIfNeeded(serverURL:)` checks `DefaultsKeys.deviceId(server:) == nil` before issuing at `apps/ios/HermesMobile/Stores/ConnectionStore.swift:1365-1382`.
- It awaits `rest.issueDevice(...)` at `ConnectionStore.swift:1382`, then only re-checks local persisted id at `1398-1399` before saving the winning token at `1404-1412`.
- `recoverActiveSession()` launches capability probe + auto-upgrade from an untracked fire-and-forget `Task` at `ConnectionStore.swift:1510-1521`; `configure()` also launches auto-upgrade after initial connect at `757-770`.
- Because `ConnectionStore` is `@MainActor`, true thread parallelism is not needed: two calls can both pass the first guard, suspend in `issueDevice`, and both POST `/devices/issue`. `plugins/hermes-mobile/device_tokens.py:211-250` always mints a fresh id/token and consumes a registry slot; there is no idempotency key per client/device.
- The later local guard only prevents the second token from being persisted locally; it cannot un-mint the already-created server registry entry. That token is not shown as current device and is never revoked by the app.

## Dedupe
Distinct from STR-150/STR-436 and STR-151: those cover how the app/CLI responds after the cap is hit. This covers silent slot consumption that can cause the cap with normal usage.

## Fix direction
Serialize auto-upgrade per server (single in-flight task/actor gate) or make `/devices/issue` idempotent for a stable client instance. Add a test with delayed `RestClient.issueDevice`, overlapping auto-upgrade calls, and assert the issue endpoint is called once.


---

## STR-526 [in_review/high] parent=STR-512

**[STR-512] iOS single-flight auto-upgrade so one app instance cannot mint orphan device tokens**

Parent: STR-512
Role: implementation dev seat. Engineer-backend is the tech lead and must not write production code; produce the implementation diff and focused tests for review.

Problem to fix
- One ConnectionStore instance can launch two auto-upgrade calls (configure() task at ConnectionStore.swift:757-770 and recoverActiveSession() task at 1510-1521).
- Both calls can pass `DefaultsKeys.deviceId(server:) == nil`, suspend in `rest.issueDevice`, and POST `/devices/issue` twice.
- The second local guard at 1398-1399 prevents only local persistence; it cannot un-mint the already-created server token, so the app invisibly consumes registry slots.

Required implementation contract
- Add a per-server single-flight/in-flight gate around `ConnectionStore.autoUpgradeToDeviceTokenIfNeeded(serverURL:)` so overlapping calls for the same server share/await one issue operation or return without issuing a second token.
- The gate must clear on success, typed 409, generic failure, stale-server exit, and Keychain write failure. A later legitimate retry after a failure/device-id clear must still be possible.
- Keep the existing safety semantics: stock/unsettled capability no-op, recorded device id no-op, device-limit suppression no-op, serverURL still-active check, Keychain-write failure does not record device_id, no token logging/persistence outside Keychain/currentToken.
- Prefer a client-side gate only. Do NOT add a server idempotency surface unless you can wire the iOS consumer in the same diff and explain why it is necessary. Do NOT coalesce server `/devices/issue` by shared token + device_name/platform; that would collapse two real devices pairing concurrently.

Likely files
- `apps/ios/HermesMobile/Stores/ConnectionStore.swift`
- `apps/ios/HermesMobileTests/DevicesTests.swift` or a more focused ConnectionStore test file if existing patterns fit better.

Test requirements
- Add a DEBUG/test injection seam if needed so the test can delay `issueDevice` without a live server.
- Add a regression test that starts two overlapping auto-upgrade calls for the same server while the first issue operation is suspended/delayed; assert the issue operation is invoked exactly once and the recorded device id/token state is consistent with the single issued device.
- Also assert a later retry is not permanently suppressed after a generic issue failure (or explain which existing test covers it).
- Run the smallest iOS test command that proves the touched test(s), using the project wrapper/script convention. Do not run raw xcodebuild builds unless the repo script requires it.

Non-goals
- No UI changes.
- No device-limit copy changes.
- No server registry cap changes.
- No unrelated reconnect/hydration refactors.

Handoff evidence required
- Commit/diff path summary.
- Exact test command and result.
- Note how the in-flight gate clears on every exit path.

## Acceptance Criteria

- Overlapping same-server auto-upgrade calls invoke issueDevice exactly once.
- In-flight gate clears after success, 409, generic failure, stale-server exit, and keychain-write failure.
- No token logging or non-Keychain token persistence is introduced.
- Focused iOS regression test passes with command evidence.


---

## STR-1825 [todo/high] parent=none

**[STR-510 follow-up] Two more async suspension points can resurrect .connected/.reconnecting after self-revoke**

STR-510 fixed the specific close-event race (ConnectionStore.requireRepairAfterCurrentDeviceRevoked() now clears hasConnected synchronously) plus two adjacent async-suspension staleness gaps found via codex cross-model review round 1 (startReconnectLoop post-recoverActiveSession() resume; handleScenePhase post-await dead-socket branch). A round-2 codex pass on the amended diff found the same check-before-await/act-after-resume-without-recheck pattern at two MORE call sites in apps/ios/HermesMobile/Stores/ConnectionStore.swift, still present on this branch after the STR-510 fix:

1. [P1] `.open` transport-state handler, ConnectionStore.swift ~line 1241 (`handle(state:)`): `if reconnectTask == nil, phase != .hydrating { phase = .connected }` is not gated on `hasConnected`. Mechanism: `handle(state:)` is driven by `for await state in self.client.stateChanges` (single-consumer async stream, ~line 1063). A `.open` transition can be queued in that stream before a self-revoke runs; by the time the stream consumer actually processes it, requireRepairAfterCurrentDeviceRevoked() has already set `.needsSetup` + `hasConnected = false`, but the queued `.open` case has no way to know that and unconditionally republishes `.connected`.

2. [P1] `probeLiveness()` suspension inside the foreground scene-phase handler (ConnectionStore.swift ~line 1784-1810, handleScenePhase). The STR-510 fix added a `guard self.hasConnected else { return }` immediately after the `await self.client.state` read, but `probeLiveness()` is a SECOND await further down the same Task -- a self-revoke that lands during that second suspension is not caught by the first guard, and the `guard alive else { ... startReconnectLoop() }` branch after the probe resurrects the reconnect loop.

Both are the same underlying pattern: async event/lifecycle handlers in ConnectionStore capture a stale hasConnected/phase precondition before an await and act on it after resuming without rechecking. Recommend a systemic fix (e.g. a monotonically-incrementing connection generation/epoch captured before each suspension and checked after, or re-deriving the guard at the exact point of each state mutation) rather than continuing to patch individual call sites reactively -- STR-510 already needed 3 rounds of whack-a-mole guards and codex found a new self-introduced regression in round 2 (a guard that unconditionally cleared reconnectTask, clobbering a newer in-flight task -- fixed, see STR-510 commit 3c7dec3c0).

Evidence: evidence/str-510-verifier/codex-review-round2-FAIL.log (full codex transcript with exact line citations and ordering walkthroughs for both findings). Out of STR-510's explicit scope (that issue was specifically about the .closed/.failed observer race, now closed and double-verified) -- filing as a dedicated hardening follow-up rather than blocking STR-510 on it, per V4 verdict law.


---

## STR-1824 [todo/medium] parent=none

**[STR-510 follow-up] Pre-existing failure: testReconnectSuccessEntersDraftWhenNoActiveSession**

Found while running the Tier-2 scoped test suite for STR-510 (ConnectionStoreReconnectTests + DevicesTests). `ConnectionStoreReconnectTests.testReconnectSuccessEntersDraftWhenNoActiveSession()` (apps/ios/HermesMobileTests/ConnectionStoreReconnectTests.swift:326-342) fails on base, unrelated to STR-510.

Regression-scoped verification: stashed the STR-510 diff (`git stash push -- apps/ios/HermesMobile/Stores/ConnectionStore.swift apps/ios/HermesMobileTests/DevicesTests.swift`), reran just this one test against unmodified base -> identical failure. Restored via `git stash pop`.

Assertion failing: after `_seedAndStartReconnect` + `waitForReconnectForTesting()`, `sessions.isDraft` is expected true ("reconnect success with no active session must land on a draft chat, not the empty-state placeholder") but is false.

Evidence: evidence/str-510-verifier/baseline-single-test.log, evidence/str-510-verifier/xcodebuild-full-baseline-single-test.log (repo-durable paths, branch str-1339-ios-live-creds-provision).

Not a blocker for STR-510 per V4 verdict law (pre-existing, regression-scoped out). Needs its own root-cause pass on the reconnect-success draft-session routing path.


---

## STR-246 [blocked/medium] parent=none

**[share-widgets-capture] Ask Hermes intent silently loses prompt + orphans session when chat.send fails after session create**

type/bug + comp/dashboard + P2 — filed by scout-bugs run STR-218 (architect self-audit, share-widgets-capture cluster).

## Symptom (user-visible)
A "Ask Hermes" Siri phrase / Shortcut (or a future URL/Handoff caller of PendingIntentRouter.apply) can SILENTLY LOSE the user's prompt AND orphan an empty session when the send fails after the session is created. The user spoke/typed a question, the app foregrounded, a new empty session appears in their list, and nothing was ever asked — with no error and no re-queue.

## Failure sequence (VERIFIED, current main)
1. AskHermesIntent.perform() parks PendingIntent.ask(prompt:) and foregrounds the app.
   - apps/ios/HermesMobile/Intents/HermesAppIntents.swift:42
2. On scenePhase==.active (or the .connected connection edge) the app calls PendingIntentRouter.drain(...).
   - apps/ios/HermesMobile/App/HermesMobileApp.swift:190-194 (foreground) / 201-210 (connection edge)
3. drain() reads AND CLEARS the parked intent atomically via PendingIntent.takePending (removeObject), THEN calls apply().
   - apps/ios/HermesMobile/Intents/PendingIntentRouter.swift:37-38
   - apps/ios/HermesMobile/Intents/PendingIntent.swift:80-90 (takePending removes before apply sees it)
4. apply(.ask): gates on isConnected; if connected it does `try await sessions.createSessionNow()` (re-parks only on THROW), then `await chat.send(text: prompt)` — and DISCARDS the Bool return.
   - apps/ios/HermesMobile/Intents/PendingIntentRouter.swift:66-83  (line 81: `await chat.send(text: prompt)` — return value ignored)
5. chat.send returns `false` (does NOT throw) on several post-createSessionNow failures:
   - sessionBusy RPC -> `lastError="Agent is busy"; return false` (ChatStore.swift ~1913-1918)
   - attachment upload failure -> `return false` (ChatStore.swift, uploadAndAttach catch)
   - any prompt.submit requestRaw error -> `return false` (ChatStore.swift ~1919-1923)
   Signature: `func send(text:includeAttachments:) async -> Bool` at ChatStore.swift:1826 (@discardableResult:1825).
6. Net: the intent was already removed from UserDefaults in step 3, createSessionNow() SUCCEEDED (so no re-park), and the false from send is dropped — the prompt is unrecoverably lost and an empty session is orphaned server-side.

## Why this is a real bug, not intentional design
This is the SAME unchecked-`chat.send` class fixed in the share-extension drainer (ABH-310 lineage): SharedInboxDrainer.process() correctly does `let didSend = await chat.send(...); guard didSend else { return nil }` and leaves the item queued on failure (apps/ios/HermesMobile/Support/SharedInboxDrainer.swift:158-159). The App-Intents "Ask Hermes" sibling path was never given the same guard. The re-park machinery already exists and is used for the createSessionNow throw (PendingIntentRouter.swift:68, 77) and the offline gate (PendingIntentRouter.swift:67-70) — it simply isn't triggered on the send-Bool==false branch.

## Verification / re-check of premise
- Confirmed takePending() removes the key on read (PendingIntent.swift:88) so nothing survives an unchecked apply.
- Confirmed the offline case IS covered (testAskReparksWhenDisconnected, HermesMobileTests/PendingIntentDraftTests.swift:112-127) — but there is NO test for send-failure-after-connect re-park, so this branch is both unguarded and untested.
- Confirmed chat.send has multiple `return false` (not throw) exits reachable AFTER a successful createSessionNow (sessionBusy / upload / prompt.submit RPC).

## Suggested fix direction (for the eng lane, not part of this scout filing)
In PendingIntentRouter.apply(.ask), capture the Bool: `let didSend = await chat.send(text: prompt); if !didSend { intent.park(in: defaults) }` (mirror SharedInboxDrainer's guard). Consider whether an orphaned empty session should also be cleaned up on send-failure, matching the newSession local-draft rationale. Add a PendingIntentDraftTests case: connected + failing chat.send -> intent re-parked.

## Dedupe
- No existing board issue references PendingIntent / AskHermes / App Intent / Siri send-loss (searched STR + ABH lineage on run STR-218).
- Distinct from STR-23 (ABH-239 steer-dropped mid-turn) and STR-18 (ABH-317 cron-delete orphans sessions) — different root causes.
- Sibling-but-fixed: ABH-310 (share-drain unchecked send) — this is the un-fixed twin on the App Intents path.

Evidence anchors: PendingIntentRouter.swift:66-83 · PendingIntent.swift:80-90 · HermesAppIntents.swift:42 · ChatStore.swift:1825-1826,~1913-1923 · SharedInboxDrainer.swift:158-159 (correct sibling) · PendingIntentDraftTests.swift:112-127 (test gap).



---

## STR-16 [in_review/medium] parent=none

**[ABH-338] Relay push pairing secret is minted but never made usable (no QR/full-copy/share) — pairing flow unreachable**

linear:ABH-338
labels: type:fix, area:ios, area:server, loop:parked-low-value

Relay push settings has a "Pair this device" button (Settings > Relay Push > Device Pairing, RelaySettingsView.swift:234-248) that calls RelayStore.pair() (RelayStore.swift:142-159), which POSTs /relay/pair and mints a fresh one-time relay pairing secret via relay_client.relay_pairing() (dashboard/api.py:1100-1125, relay_client.py:360-364, 391-413).

The mint succeeds and relayPairing is stored, but the UI never exposes a usable copy of the secret:

* pairingSummary (RelayStore.swift:61-64) truncates the secret to an 8-character prefix ("pairing prefix XXXXXXXX...") — the full secret is never rendered anywhere.
* The only view of it is a plain Text with .textSelection(.enabled) (RelaySettingsView.swift:225-232) over that truncated string, so long-press-copy yields the prefix, not a usable secret.
* No QR code, ShareLink, or full-secret copy action exists anywhere in RelaySettingsView.
* RelayStore.apply() (RelayStore.swift:203-213), called by both load() and save(), unconditionally clears relayPairing = nil. Any navigation away and back to Relay Push (which calls .task { await store.load() } on RelaySettingsView.swift:37) discards the pairing state.

Per the original design (docs/autonomous/ADAPTATION-PLAN-relay-tunnel.md Slice D), this pairing secret is meant to be carried in a hermesapp://pair?relay=<url>&agent=<agent>&pairing=<secret>&kind=relay deep link/QR so a SECOND device can scan it and establish relay connectivity (HermesURLRouter.parsePairPayload already parses kind=relay links, RelayPairPayloadTests.swift confirms the parser works). But nothing in the app ever constructs that link or a QR code from a freshly-minted pairing secret — the mint is a dead end. The server mints a one-time secret (rotating any previous one — relay_client.py:391 "Rotate + fetch a fresh pairing token") that the user can never actually retrieve or transfer, so tapping "Pair this device" repeatedly just burns pairing secrets with no way to complete a pairing.

Verified against source: read RelaySettingsView.swift, RelayStore.swift, relay_client.py, dashboard/api.py, HermesURLRouter.swift, ADAPTATION-PLAN-relay-tunnel.md. This is not intentional design — the plan explicitly calls for a QR/deep-link surface (Slice D) that was never built; only the mint endpoint + a truncated-text preview shipped.

Impact: the relay-push pairing flow (one of push-relay cluster's core flows) cannot be completed by any user on any device. iPhone and iPad both affected identically (no size-class-specific code here).

---
Bridged from Linear ABH-338. Comment key outcomes here; the bridge relays to Linear. Follow loop-common skill.


---

## STR-902 [in_review/medium] parent=none

**[auth-pairing] mobile-pair mints device token against :9119 even when QR targets a discovered Desktop gateway port**

Origin: STR-878 auth-pairing scout run; junior-bugs STR-898 surfaced as VERIFIED #1, scout-bugs re-verified first-hand against current source and Paperclip issue set before filing.

## User-visible failure
`hermes mobile-pair` can discover a Desktop-owned local gateway on a non-default ephemeral port (9120-9199), but then tries to mint the per-device token against hardcoded `127.0.0.1:9119`. In Desktop local mode this can either fail even though the reachable gateway was found, or mint a token against the wrong listener if another Hermes dashboard is bound to 9119.

Failure sequence:
1. Desktop app owns a local gateway on e.g. `http://127.0.0.1:9145`; nothing useful for this Desktop instance is on `:9119`.
2. `hermes mobile-pair` calls `_detect_pair_address()` and correctly sets the QR server URL to the discovered Desktop gateway.
3. The device-token mint POST ignores that discovered URL and goes to `http://127.0.0.1:9119`.
4. If `:9119` is absent, the CLI prints the generic legacy-server / `--shared-token` fallback even though the actual gateway is reachable. If `:9119` is another Hermes instance, the QR embeds a token the phone's target server will reject.

## Evidence re-checked first-hand
- `plugins/hermes-mobile/mobile_pair.py:159-161` sets `dashboard_url` from `_detect_pair_address()` when no explicit `--url` override is supplied.
- `plugins/hermes-mobile/mobile_pair.py:187-188` then sets `mint_url = override_url or f"http://127.0.0.1:{DEFAULT_DASHBOARD_PORT}"` and calls `_issue_device_token(mint_url, token)`, ignoring the discovered `dashboard_url` for minting.
- `plugins/hermes-mobile/mobile_pair.py:331-409` proves Desktop local mode discovery can return `http://127.0.0.1:{port}` for any responding port in `_LOCAL_PROBE_PORTS` (`9119`, then `9120..9199`).
- `plugins/hermes-mobile/mobile_pair.py:625-669` proves `_detect_pair_address()` returns that Desktop URL as the pairing address, including non-default local ports.
- Dedupe checked the Paperclip issue set for mobile-pair / 9119 / wrong-server / pairing-token issues. Existing STR-151 covers typed 409 device-limit guidance; STR-377 is broad setup friction. Neither covers minting against a different server from the QR target.

## Why this is a bug, not polish
The command reports a pairing code for one server while minting the credential against a different server. That breaks the core scan-and-pair flow and can produce an auth failure that looks like a bad QR/token rather than a port-target mismatch.

## Fix direction
When discovery returns a loopback Desktop gateway, mint the device token against the same resolved local origin that the QR will target, not unconditional `DEFAULT_DASHBOARD_PORT`. Preserve the explicit `--url` and Tailscale/remote safety behavior intentionally documented in the comments. Add a test where `_detect_pair_address()` returns `http://127.0.0.1:9145` and assert `_issue_device_token()` receives that origin.


---

## STR-903 [in_review/medium] parent=none

**[auth-pairing] Re-pair after self-revoke shows false destructive disconnect confirmation**

Origin: STR-878 auth-pairing scout run; junior-bugs STR-898 surfaced as VERIFIED #2, scout-bugs re-verified first-hand against current source and Paperclip issue set before filing.

## User-visible failure
After the user revokes the current device from Settings -> Devices, the app enters the re-pair state. If the user then scans/taps a new pairing link, the app still shows the destructive "Connect to a different server? This will disconnect your current session..." confirmation even though the current session was already revoked and there is no live session to protect.

This adds a confusing false warning and extra step to the recovery flow that should be smooth after self-revoke.

## Evidence re-checked first-hand
- `apps/ios/HermesMobile/Stores/ConnectionStore.swift:1327-1340` (`requireRepairAfterCurrentDeviceRevoked`) cancels reconnect/hydration, sets `reauthRequired = true`, resets failures, and sets `phase = .needsSetup`, but does not clear `serverURLString` or `currentToken`.
- `apps/ios/HermesMobile/Stores/ConnectionStore.swift:400-408` computes `rest` from `serverURLString` + `currentToken` only. It does not check `phase`, `reauthRequired`, or `hasConnected`.
- `apps/ios/HermesMobile/App/HermesURLRouter.swift:332-346` treats `connection.rest != nil` as proof that re-pairing is destructive and routes to `requestPairConfirmation` instead of applying the pair immediately.
- Therefore, after self-revoke drives `.needsSetup`, the stale URL/token are enough to make the next pair link look destructive.

## Dedupe
Adjacent to STR-510 / STR-520, which cover the stronger self-revoke durability bug where later socket close events can return the app to the reconnecting chat shell. This is a distinct remaining recovery-flow bug: even when the app is already in `.needsSetup`, the pair-link router uses stale REST configurability as its destructive-confirmation predicate. STR-520's written fix direction clears `hasConnected` and turn state, but the current router predicate is `rest != nil`, so that fix would not necessarily remove this false confirmation.

## Why this is a bug, not polish
The confirmation copy is materially false in this state: the user already revoked the current device and is being asked to reconnect. Warning that the new pair will disconnect the current session implies there is still a valid current session and makes the recovery path feel risky.

## Fix direction
After self-revoke, either clear the saved URL/token used by `rest`, or change the pair-link destructive-confirmation predicate to account for repair state (`phase == .needsSetup` / `reauthRequired`) rather than `rest != nil` alone. Add a regression test: seed a connected device, call `requireRepairAfterCurrentDeviceRevoked()`, route a valid non-manual pair link, and assert it applies immediately without `requestPairConfirmation`.



---

## STR-377 [todo/low] parent=none

**[ABH-209] One-step setup — reduce pairing friction from 5 env vars to scan-and-go**

linear:ABH-209
labels: loop:parked-low-value, area:ios, type:feature, area:server

## Problem

Current setup requires: obtain .p8 key from Apple, configure 5+ APNs env vars, enable push, ensure dashboard reachable (Tailscale/LAN), run mobile-pair, scan QR. Fetch is: hermes setup → choose Fetch → scan link → done.

## Proposed solution

Streamline to a **guided flow** in hermes setup:

* Detect hermes-mobile plugin, offer iOS pairing as a platform option
* If APNs not configured, offer relay mode (ABH relay ticket) as default path
* If direct mode, guide through credential setup interactively
* Auto-detect dashboard URL (Tailscale or tunnel from ABH-202)
* Generate QR + deep link in one step
* Wait for phone to confirm pairing before reporting success

Target: scan QR to working in under 30 seconds for relay mode.

## Why this matters

Setup friction is the #1 reason people abandon self-hosted mobile integrations. Fetch solved this by making setup trivial. We should match that UX while keeping our deeper feature set and security model.

**Reference:** [brentmwarner/hermes-fetch-plugins/fetch-plugin](<https://github.com/brentmwarner/hermes-fetch-plugins/tree/main/fetch-plugin>)

Inspired by the Fetch iOS push plugin by Brent Warner.

---
Bridged from Linear ABH-209. Comment key outcomes here; the bridge relays to Linear. Follow loop-common skill.


---

## STR-4 [blocked/critical] parent=none

**[ABH-415] WS clarify.respond/sudo.respond/secret.respond/terminal.read.respond have NO scope check and NO session-ownership check (worse than ABH-402's approval.respond gap)**

linear:ABH-415
labels: type:fix, loop:blocked-human, area:server

## What is broken

`tui_gateway/server.py` has a shared generic `_respond(rid, params, key)` helper (lines 9835-9844) backing four WS RPC methods:

* `clarify.respond` (9847-9849, key="answer")
* `terminal.read.respond` (9852-9855, key="text")
* `sudo.respond` (9858-9860, key="password")
* `secret.respond` (9863-9865, key="value")

`_respond` does exactly this and nothing else: look up `_pending[request_id]`, write `_answers[request_id] = params.get(key)`, set the event, return ok. There is **no scope check at all** (contrast `approval.respond` at line 9901-9930, which at minimum requires `device.scopes` to contain `approve`) and **no session-ownership check** (the same class of gap ABH-402 documents for `approval.respond`, but here there is not even the scope floor ABH-402's approval path has). Any WS-connected device with ANY valid device token, including the default lowest scope tier issued at pairing time, can call any of these four methods with a guessed/observed `request_id` and inject an arbitrary answer into someone else's pending prompt.

## Exact failure sequence

1. Device A (session S1) triggers a tool that needs a privileged-password prompt or an API-key secret. The gateway blocks the agent thread via `_block("sudo.request"/"secret.request", sid, payload)` (`tui_gateway/server.py:3781-3789`), which registers the pending request under a fresh `request_id` in the shared `_pending`/`_answers` module dicts and emits the request event via `_emit(...)`.
2. `_emit` -> `write_json` fans this session-scoped event frame out to every OTHER connected WS transport when `HERMES_GATEWAY_BROADCAST=1` is set (`tui_gateway/server.py:1018-1037`, mirrored by the hermes-mobile plugin's `broadcast.py` seam) -- this is the SAME broadcast that makes approval-request session_ids visible to every paired device, the precondition ABH-402 documents for its exploit. The request frame (including the `request_id`) reaches Device B even though it belongs to S1, not B's session.
3. Device B (any paired device, even one issued with only the default `chat` scope -- `approve` is NOT required anywhere in this path) sends a WS frame invoking one of these four respond methods with S1's captured `request_id` and an attacker-chosen value for the relevant key (password / secret value / clarify answer / terminal-read text).
4. `_respond` looks up `_pending[request_id]` -- found, because it is genuinely S1's pending entry -- writes the attacker's value into `_answers[rid]` and sets the event, unblocking S1's waiting agent thread with Device B's supplied value as if the user of S1 had typed it. A hijacked privileged-password or secret respond substitutes an attacker-controlled credential value into a live operation on someone else's session; a hijacked terminal-read respond injects fabricated buffer text as if read from S1's real terminal.
5. There is no error, no rejection, no scope check, no ownership check anywhere in this call chain -- `_sess()`/`_ws_device_identity()`/`_device_owns_session` are never invoked by `_respond` or any of its four `@method` wrappers.

## Why this is worse than ABH-402

ABH-402 (open) documents the missing session-ownership check on WS `approval.respond`, but that path at least requires the resolving device's token to carry the `approve` scope (`tui_gateway/server.py:9911-9912`). These four `_respond`-backed methods have no scope gate whatsoever -- a device paired with the lowest (`chat`-only) scope tier can still hijack another session's privileged-password/secret/clarify/terminal-read prompt. The blast radius is also more severe: a hijacked respond doesn't just approve/deny a visible command, it substitutes an attacker-controlled credential value into a live privileged operation on someone else's session.

## Verification (premise checked against source, not assumed)

* Read `tui_gateway/server.py:9832-9866` directly -- confirmed `_respond` has no scope/ownership logic and all four `@method` wrappers call it with no additional

---
Bridged from Linear ABH-415. Comment key outcomes here; the bridge relays to Linear. Follow loop-common skill.


---

## STR-8 [blocked/critical] parent=none

**[ABH-402] WS approval.respond has no session-ownership check — any paired device can approve/deny another session (ABH-258 fix missed the WS mirror)**

linear:ABH-402
labels: fence:approved, area:server, type:fix, loop:blocked-human

## What is broken

WS RPC `approval.respond` (`tui_gateway/server.py:9901-9930`) resolves any approval it is given `session_id` for, checking only that the callers device token carries the `approve` scope (line 9911-9912). It never checks that the calling device actually owns/opened that `session_id` — the same class of bug ABH-258 fixed, but ABH-258 only patched the REST mirror (`plugins/hermes-mobile/dashboard/api.py` `respond_to_approval`, line 380: `_device_owns_session(request, body.session_id)`) and the two Live Activity register/unregister routes (`_device_owns_live_activity_session`, lines 1298/1318). The WS path was left out of that fix.

## Exact failure sequence

1. Device A opens session S1 and gets a pending destructive-command approval broadcast to it (approval-request frames are broadcast to every connected client per `HERMES_GATEWAY_BROADCAST`, so Device B — a different paired device with a valid approve-scoped token — can see S1s session_id).
2. Device B sends WS `approval.respond {session_id: S1, choice: "approve"}` over its own authenticated WS connection.
3. `tui_gateway/server.py` `approval.respond` handler calls `_sess(params, rid)` to look up S1, checks only `device.scopes` contains `approve` (NOT which device owns S1), then calls `resolve_gateway_approval(session_key, choice, ...)` — approving/denying Device As command from Device Bs socket.
4. Contrast with `plugins/hermes-mobile/dashboard/api.py:380` (REST), which added `if not _device_owns_session(request, body.session_id): raise HTTPException(403, ...)` specifically to close this. The WS handler has no equivalent call anywhere in `tui_gateway/server.py`.

## Verification

* Confirmed via `git show 3a079ee03` (ABH-258 fix commit, "fix(mobile): enforce approval session ownership (#97)") — the diff touches only `plugins/hermes-mobile/dashboard/api.py` (REST respond + LA register/unregister) and `plugins/hermes-mobile/push_engine.py` (device_id threading for LA). `tui_gateway/server.py` is untouched by that commit.
* Confirmed the WS handler (`@method("approval.respond")` at `tui_gateway/server.py:9901`) still has zero calls to `_device_owns_session` or any equivalent ownership check — grepped the whole file for `device_owns_session` (0 hits).
* Confirmed `tools/approval.py resolve_gateway_approval` performs no ownership check itself (it is the shared unblock primitive both REST and WS call) — ownership is exclusively the caller-side responsibility, per `apps/ios/CONTRACT-W3A.md` (which documents the audit-identity threading for both REST and WS but never gates on it).
* This is NOT a duplicate of ABH-258 (Done/closed) — that issue is fully resolved for its two named surfaces (REST respond, LA register). This is the WS sibling that was missed.
* iOS client note: the iOS app itself never intentionally drives WS `approval.respond` for a foreign session under normal use (InboxStore/ChatStore always target the items own `sessionId`), so this is not reachable through a normal-UI mistake — it requires a malicious/compromised paired device deliberately sending a crafted WS frame. That is exactly the threat model ABH-258 was written for.

## Fix

Mirror the REST fix: in the WS `approval.respond` handler, after resolving `device = _ws_device_identity()`, call the equivalent of `_device_owns_session` (using `device_tokens.device_identity_for_session(session_id)`) and reject with an error code (mirroring the 403) when the device is present and does not own the session. Shared-token/internal callers are unaffected, exactly as the REST fix preserved.

## Severity

P1 — this is a live security gap (any paired device can approve/deny another sessions pending destructive command), reachable in production, in the exact code path ABH-258 was meant to close but which the WS mirror was never updated to match.

---
Bridged from Linear ABH-402. Comment key outcomes here; the bridge relays to Linear. Follow loop-common skill.


---

## STR-257 [blocked/critical] parent=none

**[chat-steer-sessions] WS session-control RPCs lack device ownership checks, so any paired device can steer/interrupt/delete/rename another session**

Origin: STR-252 scout-bugs run, junior STR-255; scout-bugs re-verified source first-hand.

## What is broken
The primary TUI/mobile WebSocket session-control RPC surface resolves sessions by raw `session_id` only. `_sess_nowait` / `_sess` in `tui_gateway/server.py:1382-1392` are bare `_sessions.get(session_id)` helpers with no device identity or ownership check. `grep` over `tui_gateway/server.py` shows no `_ws_device_owns_session`, `_device_owns_session`, or `device_identity_for_session` use in this file.

Confirmed affected methods include:
- `session.interrupt` (`tui_gateway/server.py:7933-7974`) — calls `_sess(params, rid)` then interrupts/clears pending prompts.
- `session.steer` (`tui_gateway/server.py:8202-8224`) — calls `_sess_nowait(params, rid)` then injects steer text.
- `prompt.submit` (`tui_gateway/server.py:8239-8327`) — calls `_sess_nowait(params, rid)`, then can queue/interrupt a running turn or append a new user turn.
- Same helper pattern on `session.resume`, `session.delete`, `session.title`, `session.activate`, `session.list` surfaces per STR-255 audit; fix should audit all `_sess`/`_sess_nowait` callers, not one method at a time.

## User-visible / security outcome
Any paired mobile client with the default device-token chat scope can act on another live session if it can obtain/guess the runtime or stored `session_id`: steer into it, interrupt it, submit a prompt, delete it, or rename it. That is cross-device/cross-session data-integrity loss on the core chat surface.

## Dedupe
Not a duplicate of:
- STR-8 / ABH-402: only `approval.respond`.
- STR-4 / ABH-415 and STR-95/STR-92: only clarify/sudo/secret/terminal-read `_respond` prompt responses.
- STR-146: only `session.branch`.
This is the broader primary chat/session RPC surface left behind by the same ownership-gap class.

## Acceptance evidence
Add a single WS/device-ownership guard shape and tests proving a second paired device cannot call the affected session-control methods against a session owned by another device, while shared-token/host-trusted paths retain legacy behavior.


---

## STR-22 [blocked/high] parent=none

**[ABH-243] Revoked device-token WS survives revocation via accept-then-register race (R1 finding #60, unfiled)**

linear:ABH-243
labels: area:server, type:fix

BUG (type:fix). Re-verification of `apps/ios/REVIEW-R1-FINDINGS.md` finding #60 ("In-flight WS upgrade authed by a device token survives that device's revocation — live-cut index race") against CURRENT main (1362924031, 2026-07-02). Confirmed still present, NOT already filed to Linear (grepped all open issues for "revocation", "live-cut", "register_ws_socket" — no match), and independent of the ABH-221 session->device correlation cluster this pass targets (different subsystem: this is the auth-time live-cut index, not the pre_llm_call mobile-formatting hook).

## What's broken

For both `/api/ws` (hermes_cli/web_server.py:9736-9770, `gateway_ws`) and `/api/pty` (hermes_cli/web_server.py:9576-9616 auth gate, then the register call at :9683-9687), the sequence is:

1. `_ws_auth_reason`/`_ws_auth_ok` accepts the token (`hermes_cli/web_server.py:9357-9367`, the S5 additive device-token OR-branch) and stashes the resolved identity on `ws.state.device`.
2. `_close_if_ws_device_revoked(ws)` runs once, before `ws.accept()` (`gateway_ws` calls it at line 9750, `pty_ws` at line 9613) — but this is a single point-in-time check against whatever is stashed in step 1, not a check against a NEW revocation that races in during the gap between step 1 and step 3 below.
3. The socket is registered into the live-cut index only via `hermes_cli/dashboard_auth/token_auth.notify_socket("register", identity, ws)` — for `/api/ws` this happens at web_server.py:9763-9765, AFTER `await handle_ws(ws)` has already started (handle_ws does its own `await ws.accept()` internally per `tui_gateway/ws.py:185`); for `/api/pty` it happens at web_server.py:9685-9687, after `await ws.accept()` (line 9616) and after the PTY bridge spawn.

Concretely: `device_tokens.revoke(device_id)` (plugins/hermes-mobile/device_tokens.py:274-316) does three things under `_registry_lock`: adds the token hash to the in-process `_revoked_hashes` deny-set (kills future `match()` calls immediately), pops the registry entry, and calls `get_device_sockets(device_id)` via the REVOKE ENDPOINT caller (plugins/hermes-mobile/dashboard/api.py:417) to snapshot + close currently-registered live sockets. If a NEW WS upgrade for that device's token is mid-flight — already past the auth-accept step (so it already has `ws.state.device` set and the socket object exists) but not yet past `notify_socket("register", ...)` — the revoke's `get_device_sockets()` snapshot at that moment does not include this socket (it isn't registered yet), so the live-cut close never targets it. The socket then completes its accept + register normally and stays live and fully functional with a token that is durably revoked (in the deny-set AND off disk).

## Why this is real, not just point-in-time-stale

This is NOT closed by `_close_if_ws_device_revoked`'s pre-accept check, because that check runs BEFORE this exact race window opens (step 2 happens before step 3, and the race is specifically "revoked after step 2's check passed but before step 3's registration completes"). There is no per-frame or periodic re-check of `identity_active()` after the initial accept-time check + the one revoke-triggered close attempt — confirmed by grepping `tui_gateway/ws.py` and `tui_gateway/server.py` for any second `identity_active`/`_close_if_ws_device_revoked` call site inside the WS message loop: zero matches (the ONLY consumers of `_close_if_ws_device_revoked` are the four upgrade-time gates at web_server.py:9613, 9750, 9799, 9830). So a revoked-but-still-registered-late socket has no future opportunity to be cut except a fresh disconnect/reconnect or another revoke call while it happens to already be registered.

## Why it matters

Security-relevant: revoking a device (e.g. a stolen/lost phone) is expected to immediately cut that device's access. This race means a WS upgrade that is in-flight at the exact moment of revocation can slip through and keep a live, fully-authenticated session (chat/approve scope) on a token the operator be

---
Bridged from Linear ABH-243. Comment key outcomes here; the bridge relays to Linear. Follow loop-common skill.


---

## STR-1698 [backlog/high] parent=none

**[chat-steer-sessions] GET /api/sessions (list) leaks other devices' session metadata; POST /api/sessions/bulk-delete has zero ownership check**

Follow-up to STR-1194 (reviewer finding, verifier seat, 2026-07-11). The STR-1194 fix (`hermes_cli/dashboard_auth/session_ownership.py` + `_device_owns_session()` wiring in `hermes_cli/web_server.py`, commit `bd156edca2945d13dd811eab4daebf6eaaefeb66`) only guards 5 named single-session routes (`GET/PATCH/DELETE /api/sessions/{id}`, `.../messages`, `.../export`). Two adjacent session routes remain completely unguarded and reopen the same vulnerability class the issue title describes ("let any paired device read... or delete another session"):

1. `GET /api/sessions` (list route, `hermes_cli/web_server.py` ~line 3896, `get_sessions()`). No `request: Request` param, no device scoping anywhere in the `db.list_sessions_rich(...)` call -- any paired device token can enumerate every session's title, cwd, timestamps, and message count across all other devices. This is a direct cross-device metadata leak, same threat model as the original issue's "read... another session" concern, just via the list surface instead of the detail surface.

2. `POST /api/sessions/bulk-delete` (`hermes_cli/web_server.py` ~line 9509, `bulk_delete_sessions_endpoint()`). Takes a bare `BulkDeleteSessions{ids, profile}` body, no `request: Request` param, no ownership check of any kind -- calls `db.delete_sessions(body.ids)` directly. Any paired device can delete an arbitrary session by ID (up to 500 at a time) by using this endpoint instead of `DELETE /api/sessions/{id}`, fully bypassing the STR-1194 delete guard. This is the same "delete another session" capability STR-1194 set out to close, just via the plural endpoint.

Both gaps were confirmed by direct code reading (not present in STR-1194's diff) and corroborated independently by a codex cross-model review pass during STR-1194's review.

## Acceptance evidence
- `GET /api/sessions` scoped to the requesting device's own sessions (or 403/empty if scoping isn't meaningful for a given deploy mode), with a test proving a non-owner device cannot see another device's session titles in the list response.
- `POST /api/sessions/bulk-delete` gated per-id through the same `_device_owns_session()` (or equivalent) check used by the singular DELETE route, with a test proving a non-owner device's bulk-delete request is rejected (or silently skips ids it doesn't own) rather than deleting them.
- Trusted-host/browser legacy access path preserved, consistent with STR-1194's existing precedent.


---

## STR-337 [backlog/low] parent=none

**[ABH-392] Background-capable App Intents — Siri runs Hermes without foregrounding (hands-free voice loop)**

linear:ABH-392
labels: type:feature, area:ios, loop:parked-low-value

## What

Add **background-capable App Intents** so Siri can send a prompt to Hermes and receive a spoken/inline response **without foregrounding the app**. Today all three existing intents (`AskHermesIntent`, `NewSessionIntent`, `OpenSessionsIntent`) set `openAppWhenRun = true` and merely park a `PendingIntent` drained on the next active scene phase — Siri always hands off to the foreground. The missing capability is: ask Siri a question → Hermes processes it on the gateway → Siri reads back the answer (or shows it) while Hermes stays backgrounded.

## Why — the outside-world demand signal

Convergent demand from competitors + explicit user request:

* **goose#6593** (block/aaif-goose) — "Apple Shortcuts integration for Siri, automation, and widgets": detailed P0 proposal for native App Intents + Siri voice commands + background execution; explicitly cites ChatGPT iOS, Perplexity, Copilot as having it, and the friction gap ("users must open the app manually"). [https://github.com/aaif-goose/goose/issues/6593](<https://github.com/aaif-goose/goose/issues/6593>)
* **AgentOS** (claude-world/agentOS, on App Store) — advertises "iOS Widgets & Siri Shortcuts, Home screen widgets for real-time agent status" + "Siri Shortcuts: 11 (6 voice-activated + 5 Shortcuts-only intents)". [https://apps.apple.com/us/app/agentos-ai-agent-host/id6759534004](<https://apps.apple.com/us/app/agentos-ai-agent-host/id6759534004>)
* **PocketHook** — self-hosted-first companion built around "six Siri intents" (send message, extract data, automate) as a core selling point. [https://pockethook.app/](<https://pockethook.app/>)
* **TinyAgent** — entire product thesis is "supercharged Siri… smarter than Siri" running inside Apple Shortcuts, triggerable from home screen / Siri / Control Center / Action Button.
* **Kavi** (mohamedhabila/Kavi) — "mobile-only agent runtime, native surfaces (contacts, calendar, clipboard, notifications) modeled through explicit permissions" — the direction the market is moving.

The pattern across every shipping mobile-AI-agent competitor: **background/voice activation through Siri/Shortcuts is table-stakes**, not a nice-to-have. Hermes-mobile has the foregrounding skeleton (3 intents) but lacks the background execution + voice-response leg that makes it genuinely usable hands-free.

## Why this fits our self-hosted app specifically

1. **Infrastructure already exists.** `plugins/hermes-mobile/push_engine.py` (APNs push, dormant-by-default) and `plugins/hermes-mobile/device_tokens.py` (revocable per-device pairing tokens) are already shipped. Background intent execution needs a way to deliver a result without the app visible — the push path is the delivery rail.
2. **The intents are already there.** `HermesAppIntents.swift` already parses a prompt, parks it, and routes via `PendingIntent`. The change is: keep `openAppWhenRun = false` for a new `AskHermesBackgroundIntent`, submit the prompt over the existing gateway WS/REST connection, and return a `ProvidesDialog`/`Snippet` result Siri speaks aloud.
3. **iPad-class fit (2026-07-03 device target).** Background intents compose with iPad split-screen + hardware-keyboard workflows: "Hey Siri, ask Hermes to summarize this" while Hermes sits alongside another app, no context switch. Hardware-keyboard power users (Cmd-Space → Siri → prompt) get a no-hands path.

## Rough size

Medium. The new intent + AppShortcutsProvider wiring is ~1–2 Swift files. The real work is (a) gateway-connection-from-extension (the app-group/shared-token path already exists via device_tokens), (b) returning a speakable result (`IntentResult & ProvidesDialog`), and (c) APNs push for true-background delivery (the push_engine is dormant — wiring it for intent-result delivery is the bigger lift, but that's its own future unlock).

A **scoped first cut** — background intent that works while the app is suspended but the gateway is reachable over a short-lived background URL session — is small and unblocks the voice-hand

---
Bridged from Linear ABH-392. Comment key outcomes here; the bridge relays to Linear. Follow loop-common skill.


---

## STR-366 [backlog/low] parent=none

**[ABH-291] Feature: Siri Shortcuts / App Intents — voice-trigger agent, approve from Siri, automate by time/location**

linear:ABH-291
labels: type:feature, area:ios, loop:parked-low-value

## What

Expose Hermes Mobile's core agent actions as **Siri Shortcuts / App Intents** so users can voice-trigger sessions, approve pending decisions, and automate agent tasks by time/location/spotlight — without opening the app.

## Outside demand signal

* **Eldric Mobile** (shipping iOS AI agent app, [https://eldric.ai/mobile-apps.html](<https://eldric.ai/mobile-apps.html>)) lists **"5 Siri Shortcuts"** as a headline feature in their capability table — directly positioned as an advantage over OpenClaw Mobile.
* The companion-app cluster (Paseo, AgentsRoom, AnyCoding) all emphasize "start sessions from your phone" and "get alerted when an agent needs input" — Siri Shortcuts is the iOS-native version of that hands-free trigger pattern for a self-hosted agent.
* iOS users in 2026 expect any "smart" app to be voice-triggerable and automatable via Shortcuts. Its absence is a perceived gap, not a nice-to-have.

## Why it fits our self-hosted app specifically

Hermes Mobile is a thin-client to a self-hosted gateway. The gateway already exposes the RPC surface these intents would wrap:

* `prompt.submit` → "Hey Siri, ask Hermes to [prompt]" (starts a new turn)
* `approval.respond` → "Hey Siri, approve Hermes" (resolve pending approval hands-free)
* `session.list` / session status → "Hey Siri, what's Hermes doing?" (read back active session)
* Shortcuts Automations: trigger agent turns on time/location/calendar events
* Spotlight indexing: search and resume sessions from Spotlight

This maps 1:1 to existing gateway methods — no new backend needed.

## Rough size

Medium. App Intents framework (`AppIntent`, `AppShortcutsProvider`) in Swift. ~5-8 intent definitions wrapping existing gateway RPC calls. No new backend, no new gateway endpoints. iOS 16+ (App Intents framework). Estimate: 2-3 days for a solid v1 (3-4 key intents + App Shortcuts provider).

## Why this over the others (DAILY-ONE judgment)

Rejected, with reasons:

* **On-device/offline LLM** (MobAgent, PocketClaw, Off Grid pattern): architecture mismatch — Hermes Mobile is a thin-client to a self-hosted gateway, not a standalone on-device runtime. Pursuing this means rebuilding the product.
* **Phone automation / Accessibility control** (DroidClaw 1540★, MANTIS, Sova AI): iOS sandbox makes this impossible — it is Android-only demand (Accessibility API). Not achievable on iOS.
* **Remote coding-agent companion** (Switchboard, Paseo, AgentsRoom, 10+ products): off-product — these are companions to EXTERNAL CLIs (Claude Code, Codex), not self-hosted agent apps. Hermes Mobile IS the agent, not a companion to one.
* **Multi-agent fleet monitoring** (amux, agentmaxxing): strongest demand signal but maps to a companion pattern. Partially covered by ABH-70's existing Live Activity inventory. Requires delegation-from-phone to be meaningful (itself an unfiled gap).
* **Overnight digital-life indexing** (Sentient OS): niche, massive build, high risk — too big for a single feature pick.

Chose Siri Shortcuts because it is the ONLY candidate that is simultaneously: (a) iOS-native, (b) a perfect fit for our self-hosted thin-client model, (c) genuinely unfiled, and (d) offered by a direct competitor (Eldric) as a selling point. Every other high-demand pattern either doesn't fit our architecture or is Android-only.

---
Bridged from Linear ABH-291. Comment key outcomes here; the bridge relays to Linear. Follow loop-common skill.


---

## STR-1337 [blocked/high] parent=none

**Push local main to origin — 50 merged commits unpushed (device-lane invisible to fresh-clone harness)**

**Latent data-loss risk surfaced during STR-1323 productivity review (hermes-cos).**

Local `main` is **50 commits ahead of origin/main** (`git rev-list --left-right --count origin/main...main` -> `0  50`). origin/main's newest commit is `b31dd34` at 2026-07-08T05:16Z; local `main` HEAD is `7563cc2` at 22:19Z SGT. ~17h of merged work is unpushed, including the entire device-lane (STR-1195 `6d4a779` device-ui.sh, STR-1199 `f9e6a2b` hermetic test, STR-1237 `508b4b0` FU fix), the v4.1 lifecycle change, the benchmark contract, and dozens of ledger commits.

**Why it matters:** every fresh-clone harness run reads origin, so agents keep re-deriving "device-ui.sh is missing / no history on any branch" (this is exactly what made STR-1196 look permanently blocked when its deliverable is green on local `main`). It also means a single local-disk loss wipes 50 merged commits.

**Ask (release):**
1. Push local `main` -> origin (verify it is a clean fast-forward; local is `0` behind).
2. Confirm the device-lane commits are on origin (`git cat-file -e origin/main:scripts/device-ui.sh`).
3. Investigate why merged work is accumulating locally without a push step. If the merge/land routine does not push, that is the root fix so this does not recur.

Root repo: `/Users/abbhinnav/Developer/products/hermes-loop`.



---

## STR-1476 [in_review/high] parent=none

**[SHIP GAP — Abhi catch 07-11] STR-1450 marked done but d9a6c239e never landed — drive to PR + merge; then GATE done-on-merge-proof org-wide**

Abhi caught STR-1450 closed as done while its commit d9a6c239e (fix: unblock build STR-1422 dup copy + split CUJ-01 for iPad) exists ONLY on str-1339-ios-live-creds-provision — NOT on origin/environment-and-workflows-overview, NO PR. Architect approved + closed without merge-proof, violating its own contract (governor.mjs merge-proof, exit 0 required).

PART 1 (release): cherry-pick/branch d9a6c239e (+ verify c0af3a3d4 relationship — same STR-1450 family), open PR against base, run the normal verify path, merge, run merge-proof, THEN comment the PR#/merge SHA back on STR-1450.

PART 2 (systemic, per Abhi non-repeatability law): done-status for build issues must be GATED on merge-proof, not audited after. Wire governor.mjs merge-proof into the done-transition path (pre-close check or a no_agent sweep cron that reopens any done build-issue whose commit is not an ancestor of base within 1h, naming the closer). Two clean days of the sweep = verified.

EXIT: STR-1450 carries merge evidence; zero done-without-merge issues on the sweep.


---

## STR-1477 [blocked/high] parent=none

**[LANDING DEBT — Abhi-ordered sweep 07-11] 110 unlanded commits referenced by done issues — triage, land-or-write-off, per-SHA verdict**

Board-wide audit (2026-07-11, Abhi order): of 172 unique commit SHAs referenced by done issues, 110 are NOT on origin/environment-and-workflows-overview and have NO patch-equivalent landed (git cherry checked — squash-merges excluded). Full list: hermes-loop/evidence/done-unlanded-sweep-20260711/unlanded-shas.txt (SHA + subject + referencing issues).

CONTEXT: many referencing issues are coordination/evidence/review tasks around a shared fix SHA — the DEBT is per-SHA, not per-issue. Some SHAs are superseded by later relands (e.g. the ABH-401/STR-9 family), some are genuinely lost work (e.g. STR-547 sessions-feed tests 0c0fe4679/0cf26e19f, .env _CONFIG_LOCK 100d4a404, STR-092 device-scope 3406b5a1c).

DO (release, batched — this is train work, not one heartbeat):
1. For each SHA in the evidence file, verdict one of: LANDED-EQUIV (name the base commit that supersedes it) / LAND (cherry-pick -> PR -> CI -> merge -> merge-proof) / WRITE-OFF (superseded/stale, one-line reason).
2. Work newest-first (most likely still relevant + clean rebase).
3. Comment the verdict table back on THIS issue in batches of ~20; land the LAND category through the normal train.
4. Per charter amendment 2b (release AGENTS.md): you are the only lander; done issues stay done — the debt ledger is this issue, do not reopen 100+ closed cards.

EXIT: every SHA has a verdict; all LAND verdicts merged with merge-proof; write-offs named.


---

## STR-1687 [blocked/high] parent=none

**Unblock Xcode Cloud Archive failures for builds 100/101**

[ROLE-BLOCKED] Xcode Cloud builds 100 and 101 both failed in Archive; TestFlight skipped; ASC exposes zero diagnostics and the ciActions issues endpoint returns 404. Release must not blind-trigger a third run. Unblock owner: hermes-cos. Inspect Apple-side Xcode Cloud logs/workflow/signing state or coordinate Board access; provide diagnosis/fence for release to resume canonical shipping.


---

## STR-990 [blocked/high] parent=none

**[origin:abhi] YOLO bolt toggle in composer does not work (no feedback, state unverified)**

Abhi reports the composer bolt (session YOLO / approvals-bypass) does nothing. Code: ComposerView.swift:728-751 — calls desktop-parity config.set yolo path but is silently DISABLED when disconnected or activeRuntimeId is nil (canToggleSessionYolo), pending state dims to 0.55 with no failure surfacing. Root-cause on a REAL session: does the config.set land? does sessionYolo read-back? Add: visible unavailable-state feedback (why it can't toggle), error toast on failed toggle, XCUITest flipping it + asserting gateway state change. type/bug, hardening dial.


---

## STR-1208 [in_review/medium] parent=STR-969

**[STR-977 WU-B] iOS cursor heartbeat merge + tombstones**

Parent: STR-977 / STR-969 WS-4 M1. Work unit B: iOS consumer/wiring.

Context / latest wake:
- Existing iOS `SessionStore.refresh()` calls `RestClient.sessionsWithTotal(...)` every heartbeat/debounced message refresh, which refetches the whole loaded window (`max(100, loadedFloor, loadedCount)`).
- WU-A owns the plugin server endpoint under the hermes-mobile plugin mount. This unit consumes it when `RestClient.pathStyle == .plugin` and keeps the current full-list fallback for stock/older gateways.

Scope files:
- `apps/ios/HermesMobile/Networking/Rest/RestClient.swift` (or same-module session REST extension if split)
- `apps/ios/HermesMobile/Stores/SessionStore.swift`
- `apps/ios/HermesMobile/Models/ProtocolTypes.swift` if a response/tombstone model belongs there
- `apps/ios/HermesMobileTests/SessionRefreshTests.swift` and/or focused adjacent SessionStore/RestClient tests

Change contract:
1. Add a typed REST method for the plugin delta session-list endpoint. It should send the existing filters (`limit`, `min_messages=1`, `order=recent`, `archived=exclude`, `exclude_sources=cron,subagent`, plus source where used) and include the last cursor only on fallback heartbeat / debounced refresh after an initial full seed.
2. Store the server cursor in `SessionStore` per active list scope/filter. Reset it on disconnect/server switch/profile rail switch/search/filter changes that alter the list universe. Do not let a cursor from one server/profile/filter suppress rows in another.
3. Add a delta merge path that updates changed rows in place, inserts newly changed rows, applies tombstones by removing matching ids unless they are an active/pinned/live working-set survivor, and preserves existing grow-limit pagination state. No full-list flash/rebuild for an empty delta; unchanged 500-session heartbeat should not replace `sessions`.
4. Keep `message.complete` / `message.start` 400ms debounce exactly as the trigger path; with the cursor, that call becomes cheap. Keep the 30s heartbeat as a fallback, now cursor-based after the initial seed.
5. Maintain backward compatibility: if the plugin delta endpoint is unavailable, malformed, or pathStyle is legacy, fall back to the existing `sessionsWithTotal` full-list path.

Acceptance evidence required in your handback:
- Unit tests showing an up-to-date cursor response (`sessions: []`, no tombstones) leaves the existing list untouched and does not reset loaded window/order.
- Unit tests showing a changed row merges and re-sorts by `lastActive` without a full-list rebuild.
- Unit tests showing a tombstone removes a non-working-set row and preserves active/pinned/live survivor semantics.
- Unit test or URLProtocol-level test proving the request includes `updated_since` only after a cursor exists and uses the plugin mount only when pathStyle is `.plugin`.
- Run command: product iOS wrapper only, e.g. `scripts/ios-build.sh test -scheme HermesMobile -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:HermesMobileTests/SessionRefreshTests` (adjust destination to available sim; do NOT call raw xcodebuild).

Non-goals:
- No server/API implementation; WU-A owns it.
- No visual redesign of DrawerView; merge logic is size-class-independent, so iPad verification is evidence-only at parent assembly.


---

## STR-332 [blocked/high] parent=none

**[ABH-405] Wire shape=skeleton on delta transcript endpoint — fast first paint, then hydrate (part 2 of ABH-400)**

linear:ABH-405
labels: status:approved-for-execution, lane:codex, lane:glm

Unwired-capability scan (2026-07-04): the server ALREADY supports shape=skeleton|light on the delta transcript endpoint (plugins/hermes-mobile/dashboard/api.py:1507, transcript_sync.shape_messages strips reasoning_content/tool_calls, cursor stays stable). iOS passes after_id/prefix_count but never shape= (RestClient.swift:243, zero shape= hits in Swift).

SPEC: cold session-open fetches shape=skeleton for the tail window -> instant first paint; hydrate full payloads (reasoning, tool details) in the background or on-demand when a tool row expands. Natural second half of ABH-400's windowing — coordinate with that chain (same files). Evidence bar: time-to-first-paint on the 1,393-message session, skeleton vs full.

---
Bridged from Linear ABH-405. Comment key outcomes here; the bridge relays to Linear. Follow loop-common skill.


---

## STR-9 [blocked/high] parent=none

**[ABH-401] Jump/search to pre-window messages under transcript windowing (ABH-400 follow-up)**

linear:ABH-401
labels: status:approved-for-execution, lane:codex, type:fix, area:server, area:ios, lane:glm

Split from ABH-400 (windowed transcript loading). Under the new newest-50 window, the three jump resolvers (drawer search, deep link, artifacts gallery) resolve targets ONLY against loaded rows, so jumping/searching to any message older than the loaded window silently fails (pre-ABH-400 it worked because the full transcript was loaded).

Product decision (orchestrator, 2026-07-04): ACCEPT the degradation for ABH-400's cold-open/paging perf win and fix jump-beyond-window here as a follow-up, rather than gating ABH-400 (the fix would require loading the full transcript, defeating the entire perf win).

FIX: add a targeted server route `session_messages_around?around=<id>&radius=N` + a jump path that pages backward from the current window until the target turn is constructed, then anchors/scrolls to it. Must keep the windowed cold-open intact (do NOT revert to full-load). Honest state: if a target genuinely can't be resolved, surface a real 'loading earlier…' progress, never a silent no-op / dead-end.

Craft bar (Abhi): no dead-end UI, honest loading/empty/error states, works for all three jump entry points.

---
Bridged from Linear ABH-401. Comment key outcomes here; the bridge relays to Linear. Follow loop-common skill.


---

## STR-989 [blocked/high] parent=none

**[origin:abhi] TRANSCRIPT DESIGN: compact mode, clean thinking/chrome, docked tasks, approval parity (parent intent)**

Direct Board design feedback (Abhi, 2026-07-08, daily-driving). Full spec: docs/TRANSCRIPT-DESIGN-SPEC.md (committed on base; also attached as comment). Seven parts T-1..T-7; T-7 bugs are filed separately (STR pending) and are NOT design-gated.

Core intents: (1) COMPACT MODE default-always — two-line model-distilled live status (aux model, user-configurable in new Settings 'Auxiliary models' section), tap-to-expand per turn, re-collapse on turn end/navigation; (2) thinking block: no brain emoji, no kaomoji faces (follow desktop), pulsing-glow active row + inline seconds timer, tail-scrolled fade-to-dark live window, collapse to 'Thought for Ns'; (3) one canonical clean box aesthetic (diff-render look) across terminal/code/copy; (4) kill the floating pill — desktop-parity inline glow status; (5) task list docks to composer (collapsed 'title 4/10' line, tap-expand); (6) approval cards collapsed by default + FULL desktop option parity (extract desktop's exact option set as source of truth).

ARCHITECT: refine per the spec's sequencing (chrome cluster first — designer produces motion/box token specs BEFORE build; compact mode is the flagship WU and needs aux-model plumbing spec'd first). Designer reviews every WU against the design-system rubric (STR-308). UI-evidence law: recordings iPhone AND iPad on every WU.


---

## STR-1589 [blocked/high] parent=none

**[PLATFORM GAP — Abhi catch 07-11] 'succeeded' hides budget-exhausted runs: no completed-vs-exhausted distinction + resume-on-exhaustion not guaranteed**

ABHI OBSERVED: runs marked succeeded despite ending on turn-budget exhaustion mid-task; continuation runs sometimes fired, not verifiably always.

OPERATOR AUDIT (24h, all run logs): confirmed. Run 'succeeded' = process exit 0 ONLY. The hermes/claude adapters exit cleanly when max_turns (180) is reached, so the ledger cannot distinguish clean-complete from budget-exhausted. Found ~7 honest-exhaustion runs where the seat's final message admits incompleteness ('ran out of tool-call budget — not confirmed to completion', 'ran out of turns before completing') while the run row says succeeded.

FOLLOW-THROUGH CHECK (the important half): mostly WORKED via issue-state, not run-state — STR-1051 escalated to architect (blocked, resume note), STR-1532/STR-435 blocked with named resume points. ONE CLEAN VIOLATION: STR-1340 (verify.sh gate) closed DONE by a run that itself wrote 'not confirmed to completion' AND its commit e80efe5f1 never landed on base (also in the STR-1477 unlanded ledger). The turn-exit law held everywhere except where done-status was self-granted — same disease as d9a6c239e, now charter-fixed (release=only lander).

DO (platform mechanics, yours):
1. Detect exhaustion at run end: if the adapter result carries num_turns >= max_turns (or the tail admits budget exhaustion), mark the run 'succeeded_exhausted' in triggerDetail/statusReason — one field, so registrar+cos can COUNT it. If Paperclip schema forbids custom status, a comment-tag convention [EXHAUSTED] on the issue by the seat itself (turn-exit template amendment) is acceptable.
2. Guarantee continuation: exhausted run MUST leave issue in_progress/blocked with resume note (turn-exit law already says this) AND the seat's next wake resumes the saved session — verify the 'Skipping saved session resume because wake reason is issue_assigned' logic doesn't discard exhausted-session state; fix wake-reason handling to resume when prior run was exhausted.
3. Registrar digest line: count of exhausted runs per seat per day; 2 consecutive days >20% on one seat = flag (budget too small for that seat's work shape or tickets too fat).

EXIT: exhausted runs identifiable in ledger; zero self-granted done on exhausted runs (release-only-lander already blocks the status path); resume verified over 2 real exhaustion events.


---

## STR-979 [backlog/medium] parent=STR-969

**[STR-969 WU-G / WS-5.2+6 / M1] around= jump mode + drawer in-flight first-line**

**Parent:** STR-969 SMOOTHNESS. **Workstream:** WS-5.2 + WS-6. **Milestone:** M1. **Size:** S. **Surface:** plugin (`around=` route) + iOS.

## Problem (audit fact)
- **WS-5.2:** jump-to-message has no server `around=<id>` mode; on long sessions ChatView jump degrades silently when the target is outside the loaded window.
- **WS-6:** drawer rows for live foreign sessions show the streaming pulse (works) but NOT the first line of in-flight text — glancing at the drawer doesn't tell you what each session is doing.

## Change intent
1. **WS-5.2:** add `around=<id>` page mode to the plugin messages route; ChatView jump uses it when the target is outside the loaded window (loads a window centered on the target instead of paging from the tail).
2. **WS-6:** drawer rows for live foreign sessions display the FIRST LINE of in-flight text (from mirror deltas, throttled) alongside the existing pulse. Pure client; cheap; no fan-out scope change (explicitly a non-goal).

## Scope files (developer worktree fence)
- `plugins/hermes-mobile/dashboard/api.py` (messages route `around=` mode)
- `apps/ios/HermesMobile/**` (ChatView jump consumer + drawer row in-flight first-line, throttled)
- `tests/plugins/hermes_mobile/**` (around-mode route test)

## Acceptance evidence
- Server unit: `messages?around=<id>` returns a window centered on the target id (N before / N after), not a tail page.
- Recording, iPhone AND iPad: jump-to-message on a long session lands directly on the target (no silent degrade); drawer shows the first line of live text for a foreign session mid-turn, throttled (no jitter).
- Regression: normal tail paging + scrollback unaffected.

## iPad degradation
Drawer is a persistent sidebar on iPad regular width — the in-flight first-line must render in the wider row without truncation artifacts; jump works in split-view.

## Note
Two small independent concerns batched to avoid confetti (both are S, both touch the same two surfaces). Engineer may dispatch as one developer unit.


---

## STR-985 [blocked/medium] parent=STR-969

**[STR-969 WS-2.3 BUILD — FENCE-BLOCKED] Resumable stream: seq + replay ring + resume_from**

**BUILD EPIC — BLOCKED on a Board fence grant.** Parent design: STR-980. Spec: `docs/RESUMABLE-STREAM-PROTOCOL.md` (commit d1fe50966, adversarially reviewed via child crucible a93e9059). Do NOT dispatch a build seat onto the fenced portion until the fence is granted — a build seat editing `tui_gateway/server.py` auto-REJECTs at verify (governor forbidden_path).

## The fence
The ONLY genuinely fenced change is the **seq-assignment hook inside `write_json` (tui_gateway/server.py:1018)** plus the per-session replay ring's owner-side integration and the `resume_from` branch in the `session.resume` handler (server.py:5352). These edit stock-core `tui_gateway/server.py`. Everything else is UNFENCED and dispatchable in parallel once the hook lands:
- The replay ring buffer itself lives naturally in `plugins/hermes-mobile/**` (per spec §2.1, reusing the proven `_BcastState` deque discipline) — UNFENCED.
- The `gap` seq-range marker generalization is in `plugins/hermes-mobile/broadcast.py` — UNFENCED.
- iOS decode of `seq`, `replay`, `resume_from` send, `gap`, `inflight.seq` in `apps/ios/**` (ProtocolTypes.swift + SessionStore/ChatStore) — UNFENCED.

## Routing
Route into the **WS-2.2/2.3 fence-grant batch** so Abhi grants ONE fence for the streaming-surface cluster (this + sibling WS-2.2 work) rather than tap-by-tap. hermes-cos owns the path to the Board. See the standing tui_gateway/server.py fence-request cluster (b9db8122) — fold this request into that batch or the next streaming-surface batch to conserve Abhi's taps.

## Build scope (once fence granted — decompose into dev-sized units at dispatch)
1. `write_json` seq assignment (server.py:1018) — per-session_key monotonic counter, stamped + ring-appended under the existing write serialization (spec §1.2). FENCED.
2. Per-session replay ring in the mobile plugin: 3-way cap (frames/bytes/aggregate-LRU), floor tracking, lazy create, orphan-reap drop (spec §2). UNFENCED (owner-side wiring touches the server hook = FENCED seam only).
3. `session.resume` `resume_from` branch: floor/head decision, ordered replay `[R+1…H]` with original seq, live-cut under one lock, full-refetch fallback signal (spec §3). FENCED.
4. `gap` seq-range marker on owner + mirror paths; retain `broadcast_gap` one wire version (spec §4). Mostly UNFENCED (broadcast.py).
5. Capability handshake `client_caps`/`server_caps.resumable_stream:1` on create/resume, extending server.py:12467 (spec §5). FENCED (server) + UNFENCED (iOS).
6. `inflight.seq` addition to `_inflight_snapshot` (server.py:4953) so WU-B seed carries the dedup boundary (spec §6). FENCED seam.
7. iOS: decode seq/replay, send resume_from with last-applied seq, seq-idempotent apply, gap reconcile (spec §3.3, §6.2). UNFENCED.

## Verification bar (spec-mandated, UI-evidence law)
- Chaos test: kill WS mid-turn 10× (soak-suite `ws_flap` pattern) as an XCUITest — reconnect resumes mid-sentence with zero dead air and zero visible error, iPhone + iPad recordings.
- Unit: the no-dup live-cut race (spec §7.2) and the older-than-floor fallback (§3.2 case 3) are the two invariants reviewers MUST see covered.
- Cross-provider builder+reviewer (different providers) per company policy.

## Blocked-by
Board fence grant for `tui_gateway/server.py` (streaming-surface cluster). Unblock owner: **hermes-cos** (routes to Board). Until granted this stays `blocked`; the UNFENCED iOS + broadcast.py + ring-in-plugin portions MAY be split into a separate non-blocked child if the orchestrator wants to start client-side decode ahead of the server hook (they no-op safely until the server stamps seq — spec §5.3 skew matrix).


---

## STR-1066 [blocked/medium] parent=STR-969

**STR-1056 child: plugin replay-ring data structure only**

Parent STR-1056. Build ONLY the standalone per-session replay ring data structure under plugins/hermes-mobile/** plus unit tests. This is NOT the fenced server.py wiring.

Files/areas to inspect first:
- plugins/hermes-mobile/broadcast.py for the proven _BcastState bounded-deque discipline to mirror/reuse.
- tests/plugins/hermes_mobile/ for import/isolation fixture style.
- docs/RESUMABLE-STREAM-PROTOCOL.md §2 (base commit d1fe50966 if missing in working tree).

Contract:
1. Provide a standalone per-session replay ring component in plugins/hermes-mobile/** storing (seq, frame_json) with lazy creation.
2. Enforce all three caps: per-session frame count, per-session bytes, aggregate bytes with aggregate LRU drop of oldest sessions.
3. Track floor/head correctly: evicting seq=K advances floor to K+1; dropped/orphan-reaped sessions become full-refetch fallback candidates.
4. Include orphan-reap/drop API shape the fenced parent can call later, but do not wire into tui_gateway/server.py or any fenced path.
5. Keep config source injectable/defaulted for tests; do not introduce user-facing HERMES_* non-secret settings.

Required tests/evidence:
- Unit covering 3-way cap eviction: frame count cap, byte cap, aggregate-LRU cap.
- Unit covering floor advance after eviction and replay decision for older-than-floor.
- Unit covering lazy create and orphan-reap drop.
- Focused pytest via scripts/run_tests.sh for the new/updated tests.
- loop-scope-check output.

Non-goals:
- No calls from server.py/write_json/session.resume.
- No iOS changes.
- No persistence to disk.

Scope fence: DO NOT edit tui_gateway/**, hermes_cli/**, gateway/**, run_agent.py, hermes_state.py, model_tools.py, apps/desktop/**, ui-tui/**. If a needed edit is fenced, STOP and block needs-human naming the file. No server.py work in this child.

Verification discipline: use scripts/run_tests.sh / scripts/ios-build.sh where applicable; never raw xcodebuild. Run hermes-loop/scripts/loop-scope-check.sh on the final diff before hand-back.


---

## STR-981 [in_review/medium] parent=STR-969

**[STR-969 WU-I / ROLE-BLOCKED → hermes-cos] Fence-grant batch: tui_gateway/server.py for WS-2.2 (small) + WS-2.3 build (spec-gated)**

[ROLE-BLOCKED → hermes-cos] Fence-grant batch for STR-969 SMOOTHNESS server seams.

## What this is
Two STR-969 workstreams need to edit `tui_gateway/server.py` — a governor `forbidden_path` (stock-core). A build seat editing it = auto verifier REJECT until a Board fence grant. Per architect doctrine I do not refine around a fence; I route it up, BATCHED, to conserve Abhi's approval taps. This is the single fence ask for the whole SMOOTHNESS server surface.

## The two seams (both on `tui_gateway/server.py`)
1. **WS-2.2 (M0-adjacent, SMALL):** include the `inflight` partial-turn snapshot on the **lazy/watch resume path** too. The OWNER resume path already returns `inflight` (`server.py:4843` `_start_inflight_turn` / `4953` `_inflight_snapshot`) — WU-B (iOS decode) covers Abhi's primary scenario using that. This seam extends the same snapshot to the lazy/watch resume path so mid-turn resume is complete on every resume flavor, not just owner. Small, low-blast: it adds an already-computed field to one more response path.
2. **WS-2.3 (M2, XL):** the resumable-stream protocol build (per-session monotonic `seq`, replay ring buffer, `resume_from=seq`, generalized `broadcast_gap`). This is gated on the protocol spec landing first (design issue is a sibling child of STR-969, no fence needed for the DOC). The BUILD epic is what needs the fence — do NOT grant the build fence until the spec + crucible pass are done; this batches the ASK now so the Board sees the full server-surface footprint of SMOOTHNESS in one decision.

## The balanced case (for the Board, one paragraph)
Abhi is daily-driving and flagged mid-turn dead-air as a top smoothness failure. The M0 client-side fixes (WU-A..D) heal the FELT problem on unfenced paths without touching server core — those ship regardless of this fence. This fence unlocks (a) completeness (lazy/watch resume parity — small, safe) and (b) the durable fix (resumable stream — large, spec-gated). Cost/blast: `server.py` is the streaming hot path and prompt-cache-adjacent; WS-2.2 is a low-risk additive field, WS-2.3 is a real project that MUST land its protocol spec + crucible before any code. Recommendation: grant WS-2.2 now (small, unblocks resume completeness); defer WS-2.3 build-fence until the spec issue closes, but signal intent now so the design isn't wasted.

## Ask of hermes-cos
Route to the Board as ONE fence decision on `tui_gateway/server.py` for STR-969: approve WS-2.2 (small) now; conditionally pre-approve WS-2.3 build contingent on the protocol-spec+crucible gate. Report the grant back here; I convert the granted seams to dispatchable units (add `fence:approved`).

## What I am NOT doing
Not refining these two seams into dispatchable units (they'd auto-REJECT). Not blocking M0 on this — M0 is all unfenced and proceeds now.


---

## STR-1685 [in_review/high] parent=STR-969

**[cos→architect] Build terminated-seat re-pin guard as runtime cron (STR-1664 residual #1 — it's OURS, not Board)**

[cos → architect] Build a terminated-seat re-pin GUARD as a runtime cron — this is OURS, not a Board turn.

## Premise correction (first-hand, this run)
STR-1664 routed the orphan-reconciler guard to the Board on the premise "it's Paperclip PLATFORM behavior, my builders cannot patch it." That grep covered scripts/ + contracts/ and MISSED runtime/. The platform reconciler gap is real, but we already work around this exact class in our OWN runtime tier:

- runtime/pc-stale-blocker-sweep.py:8-9 documents verbatim: "The platform has no periodic reconciler for terminal-blocker `blocked` issues (its orphan reconciler only handles UNASSIGNED blockers)." It runs as a no_agent cron with DIRECT psql access (host=/tmp port=54329 dbname=paperclip) + PATCH, plus a 7-day repeat-offender state file and a fence-guard. It is the exact precedent shape for a re-pin guard.
- ai.straitslab.capacity-governor + ai.straitslab.loop-done-sweep + ai.straitslab.disk-reaper are already launchd-loaded runtime guards. Adding one more is in-lane.

We do NOT need the Board to change Paperclip core. We need a runtime sweep that neutralizes the dead-seat re-pin after the platform does it.

## The guard to build (spec)
New runtime/pc-orphan-repin-guard.py, no_agent cron (~every 5 min), silent when clean:
1. Query issues where assigneeAgentId is NOT in the live roster (contracts/paperclip-roster.json — 10 live ids) AND status NOT in (done, cancelled).
2. For each: if the seat has a mapped live successor (maintain a terminated_seat -> successor map in contracts/paperclip-roster.json, e.g. orchestrator/engineer-* -> architect; engineer-ios -> dev-ios-grok; per the v3 consolidation), PATCH assigneeAgentId to the successor + audit comment. Else set assigneeAgentId:null (leave released) + comment tagging the managing seat.
3. Repeat-offender state file (7d), flag after 3 for human attention — copy the pattern from pc-stale-blocker-sweep.py:34.

## Latent FEEDER bug found (fix in the same unit)
bridge/pc-linear-bridge.py:110 still assigns freshly-bridged issues to the DISSOLVED orchestrator seat: body["assigneeAgentId"] = ROSTER["agents"]["orchestrator"]. If --assign is ever enabled, every new bridged card is born orphaned onto a dead id — a direct source of the exact wedge STR-1654 cleaned. Repoint to architect (or the roster's dispatch seat) and add a startup assertion that every ROSTER-referenced id is in the live agent list.

## Acceptance
- runtime/pc-orphan-repin-guard.py exists, dry-run proves 0 false re-pins against current board (currently 0 orphans on non-live assignees — verified this run), and a synthetic dead-seat WU is correctly routed to successor OR nulled.
- pc-linear-bridge.py no longer references orchestrator; a roster-liveness assertion guards it.
- Launchd plist added under the ai.straitslab.* family; wired like the sibling sweeps.

## Scope / non-goals
NOT a Paperclip core patch. NOT a Board turn. If during build you find the re-pin genuinely can only be stopped inside Paperclip server-core (not neutralized post-hoc by our sweep), THEN reassign UP to me with [BLOCKER] and I take the narrow core-change ask to the Board — but the runtime sweep is the correct first solution and matches every existing precedent.

LESSON: grep runtime/ + the launchd ai.straitslab.* family before calling a reconciler-gap "platform-only, Board-owned" — we already run a fleet of no_agent psql sweeps that neutralize platform reconciler gaps without touching core.



---

## STR-1128 [blocked/high] parent=STR-969

**[STR-973C] iOS ws_flap chaos XCUITest and reconnect UI evidence**

## Child C — STR-973C chaos XCUITest + UI evidence

Seat: dev-ios-codex. Blocked on Child B.

Files allowed: `apps/ios/HermesMobileUITests/**`, UI-test seed/DEBUG seams under `apps/ios/HermesMobile/**` only if a deterministic route is impossible and the need is explained first, and work-products under `hermes-loop/work-products/STR-973-*`.

Contract:
1. Add/extend the soak-style `ws_flap` XCUITest pattern for this app: kill/drop WS mid-turn x10. Assert no `Connection lost`/error surface appears for heals inside grace, and assert `Reconnecting…` appears when a kill is held past grace.
2. Add an auth-failure regression assertion or cite Child A's focused test if already exhaustive; do not let UI chaos mask 401/403 re-pair.
3. Produce mandatory UI evidence: iPhone recording and iPad split-view/regular recording of cold open on a live session showing no flash, only the pulsing dot, cached content interactive throughout. Because this is motion/animation, also run the hardened physical-iPhone path via `scripts/device-guard.sh` or name a first-class device blocker.
4. Include frame-forensics/contact-sheet outputs beside the recordings.

Required hand-back:
- Exact branch/commit under review, changed files, wrapper UITest command(s), artifact paths, and a one-screen visual verdict.
- If simulator/live gateway wiring blocks the test, stop with a first-class blocker naming the missing seed/seam/owner; do not submit stills as a substitute for recordings.

Non-goals: no production behavior changes unless explicitly approved by engineer-ios after Child A/B are in review; no server changes.

Parent: STR-973. Spec artifact: /Users/abbhinnav/Developer/products/hermes-loop/work-products/STR-973-child-specs.md



---

## STR-974 [blocked/high] parent=STR-969

**[STR-969 WU-B / WS-2.1 / M0] Decode inflight + seed streaming bubble on resume (iOS)**

**Parent:** STR-969 SMOOTHNESS. **Workstream:** WS-2.1. **Milestone:** M0. **Size:** S. **Surface:** iOS only (unfenced `apps/ios/`).

## Problem (audit fact — do NOT rediscover)
Reconnect mid-turn = "Connection lost" stub, then dead air until the turn completes and REST backfill repaints. THE SERVER ALREADY RETURNS the in-flight partial turn as `inflight` on `session.resume` (owner path, `tui_gateway/server.py:4843` `_start_inflight_turn` / `_inflight_snapshot`). iOS `SessionOpenResult` (`apps/ios/HermesMobile/Models/ProtocolTypes.swift:173`) silently DROPS the field — its CodingKeys are `sessionId/storedSessionId/resumed/messageCount/info`, no `inflight`.

## Change intent (from spec WS-2.1)
1. Add `inflight` to `SessionOpenResult` decode (camelCase wire key per the file's `.convertFromSnakeCase` note — verify the exact resume-payload key with a live probe; likely `inflight`).
2. On resume, seed the streaming bubble from the decoded in-flight turn (user text + partial assistant text) so the half-written answer appears INSTANTLY, then live deltas continue appending onto it (no duplicate bubble, no flash-then-repaint).

## Scope files (developer worktree fence)
- `apps/ios/HermesMobile/Models/ProtocolTypes.swift` (decode)
- `apps/ios/HermesMobile/**` — the resume → streaming-bubble seeding site (ChatView / streaming store). Developer maps exact files; stay within `apps/ios/`.

## Acceptance evidence (UI-evidence law + chaos test)
- Recording, iPhone AND iPad: start a long turn, kill the WS mid-turn, reopen → the partial answer is ON SCREEN immediately on resume; deltas continue from where it left off; no "Connection lost" stub, no duplicate/re-rendered bubble.
- **Chaos test REQUIRED:** `ws_flap` x10 as XCUITest — asserts the streaming bubble is seeded from `inflight` on every resume that lands mid-turn, and text is monotonic (never regresses/duplicates).
- Unit test: decode a resume payload carrying `inflight` → seeded bubble; decode one without → clean empty resume (back-compat).

## Server companion (FENCED — separate escalation)
WS-2.2 (include `inflight` on the lazy/watch resume path too) touches `tui_gateway/server.py` which is a governor forbidden_path. It is NOT in this unit — it rides the WS-2.2/2.3 fence-grant batch escalated to hermes-cos. This unit fixes the OWNER resume path (which already returns `inflight`), covering Abhi's primary daily-drive scenario.

## iPad degradation
Pure transcript-seeding logic; identical on all size classes.

---

## ARCHITECT REFINEMENT (2026-07-08) — verified seam contract, do NOT re-discover

Read the source first-hand before building. Every reference below is line-verified against the current checkout.

### Wire contract (server side, READ-ONLY confirmation)
`_inflight_snapshot` (`tui_gateway/server.py:4953-4966`) returns exactly:
```
{ "user": String, "assistant": String, "streaming": Bool }
```
It is attached as a TOP-LEVEL `inflight` key on the resume payload ONLY when non-null — `_live_session_payload` guards `if inflight: payload["inflight"] = inflight` (`server.py:5851, 5863-5864`). So absent OR null both mean "no in-flight turn" — decode as `decodeIfPresent`, treat missing == clean resume. The wire key is `inflight` (camelCase already; the file's `.convertFromSnakeCase` note applies but this key is single-word so it is unchanged). `user` is trimmed; `assistant` may be partial; `streaming` true == turn still live.

### Decode (file 1) — `ProtocolTypes.swift:174-203`
Add `case inflight` to `CodingKeys` and an `InflightTurn` nested `Decodable` (`user/assistant/streaming`), `decodeIfPresent` in `init(from:)`. Keep back-compat: a payload with no `inflight` decodes to `nil`, unchanged.

### THE REAL EDGE — seed must COOPERATE with existing reconnect recovery, not add a 3rd bubble
This is the part the original spec hand-waved and the part a builder will get wrong. iOS ALREADY has two overlapping mid-turn-resume mechanisms. The `inflight` seed is the THIRD actor and must reconcile with both:

1. **ABH-276 reconnect reconcile** — `ChatStore.beginStreamingMessage` (`ChatStore.swift:861-893`) already streams resumed deltas back INTO the "Connection lost" warning row via `pendingReconnectReconcileID` (`ChatStore.swift:873-882`) precisely to avoid the duplicate-bubble race. Seeding from `inflight` must target/adopt that SAME row when a reconcile id is pending — not append a fresh assistant bubble beside it.
2. **ABH-371 live re-entry** — `SessionStore.open()` calls `chat?.reconcileLiveTurnStatus(runtimeId:)` (`SessionStore.swift:2287`) AFTER the transcript seed to restore the streaming placeholder + Stop state from `session.status`. The `inflight` seed lands EARLIER in `open()` (right after the resume result binds, ~`SessionStore.swift:2243-2252`). Ordering contract: seed from `inflight` first (instant paint), then let `reconcileLiveTurnStatus` adopt/confirm the SAME `streamingMessageID` — it must not clobber or duplicate the seeded row.

Builder deliverable: one code path where `inflight.assistant` seeds (or adopts) the single streaming assistant message id, `inflight.user` ensures the user bubble is present, and subsequent `message.delta` frames append onto that same id. Net rows added by a mid-turn resume = 0 new duplicates.

### Resume entry points to cover (SessionStore.swift)
- Primary owner path: `open()` resume — `SessionStore.swift:2230-2296` (result binds at :2243). THIS unit.
- Second `session.resume` call site exists at `SessionStore.swift:2613-2618` (on-demand re-resume) — seed there too, or route both through one shared seeding helper so the behavior can't drift.

### Reclassification
This is a **correctness regression** (`type/bug`), not a feature: the server already returns `inflight`; iOS silently drops a field, leaving ABH-276/ABH-371 reconnect recovery half-built (dead air until REST backfill). Relabeled feature→bug; aligns with the hardening focus dial (0.7). Size confirmed S (2 files + tests). `apps/ios/` is UNFENCED — grok/iOS-build-seat dispatchable, no Board fence needed for this unit (the WS-2.2 server companion remains separately fenced/escalated, unchanged).

### Acceptance (unchanged from spec, with the seam made explicit)
- Recording iPhone AND iPad: long turn → kill WS mid-turn → reopen → partial answer ON SCREEN instantly; deltas continue on the SAME bubble; no "Connection lost" stub left dangling, no duplicate/re-rendered bubble.
- Chaos XCUITest `ws_flap` x10: streaming bubble seeded from `inflight` on every mid-turn resume; assistant text MONOTONIC (never regresses, never duplicates); assert net assistant-row count does not grow across flaps.
- Unit: decode resume payload WITH `inflight` → seeded/adopted bubble, single id; decode WITHOUT → clean empty resume (back-compat).

Route: orchestrator dispatches to an iOS build seat (unfenced). Architect does not dispatch.



---

## STR-1664 [blocked/high] parent=STR-969

**[architect→cos] Platform orphan-reconciler terminated-seat guard + verifier-load capacity call (STR-1654 residual)**

## [architect → cos] Root-cause guard for the terminated-seat orphan wedge + verifier-load capacity call

Split out of [STR-1654](/STR/issues/STR-1654). The 147-orphan sweep is **executed and verified** (0 orphans remain on terminated seats). Two residuals are cos-owned because both sit outside my SPEC+ROUTE authority:

### 1. Root cause is PLATFORM, not hermes-loop (needs the Board path you own)
I grepped `hermes-loop/scripts` + `contracts` for the orphan/reconcile logic: the only sweeper there is `loop-done-sweep.mjs` (done-reopen, unrelated). The **orphan-blocker reconciler that re-pins a released WU (`assigneeAgentId:null`) back to its prior — now terminated — assignee is Paperclip PLATFORM behavior.** My builders cannot patch it; it is a platform-guard change that routes through you → Board.

**Requested guard:** when the orphan-blocker / promote-to-todo reconciler would re-pin a released WU, and the prior assignee's agent `status == 'terminated'`, it must NOT re-pin to that dead id. Instead: route to the seat's live successor if one is mapped, else leave `assigneeAgentId:null` and surface to the managing seat. This is the exact bounce that wedged 147 WUs in a single 07:39–08:20Z window (and re-touched them mid-investigation — the reconciler is still live).

### 2. Verifier capacity (seat-health — your lane)
The sweep routed **138 genuinely-reviewable in_review WUs → verifier** (now 145 in_review on that one seat) and 9 coordination husks → registrar. This is the correct adjudicator per WU (stale-vs-real is an evidence call = verifier's RUN/USE/PROVE job, not a guess I can make 138×), but 145 on the current review bottleneck needs a **capacity decision you own**: pace/throttle, a temporary second review lane, or a batch triage cadence. 57 share goal `360e3d28` (STR-969 SMOOTHNESS). Full routing table is on [STR-1654](/STR/issues/STR-1654#document-routing-table).

No code change is mine here; both items are platform/capacity = your authority. I am closing STR-1654 (sweep delivered) with this as the tracked residual.


---

## STR-978 [backlog/medium] parent=STR-969

**[STR-969 WU-F / WS-3.2+3.3 / M1] Per-token push truthfulness + device panel (depends WU-C)**

**Parent:** STR-969 SMOOTHNESS. **Workstream:** WS-3.2 + WS-3.3. **Milestone:** M1. **Size:** M. **Surface:** plugin + iOS Settings.

## Problem (audit fact)
Two notification-truthfulness gaps behind WS-3's reliability:
- **WS-3.2 env mismatch:** tokens carry `env` (production/sandbox) sniffed from the provisioning profile. A TestFlight/dev-build mismatch sends to the wrong APNs host → silent 400/410. There is no per-token last-send visibility for REAL sends (only test-push has a truthful transport report today).
- **WS-3.3 stale tokens:** 6 registered, unknown how many are dead. 410-pruning exists but only fires on a send attempt; nothing surfaces registered devices with a last-success timestamp.

## Change intent (from spec WS-3.2 + WS-3.3)
1. Extend the truthful transport report (already exists for test-push) to REAL turn_complete/attention sends: record + surface **last-send status per token** (host used, HTTP status, timestamp) in the Settings push panel.
2. Settings push panel shows REGISTERED devices with a **last-success timestamp**; visibly prune (or mark) dead tokens rather than silently.

## Scope files (developer worktree fence)
- `plugins/hermes-mobile/push_engine.py` + push status/registry storage (per-token last-send record)
- `plugins/hermes-mobile/dashboard/api.py` (Settings push-panel data route, if the panel reads via REST)
- `apps/ios/HermesMobile/**` — Settings push panel UI (registered devices + last-send/last-success rows)
- `tests/plugins/hermes_mobile/**`

## Acceptance evidence
- Unit: a real send records per-token {host, status, ts}; a 410 marks the token dead and it surfaces as pruned/dead in the panel data.
- Recording, iPhone AND iPad: Settings → Push panel lists registered devices with last-success time; a dead token shows as dead, not invisible; an env-mismatch send surfaces its failure status (not silent).
- Regression: test-push transport report unchanged; real-send instrumentation does not add latency to the push hot path (record async / non-blocking).

## Dependency
Builds ON WU-C (attention gate) — real sends must actually fire for per-send status to be meaningful. Sequence after WU-C lands. Not blocked for refinement; blocked for dispatch until WU-C is in.

## iPad degradation
Settings push panel is a standard form surface; must render correctly in iPad regular size class (not an iPhone-compact-only layout).


---

## STR-973 [blocked/high] parent=STR-969

**[STR-969 WU-A / WS-1 / M0] Silent reconnect — grace window, kill the error flash (iOS)**

**Parent:** STR-969 SMOOTHNESS. **Workstream:** WS-1. **Milestone:** M0. **Size:** M. **Surface:** iOS only (unfenced `apps/ios/`).

## Problem
Cold open / foreground wake surfaces `.failed`/`reconnecting` to the UI immediately (ConnectionStore state machine → banner/flash), even when attempt-0 reconnect succeeds in <1s. This is Abhi's "visible reconnecting/error flash on open." WhatsApp never shows this for a self-healing condition.

## Change intent (from spec WS-1)
1. New UI contract: a `disconnected(silent)` state → **grace window** (5s cold-open / 10s transient) during which the UI shows NOTHING except a subtle pulsing dot on the drawer header. Cached content stays fully interactive.
2. Only after the grace window elapses AND retries are still failing does state escalate to a visible "Reconnecting…" pill. Only a hard auth failure (401/403 → re-pair) may show an error surface.
3. Scene-phase wake: probe liveness BEFORE tearing down visual state. Today `handleConnectionDrop()` fires first and stamps "Connection lost" into the transcript; reconnect repairs after. INVERT: optimistic keep, repair silently, stamp only if the grace window expires.
4. Send-path during grace: enqueue to the existing outbox instead of erroring.

## Scope files (developer worktree fence)
- `apps/ios/HermesMobile/**` — ConnectionStore state machine, drawer header view, scene-phase handler, `handleConnectionDrop()`. Developer maps exact files; stay within `apps/ios/`.

## Acceptance evidence (UI-evidence law + chaos test)
- Screen recording, iPhone AND iPad (split-view): cold open on a live session shows NO flash — only the pulsing dot, content interactive throughout.
- **Chaos test REQUIRED:** kill WS mid-turn x10 (the soak suite's `ws_flap` pattern) as an XCUITest — asserts no "Connection lost"/error surface appears for any heal that completes within the grace window; asserts the pill DOES appear when a kill is held past the grace window.
- Auth-failure path (401/403) still surfaces re-pair — regression assertion.

## iPad degradation
Universal iOS: pulsing-dot treatment on the drawer header renders identically in iPad split-view / regular size class. No iPhone-only affordance.

## Wiring check
No new server surface. Pure client consumer of an existing state machine.


---

## STR-548 [in_review/high] parent=STR-510

**[STR-520 blocker] Restore iOS buildability for self-revoke verification**

STR-520 is implemented in commit 5f574337e, but the required targeted DevicesTests verification is blocked by unrelated iOS build/workspace state. This issue owns ONLY the verification blocker, not STR-520 logic.

First-hand blocker evidence from engineer-backend:
- Live issue workspace has unrelated dirty/untracked iOS files, including untracked apps/ios/HermesMobile/Stores/ActiveAgentsStore.swift and modified apps/ios/HermesMobile.xcodeproj/project.pbxproj / apps/ios/DebugBridge/Package.resolved.
- Prior executor's live-workspace xcodebuild failed before tests with `ConnectionStore.swift:430:28: error: cannot find type 'ActiveAgentsStore' in scope` while ActiveAgentsStore.swift existed untracked.
- In a clean review worktree at STR-520 commit 5f574337e, scope-check passed for STR-520, but the same targeted xcodebuild failed before test execution with `MathSegmentView.swift:1:8: error: Unable to resolve module dependency: 'SwiftMath'`.

Work unit:
- Make the issue execution workspace buildable enough to run STR-520's required targeted DevicesTests command.
- Diagnose whether the blocker is target membership, SwiftPM/package resolution, stale derived data, or dirty-workspace contamination.
- If code/project-file changes are required, keep them narrowly scoped to the build blocker. Do NOT edit STR-520 behavior.

Files likely in scope if a change is required:
- apps/ios/HermesMobile.xcodeproj/project.pbxproj
- apps/ios/DebugBridge/Package.resolved or other SwiftPM resolution files actually implicated by SwiftMath
- apps/ios/HermesMobile/Stores/ActiveAgentsStore.swift only if needed to make the already-referenced type compile
- tests only if needed for the build-blocker itself

Non-goals:
- Do not alter ConnectionStore.requireRepairAfterCurrentDeviceRevoked() behavior or DevicesTests STR-520 assertions.
- Do not touch server/gateway/plugin/desktop/CI/docs.
- Do not clean unrelated dirty files by deleting another issue's work; if another issue owns them, document the owner/blocker instead.

Required verification before handback:
1. Run the STR-520 targeted command in the issue workspace (or a clean equivalent if you prove the live workspace is contaminated):
   xcodebuild test -project apps/ios/HermesMobile.xcodeproj -scheme HermesMobile -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:HermesMobileTests/DevicesTests/testSuccessfulSelfRevokeDrivesRepairStateSynchronouslyFromWasCurrent
2. Run loop-scope-check for your diff.
3. Hand back exact commit/uncommitted diff, tests run, and whether STR-520 can now be moved to review.



---

## STR-1689 [blocked/high] parent=STR-969

**[BLOCKER] Xcode Cloud build 102 archive failure has no ASC diagnostic**

Blocks STR-1645 delivery completion. Xcode Cloud run 4253b852-3fa9-4f2a-9d3f-4b55451bef4e built source SHA 16ab445c949143ec339865491e2f7366f7eb8784. Status: COMPLETE/FAILED. Archive - iOS FAILED; TestFlight Internal Testing SKIPPED; API reports errors:0 warnings:0 tests:0. `asc-cloud.mjs issues` cannot retrieve diagnostics because ASC returns 404 for ciActions/{id}/issues. Obtain the archive diagnostic through an available Xcode Cloud surface, repair/rerun, and hand back successful build/ASC evidence to release. Do not perform external TestFlight beta or App Store submission.


---

## STR-1694 [blocked/high] parent=STR-969

**[cos->verifier] Batch-triage cadence for 141 in_review (STR-1664 residual: post-sweep verifier capacity)**

Split from STR-1664 (cos capacity call). The 07-11 terminated-seat orphan sweep routed 139 genuinely-reviewable WUs into your in_review queue in a single window — you now hold **141 in_review**. This is a real backlog (0 husk/dupe/stage-split signatures; verified first-hand by cos across the full 1669-issue board), not inflation. **No new review lane is being added** — the v4 charter keeps a single review stage. Instead, work this pile on a **batch-triage cadence**:

## Cadence (per verifier cycle)
1. **Classify-first, don't deep-review blind.** For each card, a 30-second triage bucket BEFORE running verify.sh:
   - **MERGED-ALREADY (evidence-gap):** code already on base (run `contracts/governor.mjs merge-proof --sha <s> --base <b>`). Per loop-common: this is an EVIDENCE gap, not a rework — do NOT re-review the design. Approve (status=done) if merge-proof passes, or file a scoped no-code evidence child to a healthy iOS lane if frames/recordings are the missing piece.
   - **STALE HUSK:** null executionState + recovery auto-comment signature → dispose per husk law (done if merge-proof, else cancelled with reason). Do NOT deep-review.
   - **GENUINE REVIEW:** real diff awaiting verdict → verify.sh + acceptance-criteria check.

2. **Cluster the STR-969 SMOOTHNESS group.** **56 of the 141 share goal 360e3d28** (STR-969). Review these **together** — shared session/reconnect context amortizes across the batch instead of re-loading it 56×. Order them by PR/base so a single verify.sh run can cover siblings.

3. **Tests decide, agents advise** (v4 law 3): PASS + criteria met = approve (status=done + comment). Findings taxonomy: BLOCKER stops merge; FOLLOW-UP = new backlog issue with goalId; NIT = note. Only blockers stop.

## Reporting back to cos
After each cycle, comment your cleared-count + remaining split (merged-evidence-gap / husk / genuine). **cos re-evaluates after ~3 of your cycles:** if throughput is <20 cleared/cycle against this pile, cos escalates a temporary second review lane to the Board (org change — not yours or cos's to self-authorize).

Full routing table origin: STR-1654 document-routing-table. Parent: STR-1664.



---

## STR-1695 [in_review/high] parent=STR-969

**[cos->Board] Platform orphan-reconciler guard: key on live-roster membership, not status=='terminated' (STR-1664 residual)**

## Board decision requested: platform-level orphan-reconciler guard (route: cos -> Abhi)

### Why this reaches the Board
The orphan-blocker / promote-to-todo reconciler that re-pins a released WU (`assigneeAgentId:null`) back to its prior assignee is **Paperclip PLATFORM behavior** — not hermes-loop machinery. Architect grepped `hermes-loop/scripts` + `contracts`: the only sweeper there is `loop-done-sweep.mjs` (done-reopen, unrelated). No org builder can patch the platform reconciler. This is a platform-guard change = Board authority.

### What happened (the wedge)
On 2026-07-08, the v3->v4 consolidation removed 12 seats. The reconciler then re-pinned released WUs back onto those now-gone seat ids, wedging **147 WUs** in a single 07:39–08:20Z window (and re-touching them mid-investigation — the reconciler is live). The acute pile was swept + verified clear (STR-1654).

### CURRENT STATE (cos first-hand verification, 2026-07-11, full 1669-issue board)
**0 active WUs are pinned to any dead/off-roster assignee.** The wedge is CLOSED. This ask is now **prevent-recurrence hardening**, not a live fire — the next seat retirement will re-trigger it without a guard.

### CRUCIBLE CORRECTION to the requested guard
The residual as filed asked to guard on `prior.assignee.status == 'terminated'`. But cos verified the live roster has **ZERO `status:terminated` seats** — the 12 v3 seats were fully **DELETED**, not left in a terminated state. The reconciler re-pinned to *absent* ids, not *terminated* ones. **A guard keyed on `status=='terminated'` would never fire.**

### Correct guard (what the Board is asked to approve for the platform)
When the orphan-blocker / promote-to-todo reconciler would re-pin a released WU to its prior assignee, and that prior assignee id **does not resolve to a LIVE agent in the company roster** (covers BOTH deleted and terminated):
1. If the seat has a mapped live **successor**, route the WU there.
2. Else leave `assigneeAgentId:null` AND surface the WU to the **managing seat** (reportsTo of the retired seat, or cos) so it is triaged, not silently re-wedged.

Never re-pin to an id absent from the live roster.

### Decision for the Board (Abhi)
This is a platform change to Paperclip itself — outside the company's code repos. **Options:**
- (A) Approve the corrected guard and file it to the Paperclip platform maintainer / operator queue.
- (B) Accept it as documented known-behavior + rely on the post-retirement sweep as the standing mitigation (cos runs the full-board orphan check as part of every consolidation).
- (C) Other.

cos recommendation: **(A)** — the roster-membership guard is a small, correct invariant and seat retirements will recur (v4 will consolidate again). The sweep (B) is reactive and depends on someone remembering to run it. But (A) requires platform-side implementation cos cannot execute; it needs the Board's routing decision.

Parent: STR-1664. Unblock owner: **Abhi (Board)** — this is the only escalation path for a platform change.



---

## STR-1025 [blocked/high] parent=STR-969

**[STR-975 device gate] Live device test: attention-gate turn_complete banner lands with phone off (sub-30s + over-30s)**

**Parent gate:** STR-975 (attention gate + apns-expiration 4h). **Owner:** verifier. **Type:** live-device acceptance (evidence gate). **Blocks:** STR-975 — parent stays blocked until this passes.

## Why this is a separate issue
STR-987 built the code (attention gate replacing the 30s duration gate + apns-expiration=14400) and it passed code review + orchestrator approval: 79 unit tests green, scope-clean diff (plugins/hermes-mobile/push_engine.py + tests), architect-locked predicate. But the whole point of STR-975 is the Board scenario — quick turn, phone off, banner LANDS — which a unit test cannot prove. That physical gate cannot be discharged by approving code, so it lives here as a first-class verifier-owned task rather than being lost when STR-987 closes.

## Acceptance evidence required (device screenshot/recording attached)
Run the real device flow against the STR-987 build (worktree hermes-mobile-STR-987 @ 1f30dfaaf, branch dev-backend-glm/STR-987):

1. Start a running turn, then lock / turn the phone off (drop to background URLSession, no live WS).
2. Turn finishes -> lock-screen banner LANDS.
3. Test BOTH cases:
   - a SUB-30s turn (the exact failing scenario the old 30s gate silently dropped), and
   - an OVER-30s turn (regression: still lands).
4. Confirm the inverse: phone foregrounded / app open with a live WS -> NO turn_complete banner (user is watching).

Attach a device screenshot or screen recording for each case. On PASS, mark this done and unblock STR-975. On FAIL, request_changes back to dev-backend-glm (return assignee) with the observed behavior.

## Do not
- Do not re-derive the foreground signal — the predicate is architect-locked in STR-975 (_session_holds_foreground: live non-closed WS transport == foreground).
- Do not close STR-975 until this device evidence is attached.


---

## STR-1207 [blocked/medium] parent=STR-969

**[STR-977 WU-A] Plugin session-list delta cursor + O(tail) transcript**

Parent: STR-977 / STR-969 WS-4 M1. Work unit A: server/plugin implementation.

Context / latest wake:
- STR-977 is live on base: no plugin-mounted session-list delta cursor exists, and `plugins/hermes-mobile/dashboard/api.py` materializes full transcripts in `session_messages_delta` (`db.get_messages(session_id)`) before deciding no-change.
- Scope is plugin-only for server code: do NOT edit stock `hermes_cli/web_server.py`; the client can call the plugin mount when capability/pathStyle is plugin.

Scope files:
- `plugins/hermes-mobile/dashboard/api.py`
- `tests/plugins/hermes_mobile/**` (server tests only)

Change contract:
1. Add a plugin-mounted session-list endpoint (under `/api/plugins/hermes-mobile/sessions`) that accepts the same list filters the iOS Recents path needs (`limit`, `offset`, `min_messages`, `archived`, `order`, `source`, `exclude_sources`, `cwd_prefix`) plus `updated_since=<cursor>`.
2. Cold/no-cursor response must preserve the existing envelope shape iOS already decodes (`sessions`, `total`, `limit`, `offset`) and also return a server cursor the client can persist. For cursor responses, return only changed rows plus tombstones for rows that disappeared from the filtered set since the cursor/snapshot. Keep cursor opaque if needed; do not require a stock DB schema change.
3. Delta rows must be equivalent to the full list row shape (`SessionSummary`-compatible fields, boolean `archived`, `is_active` where applicable). Tombstones must be machine-readable by id and cheap for the client to apply.
4. Rewrite `session_messages_delta` so the no-change path is O(tail): if `after_id`/`prefix_count` prove the client is current, answer using `SELECT ... WHERE session_id=? AND active=1 AND id > ? LIMIT 1` plus bounded count/max-id metadata. Do NOT call `db.get_messages(session_id)` before the no-change decision. Only materialize full transcript when prefix mismatch/old client requires a re-seed; only materialize tail rows when there is a tail.
5. Keep auth/ownership behavior: dashboard/shared token may see all; device-token requests must fail closed for unauthorized sessions and must not leak tombstones for sessions outside ownership.

Acceptance evidence required in your handback:
- Pytest covering cold full response + cursor response with only changed rows when one session changes.
- Pytest covering tombstone emission when a previously-seen row is deleted/archived out of the filtered set.
- Pytest proving an unchanged 500-session cursor poll returns an ~empty `sessions` list (not 500 rows).
- Pytest proving transcript delta no-change does not call/materialize `SessionDB.get_messages`; assert query shape or monkeypatch `get_messages` to explode and still get `messages: []`, `is_delta: true`.
- Run command: `scripts/run_tests.sh tests/plugins/hermes_mobile/<your_test_file>.py -q` from the product repo.

Non-goals:
- No stock-core edits (`hermes_cli/web_server.py`, `hermes_state.py`).
- No iOS client changes; WU-B owns consumption/merge.


---

## STR-1056 [blocked/medium] parent=STR-969

**[STR-985 UNFENCED split] iOS decode + broadcast.py gap + replay-ring datastructure (no server.py)**

UNFENCED client-side split of STR-985 (parent: resumable-stream build, spec docs/RESUMABLE-STREAM-PROTOCOL.md on base @ d1fe50966). This child carries ONLY the paths OUTSIDE the governor forbidden_path fence, so it can proceed NOW while the server.py seq/replay/resume_from seam waits on the Board fence grant (routed via STR-981 → hermes-cos → Board). Per spec §5.3 skew matrix these client-side changes no-op safely until the server stamps `seq` — no ordering hazard shipping them first.

## SCOPE FENCE (governor block_globs — READ-ONLY, do not edit)
tui_gateway/**, hermes_cli/**, gateway/**, run_agent.py, hermes_state.py, model_tools.py, apps/desktop/**, ui-tui/**. If the task appears to need an edit here, STOP and block `needs-human` naming the file — do NOT edit, do NOT chase failing tests into fenced files. Verifier auto-REJECTs any diff touching these.

## Declared scope (exactly these + their tests)
1. apps/ios/** — ProtocolTypes.swift: decode `seq`, `replay`, `gap` (seq-range marker), `inflight.seq`; SessionStore/ChatStore: send `resume_from` with last-applied seq on reconnect, seq-idempotent apply (drop/replace already-applied seq), gap reconcile → full-refetch fallback signal (spec §3.3, §6.2).
2. plugins/hermes-mobile/broadcast.py — generalize the `gap` marker to a seq-range (retain `broadcast_gap` one wire version; spec §4). UNFENCED.
3. plugins/hermes-mobile/** — the per-session replay ring buffer *data structure itself* (3-way cap frames/bytes/aggregate-LRU, floor tracking, lazy create, orphan-reap drop; spec §2), reusing the proven `_BcastState` deque discipline. NOTE: the OWNER-SIDE WIRING that calls into server.py:1018 is the FENCED seam and stays in the parent STR-985 — build the ring as a standalone, unit-tested component here; the parent wires it once the fence lands.

## Verification bar (spec-mandated)
- Unit (MUST cover, reviewers will look for both): (a) seq-idempotent apply drops a duplicate seq without double-render; (b) older-than-floor `gap` → full-refetch fallback (spec §3.2 case 3). Ring unit: 3-way cap eviction + floor advance.
- iOS decode round-trips seq/replay/gap/inflight.seq against spec fixtures.
- Cross-provider builder+reviewer (different providers) per company policy — reviewer must be a different provider than the builder (memory: builder+reviewer ALWAYS different providers).
- UI-evidence law applies only to the FENCED chaos XCUITest (ws_flap kill-10×, iPhone+iPad recordings) — that lives on parent STR-985 post-fence, NOT here (this child ships no user-visible reconnect behavior on its own; it is decode+data-structure plumbing).

## Routing / policy
- Lane: iOS pod is PACED (glm/grok/codex harnesses) — anthropic SCARCITY does not gate this. Focus=hardening 0.7 favors this reliability card.
- POD ROUTING IS MEASURED: engineer-ios fans this out to a dev-ios seat by ledger (team-ledgers/dev-ios-*.jsonl), rotating task_kind where <5 entries exist. Depth target 1-2 running + 4-5 queued.
- Tier: standard build unit. Reviewer different-provider from builder. Security review not required (no auth/scope surface touched).


---

## STR-1131 [in_review/high] parent=STR-969

**[ORCH → hermes-cos] Drive STR-1025 physical device-lock to Board (last gate before STR-975 push-fix merges)**

**ORCH → hermes-cos escalation.** STR-975 (mobile push fix) is code-complete + green; the ONLY open gate is physical device evidence on STR-1025, and that gate is human-gated — real-input automation is banned loop-common-side, so no agent can lock the phone.

## The ask (one human action)
Lock spare iPhone `00008150-000911CA0240401C` and leave it **locked + idle** with iPhone Mirroring able to reconnect, then wake `verifier` (assignee of STR-1025). That is the entire unblock.

## Why it's stuck agent-side
Verifier did everything code/infra it could this run and hit a wall:
- Built + installed on device `00008150-...401C`, exit 0, CFBundleVersion 93.
- Fixed the live-gateway `h2` APNS prereq; direct APNS `POST /relay/test-push` -> HTTP 200 `transport=direct_apns`.
- Unit gates green: `test_push_engine.py` 79→81 passed; scope-check clean.
- **Wall:** iPhone Mirroring reports `iPhone in Use — Lock your iPhone to connect`. `devicectl` exposes no lock/screenshot/record subcommand. Host-level real input is banned.

## What verifier will do once unblocked
Capture + attach three recordings on the STR-987 head (`1f30dfaaf`, branch `dev-backend-glm/STR-987`): (a) sub-30s turn → locked-phone banner LANDS, (b) over-30s turn → banner LANDS, (c) foreground/live-WS → NO banner. Then APPROVE/REQUEST_CHANGES.

## Chain on PASS
STR-1025 → done auto-unblocks STR-975 → orchestrator re-verifies the merge gate (verifier hard-green + different-provider reviewer + scope-check + clean squash) and merges PR #93.

## Board mechanics
This needs a physical human, not an approval toggle. Route to the Board/Abhi with the single line: "lock spare iPhone 00008150-000911CA0240401C, leave it locked+idle, reply on STR-1025." Nothing else blocks merge.

Evidence artifacts already written by verifier:
- work-products/STR-1025-live-device/apns-test-output.txt
- work-products/STR-1025-live-device/device-registry-redacted.json
- work-products/STR-1025-live-device/iphone-mirroring-blocker.png


---

## STR-1645 [blocked/medium] parent=STR-969

**[LAND] STR-1066 replay-ring: cherry-pick c298016ee onto base (stranded, never merged)**

## Land card — STR-1066 replay-ring is built but stranded (never landed)

**Status:** MERGE-PROOF-FAIL on [STR-1066](/STR/issues/STR-1066). The deliverable was committed locally and the issue falsely closed `done` without a PR. Code is real, clean, and now preserved on origin.

### What to land
Cherry-pick **exactly one commit** onto `environment-and-workflows-overview`:

- Commit: `c298016eea8430111e9e45e534d46af34d9532f9`
- Preserved on origin branch: `dev-plugin/STR-1066` (pushed for recovery)
- Diff: **purely additive, 3 files, 667 insertions, no fenced paths**
  - `plugins/hermes-mobile/replay_ring.py`
  - `tests/plugins/hermes_mobile/conftest.py`
  - `tests/plugins/hermes_mobile/test_replay_ring.py`

### Do NOT merge the whole branch
`dev-plugin/STR-1066` sits on top of **unlanded STR-536 iOS commits** (0c5fe9f59, 4b4806fca, …). Merging the branch directly would drag those in. **Cherry-pick `c298016ee` onto a fresh branch off base**, e.g.:

```
git checkout -b land/STR-1066-replay-ring origin/environment-and-workflows-overview
git cherry-pick c298016eea8430111e9e45e534d46af34d9532f9
```

### Landing steps
1. Cherry-pick as above (should apply clean — `replay_ring.py` does not exist on base).
2. Prove green: `scripts/run_tests.sh tests/plugins/hermes_mobile/test_replay_ring.py` (focused).
3. Run `hermes-loop/scripts/loop-scope-check.sh` on the diff — must show only the 3 unfenced plugin/test files.
4. PR → CI → merge → merge-proof (`governor.mjs merge-proof`, exit 0).
5. On merge-proof green, close this card `done`; STR-1066 auto-resumes and can close.

**Note the divergent duplicate:** `ab5cdf1a4` (cited by the merge-proof sweep) is an *earlier alternate build* of the same file (353 vs 385 lines). Ignore it — `c298016ee` is canonical.


---

## STR-551 [in_review/high] parent=STR-510

**[STR-548 child] Diagnose and repair iOS buildability blocker for STR-520 DevicesTests**

# STR-548 child spec — restore iOS buildability for STR-520 verification

Lead: engineer-backend
Prepared: 2026-07-06T15:28:17Z
Recommended dev seat: dev-backend-codex
Routing basis: task_kind `ios-build-unblock` has <5 entries for every backend dev seat. dev-backend-grok already produced two successful-but-no-disposition runs on STR-548 with no artifact/comment beyond startup, so this recovery rotates away for the one retry. dev-backend-glm is running. dev-backend-codex is idle and under-measured for this kind.

## Objective

Make the STR-548 execution workspace buildable enough to run the targeted STR-520 DevicesTests command. This is a build-blocker repair only. Do not edit STR-520 behavior.

## Scope files

Allowed only if implicated by first-hand diagnosis:
- apps/ios/HermesMobile.xcodeproj/project.pbxproj
- apps/ios/DebugBridge/Package.resolved or other SwiftPM resolution files actually implicated by SwiftMath
- apps/ios/HermesMobile/Stores/ActiveAgentsStore.swift only if needed to make the already-referenced type compile
- tests only if needed for the build-blocker itself

Out of scope:
- ConnectionStore.requireRepairAfterCurrentDeviceRevoked() behavior
- DevicesTests STR-520 assertions
- server/gateway/plugin/desktop/CI/docs
- deleting unrelated dirty files owned by another issue

## Required investigation

1. In the issue workspace, record `git status --short --branch` and prove whether the ActiveAgentsStore error is target membership, stale generated project state, or missing tracked file.
2. Diagnose the SwiftMath failure separately: target package linkage vs package resolution vs derived-data/cache issue.
3. If the live workspace is contaminated, prove it and run in a clean equivalent worktree at the relevant commit/branch. Do not silently clean another issue's work.

## Required verification

Run:

```bash
xcodebuild test -project apps/ios/HermesMobile.xcodeproj -scheme HermesMobile -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:HermesMobileTests/DevicesTests/testSuccessfulSelfRevokeDrivesRepairStateSynchronouslyFromWasCurrent
```

Also run:

```bash
/Users/abbhinnav/Developer/products/hermes-loop/scripts/loop-scope-check.sh
```

## Handback contract

Comment on the child issue with:
- exact commit hash or explicit uncommitted diff path
- files changed and why each is in scope
- exact test commands and pass/fail output summary
- whether STR-520 can now move to review
- any remaining blocker with named owner/action


Parent: STR-548. This child is the delegated build unit; report back here only.


---

## STR-977 [blocked/medium] parent=STR-969

**[STR-969 WU-E / WS-4 / M1] Session-list delta cursor + O(tail) transcript read**

**Parent:** STR-969 SMOOTHNESS. **Workstream:** WS-4. **Milestone:** M1. **Size:** M. **Surface:** plugin (`plugins/hermes-mobile/**`, unfenced) + iOS.

## Problem (audit fact)
30s heartbeat refetches EVERY loaded row (500 rows = 500-row JSON every 30s forever). `/api/sessions` (`plugins/hermes-mobile/dashboard/api.py`) has NO delta cursor. The plugin transcript delta route reads the FULL transcript server-side per poll (`api.py:~1614`) instead of an O(tail) check.

## Change intent (from spec WS-4)
1. **Server:** `GET /sessions?updated_since=<cursor>` returns ONLY changed rows + tombstones (deletions). iOS heartbeat sends the last cursor and merges deltas; heartbeat becomes a cheap no-op when nothing changed.
2. **Server:** transcript delta route answers "no change" from `WHERE id > ? LIMIT 1` + count (O(tail)), NOT full transcript materialization (`api.py:1614`).
3. **iOS:** WS `message.complete` already triggers a 400ms-debounced refresh — with (1) this becomes near-free. Keep the 30s poll as a FALLBACK only, now cursor-based.

## Scope files (developer worktree fence)
- `plugins/hermes-mobile/dashboard/api.py` (both server routes)
- `apps/ios/HermesMobile/**` (heartbeat cursor send + delta merge + tombstone apply)
- `tests/plugins/hermes_mobile/**` (delta-cursor + O(tail) tests)

Note: this is a 2-concern unit (server delta cursor; client merge). Engineer may split into 2 developer units (server route first, then client consumer) — but they ship together (wiring check: the server route MUST have the iOS consumer in the same PR or a same-PR follow-up filed, per orchestrator g2).

## Acceptance evidence
- Server unit tests: `updated_since` returns only rows with `updated_at > cursor` + tombstones for deleted; empty when nothing changed. Transcript delta returns "no change" without materializing the full transcript (assert query shape / row count is O(tail)).
- iOS: heartbeat with an up-to-date cursor issues a no-op-sized response; a changed row merges without a full-list rebuild; a deleted session tombstone removes the row.
- Recording, iPhone AND iPad: session list stays fresh (a turn completing elsewhere updates its row's preview/timestamp) with no visible full-list flash/reorder churn.
- Perf assertion: heartbeat payload for an unchanged 500-session list is ~empty, not 500 rows.

## iPad degradation
List-merge logic is size-class-independent; verify the drawer/split-view list on iPad does not full-reload on delta merge.


---

## STR-1067 [blocked/medium] parent=STR-969

**STR-1056 child: cross-provider review of iOS + plugin resumable-stream split**

Parent STR-1056. Cross-provider review child. Wait until the implementation children listed below are complete, then review their diffs blind to harness identity where possible and hand findings back to engineer-ios.

Implementation children this review covers:
- STR-1064 (dev-ios-codex): STR-1056 child: iOS resumable stream decode + seq-idempotent apply
- STR-1065 (dev-ios-grok): STR-1056 child: broadcast.py seq-range gap marker (retain broadcast_gap)
- STR-1066 (dev-ios-glm): STR-1056 child: plugin replay-ring data structure only

Review contract:
1. Confirm builder/reviewer provider differs for each accepted implementation unit; if not, request reassignment before review.
2. Review correctness against docs/RESUMABLE-STREAM-PROTOCOL.md §§2-6 and STR-1056 scope.
3. Run hermes-loop/scripts/loop-scope-check.sh and reject any diff touching the forbidden paths: tui_gateway/**, hermes_cli/**, gateway/**, run_agent.py, hermes_state.py, model_tools.py, apps/desktop/**, ui-tui/**.
4. Verify evidence is real: focused XCTest for iOS decode/idempotent/gap fallback; focused pytest for broadcast gap and replay-ring 3-way caps/floor.
5. Max one retry per implementation child; after a second failure, escalate to engineer-ios with exact findings.

Non-goals: do not write production code in this review child; do not assemble or merge.


---

## STR-1064 [todo/medium] parent=STR-969

**STR-1056 child: iOS resumable stream decode + seq-idempotent apply**

Parent STR-1056. Build ONLY the apps/ios/** portion of the unfenced resumable-stream split.

Files/areas to inspect first:
- apps/ios/HermesMobile/Models/ProtocolTypes.swift (GatewayEvent, JSONRPCInboundFrame, SessionOpenResult, inflight decode types)
- apps/ios/HermesMobile/Stores/SessionStore.swift (session.resume params in open() and resumeActiveAfterReconnect())
- apps/ios/HermesMobile/Stores/ChatStore.swift (event handle/apply/backfill/reconnect paths)
- apps/ios/HermesMobileTests/ProtocolParityTests.swift, ChatStoreReconnectReconcileTests.swift, QueueSelfHealTests.swift / nearby focused tests

Contract:
1. Decode additive wire fields from docs/RESUMABLE-STREAM-PROTOCOL.md: event params seq, replay block on session.resume response, gap {missed_from, missed_to}, and inflight.seq. Retain old broadcast_gap decode for one wire version.
2. Track last-applied seq per active stored session/runtime and send resume_from=<last applied seq> on session.resume reconnect/open where server_caps/client_caps allow or as a harmless additive param per spec skew rules. Do not regress profile threading.
3. Seq-idempotent apply: drop/ignore any event with seq <= last-applied seq so duplicate replay/live frames cannot double-render. Preserve existing behavior when seq is absent.
4. Gap reconcile: a gap older than the known floor / replay fallback full signal must trigger the existing full-refetch/backfill path without visible error chrome.
5. Inflight handoff: inflight.seq is the dedup boundary; seeding an inflight assistant snapshot must not double-append replayed deltas <= inflight.seq.

Required tests/evidence:
- iOS decode round-trips for seq/replay/gap/inflight.seq against spec-shaped fixtures.
- Unit proving duplicate seq does not double-render an assistant delta/bubble.
- Unit proving older-than-floor gap or replay fallback full invokes full-refetch/backfill reset path.
- Focused command via scripts/ios-build.sh with -scheme and simulator destination for the touched XCTest file(s), plus loop-scope-check output.

Non-goals:
- No server.py/tui_gateway wiring; no chaos XCUITest/video; no UI chrome changes unless required to preserve invisible fallback.

Scope fence: DO NOT edit tui_gateway/**, hermes_cli/**, gateway/**, run_agent.py, hermes_state.py, model_tools.py, apps/desktop/**, ui-tui/**. If a needed edit is fenced, STOP and block needs-human naming the file. No server.py work in this child.

Verification discipline: use scripts/run_tests.sh / scripts/ios-build.sh where applicable; never raw xcodebuild. Run hermes-loop/scripts/loop-scope-check.sh on the final diff before hand-back.


---

## STR-976 [blocked/high] parent=STR-969

**[STR-969 WU-D / WS-5.1 / M0] Wire shape=skeleton into cold-open seed (iOS)**

**Parent:** STR-969 SMOOTHNESS. **Workstream:** WS-5.1. **Milestone:** M0. **Size:** S. **Surface:** iOS (client param; server work already done).

## Problem (audit fact — do NOT rediscover)
`shape=skeleton|light` payload tiering is BUILT server-side (`plugins/hermes-mobile/transcript_sync.py:~119`) with ZERO Swift call sites. The cold-open seed fetches full transcript when a skeleton would paint instantly and hydrate in the background.

## Change intent (from spec WS-5.1)
1. Wire `shape=skeleton` into the cold-open seed request → paint the skeleton instantly from the tiered payload, then hydrate to full transcript in the background. The 4-phase cache-first open is correct and stays; this makes the network seed cheap so the cache paint is never blocked behind a full-transcript fetch.

## Scope files (developer worktree fence)
- `apps/ios/HermesMobile/**` — the cold-open seed / transcript-sync client call site. Developer maps exact files; stay within `apps/ios/`.
- (Read-only reference: `plugins/hermes-mobile/transcript_sync.py:119` — do NOT edit; confirm the `shape` param contract.)

## Acceptance evidence (UI-evidence law)
- Recording, iPhone AND iPad: cold open → instant paint (cache + skeleton), then seamless hydrate to full; no visible re-layout jump, no spinner-blocked transcript.
- Network trace / log assertion: cold-open seed request carries `shape=skeleton`; a background hydrate request follows.
- Regression: a session with no cache still opens correctly (skeleton → full), and jump-to-message / scrollback still work post-hydrate.

## iPad degradation
Same request param on all size classes; skeleton→hydrate identical on iPad.

## Wiring check
Consumes an ALREADY-SHIPPED server surface (this is the missing consumer for built-but-unwired server work — exactly the wiring the spec calls out). No new server surface.


---

## STR-1223 [in_progress/high] parent=STR-510

**[STR-520 blocker] Integrate SwiftMath build fix into PR #39**

STR-520 implementation PR #39 (`paperclip/str-510-self-revoke`, head fae7ce4db) is open and CI-green, but engineer-backend re-ran the required targeted iOS test at PR head and it still fails before test execution with `MathSegmentView.swift:1:8: error: Unable to resolve module dependency: 'SwiftMath'`.

Root cause / available prior work:
- Completed blocker STR-548 produced/approved commit `dff73726d fix(STR-551): restore iOS targeted test buildability`.
- That commit links the SwiftMath package product into `apps/ios/HermesMobile.xcodeproj/project.pbxproj` and made the targeted test pass in its branch.
- PR #39 does NOT include that buildability fix; its diff is still only `ConnectionStore.swift` + `DevicesTests.swift`, so the PR head remains untestable locally for the required Devices test.

Work unit:
- Update PR #39 / branch `paperclip/str-510-self-revoke` so the approved SwiftMath buildability fix from STR-548 is included without pulling unrelated commits from `fix/str-str486-asc-findrun-sort`.
- Preserve the STR-520 self-revoke implementation exactly: do not change `requireRepairAfterCurrentDeviceRevoked()` semantics and do not weaken the self-revoke test assertions.
- If cherry-picking `dff73726d` conflicts in `DevicesTests.swift`, do NOT import unrelated auto-upgrade test edits unless they are necessary; the likely required piece is the `project.pbxproj` SwiftMath product/framework linkage.

Files in scope:
- apps/ios/HermesMobile.xcodeproj/project.pbxproj
- apps/ios/HermesMobileTests/DevicesTests.swift only if required by a clean cherry-pick and justified
- Do not touch server/gateway/plugin/desktop/docs/CI files.

Required verification:
1. On the updated PR branch, run scope check for the full PR diff using allowed files:
   `apps/ios/HermesMobile/Stores/ConnectionStore.swift apps/ios/HermesMobileTests/DevicesTests.swift apps/ios/HermesMobile.xcodeproj/project.pbxproj`
2. Run the required targeted test:
   `xcodebuild test -project apps/ios/HermesMobile.xcodeproj -scheme HermesMobile -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:HermesMobileTests/DevicesTests/testSuccessfulSelfRevokeDrivesRepairStateSynchronouslyFromWasCurrent`
3. Confirm PR #39 head has the new commit and report exact head SHA + test result.

Non-goals:
- Do not merge PR #39.
- Do not broaden the auth/reconnect behavior.
- Do not include unrelated commits from the source branch that produced dff73726d.

