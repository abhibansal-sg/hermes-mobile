# UX-1 P0 Contract — Delete-Flow Correctness + Voice Hold/Stop State Machine (ABH-73, ABH-74)

Fix wave UX-1, priority P0. Two unrelated user-facing breakages, each with
user-approved riders, split across THREE strictly-disjoint modules (one server,
two iOS). Builds on the WORKING hermes-mobile iOS app (`apps/ios/HermesMobile`
is hermes-mobile-ONLY — origin/main has none of it, so there is NO upstream
baseline to reconcile) and the LIVE JSON-RPC gateway in `tui_gateway/server.py`
(stdio AND WebSocket `/api/ws`; events are `{method:"event", params:{type,
session_id, payload}}` notifications) plus the REST surface in
`hermes_cli/web_server.py` (token-gated by the global `/api/` middleware).

Both bugs are root-caused at file:line (current at build 11 / commit
059a1b329). This contract PINS the fix paths and the file-ownership map; the
three modules code against THIS document, not each other.

## BINDING constraints (/careful — the server is LIVE)

- `ai.hermes.dashboard` on 127.0.0.1:9119 is the user's LIVE shared backend
  (desktop + phone connected). NEVER restart, stop, or reload it. NEVER send it
  test traffic that creates, evicts, deletes, or interrupts sessions. The
  running gateway serves the LIVE phone session from this tree's python at the
  PROCESS level — editing files on disk is safe (it takes effect only on
  restart, which you must NOT do).
- All live testing runs against YOUR OWN dashboard instance on port 9123+
  (pattern: `HERMES_DASHBOARD_SESSION_TOKEN=<own> HERMES_GATEWAY_BROADCAST=1
  venv/bin/hermes dashboard --no-open --tui --host 127.0.0.1 --port 9123` from
  the repo checkout; leave HERMES_PUSH_ENABLED unset). Kill it when done.
- Production rollout (restarting the real dashboard so new SERVER code loads) is
  NOT yours — the iOS fixes ship in the app binary; the server fix only takes
  effect on a dashboard restart the main thread coordinates. Report completion.
- Branch `hermes-mobile` only. NEVER push to any remote. No build artifacts in
  commits. git identity/commits/the integration merge are the integrator's —
  builders do NO git writes in the MAIN tree.
- Swift 6 strict concurrency, `@Observable` stores, iOS 17 base. Availability-
  gate any newer API and VERIFY signatures against the installed
  iPhoneSimulator 26.5 SDK swiftinterface BEFORE coding (house standard).
- XcodeGen: any target/Info.plist/new-file membership change goes in
  `project.yml` + `xcodegen generate` in `apps/ios`. Do NOT bump
  CURRENT_PROJECT_VERSION / MARKETING_VERSION — version bumps happen at
  TestFlight ship time only, and TestFlight upload is NOT yours.
- OUT OF SCOPE (ships later, do NOT build here): the destructive-confirmation
  dialog for delete/archive ships with the drawer pass (ABH-80). The UX-1 P0
  delete fix = delete WORKS + failures are VISIBLE + the interrupt rider. Do
  NOT add a confirmation alert; do NOT touch ABH-80's seams.

## Bug A — ABH-73: session delete fails silently

### Root cause (verified)
1. **Server refuses live sessions.** `session.delete` (`server.py:3968`) snapshots
   `_sessions`, builds `active = {s["session_key"] for s in snapshot}`
   (`server.py:3997`), and returns `_err(rid, 4023, "cannot delete an active
   session")` if `target in active` (`server.py:3998-3999`). EVERY session the
   app opens is registered live via `session.resume` → `_init_session`
   (`server.py:3059`, which puts the row in `_sessions` keyed by runtime `sid`
   with `session_key` = the stored id). iOS NEVER sends `session.close` —
   `closeActive()` is local-only (`SessionStore.swift:724`, calls `clearActive`
   `SessionStore.swift:1007` with no RPC). So any session the user has touched
   in this app session is live ⇒ delete reliably hits 4023.
2. **iOS swallows the failure.** `SessionStore.delete` (`SessionStore.swift:704`)
   catches the throw and writes `lastError` (`:718`) but the row is removed ONLY
   on the success path (`:711`), and NOTHING observes `lastError` in the delete
   UI — DrawerView's delete button (`DrawerView.swift:634`) just
   `Task { await sessions.delete(summary) }` and never reads back. Net effect:
   user taps Delete, nothing happens, no error.
3. **REST fallback is unsafe.** `DELETE /api/sessions/{id}`
   (`web_server.py:5968`) calls `db.delete_session` directly with NO live-guard —
   it would delete the on-disk rows out from under the live agent, corrupting
   message ordering / tripping FK constraints (exactly what the 4023 guard
   exists to prevent). It is NOT the fix path.

### CHOSEN FIX (belt-and-braces, decisive)

**Primary path = RPC `session.delete` with server-side auto-eviction + an iOS
`session.close` before delete for sessions the app holds open. Plus a mandatory
client error surface. The REST endpoint is NOT used for delete and is hardened
to refuse live sessions so it cannot corrupt state if some other client calls
it.**

#### S — Server: auto-evict a live session before deleting (`session.delete`, `server.py:3968`)
Replace the unconditional `4023` refusal with bounded auto-eviction:
- After computing the live snapshot, locate the live session whose
  `session_key == target` via the EXISTING `_find_live_session_by_key(target)`
  (`server.py:3871`) — note `session.delete` keys on the STORED id (`session_key`),
  not the runtime `sid`, so resolve through the key, not `_sessions.get`.
- **Eviction semantics vs in-flight turns (PINNED):**
  - If the live session is NOT running (`session.get("running")` is falsy,
    `server.py:423`/`2272` precedent): EVICT it via the EXISTING teardown path —
    interrupt-free is fine because no turn is in flight. Reuse the
    `session.close` body: under `_session_resume_lock` then `_sessions_lock`,
    `_sessions.pop(sid, None)` then `_teardown_session(session)` (mirror
    `server.py:4356-4361`). THEN proceed to `db.delete_session`.
  - If the live session IS running (`session.get("running")` truthy): the agent
    is mid-turn. DECISION — delete must NOT silently abandon a spending runtime.
    INTERRUPT first, then evict, then delete: call
    `session["agent"].interrupt()` if present (mirror `session.interrupt`,
    `server.py:4432-4433`), `_clear_pending(sid)` and
    `resolve_gateway_approval(session_key, "deny", resolve_all=True)` (mirror
    `server.py:4442-4446`) to release any pending prompt/approval, THEN tear
    down and delete. This guarantees the orphaned runtime stops spending tokens
    the instant the session is destroyed.
  - The eviction is SCOPED to the single `target` session only — never touch
    other rows in `_sessions` (the lock-snapshot + single-key resolve enforces
    this).
- Error codes preserved/extended: `4006` missing `session_id`; `4007` "session
  not found" when `db.delete_session` returns falsy AND no live row existed;
  `5036` db-unavailable / enumerate-failure (keep the fail-CLOSED behavior on a
  snapshot exception — refuse rather than delete blind). The `4023` code is
  RETIRED from the success path but its STRING is preserved as a fallback iff
  eviction itself fails (e.g. teardown raises) — return `4023` "could not evict
  active session" rather than deleting a half-torn-down session.
- Return `_ok(rid, {"deleted": target, "evicted": <bool>})` — add the `evicted`
  flag so the client/integration gate can assert the live-eviction path fired.
- Concurrency: the existing `list(_sessions.values())` snapshot under
  `_sessions_lock` stays (it guards against "dictionary changed size during
  iteration"). The evict + delete sequence runs AFTER releasing the snapshot
  lock, re-acquiring `_session_resume_lock`/`_sessions_lock` only around the
  pop+teardown, exactly as `session.close` does — do NOT hold the snapshot lock
  across teardown (teardown can block on agent/worker close).
- REST hardening (`web_server.py:5968`): the `DELETE /api/sessions/{id}`
  endpoint MUST gain the SAME live-guard the RPC used to have — if `session_id`
  resolves to a live `_sessions` row (by `session_key`), return `409`
  `{"detail":"session is active — close it first"}` rather than deleting on-disk
  rows under a live agent. (The iOS app does NOT use this endpoint for delete;
  this is purely defense-in-depth so a stray REST caller cannot corrupt state.
  The endpoint does NOT auto-evict — eviction lives only in the RPC, which owns
  the live `_sessions` lifecycle.)

#### A — iOS: send `session.close` before delete, then surface failures

**`session.close` RPC wiring (`HermesGatewayClient.swift` — NEW call site).**
The RPC `session.close` ALREADY EXISTS server-side (`server.py:4349`, params
`{session_id}` = RUNTIME sid, returns `{"closed": bool}`). It is NOT yet called
from iOS (zero grep hits). No new client method is required — it is invoked via
the existing generic `client.requestRaw("session.close", params: .object([
"session_id": .string(runtimeId)]))` (`HermesGatewayClient.swift:175`). If a
typed convenience wrapper is desired, add it to `HermesGatewayClient.swift`
(A-owned).

**`SessionStore.delete` rewrite (`SessionStore.swift:704`):**
1. If the session being deleted is the one this app holds open
   (`summary.id == activeStoredId`), and there is a known runtime id
   (`activeRuntimeId`), FIRST interrupt the in-flight turn (RIDER, below), THEN
   send `session.close` for that runtime id, THEN clear the active pointers
   locally. `session.close` is best-effort: `{"closed": false}` (already gone)
   is success; a transport error is logged but does NOT block the delete attempt
   (the server now auto-evicts regardless).
2. Send `session.delete` (params `{session_id: summary.id}` = STORED id) via
   `requestRaw`. On success: remove the row, drop the pin, `clearActive()` if it
   was active. On failure: do NOT remove the row; populate the error surface
   (below) so the user SEES it.
3. Belt-and-braces resilience: because the server now auto-evicts, the
   client-side `session.close` is an optimization (it makes the eviction
   explicit and immediate for the app's own session), NOT a correctness
   dependency — a delete of a session the app never opened (so the app holds no
   runtime id for it) goes straight to `session.delete` and the server evicts if
   some OTHER client had it live.

**RIDER (user-approved) — interrupt-on-delete for an actively-streaming session.**
Deleting/archiving the actively-streaming session must NOT leave an orphaned
runtime spending tokens. BEFORE `session.close`/`clearActive` for the active
session, call the EXISTING `ChatStore.interrupt()` (`ChatStore.swift:1589`,
which routes `session.interrupt` to `interruptTarget = mirroringRuntimeId ??
activeSessionId`, `ChatStore.swift:1604` — the stream's OWN runtime, R1 #2).
SessionStore reaches ChatStore through the SAME app glue it already uses (the
two stores are co-injected via `AppEnvironment`); the seam is a single
`await chatStore.interrupt()` call before clearing active. ChatStore is touched
by module A ONLY for this interrupt seam — no other ChatStore edits in UX-1 P0.
(The server-side interrupt-before-evict in S is the second belt: even if the
client interrupt is skipped/races, the server stops the runtime on delete.)

**MANDATORY client error surface (PINNED observable seam):**
- `SessionStore` exposes failures via a NEW dedicated published property, NOT
  the catch-all `lastError` (which is unobserved noise here). Add:
  ```swift
  /// Set when a session mutation (delete/archive/rename) fails, for the drawer
  /// to surface as a transient toast/alert. nil when there is nothing to show.
  var sessionActionError: SessionActionError?
  ```
  with a small value type owned by SessionStore:
  ```swift
  struct SessionActionError: Identifiable, Equatable {
      let id = UUID()
      let action: String      // "Delete", "Archive", "Rename"
      let message: String     // human-readable (GatewayError.errorDescription)
  }
  ```
  In the `catch` of `delete` (and, for consistency, archive/rename), set
  `sessionActionError = SessionActionError(action: "Delete", message: <msg>)`
  where `<msg>` is `(error as? LocalizedError)?.errorDescription ??
  error.localizedDescription`. For a `GatewayError.rpc(code:message:)`
  (`HermesGatewayClient.swift:284`) prefer the server message. KEEP writing
  `lastError` too (other call sites read it), but the toast binds to
  `sessionActionError`. In DEBUG, mark `sessionActionError` `@Snapshotable`
  (mirror `SessionStore.swift:22/34`) so the integration gate can assert a
  failure surfaced without needing the visible toast.
- **DrawerView render (PINNED):** DrawerView already owns the `sessions` store
  via `@Environment(SessionStore.self)` (`DrawerView.swift:61`) and already uses
  the system-alert idiom (the Rename alert, `DrawerView.swift:122-139`). Render
  the failure as a system `.alert` bound to `sessionActionError` (a value-
  presenting alert, mirroring the rename alert's `presenting:` form), titled
  `"<action> Failed"` with the message and a single "OK" dismiss that sets
  `sessionActionError = nil`. Use `.alert(item:)`-style binding off the
  `Identifiable` value. (Toast vs alert: an ALERT is chosen over a custom toast
  — it is a system primitive, matches the UI-I FULL-NATIVE principle and the
  existing rename-alert idiom, requires no new toast infrastructure, and
  guarantees the failure is unmissable. Do NOT build a custom toast component.)
- On SUCCESS, `sessionActionError` stays nil (delete is silent-success, correct
  for a list mutation; the row simply disappears).

## Bug B — ABH-74: hold-to-talk wedge (voice blocker)

### Root cause (verified)
1. **Gesture host destroyed mid-press.** Starting a hold flips `isCapturing`
   (`ComposerView.swift:80`, derived from `recorder.state`), which swaps the
   composer card body from `composerField`+`actionRow` to `RecordingStrip`
   (`ComposerView.swift:298-309`). `micAction` (`ComposerView.swift:557`) is the
   host of the `holdToTalkGesture` (`:566`); when `actionRow` leaves the view
   tree the in-flight `LongPress→Drag` recognizer is destroyed. If SwiftUI then
   drops `.onEnded` (`ComposerView.swift:743`), `endHold()` (`:762`) never fires:
   the recorder stays `.recording`, the meter freezes, and — because
   `holdContent` (`ComposerView.swift:917-937`) has NO stop/cancel button — there
   is NO way to end the capture. Hard wedge.
2. **Gesture collision.** `micAction` carries BOTH `.onTapGesture { tapMic() }`
   (`:567`) and the sequenced `.gesture(holdToTalkGesture)` (`:566`) on the same
   view — the simultaneous tap + long-press-sequence recognizers race.
3. **No interruption observer (RIDER).** A call/Siri mid-record fires
   `AVAudioSession.interruptionNotification`, which NOTHING observes anywhere
   (zero grep hits) — the recorder is left stuck `.recording` with a frozen
   meter (`VoiceRecorder.swift`).
4. **Mic live while disconnected (RIDER).** `tapMic()` (`:679`) and the hold
   gesture are NOT gated on `isConnected` (`ComposerView.swift:27`) — the user
   can record while disconnected and the resulting transcript silently vanishes
   (transcription needs the gateway).
5. **Shared 15s timeout (RIDER).** Transcription goes through
   `RestClient.transcribe` → `audioPost` → `perform` (`RestClient+Audio.swift:79-84`),
   which uses the shared `RestClient.timeout = 15` (`RestClient.swift:56,186`).
   Long dictations exceed 15s of upload+STT and fail.

### CHOSEN FIX — target record/stop/cancel state machine (PINNED)

**State machine (authoritative).** Keep `VoiceRecorder.State` =
`{idle, recording(elapsed), transcribing}` (`VoiceRecorder.swift:17-23`) and
the existing `start()` / `stopAndTranscribe(rest:)` / `cancel()` lifecycle
(including the R1 #92 `generation` invalidation). The bug is in the COMPOSER's
gesture hosting and the missing controls/observers/gates, NOT the recorder's
core lifecycle. Transitions:
- `idle → recording`: via `tapMic()` (tap-to-record) OR `beginHoldIfNeeded()`
  (hold), both gated on `isConnected` (RIDER 4) and mic permission.
- `recording → transcribing → idle`: via STOP (tap "finish", hold "release") →
  `stopAndTranscribe`. Result text is appended to the composer on success.
- `recording → idle`: via CANCEL (tap "X", hold "slide-away release", watchdog
  expiry, interruption) → `recorder.cancel()`, no transcript.
- `transcribing → idle`: on transcript return / failure / cancel
  (generation-guarded).

**B1 — Gesture re-hosting (the core fix).** The hold gesture MUST live on a view
that does NOT leave the tree when `isCapturing` flips. PINNED owner: hoist the
hold gesture (and the tap) onto the `composerCard` container
(`ComposerView.swift:296`), which renders in BOTH the idle and capturing states
(it is the always-present VStack whose CONTENTS swap, not the card itself), OR
onto a dedicated stable always-mounted `micGestureHost` ZStack overlay that
persists across the `isCapturing` swap. The recognizer must survive the
field↔strip transition so `.onEnded` always fires. The `micAction` glyph
remains the VISIBLE affordance in the idle state but is no longer the gesture
HOST. Resolve the tap/long-press collision (root cause 2): use a single
`.gesture` carrying an `ExclusiveGesture`/sequenced recognizer (tap vs
long-press→drag) rather than `.onTapGesture` + `.gesture` on the same view — one
recognizer tree, no simultaneous-race.

**B2 — Hold-strip stop/cancel controls (no more dead-end).** `holdContent`
(`ComposerView.swift:917-937`) MUST gain explicit STOP and CANCEL controls so a
dropped-`.onEnded` press is always escapable. REUSE `RecordingControls`
(`RecordingControls.swift:16`) — it already renders the cancel(X)+stop(checkmark)
cluster with stable a11y labels ("Cancel recording" / "Finish and transcribe")
and is parameterized by `onCancel`/`onStop`/`isTranscribing`. Wire `onCancel:
{ recorder.cancel() }` and `onStop: stopAndTranscribe` (same closures the tap
strip uses, `ComposerView.swift:303-304`). The hold-mode strip keeps its
"release to transcribe / cancel" hint AND gains the always-tappable controls —
the gesture is the fast path, the buttons are the guaranteed escape. Do NOT
fork a second control component; `RecordingControls` is the single source.

**B3 — Watchdog (PINNED semantics).** Add a recording watchdog in
`VoiceRecorder` so a wedged `.recording` can never persist indefinitely:
- TRIGGER: armed on the `idle → recording` transition (in `start()`, alongside
  the existing `meterTask`).
- DURATION: a MAX recording cap of **120 seconds** (matches a generous mobile
  dictation ceiling and the server's own per-prompt windows). On expiry the
  recorder auto-stops: if a `rest` client is reachable it transitions to
  `stopAndTranscribe` (salvage the audio); if not, `cancel()`. Implemented as a
  cancelable `Task` mirroring `meterTask` (`VoiceRecorder.swift:281-291`),
  invalidated by `cancel()`/`stopAndTranscribe`/the next `start()` via the
  existing `generation` bump (`VoiceRecorder.swift:188`).
- RECOVERY UI: when the watchdog fires, set `recorder.lastError` to a
  human-readable note ("Recording stopped at the 2-minute limit.") so the strip/
  composer can show it; the strip returns to idle automatically (state → idle).
  The watchdog is the LAST-RESORT net behind B1/B2 — with re-hosting + buttons a
  user never needs it, but it guarantees no permanently-frozen meter ships.

**B4 — Interruption observer (RIDER 3, PINNED behavior).** `VoiceRecorder`
observes `AVAudioSession.interruptionNotification`:
- On `.began` while `.recording`: END the capture. DECISION —
  **preserve-and-transcribe** the audio captured so far IF a `rest` client is
  available at the recorder (salvage the user's words: a phone call mid-dictation
  should not lose what they already said), ELSE `cancel()`. The recorder already
  closes the file and deactivates the session cleanly in `stopAndTranscribe`, so
  the preserve path reuses it. (Rationale for preserve-not-discard: dictations
  are effortful; the AAC file up to the interruption is valid and transcribable.
  If salvage is infeasible because no `rest` handle is held by the recorder,
  fall back to `cancel()` — never leave it stuck `.recording`.)
- On `.ended`: do NOT auto-resume (recording is single-shot; the user re-taps).
- The observer is added in `start()` and removed in the teardown paths
  (`cancel`/`stopAndTranscribe` defer), `@MainActor`-isolated like the rest of
  the class. Must be robust to the notification arriving on a background queue
  (hop to the main actor).

**B5 — Disconnected gate (RIDER 4, PINNED).** Gate BOTH entry points on
`isConnected` (`ComposerView.swift:27`): `tapMic()` (`:679`) returns early /
the mic affordance is `.disabled(!isConnected)` and dimmed (mirror the attach
button's `isConnected ? theme.midground : theme.mutedFg` + `.disabled` idiom at
`ComposerView.swift:412-415`), and `beginHoldIfNeeded()` (`:750`) no-ops when
`!isConnected`. A disconnected long-press gives no haptic and starts no capture.
(The mic stays VISIBLE for affordance discoverability but is inert offline.)

**B6 — Transcription timeout (RIDER 5, PINNED value + location).** Give
transcription a longer, dedicated timeout instead of the shared 15s. CONFIGURE
in `RestClient+Audio.swift`: `audioPost` (`RestClient+Audio.swift:79`) builds
its request and MUST set a per-request `timeoutInterval` of **60 seconds**
(4× the shared default; covers a 2-minute-capped recording's base64 upload + STT
round-trip with margin). Since `makeRequest` (`RestClient.swift:170`) bakes in
`Self.timeout`, the cleanest seam is to mutate the returned request's
`request.timeoutInterval = 60` inside `audioPost` (RestClient+Audio is B-owned),
OR add a `makeRequest(path:method:timeout:)` overload on RestClient that
`audioPost` calls. PINNED value: 60s. Define the constant in
`RestClient+Audio.swift` (`private static let transcribeTimeout: TimeInterval =
60`) so it is co-located with the audio endpoints and does not perturb the
shared 15s used everywhere else. (No DefaultsKeys entry — the timeout is a fixed
engineering constant, not a user preference.)

## File-ownership map (THREE modules, strictly disjoint file sets)

Run CONCURRENTLY. No file appears in two modules. Conflicts resolved below.

### Module S (server, Python) — `tui_gateway/server.py` + `hermes_cli/web_server.py` + server tests
Owns the delete/eviction logic. Files:
- `tui_gateway/server.py` — `session.delete` auto-eviction (`:3968`), reusing
  `_find_live_session_by_key` / `_teardown_session` / the `session.close`
  pop+teardown idiom / the `session.interrupt` interrupt+clear-pending idiom.
- `hermes_cli/web_server.py` — `DELETE /api/sessions/{id}` live-guard `409`
  (`:5968`).
- Server test module (the existing pytest harness for gateway RPCs — locate the
  `session.delete`/`session.close` tests and extend that file; if none exists,
  add one alongside the gateway test suite). NOTE: per the dual-executor rule
  (CODEX-LANE.md) ALL backend Python is dispatched to Codex via `~/bin/codexw
  exec` — module S is authored in the Codex lane; Claude reviews/tests/commits.
- Commit style (separable for a possible upstream PR): `hermes-mobile UX1-S: ...`.

### Module A (iOS delete) — `SessionStore.swift`, `DrawerView.swift`, `ChatStore.swift` (interrupt seam ONLY), `HermesGatewayClient.swift` (if a session.close wrapper is added) + their tests
Owns the iOS delete flow + error surface + interrupt rider. Files:
- `Stores/SessionStore.swift` — rewrite `delete` (`:704`): interrupt → close →
  delete sequence; add `sessionActionError` + `SessionActionError` type; set it
  in the delete (and archive/rename) catch blocks; `@Snapshotable` in DEBUG.
- `Views/Drawer/DrawerView.swift` — add the `.alert` bound to
  `sessionActionError` (mirror the rename alert `:122`); the delete button
  (`:634`) is unchanged in wiring (it already calls `sessions.delete`).
- `Stores/ChatStore.swift` — INTERRUPT SEAM ONLY: A calls the EXISTING
  `ChatStore.interrupt()` (`:1589`); it does NOT modify ChatStore. (Listed for
  ownership clarity — A's only ChatStore interaction is the call site in
  SessionStore + AppEnvironment glue, no edit to ChatStore.swift is required. If
  a tiny helper is genuinely needed, A owns that one edit; B never touches
  ChatStore.)
- `Networking/HermesGatewayClient.swift` — ONLY if a typed `session.close`
  wrapper is added (optional; the generic `requestRaw` suffices). A-owned if so.
- Tests: `HermesMobileTests/` — a delete-flow test file (SessionStore delete
  success/failure → `sessionActionError` set; close-before-delete sequence;
  interrupt-on-active-delete fires). The DrawerView alert is covered by
  `ChatFlowUITests` (see test plan).
- Commit style: `hermes-mobile UX1-A: ...`.

### Module B (iOS voice) — `ComposerView.swift`, `VoiceRecorder.swift`, `RecordingControls.swift`, `RestClient+Audio.swift` + their tests
Owns the voice state machine + gesture re-host + controls + observers + gates +
timeout. Files:
- `Views/Chat/ComposerView.swift` — gesture re-hosting (B1), hold-strip controls
  via `RecordingControls` (B2), disconnected gate on `tapMic`/`beginHoldIfNeeded`
  + mic affordance (B5). (ComposerView is the gesture/host file; B5's
  `isConnected` is already a ComposerView input at `:27`.)
- `Networking/Audio/VoiceRecorder.swift` — watchdog (B3), interruption observer
  (B4).
- `Views/Chat/RecordingControls.swift` — REUSED as-is for the hold strip; B may
  extend it ONLY if the hold presentation needs a variant flag (prefer reuse
  with the existing `compact`/labels intact so a11y ids are preserved).
- `Networking/Audio/RestClient+Audio.swift` — 60s transcribe timeout (B6).
- Tests: `HermesMobileTests/` — VoiceRecorder watchdog-fires test, interruption-
  observer end-and-salvage test, `normalizedPower` curve (existing), timeout-
  constant assertion; ComposerView gesture/gate behavior where unit-testable.
- Commit style: `hermes-mobile UX1-B: ...`.

### Conflict resolution (files that could be claimed by two modules)
- **`ChatStore.swift`** — claimed by A (interrupt seam) but NOT edited: A
  CONSUMES the existing `interrupt()` interface; B never references ChatStore.
  No two-writer conflict. Interface A consumes: `func interrupt() async`
  (`ChatStore.swift:1589`), routing to `interruptTarget` (`:1604`). Frozen — A
  must not change ChatStore's interrupt signature or semantics.
- **`RestClient.swift`** — NOT owned by any UX-1 P0 module. B6's timeout is
  applied in `RestClient+Audio.swift` (B-owned) via `request.timeoutInterval`
  mutation, OR via a NEW `makeRequest(path:method:timeout:)` overload. DECISION:
  if the overload route is taken, that one-method addition to `RestClient.swift`
  is B-owned and is the ONLY edit to that file; prefer the in-extension
  `timeoutInterval` mutation to avoid touching `RestClient.swift` at all.
- **`HermesGatewayClient.swift`** — A-owned (only if the optional `session.close`
  wrapper is added). B never touches networking. The `session.close` RPC is
  invoked via the existing `requestRaw` (`:175`) — frozen interface A consumes.
- **`RecordingControls.swift`** — B-owned. A never touches voice UI.
- Server (S) shares NO files with A/B (Python vs Swift). All three run
  concurrently with zero shared lines.

## Test plan

### Module S obligations (server, pytest)
- `session.delete` of a NON-running live session → asserts the row is evicted
  from `_sessions` AND `db.delete_session` ran AND `{"deleted":..., "evicted":
  true}`.
- `session.delete` of a RUNNING live session → asserts `agent.interrupt()` was
  called (mock/spy), pending prompts/approvals released, then evicted + deleted.
- `session.delete` of a NON-live (stored-only) session → straight delete,
  `"evicted": false`.
- `session.delete` missing `session_id` → `4006`; not-found → `4007`; db
  unavailable / enumerate failure → `5036` (fail-closed, no delete).
- Eviction-failure fallback → `4023` (teardown raises ⇒ refuse, do not delete a
  half-torn session).
- `DELETE /api/sessions/{id}` on a LIVE session → `409` (live-guard);
  on a stored-only session → `200 {"ok": true}` (unchanged path).
- Full server suite stays green.

### Module A obligations (iOS unit, XCTest)
- `SessionStore.delete` success → row removed, pins dropped, `clearActive` iff
  active, `sessionActionError == nil`.
- `SessionStore.delete` failure (mock client throws `GatewayError.rpc`) → row
  NOT removed, `sessionActionError` set with the server message and `action ==
  "Delete"`.
- Active-session delete → asserts `ChatStore.interrupt()` invoked then
  `session.close` sent (RUNTIME id) then `session.delete` sent (STORED id), in
  that ORDER (spy on the mock client's recorded calls).
- archive/rename failures also populate `sessionActionError` (consistency).

### Module B obligations (iOS unit, XCTest)
- `VoiceRecorder` watchdog: drive past the 120s cap (inject a clock / short cap
  in test) → asserts auto-stop fires and state returns to idle with `lastError`
  set.
- Interruption `.began` while recording → asserts capture ENDS (preserve path
  reuses stopAndTranscribe when rest is present; cancel path otherwise) and
  state leaves `.recording`.
- `normalizedPower` curve (existing) stays green.
- Transcribe timeout constant == 60 (assert the configured `timeoutInterval` on
  the audio request, or the constant).
- Gesture/gate: where unit-testable, assert `tapMic`/`beginHoldIfNeeded` no-op
  when `!isConnected` (extract the gate predicate to a testable seam if needed).

### Integration suite invocation (PROVEN repo invocation)
Build/test the `HermesMobile` scheme (`project.yml:147`; targets `HermesMobileTests`
+ `HermesMobileUITests`, `project.yml:154-158`) on the house simulator
**iPhone 17 Pro, iOS 26.5** (the standard across CONTRACT-F2/F4B/W3A and
CHAT-THREAD-PARTS-2026-06-07: "Simulator: iPhone 17 Pro, iOS 26.5"). Invocation:

```
xcodegen generate            # only if project.yml / file membership changed
xcodebuild test \
  -project HermesMobile.xcodeproj \
  -scheme HermesMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5'
```

Live UI tests (`ChatFlowUITests`, `CrossClientSyncUITests`) self-skip unless
`TEST_RUNNER_HERMES_URL` / `TEST_RUNNER_HERMES_TOKEN` are forwarded
(`project.yml:159-171`) — point them at YOUR OWN 9123 instance, never 9119:
prefix with `TEST_RUNNER_HERMES_URL=http://127.0.0.1:9123
TEST_RUNNER_HERMES_TOKEN=<own>` to exercise the live delete/voice paths.
**`ChatFlowUITests` is KNOWN-FLAKY under load — retry-once convention:** a single
failure of a `ChatFlowUITests` case is re-run once (`-only-testing:
HermesMobileUITests/ChatFlowUITests/<case>`) before being treated as a real
regression; two consecutive failures = a real failure. The Debug build is the
test config; ALSO confirm a Release sim build compiles green (Swift 6 strict
catches `#if DEBUG`-gated `@Snapshotable` drift).

### Integration gate evidence
- Delete: on 9123, open a session in the sim (it goes live), delete it from the
  drawer long-press menu → assert the row disappears, the server log shows
  `evicted: true`, and a STREAMING-then-deleted session shows `session.interrupt`
  fired (no orphaned runtime keeps spending — check the gateway log). Force a
  delete failure (e.g. db made unavailable) → assert the `"<action> Failed"`
  alert renders (screenshot) AND `sessionActionError` is set via the
  `@Snapshotable` bridge.
- Voice: hold the mic and force the field↔strip swap → assert the gesture
  survives, `.onEnded`/the strip STOP both end the capture (no frozen meter).
  Trigger an interruption (sim: phone-call / Siri) mid-record → assert the
  capture ends and (salvage path) the partial transcript lands or (no-rest)
  cancels — never stuck `.recording`. Disconnect (kill 9123) → assert the mic is
  inert (no haptic, no capture). Record a long (>15s) dictation against a slow
  STT → assert it completes (60s timeout) where it previously failed at 15s.
- Evidence dir: `/tmp/hermes-ux1-evidence/` (screenshots, gateway log greps,
  bridge snapshots). Report: verdict per module, regressions, and STOP — no prod
  dashboard restart, no version bump, no TestFlight upload.

## Invariants the gate MUST verify

1. **No regression to R1 fixes.**
   - R1 #2 (interrupt routes to the STREAM's runtime, not local): `ChatStore.
     interrupt()` / `interruptTarget` (`ChatStore.swift:1589/1604`) unchanged;
     the delete-rider interrupt reuses it verbatim.
   - R1 #92 (transcript not inserted after cancel): the `VoiceRecorder.generation`
     invalidation (`VoiceRecorder.swift:188,222,252,265`) is preserved — the
     watchdog and interruption paths bump/respect `generation` exactly as
     `cancel()` does, so a salvaged-then-cancelled capture never inserts text.
   - R1 #18 (offline outbox front door): the disconnected-mic gate (B5) must NOT
     touch the SEND/queue path — `isQueueMode` / `canQueue` (`ComposerView.swift:
     95-96,644`) stay intact; only the MIC entry points are gated.
   - R1 #79 (stale error not shown in next session): `ChatStore.reset()`
     (`ChatStore.swift:1864`) behavior unchanged; `sessionActionError` is a
     SessionStore concern (list-level), not a transcript concern, so it does not
     leak into a new session's empty state.
2. **Release purity.** No new symbol leaks into Release: `sessionActionError`'s
   `@Snapshotable` is `#if DEBUG` gated (mirror `SessionStore.swift:21-23`); the
   debug bridge / `DebugBridgeWiring` is untouched except for the one new
   accessor; the Release build compiles green. No backend working files
   (CLAUDE.md, CODEX-LANE.md, CONTRACT-*.md) in any upstream-bound patch.
3. **A11y identifiers preserved.** All existing identifiers survive verbatim:
   `sessionRow` (`DrawerView.swift:605`), `drawerNewChat` (`:671/687`),
   `settingsAvatar` (`:280`), `drawerProfilePicker` (`:240`),
   `drawerRecentsFilter` (`:510`), `composerAttachButton`
   (`ComposerView.swift:417`), `composerModelChip` (`:483`),
   `composerBrowseFiles` (`:217`); and the `RecordingControls` a11y LABELS
   ("Cancel recording" / "Finish and transcribe", `RecordingControls.swift:42/55`)
   and the mic's "Dictate message" label/`.isButton` trait
   (`ComposerView.swift:574-576`) are preserved so the live `ChatFlowUITests`
   idle-composer / mic queries keep passing. Any NEW identifier added for the
   delete-failure alert or the hold-strip controls is ADDITIVE only.
