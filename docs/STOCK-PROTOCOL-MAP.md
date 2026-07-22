# Stock protocol map for the Hermes Mobile v0.19 path

**Phase 0 evidence only.** Audited 2026-07-22 against upstream tag
`v2026.7.20^{}` (`3ef6bbd201263d354fd83ec55b3c306ded2eb72a`) and fork main
`f98610f9f9eb7dc85c017eaa3165a005dbdab958`. The phone uses the intersection
below through the transparent relay. The relay must not translate these frames.

## Wire envelope and identity

WebSocket requests and responses are JSON-RPC 2.0:

```json
{"jsonrpc":"2.0","id":"r1","method":"session.resume","params":{"session_id":"stored-id"}}
{"jsonrpc":"2.0","id":"r1","result":{}}
{"jsonrpc":"2.0","id":"r1","error":{"code":4007,"message":"session not found"}}
```

Events use `{"jsonrpc":"2.0","method":"event","params":{"type":"...","session_id":"runtime-id","payload":{...}}}`.
`gateway.ready` is the sole required event without `session_id`. On the fork, S1 may add
`stored_session_id` to a mirrored event; that is additive and must not replace the runtime id.

The phone keeps one binding value: stable `storedID` for cache, drawer, deep links, and outbox;
ephemeral `runtimeID` for RPCs and event routing; `mode` (`drive` or `watch`); and the socket
`generation` that owns a drive claim. No durable row is keyed by `runtimeID`.

## RPCs the phone uses

| Operation | v0.19 request | Exact v0.19 result / semantics | Fork-main check and client action |
|---|---|---|---|
| Create | `session.create` with optional `cols`, `messages`, `title`, `cwd`, `profile`, `model`, `provider`, `reasoning_effort`, `fast`, `source` | `session_id` (runtime), `stored_session_id`, `message_count`, full `messages[]`, and `info`. It creates an in-memory session; the DB row is lazy until first submit. | Present at `tui_gateway/server.py:5590`; same identity/history fields. `SessionOpenResult` must decode `messages[]` instead of discarding them. |
| Inspect live sessions | `session.active_list` with optional `current_session_id` | Read-only `sessions[]`; each row has runtime `id`, stored `session_key`, `status` in `idle|starting|waiting|working`, plus `last_active`, `message_count`, `model`, `preview`, `started_at`, `title`, `current`. It does not rebind transport. | Present at `:6499`; same structured shape. Use a version guard like stock desktop `use-background-sync.ts`: unsupported RPC leaves current state untouched. This is the drive/watch preflight. |
| Resume for driving | `session.resume` with stored `session_id`; optional `cols`, `profile`, `source` | Returns runtime `session_id`, stored target as both `resumed` and `session_key`, full `messages[]`, `message_count`, `info`, `running`, `status`, `started_at`, optional `inflight`, and in v0.19 optional `queued`. **If already live, `_live_session_payload(... transport=current_transport())` rebinds the session to the caller.** | Present at `:5972`; same ownership-rebind. Fork main omits v0.19's `queued` resume snapshot. Never call resume for passive open; call only after `active_list` says no live runtime, or when deliberately reclaiming for queued work. |
| Submit | `prompt.submit` with runtime `session_id`, `text`, optional `truncate_before_user_ordinal`, and fork S11 `client_message_id` | Stock success is `{"status":"streaming"}` (or busy-policy `queued`/`steered`) and the request rebinds `session["transport"]` to the caller before the turn. Stock has no `client_message_id`. | Present at `:8910`. Fork S11 adds `accepted`, echoed `client_message_id`, and `deduplicated` only when an id is supplied; legacy shape stays stock. WorkRepository deletes an outbox row only after that acceptance proof. |
| Human status fallback | `session.status` with runtime `session_id` | v0.19 returns only human `output`; it is not machine liveness. | Present at `:8217`; fork adds nullable `running`, `model`, `provider`, `usage`. Do not parse `output`; normal drive/watch uses `active_list`. |
| Full live history | `session.history` with runtime `session_id` | `count` plus full `messages[]`; not paginated. | Present at `:8297`; same shape. Use only when a live-runtime read is specifically required, not for scrollback. |

## Authoritative transcript read and pagination

Use HTTP `GET /api/sessions/{storedID}/messages?profile=...&limit=N&offset=O` through the same
relay address. Both v0.19 (`hermes_cli/web_server.py:10962`) and fork main (`:10026`) resolve
the compression tip and return:

```json
{"session_id":"resolved-stored-id","messages":[],"pagination":{"limit":100,"offset":0,"returned":0}}
```

`limit` is clamped to 500. Rows are insertion-order, oldest first; `offset` is zero-based.
For “load earlier,” calculate the preceding offset from the known total/message count and the
already loaded window. A cold cache miss and the existing bounded foreign-user tail merge may each
use this authoritative read only where I14 permits; ordinary live turns come from events.

## Required event vocabulary

These events exist in both audited trees and are the only baseline the vertical slice may require.
Every session-scoped event routes by runtime `session_id`; unknown additions are ignored in isolation.

| Event | Payload used by iOS | Phone effect |
|---|---|---|
| `gateway.ready` | `skin` (optional) | Marks the socket generation open. |
| `message.start` | no user text | Starts assistant live state. For a foreign turn, run the one existing bounded tail read to obtain the durable user row. |
| `message.delta` | `text`, optional `rendered` | Append assistant text to the runtime-bound transcript. |
| `message.complete` | `text`, `status`, `usage`; optional `reasoning`, `warning`, `rendered`, `response_previewed` | Authoritative settle edge for assistant text; persist settled rows under `storedID`. |
| `thinking.delta`, `reasoning.delta`, `reasoning.available` | `text`, optional `verbose` | Transient live display; no durable replay promise. |
| `tool.start`, `tool.complete` | stable `tool_id`, `name`, context/args/result/summary/duration and optional diff/todos | Structured live activity. `tool.generating` and `tool.output_risk` are optional stock additions and must decode as unknown until a native surface needs them. |
| `status.update` | `kind`, `text` | Structured lifecycle/compaction status. |
| `approval.request` | redacted command data, `choices`, request identity | Park by session/request; answer through the existing explicit-target RPC and S13 recovery. |
| `clarify.request`, `sudo.request`, `secret.request` | `request_id` plus question/choices or secure-prompt metadata | Park by session/request; secure values are never persisted. |
| `error` | `message` | Settle the affected runtime as failed without contaminating another session. |
| `session.info` | runtime metadata such as model/provider/cwd/reasoning/tier/running | Update the bound session's metadata, not global composer state for another chat. |
| `subagent.start`, `subagent.thinking`, `subagent.tool`, `subagent.complete` | structured child identity/activity fields | Retain the existing raw-event support; unattributable child events are dropped. |

## Drift HermesGatewayClient must reconcile

1. Decode `messages[]` on create/resume. The current `SessionOpenResult` drops it.
2. Decode stored resume identity from `session_key` as well as `resumed`; keep `inflight`; tolerate
   v0.19 `queued` and its absence on fork main.
3. Add a typed `session.active_list` response and treat only its four structured status strings as
   liveness. Do not use fork-only structured `session.status` as the normal decision source.
4. Preserve the stock ownership rule: resume and submit drive/rebind; `active_list` and HTTP reads
   watch without rebinding.
5. Required baseline events above are present on both trees. The fork is a superset of this required
   subset, **not of the entire v0.19 optional vocabulary**: v0.19 has `message.interim`, while fork
   main does not. Keep unknown-event isolation and do not require optional events in Phase 2.
6. Retain S1/S2/S5/S6/S11/S13 behavior as additive seams. No relay-owned transcript, session state,
   event vocabulary, receipt database, or stored/runtime translation is part of this map.

Reproduce presence and ownership checks:

```sh
git rev-parse 'v2026.7.20^{}'
git grep -nE '@method\("(session.create|session.resume|session.active_list|session.status|session.history|prompt.submit)' v2026.7.20 -- tui_gateway/server.py
git grep -nE '@method\("(session.create|session.resume|session.active_list|session.status|session.history|prompt.submit)' HEAD -- tui_gateway/server.py
git show v2026.7.20:tui_gateway/server.py | sed -n '6224,6246p;6659,6732p;9390,9506p'
git show HEAD:tui_gateway/server.py | sed -n '6042,6064p;6464,6534p;8910,9019p'
git grep -n '@app.get("/api/sessions/{session_id}/messages")' v2026.7.20 HEAD -- hermes_cli/web_server.py
```
