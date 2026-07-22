# ABH-519 Phase 4 — single-protocol deletion evidence

**Captured:** 2026-07-23 +08:00

**Branch:** `codex/abh-519-v019-phase4-deletion`

**Status:** Phase 4 implementation and focused acceptance gates are green. All
iOS checks ran on the attached iPhone 16 Pro Max. No simulator was booted or
used.

## Deleted architecture

- Deleted the relay reframer, session state, durable relay transcript, item
  protocol, relay client/coordinator, relay-only render hierarchy, and their
  duplicate protocol tests.
- The relay retains one authenticated transparent stock WebSocket/HTTP proxy.
  It routes and forwards; it does not parse stock frames or own session,
  transcript, translation, or persistence state.
- iOS retains `HermesGatewayClient`, `GatewayEvent`, `WorkRepository`/outbox,
  `CacheStore`, and `ConnectionStore`. New sends use explicit `session.create`
  followed by `prompt.submit`; stock events are the only live transcript input.
- The transport toggle is gone. An optional proxy address only changes the host
  used by the same stock HTTP/WebSocket protocol.

Complete Phase 4 branch diff, including this evidence and the stock render
fixture: **786 insertions, 41,961 deletions**. `git diff --check` passes.
Searches find no product references to
`RelayClient`, `RelayItemStore`, `RelaySessionCoordinator`, `RelayProtocol`,
`Reframer`, `session_state`, or `applyRelayItems`.

## Transparent relay gates

- Full retained relay suite: `26 passed`.
- Python phone driver using stock frames through the transparent relay:
  `1 passed`; no legacy item-stream frame was observed. Evidence:
  `hermes-tmp/evidence/daily-driver/e2e/test_stock_frames_round_trip_unchanged-stock-proxy.json`.
- The obsolete custom wire-conformance parser, item-stream recordings, and
  simulator render replay were deleted. Render conformance now drives the
  production `GatewayEvent` decoder directly from stock JSON-RPC events.
- No relay persistence, translation, transcript, or session-state implementation
  was added.

## Physical iPhone gates

Device: iPhone 16 Pro Max, iOS 26.5, UDID
`00008140-000648640A33001C`, controlled through Xcode/XCUITest.

- Surgical I1-I23-adjacent slice: **138 tests, 0 failures** in 11.59 seconds.
  This covers outbox idempotency, stock rendering/order, drive/watch ownership,
  prompt gates and task events, pending attention, pagination, steering,
  working-directory selection, and projects. Log:
  `/tmp/hermes-ios-build-29242.log`.
- Deliberately unavailable cache: exactly one history fetch for stored session B,
  no paint of pre-seeded session A, and the focused physical test passed. Log:
  `/tmp/hermes-ios-build-18747.log`.
- Migrated device-shaped database (build 116 upgraded through the current
  schema): **6 tests, 0 failures**, including reopen plus draft-born write. Log:
  `/tmp/hermes-ios-build-67893.log`.
- New chat, stock reply as a standalone bubble, drawer open, then four
  force-close/reopens: every reopen painted the same session from disk and no
  alert appeared. XCUITest log: `/tmp/hermes-ios-build-61910.log`.
- The USB device log proves the exact identity chain for `sess-acaaa0a3`:
  `CacheStore.init success` → `upsertSession success` → `saveTranscript success`
  → `cache-paint(HIT)` after every process restart. Committed excerpt:
  [`docs/evidence/ABH519-PHASE4-IPHONE16PM-DEVICE-LOG.txt`](evidence/ABH519-PHASE4-IPHONE16PM-DEVICE-LOG.txt).

Phase 3's retained-seam physical checks (clarification/approval push and
continuation, foreground suppression, foreign-turn follow, pagination, and
force-close repaint) remain recorded in
[`docs/ABH519-PHASE3-PARITY-EVIDENCE.md`](ABH519-PHASE3-PARITY-EVIDENCE.md).

## Hardware-only rule

Every iOS command used `scripts/ios-build.sh` with destination
`id=00008140-000648640A33001C` and `-collect-test-diagnostics never`. The latter
prevents Xcode's optional failure-diagnostics path from invoking `sudo`. No
password, trust, signing, or simulator interaction was required.
