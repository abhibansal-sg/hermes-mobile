# ABH-519 Phase 3 — retained-seam parity evidence

**Captured:** 2026-07-22 +08:00

**Branch:** `codex/abh-519-v019-phase3-parity`

**Base:** Phase 2 merge `565f357d8c29af744eadb34c24c76108e902bfbe`

**Status:** non-device verification is green. The physical-device gate is intentionally
open because the owner and iPhone Air are away. This phase must not merge until the device
checks below are captured.

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

## Physical-device gate still required

When the iPhone Air is available, install this exact branch build and capture:

1. background/locked turn completion, clarification, and approval each produce one
   actionable push;
2. the phone receives completion push when a desktop drives the session, but receives no
   redundant push while that same phone is foregrounded on the session;
3. a foreign turn live-follows without stealing ownership or producing a 4007;
4. **Load Earlier** works during an active streamed turn and preserves the live placeholder;
5. force-close/reopen still paints the same stored transcript from disk.

Only after those observations and the corresponding device log are committed is the Phase 3
gate complete.
