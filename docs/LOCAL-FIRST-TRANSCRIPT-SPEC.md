# Hermes Mobile — Local-First Transcript and Asset Integrity

**Status:** Product direction confirmed; implementation underway behind versioned capability gates
**Date:** 2026-07-17
**Scope:** iOS app and external `hermes-mobile` gateway plugin
**Implementation state:** Authority identity, manifest v2, display lineage, durable turn ledger, compact GRDB projection, capability-gated iOS reads, bounded historical backfill, and stable upload/receipt asset identity are implemented; memory-only detail, permanent asset rendering/cache migration, generalized mutations, and rollout evidence remain

## 1. Outcome

Hermes Mobile should open and switch conversations at local-database speed while
remaining an honest, strongly reconciled replica of the Hermes gateway.

The permanent mobile transcript contains:

- every committed user message;
- every committed final assistant response;
- a compact, structured work envelope for each turn;
- safe aggregated operation summaries;
- stable attachment descriptors and lightweight thumbnails; and
- enough revision metadata to prove whether the projection is fresh, stale, or
  awaiting reconciliation.

Raw tool arguments, raw tool results, terminal output, and expanded
user-visible reasoning are not part of the permanent mobile transcript. They
exist in memory while the relevant session is open and are fetched again when
the user reopens or expands that turn.

The gateway remains authoritative. Mobile is a durable read replica plus a
durable mutation outbox, not an automatic backup-restoration system.

### North-star interaction

1. Launch paints the cached drawer and last conversation without waiting for a
   network request.
2. Selecting a cached session reads only its newest compact turns from SQLite.
3. An active turn immediately shows truthful running state and its compact live
   activity.
4. Tapping “Worked for 7m 53s” fetches deep detail on demand.
5. Leaving the session clears deep detail from memory.
6. Server changes reconcile through revisions and tombstones without silently
   resurrecting deleted data.
7. Attachments render through stable asset IDs, never through server-local file
   paths.

## 2. Locked product decisions

1. **Authority:** the gateway database is authoritative.
2. **Gateway loss:** cached mobile history is not automatically uploaded to
   recreate a lost gateway. It remains readable/exportable and requires an
   explicit future restore workflow.
3. **Scope identity:** multiple gateway and profile cache partitions may coexist
   on one device. Every durable key includes server-issued gateway installation,
   concrete profile, that profile database's authority epoch, and session scope.
   A URL is a locator, not an authority identity.
4. **Committed content:** previously committed user and assistant message bodies
   are immutable in version one.
5. **Deep detail:** raw turn detail is memory-only. It is discarded on session
   navigation, app termination, memory pressure, or explicit collapse/cleanup
   policy and is fetched again when needed.
6. **Thumbnails:** lightweight thumbnails remain until their associated
   message, asset, session, profile, or gateway partition is deleted.
7. **Downloaded originals:** mobile originals use a 30-day or 1 GB LRU policy,
   whichever limit is reached first.
8. **Offline retention:** a future WhatsApp-style download setting controls
   automatic download by network and media type. A future “Keep Downloaded”
   action exempts selected assets from automatic eviction.
9. **Summarization:** the integrity-critical compact projection is generated
   deterministically from structured data. An auxiliary model may later improve
   live wording, but its output is presentation-only and never the source of
   transcript truth.

## 3. Verified current state

This section distinguishes observed source/deployment facts from design
inference.

### 3.1 Foundations worth keeping

- Cache schema v5 has scope-qualified session and message identities.
- GRDB, WAL, FTS5, and cache-first drawer/transcript paths already exist.
- `WorkRepository` provides protected durable jobs, drafts, assets, leases, and
  cross-process state.
- `OutboxProcessor` provides staged prompt delivery with stable
  `client_message_id` receipts and ambiguous-delivery recovery.
- `AttachmentBlobCache` already provides content-versioned keys, downsampling,
  memory and disk caps, TTL, per-scope purge, and maintenance.
- The plugin already exposes transcript paging/delta primitives and attachment
  download with ETags.
- Current upstream gateway responses now expose running status and in-flight
  information on session resume/active-list paths.

These components should be extended, not replaced.

### 3.2 Confirmed integration failures

1. The iOS manifest client requests
   `/api/plugins/hermes-mobile/sync-manifest`; the plugin exposes
   `/api/plugins/hermes-mobile/sync/manifest`.
2. The Swift and Python manifest response models are structurally incompatible.
3. `SyncCoordinator` is present but is not constructed by the production app
   graph. Production invalidation currently falls back to a session-list
   refresh.
4. Manifest client and server tests validate independent fixtures, allowing two
   incompatible contracts to pass.
5. `shape=skeleton` was previously merged but current iOS transcript calls no
   longer send it.
6. Cached session opening still decodes all cached message rows before taking a
   suffix window.
7. The reconstructible cache stores complete raw messages, including reasoning,
   tool arguments, and tool results.
8. `turnsInProgress` is primarily an in-memory edge-event set. Root-level
   resume/active-list running state is not fully consumed, allowing the drawer
   and reopened transcript to appear idle until another event arrives.
9. Upload responses expose an absolute server path. Persisted transcript text
   encodes that path as a hint rather than referencing a stable asset entity.
10. **Team-observed local deployment evidence, not independently verified:** the
    active daily-driver plugin checkout does not expose the current manifest and
    pending-attention routes, so a compatible app cannot use those capabilities
    today.

### 3.3 Important inference

The current glitches are not evidence that SQLite or local-first rendering is
the wrong direction. They result from storing and decoding the wrong unit of
data, losing previously merged paging behavior, and allowing independently
tested cross-surface contracts to drift.

## 4. Scope and non-goals

### 4.1 In scope

- Repair the current manifest and live-session truth contracts.
- Replace permanent raw-message storage with a compact durable turn projection.
- Make session opening and switching proportional to the displayed turn window,
  not total transcript length.
- Provide memory-only on-demand deep detail.
- Introduce stable gateway asset identities and durable message associations.
- Reconcile server mutations through revisions, conditional requests, receipts,
  and tombstones.
- Extend the existing durable outbox to remaining supported mobile mutations.
- Provide deployment compatibility and end-to-end contract tests.
- Preserve Hermes prompt caching: no projection, status, attachment, or sync
  metadata may mutate the system prompt or prior model context.

### 4.2 Non-goals

- Multi-user tenancy or collaborative conflict resolution.
- Automatic mobile-to-gateway disaster restoration.
- Editing committed historical message bodies.
- Persisting hidden chain-of-thought or raw provider reasoning.
- Keeping a WebSocket alive continuously in the iOS background.
- CloudKit as transcript authority or transport.
- Replacing `WorkRepository`, `OutboxProcessor`, GRDB, or
  `AttachmentBlobCache`.
- Building the auxiliary-model live distillation feature in the integrity
  milestone.
- Redesigning every transcript visual in the same engineering change.

### 4.3 External-plugin/upstream dependency

Completed-turn projection, manifest reads, assets, and mutation receipts remain
plugin-owned and can use public gateway/database interfaces. They do not justify
mobile-specific code in Hermes core.

The generic authority metadata required for correctness—gateway installation
ID, authority epoch, per-session display revision/lineage, and durable turn
ledger fields—is an upstream public-data prerequisite when current SessionDB
cannot express it. It is not implemented through plugin access to private
connections or tables.

Real-time sibling frame delivery and authoritative connection/session lifecycle
still depend on the separately designed upstream seam:

- typed, bounded, passive lifecycle events;
- opaque connection and binding identifiers; and
- a host-owned, capability-gated authorized-sibling frame-mirroring service.

This epic must not recreate `post_emit_event`, `post_frame_write`, or
`on_ws_transport_change`, expose `WSTransport`, or let plugin callbacks block a
latency-sensitive path. Upstream contributions follow the already-recommended
small atomic PR sequence and remain independently reviewable from the iOS local
projection. Until upstream support lands, capability parity must state whether
the deployed Hermes fork supplies the required live seam.

## 5. Integrity invariants

The implementation is incorrect if any of these invariants can be violated.

1. **Scoped identity:** no row is addressed by session ID alone. Durable
   identity is `(gatewayID, profileID, authorityEpoch, storedSessionID,
   entityID)`.
2. **One authority:** gateway revisions decide committed remote truth. Local
   pending work is represented separately and never masquerades as acknowledged
   server state.
3. **Atomic apply:** one manifest revision is applied in one GRDB transaction
   and becomes observable once.
4. **Cursor-after-commit:** a cursor is persisted only in the same transaction
   that successfully applies its data.
5. **Tombstone dominance:** a tombstone at revision N dominates any upsert older
   than N. Entity-specific cascade rules remove turns, search rows, detail
   memory, widgets, navigation state, and thumbnails only when their final
   retained association is deleted. Asset unavailability does not erase a
   retained descriptor or thumbnail.
6. **No silent resurrection:** stale mobile data never recreates a deleted
   server entity automatically.
7. **Idempotent mutation:** retrying a mutation with the same operation ID has
   the same server result and cannot duplicate the change.
8. **Conditional destructive writes:** destructive or state-changing mutations
   include their known authority epoch and base entity revision. A manifest
   revision is never used as an entity compare-and-swap value. Conflicts are
   returned, not overwritten.
9. **Immutable committed bodies:** a committed message body never changes in
   place in version one.
10. **Bounded reads:** cached first paint and normal session switching never
    enumerate the full transcript.
11. **No durable raw detail:** raw tool/reasoning/terminal payloads never enter
    the permanent turn projection or FTS index.
12. **Stable asset reference:** transcript rows never depend on an absolute
    gateway filesystem path.
13. **Honest freshness:** cached data remains readable, but the UI distinguishes
    fresh, synchronizing, stale, pending mutation, and conflict states.
14. **Live-state recovery:** running state can be reconstructed from a snapshot;
    it is not dependent on having observed every edge event.
15. **Prompt-cache preservation:** projection and synchronization are downstream
    observers/read models and cannot change model input or conversation history.
16. **Monotonic authority:** provisional live state can improve immediacy but
    cannot overwrite a newer authoritative server revision. Manifest revisions
    are comparable only within one `journal_epoch`.
17. **Compaction is not deletion:** model-context compaction cannot tombstone or
    rewrite the user's permanent conversation projection. Rewind/undo remains a
    distinct user-visible history mutation.
18. **Authority epoch:** no cursor, projection, asset, or pending mutation
    crosses an authoritative database epoch automatically.
19. **Display generation:** every display-affecting SessionDB append, rewrite,
    rewind, compaction, or deletion advances the affected session's
    `display_revision`.
20. **One display origin:** every source message maps to one stable display
    origin or to an explicit synthetic/rewound no-display class.
21. **Pending-overlay precedence:** pending local mutations are separate overlays
    whose precedence over incoming server state is explicit and reversible.
22. **Cross-store convergence:** server acceptance remains durably recoverable in
    `WorkRepository` until the authoritative GRDB projection has committed.
23. **Receipt lifetime:** server idempotency evidence outlives every possible
    automatic client retry.
24. **Immutable asset reference:** a committed message association fixes both
    asset ID and content version.
25. **Bounded derivation:** an HTTP request never performs unbounded historical
    projection work. Incomplete reconstructible backfill is reported honestly.
26. **Page-chain identity:** continuation pages belong to one scope, authority
    map, journal epoch, revision, immutable snapshot, filter, and page-size
    contract.
27. **Stale-work quarantine:** gateway authority replacement cannot
    automatically deliver pending work created for the previous epoch.

## 6. Data model

### 6.1 Scope key

```text
ScopeKeyV1
- gateway_id        // server-issued installation identity; URL is only a locator
- profile_id        // server-issued stable profile identity
- authority_epoch   // this profile database's lifetime
```

Credentials and bearer tokens are not part of cache identity. Profiles are
independent authority islands: replacing one profile database changes only that
profile's epoch. A0 freezes the exact lifetimes, persistence, restore behavior,
legacy migration, and conformance tests in
`LOCAL-FIRST-A0-AUTHORITY-EPOCH-CONTRACT.md`. The stable profile ID survives a
rename; cloning/importing as new or deleting/recreating produces a new profile
ID. URL and profile name remain locator/display data and are never merged as
authority automatically.

### 6.2 Compact turn projection

Add a reconstructible projection table rather than adapting
`message_row_cache` into another all-purpose store.

```text
turn_projection_v1
- gateway_id
- authority_epoch
- profile_id
- stored_session_id
- turn_id
- client_message_id nullable
- final_content_json nullable
- final_created_at nullable
- state                 // running, completed, interrupted, failed
- accepted_at nullable
- terminal_at nullable
- terminal_message_id nullable
- elapsed_ms nullable
- timing_quality        // exact, derived, unknown
- source_head_id
- display_revision
- projection_version
- entity_revision
- journal_epoch
- manifest_revision
- updated_at
- PRIMARY KEY(gateway_id, authority_epoch, profile_id, stored_session_id, turn_id)
- UNIQUE(gateway_id, profile_id, authority_epoch, client_message_id)
  WHERE client_message_id IS NOT NULL

turn_input_v1
- gateway_id
- authority_epoch
- profile_id
- stored_session_id
- turn_id
- message_id
- ordinal
- content_json
- created_at
- input_kind            // prompt, steer, queued_follow_up, other
- client_message_id nullable
- journal_epoch
- manifest_revision
- PRIMARY KEY(..., turn_id, message_id)
```

`turn_id` is opaque to iOS. New turns use a gateway-minted identity at prompt
acceptance. Historical IDs may be derived only from stable display-origin
metadata proven by B1; active database row IDs are not stable across compaction
or replacement and cannot be used directly.

The prompt receipt returns both `client_message_id` and authoritative `turn_id`.
The optimistic turn remains a `WorkRepository` overlay and is never written as
a provisional GRDB turn. On acceptance, WorkRepository persists the receipt,
authoritative turn ID, authority epoch, and entity revision in an
`accepted_awaiting_projection` state. GRDB then idempotently upserts the
authoritative turn with its unique scoped `client_message_id`; only after that
commit does WorkRepository mark the job complete. Restart recovery repeats the
two commits, and UI suppresses the overlay whenever GRDB already contains its
`client_message_id`.

Turn boundaries are authority-defined:

1. A durable turn ledger records `turn_id`, acceptance time, terminal state,
   terminal time, and nullable terminal message ID for new turns.
2. Every committed user input associated with the turn is preserved in
   `turn_input_v1`; the schema does not assume one user row per turn.
3. Assistant rows with tool calls are intermediate even when they contain text.
4. Only the ledger's `terminal_message_id` may populate a new turn's immutable
   final response.
5. A turn without a proven terminal assistant row has no final response and is
   represented as running, interrupted, or failed from durable lifecycle state.
6. Historical grouping and terminal selection are emitted only when B1 fixtures
   prove them. Ambiguous final content and duration remain null.
7. Rewind or replacement advances `display_revision` and emits explicit turn or
   message tombstones; compaction does not change display membership.

Steered input and queued follow-up boundaries are never guessed by iOS. B1 must
prove their real gateway mapping before projection capability is enabled.
Historical fallback may treat a committed user row as a boundary only where
stable display lineage and surrounding terminal state make that mapping
unambiguous.

For new turns, duration is exact only when durable acceptance and terminal
timestamps share the same authority epoch and turn ID. Historical duration is
derived only when boundaries and timestamps are unambiguous; otherwise it is
unknown.

#### Compaction and rewind visibility

Hermes currently soft-archives pre-compaction rows (`active=0, compacted=1`) and
inserts a new active compacted context. That rewrite serves model prompt
management; it is not the user's display transcript.

The projection contract therefore requires:

- original compacted user/final turns remain visible and keep their identities;
- synthetic checkpoint/context messages do not appear as new user turns;
- retained recent rows reinserted into compacted context do not duplicate their
  original display turns;
- rewind/undo rows (`active=0, compacted=0`) produce explicit projection
  tombstones or reverted state; and
- context compaction never invalidates prompt caching through the mobile seam.

The current row flags and regenerated database IDs are insufficient to promise
that lineage. B1 is a hard proof gate. Every row must resolve to a stable
`display_origin_message_id` plus `display_generation`, or to an explicit
`synthetic_no_display` / `rewound_no_display` class. If public `SessionDB` data
cannot express that mapping, the smallest upstream prerequisite is generic
display-lineage metadata or a bounded public `get_display_messages` API. The
plugin must not infer synthetic rows from text prefixes, access private database
connections, or advertise `turn_projection: 1` before the proof passes.

`content_json` and `final_content_json` retain safe structured content
parts so text, asset references, and supported rich content do not need to be
flattened into strings.

#### Reconstructible plugin projection index

Turn-count HTTP endpoints read a plugin-owned compact projection index under
`HERMES_HOME`; they do not derive arbitrary history synchronously per request.
The index is reconstructible from authoritative SessionDB and structured
lifecycle data and never becomes an independent authority.

- New turns update the compact index incrementally.
- Historical projection runs in fixed raw-row batches with a persisted backfill
  cursor and hard source-row budget.
- Each session index checkpoint records authority epoch, display revision, and
  projection version. Lifecycle delivery is an accelerator; startup/reconnect
  compares the checkpoint to authoritative SessionDB metadata and resumes
  bounded backfill whenever they differ.
- HTTP tail/older-page requests query only the compact index.
- If requested history is not projected, the response returns bounded available
  turns with `coverage_complete=false` and `projection_pending=true`.
- A rebuild can discard this index without touching SessionDB or mobile work.

### 6.3 Work envelope

```text
turn_activity_group_v1
- gateway_id
- authority_epoch
- profile_id
- stored_session_id
- turn_id
- group_id
- ordinal
- category              // reasoning, files, shell, edit, test, web, other
- display_label
- operation_count
- state                 // running, completed, failed, interrupted
- started_at nullable
- completed_at nullable
- detail_available
- grouping_version
- journal_epoch
- manifest_revision
- PRIMARY KEY(..., turn_id, group_id)
```

The permanent group contains safe labels and counts such as:

- “Inspected 12 files”
- “Ran 8 terminal commands”
- “Updated 4 files”
- “Verified 3 test suites”

It does not contain command lines, tool arguments, raw results, terminal output,
or hidden reasoning. Adjacent compatible operations may be grouped
deterministically. The final UI label is derived from timestamps:
“Worked for 7m 53s.”

`group_id` is append-stable: a hash of `(turn_id, grouping_version, category,
first_operation_id)`. New operations may extend only the current terminal group
without rekeying it. A grouping-algorithm change increments projection version
and resets reconstructible groups rather than silently changing IDs.

Each group exposes opaque operation headers only after the group is expanded:

```text
TurnOperationHeaderV1
- operation_id
- group_id
- ordinal
- kind
- safe_label
- state
- started_at nullable
- completed_at nullable
- detail_available
```

The header still contains no raw argument/result content. It provides the middle
level of the interaction hierarchy: turn envelope → aggregated group → specific
operation → paged raw detail.

Historical turns without reliable timestamps render “Work details” without a
fabricated duration.

### 6.4 Session projection metadata

Extend the existing scope-safe session projection with:

```text
- authority_epoch
- transcript_head_id
- display_revision
- latest_turn_id
- active_turn_id nullable
- active_turn_state nullable
- entity_revision
- projection_revision
- manifest_journal_epoch
- manifest_revision
- last_server_sync_at
- freshness_state
```

The drawer reads this projection. It must not compute global live state solely
from an in-memory `Set`.

### 6.5 Asset projection

```text
asset_projection_v1
- gateway_id
- authority_epoch
- profile_id
- asset_id
- content_version
- media_type
- byte_count
- pixel_width nullable
- pixel_height nullable
- thumbnail_version nullable
- server_state          // pending, available, deleted
- local_original_state  // absent, downloaded, pinned
- last_accessed_at nullable
- downloaded_at nullable
- entity_revision
- journal_epoch
- manifest_revision
- PRIMARY KEY(gateway_id, authority_epoch, profile_id, asset_id)

message_asset_link_v1
- gateway_id
- authority_epoch
- profile_id
- stored_session_id
- turn_id
- message_id
- asset_id
- content_version
- role                   // input, output, artifact
- ordinal
- entity_revision
- journal_epoch
- manifest_revision
- PRIMARY KEY(..., message_id, asset_id, role)
```

Thumbnails are removed only when their final association is tombstoned or the
user purges that gateway/profile. Downloaded originals are subject to the
30-day/1 GB LRU unless `local_original_state == pinned`.

Asset IDs identify immutable asset records. A committed association fixes asset
ID and content version. Changed bytes create a new version and cannot mutate a
historical link.

#### Durable projection tombstones

```text
projection_tombstone_v1
- gateway_id
- authority_epoch
- profile_id
- entity_kind           // session, turn, message, asset, association
- entity_id
- entity_revision
- journal_epoch
- manifest_revision
- deleted_at
- PRIMARY KEY(gateway_id, authority_epoch, profile_id, entity_kind, entity_id)
```

Every manifest, turn, asset, live-frame, and delayed HTTP apply checks this table
before upsert. Tombstones are pruned only after a later complete snapshot proves
that replay from the dominated revision is no longer possible.

### 6.6 Deep detail memory

```text
TurnDetailSnapshotV1   // process memory only
- scene_id
- scoped_turn_id
- authority_epoch
- group_id nullable
- operation_id nullable
- source_head_id
- detail_revision
- publication_generation
- fetched_at
- visible_reasoning_status
- operations[]
- terminal_chunks[]
- error nullable
```

It is owned by the currently visible scene/session/turn. It is cleared when:

- another session becomes active;
- the owning scene is destroyed;
- the app terminates;
- memory pressure requests eviction;
- a tombstone invalidates the turn; or
- the authenticated scope changes.

No background task prefetches deep detail. No disk restoration path exists in
version one. Initial hard limits are 500 retained headers, 2 MiB decoded detail
for one operation, 8 MiB decoded detail across one scene, at most two retained
expanded groups, and one active page request per expansion. Collapsed
least-recently-viewed detail is evicted first. The process-wide decoded-detail
budget is 16 MiB across scenes, with inactive-scene data evicted first. Raw
responses are excluded from URL cache, logs, analytics, and crash breadcrumbs.

## 7. Canonical gateway contracts

All plugin responses use snake_case JSON and explicit schema versions. Swift
uses `CodingKeys`; it does not define a parallel wire shape.

### 7.1 Capability discovery

The plugin capability response advertises independent versions:

```json
{
  "sync_manifest": 2,
  "turn_projection": 1,
  "turn_detail": 1,
  "stable_assets": 1,
  "conditional_mutations": 1
}
```

Capabilities are feature-specific. The client may use the compact transcript
without assuming conditional mutation support, for example. Each capability is
advertised only when its public prerequisites are present. Compact projection
requires public bounded display-lineage access; live state and mirroring require
the typed opaque upstream seam. Loading a plugin that falls back to `_conn`,
`_sessions`, `WSTransport`, or private send-loop fields must not advertise these
capabilities.

### 7.2 Sync manifest

Freeze exactly one route:

```text
GET /api/plugins/hermes-mobile/sync/manifest
    ?scope=profile:<profile_id>|all
    &resume_cursor=<opaque_resume_cursor>
    &continuation_cursor=<opaque_page_cursor>
    &limit=<bounded_page_size>
```

The canonical response is the plugin schema, with explicit schema version and a
single immutable revision across all pages:

```json
{
  "schema_version": 2,
  "gateway_id": "gw_opaque",
  "profile_authorities": [
    {
      "profile_id": "profile_opaque",
      "profile_name": "default",
      "authority_epoch": "epoch_opaque"
    }
  ],
  "journal_epoch": "journal_opaque",
  "complete": false,
  "revision": 1842,
  "snapshot_id": "snapshot_opaque",
  "continuation_cursor": "opaque-or-null",
  "resume_cursor": null,
  "reset": false,
  "reset_reason": null,
  "server_time": 1784101200,
  "sessions": {"upserts": [], "tombstones": []},
  "runtime_snapshot": null,
  "pending_attention": null,
  "transcript_heads": null,
  "widget_summary": null,
  "push_registry": null
}
```

Rules:

- all pages carry the same gateway ID, immutable profile-authority map, journal
  epoch, revision, snapshot ID, schema, filters, and page-size contract;
- a concrete-profile response contains exactly one profile-authority pair. An
  `all` response carries one pair per concrete profile, and every entity names
  the matching profile ID and epoch;
- `continuation_cursor` is non-null only when `complete=false`; it is transient
  and is never persisted as authority state. It is bound to the journal epoch,
  profile-authority map, revision, snapshot, scope, visibility, filters, and page
  size;
- `resume_cursor` is non-null only when `complete=true`; it is persisted only in
  the final GRDB apply transaction and is bound to the same identity domains;
- non-paginated pending-attention, runtime, head, widget, and push blocks are
  absent from continuation pages and appear once on the complete final page;
- the persisted `revision` governs persisted entities only. The runtime block
  carries its own runtime instance, binding epoch, sequence, and capture time;
- manifest revisions are ordered only within `(gateway_id, journal_epoch,
  scope, visibility)`. Rebuilding the plugin journal changes `journal_epoch`
  without changing any profile authority epoch;
- every mutable entity upsert and tombstone carries its own `entity_revision`
  for conditional writes; the manifest `revision` remains only the sync-journal
  position;
- the client rejects repeated cursors and enforces hard total page, entity,
  encoded-byte, and elapsed-time limits;
- each page validates into non-observable GRDB staging rows under `snapshot_id`;
  one final transaction replaces/applies the revision, persists the resume
  cursor, and makes it observable once. Cancellation or error deletes staging;
- a changed journal epoch with an unchanged profile-authority map returns a
  complete `reset=true` snapshot with `reset_reason=journal_rebuilt`. It
  atomically clears every reconstructible row for the selected current profile
  epochs, applies the snapshot, and persists its cursor, but never deletes or
  quarantines `WorkRepository` work;
- a same-journal-epoch reset caused by delta expiry follows the same complete
  snapshot replacement rule;
- an authority-epoch change is not a reset: only the affected profile's old
  partition becomes a read-only recovered local copy, its new partition is
  seeded, and its prior pending work is quarantined;
- `reset_reason` is stable and mandatory when reset is true;
- the journal retains at least 90 days of deltas before requiring reset;
- missing capability falls back honestly and cannot claim manifest freshness;
- manifest schema/capability 1 remains the incompatible legacy contract. The
  reconciled client requires exact `sync_manifest >= 2` and never decodes v1 as
  v2;
- every response model is tested from a fixture serialized by the real Python
  router and decoded by the real Swift model, including multipage, reset, and
  malformed-chain fixtures.

### 7.3 Compact turn page/delta

```text
GET /api/plugins/hermes-mobile/sessions/{stored_session_id}/turns
    ?profile=<profile_id>
    &before=<opaque_turn_cursor>
    &after_display_revision=<known_display_revision>
    &limit=<turn_count>
```

Response:

```json
{
  "schema_version": 1,
  "projection_version": 1,
  "gateway_id": "gw_opaque",
  "authority_epoch": "epoch_opaque",
  "stored_session_id": "opaque",
  "source_head_id": 9821,
  "display_revision": 93,
  "reset": false,
  "coverage_complete": true,
  "projection_pending": false,
  "turns": [],
  "tombstones": [],
  "previous_cursor": "opaque-or-null",
  "has_older": true
}
```

Rules:

- `limit` counts turns, not raw message rows;
- returned turns are complete boundary-aligned projections;
- normal tail and older-page fetches read the reconstructible compact plugin
  index with bounded SQL work;
- HTTP request handling never scans an unbounded raw history. Historical
  backfill runs separately in fixed batches and incomplete coverage is explicit;
- every display-affecting append, replacement, rewind, compaction, or deletion
  advances `display_revision` in the authority transaction;
- a cursor revision mismatch returns `reset: true`; source head and row counts
  may optimize checks but cannot authorize a delta;
- no response contains raw tool arguments/results or hidden provider reasoning;
- a fresh-install tail request returns already-projected turns and honest
  coverage state; it never materializes the complete transcript;
- projection/backfill uses only public SessionDB/display-lineage APIs. The
  plugin never accesses a private database connection.

### 7.4 Deep turn detail

```text
GET /api/plugins/hermes-mobile/sessions/{stored_session_id}/turns/{turn_id}/operations
    ?profile=<profile_id>&group_id=<opaque>&cursor=<opaque>&limit=<bounded>

GET /api/plugins/hermes-mobile/sessions/{stored_session_id}/turns/{turn_id}/operations/{operation_id}/detail
    ?profile=<profile_id>&cursor=<opaque>&limit=<bounded>
```

The first route returns safe `TurnOperationHeaderV1` pages for one expanded
group. The second returns bounded chunks of user-visible detail for one selected
operation. Neither endpoint materializes an entire tool-heavy turn. Both carry
`source_head_id`, `detail_revision`, `next_cursor`, and an ETag. Every cursor is
bound to authority epoch, stored session, turn, detail revision, group/operation
filter, and page size. If live data changes during a chain, the server returns
`409 detail_revision_changed` with `reset=true`; the client discards the chain
and restarts rather than merging drifting pages.

Authorization is checked against the scoped session and current operation
visibility on every request. Responses never include hidden provider reasoning
or secrets removed by the gateway's existing redaction policy.

The iOS request uses an ephemeral session and stores the decoded response only
in `TurnDetailSnapshotV1`. HTTP or URL cache persistence is disabled for this
route. A navigation cancellation cancels the task and discards partial state.
Every request captures a scene/session/turn publication generation and may
publish only while that generation still matches.

Offline behavior is explicit: the compact turn remains readable and expansion
shows “Connect to load work details.” No global transcript loader appears.

### 7.5 Stable assets

```text
POST /api/plugins/hermes-mobile/assets
GET  /api/plugins/hermes-mobile/assets/{asset_id}
GET  /api/plugins/hermes-mobile/assets/{asset_id}/thumbnail
POST /api/plugins/hermes-mobile/assets/{asset_id}/associate
```

The upload response contains an opaque `asset_id`, `content_version`, metadata,
and authenticated download URLs or route templates. It never returns an
absolute filesystem path as transcript identity.

The plugin maintains a plugin-owned asset registry and associations. Canonical
server originals remain available while referenced by a committed message. The
current unconditional seven-day upload-directory pruning cannot delete
referenced assets. A future explicit administrative purge must make the asset
unavailable through an authoritative revision/tombstone; it cannot leave a
silently broken reference.

Asset ID names one immutable record, and every committed reference includes its
content version. Prompt submission carries ordered `(asset_id,
content_version, role)` references.

SessionDB and plugin-owned receipt/asset state are separate databases, so this
external plugin does not claim a cross-database transaction. Instead:

1. Receipt reservation and pending asset references commit together in one
   plugin-registry transaction before core prompt submission. The existing
   receipt provider is migrated/extended behind its public provider interface so
   receipts and reference roots share that SQLite transaction.
2. Pending, accepted, and indeterminate references are GC roots.
3. Core persists the authoritative turn with `client_message_id`, `turn_id`,
   terminal metadata, and committed content through its public turn ledger.
4. The plugin idempotently converges the receipt and pending references to
   committed message associations from that public ledger.
5. A crash at any boundary leaves a durable pending/indeterminate root that can
   be reconciled without re-executing an accepted prompt.

`/associate` is only an idempotent recovery route using the same operation ID.

Download supports ETag and range requests. Resume uses `If-Range` with the exact
ETag; version mismatch returns a complete `200`, never an incompatible partial
range. Authorization is based on authenticated gateway/profile scope plus a
durable committed association to a visible session, not a live runtime binding.
Generated artifacts are imported only after allowlisted path resolution and
become normal stable assets.

Server garbage collection requires zero committed associations, zero pending or
ambiguous receipt references, an authoritative asset/link tombstone, and an
elapsed retention grace. Eligibility is rechecked transactionally immediately
before deletion. Explicit administrative purge emits an authoritative
asset-unavailable tombstone. That tombstone sets `server_state=deleted` and
blocks stale byte resurrection but does not delete a retained message link,
descriptor, or local thumbnail; those follow association lifetime.

Rejected/cancelled operations release pending references after their retention
grace. An accepted or indeterminate operation without a proven association
remains a GC root until public authority reconciliation resolves it; storage may
surface an integrity warning but must not guess that the reference is orphaned.

### 7.6 Conditional mutations

Each supported mutation accepts:

```json
{
  "operation_id": "client-generated-uuid",
  "authority_epoch": "epoch_opaque",
  "base_entity_revision": 1842,
  "operation_expires_at": 1784104800,
  "payload": {}
}
```

The server returns one of:

- `accepted` with authoritative entity revision;
- the previously accepted receipt for the same operation ID;
- `conflict` with current revision and safe current state;
- `rejected` with a stable reason code.

The operation fingerprint includes authority/profile scope, destination,
payload, and ordered asset ID/content-version/role references. Server receipt
retention extends beyond `operation_expires_at` plus a documented safety window.
An ambiguous operation beyond expiry is never automatically resent.

Initial automatic-retry lifetimes are normative:

| Operation | Automatic retry expiry | State after expiry |
|---|---:|---|
| Direct prompt | 30 days from creation | Manual review; local source retained |
| Share prompt | 14 days from creation | Expired; local job remains user-removable |
| App Intent prompt | 24 hours from creation | Expired |
| Rename/archive/delete | 30 days from creation | Manual review against current authority |
| Approval/clarification | Server request expiry | Query authority; resolved elsewhere or expired |

The server retains each receipt until at least 30 days after its operation
expiry. A retained manual-review job can be deliberately resubmitted only as a
new operation with a new ID after showing current authority to the user.

Pending local state has explicit overlay precedence. A pending delete remains
hidden despite server upserts until accepted, conflicted, or rejected. Approval
and clarification jobs carry request ID, request entity revision, and expiry;
expired jobs query current authority and finish as expired or resolved elsewhere
without sending the stale response.

Version-one outbox coverage:

- prompt submit, including attachments;
- session rename;
- session archive/unarchive;
- session delete;
- approval response; and
- clarification response.

Committed message editing is absent by design.

## 8. iOS read and live-update architecture

### 8.1 Launch

1. Open GRDB and `WorkRepository`.
2. Paint cached scope/session projections immediately.
3. Paint only the newest compact turn window for the last-opened session.
4. Resolve credentials and begin WebSocket plus manifest recovery concurrently.
5. Apply manifest pages atomically.
6. Fetch a compact turn delta only when its transcript head differs.
7. Reconcile pending outbox work.
8. Begin low-priority prefetch only after the UI is interactive; never prefetch
   deep turn detail.

### 8.2 Session switching

On selection:

1. Cancel detail work owned by the previous session.
2. Clear its `TurnDetailSnapshotV1` values.
3. Query the newest 20–30 `turn_projection_v1` rows directly with SQL `LIMIT`.
4. Publish the compact transcript immediately.
5. Bind/resume the runtime session in parallel.
6. Decode root-level `running`, `status`, and `inflight` fields.
7. Reconcile the compact delta if the head changed.
8. Load older compact turns only when scroll position requests them.

No step enumerates every cached row. Lazy-load state is scoped to the selected
session and resets on session change.

### 8.3 Live turn reducer

One scoped reducer combines:

- local pending prompt state from `WorkRepository`;
- session resume snapshot;
- a volatile runtime snapshot;
- ordered JSON-RPC frames; and
- compact projection delta/finalization.

Edge events update responsiveness; snapshots restore truth. A session remains
visibly running across navigation even when no new tool event arrives.

The reducer persists only compact state:

- turn state and timestamps;
- user/final content;
- activity category, label, count, and result state;
- asset associations; and
- source/revision metadata.

Raw event payloads feed the visible in-memory detail only when that session is
open.

Provisional live updates and authoritative sync use separate merge ranks. A
frame may advance the provisional head, but only a server revision can replace
authoritative committed content or clear a server tombstone.

Persisted and runtime revision domains are separate. The runtime snapshot and
every live event carry:

```text
- runtime_instance_id
- connection_binding_epoch
- runtime_session_id
- turn_id nullable
- runtime_sequence
- captured_at
```

The reducer accepts provisional state only from the current runtime instance and
binding epoch. A committed terminal state or durable tombstone cannot be moved
back to running by an older runtime snapshot or delayed frame.

### 8.4 Compact and expanded UI

Default completed turn:

```text
[User message and thumbnail attachments]

Worked for 7m 53s                         >
[Final assistant response]
```

First expansion shows safe persistent activity groups. Expanding a group
fetches paged operation headers. Expanding an individual operation fetches only
that operation's paged detail and presents a local inline loading state.
Navigation away returns the session to compact mode and releases all headers
and deep detail for that scene/session.

No black global “Syncing” box is permitted. Connection and synchronization use
one status treatment:

- self-healing work inside the grace period is silent;
- cached content remains interactive;
- after the existing grace threshold, the existing yellow pill may say
  “Reconnecting…” or “Updating…”;
- hard authentication failure uses the existing explicit repair surface.

## 9. Reconciliation behavior

### 9.1 Server-to-mobile

- APNs background push is an invalidation hint, not database truth.
- Foreground, reconnect, and `BGAppRefreshTask` request the manifest.
- A changed transcript head schedules compact turn delta retrieval.
- Session tombstones delete session/turn/search/asset-link projections in one
  transaction, retain durable tombstone evidence, and clear relevant
  navigation/detail state.
- Asset bytes are removed only when no retained association remains, except
  bounded downloaded-original eviction.
- Delta expiration or incompatible projection version triggers a reconstructible
  scope reset and snapshot reload.
- A new authority epoch never triggers that destructive reset path. It detaches
  the old partition as a recovered local copy, seeds a new partition, and
  quarantines old pending work.

### 9.2 Mobile-to-server

- Local work is first persisted to `WorkRepository`.
- Optimistic UI is visibly marked pending.
- The outbox sends an idempotent conditional mutation.
- Acceptance records the receipt, turn/entity ID, epoch, and revision as
  `accepted_awaiting_projection`. GRDB then applies the authoritative entity;
  only that successful commit permits WorkRepository completion.
- Rejection rolls back or offers retry based on stable error class.
- Conflict never silently overwrites. The UI refreshes current authority and
  explains that the item changed elsewhere.

For offline delete, the session is hidden locally but retained as a pending
tombstone until acknowledgement. A server conflict restores it with an
explanation; it is never silently discarded.

### 9.3 Gateway loss

If the mobile client cannot find server entities after gateway reset or
replacement:

- local cached projections are marked “Recovered local copy”;
- they remain readable and exportable;
- they do not participate in ordinary reconciliation;
- they are never automatically uploaded; and
- a future explicit restore/import workflow may create new server identities.

This behavior is keyed by `authority_epoch`, not by URL or a lower revision.
Pending work from the previous epoch is quarantined for explicit user review and
is never automatically submitted to the replacement authority.

## 10. Storage and eviction

| Data | Retention |
|---|---|
| User messages | Until authoritative tombstone or explicit local purge |
| Final assistant responses | Until authoritative tombstone or explicit local purge |
| Compact work envelopes | Until authoritative tombstone or explicit local purge |
| Safe operation groups | Until authoritative tombstone or explicit local purge |
| Raw deep detail | Memory-only while relevant session/turn is open |
| Thumbnails | Until final asset association is removed |
| Downloaded originals | 30 days or shared 1 GB LRU, unless pinned |
| Pending local upload source | Until acknowledged or user cancels/deletes failed work |
| Server canonical referenced asset | While referenced; explicit purge produces authoritative unavailability |
| Manifest/delta journal | Minimum 90 days before snapshot reset |
| Projection tombstones | Until a later complete snapshot proves dominated replay impossible |
| Mutation receipts | Beyond operation expiry plus the documented safety window |

The existing attachment maintenance actor owns downloaded-original eviction.
Projection cleanup and detail-memory cleanup remain separate operations so a
blob purge cannot damage transcript integrity.

The 1 GB budget applies globally to unpinned downloaded originals. Thumbnails
and pinned originals are outside that eviction budget; Settings must report
their storage separately before pinning is shipped. Offline FTS indexes only
committed user text, final assistant text, and safe compact labels—not raw
detail.

`AttachmentBlobCache` remains the blob owner but migrates metadata to
`asset_id`, `content_version`, `blob_class = thumbnail | original`, and `pinned`.
The 30-day/1 GB policy applies only to unpinned originals. Thumbnails have a
deterministic maximum pixel dimension and encoded-byte ceiling. Under low disk,
the actor may refuse new nonessential blobs but cannot silently violate pinned
or referenced-thumbnail retention.

## 11. Performance contract

Initial acceptance targets:

- cached application shell visible within 300 ms of process-ready state;
- cached session switch visible within 200 ms;
- no network dependency for first paint;
- newest compact transcript query proportional to requested turn count;
- no full-transcript decode on normal open, switch, reconnect, or foreground;
- session switch cancels prior session paging/detail work before starting new
  work;
- scrolling and live streaming remain responsive with 10,000 historical raw
  message rows and a 1,000-operation turn;
- foreground convergence within 1 second on a healthy active connection and
  within 5 seconds after reconnect/foreground recovery.

Aspirational follow-up targets are 30 ms for cached projection query and 20 ms
for already-decoded UI publication. These are optimization goals after correct
instrumentation, not launch blockers.

## 12. Failure and fallback behavior

- **No compatible manifest:** cached reading works; freshness says limited
  compatibility; fallback session refresh is allowed.
- **No turn-projection capability:** use the legacy skeleton-shaped compatibility
  window without persisting raw deep fields, label performance/freshness as
  limited, and do not claim bounded source derivation.
- **Detail fetch fails:** compact turn remains; inline retry appears.
- **WebSocket gap:** mark live detail incomplete, use resume/backfill, keep the
  compact authoritative final once fetched.
- **Manifest page mismatch:** roll back everything and keep prior projection.
- **Manifest resource limit:** cursor cycle, page/entity/byte/time cap, or
  malformed final auxiliary state deletes staging and retains the prior
  projection.
- **Authority epoch changed:** preserve the old projection as a recovered local
  copy, create a new partition, and quarantine old pending work.
- **Database migration failure:** preserve `WorkRepository`; rebuild only
  reconstructible projection/cache state.
- **Asset unavailable:** retain descriptor and thumbnail if present; show an
  honest unavailable state rather than a filesystem-path error.
- **Mutation ambiguity:** retain operation in ambiguous state and query receipt
  before retrying.
- **Mutation expired:** query current authority and require manual review; never
  automatically resend beyond the operation expiry.
- **Auth failure:** stop reconciliation/outbox sends and request repair without
  erasing local readable history.

### 12.1 Pre-implementation authorization gate

Implementation beyond isolated contract/foundation repair is not authorized
until all of the following are frozen and tested:

1. B1 display lineage and turn-boundary fixtures pass against real SessionDB
   behavior.
2. Gateway installation ID, authority epoch, stable/transitional profile ID,
   and per-session display revision exist.
3. Manifest journal epoch, cursor roles, page caps, staging, reset/replacement
   semantics, and durable tombstone precedence pass Python-to-Swift tests.
4. The WorkRepository-to-GRDB `accepted_awaiting_projection` protocol and
   receipt lifetime are frozen.
5. Asset ID/version/association convergence and reference-aware GC are frozen.
6. The compatibility matrix and rollback-support window are documented.
7. A5 verifies the actual deployed plugin commit and capability set.

## 13. Atomic implementation plan

Each work unit is independently reviewable and reversible. Cross-surface work is
allowed only where the contract cannot be proven otherwise.

### Milestone A — Restore foundation truth

#### A0. Freeze authority and scope identity

**Purpose:** establish the identity domain required by every later cursor,
projection, receipt, asset, and pending mutation.

**Frozen contract:** `LOCAL-FIRST-A0-AUTHORITY-EPOCH-CONTRACT.md`.

**Changes:** add an installation-root gateway ID, one stable metadata-backed
profile ID, one `state_meta`-backed authority epoch per concrete profile
database, a plugin manifest journal epoch, and a non-destructive iOS scope
migration. The narrow generic SessionDB surface exposes read/get-or-create
authority identity without private `_conn` access. Existing URL/name-scoped
cache becomes a labelled legacy/recovered partition. Its pending work is
quarantined until explicitly bound to an authenticated concrete authority and
is never sent speculatively. Aggregate `all` is a query selector and is invalid
for WorkRepository mutation scope.

**Exit gate:** persistence, rename/clone/delete/recreate behavior, profile-A-only
database replacement, journal-only rebuild, cursor binding, legacy quarantine,
and concurrent first-start conformance tests pass. The design proof alone does
not complete A0 implementation.

**Non-goals:** no manifest activation, transcript projection, or automatic cache
alias merge.

**Dependency:** any generic upstream metadata/API addition is independently
reviewed and contains no mobile-specific code.

#### A1. Freeze one manifest path and fixture

**Purpose:** make the existing Python and Swift implementations speak the same
integrity contract before production wiring.

**Dependency:** A0 identity is available.

**Changes:** canonicalize `/sync/manifest`; freeze gateway ID, authority epoch,
manifest journal epoch, schema version, revision, snapshot ID, distinct
continuation/resume cursors, journal rebuild/reset, profile-authority
replacement, page caps, final-page auxiliary state, and Swift `CodingKeys`.
Serialize real Python multipage/reset/malformed fixtures and decode them with
shipping Swift.

**Non-goals:** no lifecycle wiring or UI changes.

**Likely files:**

- `plugins/hermes-mobile/dashboard/api.py`
- `apps/ios/HermesMobile/Networking/Rest/RestClient+SyncManifest.swift`
- plugin contract tests and `SyncCoordinatorTests.swift`

**Size:** proof-sized; estimate only after fixture inventory.

#### A2. Wire `SyncCoordinator` into production

**Purpose:** make foreground, invalidation push, and background refresh consume
the atomic manifest path already built.

**Dependency:** A1 multipage, cancellation, reset, epoch-replacement, and staging
tests pass. This unit cannot activate a partially frozen manifest.

**Non-goals:** no transcript projection yet.

**Likely files:** `HermesMobileApp`/`AppEnvironment`,
`ManifestInvalidationCoordinator`, `SyncCoordinator`, lifecycle tests.

**Size:** 1–2 days.

#### A3. Restore skeleton transcript payload shaping

**Purpose:** repair the lost `shape=skeleton` request/response behavior so the
compatibility path does not return raw deep fields.

**Non-goals:** this does not claim bounded source reads. The current server still
materializes the source transcript before shaping; bounded derivation belongs to
B1/B2a/B2b.

**Likely files:** `RestClient+Sessions.swift`, `SessionStore.swift`,
`plugins/hermes-mobile/transcript_sync.py`, paging tests.

**Size:** 1 day.

#### A4. Restore snapshot-based live-session truth

**Purpose:** decode resume/active-list `running`, `status`, and `inflight`; make
drawer and transcript state recover without waiting for a new edge event.

**Non-goals:** no replay-ring protocol.

**Likely files:** `ProtocolTypes.swift`, `SessionStore.swift`, `ChatStore.swift`,
live re-entry tests.

**Size:** 1–2 days.

#### A5. Add deployed-capability parity gate

**Purpose:** make development, daily-driver, and release verification report the
actual installed plugin commit and capability versions.

**Non-goals:** no automatic deployment mutation.

The gate reports gateway installation ID, authority epoch, plugin commit,
capability versions, and required public-upstream seam availability. Daily-driver
claims remain local evidence until this output is captured.

**Size:** 1 day.

### Milestone B — Compact local transcript

#### B1. Freeze `TurnProjectionV1`

This is a proof gate, not a one-day implementation estimate. Freeze shared JSON
examples, stable turn/input/group identities, terminal-message selection,
privacy rules, exact/derived/unknown timing, and display revision behavior.

Golden fixtures must cover:

- at least two compaction generations;
- rewind before and after compaction;
- retry/undo replacement;
- steering, interrupt-and-replace, and queued follow-up;
- interrupted, failed, and no-final turns; and
- a tool-heavy turn.

Every source row must map to one stable display origin or explicit no-display
class. If current public rows are ambiguous, land the narrow generic upstream
display-lineage/bounded-display-read prerequisite before continuing. The plugin
must not advertise compact projection before this proof passes.

The same proof freezes the generic durable turn-ledger fields for new turns:
`turn_id`, `client_message_id`, acceptance time, terminal state/time, and
terminal message ID. These are upstream authority metadata, not mobile-specific
prompt content.

#### B2a. Add reconstructible plugin projection and bounded backfill

Create the plugin-owned compact index under `HERMES_HOME`. New authoritative
turn lifecycle updates it incrementally. Historical projection runs in fixed
source-row batches with persisted backfill cursor, coverage metadata, and a hard
read budget. Use public `SessionDB`/display-lineage APIs only.

**Implemented:** the generic SessionDB turn ledger is the compact authoritative
index. The external plugin owns a restart-safe backfill checkpoint under
`HERMES_HOME`, scans at most 500 canonical display rows per advancement, stores
only safe operation metadata, and leaves ambiguous/no-final or over-limit turns
explicitly incomplete. A display-revision change discards only the checkpoint
and restarts derivation; it never deletes authoritative turns or durable mobile
work.

#### B2b. Add bounded compact turn HTTP reads

Expose tail, older-page, and delta/reset endpoints backed only by B2a's compact
index. Return explicit incomplete coverage rather than deriving arbitrary
history during a request. Include the real Python-to-Swift fixture in this unit.

**Implemented:** `/sessions/{stored_session_id}/turns` reads the bounded turn
ledger only. A request may advance one fixed historical source batch before the
read, reports `projection_pending` until every displayed user origin is proven,
and never falls back to full-transcript hydration.

#### B3. Add GRDB compact projection schema

Add turn/input/activity/link/tombstone tables, authority epoch, display revision,
unique scoped `client_message_id`, staging tables, and transactional
upsert/tombstone APIs. Do not place raw detail in these tables or FTS.

**Likely files:** `CacheSchema.swift`, new projection records/repository,
migration tests.

**Size:** 2 days.

#### B4. Make session open query compact turns directly

Replace full cached-message decode/suffix with SQL-limited compact projection
reads and session-scoped paging state.

**Likely files:** `SessionStore.swift`, `ChatStore.swift`, transcript adapter,
performance tests.

**Size:** 2–3 days.

#### B5. Add scoped live projection reducer

Persist only compact live fields while keeping visible raw detail in memory.
Adopt the separate runtime-instance/binding-epoch truth domain and protect
terminal authority from stale runtime/session IDs.

**Size:** 2–3 days.

#### B6. Add on-demand memory-only detail

Add paged group-operation and per-operation detail routes/clients, inline
expansion state, cancellation on navigation, memory-pressure cleanup, and
offline retry behavior. Enforce immutable detail-page chains and the per-scene
memory budgets in §6.6. Include the real Python-to-Swift detail fixture here.

**Size:** 2–3 days.

#### B7. Apply compact transcript presentation

Default to user message + collapsed work envelope + final response. Reuse the
current `ChatMessagePart` rendering through an adapter; do not redesign all
tool boxes in this unit.

**Size:** 2 days plus iPhone/iPad visual evidence.

### Milestone C — Stable assets

#### C1a. Add immutable asset identity and upload registry

Create opaque immutable asset/content versions and upload records. Stop returning
server paths as transcript identity. Include a real Python-to-Swift upload
descriptor fixture.

**Implemented:** uploads retain the legacy `path` field for old clients and now
also return an opaque `asset_id`, immutable SHA-256 content version,
authenticated download route, and thumbnail route. Registry rows live beside
the plugin receipt store; asset bytes are never addressed by their absolute
path on the new API.

#### C1b. Add durable prompt/asset association convergence

Keep the local source until prompt/asset association is acknowledged. Ensure
retry with one `operation_id` cannot create duplicate assets or messages. Prompt
receipt reservation and pending asset references commit in the plugin registry
before core submission; pending/indeterminate references are GC roots; the
public authoritative turn ledger converges them to committed associations after
SessionDB commit. `/associate` is recovery-only.

**Implemented for prompt submissions:** WorkRepository persists the remote
asset/version beside the background transfer. `prompt.submit` includes ordered
asset references in its idempotency fingerprint. The plugin writes pending GC
roots in the receipt reservation transaction and converts them to accepted turn
associations in the receipt-completion transaction; an abandoned reservation
remains indeterminate and cannot be garbage-collected automatically.

#### C2. Add authenticated asset reads, thumbnails, and GC

Add scoped historical authorization, ETag/`If-Range` download, deterministic
thumbnail bounds, reference-aware GC, tombstones, grace period, and
administrative unavailability. This unit does not change iOS rendering.

**Implemented for uploaded input assets:** reads recheck device/session
authorization, support ETag, `If-Range`, and bounded byte ranges; thumbnails are
generated at a 512-pixel bound; pruning skips pending and accepted references
and tombstones unreferenced registry entries before deleting bytes. Generated
artifact import and administrative purge remain gated.

#### C3. Adopt asset descriptors in iOS

Store links and thumbnails permanently, route downloaded originals through the
existing cache actor after migrating its metadata to asset/version/blob
class/pin state. Apply 30-day/1 GB only to unpinned originals and render honest
unavailable states.

**Size:** 2–3 days.

#### C4. Import generated artifacts safely

Convert allowlisted generated files into normal stable assets and remove
server-path rendering assumptions.

**Size:** 2 days.

### Milestone D — Complete bidirectional integrity

#### D1. Add cross-store accepted-awaiting-projection convergence

Extend the prompt Work record with authority epoch, authoritative turn/entity
ID, accepted entity revision, receipt payload, and
`accepted_awaiting_projection`. Add idempotent restart recovery and overlay
suppression by scoped `client_message_id`. Do not enable new mutation kinds.

#### D2. Add conditional mutations one vertical slice at a time

For each of rename, archive/unarchive, delete, approval, and clarification,
ship the server receipt/CAS contract, WorkRepository kind/state, expiry policy,
Python-to-Swift fixture, processor path, and conflict behavior in the same
independently gated unit. Use `base_entity_revision` plus authority epoch.
Never merge a client job kind that can execute before its matching server
contract exists.

#### D3. Add pending/conflict/tombstone UX

Represent pending deletes, accepted revisions, resolved-elsewhere approvals,
and conflicts without silent last-write-wins.

**Size:** 2 days.

### Milestone E — Hardening and rollout

#### E1. Aggregate cross-language contract suite

Real Python serialization to Swift decoding for manifest, turns, assets,
receipts, reset, and tombstones. Each feature PR already contains its own
shipping-path fixture; this unit is an aggregate regression suite, not the first
integration proof.

#### E2. Long-session performance suite

Use 1,393-message and 10,000-row fixtures; assert bounded query/decode counts and
session-switch latency.

#### E3. Chaos and integrity suite

Exercise dropped frames, reconnect, process kill between accept/commit,
out-of-order revisions, repeated tombstones, plugin downgrade, and gateway
database reset.

#### E4. Physical-device experience gate

Record iPhone and iPad launch, rapid session switching, live re-entry, detail
expansion, offline behavior, and attachment rendering. Assert no black syncing
box and no stale-session spinner loss.

## 14. Required adversarial tests

### Contract

- Real router fixture decodes in shipping Swift model.
- Unknown fields are tolerated; missing required version/identity fails closed.
- Path-family aliases cannot silently return a different schema.
- Old plugin capability produces honest fallback.
- Enabling the external plugin leaves the model system prompt and prior
  conversation payload byte-identical to the disabled case.
- New capabilities fail if their implementation imports or reads
  `SessionDB._conn`, gateway `_sessions`, `WSTransport`, or private send-loop
  fields.
- Continuation and resume cursors cannot be interchanged or persisted in the
  wrong role.
- Cursor cycles, excess pages/entities/bytes/time, snapshot mismatch, and
  repeated final auxiliary blocks fail closed without changing projection.
- Same-epoch reset replaces all reconstructible state; new-epoch replacement
  preserves the old recovered partition and quarantines pending work.
- Deleting/rebuilding only the plugin manifest journal changes `journal_epoch`
  and performs a same-authority reset; it does not create recovered history or
  quarantine work.
- In an aggregate scope, replacing profile A's database leaves profile B's
  epoch, projection, and pending work untouched.

### Projection

- Empty session, one turn, interrupted turn, failed turn, and no-final turn.
- One user turn containing 1,000 tool operations.
- Concurrent new rows during page retrieval.
- Any display-revision mismatch forces reset; suffix rewind after the prior row
  head cannot evade the guard.
- Projection replay is idempotent.
- Optimistic `client_message_id` merges into authoritative `turn_id` without a
  duplicate UI row.
- Intermediate assistant content/tool-call rows cannot be selected as the final
  response.
- Steer and queued-follow-up fixtures produce the gateway-defined turn
  boundaries.
- Pre-compaction original turns remain visible exactly once after compaction;
  synthetic compacted context is not displayed as a user turn.
- Two consecutive compactions preserve the same display origins and turn IDs.
- Rewind/undo removes or marks only the intended display turns and cannot be
  confused with compaction.
- Mutation of one profile cannot affect the same session ID in another profile.
- Raw arguments/results/reasoning never appear in persistent rows or FTS.
- One HTTP request never crosses its hard source-row derivation budget; partial
  historical coverage is returned honestly.

### Session switching

- Switch A→B→A rapidly while A is running.
- Prior page/detail task cannot publish into the new session.
- Drawer remains running during a quiet long tool call.
- Re-entering uses snapshot/inflight before the next live frame.
- Cached switch does not call the network before paint.
- SQL query count and decoded row count remain bounded.

### Detail lifecycle

- Detail is present while viewed and absent after navigation.
- Expanding a group loads bounded operation headers; expanding one operation
  cannot load sibling operation payloads.
- A 1,000-operation turn is paged and never decoded as one detail response.
- App relaunch does not restore detail from disk.
- Memory pressure clears detail without damaging compact state.
- Tombstone cancels the fetch and removes the view.
- Offline expansion shows inline retry, not a global loader.
- Detail-revision change resets the page chain without duplicates or gaps.
- Per-operation and per-scene decoded-memory budgets evict collapsed detail
  without damaging compact state.

### Reconciliation

- Atomic rollback on malformed second manifest page.
- Cursor never advances after rollback/cancellation.
- Old upsert after newer tombstone cannot resurrect data.
- Duplicate mutation receipt is harmless.
- Conflict refreshes authority and preserves an explanation.
- Pending offline delete hides locally, then accepts or restores explicitly.
- Gateway reset marks recovered local copies without uploading them.
- Process kill after Work acceptance but before GRDB projection resumes
  `accepted_awaiting_projection` without losing or duplicating the optimistic
  turn.
- Process kill after GRDB projection but before Work completion suppresses the
  overlay and completes idempotently.
- Delayed older turn/asset/live responses cannot pass a newer durable tombstone.

### Assets

- Same-size changed file gets a new content version.
- Referenced server asset survives time-based upload cleanup.
- Unauthorized session cannot fetch an asset by ID.
- Thumbnail remains after original LRU eviction.
- 30-day and 1 GB limits both evict correctly.
- Pinned original is exempt.
- Final association tombstone removes thumbnail and unreferenced bytes.
- Upload retry cannot duplicate asset or message association.
- Every crash boundary between plugin reservation, core prompt acceptance,
  receipt completion, and association convergence retains a GC root and
  resolves without duplicate prompt execution or broken committed reference.
- Historical asset authorization succeeds without a live runtime and fails for
  a different scope.
- `If-Range` version mismatch returns a clean full response rather than
  concatenating versions.

### End to end

Against a temporary `HERMES_HOME` and externally installed plugin:

1. Start pristine gateway and iOS contract harness.
2. Create two profiles with deliberately colliding session IDs in fixtures.
3. Submit prompt with image.
4. Stream tool-heavy turn and final response.
5. Switch away during a quiet tool operation and return.
6. Kill/restart client and verify compact local paint.
7. Expand detail, navigate away, and prove memory cleanup.
8. Rename/archive/delete offline and reconcile receipts/conflicts.
9. Restart/downgrade plugin and verify compatibility behavior.
10. Delete server database and verify no automatic restoration.

## 15. Deployment order

1. Land contract fixtures and foundation repairs.
2. Freeze and test this compatibility matrix:

   | Combination | Required behavior |
   |---|---|
   | Old plugin + new app | Capability absent; no destructive migration; bounded compatibility path; limited freshness shown honestly |
   | New plugin + old app | Legacy message, upload, attachment, and mutation routes/fields remain supported |
   | New plugin + new app | Compact capability enabled only by exact compatible versions |
   | Plugin downgrade | Compact local reader remains usable; network feature disables without deleting projection |
   | App rollback | Legacy raw rows remain throughout the documented rollback-support window |

3. Deploy plugin capabilities before enabling them in the iOS release.
4. Verify the daily-driver gateway reports the expected plugin commit,
   gateway ID, authority epoch, and
   versions.
5. Ship iOS with capability-gated fallback.
6. Build compact projections in the background from newest turns backward and
   persist per-scope `projection_coverage`.
7. Stop writing new raw permanent transcript rows only after coverage is durable
   and the minimum supported app can read compact projections.
8. Keep legacy raw rows through at least one documented rollback-support release
   window and until app/plugin downgrade tests pass.
9. Remove eligible legacy rows in bounded maintenance batches.
10. Keep durable `WorkRepository` data outside reconstructible-cache resets and
    quarantine it on authority-epoch change.

Rollback disables incompatible network capability use but does not disable the
local compact reader or delete compact projections. It returns network reads to
bounded skeleton windows only while legacy compatibility is retained and never
deletes durable user work or server data.

## 16. Tracker reconciliation

- **ABH-400:** remains the transcript-windowing/performance umbrella until the
  bounded SQL and session-switch targets pass.
- **ABH-405:** its merged behavior has regressed; track a regression rather than
  pretending the current main still satisfies it.
- **ABH-453 / ABH-454:** server/client manifest work exists but is incompatible
  and unwired. One blocking integration defect should link both completed
  issues and carry the real cross-language acceptance test.
- **ABH-371:** current snapshot consumption does not satisfy the live re-entry
  contract; track a regression linked to the original issue.
- **ABH-452, ABH-460, ABH-462, ABH-465, ABH-468, ABH-469, ABH-470:** preserve
  and build on these foundations.
- **STR-989 / `TRANSCRIPT-DESIGN-SPEC`:** retain compact-mode and clean-chrome
  intent. The auxiliary-model distillation lane is explicitly deferred and
  does not define permanent transcript truth.
- **`SMOOTHNESS-SPEC`:** this spec implements its local-first and live-recovery
  objectives while removing the redundant black syncing surface.

Recommended tracker shape: one new epic, **Local-First Transcript & Asset
Integrity**, containing Milestones A–E above. Do not create duplicate issues for
already-correct cache/outbox/attachment infrastructure.

## 17. Definition of done

The epic is complete only when:

1. A week-old cached app opens and switches sessions without network-blocked
   paint.
2. Normal switching reads a bounded number of compact turn rows regardless of
   historical transcript length.
3. A running session remains visibly running across quiet tools, navigation,
   reconnect, and process restoration.
4. Permanent mobile storage contains user messages, final responses, safe work
   envelopes, asset descriptors, and thumbnails—but no raw deep detail.
5. Expanded detail is fetched on demand and disappears after navigation or
   process reset.
6. Deletes, archives, renames, approvals, clarifications, and prompts reconcile
   through idempotent conditional operations.
7. Server tombstones cascade locally and never silently resurrect.
8. Gateway loss does not trigger automatic mobile restoration.
9. Sent and generated images render from stable asset IDs after gateway restarts
   and across devices, subject to explicit server retention policy.
10. Python-to-Swift fixtures, long-session performance tests, chaos tests, and
    physical-device evidence all pass.
11. The production/daily-driver plugin capability versions match the iOS build
    being tested.
12. The transcript never shows the redundant black “Syncing” box.
13. Authority replacement preserves the prior partition as a recovered local
    copy and never sends its pending work automatically.
14. Server acceptance cannot lose or duplicate an optimistic turn across either
    WorkRepository/GRDB crash window.
15. Every committed asset association fixes content version and survives
    reference-aware retention; download resume cannot mix versions.
16. Old/new app and plugin combinations pass the compatibility matrix through
    the documented rollback-support window.
