# Lane G — Phase 2: Durable User Work & Transfers

## DURABILITY CONTRACT

### 1. Ownership, location, protection, and Phase-1 identity dependency

Phase 2 introduces one cross-process `WorkRepository` for user-created work. It is a GRDB-backed SQLite database in the existing `group.ai.hermes.mobile` app-group container so both `HermesMobile` and `HermesShare` can open it. The implementation must add GRDB and the shared repository sources to the `HermesShare` target in `apps/ios/project.yml`; the current cache database at `Application Support/HermesMobile/hermes_cache.sqlite` is main-app-only and is not the common work database.

The file name is `hermes_work.sqlite`. Create it with WAL, foreign keys enabled, a 5-second busy timeout, atomic GRDB transactions, and `NSFileProtectionCompleteUntilFirstUserAuthentication`. Exclude it, its WAL/SHM companions, and reconstructible attachment files from backup. Store no bearer token, cookie, Keychain secret, or absolute path in this database. Each process owns its own GRDB connection/pool; leases and transactions, rather than process-local flags, serialize drainers. If protected data is unavailable, the share extension must report that it could not queue the item and must not claim success.

**Hard dependency — Phase-1 identity migration:** the DDL below names the semantic scope columns `server_id` and `profile_id`. Their exact SQL types, canonical values, collation, and Swift construction must be the ones committed by the Phase-1 identity migration. Phase 2 must import that scope type/normalizer and must not introduce a second URL/profile parser. If Phase 1 replaces these with a scope primary key, use that foreign key in every place marked `server_id, profile_id` below. The current cache v2 migration merely adds scope columns to globally keyed rows, so it is not a safe identity contract to copy.

### 2. SQLite schema

The following is normative logical DDL. A GRDB migration may express the same constraints using the Phase-1 physical scope key.

```sql
CREATE TABLE drafts (
    draft_id TEXT PRIMARY KEY NOT NULL,
    server_id TEXT NOT NULL,
    profile_id TEXT NOT NULL,
    context_key TEXT NOT NULL,             -- "new" or "session:<stored id>"
    stored_session_id TEXT,
    text TEXT NOT NULL DEFAULT '',
    cwd TEXT,
    model_selection_json TEXT,
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL,
    CHECK (length(context_key) > 0),
    UNIQUE (server_id, profile_id, context_key)
);

CREATE INDEX drafts_scope_updated
    ON drafts(server_id, profile_id, updated_at DESC);

CREATE TABLE work_jobs (
    job_id TEXT PRIMARY KEY NOT NULL,
    kind TEXT NOT NULL CHECK (kind IN ('prompt', 'share', 'app_intent')),
    client_message_id TEXT NOT NULL,

    -- A share may be captured before a destination is configured. Scope columns
    -- are otherwise mandatory and must become immutable when the job is claimed.
    server_id TEXT,
    profile_id TEXT,
    CHECK ((server_id IS NULL) = (profile_id IS NULL)),

    state TEXT NOT NULL CHECK (state IN (
        'waiting_for_scope', 'queued', 'creating_destination', 'uploading',
        'submitting', 'accepted', 'retry_wait', 'failed', 'completed',
        'cancelled', 'expired'
    )),
    intent_kind TEXT CHECK (
        intent_kind IS NULL OR
        intent_kind IN ('ask_hermes', 'open_sessions', 'new_session')
    ),
    text TEXT,
    source_url TEXT,
    comment TEXT,
    stored_session_id TEXT,                -- requested existing session, if any
    destination_session_id TEXT,           -- created/resolved destination; persist once
    payload_hash TEXT NOT NULL,             -- SHA-256 over canonical immutable payload
    attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
    next_attempt_at REAL,
    last_error_code TEXT,
    last_error_message TEXT,
    lease_owner TEXT,
    lease_expires_at REAL,
    expires_at REAL,
    legacy_import_key TEXT UNIQUE,
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL,
    accepted_at REAL,
    completed_at REAL
);

CREATE UNIQUE INDEX work_jobs_scoped_client_message
    ON work_jobs(server_id, profile_id, client_message_id)
    WHERE server_id IS NOT NULL AND profile_id IS NOT NULL;
CREATE INDEX work_jobs_drain
    ON work_jobs(state, next_attempt_at, created_at);
CREATE INDEX work_jobs_scope_state
    ON work_jobs(server_id, profile_id, state, created_at);

CREATE TABLE work_assets (
    asset_id TEXT PRIMARY KEY NOT NULL,
    relative_path TEXT NOT NULL UNIQUE,      -- relative to protected app-group asset root
    mime_type TEXT NOT NULL,
    byte_count INTEGER NOT NULL CHECK (byte_count >= 0),
    sha256 TEXT NOT NULL,
    created_at REAL NOT NULL,
    last_accessed_at REAL NOT NULL
);

CREATE TABLE job_assets (
    job_id TEXT NOT NULL REFERENCES work_jobs(job_id) ON DELETE CASCADE,
    asset_id TEXT NOT NULL REFERENCES work_assets(asset_id) ON DELETE RESTRICT,
    ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
    transfer_id TEXT,
    remote_path TEXT,
    state TEXT NOT NULL CHECK (state IN ('local', 'transferring', 'uploaded', 'failed')),
    PRIMARY KEY (job_id, ordinal),
    UNIQUE (job_id, asset_id)
);

CREATE TABLE draft_assets (
    draft_id TEXT NOT NULL REFERENCES drafts(draft_id) ON DELETE CASCADE,
    asset_id TEXT NOT NULL REFERENCES work_assets(asset_id) ON DELETE RESTRICT,
    ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
    PRIMARY KEY (draft_id, ordinal),
    UNIQUE (draft_id, asset_id)
);

CREATE TABLE transfers (
    transfer_id TEXT PRIMARY KEY NOT NULL,
    background_session_id TEXT NOT NULL,
    task_identifier INTEGER,
    direction TEXT NOT NULL CHECK (direction IN ('upload', 'download')),
    purpose TEXT NOT NULL CHECK (purpose IN ('prompt_asset', 'share_asset', 'attachment', 'export')),
    server_id TEXT NOT NULL,
    profile_id TEXT NOT NULL,
    owner_job_id TEXT REFERENCES work_jobs(job_id) ON DELETE SET NULL,
    source_relative_path TEXT,
    destination_relative_path TEXT,
    request_url TEXT NOT NULL,
    request_method TEXT NOT NULL,
    mime_type TEXT,
    expected_bytes INTEGER,
    transferred_bytes INTEGER NOT NULL DEFAULT 0,
    resume_data BLOB,
    state TEXT NOT NULL CHECK (state IN (
        'prepared', 'running', 'suspended', 'retry_wait', 'succeeded',
        'failed', 'cancelled'
    )),
    attempt_count INTEGER NOT NULL DEFAULT 0,
    next_attempt_at REAL,
    last_error_code TEXT,
    last_error_message TEXT,
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL,
    completed_at REAL
);

CREATE UNIQUE INDEX transfers_background_task
    ON transfers(background_session_id, task_identifier)
    WHERE task_identifier IS NOT NULL;
CREATE INDEX transfers_resume
    ON transfers(state, next_attempt_at, created_at);
```

`drafts` is an autosave snapshot, not an event log. One row exists per Phase-1 scope and composer context. `work_jobs` is the single durable source of truth for prompt sends, share deliveries, and App Intent work; `QueueStore`, `PendingIntent`, and the JSON share inbox cease to be writers after migration. `work_assets` owns copied bytes until no draft/job references them. `transfers` is part of the frozen contract but its manager can be implemented independently of the outbox processor.

### 3. Job invariants and transitions

- Write the job and its copied assets before starting an upload, creating a session, or calling `prompt.submit`. Every retry reuses `job_id`, `client_message_id`, and immutable `payload_hash`.
- Normal delivery is `waiting_for_scope -> queued -> creating_destination -> uploading -> submitting -> accepted -> completed`; stages that do not apply are skipped. Failures enter `retry_wait` with bounded exponential backoff and then `failed` after the retry policy is exhausted. `cancelled` and `expired` are terminal.
- Claim work with an atomic compare-and-set lease. A process may take a job only when its lease is absent/expired. Every external side effect is preceded by a durable state update. Relaunch recovers expired leases and resumes from the last completed stage.
- A newly created destination session is written to `destination_session_id` immediately after `session.create` succeeds and before any attachment or prompt call. Retries always reuse it; they never create another session for the same job.
- A prompt is removed from visible pending work only after an idempotent `prompt.submit` response says `accepted: true`. `streaming`, `queued`, and `steered` are all accepted server dispositions. `completed` means local post-acceptance cleanup has committed; it does not wait for the assistant's final answer.
- Draft deletion is in the same local transaction that records its derived job. The draft row is retained if job creation fails. For an existing-session composer, clear the acknowledged draft only when its revision/payload still equals the sent revision so later typing is never erased.
- Share capture is capped at 20 live share jobs and 100 MiB total copied assets. Default share expiry is 14 days (within R-58's 7–30 day bound). Expired rows and unreferenced files are deleted by maintenance. App Intent jobs are capped at 20 and expire after 24 hours. Ordinary prompt jobs do not expire automatically.
- A share extension that cannot read the current Phase-1 scope writes `waiting_for_scope`; the main app binds it exactly once to the selected scope before claiming it. Once claimed, scope and destination are immutable.
- UI groups `waiting_for_scope`, `queued`, `creating_destination`, `uploading`, `submitting`, and `retry_wait` as **Waiting/Sending**; `failed` as **Failed** with Retry/Delete; `accepted`/`completed` as **Sent**. Retry never creates a new client id. Delete removes files only after references reach zero.

### 4. Legacy migration

The first repository open performs idempotent, crash-safe imports:

1. Import every `QueueStore` `QueuedPrompt` from `DefaultsKeys.queue` as `kind='prompt'`, using its UUID as both `job_id` and stable `client_message_id`, and `legacy_import_key='queue:<uuid>'`.
2. Import the one legacy `PendingIntent` value as a job with `legacy_import_key='pending-intent:v1:<payload-hash>'`. Clear the UserDefaults key only after the insert transaction commits.
3. Import each `SharedInboxItem` and its copied image files with `legacy_import_key='share:<uuid>'`. Remove that JSON entry only after the database rows and asset ownership commit; do not delete its files during import.
4. Reopening after a crash is harmless because `legacy_import_key` is unique. Retain read/import compatibility for one release, instrument only local diagnostics, then delete the obsolete writers and keys.

### 5. `prompt.submit(client_message_id)` server idempotency contract

Current `tui_gateway/server.py:8505-8593` accepts only `session_id`, `text`, and optional `truncate_before_user_ordinal`; it immediately returns `{status: streaming}` after starting a thread. The busy path at `tui_gateway/server.py:5131-5162` returns `queued` or `steered`, and `_enqueue_prompt` currently merges multiple inputs into one process-memory slot. There is no durable request identity.

The additive wire contract is:

```json
{
  "session_id": "runtime-session-id",
  "text": "hello",
  "client_message_id": "lowercase UUID string"
}
```

- `client_message_id` is optional for backward compatibility. When absent, response shapes and behavior remain byte-compatible with current clients.
- When present, validate a canonical UUID before any mutation; malformed values return JSON-RPC error `4004`. The idempotency key is `(resolved Hermes profile/home, stored session key, client_message_id)`, not merely the transient WebSocket session id. Store a SHA-256 of canonical submit semantics (`text`, truncation target, attachment identities, and destination) and never raw credentials.
- The first caller durably reserves the key before `_handle_busy_submit`, history truncation, `_start_inflight_turn`, attachment consumption, or thread creation. The reservation and accepted receipt live in a plugin-owned SQLite ledger under the resolved Hermes home. A same-key/same-hash duplicate does not execute any of those paths and returns the original disposition with `accepted: true`, the same `client_message_id`, and `deduplicated: true`. A same-key/different-hash request returns conflict error `4091` and performs no side effect.
- First-accept responses add `accepted: true`, `client_message_id`, and `deduplicated: false` to the current disposition (`streaming`, `queued`, or `steered`). Mobile deletes the job only for `accepted: true`. A reservation that cannot be proven accepted after a process crash returns `status: indeterminate`, `accepted: false`; it is not silently executed again. The job remains visible for reconciliation/manual retry, preventing ambiguous network failure from double-submitting.
- The accepted receipt must be committed before its success response is written. Retain accepted receipts for at least 30 days and prune only terminal receipts older than that. Concurrent duplicates are serialized by the unique key and return one canonical receipt.
- This contract is idempotent **acceptance**, not transactional exactly-once model execution. No client/server protocol can atomically couple a SQLite receipt to an arbitrary agent/tool run. The explicit `indeterminate` state closes the dangerous ambiguity by refusing an automatic second execution.

Hermes core must remain narrow. The durable ledger, hashing, retention, and tests belong in `plugins/hermes-mobile/`. The minimal core change is a generic prompt-submit idempotency provider seam around the existing handler, registered only when the plugin loads; without a provider, the optional field is ignored/current behavior remains unchanged. `tui_gateway/server.py` is a PATCHED-CORE file in this fork. This is a new core-adjacent seam and must be reviewed as a de-patch-aware addition to `CONTRACT-DEPATCH.md` (do not bury the ledger itself in core). The review must verify prompt caching and user/assistant alternation are unchanged.

### 6. Background `URLSession` TransferManager contract

`TransferManager` uses one stable identifier, `ai.hermes.mobile.background-transfer.v1`, and recreates `URLSessionConfiguration.background(withIdentifier:)` with `sessionSendsLaunchEvents = true`, `waitsForConnectivity = true`, and `isDiscretionary = false` for user-initiated work. Upload bodies are protected files and use `uploadTask(with:fromFile:)`; never use in-memory `Data` or a foreground `session.data(for:)` for a durable transfer. Set `taskDescription = transfer_id`, persist the `transfers` row and assigned `taskIdentifier` before `resume()`, and reconcile `getAllTasks()` against SQLite on every launch.

The transfer database stores no Authorization value. Requests are formed from the Keychain-backed credential at task creation; logs and persisted diagnostics redact headers. Delegate callbacks transactionally update byte counts/state. Download callbacks move the system temporary file into the protected destination before returning. Completion is idempotent: a callback for an already terminal row is ignored, and a success wakes the owning job without directly submitting it.

`AppDelegate.application(_:handleEventsForBackgroundURLSession:completionHandler:)` hands the completion handler to `TransferManager` for the matching identifier. The manager is initialized during app launch early enough to recreate the same session, keeps one handler per identifier, and calls it exactly once on the main queue from `urlSessionDidFinishEvents(forBackgroundURLSession:)` after SQLite/file updates and client notifications finish. Unknown identifiers are completed safely and logged locally. Cancellation, retry/backoff, missing source files, orphaned system tasks, and orphaned rows have explicit reconciliation paths.

This manager is independent of the OutboxRepository behavior implementation: it may be built in parallel against the frozen `transfers` contract and Phase-1 scope type. The final prompt/share integrations consume it. Simulator tests cover state machines, but suspension, force-termination, relaunch delivery, Keychain availability, and completion-handler behavior require a physical-device test plan.


---

# FULL PHASE-2 ISSUE DRAFTS (recovered from lane final message)

I completed the specification, but could not write the requested file: the sandbox rejected `/Users/abbhinnav/Developer/products/hermes-loop/...` because only the Hermes Mobile workspace is writable. No substitute file was created.

The complete intended contents follow.

---

# Lane G — Phase 2: Durable User Work & Transfers

## DURABILITY CONTRACT

### Repository ownership and protection

Phase 2 introduces one cross-process `WorkRepository` for drafts, prompt outbox items, share jobs, and App Intent jobs.

- Store `hermes_work.sqlite` in the existing `group.ai.hermes.app` app-group container so `HermesMobile` and `HermesShare` can open it.
- Link GRDB and the shared repository sources into `HermesShare` through `apps/ios/project.yml`. GRDB is currently linked only to `HermesMobile` at `project.yml:22-26,48-51,116-129`.
- Do not reuse `CacheStore`’s main-app-only `Application Support/HermesMobile/hermes_cache.sqlite` (`CacheStore.swift:12-14,54-70`).
- Enable WAL, foreign keys, and a five-second busy timeout. Each process owns its own GRDB connection; SQLite transactions and expiring leases coordinate drainers.
- Apply `NSFileProtectionCompleteUntilFirstUserAuthentication` to the database and durable work assets. Exclude reconstructible files from backup.
- Store no bearer token, cookie, Keychain secret, or absolute path.
- If protected storage is unavailable, the share extension must report failure and must not tell the user that the share was queued.

Hard dependency: every semantic `server_id`/`profile_id` reference below must use the exact SQL representation and Swift normalizer delivered by the **Phase-1 identity migration**. If Phase 1 introduces a `scope_id` foreign key, substitute it everywhere rather than creating parallel identity logic.

Current `CacheSchema` is not safe to copy: `session_cache.id` remains the sole primary key (`CacheSchema.swift:47-73`), while v2 merely adds `serverId/profileId` columns and an index (`CacheSchema.swift:117-149`). `CacheStore.saveSessionList` still fetches existing rows by global session ID (`CacheStore.swift:98-110`).

### Normative logical schema

```sql
CREATE TABLE drafts (
    draft_id TEXT PRIMARY KEY NOT NULL,
    server_id TEXT NOT NULL,
    profile_id TEXT NOT NULL,
    context_key TEXT NOT NULL,             -- "new" or "session:<stored id>"
    stored_session_id TEXT,
    text TEXT NOT NULL DEFAULT '',
    cwd TEXT,
    model_selection_json TEXT,
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL,
    UNIQUE (server_id, profile_id, context_key)
);

CREATE INDEX drafts_scope_updated
    ON drafts(server_id, profile_id, updated_at DESC);

CREATE TABLE work_jobs (
    job_id TEXT PRIMARY KEY NOT NULL,
    kind TEXT NOT NULL
        CHECK (kind IN ('prompt', 'share', 'app_intent')),
    client_message_id TEXT NOT NULL,

    -- Share capture may precede pairing/scope availability.
    server_id TEXT,
    profile_id TEXT,
    CHECK ((server_id IS NULL) = (profile_id IS NULL)),

    state TEXT NOT NULL CHECK (state IN (
        'waiting_for_scope',
        'queued',
        'creating_destination',
        'uploading',
        'submitting',
        'accepted',
        'retry_wait',
        'failed',
        'completed',
        'cancelled',
        'expired'
    )),

    intent_kind TEXT CHECK (
        intent_kind IS NULL OR
        intent_kind IN ('ask_hermes', 'open_sessions', 'new_session')
    ),

    text TEXT,
    source_url TEXT,
    comment TEXT,
    stored_session_id TEXT,
    destination_session_id TEXT,

    payload_hash TEXT NOT NULL,
    attempt_count INTEGER NOT NULL DEFAULT 0
        CHECK (attempt_count >= 0),
    next_attempt_at REAL,
    last_error_code TEXT,
    last_error_message TEXT,

    lease_owner TEXT,
    lease_expires_at REAL,
    expires_at REAL,

    legacy_import_key TEXT UNIQUE,
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL,
    accepted_at REAL,
    completed_at REAL
);

CREATE UNIQUE INDEX work_jobs_scoped_client_message
    ON work_jobs(server_id, profile_id, client_message_id)
    WHERE server_id IS NOT NULL AND profile_id IS NOT NULL;

CREATE INDEX work_jobs_drain
    ON work_jobs(state, next_attempt_at, created_at);

CREATE INDEX work_jobs_scope_state
    ON work_jobs(server_id, profile_id, state, created_at);

CREATE TABLE work_assets (
    asset_id TEXT PRIMARY KEY NOT NULL,
    relative_path TEXT NOT NULL UNIQUE,
    mime_type TEXT NOT NULL,
    byte_count INTEGER NOT NULL CHECK (byte_count >= 0),
    sha256 TEXT NOT NULL,
    created_at REAL NOT NULL,
    last_accessed_at REAL NOT NULL
);

CREATE TABLE job_assets (
    job_id TEXT NOT NULL
        REFERENCES work_jobs(job_id) ON DELETE CASCADE,
    asset_id TEXT NOT NULL
        REFERENCES work_assets(asset_id) ON DELETE RESTRICT,
    ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
    transfer_id TEXT,
    remote_path TEXT,
    state TEXT NOT NULL
        CHECK (state IN ('local', 'transferring', 'uploaded', 'failed')),
    PRIMARY KEY (job_id, ordinal),
    UNIQUE (job_id, asset_id)
);

CREATE TABLE draft_assets (
    draft_id TEXT NOT NULL
        REFERENCES drafts(draft_id) ON DELETE CASCADE,
    asset_id TEXT NOT NULL
        REFERENCES work_assets(asset_id) ON DELETE RESTRICT,
    ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
    PRIMARY KEY (draft_id, ordinal),
    UNIQUE (draft_id, asset_id)
);

CREATE TABLE transfers (
    transfer_id TEXT PRIMARY KEY NOT NULL,
    background_session_id TEXT NOT NULL,
    task_identifier INTEGER,

    direction TEXT NOT NULL
        CHECK (direction IN ('upload', 'download')),
    purpose TEXT NOT NULL CHECK (
        purpose IN ('prompt_asset', 'share_asset', 'attachment', 'export')
    ),

    server_id TEXT NOT NULL,
    profile_id TEXT NOT NULL,
    owner_job_id TEXT
        REFERENCES work_jobs(job_id) ON DELETE SET NULL,

    source_relative_path TEXT,
    destination_relative_path TEXT,
    request_url TEXT NOT NULL,
    request_method TEXT NOT NULL,
    mime_type TEXT,
    expected_bytes INTEGER,
    transferred_bytes INTEGER NOT NULL DEFAULT 0,
    resume_data BLOB,

    state TEXT NOT NULL CHECK (state IN (
        'prepared',
        'running',
        'suspended',
        'retry_wait',
        'succeeded',
        'failed',
        'cancelled'
    )),

    attempt_count INTEGER NOT NULL DEFAULT 0,
    next_attempt_at REAL,
    last_error_code TEXT,
    last_error_message TEXT,
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL,
    completed_at REAL
);

CREATE UNIQUE INDEX transfers_background_task
    ON transfers(background_session_id, task_identifier)
    WHERE task_identifier IS NOT NULL;

CREATE INDEX transfers_resume
    ON transfers(state, next_attempt_at, created_at);
```

`drafts` is an autosave snapshot, not an event log. `work_jobs` becomes the only durable writer for prompts, shares, and App Intents. `work_assets` owns copied bytes until no job or draft references them. The `transfers` schema is frozen here, but `TransferManager` can be implemented independently of the outbox processor.

### Job transition invariants

- Persist a job and copied assets before uploading, creating a session, attaching an image, or submitting a prompt.
- Reuse the same `job_id`, `client_message_id`, and immutable `payload_hash` for every automatic retry.
- Normal progression is:

  `waiting_for_scope → queued → creating_destination → uploading → submitting → accepted → completed`

  Stages that do not apply are skipped.

- Transient failures enter `retry_wait` with bounded exponential backoff. Exhausted failures enter `failed`. `cancelled` and `expired` are terminal.
- Claim work with an atomic compare-and-set lease. A process may claim only an absent or expired lease. Relaunch recovers expired leases.
- Persist `destination_session_id` immediately after `session.create` and before uploads or submission. Retrying a share or App Intent must reuse that session.
- Remove a prompt from visible pending work only after `prompt.submit` returns `accepted: true`. `streaming`, `queued`, and `steered` are accepted dispositions.
- `completed` means local post-acceptance cleanup committed; it does not wait for the assistant’s final answer.
- Convert a draft into a job transactionally. Retain the draft if job creation fails. Clear only the sent draft revision so typing performed during submission cannot be erased.
- Share jobs are capped at 20 live jobs and 100 MiB of copied assets. Default expiry is 14 days. App Intent jobs are capped at 20 and expire after 24 hours. Ordinary prompt jobs do not expire automatically.
- A share captured without a Phase-1 scope enters `waiting_for_scope`. The main app binds it once before claiming it. Scope and destination become immutable after claim.
- UI mappings:

  - Waiting/Sending: `waiting_for_scope`, `queued`, `creating_destination`, `uploading`, `submitting`, `retry_wait`
  - Sent: `accepted`, `completed`
  - Failed — Retry/Delete: `failed`
  - Cancelled: `cancelled`
  - Expired: `expired`

### Crash-safe legacy migration

1. Import each `QueueStore.QueuedPrompt` from `DefaultsKeys.queue` as a prompt job. Reuse its UUID as `job_id` and `client_message_id`; set `legacy_import_key = "queue:<uuid>"`.
2. Import the legacy `PendingIntent` slot with `legacy_import_key = "pending-intent:v1:<payload-hash>"`. Clear UserDefaults only after commit.
3. Import every `SharedInboxItem` and its image files using `legacy_import_key = "share:<uuid>"`. Remove its JSON entry only after the rows and asset ownership commit.
4. `legacy_import_key` uniqueness makes relaunch after a migration crash harmless.
5. Keep read/import compatibility for one release, then remove the old writers and keys.

### `prompt.submit(client_message_id)` idempotency contract

The current handler at `tui_gateway/server.py:8505-8593` accepts `session_id`, `text`, and optional `truncate_before_user_ordinal`. It starts a thread and immediately returns `{status: "streaming"}`. Busy submissions return `queued` or `steered` through `_handle_busy_submit` (`server.py:5131-5162`). No durable request identity exists.

Add the optional request field:

```json
{
  "session_id": "runtime-session-id",
  "text": "hello",
  "client_message_id": "canonical-lowercase-uuid"
}
```

Contract:

- Omitting `client_message_id` preserves current behavior and response shapes.
- Validate a canonical UUID before mutation. Invalid values return JSON-RPC error `4004`.
- The durable key is `(resolved Hermes profile home, client_message_id)`. The payload hash includes the stored destination session, text, and truncation semantics.
- The first call reserves the key before `_handle_busy_submit`, history truncation, inflight-turn mutation, or thread creation.
- A duplicate with the same hash never executes those paths again. It returns the original disposition plus:

```json
{
  "status": "streaming",
  "accepted": true,
  "client_message_id": "…",
  "deduplicated": true
}
```

- A first acceptance returns the same fields with `deduplicated: false`.
- A same-key/different-hash request returns conflict error `4091` without side effects.
- Concurrent callers serialize through the unique durable key.
- A live reservation not yet accepted returns `status: "in_progress", accepted: false`.
- A reservation left after a gateway crash returns `status: "indeterminate", accepted: false` and is not silently executed again. The mobile job remains visible for reconciliation/manual retry.
- Commit the accepted receipt before writing the success response.
- Retain accepted receipts for at least 30 days.

This is idempotent acceptance, not a transactional guarantee around arbitrary model/tool execution. The explicit indeterminate state prevents an ambiguous network retry from automatically performing a second agent turn.

The implementation must keep the ledger, hashing, and retention inside `plugins/hermes-mobile/`. The minimal core change is a generic prompt-submit idempotency provider seam around the existing handler, registered only when the plugin loads.

`tui_gateway/server.py` is PATCHED-CORE. This new core-adjacent seam requires de-patch-aware review and a new seam entry in `CONTRACT-DEPATCH.md`. It must preserve prompt-cache stability and message-role alternation.

### Background URLSession TransferManager

Use the stable identifier:

```text
ai.hermes.app.background-transfer.v1
```

Configuration:

```swift
let configuration = URLSessionConfiguration.background(
    withIdentifier: "ai.hermes.app.background-transfer.v1"
)
configuration.sessionSendsLaunchEvents = true
configuration.waitsForConnectivity = true
configuration.isDiscretionary = false
```

Required behavior:

- Upload from a protected file with `uploadTask(with:fromFile:)`; never use in-memory `Data` for a durable transfer.
- Set `taskDescription = transfer_id`.
- Persist the transfer and assigned task identifier before `resume()`.
- Reconcile `getAllTasks()` against SQLite on every launch.
- Do not persist Authorization headers. Obtain credentials from Keychain when constructing or recreating a request; redact headers from diagnostics.
- Move a background download’s system temporary file to its protected destination inside the delegate callback.
- Make completion callbacks idempotent. A duplicate callback for a terminal row is ignored.
- A successful transfer wakes its owning job but does not itself call `prompt.submit`.
- `AppDelegate.application(_:handleEventsForBackgroundURLSession:completionHandler:)` forwards the handler to `TransferManager`.
- Recreate the session early during launch. Call the saved completion handler exactly once, on the main queue, from `urlSessionDidFinishEvents(forBackgroundURLSession:)` after repository/file updates finish.
- Unknown identifiers must be completed safely and logged locally.
- Cover cancellation, retry/backoff, missing source files, orphaned system tasks, orphaned rows, authentication failure, and expired resume data.
- Physical-device QA is required for suspension, force termination, relaunch delivery, and completion-handler behavior.

## Build sequence

Issues 2 and 3 can be developed in parallel with Issue 1. All other issues consume the shared repository or the frozen transfer/idempotency contracts.

### ISSUE: Create the protected shared WorkRepository

Phase: 2 | Spec: R-10,R-47,R-48,R-49,R-58 | Priority: high | Labels: type:feature, area:ios  
Depends-on: Phase-1 identity migration | Inherited-context: none | Estimate: L

`QueueStore` currently stores JSON in standard UserDefaults (`QueueStore.swift:3-18,64-71,215-236`). `PendingIntent` uses a single UserDefaults slot (`PendingIntent.swift:68-90`). Shares use app-group UserDefaults plus loose JPEGs (`SharedStore.swift:44-116`, `SharedInboxWriter.swift:25-79`). GRDB is not linked into `HermesShare` (`project.yml:22-26,116-129`).

Implement the contract’s app-group `WorkRepository`, migrations, records, transactional CRUD, asset ownership, job leases, state transitions, and legacy imports. Compile the repository into both the app and share extension. Repository APIs must be async/actor-safe and publish observations on the main actor without making SQLite main-actor-bound.

Out of scope: job draining, server idempotency, transfer execution, and final UI.

Acceptance criteria:

- [ ] The schema matches the durability contract using the Phase-1 scope identity.
- [ ] Both app and share extension can open the same protected database.
- [ ] Two process-local connections can concurrently enqueue without losing either job.
- [ ] No credential or absolute file path is persisted.
- [ ] Legacy QueueStore, PendingIntent, and share items import exactly once across an injected crash/relaunch.
- [ ] Job claiming and lease recovery are atomic and deterministic.
- [ ] Asset deletion occurs only after all draft/job references are removed.
- [ ] A protected-data failure is surfaced rather than reported as successful queueing.

Tests required: new `WorkRepositoryMigrationTests`, `WorkRepositoryLeaseTests`, `WorkRepositoryCrossProcessTests`, `LegacyWorkImportTests`, and a HermesShare repository-open integration test using a temporary app-group URL.

### ISSUE: Add durable client-message receipts to prompt.submit

Phase: 2 | Spec: R-48 | Priority: high | Labels: type:feature, area:server  
Depends-on: none; protocol can land in parallel | Inherited-context: none | Estimate: L

`prompt.submit` currently has no client identity (`tui_gateway/server.py:8505-8593`). Busy submissions mutate a process-memory queue and return immediately (`server.py:5111-5162`). Implement the exact idempotency contract above.

Add a generic provider registry/seam to `tui_gateway/server.py`; implement the SQLite receipt provider under `plugins/hermes-mobile/`, registered from `plugins/hermes-mobile/__init__.py`. Core must contain no mobile-specific database or retention policy.

Out of scope: client outbox UI and exactly-once guarantees for arbitrary agent/tool side effects.

Acceptance criteria:

- [ ] Requests without `client_message_id` retain existing behavior and response shape.
- [ ] A canonical client ID is validated before handler mutation.
- [ ] Repeating an accepted request after disconnect/restart returns the original disposition without starting, queueing, steering, truncating, or attaching another turn.
- [ ] Same ID with changed session/text/truncation returns `4091`.
- [ ] Concurrent identical requests yield one execution and one durable receipt.
- [ ] Live reservations return `in_progress`; abandoned reservations become `indeterminate` and are not automatically re-executed.
- [ ] Receipts are profile-home scoped and pruned only after 30 days.
- [ ] Plugin-disabled parity tests prove the seam has zero behavior change.
- [ ] `CONTRACT-DEPATCH.md` records the seam and de-patch review passes.
- [ ] Prompt caching and strict user/assistant role alternation are unchanged.

Tests required: extend `tests/test_tui_gateway_server.py` and `tests/test_tui_gateway_queue_on_busy.py`; add `tests/plugins/hermes_mobile/test_prompt_idempotency.py` covering replay, conflict, concurrency, restart, profile isolation, expiry, and plugin-disabled parity.

### ISSUE: Build relaunch-safe background TransferManager

Phase: 2 | Spec: R-36 | Priority: high | Labels: type:feature, area:ios  
Depends-on: Phase-1 identity migration only; independent of OutboxRepository behavior | Inherited-context: none | Estimate: L

Current attachment upload builds a complete multipart body in memory and calls foreground `URLSession.data(for:)` through `RestClient.upload` (`RestClient.swift:325-362`). `AttachmentStore.uploadAndAttach` feeds it in-memory JPEG data (`AttachmentStore.swift:139-188`). No background URLSession or relaunch callback exists. `AppDelegate` only forwards APNs registration callbacks (`HermesMobileApp.swift:360-383`).

Implement `TransferRepository`/`TransferManager` against the frozen `transfers` schema and session identifier. Add early app-launch initialization and the background URLSession AppDelegate callback. Route durable attachment uploads through file-backed tasks. Expose generic download/export entry points without creating new artifact/export UX.

Out of scope: BGProcessing maintenance and non-user-visible small JSON sync requests.

Acceptance criteria:

- [ ] Transfer records and task identifiers commit before tasks resume.
- [ ] Uploads use protected files and `uploadTask(with:fromFile:)`.
- [ ] Relaunch reconstructs the identical background session and reconciles system tasks with SQLite.
- [ ] Background completion handlers are invoked exactly once after durable completion processing.
- [ ] Authentication headers are never written to SQLite or logs.
- [ ] Missing files, 401, cancellation, retryable HTTP status, resume-data failure, orphan rows, and orphan tasks reach defined states.
- [ ] A completed transfer wakes its owner job exactly once.
- [ ] A large test upload completes after suspension and after app termination/relaunch on a physical device.

Tests required: `TransferRepositoryTests`, `TransferManagerStateMachineTests`, `BackgroundSessionReconciliationTests`, AppDelegate callback tests, mocked URLProtocol tests, plus a documented physical-device XCTest/manual gate.

### ISSUE: Persist and restore composer drafts

Phase: 2 | Spec: R-10,R-47 | Priority: high | Labels: type:feature, area:ios  
Depends-on: Create the protected shared WorkRepository | Inherited-context: none | Estimate: M

Composer drafts currently live in `SessionStore.composerDrafts` (`SessionStore.swift:224-275`). `ComposerView` writes on every text change, but only into that dictionary (`ComposerView.swift:393-425,674-683`). `startDraft()` retains `draftCwd` only in memory (`SessionStore.swift:2765-2791`), and draft model selection is process memory (`ConnectionStore.swift:165-202`). `AttachmentStore.pending` is also in memory (`AttachmentStore.swift:15-33`).

Replace the dictionary as source of truth with repository-backed scope/context drafts. Debounce text writes by 300–500 ms, flush immediately on context change/backgrounding, copy attachment bytes into `work_assets`, and restore text, cwd, model selection, and attachment order when a scope/context reopens.

On send, transactionally create the prompt job from the current draft revision. Do not clear later edits made while submission is underway.

Out of scope: network submission and transfer execution.

Acceptance criteria:

- [ ] A new-chat draft survives force quit and restores in the same Phase-1 scope.
- [ ] Existing-session drafts restore independently by stored session ID.
- [ ] Drafts never bleed across server/profile scopes.
- [ ] Text, cwd, model/reasoning/fast selection, and pending attachments restore together.
- [ ] Empty drafts are removed after the debounce/flush.
- [ ] Converting a draft to a job and clearing its acknowledged revision is atomic.
- [ ] Typing after send begins cannot be erased by the earlier send’s acknowledgement.
- [ ] Repeated keystrokes do not perform one SQLite transaction per character.

Tests required: `DraftRepositoryTests`, `ComposerDraftPersistenceTests`, `DraftScopeIsolationTests`, attachment restoration tests, and a force-quit/relaunch UI test.

### ISSUE: Drive prompt sends from the durable outbox

Phase: 2 | Spec: R-10,R-48 | Priority: high | Labels: type:feature, area:ios  
Depends-on: Create the protected shared WorkRepository; Add durable client-message receipts to prompt.submit; Build relaunch-safe background TransferManager for attachment jobs | Inherited-context: none | Estimate: L

`QueueStore.drain` removes and persists a prompt before `chat.send`, then reinserts only when `send` returns false (`QueueStore.swift:181-210`). A crash between server acceptance and reinsertion/completion is ambiguous. `ChatStore.send` also appends a local bubble and calls `prompt.submit` directly without a client ID (`ChatStore.swift:1954-2085`).

Make `WorkRepository` the source of truth for both immediate sends and explicitly queued prompts. Persist before the local echo or network call. Add a single leased processor that respects scope/session affinity, creates a draft destination once, uploads durable assets, and submits with the stable `client_message_id`.

Adapt or replace `QueueStore` and `ComposerView.QueueSheet` (`ComposerView.swift:1679-1747`) with observable repository projections. Preserve editing/reordering only while a job is unclaimed. Surface Waiting, Uploading, Sending, Sent, Failed — Retry, and Cancelled states.

Out of scope: waiting for the assistant’s completion before marking Sent.

Acceptance criteria:

- [ ] Every live or queued send is durable before any external side effect.
- [ ] Ambiguous transport retry reuses the same client ID and does not double-submit.
- [ ] A new-session job persists and reuses its destination session across retries.
- [ ] Prompt jobs remain pending until `accepted: true`.
- [ ] `streaming`, `queued`, and `steered` dispositions are treated as accepted.
- [ ] `in_progress` and `indeterminate` remain visible and are not deleted.
- [ ] Attachment-bearing jobs resume from their last uploaded asset.
- [ ] Reconnect, active-runtime binding, and turn completion wake one processor without overlapping drains.
- [ ] Session continuation/restamping preserves existing queue affinity behavior.
- [ ] A failed job offers Retry and Delete; Retry reuses its client ID.
- [ ] Force-killing at every state boundary loses neither the job nor its destination/asset progress.

Tests required: replace/extend `ChatStoreBatchCTests`, `QueueReorderTests`, and `QueueSelfHealTests`; add `OutboxProcessorTests`, idempotency integration tests against the gateway, state-projection tests, and crash-boundary relaunch tests.

### ISSUE: Queue App Intents in WorkRepository

Phase: 2 | Spec: R-49 | Priority: high | Labels: type:fix, area:ios  
Depends-on: Create the protected shared WorkRepository; Drive prompt sends from the durable outbox | Inherited-context: STR-246 | Estimate: M

`PendingIntent.park` explicitly overwrites the previous request (`PendingIntent.swift:68-75`), and `takePending` deletes before applying (`PendingIntent.swift:77-90`). `AskHermesIntent`, `OpenSessionsIntent`, and `NewSessionIntent` all use this singleton (`HermesAppIntents.swift:36-43,58-62,81-84`).

Write each invocation as an independent `app_intent` job. Foreground processing must preserve FIFO order, expiration, stable destination, and stable client ID. Navigation-only intents complete after their local navigation transaction; Ask Hermes flows through the common outbox processor.

Retain one-release import of the legacy slot.

Out of scope: changing Siri phrases or adding new intents.

Acceptance criteria:

- [ ] Rapidly invoking multiple shortcuts preserves every request in order.
- [ ] The 20-job cap and 24-hour expiry are enforced transactionally.
- [ ] Ask Hermes creates/persists at most one destination session per job.
- [ ] Failed prompt submission retains the job and destination instead of overwriting a newer intent.
- [ ] Offline Ask Hermes remains queued and visible.
- [ ] Open Sessions and New Session do not require gateway connectivity.
- [ ] Legacy pending data imports exactly once.

Tests required: extend `PendingIntentDraftTests`; add multi-invocation, expiry/cap, destination-reuse, offline/reconnect, and migration tests.

### ISSUE: Make share delivery durable and user-retryable

Phase: 2 | Spec: R-58 | Priority: high | Labels: type:feature, area:ios  
Depends-on: Create the protected shared WorkRepository; Drive prompt sends from the durable outbox; Build relaunch-safe background TransferManager | Inherited-context: none | Estimate: L

The extension currently writes JPEGs first and then appends JSON to app-group UserDefaults (`SharedInboxWriter.swift:25-79`). The queue has no count, byte, age, retry, state, or protection policy (`SharedStore.swift:44-116`). `SharedInboxDrainer.process` creates a session before loading assets or submitting (`SharedInboxDrainer.swift:121-160`); a later retry creates another session. Image reads and decoding also run through main-actor `Data(contentsOf:)` (`SharedInboxDrainer.swift:163-175`).

Replace the JSON writer with an atomic common-repository insert and protected copied assets. Replace `SharedInboxDrainer` with the leased job processor. Persist the destination immediately after creation, resume uploads through `TransferManager`, and submit with the job’s client ID.

Add a user-visible work/share list reachable from the existing drawer badge or queue surface. It must show state, age, failure, Retry, and Delete.

Out of scope: networking directly from the share extension.

Acceptance criteria:

- [ ] The extension performs no gateway networking.
- [ ] A share is either durably committed with every accepted asset or reported as failed.
- [ ] The 20-job, 100 MiB, and 14-day policies are enforced before accepting new work.
- [ ] An unpaired share enters `waiting_for_scope` and binds once after setup.
- [ ] Destination creation is persisted and never repeated on retry.
- [ ] Failed shares remain visible with Retry/Delete.
- [ ] Retry reuses destination, uploaded assets, and client ID.
- [ ] Delete and expiry remove only unreferenced files.
- [ ] Orphan scanning removes files not referenced by any job/asset row.
- [ ] Main-thread file I/O and image decoding are removed.
- [ ] Existing foreground and connected-edge triggers continue to wake processing.

Tests required: replace/extend `SharedInboxDrainerTests`; add HermesShare repository tests, quota/expiry tests, destination-reuse tests, asset-orphan tests, UI state tests, and a share-extension-to-main-app integration test.

### ISSUE: Add attachment content versions end to end

Phase: 2 | Spec: R-11,R-50 | Priority: high | Labels: type:fix, area:server  
Depends-on: Phase-1 identity migration | Inherited-context: none | Estimate: L

`AttachmentBlobCache.Key` includes scope, session, path, and byte size (`AttachmentBlobCache.swift:40-58`). Its filename hashes scope/path but appends only size as the version (`AttachmentBlobCache.swift:118-133`). `FileViewerView` constructs that key from `FSReadResult.size` (`FileViewerView.swift:229-280`), while `FSReadResult` has no version, modification time, or MIME type (`FileSystemModels.swift:77-127`). `Artifact.blobCacheKey` likewise relies on size (`RestClient+Artifacts.swift:127-140`).

Extend plugin responses:

- `/fs/read`: `content_version`, `modified`, `mime`, and `size`
- `/upload`: `content_version`/SHA-256 and MIME type
- `/attachments/{name}`: strong `ETag`, `Content-Length`, `Last-Modified`, and MIME
- Artifact rows: `content_version` and modification/version metadata where available

For bounded files already read by the endpoint, use a SHA-256 content version. Never expose raw absolute paths in a version token. Older gateways that omit a content version must bypass persistent blob caching rather than fall back to size-only freshness.

Update Swift models and all cache-key call sites to use the Phase-1 scope plus session/path and content version.

Out of scope: cache eviction policy and background transfer implementation.

Acceptance criteria:

- [ ] Replacing a remote file with different bytes but identical path and size produces a different cache key.
- [ ] MIME, byte count, remote modification/version, and content version flow through plugin and Swift models.
- [ ] Uploaded attachment fetches return and honor ETag.
- [ ] Missing version metadata on an older gateway disables disk caching safely.
- [ ] Version calculation does not weaken filesystem sandbox checks.
- [ ] Existing plugin path capability fallback continues to work.
- [ ] No attachment identity is keyed solely by size.

Tests required: plugin pytest for same-size mutation, ETag/conditional fetch, MIME and sandbox behavior; Swift decoding/key tests for `FSReadResult`, `Artifact`, upload results, and legacy server fallback.

### ISSUE: Bound attachment cache and move decoding off main

Phase: 2 | Spec: R-11,R-50 | Priority: high | Labels: type:feature, area:ios  
Depends-on: Add attachment content versions end to end; Phase-1 identity migration | Inherited-context: none | Estimate: L

`AttachmentBlobCache` reads and decodes synchronously (`AttachmentBlobCache.swift:137-158`). The current 365-day `evictStale` exists but is explicitly unwired (`AttachmentBlobCache.swift:30-32,76-78,180-203`). Only `clearAll` exists; no per-scope purge or byte cap is implemented (`AttachmentBlobCache.swift:205-219`).

Refactor the cache into an async actor/service with SQLite metadata:

- Phase-1 scope, session/path, content version, MIME, byte count
- relative filename
- created/last-access times

Initial policy constants:

- 256 MiB disk LRU cap
- 30-day TTL
- 64 MiB decoded-memory cost cap

Use `NSCache` above disk, `CGImageSourceCreateThumbnailAtIndex` for display-size downsampling, and non-main execution for file reads, hashing, and decode. Coalesce last-access writes. Enforce cap after writes and in maintenance. Support per-scope purge, orphan reconciliation, memory warning, and low-disk response.

Out of scope: image prefetching; preserve cache-on-access behavior.

Acceptance criteria:

- [ ] Disk use remains at or below the configured cap after eviction completes.
- [ ] Expired entries, LRU overflow, missing files, and orphan files are reconciled.
- [ ] Forget Gateway can purge one Phase-1 scope without affecting another.
- [ ] MainActor callers never perform disk I/O or full-size image decode.
- [ ] Images are downsampled to the requested display dimensions.
- [ ] Memory warning clears decoded objects without deleting valid disk entries.
- [ ] Low available capacity triggers aggressive LRU cleanup.
- [ ] Same-size content changes remain version-correct.
- [ ] Cache miss/corruption continues to fall through to network.

Tests required: `AttachmentBlobCacheTests` with injectable directory/cap/clock, LRU/TTL/scope/orphan tests, concurrency tests, downsampling pixel-dimension tests, memory-warning tests, and Instruments/main-thread-checker QA.

### ISSUE: Run maintenance with BGProcessingTask

Phase: 2 | Spec: R-35 | Priority: medium | Labels: type:feature, area:ios  
Depends-on: Create the protected shared WorkRepository; Make share delivery durable and user-retryable; Bound attachment cache and move decoding off main; Phase-1 sync/identity work | Inherited-context: none | Estimate: L

The app has no `BGTaskSchedulerPermittedIdentifiers` or background modes (`HermesMobile/Info.plist:1-77`, `project.yml:63-95`). AppDelegate currently registers no launch-time background task handler (`HermesMobileApp.swift:360-383`).

Register `ai.hermes.app.maintenance` during application launch. Add the permitted identifier and `processing` background mode to the XcodeGen source of truth and generated plist. Resubmit after launch and every invocation.

The maintenance coordinator performs bounded, cancellable steps:

1. Session/cache eviction
2. Attachment LRU/TTL/orphan cleanup
3. Orphaned share/work-asset cleanup
4. Expired outbox/App Intent/Inbox cleanup
5. WAL checkpoint and threshold-based vacuum
6. Spotlight authoritative purge/reindex
7. SQLite quick integrity checks

Use no network connection and no hidden keepalive. Observe the expiration handler and report success only according to the coordinator’s explicit result policy.

Acceptance criteria:

- [ ] Registration occurs at app launch before SwiftUI view tasks.
- [ ] Plist/XcodeGen declarations contain the exact identifier and processing mode.
- [ ] A request is scheduled at launch and rescheduled after execution.
- [ ] Every listed maintenance consumer is real and covered; no speculative hook is added.
- [ ] Work is bounded, cancellation-aware, and off main.
- [ ] Vacuum runs only when policy thresholds justify it.
- [ ] Expired work and orphan files are removed without deleting live references.
- [ ] Expiration ends work and calls `setTaskCompleted` exactly once.
- [ ] Unsupported/unavailable scheduler conditions do not affect foreground use.

Tests required: scheduler wrapper tests, `MaintenanceCoordinatorTests`, cancellation/expiration tests, repository cleanup tests, and a device debug invocation using Xcode’s BGTask simulation.

### ISSUE: Flush essential state on app backgrounding

Phase: 2 | Spec: R-37 | Priority: high | Labels: type:fix, area:ios  
Depends-on: Persist and restore composer drafts; Drive prompt sends from the durable outbox; Phase-1 sync cursor/widget/navigation persistence | Inherited-context: none | Estimate: M

The scene-phase handler currently forwards lifecycle changes and performs only foreground App Intent/share work (`HermesMobileApp.swift:184-213`). `ConnectionStore.handleScenePhase` has no formal durability flush, and AppDelegate has no background task handling.

Add a `StateFlushCoordinator` invoked when entering `.background`. Acquire one brief `UIApplication.beginBackgroundTask`, then:

- force the active draft debounce to commit;
- commit current outbox/job transitions and release safe leases;
- persist the latest Phase-1 sync cursor;
- flush the authoritative widget snapshot;
- persist any pending notification/deep-link navigation intent.

End immediately after local writes. The expiration handler cancels pending work and ends the task exactly once. Do not drain the outbox, reconnect WebSockets, upload, sync, or keep the app alive.

Acceptance criteria:

- [ ] Backgrounding with an active draft commits its current revision.
- [ ] In-flight job state is transactionally recoverable after immediate termination.
- [ ] Sync cursor, widget snapshot, and pending navigation intent flush through their owning repositories.
- [ ] The task ends promptly on success and exactly once on expiration.
- [ ] No network operation starts from the flush.
- [ ] Repeated inactive/background transitions coalesce without leaking task identifiers.
- [ ] Foreground behavior is unchanged.

Tests required: `StateFlushCoordinatorTests`, debounce-force-flush tests, expiration race tests, scene transition tests, and force-termination relaunch validation.

## SPEC-VS-CODE DISCREPANCIES

1. **STR-246’s specific Ask Hermes loss path is fixed on current HEAD.** `PendingIntentRouter.deliverAskPrompt` now checks the `chat.send` Boolean and reparks on failure (`PendingIntentRouter.swift:82-103`). `NewSessionIntent` also uses a local draft instead of eagerly creating an empty server session (`PendingIntentRouter.swift:55-64`). R-49 remains valid because the shared slot is still explicitly last-write-wins, and reparking can overwrite a newer request.

2. **The share inbox is durable only in a limited sense.** Inventory language calls it an app-group job, but current storage is JSON UserDefaults plus loose files, not a transactional job repository (`SharedStore.swift:44-116`). Oldest-first processing, per-item success removal, and failure retention are already present (`SharedInboxDrainer.swift:75-118`).

3. **The share writer’s atomicity comment is too strong.** It writes image files before the UserDefaults item (`SharedInboxWriter.swift:25-55`). A crash between those operations can orphan images, and individual image-write failures are silently skipped (`SharedInboxWriter.swift:61-78`).

4. **QueueStore’s crash-safety comment contradicts its implementation.** It claims prompts cannot be lost or duplicated (`QueueStore.swift:15-18`), but removes and persists before awaiting the server (`QueueStore.swift:198-208`). R-48’s ambiguous-acceptance claim is correct.

5. **R-47 is confirmed.** Composer text is updated frequently, but only into `SessionStore.composerDrafts`; cwd, model selection, and attachments are also process memory. The missing part is disk durability, not UI autosave wiring.

6. **R-50’s key description is slightly incomplete.** The cache key includes `sessionId` in addition to scope/path/size (`AttachmentBlobCache.swift:43-58`), but byte size remains its only content discriminator. `MessageBubble` also constructs some keys with size zero, making the weakness worse. The same-size-staleness finding remains valid.

7. **Attachment eviction exists but is not activated.** A 365-day stale-file method is defined, while comments explicitly state it is never scheduled (`AttachmentBlobCache.swift:30-32,180-203`). There is no LRU byte cap, metadata index, or per-scope purge.

8. **The background-execution premise is confirmed.** No BGProcessing registration, background URLSession configuration, begin-background flush, permitted identifiers, or URLSession relaunch callback exists.

9. **Phase-1 identity remains a blocking dependency in current code.** Scope columns were added without changing global primary keys. Phase 2 must not encode that transitional schema into durable work.

## Unsatisfiable clause

The requested destination `/Users/abbhinnav/Developer/products/hermes-loop/docs/mobile-foundation/lane-outputs/lane-g-phase2-issues.md` is outside the writable workspace root. The sandbox rejected the only attempted write, and no alternate file was written because the user authorized only that output path.

LANE_RESULT: done_with_concerns Complete contract and all Phase-2 issue drafts produced; requested output file could not be written because the sandbox denied the destination path.