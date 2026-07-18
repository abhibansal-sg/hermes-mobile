# F4a Contract — Agent-Native Surfaces (file browser + @-file refs, subagent tree, working-dir picker, sudo/secret prompts, branch/checkpoint, todo card, tool-group collapsing)

Functionality track, batch 4a. Builds on the WORKING hermes-mobile iOS app
(the entire `apps/ios/HermesMobile` tree — ChatStore, GatewayEvent, all
stores/views — is hermes-mobile-ONLY; origin/main has none of it, so there is
NO upstream baseline to reconcile against) and on the LIVE JSON-RPC gateway in
`tui_gateway/server.py` (exposed over stdio AND WebSocket `/api/ws`; events are
`{method:"event", params:{type, session_id, payload}}` notifications). It also
builds on the working REST surface in `hermes_cli/web_server.py`, token-gated by
the global `/api/` middleware (`web_server.py:327` → `_has_valid_session_token`).

The CORE of F4a is a file browser. The gateway READ confirmed a HARD GAP: there
is NO endpoint (REST or RPC) on EITHER branch that lists a directory or reads a
file's bytes under a session cwd. `complete.path` returns autocomplete strings
only (names, never contents). So the two file endpoints are GREENFIELD and are
the entire server module F4A-S. Everything else (subagent tree, sudo/secret,
branch/checkpoint, todo card, tool grouping, @-file refs, working-dir picker) is
built on RPCs/events that already exist OR on `subagent.*`/`sudo.*`/`secret.*`
events the gateway ALREADY EMITS but the iOS client currently drops to
`.unknown`. Do not regress any existing surface.

## BINDING constraints (/careful — the server is LIVE)

- `ai.hermes.dashboard` on 127.0.0.1:9119 is the user's LIVE shared backend
  (desktop + phone connected). NEVER restart, stop, or reload it. NEVER point
  test traffic at it that creates sessions, mutates cwd, forks sessions, or
  reads files outside the test scope.
- All live testing runs against YOUR OWN dashboard instance on port 9123
  (pattern: `HERMES_DASHBOARD_SESSION_TOKEN=<own> HERMES_GATEWAY_BROADCAST=1
  venv/bin/hermes dashboard --no-open --tui --host 127.0.0.1 --port 9123` from
  the repo checkout; leave HERMES_PUSH_ENABLED unset). Kill it when done.
- Production rollout (restarting the real dashboard so new server code loads) is
  NOT yours — report completion; the main thread coordinates the restart.
- Branch `hermes-mobile` only. NEVER push to any remote. No build artifacts in
  commits. Swift 6 strict, iOS 17 base, availability-gate newer API and VERIFY
  signatures against the iPhoneSimulator26.5 SDK swiftinterface before coding
  (house standard since the geometry fix).
- XcodeGen: any target/Info.plist change goes in project.yml + regenerate
  (`xcodegen generate` in apps/ios). Do NOT bump CURRENT_PROJECT_VERSION /
  MARKETING_VERSION — version bumps happen at TestFlight ship time only.
- STOCK-SERVER DEGRADATION: the two new file endpoints (and any new RPC) MUST be
  feature-detected via `ServerCapabilities` (Stores/ServerCapabilities.swift) —
  add a `State` field + probe per the existing `upload` pattern, and gate every
  new UI affordance on `connection.capabilities.<feature> != .unavailable`
  (exact template: `ComposerView.swift:100` uploadSupported). A stock
  hermes-agent (no file endpoints, no `subagent.*`/`sudo.*`/`secret.*` emission)
  must show NONE of the new affordances and never error.
- UI follows the UI-I FULL NATIVE principle: system components only (List,
  Toggle, LabeledContent, NavigationSplitView, sheets); identity via tint. No
  custom-drawn chrome.
- SECRETS — BINDING: a `secret.request` value is NEVER logged, NEVER persisted
  (no UserDefaults, no Keychain, no transcript, no @Snapshotable accessor, no
  DEBUG ring buffer), and is held only in a transient `@State` cleared the
  instant the RPC reply is sent or the prompt is dismissed. The input field is
  `.textContentType(.password)` masked / SecureField. This applies to the
  `sudo.request` password too.
- F3-H ROUND-2 OWNERSHIP REFACTOR (in flight): the round-2 ChatStore refactor is
  NOT named `localTurnToken` — that symbol does not exist. Ownership is modeled
  today by two private ChatStore fields, `mirroringRuntimeId: String?`
  (ChatStore.swift:222) and `streamingIsForeign: Bool` (ChatStore.swift:232),
  with the local-vs-foreign predicate `isStreaming && !streamingIsForeign`
  (ChatStore.swift, foreign-mirror gate ~:298-263). F4A-A2 MUST treat that
  PREDICATE as the seam (it may be renamed/extracted into a token) and MUST NOT
  hard-code either field name. **Rebase F4A-A2 on the round-2 HEAD before
  starting**; if round-2 has not landed, A2 codes against the predicate via a
  one-line private accessor it owns, so a rename is a single-site edit.

## Interface (pinned — all three modules code against THIS, not each other)

### NEW server endpoint #1 — list a directory under a session cwd (F4A-S, GREENFIELD)
`GET /api/fs/list` in `hermes_cli/web_server.py`. NEW — nothing comparable
exists (the only `read_text` calls in web_server.py are fixed config/soul/html
paths; `complete.path` lists names internally at `server.py:6675` but never
returns them as a browsable tree and does NOT sandbox to cwd).
- Auth: auto-gated by the global `/api/` middleware (`web_server.py:327`); the
  path is NOT in `PUBLIC_API_PATHS` (`dashboard_auth/public_paths.py:39`), so no
  per-route auth is needed. MIRROR `/api/approvals/respond` (`web_server.py:1345`)
  and add an explicit in-handler `_has_valid_session_token(request)` belt-and-
  suspenders check returning `401` — house precedent for `/api/` mutators and
  reads of session state.
- Query params: `session_id` (runtime sid, required — resolves the cwd ROOT),
  `path` (relative sub-path under the session cwd, optional; default = cwd root).
- cwd resolution + SANDBOX: resolve the session cwd via the SAME logic as
  `_set_session_cwd` (`server.py:988`) / `_completion_cwd` (`server.py:860`):
  `_sessions.get(session_id)["cwd"]` → `os.environ["TERMINAL_CWD"]` →
  `os.getcwd()`. The ROOT is that cwd. Then `os.path.realpath(os.path.join(root,
  path))` and REJECT (`403` `{"error":"path escapes session root"}`) unless the
  realpath is `== root` or starts with `root + os.sep`. DO NOT copy
  `complete.path`'s behavior — it allows absolute paths and `~/`, which this
  endpoint MUST refuse. Symlinks resolve via realpath BEFORE the prefix check.
- Responses:
  - `200` `{"root": "<abs cwd>", "path": "<rel path>", "entries": [{"name":
    str, "is_dir": bool, "size": int (bytes, 0 for dirs), "modified": float
    (epoch secs)}]}` — entries sorted dirs-first then name; capped at 1000
    entries (`{"truncated": true}` flag when capped). Hidden files (dotfiles)
    INCLUDED (the agent works on them); the client decides display.
  - `400` `{"error":"session_id required"}` when missing.
  - `403` path escapes root (above).
  - `404` `{"error":"not a directory"}` when the resolved path is a file or does
    not exist (reuse the `os.path.isdir` check `_set_session_cwd` already does;
    raises `ValueError` there → map to 404 here).
  - `401` bad/absent token. Never 500 on a missing path or unknown sid.
    UNKNOWN/STALE SID → `404 {"error":"unknown session"}` (R1-fix finding 2):
    the resolver requires the sid to be a LIVE session in the gateway
    `_sessions` map. It does NOT fall back to `TERMINAL_CWD`/`os.getcwd()` — that
    fallback leaked the dashboard's own workspace to any client presenting a
    bogus sid. The iOS client always passes its active runtime sid (and
    re-resolves it via `session.resume` on reconnect), so a live app never trips
    this; a 404 only fires for a stale/forged sid and the app shows "No Active
    Session". A KNOWN session registered without an explicit cwd still resolves
    via the gateway's own cwd precedence — the 404 is unknown-sid only.

### NEW server endpoint #2 — read a file's contents under a session cwd (F4A-S, GREENFIELD)
`GET /api/fs/read` in `hermes_cli/web_server.py`. NEW — no precedent returns
arbitrary session-cwd file bytes.
- Auth: identical to `/api/fs/list` (middleware + explicit `_has_valid_session_
  token` check, `401`).
- Query params: `session_id` (required), `path` (required, relative to cwd
  root — same sandbox + realpath + prefix guard as `/api/fs/list`; `403` on
  escape).
- Size cap: reuse the `/api/upload` precedent `_MAX_ATTACHMENT_UPLOAD_BYTES =
  25 * 1024 * 1024` (`web_server.py:1253`) BUT for read use a tighter
  `_MAX_FS_READ_BYTES = 1 * 1024 * 1024` (1 MB) — mobile-text-viewer scope.
  Over-cap → `413` `{"error":"file too large","size":int}`.
- Binary policy: read the first up-to-cap bytes; if they decode as UTF-8, return
  `200` `{"path": str, "size": int, "encoding": "utf-8", "content": "<text>",
  "truncated": bool}` (`truncated` true if the file exceeds the cap but is under
  the 413 ceiling — DECISION: do NOT 413 a large-but-text file, truncate to the
  cap and flag it; only hard-413 above `_MAX_FS_READ_BYTES`). If it does NOT
  decode UTF-8, return `200` `{"path": str, "size": int, "encoding": "binary",
  "content": null}` — the client shows "Binary file (N bytes)" and offers
  nothing else. No base64 of binaries in v1.
- `404` `{"error":"not a file"}` (path is a dir / missing). `401` bad token.
  Never 500.

### File-browser feature probe (app ↔ server, F4A-A1)
Add `fs: State` to `ServerCapabilities` (Stores/ServerCapabilities.swift:48
region). EAGER probe (like `upload`): `GET /api/fs/list` with NO `session_id` →
the patched gateway returns `400 {"error":"session_id required"}` ⇒ available;
a stock gateway has no route ⇒ `404`/`405` ⇒ unavailable. Zero side effects (no
file is read). Wire it through `probe()` (`ServerCapabilities.swift:73`), the
`Cache` struct (`:155`) + `applyCache`/`persist` (`:163`/`:171`), and add a
`probeFsEndpoint() -> UploadProbeResult`-shaped helper on `RestClient` (mirror
`probeUploadEndpoint()` at `RestClient.swift:117`, reusing its
`UploadProbeResult` enum `available/unavailable/inconclusive` at `:103-110`).
View gate everywhere: `connection.capabilities.fs != .unavailable`.

### @-file references via complete.path (app → server, F4A-A1)
RPC `complete.path` ALREADY EXISTS (`server.py:6587`). Params `{word (required;
empty ⇒ {items:[]}), cwd (optional), session_id (optional)}`. Pass the active
runtime `session_id` so cwd resolves to the session's cwd (`_completion_cwd`
`server.py:860`). Response `_ok {items: [{text, display, meta}]}` capped at 30.
For an @-file picker, send `word="@" + query` (the `@file:`/`@folder:` context
tokens are handled server-side); for a bare path picker send the raw prefix.
Returns NAMES only — selecting an entry inserts a `@file:<path>` token into the
composer text; it does NOT read the file (that is the chat agent's job at send).
No server change.

### Working-directory set (app → server) — EXISTS, no server change (F4A-A2 + A1 picker)
RPC `session.cwd.set` (`server.py:3249`). Params `{session_id, cwd (required)}`.
Validation already enforced server-side: session busy ⇒ `_err 4009`
("session busy"); empty cwd ⇒ `_err 4016`; non-existent dir ⇒ `_err 4017`
("working directory does not exist"). On success: sets cwd, `explicit_cwd=True`,
persists, emits a `session.info` event, returns `_ok(info)` where `info =
{cwd, branch, lazy:true, ...}`. The iOS working-dir picker (F4A-A1 UI, wired by
A2's chat surface) calls `client.requestRaw("session.cwd.set", .object([
"session_id": ..., "cwd": ...]))` and handles `4009`/`4016`/`4017` with native
inline errors. NOTE: a successful set should refresh the file browser root and
the composer @-file cwd. No new endpoint.

### subagent.* events (server → app) — ALREADY EMITTED, client must decode (F4A-A2)
The gateway ALREADY EMITS these (built in `server.py:2122` `_on_tool_progress`,
relayed from `tools/delegate_tool.py`). They currently decode to `.unknown` and
are dropped at THREE layers (GatewayEvent enum, ConnectionStore.route whitelist,
ChatStore.handle switch) — all three must gain cases. Externally-visible names
(the internal `delegate.*` enum is normalized to these before relay; there is no
`delegate.running`/`delegate.complete` on the wire):
- `subagent.start` — payload keys: `goal` (str), `task_count` (int),
  `task_index` (int), optional `subagent_id`, `parent_id`, `depth` (int),
  `model` (str), `tool_count` (int), `toolsets` (list[str]), `preview` (=goal).
- `subagent.thinking` — `text` (=preview), + identity keys above.
- `subagent.tool` — `tool_name` (str), `tool_preview` (str), `text` (=preview),
  `args`, + identity keys.
- `subagent.progress` — batched tool names (BATCH_SIZE=5), `text` (=preview).
- `subagent.complete` — `preview` (str ≤160), `status`, `duration_seconds`
  (float), `summary` (str ≤500), `input_tokens`/`output_tokens`/
  `reasoning_tokens`/`api_calls` (int), `files_read`/`files_written`
  (list[str]), `output_tail` (list[dict], ≤8 entries / 600 chars), `cost_usd`
  (float, optional). Timeout/error variant: `status` ∈ {`timeout`,`error`},
  `summary`=``, `preview`=`"Timed out after Ns"`.
All carry the standard `session_id` (and `stored_session_id` on broadcast
frames) so they route through the SAME foreign-mirror gate as message/tool
frames. Identity correlation: `subagent_id` / `parent_id` / `depth` build the
tree; `task_index`/`task_count` order siblings.

### subagent-tree feature probe (F4A-A2)
`subagent.*` cannot be eagerly probed (it only fires when the agent delegates).
Add `subagentEvents: State` to `ServerCapabilities` as a PASSIVE signal (mirror
`broadcast`/`noteBroadcastObserved` at `ServerCapabilities.swift:133`): call a
new `noteSubagentObserved()` the first time ConnectionStore.route sees a
`subagent.*` frame. Stays `.unknown` until then (never provably unavailable,
which is acceptable — the tree UI simply has no data on a stock server and the
inspector tab/sheet stays empty/hidden until the first subagent event).

### sudo.request / secret.request prompts (server → app) — ALREADY EMITTED (F4A-A2)
Emitted by the gateway as standard `event` notifications:
- `sudo.request` (`server.py:2214`) — payload `{request_id (8-hex)}` (empty dict
  + injected `request_id`). Timeout 120s server-side.
- `secret.request` (`server.py:2220`) — payload `{prompt (str), env_var (str),
  metadata (optional dict), request_id (8-hex)}`. Timeout 300s server-side.
Reply RPCs (the gateway `_respond` router, `server.py:5058`):
- `sudo.respond` params `{request_id, password}` (key `password`).
- `secret.respond` params `{request_id, value}` (key `value`).
On success `_ok {status:"ok"}`. Unknown `request_id` ⇒ `_err 4009` "no pending
<key> request". Empty reply ('') = skipped (the gateway treats secret skip as
`success:true, skipped:true`); `session.interrupt` releases pending prompts with
''. These do NOT exist in the iOS client today (zero grep hits) — add enum cases
+ route whitelist + a NEW prompt path (NOT InboxStore — these are transient,
session-local, biometric-gated, and must never persist a value). No server
change. NOTE: per the desktop reader, cluster5 approval/sudo/secret handling is
origin/main-only on the DESKTOP; on the GATEWAY the emission is present — F4A
targets the gateway events, which our `hermes-mobile` checkout has.

### sudo/secret biometric gate (F4A-A2)
Reuse the F2 AppLock seam: protocol `BiometricAuthenticating { func evaluate(
reason:) async -> BiometricResult }` (Support/AppLock.swift:183), live impl
`LAContextAuthenticator` (`:193`, `.deviceOwnerAuthentication`). INJECT the
protocol into the new prompt path (do NOT call `AppLock.authenticate()` —
`:150` — it is private/app-lock-specific). BINDING: before the value/password is
revealed for entry AND before `*.respond` is sent, require a successful
`evaluate(reason:)`; on failure/cancel, send the empty-skip ('') reply or leave
pending — never leak the field. Add a `requiresBiometric` user pref to
`DefaultsKeys` (default ON).

### Branch / checkpoint (app → server) — uses EXISTING RPCs (F4A-A2)
- Restore-checkpoint: client truncation already exists. `prompt.submit` accepts
  `truncate_before_user_ordinal` (int; `server.py:4131`, `_err 4004` if
  non-int, staleTruncation `4018`). Reuse `ChatStore.submitTruncating`
  (ChatStore.swift:716) — a checkpoint picker maps a chosen user message to its
  `visibleUserOrdinal` and re-submits with that ordinal.
- Branch-in-new-chat: NO server fork RPC exists. Use the EXISTING `session.create`
  seed path (`server.py:3022`): params `{messages (list), cols, title, cwd}`.
  `_coerce_seed_history` (`server.py:2917`) accepts ONLY items that are dicts
  with `role` ∈ {`user`,`assistant`,`system`} and a NON-EMPTY str `content`
  (falls back to `text` if `content` absent); everything else (tool_calls, etc.)
  is dropped, normalized to `{role, content}` ONLY. Response `_ok {session_id,
  stored_session_id, message_count, messages, info:{...,cwd,branch,lazy:true}}`;
  the agent build is deferred 50ms so create returns immediately. iOS reuses
  `SessionStore.createSessionNow()` (SessionStore.swift:394) /
  `startDraft()` (`:339`) + builds the seed from history up to the chosen
  message, flattening via `StoredMessage` (ProtocolTypes.swift:131). No new
  endpoint; no `session.branch` RPC in F4a.

### Todo-tool checklist card + tool-group collapsing (F4A-A2, client-only)
Both are pure rendering on EXISTING data. Tool collapse already exists
(`ToolClusterView`, ToolActivityRow.swift; collapse SET in
`ChatStore.handleMessageComplete:407` when `tools.count>=2`). F4A-A2 adds the
product/technical DETAIL toggle (persisted via a NEW `DefaultsKeys` key,
default = product/summary) controlling `ToolActivityRow.expandedDetail` (`:179`)
verbosity. The todo card renders a todo-tool's structured result (a tool whose
`name` is the todo/checklist tool) as a native checklist from
`ToolActivity.resultPreview` / the `tool.complete` result JSON — NO new event,
NO new model field beyond a derived view over `ChatMessage.tools`
(ChatModels.swift:31). If the todo tool's exact name/result shape is unknown,
A2 confirms it from a live session before coding (see Open Questions).

## Module split (three modules run CONCURRENTLY — file-ownership boundaries below)

### Module F4A-S (server, Python) — touches hermes_cli/web_server.py + tests ONLY
Owns ONLY the two NEW file endpoints and their tests. Touches no `tui_gateway/`
code (every RPC/event F4a needs there already exists). Files:
`hermes_cli/web_server.py` (add `/api/fs/list`, `/api/fs/read`,
`_MAX_FS_READ_BYTES`, the shared sandbox-resolve helper) and the server test
module.
- S1 `/api/fs/list` (spec above): middleware auth + explicit token check, cwd
  resolve reusing the `_set_session_cwd`/`_completion_cwd` logic, realpath
  prefix sandbox, sorted/capped entries, error codes 400/401/403/404.
- S2 `/api/fs/read` (spec above): same sandbox, 1 MB cap, UTF-8/binary policy,
  413/404/403/401.
- S3 a single private `_resolve_under_session_cwd(session_id, rel_path) ->
  (root, abspath)` helper raising on escape, shared by S1+S2 (DRY; one sandbox
  implementation, one place to audit traversal).
- S4 tests (httpx/TestClient): list root, list subdir, list escaped path
  (`../`, absolute, symlink-out) → 403; read text (with truncation flag), read
  binary → encoding:"binary", read >1 MB → 413, read missing → 404, both with
  bad/absent token → 401, unknown sid → 404. Full server suite stays green.
- Commit style (separable for a possible upstream PR): `hermes-mobile F4A-S: ...`.

### Module F4A-A1 (app, Swift) — composer / @-refs / file browser UI
Owns the COMPOSER + FILE-BROWSER files. Touches ONLY:
`Views/Chat/ComposerView.swift`, a NEW `Views/Files/` directory (FileBrowserView,
WorkingDirPicker, MentionPicker views — all new files), `ServerCapabilities.swift`
(add `fs` State + probe wiring), `Networking/Rest/RestClient.swift` (add
`probeFsEndpoint()` + `fsList`/`fsRead` calls), `Support/DefaultsKeys.swift` (add
A1's @-mention/file-browser prefs), and the new file-browser feature in
`project.yml`/xcodegen if a new dir needs target membership.
- A1.1 `fs` capability probe (eager) in ServerCapabilities + RestClient helper.
- A1.2 FileBrowserView: native `List` over `GET /api/fs/list` (dirs-first,
  size/modified subtitles, drill-down via `path`), tap a file → `GET /api/fs/read`
  → native text viewer (mono font, ANSI off; "Binary file (N bytes)" for binary;
  413 → "Too large to preview"). Gated on `capabilities.fs != .unavailable`.
- A1.3 Working-dir picker: a FileBrowser variant that selects a DIRECTORY and
  returns it for `session.cwd.set` (the RPC call itself is invoked by A2's chat
  surface via the closure A1 exposes — see boundary note).
- A1.4 @-file references: a NEW attributed/segment model for the composer
  (ComposerView's single `@State text` at `:40` has no chip model — greenfield);
  typing `@` opens MentionPicker backed by `complete.path` (word=`@`+query,
  session_id threaded); selecting inserts a `@file:<path>` token. Persist the
  @-mention pref in DefaultsKeys. Gate the @-trigger affordance on
  `capabilities.fs != .unavailable` (the same patched server provides both).
- A1.5 unit tests (probe state machine, fsList/fsRead decode + error mapping,
  mention-token insertion, sandbox-error surfacing). Debug + Release sim builds
  green. Commit: `hermes-mobile F4A-A1: ...`.

### Module F4A-A2 (app, Swift) — chat surface: subagent tree, sudo/secret, branch UX, todo card, tool grouping
Owns the EVENT PIPELINE + CHAT-SURFACE rendering files. Touches ONLY:
`Models/GatewayEvent.swift` (new enum cases), `Models/ProtocolTypes.swift` (new
payload structs: subagent, sudo, secret), `Stores/ConnectionStore.swift`
(route whitelist + `noteSubagentObserved`), `Stores/ChatStore.swift` (handle
switch cases, subagent grouping, todo derivation, tool-detail toggle, branch
seed builder — coding against the F3-H predicate as the seam),
`Views/Chat/ToolActivityRow.swift` (tool grouping + detail toggle + todo card),
NEW `Views/Chat/SubagentTreeView.swift` + `Views/Chat/SecurePromptView.swift`
(sudo/secret), `Views/Shell/RootView.swift` (iPad inspector tab for the subagent
tree + the file browser surface A1 builds; iPhone presents them as sheets),
`Stores/SessionStore.swift` (branch-in-new-chat seed reuse of `createSessionNow`),
`Support/DefaultsKeys.swift` (A2's detail-toggle + `requiresBiometric` prefs).
- A2.1 Event decode: add `subagentStart/Thinking/Tool/Progress/Complete`,
  `sudoRequest`, `secretRequest` to GatewayEventType + the 3-layer routing
  (enum, ConnectionStore.route whitelist `:294`, ChatStore.handle switch `:265`).
  Add payload structs to ProtocolTypes.
- A2.2 Subagent tree: build a tree model from `subagent.*` (keyed by
  `subagent_id`/`parent_id`/`depth`), surfaced as an iPhone sheet AND an iPad
  inspector tab (extend `inspectorColumn` at RootView.swift:178; add a toggle
  item next to `inspectorToggleButton:158`). Passive `subagentEvents` capability
  gates visibility.
- A2.3 sudo/secret: SecurePromptView with SecureField, biometric gate via the
  injected `BiometricAuthenticating` protocol, `*.respond` reply by `request_id`.
  BINDING secret hygiene (no log/persist/snapshot, transient @State, cleared on
  send/dismiss).
- A2.4 Branch/checkpoint: checkpoint picker → `submitTruncating`; branch-in-new-
  chat → `createSessionNow` + `messages[]` seed (role/content only).
- A2.5 Todo card + tool grouping detail toggle (client-only, over existing
  `ChatMessage.tools`). Detail toggle + `requiresBiometric` persisted in
  DefaultsKeys.
- A2.6 unit tests (event decode round-trips incl. timeout `subagent.complete`,
  tree assembly, secret-never-persisted assertion, branch seed coercion matches
  `_coerce_seed_history` rules, truncation ordinal mapping). Debug + Release sim
  builds green. Commit: `hermes-mobile F4A-A2: ...`.

### Ownership boundary notes (so the three never collide)
- `DefaultsKeys.swift` is touched by BOTH A1 and A2 — they add DISJOINT keys
  (A1: file-browser/@-mention; A2: detail-toggle/requiresBiometric). Land A1's
  keys and A2's keys as separate enum additions; if they race, the second
  rebases (enum case additions are trivially mergeable, no shared lines).
- `RootView.swift` is A2-owned for F4a; A1's FileBrowserView/WorkingDirPicker are
  self-contained views A2 MOUNTS (iPhone sheet / iPad inspector tab). A1 exposes
  them with their own view init + a completion closure; A2 owns the mounting and
  the `session.cwd.set` call wiring.
- `ServerCapabilities.swift` + `RestClient.swift` are A1-owned (the `fs` probe);
  A2 only READS `capabilities.subagentEvents` and adds `noteSubagentObserved()`
  via ConnectionStore (A2-owned) — A2 does NOT edit ServerCapabilities except to
  add the one passive `subagentEvents` field; to avoid a two-writer file, A1
  adds BOTH `fs` (eager) and `subagentEvents` (passive) fields in one pass and
  A2 only calls the passive setter. (Single writer of ServerCapabilities = A1.)
- F4A-S shares NO files with A1/A2 (Python vs Swift). All three run concurrently.

## Integration gate (separate agent, runs after all three land)
Own dashboard on 9123 (`HERMES_GATEWAY_BROADCAST=1`, no push armed), sim iPhone
17 Pro; iPad sim for the split/inspector items. Use the UI-G debug bridge: DEBUG
builds expose `StateServer` on loopback with `@Snapshotable` read accessors
(generated in `DebugBridgeGenerated/StateAccessor.swift`); ADD `@Snapshotable`
accessors for the new surfaces (subagent-tree node count, fs-capability state,
active-secure-prompt kind — NEVER the secret value) so the gate can assert state
transitions without the value ever leaving the device.
1. **fs probe (stock degradation):** point the app at a STOCK hermes-agent (or a
   9123 with the fs routes stubbed off) → assert `capabilities.fs == .unavailable`
   via the bridge AND that NO file-browser / @-file affordance renders. Then
   point at patched 9123 → assert `fs == .available` and affordances appear.
2. **`/api/fs/list`:** create a session on 9123 with a known cwd → call
   `/api/fs/list?session_id=...` directly (curl with the session token) → assert
   sorted dirs-first entries + a known file present. Then `path=../../etc` and an
   absolute `path=/etc/passwd` → assert `403`. Then `path` to a real file → `404`
   "not a directory". A bogus `session_id` → `404 {"error":"unknown session"}`
   (R1-fix finding 2 — NOT a dashboard-cwd fallback). Bad token → `401`.
3. **`/api/fs/read`:** read a known small text file → assert `encoding:"utf-8"`,
   exact content. Read a >1 MB file → `413`. Read a binary (e.g. a PNG under the
   cwd) → `encoding:"binary"`, `content:null`. Escape path → `403`.
4. **File browser + viewer (UI):** open FileBrowserView in the sim, drill into a
   subdir, open the known text file → assert the viewer shows its content; open
   the binary → assert "Binary file" string. Screenshot each.
5. **@-file references:** type `@` in the composer → assert MentionPicker
   populates from `complete.path` (session_id threaded) → select an entry →
   assert a `@file:<path>` token lands in the composer buffer.
6. **Working-dir picker + `session.cwd.set`:** pick a new dir → assert
   `session.cwd.set` resolved (a `session.info` event arrived with the new cwd
   via the bridge), the file-browser root updated, and a deliberate non-existent
   cwd surfaces the `4017` native error. Run while the session is BUSY → assert
   the `4009` "session busy" native error.
7. **Subagent tree:** start a session and prompt the agent to delegate (a task
   that spawns subagents) → assert `subagent.*` frames decode (no `.unknown`
   drop) via the bridge, `capabilities.subagentEvents == .available`, the tree
   renders (iPhone sheet AND iPad inspector tab — screenshot both), and a
   `subagent.complete` updates status + token/cost stats. Include a timeout/error
   variant if reproducible (else unit-test evidence).
8. **sudo/secret prompts:** trigger a `sudo.request` (a command needing sudo) and
   a `secret.request` (a skill capturing a secret) on 9123 → assert the
   SecurePromptView appears with a MASKED field, the biometric gate fires
   (sim Face ID enroll + `notifyForAction(.matchedFace)`), and `sudo.respond` /
   `secret.respond` resolve by `request_id` (turn proceeds). BINDING evidence:
   grep the sim logs + the bridge snapshot + UserDefaults/Keychain dump → assert
   the entered value appears NOWHERE. Skip (empty reply) path → assert
   `skipped:true` resolution.
9. **Branch / checkpoint:** (a) restore-checkpoint — pick an earlier message,
   restore → assert `prompt.submit` carried `truncate_before_user_ordinal` and
   the transcript truncated; assert the staleTruncation `4018` path on a stale
   ordinal. (b) branch-in-new-chat — branch at a message → assert a NEW
   `session.create` with a `messages[]` seed (role/content only, tool frames
   dropped) and the new chat opens seeded with history up to that point.
10. **Todo card + tool grouping toggle:** a turn with a todo-tool result →
    assert the native checklist card renders; a turn with ≥2 tools → assert the
    collapsed cluster, expand it, flip the product/technical detail toggle →
    assert verbosity changes and the toggle persists across relaunch
    (DefaultsKeys).
- Evidence dir: `/tmp/hermes-f4a-evidence/` (screenshots, curl transcripts,
  bridge snapshots, log greps, registry/UserDefaults dumps proving secret
  hygiene). Release build still green. Full server suite + full iOS unit suite
  green.
- Report: verdict per numbered item, regressions, and STOP — no prod dashboard
  restart, no version bump, no TestFlight upload.

## Open questions (resolve before/early in the relevant module, do not block the others)
- Todo-tool exact `name` + result JSON shape (A2.5): confirm from a live 9123
  session (run the agent's todo/checklist tool, capture the `tool.complete`
  result) before coding the card. Until confirmed, A2 renders a generic
  structured-result fallback.
- `secret.request` `metadata` keys (A2.3): the gateway passes an optional
  `metadata` dict through; confirm whether it carries display hints (e.g. a label
  or a "sensitive" flag) worth surfacing in the prompt, or treat it as opaque.
- `/api/fs/read` binary-needed cases (S2): v1 returns `content:null` for binary.
  Confirm no near-term UI needs base64/image preview of cwd files (the existing
  image pipeline is upload-only); if it does, that is a follow-up endpoint param,
  not F4a.
- `subagent.*` ordering vs the foreign-mirror gate (A2.1/A2.2): confirm subagent
  frames on the LOCAL turn are not accidentally adopted as foreign (they carry
  the parent's `session_id`); the predicate seam should treat them as local —
  verify against the round-2 HEAD before wiring.
