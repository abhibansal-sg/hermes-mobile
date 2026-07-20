# Relay ↔ Phone Protocol — v1 RATIFIED contract (Wave 2 linchpin)

**Status:** RATIFIED 2026-07-18 — the R0 spike proved all four gateway-side
claims against a STOCK gateway (list foreign sessions, store-read foreign history,
own-session live stream, continue an idle foreign session with history intact).
One correction applied from R0 (see §5). This is the frozen interface both build
tracks parallelize against:
the relay reframes the gateway stream INTO this; iOS decodes/renders FROM this.
Once ratified, relay-lane and iOS-lane agents build independently against it.

Design roots: the item-lifecycle model (Codex-verified), the full Hermes event/
tool catalog (every tool streams via `tool.start`/`tool.complete` with `name` as
the only discriminator → one generic tool item), and `replay_ring.py`.

---

## 1. Transport + envelope

Relay serves the phone over WS (with an HTTP fallback for cold reads). Every
downstream frame from relay → phone is:

```json
{ "seq": 1421, "sid": "<session_id>", "turn": "<turn_id>", "kind": "<frame_kind>", "body": { ... } }
```

- `seq` — monotonic per phone-connection (NOT per session). The reliability spine.
- `sid` / `turn` — session + turn the frame belongs to (phone demuxes by these).
- `kind` — one of the frame kinds in §3.
- `body` — kind-specific payload.

Upstream phone → relay frames are ordinary JSON-RPC-2.0 requests (the relay
translates to gateway RPCs): `submit`, `resume`, `open`, `list`, `history`,
`approve`, `clarify`, `interrupt`, `ack`, `resync`.

## 2. The item model (what the phone renders)

A turn is an ordered list of **items**, each with a stable `item_id` and a
lifecycle `started → delta* → completed` where **`completed` is authoritative**
(replaces whatever deltas accumulated). Item shape:

```json
{ "item_id": "...", "type": "<item_type>", "status": "in_progress|completed|failed",
  "ord": 7, "summary": "<one-line>", "body": { ... type-specific ... } }
```

**Item types** — the generic backbone + special renders (drive off `type`, which
the relay assigns from the raw event / tool `name`):

| type | source | render note |
|---|---|---|
| `userMessage` | the submitted prompt | right-aligned bubble |
| `agentMessage` | `message.delta`/`complete` | markdown text, streams |
| `reasoning` | `reasoning.delta`/`available` | collapsible "thinking" |
| `toolCall` (GENERIC) | ANY `tool.start`/`tool.complete`, keyed by `name` | collapsed tool card: name + status + summary; body = args/result/duration; covers ALL current + future tools |
| `fileChange` | `tool.complete.inline_diff` present | diff render |
| `image` | `image_generate` result / attachment / md image | inline image (shipped on iOS — STR-695: AsyncImage + retry + lightbox) |
| `browser` | `browser_*` name family | screenshot/snapshot render |
| `error` | `error` event / failed tool | error item, never hidden in a collapse |
| `usage` | `message.complete.usage` | turn footer |

Non-item turn signals delivered as frame kinds (not ordered items):
`approval.request`, `clarify.request`, `status`, `title`.

Rule: a client that receives an unknown `type` renders it as a generic `toolCall`
card (forward-compatible; new Hermes tools never break the phone).

## 3. Frame kinds (relay → phone)

- `item.started` — `body` = the item skeleton (item_id, type, ord, status=in_progress).
- `item.delta` — `body` = `{ item_id, patch }` (append text / partial fields).
- `item.completed` — `body` = the FULL authoritative item (status completed/failed).
- `turn.started` / `turn.completed` — turn boundaries (`turn.completed` carries `usage`).
- `approval.request` / `clarify.request` — interactive gates (phone replies via RPC).
- `status` — `{ kind, text }` (lifecycle/compacting/etc., non-item chatter).
- `title` — session title changed.
- `snapshot` — reply to `resync`/`open`: `{ items:[...full items...], cursor }` — the
  resume-as-items payload (relay-built from its accumulated state).

## 4. Seq / ack / replay (reliability spine — lives entirely in the relay)

- Relay stamps every downstream frame with a monotonic `seq` and appends it to a
  bounded per-connection ring (`replay_ring.py`).
- Phone periodically sends `ack{through: <seq>}`; relay drops acked frames from the ring.
- On reconnect the phone sends `resync{last_seq: <n>}`:
  - if `n` is still within the ring → relay replays frames `n+1..head` (gap-free).
  - if `n` is below the ring floor (gap too big) → relay sends a fresh `snapshot`
    (full current items) + resumes live. The phone reconciles by item_id.
- `completed`-is-authoritative means even a dropped delta is harmless: the phone
  paints optimistically and self-heals on `item.completed` / `snapshot`.

## 5. Session operations (phone → relay → gateway mapping)

| phone intent | relay action | gateway RPC | ownership effect |
|---|---|---|---|
| list all sessions | pass-through | `session.list` | none (read) |
| open/read a session (incl. foreign) | store-read | **REST `GET /api/sessions/{id}/messages` ONLY** (`web_server.py:9985`, reads `state.db`) | none (NO reactivation) — R0 CORRECTION: `session.history` RPC is NOT a store-read; it resolves via `_sess_nowait` (in-memory live sessions only, `server.py:1727`) and returns 4001 for a foreign session the phone never owned. Use the REST path for foreign/idle history. |
| start a NEW chat | create + own | `session.create` → `prompt.submit` | relay becomes owner |
| send into an idle session (incl. a terminal one) | resume + own + submit | `session.resume` → `prompt.submit` | relay becomes owner; turn continues same sid/history/cwd |
| answer approval/clarify | pass-through | `approval.respond` / `clarify.respond` | — |
| stop | pass-through | `session.interrupt` | — |

Live streaming to the phone works for any session the relay OWNS (i.e. after
submit/resume-to-drive). Live mirroring of a session actively driven by ANOTHER
client = PARKED (needs broadcast; see `MOBILE-RELAY-CLIENT-DESIGN.md`).

## 6. Notifications (relay-fired, phone-off)

Relay observes `item.completed`(agentMessage) / `approval.request` / `error` for
its OWNED sessions → fires APNs via the existing plumbing (device tokens +
`relay_client.py`/direct HTTP2), gated to skip when a live phone WS holds the
session foregrounded. No gateway code. Foreign-session notifications = PARKED.

## 7. What the two build tracks own (against THIS contract)

- **Relay track:** gateway WS client (§5), raw→item reframer (§2/§3 mapping),
  seq/ack/replay ring (§4), notification observer (§6). Testable against recorded
  gateway streams with zero iOS dependency.
- **iOS track:** decode frames (§1/§3), widen `ChatMessagePart` to the item model
  (§2), generic tool card + special renders, seq/ack client + `resync` (§4), point
  the app at the relay. Testable against a mock relay emitting this contract with
  zero relay-internals dependency.

Ratification checklist (post-R0): confirm the raw event field names the mapping
in §2/§5 assumes (`message.delta.text`, `tool.complete.{name,args,result,
duration_s,inline_diff}`, `reasoning.*`, `message.complete.usage`) match what R0
actually observed on the wire. Adjust the mapping only; the envelope/lifecycle/
seq-ack design is R0-independent.
