# Critical User Journeys (CUJ) — the app's "must always work" catalog

**This file is the contract for staging smoke coverage.** Layer 3 of the test
pyramid: unit tests catch logic (layer 1), per-fix regression tests catch
recurrence (layer 2), THIS catalog catches "a user can no longer do a core
thing" (layer 3), the soak catches systemic decay under abuse (layer 4),
TestFlight + Abhi catch taste (layer 5).

## Rules (build practice, locked 2026-07-03)

1. **Every shipped feature that adds a user-facing capability MUST add or amend
   a CUJ entry in the same PR.** The reviewer's craft checklist includes this.
   No entry → the feature is invisible to the smoke gate → review FAIL.
2. Each CUJ has a **machine-checkable smoke** (REST/WS against the staging
   gateway) — cheap (<30s each), deterministic, evidence-producing. UI-only
   journeys (pure SwiftUI behavior) are marked `smoke: ios-sim` and covered by
   the iOS test suite instead — the smoke runner skips them but counts them.
3. The soak beat runs the FULL catalog first (breadth), THEN its abuse suites
   (depth). A CUJ failure = DO-NOT-SHIP, same as an abuse failure.
4. Keep it honest-sized: a CUJ is a JOURNEY (user intent), not an endpoint.
   Target ≤20 entries; consolidate rather than sprawl.

## Catalog (v1 — derived from shipped surface as of build 58)

| id | journey | smoke | added by |
|----|---------|-------|----------|
| CUJ-01 | Pair a device and get an authed session | `POST /api/devices/issue` + authed `/api/status` | core |
| CUJ-02 | Send a prompt, receive a completed reply | REST session create → prompt → completion | core |
| CUJ-03 | Reconnect mid-turn without losing the reply | WS flap + reconcile (ABH-276/278/288/289) | Malacca |
| CUJ-04 | Approve/deny a pending approval from the phone | `/api/approvals/respond` contract (ABH-258 ownership) | core |
| CUJ-05 | Sessions list, search, resume | `/api/sessions/search` + resume + messages readback | core |
| CUJ-06 | Enable relay push + pair + truthful test-push | `/relay/config` → `/relay/pair` → `/relay/test-push` → `/relay/status` truthfulness (ABH-282/283/284/285, ABH-213) | wave-68 |
| CUJ-07 | Device tokens: register, list, revoke (scope-gated) | `/push/register`, `/api/devices`, DELETE + approve-scope 403 (ABH-275, ABH-270) | push lineage |
| CUJ-08 | Provider list + key entry (no key leak in response) | `/api/providers` + `/providers/{slug}/key` write→readback redacted | provider mgmt |
| CUJ-09 | Cron jobs: list + delivery-failure surfaced | cron surface + lastError contract (#85) | cron |
| CUJ-10 | File attach/upload → agent sees it | `/api/upload` + fs/read contract | share/capture |
| CUJ-11 | Kanban/agents visibility (active agents view) | `/api/agents` shape sanity | ops surface |
| CUJ-12 | Slash-command launcher lists real commands | slash-commands route (#104, ABH-228) | build 58 |
| CUJ-13 | Learning Journey read surface loads | learning.frames/detail (ABH-246) | build 56 |
| CUJ-14 | Credits/billing view loads (view-only) | credits surface (ABH-237) | build 56 |
| CUJ-15 | Manual context compress action | compress route (ABH-222) | build 55 |
| CUJ-16 | YOLO/flow-state approval-bypass toggle honored | toggle write + approval behavior contract (ABH-227) | build 55 |
| CUJ-17 | Device-limit 409 surfaced without composer lock | `/api/devices/issue` at limit → 409 contract (ABH-254) | fix lineage |
| CUJ-18 | Debug share bundle from settings | `/api/debug-share` produces a bundle (#90) | support |

`smoke: ios-sim` (covered by iOS test suite, skipped by gateway smoke): stale
'Connection lost' warning clears on clean resume (ABH-289 tests), per-event
push toggles gate local notifications (ABH-269), share-extension inbox drain
toast (ABH-277).

## Maintenance

- Refiner: when promoting a feature, note which CUJ it lands in (or that it
  adds one). Orchestrator: the engineer card for a user-facing feature includes
  "add/amend CUJ entry + smoke" in SCOPE.
- The soak beat reads this file every run; entries it cannot smoke (route gone,
  contract changed) are DO-NOT-SHIP evidence — the catalog IS the contract.
