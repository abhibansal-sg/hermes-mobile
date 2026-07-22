# Codex handoff — ABH-519 round 2: transcript persistence + foreign-session staleness (build 120)

**Base:** `main` @ `f98610f9f` (build 120, live on the iPhone Air + relay redeployed). **Linear:** ABH-519 (P0, In Progress), related ABH-516, ABH-401.
**Work in an isolated worktree from `f98610f9f`. Do NOT touch `main`, the live relay, or a dirty checkout.**

Round 1 (your fix, commits `ca8fb56ab` diagnostics + `1723a4a51` "preserve durable id for relay-created chats") **worked** and is device-accepted: the original draft-born **blank**, the **cross-session bleed**, and the user-message persistence are all fixed. Owner QA on build 120 confirms: the user's message now survives switch + force-close, and there is **no bleed**. But a **narrower, adjacent set of transcript bugs** surfaced. This doc scopes them for a diagnostic-first round 2.

---

## Symptoms — owner device QA, iPhone Air, build 120, 2026-07-22 (verbatim)

**New chat → "hi" → send:**
- **S-A (render collapse):** when the turn finishes, **"everything collapses under work"** — the assistant's final reply is folded *inside* the collapsed working/tool section instead of rendering as its own assistant message bubble. There may be no standalone reply bubble at all.
- **S-B (assistant not persisted):** switch to another chat and back → **the user's "hi" is still there, but the "work" section AND the reply are gone.** Only "hi" remains.
- **S-C:** force-close + reopen → same as S-B: only "hi" survives; no work, no reply.

**Foreign / desktop-driven session (NEW, important):**
- **S-D (foreign transcript staleness):** owner opened a session he is actively driving **from the desktop app**. The **drawer shows the correct fresh activity ("3 minutes ago")**, but opening the session shows a **transcript that is days old** — the current, ongoing conversation is missing. The last-activity timer updates correctly; the **actual transcript never refreshes to the live one.** Force-close + reopen does not help — only his own message shows, no work/reply.

**Other:**
- **S-E (dead affordance):** the **"Load earlier messages"** control at the top of the transcript — **tapping it has no effect** (no-op).
- **S-F (4007 on switch):** during a session switch the app surfaced a **`4007` = `JSONRPC.sessionNotFound`** (`apps/ios/HermesMobile/Models/JSONRPC.swift:106`), then recovered and loaded what looked like the right session.

**Unifying observation:** the round-1 fix persisted the *draft-born seed* (session row + user message row). Everything that comes AFTER or FROM the server — the assistant completion, the tool/work items, and the live transcript of a foreign session — is **not making it into the GRDB cache**, so any rebuild-from-cache (switch-back, cold reopen) shows only the locally-seeded user message. S-D shows the same class of bug for foreign sessions: the cache holds a stale window and is never reconciled to the live transcript even though the drawer metadata is.

---

## Device-evidence status — READ THIS (the recurring trap)

**I could not capture a usable device trace.** `idevicesyslog -u <udid>` (and `-p HermesMobile`) produced only connection churn (`[connected]` / `Exiting...` / `[disconnected]`, 6 lines total) across two attempts — it did **not** stream the app's `os_log` output at all. Cause is almost certainly that the app's signposts are emitted at `.info`/`.debug` level, which **`idevicesyslog` silently drops** (it reliably streams only `.default`/`.error`/`.fault`), compounded by an unstable USB syslog relay on this Mac.

**This is the exact reason four builds "passed" and failed on device.** Before diagnosing, fix the evidence channel — pick ONE:
1. **`log stream` / `log collect` from macOS** targeting the device (Console.app "Include Info/Debug Messages", or `sudo log collect --device --last 5m`) — captures `.info`/`.debug` os_log that idevicesyslog misses.
2. Temporarily **raise the ABH-519 signposts to `.default` (or `.error`)** in the instrumented build so idevicesyslog *does* stream them.
3. Have the instrumented build **write a plain debug log file into the app container** and pull it with `xcrun devicectl device copy from ...` after the run.

Do not ship a fix without a device trace of the persist path — same bar as round 1.

---

## Candidate root causes (HYPOTHESES — confirm in code before fixing)

The cache is `session_cache` + `message_row_cache` (GRDB, `Cache/CacheStore.swift` + `Cache/CacheSchema.swift`), keyed by `(serverId, profileId, sessionId)`; a "run" is stored as multiple role-rows, each `rowJSON` a full `StoredMessage`, reassembled to interleaved parts at render.

- **H1 — assistant/tool completion never persisted for relay-created (and foreign) sessions [PRIMARY].** Round 1 wired `SessionStore.persistDraftBornCacheSeed` (~`SessionStore.swift:4485`, called from `ChatStore.swift:2922` → `landRelayCreatedSession`) to write the session + the *user* row. Trace the **turn-completion → cache-write** path (`ChatStore` reconcile / `applyRelayItems` / backfill / persist seams + `SessionStore`) and find why the **assistant completion + tool/work rows are not written to `message_row_cache`** for these sessions. Prime suspects: (a) the completion write is keyed to the **runtime** `session_id` while the seeded rows are keyed to the **stored** id (your round-1 split) → writes land under a key nothing ever reads, or are dropped; (b) persistence is only wired for the seed, not for subsequent turn items; (c) the cache-identity used at completion time isn't re-derived for a session that was born mid-turn.

- **H2 — assistant final text renders inside the working collapse.** In the RelayItemStore→ChatStore merge (item.started/delta/completed → parts → bubbles), the completed **assistant text item is grouped with the working/tool items instead of promoted to a standalone bubble.** Related to the QA-3 "untagged assistant twin" seam (`applyRelayItems` merge). May share a root with H1 (if the completed assistant item is mis-tagged, it's neither rendered as a bubble nor persisted as an assistant row).

- **H3 — foreign session: cache HIT on a stale window, never reconciled (S-D).** For a session driven elsewhere (desktop), the phone paints the **stale cached transcript** and does **not** fetch/reconcile the live one. The drawer's last-activity updates (session list fetch) but the **transcript reconcile/history read never fires** — likely because the cache "HIT"s on an old window (not a miss), so the I14 one-history-read is skipped. Check the open/reconcile decision (`RelaySessionCoordinator` + `ChatStore` reconcile owner, `docs/INTERACTION-CONTRACT.md` I14) — a HIT on a stale/short window should still trigger exactly one reconcile against the server head.

- **H4 — 4007 on switch = runtime/stored id mismatch (S-F).** Find every raise/handle of `JSONRPC.sessionNotFound` (4007). On switch, confirm whether the phone opens/resumes by the **runtime** id when the gateway only knows the **stored** id (or vice versa) — a consequence of the round-1 two-id return from `relay/hermes_relay/gateway_client.py` `session_create`. Confirm the recovery path (I14 fallback) and make the open use the correct id so 4007 doesn't surface.

- **H5 — "Load earlier messages" tap is a no-op (S-E).** The load-earlier affordance under windowed transcript loading has no working handler (related to ABH-401 jump/paging under the newest-N window). Lower priority than H1/H3 but user-visible.

---

## Plan (diagnostic-first — do NOT ship a blind patch)

**Step 0 — fix the evidence channel** (see above). Prove you can see the app's persist/reconcile signposts on device.

**Step 1 — instrument only (no fix).** Add signposts (at a level idevicesyslog OR your chosen channel captures) at: the turn-completion cache-write call + each guard/skip; the key each row is written under (stored vs runtime id) and the key each read/paint uses; the open/reconcile decision (HIT vs miss vs stale-HIT → fetch-or-not); the 4007 raise + recovery. Install on the iPhone Air (UDID `00008150-000911CA0240401C`; devicectl id `1D51F2FB-1DB2-52BF-818B-EFD2ACE7C0E7`). Owner runs: new chat → hi → send → switch away → back → force-close → reopen; then open the desktop-driven session. Identify the exact failing lines.

**Step 2 — narrow corrections.** Fix H1 first (persist assistant + tool rows under the same key the paint reads — the id the transcript is keyed by), then H2 (promote completed assistant to a bubble), then H3 (reconcile once on a stale-HIT for foreign sessions), then H4 (open by the correct id), then H5. Keep cache failure non-fatal; relay history is the correctness fallback (I14). Small commits.

**Acceptance evidence (device trace required):**
`new chat → send → assistant reply renders as its own bubble → switch away/back paints reply+work from cache → force-close/reopen paints the full turn from disk`. **Plus:** opening a **foreign desktop-driven session** paints the **current** transcript (exactly one reconcile fetch on a stale-HIT), and a session switch performs **zero** 4007s.

**Harness:** extend the migrated-DB test to persist + repaint a **full turn (user + assistant + tool rows)**, not just the seed; add a foreign-session stale-HIT-reconcile store test. These must run against a migrated device-shaped DB.

---

## Guardrails
- Isolated worktree from `f98610f9f`; never `main` / live relay / dirty checkout. No merge without a **device-capture proof** of the acceptance evidence above.
- iOS builds via `scripts/ios-build.sh` (machine mutex; SIGTERM never `kill -9`). Swift 6 strict. Isolated gateways `9130+`; never the live gateway `9119` except read-only health.
- Key files: `Stores/SessionStore.swift` (persistDraftBornCacheSeed + the completion persist path), `Stores/ChatStore.swift` (:2922 adopt, applyRelayItems/reconcile/backfill), `Stores/RelaySessionCoordinator.swift` (open/resume/reconcile owner, id selection), `Cache/CacheStore.swift` + `Cache/CacheSchema.swift`, `Models/JSONRPC.swift:106` (4007), `relay/hermes_relay/gateway_client.py` (session_create two-id split), `relay/hermes_relay/downstream.py:884` (OPEN returns history), `docs/INTERACTION-CONTRACT.md` (I3 echo, I5 draft-born, I14 cache-miss/stale reconcile).
