# F2 Contract — Notifications v2 (actionable push, Face ID gate, Live Activity remote updates, per-event prefs)

Functionality track, batch 2 (F1 closed: tool execution verified REAL on
dashboard sessions, all three probes green — see task #25). Everything here
builds on the WORKING v1 push pipeline (verified cross-continent Singapore→
Dar es Salaam): APNs sender `hermes_cli/push_notify.py`, gateway hook
`tui_gateway/server.py:_push_hook` (approval.request / clarify.request /
>30s message.complete), token registry `~/.hermes/push_tokens.json` with
per-token env routing (sandbox=dev builds, production=TestFlight),
`/api/push/register` REST. Do not regress any of it.

## BINDING constraints (/careful — the server is LIVE)

- `ai.hermes.dashboard` on 127.0.0.1:9119 is the user's LIVE shared backend
  (desktop + phone connected). NEVER restart, stop, or reload it. NEVER
  point test traffic at it that creates sessions or sends real pushes.
- All live testing runs against YOUR OWN dashboard instance on port 9123
  (pattern: `HERMES_DASHBOARD_SESSION_TOKEN=<own> HERMES_GATEWAY_BROADCAST=1
  venv/bin/hermes dashboard --no-open --tui --host 127.0.0.1 --port 9123`
  from the repo checkout; leave HERMES_PUSH_ENABLED unset so no real APNs
  traffic). Kill it when done.
- Production rollout (restarting the real dashboard so the new code loads)
  is NOT yours — report completion; the main thread coordinates the restart.
- Branch `hermes-mobile` only. NEVER push to any remote. No build artifacts
  in commits. Swift 6 strict, iOS 17 base, availability-gate newer API and
  VERIFY signatures against the iPhoneSimulator26.5 SDK swiftinterface
  before coding (house standard since the geometry fix).
- XcodeGen: any target/Info.plist change goes in project.yml + regenerate
  (`xcodegen generate` in apps/ios). Do NOT bump CURRENT_PROJECT_VERSION /
  MARKETING_VERSION — version bumps happen at TestFlight ship time only.
- UI work follows the UI-I FULL NATIVE principle: system components only
  (List, Toggle, LabeledContent); identity via tint.

## Interface (pinned — both modules code against THIS, not each other)

### Push payload (server → app)
`build_alert_payload` keeps `{aps: {...}, hermes: {...}}`. New:
- `aps.category` set per event: `HERMES_APPROVAL`, `HERMES_CLARIFY`,
  `HERMES_TURN` (new `category` param threaded through `notify()`).
- `hermes` block for approval.request gains: `session_id` (runtime sid —
  already there), `stored_session_id` (when resolvable), `destructive`
  (bool — true when the approval payload marks a destructive/dangerous
  action; default false), `approval_title` (short target string).

### REST respond endpoint (app → server) — upstream PR #6 candidate, keep separable
`POST /api/approvals/respond` in `hermes_cli/web_server.py`:
- Auth: same `_has_valid_session_token` dependency as `/api/upload`.
- Body: `{"session_id": "<runtime sid>", "choice": "approve"|"deny",
  "all": false}` (mirror of the WS `approval.respond` params).
- Impl: same process as the gateway — import `tui_gateway.server._sessions`
  to map sid → `session_key`, then `tools.approval.resolve_gateway_approval
  (session_key, choice, resolve_all=all)`.
- Responses: 200 `{"resolved": true|false}` (false = nothing pending /
  already handled — app shows "Already handled"); 404 unknown sid (runtime
  gone); 401 bad token. Never 500 on a moot approval.

### Live Activity token registration (app → server)
`POST /api/push/live-activity` (same auth):
- Body: `{"token": hex, "session_id": str, "env": "sandbox"|"production"}`.
  `DELETE` with same body unregisters. Tokens rotate — re-POST upserts by
  session_id.
- Registry: sibling file `~/.hermes/live_activity_tokens.json` (0600), keyed
  by session_id, pruned on 410/BadDeviceToken like the alert registry.

### Live Activity remote updates (server → app)
New sender in `push_notify.py`: `notify_live_activity(session_id,
content_state: dict, *, end: bool = False)`:
- Headers: `apns-push-type: liveactivity`, `apns-topic:
  ai.hermes.app.push-type.liveactivity`, priority 10.
- Payload: `{"aps": {"timestamp": <now>, "event": "update"|"end",
  "content-state": {...}, ...}}` (end carries `dismissal-date`).
- `content-state` MUST match `HermesTurnAttributes.ContentState` Codable
  field names exactly — app module: read the existing struct in
  HermesWidgets and DO NOT rename fields; server module: copy the field
  names from that struct (read it first).
- Gateway hook: update on tool.start (tool name), tool.complete, and
  status changes; end on message.complete / session interrupt. THROTTLE:
  ≥3s between updates per session, final/end always sent. All of it behind
  the same is_armed() no-op guard as v1.

### Per-event prefs (app ↔ server)
- `PushRegisterBody` gains `events: list[str] | None` — subset of
  `["approval", "clarify", "turn_complete"]`; None/absent = all (legacy
  entries keep working). Registry stores it per token.
- `notify()` filters recipient tokens by event kind before sending.
- App: Settings → Notifications gets three native Toggles (Approvals,
  Questions, Long turns) persisted in DefaultsKeys; any change re-POSTs
  /api/push/register with the new `events` list.

## Module F2-S (server, Python) — touches hermes_cli/ + tui_gateway/ + tools/ only
S1 respond endpoint (above). S2 category + payload enrichment in
push_notify + _push_hook. S3 LA registry + sender + gateway hook + throttle.
S4 per-event prefs in registry/notify. S5 unit tests for every piece
(extend the existing push test module; httpx/TestClient for the endpoints;
full server test suite must stay green — it was 296/296). Commit as ONE
clean server commit (separable for the upstream PR series), message style:
`hermes-mobile F2-S: ...`.

## Module F2-A (app, Swift) — touches apps/ios/ only
A1 categories: register UNNotificationCategory set in PushRegistrar —
HERMES_APPROVAL with actions `APPROVE` (options: [.authenticationRequired])
and `DENY` (options: [.destructive, .authenticationRequired]);
HERMES_CLARIFY + HERMES_TURN open-app only. BINDING: no approval action may
fire from a locked, unauthenticated device (authenticationRequired gives
this — verify against the SDK).
A2 action handling: UNUserNotificationCenterDelegate didReceive → POST
/api/approvals/respond (background URLSession, Keychain token, Host:
127.0.0.1 override — reuse RestClient if it works app-launched-in-
background, else a minimal background-safe path). `resolved:false`/404 →
local feedback notification "Already handled elsewhere". When
`hermes.destructive == true` or the action is approve-all from INSIDE the
app, gate with LAContext biometric evaluate before sending (Wave 2.2
amendment); SDK-verify what's possible in the background-action context
and document the chosen mechanics in the commit.
A3 Live Activity tokens: start HermesTurnLiveActivity with `pushType:
.token`; observe `activity.pushTokenUpdates` and POST/re-POST
/api/push/live-activity; unregister on end. Do NOT rename ContentState
fields. Optional stretch (only if clean, iOS 17.2+ gated):
pushToStartTokenUpdates.
A4 Settings per-event toggles (native, re-register on change).
A5 unit tests (payload decode, category mapping, prefs round-trip);
`xcodegen generate` if project.yml changed; Debug + Release sim builds
green; full unit test suite green. Commit as ONE clean app commit:
`hermes-mobile F2-A: ...`.

## Integration gate (separate agent, runs after both land)
- Own dashboard on 9123 (no push armed), sim iPhone 17 Pro:
  1. Stage a REAL pending approval (session via WS on 9123, prompt that
     triggers an approval-gated command with yolo OFF on that instance).
  2. `xcrun simctl push` a synthetic approval payload carrying that real
     session_id + category → assert action buttons render (long-press) →
     tap Approve → assert REST respond hit 9123 and the gateway resolved
     (turn proceeds). Use the UI-G debug bridge (DEBUG builds expose
     StateServer on loopback — InboxStore.pendingCount accessor) to assert
     inbox state transitions.
  3. Replay the respond → assert "Already handled" path.
  4. LA: verify token registration round-trip against 9123; sim LA push
     update via simctl push if the sim supports liveactivity push type
     (check; if unsupported, evidence = unit tests + a recorded real
     pushTokenUpdates token on sim/device and the sender's dry-run JSON).
  5. Per-event prefs: toggle Approvals off in Settings → assert re-register
     body excludes "approval" (9123 access log / registry file).
- Evidence dir: /tmp/hermes-f2-evidence/ (screenshots, logs, registry
  snapshots). Release build still green. Server suite + iOS suite green.
- Report: verdict per numbered item, regressions, and STOP — no prod
  dashboard restart, no version bump, no TestFlight upload.
