# ABH-519 Phase 1 — transparent proxy evidence

**Base:** `origin/main` at `d66372ed5134c8fc8ac529ca3f6c9f9d77cbc998`

**Branch:** `codex/abh-519-v019-phase1-thin-proxy`

**Scope:** authenticated stock WebSocket and HTTP forwarding only; the legacy relay path remains available.

## Transparent wire proof

`relay/tests/test_transparent_proxy.py` runs real downstream and upstream sockets. It proves:

- `/api/ws?token=...` authenticates the phone, replaces the boundary credential with the configured gateway token, and forwards text frames byte-for-byte in both directions;
- arbitrary HTTP methods, paths, query strings, request bodies, response statuses, and response bodies pass through unchanged;
- the phone credential is removed before forwarding and the gateway credential is injected;
- invalid phone credentials receive HTTP 401 and never reach the upstream.

Result: `3 passed`.

The existing Python phone driver now records stock `method: "event"` frames and exposes a generic JSON-RPC call without adding a second driver. Against the deterministic scripted gateway it completed stock `session.create` -> `prompt.submit` -> `message.complete`, retrieved the transcript over proxied HTTP, and observed zero legacy relay frames.

Evidence: `/Volumes/MainData/Developer/hermes-tmp/evidence/daily-driver/e2e/test_stock_frames_round_trip_unchanged-stock-proxy.json`.

## Real isolated fork gateway

The stock-aware driver was then run through this worktree's relay against the real fork gateway:

- gateway: `127.0.0.1:9134`, temporary `HERMES_HOME`;
- relay: `127.0.0.1:8792`, separate temporary `HERMES_HOME`;
- live ports `9119` and `8788` were not contacted;
- both processes were stopped with explicit `SIGTERM`.

Observed through the proxy: `gateway.ready`, successful `session.active_list`, successful `session.create`, HTTP 200 from stock `/api/status`, and zero legacy relay frames. The created runtime/stored IDs are recorded in the external evidence without credentials.

Evidence: `/Volumes/MainData/Developer/hermes-tmp/evidence/daily-driver/e2e/test_external_stock_gateway_9130_plus-external-stock-proxy.json`.

An initial HTTP probe asked for history of the newly created but still-empty session and received the gateway's 404 unchanged. The probe was corrected to `/api/status`; no special case or response translation was added.

## Regression and state audit

- Full relay suite: `254 passed, 1 skipped`.
- Legacy item-stream E2E plus stock-frame E2E: `2 passed`.
- Legacy relay SIGTERM/reconnect E2E: `1 passed`.
- `git diff --check`: pass.
- No edits to `durable_state.py`, `session_state.py`, `reframer.py`, `gateway_client.py`, or their schemas.
- Added proxy lines contain no `SessionStore`, `DurableState`, `Reframer`, SQLite, submit deduplication, `json.loads`, or `json.dumps` use.

The stock lane authenticates, selects the configured gateway, forwards, and applies socket/HTTP backpressure. It creates no relay session identity, persistence, transcript, event vocabulary, replay, or semantic translation.
