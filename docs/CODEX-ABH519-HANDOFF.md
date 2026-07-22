# Codex handoff — ABH-519: draft-born (new chat) sessions render blank on device

**Base:** `main` @ `81e49125d` (build 119). **Linear:** ABH-519 (P0), related ABH-516.
**Do NOT touch `main` or any dirty checkout.** Work in an isolated worktree from
`81e49125d` on a branch like `codex/abh-519-device-cache-root-cause`.

This doc is the corrected root-cause + plan from the 2026-07-22 audit. An earlier claim
("the build-119 cache write never executes on device") was an **argument from silence and is
withdrawn** — build 119 has no signposts, so absent logs prove nothing.

---

## Symptom (100% reproducible, build 118 + 119)

New chat → type → send. The gateway has the full turn (verified: session
`20260722_132545_73c180` returns 4 messages server-side), but the phone shows blank / the
reply vanishes after "Worked" / the new chat is absent from the drawer until force-close;
after force-close+reopen the wrong session loads showing random messages from other chats.

Device os.Logger trace (`idevicesyslog`, iPhone Air, ~13:25): the new session logs **7×
`open-latency cache-miss(reset)` and never a cache paint**, with **zero cache-write
signposts** — because build 119 has none to emit.

---

## Corrected root cause

**Build 119 turned an OPTIONAL cache into a CORRECTNESS DEPENDENCY, and its write path can
silently vanish or silently fail.**

1. Send path DOES reach the fix: `ChatStore.swift:2922` adopts the relay-created session →
   `landRelayCreatedSession` → `persistDraftBornCacheSeed` (`SessionStore.swift:4485`).
2. `persistDraftBornCacheSeed` **silently exits** if `cacheStore`/cache-identity is missing;
   its writes use `try?` (errors discarded); it runs in an **unstructured `Task`**
   (force-close beats persistence).
3. Production builds the cache with `try? CacheStore()` (`AppEnvironment.swift:235`) — a
   device DB **migration/open failure → `cacheStore == nil` with no error**. A physical
   phone's upgraded DB (116→119) ≠ the sim's fresh DB.
4. `cache-miss(reset)` clears only the **in-memory** transcript; it does NOT delete GRDB
   rows. So "the reset wipes the write" is also not the cause.

**Deeper architectural cause:** R4 removed the relay cache-miss history fallback on the
assumption that opening a relay session emits a snapshot — but relay `OPEN` returns history
**in its command result** (`relay/hermes_relay/downstream.py:884`) and the iOS open path
**ignores those returned messages**. So when the cache is unavailable/misidentified/
write-failed: cache paint misses → history fallback disabled → no authoritative transcript
to render, though the gateway holds the complete turn. **This violates INTERACTION-CONTRACT
I14** (`docs/INTERACTION-CONTRACT.md`), which permits one relay history read on cold
cache-miss.

## Why every simulator test passes (the harness gap)

`ContractDraftBornW4bTests.swift:78` builds a **fresh temp DB, manually attaches a valid
cache, manually supplies the server identity** — bypassing production `CacheStore()` init,
real 116→118 DB upgrades, the silent `try?` in AppEnvironment, real pairing/identity
construction, and process termination before the detached write finishes. The force-close
test even awaits persistence and reuses the same CacheStore actor — not a real restart.
(Four device builds 116→119 "fixed" new-chat with green gates and all failed on device for
this reason.)

---

## Plan (diagnostic-first — do NOT ship a 5th blind patch)

### Step 1 — diagnostic commit only (no fix)
- Log production `CacheStore()` init success/error (`AppEnvironment.swift:235`).
- Log entry + each guard-exit in `persistDraftBornCacheSeed` (`SessionStore.swift:4485`).
- Replace the two diagnostic `try?` calls with `do/catch` logging.
- Log the cache identity + `hasTranscript` result at the `cache-miss(reset)` site.
Install on the physical iPhone Air (UDID `1D51F2FB-1DB2-52BF-818B-EFD2ACE7C0E7`), capture one
new-chat send, and identify the exact failing line.

### Step 2 — narrow correction (tens of lines, not a new subsystem)
- Fix the actual failing path (cache init / migration / identity / write).
- **Restore the existing relay-history fallback on a GENUINE cold cache-miss (I14).** Cache
  HITs must remain zero-network opens. Relay `OPEN` already returns history in its result
  (`downstream.py:884`) — consume it, or issue the one permitted history read.
- Order/await the draft-born persistence instead of an untracked `Task`.
- Keep cache failure **non-fatal** — relay history is the correctness fallback.

### Acceptance evidence
`created sid → successful cache write → next open cache-paint(HIT) →
force-close/reopen paints the same sid from disk`. **Plus:** a deliberately-unavailable-cache
run performs **exactly one history fetch and never paints messages from another session.**

### Harness fix (prevents the four-build pattern)
The iOS test that exercises this must run against a **migrated device-shaped DB** (upgraded
116→119), not a fresh one — otherwise it keeps passing while hardware fails.

---

## Guardrails
- Isolated worktree from `81e49125d`; never `main` or a dirty checkout. No merge without
  device-capture proof of the acceptance evidence above. Small commits.
- iOS builds via `scripts/ios-build.sh` (machine mutex; SIGTERM never `kill -9`). Swift 6
  strict. Never test against the live gateway `9119` except read-only health; isolated
  gateways `9130+`.
- Key files: `apps/ios/HermesMobile/Stores/SessionStore.swift` (persistDraftBornCacheSeed),
  `Stores/ChatStore.swift` (:2922 adopt), `App/AppEnvironment.swift:235` (CacheStore init),
  `Cache/CacheStore.swift` + `Cache/CacheSchema.swift` (GRDB), `relay/hermes_relay/downstream.py:884`
  (OPEN returns history), `docs/INTERACTION-CONTRACT.md` (I14, I3, I5, I20).
