# QA-1 ROOT CAUSES — Device-QA Round 1 (build 114, relay mode)

**Diagnostician pass · 2026-07-20 · branch `qa1/base` @ 29804b344 + spec commit.**
Every cause below is code-evidenced (file:line on the qa1/base tree). Spec hypotheses
are marked CONFIRMED / REFUTED / REFINED per bug. This document steers the fix lanes.

Repo paths below are relative to repo root; iOS = `apps/ios/HermesMobile/`.

---

## FAMILY 1 — THE TRANSCRIPT FAMILY (B5, B6, B7, B13) — one defect, three seams

**Spec hypothesis CONFIRMED and sharpened.** The relay path replaces the transcript
data source wholesale and has no optimistic user echo — but the "history dropped"
point is actually TWO seams, and the relay itself never emits a user item.

### Seam A — projection is a wholesale REPLACE, not a merge
`ChatStore.applyRelayItems(_:)` (`Stores/ChatStore.swift:4178-4226`) rebuilds the
transcript purely from the relay render store's items and assigns
`messages = rebuilt` (**ChatStore.swift:4218**), then
`setStreaming(rebuilt.contains { $0.isStreaming })` (**4225**). It NEVER consults the
GRDB-cache-seeded `messages`, the seed window, or settled history. It is invoked on
**every** downstream frame by `RelaySessionCoordinator.ingest`
(`Stores/RelaySessionCoordinator.swift:305-311`: `store.apply(frame);
chatStore.applyRelayItems(store.items)`).

The render store itself starts EMPTY per session:
- `coordinator.start()` news up `store = RelayItemStore()`
  (`RelaySessionCoordinator.swift:196`), and ConnectionStore cold-starts WITHOUT a
  session id (`Stores/ConnectionStore.swift:1529/1532`).
- Session selection goes through `coordinator.resume(sid)`
  (`Stores/SessionStore.swift:3982`, via `bindRelayRuntime`, 3973-4010) whose FIRST
  act is `resetItemStoreForSessionSwitch` → `store = RelayItemStore()` +
  `chatStore.applyRelayItems([])` (**RelaySessionCoordinator.swift:430-434**) —
  which wipes the cache-painted transcript to `messages == []` mid-open (see B4).
- The relay `open` RPC DOES return full REST history in its RESULT
  (`relay/hermes_relay/downstream.py:556-572` — `{"session_id", "messages"}`), but
  the iOS side DISCARDS it: `coordinator.open/resume` return the JSON to callers who
  ignore `messages`, and no snapshot frames are sent on `open` (relay sends snapshots
  only on `resync` FALLBACK — `downstream.py:178-211`). The relay's per-session
  `SessionStore` only holds items the reframer has OBSERVED since process start
  (`relay/hermes_relay/session_state.py:74-98`), so an idle session's snapshot is
  empty anyway.

Consequence: the only history the user sees is the GRDB seed from
`seedTranscriptCacheFirst` — and the FIRST live frame of a new turn replaces
`messages` with just the current turn's items. **This is B7** ("every time I sent a
message the previous history disappeared") and **B6** (live turn floats with no
context above it; `ChatView` bottom-anchors the now-short list).

### Seam B — no optimistic user echo, and none on the wire either
`ChatStore.send` relay branch (**ChatStore.swift:2399-2426**) submits via
`coordinator.submit` with the comment "no local echo is appended here" (2404-2406),
relying on "the echoed user item" reconciling back. **There is no echoed user item:**
- The relay reframer maps only AGENT events; nothing synthesizes a `userMessage`
  item (`relay/hermes_relay/reframer.py:15-37` mapping table — `message.start` →
  `turn.started` only). `FrameKind.USER_MESSAGE` exists
  (`relay/hermes_relay/types.py:77`) but is emitted NOWHERE (zero emitters in the
  relay package).
- The SUBMIT handler drives resume/create + `prompt_submit` and returns the session
  id — it does not fan out a user item (`downstream.py:575-622`).
- The direct path's echo (`messages.append(ChatMessage(role: .user, …))`,
  ChatStore.swift:2536-2538) and the outbox's `presentOutboxEcho` (2444-2448) are
  both BYPASSED because the relay branch returns first (2419).

**This is B5** (sent message never appears until force-close reload — the reload
re-seeds from the gateway REST cache which the gateway populated server-side) and
**B13** (new chat: greeting stays, no user bubble; the relay submit result is also
discarded at ChatStore.swift:2416 `_ =`, so `SessionStore.isDraft`/`activeStoredId`
are never landed for a relay-created session — the new chat never becomes a real
row in the drawer until refresh, and a second send only works because
`coordinator.submit` falls back to its adopted `activeSessionID`,
`RelaySessionCoordinator.swift:373-379`).

### Why force-close "fixes" it (B15 — preserve)
Cold relaunch → `seedTranscriptCacheFirst` paints from the GRDB cache (which the
gateway-side store write-through keeps current) BEFORE any relay frame lands; the
transcript looks right until the first live frame replaces it again.

### Fix outline (Family 1)
1. **Merge, don't replace.** Give ChatStore a relay projection that unions
   cache/seeded settled history with relay items: keep seeded rows whose ids precede
   the relay turn baseline and append the relay-projected turn; or seed the
   RelayItemStore from the `open` RPC's `messages` result (map gateway REST rows →
   ChatItems with stable ids) so the store IS the history and the replace is safe.
   Prefer the second — one data source, snapshot reconciliation already idempotent.
2. **Optimistic user echo on relay send** (ChatStore.swift:2409-2426): append a local
   `.user` row at submit time (mirror 2536-2538, deterministic id), reconcile/replace
   it when a relay `userMessage` item arrives — AND make the relay actually emit one:
   synthesize a completed `userMessage` item in the relay SUBMIT handler
   (`downstream.py:575-622`, ord from `SessionState.next_ord`, fan out like any item)
   so cold-resume snapshots also contain the prompt. Both halves needed: the echo
   for latency, the item for replay fidelity.
3. **Land new-chat bookkeeping**: route the relay submit result's `session_id` back
   into SessionStore (clear `isDraft`, set `activeStoredId`, refresh list) —
   ChatStore.send relay branch currently discards it.
4. Route relay sends through the durable outbox with `clientMessageID`
   (`coordinator.submit` already supports it, RelaySessionCoordinator.swift:367-380;
   ChatStore's relay branch passes none → no dedup on flap-ambiguous submits).

---

## B1 — Cold-start "Resume Session Failed" alert

**Spec hypothesis REFINED (not a timing race — wrong transport, unconditionally).**
The alert text "Not connected to the Hermes gateway" is the giveaway: it is the
GATEWAY-DIRECT resume firing in relay mode, where the gateway socket is deliberately
idle.

- Alert surface: `DrawerView.swift:280-292` renders
  `"<action> Failed"` from `SessionStore.sessionActionError`.
- The error is stamped at **`Stores/SessionStore.swift:4442`** —
  `sessionActionError = SessionActionError(action: "Resume Session", …)` in the catch
  of `resumeActiveAfterReconnect()` (4351-4445), which sends `session.resume` over
  the gateway `client` (guard at 4354 only requires the gateway client object to
  exist — it always does, just never connected in relay mode → RPC throws
  "Not connected to the Hermes gateway").
- Two unguarded callers fire it on EVERY cold open / reconnect in relay mode:
  - **`Stores/ConnectionStore.swift:1617-1621`** — post-`configure` bind, runs for
    BOTH transports (no `transportPath` check) whenever the cold cache restore
    pre-selected a session (`sessionStore.activeStoredId != nil`).
  - **`Stores/ConnectionStore.swift:3112-3121`** — reconnect-recovery loop (same).
- The scene-phase path IS relay-guarded (`ConnectionStore.swift:3170-3171`), and
  session SELECTION is relay-aware (`bindRelayRuntime`, SessionStore.swift:3814-3821)
  — only these two resume callers were missed. So the spec's "fires before
  transport-ready" is refuted as stated: it fires AFTER the relay socket is open,
  against the idle gateway, and can never succeed in relay mode. North-star
  violation: a retryable/structural condition surfaced as a modal.

### Fix outline (B1)
- In `resumeActiveAfterReconnect` (SessionStore.swift:4351) branch on
  `connection?.transportPath == .relay` → resume via `coordinator.resume(storedId)`
  (exists: RelaySessionCoordinator.swift:396-403) and bind the runtime identically to
  `bindRelayRuntime`; or guard the two ConnectionStore callers to skip the
  gateway-direct resume in relay mode (the relay coordinator's `onReady` re-open at
  RelaySessionCoordinator.swift:345-350 already re-establishes the session).
- Policy: `sessionActionError` must never be set for transport-not-ready classes;
  silent queue-and-drain on ready (outbox + `onReady → queueStore.wake()` already
  exist — RelaySessionCoordinator.swift:100, ConnectionStore.swift:510).

---

## B4 — Blank screen · B2 — skeleton-forever switch · (cache-first path)

**B4 root cause** — the same wholesale replace, in the open path:
`bindRelayRuntime → coordinator.resume → resetItemStoreForSessionSwitch`
(RelaySessionCoordinator.swift:430-434) calls `applyRelayItems([])` →
`messages == []` — but `transcriptGeneration` was ALREADY bumped by the cache seed,
so `ChatView.transcriptPlaceholder`
(`Views/Chat/ChatView.swift:2380-2398`) returns `.transcript` (EMPTY, no skeleton)
because its skeleton branch requires `messagesEmpty && transcriptGeneration == 0`
(2389). Result: fully blank transcript, composer fine — exactly IMG_2513/2516.
It races the cache seed (`seedTranscriptCacheFirst`, SessionStore.swift:5234-5455):
whichever lands last wins — hence "likely"/intermittent.

**B2 root cause** — cache-first paint is correct when the GRDB cache is alive
(`seedTranscriptCacheFirst` phases 1/2, 5289-5348), but on a CACHE MISS the phase-2
authoritative fetch is gateway-REST via `resolvedTranscriptFetch` →
`connection?.rest` (**SessionStore.swift:5640-5680**) — the DIRECT gateway URL,
which in relay-only mode may be unreachable from the phone → the fetch hangs to the
15 s RestClient timeout (`Networking/Rest/RestClient.swift:152`) → skeleton
(`ChatView.swift:2377` branch) for up to 15 s per switch; on failure the catch
KEPS the cache if painted, else surfaces "Couldn't load conversation"
(SessionStore.swift:5438-5453). Note: the relay `open` RPC returns the same REST
history (`downstream.py:556-572`) over a transport that IS up — the phone simply
never consumes it.

### Fix outline (B4/B2)
- Never wipe-then-wait: `resetItemStoreForSessionSwitch` must not blank
  `chatStore.messages`; reset the item store but leave the painted transcript until
  the new session's first relay content lands (or seed the store from the open RPC,
  per Family 1 fix — then the reset is content→content, never content→void).
- Blank-screen impossibility test: `messagesEmpty && generation>0` must render
  skeleton-or-cache, never `.transcript` empty (close the placeholder hole at
  ChatView.swift:2389).
- Consume the relay `open`/`history` RPC `messages` as the network seed on the relay
  path instead of gateway REST (SessionStore.resolvedTranscriptFetch relay branch →
  `coordinator.history`/open result), so cache-miss switches paint over the relay,
  instantly, independent of gateway-REST reachability.

---

## B3 — Drawer does not close on session tap

**Mechanism found; spec hypothesis CONFIRMED at the state level.** The row tap's
dismissal is NOT direct — it is the R40 reveal-on-paint callback:
`sessions.open(summary) { onNavigate() }` (`Views/Drawer/DrawerView.swift:1926`;
`onNavigate == DrawerState.close`, `Views/Shell/RootView.swift:1378,1819`). The close
fires ONLY through `signalFirstPaint` (`SessionStore.swift:5263-5271,5348`) or a
300 ms deadline (`SessionStore.swift:3750-3756; drawerRevealDeadline 3567`) — and
BOTH are double-gated on `openToken`/`openRevealToken`
(`makeOpenReveal`, SessionStore.swift:3569-3582). ANY reveal-less `open()` that
rotates `openToken` inside the window kills the close permanently; the rotator
carries no `onNavigate`, so nothing ever closes the drawer:
- cold cache restore `open(summary, bindRuntime: false)` (SessionStore.swift:2229),
- `reviewCrossSession` (ChatView.swift:1785), `land()` (SessionStore.swift:4246-4257),
- scope/profile invalidation rotating the token (SessionStore.swift:246,272,3550).
Relay mode WIDENS the window: the switch carries an extra async hop
(`bindRelayRuntime` → relay RESUME RPC round-trip, SessionStore.swift:3978-3996) and
the phase-2 seed fetch can stall 15 s on unreachable gateway REST (B2), so a
second open/rotation lands mid-window far more often than on the direct path.
Also: `capturedIdentity == nil` early-returns WITHOUT signalling first paint
(SessionStore.swift:5313) — the deadline remains the only backstop, and it is
token-gated too. There is NO liveness fallback ("close once the tapped session is
the active one").

### Fix outline (B3)
- Make dismissal intent-based: the drawer tap records the target id; close when
  EITHER first paint fires OR the active stored id equals the tapped id (onChange of
  `activeStoredId` in RootView/DrawerView), independent of token plumbing.
- Have any superseding `open()` inherit/fire the pending drawer reveal instead of
  silently killing it (makeOpenReveal hand-off), and signal first paint on the 5313
  early return.
- Pin with a test: rotate openToken during the reveal window, assert drawer closes.

---

## B8 — Working pill back on relay · B12 — dead space above composer

**B8 root cause.** The tail "Working ⏱" row is `TurnActivityBar`
(`Views/Chat/ChatView.swift:2912-3005`, accessibilityId `inlineWorkingIndicator`),
mounted at the transcript tail when `shouldShowInlineTurnActivity`
(**ChatView.swift:208-213**: `chatStore.isStreaming && no pending gates`). The gate
is transport-agnostic; the relay path TRIPS it differently from the approved direct
behavior:
- `ChatStore.send` sets `setStreaming(true, reason: "relay.send")` at SUBMIT TIME
  (**ChatStore.swift:2412**) — before ANY renderable content exists; and
  `applyRelayItems` re-asserts streaming while any item is non-terminal
  (**ChatStore.swift:4225**). With history wiped (Family 1) and no user echo, the bar
  renders over a VOID — the "big working bar above the composer".
- The approved direct-path signal (breathing cursor in the streaming bubble) never
  materializes on relay until the first `agentMessage` delta: pre-turn `status` /
  `thinking` frames are non-item and project to NOTHING
  (`Networking/Relay/RelayItemStore.swift:109-111`).
- The bar's label/elapsed read `chatStore.activeToolName` / `turnStartedAt`
  (ChatView.swift:2995-3004) — both are DIRECT-PATH streaming internals the relay
  path never sets, so it always reads "Working · 0s" instead of the tool name.

**B12 root cause.** Reserved clearance is `composerClearance` =
`max(140 floor, measured composer + 16) + dock + 8`
(`ChatView.swift:254-269`), PLUS the TurnActivityBar row itself when up
(ChatView.swift:1124-1129, inside the scroll content above the clearance spacer).
With B8's Working row live over an emptied transcript (Family 1), the visible dead
space = bar height + ≥140 pt floor; remove B8 + restore history and the gap returns
to spec. (The dock collapses to height 0 when empty — its measurement path is sound,
ChatView.swift:851-856.)

### Fix outline (B8/B12)
- With Family 1 fixed (user echo + merged history), suppress the tail activity row on
  the relay path while a streaming assistant bubble is rendering the cursor
  (`shouldShowInlineTurnActivity` relay clause: show only pre-first-item), matching
  the ratified "cursor is the working signal; dock only for tasks/approvals/clarifies".
- If `activeToolName`/`turnStartedAt` are to mean anything on relay, derive them from
  in-flight relay items (latest non-terminal toolCall) — otherwise drop them from the
  relay label. Re-measure the gap after B8 suppression; 140 floor may still exceed
  the iPhone Air composer — tighten only if evidence shows it (composer frozen rule).

---

## B9 — Composer "+" (attach) button missing

**Spec hypothesis CONFIRMED: direct-mode-only capability gating.** The button's SOLE
visibility gate is `if uploadSupported` (**`Views/Chat/ComposerView.swift:664`**,
gate at **190-192**: `connection.capabilities.upload != .unavailable`). That state is
decided by a GATEWAY-REST probe chain the relay mode has no business depending on:
- `ServerCapabilities.probe` runs against `connection.rest` — the direct gateway URL
  (`Stores/ConnectionStore.swift:1632-1635` → `Stores/ServerCapabilities.swift:131-196`).
- Stage 1 probes the plugin mount `GET /api/plugins/hermes-mobile/devices`
  (`Networking/Rest/RestClient.probePluginMountEndpoint`); anything but a 200 with a
  `devices` array → not `.available` → **`resolvedPathStyle == .legacy`**
  (**ServerCapabilities.swift:111-113** — `.unknown` ALSO resolves `.legacy`).
- Stage 2 then probes upload on the LEGACY path `POST /api/upload`
  (`RestClient.probeUploadEndpoint`); a patched gateway has no legacy route → **404 →
  `upload = .unavailable`** → button hidden. On relay-only reaches where the mount
  probe 401/404s (or the phone hits the gateway from outside its LAN), this cascade
  is deterministic.
- The verdict is PERSISTED per server+app-version and CACHE-RESTORED on every cold
  open (ServerCapabilities.swift:144-156,195) — one bad probe pins "+" hidden for the
  whole build.
- Even if shown, relay-mode attach is architecturally broken today: the relay send
  branch is TEXT-ONLY by comment ("attachments still route the gateway-direct upload
  path", **ChatStore.swift:2406-2407**) and the files lane (#225) uploads via gateway
  `file.attach`/REST (`file.attach` RPC + `RestClient.upload`) — direct API only.

### Fix outline (B9)
- In relay mode, do not hide "+" off a gateway-REST probe: treat relay transport as
  `uploadSupported` (the relay is the source of truth, and the frozen composer rule
  says restore the button identically in both modes).
- For function (A5): relay attach path — either proxy `POST /api/upload` / `file.attach`
  THROUGH the relay (new upstream method; relay already proxies REST-ish reads,
  downstream.py:556-572) or keep gateway-direct upload but only when the REST probe
  genuinely proved availability. Relay branch of `send` must stop being text-only
  (ChatStore.swift:2409 `!hasAttachments` guard).

---

## B10 — Clarify / approval card never renders on relay

**Spec hypothesis CONFIRMED: render-layer gap, both directions direct-only.**
Wire conformance passed because the FRAMES decode (`Models/RelayProtocol.swift:69-70,
83-84` — `.approvalRequest`/`.clarifyRequest` kinds with `body` payload) — but:
- **Ingest gap:** `RelayItemStore.apply` drops both gate kinds by design
  (**`Networking/Relay/RelayItemStore.swift:109-111`** — "non-item frame kinds carry
  no store mutation"), and `RelaySessionCoordinator.ingest`
  (RelaySessionCoordinator.swift:305-311) has NO side channel into
  `chatStore.pendingApproval` / `pendingClarification`. Those fields — the SOLE input
  of the TurnDock resolver (`TurnDockContent.resolve`, ChatView.swift:815-822,
  TurnDock.swift:20-33) — are set ONLY by the gateway event router
  (`handleApprovalRequest`/`handleClarifyRequest`, **ChatStore.swift:1440-1451**,
  called from 826/829 + 1016/1019). So on relay the dock resolves `.none` forever and
  the user sees only the generic tool row ("Asking … ›") the reframer produced from
  the tool.start, plus the streaming "Still thinking" tail.
- **Egress gap:** the card actions call `respondApproval`/`respondClarification`
  (**ChatStore.swift:3009-3059**) which `guard let client` — the GATEWAY client — and
  send `approval.respond`/`clarify.respond` over it; in relay mode that socket is
  idle, so even a manually-surfaced card could never answer. The relay RPCs EXIST
  (`coordinator.approve`/`clarify`, RelaySessionCoordinator.swift:448-479) but
  nothing wires the UI to them.

### Fix outline (B10)
- In `RelaySessionCoordinator.ingest`, bridge the two frame kinds:
  `ApprovalRequestPayload(payload: frame.body)` / `ClarifyRequestPayload(payload:
  frame.body)` (constructors at `Models/ProtocolTypes.swift:634/670`, taking
  JSONValue) → set `chatStore.pendingApproval/pendingClarification` with
  `sessionId: frame.sid`; clear on `turn.completed`/resolution exactly as the direct
  router does (ChatStore.swift:1304-1307 semantics).
- Route `respondApproval`/`respondClarification` through the coordinator when
  `connection.transportPath == .relay` (coordinator.approve/clarify already build the
  ratified wire shape; relay passes through at downstream.py:634-661).
- Render-level test (A3/A9): feed recorded clarify+approval fixtures through
  RelayItemStore/coordinator and assert `pendingClarification/pendingApproval`
  non-nil, dock `.clarify/.approval`, and answer round-trip.

---

## B11 — Selection granularity wrong (whole-paragraph block + Done, no cross-paragraph)

**Architecture confirmed as the blocker — per-run islands, select-all on mount.**
- Each contiguous prose run is an independent `SelectableProseText` island
  (**`Views/Chat/MessageBubble.swift:2600-2670`**, mounted per `.text` segment at
  804, 1955-2057; segments come from `Rendering/MessageSegmenter.swift`).
- Long-press is a 0.4 s `LongPressGesture` (**2653**) that SWAPS the run for a
  `SelectableTextView` (first-responding `UITextView`, 2629-2633) which
  **auto-selects the ENTIRE run** on mount (doc contract 2590-2595:
  "becomeFirstResponder, selectAll — the approved fallback; selection is BOUNDED TO
  THIS RUN"), with a manual **"Done" exit button (2634-2643)**. That is precisely the
  owner's screenshot: whole paragraph selected, Done button, cannot extend past the
  paragraph — paragraphs (and code/table/image cards) are selection walls BY DESIGN
  of the island model.
- Native WORD-level selection from the press point + drag handles that extend across
  the whole message is impossible with N independent UITextViews: a UIKit selection
  cannot span sibling views, and select-all-on-mount is why there is no word-granular
  start.

### Fix outline (B11) — restructure per spec's sanctioned path
- ONE selectable container per assistant message: concatenate the message's prose
  runs into a single attributed string rendered by one UITextView-backed view
  (cards remain separate non-selectable views ABOVE/BELOW the prose container or are
  represented as object-replacement placeholders with exclusion paths so selection
  flows around them but never selects them).
- Drop select-all-on-mount: let the system long-press do word selection at the touch
  point (UITextView native interaction — no swap gesture, no Done button; exit by
  tapping away). Keep the user-bubble context-menu "Select Text" flow (§6) as is.
- Copy pill must stay absent (islands rules) — the system edit menu provides Copy.

---

## B14 — Zero notifications (live push path)

**Primary break: the relay service can NEVER send APNs — it is unarmed by env.**
- The relay Notifier fires via the reused `plugins/hermes-mobile/push_engine.notify`
  (`relay/hermes_relay/notifier.py` header + `_fire/_send`; observer over
  `TOPIC_RELAY_FRAMES`). `push_engine.notify` in a process WITHOUT
  `HERMES_MOBILE_RELAY_URL` takes the DIRECT APNs path, which is a no-op unless
  `APNsConfig.is_armed()` (`plugins/hermes-mobile/push_engine.py:149-160`):
  `HERMES_PUSH_ENABLED` truthy **AND** `HERMES_APNS_KEY_FILE` exists **AND**
  `HERMES_APNS_KEY_ID` **AND** `HERMES_APNS_TEAM_ID`
  (`push_engine.py:134-139`).
- **The launchd service sets NONE of these.** `relay/scripts/ai.hermes.relay.plist`
  `EnvironmentVariables` = only `HERMES_REPO_ROOT` + `PATH`. So in the supervised
  relay process `is_armed()` is False → every notify returns 0 → **zero pushes for
  ALL event kinds**, including approval/clarify which bypass foreground suppression.
  This alone explains "none arrived at all". (The mock-APNs E2E passed because the
  harness injects a fake push_engine — tests never exercise `is_armed`.)

**Secondary break: in relay mode the phone's token has no path to the notifier.**
- iOS registers the device token by DIRECT gateway REST
  `POST {gateway}/api/[mobile/]push/register` (`Support/PushRegistrar.swift:20,
  503-541`), gated on the REST capability probe (86). The relay upstream protocol has
  NO push-registration method (`relay/hermes_relay/types.py:120-133` —
  submit/resume/open/list/history/approve/clarify/interrupt/ack/resync/foreground
  only). The notifier reads tokens from `<HERMES_HOME>/push_tokens.json`
  (`push_engine.py:35`). It works ONLY when (a) the gateway runs on the SAME Mac as
  the relay (shared `~/.hermes`) AND (b) the phone once registered over reachable
  gateway REST. Off-LAN relay-only phones can never (re-)register → stale/empty
  registry even once armed.

**Owner-gated remainder:** the APNs `.p8` key file + Key/Team IDs must exist on the
Mac; that is not in the repo (secrets). Everything else is code/config.

### Fix outline (B14)
- Config (landable): extend `ai.hermes.relay.plist` + `install-service.sh` to carry
  `HERMES_PUSH_ENABLED`, `HERMES_APNS_KEY_FILE`, `HERMES_APNS_KEY_ID`,
  `HERMES_APNS_TEAM_ID` (and optional `HERMES_APNS_USE_SANDBOX`) — rendered from
  env/`~/.hermes/apns.env` at install; document the one-line owner action: place
  `AuthKey_*.p8` + fill the four values.
- Code (landable): add a `push.register` upstream method (token+platform+env+events)
  to the relay protocol, have the Notifier/durable_state own a relay-side token
  registry, and register from `PushRegistrar` over the relay when
  `transportPath == .relay` — removes the shared-HERMES_HOME + gateway-REST-reachable
  coincidence requirement.
- Verify suppression correctness while here: phone must clear foreground on
  background (FOREGROUND null) or turn_complete stays gagged; approval/clarify
  already bypass (notifier.py header policy).
- Evidence target: one real push to the device, or a logged `notify` attempt with
  armed creds + registered token showing the exact remaining blocker.

---

## B15 — Force-close recovery (regression guard)

Works because cold relaunch seeds from GRDB before any relay frame (see Family 1).
The Family-1/B4 fixes must keep cold-open paint cache-first and never route the
initial paint through the relay store — assert in the render-conformance gate (A9):
cached transcript paints with zero relay frames; live frames append, never replace.

---

## Hypotheses from the spec — verdict summary

| # | Spec hypothesis | Verdict |
|---|---|---|
| B5/B6/B7/B13 | live-turn view replaces transcript (RelayItemStore vs ChatStore union) + no optimistic echo | **CONFIRMED + sharpened**: replace is `messages = rebuilt` (ChatStore:4218); wipe ALSO happens at session open via `resetItemStoreForSessionSwitch` (RSC:430-434); the relay emits NO userMessage item at all (zero emitters) — echo must be local AND relay-synthesized |
| B1 | resume fires on scene-activate before transport-ready on the phase bridge | **REFINED**: scene-phase is relay-guarded; the culprits are the post-configure bind (ConnectionStore:1617-1621) and reconnect loop (3112-3121) firing the GATEWAY-direct resume unconditionally — wrong transport, not timing |
| B8/B12 | dock/working-pill suppression rules not applied on relay state; reserved space | **REFINED**: dock is fine (no working case); the bar is `TurnActivityBar` driven by `isStreaming`, tripped at submit on relay (ChatStore:2412) over a wiped transcript; gap = bar + 140 floor |
| B9 | attach gated behind direct-mode capability check / relay-ready gating | **CONFIRMED**: `uploadSupported` ← gateway-REST probe; unknown-mount → legacy path → 404 → `.unavailable`, persisted |
| B10 | relay gate frames decode but UI mapping direct-only | **CONFIRMED both directions**: frames dropped at RelayItemStore:109-111 + no bridge to `pendingApproval/pendingClarification`; answers hardwired to gateway client |
| B14 | token never registers with relay session / service env lacks APNs creds | **CONFIRMED BOTH**: plist carries no APNs env → `is_armed()` false → zero sends; no relay push.register method → relay-only phones can't register tokens |

---

## LANE STATUS — transcript family (2026-07-20, branch qa1/transcript)

**Family-1 root cause CONFIRMED exactly as above** (all four seams code-verified
on qa1/base): the wholesale `messages = rebuilt` replace (ChatStore:4218), the
open-path wipe via `resetItemStoreForSessionSwitch` → `applyRelayItems([])`
(RSC:430-434), zero `userMessage` emitters in the relay (`FrameKind.USER_MESSAGE`
unused; reframer maps only agent events), and the discarded submit result
(ChatStore:2416). Fixed in commits `40ad925ac` (relay SUBMIT emits the completed
userMessage item; deterministic cmid-keyed id; folded + fanned out like a
reframer frame), `93e7fee8a` (iOS merged-timeline projection — tagged
`relayProjected` rows append below untagged history; optimistic echo on relay
send with cmid; sticky echo adoption by cmid-then-text; switch reset no longer
blanks the paint; `SessionStore.landRelayCreatedSession` lands the relay-created
id for B13) and render-gate tests `cde13013e`
(RelayTranscriptMergeTests: FAILS on base, PASSES with the fix).

Two refinements to the fix outline, landed:
- Outline step 2 said "reconcile when a relay userMessage item arrives" — the
  relay now ALSO carries `client_message_id` in the item body so the echo
  adoption correlates by cmid FIRST (distinct sends of identical text never
  collapse); text is the fallback for cmid-less items.
- Outline step 4 (route relay sends through the durable outbox) is DEFERRED as
  debt: `createOutboxDestination()` is gateway-`session.create`-bound, so
  outbox routing would break the relay new-chat flow without a relay-aware
  destination path. The direct relay submit now carries a fresh cmid per send
  (flap-dedup identity for the relay side; outbox drain already passed its job
  cmid). Residual limitation: a failed direct relay send is not retried
  durably — the echo is removed and the error surfaced; the user re-sends.

Inter-lane notes: the B4 placeholder hole (ChatView:2389 `messagesEmpty &&
generation>0` → empty `.transcript`) is left for the B4 lane; this lane removes
its trigger on the relay path (the switch reset no longer blanks `messages`).
The B8 lane owns the TurnActivityBar suppression; `setStreaming` semantics on
the projection are unchanged.
