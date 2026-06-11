# W3a Contract — Security Hardening (per-device tokens, revocation panel, approval audit log, token rotation / re-pair)

Security-hardening track, wave 3a. Adds **per-device pairing tokens** to the
WORKING hermes-mobile stack so the single shared bearer secret stops being the
only auth principal. Today the ENTIRE auth surface is one shared secret
(`_SESSION_TOKEN` / `~/.hermes/dashboard.token`) used identically across REST
(`X-Hermes-Session-Token` / `Authorization: Bearer`), WS (`?token=`), and the
mobile-pair QR (`hermesapp://pair?token=`). There is NO device identity in any
registry, NONE at approval-resolve time, and the gated-mode ticket already
carries OAuth `user_id`/`provider` (consumed-but-discarded) as the only existing
identity seam. W3a issues a **distinct token per paired device**, lets every
auth path accept BOTH the legacy shared token AND device tokens, surfaces a
native **Devices** revocation panel on iOS, records **which device resolved each
approval** in an append-only audit log, and adds a **re-pair / rotation** flow.

W3a spans a SERVER module (`hermes_cli/`, Python) and an APP module
(`apps/ios/HermesMobile`, Swift) running CONCURRENTLY, mirroring the F4A split.
The CORE invariant overriding every decision: **MIGRATION SAFETY** — the legacy
shared token MUST keep working unchanged throughout this entire batch. The
user's LIVE desktop + phone are paired with the shared token right now; nothing
in W3a may strand them. W3a is **purely additive**: it ADDS a device-token
acceptance path alongside the shared-token path; it NEVER removes, gates, or
weakens the shared-token path. Flipping any enforcement (e.g. "reject the shared
token once all devices re-paired") is a SEPARATE, user-coordinated step that is
explicitly NOT in this batch. On a stock / pre-W3a server the iOS Devices
section is feature-detected OFF and the app is byte-for-byte its pre-W3a self.

## BINDING constraints (/careful — the server is LIVE; migration safety is law)

- **MIGRATION SAFETY ABOVE ALL (the overriding constraint).** The legacy shared
  token (`_SESSION_TOKEN`, sourced from `~/.hermes/dashboard.token`) MUST remain
  a fully-valid credential on EVERY auth path for the entire batch. Each new
  device-token check is an OR-branch added BEFORE/AFTER the existing
  `hmac.compare_digest(..., _SESSION_TOKEN)` check, never a replacement of it.
  `_has_valid_session_token` returns True if EITHER the shared token OR a live
  device token matches; the WS gate accepts EITHER. There is NO config flag in
  W3a that turns the shared token off — adding one is a later, separate,
  user-coordinated PR. If any reviewer reads a change that could reject the
  shared token, that change is out of scope and must be cut.
- `ai.hermes.dashboard` on `127.0.0.1:9119` is the user's LIVE shared backend
  (desktop + phone connected via the shared token). NEVER restart, stop, reload,
  re-pair, or revoke anything on it. NEVER point test traffic at it that issues,
  lists, or revokes device tokens, mutates `push_tokens.json`/`device_tokens.json`,
  or writes the audit log. /careful applies: own instances ONLY.
- All live testing runs against YOUR OWN dashboard instance on port 9123
  (pattern: `HERMES_DASHBOARD_SESSION_TOKEN=<own> HERMES_GATEWAY_BROADCAST=1
  venv/bin/hermes dashboard --no-open --tui --host 127.0.0.1 --port 9123` from
  the repo checkout; leave `HERMES_PUSH_ENABLED` unset unless a test needs it).
  Use a throwaway `HERMES_HOME` (e.g. `HERMES_HOME=/tmp/hermes-w3a-home`) so the
  new `device_tokens.json` + `approval_audit.jsonl` never touch `~/.hermes`. Kill
  the instance and delete the temp home when done.
- Production rollout (restarting the real dashboard so the new server code loads)
  is NOT yours — report completion; the main thread coordinates any restart. The
  shared token keeps working before AND after that restart by construction.
- Branch `hermes-mobile` only. NEVER push to any remote. No build artifacts in
  commits. Swift 6 strict, iOS 17 base, availability-gate newer API and VERIFY
  signatures against the iPhoneSimulator26.5 SDK swiftinterface before coding
  (house standard since the geometry fix).
- XcodeGen: any target/Info.plist change goes in `project.yml` + regenerate
  (`xcodegen generate` in `apps/ios`). Do NOT bump `CURRENT_PROJECT_VERSION` /
  `MARKETING_VERSION` — version bumps happen at TestFlight ship time only.
- STOCK-SERVER DEGRADATION: every new endpoint (`/api/devices`,
  `/api/devices/issue`, `/api/devices/{id}` DELETE, `/api/approvals/audit`) MUST
  be feature-detected via `ServerCapabilities` (`Stores/ServerCapabilities.swift`)
  — add a `devices: State` field + an EAGER probe per the existing `fs`/`upload`/
  `profiles` pattern, and gate EVERY Devices-section affordance on
  `connection.capabilities.devices == .available`. A stock hermes-agent (no
  device routes) MUST hide the Devices section entirely and never error.
- UPSTREAM ALIGNMENT (binding — the rebase brings a WS-auth refactor): commit
  `6717914e0` (PR #38743, on `origin/main`, NOT yet on `hermes-mobile`) converts
  `_ws_auth_ok(ws)->bool` into `_ws_auth_reason(ws)->(reason, credential)` and
  adds `_ws_auth_mode()`, `_ws_close_reason`, and distinct pty close codes
  (4401 auth / 4403 host-origin / 4408 peer / 4404 chat-disabled). The W3a WS
  device-token check MUST be designed as a THIN, SEPARABLE layer that survives
  that refactor: implement it as a single helper `_ws_device_token_match(token)
  -> Optional[dict]` (returns device identity info or None) that the WS gate
  calls as one extra OR-branch. Pre-rebase it slots into `_ws_auth_ok`; post-
  rebase it slots into `_ws_auth_reason` returning `credential="device"` and the
  device info — ONE call-site edit either way, no logic rewrite. Build on the
  `(reason, credential)` tuple shape, NOT the old bool, where the rebase has
  landed. Keep every server change in a separate commit per the PR series.
- SECRETS HYGIENE — BINDING: a device token (like the shared token) is NEVER
  logged in full (truncate to an 8-char prefix + "…" in any audit/error/log
  line, mirroring `consume_ticket`'s truncation at `ws_tickets.py:94`), NEVER
  echoed back on list, and is compared ONLY via `hmac.compare_digest` /
  `secrets.compare_digest` (timing-safe, matching every existing comparison).
  On iOS the device token is stored ONLY in the Keychain (the existing
  `KeychainService`, keyed by server URL), NEVER in UserDefaults, NEVER in a
  `@Snapshotable` accessor, NEVER in the DEBUG ring buffer. The audit log stores
  a token's stable `device_id` and an 8-char prefix, NEVER the token itself.
- UI follows the UI-I FULL NATIVE principle: system components only (`List`,
  `Section`, `Button`, `Label`, `LabeledContent`, sheets, `confirmationDialog`).
  The Devices section mirrors the F2 Notifications inline-section pattern
  (`SettingsView.swift:293-354`); identity via tint (`theme.destructive` for the
  revoke button, matching the existing Disconnect button at `:384-421`). No
  custom-drawn chrome.

## Interface (pinned — all four modules code against THIS, not each other)

### Device-token registry file (server, NEW — F-pattern: atomic 0600 + lock)
A NEW registry `<HERMES_HOME>/device_tokens.json`, distinct from the existing
`push_tokens.json` (APNs) and `live_activity_tokens.json` (LA). It stores ONE
entry per paired device. Reuse the CANONICAL atomic-write helper from
`push_notify.py` — `_save_la_registry` (`push_notify.py:616-630`): `parent.
mkdir(parents=True, exist_ok=True)` → write `path.with_suffix(suffix+'.tmp')` →
`os.replace(tmp, path)` → `os.chmod(path, 0o600)` in a `try/except OSError`
(non-POSIX safe). NOTE the existing inconsistency to NOT replicate: the alert
`_save_registry` (`push_notify.py:382-390`) omits the `chmod 0o600` — the new
device-token saver MUST include it (this file holds live credentials). Serialise
read-modify-write under a module-level `threading.Lock` (mirror `_la_registry_
lock` at `:580`); register/revoke wrap `_load` + mutate + `_save` under the lock.
File shape — a JSON object keyed by `device_id` (NOT a flat list; keying enables
O(1) revoke and prevents duplicate-device drift):
```
{
  "<device_id>": {
    "token_hash": "<hex sha256 of the device token>",   // NEVER the token itself
    "token_prefix": "<first 8 chars of the token>",      // for the audit log + UI hint
    "device_name": "<human label, ≤64 chars, sanitized>",
    "platform": "ios",
    "created_at": <epoch float>,
    "last_seen": <epoch float>,                          // refreshed on each accepted auth
    "scopes": ["chat", "approve"]                        // reserved; default both; see note
  },
  …
}
```
- `device_id` is a server-minted opaque id (`"dev_" + secrets.token_urlsafe(12)`),
  the STABLE handle the iOS app stores and the audit log references. It is NOT
  the token and NOT secret (safe to list/log).
- The TOKEN itself is `secrets.token_urlsafe(32)` (matching `mint_ticket` /
  `internal_ws_credential` entropy) and is returned to the client EXACTLY ONCE at
  issue time. The registry stores ONLY `sha256(token)` (`token_hash`) + an 8-char
  `token_prefix`. Auth comparison hashes the presented token and `hmac.compare_
  digest`-checks against stored `token_hash` (timing-safe; the registry never
  holds a recoverable secret — defense in depth vs the shared-token file which is
  plaintext, because device tokens are many and revocable).
- `last_seen` is updated (best-effort, under lock, NOT on the hot path of every
  request — see "auth acceptance" note) so the panel can show "last active".
- `scopes` is RESERVED for forward-compat; W3a issues `["chat","approve"]` for
  every device and does NOT enforce per-scope gating (enforcement is a later
  batch). Decoders MUST tolerate its absence (legacy/forward-compat) → treat as
  full scope. Recorded as an open question.
- A new `_device_registry_path()` mirrors `_registry_path()` (`push_notify.py:
  333-344`), honouring `HERMES_HOME`. A `_normalize_device_name()` strips control
  chars, collapses whitespace, truncates to 64, defaults to `"iPhone"` if empty.

### Auth acceptance — both paths accept device tokens (server, the migration-safe core)
TWO acceptance points, each gaining ONE additive OR-branch. NEITHER removes the
shared-token branch.
- **REST** — `_has_valid_session_token(request)` (`web_server.py:176-193`). Today:
  shared-token header check → legacy Bearer fallback, both `hmac.compare_digest`.
  ADD a third branch AFTER both: if neither matched, hash the presented credential
  (header value, then Bearer value) and call a NEW `device_tokens.match(token) ->
  Optional[dict]` (returns the device entry incl. `device_id`, or None). On a
  match, stash the resolved device identity on `request.state.device` (so the
  approval handler can read it) and return True; bump `last_seen` best-effort.
  Order: shared token first (fast path, the common live case), device token only
  on shared-token miss (so the live shared-token user pays zero extra cost). When
  `request.app.state.auth_required` is True (gated/OAuth mode) the legacy token
  path is ALREADY skipped (`web_server.py:324-325`) and cookie auth is
  authoritative — device tokens follow the SAME rule: they are a peer of the
  legacy shared token, NOT of the OAuth cookie, so they too are skipped in gated
  mode (W3a targets the loopback/shared-token deployment, which is the live one).
- **WS** — the `?token=` gate. Pre-rebase: `_ws_auth_ok(ws)` (`web_server.py:
  7034-7105`), loopback branch at `:7104-7105`. Post-rebase: `_ws_auth_reason(ws)`
  (commit `6717914e0`). ADD the SAME `_ws_device_token_match(token)` OR-branch
  AFTER the shared-token `hmac.compare_digest`: if the shared token misses, hash
  `ws.query_params.get("token")` and match against the device registry; on a hit
  accept (pre-rebase: return True; post-rebase: `reason=None, credential="device"`
  + carry the device info forward, the natural successor to the ws_tickets
  `info`-dict seam). The `?ticket=`/`?internal=` gated-mode paths are UNTOUCHED.
  This helper is the ONE function the rebase owner re-slots; everything else is
  unchanged. Device identity from a WS accept is carried to `approval.respond`
  via the session-attach context (see audit seam).
- BINDING: BOTH branches are OR-additive. Removing or gating the shared-token
  branch in either function is OUT OF SCOPE and a review-stop.

### NEW endpoint #1 — issue a device token (server, token-gated)
`POST /api/devices/issue` in `hermes_cli/web_server.py`. The QR/`mobile-pair`
flow and the in-app re-pair flow both call this to mint a device token. NEW.
- Auth: `/api/`-middleware-gated (NOT in `_PUBLIC_API_PATHS`) PLUS an explicit
  in-handler `_has_valid_session_token(request)` 401 check — house precedent for
  `/api/` mutators (mirrors `/api/approvals/respond` at `web_server.py:1345`).
  CRITICAL: the caller authenticates with EITHER the shared token (the QR carries
  it today) OR an existing device token (re-pair / rotation from an already-paired
  device). Issuing is thus available to anyone holding any valid credential —
  acceptable because holding a valid credential already grants full access; the
  device token is a NARROWER, revocable re-grant, not an escalation.
- Body (JSON): `{"device_name": str (optional; sanitized, default "iPhone"),
  "platform": str (optional, default "ios")}`. No token is accepted in the body
  (the token is server-minted).
- Behaviour: mint `device_id` + token, write the registry entry (atomic 0600,
  under lock), return the token ONCE.
- Responses:
  - `200` `{"device_id": str, "token": str, "device_name": str, "created_at":
    float}` — the ONLY time `token` is ever returned. The client MUST persist it
    to Keychain immediately.
  - `400` `{"error":"invalid device_name"}` if the name fails normalization to a
    non-empty ≤64-char string (after sanitization) — defensive; normalization
    normally coerces rather than rejects.
  - `401` bad/absent credential.
  - Registry-write failure → `500` `{"error":"registry persist failed"}` (issue
    MUST fail loud since the token would be unusable — no auth gate in this or any
    other process could match an un-persisted token). The token is NOT returned if
    the write fails.

### NEW endpoint #2 — list devices (server, token-gated)
`GET /api/devices` in `hermes_cli/web_server.py`. Backs the iOS Devices panel AND
the eager capability probe. NEW.
- Auth: middleware + explicit `_has_valid_session_token` 401.
- No query params.
- `200` `{"devices": [{"device_id": str, "device_name": str, "platform": str,
  "created_at": float, "last_seen": float, "token_prefix": str, "scopes":
  [str]}]}` — sorted `last_seen` desc (most-recent first). NEVER includes
  `token` or `token_hash`. An empty registry → `{"devices": []}` (200, NOT 404 —
  the route exists, so the probe still classifies it `.available`).
- `401` bad/absent credential. Never 500 (a corrupt/missing registry file →
  `{"devices": []}`, mirroring `_load_registry`'s corrupt-file fallback at
  `push_notify.py:370-372`).
- This is the EAGER probe target (see capability probe): a stock server with no
  route → `404`/`405` ⇒ `.unavailable`.

### NEW endpoint #3 — revoke a device (server, token-gated)
`DELETE /api/devices/{device_id}` in `hermes_cli/web_server.py`. Backs the panel's
revoke button. NEW. Invalidates the device token IMMEDIATELY.
- Auth: middleware + explicit `_has_valid_session_token` 401.
- Path param: `device_id`.
- Behaviour: remove the entry from the registry (atomic 0600, under lock). After
  removal the device's token no longer matches in `device_tokens.match`, so its
  NEXT REST request and its NEXT WS auth both fail (`401` / WS close). LIVE WS CUT
  (best-effort, where feasible): if the revoked `device_id` has live WS socket(s)
  attributed to it, close them immediately. Implementation note: WS sockets are
  not currently indexed by device today — the server maintains a per-process map
  `{device_id: set[WebSocket]}` populated when a WS auth resolves to a device
  (the `_ws_device_token_match` accept path registers the socket; the pty/ws
  endpoints deregister on close). On revoke, iterate that set and call
  `ws.close(code=4401, reason="device revoked")` (post-rebase: route through the
  new `_ws_close_reason` clamp). If the index is empty for that device (no live
  socket, or a socket on the shared token), the revoke still succeeds — the
  device simply fails on its next auth. This live-cut map is the one piece of new
  WS state; keep it minimal and behind the same lock discipline.
- Responses:
  - `200` `{"revoked": true, "device_id": str, "sockets_closed": int}`.
  - `404` `{"error":"unknown device"}` if `device_id` is not in the registry.
  - `401` bad/absent credential.
  - `500` `{"error":"revocation persist failed", "revoked": true, "device_id":
    str, "sockets_closed": int}` on a registry-write failure. The token is ALREADY
    dead in THIS process (the `token_hash` is recorded in the in-process deny-set
    BEFORE the disk write, and `match` consults that deny-set first), and any live
    WS sockets are still cut — but the on-disk file is STALE, so OTHER processes
    (and a restart of this one) keep authenticating the token until disk is
    writable and the revoke is retried. The `500` makes that durability gap
    visible rather than reporting a false clean revoke.
- BINDING: revoking a device NEVER affects the shared token. A device cannot
  revoke the shared token via this endpoint (no `device_id` maps to it).

### NEW endpoint #4 — approval audit log (server, append-only, token-gated read)
`GET /api/approvals/audit` in `hermes_cli/web_server.py`. Surfaces the audit log
read-only in the iOS panel. The WRITE side extends the existing resolve path
(below). NEW read endpoint.
- Auth: middleware + explicit `_has_valid_session_token` 401.
- Query params: `limit: int = 100` (cap 500; clamp, never error), `session_id:
  str` (optional filter).
- `200` `{"entries": [<audit record>, …]}` — most-recent-first, the tail window.
  Record schema below. NEVER includes a full token (only `token_prefix` +
  `device_id`).
- `401` bad/absent credential. Missing/corrupt log file → `{"entries": []}`
  (200). Never 500.

#### Audit JSONL schema (append-only 0600 file)
`<HERMES_HOME>/approval_audit.jsonl` — one JSON object per line, append-only.
Written by the resolve path (REST + WS). Atomic-append: open in `"a"` mode under
a module-level `_audit_lock`, `write(json.dumps(rec) + "\n")`, `flush()`; on
FIRST create `os.chmod(path, 0o600)` (mirror the LA chmod; a JSONL append can't
use the tmp+replace idiom, so chmod-on-create + append-under-lock is the pattern).
One record per resolved approval:
```
{
  "ts": <epoch float>,
  "session_id": "<runtime session id>",
  "session_key": "<gateway session_key>",       // stable session identity
  "choice": "once" | "session" | "always" | "deny",
  "resolve_all": <bool>,
  "credential": "device" | "shared" | "internal" | "cookie",  // which auth path resolved it
  "device_id": "<device_id>" | null,             // present iff credential == "device"
  "device_name": "<label>" | null,               // denormalized for read-only display
  "token_prefix": "<8 chars>" | null,            // present iff a token resolved it; NEVER the full token
  "command_preview": "<≤120 chars of the approved command/description>"
}
```
- `command_preview` is derived from the `_ApprovalEntry.data` (`approval.py:542`,
  carries `command`/`description`/`pattern_keys`) — truncate to 120 chars, never
  log secrets that might ride in a command (the preview is a hint, the entry
  already exists in the session). If unsure a command may contain a secret,
  prefer `description` over `command`.
- `credential`/`device_id`/`device_name`/`token_prefix` come from the auth
  context threaded into the resolve call (see resolve-path extension).

### Approval resolve path — capture identity (server, extends F2 respond + WS)
Today resolve captures NO identity: `_ApprovalEntry` (`approval.py:536-543`) has
only `event`/`data`/`result`; `resolve_gateway_approval(session_key, choice,
resolve_all)` (`approval.py:575-601`) sets `result` + fires the event; the REST
handler `respond_to_approval` (`web_server.py:1335-1375`) and the WS RPC
`approval.respond` (`tui_gateway/server.py:5084-5103`) both call it with NO
caller identity. W3a THREADS identity to the audit WRITE without changing the
agent-unblock semantics:
- ADD an OPTIONAL `audit: Optional[dict] = None` keyword param to
  `resolve_gateway_approval` (back-compat: existing callers pass nothing). When
  present and ≥1 approval resolved, append ONE audit record per resolved entry
  (carrying `command_preview` from each `entry.data`). Do NOT add an identity
  field to `_ApprovalEntry` — the identity belongs to the RESOLVER, not the
  pending request; pass it at resolve time.
- REST `respond_to_approval`: build the `audit` dict from `request.state.device`
  (set by `_has_valid_session_token` on a device-token match) → `credential=
  "device"`, `device_id`/`device_name`/`token_prefix` from the entry; else
  `credential="shared"` (shared token), `device_id=None`. Pass `audit=` to
  `resolve_gateway_approval`.
- WS `approval.respond`: the WS connection's auth resolution (device vs shared vs
  internal) is carried on the session-attach context established at WS auth time
  (the `_ws_device_token_match` accept path stashes the device info on the
  connection state, the successor to the discarded `consume_ticket`/`consume_
  internal_credential` info dict). Build the same `audit` dict from that context
  and pass it through. `credential="internal"` for the server-spawned PTY child.
- BINDING: the audit write is BEST-EFFORT and MUST NOT block or fail the
  approval resolution — wrap the append in `try/except` and log a truncated
  warning on failure. An approval ALWAYS resolves even if the audit log can't be
  written (availability > auditability for the live agent loop).

### QR payload v2 — backward-compatible device-token carry (server CLI + iOS)
Today `hermes mobile-pair` prints `hermesapp://pair?url=<url>&token=<shared
token>` (`mobile_pair.py:_build_pair_link:197-202`) and iOS parses scheme==
`hermesapp` + host==`pair` + required `url`+`token` (`HermesURLRouter.swift:
73-81`, `QRScannerView.parsePairPayload:221-238`). v2 is ADDITIVE and BACKWARD-
COMPATIBLE:
- **v1 (unchanged, still emitted by a stock server / still parsed):** `hermesapp://
  pair?url=<url>&token=<shared>`. A v1 QR scanned by a W3a app → the app pairs
  with the shared token AND THEN, if the server advertises the devices capability
  (probe after connect), silently calls `POST /api/devices/issue` to upgrade
  itself to a device token (see iOS rotation). So even a v1 QR yields a per-device
  token on a W3a server, with zero new QR fields.
- **v2 (W3a server, opt-in):** `hermes mobile-pair` gains a `--device-token` flag
  (DEFAULT keeps v1 behaviour to avoid surprising the live flow) that, when set,
  calls `POST /api/devices/issue` itself and emits `hermesapp://pair?url=<url>&
  token=<DEVICE token>&kind=device&device_id=<id>`. The NEW query keys are `kind`
  (`device`|absent⇒`shared`) and `device_id` (present iff `kind=device`). A v1
  app (no `kind` awareness) IGNORES the extra keys and treats `token` as before —
  it pairs with what is, to it, just "the token" (which happens to be a device
  token). A W3a app reads `kind`/`device_id` to record the device identity it was
  handed. BINDING: `token` remains the credential key in BOTH versions so old
  parsers never break; `kind`/`device_id` are purely additive.
- iOS parse contract extension: `parsePairPayload`/`HermesURLRouter.route` keep
  requiring `url`+`token`; they OPTIONALLY read `kind`+`device_id`. Absent ⇒
  shared-token pairing (then auto-upgrade via issue). Present+`device`⇒ store the
  device token + `device_id`.

### Device capability probe (app ↔ server) — `GET /api/devices` (EAGER)
Add `devices: State` to `ServerCapabilities` (`Stores/ServerCapabilities.swift`),
mirroring `fs`/`profiles` VERBATIM. EAGER, side-effect-free: `GET /api/devices`
→ `200` (+ well-formed `{"devices":[…]}`) ⇒ `.available`; `404`/`405` ⇒
`.unavailable`; else ⇒ `.inconclusive`. Add `static func probeDevices(rest:)`
mirroring `probeProfiles`/`probeFs`, a `rest.probeDevicesEndpoint() ->
UploadProbeResult` on a NEW `RestClient+Devices.swift` (mirror `RestClient+FS.
swift:28-41` exactly), wire it into `probe()`'s concurrent `async let` group, the
`Cache` struct (+ `CodingKeys` + tolerant `init(from:)` defaulting `.unknown` for
a pre-W3a cache) + `applyCache`/`persist`/`reset`. Single writer of
`ServerCapabilities` for W3a = the APP module. View-gate the Devices section on
`connection.capabilities.devices == .available`.

### iOS device-token storage + auto-upgrade rotation
- The device token is stored in the EXISTING `KeychainService` (`Networking/Rest/
  KeychainService.swift`), keyed by the server URL string (the existing one-token-
  per-gateway model). W3a does NOT add a second keychain item shape; the device
  token REPLACES the shared token as the stored credential once issued (the app
  authenticates with whichever token is in Keychain — shared or device — and both
  are accepted by the server). The `device_id` (non-secret) is stored alongside in
  UserDefaults via a NEW `DefaultsKeys` key (`hermes.deviceId`), so the Devices
  panel can mark "this device".
- AUTO-UPGRADE (silent rotation, the migration bridge): after `configure()`
  succeeds and the `devices` capability probes `.available`, if the stored token
  is NOT already a device token (no `hermes.deviceId` recorded for this server),
  the app calls `POST /api/devices/issue` with `device_name = UIDevice.current.
  name` (note: returns a generic "iPhone" on iOS 16+ without the user-assigned-
  name entitlement — acceptable; the user can rename later / the name is a hint),
  persists the returned token to Keychain (overwriting the shared token IN THE
  KEYCHAIN ITEM for this server URL) and the `device_id` to UserDefaults, and
  re-reads the token for subsequent requests. BINDING: this is the ONLY new path
  that mutates `currentToken`/Keychain mid-session — it MUST update
  `ConnectionStore.currentToken` (`:113`) + `KeychainService.saveToken`
  (`:211` pattern) WITHOUT calling `configure()`/`disconnect()`/`connect()` (no
  socket rebuild, no capability reset) — the token swap is transparent because
  the server accepts both. This is the FIRST true silent-rotation path in the app
  (the F4 read noted none existed). If issue fails, the app KEEPS the shared token
  (no regression) and retries on next connect.
- RE-PAIR (explicit, the revocation recovery): if THIS device is revoked from
  another device, its next request 401s → the EXISTING D3 re-pair flow fires
  (`ConnectionStore.isAuthFailure` → `reauthRequired` → `phase=.needsSetup` →
  `WelcomeView` reauthBanner, `RootView.swift:50`). Re-scanning a QR re-pairs:
  on a W3a server the new pairing again auto-upgrades to a FRESH device token (a
  NEW `device_id`). The reauthMessage ("This device's pairing was revoked. Scan a
  new pairing code to reconnect.") already fits verbatim. NO new re-pair UI is
  needed — W3a reuses the existing mount.
- OLD-TOKEN GRACE: there is NO server-side grace window in W3a (a revoked device
  token is invalid immediately — that is the security goal). The "grace" is the
  CLIENT-SIDE `consecutiveReconnectFailures` + `authReprobeThreshold = 3`
  (`ConnectionStore.swift:69,73,413-421`) that already prevents a single transient
  401 (e.g. a rotation race during auto-upgrade) from bouncing a live session.
  W3a does NOT change those thresholds. (A server-side overlap window — old + new
  token both valid for N seconds during rotation — is explicitly OUT OF SCOPE; the
  auto-upgrade is atomic from the client's view because the server accepts the old
  token until the moment the new one is persisted, and persistence is local.)

## Module split (FOUR work-items in TWO modules; file-ownership boundaries below)

### Module W3A-S (server, Python) — touches hermes_cli/ + tools/approval.py + tui_gateway/ + tests
Owns ALL server-side W3a. Files: a NEW `hermes_cli/device_tokens.py` (registry +
match + issue/list/revoke logic + the live-WS-socket index), `hermes_cli/
web_server.py` (the 4 endpoints, the `_has_valid_session_token` device branch,
the WS `_ws_device_token_match` branch + socket index reg/dereg, the audit read
endpoint), `hermes_cli/audit_log.py` (NEW, append-only 0600 JSONL writer +
reader), `hermes_cli/mobile_pair.py` (the `--device-token` flag + v2 link),
`tools/approval.py` (the optional `audit=` param on `resolve_gateway_approval`),
`tui_gateway/server.py` (thread the WS auth context into `approval.respond`), and
the server test modules. Touches NO Swift.
- S1 `device_tokens.py`: `_device_registry_path`, atomic 0600 save (WITH chmod —
  fix the inconsistency), `threading.Lock`, `issue()`, `list_devices()`,
  `revoke()`, `match(token)->Optional[dict]` (sha256 + `hmac.compare_digest` vs
  `token_hash`, bumps `last_seen` best-effort), `_normalize_device_name`. The
  live-WS-socket index `{device_id: set}` + register/deregister/close-all helpers.
- S2 the 4 endpoints in `web_server.py` (`/api/devices/issue` POST, `/api/devices`
  GET, `/api/devices/{id}` DELETE, `/api/approvals/audit` GET) — middleware +
  explicit token check, error codes per spec, NEVER 500.
- S3 auth acceptance branches: the additive device OR-branch in `_has_valid_
  session_token` (stash `request.state.device`) AND the `_ws_device_token_match`
  branch in `_ws_auth_ok` / `_ws_auth_reason` (rebase-aware: one helper, slotted
  per the upstream shape present at code time). Register/deregister the live
  socket in the index on WS accept/close.
- S4 audit: `audit_log.py` (append-under-lock, chmod-on-create, truncated
  prefixes, reader with limit/session_id filter); the optional `audit=` param on
  `resolve_gateway_approval` (`tools/approval.py`); the REST + WS resolve sites
  building the `audit` dict from the auth context (best-effort, never blocks
  resolve).
- S5 `mobile_pair.py` `--device-token` flag (default OFF = v1) + v2 link with
  `kind`/`device_id`; token still printed exactly once, never logged.
- S6 tests (httpx/TestClient + unit): MIGRATION-SAFETY FIRST — shared token still
  authenticates REST + WS unchanged; issue→list→revoke round-trip; a device token
  authenticates REST + WS; a revoked device token 401s REST + fails WS; the live
  WS cut closes the socket; audit record written on REST respond AND WS respond
  with the right `credential`/`device_id`; audit read with limit/session filter;
  registry + audit files are `0600`; bad/absent token → 401 on all 4 endpoints;
  corrupt registry/audit → empty, never 500; v2 link parse round-trip. Full
  server suite stays green. Commit style (separable per PR): `hermes-mobile W3A-S:
  …` — and KEEP the auth-acceptance branch, the endpoints, the audit, and the QR
  change in SEPARATE commits so the PR series can land them independently.

### Module W3A-A (app, Swift) — Devices panel + capability probe + storage + rotation
Owns ALL iOS W3a. Touches ONLY: `Stores/ServerCapabilities.swift` (add `devices`
State + eager probe wiring + Cache/applyCache/persist/reset — single writer),
`Networking/Rest/RestClient+Devices.swift` (NEW — `probeDevicesEndpoint`,
`devicesList()`, `issueDevice(name:)`, `revokeDevice(id:)`, `approvalAudit(limit:
sessionId:)`, mirroring `RestClient+FS.swift`), `Stores/ConnectionStore.swift`
(the auto-upgrade rotation path: post-configure issue + token swap WITHOUT
reconfigure; read `kind`/`device_id` from the pair payload), `Networking/Rest/
KeychainService.swift` (NO shape change — reuse `saveToken`/`loadToken`; the
device token IS the stored token), `Models/HermesURLRouter.swift` +
`Views/Onboarding/QRScannerView.swift` (parse optional `kind`/`device_id` —
additive, v1 payloads still parse), a NEW `Views/Settings/DevicesView.swift` (the
native List of devices + revoke), `Views/Settings/SettingsView.swift` (mount the
Devices section, mirroring the F2 Notifications section at `:293-354`, gated on
`capabilities.devices == .available`), an optional NEW `Views/Settings/
ApprovalAuditView.swift` (read-only audit list, pushed from the Devices section),
`Support/DefaultsKeys.swift` (NEW disjoint keys: `hermes.deviceId`), and
`project.yml`/xcodegen iff the new files need target membership.
- A1 `devices` capability probe (eager) in ServerCapabilities + `RestClient+
  Devices.probeDevicesEndpoint`, wired through probe()/Cache/persist (single
  writer).
- A2 REST surface: `devicesList`/`issueDevice`/`revokeDevice`/`approvalAudit`
  decode + typed error mapping (401/404/500 → native inline errors).
- A3 auto-upgrade rotation: post-configure, if `.available` AND no `deviceId`
  recorded for this server, `issueDevice(name: UIDevice.current.name)` → persist
  token to Keychain + `device_id` to UserDefaults + swap `currentToken` WITHOUT
  reconfigure. Keep shared token on failure (no regression).
- A4 QR v2 parse: read optional `kind`/`device_id`; v1 payloads unchanged; on
  `kind=device` record the handed `device_id`.
- A5 Devices section (FULL NATIVE): a `Section` in SettingsView (gated) listing
  devices via `GET /api/devices` (name, platform, last-seen relative date,
  `token_prefix` hint, "This device" marker for the local `deviceId`), each row a
  revoke `Button(role: .destructive)` behind a `confirmationDialog` (mirror the
  Disconnect dialog at `SettingsView.swift:384-421`). Revoke calls `DELETE` →
  removes the row; if the user revokes THIS device, fall through to the existing
  re-pair flow on next 401. Optional pushable `ApprovalAuditView` (read-only list
  of audit entries via `GET /api/approvals/audit`).
- A6 re-pair: NO new UI — verify the existing `reauthRequired` → `WelcomeView`
  path fires on a 401 from a revoked device token and that a re-scan auto-upgrades
  to a fresh device token. (Reuse, not rebuild.)
- A7 unit tests: probe state machine (200/404/405/500 + Cache round-trip incl.
  pre-W3a cache); devicesList/issue/revoke/audit decode + error mapping; QR v2
  parse (v1 + v2 fixtures, unknown keys ignored); auto-upgrade decision logic
  (issues iff available + no recorded deviceId; keeps shared token on failure;
  does NOT reconfigure); SECRET-HYGIENE assertion (the token never lands in
  UserDefaults / a `@Snapshotable` accessor / the DEBUG ring buffer — only
  Keychain); Devices-section visibility gate (available⇒shown, unavailable/
  unknown⇒hidden). Debug + Release sim builds green. Commit: `hermes-mobile W3A-A:
  …`.

### Ownership boundary notes (so the modules never collide)
- W3A-S (Python) and W3A-A (Swift) share NO files — they run fully concurrently.
- `ServerCapabilities.swift` + `RestClient+*.swift` are W3A-A-owned (single writer
  of the `devices` field). No other in-flight batch touches the `devices` field.
- `DefaultsKeys.swift` gains ONE disjoint key (`hermes.deviceId`) — trivially
  mergeable enum addition; if it races another batch's key add, the second rebases.
- The four server work-items (auth-acceptance, endpoints, audit, QR) are kept in
  SEPARATE commits within W3A-S so the upstream PR series can land them piecewise
  and so the rebase owner re-slots ONLY the `_ws_device_token_match` helper.
- The WS-auth device branch is a SINGLE helper (`_ws_device_token_match`) — the
  ONE function that the `6717914e0` rebase re-points. It does not duplicate auth
  logic; it returns device info or None and the gate folds it into its existing
  accept/reject decision (bool pre-rebase, `(reason, credential)` post-rebase).

## Integration gate (separate agent, runs after S and A land; adversarial)
Own dashboard on 9123 (`HERMES_GATEWAY_BROADCAST=1`, throwaway `HERMES_HOME=/tmp/
hermes-w3a-home`, no push armed unless a step needs it), sim iPhone 17 Pro; iPad
sim for split items. Use the UI-G debug bridge: DEBUG builds expose `StateServer`
on loopback with `@Snapshotable` read accessors; ADD accessors for the new
surfaces (`devices` capability state, recorded `device_id` for this server,
Devices-section-visible bool, device row count) — NEVER the token value.
1. **LEGACY-TOKEN REGRESSION (BINDING — runs FIRST, the migration-safety proof):**
   start 9123 with a shared `HERMES_DASHBOARD_SESSION_TOKEN`. With NO device
   tokens issued, assert the shared token authenticates EVERY path UNCHANGED:
   REST `GET /api/sessions` 200, REST `/api/approvals/respond` resolves, WS
   `?token=<shared>` connects, a full chat turn completes, an approval resolves.
   Then issue a device token and assert the shared token STILL works on all the
   same paths (additive, not replacing). This step must pass before any other —
   if the shared token is ever rejected, STOP and report a migration-safety
   regression.
2. **Issue / list / revoke round-trip:** `POST /api/devices/issue` (curl, shared
   token) → assert a `token` + `device_id` returned ONCE; `GET /api/devices` →
   assert the device appears with `token_prefix` (NOT the full token),
   `created_at`, `last_seen`, NO `token`/`token_hash` in the body. Issue a second
   device → assert both list, sorted `last_seen` desc. `DELETE /api/devices/
   {id}` → assert `{"revoked":true}` and the row disappears from `GET /api/
   devices`. Assert `device_tokens.json` on disk is mode `0600`.
3. **Device token auth + revoked-token 401 + LIVE WS CUT:** authenticate REST
   `GET /api/sessions` with the device token (header AND Bearer) → 200; connect
   WS `?token=<device>` → assert connected and a chat frame flows. Then `DELETE`
   that device while the WS is OPEN → assert (a) the open WS is closed immediately
   with code 4401 (`sockets_closed >= 1` in the revoke response), and (b) the
   device token now 401s on REST and fails the WS auth on reconnect. Assert the
   SHARED token is unaffected throughout (still 200 / still connects).
4. **Audit entries from TWO different identities:** resolve one approval via the
   SHARED token (REST `/api/approvals/respond`) and one via a DEVICE token (REST,
   AND once via WS `approval.respond` over a device-authed socket) → `GET /api/
   approvals/audit` → assert distinct records: the shared one has `credential:
   "shared"`, `device_id: null`; the device ones have `credential:"device"`, the
   right `device_id`/`device_name`/`token_prefix` (8 chars, NEVER the full
   token), correct `choice`/`session_id`/`command_preview`. Assert `approval_
   audit.jsonl` is mode `0600` and append-only (line count grows, never
   rewritten). BINDING: grep the audit file + all server logs → assert NO full
   device token (nor the shared token) appears anywhere.
5. **Re-pair flow (revocation recovery, iOS):** pair the sim app at 9123 →
   assert (bridge) it auto-upgraded to a device token (a `device_id` recorded for
   the server) and the Keychain holds the device token (NOT the shared token).
   From another client, `DELETE` that device → drive the app to make a request →
   assert it 401s, `reauthRequired` flips, `phase == .needsSetup`, `WelcomeView`
   shows the reauth banner. Re-scan a fresh QR → assert it re-pairs and
   auto-upgrades to a NEW `device_id` (different from the revoked one) and chat
   resumes. SCREENSHOT the reauth banner + the recovered session.
6. **Stock degradation (Devices section hidden):** point the app at a STOCK
   hermes-agent (or a 9123 with the device routes stubbed off) → assert (bridge)
   `capabilities.devices == .unavailable`, the Devices section does NOT render in
   Settings, and NO auto-upgrade issue call fires (the app keeps the shared
   token). Exercise the app (open a session, send a prompt) → assert ZERO behavior
   change and no error. SCREENSHOT Settings with NO Devices section. Then point at
   the patched 9123 → assert `.available`, the Devices section renders, and the
   auto-upgrade fired.
- Evidence dir: `/tmp/hermes-w3a-evidence/` (curl transcripts, bridge snapshots,
  screenshots, log + audit-file greps proving NO token leaked, `ls -l` proving
  `0600` on both new files, the migration-safety transcript FIRST). Release build
  still green. Full server suite + full iOS unit suite green.
- Report: verdict per numbered item, the LEGACY-TOKEN REGRESSION result FIRST,
  any regressions, and STOP — no prod dashboard restart, no shared-token
  disablement, no version bump, no TestFlight upload. Enforcement-flip (rejecting
  the shared token) is a SEPARATE user-coordinated batch, NOT this one.

## Open questions (resolve before/early in the relevant module; do not block the others)
- `scopes` enforcement (S1): W3a issues `["chat","approve"]` for every device and
  does NOT enforce per-scope gating (a device token grants the same access as the
  shared token). Confirm whether a near-term batch wants scope enforcement (e.g. a
  read-only device) — if so the WS/REST gate would consult `scopes` per route;
  for W3a the field is reserved + tolerated-on-absence only.
- Gated/OAuth-mode interaction (S3): W3a device tokens are peers of the LEGACY
  shared token (loopback/shared-token deployment, which is the live one), so they
  are skipped in gated mode exactly as the legacy token is (`web_server.py:
  324-325`). Confirm no near-term need to issue device tokens UNDER OAuth (that
  would bind a device to an OAuth `user_id` — the ws_tickets `user_id`/`provider`
  seam exists for it, but it is a different surface and OUT OF SCOPE for W3a).
- Live-WS-cut completeness (S1/S3): the `{device_id: set[WebSocket]}` index closes
  sockets the server can attribute to a device. Confirm whether sockets that
  authed with the shared token but "belong" to a now-revoked device (an edge case
  only if a device re-paired without rotating) need any handling — W3a treats the
  shared-token socket as un-revocable-by-device (correct: revoking a device must
  never cut the shared-token live session). Document the boundary.
- `command_preview` secret risk (S4): the preview is truncated `description`/
  `command` from `_ApprovalEntry.data`. Confirm the gateway never places a raw
  secret in the approval `command` field that the preview would capture; if it
  can, prefer `description` only and/or redact `pattern_keys`-flagged segments.
- `UIDevice.current.name` entitlement (A3): without the
  `com.apple.developer.device-information.user-assigned-device-name` entitlement
  the auto-upgrade device name is a generic "iPhone" on iOS 16+. Confirm whether
  to request that entitlement (better labels) or to let the user rename a device
  from the panel (a `PATCH /api/devices/{id}` rename endpoint — a small follow-up,
  NOT in W3a scope as written).
```
