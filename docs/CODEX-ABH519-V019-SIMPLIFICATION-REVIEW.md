# Review — ABH-519 v0.19 simplification proposal

**Reviews:** `docs/CODEX-ABH519-V019-SIMPLIFICATION-PROPOSAL.md` @ `76a82edc0`.
**Reviewer:** independent architecture audit (Claude), 2026-07-22. Discussion only — no implementation.
**Method:** every load-bearing factual claim was verified against the repo and against the actual
upstream tag (`git fetch upstream refs/tags/v2026.7.20:refs/tags/v2026.7.20`, commit `3ef6bbd20126`).
Verification commands are included so the findings are reproducible.

---

## Verdict

**Endorse the transport half. Reject the plugin/purity half as written. The proposal ignores the
repo's own standing de-patch contract — `CONTRACT-DEPATCH.md` (ABH-88) — which already answers
several of its six questions, with per-seam evidence it does not engage.**

The diagnosis is correct and matches the independently confirmed Round-2 root causes: Q1 (assistant
row keyed under the runtime id, written only at LRU eviction), Q2 (unseen-delta → `.toolCall`
heuristic), Q3 (stored/runtime divergence + removed seed-bind) are all **copy-divergence bugs
between three models of the same conversation** (gateway, relay, phone). Deleting the second
transcript system removes the bug factory rather than patching its output. Four consecutive
sim-green/device-broken builds all failed inside that custom pipeline. That part of the proposal is
right — stated by a reviewer who helped build what it deletes.

The overreach is the jump from "delete the second transcript" to "zero core seams, public v0.19
hooks only." The fork's own seam ledger documents, seam by seam, which product behaviors die at
zero seams — and two of them (desktop-driven live-follow, turn-level push) are precisely what this
owner uses hardest.

---

## Fact-check (verified)

| Doc claim | Verdict | Evidence |
|---|---|---|
| v0.19 = tag `v2026.7.20`, commit `3ef6bbd2`, not an ancestor of build 120 | **CONFIRMED** | `git merge-base --is-ancestor v2026.7.20 f98610f9f` → false |
| Build 120 lacks `gateway/delivery_ledger.py`; v0.19 has it | **CONFIRMED** | absent on `origin/main`; 19 hits in the tag |
| Current plugin relies on 5 fork-only seams absent from v0.19 | **CONFIRMED** | `pre_emit_event`(3), `post_emit_event`(6), `post_frame_write`(4), `on_ws_transport_change`(4), `register_prompt_receipt_provider`(1) hits in `plugins/hermes-mobile`; **0 hits anywhere in the tag** for all five |
| `on_session_finalize` is a stock v0.19 hook | **CONFIRMED** | 78 hits incl. `gateway/run.py` |
| ~6,855-line alternate transport stack | **PLAUSIBLE** | 8 core files alone = 5,421 lines (reframer 855, session_state 284, downstream 1136, gateway_client 766, types 324; RelayItemStore 285, RelayClient 613, RelaySessionCoordinator 1158) |
| Framing: "not based on official v0.19" (implies an old divergent fork) | **MISLEADING** | merge-base is `306e2d231`, dated **2026-07-15** — the ABH-88 supersession sweep deliberately rebased the fork onto a *pristine upstream base five days older than the tag*. Delta: 987 upstream / 524 fork commits. This is a routine (if large) upstream sync, not an ancient fork. Upstream moves ~200 commits/day, so pinning "the exact v0.19 tag" chases a snapshot; the correct posture is *pristine upstream + seam ledger + sync cadence* — ABH-88's posture, already ratified. |
| "The current plugin cannot be carried forward" presented as a discovery | **STRAWMAN-ADJACENT** | The seams are not accidental fork rot; they are ABH-88's curated ledger (9 files, +701/−80, down from ~1,257 patch lines), each shaped as an upstream-PR candidate with a recorded verdict (S1–S13, four already SUPERSEDED by upstream). The plugin already rides the **stock** plugin system. |

Additional verified facts material to the questions:

- **`steer` is stock in v0.19** (820 hits) — the phone's interrupt/steer needs are stock-satisfiable.
- **`client_message_id` has zero hits in v0.19** — there is **no stock submit idempotency**. (Q4 is a real, unsolved gap in pure stock.)
- **`HermesGatewayClient` still exists on `origin/main`** (`apps/ios/HermesMobile/Networking/`) — because R4 Waves 3-4 (the direct-path deletion) never ran. See Required Amendment 8.

Reproduce:

```sh
git fetch upstream refs/tags/v2026.7.20:refs/tags/v2026.7.20 --no-tags
git merge-base v2026.7.20 origin/main                     # 306e2d231, 2026-07-15
git rev-list --count 306e2d231..origin/main               # 524
git rev-list --count 306e2d231..v2026.7.20                # 987
git grep -c pre_emit_event origin/main -- plugins/hermes-mobile
git grep -c on_session_finalize v2026.7.20 | head
git grep -c client_message_id v2026.7.20 | wc -l          # 0
git grep -c steer v2026.7.20 | awk -F: '{n+=$NF} END {print n}'
```

---

## Architecture challenges

### C1 — The identity system doesn't disappear; it gets one owner
Stock `session.create` returns runtime *and* stored ids (the proposal's own sequence diagram shows
both). "Delete the custom identity lifecycle" is rhetoric; the truth is "collapse three copies of
the mapping to one, owned on the phone." Q1 and Q3 were both identity-mapping bugs. Unless the
mapping is a single owned type with contract tests (cache/UI keyed by stored id, live commands by
runtime id), Q1 recurs in new clothes. The plan must name this retained complexity explicitly.

### C2 — Observe-vs-drive is the unmodeled hard problem (strongest objection)
Seam S1 exists because **stock delivers a session's events to the owning transport only** — the
plugin's `broadcast.py` + S1 (~3 core lines) are what let the phone watch a desktop-driven session
live. Current `resume` semantics *reactivate* (take ownership of) a session. Under pure stock, the
proposal's "interactive open uses stock `session.resume`" risks the phone **stealing a session the
desktop is mid-turn on** — a new catastrophic bug class — and the passive alternative (HTTP
transcript read) provides no live view at all. The session-open flow needs an explicit
drive-vs-watch branch, gated on a liveness signal that pure stock may not expose (S12: stock
`session.status` returns rendered text only). Absent from the doc entirely.

### C3 — Ambiguous submit is genuinely unsolved in pure stock (verified)
No `client_message_id` anywhere in v0.19. The fork built submit receipts (S11 / ABH-462: plugin-owned
SQLite, 30-day retention) because duplicate sends were a real device-QA bug. Deleting relay dedup
*and* the receipt provider with no replacement regresses to duplicate sends on flaky reconnects —
and content-matching cannot disambiguate identical short messages ("hi"). See answer Q4.

### C4 — `on_session_finalize` is the wrong event for this product's push
Sessions here live for hours. The product need is **turn-complete / clarify / approval** push while
the phone is away. The ledger states it plainly: approval push already rides stock
`pre_approval_request`; Live-Activity cleanup rides `on_session_finalize`; but *long-turn/clarify
pushes need the emit-observer seam (S2) "until an upstream events hook exists."* The proposal's
plugin sketch silently downgrades push to session-end granularity — a regression the owner would
notice on day one.

### C5 — "Point the existing HermesGatewayClient at the relay unchanged" hides API drift
The client exists (verified) but was written against the fork's WS surface and has been mothballed
since R4 made the relay primary; upstream has moved 987 commits since the pristine base. Stock RPC
semantics the proposal leans on (resume returns messages + streaming flag; status shape; event
vocabulary) are asserted, not verified. A concrete protocol map against the tag is required before
this claim is load-bearing. (The seam ledger does confirm stock RPCs `prompt.submit`,
`session.status`, `session.delete` exist by name.)

### C6 — The migration story is *better* than the doc claims, and should say so
Because the fork is already "pristine base + additive seams," a stock-protocol phone client works
against the **current live gateway** (a superset of stock). No big-bang gateway swap is needed:
land the thin-proxy phone against today's fork, keep the seam ledger, sync upstream on cadence.
The doc's "establish an isolated baseline aligned to the exact official tag" as step 1 is both
riskier and unnecessary as a prerequisite for the mobile work. Decoupling these two tracks
(mobile transport rewrite; upstream sync) shrinks the blast radius of each.

### C7 — What survives must be named
- `docs/INTERACTION-CONTRACT.md` I1–I23 is transport-agnostic — adopt it explicitly as the
  acceptance oracle (the proposal's device list overlaps it ~80% without citing it).
- The migrated device-shaped-DB cache harness and the device-truth process carry over.
- `tests/render_conformance` fixtures are relay-frame-coupled and die with the relay protocol;
  re-recording them from stock GatewayEvents is real, un-costed work.
- The just-landed D2/O1 relay work becomes deletion fodder — accepted; it is small and sunk.

---

## Answers to the six review questions

**Q1 — Any basic iPhone chat requirement stock can't satisfy?**
For the solo, phone-driven path: no — create/resume/submit/events + cache/outbox suffice (steer
included, verified stock). Three *basics of this product* leak past it, per the fork's own ledger:
(a) live view of a desktop-driven session — stock has no fan-out; S1 exists for exactly this;
(b) knowing a session is running without parsing rendered text — S12;
(c) pending-approval visibility from the phone — S13.
Plus submit receipts (Q4). "Stock-only" covers the solo happy path, not the owner's actual
multi-client daily driver.

**Q2 — Phone-originated-only push, eliminating the plugin?**
**No.** Desktop-driven completion push is a demonstrated product requirement for this user — the
workflow is desktop drives, phone satellites (the S-D symptom in the Round-2 handoff *is* that
workflow; QA-2/3 built APNs for it). The relay-attached-until-terminal alternative is strictly
worse: it reintroduces per-turn state into the "thin" relay and loses pushes on relay restart.
Keep the plugin.

**Q3 — Plugin strictly via public v0.19 hooks, tree untouched?**
**Not today, honestly.** Approval push and LA-cleanup: yes, stock hooks (verified/ledgered).
Turn-complete + clarify push: **no stock hook** — needs S2 until upstream grows an events hook.
Structured liveness: needs S12. The achievable bound is not zero seams; it is the ABH-88 bound —
pristine core + a shrinking seam ledger (upstream already superseded S7/S8/S9/S10), each seam an
upstream-PR candidate. The correct response to a missing hook is an upstream PR, not absolutism
that silently drops features.

**Q4 — Narrowest honest ambiguous-submit policy?**
Ranked: **(1)** upstream PR adding idempotency-key acceptance on `prompt.submit` — small, generic,
the durable fix; **(2)** until merged, keep the **S11 plugin receipt** (already built: ABH-462) —
gateway-side truth, not relay transcript state, so it does not violate the thin-relay principle;
**(3)** phone-side reconcile-before-retry as the transport-failure fallback (read the tail,
resubmit only if absent) — necessary but insufficient alone, because identical short messages
cannot be disambiguated without an id echo. A relay-side receipt LRU is the **worst** option —
session state back in the relay, lost on restart. Both options offered in the proposal's own Q4
are inferior to "keep S11 now, upstream the idempotency key, delete S11 when merged."

**Q5 — Simultaneous desktop/phone without event broadcast?**
Stock cannot do it — S1's existence is the proof (events go to the owner transport only).
Refresh-on-open/foreground is an acceptable floor for **background** sessions (it fixes S-D
staleness). For the **foregrounded** session being driven from desktop, decide deliberately:
keep S1 + plugin broadcast (~3 core lines, already an upstream-PR candidate) for true live
mirroring, or client-side short-interval transcript polling while foregrounded (no core change,
worse latency/cost). Given the owner's co-watch workflow, the reviewer recommends **keeping S1**.
This is a product decision the proposal defers by construction; it should be decided, not defaulted.

**Q6 — Which relay/plugin features are genuinely user-critical for v1?**
From four rounds of the owner's device QA (what was actually noticed and filed), v1-critical:
instant cache paint + offline read; durable send incl. offline; live streaming of own turn; push
(turn-complete/approval/clarify, **including desktop-originated**); foreground-live view of
desktop-driven sessions; approvals/interrupt/steer from phone; attachments; load-earlier
pagination; delete-live-session working (S6 — stock still returns 4023 on live rows).
**Not** v1-critical: multi-device broadcast beyond one phone, sync manifest, exact mid-turn card
recovery, background approval recovery beyond push+snapshot, attention read-state sync.
Note: the reframer, relay session tables, item vocabulary, and relay dedup are *structure serving
the second protocol*, not features — they die with it, and nothing user-visible is lost **iff**
the seam-backed features above survive in the plugin.

---

## Required amendments before this becomes a plan

1. **Reconcile with ABH-88.** Position the proposal relative to `CONTRACT-DEPATCH.md`: adopt its
   transport simplification *on top of* the seam-ledger posture, not "zero core changes" by fiat.
   Re-verdict S1–S13 against `v2026.7.20` or newer — more seams may now be SUPERSEDED.
2. **Add the drive-vs-watch state machine** to the session-open flow, with a verified liveness
   source; prove the phone can never reactivate/steal a desktop-driven session.
3. **Protocol map against the tag**: resume-returns-messages + streaming flag, status shape, and
   the exact event vocabulary `HermesGatewayClient` must speak after 987 commits of upstream drift.
4. **Fix the push design**: turn-complete granularity, not session-finalize.
5. **Submit idempotency**: keep S11 (plugin receipts) until an upstream idempotency PR lands;
   name this in the plan.
6. **Re-sequence the migration** per C6: thin-proxy phone against the *current* fork gateway first
   (isolated 9130+ instance, then the daily driver); upstream sync as an independent track — no
   big-bang tag alignment as a prerequisite.
7. **Name the test story**: I1–I23 as the oracle; re-record render fixtures from stock events;
   carry the migrated-DB harness; device-capture proof per the device-truth process (no
   simulator-only gates — agreed with the proposal).
8. **Immediately cancel the queued R4 Waves 3-4 deletion** (still queued behind owner soak). It
   deletes `HermesGatewayClient` + the GatewayEvent ingestors — the exact assets this plan needs.

---

## Bottom line

The proposal correctly identifies the disease (three models of one conversation) and the cure for
the transport layer. Its purity doctrine ("untouched stock, public hooks only") is refuted by the
repo's own evidence ledger, and its two biggest silent costs — losing desktop-driven live-follow
and losing turn-level push — are exactly the two capabilities this owner exercises hardest.

Amended to **"thin relay proxy + stock client protocol + ABH-88 seam ledger + active
upstreaming,"** the reviewer endorses it fully.
