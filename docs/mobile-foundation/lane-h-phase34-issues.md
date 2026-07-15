# Lane H: Phase 3 + 4 issue drafts

Scope: Hermes Mobile iOS and `plugins/hermes-mobile/`, current checkout inspected 2026-07-15. Phase 3 behavior work is ordered before the R-76 decomposition mini-epic. The decomposition runs last, after Phase 2 and after behavior-changing Phase 3 issues touching the same domains.

## Verification summary

Cheap premise checks performed:

- `find apps/ios -name '*.xcprivacy'` returned no files. R-16/R-68 is verified.
- `CronJobRow` is an outer `Button` at `apps/ios/HermesMobile/Views/Panels/CronJobsView.swift:240` with Run/Resume/Pause child buttons at lines 305-318. R-71 is verified.
- Direct global pasteboard writes exist in message, chat, file, code-block, tool, settings, and cron surfaces. Examples: `MessageBubble.swift:225`, `ChatView.swift:2044`, `FileViewerView.swift:185`, and `CronJobsView.swift:336`. No expiring/local-only helper was found. R-65 is verified.
- `DevicesView.swift:149-183` uses a static `VStack` plus `.onTapGesture` for row navigation. R-72 is verified.
- `PushRegistrar.didFailToRegister(error:)` is a no-op at `Support/PushRegistrar.swift:314-320`; notification health persistence is absent. R-21 is verified.
- Notification opt-out clears the remembered token even when unregister hard-fails at `PushRegistrar.swift:80-117`; there is no unregister tombstone. R-22 is verified.
- The clarification Reply action uses `options: []` at `NotificationService.swift:599-605`. The R-24 residual is verified.
- `QRScannerView.swift:229-257` polls connection phase every 200 ms for up to 30 seconds. R-59 is verified.
- Pair URLs still accept `url` plus `token` in `HermesURLRouter.swift:74-84,167-239`. R-66's durable-secret premise is verified; the full server exchange design was not inspected.
- Generic `ConnectionStore.configure` accepts either HTTP or HTTPS at `ConnectionStore.swift:861-873`; only the manual-token QR path has private/local host hardening in `WSURLBuilder.swift:102-225`. R-67 is verified as a residual gap.
- The deployment target is iOS 17.0; no `BGTaskScheduler`, background `URLSession`, `BGContinuedProcessingTask`, notification service extension, or `UIBackgroundModes` declaration was found.
- `LiveActivityManager.swift:9,35-56,162-225` owns one locally started activity and registers only its update token. No push-to-start token API was found. R-30/R-31 is verified.
- No String Catalog or `.strings` resources were found under `apps/ios`. R-75 is verified.
- Existing accessibility coverage is narrow (`A11yMechanicalUITests.swift`, `ViewA11yTests.swift`); no `performAccessibilityAudit` use was found. R-18/R-74 is verified.
- Oversized types remain: `ConnectionStore` 2,060 lines, `SessionStore` 4,328, and `ChatStore` 3,646. R-76's concentration premise is verified.

Anything not supported by the checks above is marked `PREMISE-UNCHECKED` and must be verified when its issue starts.

## Untagged-item disposition

| Item | Disposition | Justification |
|---|---|---|
| R-22 | Phase 3, dedicated issue | Durable opt-out reconciliation is notification privacy/health work and is independently verified. |
| R-24 residual | Fold into “Enforce notification preview and locked-action privacy” | It is a small notification trust residual; pull it forward into Phase 0 if that lane has not closed. |
| R-27 | Phase 3, dedicated issue | Badge permission must match a truthful pending-attention model; this is UX/privacy cleanup, not an advanced API. |
| R-31 | Phase 4, fold into Live Activity push-to-start | Remote starts multiply ownership conflicts, so the single-activity product rule must ship with push-to-start. |
| R-59 | Phase 3, dedicated issue | Replacing polling with a typed awaitable result is current pairing UX/reliability work. |
| R-66 | Phase 3, dedicated issue | One-time pairing removes a durable credential from URLs and is privacy/security foundation work. |
| R-67 | Phase 3, dedicated issue | Transport validation protects the existing credential path and should precede optional Phase 4 features. |

## Phase 3 issues: privacy, UX, and diagnostics

### ISSUE: Enforce notification preview and locked-action privacy
Phase: 3 | Spec: R-25,R-24 | Priority: high | Labels: type:feature, area:ios, area:server
Depends-on: Phase 0 notification authority complete | Inherited-context: none | Estimate: L
Premise: VERIFIED

The gateway currently derives alert bodies from approval text, clarification questions, errors, and first-line output in `plugins/hermes-mobile/push_engine.py:1540-1618`; iOS registers clarification Reply without `.authenticationRequired` at `NotificationService.swift:599-605`. Add persisted Full, Generic, and Hidden preview modes. Generic is the default whenever App Lock is enabled. Generic/Hidden payloads carry opaque event/request/session identifiers and fetch sensitive detail only after foreground unlock. Add `.authenticationRequired` to Reply. Apply identical policy to direct APNs and relay payload construction; do not rely on regex redaction as the privacy boundary. Out of scope: notification service-extension rich media and quiet-hours scheduling.

Acceptance criteria:
- [ ] Full mode may include policy-approved preview text; Generic contains only event-class copy; Hidden contains no agent/session content.
- [ ] Enabling App Lock changes an unset/Full default to Generic after explicit user explanation; the user may later choose a stricter mode.
- [ ] Approve, Deny, and Reply cannot reach app handlers from a locked device before system authentication.
- [ ] Generic/Hidden action and tap flows fetch detail only after app authentication and handle expired/resolved events without leaking cached text.
- [ ] Direct and relay payload tests prove identical preview-policy results.
Tests required: extend `NotificationActionTests`, `NotificationReplyActionTests`, iOS settings tests, and `plugins/hermes-mobile` push/relay pytest coverage; physical locked-device action matrix.

### ISSUE: Add quiet hours, per-session mute, and APNs presentation metadata
Phase: 3 | Spec: R-15,R-26 | Priority: high | Labels: type:feature, area:ios, area:server
Depends-on: Phase 0 notification authority complete | Inherited-context: none | Estimate: L
Premise: VERIFIED (residual; see discrepancies)

Five per-event toggles already exist in `SettingsView.swift:452-500` and `DefaultsKeys.swift:120-159`; the residual is quiet hours, per-session mute, and event-specific APNs metadata. Persist device-local quiet hours with timezone and an explicit “approvals may break through” option. Extend device registration with quiet-hours and mute policy or enforce it at the authoritative gateway recipient filter. Emit `thread-id`, interruption level, relevance score, target-content-identifier, collapse ID, expiry, and localization keys/arguments per event class. Existing `build_push_headers` supports `collapse_id` but call paths do not expose the complete policy. Never claim Time Sensitive delivery unless the app has the entitlement and the user opted in.

Acceptance criteria:
- [ ] Quiet hours survive relaunch/timezone changes and suppress non-exempt events on both direct and relay routes.
- [ ] Muting one session never suppresses other sessions or device-wide test notifications.
- [ ] Approval uses the request expiry and session thread; clarification uses Time Sensitive only when entitled/opted in; completion/error/background events use the roadmap's Active/Passive levels and expirations.
- [ ] Every alert carries deterministic event/request/session identifiers and a stable collapse/thread policy.
- [ ] Settings explain Focus/Time Sensitive limits without promising delivery.
Tests required: iOS preference serialization tests; gateway table-driven payload/header tests for every event kind, timezone boundary tests, relay parity tests, and TestFlight Focus-mode checks.

### ISSUE: Persist notification registration health
Phase: 3 | Spec: R-21 | Priority: high | Labels: type:feature, area:ios
Depends-on: Phase 0 notification launch coordination complete | Inherited-context: PR #43 partial relay-health fix | Estimate: M
Premise: VERIFIED

`PushRegistrar.didFailToRegister(error:)` discards the error at `Support/PushRegistrar.swift:314-320`, while Settings only derives authorization and whether a token string exists at `SettingsView.swift:434-449`. Persist non-secret health per server scope: last APNs attempt/success, categorized APNs error, environment, last gateway register attempt/result/status, gateway capability, direct/relay route, and last test-notification correlation ID/result. Never persist or export the device token itself; only a short hash if correlation requires one. Provide a read model consumed by diagnostics rather than adding more ad hoc UserDefaults reads.

Acceptance criteria:
- [ ] APNs and gateway registration successes/failures update a scope-bound health record across relaunches.
- [ ] Raw tokens, auth headers, payload bodies, and agent text never enter health storage or logs.
- [ ] Errors are categorized into actionable groups without storing localized free-form secrets.
- [ ] Health resets or migrates on Forget Gateway and environment/server-scope changes.
Tests required: `PushRegistrarPairFlowTests`, new health-store migration/redaction tests, AppDelegate failure callback test, direct/relay outcome tests.

### ISSUE: Reconcile failed notification unregistration with tombstones
Phase: 3 | Spec: R-22 | Priority: high | Labels: type:fix, area:ios, area:server
Depends-on: Phase 1 background refresh; persist notification registration health | Inherited-context: none | Estimate: M
Premise: VERIFIED

`PushRegistrar.setEnabled(false)` fires unregister asynchronously, ignores `.hardFail`, then deletes the local token/env/events at `PushRegistrar.swift:92-116`. Persist an unregister tombstone before the first DELETE with server scope, environment, token hash plus an encrypted/Keychain-backed token reference required to retry, attempt count/timestamps, next attempt, and last categorized result. Retry on launch, foreground, background refresh, and network recovery until the gateway confirms absence. UI opt-out remains immediate, but local retry material is deleted only after confirmation or an explicit Forget Gateway policy decision.

Acceptance criteria:
- [ ] Killing the app after opt-out but before DELETE completion does not lose the retry record.
- [ ] A failed unregister retries with bounded exponential backoff and becomes terminal only on confirmed removal/invalid token.
- [ ] Re-enabling notifications resolves or supersedes the tombstone without racing duplicate registrations.
- [ ] Diagnostics shows pending cleanup without displaying token material.
- [ ] Direct and relay unregister paths converge on one durable outcome model.
Tests required: registrar crash-window tests, tombstone persistence/migration tests, direct/relay API retry tests, launch/foreground/background trigger tests.

### ISSUE: Make badge permission match an authoritative badge model
Phase: 3 | Spec: R-27 | Priority: medium | Labels: type:fix, area:ios, area:server
Depends-on: Phase 1 pending-attention manifest complete | Inherited-context: none | Estimate: S
Premise: VERIFIED

The app requests `.badge` authorization at `NotificationService.swift:549-552`, but no app-icon badge setter or authoritative APNs badge count was found; `InboxStore.pendingCount` only drives in-app badges. Choose and implement one truth source: pending attention from the Phase 1 manifest. Set the icon badge after every atomic pending-attention reconciliation and include the same count in APNs only when revision-safe. Clear it when pending attention reaches zero and during Forget Gateway. If the manifest contract cannot supply an authoritative count, remove `.badge` from requested authorization and payloads instead of inventing a local count.

Acceptance criteria:
- [ ] App-icon, Inbox, and widget pending counts derive from the same server revision, or badge permission is no longer requested.
- [ ] Termination/relaunch and another-client resolution cannot leave a stale badge after successful reconciliation.
- [ ] Forget Gateway clears the app-icon badge.
Tests required: notification authorization option test, manifest reconciliation badge tests, cold-launch and resolved-elsewhere integration tests.

### ISSUE: Persist stale-while-revalidate snapshots for remote panels
Phase: 3 | Spec: R-14,R-51,R-70 | Priority: high | Labels: type:feature, area:ios
Depends-on: Phase 1 identity migration and freshness model | Inherited-context: none | Estimate: L
Premise: VERIFIED

Usage, cron, skills, providers, devices, archived sessions, file listings, and artifact metadata load into per-view transient state, for example `UsageView.swift:263`, `CronJobsView.swift:173`, `SkillsBrowserView.swift:111`, `DevicesView.swift:204`, and `ArtifactsGalleryView.swift:324`. Add scope-bound, versioned panel snapshots using the Phase 1 identity keys. Render last-known data immediately, label it with `Updated …`, `Cached`, `Offline`, `Sync failed`, or `Partial result`, refresh in the background, atomically replace on success, and retain stale data on failure. Mutations remain live-only and must never pretend a stale write succeeded. File/artifact blobs remain Phase 2 cache concerns; this issue stores list/metadata only.

Acceptance criteria:
- [ ] All eight named panel families render a persisted last-known snapshot after force quit with an accurate freshness state.
- [ ] Successful refresh replaces data and timestamp atomically; failure preserves data and reports failure without a blank spinner.
- [ ] Snapshots are isolated and purged by Phase 1 server/profile scope.
- [ ] Mutating controls are disabled or explicitly offline while cached reads stay usable.
- [ ] Schema/version mismatch fails closed to an empty panel and schedules refresh without crashing.
Tests required: snapshot repository unit/migration tests; one integration test per panel family; offline relaunch UI tests; mutation-disabled tests.

### ISSUE: Add private-by-default Spotlight and Handoff controls
Phase: 3 | Spec: R-64 | Priority: high | Labels: type:feature, area:ios
Depends-on: Phase 0 Forget Gateway; Phase 1 authoritative tombstones | Inherited-context: PR #122 partial clear-on-revoke/switch | Estimate: M
Premise: VERIFIED

`SpotlightIndexer.swift:53-76` indexes titles and previews, and `userActivity(for:)` marks Handoff/search eligible with preview metadata at lines 124-138. `clearAll()` exists at lines 79-90 but no current disconnect call was found. Add “Show conversations in Spotlight and Handoff,” default off when App Lock is enabled. When off, clear the domain and stop publishing eligible activities. When on, support titles-only mode; never attach previews for sessions marked sensitive. Clear on Forget Gateway/server switch and reindex only from authoritative Phase 1 state after delete/archive reconciliation.

Acceptance criteria:
- [ ] Turning the preference off removes indexed items and disables new Handoff/search publication.
- [ ] App Lock defaults new/unset installations to off; migration never silently widens exposure.
- [ ] Titles-only mode places no transcript preview in Spotlight or `NSUserActivity`.
- [ ] Deleted/archived/forgotten sessions disappear after authoritative reconciliation.
Tests required: Spotlight indexer policy tests with injected index seam, Settings persistence tests, Forget Gateway integration test, on-device Spotlight/Handoff verification.

### ISSUE: Route sensitive copies through an expiring local pasteboard
Phase: 3 | Spec: R-65 | Priority: high | Labels: type:fix, area:ios
Depends-on: none | Inherited-context: none | Estimate: M
Premise: VERIFIED

Direct `UIPasteboard.general.string` writes exist across chat, message, cron, file, code, tool, and diagnostics/settings surfaces. Introduce one `SensitivePasteboard` policy that writes UTF-8 items with `.localOnly: true` and an expiration around 120 seconds. Migrate every agent content, prompt, error, token-adjacent diagnostic, code, and file-text copy site; keep a deliberate explicit Share action for cross-device transfer. Non-sensitive app links may retain a documented separate policy. Do not silently change copy success affordances.

Acceptance criteria:
- [ ] No sensitive-copy call site assigns `UIPasteboard.general.string` directly.
- [ ] Sensitive items are local-only, expire at the configured duration, and preserve exact copied text.
- [ ] Cross-device transfer requires an explicit Share action with a clear system sheet.
- [ ] Copy success remains announced visually and accessibly.
Tests required: pasteboard option/payload unit tests through an injectable adapter, source grep guard for direct sensitive writes, message/cron/file UI action tests.

### ISSUE: Add and validate the iOS privacy manifest at archive time
Phase: 3 | Spec: R-16,R-68 | Priority: high | Labels: type:fix, area:ios, area:ci
Depends-on: dependency inventory stable for release candidate | Inherited-context: none | Estimate: M
Premise: VERIFIED

No `PrivacyInfo.xcprivacy` exists under `apps/ios`. Generate Xcode's privacy report for the app, widget, share extension, dependencies, and any later notification service extension. Add manifests only for actually used required-reason APIs and declared data practices, include them in the correct targets, and add a CI archive gate that fails if manifests are missing, malformed, excluded from an archive, or Xcode reports unresolved required-reason usage. Do not guess API reasons from static names alone.

Acceptance criteria:
- [ ] Release archive contains a valid privacy manifest for every target that requires one.
- [ ] Every declared required-reason API is backed by verified code/dependency usage and an allowed reason.
- [ ] CI produces and checks the privacy report before TestFlight/App Store submission.
- [ ] Adding/removing an SDK changes the checked report or fails the gate, not a change-detector count test.
Tests required: plist schema validation, archive-content assertion, clean release archive/privacy-report job.

### ISSUE: Replace QR pairing phase polling with an awaitable result
Phase: 3 | Spec: R-59 | Priority: medium | Labels: type:refactor, area:ios
Depends-on: Phase 0 connection lifecycle stable | Inherited-context: none | Estimate: M
Premise: VERIFIED

`QRScannerView.handleScan` calls `HermesURLRouter.applyPair`, then polls global `ConnectionStore.phase` every 200 ms for 30 seconds at `QRScannerView.swift:229-257`. Expose an async pairing operation returning a typed result (`connected`, `needsManualToken`, `rejected`, `cancelled`, `timedOut`, categorized failure) while state publication remains in `ConnectionStore`. QR scan and deep-link confirmation must await the same operation. Cancellation must cancel only that attempt and generation guards must prevent a prior attempt completing a newer UI.

Acceptance criteria:
- [ ] No QR/deep-link pairing path polls `ConnectionStore.phase` or sleeps to infer completion.
- [ ] The typed result maps deterministically to dismiss, retry, manual-token prompt, and error UI.
- [ ] Cancellation and two rapid scans cannot let stale completion replace the current attempt.
- [ ] Existing v1/v2/relay/manual-token compatibility remains intact.
Tests required: QR pairing async-result tests with fake connector/clock, cancellation/race tests, existing `RelayPairPayloadTests` and connection tests.

### ISSUE: Replace URL-carried credentials with one-time pairing exchange
Phase: 3 | Spec: R-66 | Priority: high | Labels: type:feature, area:ios, area:server
Depends-on: Phase 0 device-token lifecycle complete | Inherited-context: PRs #74, #83, #94 partial current-generation pairing fixes | Estimate: L
Premise: VERIFIED for URL-carried credential; exchange internals PREMISE-UNCHECKED

`HermesURLRouter.PairPayload` still parses durable/shared or device tokens from `hermesapp://pair?...&token=...` at `HermesURLRouter.swift:100-239`. Replace newly minted payloads with a short-lived opaque pairing code plus signed envelope metadata: issuer, intended app bundle/audience, issued/expiry times, nonce, server/relay locator, and protocol version. The gateway/relay atomically consumes the code once, rejects replay/expiry/audience mismatch, and returns a newly issued device credential over the validated channel. Retain legacy parsing behind an explicit compatibility warning and removal telemetry; never log codes or credentials. Build-time verification must map existing relay pairing behavior before choosing a common direct/relay exchange endpoint.

Acceptance criteria:
- [ ] Newly generated QR/deep links contain no durable session/device credential.
- [ ] A code is single-use, expires quickly, is audience-bound, and replay returns a non-secret terminal error.
- [ ] Successful exchange persists only the resulting device credential in Keychain and invalidates the code server-side.
- [ ] Logs, analytics, diagnostics export, and UI errors redact both codes and returned credentials.
- [ ] Legacy payloads remain either explicitly warned-and-supported for a documented window or rejected with actionable upgrade guidance.
Tests required: gateway/relay exchange pytest suite for expiry/replay/audience/concurrency; iOS parser and Keychain tests; QR/deep-link E2E on old and new gateway versions.

### ISSUE: Enforce secure transport policy before saving credentials
Phase: 3 | Spec: R-67 | Priority: high | Labels: type:fix, area:ios
Depends-on: none | Inherited-context: none | Estimate: M
Premise: VERIFIED (residual; manual-token pairing already has partial host checks)

`ConnectionStore.configure` accepts both HTTP and HTTPS for any host at `ConnectionStore.swift:865-873`, probes with the credential, and persists after success. The manual-token QR path separately recognizes loopback/private/LAN/tailnet hosts in `WSURLBuilder.swift:102-225`; generic manual setup does not enforce equivalent policy. Centralize transport classification before any authenticated request: HTTPS is accepted; HTTP is accepted only for loopback/private/link-local/local/tailnet policy targets and requires a one-time explicit warning before save; public HTTP is rejected. Never downgrade HTTPS to HTTP during recovery. Show the active transport classification in Settings and diagnostics.

Acceptance criteria:
- [ ] Public/non-private HTTP is rejected before a token is placed in any request.
- [ ] Allowed local HTTP requires explicit risk confirmation and is labeled Insecure local transport in Settings.
- [ ] HTTPS connection failures never retry over HTTP.
- [ ] IPv4, IPv6, `.local`, bare-host, and `.ts.net` classification shares one tested implementation across QR and manual setup.
- [ ] Existing ATS local-network policy remains least-privilege.
Tests required: `WSURLBuilder` table tests, `ConnectionStore.configure` preflight tests proving no network call, setup warning UI tests, downgrade regression tests.

### ISSUE: Remove nested interactive controls from cron rows
Phase: 3 | Spec: R-71 | Priority: medium | Labels: type:fix, area:ios
Depends-on: none | Inherited-context: open cron PRs must land/rebase first | Estimate: S
Premise: VERIFIED

`CronJobRow` wraps its entire label in `Button(action: onTap)` at `CronJobsView.swift:240` while embedding Run/Pause/Resume buttons at lines 305-318. Restructure the row so navigation/editing is a semantic `NavigationLink` or sibling row button and quick actions are sibling controls outside that label. Preserve context-menu copy, pending-state disablement, swipe/tap behavior, identifiers, and visual hierarchy.

Acceptance criteria:
- [ ] SwiftUI view hierarchy contains no Button or NavigationLink nested inside another interactive control.
- [ ] VoiceOver focuses the row and each quick action once, in a predictable order, with state-specific labels.
- [ ] Row activation opens edit; Run/Pause/Resume perform only their named action.
- [ ] Pending state prevents duplicate actions without disabling row inspection.
Tests required: cron view hierarchy/action unit tests, `performAccessibilityAudit` coverage when available, VoiceOver manual pass.

### ISSUE: Make device rows semantic navigation controls
Phase: 3 | Spec: R-72 | Priority: medium | Labels: type:fix, area:ios
Depends-on: none | Inherited-context: none | Estimate: S
Premise: VERIFIED

`DevicesView.deviceRow` is a static `VStack` with `.onTapGesture` at `DevicesView.swift:149-183`. Replace it with a `Button` or `NavigationLink` that exposes the device name, platform/current-device state, detail summary, button trait, hint, and activation action. Preserve the trailing destructive swipe action and its confirmation/biometric flow.

Acceptance criteria:
- [ ] VoiceOver and Switch Control discover and activate the complete row as one semantic navigation control.
- [ ] The revoke swipe action remains separately named and cannot be triggered by row activation.
- [ ] Current-device and revoking states are included in accessibility value without duplicate speech.
Tests required: `DevicesTests`, device-row accessibility/action tests, VoiceOver and Switch Control manual pass.

### ISSUE: Announce transient success and failure banners accessibly
Phase: 3 | Spec: R-73 | Priority: medium | Labels: type:fix, area:ios
Depends-on: none | Inherited-context: none | Estimate: M
Premise: VERIFIED (QR scan already announces; general toast paths do not)

Cron, share-drain, chat, pairing, background sync, copy, and notification-test outcomes use transient visual banners or haptics; for example `CronJobsView.swift:103-107,216-223` and `HermesMobileApp.swift:87-95,278-286`. Add one toast announcement policy using an accessibility live region or `UIAccessibility.post` after visible state commits. Coalesce identical bursts, do not interrupt ongoing VoiceOver with low-value repeats, and distinguish success, warning, and actionable failure. Keep QR scanner's existing announcement at `QRScannerView.swift:213-216` without double-speaking.

Acceptance criteria:
- [ ] Job CRUD/trigger, share queued, copy, pairing, background-sync failure, and notification-test result each produce one meaningful assistive announcement.
- [ ] Repeated identical events within the coalescing window do not create an announcement storm.
- [ ] Visual banner lifetime and haptics remain unchanged, and QR success is not announced twice.
- [ ] Actionable failures name the recovery action when one exists.
Tests required: injectable accessibility-announcer unit tests, toast producer integration tests, VoiceOver manual sequence test.

### ISSUE: Expand accessibility and adaptive-layout release audits
Phase: 3 | Spec: R-18,R-74,R-17 | Priority: high | Labels: type:test, area:ios
Depends-on: cron-row, device-row, toast fixes; localization foundation | Inherited-context: none | Estimate: L
Premise: VERIFIED

Current `A11yMechanicalUITests.swift` and `ViewA11yTests.swift` verify selected labels/identifiers and may skip live flows; no `XCUIApplication.performAccessibilityAudit` use was found. Add a release matrix covering all accessibility text sizes, VoiceOver reading/action order, Voice Control names, Reduce Motion, Differentiate Without Color, Increase Contrast, Button Shapes, Switch Control, RTL, long localized strings, landscape, iPad split views, all themes, locked notification actions, and Live Activity/Dynamic Island VoiceOver. Automate stable checks and document physical/manual gates where XCTest cannot assert behavior. Scene-specific routing itself remains Phase 4.

Acceptance criteria:
- [ ] Deterministic screens run `performAccessibilityAudit` on supported OS versions with a documented, reviewed exception list.
- [ ] CI exercises smallest/largest content sizes, RTL, landscape, and iPad split layouts without truncating primary actions.
- [ ] Manual release checklist covers VoiceOver, Voice Control, Switch Control, contrast settings, locked actions, and Live Activity.
- [ ] Live-gateway-required tests provision a fixture or report an explicit skipped release gate; they do not silently pass.
Tests required: expanded `HermesMobileUITests` accessibility plans, snapshot/geometry assertions where stable, physical-device release checklist.

### ISSUE: Localize app, widget, Live Activity, notifications, and intents
Phase: 3 | Spec: R-75 | Priority: medium | Labels: type:feature, area:ios, area:server
Depends-on: notification APNs presentation metadata | Inherited-context: parked parity/localization backlog | Estimate: L
Premise: VERIFIED

No String Catalog or legacy strings resources were found. Add target-appropriate String Catalogs for the app, widget/Live Activity, share extension, Siri/App Intent phrases, errors, permission guidance, and any notification service extension. Replace user-visible literals incrementally without localizing protocol tokens, accessibility identifiers, log categories, or server keys. Gateway APNs payloads must use localization keys/arguments with a safe generic fallback for old clients. Seed English plus one pseudo/double-length and one RTL validation locale; production language selection is a product decision outside this issue.

Acceptance criteria:
- [ ] Every shipping target resolves user-visible copy through a catalog, including pluralized/count strings.
- [ ] Notification payloads use valid `loc-key`/`loc-args` and remain readable on clients lacking the new key.
- [ ] Siri/App Intent phrases and permission/error guidance are localized through supported APIs.
- [ ] Pseudolocalization and RTL runs pass the adaptive-layout/a11y matrix.
- [ ] No wire identifier, analytics key, test identifier, or log schema is translated.
Tests required: catalog extraction/build checks, missing-key test, APNs localization payload tests, pseudolocale/RTL UI tests.

### ISSUE: Instrument client lifecycle, freshness, queue, and cache health
Phase: 3 | Spec: R-77 | Priority: high | Labels: type:feature, area:ios
Depends-on: Phases 1 and 2 complete | Inherited-context: none | Estimate: L
Premise: VERIFIED as residual; see discrepancies

`ChatStore.swift:50` and `SessionStore.swift:8` already use `Logger`, and `PerfHitchLogger.swift` provides a DEBUG hitch seam, but the audit's lifecycle/health measures are not present as one redacted contract. Add typed `os.Logger` categories, signposts, and MetricKit where applicable for launch-to-cached-shell, launch-to-fresh-manifest, reconnect, resume/backfill, last sync by scope, BG attempts/expiry, APNs/gateway registration results, notification action latency, outbox depth/oldest age, attachment bytes/evictions/orphans, widget age, hangs/hitches, long-transcript memory, and DB migration failures. Use hashes or enumerations, never URLs, tokens, prompts, transcript text, paths, or session titles. This is local diagnostics instrumentation, not outbound telemetry.

Acceptance criteria:
- [ ] Every named metric has an owner, start/end semantics, unit, privacy classification, and bounded-cardinality fields.
- [ ] Signposts close on success, cancellation, expiration, and error.
- [ ] Release builds collect the approved local metrics without enabling outbound analytics.
- [ ] Automated redaction tests reject secrets/content in log interpolation and diagnostics export.
- [ ] Metrics feed the diagnostics read model without scraping free-form log text.
Tests required: metric-contract unit tests with injectable sink/clock, cancellation/error path tests, MetricKit seam tests, redaction/cardinality tests.

### ISSUE: Publish bounded gateway mobile-health metrics
Phase: 3 | Spec: R-78 | Priority: high | Labels: type:feature, area:server
Depends-on: Phase 1 sync manifest; durable push outbox if separately scheduled | Inherited-context: none | Estimate: L
Premise: PREMISE-UNCHECKED

Define plugin-owned metrics for push outbox depth/oldest age, APNs acceptance by event kind, status/reason distribution, retries, invalid-token pruning, relay enqueue versus confirmed delivery, Live Activity priority/throttling, pending-approval age, and sync-manifest latency/delta size. Instrument `plugins/hermes-mobile/push_engine.py`, relay callbacks, pending-attention provider, and manifest route through the repository's existing metrics/logging extension point verified at build time. Keep event kinds/statuses bounded; never label by device, session, user, URL, token, request text, or agent content. Do not add a new core model tool or outbound telemetry path.

Acceptance criteria:
- [ ] All named measures are emitted from plugin/service edges with documented units and bounded labels.
- [ ] Relay enqueue and confirmed delivery are distinct states; neither is labeled delivered merely on queue acceptance.
- [ ] APNs request IDs may appear only in redacted diagnostics correlation, not as high-cardinality metric labels.
- [ ] Metrics can be disabled through existing config/observability policy and add no user-facing secret env var.
- [ ] Load tests prove instrumentation does not block push delivery or manifest responses.
Tests required: plugin metric-sink pytest suite, label allowlist/redaction tests, retry/status table tests, performance smoke test.

### ISSUE: Add Notification Health, Sync Health, and redacted diagnostics
Phase: 3 | Spec: R-79,R-21,R-77,R-78 | Priority: high | Labels: type:feature, area:ios
Depends-on: persist notification registration health; instrument client lifecycle; publish gateway mobile-health metrics | Inherited-context: PR #43 partial relay health | Estimate: L
Premise: PREMISE-UNCHECKED

Add Settings destinations for Notification Health, Sync Health, and a combined Diagnostics view. Expose only non-secret values: app/build, server scope fingerprint, last connection/sync, WebSocket state, APNs environment/authorization/registration health, direct/relay route, Background App Refresh availability/last result, cache bytes, outbox count/oldest age, widget snapshot age, and categorized recent errors. “Send test notification” creates a correlation ID and reports accepted/enqueued/confirmed/failure honestly. “Export redacted diagnostics” uses a versioned schema and explicit preview/share flow. Verify at build time which Phase 1/2 stores expose these values; do not scrape view state or raw logs.

Acceptance criteria:
- [ ] All roadmap fields render a value or explicit Unsupported/No attempt/Unavailable state.
- [ ] Test notification correlates client, relay/direct gateway, and APNs acceptance without claiming device display delivery.
- [ ] Export contains no tokens, auth headers, payload bodies, transcript/prompt text, raw URLs/paths, or stable device identifiers.
- [ ] Export schema is versioned and covered by golden redaction tests; the user previews before sharing.
- [ ] The screen remains useful offline from persisted health records and marks their age.
Tests required: diagnostics view-model tests, unsupported/offline UI tests, test-push correlation integration tests, export schema/redaction tests.

## Phase 3 sequenced mini-epic: decompose coordination stores last

This epic is deliberately last in the campaign. Land all Phase 0-2 behavior and reconcile open hotspot PRs before moving code. Each child is extraction-only: preserve observable behavior, prompt/cache contracts, wire formats, persistence schema, and UI state. Do not combine feature work with these refactors.

Sequence:

```text
1 CacheRepository ──> 4 SyncCoordinator ──> 5 BackgroundTaskCoordinator
2 OutboxRepository ─┬──────────────────────> 5 BackgroundTaskCoordinator
3 TransferManager ──┘
6 NotificationCoordinator ──> 7 PrivacyCoordinator
1 CacheRepository ──────────> 7 PrivacyCoordinator
2 OutboxRepository ─────────> 7 PrivacyCoordinator
```

### ISSUE: Extract CacheRepository from session and connection stores
Phase: 3 | Spec: R-76 | Priority: medium | Labels: type:refactor, area:ios
Depends-on: Phase 2 complete; all cache/freshness behavior issues landed | Inherited-context: PR #147 must land/reconcile first | Estimate: L
Premise: VERIFIED

First extraction. Move session/message persistence, Phase 1 tombstone/revision application, offline search index access, attachment metadata/eviction hooks, panel snapshots, and scope purge behind a `CacheRepository` interface. `SessionStore` remains the observable presentation owner and publishes only after repository transactions complete. Keep GRDB transactions, identity schema, cache-first paint order, and migration behavior byte/semantics compatible. Do not rename tables or add a second cache implementation.

Acceptance criteria:
- [ ] No view or coordinator issues raw GRDB queries; all cache operations flow through the repository.
- [ ] Manifest delta application remains one SQLite transaction and one observable publish.
- [ ] Cache-first launch, tombstones, search, attachments, snapshots, and scope purge retain existing behavior.
- [ ] `SessionStore` shrinks by the extracted persistence responsibilities without becoming a pass-through god facade.
Tests required: existing cache/launch/search/attachment/panel suites plus repository contract, transaction rollback, migration, and scope-isolation tests.

### ISSUE: Extract OutboxRepository from chat, queue, and app-intent flows
Phase: 3 | Spec: R-76 | Priority: medium | Labels: type:refactor, area:ios
Depends-on: Phase 2 complete; Phase 2 durable job repository landed | Inherited-context: STR-246 | Estimate: L
Premise: VERIFIED

Second extraction. Move Phase 2 drafts, prompt jobs, App Intent jobs, share jobs, state transitions, retry scheduling, and idempotency lookup into `OutboxRepository`. `ChatStore`, composer, share drainer, and intents consume typed operations/events rather than storage details. Preserve client-message IDs, exactly-once contract, ordering, backoff, crash windows, and user-visible states. Do not redesign schema or retry policy in this refactor.

Acceptance criteria:
- [ ] Every durable user-work producer uses the repository; no duplicate UserDefaults/job persistence remains.
- [ ] State transitions reject invalid regressions and are transactionally persisted before UI acknowledgement.
- [ ] Existing ordering, retry, cancellation, and idempotency behavior is unchanged.
- [ ] Chat/UI stores observe typed snapshots/events and do not expose database records directly.
Tests required: Phase 2 outbox/draft/share/intent suite, repository state-machine contract tests, crash/relaunch tests.

### ISSUE: Extract TransferManager from attachment and lifecycle stores
Phase: 3 | Spec: R-76 | Priority: medium | Labels: type:refactor, area:ios
Depends-on: Phase 2 complete; Phase 2 background URLSession manager landed | Inherited-context: none | Estimate: M
Premise: VERIFIED

Third extraction. Move background URLSession creation, upload/download task mapping, transfer persistence, relaunch completion, progress aggregation, cancellation, and retry handoff into `TransferManager`. Keep attachment selection/preview in UI stores and durable job truth in `OutboxRepository`; link them through stable transfer/job IDs. Preserve the Phase 2 background session identifier and AppDelegate completion contract.

Acceptance criteria:
- [ ] One manager owns all long-lived upload/download sessions and delegate callbacks.
- [ ] Relaunch restores transfer-to-job mapping before invoking completion handlers.
- [ ] UI observes typed progress/result streams without retaining URLSession tasks.
- [ ] Suspension/termination, retry, cancellation, and orphan cleanup behavior is unchanged.
Tests required: Phase 2 transfer suite, delegate/relaunch mapping tests, duplicate completion and cancellation races.

### ISSUE: Extract SyncCoordinator from connection and session stores
Phase: 3 | Spec: R-76 | Priority: medium | Labels: type:refactor, area:ios
Depends-on: Phase 2 complete; Extract CacheRepository; Phase 1 sync protocol landed | Inherited-context: STR-969, PR #147 | Estimate: L
Premise: VERIFIED

Fourth extraction. Move foreground/background manifest fetch, cursor/revision ownership, invalidation coalescing, atomic delta application orchestration, capability version handling, and freshness state into `SyncCoordinator`. `ConnectionStore` continues to own socket/connectivity and `SessionStore` presentation/session selection. The coordinator consumes `CacheRepository` and publishes a typed freshness snapshot; it must not inject synthetic UI events or create a second reconnect loop.

Acceptance criteria:
- [ ] One coordinator owns sync requests, coalescing, revisions, and freshness transitions across launch/foreground/background.
- [ ] Connection loss and stale responses cannot regress the accepted revision.
- [ ] Manifest application remains atomic and publishes once to consumers.
- [ ] Existing WebSocket reconnect and cache-first presentation behavior is unchanged.
Tests required: Phase 1 manifest/background refresh suite, stale-generation/coalescing tests, cancellation and atomic publish tests.

### ISSUE: Extract BackgroundTaskCoordinator from app lifecycle code
Phase: 3 | Spec: R-76 | Priority: medium | Labels: type:refactor, area:ios
Depends-on: Phase 2 complete; Extract SyncCoordinator; Extract OutboxRepository; Extract TransferManager | Inherited-context: none | Estimate: M
Premise: VERIFIED

Fifth extraction. Centralize BGTask registration at launch, refresh/maintenance scheduling, expiration handlers, completion semantics, and bounded state flush in `BackgroundTaskCoordinator`. It orchestrates `SyncCoordinator`, `CacheRepository`, `OutboxRepository`, and `TransferManager` through protocols and owns no duplicated business data. Keep identifiers, Info.plist declarations, budgets, and scheduling policy from Phases 1-2 unchanged.

Acceptance criteria:
- [ ] All BGTask identifiers register before launch completes and exactly one owner schedules each task class.
- [ ] Expiration cancels child work and calls task completion exactly once with an honest result.
- [ ] State flush remains bounded and is never used as a keepalive.
- [ ] Test seams do not require a live `BGTaskScheduler`.
Tests required: Phase 1/2 background task suites, fake scheduler/expiration tests, exact-once completion tests.

### ISSUE: Extract NotificationCoordinator from app and settings code
Phase: 3 | Spec: R-76 | Priority: medium | Labels: type:refactor, area:ios
Depends-on: Phase 2 complete; all Phase 0/3 notification behavior issues landed | Inherited-context: PR #145 and #43 must land/reconcile first | Estimate: L
Premise: VERIFIED

Sixth extraction. Consolidate notification authorization, category registration, APNs token lifecycle, gateway/relay registration, durable unregister cleanup, tap/action routing, deduplication, privacy/quiet-hours policy, and notification health behind `NotificationCoordinator`. Absorb responsibilities currently split across `HermesMobileApp`, `NotificationService`, `PushRegistrar`, Settings, and connection attachment hooks. Preserve launch-time delegate/category installation and cold-launch action queues. The coordinator must not become a second UI store; expose small observable read models.

Acceptance criteria:
- [ ] One coordinator owns every authorization/token/register/unregister/action transition.
- [ ] Launch installation still occurs before any notification response can arrive.
- [ ] Preview, quiet-hours, dedupe, health, and tombstone policies retain behavior and direct/relay parity.
- [ ] Settings and diagnostics consume typed read models rather than reading token UserDefaults directly.
Tests required: complete notification unit/integration suite, cold-launch actions, direct/relay parity, coordinator state-machine and race tests.

### ISSUE: Extract PrivacyCoordinator and atomic privacy transactions
Phase: 3 | Spec: R-76 | Priority: medium | Labels: type:refactor, area:ios
Depends-on: Phase 2 complete; Extract CacheRepository; Extract OutboxRepository; Extract NotificationCoordinator; all privacy behavior issues landed | Inherited-context: STR-510 cluster, PR #122 | Estimate: L
Premise: VERIFIED

Final extraction. Centralize immediate switcher shield policy, App Lock policy, Spotlight/Handoff preference, sensitive pasteboard, notification preview policy, self-revoke handling, and the Phase 0 Forget Gateway transaction in `PrivacyCoordinator`. Compose existing repositories/coordinators through explicit steps with persisted transaction progress where Phase 0 defined it; do not create a parallel cache, Keychain wrapper, or notification registrar. UI owns presentation and confirmation; coordinator owns policy and atomic/best-effort cleanup ordering.

Acceptance criteria:
- [ ] All privacy-sensitive operations call one policy boundary and retain Phase 0/3 user-visible behavior.
- [ ] Forget Gateway and self-revoke execute the same tested cleanup plan and recover safely after interruption.
- [ ] Coordinator APIs never return or log raw credentials/content for UI convenience.
- [ ] App lifecycle/store types no longer contain duplicated Spotlight, pasteboard, preview, or wipe policy.
Tests required: Phase 0 Forget/self-revoke/app-lock/shield suite, Spotlight/pasteboard/preview tests, interrupted transaction recovery and redaction tests.

## Phase 4 issues: optional advanced capabilities

### ISSUE: Start Live Activities for remotely initiated user turns
Phase: 4 | Spec: R-30,R-31 | Priority: medium | Labels: type:feature, area:ios, area:server
Depends-on: Phase 0 Live Activity cadence fix; notification preview policy | Inherited-context: none | Estimate: L
Premise: VERIFIED

Add ActivityKit push-to-start for remotely initiated interactive turns. Minimum OS: iOS 17.2 for `Activity<Attributes>.pushToStartTokenUpdates`; retain current local-start/update-token behavior on iOS 17.0-17.1. Register/rotate/unregister the push-to-start token by device/environment without exposing it in diagnostics. Gateway start pushes use `apns-push-type: liveactivity`, the Live Activity topic, and ActivityKit's `event: start` payload with matching attributes/content-state. Define ownership in the same issue: latest user-owned turn wins, approval preempts, worker/kanban turns never own the phone surface, background jobs use notifications, and ownership changes show session context. Existing `NSSupportsLiveActivities` remains required; verify provisioning/topic support in development and production APNs.

Acceptance criteria:
- [ ] A desktop-started user turn can create one Live Activity while the iOS app is terminated on iOS 17.2+.
- [ ] iOS 17.0-17.1 degrades to alerts/current local-start behavior without calling unavailable APIs.
- [ ] Token rotation/environment changes reconcile with the gateway; stale tokens are pruned.
- [ ] Simultaneous-turn and approval-preemption rules are deterministic and visible, never silent session hopping.
- [ ] Generic/Hidden notification privacy policy also limits Live Activity content.
Tests required: availability/unit payload tests, gateway APNs topic/header tests, physical-device development and TestFlight remote-start/rotation/termination matrix.

### ISSUE: Add user-visible continued processing for eligible long operations
Phase: 4 | Spec: R-38 | Priority: low | Labels: type:feature, area:ios
Depends-on: Phase 2 TransferManager; a concrete eligible operation approved | Inherited-context: none | Estimate: M
Premise: VERIFIED absent; concrete consumer PREMISE-UNCHECKED

Use `BGContinuedProcessingTask` only for a real user-started operation that must continue with visible progress, such as a large archive export or local report/media transformation. Minimum OS: iOS 26; guard every API and preserve Phase 2 background URLSession/BGProcessing behavior on older systems. Register/submit the continued-processing task using the pinned iOS 26 SDK's identifier and permitted-resource requirements, show title/subtitle/progress, support cancellation and expiration, and never use it for routine sync, hidden maintenance, WebSocket keepalive, or ordinary downloads already owned by background URLSession. Verify exact Info.plist/background capability requirements against the shipping SDK at build time.

Acceptance criteria:
- [ ] No continued-processing request is submitted without a direct user action and visible progress/cancel affordance.
- [ ] iOS 17-25 use the existing transfer/export fallback without runtime symbol access.
- [ ] Expiration/cancellation persists an honest resumable or failed operation state.
- [ ] Routine sync and maintenance never schedule this task class.
Tests required: availability/fallback tests, fake scheduler cancellation/expiration tests, iOS 26 device test for the selected operation.

### ISSUE: Build a complete locked-screen background voice experience
Phase: 4 | Spec: R-39 | Priority: low | Labels: type:feature, area:ios
Depends-on: product approval for genuine hands-free mode; privacy review | Inherited-context: none | Estimate: L
Premise: VERIFIED foreground-only; product requirements PREMISE-UNCHECKED

Only ship background voice as an explicit hands-free feature, not as a suspension workaround. Minimum OS follows the app baseline, iOS 17. Add the Audio background mode (`UIBackgroundModes: audio`), retain microphone usage disclosure, configure `AVAudioSession` for the approved record/playback mode and routes, expose an unmistakable locked-screen recording/listening state with stop/mute controls, and handle calls, Siri, route changes, permission revocation, thermal/battery constraints, network loss, and app termination. Evaluate whether Now Playing/remote commands are appropriate for playback; do not misuse them to mask recording. VAD, barge-in, CarPlay, and route selection require explicit scope decisions before implementation.

Acceptance criteria:
- [ ] Background audio runs only while the user-visible voice session is active and stops immediately on user stop, auth revoke, fatal error, or policy expiration.
- [ ] Lock-screen/system indicators truthfully show microphone/audio activity and provide an accessible stop path.
- [ ] Interruptions and route changes recover or terminate without recording silently.
- [ ] Foreground-only voice remains the default and no keepalive audio is emitted.
Tests required: audio-session unit seams; physical locked/background/call/Siri/Bluetooth/network-loss/battery matrix; App Store capability justification review.

### ISSUE: Route sessions and deep links to scene-owned iPad windows
Phase: 4 | Spec: R-17 | Priority: medium | Labels: type:feature, area:ios
Depends-on: decomposition mini-epic complete; Phase 1 identity model | Inherited-context: none | Estimate: L
Premise: VERIFIED single `WindowGroup`; detailed ownership PREMISE-UNCHECKED

Add scene-specific routing and state for multiple iPad windows. Minimum OS: iPadOS/iOS 17 baseline. Enable multiple scene instances in the generated scene manifest, use a value-based `WindowGroup`/`openWindow` or equivalent scene-session API keyed by stable stored session identity, and keep navigation selection, composer draft, presented sheets, restoration activity, and pending deep-link target scene-owned. Shared repositories, connection, sync, notifications, and caches remain process-wide; one scene closing must not cancel work used by another. Define deterministic routing for Spotlight/Handoff, notification taps/actions, widgets, and duplicate session opens. No special entitlement is expected; verify scene manifest generation and iPad support in the archive.

Acceptance criteria:
- [ ] Two iPad windows can show different sessions/drafts without navigation or composer state bleeding.
- [ ] Deep links and continuation activities select/create one deterministic target scene and do not mutate unrelated windows.
- [ ] Closing a window releases scene state but preserves shared connection/transfers/outbox used elsewhere.
- [ ] Single-window iPhone behavior is unchanged.
Tests required: scene router/state-restoration unit tests, iPad multiwindow UI tests, notification/Spotlight/Handoff/widget routing matrix.

### ISSUE: Add privacy-aware rich notification content extension
Phase: 4 | Spec: §18 Phase-4 notification service extension | Priority: low | Labels: type:feature, area:ios, area:server
Depends-on: notification preview policy and localization complete | Inherited-context: none | Estimate: L
Premise: VERIFIED absent

Add a `UNNotificationServiceExtension` target only for a defined rich-content use case such as safely downloaded thumbnails or localized formatting. Minimum OS: iOS 10 API, app deployment remains iOS 17. Gateway sets `mutable-content: 1` only when enrichment is useful. The extension must finish within the system deadline, always call the content handler with original/sanitized fallback, enforce MIME/byte/time limits, and honor Full/Generic/Hidden policy without needing the user's gateway credential. Use the existing App Group only for a minimal non-secret policy snapshot if required; add Keychain access groups only if a security review proves unavoidable. Include the extension in privacy manifests, signing, and archive checks.

Acceptance criteria:
- [ ] Generic/Hidden notifications cannot be enriched into sensitive content.
- [ ] Timeout, network, decode, and oversized-attachment failures deliver the safe original notification.
- [ ] The extension stores no credential or durable agent content and cleans temporary attachments.
- [ ] Direct and relay payloads set `mutable-content` and attachment metadata consistently.
Tests required: extension handler tests with timeout/size/MIME failures, preview-mode privacy tests, signed archive/install/TestFlight delivery tests.

### ISSUE: Add user-selectable offline conversation and artifact policy
Phase: 4 | Spec: §18 Phase-4 offline download policy | Priority: medium | Labels: type:feature, area:ios
Depends-on: Phase 1 scope/tombstones; Phase 2 CacheRepository and TransferManager; privacy coordinator | Inherited-context: none | Estimate: L
Premise: PREMISE-UNCHECKED

Add Settings policy for conversations and artifacts: metadata/cache-only, recent-N-days, selected/pinned, or all within a user-set byte cap; include Wi-Fi-only, Low Data Mode, Low Power Mode, and cellular override behavior. No special entitlement is required. Downloads use `TransferManager`, content versions, protected storage, exclusion from backup where appropriate, LRU/TTL and disk-pressure policy, and Phase 1 scope/tombstone deletion. Show estimated/actual bytes, progress, errors, and “remove downloads” separately from deleting remote content. Forget Gateway defaults to purging; any preserve-download option must state encryption, scope, and future accessibility explicitly.

Acceptance criteria:
- [ ] Policy is scope-bound, survives relaunch, and deterministically selects content without bypassing byte caps.
- [ ] Downloads resume safely through suspension/termination and verify content version before presentation.
- [ ] Remote delete/archive and Forget Gateway apply the documented purge/retention policy without orphaned files.
- [ ] Disk pressure and policy reduction evict eligible data while preserving pinned/in-progress work until the user is warned.
- [ ] Offline UI labels content version/freshness and never presents a partial blob as complete.
Tests required: policy selection/quota/LRU tests, transfer resume/version tests, disk-pressure and scope-purge integration tests, offline UI tests.

## SPEC-VS-CODE DISCREPANCIES

1. **R-15 overstates the missing preference surface.** Five per-event notification toggles already exist in `SettingsView.swift:452-500` and persist through `DefaultsKeys.swift:120-159`. The drafted issue covers quiet hours, session mute, and presentation policy only.
2. **R-26 is partially implemented.** `push_engine.build_push_headers` already supports `collapse_id` (`push_engine.py:196-220`) and categories exist, but the notification call chain does not expose the complete thread/interruption/relevance/localization policy. The issue preserves and extends this work.
3. **R-67 is partially hardened.** Manual-token QR pairing rejects public hosts through `WSURLBuilder.isSafeForManualTokenPair`, but generic `ConnectionStore.configure` still accepts public HTTP before sending credentials. The issue targets that residual.
4. **R-73 is not universally absent.** QR success already posts a VoiceOver announcement at `QRScannerView.swift:213-216`. General toast/banner producers remain unannounced; the issue explicitly prevents double-speaking QR success.
5. **R-77's “missing” label is too broad.** `ChatStore` and `SessionStore` use `os.Logger`, and `PerfHitchLogger` provides DEBUG hitch logging. The missing work is a typed, redacted, end-to-end metric contract and the listed lifecycle/health coverage.
6. **R-64 cleanup work may overlap PR #122.** Current checked-out code defines `SpotlightIndexer.clearAll()` but does not call it from disconnect paths. Reconcile/cherry-pick PR #122 before implementing the broader preference/titles-only issue.
7. **Phase 4 deployment mismatch is intentional.** The app targets iOS 17.0, while ActivityKit push-to-start requires iOS 17.2 and `BGContinuedProcessingTask` requires iOS 26. Both issues require runtime availability and older-OS fallbacks rather than raising the whole app minimum.

## Coverage audit

| Required scope | Issue coverage |
|---|---|
| R-14/R-51/R-70(part) | Persist stale-while-revalidate snapshots |
| R-15/R-25/R-26 | Notification privacy + quiet-hours/metadata issues |
| R-16/R-68 | Privacy manifest/archive gate |
| R-17 | Decomposition mini-epic + Phase 4 multiwindow routing + Phase 3 layout tests |
| R-18/R-71..R-75 | Cron/device/toast/a11y/localization issues |
| R-21/R-22/R-27 | Registration health, unregister tombstone, badge model |
| R-64/R-65 | Spotlight/Handoff and pasteboard issues |
| R-76 | Seven ordered extraction issues, each depending on Phase 2 complete |
| R-77/R-78/R-79 | Client metrics, gateway metrics, diagnostics UI |
| R-24/R-59/R-66/R-67 residuals | Folded auth residual plus three dedicated Phase 3 issues |
| R-30/R-31 | Phase 4 Live Activity push-to-start and ownership rule |
| R-38/R-39 | Phase 4 continued processing and background voice |
| §18 Phase-4 extras | Multiwindow, notification service extension, offline policy |

## Unsatisfiable clauses

- The requested destination `/Users/abbhinnav/Developer/products/hermes-loop/docs/mobile-foundation/lane-outputs/lane-h-phase34-issues.md` is outside this session's writable root. The sandbox rejected the early `apply_patch` attempt. This complete artifact was therefore written to `/Volumes/MainData/Developer/products/hermes-mobile/lane-h-phase34-issues.md`; no repository file other than this output artifact was modified.

LANE_RESULT: done_with_concerns Drafted all Phase 3 and Phase 4 work as 33 build-ready issues, including the seven-child sequenced decomposition epic, explicit untagged-item disposition, targeted verification labels, API/OS requirements, discrepancies, and full coverage; only the mandated sibling-checkout output path was sandbox-unsatisfiable.
