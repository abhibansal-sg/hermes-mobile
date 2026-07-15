# Hermes Mobile iOS Audit — Structured Inventory (from final ChatGPT audit message)

Source: `/Volumes/MainData/Runtime/Hermes/cache/web/chatgpt.com-d9aa778fb4.md` — third and final ChatGPT reply, titled "Hermes Mobile iOS — Fresh Full Audit," covering `abhibansal-sg/hermes-mobile` @ commit `73a6ee5ed7e8a4dc8ef479dd9b178bb3739f6027`, branch `environment-and-workflows-overview`. Static source audit only (no Xcode archive build, no Instruments, no on-device APNs test).

## 1. Section/Heading Outline (final message, sections 1–19)

1. Audit scope and confidence
2. Executive verdict (incl. Assessment scorecard table)
3. Highest-priority findings — P0 / P1 / P2
4. Notifications audit — 4.1 What is already strong; 4.2 Confirmed notification defects and gaps (N1–N9); 4.3 Server push-delivery reliability
5. Live Activities audit — 5.1 Strong implementation details; 5.2 Priority and cadence too aggressive; 5.3 Remote start not implemented; 5.4 Multiple simultaneous turns need a rule
6. Background execution and refresh — 6.1 Current state; 6.2 Recommended layered background architecture (Layers 1–8)
7. Making the app fresh after a long absence — 7.1 Current cold-launch flow; 7.2 Recommended launch experience; 7.3 Single sync-manifest endpoint
8. Cache, offline storage, drafts, and outbox — 8.1 Existing strengths; 8.2 C1 session list not reconciled; 8.3 C2 scope not part of DB identity; 8.4 C3 drafts memory-only; 8.5 C4 outbox not exactly-once; 8.6 C5 pending App Intent last-write-wins; 8.7 C6 attachment cache freshness weak; 8.8 C7 panel data live-only; 8.9 Add offline search
9. Inbox and approvals — 9.1 Strong action behavior; 9.2 I1 Inbox process-memory only; 9.3 Recommended pending-attention contract
10. Widgets — 10.1 Current design; 10.2 W1 cold-process snapshot overwrite risk; 10.3 W2 widget metrics not authoritative; 10.4 Recommended widget snapshot schema
11. Share extension and App Intents — 11.1 Share extension strengths; 11.2 Share queue gaps; 11.3 QR scanner lifecycle is polling-based
12. Security and privacy — 12.1 Good credential posture; 12.2 S1 disconnect not durable; 12.3 Self-revoke should wipe immediately; 12.4 S2 app-switcher privacy not immediate; 12.5 S3 app lock silently succeeds w/o passcode; 12.6 Spotlight/Handoff exposure; 12.7 Global pasteboard retention; 12.8 Pairing secrets in URLs; 12.9 Plain HTTP posture; 12.10 Privacy manifest/archive verification
13. Full feature-by-feature audit (table across all surfaces)
14. UI, interaction design, and accessibility — 14.1 Strong UI work; 14.2 U1 hydration blocks cached content; 14.3 U2 missing freshness language; 14.4 U3 nested controls in cron rows; 14.5 U4 device rows not semantic controls; 14.6 U5 toasts need assistive announcements; 14.7 Accessibility test coverage should broaden; 14.8 Localization
15. Architecture and maintainability (recommended decomposition into 7 coordinators/services)
16. Observability and diagnostics (client metrics, gateway metrics, in-app diagnostics screen)
17. Required testing matrix (Notifications, Background refresh, Cache/dormancy, Outbox/transfers, Privacy, UI/accessibility)
18. Recommended implementation roadmap — Phase 0/1/2/3/4 with acceptance criteria
19. Final assessment (incl. "five changes that will improve the app most")

---

## 2. Complete Item Inventory (ID · Section · Already Does vs Missing/Recommended · Phase)

**§3 — Priority tables**
- **R-01** [§3 P0] Short-turn notification bug: turns <30s suppress `turn_complete`. **HAS:** PR #145 fix drafted (attention-gate + 4hr expiry), not merged. **MISSING:** merge + live-device validation. → Phase 0
- **R-02** [§3 P0] Disconnect not durable: URL/token survive "Disconnect." **HAS:** UI claims destructive disconnect. **MISSING:** split Go-Offline vs Forget-Gateway wipe transaction. → Phase 0
- **R-03** [§3 P0] Inbox is process-memory only, empty after termination even if server is blocked. **MISSING:** server pending-attention endpoint + persisted snapshot. → Phase 0
- **R-04** [§3 P0] Cold-launch notification actions race SwiftUI bootstrap. **MISSING:** install delegate/categories at `didFinishLaunchingWithOptions`, resolve credentials from persistent storage. → Phase 0
- **R-05** [§3 P0] No authoritative long-dormancy sync protocol; sessions/approvals/widgets/cache disagree. **MISSING:** revisioned sync manifest with deltas/tombstones. → Phase 1
- **R-06** [§3 P1] No `BGAppRefreshTask`/`BGProcessingTask`/background push sync — data only freshens on open. **MISSING:** layered background refresh architecture. → Phase 1/2
- **R-07** [§3 P1] Local + remote notifications can overlap/duplicate. **MISSING:** make APNs authoritative, local fallback only, dedupe by event/request/session ID. → Phase 0
- **R-08** [§3 P1] Live Activity updates default priority 10 every 3s. **MISSING:** priority 5 for routine, priority 10 reserved for urgent/terminal events. → Phase 0
- **R-09** [§3 P1] Session cache upserts w/o authoritative deletion. **MISSING:** generation-based reconciliation/tombstones. → Phase 1
- **R-10** [§3 P1] Outbox/drafts durability incomplete; can lose prompts on crash. **MISSING:** protected SQLite + idempotency keys + message states. → Phase 2
- **R-11** [§3 P1] Attachment cache freshness/eviction unfinished (same-size-but-changed files stay stale). **MISSING:** content versions/ETags + LRU/TTL eviction. → Phase 2
- **R-12** [§3 P1] Widget state not authoritative, can show stale numbers, loses fields on process restart. **MISSING:** merge-from-disk snapshot writer with timestamps/staleness. → Phase 1
- **R-13** [§3 P1] Cached UI hidden during hydration — full-screen loader over usable cache. **MISSING:** render cached shell + nonblocking "Syncing" state. → Phase 1
- **R-14** [§3 P2] No stale-while-revalidate caching for usage/cron/skills/providers/devices/archives/files/artifacts panels. → Phase 3
- **R-15** [§3 P2] No notification privacy/quiet-hours/threading/interruption-level preferences. → Phase 3
- **R-16** [§3 P2] No privacy manifest / archive-time privacy+entitlement checks. → Phase 3
- **R-17** [§3 P2] Multiwindow ownership weak; oversized coordination stores need decomposition. → Phase 3 (partly §15)
- **R-18** [§3 P2] Accessibility testing needs expansion beyond mechanical identifiers. → Phase 3

**§4 Notifications**
- **ALREADY STRONG (4.1):** APNs registration flow (auth request, `registerForRemoteNotifications`, token→hex, gateway registration, event-preference tracking, environment tracking, re-registration on change, serialized overlapping intents); server segregates sandbox/production tokens with atomic 0600 writes; five event classes (approval, clarification, turn completed, turn error, background job completed) consistently modeled server-side with legacy "all events" preserved; Approve/Deny use `.authenticationRequired`, destructive actions get extra `LAContext` biometric check, completion handler delayed until network response returns (correct pattern); path-family self-healing retry on 404 for approval/Live Activity token calls.
- **R-19** [§4.2 N1] Short turns suppressed (duplicate of R-01, includes full test matrix: 5s foreground/locked, 45s foreground/other-app, offline-then-online within/after 4hrs, kanban/worker turns, worker approvals). → Phase 0
- **R-20** [§4.2 N2] Notification setup installed too late (SwiftUI `.task`, not AppDelegate). **MISSING:** `NotificationCoordinator.shared.install()` from `didFinishLaunchingWithOptions`, queuing nav intents until `AppEnvironment` ready, using cached API path style, independent of live WebSocket. → Phase 0
- **R-21** [§4.2 N3] APNs registration failure swallowed — `PushRegistrar.didFailToRegister` does nothing. **MISSING:** persist non-secret health state (last token time, last attempt/success, error category, environment, gateway capability, last HTTP outcome, last test-notification correlation ID, relay/direct status) shown in a "Notification Health" section. → Phase 3
- **R-22** [§4.2 N4] Notification disable not durably reconciled — local state cleared even if server unregister fails. **MISSING:** persist unregister tombstone (token hash, scope, env, attempt timestamps/count), retry on launch/foreground/background until confirmed. → not explicitly phase-tagged (implied Phase 3 diagnostics)
- **R-23** [§4.2 N5] Local/remote notifications can duplicate (dup of R-07): needs one authority (APNs), event_id/request_id/session_id tagging, dedupe set with TTL, deterministic request IDs, in-foreground haptic instead of banner for active session. → Phase 0
- **R-24** [§4.2 N6] Clarification Reply action has no auth requirement, unlike Approve/Deny. **MISSING:** `.authenticationRequired` on Reply action. → not explicitly phased (falls under Phase 0 trust items)
- **R-25** [§4.2 N7] Notification payloads can expose sensitive agent content (first-line output, approvals, questions) with only regex redaction. **MISSING:** privacy setting (Full preview / Generic / Hidden), default Generic when app lock enabled, opaque IDs + fetch-after-unlock. → Phase 3
- **R-26** [§4.2 N8] Missing `thread-id`, interruption level, relevance score, target-content-identifier, collapse-ID, `loc-key`/`loc-args`, per-session mute. **HAS RECOMMENDED TABLE:** Approval=Time Sensitive (opt-in)/match expiry/session-thread; Clarification=Time Sensitive or Active; Turn complete=Active/4hr; Turn error=Active/1–4hr; Background job=Passive-Active/several hrs; Test=Active/0. → Phase 3
- **R-27** [§4.2 N9] Badge permission requested but no badge model exists. **MISSING:** authoritative pending-attention badge count OR stop requesting badge permission. → not phase-tagged explicitly
- **R-28** [§4.3] Server push queue is process-memory only, capped 512, drops oldest when full — notifications can be permanently lost on crash/restart. **MISSING:** durable `push_outbox` SQLite table (event_id, device_id, event_kind, session_id, request_id, payload, priority, expiration_at, collapse_id, status, attempt_count, next_attempt_at, last_apns_status/reason, created_at) with retry/backoff, `Retry-After` respect, permanent token pruning on `BadDeviceToken`/`DeviceTokenNotForTopic`, APNs request-ID logging, expired-event skip, UI should say "accepted by APNs" not "delivered." → Phase 1 (background push layer)/Phase 3 (diagnostics)

**§5 Live Activities**
- **ALREADY STRONG (5.1):** one owned activity lifecycle; push token observation/rotation; gateway token register/unregister; generation guards vs stale responses; FIFO content-state delivery; orphan reconciliation on foreground; local stale watchdog; immediate manager-state detachment before deferred dismissal; terminal cleanup + server token pruning; widget UI uses on-device timer instead of pushing elapsed seconds.
- **R-29** [§5.2] Non-final updates allowed every 3s at priority 10 (dup of R-08). **MISSING:** priority 5 for thinking/tool-start/progress/nonurgent; priority 10 only for approval/clarification/error/terminal completion; semantic (not timer-based) update triggers; stable `startedAtEpochSeconds` in content state so widget can compute elapsed locally. → Phase 0
- **R-30** [§5.3] Remote/push-to-start not implemented — Live Activity only starts from an already-running foreground process observing local turn start; desktop-started turns don't spawn an activity on a terminated phone app. **MISSING:** ActivityKit push-to-start token registration. → Phase 4
- **R-31** [§5.4] No explicit rule for multiple simultaneous turns (desktop/cron/background/subagents) sharing the one owned activity. **MISSING:** product rule — latest user-owned turn wins; approval always preempts; kanban workers don't own phone surface; background jobs use notifications not the activity; ownership changes must be visible. → not phase-tagged

**§6 Background execution**
- **CONFIRMED MISSING (6.1, dup of the earlier reply's finding-4):** No `BGAppRefreshTask`, `BGProcessingTask`, `BGContinuedProcessingTask`, `BGTaskSchedulerPermittedIdentifiers`, background remote-notification handling, `UIBackgroundModes` entries, background `URLSession` transfer manager, or app-relaunch callback for background URLSession completion. AppDelegate only handles APNs token callbacks; plist has Live Activity config but no background-mode array.
- **R-32** [§6.2 Layer 1] Visible APNs alerts (approval/clarification/turn-complete/turn-error/background-job-complete) — **ALREADY EXISTS**, informational only, not a sync mechanism.
- **R-33** [§6.2 Layer 2] Background push as invalidation signal (`content-available:1` + `sync{scope,revision,reason}`), used for session-list invalidation, pending-approval count, widget summary, active-turn summary, deletion/archive tombstones — client should fetch a delta, not trust payload as data source; not for streaming tokens, WebSocket replacement, large downloads, or exact scheduling. **MISSING entirely.** → Phase 1
- **R-34** [§6.2 Layer 3] `BGAppRefreshTask` (e.g. `ai.hermes.app.refresh`): load gateway scope → resolve Keychain token → request sync manifest/delta → one SQLite transaction → refresh widget snapshot → reschedule → complete immediately. **MISSING.** → Phase 1
- **R-35** [§6.2 Layer 4] `BGProcessingTask` (e.g. `ai.hermes.app.maintenance`) for cache eviction, attachment LRU cleanup, orphaned share-image cleanup, SQLite checkpoint/vacuum, Spotlight reindex/purge, expired outbox/Inbox cleanup, cache integrity checks; register at launch not lazily. **MISSING.** → Phase 2 (implied by attachment/outbox items) 
- **R-36** [§6.2 Layer 5] Background `URLSession` with identified config for large attachment uploads, artifact downloads, file exports, any transfer expected to survive backgrounding — `sessionSendsLaunchEvents=true`, persist transfer records, restore session ID on relaunch. **MISSING.** → Phase 2
- **R-37** [§6.2 Layer 6] Brief `beginBackgroundTask` state flush only (persist draft, commit outbox state, store sync cursor, flush widget snapshot, persist pending notification navigation intent) — not a keepalive, end promptly. **MISSING as formalized flow.** → implied Phase 1/2
- **R-38** [§6.2 Layer 7] `BGContinuedProcessingTask` (iOS 26+) only for user-started ops with visible progress (large archive export, large local report, media transformation) — not for routine sync/hidden maintenance. **MISSING**, optional. → Phase 4 (advanced/optional bucket, though not explicitly listed there — closest analog)
- **R-39** [§6.2 Layer 8] Background audio mode only if genuine locked-screen hands-free voice becomes a real feature; current voice loop is deliberately foreground-only (explicit non-goals: VAD, barge-in, CarPlay, route selection). **MISSING/optional**, do not add merely to prevent suspension. → Phase 4

**§7 Freshness after long absence**
- **ALREADY BUILT (7.1):** saved URL + Keychain token bootstrap; cache-first session-list paint; cache-first transcript opening; liveness probe; immediate reconnect attempt; session resume; transcript backfill; foreground session-list refresh; recent-transcript prefetch.
- **R-40** [§7.1] Despite cache-first data, `.hydrating` state shows a full-screen branded loader (`RootView`/`HydrationLoadingView`), hiding the cached shell — "cache-first data, network-first experience." (= U1, R-13 dup) → Phase 1
- **R-41** [§7.2] Recommended first paint: cached drawer, last-opened session/local draft, cached transcript, cached widget/attention counts, freshness label ("Last synced 6 days ago · Connecting…"). **MISSING.** → Phase 1
- **R-42** [§7.2] Recommended concurrent recovery sequence: resolve credentials → fetch sync manifest → open WebSocket → re-register APNs if needed → fetch pending approvals → reconcile capabilities → reconcile visible transcript → refresh widget summary → prefetch recent transcripts only once interactive. **MISSING as an orchestrated flow.** → Phase 1
- **R-43** [§7.2] User-interaction rules during sync: reading/search/draft composition remain available; sending queues durably without runtime; destructive actions disabled until freshness established; explicit states (Offline/Connecting/Syncing/Fresh/Sync-failed-cached-shown). **MISSING.** → Phase 1
- **R-44** [§7.3] Single authoritative sync-manifest endpoint (`server_time`, `revision`, `next_cursor`, `capabilities_version`, `sessions.upserts/tombstones`, `pending_attention`, `active_turns`, `transcript_heads`, `widget_summary`, `push_registry.device_registered`) applied in one SQLite transaction + one observable state publish. **MISSING.** → Phase 1

**§8 Cache/offline/drafts/outbox**
- **ALREADY BUILT (8.1):** scoped session/message/meta records via GRDB; queue + WAL + foreign keys; excluded from backup; cached session list before network; cached transcript before resume; in-place transcript reconciliation; conservative freshness; delta cursor support; recent-transcript prefetch; transcript eviction; graceful fallback when cache construction fails.
- **R-45** [§8.2 C1] Session list upserted, never reconciled — deleted/archived sessions can reappear offline; sessions removed by another client can survive indefinitely. **MISSING:** server tombstones w/ monotonic revision, OR full-snapshot generation marking, OR dedicated `/sessions/deleted?after=cursor` feed. → Phase 1
- **R-46** [§8.3 C2] Scope not part of DB identity (collision risk across gateways/profiles). **MISSING:** composite `PRIMARY KEY(server_id, profile_id, session_id)` applied to messages, sync metadata, attachments, pending approvals, outbox items, last-opened session, panel snapshots. → not explicitly phased (implied Phase 1 schema work)
- **R-47** [§8.4 C3] Drafts are memory-only (`startDraft()`), lost on force quit/crash/update/memory pressure. **MISSING:** `drafts` table (draft_id, server_id, profile_id, text, model_selection, cwd, attachment_refs, created_at, updated_at), autosave debounce, restore by scope, remove only after server-acknowledged submission. → Phase 2
- **R-48** [§8.5 C4] Outbox durability not exactly-once (`QueueStore` in UserDefaults; crash after server accept but before local completion = ambiguous). **MISSING:** SQLite outbox table (outbox_id/idempotency key, scope, stored/runtime session id, text, attachment_refs, state, attempt_count, next_attempt_at, last_error, timestamps), server `prompt.submit` accepting `client_message_id`, visible states (Waiting/Uploading/Sending/Sent/Failed-Retry/Cancelled). → Phase 2
- **R-49** [§8.6 C5] Pending App Intent is last-write-wins in UserDefaults — not durable for rapid multi-request Siri/Shortcuts use. **MISSING:** use same durable job/outbox repo as share items/prompts, small queue + expiration. → Phase 2
- **R-50** [§8.7 C6] Attachment cache freshness weak — keyed on scope/path/byte-size only; same-size-changed file stays stale; eviction "not fully wired" per code comments. **MISSING:** ETag/content hash, remote mod timestamp/version, MIME type, byte count, last access/created time, scope; plus LRU byte cap, TTL, per-scope purge, orphan scan, off-main decoding, image downsampling, memory-cache-over-disk-cache, disk-pressure reaction. → Phase 2
- **R-51** [§8.8 C7] Panel data (usage, cron, skills, providers, devices, archived sessions, file listings, artifacts) is live-only/transient, no last-known-value. **MISSING:** stale-while-revalidate (last snapshot shown, "Updated 3 days ago," background refresh, replace on success, preserve stale on failure). Mutating panels still require live connection. → Phase 3
- **R-52** [§8.9] No offline search despite persisted transcript content. **MISSING:** SQLite FTS for offline conversation search, instant initial results, merge with remote/global results when connected, scoped + purged on Forget Gateway. → not explicitly phased (adjacent to Phase 1/3)

**§9 Inbox/approvals**
- **ALREADY BUILT (9.1):** approval/clarification cards; per-session targeting; double-submit guards; dismiss/clear-expired affordances; biometric protection on destructive notification actions; feedback when another client already handled a request.
- **R-53** [§9.2 I1] `InboxStore` is process-memory only, populated solely from live broadcast events, no durable snapshot or startup REST fetch — after termination, Inbox/widget pending count can show empty/zero even though server is blocked on user. **Major seamlessness gap.** (dup of R-03) → Phase 0
- **R-54** [§9.3] Recommended `GET /api/attention/pending?after=<cursor>` returning approval/request ID, session IDs, prompt kind, safe title, detailed content, destructive flag, created/expires time, status, revision — reconciled on launch, foreground, `BGAppRefreshTask`, background invalidation push, notification tap/action, WebSocket event, turn completion, another-client resolution. Inbox states: Pending/Responding/Resolved-elsewhere/Expired/Failed-retry. **MISSING.** → Phase 0/1

**§10 Widgets**
- **ALREADY BUILT (10.1):** widgets read shared app-group snapshot; app is sole writer, reloads WidgetKit timelines on change; widget self-schedules 15-min timeline refresh (rereads same snapshot only).
- **R-55** [§10.2 W1] Cold-process snapshot overwrite risk: `AppEnvironment` writes baseline snapshot before bootstrap; `WidgetSnapshotWriter`'s `lastWritten` static resets per-process, so a cold launch can overwrite valid shared usage fields with nil. **MISSING:** read-merge-write pattern (read current disk snapshot, merge unspecified fields, never clear nonnil field without explicit clear op, include schema version + data-source revision, atomic write). → Phase 1
- **R-56** [§10.3 W2] Widget metrics not authoritative — "active sessions" is locally defined (1 if session open, else 0) not gateway's real count; pending approvals from volatile in-memory Inbox; connected status can go stale after suspension. **MISSING:** rename metrics honestly or populate from sync manifest. → Phase 1
- **R-57** [§10.4] Recommended widget snapshot schema: schema_version, server_scope, server_revision, connection_state, open_session_count, active_turn_count, pending_attention_count, tokens_today, cost_today, fetched_at, written_at, is_stale — render explicit stale state ("Last updated 2 days ago"), don't show stale "Connected" as current. **MISSING.** → Phase 1

**§11 Share extension/App Intents**
- **ALREADY BUILT (11.1):** share extension does no direct networking; resolves input, normalizes images, persists durable app-group job for main app to process later (correct architecture); drainer processes oldest-first, removes delivered items individually, leaves failures queued.
- **R-58** [§11.2] Share queue has no max item count, max byte budget, max age, orphaned-image sweep, per-job state, retry count, user-visible failed-share list, or content-protection strategy beyond platform default; partial failure can create duplicate server sessions on retry. **MISSING:** model each share as durable job (Queued/Creating destination/Uploading/Submitting/Completed/Failed/Expired) with stable idempotency key + destination session ID, 20-job (or configured) cap, total byte cap, 7–30 day TTL, orphan cleanup, failed-share UI with Retry/Delete. → Phase 2 (common job repository)
- **R-59** [§11.3] QR scanner polls `ConnectionStore.phase` every 200ms for up to 30s instead of awaiting a typed result. **MISSING:** expose an awaitable pairing API. → not phase-tagged

**§12 Security/privacy**
- **ALREADY GOOD (12.1):** gateway/provider credentials in Keychain incl. `ThisDeviceOnly` accessibility class; provider key entry is transient, deletes temp Keychain copy after provisioning.
- **R-60** [§12.2 S1] Disconnect UI claims URL/token needed to reconnect, but `disconnect()` leaves persisted URL + Keychain token intact; bootstrap reconnects automatically next launch (source comments acknowledge this). (dup of R-02) **MISSING:** Go-Offline (preserve creds/cache, stop reconnect, explicit Offline state, manual Reconnect) vs Forget-Gateway-&-Remove-Local-Data (confirmation + device-owner auth) — 15-step wipe transaction: persist/complete push unregister, revoke device token, clear saved URL, delete Keychain token, clear device ID, clear session/message cache, clear drafts/outbox, clear pending Inbox, clear attachment cache, clear pending share jobs/App Intents, clear widget snapshot, clear Spotlight items, end Live Activities, reset notification health/prefs, return to onboarding; optional advanced "preserve downloaded conversations" toggle. → Phase 0
- **R-61** [§12.3] Self-revoke clears device ID but intentionally leaves the now-invalid token in Keychain. **MISSING:** trigger same local-forget transaction immediately after self-revoke succeeds. → not phase-tagged (adjacent to Phase 0 wipe work)
- **R-62** [§12.4 S2] App-switcher content hidden only when `AppLock.isLocked`; App Lock requires re-auth only after 5-min absence, so switcher snapshot can show readable transcript during grace period. **MISSING:** separate immediate Privacy Shield (on `.inactive`/`.background`) from Authentication Lock (timeout-based). → Phase 0
- **R-63** [§12.5 S3] Device-owner auth silently "succeeds" when no device passcode exists, making App Lock ineffective. **MISSING:** refuse to enable App Lock, show "Set a device passcode before enabling Hermes App Lock." → Phase 0
- **R-64** [§12.6] Spotlight/Handoff index session titles/previews; `clearAll()` exists but current disconnect path doesn't call it. **MISSING:** clear during Forget Gateway, add "Show conversations in Spotlight" preference (default off with App Lock), reindex after authoritative delete/archive reconciliation, avoid Handoff previews for sensitive sessions. → Phase 3
- **R-65** [§12.7] Message/cron actions place content on global pasteboard with no expiration. **MISSING:** local-only expiring pasteboard items (`.localOnly:true`, `.expirationDate` ~120s) for sensitive content; explicit Share action for cross-device transfer. → Phase 3
- **R-66** [§12.8] Pairing supports URL payloads carrying gateway URL + token — durable secret in a deep-link/QR payload. **MISSING:** short-lived pairing code, one-time exchange, signed payload, expiration, intended bundle/audience, nonce/replay protection, server-side invalidation after first use; durable device token issued only after secure exchange. → not phase-tagged
- **R-67** [§12.9] Manual setup suggests `http://` while sending auth header over it. **MISSING:** require HTTPS for non-loopback/non-private hosts, permit HTTP only for loopback/LAN/tailnet, warn before saving insecure endpoint, never silently downgrade HTTPS→HTTP, show transport security state in Settings. → not phase-tagged
- **R-68** [§12.10] No app privacy manifest found referenced in the Xcode project. **MISSING:** `PrivacyInfo.xcprivacy` for required-reason APIs/declared data practices; should be an archive gate not a submission-time surprise. → Phase 3

**§13 Feature-by-feature table** — condensed strengths/gaps per surface (Onboarding/pairing, Chat/streaming, Composer, Sessions/drawer, Approval Inbox, Files, Artifacts, Voice/TTS, Cron, Usage analytics, Skills, Providers, Devices, Archived chats, Widgets, Share extension, App Intents, Spotlight/Handoff, Theming, Tests) — this table largely re-states findings already itemized above (R-45 through R-68, R-40, etc.) surface-by-surface; notable additive detail: Composer "queued prompts are text-only" (attachments not durably queued); Files "downloaded version semantics are weak"; Artifacts "gallery metadata not cached, blob invalidation/eviction incomplete"; Theming "needs automated contrast checks across every theme and accessibility contrast mode"; Tests "audit did not execute them; some UI/a11y tests deliberately narrow or skip without a live gateway."

**§14 UI/accessibility**
- **ALREADY STRONG (14.1):** adaptive `NavigationSplitView` vs. slide-over drawer; cache-first session switching; stable transcript identity; geometry-based sizing; keyboard/composer safe-area management; Reduce Motion handling in chat; accessible onboarding controls; proper loading/retry/empty/confirmation surfaces; native controls for most settings/management screens.
- **R-69** [§14.2 U1] `.hydrating` state replaces content with full-screen loader instead of showing stale-but-useful cache (dup of R-13/R-40). **MISSING:** cached shell + readable transcript + disabled destructive actions + "Syncing…" indicator + last-sync time + progress only where data absent; brand loading screen reserved for true first launch/empty cache. → Phase 1
- **R-70** [§14.3 U2] Missing freshness language across remotely-sourced screens (Sessions, Inbox, Devices, Cron, Usage, Skills, Providers, Artifacts, Widgets) — good loading/error components but no persisted freshness timestamp. **MISSING:** "Updated just now/2 hours ago," "Cached data," "Offline," "Sync failed," "Partial result." → Phase 1/3
- **R-71** [§14.4 U3] `CronJobRow` nests a `Button`-wrapped row plus Run/Pause/Resume buttons inside — confusing tap routing/VoiceOver. **MISSING:** `NavigationLink`/semantic row button + separate sibling action buttons. → not phase-tagged
- **R-72** [§14.5 U4] Device rows use `.onTapGesture` on a static stack. **MISSING:** `Button`/`NavigationLink` or `.accessibilityAddTraits(.isButton)` + explicit accessibility action + hint. → not phase-tagged
- **R-73** [§14.6 U5] Toast banners (job created/updated/deleted, share queued, copy success, pairing success, background sync failure, notification test result) are visual-only. **MISSING:** accessibility announcement/live-region update, not just haptics. → not phase-tagged
- **R-74** [§14.7] Mechanical accessibility UI test is narrow, skips live tests without gateway creds. **MISSING:** `XCUIApplication.performAccessibilityAudit`, all Dynamic Type sizes, VoiceOver reading order, Voice Control names, Reduce Motion, Differentiate Without Color, Increase Contrast, Button Shapes, Switch Control, RTL, landscape/iPad split views, long localized strings, notification actions while locked, Dynamic Island/Live Activity VoiceOver. → Phase 3
- **R-75** [§14.8] Known regions effectively English-only, many hardcoded strings. **MISSING:** String Catalog adoption across app UI, widget UI, Live Activity UI, notification titles/bodies (via payload localization keys), Siri/App Intent phrases, error/permission guidance. → Phase 3

**§15 Architecture/maintainability**
- **FINDING:** Complexity concentrated in `ConnectionStore`, `SessionStore`, `ChatStore`, `HermesMobileApp`, `MessageBubble`, `SettingsView` — combine network lifecycle, UI state, background concerns, cache orchestration, navigation, product policy.
- **R-76** [§15] **MISSING:** decompose into 7 dedicated types: `NotificationCoordinator` (authorization, categories, APNs token lifecycle, tap/action routing, health, dedup, privacy policy); `SyncCoordinator` (foreground/background refresh, manifest, cursors/revisions, atomic delta application, freshness state); `BackgroundTaskCoordinator` (BGTask registration/scheduling/expiration, maintenance task, state flush); `OutboxRepository` (drafts, prompt jobs, App Intent jobs, share jobs, retry/idempotency); `TransferManager` (background URLSession, attachment upload/download, transfer persistence, relaunch completion); `CacheRepository` (session/message cache, tombstones, search index, attachment metadata/eviction, scope purge); `PrivacyCoordinator` (switcher shield, app lock, Spotlight pref, pasteboard policy, Forget-Gateway transaction, notification preview policy). → Phase 3 (implied — maintainability/oversized stores item)

**§16 Observability/diagnostics**
- **R-77** [§16] **MISSING:** client metrics via `os.Logger`/signposts/MetricKit — launch-to-cached-shell paint, launch-to-first-fresh-manifest, WS reconnect duration, resume/backfill duration, last successful sync by scope, last BG refresh attempt/result, BG task expiration count, APNs token registration result, gateway push registration result, notification action latency/result, outbox depth/oldest age, attachment-cache bytes/evictions, orphaned-file count, widget snapshot age, main-thread hangs/scroll hitches, memory footprint for long transcripts, DB migration failures. → Phase 3
- **R-78** [§16] **MISSING:** gateway metrics — push outbox depth, oldest queued push age, APNs acceptance by event kind, APNs status/reason distribution, retry count, invalid-token pruning, relay-enqueue vs confirmed-delivery, Live Activity update priority/throttling, pending approval age, sync manifest latency/delta size. → Phase 3
- **R-79** [§16] **MISSING:** in-app diagnostics screen — app/build version, server scope, last connection/sync times, WS state, APNs environment, notification authorization, token registration health, push route (direct/relay), Background App Refresh availability, last BG task result, cache size, outbox count, widget snapshot age, last error categories, "Send test notification" w/ correlation ID, "Export redacted diagnostics." → Phase 3

**§17 Testing matrix** — six checklists (Notifications, Background refresh, Cache/dormancy, Outbox/transfers, Privacy, UI/accessibility) enumerating on-device scenarios to validate the above fixes; not independent recommendations but verification gates for R-01 through R-79 (e.g., cold-launch Approve/Deny/Reply, force-quit, device reboot, Low Power Mode, Wi-Fi↔cellular transition, session deleted/archived remotely, crash-before/after-send, App Lock w/o passcode, Dynamic Type/VoiceOver/RTL, etc.).

---

## 3. Phase 0/1/2/3/4 Roadmap (verbatim-condensed, with acceptance criteria)

### Phase 0 — Correctness and trust
1. Finish physical-device verification and land the short-turn notification fix.
2. Install notification delegation/categories during app launch.
3. Add persistent cold-launch credential resolution for notification actions.
4. Eliminate local/remote notification duplication.
5. Make Live Activity priority and cadence compliant.
6. Implement durable temporary disconnect versus Forget Gateway.
7. Add persistent/fetched pending-attention state.
8. Add immediate app-switcher privacy shield.
9. Reject App Lock enablement when the device has no passcode.

**Acceptance criteria:**
- A five-second turn finishing while locked produces exactly one completion alert.
- A killed-app approval action completes successfully.
- A clarification reply cannot execute from a locked device without authentication.
- Forget Gateway prevents automatic reconnection and removes local conversation surfaces.
- The Inbox remains correct after process termination.

### Phase 1 — Freshness protocol
1. Add sync-manifest API.
2. Add cursor/revision/tombstone tables.
3. Apply sync delta atomically.
4. Render cached shell during synchronization.
5. Add last-sync and stale states.
6. Add background invalidation pushes.
7. Add `BGAppRefreshTask`.
8. Refresh widget summary from the same manifest.

**Acceptance criteria:**
- Opening after a week shows cached content immediately.
- Deleted sessions do not reappear offline after a successful reconciliation.
- Inbox, widget, and drawer share the same revision.
- A missed push is recovered by foreground or app-refresh sync.

### Phase 2 — Durable user work and transfers
1. Move drafts to SQLite.
2. Move prompt queue to an outbox table.
3. Add server idempotency keys.
4. Persist send and retry state per message.
5. Add background URLSession transfer manager.
6. Make share/App Intent work use the common job repository.
7. Add attachment content-versioning and LRU eviction.

**Acceptance criteria:**
- Draft survives force quit.
- Retrying after ambiguous network failure does not double-submit.
- Large upload survives suspension or process termination.
- Failed share remains visible and retryable.
- Attachment cache remains bounded and version-correct.

### Phase 3 — Privacy, UX, and diagnostics
1. Add notification preview modes and quiet hours.
2. Add Spotlight/Handoff preference.
3. Add expiring local-only pasteboard.
4. Add privacy manifest and archive validation.
5. Add stale-while-revalidate panel snapshots.
6. Add Notification Health and Sync Health screens.
7. Add localization String Catalog.
8. Broaden accessibility and multiwindow testing.

*(No separate acceptance-criteria list given for Phase 3 in the source text.)*

### Phase 4 — Optional advanced capabilities
1. Live Activity push-to-start for remotely initiated turns.
2. Genuine background voice mode, only with a complete locked-screen experience.
3. Multiwindow scene-specific routing.
4. Rich notification content through a notification service extension.
5. User-selectable offline download policy for conversations and artifacts.

*(No acceptance-criteria list given for Phase 4.)*

---

## 4. "Five Changes That Will Improve the App Most" (§19, verbatim)

1. **A durable sync manifest with tombstones and pending attention.**
2. **Launch-time notification coordination with persistent cold-launch action support.**
3. **A real Forget Gateway transaction and immediate privacy shield.**
4. **A SQLite outbox/draft system with server idempotency.**
5. **A layered background architecture using background push, BGAppRefresh, BGProcessing, and background URLSession.**

Stated correct objective (framing quote): *"Make every important state durable, make every refresh revisioned and authoritative, use APNs as attention and invalidation, use BackgroundTasks for opportunistic catch-up and maintenance, use background URLSession for transfers, and render cached data honestly while synchronization occurs."* Explicitly **not** the objective: "make iOS keep the WebSocket alive."

---

## 5. "ALREADY BUILT per report" (consolidated, cross-referenced)

- **APNs alert notifications:** full registration flow (permission → `registerForRemoteNotifications` → token → hex → gateway registration), sandbox/production token segregation with atomic 0600 writes, event-type preference tracking + re-registration on change, serialized overlapping registration intents.
- **Actionable notifications:** Approve/Deny require `.authenticationRequired`; destructive actions get an additional `LAContext` biometric check; completion handler correctly delayed until the network response returns; clarification replies work from the notification (though currently unauthenticated — see R-24).
- **Path-family self-healing:** approval/Live Activity token calls retry once on the alternate API path family after a 404.
- **Live Activities:** `NSSupportsLiveActivities` enabled; starts with `pushType: .token`; token rotations observed and re-registered; remote updates use correct `.push-type.liveactivity` topic; payloads use `timestamp`/`event`/`content-state`; one owned activity lifecycle; generation guards against stale registration responses; FIFO content-state delivery; orphan reconciliation on foreground; local stale watchdog; immediate manager-state detachment before deferred dismissal; terminal cleanup + server token pruning; widget uses on-device timer instead of continuous elapsed-second pushes.
- **Foreground recovery / reconnect:** app assumes iOS may kill/suspend WebSocket in background; on foreground it probes liveness, reconnects immediately, resumes session, backfills messages, refreshes drawer — described as "the correct recovery model" and rated B+.
- **Cache-first architecture (SQLite/GRDB):** scoped session/message/meta records; queue + WAL + foreign keys; excluded from backup; cached session-list paint before network; cache-first transcript opening before resume; in-place transcript reconciliation; conservative freshness; delta cursor support; recent-transcript prefetch; transcript eviction; graceful fallback when cache construction fails.
- **Cold-launch bootstrap:** saved URL + Keychain token bootstrap; liveness probe; immediate reconnect attempt; session resume; transcript backfill; foreground session-list refresh; recent-transcript prefetch — described as "several excellent pieces" already in place.
- **Inbox (in-app):** approval/clarification cards, per-session targeting, double-submit guards, dismiss/clear-expired affordances, biometric protection for destructive notification actions, correct feedback when another client already handled a request.
- **Widgets:** shared app-group snapshot read model, app as sole writer, WidgetKit timeline reload on change, widget self-scheduled 15-min refresh, deep links, staleness timestamp support.
- **Share extension:** performs no direct networking; resolves input, normalizes images, persists a durable app-group job for the main app to process later (called "the right extension architecture"); drainer processes oldest-first, removes delivered items individually, leaves failures queued.
- **App Intents:** lightweight, foregrounds app, avoids independent gateway connections.
- **Security foundation:** gateway/provider credentials in Keychain with `ThisDeviceOnly` accessibility class; provider key entry is transient and deletes the temporary Keychain copy after provisioning — called "good foundations."
- **UI:** adaptive `NavigationSplitView` vs. slide-over drawer; cache-first session switching; stable transcript identity; geometry-based sizing; keyboard/composer safe-area management; Reduce Motion handling in central chat; accessible onboarding controls; proper loading/retry/empty/confirmation surfaces; native controls for most settings/management screens.
- **Code quality/tests:** "generally high" code quality; a "large collection of regression and test-seam coverage" exists in the Xcode project (though not executed during this audit, and some UI/a11y tests are deliberately narrow or skip without a live gateway).

---

## Notes on methodology
- Read the full 2,983-line / 87,815-char file via four sequential `read_file` calls (offsets 1, 501, 1001, 1501, 2001, 2501) to cover the entire document, including the generic iOS background-execution primer (turns 1) and the first shorter audit (turn 2) that precede the final full audit (turn 3, sections 1–19) — the primer/first-audit content was skimmed per instructions and excluded from the inventory since the task scoped extraction to the final message only.
- IDs R-01…R-79 were assigned by me (not present in source) to make every distinct finding/recommendation independently referenceable; several IDs intentionally note "(dup of R-xx)" where the source itself restates the same underlying issue across multiple sections (e.g., short-turn notification bug appears in §3, §4.2, and Phase 0; disconnect durability appears in §3, §7.1/§9 cross-refs, §12.2, and Phase 0).
- Phase tagging reflects explicit placement in §18's roadmap where stated; items without an explicit roadmap slot are marked "not phase-tagged" rather than guessed, to preserve fidelity to the source.