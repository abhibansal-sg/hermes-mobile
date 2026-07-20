# QA-2 ROOT CAUSES — Device-QA Round 2 (build 115, relay mode)

**Diagnostician pass · 2026-07-21 · branch `qa2/base` @ 1fcffe3d5 (QA-1 landing on main) + spec/ledger commits.**
Every cause below is code-evidenced (file:line on the qa2/base tree == origin/main 1fcffe3d5).
Spec hypotheses are marked CONFIRMED / REFUTED / REFINED per bug. This document steers the fix lanes.
Repo paths relative to repo root; iOS = `apps/ios/HermesMobile/`. Forensics: `docs/qa2-image-ledger.md`.

QA-1 context: `docs/qa1-root-causes.md`. QA-1's 15 B-fixes ARE on this tree; several R-items are
incomplete-successors of B-items (called out per bug).

---

## R1 — Notifications broken end-to-end (P0)

**Spec hypothesis REFINED.** Per-token APNs env routing ALREADY EXISTS on main (QA-1 B14 landed):
`register_token(env=…)` (`plugins/hermes-mobile/push_engine.py:578-629`), `recipients_for_event()`
grouped by env (`push_engine.py:683-706`), `notify()` routes per env via `env_hosts =
{"sandbox": _APNS_HOST_SANDBOX, "production": _APNS_HOST_PROD}` (`push_engine.py:1035-1042`).
The relay's own registry + `push.register`/`push.unregister` upstream methods exist
(`relay/hermes_relay/downstream.py:635-667`, `types.py:132`), and iOS registers OVER THE RELAY
in relay mode (`Support/PushRegistrar.swift:419-439` → `RelayClient.registerPushToken`,
`Networking/Relay/RelayClient.swift:328-341`). **Three distinct breaks remain, and the first is the killer:**

### (a) iOS mis-stamps the APNs environment on EVERY real dev-signed build
`PushTokenPoster.apnsEnvironment` (`PushRegistrar.swift:547-573`) scans `embedded.mobileprovision`
via `String(data: data, encoding: .ascii)` (`563-565`). Swift `.ascii` decoding is STRICT — any
byte ≥ 0x80 → `nil` — and every signed profile contains a binary CMS/PKCS#7 signature, so the
decode returns `nil` → the function returns `"production"` (`565`) for dev-signed builds whose
tokens are SANDBOX. **Empirically proven** (scratch Swift run, evidence
`evidence/daily-driver-qa2/r1-ascii-strict.txt`): `String(data: <ascii+high bytes>, encoding:.ascii)
== nil`. The simulator never catches this: `#if targetEnvironment(simulator) return "sandbox"`
(`558-559`) short-circuits before the profile read — every sim/E2E/conformance run sees the
correct env. Sandbox token + `env:"production"` → routed to `api.push.apple.com` → APNs returns
**400 BadDeviceToken** — exactly the relay.log signature.

**Live evidence (read-only):**
- `~/.hermes/push_tokens.json`: **all 5 entries `env: "production"`**, zero sandbox entries (token
  values redacted; last-6 only in evidence copy).
- `~/Library/Logs/Hermes/relay.log`: every POST goes to `https://api.push.apple.com` (production
  host) — ZERO posts to `api.sandbox.push.apple.com`; tokens …984a0b/…562bcb/…bd6b4a → `400
  {"reason":"BadDeviceToken"}` at 02:27:46, 02:35:29–30, 02:36:52–53 (same three dead tokens every
  notify window); …0ac44e7d/…0fce4f7f → 200 OK (genuine production tokens — other build/device;
  the phone received nothing because its sandbox token is either one of the mis-stamped 400s or
  absent from the registry entirely).

### (b) 400 BadDeviceToken is NEVER evicted
`notify()` prunes only on `status == 410` (`push_engine.py:1057-1058`); every other non-200 —
including 400 BadDeviceToken — is merely logged (`1059-1062`). Same 410-only pruning in the
manifest-invalidation path (`1107-1108`) and the Live-Activity push path (`1307-1309`). Dead
tokens therefore persist forever and are re-hammered on every notify attempt (the relay.log
repeats above).

### (c) No device-identity dedup — tokens accumulate
`register_token` dedups by TOKEN STRING ONLY (`push_engine.py:606-616`); `device_id` is stored
(`611-612, 627-628`) but is never a dedup key. iOS never sends one anyway: relay params are
token/platform/env/events only (`RelayClient.swift:334-339`); the downstream handler reads
`p.get("device_id")` (`downstream.py:659`) which is always `None`. Every re-sign/reinstall/APNs
rotation APPENDS → 5 entries for one phone. Spec R1(c) "exactly ONE token per device keyed by a
stable device id" is unimplemented on both sides (a stable device id EXISTS client-side:
`DefaultsKeys.deviceId(server:)`, `PushRegistrar.swift:112`).

### Fix outline (R1)
1. **iOS env**: parse the profile properly — locate the `<?xml … </plist>` region and
   `PropertyListSerialization`-read `Entitlements.aps-environment` (`development` → sandbox,
   `production` → production); decode bytes with `.isoLatin1` (never fails) for the scan, or
   binary-search the plist bounds. Fallback when a profile EXISTS but is unreadable: `sandbox`
   (the failing-safe direction for dev builds is a 400 on the wrong host, which (b) will now
   evict — mis-stamping production is the unrecoverable case today). Belt: `scripts/ios-build.sh`
   knows the signing style — inject an `HERMES_APS_ENVIRONMENT` Info.plist value as an override
   the app reads first (spec's "build flag" option).
2. **Evict on 400 BadDeviceToken**: in all three send paths, parse the APNs reason JSON;
   `BadDeviceToken` and `Unregistered` → prune; other 400s (TopicDisallowed/BadPath) must NOT
   evict. Log the eviction (A1 wants it in evidence).
3. **Device-id dedup**: send `device_id` from both registration paths (relay params +
   gateway-direct body); in `register_token`, when `device_id` matches an existing entry with a
   DIFFERENT token, REPLACE it (one entry per device). One-shot migration: nothing needed — (2)
   evicts the dead ones, (3) converges the phone to 1 on next register.
4. Re-register on transport switch to `.relay` (verify the `enableIfAllowed()` launch-time call
   vs transport-decision race while in the lane; hardFail retries exist at
   `PushRegistrar.swift:316-321`, but a relay socket that comes up AFTER the launch registration
   attempt has no re-trigger until next launch — wire a re-register on relay-ready).

**Prove (A1):** isolated relay run with owner's real key/sandbox env; dev-signed build token
registered `env:sandbox` → POST to `api.sandbox.push.apple.com` → real push on the phone; store
converges to 1 phone entry; dead-token evictions logged.

---

## R4 — Send does not enter working mode (P0)

**Spec hypothesis REFINED (the failure is the INVERSE of the flash).**
- Send sets streaming at submit: `setStreaming(true, reason: "relay.send")` (`Stores/ChatStore.swift:2516`).
- The relay SUBMIT handler synthesizes a **completed (terminal)** `userMessage` item and fans it
  out immediately (QA-1 commit `40ad925ac`). The first frame back projects `[userMessage]` →
  `applyRelayItems` computes `nowStreaming = rebuilt.contains { $0.isStreaming }`
  (`ChatStore.swift:4528`) → **false** → `setStreaming(false, reason: "relayProjection")`
  (`4540`). This KILLS the submit-time streaming flag for the ENTIRE accepted-and-waiting window
  until the first non-terminal AGENT item arrives.
- Consequences: `shouldShowInlineTurnActivity` (`Views/Chat/ChatView.swift:232-251`) gates on
  `isStreaming` → no working row; the composer's stop button (gated on the same flag;
  `Views/Chat/ComposerView.swift:1052,1759`) disappears; no streaming assistant bubble exists
  (the projection only creates assistant segments from items with a `renderPart`,
  `Models/ChatItem.swift:195-209`). For short/fast turns the reply lands with NO affordance ever
  shown — exactly "reply just appears later".
- The sub-1s Working-pill FLASH is the window between `setStreaming(true)` at `2516` and the
  userMessage frame: `shouldShowInlineTurnActivity`'s relay pre-first-item clause
  (`ChatView.swift:243-249`) shows the bar while the last message is the user echo (not an
  assistant streaming bubble). So the pill state the spec says "must never appear on relay" is
  the pre-first-item branch itself.
- The orphaned blue rectangle (IMG_2542) is `needsStandaloneCursor` — `message.isStreaming &&
  lastTextPartID == nil` (`Views/Chat/MessageBubble.swift:538,573-577`): a `StreamingCursor` with
  no bubble text, i.e. the working signal detached from any container.

### Fix outline (R4)
1. On relay send, append an OPTIMISTIC EMPTY STREAMING assistant bubble (deterministic id,
   `isStreaming: true`, zero parts) right after the user echo — the breathing cursor renders
   ≤100 ms from send, independent of any frame.
2. Make relay `isStreaming` TURN-SCOPED: true from submit until the turn settles via
   `turn.completed`/error — `applyRelayItems` must not clear it off item terminality while the
   turn is live (pass the turn-state down from the coordinator's frame stream; terminal
   userMessage items no longer gate it).
3. DELETE `TurnActivityBar` from the relay path entirely (A2: "state deleted, not just hidden"):
   the optimistic cursor bubble IS the pre-first-item affordance; remove the relay clause of
   `shouldShowInlineTurnActivity` and the bar mount (`ChatView.swift:1173-1174`) behind transport.
   Direct path keeps the approved tail bar byte-identical.

---

## R5 — Working-section collapse missing in live turn (P0 render) · R6 — whitespace bands

**Settled turns work; the LIVE turn renders the old Wave-2 live design, not the ratified
Wave-2.5 single-line rule.** The fold machinery exists and is correct for settled turns:
`WorkingSectionModel.renderNodes` folds everything up to the LAST work part into ONE `.working`
node (`Views/Chat/WorkingSectionView.swift:125-138`), consumed in `MessageBubble.swift:560-571`;
settled = chrome-less `Worked for Nm Ns ›` row (`595-633`). But the LIVE branch
(`WorkingSectionView.swift:676-712`) deliberately renders:
1. **each reasoning run INLINE** via `ThinkingView(streaming: true)` (`677-684`) — an
   auto-OPENED accordion (`ThinkingView.swift:63`, `autoExpanded = streaming`) with its OWN
   1 s timer (`ThinkingView.swift:19,96-98,125-137`) showing the truncated label line AND the
   full body text simultaneously — that is BOTH the per-item timer (R5: "timer is per-TURN") AND
   the duplicate double-print of identical thinking text (ledger N4: IMG_2533/2536/2538/2541);
2. a SEPARATE current-tool line (`currentToolLine`, `715-745`) — the `⟳ Reading … >` row;
3. plus the standalone cursor row from `MessageBubble` — so one live turn = 3+ stacked rows
   (IMG_2532, IMG_2545: `Tasks 0/0` + `tool.generating` + `Tasks 0/0` + `review.summary` = 4 rows
   at 1 m 20 s). The ratified contract is ONE collapsed `Working… ‹global turn timer›` line with
   the current tool inline, tap to expand.

**R6 bands** are stacked reserved heights, not empty item containers (REFINED):
- `ThinkingView`'s live scroll window is a FIXED `.frame(height: 172)` regardless of content
  (`ThinkingView.swift:16,163`) — one line of thought still reserves 172 pt;
- the standalone-cursor row `.frame(maxWidth: .infinity)` (`MessageBubble.swift:573-577`);
- part VStack spacing 10 + per-row `.padding(.vertical, 6)` (`MessageBubble.swift:552-554`,
  `WorkingSectionView.swift:741,634`);
- `composerClearance` floor + the tail bar row when up (`ChatView.swift` ~254-269, 1173-1174 —
  QA-1 B12 mechanics).
These SUM to the observed 320–700 px dead bands (IMG_2533/2538/2540/2542).

**Two adjacent facts:**
- Settled RELAY turns show bare `Worked ›` with NO duration (IMG_2532): `workedLabel(seconds:
  nil)` → "Worked" (`WorkingSectionView.swift:265-270`); relay items carry no start/complete
  timestamps and `applyRelayItems` never stamps `reasoningElapsed` on `relayProjected` rows.
- Raw internal state names flash in rows (`tool.generating`, `review.summary`, IMG_2538/2545/2546,
  ledger N2): `stepSummary`/`currentWork` fall back to the raw item name before the tool resolves
  its friendly name; the green ✓ (`statusIcon(.completed)`, `WorkingSectionView.swift:756-771`)
  beside an in-progress-looking label is the same race.

### Fix outline (R5/R6)
1. Replace `liveSection` with the ratified single line: `Working… ‹turn timer› · ‹current tool
   inline›` + chevron; tap expands the bifurcation (reuse `stepList`). Kill inline
   `ThinkingView` while live (thoughts live behind the expand); the streaming caret in the
   answer bubble remains THE progress signal. Timer = per-turn from
   `chatStore.turnStartedAt` (already stamped at relay submit, `ChatStore.swift:2526`).
2. Delete the fixed 172 pt window from the live path (settled sheet keeps bounded scrolling).
3. Stamp `reasoningElapsed` on the settled relay projection (turn.completed carries the span, or
   derive from first-item→settle wall-clock in the store) so settled rows read `Worked for Ns`.
4. Humanize fallback labels: never render the raw item kind; `Working…` until a friendly summary
   exists; don't show ✓ until status is terminal (status/label consistency).
5. Pin via `tests/render_conformance` fixtures (A3): live turn = exactly one working row; no
   band taller than row+spacing (layout assertion).

---

## R7–R10 — Clarification card

The card is `Views/Chat/ClarifyBanner.swift` (171 lines), mounted by the Turn Dock resolver
(`Views/Chat/TurnDock.swift:58-88` off `chatStore.pendingClarification`).

- **R7 (hand-rolled chrome, C1 violation):** flat `theme.card` fill + 14 pt hand-drawn stroke
  (`ClarifyBanner.swift:72-79`); choices are `.buttonStyle(.bordered)` + `.tint(theme.midground)`
  capsule buttons visually identical to chat bubbles (`33-47`); the free-text field is
  `.textFieldStyle(.roundedBorder)` (`53`) → renders PURE BLACK on the dark card (IMG_2534/2537);
  send glyph is a plain `arrow.up.circle.fill` (`60`), no system material anywhere.
- **R10 (long text clips/overflows):** the question is `Text(…).fixedSize(horizontal: false,
  vertical: true)` (`28-29`) — the card GROWS unbounded with no ScrollView, shoving content past
  the safe area into the nav bar (IMG_2537: "New chat" printed over the question). Choices have
  NO max-width: a `.bordered` button sizes to the text's ideal width and `ChoiceFlowLayout`
  (`32-48`) places it unconstrained → ≥100-char options run off-screen HARD-CLIPPED with no
  wrap/ellipsis/scroll (IMG_2539 — unambiguous R10 proof).
- **R9 (keyboard):** NOTHING resigns first responder when a clarify appears — the only
  app-wide resign fires on drawer OPEN (`Views/Shell/RootView.swift:1501-1506`); the composer's
  `@FocusState` persists → keyboard + card + composer stack (IMG_2534/2537). Dismissal is
  timing-dependent (IMG_2539 had no keyboard) because it only happens incidentally.
- **R8 (post-answer unclean):** the card clears correctly on answer (`ChatStore.swift:3203`
  `respondClarification` → `pendingClarification = nil`; direct-path turn-complete clear at
  `1307`; relay bridge sets with `resolvedRelayGateIDs` dedup at `1474-1479,1489-1503`). The
  leftover chrome/gaps are R5/R6's live fold (172 pt window + tool rows) persisting while the
  turn continues post-answer. **REFINED (ledger N3):** the "card vanished before any answer"
  reading is likely a MISSING ANSWER BUBBLE, not premature dismissal: a clarify answer (choice
  tap or free text) calls `respondClarification` directly — it synthesizes NO local user echo
  and the relay emits NO `userMessage` item for clarify answers (the relay SUBMIT synthesis of
  QA-1 covers prompts only). The card collapses on a real answer, but the user's answer never
  appears in the transcript — verify in sim; if confirmed, fix = local echo (or relay-synthesized
  userMessage) for clarify/approval answers, same mechanism as the Family-1 prompt echo.

### Fix outline (R7–R10)
Rebuild `ClarifyBanner` on native components per C1: system-material card (`.regularMaterial` /
Liquid Glass), choices as native list rows or `.buttonStyle(.borderedProminent)` capsules with
`fixedSize(horizontal: false, vertical: true)` + `.frame(maxWidth: .infinity)` inside a
`ScrollView` for long text; question in a scrollable header bounded below the nav bar;
SF Symbol send. On appear: resign composer focus (R9); "Type answer" tap restores it. Answered
card → compact settled row folded into the turn's working section (R5 contract). Echo the answer
as a user row (N3).

---

## R11 — Turn control broken during live run (P0)

**Spec hypothesis CONFIRMED exactly: the control RPCs route via the gateway-DIRECT client even
in relay mode, where that socket is idle.**
- **Stop:** `ChatStore.interrupt()` (`Stores/ChatStore.swift:2973-2983`) — `guard let client` is
  the `HermesGatewayClient`; sends `session.interrupt` via `client.requestRaw`. Relay mode →
  socket never open → `GatewayError.notConnected` → `lastError = "Not connected to the Hermes
  gateway"` (`Models/JSONRPC.swift:82,93`) — the exact banner text. The relay path EXISTS and is
  unused: `RelaySessionCoordinator.interrupt` (`Stores/RelaySessionCoordinator.swift:665-667`) →
  upstream `interrupt` (handled in `relay/hermes_relay/downstream.py`). This is precisely the
  QA-1 B10 egress gap, which was fixed ONLY for approve/clarify (relay-aware at
  `ChatStore.swift:3140+`) — interrupt was missed.
- **Steer:** `ChatStore.steer(text:)` (`ChatStore.swift:3092-3133`) — same `guard let client` +
  `client.request("session.steer")`; AND the relay upstream protocol has NO steer method at all
  (`relay/hermes_relay/types.py:120-133`: submit/resume/open/list/history/approve/clarify/
  interrupt/ack/resync/foreground/push.* — no STEER). Double gap.
- **Queue-mode send disappears:** the relay send branch (`ChatStore.swift:~2470-2552`) RETURNS
  BEFORE the `if let queueStore` outbox branch (`2555-2577`). Relay sends NEVER enter the outbox
  → no pill (the dock's queued strip derives from `queueStore.pendingCount`,
  `TurnDock.swift:93`), and a failed submit executes `removeLocalEcho` + `setStreaming(false)`
  + `lastError` (`2543-2549`) — the echo is deleted and an error surfaced: the message
  "disappears" (C3 violation both ways). Since `interrupt` fails (above), the live turn never
  actually stops → `isStreaming` stays true → the composer is stuck in stop/queue posture until
  force-close (the R12 wedge).
- The inline "Not connected" banner surfaces `lastError` (toast at `ChatView.swift:618-621`)
  PLUS the connection-status banner (`Views/Drawer/ConnectionStatusBanner.swift`) for the same
  condition — the duplicated banners of IMG_2548.

### Fix outline (R11)
1. `interrupt()`: branch on `transportPath == .relay` → `coordinator.interrupt(interruptTarget)`
   (mirrors the QA-1 B10 approve/clarify pattern already in-tree).
2. Add upstream `steer` to the relay protocol (`types.py` + `downstream.py` → gateway
   `session.steer`), then route `steer()` through the coordinator identically.
3. Relay-mode queueing: while a turn is live (or submit fails/rejects-busy), enqueue to the
   outbox exactly like the direct path (route through the `2555` branch with a relay-aware
   drain — the drain's `send()` re-entry is already guarded by `isDraining`, `ChatStore.swift:
   2589-2592`); pill always visible; on submit failure NEVER delete the echo without a durable
   outbox row.
4. Policy: no `lastError` for transport-transition classes (C3); silent queue-and-drain.

---

## R12 — Task pill (dock) wrong · R13 — task list ownership/scoping

- **Visibility gate has no lifecycle:** the dock shows the task box solely on
  `chatStore.latestTodoList != nil` (`TurnDock.swift:60,88-92`). No turn-active gate, no
  "agent closed the list" state, no all-done auto-close → the pill PERSISTS after the turn ends
  and the stop wedge (R11: interrupt never lands → `isStreaming` stays true → red stop stuck →
  force-close, the IMG_2542-2549 episode).
- **Full-width (C2 violation):** `DockTaskBox` pill stretches via `Text(currentTitle).frame(
  maxWidth: .infinity)` (`TurnDock.swift:195`) and the expanded list `.frame(maxWidth: .infinity)`
  (`231`) inside a full-bleed background box — never width-to-fit, never centered, never
  side-by-side with the pending pill (they stack: `TurnDock.swift:78-97`).
- **Stale/wrong counts:** `doneCount` counts only `.completed` (`TurnDock.swift:146-148`); "0 of
  10" while task #1 is in_progress is literally true but reads as broken because there is no
  in-progress affordance; the transcript-side `Tasks 0/0` header (IMG_2543/2545) is a SECOND
  surface: `.taskList` items render inline via the item-layer `TaskListItemView`
  (`Views/Chat/Items/TaskListItemView.swift`) while `dockSuppressesTodoCards` suppresses ONLY the
  LEGACY `TodoCardView` (`ChatStore.swift:225-232` comment) — double render, and the inline
  header shows 0/0 before the item body parses.
- **R13 cross-session reappearance:** `latestTodo` (`ChatStore.swift:296-307`) prefers the relay
  mirror but FALLS BACK to scanning ALL `messages` for any `todo` tool activity — opening ANY
  session whose cached history contains an old todo tool call resurrects the dock in a context
  that has no live agent owning a list. The relay mirror (`relayLatestTaskList`,
  `ChatStore.swift:256,275-285`) is a single global slot refreshed per projection; relay
  `taskList` ITEMS persist in the session's item store after the turn (the relay keeps them in
  the snapshot), so the dock outlives the turn that created it.

### Fix outline (R12/R13)
- Visibility = (turn live AND list present) OR (list present AND agent has not closed it AND
  same session owns it); clear on `turn.completed` when the list is terminal (all done/cancelled)
  or the agent's list item is dropped; STOP state cannot wedge because turn-end (even frameless,
  via error/timeout) clears streaming (depends on R11/R4 fixes).
- Redesign per owner: native capsule, width-to-fit, centered; task + pending pills side-by-side.
- Strict session-scoping: key the mirror by session id; the `messages` fallback must require the
  scanned turn to be the session's LIVE turn (drop the context-free scan); test A6 (taskList in
  session A never shows in B).
- Suppress the item-layer `TaskListItemView` inline render while the dock owns the list (extend
  `dockSuppressesTodoCards` to the item layer); radio circles → per-row status affordances (C1).

---

## R14 — Outbox tombstone not persisted (P0 data)

**The repository write IS durable; the UI confirms removal BEFORE the write lands.**
- `QueueStore.remove` (`Stores/QueueStore.swift:361-373`): unleased/terminal job →
  `WorkRepository.deleteJob` (hard row delete, `Work/WorkRepository.swift:734-741`); leased job →
  `cancelJob` (sets `.cancelled` durably, `WorkRepository.swift:846-858`).
- But the user-facing delete sites are FIRE-AND-FORGET: `TurnDock.swift:347` `Task { await
  queueStore.remove(id: item.id) }` and `ComposerView.swift:1857` `Task { await queueStore.remove(
  id: id) }`. The row/pill disappears from the UI immediately (observation-driven), the GRDB
  tombstone write executes asynchronously later. Force-close inside that scheduling window →
  tombstone never lands → on relaunch the job is still `.queued` → the drain sends it. Exactly
  the owner's scenario ("cleared, force-closed quickly, reopened → SENT anyway").
- Secondary race: TOCTOU between the `repository.job(id:)` read (`QueueStore.swift:364`) and the
  delete/cancel — the drain can lease the job in between; deleting a leased job under an
  in-flight submit lets the submit land server-side while the completion guard fails silently
  (`WorkRepository.swift:886`).

### Fix outline (R14)
- `remove` must AWAIT the durable write before the UI confirms (button action `await`s; row
  removal keyed on the observation that follows the write, not optimistic); also cover
  `removeAll()` (`QueueStore.swift:375-377`).
- Verify the claim query excludes `.cancelled` on crash-recovery drain (pin in the A7 test:
  kill process after tombstone → relaunch → item never sends).
- Relay-mode queue-send always shows the pill (shared with R11 fix 3).

---

## R15 — Transcript segment dropped after the stuck episode (P0 render/data)

**The relay live-merge is safe; the eviction lives in the RESEED reconcile.**
- `applyRelayItems` preserves every untagged (cache/seeded) row: `preserved = messages.filter {
  !$0.relayProjected && !consumedEchoIDs.contains($0.id) }; messages = preserved + rebuilt`
  (`ChatStore.swift:4517-4520`) — NOT the culprit.
- The culprit: `reconcileMessages(with:)` (`ChatStore.swift:~3522-3615`) — used by backfill/
  reseed — treats `incoming` as the SOLE truth: "Existing rows absent from `incoming` are removed"
  (comment block `3500-3518`; final `messages = rebuilt` at `3615`). The only protection is the
  single-row ABH-278 keep for `pendingReconnectReconcileID` (`3603-3611`).
- On the relay path the network seed comes from `coordinator.history`
  (`Stores/SessionStore.swift:5924-5928` → `RelaySessionCoordinator.history`,
  `RelaySessionCoordinator.swift:593` → relay `rest_history`). The relay's per-session store
  holds only items OBSERVED since relay process start (QA-1: `relay/hermes_relay/session_state.py:
  74-98`) — so a reseed snapshot can be SHORTER than the in-memory merged timeline.
- **Episode:** the R12 wedge produced connection flapping (`Not connected` banners, IMG_2547) →
  `handleConnectionDrop` → reconnect → `backfill()` → `reconcileMessages(incoming = short
  snapshot)` → settled untagged rows absent from the snapshot were EVICTED from memory — the
  "conversation between two messages" vanished. The GRDB cache (write-through) still held the
  segment; switching sessions and back re-runs the cache-first seed (`seedTranscriptCacheFirst`)
  → repaired — exactly the owner's recovery path.

### Fix outline (R15)
- `reconcileMessages` must UNION, not replace: never evict an untagged settled row the store
  still holds unless `incoming` authoritatively COVERS its position (the snapshot is known-partial
  on relay — treat absent-older-than-snapshot-base as retained, not deleted). Or: on the relay
  path, skip the destructive reconcile and route reseeds through the same preserved+rebuilt merge
  (`4517-4520`) seeded from cache.
- A8 regression test: replay the recorded stuck-episode frames + a short reseed over a seeded
  cache transcript; assert zero segment loss (`tests/render_conformance` fixture).

### FIX RESULT (lane qa2/transcript2 — root cause CONFIRMED, no correction needed)
- Verified: `reconcileMessages` rebuilt solely from `incoming` (`ChatStore.swift:3615` on qa2/base);
  every reseed source is a known-partial TAIL window — relay history honors `limit` with
  `messages[-limit:]` (`relay/hermes_relay/downstream.py:697-699`), plugin REST serves the 50-row
  tail; `backfill()` additionally resolved ONLY `connection?.rest`, which is idle/unreachable in
  relay-only reach, so the post-flap recovery reseed never landed at all.
- Fix: `ChatStore.ReseedPolicy {replace, union}` on `seed(...)`/`reconcileMessages(...)`. Union
  updates matched rows in place, appends genuinely-new rows after the newest match, and RETAINS
  every untagged row the snapshot does not carry (settled history is never evicted — spec R15/A8
  invariant); `relayProjected` rows are still superseded (the live projection re-renders them from
  the item store on the next frame — no new duplication vs the pre-existing applyRelayItems merge).
  An unmatched incoming USER row adopts the same-text echo/projection slot (mirror of
  `adoptRelayEcho`, cmid-preserving) so the optimistic echo converges instead of doubling.
  REPLACE remains the default (session-open paints keep session isolation — cache-HIT opens seed
  WITHOUT a preceding `reset()`). Union callers (all same-session-guarded): `backfill()`
  (`ChatStore.swift`), phase-2 network seed / skeleton hydration / chain-tip cache+network seeds
  (`SessionStore.swift`). `backfill()` now resolves the relay `history` RPC on relay transport
  (R3 residue: recovery over the up transport, mirroring `SessionStore.resolvedTranscriptFetch`).
- A8 tests (RED on qa2/base 62a826a48 → GREEN with fix, `RenderConformanceTests`): short-snapshot
  reseed over a seeded cache transcript + recorded stuck-episode frames (mid-conversation segment
  survives flap→backfill→resume→settle); tail-window shift keeps older loaded rows with zero
  duplicates; echo↔gateway-row convergence; switch away+back restores the full cached transcript
  instantly (R3 residue pin); relay backfill runs over the relay transport.

---

## R16 — Live Activity lifecycle

**Start is wired; END is not, on the relay path.**
- Seams (`App/AppEnvironment.swift:295-339`): `onTurnStart → LiveActivityManager.shared.start`,
  `onTurnComplete → .end()` (`295-298`), `onTurnDiscarded → .end()` (`336-339`).
- `onTurnComplete?()` fires ONLY from the direct-path `handleMessageComplete`
  (`ChatStore.swift:1288`), the queue-drain idle path (`969`), and the foreign-mirror watchdog
  (`4620`). The relay settle in `applyRelayItems` — `else if isStreaming { turnStartedAt = nil;
  activeToolName = nil } ; setStreaming(false, "relayProjection")` (`ChatStore.swift:4532-4540`)
  — clears the timer fields "in parity with handleMessageComplete" **but never fires
  `onTurnComplete`** → on relay turns `LiveActivityManager.end()` is NEVER called when the turn
  ends. The widget counts elapsed locally from `startedAt`
  (`Support/LiveActivityManager.swift:137-148`) → timer runs endlessly. `staleAfter = 5 min`
  (`LiveActivityManager.swift:101`) only marks the activity STALE (dims it) — it does not end it.
- `onTurnDiscarded` fires from `cancelStreaming` (`ChatStore.swift:4569`) and
  `handleConnectionDrop` (`4687`) — but the B4 fix made the relay session-switch reset stop
  re-projecting, so a switch mid-turn may not reach `cancelStreaming` → the activity survives
  session switches too. End-callers otherwise: `ConnectionStore.swift:2118` (teardown) and the
  foreground `reconcile(hasActiveTurn:)` (`3281,3305`) — the latter ends it on the NEXT
  foreground after settle, which never comes while the phone stays locked (the owner's exact
  complaint: lock/home screen timer forever).

### Fix outline (R16)
- Fire `onTurnComplete?()` on the relay settle transition in `applyRelayItems` (the `isStreaming
  true→false` edge), and on relay turn-error frames; make the session-switch reset fire
  `onTurnDiscarded` when a live turn is dropped.
- Restyle minimal native (progress + session title + elapsed; ends at turn end) — A9 unit test
  on `shouldEndOrphan`-style pure decisions + the settle-edge firing.

---

## R2 — Drawer imperfect (snap-back / stuck)

**The right-edge "leak" is BY DESIGN; the snap-back and stuck are timing/plumbing gaps.**
- Presentation: `CompactLayout` (`Views/Shell/RootView.swift:1272+`) — the chat CARD travels
  `drawerWidth = width * 0.78` (`1324,1358-1361`) with parallax (`1346`); the right ~22 % strip in
  IMG_2529 IS the displaced chat card (its hamburger + skeleton are the destination view). The
  defects are: the displaced card is stuck on the R3 skeleton (so the reveal looks broken), and
  the close choreography.
- **Snap-back:** the close fires on first-paint reveal OR a 300 ms deadline
  (`Stores/SessionStore.swift:3572-3583,3769`; `DrawerState.close()` = spring `isOpen=false`,
  `Views/Drawer/DrawerState.swift:43`) — NOT on session identity. When the relay resume RPC +
  seed outlast the 300 ms deadline (relay mode widens the window — QA-1 B3 finding, still true),
  the drawer animates CLOSED onto the PREVIOUS session's card and the new session paints under it
  afterwards = "open-motion plays reversed". The search-result tap closes IMMEDIATELY with no
  reveal gate at all (`Views/Drawer/DrawerView.swift:1572-1573`).
- **Stuck:** QA-1 B3 added reveal hand-off for superseding `open()` calls
  (`SessionStore.swift:3727-3732,3590-3592`), but the reveal is still token-gated
  (`openToken`/`openRevealToken`), and scope/profile invalidation paths rotate the token WITHOUT
  firing the pending reveal (QA-1 doc enumerated `SessionStore.swift:246,272,3550`) — a rotation
  inside the reveal window kills the close permanently; there is still NO liveness fallback
  ("close once activeStoredId == the tapped id").

### Fix outline (R2)
- Intent-based close: the tap records the target id; close when `activeStoredId` becomes that id
  (onChange in RootView/DrawerView) — reveal/deadline become ACCELERATORS only. Make every
  token-rotation path fire/inherit the pending reveal. UI-test: rotate token mid-window → drawer
  closes; close completes only after the destination identity is active (no reverse-motion frame).

---

## R3 — Session load not clean (skeleton hang)

**QA-1 B2/B4 fixes landed** — relay network seed (`SessionStore.swift:5924-5928`) and the
blank-screen-impossible placeholder chain (`ChatView.transcriptPlaceholder`: empty-at-generation>0
→ skeleton unless `transcriptConfirmedEmpty`, `Views/Chat/ChatView.swift` static
`transcriptPlaceholder`). Remaining gap (REFINED, continuation of B2):
- On a CACHE MISS the paint waits on the relay `history` round-trip: phone → relay
  `wait_ready(10s)` → relay → gateway REST history (`relay/hermes_relay/downstream.py` read path)
  → single full-screen skeleton (`Views/Chat/TranscriptSkeletonView.swift`) for the whole window.
  With 175 chats / large transcripts this is multi-second (IMG_2530).
- Chrome resolves independently of the transcript: composer + breadcrumb paint instantly while
  the body is skeleton — the "half-loaded" look (by design of the phase split, but reads broken).
- No incremental paint of the network seed (all-or-nothing `messages = seeded`), no
  touch-down/neighbor pre-warm from the drawer.

### Fix outline (R3)
- Paginated/incremental seed: paint the relay `history` first page immediately, append older on
  scroll-up (the REST `limit` exists — `RelaySessionCoordinator.history(sessionID:limit:)`).
- Prewarm on drawer row touch-down/highlight; keep the last-N sessions' cache hot (cache eviction
  policy check — the internal disk is small).
- Skeleton parity: render the skeleton WITH the chrome composition the settled state has, so the
  transition is skeleton→content, not chrome+skeleton→chrome+content.

---

## NEW defects from forensics (ledger N1–N6) — triage

- **N1 nav-bar ghost-text bleed (pervasive, IMG_2531–2541+):** the transcript runs full-bleed
  under the nav bar — `.ignoresSafeArea(.container, edges: [.top, .bottom])`
  (`Views/Chat/ChatView.swift:568`) with a translucent compact nav background (deliberate
  full-bleed, comment at `ChatView.swift:~200`: compact uses the system-default bar "so the
  full-bleed card shows through") and NO top mask/clip on the scroll content. Scroll content
  renders through the bar region; combined with stale scroll offset across session switches it
  reads as prior-turn ghost text overlapping the title/icons. Fix: material/scrim or fade mask
  behind the compact bar, and reset scroll offset deterministically on session bind.
- **N2 raw state-name flash** — covered under R5 fix 4.
- **N3 premature-card-dismissal reading** — covered under R8 (REFINED: missing answer bubble,
  verify in sim).
- **N4 live-turn thinking double-print** — covered under R5 (inline ThinkingView label + body).
- **N5 composer trailing icon swap (IMG_2548):** the glyph family matches the dock's `checklist`
  icon (`TurnDock.swift:184`), not any `ComposerView` send-state glyph (send states are
  `arrow.up.*`/`stop.fill`/`mic`, `ComposerView.swift:1052,1659,1759`). Prime candidate:
  dock/pill control overlapping the composer's trailing slot (spacing/z-order collision with the
  task pill stuck at 0/10). UNVERIFIED — confirm in sim before fixing.
- **N6 per-item timers** — covered under R5.

---

## Hypotheses from the spec — verdict summary

| # | Spec hypothesis | Verdict |
|---|---|---|
| R1 | relay must route per-token env; iOS must report env; evict 400/410; dedup per device | **REFINED**: env routing + relay registration EXIST on main (QA-1 B14); the breaks are iOS mis-stamping env (strict-ASCII profile decode → `nil` → "production" on every dev build; sim `#if` masks it), 400 never evicted (410-only), and no device-id dedup (token-string-only; iOS sends no id) |
| R4 | state that flashes the Working pill still exists | **REFINED**: the flash is the sanctioned pre-first-item window (`ChatView.swift:243-249`); the real failure is its inverse — the terminal userMessage projection clears `isStreaming` (`ChatStore.swift:4540`), killing ALL affordance for the wait window; A2 requires deleting the pill state AND an immediate cursor bubble |
| R5/R6 | live turn stacks Worked+toolCall rows; empty containers reserve bands | **CONFIRMED + REFINED**: `liveSection` renders inline ThinkingView(s) + current-tool line + standalone cursor (3+ rows); bands are the FIXED 172 pt thinking window + standalone cursor row + clearance floor summing, not literal empty item containers |
| R7-R10 | card hand-rolled; keyboard not dismissed; long text clips | **CONFIRMED**: `ClarifyBanner` flat theme.card + bordered-bubble choices + roundedBorder black field; zero resign-on-appear; question unbounded-grows into nav bar; choices unconstrained ideal-width → hard clip |
| R11 | interrupt/steer/queue route via the direct-gateway client in relay mode | **CONFIRMED EXACTLY**: `interrupt()`/`steer()` `guard let client` (gateway-direct) → `GatewayError.notConnected`; relay has interrupt (unused) and NO steer method; relay sends bypass the outbox entirely |
| R12/R13 | dock wider than composer, stuck counts, no session scoping | **CONFIRMED**: visibility keyed solely on `latestTodoList != nil`; `maxWidth:.infinity` pill; context-free `messages` scan resurrects lists; item-layer task row double-renders with 0/0 |
| R14 | tombstone not durable before UI confirms | **CONFIRMED**: repository writes ARE durable, but delete sites are fire-and-forget `Task {…}` — UI confirms before the write; force-close in the gap resurrects the job |
| R15 | in-memory merged timeline evicts a segment the cache still holds | **CONFIRMED, seam located**: `reconcileMessages` reseed evicts rows absent from a (relay-short) snapshot (`ChatStore.swift:3615`); the live merge (`4517-4520`) is safe; cache reload repairs |
| R16 | LA timer not tied to turn end | **CONFIRMED**: relay settle never fires `onTurnComplete` → `end()` never called on relay turns; stale-mark ≠ end |
| R2 | drawer stuck + snap-back animation | **REFINED**: right strip is by-design displaced card; snap-back = close fires on 300 ms deadline/first-paint, not session identity; stuck = token-rotation paths still kill the token-gated reveal without hand-off; no identity-keyed liveness close |
| R3 | skeleton hangs, delayed paint | **REFINED**: B2/B4 landed; residual = cold-cache waits on the full relay-history round-trip as one all-or-nothing full-screen skeleton; chrome/body phase split |
