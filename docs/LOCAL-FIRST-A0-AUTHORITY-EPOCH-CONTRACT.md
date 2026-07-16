# Hermes Mobile — A0 Authority and Scope Identity Contract

**Status:** Frozen contract; identity substrate implemented; production v2 activation pending

**Date:** 2026-07-17

**Tracker:** ABH-474

**Audited source:** `ac84fe41ec7c3703de04c0c30a7ec2153280643e`

**Parent specification:** `LOCAL-FIRST-TRANSCRIPT-SPEC.md`

## 1. Decision

Hermes Mobile v2 identity is the following tuple:

```text
AuthorityScopeV1
- gateway_id
- profile_id
- authority_epoch
```

The plugin manifest adds a separate `journal_epoch`. It is deliberately not
part of authoritative entity identity:

```text
ManifestOrderDomainV1
- gateway_id
- journal_epoch
- requested_scope
- authorization_visibility
```

The four opaque identifiers have distinct lifetimes:

| Identifier | Meaning | Survives | Changes when |
|---|---|---|---|
| `gateway_id` | One Hermes installation root | process restart, URL/hostname change, profile rename, profile DB replacement | installation identity is explicitly reset or a different installation answers at the locator |
| `profile_id` | One logical profile | process restart, profile rename, in-place configuration change, authority DB replacement | profile is cloned/imported as new, deleted and recreated, or explicitly rekeyed |
| `authority_epoch` | One concrete profile authority-database lifetime | process restart and ordinary writes | that profile's authoritative DB is created, replaced, restored from an older authority snapshot, or explicitly reset |
| `journal_epoch` | One plugin manifest-journal lifetime | process restart and ordinary journal compaction | manifest journal is deleted, rebuilt, restored, or incompatibly migrated |

URLs and profile names are locators/display labels. They are never durable
authority identifiers. Credentials remain locator-bound and are not part of
cache identity.

No cursor, projection, asset reference, receipt, or pending mutation may cross
an `authority_epoch` automatically. A `journal_epoch` change with unchanged
authorities causes a reconstructible snapshot reset but does not quarantine
pending work.

## 2. Verified current state

### 2.1 iOS identity is locator-based

Observed in `apps/ios/HermesMobile/Cache/SessionCacheRecord.swift`:

- `CacheScope.serverId` is the trimmed `ConnectionStore.serverURLString`.
- `CacheScope.profileId` is the normalized active profile name.
- `CacheIdentity` is `(serverId, profileId, sessionId)`.

Observed in `apps/ios/HermesMobile/Work/WorkRecords.swift`:

- `WorkScope` contains only `serverID` and `profileID`.
- It deliberately does not parse or independently verify either value.

Observed in `apps/ios/HermesMobile/Stores/SessionStore.swift`:

- `durableWorkScope` is copied directly from the current URL/name cache scope.

Consequences:

1. URL aliases create unrelated partitions for one installation.
2. A new gateway installed at an old URL inherits the old partition.
3. A profile rename changes the apparent identity.
4. A profile DB replacement cannot be distinguished from an old revision.
5. Pending work can be delivered to a replacement authority at the same URL.

### 2.2 Profiles are independent authority islands

The original profile implementation commit, `603599e98`, explicitly defines
each profile as a fully independent `HERMES_HOME` with independent sessions,
gateway, cron, memory, configuration, and logs.

Current source preserves that intent:

- `hermes_constants.get_hermes_home()` resolves one profile home.
- `SessionDB.DEFAULT_DB_PATH` is `<active HERMES_HOME>/state.db`.
- named profiles live at `<root>/profiles/<name>`.
- `rename_profile()` moves the directory and therefore preserves its DB.
- clone-all explicitly excludes `state.db`, sessions, backups, snapshots, and
  checkpoints, so a cloned profile is a fresh authority even when its
  configuration and metadata are copied.

The profile name is currently the API identity. `ProfileSummary.id == name`,
and `/api/profiles` emits no stable profile identifier. A rename therefore
proves that the name cannot be the v2 identity.

### 2.3 SessionDB has a suitable public-storage substrate but no identity API

`hermes_state.py` already creates `state_meta(key PRIMARY KEY, value)` inside
every `state.db`. This is the correct transactional home for a database
lifetime marker.

Current public `SessionDB` behavior does not expose an authority-identity API.
The mobile plugin already violates the intended boundary elsewhere by reading
`SessionDB._conn`; A0 must not add another private access.

### 2.4 The manifest journal has revision but no journal identity

Observed in `plugins/hermes-mobile/sync_manifest.py`:

- the journal is `<HERMES_HOME>/mobile/sync-manifest.sqlite3`;
- the only meta value is numeric `revision`;
- cursor tokens use the `m1.` family;
- page continuation and durable resume share `next_cursor`;
- scopes and entity keys use profile names;
- `scope=all` aggregates multiple independent profile databases;
- journal deletion restarts revision ordering without a durable epoch;
- the journal currently retains cursors for 30 days;
- current code reads `SessionDB._conn`, so v2 capability must remain disabled
  until public prerequisites exist.

### 2.5 Existing instance-like IDs are not authority identity

- `pending_attention.SERVER_INSTANCE_ID` is random process memory and changes
  on every process start. It is a runtime/cursor invalidation value only.
- relay `gateway_id` and `relay_instance_id` are optional deployment routing
  identifiers. They may be absent, hostname-derived, tenant-managed, or shared
  across profile gateways. They cannot define local transcript authority.
- APNs device IDs identify clients, not servers.

None may be reused as `gateway_id`, `profile_id`, or `authority_epoch`.

## 3. Opaque ID format

The wire contract treats every identifier as an opaque, case-sensitive string.
The initial generator uses 128 random bits encoded as URL-safe base64 without
padding:

```text
gateway_id       = "gw_" + token_urlsafe_128
profile_id       = "pf_" + token_urlsafe_128
authority_epoch  = "ae_" + token_urlsafe_128
journal_epoch    = "je_" + token_urlsafe_128
```

Initial validation regex:

```text
^(gw|pf|ae|je)_[A-Za-z0-9_-]{22}$
```

The prefix aids diagnostics but carries no semantics. Clients must not parse,
sort, case-fold, truncate, or derive one identifier from another. A future
schema version may accept a different opaque format without changing identity
semantics.

IDs are not secrets. They may appear in authenticated responses and redacted
diagnostics. They must not be accepted from an unauthenticated response as a
reason to rebind or release quarantined work.

## 4. Persistence and ownership

### 4.1 Installation registry

The installation root owns one atomically written, mode-`0600` identity
registry outside every profile DB:

```text
<hermes-root>/mobile/authority-identity-v1.json
```

Normative minimum shape:

```json
{
  "schema_version": 1,
  "gateway_id": "gw_opaque",
  "profiles": {
    "pf_opaque": {
      "last_known_name": "default",
      "authority_epoch": "ae_opaque"
    }
  }
}
```

The registry is infrastructure metadata, not a user configuration setting. It
is written through atomic replace and directory fsync. Concurrent creators use
an inter-process lock and re-read after acquiring it. A process must not serve
v2 capabilities until the registry and DB identity agree.

### 4.2 Stable profile identity

Each profile owns one stable `profile_id` in its tiny profile metadata file:

```yaml
# <profile-home>/profile.yaml
profile_id: pf_opaque
```

This extends the existing profile-metadata surface; it does not place behavior
in `config.yaml` or `.env`.

Lifecycle rules:

- existing/default profile: lazily create once under the identity lock;
- rename: preserve the ID because `profile.yaml` moves with the directory;
- clone/duplicate/import-as-new: generate a new ID even if source metadata was
  copied;
- delete and recreate under the same name: generate a new ID;
- in-place restore of the same logical profile: preserve only when the restore
  workflow explicitly declares it an in-place restore and rotates the authority
  epoch as required below;
- duplicate IDs within one installation: fail v2 capability closed until the
  clone/import path rekeys the new copy. Never guess between two live profiles.

The profile-list API adds `profile_id` while retaining `name` and `is_default`.
Mobile uses `profile_id` for identity and `name` only for display and request
routing during compatibility transitions.

### 4.3 Database authority epoch

Each writable `SessionDB` stores:

```text
state_meta['profile_id']       = pf_opaque
state_meta['authority_epoch']  = ae_opaque
```

The narrow generic upstream surface is:

```python
@dataclass(frozen=True, slots=True)
class StateAuthorityIdentity:
    profile_id: str
    authority_epoch: str

class SessionDB:
    def get_or_create_authority_identity(
        self,
        *,
        expected_profile_id: str,
    ) -> StateAuthorityIdentity: ...

    def read_authority_identity(self) -> StateAuthorityIdentity | None: ...
```

Contract:

- `get_or_create` is unavailable on a read-only connection;
- creation of both keys is one `BEGIN IMMEDIATE` transaction;
- a missing authority epoch in a new/legacy DB creates one before v2 is served;
- stored `profile_id != expected_profile_id` is a copied/restored DB conflict,
  not a reason to overwrite metadata silently;
- plugin aggregate reads use `read_authority_identity()` and never `_conn`;
- a read-only legacy profile without identity is reported as
  `identity_pending`; it is omitted from v2 authority claims until a normal
  writable initialization establishes identity.

The installation registry mirrors the most recently committed epoch for each
`profile_id`. On mismatch between DB and registry, the server treats the DB as
restored/replaced and rotates to a new epoch before serving. Crash ordering is:

1. commit DB identity;
2. atomically update/fsync installation registry;
3. expose capability.

A crash between 1 and 2 causes another rotation on restart. That is safe: no
client was allowed to observe the unregistered epoch.

### 4.4 Manifest journal epoch

The plugin journal meta table adds a string `journal_epoch`. It is generated in
the same initialization transaction as revision zero and returned on every
manifest page.

Deleting/rebuilding/restoring the journal creates a new `journal_epoch`.
Ordinary compaction that preserves cursor/revision ordering does not. All
continuation and resume cursors bind the journal epoch; a token from another
journal fails closed and requests a complete `journal_rebuilt` snapshot.

The journal epoch is plugin-owned. It never appears in SessionDB and never
changes a profile authority epoch.

## 5. Aggregate scope contract

`all` is a query selector, not a durable profile identity and never a mutation
scope.

Every manifest page includes an immutable, canonically sorted authority map:

```json
{
  "gateway_id": "gw_opaque",
  "profile_authorities": [
    {
      "profile_id": "pf_a",
      "profile_name": "default",
      "authority_epoch": "ae_a"
    },
    {
      "profile_id": "pf_b",
      "profile_name": "work",
      "authority_epoch": "ae_b"
    }
  ],
  "journal_epoch": "je_opaque"
}
```

Rules:

- concrete `profile:<profile_id>` scope contains exactly one descriptor;
- `all` contains one descriptor for every included concrete profile;
- every upsert/tombstone/head/runtime record names its `profile_id` and
  `authority_epoch`;
- the canonical authority-map digest is bound into both cursor families;
- a page-chain authority-map change invalidates the entire staged chain;
- after final validation, an epoch change detaches only that profile's old
  partition and quarantines only its pending work;
- unaffected profiles retain projections, cursors, thumbnails, and pending
  work;
- an `identity_pending` profile makes aggregate freshness partial and cannot be
  silently represented by its mutable name.

All mutations, drafts, outbox jobs, prompt receipts, and asset associations
target one concrete `AuthorityScopeV1`. `profile_id=all` is invalid.

## 6. Client binding and transition rules

### 6.1 Locator binding

The client keeps a separate authenticated locator binding:

```text
GatewayLocatorBindingV1
- normalized_locator
- gateway_id
- verified_at
```

This table helps reconnect but is not part of entity identity.

- same `gateway_id`, new URL: update locator binding; keep authority partitions;
- different `gateway_id`, same URL: detach every old profile partition and
  quarantine all old pending work;
- no authenticated identity: cached content remains readable but cannot claim
  current freshness and pending work does not send.

The identity response is accepted only through the authenticated gateway path.

### 6.2 Authority transition table

| Observed change | Client action |
|---|---|
| URL changes; gateway/profile/epoch unchanged | update locator only |
| profile name changes; profile ID/epoch unchanged | update display label only |
| journal epoch changes; authority map unchanged | discard/rebuild reconstructible state for selected current epochs; do not quarantine work |
| authority epoch changes for one profile | preserve old profile partition as recovered local copy; seed new partition; quarantine that profile's pending work |
| profile ID changes under same name | treat as delete/recreate; preserve old recovered partition; quarantine old work |
| gateway ID changes at same URL | treat as installation replacement; preserve all old partitions as recovered; quarantine all old work |
| process/runtime instance changes only | no authority transition |
| lower revision in same journal epoch without reset | protocol error; keep prior projection |

### 6.3 Legacy iOS migration

Existing URL/name-scoped rows cannot be proven to belong to a returned
authority. Migration is non-destructive and fail-closed:

1. Leave old cache rows under a `legacy_unverified`/recovered partition.
2. Seed the verified v2 authority partition from the gateway.
3. Do not automatically merge URL aliases or rekey old committed cache rows.
4. Quarantine every URL/name-scoped pending WorkRepository job.
5. Releasing a legacy job requires an explicit user-confirmed binding to the
   currently authenticated concrete authority, followed by a new operation
   fingerprint/receipt check.
6. An aggregate `all` scope can never receive a legacy mutation binding.
7. Legacy credentials may remain URL-keyed; credentials do not prove cached
   authority.

This may temporarily display a current remote session and a separately labelled
recovered local copy. That is preferable to silent data loss or sending work to
the wrong authority.

## 7. Restore and replacement rules

Automatic detection has a fundamental limit: restoring a byte-for-byte copy of
both the installation registry and every database also restores their IDs.
Therefore the supported restore workflow is normative:

- restoring/replacing one profile DB rotates that profile's authority epoch;
- restoring an installation as a new installation rotates `gateway_id`, every
  profile ID, every authority epoch, and the journal epoch;
- restoring an older full-installation snapshot in place must at minimum rotate
  every authority epoch and the journal epoch before network service resumes;
- raw filesystem replacement that bypasses the restore command is unsupported
  and must be surfaced by A5 diagnostics as unverifiable identity provenance.

The restore workflow never uploads mobile data and does not change the locked
gateway-authority decision.

## 8. Security and failure behavior

- Identity metadata contains no credential or bearer token.
- Files are mode `0600`; parent directories are `0700` where supported.
- Writes use atomic replace, fsync, and an inter-process lock.
- Malformed/duplicate/mismatched identity fails v2 capability closed. Legacy
  read-only behavior may continue with limited compatibility.
- A profile identity conflict never causes another profile's metadata to be
  rewritten.
- Logs may include opaque IDs but never tokens or raw transcript content.
- The plugin cannot advertise `sync_manifest >= 2`, stable assets, conditional
  mutations, or compact turns until the identity provider succeeds for the
  requested concrete authority set.
- Prompt/system context is untouched; the identity surface is downstream
  metadata and cannot affect prompt caching.

## 9. Required conformance tests

### Server identity

1. Concurrent first startup produces one gateway ID, profile ID, authority
   epoch, and journal epoch.
2. Process restart preserves all four.
3. URL/hostname change preserves gateway/profile/authority identity.
4. Profile rename preserves profile ID and authority epoch.
5. Clone/import-as-new creates new profile ID and authority epoch.
6. Delete/recreate same profile name creates new profile ID and epoch.
7. Delete/recreate `state.db` changes only that profile's authority epoch.
8. Replace profile A DB leaves profile B identity unchanged.
9. Delete/rebuild only manifest journal changes only journal epoch.
10. DB/registry mismatch rotates before capability is served.
11. Duplicate profile IDs fail closed until the new copy is explicitly rekeyed.
12. Read-only aggregate access uses public APIs and performs no identity write.
13. Plugin source for the new path has no `_conn`, `_sessions`, `WSTransport`,
    or private send-loop access.

### Manifest and cursor binding

1. Concrete scope returns exactly one authority descriptor.
2. Aggregate scope returns a stable sorted map and entity-level epoch tags.
3. Authority-map change between pages rejects the staged chain.
4. Cursor from another gateway, journal, authority map, scope, visibility, or
   page-size contract fails closed.
5. Journal rebuild yields full `journal_rebuilt` reset without work quarantine.
6. One profile epoch change yields recovered history/quarantine only for that
   profile.

### iOS migration and work safety

1. Different gateway at same URL cannot read current-authority rows or drain old
   work.
2. Same gateway at a new URL reuses verified partitions after authentication.
3. Profile rename does not duplicate current partitions.
4. Legacy URL/name cache remains readable as recovered content.
5. Legacy pending jobs never send automatically.
6. `all` cannot construct a `WorkScope`.
7. Scope/epoch change during an in-flight request prevents publication/commit.
8. Gateway-loss UI never offers automatic restore from mobile.

## 10. Implementation boundaries

Minimum likely surfaces:

### Generic Hermes identity prerequisite

- `hermes_cli/profiles.py`
  - stable profile metadata;
  - rename preservation;
  - clone/import rekey;
  - duplicate detection.
- `hermes_state.py`
  - public state-authority identity API backed by `state_meta`.
- profile API models/routes
  - add stable profile ID without removing name fields.

This work is generic and contains no mobile-specific session/projection logic.

### External hermes-mobile plugin

- installation identity registry;
- journal epoch;
- capability gating;
- manifest authority descriptors;
- restore/reset diagnostics.

### iOS

- authority scope and locator-binding models;
- GRDB migration/legacy recovered partition;
- WorkRepository epoch columns and quarantine state;
- authenticated binding reducer;
- diagnostic provenance.

No existing GRDB, WorkRepository, OutboxProcessor, or AttachmentBlobCache
foundation is replaced.

## 11. Proof verdict

**Contract: GO. Current implementation: NO-GO.**

The contract is implementable with one narrow generic upstream identity
prerequisite plus plugin/iOS extensions. Current source does not satisfy it:

- URL and profile name are still used as durable mobile scope;
- no stable gateway/profile IDs exist;
- no per-profile database authority epoch exists;
- no manifest journal epoch exists;
- aggregate scope cannot prove independent profile authority lifetimes; and
- existing pending work has no epoch fence.

ABH-474 must remain open until the persistence, API, migration, and conformance
tests in this document land. This document completes the read-only design proof
and unblocks implementation planning; it does not authorize A1 production
wiring or broader transcript implementation.

## 12. Verification evidence

The read-only proof was checked in a clean worktree at the audited commit.

Targeted existing behavior tests:

```text
pytest -q \
  tests/hermes_cli/test_profiles.py \
  plugins/hermes-mobile/tests/test_sync_manifest.py \
  plugins/hermes-mobile/tests/test_sync_manifest_e2e.py

169 passed in 3.42s
```

Static premise checks confirmed:

- `WorkScope` currently contains only URL-derived `serverID` and name-derived
  `profileID`;
- `ProfileSummary.id` is the mutable profile name;
- `CacheScope.serverId` trims but otherwise preserves the connection URL;
- manifest journal initialization creates only numeric `revision` metadata;
- pending-attention instance identity is process-random; and
- no `authority_epoch` or `journal_epoch` implementation exists in the current
  SessionDB, manifest journal, iOS work scope, cache scope, or manifest model.

Markdown parsing, balanced-fence validation, and `git diff --check` are required
before the proof commit.

## 13. Implementation progress

The first two independently reversible implementation slices now exist on the
contract branch:

- `c060e6b9d` adds stable profile IDs, public transactional `SessionDB`
  authority APIs, the installation registry, manifest journal epochs, cursor
  journal fencing, profile API identity, and server/plugin conformance tests.
- `cb34a53d4` adds additive iOS authority wire models, WorkRepository v3 scope
  columns, verified and legacy authority states, explicit legacy quarantine,
  and claim-time exclusion of quarantined work.

Verification at those commits:

```text
180 Python profile/SessionDB/plugin/manifest tests passed
ruff and py_compile passed
WorkRepositoryTests build-for-testing passed
WorkRepositoryMacTests passed
HermesMobile + HermesMobileTests build-for-testing passed
```

The normal device-hosted `WorkRepositoryTests` runner could not launch on the
local Mac because its provisioning profile does not include that Mac device.
The same target compiled successfully; this is recorded as an environment
limitation, not test success.

ABH-474 remains **In Progress**. Production v2 activation is still fail-closed
until A1 freezes the real cross-language manifest shape, `SyncCoordinator` is
wired into the production graph, the authenticated locator binding persists a
verified `gateway_id`, and capability advertisement no longer depends on the
plugin's existing private SessionDB/runtime reads. Legacy URL/name work is not
silently rebound by the new code.
