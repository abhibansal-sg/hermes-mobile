# Hermes Mobile — Wave Roadmap (updated 2026-07-19)

Owner objective (north star): **WhatsApp-grade smoothness.** Open the app → last
state paints instantly from disk; the connection heals silently; a running turn
resumes mid-sentence after a drop; a finished turn always lands as a notification
when the phone is off. No visible error flash, ever, for a self-healing condition.

This revision folds in the **R-01…R-79 audit inventory**
(`docs/mobile-foundation/spec-inventory-r01-r79.md`, from the ChatGPT Pro full
audit) as the checklist backbone for Waves 3–6, and adds the session-surface UX
one-shot (Wave 2.5). The audit's framing quote is adopted verbatim as the
architecture rule for Waves 3–4:

> "Make every important state durable, make every refresh revisioned and
> authoritative, use APNs as attention and invalidation, use BackgroundTasks for
> opportunistic catch-up and maintenance, use background URLSession for
> transfers, and render cached data honestly while synchronization occurs."
> Explicitly NOT the objective: making iOS keep the WebSocket alive.

**Architectural amendment to the audit (important):** the audit assumed the
gateway is the only server. We now have the **relay** (Wave 2) — a co-located,
phone-owned process. Every server-side item the audit calls for (durable push
outbox R-28, pending-attention endpoint R-54, sync manifest R-44, background
invalidation pushes R-33) can be implemented **in the relay with zero gateway
core patch**, preserving the Wave-2 boundary. That is the default home for all
server-side R-items unless a specific item proves impossible there.

---

## WAVE 1 / 1.1 / 1.2 — DONE (recovery + durability last-mile)

Offline cold-open paints from the on-device cache (dead-cache v3 migration bug
fixed against the owner's real DB), auto-reconnect on network return, session
list re-seeds after recovery, WhatsApp-style send states + session-scoped queue
pill, settled-reasoning auto-collapse interim.

## WAVE 2 — Item-lifecycle streaming via the relay — LANDED, CLOSING OUT

The phone is a first-class client of the stock gateway through a co-located
**relay-client** (`relay/hermes_relay`): raw gateway events reframed into the
ratified item protocol (`docs/RELAY-PHONE-PROTOCOL.md` — envelope
{seq,sid,turn,kind,body}, item lifecycle with authoritative `completed`, seq/ack/
replay ring, resume-as-items snapshot), relay-fired APNs. Zero gateway core
patch. R0 spike + convergence E2E both passed; device QA confirms the relay is
seamless (owner couldn't tell relay from direct — the goal).

Remaining to close Wave 2:
- [ ] Merge PR #220 (convergence: transport toggle, ATS, relay URL mapping) — device-QA sign-off.
- [ ] Merge PR #221 (relay reliability: pending-drain on reconnect, last-turn
      cache reconciliation via retained-watermark resync, fast reconnect backoff,
      deep-link resume via relay, downstream SUBMIT dedupe).
- [ ] Land `wave2/relay-turn-elements` (in flight): dedicated task/todo frame,
      approval/clarify forwarding + response routing, notifier on clarify +
      task-complete. Protocol doc updated alongside.
- [ ] Known gap (accepted, tracked for Wave 4): relay `submit` lacks
      `client_message_id` end-to-end idempotency (R-48's server half).
- [ ] Doc drift: protocol §2 called inline images "an iOS gap today" — stale;
      STR-695 shipped full inline image rendering. (Fixed 2026-07-19.)

## WAVE 2.5 — Session-surface UX one-shot (IN FLIGHT — design locked via mockups)

One coherent SwiftUI rebuild of the session surface, designed collaboratively in
HTML mockups first (`hermes-tmp/mockups/transcript-full.html`, approved
2026-07-19). The mockup is throwaway; the build is native. Composer is **frozen**
— zero changes to the current app composer.

- **Transcript redesign (ChatGPT-language, approved):**
  - Collapsed thinking = plain muted text "Worked for Nm Ns ›" — no box/border.
  - Expanded = chrome-less step list (monochrome glyph + humanized summary).
  - Tap step → "Thinking" sheet: timeline rail, per-step reasoning + command/
    output cards. Three-level disclosure.
  - Answer body: high-contrast prose, bold headings; code/table/graph as subtle
    lifted cards (no hard borders) with per-card copy.
  - Selection islands: prose runs natively selectable via long-press (no context
    menu stealing the gesture); rich cards non-selectable; bar Copy = whole
    answer minus thinking/tools.
  - Always-visible action row under agent turns: muted icons Copy · Retry ·
    Branch · Share · Speak. No delete on agent turns. User bubbles fully clean.
  - **Streaming caret = the working signal**: the app's existing ▌ half-block,
    theme-bound (`theme.midground`), breathing 0.6s — extracted into ONE
    reusable, swappable component. No fat working pill; send button becomes stop.
  - **Turn dock attached above the composer** (not inline, not floating): task
    box (collapsed snapshot "3 of 7 · current task" + thin progress line → tap
    expands full list, reusing current TodoCardView styling), approval card,
    clarify card (chips + free text), tappable queued strip → queued-messages
    sheet. One home for everything interactive.
- **Link fixes** (images audited 2026-07-19: already clean — inline AsyncImage,
  retry, lightbox, provider embeds; no changes): (a) in-app SFSafariViewController
  instead of kicking to Safari; (b) autolink bare URLs (currently inert text);
  (c) explicit link styling + long-press copy/open/share.
- **Drawer bug** (fix in flight on `fix/drawer-session-switch`): drawer doesn't
  close on session select; open-swipe gesture then fights itself (follow-finger
  jitter). Close-on-select + gesture guard.
- **Projects page repair**: opening a project shows none of its sessions; no
  create-project flow; projects are live-only (no cache-first paint). Audit in
  flight; fix lands in this wave. Projects list + detail must paint from GRDB
  cache like sessions do.
- **Files & attachments**: make "work directly with files/attachments" real —
  audit in flight (known-weak: downloaded-version semantics, no inline file
  cards in transcript, attachment queue is text-only). Scope the fixes here;
  durable transfer machinery itself is Wave 4 (R-36).
- **Settings restructure**: group the long flat page into sub-screens
  (Connection · Notifications · Appearance · Privacy · Advanced/Developer ·
  About), clean up label language, reserve slots for the Wave-5 health screens
  (Notification Health, Sync Health, Diagnostics R-79). Experimental toggles
  (Relay) move under Advanced.
- **Transcript perf guard**: the rebuild must preserve Wave-1/2 wins — cache-
  first paint, item-scoped O(delta) streaming, tail-cap.

Acceptance (feel bar): user bubbles have zero affordances; long-press selection
gives real drag handles; thinking folds to one muted line; tasks/approvals/
clarifications/queue all live in the dock; links open in-app; a project opens to
its sessions instantly from cache.

## WAVE 3 — Attention & freshness (notifications, background refresh, sync truth)

The audit's Phase 0 + Phase 1, relay-first. This is "the app is correct and
fresh even when you're not looking at it."

**3a — Notification correctness & trust (audit Phase 0):**
- [x] R-01/R-19 short-turn suppression (attention-gate + 4h APNs expiry) — shipped pre-Wave-1; keep the device test matrix as a regression gate.
- [ ] R-20/R-04 install notification delegate/categories at
      `didFinishLaunchingWithOptions`; cold-launch actions resolve credentials
      from persistent storage (no SwiftUI-bootstrap race).
- [ ] R-07/R-23 one notification authority (APNs authoritative, local fallback
      only, event/request/session-ID dedupe with TTL; foreground haptic instead
      of banner for the active session).
- [ ] R-08/R-29 Live Activity cadence: priority 5 routine / 10 urgent-terminal
      only; semantic triggers; `startedAtEpochSeconds` in content state.
- [ ] R-24 `.authenticationRequired` on clarification Reply.
- [ ] R-27 badge = authoritative pending-attention count (or drop badge permission).
- [ ] R-31 multi-turn Live Activity ownership rule (latest user-owned turn wins;
      approval preempts; workers/background jobs never own the phone surface).

**3b — Durable attention (the Inbox can never lie):**
- [ ] R-03/R-53/R-54 pending-attention endpoint (`/attention/pending?after=cursor`)
      — **implement in the relay**; persisted snapshot on device; reconciled on
      launch/foreground/BG-refresh/push/notification-tap/WS event. Inbox states:
      Pending / Responding / Resolved-elsewhere / Expired / Failed-retry.
- [ ] R-28 durable push outbox — **in the relay**: SQLite outbox (event_id,
      device, kind, payload, priority, expiry, collapse_id, status, attempts,
      next_attempt, last APNs status), retry/backoff, Retry-After, token pruning
      on BadDeviceToken, expired-event skip. (Relay notifier already fires
      turn_complete/approval/error + clarify/task-complete from turn-elements;
      this makes delivery durable across relay restarts.)

**3c — Freshness protocol (sync manifest as the single truth):**
- [ ] R-05/R-44 revisioned **sync manifest** endpoint — **in the relay** (it
      already reads state.db + accumulates live state): server_time, revision,
      cursors, session upserts + **tombstones** (R-45, kills the
      deleted-sessions-reappear bug and the 30s full-list refetch tax),
      pending_attention, active_turns, transcript_heads, widget_summary; applied
      client-side in ONE SQLite transaction + one observable publish (R-42).
- [ ] R-46 scope in DB identity (composite server/profile/session keys).
- [ ] R-09 generation-based session-list reconciliation.
- [ ] R-13/R-40/R-69 kill the hydration full-screen loader: cached shell +
      readable transcript + "Syncing…" nonblocking state; brand loader reserved
      for true first launch.
- [ ] R-41/R-43/R-70 freshness language everywhere remotely-sourced ("Updated 2h
      ago · Connecting…", Offline/Connecting/Syncing/Fresh/Sync-failed-cached).
- [ ] R-52 offline transcript search (SQLite FTS over the already-persisted
      transcripts; merge remote results when connected).

**3d — Background execution layers (audit §6, the layered architecture):**
- [ ] R-33 background push as invalidation (`content-available:1` +
      `sync{scope,revision,reason}`) — sent by the relay; client fetches delta,
      never trusts payload as data.
- [ ] R-34 `BGAppRefreshTask`: manifest delta → one transaction → widget
      snapshot → reschedule.
- [ ] R-37 `beginBackgroundTask` state flush (draft, outbox, cursor, widget
      snapshot, pending nav intent) — flush-only, never keepalive.
- [ ] R-55/R-56/R-57 widgets: read-merge-write snapshot (no cold-launch nil
      overwrite), metrics from the manifest (honest numbers), explicit staleness
      rendering.
- [ ] Progressive history backfill on pairing (owner ask): recent-first, weeks in
      seconds, rest via background fill; attachments on demand.
- [ ] Windowed lazy scrollback from disk (memory holds a window, disk holds all).

Acceptance: opening after a week shows cached content instantly with honest
freshness labels; deleted sessions never resurrect; a 5s locked-phone turn
produces exactly one alert; killed-app approval actions work; Inbox correct
after process termination; missed pushes recovered by foreground/BG sync;
widget numbers truthful.

## WAVE 4 — Durable user work & transfers (audit Phase 2)

- [ ] R-47 drafts → SQLite (autosave debounce, restore by scope, clear only on
      server-acked submit).
- [ ] R-10/R-48 outbox → SQLite with **end-to-end idempotency**: relay `submit`
      gains `client_message_id`, gateway-ambiguous retries never double-drive a
      turn; visible states Waiting/Uploading/Sending/Sent/Failed-Retry/Cancelled.
- [ ] R-49 App-Intent/Siri jobs into the same durable job repo.
- [ ] R-58 share-extension jobs: caps, TTL, orphan sweep, failed-share UI with
      Retry/Delete, idempotent destination creation.
- [ ] R-36 background `URLSession` TransferManager (uploads/downloads survive
      suspension + relaunch); attachment sends join the durable queue (today
      queued prompts are text-only).
- [ ] R-50 attachment cache: content-version/ETag keys, LRU byte cap, TTL,
      per-scope purge, orphan scan, downsampling, disk-pressure reaction.
- [ ] R-35 `BGProcessingTask` maintenance: cache eviction, orphan cleanup,
      SQLite checkpoint/vacuum, Spotlight reindex, expired outbox/inbox cleanup.
- [ ] R-11 (dup of R-50) attachment freshness.

Acceptance: drafts survive force-quit; ambiguous-network retry never
double-submits; large uploads survive termination; failed shares visible and
retryable; attachment cache bounded and version-correct.

## WAVE 5 — Privacy, trust surface, diagnostics, polish (audit Phase 3)

- [ ] R-02/R-60/R-61 real **Go Offline vs Forget Gateway** split; 15-step wipe
      transaction; self-revoke triggers the same wipe.
- [ ] R-62 immediate app-switcher privacy shield (separate from auth lock).
- [ ] R-63 refuse App Lock without a device passcode.
- [ ] R-25/R-26 notification privacy previews (Full/Generic/Hidden), quiet
      hours, thread-ids, interruption levels, collapse-ids, per-session mute.
- [ ] R-21/R-22 notification health: persisted registration state, unregister
      tombstones with retry; **Notification Health screen**.
- [ ] R-14/R-51 stale-while-revalidate snapshots for all panels (usage, cron,
      skills, providers, devices, archives, files, artifacts).
- [ ] R-64 Spotlight/Handoff preference + purge on forget; R-65 expiring
      local-only pasteboard; R-66 pairing secret hygiene (short-lived one-time
      codes); R-67 HTTPS posture (HTTP only for loopback/LAN/tailnet, with
      warning); R-68 privacy manifest + archive gate.
- [ ] R-71/R-72/R-73/R-74 a11y: semantic rows (cron/devices), toast
      announcements, `performAccessibilityAudit` matrix, Dynamic Type/VoiceOver/
      RTL coverage.
- [ ] R-75 String Catalog localization (app, widgets, Live Activity,
      notification payload loc-keys, App Intent phrases).
- [ ] R-76 store decomposition: NotificationCoordinator, SyncCoordinator,
      BackgroundTaskCoordinator, OutboxRepository, TransferManager,
      CacheRepository, PrivacyCoordinator. (SyncCoordinator work re-uses the
      parked local-first program — it earns its A0/A1/B1 proof gates here.)
- [ ] R-77/R-78/R-79 observability: client signposts/MetricKit, relay/gateway
      push metrics, in-app **Diagnostics screen** with test-notification
      correlation IDs + redacted export.
- [ ] R-59 awaitable pairing API (kill the 200ms QR poll).
- [ ] R-17 multiwindow ownership.
- [ ] Theming: automated contrast checks across themes (from §13).

## WAVE 6 — Advanced / optional (audit Phase 4 + parked items)

- [ ] R-30 Live Activity **push-to-start** (desktop-started turns spawn the
      activity on a terminated phone).
- [ ] Rich notification content via a notification service extension.
- [ ] User-selectable offline download policy (conversations + artifacts).
- [ ] R-38 `BGContinuedProcessingTask` (iOS 26+) for user-visible long ops only.
- [ ] R-39 background audio ONLY if a real locked-screen voice feature ships.
- [ ] **Outbound reverse tunnel** reachability (Fetch-plugin pattern; removes the
      Tailscale requirement; self-hosted, protocol rides over it unchanged).
- [ ] **Foreign-session live co-watch** (parked): relay subscribes to the stock
      broadcast fan-out as observer — still zero core patch.
- [ ] Multiwindow scene-specific routing.

---

## Cross-cutting / infra (fold in opportunistically)
- **ABH-370 durable fix**: dashboard-supervisor provenance flap (npm re-dirties
  the runtime `package-lock.json` → exit 78). Proactive watchdog carries it;
  real fix = dashboard startup must not run npm against the workspace lock.
- **Generated-file policy**: `.pbxproj` + Info.plists are XcodeGen output but
  committed; CI regenerates since Wave-1 — decide gitignore + generation story
  (check `ci_scripts/` for Xcode Cloud).
- **Fixed-sleep test de-flaking**: convert `Task.sleep` settle() helpers to
  condition-polling (~9 files).
- **Doc hygiene**: keep `RELAY-PHONE-PROTOCOL.md` in lockstep with relay changes
  (turn-elements adds task frame; §2 image note fixed 2026-07-19).

## REACHABILITY (phone → relay)
- **NOW**: Tailscale (owner runs it; device QA green over tailnet).
- **Wave 6**: self-hosted outbound reverse tunnel (see above). Never route
  session content through third-party cloud.

---

## Appendix — R-01…R-79 → wave map (compact)

- **Shipped / superseded**: R-01, R-19 (short-turn fix); R-13/R-40/R-69 partially
  (cache-first paint exists; hydration-loader kill completes it in W3c).
- **Wave 2 (relay, landed/closing)**: streaming, resume, replay, relay notifier
  basics; turn-elements (tasks/approval/clarify frames) in flight.
- **Wave 2.5**: transcript/dock/selection redesign; link fixes; drawer bug;
  Projects repair; files/attachments UX; Settings restructure.
- **Wave 3**: R-03 R-04 R-05 R-07 R-08 R-09 R-12 R-20 R-23 R-24 R-27 R-28 R-29
  R-31 R-32 R-33 R-34 R-37 R-41 R-42 R-43 R-44 R-45 R-46 R-52 R-53 R-54 R-55
  R-56 R-57 R-70.
- **Wave 4**: R-10 R-11 R-35 R-36 R-47 R-48 R-49 R-50 R-58.
- **Wave 5**: R-02 R-14 R-15 R-16 R-17 R-18 R-21 R-22 R-25 R-26 R-51 R-59 R-60
  R-61 R-62 R-63 R-64 R-65 R-66 R-67 R-68 R-71 R-72 R-73 R-74 R-75 R-76 R-77
  R-78 R-79.
- **Wave 6**: R-30 R-38 R-39 + tunnel + co-watch.
