# CONTRACT — De-patch to Plugin Architecture (ABH-88)

**Goal:** stock Hermes files pristine (or near); ALL mobile/multi-client work lives in
a plugin package + a short list of minimal seams, each shaped as an upstream-PR
candidate. Sustainable across upstream evolution; adoptable by Nous.
**Hard requirements:** both topologies work natively —
(A) standalone gateway, desktop remote + iOS remote (current);
(B) desktop EMBEDDED gateway (stock `mode:"local"`), iOS connects to it.
**Target API:** design against pristine `upstream/main`; capability stays in the
plugin and only the irreducible host seams below remain in core.

## Baseline (supersession sweep 2026-07-15, merge-base 306e2d231)
The iOS overlay is rebased onto pristine upstream commit `306e2d231`. The old
fork carried roughly 1,257 core-patch lines; the re-applied core seam set is 9
files, +701/-80 lines at this ledger/patch regeneration. Everything else is
either already upstream or no longer consumed by `plugins/hermes-mobile` / iOS.

### Seam verdicts on the new base

| Seam | Verdict | New-base disposition / evidence |
|---|---|---|
| S1 | STILL-NEEDED (reduced) | First-class `post_frame_write` and `on_ws_transport_change` hooks only; no legacy subscriber lists (`hermes_cli/plugins.py`, `tui_gateway/server.py`, `tui_gateway/ws.py`). |
| S2 | STILL-NEEDED (reduced) | First-class `pre_emit_event` payload transform and `post_emit_event` observer plus runtime id metadata on upstream's existing `on_session_finalize`; no `_EMIT_OBSERVERS` or synthetic finalize event. The pre-transform lets the mobile plugin stamp one correlation identity before both owner and broadcast delivery. |
| S3 | SUPERSEDED / reduced | Upstream `_session_info` already includes provider. `_runtime_sid` storage is dropped; finalize receives the existing record's `_sid` as transient hook metadata. |
| S4 | STILL-NEEDED (small) | Reasoning is already session-scoped upstream. Only `config.set/get fast` needed adaptation to `create_service_tier_override`. |
| S5 | STILL-NEEDED | The stock provider registry covers exact Bearer-token REST routes, but not rich device metadata, plugin routes, WS tickets, live revocation, socket indexing, or resolver audit identity. Generic registries and guarded call sites remain. Every device-capable dashboard WS route now enters one shared lifecycle that indexes only active device identities and closes revoke/register races (ABH-449). |
| S6 | STILL-NEEDED | Stock `session.delete` still returned 4023 for a live row. It now interrupts a running turn, releases prompts/approvals, tears down, deletes, and reports `evicted`. |
| S7 | SUPERSEDED | Upstream `WSTransport` already schedules loop-owned writes, coalesces token frames, and preserves control-frame ordering. |
| S8 | SUPERSEDED | `exclude_sources` is already implemented in `hermes_state.py` and both dashboard session APIs. |
| S9 | OBSOLETE | The plugin enriches fan-out frames with `stored_session_id`; no desktop foreign-frame core adoption seam is referenced. |
| S10 | OBSOLETE | Embedded-chat route guards are upstream. iOS closes its owned runtime before RPC delete and uses profile-scoped REST only for non-default rows, so the old REST live-delete core guard has no current consumer. |
| S11 | STILL-NEEDED (generic) | `prompt.submit` exposes a generic receipt-provider registry and calls it before mutation. The hermes-mobile plugin owns SQLite, profile scoping, liveness, and 30-day retention (ABH-462 / R-48). |
| S12 | STILL-NEEDED (small) | Stock `session.status` exposes only rendered text. The additive structured projection (`running`, nullable model/provider/usage) is generic gateway protocol completeness and an upstream-ready fix; authoritative runtime state is unreachable through a mobile plugin without replacing the core RPC. |
| S13 | STILL-NEEDED (generic) | Approval and clarification owners expose lock-safe, display-redacted pending-record snapshots plus the existing clarification waiter resolver. The mobile plugin owns auth visibility, cursor signing, bounded delta/tombstone history, and the REST route (ABH-445 / R-03,R-53,R-54). |

## 1. Plugin package: `plugins/hermes-mobile/`
Rides the STOCK plugin system (`hermes_cli/plugins.py` manager + dashboard
`api` router mount; precedent: `dashboard_auth` is itself a plugin).

Modules (moved or already-new):
- `api.py` — FastAPI router (auto-mounted `/api/plugins/hermes-mobile/…`):
  upload, approvals/respond, devices CRUD + audit list, fs/list + fs/read,
  pending-attention snapshot/delta, push register/prefs. (web_server clusters
  B,C,D,E,I → zero stock seams.)
- `pending_attention.py` — process-instance ID, per-credential visibility
  journals, signed cursors, bounded upsert/tombstone retention, and owner
  snapshot aggregation for the mobile reconciliation route.
- `push_engine.py` (from `hermes_cli/push_notify.py`) — APNs + Live Activity.
  Event intake: approval pushes via STOCK `pre_approval_request` hook;
  session-end LA cleanup via `on_session_finalize`; long-turn/clarify pushes
  need the emit-subscriber seam (S2) until an upstream events hook exists.
- `device_tokens.py`, `audit_log.py`, `mobile_pair.py` — move as-is.
  CLI: register `mobile-pair` via facade `register_cli_command`
  (KILLS the ~49-line main.py seam).
  Auth: expose device-token auth via `register_dashboard_auth_provider`
  (KILLS/shrinks middleware + routes seams — verify provider hook covers
  REST `_require_token` AND `_ws_auth_reason`; whatever it can't reach stays S5).
  Audit: move `tools/approval.py` seam onto `post_approval_response` hook
  (verify kwargs carry enough; device identity may need S5 cooperation).
- `broadcast.py` — fan-out engine: live-transport registry, per-transport
  broadcast queue/drain (ws.py clusters A,C,D as module/mixin), enrichment
  (stored_session_id). Activated only when seam S1 fires it.
- `gitbranch.py` — `_git_branch_fast` (pure additive helper + 1 call-site swap).
- Tests move alongside (tests/plugins/hermes_mobile/…).

## 2. Irreducible seams (each = an upstream-PR candidate)
S1 write_json broadcast hook (~3 lines, server.py) — after owner write, iterate a
   module-level subscriber set the plugin populates. PR: "gateway: event fan-out
   subscribers".
S2 _emit transform/observer (small helper + call, server.py) — generic chained
   `pre_emit_event` payload transformation followed by the existing post-emit
   observer. PR: "gateway: event payload transforms + emit observers" (mobile
   correlation and push ride it; all identity/policy remains plugin-owned).
S3 `_runtime_sid` in session record (1 line) + `provider` in `_session_info`
   (1 line). PR: trivial info-completeness.
S4 config.set session-scoping for reasoning/fast (~120 lines today) — REWRITE
   smaller by following upstream's accepted `session["model_override"]` pattern
   (session_overrides dict consulted at agent build). PR: "session-scoped
   reasoning/fast overrides" — natural extension of their own fix.
S5 Device-token auth branches not coverable by the auth-provider registry
   (`_ws_auth_reason` WS branch, `mint_ticket extra`, shared device-socket
   lifecycle on every accepting WS handler, resolver audit call sites). The
   lifecycle is provider-neutral and notifies generic socket observers; the
   plugin owns the per-device index and revoke/register race guard. PR:
   "pluggable WS auth / ticket extras / authenticated socket lifecycle".
S6 session.delete live-evict (~35-line helper + shim in the RPC handler).
   PR: UX fix — delete shouldn't 4023 on live sessions.
S7 WSTransport non-blocking owner-write queue (~175 lines, class rewrite).
   PR: perf/robustness fix (head-of-line blocking) — strong standalone case.
S8 `exclude_sources` params (hermes_state 7 + web_server 8). PR: API addition.
S9 Desktop foreign-frame adoption ref-threading (~60 lines across 3 files) —
   ships only WITH the desktop multi-client PR; until then stays in fork.
S10 web_server REST live-delete guard (~34) + embedded-chat guard reorder (~12).
   Bundle into S6's PR.
S11 prompt receipt provider registry + pre-mutation `prompt.submit` call sites.
   PR: "gateway: pluggable prompt idempotency receipts". Core contains no
   mobile database path, schema, or retention policy; those live entirely in
   `plugins/hermes-mobile/prompt_receipts.py`.
S12 session.status structured runtime truth (~30 lines, server.py). Preserve the
   existing `output` while exposing the session record's boolean `running` and
   nullable agent metadata/usage. PR: "fix(gateway): return structured session
   status" — generic wire-contract completeness for every JSON-RPC client.
S13 lock-safe pending-attention owner snapshots (`tools/approval.py`,
   `tui_gateway/server.py`) plus the public clarification resolver. PR:
   "gateway: expose safe pending interaction snapshots". The waiter maps and
   their resolution locks are unreachable to a plugin without this read seam;
   no mobile auth, cursor, retention, or HTTP policy lives in core.

## 3. Drops at rebase (Phase 2)
Model-switch env-leak fix (upstream superseded + their `model_override` ⇒ most of
ABH-145), pane-shell 1-liner (verify), i18n/whitespace nits, eslint-disable pair.

## 4. iOS client migration
RestClient paths → `/api/plugins/hermes-mobile/…` behind a capability probe
(plugins.list or probe endpoint); legacy top-level paths kept as fallback during
transition; WS protocol unchanged. One TestFlight build at the end of Phase 1.

## 5. Topology B (after de-patch)
Embedded desktop gateway loads the same plugin (user/bundled source) ⇒ feature
parity for free. Remaining work: reachable bind for the embedded backend
(localhost-only today), port stability, pairing UX from embedded gateway
(mobile-pair against the desktop's child). Separate contract section when reached.

## 6. Execution plan (house method: contract → fleet → adversarial gate)
W1 Scaffold plugin package + manifest; move PLUGIN-verdict clusters verbatim;
   stock files: delete moved code, add S1–S3 seams. Gate: full pytest + plugin
   loads + routes mounted + broadcast/push smoke on test gateway (9124).
W2 Seam-minimization conversions: CLI registration, auth provider, audit hook,
   S4 rewrite to override-dict pattern. Gate: auth matrix tests (shared token /
   device token / OAuth) + approval round-trip.
W3 iOS path migration + capability probe; full iOS suite + device QA build.
W4 Verification: diff stock files vs merge-base ⇒ ONLY seam lines remain;
   seam ledger doc generated (input to the upstream PR series).
THEN Phase 2: rebase onto upstream/main (seams re-placed; drops dropped),
   full gate, staged redeploy (test gateway → user-run live redeploy).

## Constraints
- Never break the live :9119 (user redeploys; validate on 9123/9124 instances).
- Builds via scripts/ios-build.sh only. Tests green at every wave gate.
- This file is fork-local (never in upstream-bound patches).
