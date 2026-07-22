# ROUND-4 LEAN PLAN — relay-only rewire + deletion, revised

**Inputs:** INTERACTION-CONTRACT.md (I1–I23), Matrix A/B, desktop study, plugin-route audit.
**Mandate:** LESS code. Every addition justifies itself against a deletion; every rewire
lane deletes its own compensation in the same lane; the app is never broken mid-migration.
Tree refs: `qa3-base` @ `c44e7f8d9`.
**Amended (Opus review, 2026-07-22):** the binding amendments are folded INLINE (see
`amendment` markers): G1 (expireRelayPendingGates-on-switch deleted outright in R1), G2
(lane L6 added; X5 moved from W3a to the after-L6 gate), A1 (I7/I19 void geometry → W0b
UI-level tests), G3 (I23 + W0a fixture), G4 (ord adoption replaces twin-consumption in R1),
I9-gate (W0a RED-BY-DESIGN), W0-determinism (virtual clock + cancel-spy), S1 (fork-arm
collapse → Wave 4; device soak is the real Wave-3 gate), S2 (fallback illusory — risk
register), S4 (drift split in R2/I5/I11/RR9), L5-lean (L5 dropped; projects stay on control
REST — §projects decision).

**Scope decision (binding, from audit §4 + contract preamble):** "relay-only" = sole
**chat/turn/transcript/session-list** transport. The gateway REST control plane
(model/providers/personality/skills/cron/webhooks/fs/devices/usage — gaps 4–9, 12) STAYS
REST. Building 30–40 relay RPCs for Settings panels is the opposite of the mandate. This
decision caps the relay-side work at 5 small lanes and protects ~2,500 lines of control REST
from pointless churn. `APIPathStyle` (Axis P) is NOT deleted with Axis T — it routes the
surviving control surface.

**Projects decision (binding, amendment L5-lean):** projects (overview + detail session
list) stay on the gateway REST control plane PERMANENTLY; lane L5 (relay `projects`
pass-through) is DROPPED. The contract (B10) shows projects data is request/response reads —
a near-static cwd list + a cwd-scoped session list — with NO live-streaming requirement, so
a parallel relay projects path while REST projects survives is exactly the
duplicate-transport anti-pattern the mandate forbids. The one projects fix that survives is
the `cwd` pass-through on relay SUBMIT-create (absorbed into L2 — the B10
new-session-in-project gap). GW-UNREACH projects = cache paint + honest unavailable state —
a recorded limitation in contract B10, revisited only if projects ever need live updates.

---

## (a) The 5 baseline rewires — confirmed / amended

### R1 — Session-scoped item store → **CONFIRMED, AMENDED (bigger win, same size)**
Baseline: `ingest` drops `frame.sid != activeSessionID`; store reset becomes a swap.
**Amendment (desktop §3 write-gate):** don't drop — **route**. Frames for a non-active
session fold into THAT session's map entry (bounded LRU ≤8); only the active entry projects
(contract I1/I2). Dropping would lose a background turn's completion until refetch; routing
buys zero-refetch switch-back (I14) for ~40 more lines than drop. This converts three
baseline deletions from "becomes structural" to "cease to exist":
- `resetItemStoreForSessionSwitch` (RSC:740-757) — swap is a pointer move; the manual
  task/LA clears delete (I2/I15 move them to the write-gate), and the switch-time gate
  expiry (`expireRelayPendingGates` at RSC:748-751) deletes OUTRIGHT — not moved anywhere:
  gates MOVE with their owning session and expire only on turn end or explicit answer
  (contract A13/I12, amendment G1).
- `projectionSuppressed` / `suppressProjectionForDraft` / `resumeProjection` (RSC:123-162,
  459-467) — a draft is the absence of an entry (I6); there is nothing to suppress.
- `endRelayTurnForSessionSwitch` discard dance (CS:1686-1691) — LA ownership follows the
  write-gate.
**Size:** +~250 (map + routing + LRU) / −~420 (reset dance 60, suppression 55, switch-LA 40,
fuzzy text adoption 120 [I8 kills the text fallback; cmid match stays], twin-consumption
fuzzy half ~80 of CS:5399-5424 [id-union core stays, heuristics die — amendment G4 makes
this free: cmid adoption assumes the SERVER item's ord (contract I7/I8), so the echo IS the
user row and there is never a twin to consume], D3-window gate bleed plumbing ~65).
**Net −170. Kills D3, the I2/I8/I13 cross-session family, S11 permanently.**

### R2 — Draft submit + projection → **CONFIRMED, SHARPENED (smaller than baseline)**
Baseline: `sessionID ?? (isDraft ? nil : activeSessionID)` + call `resumeProjection()` on
create-adoption. **Amendment (desktop §4, contract I5):** the rule is simply
`target = selectedStoredID` — nil when nothing is selected. The `isDraft` test is not needed
on the wire path because `startDraft` already nils the selected stored id; once R1 deletes
projection suppression there is no `resumeProjection` to call — the create-adoption makes an
entry and moves the write-gate to it (one code path, not a flag + a patch). Adds the
desktop rules the baseline missed, with the drift rule SPLIT (amendment S4):
**drift-abort** re-checks the pinned target after the submit await — drift on an
EXISTING-SESSION pin ⇒ the send converts to a durable queue row against the PINNED id
(mobile keeps durability where desktop drops; I11 asserts both branches); drift on a
DRAFT/nil-target pin ⇒ drop the echo, never redirect — and **orphan-create close** (switch
during create ⇒ close the just-created session). Also fixes **D10 for free**: a
queued new-session row drains via SUBMIT-nil (relay create, DS:759-763) — the
`.creatingDestination` → gateway `session.create` path (AE:127-130, SS:4435-4446) deletes.
**Size:** +~60 (pin/drift-check ~35, orphan close ~25) / −~180 (fallback logic + draft
retain 30, destination-create path 60, durable-echo re-key on land CS:2763-2767 ~35 [I8:
one identity re-homed at adoption, not re-keyed], frozen-caret stage-2 dump RSC:584-587 ~20,
suppression overlap with R1 ~35). **Net −120. Kills D2, I4, D10.**

### R3 — Single reconcile owner → **CONFIRMED, DESKTOP-TIGHTENED**
Baseline: relay snapshot as sole authority; drop phase-2 REST seed + relay-mode backfill.
**Amendment (desktop §2, contract I14):** replace blanket backfill with the exact desktop
rules — (1) stream authoritative; (2) gap-fill once per turn end **iff the stream delivered
no payload** (`shouldHydrate`); (3) on reconnect, resync replay + ≤1 snapshot of the visible
session; (4) zero RPC on re-opening the active entry. The relay `history` RPC is not deleted
— it BECOMES the seeding source (gap 3 rewire: `RelayItemStore` wired to `open`/`history`,
deleting `RestClient.messages/messagesDelta`, RestClient+Sessions:420,457). Adds one small
item baseline missed: **RPC-cancel superseded seeds** (openToken currently fences only the
result, SS:4208-4211 — I4).
**Size:** +~90 (gap-fill-once rule 60, RPC-cancel 30) / −~640 (phase-2 network seed relay
branch SS:5808-5853 ~110, `backfill()` storm call-sites + guards: foreground ConnS:3319,
reconnect 3150, broadcast_gap 2221-2228, foreign watchdog CS:5549-5557, concurrency guards
CS:4733-4749 ~330 total, REST transcript fetchers ~150, double-resume on cold open
ConnS:1644-1648 ~50). **Net −550. Kills D1, D5, D6, D8's fetch half; I1/I2/I9/I12 storms.**

### R4 — Kill the gateway-direct loop in relay mode → **CONFIRMED VERBATIM, RE-SEQUENCED**
No amendment to content (contract I13 = baseline exactly: gate `startLongLivedTasks`,
scene-phase probe, `startReconnectLoop`, NWPathMonitor kicks). **Sequencing amendment:** this
is the only rewire that ships as **three 1-line guards FIRST (Wave 2a, day 1)** because D4/D7
are the only rewires actively TEARING DOWN live turns on the daily-driver phone today
(A11 headline: every bg→fg mid-turn nils `activeRuntimeId`, kicks a gateway connect, stamps
"Connection lost" on healthy relay turns). The guards are transitional; Wave 4 deletes the
whole machinery they gate. **Size:** +3 / −0 at Wave 2a; the −~650 lands in Wave 4.

### R5 — Relay-native liveness for non-local turns → **CONFIRMED + ONE CRITICAL ADD**
Baseline: baseline the clock on `turn.started`/snapshot-with-in-progress; fix the arming
gap (RSC:473 vs CS:5429 ordering). **Add (Matrix B §4 gap, contract I10):** stage-2
provisional settle must NOT fire `onTurnComplete`'s queue drain — it ends LA + gates only.
Today a false-positive settle drains a queued prompt into a still-running gateway turn
(4009 churn, self-heals but visible). Two lines: the provisional path calls the
LA/gate-expiry half of the turn-end seam, not the drain half. This pairs with L3 (relay
stamps `reason` on `turn.completed`) so **stopped ≠ completed** (contract I9): user stop's
`turn.completed{reason:interrupted}` does not drain either — replacing the partial
`relayTurnTerminatedByError` latch (CS:5441-5465) with a wire-truth field.
**Size:** +~70 (baseline sites 30, arming fix 15, drain-split 25) / −~60 (error latch 30,
foreign-turn special cases 30). **Net +10 — the only rewire that isn't net-negative,
justified by killing the eternal-working family (S8/D11/D12) and the stop-drains-queue
semantic bug, which no deletion wave reaches.**

**Verdict: all 5 confirmed; 3 amended to be leaner and more correct; none rejected. Net of
rewires alone: ≈ −830 iOS lines before any deletion wave.**

---

## (b) Relay-only deletion: additions to the delete list + relay gaps as RPC lanes

### Additions the audit puts on the delete list (beyond the baseline ~12 layers)

| # | Delete | Lines | Gate (what must be true first) |
|---|---|---|---|
| X1 | `Networking/HermesGatewayClient.swift` (whole) | 575 | Wave 4 (R4 done, zero call sites) |
| X2 | `Networking/WSURLBuilder.swift` (whole) | 245 | Wave 4 |
| X3 | `Models/GatewayEvent.swift` (whole) | 110 | Wave 4 (handle(event:) gone) |
| X4 | ChatStore `handle(event:)` + `handle*` ingestors (738-2083) | ~1,300 | Wave 4 |
| X5 | Foreign-mirror subsystem (`streamingIsForeign`, `mergeForeignUserRows`, `foreignMirrorWatchdog`, telemetry; 1051-1132, 4738-4786, 5531-5572) | ~250 | **after-L6 gate (amendment G2, moved out of W3a):** L6 green + I1/I7 cover foreign `userMessage` rendering (relay liveness R5 covers foreign-turn liveness; L6 covers the missing foreign user ROW) |
| X6 | ConnectionStore gateway machinery: `startReconnectLoop` (2608-2760), `recoverActiveSession` (3054-3167), `autoUpgradeToDeviceTokenIfNeeded`, `probeLiveness`/`probeIsAuthRevoked`, gateway configure fork (1510-1538, 1561-1564), grace escalation (2455-2463), `client` property | ~650 | Wave 4 (R4 guards removed with the gated code) |
| X7 | SessionStore gateway-direct resume task + runtime-bind arms (4035-4090+, 4664/4674/5862/6168) | ~450 | Wave 4 + L1 (drawer rides relay LIST) |
| X8 | `RestClient+Sessions` `messages`/`messagesDelta` | ~150 | R3 done (relay open/history seeded) |
| X9 | PushRegistrar REST poster + path resolution (490-508, makePoster) | ~120 | Wave 4 (relay push.register is live, S13 registry converges) |
| X10 | InboxStore `handle(event:)` ingest (262-293) | ~60 | Wave 4 (relay gate frames + `rest.pendingAttention` cover it) |
| X11 | Settings transport toggle + relay-URL field (137-140, 669-691); `transportPath` reader + all 9 ChatStore fork sites collapse to the relay arm | ~40 + ~150 arms | Wave 4 (contract B11: toggle deleted outright) |
| X12 | `prefetchRecentTranscripts` (SS:2270-2415) | ~150 | R3 + gap-3 seeding warms cache (audit §4 ordering rule) |
| X13 | Baseline-12 survivors not claimed by R1–R5: `waitUntilOpen` duplicate (bind AND resumeActive, SS:4200-4207, 4791-4798 → one seam), immediate→outbox echo swap (CS:2783-2816), `relayTurnLive` flag collapse to item-state+edge (CS:5297-5306) | ~130 | R1/R2/R3 lanes absorb them |
| X14 | `ServerCapabilities` REST probe | **0 — KEEP** | **Audit estimated ~300 deletable; amended to 0.** The probe feeds the control-plane path-style (Axis P) which survives. Deleting it breaks Settings/Panels against stock vs de-patched gateways. |

**Additions total: ~4,430 lines (X14 correction nets the audit's ~4,000 figure up to this).**

### Relay protocol gaps that must close FIRST — each a small relay lane

Only gaps blocking chat-transport deletion or daily-driver correctness get lanes. Gaps 4–9
+ 12 (fs/capabilities/providers/webhooks/cron/devices/search) are **declined** — the control
REST stays (§scope decision). Gap 2 (projects) had a lane (L5) and then LOST it — amendment
L5-lean: projects stay on control REST permanently (§projects decision). Gap 10 gets a lane
because the daily-driver phone's topology (GW-UNREACH) makes it a live correctness hole, and
it's cheap via infrastructure that already exists. L6 is not a gap-table lane at all — it
is the wire half of a deletion the plan already mandates (foreign turns have no userMessage
row on the relay wire; X5 cannot delete without it — amendment G2).

| Lane | Gap | Relay change (additive, back-compat) | iOS change | Size |
|---|---|---|---|---|
| **L1** | GAP-1 session LIST parity (THE central blocker, diagnosis (a)) | `LIST` gains `order=recent`, `cwd_prefix`, `exclude_source`, `min_messages`, `limit` pass-through to gateway `session.list` (today: bare `session_list(limit)`, DS:698-699) | `SessionStore.refresh` routes through `coordinator.list()`; REST list deleted with X7 | relay ~90 / iOS ~70 |
| **L2** | GAP-3-adjacent: truncate + seeded-create (§13 dead features, B13) | SUBMIT passes through `truncate_before_user_ordinal` (gateway already accepts; relay drops unknown params DS:720-724); create branch accepts `cwd` (B10 projects gap); new `branch` method = create-with-message-seed (gateway `session.create` + seed) | relay branches in `submitTruncating` (CS:3262-3269) + `branchSession` (SS:4490-4494) replace the direct seams; direct seams delete in X4/X7 | relay ~120 / iOS ~80 |
| **L3** | turn-end reason (contract I9) | reframer/downstream stamps `reason: completed\|interrupted\|error` on `turn.completed` (interrupt is relay-observable: the phone sent INTERRUPT over the same socket) | drain splits on `reason` (R5); `relayTurnTerminatedByError` latch deletes | relay ~25 / iOS ~20 |
| **L4** | GAP-10 cold notification answer (hardest constraint, B6/B7) | relay HTTP control sibling (already exists: `relayControlURL`, ConnS:604-613; `RestClient+PendingAttention` already reads it) gains `POST /approve` + `POST /clarify` one-shots → gateway `approval.respond`/`clarify.respond` | `PersistedNotificationEndpointResolver` prefers relay HTTP when configured; REST `respondToApproval` stays as fallback for co-located setups | relay ~60 / iOS ~40 |
| ~~**L5**~~ | ~~GAP-2 projects on relay-only reach~~ | **DROPPED (amendment L5-lean).** Projects stay on control REST permanently — no parallel relay path while REST survives (§projects decision). The `cwd` SUBMIT-create pass-through survives inside L2. | — | 0 |
| **L6** | Foreign turns have NO `userMessage` row on the relay wire — the reframer maps AGENT events only, so desktop-originated prompts never render (D11's render half); X5 cannot delete without this (amendment G2) | reframer/downstream emits a `userMessage` item for non-phone-originated turns — from the gateway `message.start` prompt text (live turns) and from the `rest_history` user rows (OPEN/HISTORY seed) — same item shape as the SUBMIT-synthesized one (DS:565-598) | ChatStore renders foreign user rows from the item stream; no iOS merge machinery needed (that is X5, which deletes at the after-L6 gate) | relay ~45 / iOS ~15 |

**Relay lanes total: +~340 relay / +~225 iOS glue (L1–L4 + L6; L5 dropped). All lanes are
additive protocol changes (new params, new methods, new field, one new item emission) — an
OLD iOS client ignores them (the extra foreign `userMessage` item simply folds as a user
row, which is the desired render), so the relay deploys once, ahead of the iOS waves, with
zero coordination risk.** GAP-3 itself (open/history unused) is NOT a relay lane — the RPCs
exist (`RC.open/history/list/resume/resync` all verified present); it's R3's iOS rewire.

---

## (c) Sequencing — the app is never broken

**Principle:** contract tests first (they encode the target, most run RED on qa3-base —
that's the point), relay lanes deploy (additive), rewires land one lane at a time each
carrying its OWN deletions and going green on its invariants, deletion waves last. No lane
depends on a later lane; every intermediate tree boots, connects, and passes the existing
gate. The transport FLAG stays until Wave 4, but **nobody should mistake it for a safety
net: on the daily-driver phone the topology is GW-UNREACH (Matrix B §0/§11) — the direct
arm cannot connect there, so the "direct mode as fallback of last resort" property is
illusory for exactly the device this round protects (amendment S2). The blocking gate from
Wave 3 on is ALL invariants green + a DEVICE SOAK, not the flag.** Consistent with that,
the `transportPath` fork arms are NOT collapsed in Wave 3 — the direct arms keep COMPILING
through Wave 3 and fold to relay-only in Wave 4 with the flag (amendment S1).

### Wave 0 — Contract tests (no production code) · 2 lanes
- **W0a** `tests/render_conformance` extensions: replay fixtures for I1, I2, I6,
  I7 (STORE-layer ordering only — ord monotone + userMessage-before-agent-items incl.
  foreign turns; the void-geometry property is render-layer and moves to W0b, amendment A1),
  I8, I9 (**reason-dependent assertions recorded RED-BY-DESIGN — L3-gated until lane L3
  ships; the local-stop + queue-HOLD halves are greenable pre-L3**, amendment I9-gate),
  I10 (driven by an injected **VIRTUAL CLOCK** — no wall-clock sleeps; stages fire on
  scheduled time-advance, amendment W0-determinism), I15, I21, **I23 (pending-gate recovery
  across restart: unanswered gate re-delivered on cold open ⇒ re-raised; answered gate ⇒
  not, amendment G3)** — all store-level, deterministic. RED-on-qa3-base recorded as
  evidence.
- **W0b** `tests/e2e_daily_driver` extensions: RPC-spy scenarios for **I4 (cancel-spy:
  superseded resume/open RPCs observed CANCELLED on the wire, not merely result-fenced —
  amendment W0-determinism)**, I5 (draft target nil; **BOTH drift branches — existing-pin
  enqueue + nil-pin drop/orphan-close, amendment S4**), I11 (affinity/dedup + **drift row
  drains to the PINNED id**), I12 (gate per-session **+ switch MOVES the gate, never expires
  it — amendment G1**), I13 (bg/fg cycles ⇒ zero gateway connects), I14 (RPC budget per
  open/switch/reconnect), I17 (flap ops retry-once-open); **UI-level tests (e2e scroll or
  snapshot) for the I7/I19 void-geometry properties (render-layer — amendment A1, NOT store
  replay)**. Plus relay pytest stubs for L1–L4 + L6 params.
- Exit: RED matrix documented; harness green on itself.

### Wave 1 — Relay lanes (one deploy) · 1 lane, 5 sub-lanes
L1–L4 + L6 land on a relay branch with pytest per lane (L5 dropped — §projects decision);
deploy once (additive; live 8788 service reinstall at Land only). Old iOS unaffected. Exit:
relay pytest full + conformance green; new RPCs exercised by W0b spies.

### Wave 2 — Rewires (each lane = rewire + its compensation deletions + invariant green) · 5 lanes
- **W2a — R4 guards.** 3 one-line `transportPath != .relay` gates (ConnS:1635, 3263-3313,
  2567-2592). Instantly stops D4/D7 tearing live relay turns. I13 partial-green. Zero
  behavior change in direct mode. (Ships day 1, does not wait on the rest of the wave.)
- **W2b — R1 map + routing.** I1, I2, I6, I15 green; deletes reset dance, suppression,
  switch-LA, fuzzy adoption. Existing render_conformance fixtures must stay green except the
  ones W0a recorded RED (they flip).
- **W2c — R2 submit.** I5, I6 green; deletes fallback, destination-create, echo re-key.
- **W2d — R3 reconcile.** I3, I14 green; deletes phase-2 seed, backfill storm, REST
  fetchers (X8). Gap-3 wired (`RelayItemStore` ← open/history).
- **W2e — R5 liveness + L3 consume.** I9 (incl. the reason-dependent halves, now that L3 is
  live), I10 green; drain split; error latch deletes.
- Exit: all 23 invariants green on sim + one device soak (re-run QA-3 S-family scenarios);
  run_gate full green. Each lane: Swift 6 strict, small commits, fail-before/pass-after.

### Wave 3 — Structural deletions unlocked by Wave 2 · 2 lanes
- **W3a — X4/X10:** `handle(event:)` + ingestors + InboxStore event ingest (with the
  gateway-event route wiring that feeds them). **NOT here (amendments G2/S1):** the
  foreign-mirror subsystem (X5) deletes only at the after-L6 gate below; the 9 `transportPath`
  fork sites are NOT collapsed — **the direct arms keep COMPILING through Wave 3** (they
  fold to relay-only in Wave 4 with the flag). (Requires W2d/W2e: relay path at parity.)
- **W3b — X6/X7/X9/X12/X13:** gateway reconnect/recovery machinery, direct resume task,
  REST push poster, prefetch, waitUntilOpen duplicate, echo swap, `relayTurnLive` collapse.
  (Requires W2a–W2c + L1 for the drawer.)
- **After-L6 gate (amendment G2, new):** X5 (foreign-mirror subsystem, ~250 lines) deletes
  ONLY once L6 is green AND the I-invariants cover foreign `userMessage` rendering
  (I1 sid-routing + I7 foreign userMessage-before-agent-items assertions pass on relay
  fixtures with desktop-originated turns). Not before Wave 3; lands with Wave 4 at latest.
- Exit: full unit bundle + run_gate + **DEVICE SOAK — the REAL gate (amendments S1/S2):
  all 23 invariants green on the daily-driver device re-running the S4/S6/S8/S11 scenarios,
  not "the direct arm still compiles"**.

### Wave 4 — Axis-T deletion + flag removal · 1 lane
- X1/X2/X3 whole files; **the 9 `transportPath` fork sites collapse to the relay arm (moved
  from W3a, amendment S1)**; X5 if the after-L6 gate is green; `transportPath` enum +
  Settings toggle + reader deleted; relay is the only code path. `#if DEBUG` env overrides
  stay for sim E2E. B11 satisfied.
- Exit: full gate on a tree with no gateway WS code; build 118 to device; one live push.

### Not scheduled (explicit)
Gaps 4–9, 12 relay RPCs (control plane); **a relay projects pass-through (dropped L5 —
projects stay on control REST permanently, amendment L5-lean)**; remote LA push registry
over relay; wire-level cancel of accepted prompts (gateway lacks it too — I22
honest-surface only).

---

## (d) Net size, lane count, risk register

### Size ledger (iOS unless noted)

| | Added | Deleted | Net |
|---|---:|---:|---:|
| Wave 2 rewires (R1–R5, incl. in-lane compensation deletions) | +530 | −1,360 | **−830** |
| Wave 1 iOS glue (L1–L4, L6; L5 dropped) | +225 | 0 | +225 |
| Wave 3 structural (X4, X6, X7, X9, X10, X12, X13 — X5 + fork-arms moved to W4) | 0 | −2,730 | **−2,730** |
| Wave 4 (X1–X3, X5 at after-L6 gate, toggle/reader, fork-arm collapse) | 0 | −1,260 | **−1,260** |
| Wave 0 contract tests (XCTest + pytest; does NOT count against app code) | (+~900) | — | — |
| **iOS app total** | **+755** | **−5,350** | **≈ −4,595** |
| Relay (L1–L4, L6 + pytest) | +~340 (+~270 tests) | 0 | +340 |

**Headline: −4,595 iOS lines, +340 relay lines. Deletes ~7× what it adds. The baseline
promised ~1,500 lines touched for 5 rewires + 12 layers; this plan deletes 3× that because
the contract turns 8 more subsystems into dead code and the audit scopes which deletions are
safe. X14 correction (ServerCapabilities probe STAYS) and the dropped L5 (projects stay on
control REST, amendment L5-lean) are the two places an addition was rejected — Axis P ≠
Axis T, and one REST surface is leaner than two.**

### Lane count: **12** (W0a, W0b, W1×5-sublanes-as-1 [L1–L4+L6], W2a–W2e, W3a, W3b,
after-L6 X5 gate, W4). Max 2 concurrent iOS builds per the mutex; W1 (relay) runs in
parallel with W0.

### Risk register

| # | Risk | Likelihood | Blast radius | Mitigation |
|---|---|---|---|---|
| RR1 | Relay path not at parity when Wave 3 deletes gateway ingestion (QA-1/2/3 ledgers are relay-heavy) | Med | High — no chat on device | The transport-flag "fallback" is **illusory for the daily-driver topology** (GW-UNREACH — the direct arm cannot connect there anyway, amendment S2), so parity must be PROVEN, not assumed: the REAL Wave-3 gate is ALL 23 invariants green + a DEVICE SOAK re-running the S4/S6/S8/S11 scenarios (amendment S1); the fork arms stay compiling through Wave 3 and fold only in Wave 4 |
| RR2 | L1 LIST parity regresses drawer ordering (creation-order default vs recent) | Med | Med — drawer | L1 lands + W0b spy asserts ordering BEFORE W3b touches SessionStore.refresh; S10 backstop (refuse authoritative empty) kept |
| RR3 | Cold-tap answer still dead on GW-UNREACH if L4 slips | Med | Med — blocked agent, user-visible | L4 is Wave 1 (ships first); until then REST fallback works co-located; I17 test pins relay-HTTP preference |
| RR4 | Per-session store map grows memory / resurrects stale entries | Low | Low | Bounded LRU ≤8, write-through on evict, settled-and-inactive eviction rule (contract §1.2); I3/I21 tests replay resync onto evicted+recreated entries |
| RR5 | Relay deploy with new fields vs old device build | Low | Low | All L1–L4 + L6 additive; old iOS ignores unknown params/fields (and folds a foreign `userMessage` item as a user row — the desired render); `reason` absent ⇒ iOS falls back to latch semantics until W2e (explicit compat branch, deleted in W3b) |
| RR6 | Axis-P deleted with Axis-T by mistake | Low | High — Settings/Panels brick against stock gateways | Scope decision is binding (§top); X14 KEEP; W4 diff review checklist item: zero `APIPathStyle`/`mobileAPIPrefix` changes |
| RR7 | render_conformance fixtures pin CURRENT merge behavior; rewire trips them | Certain | Low — test churn | W0a records RED matrix first; a fixture flips only with fail-before/pass-after evidence; no fixture edit without a recorded sequence |
| RR8 | `prefetchRecentTranscripts` deletion regresses scroll-up latency | Med | Low | X12 gated on R3 + gap-3 seeding warming cache (audit §4 ordering); I19 test asserts page-fetch latency bound |
| RR9 | Drift-abort (I5) drops a legitimate send on a fast switch | Low | Med — lost prompt | Split (amendment S4): drift on an EXISTING-session pin never drops — it durably enqueues against the PINNED id, and I11 asserts the row drains to the ORIGINAL target (mobile keeps durability where desktop drops). Only DRAFT/nil-target drift drops (echo + orphan-close), which is correct: the minted session is not where the user went |
| RR10 | Two reconnect policies mid-migration (W2a guards vs coordinator driver) | Low | Low | W2a makes the coordinator the only relay-mode owner immediately; the gateway loop merely compiles until W3b; I13 asserts zero gateway connects from W2a on |

### Leanness audit of every addition (mandate: justify against a deletion)

| Addition | Justifying deletion(s) |
|---|---|
| R1 store map + routing (+250) | reset dance, suppression, switch-LA, fuzzy adoption, twin heuristics (−420) |
| R2 pin/drift/orphan-close (+60) | fallback, destination-create, re-key, dump (−180) |
| R3 gap-fill-once + RPC-cancel (+90) | phase-2 seed, backfill storm, REST fetchers, double-resume (−640) |
| R4 guards (+3) | gates the −650 Wave-3/4 deletion; stops live-turn teardown day 1 |
| R5 baseline sites + drain-split (+70) | error latch, foreign special-cases (−60); buys I9/I10 — the only net-positive, carries S8 + stop-drains-queue, unreachable by deletion alone |
| L1 LIST params (relay 90 / iOS 70) | unlocks X7 (−450) + kills REST list; diagnosis-(a) root |
| L2 truncate/branch/cwd (relay 120 / iOS 80) | replaces two DEAD direct seams (deleted in X4/X7) + B10 cwd gap; restores parity features |
| L3 reason field (relay 25 / iOS 20) | replaces the error latch (−30) + makes I9 wire-true |
| L4 relay HTTP gates (relay 60 / iOS 40) | the ONLY fix for cold-tap on GW-UNREACH; no deletion justifies it except "REST respond dies on the daily-driver topology" — accepted as pure correctness, smallest possible form (reuses existing relay HTTP sibling) |
| L6 foreign userMessage emission (relay 45 / iOS 15) | deletes the render half of the foreign-mirror (`mergeForeignUserRows`, part of X5's −250); the ONLY thing that makes X5 deletable — foreign prompts have no row on the relay wire without it (D11, amendment G2) |
| W0 contract tests (+900, not app code) | the oracle that makes every deletion PROVABLY safe; without it Wave 3 is unshippable |

~~L5 projects pass-through~~ was the one addition REJECTED by the mandate itself
(amendment L5-lean): a parallel relay projects path while REST projects survives is
duplicate transport, not leanness — projects stay on control REST permanently (§projects
decision; the `cwd` create fix rides L2 instead).

Every line added deletes ≥1 line except L4/L6/tests, which are justified by correctness
(cold-tap, foreign-prompt rendering) and by being the gate that makes −4,595 lines of
deletion safe to land.
