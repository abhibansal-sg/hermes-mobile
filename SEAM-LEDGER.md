## Phase 2 rebase status (2026-06-11) — rebuilt onto upstream/main @ c94e93a64

The fork was rebuilt on fresh `upstream/main` (613 commits past merge-base
`3c231eb39`). Upstream **independently converged** on several seams, which were
therefore DROPPED (not re-placed):

- **S7** (WS owner-write queue) — upstream's `WSTransport` adopted fire-and-forget
  loop-thread writes + a bounded `_WS_WRITE_TIMEOUT_S` pool-thread path. Dropped;
  remains a strong standalone PR if the strict never-block guarantee is wanted.
- **S8** (`exclude_source` filters) — upstream added it verbatim (`hermes_state`,
  `web_server`). Dropped.
- **S10** (REST live-delete 409 guard + embedded-chat 4404 reorder) — upstream has
  the 4404 embedded-chat guard; REST live-delete guard dropped (the gateway
  `session.delete` S6 auto-evict is the live-lifecycle mechanism the iOS app uses).
- **env-leak model-switch fix** — superseded by upstream's `session["model_override"]`
  dict (provider/base_url/api_key/api_mode). Adopted theirs; this is the
  cross-session model-picker fix.
- **S3 `provider` in `_session_info`** — upstream added it. Only `_runtime_sid`
  remained from S3.

**Residual stock seams after rebase: S1, S2, S3(`_runtime_sid`), S4, S5, S6** —
8 files, +785/−103 vs upstream. The patch applies CLEAN onto pristine upstream/main
(`dist/hermes-mobile/seams.patch`). Backend gate green (server 265/265; full
seam-surface suite passes in proper isolation; 1 regression — `search_messages`
`role_filter` kwarg — found and fixed to additive). iOS unchanged (build 33,
byte-identical) — model-picker fix is server-side, so it benefits with no rebuild.

---

# SEAM LEDGER — ABH-88 de-patch, Phase 1 (W4 deliverable)

**Fork-local** (never in upstream-bound patches). Generated 2026-06-11 against
merge-base `3c231eb39` after W1–W3 (`e2696c06c`, `a3fdf4b4d`, `b77ba0764`).
Verified by the W4 gate: every residual hunk in every stock file maps to a
catalogued seam below; a leak sweep found **zero** plugin-internal imports in
stock code. This document is the input to the upstream PR series.

ALL mobile/multi-client logic lives in `plugins/hermes-mobile/` (modules:
`dashboard/api.py`, `push_engine.py`, `broadcast.py`, `device_tokens.py`,
`audit_log.py`, `mobile_pair.py`, `gitbranch.py`). The iOS client speaks the
plugin paths behind a capability probe with legacy fallback (W3).

## Residual stock-file surface (vs merge-base)

| File | Seams present | Lines (±) |
|---|---|---|
| `tui_gateway/server.py` | S1 S2 S3 S4 S6 + SHIM + 1 DROP | ~330 |
| `tui_gateway/ws.py` | S1 S7 | ~155 |
| `hermes_cli/web_server.py` | S5 S8 S10 | ~210 |
| `hermes_cli/dashboard_auth/token_auth.py` | S5 (new additive file) | +87 |
| `hermes_cli/dashboard_auth/middleware.py` | S5 | ~33 |
| `hermes_cli/dashboard_auth/routes.py` | S5 | ~35 |
| `hermes_cli/dashboard_auth/ws_tickets.py` | S5 | ~4 |
| `tools/approval.py` | S5 | ~18 |
| `hermes_state.py` | S8 | ~7 |
| `hermes_cli/main.py` | — | **0** |

## The seams (each = an upstream-PR candidate)

### S1 — Gateway event fan-out subscribers
*PR: "gateway: event fan-out + transport lifecycle observers".*
- `server.py`: `_EVENT_FANOUT_SUBSCRIBERS` + subscriber loop in `write_json`
  after the owner-transport write (`fn(obj, sid, owner_transport)`).
- `ws.py`: `TRANSPORT_OBSERVERS` + `_notify_transport_observers` called on
  connect/disconnect in `handle_ws` (`fn(action, transport)`).
- Consumer: plugin `broadcast.py` (registry, per-transport bounded queue/drain,
  `stored_session_id` enrichment, `HERMES_GATEWAY_BROADCAST` opt-in).

### S2 — Emit observers
*PR: "gateway: emit observers".*
- `server.py`: `_EMIT_OBSERVERS` + `_notify_emit_observers(event, sid, payload)`
  from `_emit`, plus three synthetic boundary notifications that never ride
  `_emit`: `session.finalize` (finalize, carries runtime sid + session_id +
  session_key), `session.deleted` (delete handler), `session.interrupt`
  (interrupt handler).
- Consumer: plugin `push_engine.handle_gateway_event` (APNs alerts, Live
  Activity updates + cleanup).

### S3 — Session-info completeness (trivial)
- `_runtime_sid` stored on both session-row constructors (`_init_session` and
  the `session.create` placeholder — the latter also fixes a trunk gap where
  Live-Activity tokens of created-not-resumed sessions never cleaned up).
- `provider` field in `_session_info` (clients need the (provider, model) pair).

### S4 — Session-scoped reasoning/fast overrides
*PR: "session-scoped reasoning/fast overrides" — extension of upstream's own
accepted `session["model_override"]` pattern.*
- `config.set fast`/`reasoning` with a session never write global config:
  values park on `session["fast_override"]`/`["reasoning_override"]` and apply
  once at agent construction (`_apply_session_agent_overrides` in
  `_start_agent_build`); live agents update immediately (`_apply_fast_mode`).
- Pre-build `status`/`toggle`/`config.get` consult the parked override;
  pre-build fast validation resolves the target model under the session's
  `profile_home`.
- The `config.set model` → `session.info` emit (composer-pill parity, ABH-84)
  rides along; re-evaluate at rebase.

### S5 — Pluggable dashboard token auth + approval resolve observers
*PR: "dashboard: pluggable bearer-token auth (+ WS ticket extras, approval
resolve observers)" — the largest and most valuable seam.*
- **New additive** `dashboard_auth/token_auth.py`: `TOKEN_AUTHENTICATORS`
  (`fn(token) -> Optional[identity]`), `IDENTITY_VALIDATORS` (revocation),
  `SOCKET_OBSERVERS` (live-socket index for revoke-cut).
- `web_server.py`: third OR-branch in `_has_valid_session_token` (after BOTH
  shared-token checks — can only accept, never reject), `_ws_token_identity`
  branch in `_ws_auth_reason`, `_ws_active_identity` /
  `_close_if_ws_device_revoked` on long-lived sockets, `notify_socket`
  register/deregister around `pty_ws`/`gateway_ws`, scope helpers
  (`_has_dashboard_api_auth`, `_device_has_scope`, …).
- `middleware.py`: `_device_token_auth` registry path for `/api/*` in
  OAuth-gated mode.
- `routes.py` + `ws_tickets.py`: device branch of `/api/auth/ws-ticket`
  (`mint_ticket extra=` carries identity into single-use WS tickets).
- `server.py`: WS `approval.respond` scope gate + `approve→once` remap +
  `_ws_resolve_audit` attribution (built purely from `ws.state.device`).
- `tools/approval.py`: `audit=` param + `_RESOLVE_OBSERVERS` notified after
  agent threads unblock. (The stock `post_approval_response` hook cannot carry
  the resolver's identity — verified in W2 — hence this observer.)
- Consumer: plugin `device_tokens.py` (registry) + `audit_log.py` (writer),
  wired in `register(ctx)`.
- **Known limitation (by design, documented):** revocation completing between
  the auth-time `match_token` accept and the `SOCKET_OBSERVERS` register call
  leaves that socket uncut until its next `identity_active` check or
  disconnect — revocation is eventually-consistent on live sockets.

### S6 — session.delete live-evict (+ S10 bundle)
*PR: "gateway: session.delete shouldn't 4023 on live sessions".*
- `server.py`: delete handler auto-evicts the live row (interrupt mid-turn,
  release pending approvals, teardown) instead of refusing; returns `evicted`.
- S10 bundled: `web_server.py` REST delete live-guard (409 on a live session)
  and the embedded-chat guard reorder (4404 after auth instead of 4403 before).

### S7 — WSTransport non-blocking owner-write queue
*PR: "gateway: fix WS head-of-line blocking" — strong standalone case.*
- `ws.py`: `write()` enqueues onto a bounded FIFO drained by a single loop
  task; overflow closes the transport (owner frames are not gap-markable);
  `_owner_queue_max()` env-tunable.

### S8 — exclude_sources filters
*PR: trivial API addition.*
- `hermes_state.py` `session_count` + `web_server.py` `/api/sessions` and
  `/api/profiles/sessions`: `source` / `exclude_source` params (drawer
  bifurcation: human Recents vs automation runs).

### S9 — Desktop foreign-frame adoption (NOT in this branch)
Ships only with the desktop multi-client PR; remains in the desktop lane.

## SHIM (documented, not a seam)
- `server.py::_git_branch_fast` — 7-line shim importing the plugin's
  fork-free branch reader, subprocess fallback when the plugin is absent.

## DROPS at the Phase-2 rebase
- `_apply_model_switch` env-write gating (upstream superseded the env-leak fix
  with `session["model_override"]`; adopt theirs, drop ours).
- Re-evaluate the ABH-84 `session.info` emit (S4 note above) against upstream.

## Suggested upstream PR series (smallest-first)
1. S3 (2 lines) → 2. S8 → 3. S6+S10 → 4. S7 → 5. S2 → 6. S1 (flagship:
   multi-client broadcast story) → 7. S4 → 8. S5 (largest; split token_auth.py
   + gates from the approval-observer piece if review stalls).
