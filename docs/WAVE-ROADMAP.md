# Hermes Mobile — Wave Roadmap (Wave 2 detailed, Wave 3+ high-level)

Owner objective (north star): **WhatsApp-grade smoothness.** Open the app → last
state paints instantly from disk; the connection heals silently; a running turn
resumes mid-sentence after a drop; a finished turn always lands as a notification
when the phone is off. No visible error flash, ever, for a self-healing condition.

Status context (2026-07-18): Waves 1 / 1.1 / 1.2 landed the recovery + durability
last-mile — offline cold-open now paints from the on-device cache (the dead-cache
migration bug is fixed), the app auto-reconnects on network return, the session
list re-seeds fully after recovery, and sends use WhatsApp-style transcript states
with a session-scoped queue pill. What remains between here and the north star is
**how the live turn is streamed and rendered** — that is Wave 2.

---

## WAVE 2 — Item-lifecycle streaming (PRIMARY FOCUS)

### The problem in one sentence
Today a streaming turn is **one growing blob of text**. The phone receives
"…more…more…" and repaints the whole body; if the socket hiccups mid-turn, the
blob is torn and the client throws it away and refetches. This is why long answers
get progressively janky, why reconnecting mid-turn shows dead air, and why the
transcript can't cheaply show a collapsed "worked for N min" summary.

### The idea (borrowed from Codex, verified against openai/codex)
Stop streaming a blob. Stream **typed items with stable IDs and a self-healing
lifecycle**. Every piece of a turn — the answer text, a reasoning block, a tool
call, a file change — is an *item* with an `id` that goes:

    started → delta → delta → … → completed

The `completed` event carries the **authoritative full item**, and the client
replaces whatever it had accumulated. This one property is the whole trick:
- Deltas are rendered **optimistically**; dropped/garbled deltas don't matter
  because `completed` is the source of truth and reconciles them.
- Reconnecting mid-turn is just: "give me the current items" (snapshot) + resubscribe.
- A settled item can be collapsed to a one-line summary and its body fetched on
  demand — because it has a stable id to fetch by.

Codex has **no sequence numbers on its core stream** — ordering rides in-order
transport + the item-authority contract. Sequence/ack/replay lives only at the
network edge (their phone-relay). We mirror that: core stays seq-free; the mobile
plugin edge gets the replay buffer.

### What we adopt (ranked by feel-impact ÷ effort)

**2.1 — Item-lifecycle event model (the keystone).** Replace the single
accumulated `assistant` text delta with typed items each carrying `item_id` and a
terminal `completed` payload. Item types to start with: `userMessage`,
`agentMessage`, `reasoning`, `toolCall`, `fileChange` (adopt the *pattern*, not
Codex's full ~18-variant enum).
- Gateway (`tui_gateway/server.py`, around `_append_inflight_delta` /
  `_start_inflight_turn` / `_inflight_snapshot`): emit `item.started` /
  `item.delta{item_id,…}` / `item.completed{item_id, full_item}` instead of one
  text stream.
- Plugin (`plugins/hermes-mobile/`): pass through / map to the mobile envelope.
- iOS (`ChatStore`): reduce deltas by `item_id` into the ordered-parts model that
  **already exists** (`ChatMessagePart`, `assistantRenderParts`,
  `ThinkingView`/`ToolClusterView` — see `docs/archive/ios/CHAT-THREAD-PARTS-*`
  history) and into the GRDB cache, instead of string-appending.
- **Prompt caching is untouched** — this is a UI-transport concern, not a
  model-input concern. Model-visible history stays completed-items-only (mirror
  Codex's policy of never persisting raw deltas), so replay/resume never perturbs
  the cached prefix.
- Effort: **M**. Feel: **5**. Do this first; everything else builds on stable ids.

**2.2 — Resume-as-items + atomic subscribe.** Extend `_inflight_snapshot` to
return the running turn as the same item list (with in-progress items), and make
the subscribe atomic with snapshot generation (snapshot + transport-rebind under
one lock) so nothing streamed between snapshot and re-bind is dropped. Hermes
already has the resume + rebind machinery (`_session_resume_lock`); this reshapes
the payload.
- Effort: **low–M** once 2.1 exists. Feel: **5** (mid-turn reconnect repaints exactly).

**2.3 — Edge replay buffer (flaky-cellular reliability).** Add a monotonic `seq`
per mobile connection on outbound notifications, an `ack{seq}` from iOS, and a
small bounded ring of unacked frames that replays on reconnect with a
`subscribe_cursor`. **Revive the already-present `replay_ring.py`** for exactly
this — scoped to the plugin/mobile edge, NOT the core (Codex keeps seq/ack in its
relay layer, not the app-server stream).
- Effort: **M**. Feel: **4** on subway/elevator networks. Respects "capability at
  the edge, minimal core."

**2.4 — Collapsed working-sections (owner-specced, ChatGPT-style).** With stable
item ids this becomes natural:
- Settled turns: fold reasoning + tool-calls under a one-line "Worked for N min"
  summary; tap to expand thinking + a tool-call summary line; tap a tool line to
  expand its full body (code diffs etc.). Multi-level disclosure.
- Live turns: show streaming reasoning + a **single current-tool line** (10 tools
  still = one line, updating); never auto-expand every call. Manual expand allowed.
- Payload tiering: don't ship expanded tool bodies on session open — ship
  summaries, fetch bodies on tap (the server `shape=skeleton|light` tiering in
  `transcript_sync.py` and Codex's `itemsView: summary|full` are the same pattern;
  fetch-full-by-item-id is trivial once 2.1 lands, and cacheable).
- **Guardrail:** a collapsed section must surface a failure badge if a tool inside
  it failed — collapse must never hide a bad run.
- **Offline policy:** recent turns hydrate full bodies quietly in the background;
  older history stays summary-until-tapped (preserves offline reading + the
  efficiency win). Note: Wave 1.2 already restored settled-reasoning auto-collapse
  + killed empty-box whitespace as an interim.
- Effort: **M** (mostly iOS render + a fetch-by-id route). Feel: **4** (snappier
  open + render; the owner's explicit ask).

**2.5 — Per-connection notification opt-out (bandwidth).** Add
`optOutNotificationMethods` / a `deltaMode: completedOnly` to the mobile
handshake so a backgrounded/low-signal phone can receive `item.completed` only and
stay correct (safe because completed is authoritative). Effort: **low**. Feel: **3**.

### What we explicitly do NOT copy from Codex
- Wire-level sequence numbers on the **core** stream (put seq/ack at the mobile
  edge only — 2.3).
- The full cloud relay/pairing/enrollment architecture — Codex needs it to NAT-
  traverse to a user's laptop; our gateway is directly reachable, so we need the
  reliability *semantics* (2.3) but not the relay.
- SQLite as source of truth — keep the durable log authoritative, caches rebuildable.
- Persisting streaming deltas — persist completed items only.

### Wave 2 sequencing
- **2.a (gateway + plugin, invisible to the owner):** 2.1 event model + 2.2
  resume-as-items + 2.3 edge replay. Ship + soak behind the existing client before
  the iOS render changes. This is the risky protocol layer; get it right first.
- **2.b (iOS render, the visible win):** wire ChatStore's reducer to item ids,
  2.4 collapsed working-sections, 2.5 opt-out. This is where the owner *feels*
  the difference.
- Probably 2 builds: gateway/plugin first (no visible change), then iOS render.

### Wave 2 acceptance (feel bar)
- Reconnect mid-turn → the half-written answer + in-progress tool line repaint
  instantly and continue; no dead air, no error flash.
- A long streaming answer stays smooth to the last token (no O(total) reparse —
  Wave 1's tail-cap plus item-scoped deltas make each flush O(delta)).
- Reopening a settled turn shows collapsed "worked for N min"; expand is instant
  (cached) online, and recent turns expand offline.
- Chaos test: kill the socket 10× mid-turn (XCUITest ws_flap) → transcript always
  reconciles to the authoritative completed items, byte-identical to a clean run.

---

## WAVE 3 — Cache-equals-truth + history depth (high-level)

Theme: make the offline replica **complete and provably consistent** with the
gateway — the second half of the owner's mental model ("no discrepancy between
local cache and gateway; a year of history readily available offline").

- **Server delta endpoint** (closes SMOOTHNESS-SPEC WS-4): `GET
  /sessions?updated_since=<cursor>` returning only changed rows + tombstones, and
  an O(tail) transcript delta route. The iOS client for this is **already built
  and currently 404s into a full refetch** — this is the missing server half. Kills
  the 30s full-list refetch tax (battery/data) and makes reconcile cheap.
- **Progressive history backfill on pairing** (owner ask #5): on connect, hydrate
  recent-first — last week lands in seconds and the app is usable immediately; the
  rest (months/a year of text) fills quietly via background `URLSession`.
  Attachments stay on-demand (the 256MB blob cache already caps this). NOT a
  blocking first-run download.
- **Local-first integrity (retire the NO-GO — the parked work).** This is the
  `SyncCoordinator` / authority-identity / manifest-v2 program currently parked
  under a standing NO-GO. Wave 3 is where it earns authorization: pass the A0/A1/B1
  proof gates (display lineage, bounded derivation, authority epoch, cursor roles,
  tombstones, cross-db convergence, asset atomicity, rollback safety) rather than
  leaving it parked forever. The owner's "cache = truth" vision and this spec are
  the same picture; it just needs its proofs done.
- **Windowed lazy scrollback from disk** (WS-5 completion): disk holds everything,
  memory holds a window; scrolling up pages from local cache (instant), never
  re-fetches from network, and never loses your place. (Correct model — NOT
  "keep a year in memory," which would bloat/crash.)

## WAVE 4 — Notifications, background freshness, presence (high-level)

Theme: the app is correct and fresh even when you're not looking at it, within
iOS's platform limits.

- **Notification truthfulness + resilience** (SMOOTHNESS-SPEC WS-3 remainder):
  per-token last-send status in Settings, retry/backoff on APNs sends, loud queue-
  overflow. (The two M0 fixes — attention gate + 4h APNs expiration — already
  shipped; this is the diagnostics + resilience tail.)
- **Background freshness within iOS limits**: tune BGAppRefreshTask /
  BGProcessingTask cadence + silent-push-driven cache updates so the cache is
  "approximately current" on foreground with a one-shot delta reconcile. (Honest
  framing: iOS does NOT allow a continuous background feed — no app gets this,
  WhatsApp included; the felt result is instant cache paint + fast catch-up.)
- **Drawer live-preview** (WS-6): foreign live sessions show the first line of the
  in-flight turn (throttled), so glancing at the drawer shows what every session is
  doing.
- **Live Activities / widgets polish**: semantic, revision-safe updates driven by
  the same item model.

## Cross-cutting / infra (fold in opportunistically)
- **ABH-370 durable fix**: the dashboard-supervisor provenance flap keeps recurring
  (dirty `package-lock.json` → child exit 78). Real fix: make dashboard startup not
  run `npm` against the workspace lock. Until then it needs manual restart.
- **Generated-file policy**: `.pbxproj` + 3 `Info.plist` are XcodeGen output but
  committed → merge conflicts + the CI drift that broke build #213. Decide: gitignore
  + generate in CI/Xcode Cloud (needs a look at `ci_scripts/` so the Xcode Cloud
  fallback isn't broken). CI already regenerates as of Wave-1 cleanup.
- **Fixed-sleep test de-flaking**: ~9 iOS test files use `Task.sleep`-tuned settle()
  helpers that occasionally lose CI-runner timing races. Convert to condition-polling.
