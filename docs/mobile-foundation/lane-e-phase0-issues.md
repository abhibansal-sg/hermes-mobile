# Lane E — Phase 0 Correctness & Trust issue drafts

Verified against Hermes Mobile HEAD `73a6ee5ed7e8a4dc8ef479dd9b178bb3739f6027` on 2026-07-15. Paths and line numbers below refer to that revision.

## SPEC-VS-CODE DISCREPANCIES

- **The short-turn push defect remains on this HEAD, but its implementation fix is already PR #145.** `plugins/hermes-mobile/push_engine.py:1592-1619` still returns when a turn has no start timestamp or ran for less than 30 seconds, and `tests/plugins/hermes_mobile/test_push_intake.py:556-579` still asserts that suppression. Per the reconciliation report, PR #145 is mergeable and already carries the code and automated-test change. The issue below therefore covers only the unfulfilled physical-device validation; it must not duplicate the PR.
- **STR-1125's cold-start navigation dead-end is already fixed.** `apps/ios/HermesMobile/Sources/HermesMobile/HermesURLRouter.swift:453-475` enables Inbox fallback for attention and turn-complete routes, while `:513-545` waits for `ConnectionStore.waitUntilSessionRefreshReady`, refreshes, and falls back to Inbox. `ConnectionStore.swift:450-505` implements the readiness primitive, and `NotificationActionTests.swift:213-325` covers warm, cold, offline, and attention routing. No issue below reopens that work. The remaining R-04/R-20 defect is earlier in process startup: delegate/category installation and action endpoint resolution still depend on SwiftUI/bootstrap timing.
- **The notification endpoint resolver is partially more capable than the audit states.** `PushRegistrar.resolveEndpoint` in `PushRegistrar.swift:347-365` already falls back from the live connection to Keychain and cached API-path style. It is not sufficient for a killed launch, however, because the closure weakly captures `ConnectionStore` and first reads its `serverURLString`; that store remains blank until `ConnectionStore.bootstrap()` loads defaults at `ConnectionStore.swift:800-819`. The follow-up issue preserves the existing resolver but removes its dependency on hydrated live store state.
- **STR-510/STR-520's immediate close-event race is already fixed.** `ConnectionStore.handleCurrentDeviceRevoked` at `ConnectionStore.swift:1598-1609` cancels reconnect and hydration work, clears live chat/turn state, marks reauthentication, and enters setup immediately. `DevicesTests.swift:763-787` proves a later `.closed` event cannot undo that state. The remaining self-revoke issue targets durable local erasure and the broader stale-async paths identified by STR-1825.
- **STR-512/STR-526's duplicate device-load problem is already fixed.** The per-device single-flight map is declared at `ConnectionStore.swift:562-569`, used at `:1670-1752`, and exercised by `DevicesTests.swift:665-723`. It is not redrafted.
- **The frozen STR-1824 regression-test reference is stale.** The named `testReconnectSuccessEntersDraftWhenNoActiveSession` test and its `isDraft` assertion are not present in the current `ConnectionStoreReconnectTests.swift`. No issue assumes this is an active regression without a new reproduction.
- **The client Live Activity schema already has an optional start timestamp.** `HermesTurnAttributes.swift:25-57` defines `startedAt: Date?`, and `LiveActivityManager.swift` can use it. The server payload assembled at `plugins/hermes-mobile/push_engine.py:1452-1460` does not send it, so the remaining problem is cross-language epoch encoding and server update policy—not adding a wholly new client concept.

### ISSUE: Verify short-turn completion alerts on physical devices
Phase: 0 | Spec: R-01,R-19 | Priority: urgent | Labels: type:fix, area:server
Depends-on: Merge PR #145
Inherited-context: STR-969, STR-975, STR-987
Estimate: S

The current branch still suppresses short turns at `plugins/hermes-mobile/push_engine.py:1592-1619`, and `build_push_headers` defaults ordinary pushes to immediate expiration at `push_engine.py:196-217`. PR #145 is the reconciled implementation and automated-test fix, so this issue is deliberately limited to validating the merged behavior through APNs on real hardware.

Exercise a locked physical iPhone against a real gateway and APNs environment. A roughly five-second turn must produce one completion alert with a valid route; foreground delivery, background delivery, and reconnect timing must not create duplicates. Record device/iOS version, gateway commit, APNs environment, timestamps, and notification identifiers in the issue. Do not modify the short-turn implementation here, reopen PR #93, or broaden this into the notification-authority redesign.

Acceptance criteria:
- [ ] After PR #145 merges, a turn lasting approximately five seconds produces exactly one visible completion alert while the physical iPhone is locked.
- [ ] Tapping that alert routes to the completed session or the established Inbox fallback without a dead end.
- [ ] The same turn does not produce a second alert after app foregrounding or WebSocket reconnection.
- [ ] One foreground and one background control run are recorded, including notification identifier and gateway/APNs timestamps.
- [ ] Long-turn completion alerts still arrive once, and a turn that is still running does not receive a completion alert.

Tests required: `pytest tests/plugins/hermes_mobile/test_push_intake.py tests/plugins/hermes_mobile/test_push_engine.py`; `xcodebuild test` target `NotificationActionTests`; named manual target `PhysicalAPNsShortTurnValidation` on a locked device.

### ISSUE: Install notification handling during application launch
Phase: 0 | Spec: R-04,R-20,R-24 | Priority: urgent | Labels: type:fix, area:ios
Depends-on: none
Inherited-context: STR-1125
Estimate: M

Notification infrastructure is currently installed from the SwiftUI root task: `HermesMobileApp.swift:96-149` calls `NotificationService.setTapHandler` at `:129` and `setActionEndpointProvider` at `:142`. Those calls install the notification delegate and categories indirectly through `NotificationService.swift:91-95` and `:127-130`. `AppDelegate` at `HermesMobileApp.swift:360-383` only handles APNs registration success/failure and has no launch-time notification setup. A notification response can therefore arrive before the delegate, categories, or handlers exist.

Add a process-lifetime notification coordinator owned by `AppDelegate` and install it synchronously from `application(_:didFinishLaunchingWithOptions:)`. Register categories and set `UNUserNotificationCenter.current().delegate` there. The coordinator must buffer launch notification responses until routing and action dependencies attach, then drain each response exactly once. Preserve the current `HermesURLRouter` cold-start readiness/fallback behavior rather than replacing it. Also change the clarification Reply action at `NotificationService.swift:599-605` from no options to `.authenticationRequired`; approval and deny actions at `:574-598` already have that protection.

Out of scope: persistent credential lookup and action HTTP execution (next issue), notification deduplication, provisional-notification UX, and redesigning notification content.

Acceptance criteria:
- [ ] The notification delegate and all Hermes categories are installed during `didFinishLaunchingWithOptions`, before SwiftUI `.task` execution.
- [ ] A notification response delivered during a killed launch is buffered and routed once after dependencies attach; attaching twice cannot replay it.
- [ ] Warm-launch notification routing remains synchronous and still opens the target only once.
- [ ] Approval, denial, and clarification Reply actions all require device authentication when the device is locked.
- [ ] The existing cold-start session-refresh wait and Inbox fallback remain intact.
- [ ] No process-lifetime notification behavior depends on a view appearing or a SwiftUI task being scheduled.

Tests required: XCTest targets `NotificationActionTests`, `HermesURLRouterTests`, and new `NotificationLaunchCoordinatorTests` covering pre-attach buffering, one-shot drain, double attachment, category options, and warm/cold routing.

### ISSUE: Resolve killed-app actions from persisted credentials
Phase: 0 | Spec: R-04,R-20 | Priority: urgent | Labels: type:fix, area:ios
Depends-on: Install notification handling during application launch
Inherited-context: STR-1125
Estimate: M

The action endpoint provider is attached from `HermesMobileApp.swift:142-146`, after SwiftUI startup. `PushRegistrar.resolveEndpoint` at `PushRegistrar.swift:347-365` weakly captures a `ConnectionStore`, reads its in-memory `serverURLString`, and only then reads the Keychain gateway token and cached API-path style. On a killed launch, `ConnectionStore` has not yet loaded the persisted URL; that occurs in `ConnectionStore.bootstrap()` at `ConnectionStore.swift:800-819`. The launch coordinator can receive an action before a usable endpoint exists even though the required URL, token, and path-style data are persisted.

Introduce a launch-safe endpoint resolver that reads the saved gateway URL, gateway token, and cached API-path style directly from their persistence owners without constructing or waiting for a live WebSocket connection. Attach that resolver to the process-lifetime notification coordinator during launch. Approval, denial, and clarification reply requests must be idempotent by request ID, tolerate already-resolved responses as success, use the current API-path fallback rules, and surface a safe failure notification or Inbox item instead of silently dropping an action. Never place credentials in `UserDefaults`, notification payloads, logs, or buffered response records.

Out of scope: refreshing an expired pairing token without user repair, executing an action without a valid persisted credential, changing server authorization scope, and general offline response queuing.

Acceptance criteria:
- [ ] From a killed app, approving a pending request from a locked-device notification succeeds without first opening a WebSocket or waiting for `ConnectionStore.bootstrap()`.
- [ ] Denial and authenticated clarification Reply use the same launch-safe path.
- [ ] The resolver obtains the gateway token only from Keychain and the URL/path-style only from their established persistence stores.
- [ ] Missing, revoked, or invalid credentials produce a visible recoverable failure and route the user to repair/Inbox; the action is not reported as successful.
- [ ] Re-delivery of the same notification action cannot apply the response twice, and an already-resolved server response is treated as a completed outcome.
- [ ] No credential or reply body appears in logs or persisted launch buffers.

Tests required: XCTest targets `NotificationActionTests`, `PushRegistrarTests`, and new `PersistedNotificationEndpointResolverTests`; add a killed-launch fixture covering approve, deny, reply, missing token, revoked token, path-style fallback, and duplicate delivery.

### ISSUE: Make APNs authoritative and deduplicate notification events
Phase: 0 | Spec: R-07,R-23 | Priority: high | Labels: type:fix, area:ios
Depends-on: Install notification handling during application launch
Inherited-context: STR-969
Estimate: L

`ChatStore.swift:1218-1241` posts local approval and clarification notifications whenever those live events arrive, while the gateway also sends APNs for the same logical events. The local calls omit session context, and `NotificationService.swift:633-670` assigns a fresh random `UNNotificationRequest` identifier. Foreground presentation at `NotificationService.swift:715-720` always requests banner and sound. The client therefore has no stable identity or ownership rule with which to collapse WebSocket, local, and APNs delivery.

Make APNs the alert authority whenever the persisted push-registry state indicates that this device is registered (`ServerCapabilities.swift:54-55` and `:230-234`). Use local notifications only as an explicit fallback when push is unavailable or registration is known unhealthy. Define one deterministic correlation key per logical event (event kind plus stable request/turn identity and server/session scope), carry it through server APNs payloads and live events, use it as the local request identifier, and keep a scoped, bounded TTL ledger so delivery order cannot create duplicates. Do not use `ProtocolTypes.swift:527`'s random approval-ID fallback for deduplication; make the server supply a stable approval identity. For the active foreground session, update in-app UI and haptics without a redundant banner; a background or different-session event may still alert according to policy.

Out of scope: a general-purpose analytics event bus, cross-device deduplication, Notification Summary policy, and Phase-1 user preference UI.

Acceptance criteria:
- [ ] A logical approval, clarification, or turn-completion event produces at most one system alert on a registered device regardless of APNs/WebSocket arrival order.
- [ ] When push registration is unavailable or explicitly unhealthy, the live-event fallback produces one local alert.
- [ ] Each server event exposes a stable correlation identity; the iOS client never substitutes a random UUID for deduplication.
- [ ] Dedupe state is namespaced by gateway/device and expires or is bounded so it cannot grow without limit.
- [ ] The active foreground session receives in-app state/haptic feedback without an additional banner or sound.
- [ ] Background and non-active-session alerts retain their route and session context.
- [ ] Re-pairing or switching gateways cannot suppress a valid event because of another gateway's ledger entry.

Tests required: XCTest targets `ChatStoreTests`, `NotificationActionTests`, and new `NotificationAuthorityTests`; pytest targets `tests/plugins/hermes_mobile/test_push_engine.py` and `tests/plugins/hermes_mobile/test_push_intake.py` for stable event IDs and APNs payload identity.

### ISSUE: Return structured session status for live-turn re-entry
Phase: 0 | Spec: R-03,R-54 | Priority: high | Labels: type:fix, area:server
Depends-on: none
Inherited-context: STR-953
Estimate: S

The real `session.status` handler in `tui_gateway/server.py:7844-7898` returns only an `output` string. iOS decodes optional structured fields `running`, `model`, `provider`, and `usage` in `ProtocolTypes.swift:225-231`, so decoding succeeds while all fields remain `nil`. `ChatStore.swift:1190-1215` only restores a live running turn when `status.running == true`. Existing `LiveTurnReentryTests.swift:143-166` use a fake structured response and therefore do not exercise the actual wire contract; `tests/test_tui_gateway_server.py:4566-4597` currently pins the text-only result.

Keep the human-readable `output` field for TUI/CLI callers and add typed top-level fields to the same response. Derive `running` from authoritative session/task state rather than parsing the rendered text. Return nullable model/provider/usage data with stable JSON types and document their absence semantics. This is a supporting Phase-0 runtime-truth fix for Inbox/live-turn recovery; it does not implement the pending-attention endpoint.

Out of scope: changing the command text, inventing usage when unavailable, persisting turn state on iOS, or redesigning session lifecycle.

Acceptance criteria:
- [ ] The real gateway handler returns `output`, boolean `running`, and nullable structured `model`, `provider`, and `usage` fields.
- [ ] A running session decoded by iOS restores the streaming/Stop affordance on re-entry.
- [ ] An idle or missing session cannot be mistaken for running because of text parsing or omitted fields.
- [ ] Existing text consumers remain compatible.
- [ ] Python and Swift tests share representative response fixtures for running, idle, missing, and partial-usage cases.

Tests required: `pytest tests/test_tui_gateway_server.py -k session_status`; XCTest targets `LiveTurnReentryTests` and `ProtocolTypesTests` using the real response shape.

### ISSUE: Make Live Activity updates semantic and priority-aware
Phase: 0 | Spec: R-08,R-29 | Priority: high | Labels: type:fix, area:server
Depends-on: none
Inherited-context: STR-969
Estimate: M

`build_live_activity_headers` at `plugins/hermes-mobile/push_engine.py:281-299` defaults every ActivityKit push to APNs priority 10, and `notify_live_activity` at `:989-1057` exposes no priority parameter. The hook uses a three-second timer throttle (`_LIVE_ACTIVITY_THROTTLE_S` at `:1108`) and assembles content state at `:1452-1460` without the client's optional stable start timestamp (`HermesTurnAttributes.swift:25-57`). This spends high-priority budget on routine progress and makes elapsed-time display depend on repeated pushes.

Classify updates by meaning. Start/end, approval, clarification, error, and other blocking transitions use priority 10; routine tool/progress refreshes use priority 5. Coalesce identical semantic state, send routine updates only when the visible tool/status/progress actually changes, and preserve immediate delivery for blocking state. Encode a single `startedAtEpochSeconds` value at activity start, map it compatibly to the client's `Date`, and reuse it for the activity lifetime so the device can render elapsed time locally. Retain the current stale-date and end/dismissal behavior.

Out of scope: Dynamic Island visual redesign, user-configurable cadence, background polling, and guaranteed APNs delivery.

Acceptance criteria:
- [ ] Routine progress/tool updates are sent with APNs priority 5; start, blocking, error, and end transitions use priority 10.
- [ ] Repeated events that do not change user-visible activity state do not emit another push merely because three seconds elapsed.
- [ ] Approval, clarification, error, and end updates bypass routine coalescing and are emitted immediately.
- [ ] Every update for one activity carries the same start epoch, and iOS renders elapsed time without per-second pushes.
- [ ] Timestamp encoding is explicitly tested across Python seconds and Swift `Date`, including backward compatibility with a missing field.
- [ ] Push budgets and stale/dismissal dates remain valid for both sandbox and production APNs.

Tests required: `pytest tests/plugins/hermes_mobile/test_push_engine.py tests/plugins/hermes_mobile/test_push_intake.py -k live_activity`; XCTest targets `LiveActivityManagerTests` and `HermesTurnAttributesTests`.

### ISSUE: Expose a revisioned pending-attention API
Phase: 0 | Spec: R-03,R-53,R-54 | Priority: urgent | Labels: type:feature, area:server
Depends-on: Return structured session status for live-turn re-entry
Inherited-context: none
Estimate: L

The mobile plugin exposes response endpoints around `plugins/hermes-mobile/dashboard/api.py:650-698` but no fetch contract for pending approvals or clarifications. Approval waiters live in the in-memory queue managed by `tools/approval.py:1414-1435` and `resolve_gateway_approval` at `:1468-1515`; entries created around `:2438-2498` do not carry a stable public record ID, revision, or timestamp. Clarification prompts are held in `_pending` and `_pending_prompt_payloads` in `tui_gateway/server.py:128-132` and populated around `:2083-2098`. Consequently, iOS `InboxStore.swift:6-30` can only reconstruct attention state from live broadcasts and cannot fetch truth after termination, disconnection, or another client's response.

Add a mobile-plugin API for an authenticated, device-scoped snapshot/delta of pending attention. Define public snapshot interfaces in the approval and clarification owners rather than importing their private maps. Each record must include stable record/request ID, kind, session and stored-session identity, safe display content, destructive flag, created/expiry times, lifecycle status, and monotonic revision. Return `server_instance_id`, a cursor, upserts, and tombstones; reset with a full snapshot when the instance changes or a cursor is too old. Maintain a bounded tombstone ledger so another client's response or expiry can remove stale client rows. Device credentials may see only sessions authorized for that device; shared gateway credentials keep their existing scope. Serialize under the same locks used to resolve waiters.

Gateway restart may establish a new instance and force reset; Phase 0 does not require preserving dead in-memory waiters across a process restart. Do not expose prompt secrets, credentials, raw tool arguments, or unrelated sessions. Background push invalidation and server-side durable approval storage are out of scope.

Acceptance criteria:
- [ ] An authenticated mobile client can fetch all currently pending approval and clarification records in its authorized scope.
- [ ] Every record has a stable ID, request ID, timestamps, status, and monotonic revision sufficient for idempotent reconciliation.
- [ ] Responding, expiry, cancellation, or resolution by another client emits a tombstone or terminal update.
- [ ] A valid cursor returns only newer changes; an old or foreign-instance cursor explicitly requests/reset-delivers a full snapshot.
- [ ] Tombstones and change history are bounded without allowing an old cursor to silently miss a deletion.
- [ ] Device-scoped credentials cannot enumerate another device's sessions, and response text/tool secrets are not leaked.
- [ ] Existing approve, deny, and clarification reply endpoints continue to resolve the same underlying waiters.

Tests required: new `pytest tests/plugins/hermes_mobile/test_pending_attention_api.py`; `pytest tests/tools/test_approval.py -k pending_snapshot`; `pytest tests/test_tui_gateway_server.py -k pending_prompt`; include auth-scope, cursor/reset, resolution, expiry, concurrency, and redaction cases.

### ISSUE: Persist and reconcile the approval Inbox
Phase: 0 | Spec: R-03,R-53,R-54 | Priority: urgent | Labels: type:feature, area:ios
Depends-on: Expose a revisioned pending-attention API
Inherited-context: none
Estimate: L

`InboxStore.swift:6-30` explicitly describes an in-memory accumulator of live broadcasts; its `items` array at `:91-104` is not persisted. It only models pending/answered/expired at `:37-45`, ingests live approval/clarification/completion events at `:143-216`, and optimistically removes responses before re-adding them on failure at `:220-295`. `AppEnvironment.swift:92-97` attaches the store to the live event stream only. `CacheStore.swift:18-49` and the migrations beginning in `CacheSchema.swift:38` provide the existing gateway-scoped SQLite foundation, but there is no attention table or cursor metadata.

Add scoped GRDB tables for attention records and reconciliation metadata, then make Inbox cache-first and server-reconciled. Hydrate persisted rows before connection/bootstrap completes, fetch the pending-attention API on launch and foreground, and reconcile on WebSocket events, notification tap/action completion, message completion, and explicit refresh. Store all mutations transactionally. Model at least pending, responding, resolved elsewhere, expired, and failed/retryable; do not silently remove an item until server truth confirms resolution. Namespace records and cursors by gateway identity, invalidate on server-instance reset, and drive widget pending counts from the same persisted snapshot.

Out of scope: BGAppRefresh/background polling, multi-account aggregation, conversation-content persistence beyond safe attention summaries, and Inbox visual redesign unrelated to state correctness.

Acceptance criteria:
- [ ] After force-quit and relaunch, cached pending items appear before the WebSocket reconnects and then converge to the server snapshot.
- [ ] An approval or clarification created while the app is terminated appears after the next launch fetch.
- [ ] An item resolved by another client is removed or marked resolved after reconciliation, including tombstone processing.
- [ ] Failed responses remain visible with a retryable state; a successful response is not resurrected by an older live event or snapshot.
- [ ] Cursor, revision, and server-instance handling are durable and idempotent across repeated launch/foreground fetches.
- [ ] Gateway switching and Forget Gateway cannot expose items from another gateway.
- [ ] Widget pending count and Inbox rows derive from the same committed database state.
- [ ] The Phase-0 killed-app acceptance case—Inbox remains correct after termination—passes on a physical device.

Tests required: XCTest targets `InboxStoreTests`, `CacheStoreTests`, `NotificationActionTests`, and new `InboxPersistenceTests`/`PendingAttentionClientTests`; add a migration test and a named physical-device target `KilledAppInboxReconciliationValidation`.

### ISSUE: Split Go Offline from Forget Gateway
Phase: 0 | Spec: R-02,R-60 | Priority: urgent | Labels: type:feature, area:ios
Depends-on: Persist and reconcile the approval Inbox
Inherited-context: STR-510
Estimate: L

`ConnectionStore.disconnect()` at `ConnectionStore.swift:1120-1160` stops the current connection and clears live state but intentionally leaves the saved server URL and Keychain gateway token. `ConnectionStore.bootstrap()` reloads both and reconnects at `:800-819`. The destructive Settings action at `SettingsView.swift:800-837` is nevertheless titled “Disconnect” and tells users they will need the URL and token again, creating a false trust boundary: it neither behaves as a temporary offline mode nor performs a durable forget.

Replace the ambiguous action with two explicit flows. **Go Offline** stops socket/reconnect/hydration work, enters a durable offline phase, preserves credentials and all local data, and reconnects only after an explicit user action. **Forget Gateway & Remove Local Data** requires destructive confirmation plus device-owner authentication, then runs one idempotent coordinator transaction: cancel live/background work; best-effort unregister push/device; clear saved URL, Keychain gateway token, device ID, API-path/capability/push-health state; delete scoped SQLite conversations and attention rows/cursors; clear queued/pending intents and drafts; clear Inbox, attachment blobs, share/App-Intent payloads, widget snapshots, Spotlight entries, and Live Activities; then return to onboarding. Existing cleanup owners include `QueueStore.swift:107-112`, `PendingIntent.swift:68-89`, `SharedStore.swift:20-42` and `:110-116`, `AttachmentBlobCache.swift:205-219`, and `SpotlightIndexer.swift:79-90`.

If remote unregister/revoke cannot complete, persist only a protected cleanup tombstone containing the minimum non-content identifiers needed to retry after a future authorized pairing to the same gateway; never retain the old gateway credential merely to retry. The transaction must be safe after interruption and on repeated invocation.

Out of scope: an option to preserve downloaded conversations, server-side deletion of conversation history, cross-device revocation, and recovery of intentionally erased local data.

Acceptance criteria:
- [ ] Go Offline survives app relaunch, does not auto-reconnect, and preserves credentials, cached conversations, Inbox, queue, and user settings.
- [ ] Explicit Reconnect leaves offline mode and resumes the established bootstrap path.
- [ ] Forget requires a second destructive confirmation and successful device-owner authentication before erasure begins.
- [ ] After Forget completes and after another relaunch, the app cannot reconnect without pairing and shows no former gateway conversation, Inbox, attachment, widget, Spotlight, share, queued-intent, or Live Activity surface.
- [ ] URL, Keychain gateway token, device ID, push/capability health, API-path cache, and gateway-scoped database rows are cleared.
- [ ] Remote cleanup failure cannot block local privacy completion; a minimal protected tombstone records the retry without credentials or content.
- [ ] The coordinator is idempotent and resumes safely after cancellation or termination between cleanup steps.
- [ ] Data belonging to a different configured gateway is not accidentally erased unless the product explicitly invokes an all-gateways reset.

Tests required: new XCTest targets `GatewayForgetCoordinatorTests` and `ConnectionOfflineModeTests`; extend `ConnectionStoreReconnectTests`, `CacheStoreTests`, `InboxPersistenceTests`, `QueueStoreTests`, `PendingIntentTests`, `SharedStoreTests`, `AttachmentBlobCacheTests`, `SpotlightIndexerTests`, and `LiveActivityManagerTests` with success, relaunch, interruption, remote-failure, and idempotency cases.

### ISSUE: Make self-revoke forget locally and fence stale async work
Phase: 0 | Spec: R-61 | Priority: urgent | Labels: type:fix, area:ios
Depends-on: Split Go Offline from Forget Gateway
Inherited-context: STR-510, STR-520, STR-1825
Estimate: M

Successful current-device revoke currently clears the device ID but deliberately leaves the now-invalid Keychain gateway token at `DevicesView.swift:313-325`, then calls `ConnectionStore.handleCurrentDeviceRevoked`. That handler's immediate close-race defense is already correct at `ConnectionStore.swift:1598-1609`. Broader async work can still overwrite terminal state: `handle(state:)` accepts `.open` and sets connected at `:1369-1396`; the reconnect loop awaits recovery and then assigns connected at `:1448-1522`; scene activation captures `hasConnected` only before awaits at `:1897-1913` and can later start reconnect after probes at `:1958-1984`.

On successful self-revoke, invoke the same local Forget transaction as Settings so the invalid credential and all former-gateway local surfaces are erased. Add a monotonically increasing connection generation/epoch that changes on configure, offline, disconnect, forget, and current-device revoke. Every async bootstrap, reconnect, hydration, recovery, probe, scene-phase, and socket-state path must capture the generation and revalidate it plus the terminal flags after each await and immediately before phase mutation or reconnect scheduling. Guard `.open` from restoring connected state after forget/reauthentication. Keep the already-fixed one-shot revoke behavior and device-load single-flight logic intact.

Out of scope: revoking other devices, fixing the stale STR-1824 test claim without a reproduction, and replacing structured concurrency throughout the app.

Acceptance criteria:
- [ ] A successful self-revoke removes the Keychain gateway token and executes the complete local Forget transaction before presenting onboarding/repair.
- [ ] A late `.open`, `.closed`, hydration completion, session recovery, health probe, or reconnect completion from an older generation cannot change the terminal forgotten state.
- [ ] No reconnect task is created after self-revoke or Forget unless the user pairs/configures again, creating a new generation.
- [ ] Repeated revoke callbacks and repeated Forget calls remain idempotent.
- [ ] Revoke of another device does not erase this device's local state.
- [ ] Existing current-device revoke and device-load single-flight tests remain green.

Tests required: extend XCTest targets `DevicesTests`, `ConnectionStoreReconnectTests`, and `GatewayForgetCoordinatorTests`; add deterministic suspended-operation cases for late open/closed, hydrate, recover, probe, scene activation, and reconnect completion across a generation change.

### ISSUE: Cut every device-authenticated WebSocket on revocation
Phase: 0 | Spec: R-61 | Priority: urgent | Labels: type:fix, area:server
Depends-on: none
Inherited-context: STR-509
Estimate: M

The revoke endpoint at `plugins/hermes-mobile/dashboard/api.py:650-698` closes sockets returned by `device_tokens.get_device_sockets`; that registry is defined at `plugins/hermes-mobile/dashboard/device_tokens.py:53-59`. The main `/api/ws` route registers and deregisters its socket at `hermes_cli/web_server.py:15630-15657`, but device-authenticated `/api/console` (`:15088-15122`), `/api/pub` (`:15672-15700`), and `/api/events` (`:15703-15740`) authenticate without joining the registry. A revoked device can therefore retain already-open non-main WebSockets until transport failure.

Centralize device-socket registration in a small lifecycle helper/context manager and apply it to every route that accepts a device credential, preserving route-specific auth and cleanup. Revoke must close all sockets for that device with code 4401 and an authentication-safe reason, tolerate simultaneous disconnect/deregistration, and never close sockets authenticated only by an unrelated shared token. Keep the already-registered main WS and PTY behavior working; audit all WebSocket route declarations rather than fixing only the three known examples.

Out of scope: rotating shared gateway tokens, revoking other device IDs, server-process restarts, and changing WebSocket protocols.

Acceptance criteria:
- [ ] Every currently declared WebSocket endpoint that accepts device authentication registers and deregisters the socket under the authenticated device ID.
- [ ] Revoking that device closes its open main, console, pub, events, and any other device-authenticated sockets with code 4401.
- [ ] Concurrent natural disconnect and revoke cannot leak a registry entry or raise an unhandled exception.
- [ ] Shared-token-only sockets and sockets belonging to another device remain open.
- [ ] New device-authenticated WebSocket routes have one reusable registration path and a test that fails if registration is omitted.
- [ ] A revoked credential cannot reconnect to any audited endpoint.

Tests required: extend `pytest tests/plugins/hermes_mobile/test_device_tokens_ws.py`; add route integration cases for `/api/ws`, `/api/console`, `/api/pub`, `/api/events`, PTY if device-authenticated, concurrent close, shared-token isolation, and post-revoke reconnect refusal.

### ISSUE: Shield app-switcher snapshots immediately
Phase: 0 | Spec: R-62 | Priority: urgent | Labels: type:fix, area:ios
Depends-on: none
Inherited-context: none
Estimate: S

`RootView.swift:41-51` shows an opaque cover only when `AppLock.isLocked`. `AppLock.swift:44-54` grants a five-minute grace period, and `handleScenePhase` at `:112-138` records background time without locking until that timeout. During brief inactive/background transitions, the app switcher can therefore snapshot the transcript even though returning to the app correctly avoids Face ID.

Separate privacy shielding from authentication lock state. Expose a process-local `isPrivacyShieldVisible` state that becomes true synchronously for `.inactive` and `.background` and false only after returning `.active`; render a fully opaque, non-sensitive cover at the highest app layer so no transcript, Inbox, attachment, or navigation text participates in the app-switcher snapshot. Preserve the five-minute authentication grace period exactly: a two-second Control Center or app-switcher visit hides content but does not itself require authentication on return.

Out of scope: changing the lock timeout, screenshot prevention while the app is actively visible, screen-recording detection, and visual redesign of the lock screen.

Acceptance criteria:
- [ ] Entering inactive or background state immediately covers all sensitive UI before the app-switcher snapshot is captured.
- [ ] The cover contains no session title, message text, Inbox content, attachment preview, or gateway-identifying data.
- [ ] Returning within the configured grace period removes the shield without requiring authentication.
- [ ] Returning after the grace period keeps the opaque shield until successful authentication.
- [ ] The privacy shield works when App Lock is disabled as a snapshot-privacy boundary.
- [ ] Rapid active/inactive/background transitions cannot briefly reveal stale content above the cover.

Tests required: XCTest targets `AppLockTests` and new `PrivacyShieldTests`; add a rendering/snapshot target that asserts sensitive sentinel text is absent from the covered hierarchy in inactive and background states.

### ISSUE: Reject App Lock when no device passcode exists
Phase: 0 | Spec: R-63 | Priority: urgent | Labels: type:fix, area:ios
Depends-on: none
Inherited-context: none
Estimate: S

`AppLock.setEnabled` at `AppLock.swift:80-92` persists the enabled setting without checking Local Authentication availability. `LAContextAuthenticator.evaluate` at `:193-218` treats `LAError.passcodeNotSet` as success at `:203-205`. The Settings toggle at `SettingsView.swift:503-514` directly enables the feature and shows no refusal guidance. A user can therefore believe App Lock is protecting the app on a device with no passcode.

Add an explicit authenticator capability result that distinguishes available device-owner authentication from no passcode, unavailable policy, lockout, cancellation, and evaluation failure. Enabling App Lock must first prove that device-owner authentication is configured; otherwise leave the persisted setting off and show actionable guidance to enable a device passcode in iOS Settings. If a previously protected device later loses its passcode, do not silently authenticate or reveal content: keep the privacy/lock cover and present recovery guidance until the passcode is restored or the user completes an explicitly authenticated/approved reset path consistent with platform capability.

Out of scope: requiring biometrics specifically when a passcode is available, opening private Settings URLs, MDM policy management, and custom PIN storage.

Acceptance criteria:
- [ ] On a device/simulator reporting `passcodeNotSet`, enabling App Lock is refused and the setting remains false after relaunch.
- [ ] The user sees clear guidance that an iOS device passcode must be enabled; the UI never claims App Lock is active.
- [ ] `passcodeNotSet` is never converted into authentication success.
- [ ] A device with passcode but no enrolled biometrics can use the normal device-owner authentication fallback.
- [ ] If passcode capability disappears while App Lock was enabled, sensitive content remains covered and the condition is recoverable without silently disabling protection.
- [ ] Cancellation, lockout, and ordinary authentication failure remain distinct from missing-passcode setup failure.

Tests required: XCTest targets `AppLockTests` and `SettingsViewTests`; add capability-matrix cases for available biometrics, passcode fallback, passcode not set, lockout, cancellation, and capability loss after enablement.

LANE_RESULT: done Verified all Phase-0 premises at current HEAD and produced 13 dependency-ordered, build-sized issue drafts covering every requested R-item plus inherited STR-953 and STR-509 correctness work; already-fixed or PR-owned work is explicitly reconciled rather than duplicated.