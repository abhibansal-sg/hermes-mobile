# Hermes Mobile — Upstream-Impact Review (2026-06-06)

**Scope.** Our `hermes-mobile` branch carries ~30 local commits (WS broadcast fan-out,
F3 non-blocking fix, APNs `_push_hook`, `/api/upload`, `/api/approvals/respond`,
git-fork `session.create`, iOS app). Upstream `origin/main` has moved **339 commits**
since the merge-base.

- merge-base: `047e7cf36`
- our HEAD: `f4f6bcbbf` (branch `hermes-mobile`)
- upstream tip: `6f6eb871d`

This review synthesizes four reviewer passes (resume-ownership, event-pipeline,
multi-profile, conflict-scan), each cross-checked against the working tree. **We are
NOT rebasing today.** The one item that could force urgency is the `--tui` removal,
and it is only urgent *at rebase time* (nothing breaks until we actually pull).

Verification anchors (checked live this session):
- `git merge-tree --write-tree origin/main HEAD` → exactly **two** content conflicts:
  `tui_gateway/server.py` and `tests/test_tui_gateway_server.py`. `ws.py`,
  `web_server.py`, and `hermes_cli/main.py` all auto-merge clean.
- Upstream resume-reuse / lock / reaper symbols
  (`_find_live_session_by_key`, `_live_session_payload`, `_session_resume_lock`,
  `_sessions_lock`, `_prompt_lock`, `display_history_prefix`,
  `_schedule_ws_orphan_reap`, `_WS_ORPHAN_REAP_GRACE_S`): **42 hits on origin/main,
  0 on our branch.** All four resume/lock/reaper clusters are upstream-only.
- Our F3 machinery present in `tui_gateway/ws.py` (19 hits:
  `_live_transports`, `broadcast`, `_drain_broadcast`, `broadcast_gap`,
  `_bcast_queue`). Untouched by upstream.

---

## 1. F3 IMPACT

**Bottom line: F3's three conclusions stand. The fix survives the merge byte-for-byte.
But the *design premise* the broadcast feature was built on is invalidated by upstream's
resume-reuse, and we have a concrete decision to make for the eventual PR series.**

### 1a. F3 verdict unchanged (test-defect, head-of-line fix, mirror health)

- **Test-defect verdict: still valid.** Nothing upstream touches the F3 root cause.
  F3 fix `f5548b40d` lives entirely in `tui_gateway/ws.py`
  (`WSTransport.broadcast` + a per-transport bounded backlog drained on the ws loop,
  drop-oldest + coalesced `broadcast_gap` marker) plus tests. Upstream's only `ws.py`
  write-path change is cosmetic (`_safe_send`/`write_async` now log
  `type(exc).__name__`). Merge-tree auto-merges `ws.py` with zero conflicts.

- **Head-of-line fix: safe, no lock conflict.** The new `_sessions_lock` (C1) and
  `_prompt_lock` (C2) do **not** wrap the emit/broadcast path. Verified: upstream
  `write_json` reads `_sessions.get(sid)` lock-free; every `_emit` call sits *outside*
  the `with _sessions_lock` blocks; `_block()` releases `_prompt_lock` before `_emit()`
  and `ev.wait()`. So our `_emit → write_json → WSTransport.broadcast` fan-out never
  runs under `_sessions_lock` and cannot deadlock against it or `session['history_lock']`.
  Our non-blocking per-client delivery remains the head-of-line cure.

- **Mirror health: still works, but ROLE STABILITY regresses under shared runtimes.**
  Functionally every client still receives every frame (owner via `write()`, mirrors via
  `broadcast()`). The regression is *who plays owner*: see 1b.

### 1b. "Reuse live session on resume" vs our broadcast approach — DIRECT SEMANTIC COLLISION

Our broadcast was built on the assumption — literally stated in the `_broadcast_event`
docstring at `tui_gateway/server.py:382-383`:

> "two clients resuming the same stored session get distinct runtime ids"

**That is now FALSE.** Upstream commit `98903d031` rewrites `session.resume` to call
`_find_live_session_by_key`: a second client resuming the same stored `session_key`
now binds to the **same live runtime sid and the same `session` dict**, and
`_live_session_payload` unconditionally does `session["transport"] = <resuming client>`.

Our owner-vs-mirror routing keys *entirely* off `session["transport"]`
(`write_json` at `server.py:428` sends the owner copy there; `_broadcast_event` at
`:431` excludes it). So post-merge:

- **Transport fight is real.** Two clients (phone + desktop) resuming one stored session
  now share one runtime and the owner role **flaps to whoever resumed or submitted last**
  (`prompt.submit` also rebinds transport at `server.py:4138-4139`). Streaming does not
  break (owner via `write`, mirror via `broadcast`), but ownership oscillates per resume
  and per submit where it was previously stable per-runtime.
- **Shared-teardown hazard.** A `session.close` from one client now tears down the runtime
  for BOTH clients. Our broadcast feature has no signal to the surviving mirror that its
  runtime vanished — the iOS app must notice via REST/`session.list` and re-resume.

This is **not** a lock conflict and **not** a textual conflict in the broadcast functions —
it is a model-level collision in the resume handler body (see Risk Register row 1).

### 1c. Is upstream converging on its own multi-client story? YES — and we should align.

Upstream's resume cluster (`98903d031` reuse, `bd6d09876` history-prefix to keep a
2nd resumer current, `8077e7d2f` narrow the resume lock, `5bcb63e40` thread-safety locks)
is a deliberate **single-shared-runtime multi-client model**: many viewers attach to one
live runtime, write reaches the active client, and the runtime is the unit of ownership.
That is a *different and arguably better-supported* answer to the same problem our
fan-out solves. We have two coherent ways to converge for the PR series:

- **Option A — keep our distinct-runtime fan-out.** Gate upstream's reuse fast-path behind
  `not _broadcast_enabled()`, so when `HERMES_GATEWAY_BROADCAST=1` each client keeps its
  own runtime and broadcast stays the sole cross-client path. Transport stays stable.
  Lowest blast radius; preserves our shipped behavior; but we diverge from upstream's
  direction and carry the fan-out indefinitely.
- **Option B — adopt upstream reuse, neuter our broadcast for the resume case.** One shared
  runtime already reaches the owner via `write()` and the rest via `broadcast()`; we'd
  keep broadcast only to mirror the *one* runtime's frames and **fix the owner-role flap**
  by not clobbering `session["transport"]` when a mirror resumes/submits. Converges with
  upstream; smaller long-term delta; requires the transport-rebind guards below.

**Recommended: Option B at PR-series time** (align with upstream's direction), with these
guards as the concrete mechanism:
- In `_live_session_payload`, guard the rebind:
  `session["transport"] = transport` only when
  `transport is not None and (not _broadcast_enabled() or session.get("transport") is None)`.
- Same guard at `prompt.submit` (`server.py:4138-4139`): in broadcast mode, do not steal
  the owner copy from an existing owner on every submit.
- Rewrite the `_broadcast_event` docstring premise (`server.py:380-383`) — drop the
  "distinct runtime ids" claim.

Either way: **decide the model before the PR series, not during the rebase.** The merge
will *compile and stream* regardless; the bug is behavioral (role flap + shared teardown),
so it won't be caught by a green build.

---

## 2. BREAKAGE WATCH

Things that break on rebase/update, each with a one-line mitigation:

1. **`hermes dashboard --tui` flag removed (commit `cae6b5486`) → launchd service fails
   to start.** Our wrapper `~/.hermes/bin/hermes-dashboard-service:45`
   runs `hermes dashboard --no-open --tui --host 127.0.0.1 --port 9119`; the commit
   removes `--tui` from the dashboard subparser and its own body warns argparse "would
   now error with 'unrecognized arguments: --tui'".
   *Mitigation: in the same commit that rebases past `cae6b5486`, edit the wrapper to
   `hermes dashboard --no-open --host 127.0.0.1 --port 9119` (embedded chat is now
   unconditional; `HERMES_DASHBOARD_TUI` becomes a silent no-op).*

2. **WS orphan reaper (commit `96cd37e21`) → long-lived iOS owner sessions get reaped
   after 20s of disconnect.** iOS holds one `/api/ws` socket and owns the session
   (`session.create`/`resume`/`prompt.submit`); on background/socket-drop the finally
   block detaches transport and schedules `_schedule_ws_orphan_reap(sid)`. After
   `HERMES_TUI_WS_ORPHAN_REAP_GRACE_S` (default **20s**) without a re-resume, the runtime
   and its `slash_worker` are finalized — the user's live turn is gone. A >20s background
   gap is unsafe (a foreground reconnect IS safe: `ConnectionStore.swift:450-451` calls
   `resumeActiveAfterReconnect()`, which rebinds transport and cancels the reap).
   *Mitigation: set `HERMES_TUI_WS_ORPHAN_REAP_GRACE_S=300` in the launchd env (mobile-
   friendly window) — NOT 0, which re-introduces the `slash_worker` leak the commit
   fixed — and confirm iOS re-resumes promptly on every foreground reconnect (it does).*

3. **`ws.py` `handle_ws` finally block (commit `96cd37e21`) → mechanical merge with our
   `_live_transports.discard`.** Both edits touch the transport-detach loop; upstream
   renames the loop var `_`→`_sid` to pass the sid to the reaper.
   *Mitigation: keep BOTH — our `_live_transports.discard(transport)` (which sits above
   the loop) AND upstream's per-sid `_schedule_ws_orphan_reap(_sid)` inside it; preserve
   the `_`→`_sid` rename. (Merge-tree already interleaves these cleanly.)*

4. **`web_server.py` WS-refusal refactor (commit `6717914e0`) → potential conflict on WS
   gate functions.** It rewrites `_ws_auth_ok`→`_ws_auth_reason`,
   `_ws_host_origin_is_allowed`→`_ws_host_origin_reason`, and splits close code 4403 into
   4401/4403/4404/4408. Our `/api/upload`, `/api/approvals/respond`, `/api/push/*` routes
   are far above the edit zone and do NOT collide (merge-tree confirms web_server.py
   auto-merges). The only risk is IF any of our ~30 commits modified those gate functions.
   *Mitigation: confirm our branch did not change `_ws_auth_ok`/`_ws_host_origin_is_allowed`/
   `_ws_client_is_allowed`/`pty_ws`; if untouched, take upstream wholesale (the old bool
   predicates survive as thin wrappers, semantics identical). If we DID change a gate,
   re-apply that delta on top of the new `_ws_*_reason` functions.*

5. **iOS resume-response shape change (commit `98903d031`) → NO break (additive).** Resume
   now returns `inflight`/`running`/`started_at`/`status`/`session_key`. iOS decoders are
   plain `Decodable` structs that ignore unknown keys; `SessionRuntimeInfo`/`SessionOpenResult`
   fields are all optional. `gatewayTypes.ts` already added these in `98903d031`, so the
   wire contract is known.
   *Mitigation: none required for decode correctness. Separately add iOS recovery for the
   shared-runtime teardown case (item 1b): when a client closes a shared runtime, detect
   the runtime is gone via `session.active_list`/REST and re-resume.*

6. **`tests/test_tui_gateway_server.py` conflicts (out of cluster) → blocks a clean rebase
   if unowned.** Surfaced mechanically by merge-tree alongside `server.py`.
   *Mitigation: hand off to the test-cluster owner before the rebase; it is a real
   CONFLICT marker, not a soft adjacency.*

---

## 3. REBASE RISK REGISTER (ranked)

Ranked by behavioral blast radius, not textual difficulty. Verified against
`git merge-tree --write-tree origin/main HEAD` (exactly two content conflicts) and
per-region diff intersection.

| # | Location | Type | Severity | Resolution |
|---|----------|------|----------|------------|
| 1 | `server.py` `session.resume` handler (ours ~3205-3246) vs upstream `_find_live_session_by_key` rewrite | **Semantic + textual rewrite** | **HIGH (model decision)** | Must take upstream's body. Then decide Option A (gate reuse behind `not _broadcast_enabled()`) vs Option B (adopt reuse + transport-rebind guards). This is the only item needing a *decision*, not just a merge. |
| 2 | launchd wrapper vs `--tui` removal (`cae6b5486`) | **Hard runtime break (not a merge conflict)** | **HIGH (but only at rebase time)** | Edit wrapper to drop `--tui`, in lockstep with the rebase commit. |
| 3 | `server.py` `session.close` (ours ~3609) vs upstream (locks + `_teardown_session`, ~3866-3895) | Textual conflict + shared-teardown behavior | MEDIUM | Take upstream body; add iOS recovery for shared-runtime teardown (1b). |
| 4 | `ws.py` `handle_ws` finally: our `_live_transports.discard` vs upstream orphan-reap + `_`→`_sid` | Mechanical merge | MEDIUM | Keep BOTH statements; preserve loop-var rename. (Auto-interleaves.) |
| 5 | Orphan reaper grace vs mobile backgrounding (`96cd37e21`) | Config/behavioral | MEDIUM | `HERMES_TUI_WS_ORPHAN_REAP_GRACE_S=300` in launchd env. |
| 6 | `server.py` `_broadcast_enabled`/`_broadcast_event` (ours) vs `_profile_home` (theirs, `02d6bf1c3`) — same anchor after `_db_unavailable_error` | Adjacent-insertion conflict | **EASY (the only mechanical server.py conflict)** | Keep BOTH function blocks, either order. ~30s, zero logic. After: confirm the `if _broadcast_enabled(): _broadcast_event(...)` hook inside `write_json`'s event branch survived. |
| 7 | `server.py` `session.create` handler — upstream `_sessions_lock` wrap + `profile_home` key vs our `_git_branch_fast`/`desktop_contract`/`profile_name`/`stored_session_id` | Union merge | EASY | Resolve by union; keep the `transport` key. |
| 8 | `server.py` `_make_agent` + `_start_agent_build` + `_ensure_session_db_row` gain `profile_home`/`session_db` kwarg | Adjacent auto-merge | EASY | Verify our `_make_agent` callsites pass args by keyword. |
| 9 | `server.py` `_init_session` — upstream wraps `_sessions[sid]=` in `with _sessions_lock` (`5bcb63e40`) | Textual, mechanical | EASY | Take upstream; we added no fields there. |
| 10 | `server.py` unlocked `_sessions.get(sid)` in `_broadcast_event`/`_push_hook`/`_push_approval_enrichment`/`_live_activity_hook` vs upstream's new locking discipline | Semantic-only (not a conflict) | COSMETIC (optional) | Optionally wrap reads in `with _sessions_lock:` for consistency. Low risk if skipped; does not block. |
| 11 | `tests/test_tui_gateway_server.py` | Content conflict (out of cluster) | MEDIUM (blocks clean rebase) | Hand to test-cluster owner. |
| — | `ws.py`, `web_server.py`, `push_notify.py`, `hermes_cli/main.py` | Auto-merge clean | NONE | `push_notify.py` is new-to-us (0 upstream commits); only its importers matter, and they merge clean. |

**Multi-profile cluster (5 commits `b94b3622b`/`cf9dc366d`/`3045d5454`/`02d6bf1c3`/
`6f6eb871d`) is additive and DORMANT in our topology** (no `--profile`, no app-global
remote `connection.json`, so `_profile_home` returns `None` on every path). The only
real cost is the union merge in row 7. iOS decoders tolerate the new keys; the `icon`
field was added then reverted (`cf9dc366d`) and iOS never modeled it.

---

## 4. WAVE 2.4 — multi-profile

**Upstream's multi-profile work SUPERSEDES our per-profile-dashboard plan and CONFIRMS
our client-side single-connection switcher.** We should retarget the iOS app to upstream's
model rather than ship our own.

What upstream shipped (5 commits): optional `profile` param on WS `session.create`,
`session.resume`, `prompt.submit`; a new `GET /api/profiles/sessions` (returns
`sessions`/`total`/`profile_totals`/`limit`/`offset`/`errors`, rows tagged
`profile`/`is_default_profile`/`is_active`/`archived`); optional `profile` on GET/PATCH/
DELETE of `/api/sessions/{id}` and `/messages`; `clone_from` on `POST /api/profiles`.
Internally one global-remote dashboard scopes per-call by overriding `HERMES_HOME` via a
ContextVar — **one dashboard, many profiles**, instead of one dashboard per profile.

**iOS should target the single-dashboard model:**
- Keep the switcher **client-side over one connection** (upstream confirms this is the
  intended shape — do NOT build per-profile dashboards or per-profile sockets).
- For the rail: call `GET /api/profiles/sessions?profile=all&limit=&offset=&order=recent`
  with a new wrapper type; add an optional `profile: String?` to `SessionSummary`.
- Send optional `profile` on iOS `session.create`, `session.resume`, PATCH, DELETE.
- **Do NOT chase the new `profile`/`is_default_profile`/`profile_totals` fields until we
  actually ship the switcher** — they appear only on `GET /api/profiles/sessions`, which
  iOS does not call today, and our existing decoders already ignore them.

**F3 relevance of multi-profile: LOW.** Upstream touches none of `_emit`/`_broadcast_event`/
`_push_hook`; our F3 fix and `_live_transports` registry keep working. One latent gap for
*future* multi-profile: our broadcast frames carry `stored_session_id` but not the owning
profile, and stored ids now live in separate per-profile `state.db`s (collision risk). A
future fix would add `profile` alongside `stored_session_id` in `_broadcast_event`. **Moot
today** — our single-profile 9119 service makes `_profile_home` return `None` everywhere.

---

## 5. RECOMMENDED SEQUENCE

### Now (this week — we are NOT rebasing today)

1. **No code action required today.** Nothing breaks until we pull. F3 ships as-is.
2. **Pre-stage the launchd fix.** Note that the rebase commit past `cae6b5486` MUST edit
   `~/.hermes/bin/hermes-dashboard-service:45` to drop `--tui` in the same
   commit (it's a hard argparse error otherwise). Write the new command down now:
   `hermes dashboard --no-open --host 127.0.0.1 --port 9119`.
3. **Decide the multi-client model (Option A vs B) on paper** so the resume-handler
   rewrite (Risk #1) is a mechanical apply, not a design debate mid-rebase. Recommended:
   Option B (align with upstream's single-shared-runtime direction + transport-rebind
   guards). This is the single highest-leverage decision.
4. **Flag `tests/test_tui_gateway_server.py` to its owner** — it's an out-of-cluster
   CONFLICT that will block a clean rebase.
5. **Confirm whether our ~30 commits touched any WS gate function** (`_ws_auth_ok`,
   `_ws_host_origin_is_allowed`, `_ws_client_is_allowed`, `pty_ws`) so the
   `6717914e0` resolution is known to be mechanical.

### At PR-series time (the actual rebase)

6. Merge upstream. Resolve `server.py`'s two real conflicts:
   - Row 6: keep BOTH `_broadcast_enabled`/`_broadcast_event` (ours) and `_profile_home`
     (theirs) in the post-`_db_unavailable_error` gap.
   - Row 1: take upstream's `session.resume` body, then apply the chosen model
     (Option B: transport-rebind guards in `_live_session_payload` and `prompt.submit`).
7. Resolve `ws.py` finally block: keep both `_live_transports.discard` and
   `_schedule_ws_orphan_reap(_sid)`; preserve `_`→`_sid`.
8. Union-merge `session.create` (Row 7); verify `_make_agent` callsites are keyword-arg.
9. Rewrite the `_broadcast_event` docstring premise (`server.py:380-383`).
10. Edit the launchd wrapper (drop `--tui`); set
    `HERMES_TUI_WS_ORPHAN_REAP_GRACE_S=300` in the launchd env.
11. iOS: add shared-runtime teardown recovery (detect runtime gone → re-resume/REST
    fallback); confirm foreground reconnect resume lands inside the grace window.
12. Verify embedded chat serves without `--tui` (now unconditional) for both the iOS
    `/api/ws` path and the dashboard chat tab.
13. (Optional, non-blocking) wrap our bare `_sessions.get(sid)` reads in `with _sessions_lock:`
    to match upstream's new locking discipline.

### Deferred to Wave 2.4 (not at rebase time)

14. Adopt upstream's single-dashboard multi-profile model on iOS: `GET /api/profiles/sessions`
    rail wrapper, optional `profile` on `SessionSummary` and on create/resume/PATCH/DELETE,
    switcher kept client-side over one connection. If/when we go multi-profile, add `profile`
    alongside `stored_session_id` in `_broadcast_event`.
