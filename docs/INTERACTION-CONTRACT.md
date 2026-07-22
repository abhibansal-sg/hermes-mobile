# INTERACTION CONTRACT — Hermes Mobile, RELAY-ONLY transport

**Status:** definitive spec. This is the test oracle for `tests/render_conformance` +
`tests/e2e_daily_driver` extensions (Round 4). Every clause is written as an assertion a
harness can check; the invariant list (§4, **I1–I23**) is the normative core.
**Synthesized from:** Matrix A (chat lifecycle, 13 interactions × 6 connection states),
Matrix B (turn control + navigation + surfaces, 14 sections), the desktop reference study
(new Electron app @ `f2c2d1044c`), the plugin-route deletion audit. All tree citations are
`qa3-base` @ `c44e7f8d9` (main); iOS paths relative to `apps/ios/HermesMobile/`, relay to
`relay/hermes_relay/`.
**Scope of "relay-only":** the relay is the sole **chat / turn / session-list / transcript**
transport. The gateway REST control plane (model, providers, personalities, skills, cron,
webhooks, fs, devices, usage — audit §4) is out of contract scope and stays REST. The
contract says nothing about Settings panels except where they touch transport (B11).
**Amended (Opus review, 2026-07-22):** the binding amendments — G1 (gate move-semantics),
G2 (foreign userMessage lane L6 + X5 after-L6 gate), A1 (render-layer void tests), G3
(I23 pending-gate recovery), G4 (ord adoption on cmid adoption), I9-gate, W0-determinism,
S1/S2 (sequencing + illusory fallback), S4 (drift split), L5-lean (projects stay REST) —
are folded INLINE (see `amendment` markers), not appended.

**Abbrev:** CS=Stores/ChatStore.swift · SS=Stores/SessionStore.swift ·
ConnS=Stores/ConnectionStore.swift · RSC=Stores/RelaySessionCoordinator.swift ·
RIS=Networking/Relay/RelayItemStore.swift · RC=Networking/Relay/RelayClient.swift ·
DS=relay/downstream.py · RP=Models/RelayProtocol.swift · OBX=Stores/OutboxProcessor.swift ·
AE=App/AppEnvironment.swift

---

## 1. State model

### 1.1 Transport — one socket, server-stamped session id, client routing (desktop §0.1, §1)

- The app holds **exactly one** WebSocket to the relay. There is no subscribe/unsubscribe
  RPC; the relay's session→connection binding (foregrounding, `DS:874-881`) is the
  subscription. Reconnect re-binds, never re-subscribes.
- **Every downstream frame carries a non-optional `sid`** (`RP:20-35` — verified: `sid` is a
  non-optional `String` on `RelayFrame`). This is the whole leak-prevention substrate: the
  client never guesses "active session"; it routes by the stamped id and **drops frames it
  cannot attribute** (desktop `gateway-events.ts:84-129`; unscoped `subagent.*` dropped).
  The relay already satisfies this; the iOS violation is folding any `sid` into one store
  (`RSC.ingest` `:454-458`).

### 1.2 Session transcript state — one store per session, map-keyed, write-gated (desktop §2, §3)

The live transcript authority is an **in-memory map**:

```
SessionTranscriptMap: [storedSessionID : SessionTranscript]
SessionTranscript = { store: RelayItemStore        // settled items + live tail, one owner
                    , paint: [ChatMessage]         // cache-painted seed rows (untagged)
                    , epoch: Int                   // selection epoch that bound it
                    , turnState: .idle | .live(owner: TurnOwner) | .settled(Outcome) }
```

- **One `RelayItemStore` per session** (current: one per coordinator, `RSC:121` — the D3
  root). Frames route to the entry named by `frame.sid`; an entry is created on first touch
  (open / draft-send create / inbound frame for a known session). Bounded LRU (≤8 entries);
  eviction writes through to `CacheStore` first.
- **Render authority = the item stream.** The relay `snapshot` / `open` / `history` payload
  seeds a session's store; the stream then owns it (`RIS:5` "The app is not wired to it yet"
  is the sentence this contract deletes). REST transcript fetchers are not a source at all.
- **Write-gate, not teardown** (desktop `use-session-state-cache.ts:189-246`): background
  sessions keep streaming into their OWN entry; **only the active session's entry may project
  into `ChatStore.messages`**. A session switch changes which entry may paint. Nothing
  stream-side is cancelled, reset, or torn down on switch — the current
  `resetItemStoreForSessionSwitch` reset-on-switch (`RSC:740-757`) and `projectionSuppressed`
  park (`RSC:123-162`) both violate this and both delete. **Gate cards (approval/clarify)
  park on the owning entry and MOVE with the write-gate**: a switch takes the card off screen
  and re-shows it on switch-back; only turn-end or an explicit answer expires a gate, never a
  switch (A13/I12).
- **Cache is a seed, never a co-author** (desktop §2 lesson): `CacheStore` paint renders
  settled content synchronously on open (warm path, this tick); the store's first
  snapshot/stream application supersedes painted rows by **item-id union**; the cache never
  writes after the stream has spoken for an item. The durable cache exists because mobile is
  offline-capable and desktop is not — but its role is identical: paint-first seed.

### 1.3 Session store lifecycle

```
   intent(open/draft/notification-tap)          inbound frame for known sid
            │                                            │
            ▼                                            ▼
  ┌─ create/lookup entry ◄──────────────────────────────┘
  │     · bump selection epoch (monotonic, at intent, sync, pre-await)   [I4]
  │     · pin (storedID, draftToken) for any in-flight submit            [I5]
  │     · paint from cache (sync)                                        [I3]
  │     · attach: mark entry active; move write-gate to it               [I2]
  │     · clear-then-paint: outgoing projection dropped AT INTENT        [I2]
  │     · reconcile: relay open(resume) snapshot ∥ cache paint           [I3,I14]
  │     · arm per-session liveness from snapshot baseline                [I10]
  ▼
  live  · frames fold into entry.store by (sid, item_id)                 [I1,I21]
        · only active entry projects to ChatStore.messages               [I2]
        · turn end: turn.completed{reason} settles entry.turnState,
          persists write-through, gap-fills once iff stream was empty    [I9,I14]
  ▼
  switch · write-gate moves; outgoing entry KEEPS folding frames         [I2]
         · switch-back repaints from the entry — zero refetch if warm    [I14]
  ▼
  evict  · LRU; write-through to CacheStore; entry drops only when
           settled AND not the active entry                              [I3]
```

**Draft is the absence of a session, not a suppressed one.** A new-chat draft has no entry
and no id; therefore nothing from any session can paint into it (desktop
`startFreshSessionDraft`, `use-session-actions:200-233`). The draft surface becomes a real
entry atomically when the submit-create returns the new id.

### 1.4 Turn state machine

```
 idle ──send/turn.started/snapshot-with-in_progress──► live(owner: local|foreign)
 live ──turn.completed{reason: completed}────────────► settled(completed)   → queue may drain
 live ──turn.completed{reason: interrupted|error}────► settled(discarded)   → queue HOLDS   [I9]
 live ──local STOP intent────────────────────────────► settling (local UI settle FIRST,
        (interrupt RPC second; late frames for this turn no-op)              [I9]
 live ──silence past stage-1─────────────────────────► resync{last_seq} (silent, once)       [I10]
 live ──silence past stage-2─────────────────────────► settled(provisional): end LA + gates,
        late delta resurrects; queue does NOT drain on a provisional settle  [I10]
```

`TurnOwner` is stamped at turn start: `local` when this phone submitted, `foreign` when the
turn came in via snapshot/stream without a local send. Foreign turns get the same liveness
treatment as local ones (current violation: baseline stamped only at send, `CS:2712` — D11).

---

## 2. Per-interaction contracts — chat lifecycle (Matrix A)

Each contract is the **single correct data flow** under relay-only. Bracketed refs are the
binding invariants (§4). "Deletes" names the current-wiring compensation the flow renders
dead (see ROUND4-LEAN-PLAN.md for the deletion waves).

### A1. Cold open → last session
Cache paint of last-opened session synchronously (frame 0) [I3] → socket up (relay
coordinator is the ONLY reconnect owner [I13]) → attach the painted session's entry, mark
active [I2] → exactly-once reconcile: one `resume`/`open` snapshot over the paint [I3,I14] →
composer unlocks on entry-bind. If the snapshot carries in-progress items, render them
streaming and **baseline the liveness clock from the snapshot** (fixes the cold-resume arming
gap, Matrix A I9/D11) [I10]. No modal over a retryable condition [I17].
**Budget:** paint + ≤1 snapshot. Current triple-fetch (phase-2 REST seed + resume snapshot +
reconnect re-open, D6) violates I14.
*Deletes:* phase-2 network seed for relay opens (SS:5808-5853), `resumeActiveAfterReconnect`
second resume (ConnS:1644-1648), gateway loop arming via NWPathMonitor (ConnS:2567-2592).

### A2. Open existing idle session (drawer tap)
Epoch bumps at tap tick, sync [I4] → outgoing projection cleared at intent (clear-then-paint,
not after new lands) [I2] → warm entry paints this tick; cold entry paints cache, snapshot
fills ∥ (prefetch ∥ resume, desktop §3) [I3] → drawer closes on first paint or 300 ms
deadline (unchanged, S9-intent machinery is correct — Matrix B §9) → entry binds, composer
unlocks. The outgoing session's entry is NOT torn down: its frames keep folding into its own
store; only the write-gate moved [I2]. The relay keeps forwarding the old session's frames —
that is now a feature (fast switch-back), not a leak.
*Deletes:* `resetItemStoreForSessionSwitch` store reset + manual gate/task/LA clears
(RSC:740-757 — the gate expiry-on-switch deletes OUTRIGHT, not relocated: gates move with
the entry, amendment G1), `endRelayTurnForSessionSwitch` discard dance (CS:1686-1691).

### A3. Open session with a LIVE turn (own or foreign)
Paint settled tail → snapshot attaches mid-stream with `in_progress` items → entry.turnState
= `.live(owner:)` from the snapshot itself: `local` if a durable echo for the turn exists,
else `foreign` [I10] → render with stop affordance; **liveness baselined at attach** (both
owners) [I10] → `turn.completed{reason}` settles; duration reconciles from `duration_s`.
A completed-turn action row never renders while the store reports in-progress items [I9].
The foreign turn's prompt row renders from a **relay-emitted `userMessage` item** (lane L6):
the reframer maps agent events only, so a desktop-originated prompt has no user row on the
relay wire today (D11's render half) — until L6 is live the foreign-mirror subsystem stays
(A13-gate of ROUND4) [I7].
*Deletes:* the send-only liveness baseline (CS:2712 as sole stamp site).

### A4. New chat → type → send (draft)
Draft surface = no entry, no id: renders ONLY its empty timeline — structurally, not via a
suppression flag [I2,I6]. Send → pin `(storedID=nil, draftToken)` [I5] → echo + caret ≤100 ms
from LOCAL state (QA-2 A2 rule) [I8] → submit with **nil** target → relay creates (`DS:759-763`)
→ returned id adopted atomically: entry created, write-gate moves to it, projection live,
drawer row appears, outbox affinity maps, `foreground` set [I6], **the created sid is
OPEN-treated at adoption — the user row + session row written to the local cache FIRST
(write-local-first) and the one-shot relay open/seed-bind fired (amendment R4b) — so the
new chat is paintable from the store the instant it exists and survives a force-close at any
point after the send** [I5 second half] → a second send targets the
NEW id [I5]. If the user switches away mid-create, the just-created orphan session is closed
(desktop `submit.ts:262-270`) and the optimistic echo dropped — the nil-target branch of the
drift split [I5,I11].
**Current violations this deletes:** `target = sessionID ?? activeSessionID` fallback
(RSC:654 — submits into the PREVIOUS session, D2), retained `activeSessionID` across
`startDraft` (RSC:139-142), `suppressProjectionForDraft` machinery (RSC:123-162), the
stage-2 "Interrupted" dump of the suppressed turn (RSC:584-587), and the dead
`.creatingDestination` → gateway `session.create` drain path (AE:127-130 → SS:4435-4446,
D10) — a queued draft drains via relay SUBMIT-nil (create) instead.

### A5. Send in existing session
Pin target = selected stored id [I5] → echo + caret local, one durable echo identity (the
outbox-row cmid) created at intent [I8] → per-session submit lock [I5] → relay `userMessage`
item adopts the echo **in place by cmid, assuming the server item's `ord`** (never by text,
never at the optimistic tail position) [I7,I8] → deltas stream into the same caret bubble id
→ `turn.completed{reason:completed}` settles, server duration stamps → queue drains [I9].
Exactly one turn per send; relay cmid-dedup folds ambiguous flap-resubmits
(DS:729-738) [I11,I21].

### A6. Rapid double-send
Send 1 = A5. Send 2: per-session lock sees busy → queued silently with its own durable echo
row (no transient second echo+caret flash — current "double working flash + identity swap"
CS:2670-2707→2791-2816 violates I8) [I8,I11]. Turn 1 completes (`reason:completed`) → turn 2
drains and submits once [I9,I11]. Two sends never collapse to one turn (distinct cmids),
never lost.

### A7. Send while previous turn streams (queue-mode entries: voice, App Intents, steer-then-send)
Same as A6. The authoritative busy signal is the **relay/gateway 4009**, not the render-side
`isStreaming` (render state is a hint that can lie after a dropped `turn.completed` —
Matrix B §4 gap) [I11]. Per-session affinity: a row for session A drains only when the relay
drives A (`outboxRuntimeID(forStored:)` semantics kept, RSC:682-684) [I11].

### A8. Switch session mid-turn, come back
Outgoing: write-gate moves; entry KEEPS its store, gates, timer state parked; its Live
Activity ends as a discard (the user stopped watching) [I2,I9,I16]. The gateway turn keeps
running; its frames keep folding into the parked entry [I1,I2]. Incoming: A2. Return: the
parked entry repaints — still-live turn renders from its store + snapshot delta, **no
refetch if warm** [I14], no duplication (id-union), no leak either direction (sid-routed).
The outgoing turn's later `turn.completed` settles ITS OWN entry: expires that entry's
gates, ends nothing on the active entry, drains only if `reason:completed` AND affinity
holds [I1,I9] — current spurious gate-expiry/queue-drain against the wrong session
(RSC:511-525) is impossible by construction. Returning re-baselines liveness from the
repainted live items [I10].

### A9. Force-close mid-turn, reopen
Gateway turn continues (by design). Cold open = A1: durable echo (one identity, keyed by
cmid, re-homed onto the created/adopted session id) + cached tail paint [I8,I3] → resume
snapshot shows the turn live or settled exactly once [I14]. **No false "Interrupted" for a
turn that is alive:** snapshot-with-in-progress baselines liveness [I10]; a turn that died
while closed settles by the watchdog (stage 1 resync first) rather than rendering eternal
"working" [I10].

**Force-close during clarify (pending-gate recovery across restart):** a gate (approval /
clarify) left UNANSWERED at kill re-raises on cold-open resume — gate re-delivery (resync
ring replay / snapshot) re-parks it on the owning session's entry and the card renders again,
answerable by the normal routing; it never re-raises a gate that was answered or turn-ended
before the kill [I23].

### A10. Scroll back during streaming
Reader up → auto-follow disengages → older content pages from the session's settled store
(relay `history` page when the in-memory window exhausts) — **paging is never gated on
streaming** (current `CS:3856-3860` violates I19) → jump-to-bottom pill → streaming appends
at the tail without moving the reader [I19]. Delta application must not rebuild the whole
`messages` array per frame (current CS:5425-5428) — append-only tail mutation while the
reader is detached. Content or skeleton above, never void (QA-1 B4 / QA-3 S7 rule).

### A11. Background / foreground mid-turn
Background: `foreground` cleared (push suppression honest) [I16]; the socket keeps living if
iOS lets it. Foreground: re-assert `foreground`; **reconcile the visible session exactly
once** (one resync/snapshot of the active entry) [I14]; the live turn resumes rendering with
no teardown [I2]. **No gateway liveness probe, no gateway reconnect loop, no grace-window
escalation, no "Connection lost" banner over a healthy relay turn** — the current D4/D7 path
(ConnS:3275-3284 → 2654-2660 → 2455-2463) violates I13 wholesale. Relay reconnect has
exactly one owner (the coordinator driver, RSC:423-450); scene/wake/foreground signals nudge
it with counter reset (desktop §6 layering) [I13].

### A12. Notification tap → session
Tap resolves the owning session by **stored id** from the relay-composed payload (S12) →
`open(summary)` = A2 flow [I4] → never the Inbox unless the id is genuinely unresolvable
after one bounded refresh [I17]. Tap onto the already-active session is a cheap re-focus:
**no resume RPC, no snapshot refetch** (current full re-fetch, Matrix A I12 C1, violates
I14). Cold tap may supersede the last-opened restore — the superseded open's in-flight RPC
is cancelled, not merely result-fenced [I4,I14].

### A13. Session with taskList / approval / clarify pending
Gate and taskList state is parked **per session entry**, not per active view (desktop
`gateway-event.ts:483-602`: dropping a one-shot request for an unfocused session is
unrecoverable) [I12]. The card renders in the dock of the OWNING session only; a gate frame
for A never shows while B is on screen (current D3 cross-session card, Matrix A I13, is
impossible once frames route by sid) [I1,I12]. Answer routes by explicit
`(session_id, request_id)` regardless of current screen [I18]. **A session switch MOVES the
gate with its owning session** — the card leaves the screen with the session and re-appears
on switch-back; **ONLY turn end (`turn.completed` — any reason) or an explicit answer
expires the gate**, exactly once (the `expireRelayPendingGates`-on-switch call deletes in
R1 — expiry-on-switch does not move to the write-gate, it ceases to exist). The
answered-gate id suppresses resync re-delivery (the `resolvedRelayGateIDs` mechanism stays —
it is idempotency plumbing, not compensation) [I12,I21]. The taskList pill shows only for
the active session's live turn's non-terminal list; turn end / switch / terminal list
dismisses; a resync replay never re-raises a dismissed list past its turn [I15].
Secure-prompt (sudo/secret) kinds do not exist on the relay wire — they settle as expired
with an inbox pointer, never as a dead card [I17].

---

## 3. Per-interaction contracts — turn control, navigation, surfaces (Matrix B)

### B1. STOP a streaming turn
Tap → **local settlement FIRST**: mark entry `settling`, finalize partial text (keep
non-empty, drop empty caret), clear busy/stop affordance (desktop `cancelRun`
`use-prompt-actions:510-593` pattern) [I9] → THEN relay `interrupt` with the turn's explicit
session id [I18] → the `settling` mark gates late frames for this turn to no-ops [I9].
**Stopped ≠ completed:** the eventual `turn.completed{reason:interrupted}` settles the entry
and **does NOT drain the queue** (current `notifyRelayTurnCompleted` → `queueStore.wake()`,
AE:295-298, drains into a just-stopped session — Matrix B §1 gap b) [I9]. R-FLAP: interrupt
queues on relay-ready (the `waitUntilOpen` analog open/resume already have, RSC:206-217) —
no "Not connected to the relay" banner over a transient state [I17].

### B2. Interrupt-with-new-message (replace)
One gesture: discard current turn (B1 local settlement) + submit new prompt to the same
session in the same pipeline, pinned target [I5,I9]. Until the primitive exists, the UI must
not imply it (current Steer/Queue-only menu is honest) [I22]. Approximation path
(stop→wait→send) must still hold A6 semantics if the user performs it manually.

### B3. STEER mid-turn
`session.steer { session_id, text }` verbatim; no local turn mutation (server-managed)
[I18]. `queued` clears the field with an inline transcript row (not a toast); `rejected`
keeps the text and **offers one-tap queue** (desktop `steerPrompt` fallback; current note
says "queue it instead" with no action — Matrix B §3 gap) [I11]. R-FLAP: queue-on-ready,
text kept [I17].

### B4. QUEUE a message
Durable row stamped with the target stored session id (or new-session token) at enqueue
[I11]; visible immediately; survives kill. Drain: per-session busy gate + relay affinity
(kept) [I11]; wake on authoritative `turn.completed{reason:completed}` and on relay `.open`
edge. **A provisional watchdog settle (§1.4) never drains** — it ends LA + gates only
(Matrix B §4 gap: current stage-2 settle fires `onTurnComplete` → drain into a
possibly-live gateway turn → 4009 churn) [I10,I11]. Flap-mid-submit resubmits the same cmid;
relay dedup replays, re-emits the userMessage; one turn, one bubble [I11,I21].

### B5. CANCEL a queued message
Row tombstoned durably BEFORE the UI confirms (QA-2 R14 semantics kept — commit precedes
observation, QueueStore:379-387) [I11]; force-quit in the same instant cannot resurrect.
Transcript echo removal marks reconciled so warm paint can't repaint it [I8]. Local-only:
identical in every connection state. An already-accepted prompt has no wire-level cancel —
honest gap, surfaced as such, never as an error [I17,I22].

### B6. Approve / deny an approval card
Card state parked per session entry [I12]. Answer: optimistic clear + resolved-id mark,
then relay `approve { session_id, decision[, request_id, all] }` [I18]. **R-FLAP at tap:
the answer queues on relay-ready** — the card stays cleared locally and the RPC retries once
open; the agent is never left blocked with no retry (current `lastError`-and-forget,
Matrix B §6 gap) [I17,I18]. Turn end / answered-elsewhere expires exactly once; a switch
MOVES the card with its session — never expires it [I12]. Notification banner actions route
through the relay HTTP control sibling when the WS is unavailable (closes the cold-tap gap
on relay-only reach — see ROUND4 lane L4) [I18].

### B7. Answer / dismiss a clarify card
Same contract as B6, with `clarify { session_id, text, request_id }` — `request_id` required
(missing ⇒ gateway 4009 + permanent block, CS:3572-3577) [I18]. Local answer-echo row is
untagged so the sid-routed projection preserves it [I8]. Choices wrap, long text scrolls,
`isResponding` re-entry guard kept (R9/R10/P1 — correct as-is). Flap-at-tap queues on ready
exactly like B6 [I17].

### B8. taskList lifecycle
Covered by I15 + A13. The relay mirror (`refreshRelayTaskListMirror`) reads ONLY the active
entry's store; turn.started clears for a fresh seed; terminal list auto-dismisses; switch
moves the gate with the write-gate, no manual clear needed once entries are
session-scoped [I2,I15].

### B9. Drawer open → tap session (incl. during in-flight load)
Unchanged — this is the most-patched surface and the contract ratifies it: pointers land
sync at tap tick; close is an intent fired on first paint or 300 ms deadline; monotonic
epoch drops superseded programmatic intents (S9 `drawerUserGestureEpoch`, orthogonal to
transport — Matrix B §9). The contract adds: superseded opens cancel their in-flight relay
RPC, not just the result application [I4,I14].

### B10. Projects → project → sessions → open
**Projects stay on the gateway REST control plane permanently** (ROUND4 decision, amendment
L5-lean): the projects overview and the project-detail session list are request/response
reads (a near-static cwd list + a cwd-scoped session list) — the contract shows NO live-
streaming requirement, so building a parallel relay `projects` path while REST projects
survives is the duplicate-transport anti-pattern the lean mandate forbids (lane L5 is
dropped). Cache-first paint kept; the S10 "refuse authoritative empty" backstop stays
[I3,I17]. What IS fixed: new session in a project threads `cwd` through the relay SUBMIT
create params (lane L2's create branch — current gap: `downstream.py:759-763` takes only
title/model/provider — Matrix B §10 gap) [I6]. Row tap = A2. **Recorded limitation:** on
GW-UNREACH (the daily-driver phone's topology) projects paint from cache when warm and show
an honest unavailable state when cold — preferred over a second transport for a surface
with no streaming requirement; revisit only if projects ever need live updates.

### B11. Settings transport toggle
**Deleted by the contract.** Relay is the only transport; the toggle, the relay-URL override
field, and the `transportPath` reader go away (ROUND4 Wave 4). The `#if DEBUG` env overrides
stay for the sim E2E harness only. Live-swap corruption becomes unrepresentable.

### B12. Retry failed send
Unchanged contract: one tap re-drives the existing row, shared cmid end-to-end, red badge
only for terminal `.failed`, stuck predicate protocol-truth (QueueStore:232-258 kept)
[I8,I11]. Copy fix: a row held on relay affinity (destination not driven) says "waiting —
open that session", not "needs retry" [I17].

### B13. Share / branch / regenerate
Share = local text export, transport-independent. Regenerate / edit-and-resend ride relay
SUBMIT with `truncate_before_user_ordinal` passed through (lane L2 — the relay currently
drops unknown params, DS:720-724; the gateway already accepts it). Branch rides a relay
seeded-create (lane L2) [I5,I18]. Today all three except Share are DEAD in relay mode
(Matrix B §13: direct-only `prompt.submit` / `session.create` seams, CS:3262-3269,
SS:4490-4494) — silent functional regression vs direct mode; the contract makes them
relay-native and the direct seams delete.

### B14. Live Activity + push arrival
LA starts on turn start (local send OR snapshot-with-in-progress — foreign turns included),
ticks from frames, marks gates, **ends exactly once** on `turn.completed` (any reason) /
session-switch discard / provisional settle [I9,I16]. Push suppressed while the phone holds
that session foreground (relay §6 gate, honest because foreground clears on background and
re-asserts on foreground — ConnS:3191-3215 kept) [I16]. Banner tap deep-links by stored id
(A12) [I4]. Banner APPROVE/DENY/REPLY actions route via relay HTTP when cold (B6/B7, lane
L4) [I18]. Remote LA content pushes (gateway REST registry) are out of scope — the local
elapsed timer + relay-frame-driven updates suffice on relay-only reach.

---

## 4. Invariant list (the test oracle)

**I1 — Session identity.** Every item applied to a session's transcript derives from a frame
whose `sid` equals that session. Frames for a non-active session fold into THAT session's
entry (creating it if known); frames with no attributable session are dropped, never folded
into the active session. *Assert:* with B active, inject `{sid:A, itemDelta}` → `B.messages`
byte-identical; entry A gains the item; inject `{sid:unknown}` → dropped, no entry created
for an id the app never opened.

**I2 — Single projection (write-gate).** At every instant exactly one session's entry
projects into `ChatStore.messages`. A switch atomically moves (projected sid, gate
membership, per-turn timer, Live Activity ownership); the outgoing entry is not reset or
cancelled. *Assert:* after switch A→B, zero rows in `messages` derive from A's store; A's
store keeps folding frames received after the switch; no `applyRelayItems([])` blank frame
is ever emitted (QA-1 B4).

**I3 — Cache is seed, stream is authority.** Cache paint is synchronous at open and is the
only writer until the entry's first snapshot/stream application; from then on, painted rows
survive only by item-id union with store rows (same id ⇒ store wins; unknown painted id ⇒
kept as unsettled seed). The cache never overwrites a store-owned item. *Assert:* paint
rows + snapshot with overlapping ids ⇒ exactly one row per id, store content wins; a painted
row absent from the snapshot but with no store row ⇒ retained until turn settle.

**I4 — Monotonic selection epoch.** Every open/switch/draft/notification-tap bumps a
monotonic epoch synchronously at intent, before any await. Any async result (seed, resume,
bind) applies only if the epoch is still current; superseded results are RPC-cancelled, not
merely discarded after the fact. *Assert (cancel-spy on the relay RPC layer — amendment
W0-determinism):* fire open(A) then open(B) 1 tick later ⇒ A's in-flight resume is observed
CANCELLED on the wire (not merely result-fenced after completion); `messages` ends as B's;
no alert fires for the superseded op (QA-1 B1/B3).

**I5 — Submit targeting.** Target resolution at send-intent: (1) explicit selected stored id
⇒ drive/resume THAT session; (2) nothing selected (true draft) ⇒ nil ⇒ relay creates. There
is NO fallback to a previously-driven session. The pinned `(storedID, draftToken)` is
re-checked after every await; drift splits (amendment S4): **drift on an existing-session
pin (storedID ≠ nil) ⇒ the send converts to a durable queue row against the PINNED id**
(never redirected, never lost — I11 asserts the drain); **drift on a draft / nil-target pin
⇒ the optimistic echo drops and the just-created orphan closes** (the minted session is not
where the user is — desktop `submit.ts:262-270`). One in-flight submit per session
(per-session lock). **Draft-born paints write-local-first (amendment R4b, second half — the
Telegram/WhatsApp invariant: the store is the render authority; a new chat writes to the
store FIRST, the network heals behind it):** a session the relay CREATES on a nil-target
submit is born AFTER any open edge, so it gets the open treatment atomically at adoption —
(a) WRITE-LOCAL-FIRST: the created session's `session_cache` row + a `message_row_cache`
row for the optimistic user message (carrying the send's cmid) are written through the
existing `CacheStore` path the INSTANT the created sid lands (`landRelayCreatedSession`),
so a force-close at any point after the send reopens to a cache-HIT paint of the user row
(I3/I20) — never the base-tree `cache-miss(reset)`-forever blank (device-proven 2026-07-22:
the relay shows the session, the phone shows nothing); (b) the created sid IS an OPEN edge:
adoption fires the one-shot relay open/seed-bind (`setForeground` + `open`, the same seam
the `.open`-edge re-establishment runs — the relay's open seeds its store so every later
resync snapshot carries the prompt), counting as the session's ≤1 snapshot read (I14); (c)
the relay `userMessage` item (same cmid) adopts the cache-painted user row IN PLACE after
any reopen (I8 — one identity, never re-keyed, never duplicated). An existing-session send
never takes this path (the draft/nil-pointer guard). *Assert:* with `activeSessionID=P` retained from a prior session, draft
send submits `session_id=nil` (relay creates NEW id, never P); switch mid-await on the draft
(nil) pin ⇒ echo dropped, orphan closed, no turn attributed to either session; send pinned
to an existing session + switch mid-await ⇒ row enqueued against the PINNED id, drains there
exactly once, never the switched-to session; double-tap send ⇒ second tap blocked by the
lock, queued, not double-submitted; **draft send ⇒ the created sid gets exactly one `open`
upstream and ZERO `history` upstreams, the cache gains the session row + the user row (cmid
intact), and the store paints user row + streamed reply; force-close immediately after the
send + reopen ⇒ the user row paints FROM THE CACHE with zero transcript fetches, and a late
snapshot/resync carrying the cmid reconciles to exactly one user row; a send into an
existing session writes no create-land cache row and submits its pinned id.**

**I6 — Draft isolation.** A new-chat surface has no session entry and renders ONLY its empty
timeline; no frame, snapshot, or parked state from any session can reach it (structurally —
no suppression flag exists to fail). On submit-create, the returned id is adopted atomically
across drawer, outbox affinity, projection, and foreground; the immediately-following send
targets the new id. *Assert:* with another session mid-turn, enter new chat ⇒ timeline empty
for 10 s of frame traffic (QA-3 S11); send ⇒ new id everywhere; second send's submit frame
carries the new id.

**I7 — Chronology.** The rendered timeline is a stable chronological merge keyed by
`(ord, arrivalOrder)` (RIS ordering kept); an optimistic echo inserts at the turn's tail
position, and **on `userMessage` adoption by cmid the echo ASSUMES THE SERVER ITEM'S `ord`
— not its optimistic tail position** — so reconciled chronology is wire-true (amendment G4;
this natively replaces the untagged-twin-consumption heuristic R1 deletes: the echo IS the
user row, there is no twin to consume); a tool/`taskList` frame flushes queued text deltas
first so no tool row ever renders ahead of preceding text (desktop `index.ts:288-297`); no
item renders out of order, disappears, or leaves a void gap — live or after any reconcile.
*Assert — STORE layer (replayed fixture sequences from QA-3 S4/S6/S7):* for every rendered
frame, `ord` non-decreasing; userMessage always precedes its turn's agent items — local AND
foreign turns (the foreign `userMessage` is relay-emitted, lane L6 — amendment G2).
*Assert — RENDER layer (UI-level e2e scroll or snapshot, NOT store replay — amendment A1):*
no index with empty row geometry, no void gap live or after any reconcile.

**I8 — One echo identity.** Exactly one durable echo per send, created at intent, carrying
the outbox row's cmid as its stable id (monotonic-counter id, never timestamp-only —
desktop `uniqueMessageId`); it morphs IN PLACE on `userMessage` adoption by cmid —
**adoption re-homes the echo onto the server item's `ord` (row id unchanged, ordinal now
the server's), never onto a re-keyed row** (amendment G4); it is never
removed-then-re-presented; it survives session switch and store rebuild until reconciled;
adoption matches by cmid only (no fuzzy text fallback). *Assert:* flap during submit ⇒ still
one bubble after resubmit-dedup; switch away and back ⇒ the echo is the SAME row id; a
`userMessage` with a foreign cmid never adopts; after adoption the row's `ord` equals the
server item's `ord` (not the optimistic tail position).

**I9 — Turn-end semantics.** `turn.completed{reason}` is the sole completion edge.
`reason:completed` ⇒ gates expire once, LA ends once, timer settles to `duration_s`, queue
may drain. `reason:interrupted` (user stop) or `reason:error` ⇒ gates expire, LA ends, queue
HOLDS. A local STOP settles UI immediately and gates late frames for that turn to no-ops;
item terminality alone never ends the turn (build-115 rule kept). *Assert:* stop with one
queued row ⇒ `turn.completed` arrives ⇒ row still queued; normal completion ⇒ row drains
within one wake; replay `[error, turn.completed]` ⇒ one LA end, one discard, zero drains.
**L3-gated (amendment I9-gate):** the `reason` field is delivered by relay lane L3; W0a
records the reason-dependent assertions (interrupted-vs-completed drain split) RED-BY-DESIGN
until L3 ships — until then iOS distinguishes user-stop via the local `settling` mark and
error via the `relayTurnTerminatedByError` latch, both deleted when W2e consumes L3.

**I10 — Liveness.** Every `.live` entry (local OR foreign, send-started OR
snapshot-resumed) has a silence clock baselined at turn start and refreshed only by
current-turn frames (the `frameBelongsToCurrentTurn` boundary, RSC:546-561, kept). Stage 1:
one silent `resync{last_seq}`, idempotent. Stage 2: provisional local settle — muted
"Interrupted" fold, ends LA + gates, **does NOT drain the queue**; a late delta resurrects.
No eternal-working state is reachable; no false "Interrupted" for a turn that is actively
streaming. *Assert (driven by an injected VIRTUAL CLOCK — no wall-clock sleeps; stages fire
on scheduled time-advance — amendment W0-determinism):* dead foreign turn in a reopened
session ⇒ stage-1 resync within `turnLivenessResyncAfter`, settle within
`localTurnStaleTimeout`, queue untouched; live turn with frames ⇒ clock refreshes, neither
stage fires; cold-resume of a live turn ⇒ watchdog armed from the first projection
(arming-gap closed).

**I11 — Queue.** A queued prompt is durable at enqueue, drains in FIFO order per session,
submits exactly once (cmid dedup end-to-end), and only when (a) the relay drives the
destination session (affinity) and (b) the destination is idle per the authoritative server
signal (4009 busy), with render-side `isStreaming` treated as hint only. Flap-ambiguous
resubmit folds into one turn. Drift-abort feeds the queue (amendment S4): an
existing-session send whose pinned target drifted mid-pipeline becomes a durable row
against the PINNED id — it drains there exactly once, never to the session the user
switched to (a draft / nil-target drift instead drops the echo + closes the orphan — I5).
*Assert:* queue for A while viewing B ⇒ row holds; switch to A + idle ⇒ drains once; kill
mid-lease ⇒ relaunch does not double-send; double-drain attempt with same cmid ⇒ one
gateway turn; **existing-session drift ⇒ row enqueued to the pinned id and drains there
once; nil-target drift ⇒ echo dropped, orphan closed, nothing attributed to any session**
(S4 both-branches assertion).

**I12 — Gate cards per session.** Approval/clarify requests park on the owning session's
entry and are never dropped because the session is unfocused (dropping is unrecoverable —
desktop rationale). A card renders only on the owning session's surface — **a switch MOVES
the gate with the write-gate: the card leaves the screen with its session and re-appears on
switch-back; ONLY turn end (any reason) or an explicit answer expires it, exactly once
(amendment G1 — there is no expire-on-switch)**; an answer routes by explicit
`(session_id, request_id)` regardless of current screen; the resolved-id set suppresses
resync re-delivery. *Assert:* gate for A arrives while B active ⇒ card absent on B, present
on switch to A; **switch A→B→A with no intervening turn end or answer ⇒ card STILL present
(not expired by the switches)**; answer after switch ⇒ RPC targets A's sid + request_id;
resync replays the answered gate ⇒ no re-raise; turn.completed ⇒ card gone exactly once.

**I13 — One reconnect owner.** In relay mode the relay coordinator's auto-driver
(RSC:423-450) is the ONLY reconnect machinery: no gateway-direct reconnect loop, no gateway
liveness probe, no grace-window escalation over a relay turn, no second socket. Scene-phase,
foreground, and network-change signals nudge the coordinator (counter reset, immediate
attempt) and do nothing else. *Assert:* 20 background→foreground cycles mid-turn ⇒ zero
gateway connects, `activeRuntimeId` never nilled mid-turn, zero "Connection lost" banners,
one relay resync per genuine drop only.

**I14 — Reconcile budget.** Per session open: paint + ≤1 snapshot (`open`/`resume`); a
relay `history` read only on cold cache-miss or explicit scrollback page. Per turn end: ≤1
gap-fill refetch, and ONLY if the stream delivered no payload for the turn (desktop
`shouldHydrate`). Per reconnect: `resync{last_seq}` replay + ≤1 snapshot of the visible
session. Re-opening the already-active session costs zero RPCs. Superseded seeds cancel
their RPC. *Assert (RPC spy):* cold open ⇒ ≤2 transcript RPCs; warm switch ⇒ 0-1;
tap-active-session ⇒ 0; reconnect ⇒ resync + ≤1; turn end with payload ⇒ 0 gap-fills.

**I15 — taskList scoping.** The pill shows iff the active entry has a live turn AND a
non-terminal list owned by that session; terminal list, turn end, or switch dismisses; a
resync replay never re-raises a dismissed list past its turn; another session's list never
mirrors. *Assert:* A's taskList frames while B active ⇒ no pill; switch to A mid-turn ⇒ pill;
turn.completed ⇒ dismissed and stays dismissed under replay.

**I16 — Push / LA honesty.** Push for a session is suppressed iff the phone holds that
session foreground; foreground is cleared on background and re-asserted on foreground (a
turn completing seconds after background still pushes). LA starts once per turn (any owner),
ends exactly once on any settle edge, never double-ends, never runs past settle. A
notification tap resolves by stored id into A2; Inbox is the fallback only when the id is
unresolvable after one bounded refresh. *Assert:* background + turn complete ⇒ push fired;
foreground + turn complete ⇒ push suppressed, LA ended; double turn.completed ⇒ one LA end;
tap with valid stored id ⇒ that session opens, never Inbox.

**I17 — No error theater.** Transient states (flap, reconnect, relay-not-ready) never
surface a banner/alert over a retryable condition: the op queues on relay-ready (submit,
interrupt, steer, gate answers all get the `waitUntilOpen`-then-retry-once pattern) or
self-heals silently. Only terminal, non-retryable failures surface, sanitized (no raw codes;
QA-3 S5 / C3 rule). *Assert:* stop/steer/approve during R-FLAP ⇒ RPC retries once open, zero
banners, agent unblocked; session-not-found ⇒ one human-readable error, retry offered.

**I18 — Explicit wire targeting.** Every turn-control frame carries the explicit session id
it targets (plus `request_id` for gates): interrupt/steer target the turn's session
(including an adopted foreign mirror's runtime); approve/clarify target the gate's session,
not the on-screen session. No op relies on server-side "current session". *Assert:* answer
A's gate while viewing B ⇒ approve frame's `session_id == A`; interrupt a mirrored foreign
turn ⇒ interrupt frame targets the mirror's runtime id.

**I19 — Scrollback independence.** Backward paging is never gated on `isStreaming`; while
the reader is detached, streaming appends at the tail without offset movement; content or
skeleton above the window, never void. *Assert (RENDER-layer — UI-level e2e scroll or
snapshot test, not store-level replay; the void-geometry property is not observable in the
item stream — amendment A1):* mid-turn scroll-up with an exhausted in-memory window ⇒ older
page fetch issued, reader offset stable across 20 deltas, no void band ever rendered above
the reader.

**I20 — Kill/relaunch continuity.** App kill leaves the gateway turn running; cold open
paints durable echo + cache tail; the resume snapshot renders the turn live or settled
exactly once; a turn alive at relaunch never receives a false "Interrupted"; a turn dead at
relaunch settles via the watchdog from the snapshot baseline. *Assert (fixture):* kill
mid-turn, relaunch ⇒ echo row same id, snapshot folds with zero duplicates, no
"Interrupted" while frames flow.

**I21 — Idempotency.** Re-applying any frame sequence (resync replay, snapshot re-delivery,
gate re-delivery, dedup resubmit) converges to the byte-identical transcript and side-effect
set: union-by-`(sid,item_id)`, delta-append at-most-once via the seq ledger
(RIS `appliedDeltaSeqs` kept), gates once per `request_id`, drains once per cmid. *Assert:*
apply fixture F, then apply F+F ⇒ identical `messages`, identical gate state, zero extra
drains/LA ends.

**I22 — Honest capability surface.** Unimplemented primitives (replace/interrupt-with-message,
wire-level cancel of an accepted prompt) are never implied by the UI; unsupported kinds
(secure prompts on the relay wire) settle as expired with an inbox pointer, never as a dead
card. *Assert:* streaming+text menu offers only implemented actions; secure-prompt frame ⇒
card absent, inbox row present.

**I23 — Pending-gate recovery across restart (amendment G3).** A gate (approval/clarify)
left UNANSWERED at force-close re-raises on cold-open resume: gate re-delivery (resync ring
replay or snapshot) re-parks it on the owning session's entry and the card renders again,
answerable by the normal routing (I12/I18). Only a gate answered or turn-ended before the
kill stays down (durable relay-side resolution suppresses re-delivery; a turn-ended gate's
turn is settled in the snapshot). *Assert:* raise clarify on A, force-close without
answering, cold-open ⇒ card re-appears on A and the answer routes to A's `request_id`;
contrast: answer the gate before the kill ⇒ cold-open does NOT re-raise it.

---

## 5. What the desktop study bought into this contract (explicit provenance)

| Desktop lesson | Contract clause | Mobile anti-pattern it replaces |
|---|---|---|
| One socket, server-stamped `session_id`, client routes, unattributable dropped (§1) | I1, I2 | `ingest` folds any `sid` into one store (RSC:454-458), D3 leak family |
| Event stream = render authority; REST = seed + post-turn gap-fill only (§1, §2) | I3, I14 | REST-history poll as truth, stream paints tail only (RIS:5; applyRelayItems seam) |
| Per-session state map + write-gate; background sessions keep their own entry; no teardown on switch (§2, §3) | I2, I8, I14 | store reset on switch + projection suppression + switch-discard dance (RSC:740-757, 123-162) |
| Monotonic resume epoch, sync pin at intent, prefetch ∥ resume, clear-then-paint (§3) | I4, I2 | openToken fences results only; serialized seed→bind; overlay ordering (SS:4208-4211) |
| Submit: pin → drift-ABORT; resume-before-create; explicit id on wire; per-session lock; close orphan create (§4) | I5, I6 | `target = sessionID ?? activeSessionID` (RSC:654) — the exact inverse of the desktop rule |
| Interrupt = local settlement first + late-frame gate; steer-reject → queue; one-shot prompts parked per session (§5) | I9, I12, I17 | stop no-ops on flap + banner; gate cleared-and-forgotten on flap; dock cards per active view |
| One reconnect owner: capped backoff + escalation, wake nudges, lazy per-RPC reconnect-once, reconnect ⇒ re-resume (§6) | I13, I14, I17 | gateway-direct reconnect loop running in relay mode (ConnS:2608+, 3275-3284), dual reconnect policies |
| Hydrate-once-if-stream-empty; no blanket backfill (§2) | I14 | backfill storm: foreground + reconnect + broadcast_gap + foreign watchdog, no single-flight (D5) |
| Monotonic message ids; stream decode isolation (§6 id-stability commit) | I8, I21 | timestamp-built ids; echo removed-and-re-presented on outbox fallback (CS:2783-2816) |
| **Does not transfer (kept mobile-side):** offline durable cache (as seed), relay resync/replay as gap-free truth, explicit rebind RPCs (`open`/`resume`/`foreground`), per-turn watchdog stage-1 refetch (desktop's 8-min no-refetch watchdog is too weak for WAN) | I3, I10, I14 | — |
