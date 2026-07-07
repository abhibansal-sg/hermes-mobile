# RESUMABLE-STREAM-PROTOCOL — WS-2.3 seq/replay resumable stream

**Parent:** STR-969 SMOOTHNESS. **Workstream:** WS-2.3. **Milestone:** M2.
**Status:** SPEC (design-only). No code ships on the spec issue (STR-980).
Build is a separate epic, **blocked on a Board fence grant** for
`tui_gateway/server.py` (governor forbidden_path).

**Origin intent (Abhi, Board, 2026-07-07):** *"a running turn resumes
mid-sentence."* Today reconnect mid-turn throws away the stream and refetches
via REST once the turn completes — dead air until then. This protocol replaces
throw-away-and-refetch with a **resumable stream**: the server keeps a small
per-session replay buffer, every event carries a monotonic `seq`, and a
reconnecting client says "I last saw `seq=N`, give me `N+1…head` then continue
live." The one sanctioned refetch survives only as the cold fallback when the
client is further behind than the buffer holds.

This document defines the wire contract. It is deliberately implementation-shy
about internals except where an internal choice IS the contract (seq assignment
site, ordering guarantee, buffer floor semantics).

---

## 0. Grounding — the seams this protocol extends

Line references are to current `main` at spec time; they anchor intent, not a
frozen API.

| Seam | Location | Role in this protocol |
|---|---|---|
| `write_json(obj)` | `tui_gateway/server.py:1018` | **The single choke point.** Every event frame with a `session_id` passes here. This is where `seq` is assigned and where the frame is appended to the replay ring. |
| `_emit(event, sid, payload)` | `server.py:1047` | Thin wrapper that builds the `event` envelope and calls `write_json`. All owner-path events (`message.delta`, `tool.start`, `message.complete`, …) route through it. |
| `_EVENT_FANOUT_SUBSCRIBERS` → `on_owner_write` | `server.py:1015`, `plugins/hermes-mobile/broadcast.py:327` | Owner→mirror fan-out. Mirror frames must carry the **same** `seq` the owner frame got (see §1.4). |
| `enqueue` / `_drain_broadcast` | `broadcast.py:158,230` | Per-transport drop-oldest ring; already emits `broadcast_gap` (dropped-frame count) on the **mirror** path. §4 generalizes this into a seq-range gap the OWNER path also emits. |
| `_inflight_snapshot` / `inflight` | `server.py:4953`, attached at `_live_session_payload` `server.py:5864` | WU-B seed. §6 defines the `inflight`↔`resume_from` handoff so the two never double-apply. |
| `session.resume` handler | `server.py:5352` | Where `resume_from` arrives and where replay is driven before live re-attach. |
| iOS `SessionOpenResult` | `apps/ios/HermesMobile/Models/ProtocolTypes.swift:174` | Back-compat decode contract. New optional fields only; today's clients ignore them (§5). |

**Note on the existing `seq`:** `_child_mirrors[...]["seq"]` (server.py:3628) is
a *tool-id disambiguator* for submirror tool frames — unrelated to, and MUST NOT
be conflated with, the per-session wire `seq` defined here. The wire `seq` is a
new, separate counter.

---

## 1. Per-session monotonic `seq`

### 1.1 Definition
Every WS **event** frame emitted for a session (`method == "event"`, params has a
`session_id`) carries an integer `seq` in `params`:

```json
{"jsonrpc":"2.0","method":"event",
 "params":{"type":"message.delta","session_id":"a1b2c3d4","seq":417,"payload":{"text":"…"}}}
```

- `seq` is a **per-session** counter (not global, not per-transport). Two
  different sessions have independent seq spaces.
- `seq` is **strictly monotonic increasing by exactly 1** per emitted event for
  that session: the frame after `seq=N` is always `seq=N+1`. No gaps in the
  emitted sequence at the source; gaps only ever appear on a *lossy client path*
  (§4), never in what the server assigned.
- `seq` starts at **1** for the first event of a live session instance and is
  assigned in emit order.

### 1.2 Assignment site — the contract
`seq` is assigned **inside `write_json`, under the same serialization that already
guards owner writes**, at the moment the frame is committed to the owning
transport. This is the ONLY correct site because:
- It is the single funnel every session-scoped event already passes through.
- It already holds the write serialization (`_stdout_lock` / transport write
  lock), so seq assignment + append-to-ring + owner-write is one atomic step —
  no window where two threads interleave assignment order vs wire order.

Assignment is: take the session's `seq_head`, increment, stamp the frame, append
`(seq, frame)` to the ring, then write. The increment and the append happen under
the session's own lock so **wire order == seq order == ring order**, always.

Non-session frames (RPC responses, non-`event` methods) get **no** `seq` — they
are request/response correlated by `id`, not part of the replayable event stream.

### 1.3 Ownership: where `seq_head` lives
`seq_head` is per stored-session state, keyed by the same `session_key` the mirror
path already uses (`_session_lookup_key`), NOT by the ephemeral runtime `sid` and
NOT by transport. Rationale: a session that rotates transports (reconnect) or
rotates runtime id (compression-continuation chain, server.py:5409) must keep ONE
continuous seq space, or a client that resumes across a rotation cannot line up
its `resume_from`. Compression continuation is the sharp edge here — see §3.4.

### 1.4 Owner and mirror carry the SAME seq
The fan-out subscriber (`on_owner_write`) receives the frame **after** its seq is
stamped, so every mirror copy carries the identical `seq` as the owner frame.
A desktop (owner) and a phone (mirror) watching the same session therefore share
one seq axis; the phone's `resume_from` is meaningful against frames the desktop's
turn produced. This is mandatory — divergent owner/mirror seq would make
cross-client resume impossible.

### 1.5 Overflow / wraparound
`seq` is a 63-bit signed integer (JSON-safe; JS `Number.MAX_SAFE_INTEGER` is 2^53,
so the wire contract caps effective range at **2^53 − 1** and clients MUST treat
seq as fitting in a float64-safe integer — never assume 64-bit on the wire). At a
sustained, absurd 1000 events/sec a single session would take ~285,000 years to
reach 2^53. **Wraparound is therefore a non-event in practice and the protocol
does not define modular arithmetic.** The single defensive rule: if `seq_head`
ever approaches 2^53 (it won't), the server ENDS and forks the session
(compression-style continuation, resetting seq to 1 on the child) rather than
wrapping. A client seeing `seq` go *backwards* (child reset) is handled by the
same continuation-chain resolution as compression (§3.4): the resume binds to the
tip, whose seq space starts fresh, and the client seeds from the resume payload's
message list, not from stale seq.

---

## 2. Server replay ring buffer

### 2.1 Shape
Per live session, a bounded FIFO ring of the last **N** emitted event frames,
each stored as `(seq, frame_json)`. Reuses the existing bounded-deque discipline
from `broadcast.py::_BcastState.queue` (proven drop-oldest machinery) but is
**per-session** (owner truth), distinct from the existing **per-transport** mirror
backlog. The mirror backlog stays; this ring is the replay source of truth.

### 2.2 Sizing — N vs memory
- Default **N = 512 frames per session**. Justification: a normal streaming turn
  emits low-hundreds of delta frames; 512 comfortably covers a full turn plus a
  tool burst, i.e. a client that dropped for a few seconds mid-turn replays the
  whole gap. Frames are a few KB each → ~1–2 MB worst case per session.
- Override: config key `mobile.resume.ring_frames` (config.yaml, NOT an env var —
  AGENTS.md: non-secret settings live in config.yaml). Bridged to an internal
  value at load; no user-facing `HERMES_*` var.
- **Memory ceiling is bytes, not just frames.** Secondary cap
  `mobile.resume.ring_bytes` (default **4 MB/session**): the ring evicts oldest
  when EITHER frame-count > N OR total bytes > ceiling. A pathological session
  emitting huge frames (e.g. a giant tool result) cannot blow past the byte cap.
  This directly answers the adversarial "ring memory blowup at scale" finding
  (§7.1).
- **Aggregate cap across sessions:** `mobile.resume.ring_total_bytes` (default
  **128 MB** process-wide). When aggregate ring memory exceeds this, the OLDEST
  sessions' rings are dropped first (LRU by `last_active`) — those clients fall
  back to full refetch on resume, which is correct and safe. This bounds a
  many-idle-sessions fleet. See §7.1.

### 2.3 Eviction
Drop-oldest, same as the mirror backlog. When frame `seq=K` is evicted, the ring's
**floor** advances to `K+1` (the oldest seq still replayable). The floor is the
load-bearing value for the resume decision in §3.3.

### 2.4 Lifecycle
- Ring is created lazily on first emit for a session.
- Ring is dropped when the session goes fully idle/reaped
  (`_schedule_ws_orphan_reap`) — a session with no live transport for the reap
  window loses its ring; a later resume is a cold refetch. Acceptable: a client
  gone that long is doing a cold open anyway.
- Ring is NOT persisted to disk. It is a live-process replay convenience; the
  durable transcript is the DB (REST backfill remains the source of record). This
  keeps the ring off the fenced-DB path and makes it crash-safe by construction
  (a gateway restart = every client cold-refetches, exactly today's behavior).

---

## 3. `resume_from=seq` on `session.resume`

### 3.1 Client request
`session.resume` gains an OPTIONAL param `resume_from` (integer, the client's
last-seen `seq` for this session):

```json
{"jsonrpc":"2.0","id":42,"method":"session.resume",
 "params":{"session_id":"…","resume_from":417,"cols":80}}
```

- Absent `resume_from` → **today's behavior exactly** (full payload, no replay).
  This is the back-compat contract (§5).
- Present `resume_from` → the server attempts a replay-then-live attach.

### 3.2 Server response — the decision
On resume with `resume_from=R`, the server reads the session's ring floor `F` and
head `H`:

1. **`R >= H`** (client is current or somehow ahead): nothing to replay. Attach
   live. Response carries `replay: {from: R+1, to: R, count: 0}` and, if a turn is
   mid-flight, the `inflight` seed per §6.
2. **`F <= R+1 <= H`** (the gap is inside the ring): **replay `[R+1 … H]`** as
   ordered event frames, THEN attach live so `H+1…` streams naturally. Response
   carries `replay: {from: R+1, to: H, count: H-R}`. This is the happy path — a
   true mid-turn resume with zero dead air and zero refetch.
3. **`R+1 < F`** (client is older than the buffer floor — it missed frames the
   ring already evicted): **the ONE sanctioned full refetch.** Server returns the
   full `session.resume` payload as today (full `messages`, `inflight` if any) and
   signals `replay: {from: R+1, to: H, count: -1, fallback: "full"}` so the client
   KNOWS this was a fallback and must reset its transcript from `messages`, not
   splice deltas. See §3.5.

### 3.3 Replay delivery mechanism — exactly-once, ordered, no-gap
The replay frames for case (2) are delivered as **normal event frames on the
resuming transport, before the resume RPC's live attach completes**, in ascending
seq order, with their ORIGINAL `seq` values (not re-stamped). Contract:

- **Ordered:** ascending seq, contiguous `R+1, R+2, …, H`. The ring guarantees
  contiguity because assignment (§1.2) never gaps at the source; any missing seq
  inside `[F…H]` is impossible.
- **No-dup:** the live attach begins streaming at `H+1`. Because seq assignment
  and ring append are atomic under the session lock (§1.2), there is a defined
  cut: replay covers `≤H`, live covers `>H`, no frame is in both. The
  implementation MUST take the "current head" snapshot and begin buffering live
  frames under the SAME lock acquisition that reads `H`, so a frame emitted during
  replay setup is queued for live delivery, not lost and not duplicated. This is
  the single trickiest invariant; §7.2 covers the race.
- **No-gap:** client applies replay frames by seq; if it ever sees a jump
  (`seq` skips), that is a protocol violation and the client MUST fall back to
  full refetch (defensive; should never fire given §1.2).
- **Exactly-once at the client:** the client discards any replay/live frame whose
  `seq <= its last-applied seq` (idempotent apply keyed on seq). This makes the
  protocol robust to a benign overlap (server replays `R+1…H`, client had actually
  already applied up to `R+2` from a late in-flight frame) — the client simply
  drops the dup. **Client apply is seq-idempotent; that is the exactly-once
  guarantee, belt-and-suspenders over the server's no-dup cut.**

### 3.4 Interaction with compression-continuation
`session.resume` already resolves a rotated-out parent id to the live tip
(server.py:5409, `resolve_resume_session_id`). Because seq is keyed on
`session_key` and a continuation fork starts a **fresh seq space on the child**
(§1.5), a client resuming an old id with a stale `resume_from` that belongs to the
PARENT's seq space would mis-align against the CHILD's ring. Contract: when resume
resolves `target` to a different tip than the client asked for (rotation
happened), the server **ignores `resume_from` and returns the full-refetch
fallback** (case 3 shape), because the client's seq is from a dead seq space.
The client detects `resumed != requested_session_id` (already surfaced today) OR
the explicit `fallback: "full"` and resets. Simple, correct, rare.

### 3.5 Full-refetch fallback is first-class, not an error
Case (3) and §3.4 are NORMAL outcomes, not failures. No error surface, no banner
(consistent with WS-1 silent-reconnect doctrine). The client seeds from
`messages` exactly as a cold open does. The ONLY user-visible difference between a
replay resume and a fallback resume is that fallback repaints from the transcript
(one frame) instead of animating deltas — invisible for a completed turn, and for
a mid-flight turn the `inflight` seed (§6) still gives the half-written bubble.

---

## 4. Generalize `broadcast_gap` to the owner path

### 4.1 Today (mirror only)
`broadcast.py` drops oldest under per-transport backpressure and stamps the next
delivered frame with `broadcast_gap: <dropped_count>` (server.py:252) so a slow
mirror client knows it missed frames and can REST-backfill. This exists ONLY on
the mirror fan-out path; the owner path has no gap signal because the owner write
is not queue-bounded the same way.

### 4.2 The generalization — a seq-range gap marker
Replace/augment the count-only `broadcast_gap` with a **seq-range gap marker** that
BOTH paths speak:

```json
"gap": {"missed_from": 401, "missed_to": 416}
```

- **Owner path:** the owner write is not lossy under normal operation, so the
  owner emits `gap` only in one case — after a REPLAY that hit the fallback (§3.3
  case 3), the first live frame carries a `gap` marker spanning the un-replayable
  range, telling a splice-mode client "you have a hole here, you already
  refetched, resume clean from here."
- **Mirror path:** when the per-transport ring drops frames, instead of a bare
  count it now stamps `gap: {missed_from, missed_to}` derived from the seq of the
  last-delivered frame and the seq of the next-delivered frame (both now carry
  seq per §1). The client sees the exact missing range and can request replay via
  a follow-up `session.resume` with `resume_from = last_good_seq` — turning a
  mirror-drop into a targeted replay instead of a full REST backfill.
- **Back-compat:** `broadcast_gap` (the old integer) is retained as a mirrored
  field alongside `gap` for one wire version so an un-updated client still detects
  "something dropped" (it just can't do the targeted replay). New clients prefer
  `gap`; ignore `broadcast_gap` when `gap` present.

### 4.3 Contract
`gap` on any frame means: "between your last-applied seq and this frame's seq,
seq values `[missed_from … missed_to]` were NOT and will NOT be delivered on this
path; reconcile." The reconcile action is client choice: targeted replay
(`resume_from`) if the range is likely still in the server ring, or REST backfill
if not. The presence of `gap` NEVER escalates to a visible error (WS-1 doctrine).

---

## 5. Back-compat & wire-version negotiation

### 5.1 The floor: additive, optional, ignorable
Every new field is OPTIONAL and ADDITIVE:
- `seq` on event frames — old clients ignore an unknown key.
- `resume_from` on `session.resume` — old clients never send it → server serves
  today's full payload (§3.1).
- `replay` block on the resume response — old clients ignore it (iOS
  `SessionOpenResult` decodes named keys only; unknown keys are dropped, confirmed
  at ProtocolTypes.swift:191 custom `init(from:)`).
- `gap` marker — old clients ignore it and keep using `broadcast_gap` (§4.2).

A client that does nothing new keeps working byte-for-byte as today. This is the
hard requirement.

### 5.2 Negotiation — capability handshake
There is one existing capability surface (server.py:12467 `capabilities=True`).
Extend it, do NOT invent a parallel version scheme:

- Client advertises support in `session.resume` (and `session.create`) via
  `client_caps: {"resumable_stream": 1}`.
- Server advertises in the resume/create response `server_caps:
  {"resumable_stream": 1}`.
- **Feature is active for a session only when BOTH sides advertise ≥1.** If the
  server is new but the client is old (no `client_caps`), the server still ASSIGNS
  seq (harmless, ignored) but does NOT expect `resume_from` and behaves as today.
  If the client is new but the server is old (no `server_caps.resumable_stream`),
  the client MUST NOT send `resume_from` (it would be an unknown param — benign,
  but the client also can't rely on replay, so it uses REST backfill). The
  version integer allows a future v2 without breaking v1.

### 5.3 Skew matrix
| Server | Client | Behavior |
|---|---|---|
| old | old | today's behavior, unchanged |
| new | old | server stamps seq (ignored); no replay; full payload — unchanged UX |
| old | new | client detects no `server_caps`; never sends `resume_from`; REST backfill |
| new | new | full protocol: seq + replay + targeted gap reconcile |

No skew combination errors, flashes, or loses data. §7.5 (adversarial) stresses
skew under mid-turn rotation.

---

## 6. Interaction with WU-B (inflight decode)

### 6.1 The two mechanisms
- **`inflight`** (WU-B, WS-2.1, shipping in M0): a *snapshot* of the current
  half-written turn (`{user, assistant, streaming}`) returned on the resume
  payload so the bubble paints instantly.
- **`resume_from`** (this spec): the *delta stream* continuation from a seq point.

Both can be present on one resume. Without a handoff rule they double-apply: the
`inflight.assistant` snapshot already contains text that the replayed
`message.delta` frames would append AGAIN → duplicated tokens.

### 6.2 The handoff contract
The resume response carries BOTH `inflight` and `replay` when a turn is mid-flight
and the client sent `resume_from`. The rule:

- **`inflight` seeds the bubble content (the visual baseline).**
- **`replay` frames are applied ONLY for `seq > inflight_seq`.** The server stamps
  the inflight snapshot with the `seq` of the last delta already folded into it:
  `inflight: {user, assistant, streaming, seq: 412}`. The client seeds the bubble
  from `inflight.assistant`, sets its last-applied seq to `inflight.seq`, then the
  exactly-once rule (§3.3) NATURALLY drops any replay frame with `seq <= 412` and
  applies only `413…H`. **The inflight seq IS the dedup boundary** — no separate
  handoff logic needed; it falls out of seq-idempotent apply.
- If the client did NOT send `resume_from` (old client, or first attach), it uses
  `inflight` alone (WU-B behavior) — unchanged.
- If a turn is NOT mid-flight, `inflight` is absent and `replay` alone governs.

### 6.3 Consequence
WU-B and WS-2.3 compose without special-casing: `inflight.seq` is the single
number that stitches the snapshot to the delta stream. This requires WU-B's
`_inflight_snapshot` (server.py:4953) to additionally record the seq of the last
delta it reflects — a one-field addition, specified here so the M0 WU-B work lands
`inflight.seq` even before the replay epic builds (forward-compatible seed).

---

## 7. Adversarial pass (CRUCIBLE) — findings absorbed or rebutted

Per role-refiner doctrine, this p1/p2-class spec on a fenced surface took one
cross-provider adversarial pass instructed to attack. Findings and disposition:

### 7.1 "Ring-buffer memory blowup at scale" — ABSORBED
*Attack:* N frames/session × many sessions × large frames = unbounded process
memory; a single giant tool-result frame defeats a frame-count cap.
*Disposition:* §2.2 now caps THREE ways — per-session frame count (N=512),
per-session bytes (4 MB), and process-aggregate bytes (128 MB, LRU-drop oldest
sessions' rings). A blown cap degrades to full-refetch fallback, which is safe.
The frame-count-only design the attack targeted is explicitly rejected.

### 7.2 "Seq assignment race under concurrent owner+mirror writers" — REBUTTED (by design)
*Attack:* the owner thread and the mirror fan-out could stamp/append out of order,
producing wire order ≠ seq order.
*Disposition:* §1.2 assigns seq and appends to the ring INSIDE `write_json` under
the existing owner-write serialization, and §1.4 has the mirror carry the
owner-assigned seq (fan-out runs AFTER the stamp, server.py:1037). The mirror
never assigns seq; there is exactly one writer of `seq_head` per session, under
one lock. The race cannot occur. The subtler race — a live frame emitted DURING
replay setup — is handled in §3.3 by snapshotting `H` and starting the live buffer
under the same lock acquisition. Called out as the one invariant reviewers must
verify in the build epic's tests.

### 7.3 "Replay storms on flap" — ABSORBED
*Attack:* a phone flapping on/off cellular reconnects 10×/10s; each resume replays
`[R+1…H]`; a mid-turn burst means 10 replays of hundreds of frames = amplification.
*Disposition:* three mitigations added — (a) replay is bounded by the ring (≤N
frames ever, so ≤512 frames/replay, not "the whole turn from the start"); (b) the
client advances `resume_from` to the last seq it applied on EACH reconnect, so
successive flaps replay only the NEW gap, not the whole window again (monotonic
progress); (c) a server-side per-session **replay-rate guard**: if a session
serves > `mobile.resume.max_replays_per_min` (default 12) it drops that client to
full-refetch fallback for a cooldown, breaking the storm. Matches the existing
soak-suite `ws_flap` chaos pattern the spec mandates as an XCUITest.

### 7.4 "Older-than-buffer fallback correctness" — REBUTTED + hardened
*Attack:* when `R+1 < F` the client splices deltas onto a stale transcript and
corrupts state.
*Disposition:* §3.2 case 3 + §3.5 make fallback return the FULL payload and
signal `fallback: "full"`, and §3.3's exactly-once + §4's `gap` marker mean a
splice-mode client that ignored the fallback flag would STILL self-heal (it sees a
seq jump / gap and resets). Two independent guards. The attack assumed silent
splice; the protocol forbids it two ways.

### 7.5 "Wire-version skew under mid-turn rotation" — ABSORBED
*Attack:* server compresses/rotates a session mid-turn while a new client resumes
with a parent-space `resume_from`; seq spaces diverge silently.
*Disposition:* §3.4 makes rotation force the full-refetch fallback (parent seq
space is dead), and §1.3 keys seq on `session_key` so a transport-only reconnect
(no rotation) keeps one seq space. §5.3's skew matrix confirms no skew combo
errors. The one genuine hole the attack found — parent/child seq confusion — is
closed by "rotation ⇒ ignore resume_from ⇒ fallback."

### 7.6 "Persisted-ring crash inconsistency" — REBUTTED (non-issue by construction)
*Attack:* if the ring were persisted, a crash mid-write leaves a torn ring.
*Disposition:* §2.4 makes the ring IN-MEMORY ONLY; a gateway restart drops all
rings and every client cold-refetches — today's exact behavior. The ring never
touches the fenced DB path, sidestepping both the crash-consistency AND the
fence-surface concern. This is also why the ring is safe to build even before the
DB-adjacent fenced work.

**One pass complete.** The formal cross-provider crucible child issue (below)
carries this doc as its attack target; any finding it surfaces beyond the six
above is absorbed in a follow-up revision before the build epic is unblocked.

---

## 8. Acceptance mapping (spec issue STR-980)

| Deliverable | Section |
|---|---|
| Per-session monotonic seq (owner + mirror), assignment site, ordering, overflow | §1 |
| Replay ring: sizing (N vs memory), eviction, older-than-floor → full refetch | §2, §3.2(3) |
| `resume_from=seq`: replay `[seq+1…head]` then live; exactly-once/no-gap/no-dup | §3 |
| Generalize `broadcast_gap` to the owner path (seq-range gap marker) | §4 |
| Back-compat + wire-version negotiation | §5 |
| WU-B (`inflight`) × `resume_from` handoff (no double-apply) | §6 |
| Adversarial/crucible findings absorbed or rebutted in-doc | §7 |

---

## 9. Build epic gating

This spec does NOT authorize code. The build epic
(**"WS-2.3 build: resumable stream — seq/ring/replay"**, child of STR-980) is
**BLOCKED on a Board fence grant** for `tui_gateway/server.py` (governor
forbidden_path — a build seat editing it auto-REJECTs at verify without the
grant). It is routed into the WS-2.2/2.3 fence-grant batch (see the
fence-escalation issue) so Abhi grants one fence for the streaming-surface cluster
rather than tap-by-tap. `plugins/hermes-mobile/**` and `apps/ios/**` portions
(the ring buffer lives naturally in the mobile plugin per §2.1; iOS decode is
unfenced) are dispatchable independently once the server-side `write_json` seq
hook — the only genuinely fenced change — is granted.

## 10. Out of scope
Any code. N×M fan-out scoping (spec non-goal, premature at current scale).
CloudKit transport (spec non-goal — sessions live on the gateway). Persisting the
replay ring to disk (§2.4 — deliberately in-memory). Relay-mode transport
(ABH-338 owns it).
