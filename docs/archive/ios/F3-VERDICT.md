# F3-VERDICT — CrossClientSync mirror-latency: final synthesis

Synthesizes the F3 decisive test (H1), the fan-out fix (H4), and the
slow-client/latency measurement against the F3-FACTS hypotheses H1–H5.
Verdict only — no code changed by this synthesizer. Evidence at
`/tmp/hermes-f3-evidence/{h1,fanout,measure}/`; relevant commits
`f5548b40d` (fan-out) and `f4f6bcbbf` (test classification) on branch
`hermes-mobile` (committed, not pushed).

---

## 1. H1 — FINAL VERDICT: **REFUTED.** The flake is NOT a test-harness /
##    fire-and-forget / wrong-backend defect. It is a real app-side mirror bug.

The F3-FACTS bottom line ranked H1 (test+contract defect: fire-and-forget 2nd
submit, never verifies the foreign turn completed, run against live 9119) as the
top suspect. The decisive test **refutes it**.

**What was done (verified):** the improved `CrossClientSyncUITests.swift` now
splits the single 150s `waitForExistence` into two staged assertions:
- line 73 `foreign.waitForTurnComplete(sessionId: runtime, timeout: 180)` — waits
  for the foreign `message.complete` on the foreign WS (closes the
  fire-and-forget gap that H1 hinged on);
- line 76 `XCTFail("foreign turn never completed server-side …")` — the H1
  classifier (turn never finished / slow model / wrong backend);
- line 116 `XCTFail("MIRROR BUG: foreign turn COMPLETED server-side but its text
  was not mirrored within 45s …")` — the real app/server-bug classifier.

Ran 3× against an **isolated own instance** on `127.0.0.1:9121`
(`HERMES_GATEWAY_BROADCAST=1`, own `secrets.token_urlsafe` token); live 9119
(PID 82121) untouched. This also removes the CONTRACT-F2 "ran against live 9119"
confound the FACTS doc flagged.

**Result — deterministic, 3/3:**

| run | foreign turn complete | mirror UI assertion | failed at | classifier |
|-----|----------------------|---------------------|-----------|------------|
| 1   | 2.7s                 | timeout 45.41s, rendered=false | line 114/116 | **MIRROR BUG** |
| 2   | 1.4s                 | timeout 45.41s, rendered=false | line 114/116 | **MIRROR BUG** |
| 3   | 6.0s                 | timeout 45.41s, rendered=false | line 114/116 | **MIRROR BUG** |

Every failure landed on the **new line-116 MIRROR-BUG assertion, NONE on the
line-76 "turn never completed" classifier.** The foreign `message.complete`
arrived in **1.4–6.0s** (fast — not a slow model, not a wedged/queued turn), and
REST on 9121 (`/api/sessions/<sid>/messages`) confirms **all 3 sessions stored
`assistant→MIRRORTEST`** — the turn finished and the exact text is in the
backfill source. Yet the app rendered it 0 times in 45s (accessibility hierarchy
MIRRORTEST count = 0).

**Therefore:** H1's two pillars both fall. The turn DID complete server-side
(refutes "never completes / slow model / queued behind live traffic"), and the
failure reproduces deterministically on the **isolated own backend** (refutes
"caused by the live-9119 contract violation"). The CONTRACT-F2 process defect was
real and should still be fixed as hygiene, but it was **not the cause** of the
10/10 failure. **H1: REFUTED.**

**Corollary:** the original test could not tell "mirror dropped the frame" from
"turn never completed" — both surfaced as "MIRRORTEST never appears." The rewrite
now distinguishes them, and the answer is unambiguously the former.

---

## 2. FAN-OUT FIX (H4) + measured latency profile

### Was the 10s head-of-line risk real?
**Yes, structurally real, but it was never the cause of THIS flake.** The
pre-fix path (`server.py` `_broadcast_event` → `for listener: listener.write()`,
each `WSTransport.write` doing `fut.result(timeout=10s)` sequentially on the
emit/pool thread, FACTS hops 5 + §1) means one wedged mirror client could stall
every later client AND the agent emit by up to 10s/frame. On a phone over lossy
cellular co-resident with another client, that is a genuine mirror-latency and
head-of-line hazard. It is independent of the H1/H2/H3 drop bug.

### Is it gone?
**Yes — fixed and measured.** Commit `f5548b40d` (verified in tree):
- `server.py:405` now calls `listener.broadcast(obj)` (was `listener.write`).
- `ws.py:160` `broadcast()` appends each frame to a per-transport bounded FIFO
  `deque` and schedules a single drain coroutine via `run_coroutine_threadsafe`
  **without** awaiting the future — the emit thread never blocks on a slow client.
- The **owner path is untouched**: `write()` (`ws.py:124`) still uses
  `fut.result(timeout)` for confirmed owner delivery; only mirror copies moved to
  the async path. Confirmed `write` and `broadcast` are separate methods.
- Overflow policy: **drop-oldest** (`popleft`, `ws.py:195`) bounded by
  `HERMES_GATEWAY_BROADCAST_QUEUE_MAX` (default 256), with a **single coalesced**
  `broadcast_gap=<count>` marker so the client reconciles via existing REST
  backfill. Marker is additive and never touches `params.stored_session_id`
  (enrichment unchanged). Keeps newest frames → phone recovers rather than being
  kicked.

### Measured latency profile (normal mirror, `/tmp/.../measure/`):
- **Baseline (no slow client):** p50 **0.71ms**, p95 **4.90ms**, max **8.21ms**.
- **Slow isolation holds:** with a degraded 3rd client (sleeping 5–6s/recv,
  queue caps 256 and 8), normal mirror B stayed flat — p50 0.73–0.89ms, p95
  4.36–5.79ms, max ≤7.74ms. **Zero event loss on B in every run** (88/88, 87/87,
  86/86, 59/59); owner A completed all 10 turns every run. The slow/dead client
  degraded **only itself** (received ~9/87 frames, torn down at teardown,
  server-side `send_failures=0`).
- **Emit-thread max per-frame time 0.0002s** in the live in-process probe (9125) —
  no ~10s block.

**Conclusion:** mirror latency on a healthy path is **sub-10ms** (order-of-
magnitude; sub-millisecond p50), and the 10s head-of-line risk is **eliminated** —
a slow mirror can no longer stall the emit thread, the owner write, or a second
mirror. The fan-out fix is **sound and HOLDS**.

**Caveats on the measurement (carry-forward, not blockers):**
- The drop-oldest / `broadcast_gap` overflow path was **never reached by real
  loopback traffic** (short turns ≈6KB/≈9 frames; the socket buffer absorbs them,
  `send_text` never suspends, deque never hits cap — even with cap=8 and a silent
  client). Its correctness rests on the **in-process unit tests**
  (`tests/test_tui_gateway_server.py::test_f3_broadcast_*`, 7/7 pass: drop-oldest,
  FIFO order, single coalesced gap marker, newest-frame retention, emit non-block,
  owner-write-untouched, closed-transport refusal), **not** a live socket repro.
- The "keep the slow client connected + recover via REST" half of the policy is
  proven only by unit test; the live slow client disconnected via probe teardown
  (code=1006), not server eviction.
- Samples were 10 short turns on one quiet machine, single-process clock; no
  high-frequency tool-heavy turn and no cross-machine network latency. Treat p95/max
  as low-single-digit-ms order-of-magnitude.

---

## 3. H2 and H3 — still live, or ruled out?

### H2 (isStreaming adoption race): **CONFIRMED as the root-cause family —
###  strongly indicated, not yet instrumentation-proven. STILL LIVE; ships.**

The H1 decisive test, run against the isolated backend, produces the exact H2
signature on the live app:
- foreign `message.start` is **adopted** (the run-1 final screenshot shows
  "Driven by Claude Code (local)", `isStreaming=true`, a STOP button, and a
  perpetual "Thinking… / Working . 48s") —
- but the live stream is then **dropped** at `ChatStore.swift:142`
  `guard isPrompt || !isStreaming else { return }` (verified in tree), so the
  MIRRORTEST deltas never populate the transcript;
- the `message.complete` fallback `Task { await backfill() }` (`:150`) hits
  `backfill()`'s `guard !isStreaming else { return }` (`:772`, verified) — a
  **no-op while the app still believes it is streaming** — and the `do/catch`
  swallows any REST error silently (`:777-778`).
- Net: the text exists **everywhere except the app UI** (foreign WS, server store,
  REST backfill source) — precisely the "silent mirror-drop" the FACTS doc flagged.

The warmup turn (HELLO-FROM-DESKTOP) **did** resume + mirror correctly, which
tilts the diagnosis toward **H2 over H3** (correlation works at resume time).

**What evidence is still MISSING to fully nail H2 (and split it from H3):** the
FACTS §2/§4 prescribed but un-run step — a DEBUG build + UI-G StateServer snapshot
(or a temporary log at `ChatStore.swift:142`/`:135`) capturing `isStreaming` and
`mirroringRuntimeId` at the instant the foreign `message.start` arrives. H2 is
confirmed iff frames hit the `:142` return while `isStreaming==true`. The
screenshot ("Thinking…", STOP, isStreaming-adopted) is strong circumstantial
proof but is not the gate-decision log. **This instrumentation should run as part
of validating the hardening fix, not as a precondition to it** — the fix target is
unambiguous regardless.

### H3 (stored_session_id correlation break): **largely RULED OUT as the cause of
###  THIS failure; remains a latent silent-drop hazard worth one cheap guard.**

Evidence against H3 being the cause here:
1. The warmup HELLO-FROM-DESKTOP **resumed and mirrored correctly** — correlation
   demonstrably worked for that stored session at resume time.
2. The MIRRORTEST turn was **adopted** ("Driven by Claude Code (local)" banner,
   STOP button) — adoption requires passing the `:133-135`
   `storedSessionId == activeStoredId` gate. A pure H3 correlation break would
   have dropped the frame **at `:135` with no adoption** and no "Thinking…" state.
   The app got past the correlation gate and then died on the **isStreaming**
   guard — that is H2's signature, not H3's.

So for the observed 10/10, **H3 is effectively ruled out.** It is not, however,
fully closed as a class: the live H1 run did not add the gateway-side
`stored_session_id` log nor the app-side `event.storedSessionId` vs
`activeStoredId` compare (FACTS §2 H3 decisive measurement), so the
numeric-coercion / falsy-`session_key`-mid-turn / format-drift sub-cases remain
**unverified-absent** rather than proven-absent. They stay a plausible *future*
silent-drop source (drawer dot can still pulse via `stampActivity` while the
transcript stays empty).

---

## 4. RECOMMENDATION

### Is the CrossClientSync flake EXPLAINED?
**Yes — fully and deterministically.** It is not flaky; it is a 100%-reproducible
**app-side mirror drop (H2 family)**: the foreign turn completes fast (1.4–6.0s)
and its text is stored server-side, but the app adopts the foreign stream, drops
the live deltas at the `ChatStore.swift:142` isStreaming guard, and the
`message.complete→backfill()` recovery is a no-op-while-streaming that silently
swallows the result. H1 (test/contract defect) is **refuted**; H4 (head-of-line)
is **fixed and not the cause**; H3 (correlation) is **ruled out for this signal**.

### Is mirror latency healthy?
**Yes, on the transport.** Sub-10ms p95 with slow-client isolation proven; the
10s head-of-line risk is eliminated. The unhealthy part is **not latency — it is a
correctness drop** in the app's adoption/backfill state machine, which no amount
of latency budget fixes. (Note: the test's 45s budget is generous; once the H2 fix
lands, tighten to ~10–15s per FACTS §3 to make it a tight mirror-latency gate.)

### Does a hardening follow-up ship? **YES — one focused batch.**

Ships now (already landed, keep): the **fan-out non-blocking broadcast**
(`f5548b40d`) and the **two-tier test classifier** (`f4f6bcbbf`).

Hardening batch to schedule (app-side `ChatStore`, out of scope for the
decisive-test/fan-out agents):

1. **(H2, primary) Fix the isStreaming-adoption race + backfill no-op.** The
   foreign `message.complete` path must reconcile the transcript even while
   `isStreaming==true` (e.g. clear/teardown the adopted foreign stream state
   before calling `backfill()`, or make backfill foreign-turn-aware so the
   `:772 guard !isStreaming` doesn't no-op the very recovery it exists to perform).
   This is the one fix that turns CrossClientSyncUITests green.
2. **(H2, observability) Surface backfill failures.** The silent `catch` at
   `:777-778` must at minimum log/emit so a future REST-error drop is not invisible.
3. **(H3, cheap defensive guard, even though ruled-out-here) Harden
   `stored_session_id` correlation:** trim/normalize on both sides and tolerate a
   numeric stored id (`GatewayEvent.swift` / `JSONValue.swift` string-only coercion
   → nil), so a format/numeric drift can never silently zero the mirror.
4. **(test) After (1) lands, tighten the mirror budget to ~10–15s** and keep the
   line-76 vs line-116 classifier so any regression is self-diagnosing. The test
   will remain RED in CI until (1) ships — this is correct (it is a true mirror
   drop), but means it is a known-red gate, not a flake.
5. **(hygiene, not blocking) Enforce CONTRACT-F2:** route the UI test at the
   disposable instance, never live 9119, so future runs cannot regress to driving
   real user traffic.

**Validation gate for the batch:** re-run the H1 decisive test (now self-
classifying) — it must flip from the line-116 MIRROR-BUG failure to **green** —
plus run the deferred H2 instrumentation (DEBUG StateServer snapshot of
`isStreaming`/`mirroringRuntimeId` at foreign `message.start`) once, to convert
H2 from "strongly indicated" to "proven fixed at the gate."

---

## Verdict at a glance

| Hypothesis | Verdict | Disposition |
|------------|---------|-------------|
| H1 test/contract defect | **REFUTED** | Reproduces deterministically on isolated 9121; turn completes in 1.4–6.0s and text is stored. CONTRACT-F2 hygiene fix still wanted. |
| H2 isStreaming adoption race | **CONFIRMED (root cause), instrumentation-pending** | Primary hardening fix. Screenshot + code-grounding prove it; one DEBUG snapshot still owed. |
| H3 stored_session_id break | **RULED OUT for this signal**, latent class open | Warmup mirrored + MIRRORTEST adopted ⇒ correlation passed. Cheap defensive guard recommended. |
| H4 head-of-line / fan-out | **FIXED & MEASURED** | `f5548b40d`; sub-10ms p95, slow-client isolation holds, owner path untouched. Overflow path unit-tested only. |
| H5 drawer/stage-2 fragility | not the cause | stage-2 passed; remains a latent flake source, no action this batch. |
