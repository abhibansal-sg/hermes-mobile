# CONTRACT — De-patch to Plugin Architecture (ABH-88)

**Goal:** stock Hermes files pristine (or near); ALL mobile/multi-client work lives in
a plugin package + a short list of minimal seams, each shaped as an upstream-PR
candidate. Sustainable across upstream evolution; adoptable by Nous.
**Hard requirements:** both topologies work natively —
(A) standalone gateway, desktop remote + iOS remote (current);
(B) desktop EMBEDDED gateway (stock `mode:"local"`), iOS connects to it.
**Target API:** design against `upstream/main`'s plugin surface (verified stable
across the 549-commit drift; upstream only ADDED registries).

## Baseline (inventory 2026-06-10, merge-base 3c231eb39)
Production stock-file mods ≈ 1,820 lines (+~1,252 test lines that move with their
code): verdicts ~900 PLUGIN / ~870 SEAM / ~50 DROP. Full per-hunk inventory in the
ABH-88 Linear thread.

## 1. Plugin package: `plugins/hermes-mobile/`
Rides the STOCK plugin system (`hermes_cli/plugins.py` manager + dashboard
`api` router mount; precedent: `dashboard_auth` is itself a plugin).

Modules (moved or already-new):
- `api.py` — FastAPI router (auto-mounted `/api/plugins/hermes-mobile/…`):
  upload, approvals/respond, devices CRUD + audit list, fs/list + fs/read,
  push register/prefs. (web_server clusters B,C,D,E,I → zero stock seams.)
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
S2 _emit subscriber (~1 line + finalize ~5 + interrupt ~4, server.py) — generic
   post-emit observer list. PR: "gateway: emit observers" (push rides it).
S3 `_runtime_sid` in session record (1 line) + `provider` in `_session_info`
   (1 line). PR: trivial info-completeness.
S4 config.set session-scoping for reasoning/fast (~120 lines today) — REWRITE
   smaller by following upstream's accepted `session["model_override"]` pattern
   (session_overrides dict consulted at agent build). PR: "session-scoped
   reasoning/fast overrides" — natural extension of their own fix.
S5 Device-token auth branches not coverable by the auth-provider registry
   (`_ws_auth_reason` WS branch, `mint_ticket extra`, ws-handler revoke checks —
   ~40 lines worst case). PR: "pluggable WS auth / ticket extras".
S6 session.delete live-evict (~35-line helper + shim in the RPC handler).
   PR: UX fix — delete shouldn't 4023 on live sessions.
S7 WSTransport non-blocking owner-write queue (~175 lines, class rewrite).
   PR: perf/robustness fix (head-of-line blocking) — strong standalone case.
S8 `exclude_sources` params (hermes_state 7 + web_server 8). PR: API addition.
S9 Desktop foreign-frame adoption ref-threading (~60 lines across 3 files) —
   ships only WITH the desktop multi-client PR; until then stays in fork.
S10 web_server REST live-delete guard (~34) + embedded-chat guard reorder (~12).
   Bundle into S6's PR.

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
