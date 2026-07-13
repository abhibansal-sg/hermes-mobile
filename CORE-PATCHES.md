# CORE-PATCHES.md — Fork Deviations Ledger (single source of truth)

> **Purpose (Abhi mandate 2026-07-13):** every deliberate deviation of this
> fork's CORE from upstream NousResearch/hermes-agent, in ONE durable file,
> so an upstream version update can re-apply (or retire) each patch
> consciously instead of discovering divergence by breakage.
>
> **Rules:**
> 1. Any commit that touches core (not `apps/ios/`, not plugins, not skills)
>    for fork-specific reasons MUST add a row here in the same PR.
> 2. Each entry records: what, where, why, upstream status. When upstream
>    merges an equivalent, flip status to `UPSTREAMED` — the patch retires
>    at the next catch-up rebase.
> 3. Upstream catch-up procedure: for each ACTIVE row, `git log -S` the
>    symbol on the new upstream base; re-apply only rows upstream still
>    lacks. This file is the checklist.
> 4. iOS app (`apps/ios/`) is fork-native surface, NOT a core deviation —
>    it is not tracked here. Vendored-plugin copies (e.g. factory's
>    decomposer fork) are tracked in their own repos' provenance headers.

| # | Patch | Core files | Why | Landed | Upstream status |
|---|-------|-----------|-----|--------|-----------------|
| 1 | Notification session ownership (cross-session leak fix) | `tools/process_registry.py` (drain_notifications ownership for ALL event types), `tui_gateway/server.py` (poller positive-ownership gate, shutdown drain, ownerless never injected), `tests/test_tui_gateway_server.py` | Multi-session dashboard leaked background-process completions to the busiest session (upstream #35652 residual drain path; 6 live hits 2026-07-12) | `adbf0753c` / merge `ced8f18b1` | **PR #63317 open** (MERGEABLE). On merge → UPSTREAMED |
| 2 | `create_blocked_task(..., block_kind, reason)` | `hermes_cli/kanban_db.py` (+tests) | Recipe human-gates/event-waits need atomic insert-as-sticky-blocked; create-ready-then-block is a dispatch race (factory spec §17.14.2, terra round-3 finding #5) | `389b33fec1bf15b67c773dd092a8b858a899f248` | Upstream candidate after factory proves it |
| 3 | `cancel_subtree(task_ids, keep_blocked=[])` | `hermes_cli/kanban_db.py` (+tests) | Recipe cancellation needs leaf-first archive without per-task recompute_ready; archived parents satisfy dependents (kanban_db.py:3284) so non-atomic cancel transiently RELEASES downstream work (terra round-3 finding #2) | `389b33fec1bf15b67c773dd092a8b858a899f248` | Upstream candidate after factory proves it |

## Historical core patches already retired/absorbed

- `verify.sh --changed` tier-1 gate (`scripts/verify.sh`, commit 8a8875f61):
  fork CI tooling, not agent core; listed for completeness. Unlanded on
  base — rides next fork housekeeping merge.

## Related ledgers (NOT core, tracked elsewhere)

- Paperclip vendor-skill patches (node_modules, npm-upgrade-fragile):
  `~/Developer/products/hermes-loop/docs/paperclip-local-patches.md`
- Factory plugin provenance (PC MIT harvest + vendored decomposer fork):
  `~/Developer/products/hermes-factory/docs/harvest-map.md`
- iOS app conventions/tickets: ABH Linear + `apps/ios/` inline comments.
