# ABH-519 Phase 3 — retained-seam parity evidence

**Captured:** 2026-07-22–23 +08:00

**Branch:** `codex/abh-519-v019-phase3-parity`

**Base:** Phase 2 merge `565f357d8c29af744eadb34c24c76108e902bfbe`

**Status:** Phase 3 gate green. All device checks below ran on the owner-approved,
USB-connected iPhone 16 Pro Max. No simulator was booted or used.

## Retained seams

- Turn completion and clarification continue through the ABH-88 S2
  `post_emit_event` observer. `on_session_finalize` remains Live Activity teardown only.
- Approval alerting starts at the stock `pre_approval_request` hook. The plugin reads the
  already-enqueued `pending_approval_snapshot()` so APNs receives only the stock redacted
  description and choices, never the raw command supplied to the hook.
- S11 submit receipts, S1 live follow, and the existing bounded foreign-user tail read are
  retained without a second implementation.
- Load-earlier on the stock transport uses `/api/sessions/{id}/messages` with its existing
  `limit`, `offset`, and `profile` query. Older settled rows are prepended without reseeding
  the chat or cancelling an in-flight streaming placeholder.

## Phone-specific foreground selection

The existing device-token registry now holds one ephemeral stored-session selection only
while that authenticated device has a live WebSocket. Disconnect and revoke clear it.
Completion, clarify, approval, error, and background-complete pushes exclude only the phone
actively displaying that stored session. A desktop driving the runtime does not suppress a
phone notification.

The transparent relay validates a device token and preserves that validated credential to
the gateway for both stock WebSocket and HTTP. A configured relay credential still maps to
the configured upstream gateway credential. The relay does not parse frames or add
persistence, translation, transcript, or session state.

## Automated gates

- Full relay suite: `258 passed`.
- Push, device registry, dashboard auth seam, plugin registration, and late-wiring slice:
  `87 passed`.
- Stock-frame phone driver through the transparent relay: `1 passed`; the driver observed
  no legacy item-stream frames.
- iOS I1-I23-adjacent contract slice: `217 tests`, `2 skipped`, `0 failures`.
- Generic physical-iOS target via `scripts/ios-build.sh`: `BUILD SUCCEEDED`.
- `git diff --check`: pass.
- Gateway-core diff audit: no files under `gateway/`, `tui_gateway/`, or `hermes_cli/`
  changed. The stock seam ledger is unchanged.

## Physical-device gate

### Captured on physical hardware

- Device: iPhone 16 Pro Max, iOS 26.5, UDID
  `00008140-000648640A33001C`, controlled through Xcode/XCUITest.
- Stock clarification ownership: `testClarificationStaysWithOwningSessionAcrossSwitch`
  passed against the isolated relay/gateway. The card rendered only in its owning stored
  session, survived a switch plus cache reset, returned on reopen, and cleared after its
  answer. Log: `/tmp/abh519-phase3-device-clarify-owner-lean.log`; result bundle:
  `apps/ios/.derivedData/Logs/Test/Test-HermesMobile-2026.07.23_01-35-08-+0800.xcresult`.
- Foreign-turn live follow: a Mac-side stock client retained runtime `2beee0d5`; the phone
  opened unique stored session `ABH519-LIVE-014300` read-only, painted `-FIRST`, then
  rendered the independently submitted `-SECOND` turn. The phone was already watching
  for about 57 seconds before the second marker arrived. The focused XCUITest passed in
  69.36 seconds; gateway logs contain zero `4007`. Log:
  `/tmp/abh519-phase3-device-live-follow-final-head.log`; result bundle:
  `apps/ios/.derivedData/Logs/Test/Test-HermesMobile-2026.07.23_01-39-01-+0800.xcresult`.
- Force-close repaint: the phone opened the same unique stored session, verified its second
  settled turn, terminated the app, relaunched, reopened that session, and repainted the
  same marker within the 10-second disk-paint budget. The focused test passed in 19.13
  seconds. Log: `/tmp/abh519-phase3-device-force-close-repaint-2.log`; result bundle:
  `apps/ios/.derivedData/Logs/Test/Test-HermesMobile-2026.07.23_01-42-33-+0800.xcresult`.

- Clarification continuation: the owning card survived switch/cache reset, answering it
  resumed the same turn, and the exact final response `ABH519 owner answered` rendered in
  that transcript. Focused test passed in 58.399 seconds. Log:
  `/private/tmp/abh519-phase3-device-owned-clarification-answer.log`; result bundle:
  `apps/ios/.derivedData/Logs/Test/Test-HermesMobile-2026.07.23_03-48-58-+0800.xcresult`.
- Background clarification push: a desktop-driven clarification produced one notification;
  tapping it opened the owning stored session and real question/choices, and answering
  resumed the blocked turn. Focused test passed in 32.959 seconds. Log:
  `/private/tmp/abh519-phase3-device-clarification-push-final2.log`; result bundle:
  `apps/ios/.derivedData/Logs/Test/Test-HermesMobile-2026.07.23_03-23-43-+0800.xcresult`.
- Background completion push: a desktop-driven completion produced one notification and
  tapping it opened the owning transcript. The exactly-once check passed in 27.582 seconds.
  Log: `/private/tmp/abh519-phase3-device-completion-push-exactly-once-final.log`; result
  bundle:
  `apps/ios/.derivedData/Logs/Test/Test-HermesMobile-2026.07.23_03-01-41-+0800.xcresult`.
- Foreground suppression: while the phone watched the stored session, the foreign turn
  live-followed into that transcript and SpringBoard exposed no redundant completion push.
  Focused test passed in 36.107 seconds. Log:
  `/private/tmp/abh519-phase3-device-foreground-suppression-final.log`; result bundle:
  `apps/ios/.derivedData/Logs/Test/Test-HermesMobile-2026.07.23_02-55-06-+0800.xcresult`.
- Stock pagination during an active turn: **Load Earlier** crossed the first 50-row window,
  fetched the older stock page, rendered `pagination fixture message 070`, and retained the
  live Interrupt control. Focused test passed in 69.811 seconds. Log:
  `/tmp/hermes-ios-build-8723.log`; result bundle:
  `apps/ios/.derivedData/Logs/Test/Test-HermesMobile-2026.07.23_04-56-43-+0800.xcresult`.
- Approval push and continuation: the stock approval hook produced an actionable push.
  Because Do Not Disturb was active, iOS grouped it under Notification Center; opening that
  group and tapping the notification landed on the owning gate. The phone sent
  `approval.respond` for the same runtime and received an ACK:

  ```text
  ABH519_APPROVAL_RESPOND_ENTRY approvalSession=6a338c54 activeSession=6a338c54 connection=true
  ABH519_APPROVAL_RESPOND_SEND session=6a338c54
  ABH519_APPROVAL_RESPOND_OK
  ```

  The gate cleared and `ABH519 APPROVAL RESUMED` rendered as a standalone assistant text
  view below the work row. After removing all diagnostic signposts and restarting the
  isolated gateway, the same test passed again in 56.054 seconds. Clean-code log:
  `/private/tmp/abh519-phase3-approval-clean-device.log`; result bundle:
  `apps/ios/.derivedData/Logs/Test/Test-HermesMobile-2026.07.23_05-30-17-+0800.xcresult`.
  The raw USB signpost capture is
  `/private/tmp/abh519-phase3-approval-device-syslog.log`.
- The two ownership/backfill invariants also ran against the physical arm64 test bundle:
  2 passed, 0 failed. Log: `/private/tmp/abh519-phase3-focused-unit-device.log`; result
  bundle:
  `apps/ios/.derivedData/Logs/Test/Test-HermesMobile-2026.07.23_05-31-35-+0800.xcresult`.

The focused plugin seam slice was rerun after cleanup: 5 passed. `git diff --check` passes,
and the final product diff contains none of the temporary `ABH519_APPROVAL_*`,
`ABH519_STOCK_PAGE*`, or relay HTTP diagnostic signposts.
