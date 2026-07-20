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
`approve`, `clarify`, `interrupt`, `steer`, `ack`, `resync`, `foreground`,
`push.register`, `push.unregister`.

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
| `taskList` | the `todo` tool (`tool.start`/`tool.complete` with `name=="todo"`) | the agent's structured task list — ONE living card on a stable id (`<sid>:tasks`); body = `{ tasks:[{id,text,status}], counts:{total,pending,in_progress,completed,cancelled}, all_complete }`; status enum `pending`/`in_progress`/`completed`/`cancelled` |
| `fileChange` | `tool.complete.inline_diff` present | diff render |
| `image` | `image_generate` result / attachment / md image | inline image (shipped on iOS — STR-695: AsyncImage + retry + lightbox) |
| `browser` | `browser_*` name family | screenshot/snapshot render |
| `error` | `error` event / failed tool | error item, never hidden in a collapse |
| `usage` | `message.complete.usage` | turn footer |

Non-item turn signals delivered as frame kinds (not ordered items):
`approval.request`, `clarify.request`, `status`, `title`.

Rule: a client that receives an unknown `type` renders it as a generic `toolCall`
card (forward-compatible; new Hermes tools never break the phone).

**Task list (`taskList`) semantics.** The `todo` tool is the ONE tool the relay
does not collapse into a generic `toolCall`: it carries the agent's task list,
which is a persistent artifact rather than a one-shot call. The relay gives it a
stable per-session `item_id` (`<sid>:tasks`) and drives it through the normal
item lifecycle so a client renders a single card that updates in place:
- first sighting → `item.started` (the snapshot),
- each later update while work remains → `item.delta` whose `patch` carries the
  **full authoritative task list** (`{ tasks, counts, all_complete }`) — a
  REPLACE of `body.tasks`, not an append,
- every task `completed`/`cancelled` → `item.completed` (authoritative, and the
  task-list-complete notification trigger, §6).

`completed`-is-authoritative applies as everywhere else: the gateway lifts the
full list onto `tool.complete` (top-level `todos`); a `tool.start` may only carry
a partial merge preview and is never treated as authoritative.

## 3. Frame kinds (relay → phone)

- `item.started` — `body` = the item skeleton (item_id, type, ord, status=in_progress).
- `item.delta` — `body` = `{ item_id, patch }` (append text / partial fields). For a
  `taskList` item the `patch` is a full-list REPLACE (`{ tasks, counts, all_complete }`),
  not an append — the phone repaints `body.tasks` from it.
- `item.completed` — `body` = the FULL authoritative item (status completed/failed).
  For a `taskList` this frame is emitted ONLY when every task is done/cancelled.
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
| answer approval | translate params | `approval.respond` | — — the gateway reads `choice` (`once`/`session`/`always`/`deny`, mapping `approve`→`once`) + `all` and resolves by SESSION key; the relay maps the phone's `decision`→`choice` (a relay that sent `decision` defaulted every approval to DENY) |
| answer clarify | translate params | `clarify.respond` | — — the gateway matches the pending waiter by `request_id` and stores `params.answer`; the relay maps the phone's `text`→`answer` (a relay that sent `text` delivered an EMPTY answer) |
| stop | pass-through | `session.interrupt` | — |
| steer the live turn (QA-2 R11) | pass-through | `session.steer` | none — the gateway injects `text` into the running turn's next context window (no new turn, no interrupt) and returns `{status: queued\|rejected, text}`; the relay passes the disposition through VERBATIM so the phone maps it identically to the gateway-direct path (`queued` → clear the field; `rejected` → keep the text and offer queueing). Params: `session_id` required, `text` required (empty `text` → gateway 4002). Before this method existed the phone's steer went over the IDLE gateway-direct socket in relay mode and every attempt failed "Not connected". |
| attach a photo / file (B9/A5) | translate params | `file.attach` (`kind=file`) or `image.attach_bytes` (`kind=image`) | same drive semantics as SUBMIT: `session_id` absent → `session.create` (+own); foreign/idle → `session.resume` (adopt the live id); the resolved `session_id` is merged into the result. REST-FREE by construction: the phone inlines the bytes as a `data:<mime>;base64,` URL in `data_url` — NO `POST /api/upload`, which a relay-only phone cannot reach. Params: `kind` + `data_url` required, `session_id` / `name` optional. |
| register APNs device token | LOCAL (§6a) | none — relay writes its OWN push registry | notifier becomes able to reach this phone |
| unregister APNs device token | LOCAL (§6a) | none | phone stops receiving pushes |

Live streaming to the phone works for any session the relay OWNS (i.e. after
submit/resume-to-drive). Live mirroring of a session actively driven by ANOTHER
client = PARKED (needs broadcast; see `MOBILE-RELAY-CLIENT-DESIGN.md`).

### 5a. SUBMIT idempotency — `client_message_id` (A3)

A queued send must never drive two turns even when the RPC result is lost to a
socket flap (the phone marks the outbox row `transport_ambiguous` and resubmits
the SAME job on a fresh connection). The contract is a single field:

- **Field:** `client_message_id` (string, optional) on the `submit` RPC `params`.
- **Origin:** minted ONCE when the durable outbox row is created (the row's stable
  job id; persisted in the `work_jobs.client_message_id` NOT-NULL column) and
  NEVER regenerated — the same id is replayed on every retry of that row.
  Interactive/legacy sends that do not allocate an outbox row simply OMIT the
  field. The iOS submit path threads `job.clientMessageID` on both the relay
  branch (`RelayClient.submit(clientMessageID:)` → params.`client_message_id`)
  and the gateway-direct branch (`prompt.submit` params.`client_message_id`).
- **Relay handling (`downstream.handle_upstream`, SUBMIT):**
  1. Read `cmid = params.get("client_message_id")`.
  2. If `cmid` is present AND already in the server-scoped bounded LRU
     (`_submit_dedup`, cap 1024) → the prior submit already ran `prompt_submit`;
     replay the resolved live `session_id` WITHOUT driving a second turn and
     return `{"session_id": <live>, "deduplicated": true}`. The phone's outbox
     treats a `deduplicated` receipt with a matching `client_message_id` as
     accepted and transitions the row to `completed` (no second row is created).
  3. Otherwise run the normal submit path (create/resume + `prompt_submit`) and,
     BEFORE returning, record `_remember_submit(cmid, resolved_live_sid)` so a
     retry that races the RPC result back over a flapped socket is deduped.
  4. Absent the field → the dedup check and the remember are both skipped
     (legacy/interactive sends must NOT be silently swallowed); behavior is
     exactly the pre-idempotency path.
- **Scope + bound:** the dedup map lives on the `DownstreamServer` (it outlives
  any single phone connection, so a retry on a FRESH socket after reconnect is
  still recognized). It is a bounded LRU — when full, the oldest entry is
  evicted, so the table can never grow without limit. A retry whose id was
  evicted simply drives a fresh turn (correctness is preserved by `completed`-
  is-authoritative; only the duplicate-suppression window is bounded).
- **Persistence note:** the dedup map is IN-MEMORY and lives for the relay
  process lifetime. A relay *restart* (not a phone reconnect) loses it; the
  outbox still drains correctly because the gateway is the system of record
  (`completed`-is-authoritative), at the cost of a possible duplicate turn on a
  restart-mid-ambiguous-flap — an explicit non-goal bounded by A6's gap-free
  resync guarantee for the transcript.

### 5b. Turn control over the relay — interrupt / steer / queue (QA-2 R11)

A relay-mode phone MUST drive all three turn-control actions over the relay
socket; the gateway-direct socket is IDLE in relay mode, so any control RPC
sent over it fails with "Not connected to the Hermes gateway" (the build-115
bug: stop and steer errored; queue-mode sends vanished).

- **interrupt** (`interrupt`): pass-through → `session.interrupt`. Targets the
  session the phone is driving (`session_id` required on the wire; the iOS
  coordinator defaults it to the driven session). The relay holds ownership, so
  the interrupt always lands on the relay-owned runtime.
- **steer** (`steer`): pass-through → `session.steer` (see the §5 table row).
  Disposition pass-through is load-bearing: a `rejected` status tells the phone
  to keep the user's text and offer queueing — the steer→queue fallback chain.
- **queue**: there is deliberately NO `queue` upstream method. Queueing is the
  phone's durable outbox (the protected `work_jobs` repository), NOT a relay
  concept: a send that must wait (live turn in the destination session, or a
  failed/ambiguous submit) is written to the outbox — surfacing the outbox pill
  immediately and durably — and DRAINS as an ordinary §5 `submit` (carrying the
  §5a `client_message_id`, so an ambiguous-flap retry dedupes into one turn).
  The phone holds a queued row while its destination session is mid-turn
  (per-session serialization) and wakes the drain on turn completion; the relay
  needs no queue state of its own. Removing a queued row writes a durable
  tombstone (row delete or `.cancelled` state) SYNCHRONOUSLY before the UI
  confirms the removal, so a force-quit in the removal window can never
  resurrect the send on the relaunch drain (the claim query admits only
  live states — a tombstoned row is never claimed).

## 6. Notifications (relay-fired, phone-off)

Relay observes these signals for its OWNED sessions → fires APNs via the existing
plumbing (device tokens + `relay_client.py`/direct HTTP2). No gateway code.
Foreign-session notifications = PARKED.

| signal | push kind | foreground gate |
|---|---|---|
| `item.completed`(agentMessage) | `turn_complete` | gated (skip when watched) |
| `item.completed`(error) | `turn_error` | gated |
| `item.completed`(taskList) — all tasks done | `task_complete` | gated |
| `approval.request` | `approval` | BYPASS (blocking gate) |
| `clarify.request` | `clarify` | BYPASS (blocking gate) |

Blocking gates (`approval`/`clarify`) bypass the foreground gate — the turn is
stalled on the user, so they always ring; completions/errors are skipped when a
live phone WS holds the session foregrounded. Each `clarify` request rings once
(keyed by `request_id`); `task_complete` collapses per turn.

### 6a. Device-token registration over the relay (QA-1 B14)

In relay mode the phone registers its APNs device token **through the relay
socket**, not gateway-direct REST: the relay's Notifier reads the relay
process's own push registry, and an off-LAN relay-only phone cannot reach the
gateway REST at all (and when it can, the gateway's registry is a DIFFERENT
`HERMES_HOME` than the relay reads). Registering over the transport the push is
fired from is the only wiring that is correct by construction.

- **`push.register`** — phone → relay JSON-RPC, LOCAL (never hits the gateway,
  handled before the gateway-readiness gate like `ack`/`resync`/`foreground`).
  `params`: `{token (hex string, required), platform ("ios"), env
  ("sandbox"|"production"), events? (subset of approval/clarify/turn_complete/
  turn_error/background_done; absent = all), device_id?}`. The relay validates
  and writes the shared `push_engine` registry (`<HERMES_HOME>/push_tokens.json`,
  the exact registry `push_engine.notify` reads) and returns
  `{"registered": true}`; a malformed token yields a JSON-RPC error
  (`invalid device token`). Re-registering refreshes env/events (Settings
  toggles re-POST, same semantics as the gateway REST route). `device_id`
  (QA-2 R1c) is the phone's stable per-install identity: the registry keeps
  ONE entry per device — a re-register with a rotated token REPLACES the
  device's old entry; phones SHOULD send it on every register.
- **`push.unregister`** — `params`: `{token}`; returns `{"unregistered": bool}`.
- **Phone duty (foreground hygiene, §6 gate):** the phone sends
  `foreground {session_id: null}` when it leaves the foreground
  (background/inactive scene phase) so a turn completing seconds after
  backgrounding pushes instead of being gated by a WS iOS has not killed yet;
  on reconnect / return to foreground it re-asserts the active session.
- **Relay service duty:** the supervised launchd service carries the APNs sender
  env in the plist (`HERMES_PUSH_ENABLED`, `HERMES_APNS_KEY_FILE`, `HERMES_APNS_
  KEY_ID`, `HERMES_APNS_TEAM_ID`, optional `_TOPIC`/`_USE_SANDBOX`) rendered by
  `install-service.sh` from `<HERMES_HOME>/apns.env`, plus `HERMES_HOME`
  matching the gateway's. Without those the Notifier is a documented no-op —
  the mock-APNs E2E exercises the DECISION logic; the live send additionally
  requires these creds (owner-provided `.p8` + Key/Team IDs).

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
