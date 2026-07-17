# Local-First Transcript Spec — Pro Review Reconciliation

**Date:** 2026-07-17
**Repository baseline:** `ac84fe41ec7c3703de04c0c30a7ec2153280643e`
**Decision:** Accept the review's `NO-GO` for implementation authorization of
the prior draft. Preserve the locked product direction and amend only the
integrity contracts required to remove that verdict.

## 1. Source-verification summary

The principal findings reproduce against the audited source:

- `hermes_state.py` compaction archives active rows and inserts new active rows
  with new database IDs. The current row flags do not establish stable display
  lineage across compaction generations.
- `plugins/hermes-mobile/transcript_sync.py` receives an already-materialized
  active transcript, pages it in Python, and proves only that the cursor row and
  prefix at-or-before the cursor remain unchanged. A suffix rewind after the
  cursor can therefore evade the proof.
- `plugins/hermes-mobile/sync_manifest.py` uses one `next_cursor` as both page
  continuation and future delta-resume state, repeats runtime/attention blocks
  on every page, retains cursors for 30 days, and reads private `SessionDB._conn`
  and `tui_gateway.server._sessions` state.
- `SyncCoordinator` accumulates the complete manifest chain in memory before
  applying it. `CacheStore.applyManifest` deletes explicit tombstones but does
  not purge rows absent from a same-authority reset snapshot, and it does not
  retain durable tombstone dominance after deleting the entity row.
- `WorkRepository` and the reconstructible GRDB cache are separate SQLite
  databases. The current Work record has no authoritative turn ID/entity
  revision stage between `accepted` and `completed`.
- `prompt_receipts.py` retains receipts for 30 days and fingerprints session,
  text, and truncate ordinal, but not ordered attachment identity/version.
- `AttachmentBlobCache` has a 256 MiB shared capacity, a 30-day TTL, a
  path/session-based key, and no thumbnail/original or pinned class.
- Current upload storage returns an absolute path and prunes by age/count without
  committed-reference awareness.
- Current cache scope derives gateway identity from the URL and profile identity
  from a name-like string. Neither proves authoritative database continuity.

Statements about a separately deployed daily-driver plugin remain local
evidence until the capability-parity gate queries that deployment.

## 2. Finding-by-finding disposition

| ID | Disposition | Reconciliation |
|---|---|---|
| F1 | **Accept** | Stable display lineage is a hard prerequisite. `turn_projection: 1` cannot be advertised until public row metadata or a bounded public display API proves one display origin or explicit no-display classification for every row across compaction, replacement, and rewind. |
| F2 | **Accept, resolve conservatively** | The scalar user-message fields are removed. `turn_input_v1` preserves every committed user row in ordinal order. B1 must still prove how prompt, steering, interrupt-and-replace, and queued follow-up map to authoritative turns. |
| F3 | **Accept with authority clarification** | Add a plugin-owned, reconstructible compact projection index under `HERMES_HOME`. It is a bounded read model derived from authoritative SessionDB/lifecycle state, never a second authority. HTTP requests never synchronously scan unbounded history. |
| F4 | **Accept** | Add a per-session `display_revision` advanced atomically by every display-affecting append/rewrite/rewind/compaction/delete operation. Row head/count fields remain optimization hints, not delta authorization. |
| F5 | **Accept** | New authoritative turns require a durable turn ledger with acceptance time, terminal state/time, and nullable terminal message ID. Historical final/timing values remain null unless structurally proven. |
| F6 | **Accept** | Freeze append-stable group identity from turn ID, grouping version, category, and first operation ID. Grouping changes increment projection version and reset reconstructible groups. |
| F7 | **Accept** | Split transient `continuation_cursor` from durable `resume_cursor`; only the latter is persisted with the final atomic apply. Both are bound to scope, authority epoch, revision, snapshot, filters, and page-size contract. |
| F8 | **Accept with profile scoping** | `LOCAL-FIRST-A0-AUTHORITY-EPOCH-CONTRACT.md` freezes an installation-root gateway ID, stable metadata-backed profile ID, and one `state_meta`-backed `authority_epoch` per concrete profile database. An epoch change detaches only that profile's old projections as recovered local copies and quarantines its pending work. Aggregate manifests carry an immutable profile→epoch map. |
| F9 | **Accept and add journal identity** | The A0 contract separates authority identity from a plugin-owned `journal_epoch`. Rebuilding only the manifest journal changes that epoch and replaces reconstructible state without quarantining work. Profile authority replacement preserves prior local history read-only and quarantines only the affected profile's work. |
| F10 | **Accept** | Add durable scoped projection tombstones. Every delayed manifest, turn, asset, and live apply checks their revision before upsert. |
| F11 | **Accept** | Put non-paginated auxiliary state on the final page only; add page/entity/byte/time/cursor-cycle caps; stage validated pages in GRDB and publish once via a final transaction. |
| F12 | **Accept** | Persisted authority revision and volatile runtime sequence are separate domains. Runtime snapshots/events carry runtime instance and binding epoch and can never reverse terminal committed state or a tombstone. |
| F13 | **Accept** | Detail page chains bind to authority epoch, turn, detail revision, filter, and page size. Revision change returns an explicit reset. Client publication is guarded by scene/session/turn generation. |
| F14 | **Accept** | Add hard initial per-scene budgets: 500 headers, 2 MiB per operation, 8 MiB total detail, two expanded groups, one active page request per expansion. Raw detail is excluded from persistence, URL cache, logs, analytics, and crash breadcrumbs. |
| F15 | **Accept** | Replace the impossible cross-database rekey transaction with an `accepted_awaiting_projection` convergence stage in WorkRepository. Pending UI remains a Work overlay until GRDB contains the same scoped `client_message_id`. |
| F16 | **Accept** | Fingerprint ordered asset ID/version/role plus scope, destination, and payload. Every operation has an expiry; receipt retention exceeds maximum automatic retry life plus safety window; expired ambiguous work is never automatically resent. |
| F17 | **Accept** | Rename mutation CAS input to `base_entity_revision`; include authority epoch. Manifest revision remains a sync cursor, never an entity compare-and-swap value. |
| F18 | **Accept** | Freeze pending-overlay precedence. Pending delete hides despite server upserts until accepted/conflict/rejected. Approval/clarification work carries request revision and expiry and is not sent after expiry. |
| F19 | **Accept integrity goal; modify mechanism** | Asset ID denotes an immutable asset record and committed links fix asset ID/version. A literal transaction across SessionDB and plugin-owned receipt/asset databases is not available to an external plugin. Instead, receipt reservation and pending asset references commit together in the plugin registry before core submission; pending, accepted, and indeterminate references are GC roots; the public authoritative turn ledger carrying `client_message_id` converges them to committed associations idempotently. `/associate` is recovery-only. |
| F20 | **Accept** | Historical asset authorization uses authenticated scope plus durable association, not live runtime ownership. Resume uses exact ETag/`If-Range`; GC requires no committed or pending reference, a tombstone, and grace. |
| F21 | **Accept** | Extend the existing blob-cache metadata with asset/version, blob class, and pin state. The 1 GiB/30-day policy applies only to unpinned originals; thumbnails and pinned originals are reported separately. |
| F22 | **Accept** | New capabilities fail closed unless public prerequisites exist. Add static/runtime tests forbidding `_conn`, `_sessions`, `WSTransport`, and private send-loop access for the new surfaces, plus byte-stability tests for model prompt/history. |
| F23 | **Accept with transition rule** | Use server-issued gateway/profile IDs and a profile-scoped authority epoch. Until stable profile IDs exist, bind the profile name to its epoch and do not auto-merge renamed/recreated profiles or URL aliases. |
| F24 | **Accept** | Freeze the old/new compatibility matrix, projection coverage record, rollback window, and legacy route/field support. Legacy raw rows are not removed until the minimum rollback-supported app reads compact projections. |
| F25 | **Accept** | Reorder and split the implementation plan: A0 freezes authority identity; A1 freezes full manifest semantics; A3 is payload shaping only; B1 is a proof gate; B2 separates projection/backfill from HTTP; asset work separates identity/convergence from reads/thumbnail/GC; each mutation ships client and receipt contract together. |

No Pro integrity finding is rejected. F2, F3, F19, and F23 use narrower or
different mechanisms in the governing spec so they cannot be misread as
permission to invent turn grouping, create a second authority, assume an
impossible cross-database transaction, or merge locator aliases.

## 3. Revised authorization gates

Implementation beyond isolated foundation repair remains blocked until:

1. Display lineage and authoritative turn boundaries pass real SessionDB golden
   fixtures, including two compactions, rewind, replacement, steering, queued
   follow-up, interruption, and a tool-heavy turn.
2. Gateway installation ID, authority epoch, stable/transitional profile
   identity, and per-session display revision are frozen.
3. Manifest journal epoch, continuation/resume cursor roles, reset semantics,
   staged atomic apply, page caps, and durable tombstones are contract-tested
   Python-to-Swift.
4. The WorkRepository-to-GRDB convergence protocol and receipt lifetime are
   frozen.
5. Asset ID/version/association convergence and reference-aware GC are frozen.
6. The deployment matrix and rollback-support window are documented and tested.
7. The actual daily-driver plugin commit and capability set are reported by the
   parity gate.

## 4. Result

The prior draft's implementation verdict remains **NO-GO**. The revised
governing spec incorporates every accepted correction. Its next review should
therefore judge whether the newly explicit proof gates and contracts are
complete—not revisit the locked local-first product direction.

## 5. Implementation record

- A0/A1 now provide stable gateway/profile authority identity, authority epoch,
  journal identity, distinct continuation/resume cursors, and the real
  Python-to-Swift manifest contract.
- A2 now stages and atomically applies authority-keyed manifest pages with hard
  caps, durable tombstones, same-authority reset, authority replacement, and
  WorkRepository quarantine.
- A3/A4 now restore skeleton payload shaping and snapshot-derived running state.
- The first B1 prerequisite is implemented in SessionDB schema v22. See
  `LOCAL-FIRST-B1-DISPLAY-LINEAGE-CONTRACT.md`. Stable display origins now
  survive compaction, rewind, restore, and replacement through bounded public
  APIs. Already-compacted legacy histories fail closed rather than being
  guessed.

The remaining B1 blocker is the durable authoritative turn ledger and its real
prompt/steer/queued/interrupt/terminal fixtures. Compact projection capability
remains disabled until that proof passes.
