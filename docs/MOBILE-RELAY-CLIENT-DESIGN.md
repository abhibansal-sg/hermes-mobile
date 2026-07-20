# Mobile Relay-Client — Zero-Core-Patch Architecture (Wave 2 direction)

**Owner decision (2026-07-18):** make the phone a first-class CLIENT of the stock
Hermes gateway via a persistent, co-located **relay-client** process. The full
mobile experience for the phone's own sessions — session list, foreign history,
live own-session streaming, and own-session notifications — is achievable with
**ZERO core/gateway patching**. The single capability that needs gateway code —
LIVE mirroring/notifications of a session the phone did NOT initiate ("co-watch")
— is explicitly PARKED and kept separate, so it never blocks the relay.

Verified read-only against `tui_gateway/server.py`, `hermes_state.py`,
`plugins/hermes-mobile/*`, `apps/shared`/`apps/desktop` (5-agent research pass).

## Why it works — the two free layers + one parked layer

The owner's observation ("desktop shows terminal + telegram sessions; a terminal
session appears in desktop, updated but not live") is exactly:

1. **Shared session store (FREE, no patch, no ownership).** Every origin
   (cli/tui, telegram + all gateway platforms, desktop, tool, mobile) persists to
   ONE SQLite store `~/.hermes/state.db` (`SessionDB`, `hermes_state.py:141,969`;
   `sessions.source` column `:752`). `session.list` reads
   `list_sessions_rich(source=None)` with **no ownership check and no source
   filter** (only the noisy internal `"tool"` source is hidden) —
   `tui_gateway/server.py:5736,5757-5761`. So any client sees every session.
2. **History on open (FREE, store re-read).** `session.history` (`:8297`) / REST
   `GET /api/sessions/{id}/messages` (`api_server.py:1978`) read
   `get_messages_as_conversation(...)` from the store. Refresh = re-read. No
   ownership, no broadcast.
3. **Live token stream of a FOREIGN session (PARKED — needs broadcast).**
   `write_json` routes each event frame ONLY to `session["transport"]`
   (`:1207-1219`); a foreign agent runs bound to its own owner's transport (often
   a different process), so its deltas never reach another client. This is the
   only thing requiring gateway code, and it's parked.

## The ownership trick that makes own-session streaming zero-patch

`prompt.submit` rebinds `session["transport"] = current_transport()`
(`:8926-8927`). Because `write_json` routes a session's events to its bound
transport, **whoever submits the prompt owns the live stream.** So when the relay
submits on the phone's behalf, the relay becomes owner and receives
`message.delta`/`message.complete`/`approval.request`/`clarify.request` directly
on its WS connection — no broadcast, no egress hook, no core change. One WS
connection multiplexes all the relay's sessions (events tagged `session_id`,
`:1224`), demuxed client-side — exactly the desktop's model.

## ZERO-PATCH pure-client ledger (proven)

| Capability | Mechanism | Evidence |
|---|---|---|
| Enumerate all sessions, every origin | `session.list` → `list_sessions_rich(source=None)` | `server.py:5736,5757` |
| Foreign metadata + source label | `sessions.source`; iOS glyph map | `:5765`; `DrawerSessionRow.swift:26-47` |
| Foreign full history on open/refresh | store re-read: REST `/messages` or `session.history` | `:8297`; `api_server.py:1978` |
| Own phone sessions, drive live turns | `prompt.submit` binds owner transport | `:8910,8926` |
| Own-session live stream (tokens/approvals) | `write_json` → owner transport, one WS demux | `:1207-1219,1224` |
| Own-session notifications (turn_complete/approval/error) | relay observes its OWN stream, reuses existing APNs plumbing | `push_engine.py:1360-1368`; own via prompt.submit |
| Interactive responses | `approval/clarify/sudo/secret.respond` | `:10775-10796` |
| Durable reconnect / re-read | desktop hook pattern (backoff + URL re-mint + re-resume) | `use-gateway-boot.ts:196-208` |
| Item-lifecycle reframe + seq/ack/replay | relay↔phone downstream protocol only | `replay_ring.py` (plugin-side) |

## PARKED — needs the broadcast/co-watch patch (separate track)

| Capability | Why | Evidence |
|---|---|---|
| Live co-watch of a session the phone didn't start | events route only to the owning transport; foreign agent in another process | `server.py:1207-1219` |
| Live notifications for foreign sessions (e.g. a terminal turn finishing) | same routing gap; pure client never receives them | `write_json` routing; `push_engine` in-proc hook only sees same-process sessions |

The parked track, when/if wanted, reuses the ALREADY-EXISTING broadcast fan-out
(`plugins/hermes-mobile/broadcast.py`, riding the already-stock `post_frame_write`
hook) — the relay would subscribe to it as an observer. So even co-watch needs no
NEW core change; it just needs that small existing fan-out plugin loaded. Kept
separate by owner decision.

## Three design caveats (all have zero-patch workarounds)

1. **`session.resume` is NOT a pure read** — non-lazy resume calls
   `_claim_active_session_slot` (rate-limit) + `db.reopen_session` which clears
   `ended_at`, REACTIVATING the session (`:6136-6148`). → Read foreign history via
   the store-read REST `/messages` / `session.history`; use `session.resume` only
   for sessions the relay intends to OWN.
2. **Driving a FOREIGN live session would contend** with its origin process
   (transport ping-pong). Out of scope — the phone drives its OWN turns.
3. **The relay must be CO-LOCATED on the gateway host** to keep the full REST
   feature set (transcript search, fs-browse, uploads, artifacts) — those bind to
   the host's `state.db`/disk. Deployment constraint, not a core patch (the plugin
   already runs co-located).

## Component shape

```
iOS app ──(Wave-2 item-lifecycle envelope + seq/ack/replay, over WS/HTTP + APNs)──► MOBILE RELAY
  ▲                                                                                  (co-located
  └──────────────── APNs (device tokens, direct HTTP2 / relay_client.py) ◄──────────  on host)
                                                                                        │ /api/ws?token=
                                                                                        ▼
                                                                          STOCK GATEWAY (unpatched)
                                                                          session.list/history/
                                                                          prompt.submit/approval.respond
                                                                          write_json → owner transport
                                                                                        │ shared
                                                                                        ▼
                                                                          state.db (all origins)
```

The relay KEEPS the existing host-local REST mount (uploads, attachments,
fs-browse, transcript search, artifacts, device/push/pair registries — they bind
to host state.db/disk) and ADDS a persistent `/api/ws` client for the live +
interactive surface. The Wave-2 item-lifecycle envelope + seq/ack/replay live in
the relay↔phone downstream protocol (`replay_ring.py` gets wired here).

## Build path (proposed)

- **R0 — Relay skeleton (no visible change):** stand up the relay process; open a
  durable `/api/ws?token=` client to the gateway (template:
  `apps/shared/src/json-rpc-gateway.ts` + `use-gateway-boot.ts` reconnect harness);
  prove it can `session.list`, `session.history`, `prompt.submit` (become owner),
  and receive the owner event stream.
- **R1 — Item-lifecycle reframer:** map the raw `message.*`/`tool.*`/`reasoning.*`
  stream into the item envelope (generic `name`-keyed tool item + special renders,
  per the full type catalog); wire `replay_ring.py` for seq/ack/replay on the
  relay↔phone socket.
- **R2 — iOS points at the relay:** the app connects to the relay instead of the
  gateway directly; drives its own sessions; reads any session's history; renders
  the item model (widen `ChatMessagePart`).
- **R3 — Notifications from the relay:** relay observes its owned sessions'
  completion/approval events and fires APNs (reuse `push_engine`/`relay_client`
  plumbing), phone-off included.
- **PARKED — co-watch:** subscribe the relay to the existing broadcast fan-out for
  live foreign-session mirroring + notifications. Separate track, owner-gated.

Net: the stock NousResearch gateway core stays byte-for-byte unpatched; all mobile
capability lives in the relay + iOS.
