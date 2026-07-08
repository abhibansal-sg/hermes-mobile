# SMOOTHNESS-SPEC — Make hermes-mobile feel like WhatsApp

**Origin:** Abhi (Board), 2026-07-07 — verbatim intent: *"Reconnecting should
happen in the background… very smooth, like WhatsApp — you never see
reconnecting and it's almost real time all the time. If there is an ongoing
chat and I turn my phone off, once the session ends I don't get any
notification. It just doesn't feel very smooth."*

**Evidence base:** three first-hand code audits (session pipeline, live
streaming, notifications — 2026-07-07, attached below as appendices in the
issue thread) + live-gateway state checks (APNs armed, 6 alert tokens
registered, broadcast on).

**North star (acceptance bar for the whole spec):** open the app → the last
state paints instantly from disk, the connection heals silently, a running
turn resumes mid-sentence, and when the phone is off/locked a finished turn
ALWAYS lands as a notification. No visible error flash, ever, for a
self-healing condition.

---

## WS-1 — Silent reconnect (kills the error flash)  [iOS only]

TODAY: cold open / foreground wake surfaces `.failed`/`reconnecting` state to
the UI immediately (ConnectionStore state machine → banner/flash), even when
attempt-0 reconnect succeeds in <1s.

SPEC:
1. CONNECTION STATE IS NOT AN ERROR. New UI contract: `disconnected(silent)`
   → grace window (5s cold open / 10s transient) during which the UI shows
   NOTHING except a subtle pulsing dot on the drawer header (WhatsApp's
   "connecting…" title treatment). Cached content stays fully interactive.
2. Only after the grace window elapses AND retries are failing does the state
   escalate to a visible pill ("Reconnecting…"), and only a hard auth failure
   (401/403 → re-pair) may show an error surface.
3. Scene-phase wake: probe liveness BEFORE tearing down the visual state —
   today `handleConnectionDrop()` fires first (stamps "Connection lost" into
   the transcript) and reconnect repairs after. Invert: optimistic keep,
   repair silently, stamp only if the grace window expires.
4. Send-path during grace: queue (outbox already exists) instead of erroring.

## WS-2 — Resume mid-turn (the dead-air fix)  [iOS + tiny server]

TODAY: reconnect mid-turn = "Connection lost" stub, then silence until the
turn completes and REST backfill repaints. THE SERVER ALREADY RETURNS the
in-flight partial turn (`inflight` on session.resume, server.py:4843) — iOS
`SessionOpenResult` (ProtocolTypes.swift:173) silently drops the field.

SPEC:
1. Decode `inflight` and seed the streaming bubble from it on resume — the
   half-written answer appears instantly, then live deltas continue.
2. Server: include `inflight` on the lazy/watch resume path too (verify).
3. Longer-term (M2): per-session monotonic seq on WS events + server replay
   ring buffer (last N frames) + `resume_from=seq` — true resumable stream,
   replaces throw-away-and-refetch. The mirror path's `broadcast_gap` marker
   already models the gap signal; generalize it to the owner path.

## WS-3 — Notifications that actually arrive  [plugin + iOS]

TODAY (audit + live check): APNs IS armed on :9119, 6 tokens registered,
broadcast on. But Abhi's exact scenario (turn running → phone off → turn
ends → no notification) fails. Confirmed candidate causes, in test order:
1. **<30s gate**: `push_engine.py:1582` suppresses turn_complete for turns
   under 30s — Abhi's quick turns produce NOTHING by design. SPEC: the gate
   is wrong-shaped. Replace duration gate with ATTENTION gate: push whenever
   no live transport holds the session foregrounded (phone off/locked/app
   killed = always push, 5s turn or 5min turn alike).
2. **Env mismatch**: tokens carry `env` (production/sandbox) sniffed from the
   provisioning profile; a TestFlight/dev-build mismatch sends to the wrong
   APNs host → silent 400/410. SPEC: log + surface per-token send results in
   the Settings push panel (truthful transport report already exists for
   test-push; extend to real sends — last-send status per token).
3. **Stale tokens**: 6 registered, unknown how many are dead (410-pruning
   exists but only fires on a send attempt). SPEC: Settings shows registered
   devices with last-success timestamp; prune visibly.
4. **Fire-and-forget queue**: drop-oldest 512 queue, no retry anywhere.
   SPEC (M1): failed APNs sends retry ×3 with backoff; queue overflow logs
   loudly; `apns-expiration` set to 4h (not 0) so APNs stores for an offline
   phone — this alone may fix "phone off" misses.
5. Relay-mode gaps (health latch, kind demotion, LA degradation) are OUT OF
   SCOPE here — direct APNs is the active transport; relay fixes ride ABH-338.

## WS-4 — Session list freshness without the refetch tax  [plugin + iOS]

TODAY: 30s heartbeat refetches EVERY loaded row (500 rows = 500-row JSON
every 30s forever); `/api/sessions` has no delta cursor; plugin transcript
delta route reads the FULL transcript server-side per poll.

SPEC:
1. Server: `GET /sessions?updated_since=<cursor>` returning only changed rows
   + tombstones; iOS heartbeat sends the cursor, merges deltas. Heartbeat
   drops to a cheap no-op when nothing changed.
2. Server: transcript delta route answers "no change" from
   `WHERE id > ?` + count (O(tail)), not full materialization (api.py:1614).
3. iOS: WS `message.complete` already triggers the 400ms debounced refresh —
   with (1) this becomes near-free; keep 30s poll as fallback only.

## WS-5 — Instant open (finish the built-but-unwired fast path)  [iOS]

TODAY: `shape=skeleton|light` payload tiering is BUILT server-side
(transcript_sync.py:119) — zero Swift call sites. Jump-to-message has no
server `around=` mode, degrades silently on long sessions.

SPEC:
1. Wire `shape=skeleton` into the cold-open seed → hydrate to full in the
   background (the server work is done; this is a client param).
2. Add `around=<id>` page mode to the plugin messages route; ChatView jump
   uses it when the target is outside the loaded window.
3. Keep the 4-phase cache-first open (it's correct); add the same
   prefetch-on-connect sweep for the TOP session only at `shape=light` to
   make the most-likely-opened chat instant.

## WS-6 — Mirroring polish  [iOS]

TODAY: foreign-turn adoption + `stampActivity` are correct; firehose fan-out
filters client-side (fine at current scale — explicitly NOT a problem to fix
now).

SPEC: only one change — drawer rows for live foreign sessions show the
streaming pulse (already works) AND the first line of in-flight text (from
mirror deltas, throttled) so glancing at the drawer shows what every session
is doing. Cheap, pure client.

---

## Sequencing (architect refines into work units)

- **M0 (this week, small diffs, huge feel):** WS-1 grace window, WS-2.1
  inflight decode, WS-3.1 attention gate + WS-3.4 apns-expiration, WS-5.1
  skeleton wiring.
- **M1:** WS-4 delta cursor + O(tail) server read, WS-3.2/3.3 token
  truthfulness, WS-5.2 around-fetch.
- **M2:** WS-2.3 seq/replay resumable stream (the real project; spec its
  protocol before building).

Every WU: UI-evidence law applies (recordings, iPhone+iPad); reconnect WUs
must include a chaos test (kill WS mid-turn 10x — the soak suite's ws_flap
pattern as an XCUITest).

## Non-goals
CloudKit for transport/push (wrong basket — sessions live on the gateway);
relay tunnel work (ABH-338 owns it); N×M fan-out scoping (premature at
current scale).
