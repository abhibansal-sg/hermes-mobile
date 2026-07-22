# Codex handoff — ABH-519 round 2: transcript persistence + foreign-session staleness (build 120)

**Base:** `main` @ `f98610f9f` (build 120, live on the iPhone Air + relay redeployed). **Linear:** ABH-519 (P0, In Progress), related ABH-516, ABH-401.
**Work in an isolated worktree from `f98610f9f`. Do NOT touch `main`, the live relay, or a dirty checkout.**

Round 1 (your fix, commits `ca8fb56ab` diagnostics + `1723a4a51` "preserve durable id for relay-created chats") **worked** and is device-accepted: the original draft-born **blank**, the **cross-session bleed**, and user-message persistence are fixed. Owner QA on build 120 confirms the user's message survives switch + force-close, and there is **no bleed**. But a **narrower, adjacent transcript-persistence bug** surfaced. **The root cause below is now CONFIRMED in code (independent trace, file:line).** Round 2 is: fix the device-evidence channel, instrument to reproduce on device, apply the small fixes, prove on device.

---

## Symptoms — owner device QA, iPhone Air, build 120, 2026-07-22 (verbatim)

**New chat → "hi" → send:**
- **S-A (render collapse):** on turn finish, **"everything collapses under work"** — the assistant reply is folded *inside* the collapsed working/tool section, possibly with no standalone reply bubble.
- **S-B (assistant not persisted):** switch to another chat and back → **user "hi" is still there, but the "work" section AND the reply are gone.** Only "hi" remains.
- **S-C:** force-close + reopen → same: only "hi".

**Foreign / desktop-driven session (NEW):**
- **S-D (foreign transcript staleness):** owner opened a session he's driving from the **desktop app**. Drawer shows correct fresh activity ("3 minutes ago"), but the transcript shown is **days old** — the ongoing conversation is missing. Timestamp updates; transcript never refreshes. Force-close doesn't help.

**Other:**
- **S-E (dead affordance):** "Load earlier messages" tap is a **no-op**.
- **S-F (4007 on switch):** switch surfaced `4007` = `JSONRPC.sessionNotFound`, then "recovered" and loaded the right session.

---

## Device-evidence status — READ THIS (the recurring trap)

**No usable device trace exists yet.** `idevicesyslog -u <udid>` (and `-p HermesMobile`) produced only connection churn (6 lines) across two attempts — it does **not** stream this app's `os_log`, because the ABH-519 signposts are `.info`/`.debug` level and `idevicesyslog` silently drops those (streams only `.default`/`.error`/`.fault`). **This is the mechanical reason four builds passed lab gates and failed on device.** Fix the channel first — pick ONE:
1. macOS `log stream`/`log collect` targeting the device (Console.app with Info+Debug, or `sudo log collect --device --last 5m`).
2. Temporarily raise the ABH-519 signposts to `.default`/`.error` in the instrumented build.
3. Write a debug log file into the app container; pull with `xcrun devicectl device copy from …`.

Device UDID (idevice/log tools): `00008150-000911CA0240401C`. devicectl id: `1D51F2FB-1DB2-52BF-818B-EFD2ACE7C0E7`.

---

## CONFIRMED root cause (independent code trace, file:line)

Cache = `session_cache` + `message_row_cache` (GRDB), keyed by `(serverId, profileId, sessionId)`; only `userMessage`/`agentMessage` **text** rows are cached (tools/reasoning deliberately never cached — I3). Fixing **Q1** restores the most: the reply survives switch-back even while the 4007 resume still fails.

### Q1 — assistant completion is never written to the phone cache [PRIMARY, CONFIRMED]
- The draft-born **seed writes only the user row**: `persistDraftBornCacheSeed` → `saveTranscript(identity:, messages:[userRow])` (`SessionStore.swift:4572-4574,4589`). By design — it's a seed.
- The **relay turn-completion seam persists nothing**: `.turnCompleted` (`RelaySessionCoordinator.swift:648-668`) → `chatStore.notifyRelayTurnCompleted` (`ChatStore.swift:5776`) → `settleRelayTurn` (`ChatStore.swift:5757-5768`) is turn-flag bookkeeping only. **No `saveTranscript`/persist call on the completion path.**
- The **only** relay→cache assistant writer is LRU eviction: `persistRelayEntryWriteThrough` (`SessionStore.swift:3758-3777`, filters to user/agent items :3762-3768), called solely from `relayEntryEvictedWriteThrough` (`ChatStore.swift:1829-1831`) ← `evictSettledInactiveEntries` gated `guard entries.count > 8` (`RelaySessionCoordinator.swift:762-770,140`). A fresh draft-born session (≤8 entries) **never evicts → never persists the assistant row.**
- **Key mismatch (second, independent bug):** even on eviction, the entry is keyed by the **runtime** id — `adoptCreatedSession` does `touchEntry(runtimeID)` (`RelaySessionCoordinator.swift:939`) — so the write lands under the runtime key while every `open()` reads under `activeStoredId` (**stored** key). Write and read miss.
- **Why switch-back shows only "hi":** `open()` phase-1 cache read HITs the user seed → `paintedFromCache=true`, then `if transportPath == .relay, paintedFromCache { return }` (`SessionStore.swift:6008`) short-circuits **before** the I14 relay-history re-fetch. So nothing re-pulls the reply.
- **Smallest fix:** at turn-settle, write-through the ACTIVE session's items under the **stored** key — in `settleRelayTurn` (completed branch, `ChatStore.swift:5757`) or `.turnCompleted` (`RelaySessionCoordinator.swift:648`), call the existing `persistRelayEntryWriteThrough` with `sessions?.activeStoredId` and `entries[activeSessionID]?.store.items`. Do at settle what today only happens at eviction, under the stored key. Reuses the existing CacheStore path — no new persistence code. (Depends on Q2: that writer only persists `agentMessage`-typed items, so the completion must be correctly typed.)

### Q3 — 4007 sessionNotFound on switch [CONFIRMED mechanism + a round-1 regression]
- `JSONRPC.sessionNotFound = 4007` (`Models/JSONRPC.swift:106`) is **never caught** in iOS → propagates as `RelayError.rpc(4007)`.
- Switch-back resumes by the **stored** id: `bindRelayRuntime` → `coordinator.resume(summary.id)` (`SessionStore.swift:4275`). In `resume` (`RelaySessionCoordinator.swift:975-997`) the warm shortcut misses (entry keyed by runtime id), so it always issues `client.resumeSession(storedID)` + `touchEntry(storedID)` — creating a **fresh empty entry and orphaning the runtime entry that holds the assistant items** (`:986-988,727-733`). The relay forwards `session.resume(stored)` (`downstream.py:1029-1037`) and the gateway raises 4007 (proxied via `gateway_client.py:94-99,450`).
- **Contributing REGRESSION (confirmed code removal):** your narrow-correction `1723a4a51` deleted the one-shot `_ = try? await client.open(sessionID)` seed-bind from `adoptCreatedSession`/`adoptPendingSession`/`reestablishDrivenSession`, leaving only `setForeground(runtimeID)`. Contract I5/R4b(b) **requires** that open ("the created sid IS an OPEN edge … the relay's open seeds its store so every later resync snapshot carries the prompt", `docs/INTERACTION-CONTRACT.md:450-453`). Without it the stored id is never seeded → `resume(stored)` finds nothing → 4007.
- **The "recovery" is not resume recovery:** `open()`'s `seedTask` cache paint (`SessionStore.swift:4064-4079`) is independent of `bindRelayRuntime` — the user row paints regardless; the resume error is classified non-retryable (`:4336`) and the I14 fallback is NOT reached (cache HIT short-circuits at :6008). So "loaded the right session" = the user-row cache paint only.
- **Smallest fix:** restore the R4b(b) `client.open` seed-bind the narrow correction removed, OR make `coordinator.resume` register the warm runtime entry under the stored key so switch-back re-projects the parked items instead of re-issuing `resumeSession(stored)`. (Secondary to Q1 — Q1's cache fix makes the reply survive even while 4007 persists.)

### Q2 — assistant text folds into the working collapse [HYPOTHESIS, downstream of Q1/Q3]
- The fold logic is **correct** for well-formed turns: `.text` (from `agentMessage`) is not work-eligible (`WorkingSectionView.swift:161-242`; `Models/ChatItem.swift:213,220`), so a normal `[user, reasoning, tool, agentMessage]` renders the answer standalone.
- It folds only if the final `agentMessage` is left generically typed `.toolCall`: `RelayItemStore.applyDelta` materializes an **unseen-item delta as `.toolCall`** (`Networking/Relay/RelayItemStore.swift:252-260`, esp. :256); if the authoritative `started`/`completed` frame that would heal it to `agentMessage` (`:216-220,265-268`) is dropped/late during draft-born id churn, the answer stays `.toolCall` → folded, with no `.text` node → "Worked for N seconds" with the reply inside. Same missing-completion-frame fragility as Q1/Q3.
- **Smallest fix (defensive):** in `applyDelta`, materialize an unseen-item delta carrying assistant `text` as `.agentMessage` not `.toolCall` (`:256`); and/or never fold a trailing `.text` run in `renderNodes`. Durable fix is frame-delivery integrity (Q1/Q3).

### S-D (foreign staleness) and S-E (dead "load earlier") — still to confirm
S-D is the same class as Q1 for a foreign session: the cache HITs a stale window and the `:6008` short-circuit skips the I14 reconcile, so the live transcript is never pulled. Confirm the open/reconcile decision treats a **stale/short cache HIT** for a foreign (not-owned) session as still needing exactly one reconcile against the server head. S-E: the "Load earlier" handler is a no-op under windowed loading (related ABH-401) — separate, lower priority.

---

## Plan (root cause confirmed → still device-prove before merge)
1. **Fix the evidence channel** (above) — non-negotiable Step 0.
2. **Instrument + reproduce on device:** signposts at the turn-settle persist call + the key used (stored vs runtime), the `:6008` short-circuit decision (HIT/miss/stale-HIT → fetch?), and the 4007 raise. Owner runs new-chat→hi→send→switch→back→force-close→reopen, then opens the desktop-driven session.
3. **Apply the small fixes:** Q1 (turn-settle write-through under stored id) first, then Q3 (restore the `client.open` seed-bind), then Q2 (type-heal the unseen-item delta), then S-D (reconcile on stale-HIT for foreign sessions), then S-E.
4. **Acceptance (device trace required):** reply renders as its own bubble; switch-away/back and force-close/reopen paint reply+work from cache; a foreign desktop-driven session paints the CURRENT transcript (exactly one reconcile on stale-HIT); session switch = zero 4007s.
5. **Harness:** extend the migrated-DB test to persist + repaint a FULL turn (user + assistant + tool rows), not just the seed; add a foreign-session stale-HIT-reconcile store test. Run against a migrated device-shaped DB.

## Guardrails
- Isolated worktree from `f98610f9f`; never `main`/live relay/dirty checkout. No merge without a **device-capture proof** of the acceptance evidence. `scripts/ios-build.sh` (machine mutex; SIGTERM never `kill -9`), Swift 6 strict; isolated gateways `9130+`, never live `9119` except read-only health. Small commits.

## Files of record (from the confirmed trace)
- `Stores/SessionStore.swift` — persistDraftBornCacheSeed :4530-4598; persistRelayEntryWriteThrough :3758-3777; bindRelayRuntime :4252-4323; cache-miss short-circuit :6008; I14 fallback :6363-6371.
- `Stores/ChatStore.swift` — settleRelayTurn :5757-5768; notifyRelayTurnCompleted :5776-5789; relayEntryEvictedWriteThrough :1829-1831; send/adopt :2921-2961.
- `Stores/RelaySessionCoordinator.swift` — adoptCreatedSession :931-951; resume :975-997; evictSettledInactiveEntries :762-770; moveWriteGate :727-734.
- `Networking/Relay/RelayItemStore.swift` :238-268; `Views/Chat/WorkingSectionView.swift` :161-242; `Views/Chat/MessageBubble.swift` :558-611,709-716; `Models/JSONRPC.swift:106`; `Models/ChatItem.swift:208-222`.
- `relay/hermes_relay/downstream.py` :886-994,1029-1037; `relay/hermes_relay/gateway_client.py` :508-550,94-99,450.
- `docs/INTERACTION-CONTRACT.md` I3 :418-423, I5/R4b :433-457 (required open/seed-bind :450-453).
- Codex diffs: `git show 1723a4a51` (id-split + **removal of `client.open` seed-bind**), `git show ca8fb56ab` (instrumentation).
