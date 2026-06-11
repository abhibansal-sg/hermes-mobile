# CONTRACT — iOS Offline-First Local Cache (WhatsApp-style)

Status: design contract, ready for builder+gate pipeline. Build the standalone
layer NOW (P1/P2, all-new files, unblocked); wire into the live stores
(P3/P4) AFTER the scroll-rebuild + craft-cleanup waves land.
Scope: `apps/ios/HermesMobile/` persistence + sync only. NEW files; no edits to
existing files until P3. Native SwiftUI / Swift 6 strict; NOT a desktop clone.
Reference: desktop is a pure in-memory thin client (zero on-disk store) — this
contract is the iOS-only departure from that, motivated by the remote-Tailscale
latency the desktop never pays.

**The bar (acceptance invariant):** app launch, drawer open, and session open
render **instantly from disk** with zero network on the hot path; the live
fetch runs in the background and merges deltas without tearing down rendered
rows. Formally: for any session ever opened, `open(s)` paints the cached
transcript in one runloop turn, and the subsequent REST reseed is an
**identity-preserving merge** (no remount, no flicker) over the already-painted
content. The cache is a persistence layer **behind** `SessionStore.sessions`
and `ChatStore.messages` — it never becomes a second source of truth in the UI.

**Decided scope (user, binding):** cache **HUMAN (non-cron) transcripts**; the
**session list is always cached in full** (raw rows, including cron — `hideCron`
stays a client-side read-time filter so a filter flip never invalidates the
cache); transcripts are cached **lazily-on-open, then kept**; **~1-year eviction
horizon** on `last_active`; **pinned sessions are additive** (never evicted).

All model facts below re-verified against source + the LIVE dashboard
(`http://127.0.0.1:9119`, read-only GETs) on 2026-06-08.

---

## 1. STORE ENGINE — SQLite via GRDB, behind one repository actor

**Verdict: SQLite through GRDB.swift, wrapped in a single `CacheStore` actor. No SwiftData, no Core Data, no hand-rolled `libsqlite3`.**

### 1.1 Decision rationale

- **SwiftData — eliminated.** iOS 17.0/17.1 shipped with cascade-delete no-ops,
  predicate-compile crashes, and iCloud-sync data loss; a store holding 4600+
  sessions cannot risk them. Its `ModelContext`/`ModelActor` concurrency model
  does not compose with the existing all-`@MainActor`, `@Observable` store graph
  without rewriting `ChatStore`/`SessionStore`. It has **no raw-query escape
  hatch** for the recency-sorted pagination, `last_accessed_at` eviction sweeps,
  and pinned-lookup the cache needs. `VersionedSchema` migration gaps make a
  schema revision mid-TestFlight unsafe — unacceptable for the last feature
  before release.
- **Core Data — eliminated.** Correct and mature, but `NSManagedObject` is **not
  `Sendable`**; under `SWIFT_STRICT_CONCURRENCY = complete` every boundary
  crossing forces `NSManagedObjectID` dances or `performAndWait`, all of which
  emit warnings/errors. Its implicit background-vs-main context coordination is a
  footgun under an all-`@MainActor` model — background sync would have to hop to
  `MainActor.run` for every write, defeating the point.
- **GRDB — chosen.** First-class Swift 6 / `Sendable` support; `DatabaseQueue`
  serialises all access as an actor-friendly writer; full SQL (raw `SELECT`,
  custom indexes, FTS5 later); `DatabaseMigrator` with numbered migrations
  applied idempotently at open (safe schema evolution across TestFlight cycles);
  `FetchableRecord`/`PersistableRecord` on **plain structs** — no ObjC class
  inheritance, no graph contamination; proven at chat-app scale.
- **Plain `libsqlite3` — rejected as inferior.** Zero SPM cost (already linked),
  but hand-rolling safe statement prep / binding / column extraction / WAL
  pragmas / migration tracking is exactly the error-prone surface GRDB already
  is. Given the project **already carries one SPM package**, adding GRDB is the
  right trade over shipping a worse version of it.

### 1.2 Dependency / setup cost

One package entry in `apps/ios/project.yml` (the `packages:` block today holds
only the local-path `DebugBridge`, line 20):

```yaml
packages:
  DebugBridge:
    path: DebugBridge
  GRDB:
    url: https://github.com/groue/GRDB.swift
    from: "7.0.0"
```

One dependency line on the `HermesMobile` target only (NOT `HermesWidgets` /
`HermesShare` — neither has a persistence need):

```yaml
    dependencies:
      # ...existing...
      - package: GRDB
        product: GRDB
```

Then `xcodegen generate` in `apps/ios`. Do NOT bump
`CURRENT_PROJECT_VERSION` / `MARKETING_VERSION` (version bumps are
TestFlight-ship-only). The Release-build footprint is a static SQLite wrapper;
nothing about it ships to the share/widget extensions.

### 1.3 Concurrency posture

`DatabaseQueue` (single writer), not `DatabasePool` — concurrent reads give a
chat cache no throughput benefit and a pool adds WAL-reader bookkeeping for
nothing. All DB access is serialised inside one `actor CacheStore`. The actor
boundary IS the full isolation boundary: **no `SessionSummary`, `StoredMessage`,
`ChatMessage`, or `ChatMessagePart` value is ever held as actor state** — they
are `Sendable` parameters and return values only. The DB file lives in
Application Support (excluded from iCloud backup via
`URLResourceValues.isExcludedFromBackup = true`; it is a reconstructible cache),
opened with `PRAGMA journal_mode=WAL` and `foreign_keys=ON`.

---

## 2. SCHEMA — local tables + how the canonical models map to rows

The cache persists the **wire layer**, never the render layer. Transcript
reconstruction always runs through the existing, deterministic
`ChatStore.toChatMessages([StoredMessage]) -> [ChatMessage]` seed producer — so
the cache layer never has to understand `ChatMessagePart` internals. This is the
single most important schema decision: it keeps the canonical
`ChatMessagePart` enum (which is `Sendable, Equatable` but deliberately **not
`Codable`** — encoding it would pollute the domain model with a custom Codable
on a tree of `[ToolActivity]`/`[JSONValue]`) completely out of the persistence
path.

### 2.1 Model facts that drive the mapping (verified)

| Canonical type | File | Conformances today | Cache implication |
|---|---|---|---|
| `SessionSummary` | `Models/ProtocolTypes.swift:12` | `Decodable, Identifiable, Sendable, Equatable` | needs `Encodable` (or a cache-side mirror) to persist |
| `StoredMessage` | `Models/ProtocolTypes.swift:224` | `Sendable` only | needs a cache-side `Codable` mirror; its `content`/`toolCalls` already nest `Codable` types |
| `JSONValue` | `Models/JSONValue.swift:5` | `Sendable, Equatable, Codable` | already round-trips cleanly as JSON |
| `WireToolCall` | `Models/ProtocolTypes.swift:323` | `Sendable, Equatable` | flat `{callId,name,arguments}` — trivial mirror |
| `ChatMessage` | `Models/ChatModels.swift:44` | `id: UUID`, `parts: [ChatMessagePart]` | NEVER persisted; rebuilt from `StoredMessage` rows |
| `ChatMessagePart` | `Models/ChatModels.swift:22` | `Identifiable, Sendable, Equatable` (NOT Codable) | NEVER persisted |

The wire envelope is confirmed live: `GET /api/sessions` returns
`{sessions[], total, limit, offset}`; each row carries `id, last_active,
message_count, source, archived, started_at, ended_at, cwd, title, preview,
parent_session_id, rewind_count` (and cost/token fields the cache ignores).
There is **no `latest_message_id` on the session row** (see §3.4).

### 2.2 Persisted structs (GRDB records, all NEW files)

```swift
// SessionCacheRecord.swift  — one row per session (raw, includes cron)
struct SessionCacheRecord: Codable, FetchableRecord, PersistableRecord {
    var id: String                 // SessionSummary.id (stored_session_id; stable across compression chains)
    var summaryJSON: Data          // the full SessionSummary, JSON-encoded (round-trips every field incl. profile/source/cwd)
    var lastActive: Double?        // SessionSummary.lastActive — EVICTION + DIRTY key (indexed)
    var messageCount: Int?         // SessionSummary.messageCount — DIRTY key
    var source: String?            // "cron" vs human — read-time filter, NOT a cache filter
    var archived: Bool             // mirror of the row's archived state
    var isPinned: Bool             // additive; pinned ⇒ never evicted (set at P4 wiring)
    var lastAccessedAt: Double     // when the user last OPENED this session (touch on open)
    var transcriptCachedAt: Double?// nil ⇒ transcript not yet cached (lazy); set on first save
    var maxMessageId: Int?         // local cursor: max wire `id` persisted for this session (see §3.4)
    static let databaseTableName = "session_cache"
}

// MessageRowRecord.swift  — one row per StoredMessage (HUMAN sessions only)
struct MessageRowRecord: Codable, FetchableRecord, PersistableRecord {
    var sessionId: String          // FK → session_cache.id (ON DELETE CASCADE)
    var ordinal: Int               // position in the fetched transcript (0-based); rebuild order
    var wireId: Int?               // global autoincrement `id` from the wire row (cursor; may be nil pre-merge)
    var role: String               // StoredMessage.role (sql-side filtering/debug)
    var timestamp: Double?         // StoredMessage.timestamp
    var rowJSON: Data              // the FULL StoredMessage (cache-side Codable mirror), JSON-encoded
    static let databaseTableName = "message_row_cache"
}

// SyncMetaRecord.swift — singleton-ish KV for sync bookkeeping
struct SyncMetaRecord: Codable, FetchableRecord, PersistableRecord {
    var key: String                // e.g. "sessionList.lastFullFetchAt", "serverCaps.deltaSessions"
    var value: String              // small JSON/string blob
    static let databaseTableName = "sync_meta"
}
```

Rationale for the splits:

- **`summaryJSON` blob, not exploded columns.** `SessionSummary` has ~15 fields
  and computed accessors; only the four that drive SQL (`lastActive`,
  `messageCount`, `source`, `archived`) plus identity/eviction
  (`id`, `isPinned`, `lastAccessedAt`) are promoted to real columns for
  index-able WHERE/ORDER BY. Everything else round-trips inside `summaryJSON`,
  so adding a `SessionSummary` field later is a zero-migration change (the blob
  absorbs it). The cache adds `Encodable` to `SessionSummary` (or a thin
  `Codable` mirror confined to the cache layer) — it stays a value type.
- **`MessageRowRecord` stores `StoredMessage`, not `ChatMessage`.** The
  reconstruction path is always `rows → [StoredMessage] → toChatMessages →
  [ChatMessage]`, the exact existing seed path. `StoredMessage` itself is only
  `Sendable`; the cache defines a private `Codable` mirror (`role, content:
  JSONValue, timestamp, toolCalls: [WireToolCall], toolCallId, toolName,
  reasoning, finishReason`) — `JSONValue` is already `Codable`, `WireToolCall`
  is a flat struct, so the mirror is ~30 lines and lives ONLY in the cache.
- **`ordinal` + `wireId`.** `ordinal` preserves the fetched order for a clean
  rebuild even when a transcript is replaced wholesale. `wireId` (the global
  SQLite autoincrement `id`) is the per-session cursor used for append-merge and
  for `maxMessageId` (§3.4). The wire orders by `id ASC` (insertion order, per
  the WSL2 clock-regression fix), so `ordinal` and `wireId` agree on order;
  `ordinal` is the authority for rendering, `wireId` is the authority for the
  cursor.

### 2.3 Indexes

- `session_cache(lastActive)` — recency sort + eviction range scan.
- `session_cache(isPinned)` — pinned exemption in eviction.
- `message_row_cache(sessionId, ordinal)` — transcript load (the hot read).
- `message_row_cache(sessionId, wireId)` — cursor / append-merge.
- FK `message_row_cache.sessionId → session_cache.id ON DELETE CASCADE` — a
  session eviction drops its transcript rows in one statement.

### 2.4 Migration / versioning

`CacheSchema.swift` defines a `DatabaseMigrator` with numbered, append-only
migrations applied idempotently at open:

- **v1** — create `session_cache`, `message_row_cache`, `sync_meta` + the four
  indexes above. (Ships first.)
- Future migrations are additive (`ALTER TABLE ADD COLUMN`, new indexes, FTS5
  shadow table for search). Because session/transcript bodies live in JSON
  blobs, most model evolution needs **no migration at all**.
- **Schema-fingerprint fallback:** the cache stamps a `schemaVersion` in
  `sync_meta`. If a future build ever needs a non-trivial reshape, the safe
  default is **drop-and-rebuild** — the cache is 100% reconstructible from the
  gateway, so a nuke-on-incompatible-version path is always available and never
  loses user data. `DatabaseMigrator` is the normal path; drop-and-rebuild is
  the escape hatch. Either way a user can never get stuck mid-TestFlight.

---

## 3. SYNC PROTOCOL — full-fetch-diff v1 (delta-if-supported)

**Hard finding (verified by live probing): true delta sync is NOT possible with
today's endpoints.** Neither `GET /api/sessions` nor
`GET /api/sessions/{id}/messages` honors any `since` / `updated_after` /
`after_id` / `cursor` param — FastAPI silently ignores unknown query params and
returns the full result set; the DB layer (`get_messages`) has no after-id
clause. So v1 is **full-fetch + client-side diff**, made cheap by intelligent
triggers and by the broadcast channel telling us exactly which session is dirty.
A `ServerCapabilities`-gated delta fast-path (§3.7) lights up automatically if a
future gateway adds the params.

### 3.1 Initial backfill (cold install / first launch)

1. Session list: `GET /api/sessions?limit=N&order=recent` (the app's existing
   grow-limit window). Persist **all** returned rows raw into `session_cache`
   (cron included). Stamp `sessionList.lastFullFetchAt`.
2. Transcripts are **NOT** backfilled eagerly — they are lazy-on-open per the
   decided scope. Only when the user first opens a **human** session is its
   transcript fetched and persisted (§3.3). This keeps the cold-install network
   cost to a single list fetch.
3. The ~1-year horizon means even a heavy user converges to a bounded working
   set of opened human transcripts (§3.6 eviction keeps it bounded).

### 3.2 Session-list incremental sync (on connect / foreground / turn boundary)

- **Triggers (all already exist in the store graph):** post-connect
  `startHydration → sessionStore.refresh()`; the 30 s foreground heartbeat;
  `drawerOpenRefresh()`; the debounced 400 ms `scheduleSessionRefresh()` on
  `message.start`/`message.complete`; the `broadcast_gap` recovery path.
- **Fetch:** the same `GET /api/sessions?limit=N&order=recent` the app already
  issues. No new network call is introduced; the cache rides the existing one.
- **Diff:** compare each returned row's `{last_active, message_count, title,
  archived}` against the cached `SessionCacheRecord`. Any difference marks the
  session **dirty** (its transcript, if cached, is stale → re-fetch lazily on
  next open). The pair `(last_active, message_count)` detects every mutation:
  new message ⇒ both advance; rename ⇒ only `title`; archive ⇒ only `archived`.
- **Upsert, never wholesale-replace the table.** A partial page (limit < total)
  must NOT evict cached sessions absent from the page — they may simply be below
  the window. Deletion is detected only via `total` + explicit absence across a
  full enumeration, never inferred from one page.

### 3.3 Transcript sync (lazy, human-only, on open + on dirty)

- **On open (warm path):** if `session_cache.transcriptCachedAt != nil`, load
  rows by `(sessionId, ordinal)`, rebuild `[StoredMessage] → toChatMessages`,
  and seed the chat **before** any network call. Instant paint.
- **Re-fetch trigger:** the session is dirty (from §3.2 diff) OR a
  `message.complete` broadcast carried this `stored_session_id`. Then the live
  `seedTranscript` REST fetch runs in the background and **reseeds** through
  `reconcileMessages` (identity-preserving in-place merge — Batch E, landed).
- **Persist after live seed:** on a successful live fetch, overwrite this
  session's `message_row_cache` rows with the fresh `[StoredMessage]`, set
  `transcriptCachedAt`, and update `maxMessageId`. Fire-and-forget; off the UI
  path.
- **Cron sessions are never transcript-cached** (decided scope). The list row is
  still cached (so the drawer renders), but opening a cron session always goes
  straight to the live fetch — no `message_row_cache` rows are written for it.

### 3.4 The per-session cursor (and why it can't be the session row)

The wire `id` is a **global** SQLite autoincrement (verified: session A first id
156875, session B first id 156982 — globally ordered, gaps between sessions,
`sequence_num` null everywhere). Within a session, `id` is monotonic but not
contiguous. **The session-list row carries `message_count` but NOT the max
message `id`**, so the cache cannot derive an after-id cursor from the list
alone — it must track `maxMessageId` itself from the rows it has persisted.
That cursor is what a v2 `after_id` endpoint (§3.7) would consume; in v1 it is
used to classify a re-fetch as append-only (new `wireId > maxMessageId`) vs a
rewind (rows vanished from the middle — handled because the wire's `active=1`
clause already excludes rewound messages, and the full re-fetch replaces them).

### 3.5 Real-time apply from broadcast frames

The app already consumes the `HERMES_GATEWAY_BROADCAST=1` JSON-RPC channel. The
cache reacts to settled frames only (it never persists in-flight deltas):

| Frame | `stored_session_id`? | Cache action |
|---|---|---|
| `message.complete` | yes | mark that session dirty; if its transcript is cached, schedule a background re-fetch+repersist for it specifically (effective single-session delta) |
| `message.start` | yes | mark session live/active (metadata only) |
| `message.delta` | n/a | ignore for persistence (buffered live in `ChatStore`, persisted only at `message.complete`) |
| `session.info` | yes | merge changed metadata fields into the cached summary blob |
| `gateway.ready` | n/a | trigger a session-list cold sync (§3.2) |
| `tool.*` | n/a | no persistence mutation |

`message.complete` is the key lever: it names the exact dirty session, so in
practice the effective delta window is **one session at a time** even without a
delta endpoint — only that transcript re-fetches, never the whole list.

### 3.6 Conflict / staleness / eviction

- **Staleness model:** the gateway is always authoritative. The cache is a
  read-through view; on any conflict the live fetch wins and overwrites. There
  is no offline write path (the app sends turns live), so there are no
  client-side mutations to reconcile — eliminating the hard half of offline
  sync entirely.
- **Stale-render window:** the user may see cached data for one Tailscale RTT
  (~100–300 ms) before the background fetch lands and merges. Acceptable and
  invisible thanks to identity-preserving `reconcileMessages` (no remount).
- **Eviction (~1-year horizon, pinned additive):** a sweep deletes transcript
  rows for human sessions not opened/active in ~1 year and not pinned:
  ```sql
  DELETE FROM message_row_cache
  WHERE sessionId IN (
    SELECT id FROM session_cache
    WHERE isPinned = 0
      AND COALESCE(lastActive, lastAccessedAt) < :cutoff
  );
  -- then clear transcriptCachedAt/maxMessageId for those sessions
  ```
  The session-list **row** is kept (the drawer still lists it); only the
  transcript body is evicted, so re-opening re-fetches lazily. `lastAccessedAt`
  is bumped by `touchSession` on every open so an actively-used session never
  ages out. Eviction runs opportunistically (on launch, throttled to ~once/day
  via a `sync_meta` timestamp), never on the hot path.

### 3.7 Optional v2 server additions (separate, additive, NOT in this contract)

If true delta is later desired (pure-Python, no schema change, no migration):

1. `GET /api/sessions?updated_after=<unix_float>` → `WHERE last_active > ?`
   (the field is already computed). ~5 lines.
2. `GET /api/sessions/{id}/messages?after_id=<int>` → `AND id > ?` in
   `get_messages`. ~3 lines.
3. Add `last_message_id` (`SELECT MAX(id) …`) to the session-list row so the
   cache learns its cursor without opening the transcript.

The iOS cache negotiates via the existing `ServerCapabilities` probe: a
`deltaSync` capability flips the cursor (`maxMessageId`, `lastFullFetchAt`) from
"classify a full re-fetch" to "request only new rows." A stock/older gateway
stays on the v1 full-fetch-diff path byte-for-byte. These are explicitly OUT of
this contract.

---

## 4. INTEGRATION SEAMS — where the cache wires in (P3)

The entire integration is a vertical slice through **two write sites** in
`SessionStore` plus opportunistic reads; `ConnectionStore` needs **zero
changes** (its existing triggers already fan to those sites). All line cites
verified.

### 4.1 SessionStore.swift — session list

- `var sessions: [SessionSummary]` (line 17) is the `@Observable` source of
  truth; all derived slices (`visibleSessions`, `pinnedSessions`,
  `unpinnedSessions`, `workspaceGroups()`) compute from it. The cache sits
  **behind** it.
- **Cold-launch read** — at the TOP of `refresh()` (line 531), on first call
  (or after `resetInitialFill()`): before the network fetch, populate `sessions`
  from `cacheStore.loadSessionList()`. The drawer paints from disk immediately;
  `ensureInitialFill`'s fast-path (`visibleSessions.count >= 30`) fires on warm
  launch because the full raw list (cron included) is loaded and the 30 target
  counts post-`hideCron` VISIBLE rows.
- **Post-fetch write** — after each `mergeSessionPage(_:total:)` call (lines
  ~545/580/608/643): `Task { try? await cacheStore.saveSessionList(sessions) }`,
  fire-and-forget, off the UI path. No change to `mergeSessionPage`,
  `visibleSessions`, `loadMore`, or `ensureInitialFill` — the cache is pure
  persistence behind `sessions`.
- The existing `sessionsFetch` closure override (line ~1717) is **not** used by
  the cache; the cache operates at the `sessions`-array level, not the fetch
  level. Persist the **raw** list (cron rows survive); `hideCron` stays a
  read-time filter, so a filter flip never invalidates the cache.

### 4.2 ChatStore.swift + SessionStore.seedTranscript — transcript

- `seed(from stored: [StoredMessage])` (ChatStore ~1722) is the ONLY wholesale
  transcript replacement; it calls `toChatMessages → reconcileMessages`. The
  cache stores `[StoredMessage]`, never `ChatMessage`/`ChatMessagePart` —
  reconstruction always goes through this deterministic path.
- The seam is inside `private func seedTranscript(storedId:token:)`
  (SessionStore line 1738):
  - **Warm open (read):** before the REST fetch, if
    `cacheStore.hasTranscript(storedId)` (human session, transcript cached),
    rebuild `[StoredMessage]` from rows and `chat.seed(from: cached)`
    immediately — instant paint from disk.
  - **Post-seed write:** after the live fetch returns and `chat.seed(from:
    stored)` succeeds (~line 1747), `Task { try? await
    cacheStore.saveTranscript(sessionId:, messages: stored) }`. Fire-and-forget.
  - `touchSession(storedId)` is called here too, bumping `lastAccessedAt` for
    eviction.
- `backfill()` (ChatStore ~2274) is the foreground/reconnect reconcile path; it
  re-runs `rest.messages → seed`, so it flows through the SAME seam and keeps
  the cache warm with no extra logic. `transcriptFetch`/`backfillFetch`
  overrides are NOT used by the cache.
- **Cron exclusion enforced here:** the write half checks `summary.source !=
  "cron"` before persisting transcript rows.

### 4.3 ConnectionStore.swift — sync triggers (no changes needed)

ConnectionStore owns no session/transcript data; it is the lifecycle
coordinator and its existing trigger points already call the seamed methods:

| Trigger | Calls | Cache effect (automatic) |
|---|---|---|
| `startHydration()` (~351) | `sessionStore.refresh()` | cold-launch read + post-fetch write |
| `recoverActiveSession()` (~802–831) | `chatStore.backfill()` + `refresh()` | transcript re-persist + list write |
| `handleScenePhase(_:)` foreground (~842–873) | `backfill()` + `scheduleSessionRefresh()` | same |
| `route(event:)` `broadcast_gap` (~469–474) | `backfill()` + `refresh()` | same |
| `scheduleSessionRefresh()` on turn boundary (~522–527) | debounced `refresh()` | list write |

ConnectionStore needs **no** cache reference, **no** protocol change, **no** new
task. The cache injects via `SessionStore`/`ChatStore` initializers (a single
`CacheStore` instance owned by `AppEnvironment`).

### 4.4 Dependency injection

`AppEnvironment` constructs one `CacheStore` actor and passes it to
`SessionStore` and `ChatStore` at init (new optional param, defaulting to a
no-op cache for tests/previews so existing call sites compile). This is the only
existing-file touch outside the two stores, and it is part of P3.

---

## 5. PHASED BUILD PLAN

| Phase | Contents | Files | Gating |
|---|---|---|---|
| **P1 — Storage layer** | `CacheStore` actor; `SessionCacheRecord`, `MessageRowRecord`, `SyncMetaRecord`; `CacheSchema` migrator (v1); cache-side `StoredMessage`/`SessionSummary` Codable mirrors; `DatabaseQueue` open in App Support + backup-exclude + WAL. Unit tests: save/load round-trip, eviction sweep, migration idempotency, cron-exclusion. | ALL NEW + `project.yml` GRDB add | **UNBLOCKED — BUILD NOW.** Touches no existing Swift file (project.yml is config). |
| **P2 — Sync engine** | `CacheSyncEngine` (new): list diff (`last_active`+`message_count`), dirty-set tracking, broadcast-frame → cache-action mapping, `maxMessageId` cursor logic, `ServerCapabilities.deltaSync` negotiation stub (v1 path only). Pure logic over `CacheStore`; no store wiring. Unit tests with recorded fixtures. | ALL NEW | **UNBLOCKED — BUILD NOW.** Independent of P1 internals via the `CacheStore` actor interface; parallelizable with P1 once the actor signature is frozen. |
| **P3 — Wiring** | The §4 seams: cold-launch read + post-fetch write in `SessionStore.refresh`; warm-open read + post-seed write + `touchSession` in `seedTranscript`; `CacheStore` injection via `AppEnvironment`. | EDITS to `SessionStore.swift`, `ChatStore.swift` (minimal), `AppEnvironment.swift` | **GATED — wire AFTER the scroll-rebuild (`DrawerView`/`DrawerSessionRow`) + craft-cleanup waves land.** The seams don't intersect those diffs (they're in `SessionStore` private plumbing), but sequencing avoids merge churn. Batch E `reconcileMessages` is LANDED, so the transcript seam is otherwise unblocked. |
| **P4 — Backfill UX + eviction + offline state** | First-run backfill progress affordance (session list only — lazy transcripts need none); the throttled daily eviction sweep + pinned exemption + `touchSession` bumps; an offline/stale badge surfaced from `ConnectionStore` connection state (rendered-from-cache indicator). | EDITS (small) + maybe 1 new view | **GATED — after P3.** UX polish; the eviction/touch logic itself can be built in P1 and merely activated here. |

Parallelism: **P1 and P2 run concurrently NOW** (freeze the `CacheStore` actor
signature first so P2 can compile against it). **P3 and P4 wait** for the
current waves; P3 is mechanical once P1/P2 land. The scroll-rebuild work lives
entirely in `DrawerView`/`DrawerSessionRow` and does not touch
`SessionStore.sessions`, `refresh()`, or `seedTranscript`, so the two efforts
land independently — only ordering, not content, gates P3.

---

## 6. RISKS

- **Storage size.** Session-list rows are tiny (~1 KB blob each × a few thousand
  = a few MB). Transcripts are the variable cost, but bounded by lazy-on-open +
  the ~1-year eviction sweep + pinned-only retention. A heavy user converges to
  their opened-human working set, not the full 4600-session corpus. Mitigation:
  WAL checkpointing, the daily eviction throttle, and a hard ceiling guard
  (optional P4: evict oldest-accessed beyond an N-MB budget even within the
  1-year window). Cron transcripts (the highest-volume, lowest-value rows) are
  never stored at all.
- **Sync correctness.** No delta endpoint means full-fetch-diff; the risk is a
  missed mutation. The `(last_active, message_count)` pair plus the
  `message.complete` broadcast cover every observed mutation class, but a
  mutation that changes neither (none known today) would be missed until the
  next full fetch — acceptable since the gateway is always authoritative and the
  next refresh overwrites. Partial-page eviction is explicitly avoided (a
  session below the window must never be dropped). Rewinds are handled by the
  wire's `active=1` filter + full transcript replace.
- **Migration.** `DatabaseMigrator` numbered migrations + JSON-blob bodies make
  most evolution zero-migration; the drop-and-rebuild escape hatch guarantees no
  user is ever stranded mid-TestFlight (the cache is 100% reconstructible). The
  residual risk is a GRDB major-version bump changing migration semantics —
  pinned via `from: "7.0.0"` and gated by the build pipeline.
- **Remote-Tailscale latency (the whole point).** This is the risk the feature
  targets: every cold launch / session open / foreground reconnect currently
  blocks on a remote RTT. The cache removes the network from the hot path
  entirely; the residual is the ~100–300 ms stale-render window before the
  background fetch merges, made invisible by identity-preserving
  `reconcileMessages`. If the gateway is unreachable, the app is fully usable
  read-only from cache — the offline-first promise. The one regression to guard
  in QA: the background fetch must never block, double-paint, or remount over
  the cached render (covered by the §-bar acceptance invariant and P3 tests).
