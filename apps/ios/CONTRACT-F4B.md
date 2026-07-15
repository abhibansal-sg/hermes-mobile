# F4b Contract — Multi-Profile Switcher (client-side, ONE connection)

Functionality track, batch 4b. Adds a **client-side profile switcher** to the
WORKING hermes-mobile iOS app (the entire `apps/ios/HermesMobile` tree is
hermes-mobile-ONLY; origin/main has none of it). The switcher scopes the session
rail and per-session operations by profile **over the single existing
connection** — it is NOT a new connection, socket, or per-profile dashboard.

This is SMALLER than F4a (one app module, no server module). The CORE risk is
that the multi-profile server protocol this client codes against **does NOT yet
exist on our live 9119 backend** — it arrives only at the upstream rebase (5
commits `b94b3622b`/`cf9dc366d`/`3045d5454`/`02d6bf1c3`/`6f6eb871d`, present on
`origin/main`, ABSENT from our working HEAD `57f5dffcb`/`f4f6bcbbf`). So F4b
ships **DORMANT**: the `profiles` capability probe returns unavailable against
today's server, the switcher is **hidden entirely**, and the app is
pixel-identical to its pre-F4b self with ZERO behavior change. The full client
path is built against the **pinned upstream shapes** (below) and proven by unit
tests with stubbed/fixture responses; the integration gate proves (1) dormancy
against a real 9119-equivalent (our own instance off this branch) and (2) the
decode/threading layer against FIXTURE responses captured verbatim from the
upstream server code. Do not regress any existing surface.

## USER-RATIFIED model (binding — from UPSTREAM-REVIEW-2026-06-06 §4)

These decisions are **ratified and binding**; do not relitigate them in F4b:

- The switcher is **CLIENT-SIDE over ONE connection.** Upstream's multi-profile
  work is a *single-dashboard, many-profiles* model (one dashboard scopes per
  call by overriding `HERMES_HOME` via a ContextVar). iOS targets that model.
- **Do NOT build per-profile dashboards or per-profile sockets.** A profile is a
  per-request / per-session SCOPE parameter, never a new connection. The single
  long-lived `HermesGatewayClient` and single token are FIXED across a switch.
- **Do NOT chase the new profile fields until the switcher ships.**
  `profile` / `is_default_profile` / `profile_totals` appear only on
  `GET /api/profiles/sessions`, which iOS does not call today; existing decoders
  already ignore them. F4b is the batch that ships the switcher, so F4b is when
  those fields become in-scope — but ONLY the minimal `profile` field on
  `SessionSummary` and the `/api/profiles/sessions` wrapper, nothing more.
- The latent `_broadcast_event` profile-enrichment gap (broadcast frames carry
  `stored_session_id` but not the owning profile; stored ids now live in
  separate per-profile `state.db`s → collision risk) is a **rebase-time
  follow-up, explicitly OUT OF SCOPE for F4b** (recorded in §Open questions).

## BINDING constraints (/careful — the server is LIVE; the feature is DORMANT)

- `ai.hermes.dashboard` on `127.0.0.1:9119` is the user's LIVE shared backend
  (desktop + phone connected). NEVER restart, stop, or reload it. NEVER point
  test traffic at it that creates sessions, mutates profiles, or calls profile
  CRUD. Our live 9119 does NOT have the multi-profile endpoints — F4b must be
  invisible against it.
- All live testing runs against YOUR OWN dashboard instance on port 9123
  (pattern: `HERMES_DASHBOARD_SESSION_TOKEN=<own> HERMES_GATEWAY_BROADCAST=1
  venv/bin/hermes dashboard --no-open --tui --host 127.0.0.1 --port 9123` from
  the repo checkout; leave `HERMES_PUSH_ENABLED` unset). Kill it when done.
  **NOTE:** an instance built from THIS branch is a 9119-EQUIVALENT — it also
  LACKS the multi-profile endpoints (they live only on `origin/main`). That is
  exactly the dormancy target: the gate proves the app is pixel-identical with
  the switcher absent against this real, profiles-unaware server. The
  decode/threading proof therefore runs against FIXTURE responses (captured
  verbatim from the upstream code shapes below), NOT against a live patched
  server — we do not have one until rebase.
- Production rollout is NOT yours — report completion; the main thread
  coordinates any restart. There is nothing to roll out server-side for F4b.
- Branch `hermes-mobile` only. NEVER push to any remote. No build artifacts in
  commits. Swift 6 strict, iOS 17 base, availability-gate newer API and VERIFY
  signatures against the iPhoneSimulator26.5 SDK swiftinterface before coding
  (house standard since the geometry fix).
- XcodeGen: any target/Info.plist change goes in `project.yml` + regenerate
  (`xcodegen generate` in `apps/ios`). Do NOT bump `CURRENT_PROJECT_VERSION` /
  `MARKETING_VERSION` — version bumps happen at TestFlight ship time only.
- STOCK-SERVER / OLD-SERVER DEGRADATION (the heart of F4b): the multi-profile
  endpoints MUST be feature-detected via `ServerCapabilities`
  (`Stores/ServerCapabilities.swift`) — add a `profiles: State` field + an EAGER
  probe per the existing `fs`/`upload` pattern, and gate EVERY profile
  affordance on `connection.capabilities.profiles == .available`. A server
  without the routes (our live 9119, a stock hermes-agent, or our own
  this-branch 9123) MUST show NONE of the switcher chrome and never error. There
  is NO server capability FLAG — the cheapest probe is endpoint existence:
  `GET /api/profiles` → `200 {"profiles":[…]}` on a supporting server vs `404`
  on an old server (the desktop itself derives `multiProfile = profiles.length >
  1` purely from this route; we add a `.available` gate AND a `count > 1` gate —
  see "Switcher visibility" below).
- UI follows the UI-I FULL NATIVE principle: system components only (`Menu`,
  `Picker`, `List`, `Label`, sheets); identity via tint. No custom-drawn chrome.
  The switcher is a native `Menu` (the `recentsFilterMenu` precedent), NOT a
  hand-rolled control.
- SINGLE-CONNECTION LIFECYCLE — BINDING (do NOT change): `ConnectionStore` holds
  ONE long-lived `client = HermesGatewayClient()` (`ConnectionStore.swift:76`)
  and ONE `currentToken` (`:113`, persisted to Keychain at `configure` `:211`).
  A profile switch MUST NOT call `configure()`/`disconnect()`/`connect()` (those
  rebuild the socket at `:200`/`:396`, reset capabilities at `:260`, and
  re-probe). The single `eventRouterTask`/`stateObserverTask` (`:117-118`) and
  the reconnect loop (`:377-423`) are connection-scoped, not profile-scoped.
  `serverURLString` (`:46`) and the token stay FIXED across a switch.

## Interface (pinned — the client codes against THESE upstream shapes, captured
## verbatim from origin/main; line numbers are origin/main content)

The server side is FIXED and external (origin/main, arriving at rebase). The iOS
client codes against these exact shapes; the unit tests use FIXTURE JSON that
reproduces them byte-for-byte. There is NO server module in F4b.

### Capability probe — `GET /api/profiles` (existence detect, EAGER)
There is NO dedicated multi-profile flag (`/api/status` carries none —
`web_server.py:733-851`, return dict `:833-851`). The cheapest probe is route
existence:
- `GET /api/profiles` on a SUPPORTING server → `200` with body
  `{"profiles": [ … ]}` (always ≥ 1 entry, the default). `_profile_to_dict`
  (`web_server.py:6757-6773`) keys per item: `name`(str), `path`(str),
  `is_default`(bool), `model`(str|null), `provider`(str|null), `has_env`(bool),
  `skill_count`(int), `gateway_running`(bool), `description`(str),
  `description_auto`(bool), `distribution_name`/`version`/`source`(str|null),
  `has_alias`(bool). Handler `web_server.py:6868-6875`.
- A pre-multi-profile server → `404` (route absent).
- DECISION: classify `200` (+ well-formed `profiles` array) ⇒ `.available`;
  `404`/`405` ⇒ `.unavailable`; anything else ⇒ `.inconclusive` (→ `.unknown`).
  Mirror `probeFsEndpoint()` exactly (`RestClient+FS.swift:28-41`). This probe is
  side-effect-free (a read).
- `GET /api/profiles/sessions` is an equally valid existence probe but returns a
  heavier aggregated payload — use `GET /api/profiles` (cheaper).

### Profile list — `GET /api/profiles` (the switcher's data)
Same route as the probe. The client decodes the `profiles` array into a minimal
`ProfileSummary` (only the fields the switcher needs — `name`,
`is_default`/`isDefault`, and OPTIONALLY `description` for a subtitle; tolerate
all other keys via plain `Decodable` ignoring unknowns). The DEFAULT profile is
the single row where `name == "default"` AND `is_default == true`
(`profiles.py:604-628`; `is_default` field `:434`); named profiles always get
`is_default == false`. The switcher highlights the active profile and marks the
default.

### Rail — `GET /api/profiles/sessions` (cross-profile aggregate, WHEN multi)
Handler `get_profiles_sessions` (`web_server.py:1636`). Called ONLY when
`profiles == .available` AND the active scope is "All profiles" (the aggregate
view) — single-profile scope keeps using the existing `GET /api/sessions`
(`RestClient.swift:71-77`), unchanged, so the dormant/single-profile path is
byte-for-byte the shipped behavior.
- Query params (all optional, defaults shown): `limit: int = 20`,
  `offset: int = 0`, `min_messages: int = 0`, `archived: str = "exclude"`
  (one of `exclude|only|include`, else `400`), `order: str = "recent"`
  (one of `created|recent`, else `400`), `profile: str = "all"`
  (`web_server.py:1638-1643`). `profile="all"` aggregates across ALL profiles;
  a specific name resolves that one (`400`/`404` on bad/unknown name,
  `:1662-1674`).
- Response (`web_server.py:1734-1741`): top-level object
  `{ sessions: [session-row dicts, the page window merged[offset:offset+limit]],
  total: int (sum of per-profile session_count), profile_totals: {name: int},
  limit: int (echo), offset: int (echo), errors: [{profile: str, error: str}] }`.
  Read-only; profiles whose `state.db` failed to open appear in `errors`,
  profiles with no `state.db` are silently skipped.
- Per-session row tags added by the handler (`web_server.py:1717-1724`):
  `profile`(str owning profile name), `is_default_profile`(bool =
  `name == "default"`), `is_active`(bool, ended_at None AND last_active < 300s),
  `archived`(bool). Base row fields are `SessionDB.list_sessions_rich`
  (`hermes_state.py:1604`): `SELECT s.*` from `sessions` plus computed `preview`
  (first user msg ≤60 chars + "…"; "" if none) and `last_active` (REAL ts).
  The `sessions` columns (`hermes_state.py:234-269`) include `id`, `title`,
  `started_at`, `message_count`, `cwd`, `source`, `archived`, etc.
- iOS wrapper type `ProfilesSessionsResult` decodes `sessions`/`total`/
  `profileTotals`/`limit`/`offset`/`errors`. The `sessions` array decodes into
  `[SessionSummary]` — each row now carries the new optional `profile` field
  (the handler's `profile` tag → `SessionSummary.profile`).

### `SessionSummary` — add ONE optional field (`profile`)
`Models/ProtocolTypes.swift:12-100`. Today it has 8 stored fields (`id`, `title`,
`preview`, `startedAt`, `messageCount`, `source`, `lastActive`, `cwd`) and uses
the SYNTHESIZED memberwise init + synthesized `Decodable` (no explicit
`CodingKeys`, decoded via `.convertFromSnakeCase`). Add exactly:
`var profile: String? = nil` as the **last** stored property.
- WIRE KEY: the upstream handler tags the row key `profile` (a string profile
  name), NOT `profile_name` — so the Swift property must be named `profile`
  (`.convertFromSnakeCase` leaves a single-word key unchanged). Do NOT name it
  `profileName`/wire `profile_name` (that is the DISTINCT
  `SessionRuntimeInfo.profileName` key on the create/resume `info` block,
  `ProtocolTypes.swift:117` — a different surface). A stock REST row omitting
  `profile` decodes as `nil` safely (comment `ProtocolTypes.swift:11-12`: extra
  REST keys are ignored, absent keys → nil for optionals).
- MEMBERWISE-INIT IMPACT (exactly 3 positional callers): `var profile: String? =
  nil` declared LAST is mandatory — Swift's synthesized memberwise init makes a
  defaulted stored property an OPTIONAL trailing parameter, so all three
  positional callers compile UNCHANGED without passing it:
  (1) `RestClient+Sessions.swift:199` (`asSessionSummary`, search results lack a
  profile → defaults nil), (2) `SessionStore.swift:635` (`rename()` rebuild → the
  rebuilt row defaults nil; OPTIONAL polish: carry `current.profile` through so a
  rename doesn't drop the row's profile, but nil is acceptable since the rail
  re-fetches), (3) `HermesMobileTests/WorkspaceGroupingTests.swift:168` (fixture
  helper → defaults nil). Adding the field anywhere but last, or without `= nil`,
  breaks the positional calls — DO NOT do that.

### `ServerCapabilities` — add `profiles: State` (EAGER probe, A1-pattern)
`Stores/ServerCapabilities.swift`. Mirror the `fs` field added by F4a verbatim:
- (a) `private(set) var profiles: State = .unknown` near `:54` (next to `fs`).
- (b) reset it in `probe()` (the fresh-server reset block `:106-109`) and in
  `reset()` (`:129-137`).
- (c) add to the concurrent eager run in `probe()` (`:113-123`): a third
  `async let profilesProbe = Self.probeProfiles(rest:)`, awaited and assigned
  alongside `upload`/`fs` under the same `guard probedServerURL == serverURL`.
- (d) add `static func probeProfiles(rest:) async -> State` mirroring `probeFs`
  (`:189-195`), calling a new `rest.probeProfilesEndpoint() -> UploadProbeResult`.
- (e) extend `Cache` (struct `:203`, `CodingKeys` `:212-213`, the
  `decodeIfPresent`-tolerant `init(from:)` `:234-243`, and the memberwise init
  `:216-232`) with `profiles`, defaulting to `.unknown` when a pre-F4b cache
  omits the key (so an old cache restores cleanly without a needless re-probe).
- (f) include it in `applyCache` (`:246-254`) and `persist` (`:256-269`).
- The probe runs with ZERO call-site changes: `probe()` is invoked from
  `ConnectionStore.configure` (`ConnectionStore.swift:224-227`) and re-affirmed
  in `recoverActiveSession` (`:468`), both already passing `serverURL`+`rest`.

### `RestClient` — add the profiles surface (mirror `RestClient+FS.swift`)
A NEW `Networking/Rest/RestClient+Profiles.swift` extension, mirroring
`RestClient+FS.swift`:
- `probeProfilesEndpoint() -> UploadProbeResult`: `GET /api/profiles`; classify
  `200` ⇒ `.available`, `404`/`405` ⇒ `.unavailable`, else `.inconclusive`.
  (Refine: `200` must also decode a `profiles` array to count as `.available`;
  a `200` without one ⇒ `.inconclusive`, defensive against a same-path collision.)
- `profiles() async throws -> [ProfileSummary]`: `GET /api/profiles`, decode
  `{"profiles":[…]}` via `.convertFromSnakeCase` into `[ProfileSummary]`.
- `profileSessions(profile:limit:offset:order:archived:) async throws ->
  ProfilesSessionsResult`: `GET /api/profiles/sessions?profile=…&limit=…&…`,
  decode the wrapper. Reuse the `decode`/`get`/`makeRequest` plumbing
  (`RestClient.swift:38` note) — no cloned HTTP code.
- Per-session profile threading helpers (used by SessionStore when scope is a
  specific profile): pass `profile` as a QUERY param to GET
  `/api/sessions/{id}` (`web_server.py:5218-5230`), GET `…/messages`
  (`:5246-5256`), DELETE `/api/sessions/{id}` (`:5259-5270`); pass `profile` in
  the JSON BODY (`SessionRename` model `:5273-5278`) to PATCH
  `/api/sessions/{id}` (`:5281`). REST unknown-profile is STRICT: `400` on an
  invalid name (ValueError), `404 "Profile '<name>' does not exist."` when the
  profile doesn't exist (`_cron_profile_home` `:5445-5457`). Surface those as
  native inline errors. (These per-session helpers are only exercised when a
  specific profile scope is active AND multi-profile is available — dormant
  otherwise.)

### Session create/resume profile threading (WS, optional param)
The optional `profile` (string) param threads through WS `session.create`
(`server.py:2981`, reads at `:3004`) and `session.resume` (`:3169`, reads at
`:3180`). It is NOT a direct param on `prompt.submit` (`:4225`) — the session
inherits its owning profile from `profile_home` set at create/resume. Semantics:
`profile = (params.get("profile") or "").strip() or None` → `_profile_home(...)`;
None → the launch profile / shared `_get_db()` (byte-for-byte unchanged for
single-profile). The WS path is LENIENT on an unknown name (`_profile_home`
`:474-493` swallows resolver failures → silently falls back to launch profile),
unlike the STRICT REST path. iOS adds the `profile` param ONLY when a specific
non-default profile scope is active:
- `createDraftSession()` (`SessionStore.swift:359-381`): `session.create` params
  `.object(["cols": .number(96)])` (`:366-369`) — conditionally add
  `"profile": .string(name)` when an active non-default scope is set.
  `createSessionNow()` (`:394-397`) delegates to this, so it inherits the param.
- `branchSession(seed:cwd:)` (`:418-456`): builds the `session.create` params
  dict (`:423-427`, already conditionally adds `cwd`) — same conditional spot
  for `profile`.
- `open(_:)` (`:285-332`): `session.resume` params `.object(["session_id": …])`
  (`:307-311`) — add `profile` if resume is profile-scoped.
- `resumeActiveAfterReconnect()` (`:527-542`): `session.resume` (`:530-534`) —
  same, so a reconnect re-resumes into the same profile scope.
- `startDraft()` (`:339-348`) is LOCAL ONLY (no RPC); the profile attaches at the
  create that materializes the draft (`createDraftSession`), not here.
- `SessionOpenResult.info.profileName` (`ProtocolTypes.swift:117`) already echoes
  the server's active profile — use it to CONFIRM/seed the active-profile pref
  after a create/resume (defensive: the WS path silently falls back on an
  unknown name, so trust the echo over the requested name).

### Active-profile pref + switcher visibility
- Active-profile pref lives in `DefaultsKeys` as a NEW key
  `static let activeProfile = "hermes.activeProfile"` (mirror the existing
  `hideCron`/`groupByWorkspace`/`displayName` String/Bool keys at
  `DefaultsKeys.swift:32`/`:38`/`:211`). It drives the rail filter, so it is most
  naturally a `SessionStore` property persisted via `UserDefaults.standard`
  directly in `init` with a `didSet` writer (exactly like `hideCron`/
  `groupByWorkspace` at `SessionStore.swift:67-83`/`:107-113`), so
  `visibleSessions` can read it. The sentinel `"all"` (or empty) = the aggregate
  view; a specific name = that profile's scope; absence = default profile.
- SWITCHER VISIBILITY (binding gate, two conditions): show the switcher control
  ONLY when `connection.capabilities.profiles == .available` AND the fetched
  profile count `> 1`. A supporting server with exactly ONE profile (the
  default) still returns `200` but `multiProfile` is false (desktop derives
  `profiles.length > 1`, `profile-switcher.tsx:130`) — so the switcher stays
  hidden, single-profile behavior is byte-for-byte the shipped app. Against our
  live 9119 / this-branch 9123 (no route → `.unavailable`), the switcher is
  hidden regardless. This double gate IS the dormancy guarantee.

## Module (single app module — F4B-A; smaller than F4a, still adversarially gated)

### Module F4B-A (app, Swift) — profile switcher + rail + threading + probe
One app agent. Touches ONLY:
- `Models/ProtocolTypes.swift` — add `SessionSummary.profile` (last field,
  `= nil`); add `ProfileSummary` + `ProfilesSessionsResult` types.
- `Stores/ServerCapabilities.swift` — add `profiles: State` field + eager probe
  wiring + Cache/applyCache/persist (single writer; the F4a `fs` pattern).
- `Networking/Rest/RestClient+Profiles.swift` (NEW) — `probeProfilesEndpoint`,
  `profiles()`, `profileSessions(…)`, per-session profile-threaded GET/PATCH/
  DELETE helpers. (No edit to `RestClient.swift` core beyond reusing its
  `internal` plumbing; if a new shared helper is unavoidable keep it minimal.)
- `Stores/SessionStore.swift` — `activeProfile` property (persisted, didSet),
  a `profiles: [ProfileSummary]` cache + a `loadProfiles()` fetch, the rail
  swap (aggregate vs `GET /api/sessions`) in the fetch path, the
  `visibleSessions` profile filter (the single funnel at `:150` that
  pinned/unpinned/grouped read through), and the conditional `profile` param at
  the create/resume call sites listed above.
- `Views/Drawer/DrawerView.swift` — the switcher `Menu` control (see placement).
- `Support/DefaultsKeys.swift` — add `activeProfile` (one disjoint key).
- `project.yml`/xcodegen ONLY if the new `RestClient+Profiles.swift` needs target
  membership (it lives under an existing source root, so likely no change —
  verify and regenerate iff required).
- F4B-A.1 capability probe (eager) in ServerCapabilities + RestClient helper.
- F4B-A.2 `ProfileSummary`/`ProfilesSessionsResult` decode + `SessionSummary.
  profile` field (last, defaulted).
- F4B-A.3 switcher `Menu` in the drawer (FULL NATIVE), gated on
  `profiles == .available && profileCount > 1`, persisting `activeProfile`.
- F4B-A.4 rail: `visibleSessions` profile filter + the aggregate fetch via
  `GET /api/profiles/sessions?profile=all` WHEN scope is "All" and multi is
  available; else the existing `GET /api/sessions`.
- F4B-A.5 optional `profile` threading on create/resume (WS) and PATCH/DELETE/GET
  (REST) when a specific non-default scope is active; seed/confirm the pref from
  `info.profileName`.
- F4B-A.6 unit tests (below). Debug + Release sim builds green.
  Commit: `hermes-mobile F4B-A: …`. (Separable for a possible upstream PR.)

### Placement of the switcher control (FULL NATIVE, two confirmed precedents)
Both precedents already exist in `DrawerView.swift`:
- PREFERRED: the header HStack (`:140-154`) has a `Spacer` between the "Hermes"
  wordmark (`:142-145`) and `avatarButton` (`:160-185`). A native `Menu` (a
  `Label` of profiles, e.g. `person.crop.circle` + the active profile name) drops
  into that Spacer cleanly — the highest-visibility, lowest-friction spot.
- ALT: a second accessory on the "Recents" `DrawerSectionHeader` (`:386-388`)
  next to `recentsFilterMenu` (`:395-414`) — that menu IS the exact pattern to
  copy (a SwiftUI `Menu` with checkmark `Button`s toggling state;
  `DrawerSectionHeader` `:701-730` supports a trailing `@ViewBuilder` accessory).
  Use this if the header is judged too crowded; pick ONE, do not add both.
- The control is a `Menu` (or `Picker`) listing each `ProfileSummary` + an "All
  profiles" item; selecting one writes `sessions.activeProfile` and triggers a
  rail refetch. Give it an `accessibilityIdentifier` (e.g. `drawerProfilePicker`)
  for the gate. It renders ONLY under the double visibility gate — when hidden,
  the header/recents layout is byte-identical to the pre-F4b drawer.

### F4B-A.6 unit tests (stubbed/fixture responses — no live patched server)
- ServerCapabilities `profiles` probe state machine: `200`+`{profiles:[…]}` ⇒
  `.available`; `404`/`405` ⇒ `.unavailable`; `500`/timeout ⇒ `.unknown`;
  Cache round-trip incl. a pre-F4b cache (no `profiles` key) restoring `.unknown`.
- `ProfileSummary` decode from a FIXTURE `GET /api/profiles` body captured
  verbatim from `_profile_to_dict` (`web_server.py:6757-6773`) — incl. the
  default row (`name=="default"`, `is_default==true`) and a named row
  (`is_default==false`); unknown keys ignored.
- `ProfilesSessionsResult` decode from a FIXTURE `GET /api/profiles/sessions`
  body captured verbatim from `web_server.py:1734-1741` + the per-row tags
  `:1717-1724` — assert `sessions`/`total`/`profileTotals`/`limit`/`offset`/
  `errors` and that each `SessionSummary.profile` carries the row's `profile`.
- `SessionSummary` round-trip: a row WITH `profile` decodes it; a stock row
  WITHOUT `profile` decodes `nil` (regression guard for the dormant path);
  all 3 positional memberwise callers still compile (build is the assertion).
- Switcher visibility gate: `(available, count>1)` ⇒ shown;
  `(available, count==1)` ⇒ hidden; `(unavailable, *)` ⇒ hidden;
  `(unknown, *)` ⇒ hidden.
- `visibleSessions` profile filter: with `activeProfile == "work"`, only rows
  whose `profile == "work"` survive; `activeProfile == "all"` (or nil) ⇒ all
  rows (subject to the existing cron filter, which still applies).
- create/resume param threading: assert `session.create`/`session.resume` params
  include `"profile"` ONLY when a specific non-default scope is active, and OMIT
  it for the default/all scope (the dormant/single path stays byte-for-byte).
- REST per-session threading error mapping: a `404 "Profile '<name>' does not
  exist."` and a `400` map to native inline errors (fixture bodies from
  `web_server.py:1654-1657`/`:5445-5457`).

## Integration gate (separate agent, runs after F4B-A lands; adversarial)
Own dashboard on 9123 (`HERMES_GATEWAY_BROADCAST=1`, no push armed) — a
9119-EQUIVALENT off THIS branch that LACKS the multi-profile endpoints. Sim
iPhone 17 Pro; iPad sim for the split/drawer items. Use the UI-G debug bridge:
DEBUG builds expose `StateServer` on loopback with `@Snapshotable` read accessors
(`DebugBridgeGenerated/StateAccessor.swift`); ADD `@Snapshotable` accessors for
the new surfaces (`profiles` capability state, profile count, active-profile
pref, switcher-visible bool) so the gate can assert dormancy and the visibility
gate without a patched server.
1. **DORMANCY against the real 9119-equivalent (BINDING — the core proof):**
   point the app at the this-branch 9123 (no `/api/profiles` route) → assert via
   the bridge `capabilities.profiles == .unavailable`, the switcher-visible bool
   is `false`, and NO profile chrome renders. SCREENSHOT the drawer header AND
   the Recents header; diff against a pre-F4b baseline screenshot → assert
   PIXEL-IDENTICAL (the dormancy guarantee). Exercise the normal app (open a
   session, send a prompt, switch sessions) → assert ZERO behavior change and no
   error. Also point at our live 9119 read-only (NO session/profile mutation) →
   assert the same `.unavailable` + hidden + pixel-identical result.
2. **Probe classification (fixtures, since no patched server):** drive
   `probeProfilesEndpoint()` against captured `200`/`404`/`405`/`500` responses
   (a local stub or the RestClient unit harness) → assert
   `.available`/`.unavailable`/`.unavailable`/`.inconclusive` and that a `200`
   without a `profiles` array is `.inconclusive`. Bridge-assert the
   `ServerCapabilities.profiles` transition for the `.available` case.
3. **Profile-list + switcher (fixture-fed):** inject a 2-profile
   `GET /api/profiles` fixture (default + "work", captured verbatim from
   `_profile_to_dict`) so the app believes multi-profile is available → assert
   the switcher `Menu` RENDERS (double gate satisfied), lists both profiles +
   "All profiles", marks the default, and selecting "work" persists
   `activeProfile == "work"` (bridge + UserDefaults) and survives relaunch.
   SCREENSHOT the open menu (iPhone sheet/menu AND iPad). Then inject a
   1-profile fixture → assert the switcher is HIDDEN (count gate).
4. **Rail aggregate vs single (fixture-fed):** with scope "All profiles" and a
   `GET /api/profiles/sessions?profile=all` fixture (captured verbatim from
   `web_server.py:1734-1741` + per-row tags) → assert the rail decodes the
   wrapper, each row's `SessionSummary.profile` is populated, and rows from BOTH
   profiles appear. Switch scope to "work" → assert `visibleSessions` filters to
   `profile == "work"` rows only. Switch back to the default scope → assert the
   rail falls back to the existing `GET /api/sessions` path (no
   `/api/profiles/sessions` call) — byte-for-byte the shipped single-profile fetch.
5. **create/resume threading (fixture/trace):** with active scope "work", trigger
   a create (new chat → first prompt) and a resume (open a session) → assert (via
   a request trace / bridge) the `session.create`/`session.resume` params carried
   `"profile": "work"`; with scope "All"/default → assert the param is ABSENT.
   Confirm the post-create `info.profileName` echo seeds/confirms the pref.
6. **REST per-session threading errors (fixture-fed):** drive a PATCH/DELETE/GET
   with an unknown profile against the captured `404 "Profile '<name>' does not
   exist."` / `400` bodies → assert the native inline error surfaces (no crash,
   no 500-as-success).
- Evidence dir: `/tmp/hermes-f4b-evidence/` (dormancy pixel-diff screenshots,
  fixture JSON used, bridge snapshots, request traces, UserDefaults dumps).
  Release build still green. Full iOS unit suite green. (No server suite — F4b
  has no server module.)
- Report: verdict per numbered item, the dormancy pixel-diff result FIRST,
  regressions, and STOP — no prod dashboard restart, no version bump, no
  TestFlight upload.

## Open questions (resolve before/early in the module; do not block dormancy)
- `_broadcast_event` profile-enrichment (REBASE-TIME FOLLOW-UP, OUT OF SCOPE):
  broadcast frames carry `stored_session_id` but NOT the owning profile, and
  stored ids now live in separate per-profile `state.db`s (collision risk across
  profiles). A future server fix adds `profile` alongside `stored_session_id` in
  `_broadcast_event`. Moot today (single-profile 9119 → `_profile_home` returns
  None everywhere); NOT in F4b. Recorded here so the rebase owner picks it up.
- Profile NAME validation regex (`normalize_profile_name`/`validate_profile_name`/
  `_PROFILE_ID_RE` in `hermes_cli/profiles.py`) was not extracted — if the
  switcher ever lets the user CREATE a profile (NOT in F4b scope; F4b only
  SWITCHES among existing profiles), client-side validation would need it. F4b
  does not call `POST /api/profiles`, so this is deferred.
- `session.resume` full success-response tail (`server.py:3282-3290+`, e.g.
  `history_version`/`cwd`) was not exhaustively enumerated; `profile` is
  round-tripped via session state, NOT echoed in the resume response — trust
  `info.profileName` (the create/resume `info` block) for the active-profile echo.
- Whether to carry `current.profile` through the `rename()` rebuild
  (`SessionStore.swift:635`) vs letting it default nil: nil is acceptable (the
  rail re-fetches and re-tags), but carrying it is a one-field polish — A's call,
  document the choice in the commit.
