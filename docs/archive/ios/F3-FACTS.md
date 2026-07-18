# F3-FACTS — CrossClientSyncUITests cross-client mirror-latency fact base

Investigation target: `testForeignTurnIsMirroredLive` fails 10/10 with
"Foreign turn was not mirrored into the app UI" (`CrossClientSyncUITests.swift:66`),
each ~160–163s in. The question: is this a real cross-client mirror-latency
signal, a test-harness/contract defect, or an app/server mirror bug?

Recon synthesized from four readers (uitest, appMirror, serverBroadcast,
evidence) + first-hand re-grounding of every load-bearing file:line and a live
process inspection (2026-06-06).

---

## 0. LIVE-STATE GROUNDING (measured, not inferred)

- `127.0.0.1:9119` LISTEN → PID 96254 = `venv/bin/hermes dashboard --tui --host
  127.0.0.1 --port 9119` (the LIVE shared backend per CONTRACT-F2:14-16).
- `127.0.0.1:9123` LISTEN → PID 60165 = the own/test instance.
- **`ps eww` on BOTH PIDs shows `HERMES_GATEWAY_BROADCAST=1`.**
  → The evidence reader's top suspect ("broadcast not enabled on live 9119, so
  the foreign turn never mirrors") is **REFUTED for the currently-running
  process**: broadcast IS enabled on 9119. (It may have been off during some
  of the 10 historical runs — unprovable from the logs — but it is on now, so a
  re-run will not be saved by "just enable broadcast".)
- All three preserved logs (`/tmp/hermes-uiF-ccs.log`, `…uiD-crosssync.log`,
  `…uiG-test-debug.log`) hard-code
  `TEST_RUNNER_HERMES_URL=http://127.0.0.1:9119` and the same shared token.
  → **CONTRACT-F2:16-21 violation is confirmed in the logs**: every recorded
  run drove `session.create` + two real agent turns against the user's LIVE
  backend, not the disposable 9123 instance. This is a process defect
  independent of whether the test logic is correct.
- Failure timing is tightly clustered at 160.65s / 161.95s / 162.83s — i.e.
  ~10s of stage-1+stage-2 setup followed by the **full 150s `waitForExistence`
  burning to its deadline**. The mirror text never appears; it is not landing
  "late at 149s". A pure latency-creep story would show some passes and some
  fails near the edge; 10/10 at the hard ceiling means the frame is **not
  arriving at all**, not arriving slowly.

---

## 1. END-TO-END EVENT PATH: owner-turn → mirror-render

Numbered hops for the **second (MIRRORTEST) turn**, the one that fails. "Owner"
= the ForeignClient/test-runner WS (it submitted the prompt); "mirror" = the
iOS app passively watching the same stored session. Every buffer / timeout /
lock is named with file:line.

**A. Foreign owner submits (test runner side)**
1. `ForeignClient.submitPrompt` sends `prompt.submit` **fire-and-forget**:
   `request(...)` is called with `_ =` and **no `waitForTurnComplete`** —
   `CrossClientSyncUITests.swift:57-60` vs the warmup turn which DID wait
   (`:24-25`). The send-ack uses `XCTWaiter` 10s (`:157`); the RPC *result*
   wait is the default 30s (`request(...timeout:30)`, `:145`). A `prompt.submit`
   **error frame** (busy session, runtime gone, bad params) is raised as a
   thrown `NSError` (`:163-166`) — but because the call is `try`-without-catch
   at `:57`, a throw would **fail the test immediately at line 57, not line 66**.
   Since all failures are at line 66, the submit RPC *returned a result* — the
   prompt was accepted. What is NOT verified is that the turn ever *completed*.

**B. Server produces + emits (tui_gateway, 9119/9123)**
2. `dispatch(prompt.submit)` runs the agent turn on a pool thread
   (`ws.py:235` `asyncio.to_thread(server.dispatch,…)`). Agent spin-up + model
   generation latency lives here — **uncapped** by the app; only the foreign
   client's (absent) wait would bound it.
3. Each agent event → `server._emit` → `write_json` (`server.py:433-438,
   406-430`). For an `event` frame with a `session_id` it writes to the owning
   transport first (`server.py:424-425`), then, iff `_broadcast_enabled()`
   (`server.py:374` reads `HERMES_GATEWAY_BROADCAST`), calls `_broadcast_event`
   (`server.py:426-427`).
4. `_broadcast_event` (`server.py:377-403`): late-imports `ws`, snapshots
   `live_transports()` (`ws.py:43-46`, under `_live_lock`), looks up the
   **stored** key `stored_key = _sessions.get(sid).session_key`
   (`server.py:392`), and **enriches `params.stored_session_id`**
   (`server.py:394-395`) — this is the ONLY tag that lets the app correlate a
   foreign runtime to its open stored session. **If `stored_key` is falsy the
   frame is broadcast WITHOUT `stored_session_id`** and the app silently drops
   it (see hop 10).
5. **FAN-OUT IS SEQUENTIAL + BLOCKING (head-of-line lock):**
   `for listener in listeners: listener.write(obj)` (`server.py:397-401`). Each
   `WSTransport.write` from a pool thread marshals onto the loop and
   **`fut.result(timeout=_WS_WRITE_TIMEOUT_S)` blocks up to 10s**
   (`ws.py:108-113`, `_WS_WRITE_TIMEOUT_S=10.0` at `ws.py:51`). The owner write
   at hop 3 happens **before** mirror writes, in series, on the emitting path.
   One slow/wedged client stalls every later client AND the agent emit by up to
   10s/frame. No queue, no backpressure (serverBroadcast reader, confirmed).

**C. Transport → app actor**
6. App socket receives one JSON frame per `URLSessionWebSocketTask.receive()`
   in `receiveLoop` (`HermesGatewayClient.swift:185-198`); decoded
   (`:200-218`) and `eventsContinuation.yield(event)` (`:240`), one-for-one, no
   throttle. The `events` AsyncStream is **unbounded** (`:43`, `makeStream` with
   no bufferingPolicy) — a burst queues without backpressure and lags render if
   the main actor is busy.
7. `GatewayEvent(params:)` parses `session_id` and **`stored_session_id` via
   strict string-only `JSONValue.stringValue`** (`GatewayEvent.swift:22-23`,
   `JSONValue.swift:80-83`) → **a numeric stored id coerces to `nil`**.

**D. MainActor route + mirror gate**
8. `ConnectionStore.eventRouterTask` `for await` over `client.events` →
   `route(event:)` (`ConnectionStore.swift:272-277, 290-315`), MainActor-hopped.
9. `route` `stampActivity` (drawer pulse dot only, `:304, 321-332`) then
   `chatStore.handle` (`:305`). `gateway.ready` is the ONLY trigger of
   `sessionStore.refresh()` (`:292-293`) — irrelevant to this turn (the row is
   already open) but relevant to stage-2.
10. **THE MIRROR-ADOPTION GATE — `ChatStore.handle` (`ChatStore.swift:131-152`):**
    - `:132-135` foreign frame requires
      `event.storedSessionId == sessions.activeStoredId`; **else silent return**.
      (Fails if hop 4 didn't tag it, or hop 7 nil'd a numeric id, or any
      id-format drift / no trim/normalize.)
    - `:136-137` single-foreign-runtime **lock** (`mirroringRuntimeId`): once a
      foreign runtime is adopted, a *second* concurrent foreign runtime on the
      same stored session is dropped.
    - `:141-142` **`guard isPrompt || !isStreaming else { return }`** — a
      foreign **stream** frame (`message.start`/`message.delta`) is **DROPPED
      while the app's own `isStreaming` is true**. `isStreaming` is set false
      only in `handleMessageComplete` (`:302`).
    - `:143` adopt (set `mirroringRuntimeId`).
    - `:145-151` on foreign `message.complete`: clear lock, `Task { await
      backfill() }` — the foreign prompt bubble + final text are reconciled via
      REST, NOT from the dropped stream.
11. Stream deltas accumulate in `textBuffer`/`thinkingBuffer` and are flushed by
    a **single 40ms-coalescing flush Task** (`ChatStore.swift:98, 395-403`,
    `flushInterval=.milliseconds(40)`); `message.complete` calls
    `flushBuffersImmediately` (`:281, 421-425`). Caps mirror render ~25Hz; not a
    150s-scale factor.
12. **Backfill** (`ChatStore.swift:150 → backfill ~771-780`): REST `rest.messages`
    + `seed`; **no-op while streaming**, and **silently missing if the REST call
    errors**. If the MIRRORTEST text only ever lands via backfill (because the
    live stream was dropped at hop 10's `:142` guard), a backfill failure ==
    permanent missing mirror.
13. Render: seed bumps `transcriptGeneration` driving ChatView scroll
    (`ChatView.swift:179-192`); the polled UI element is a `staticText` whose
    label `CONTAINS[c] "MIRRORTEST"` (`CrossClientSyncUITests.swift:63-65`).

**Two non-obvious single points of failure on this path:**
- Hop 4 `stored_session_id` enrichment (server) ⇄ hop 10 exact-string equality
  (app). One missing/non-string/drifted id = total silent drop, drawer dot may
  still fire (`stampActivity` is independent).
- Hop 10 `:142` isStreaming guard: the live MIRRORTEST stream is only adopted
  if the app is idle when `message.start` arrives; otherwise the turn rides
  entirely on the `message.complete`→backfill path (hop 12).

---

## 2. RANKED HYPOTHESES (each with the cheapest decisive measurement)

### H1 (TOP) — Test/contract defect: fire-and-forget 2nd submit against the wrong (live 9119) backend; the foreign turn silently never completes, so there is nothing to mirror. NOT an app/server latency bug.
Grounds: 10/10 fail at the hard 150s ceiling (not edge-marginal); logs hard-code
9119 (CONTRACT-F2:16-21 violation); 2nd `submitPrompt` is fire-and-forget with
no `waitForTurnComplete` (`:57-60`) UNLIKE the warmup (`:24-25`), so a turn that
errors *after* the submit-ack, gets queued behind the live user's traffic, hits
an approval gate, or just runs >150s produces exactly "MIRRORTEST never appears"
with no diagnostic. The submit RPC clearly *returned* (failure is at line 66 not
57), so the prompt was accepted but the *turn outcome* is unobserved.
**Decisive measurement (cheapest):** add a temporary `try
foreign.waitForTurnComplete(sessionId: runtime, timeout: 150)` immediately after
the 2nd submit (`:60`) and re-run against the **own 9123** instance. If the
foreign client itself times out / sees an error waiting for `message.complete`,
the turn never completed server-side → app is exonerated, it's a test+contract
defect. If the foreign client *does* see `message.complete` but the app still
doesn't render → fall through to H2/H3.

### H2 — `isStreaming` adoption race: the live MIRRORTEST stream is dropped by the `guard isPrompt || !isStreaming` gate (`ChatStore.swift:142`) and the fallback `message.complete`→`backfill()` either errors or races, leaving no text.
Grounds: after resuming HELLO-FROM-DESKTOP, a resume/seed or any residual own
turn can leave `isStreaming==true`; the foreign `message.start` then arrives and
is silently dropped; the turn depends entirely on backfill (`:150, 771-780`)
which is a no-op while streaming and silent on REST error.
**Decisive measurement:** in a DEBUG build with the UI-G StateServer bridge,
snapshot `ChatStore.isStreaming` and `mirroringRuntimeId` at the moment the
foreign `message.start` should arrive (or add a temporary log at `:142` /
`:135`). If frames are hitting the `:142` return while `isStreaming==true`, H2
confirmed. Refuted if `isStreaming==false` and frames pass the gate.

### H3 — `stored_session_id` correlation break: server enriches with a key the app can't match (missing `session_key` at emit time, numeric id coerced to nil, or format drift), so every mirror frame is dropped at `ChatStore.swift:135`.
Grounds: hop 4 `_sessions.get(sid).session_key` can be falsy mid-turn;
`GatewayEvent` parses stored id string-only (`GatewayEvent.swift:23`,
`JSONValue.swift:80-83`); equality is exact with no trim/normalize
(`ChatStore.swift:132-134`). Drawer dot independence means the row could even
pulse while the transcript stays empty.
**Decisive measurement:** on the gateway, log `obj["params"]["stored_session_id"]`
inside `_broadcast_event` (`server.py:395`) for the MIRRORTEST frames AND log
`event.storedSessionId` + `sessions.activeStoredId` at `ChatStore.swift:133`.
One-line compare: equal strings ⇒ H3 refuted; mismatch/nil/absent ⇒ H3 confirmed.

### H4 — Genuine latency: real foreign agent turn (spin-up + model gen) + sequential/blocking fan-out (`server.py:397-401`, 10s/client `ws.py:112`) exceeds 150s under live-9119 contention.
Grounds: 150s budgets a whole foreign turn; head-of-line blocking can add up to
10s per slow co-resident client per frame; 9119 carries real user traffic.
But: 10/10 at the *exact* ceiling argues against pure latency (latency would
scatter). Demoted below H1–H3.
**Decisive measurement:** the latency-budget timestamps in §4. If
`render − server_emit` for the MIRRORTEST `message.complete` is < 150s but the
test still fails, latency is NOT the cause (it's a drop, H2/H3). If the
server-side `message.complete` itself is emitted > 150s after submit, H4
confirmed (slow turn).

### H5 — Drawer/stage-2 fragility (sessionRow 20s / resume 60s windows): refresh only on `gateway.ready` (`ConnectionStore.swift:292-293`), `firstMatch` row order (pinned-before-unpinned, `DrawerView.swift:356-357`), cron `hideCron` filter (`SessionStore.swift:148-161`), REST-vs-warmup persistence lag.
Grounds: all real, but evidence (`evidence` reader: "Resume of
HELLO-FROM-DESKTOP works in 1–2s") shows stage-2 **passed** in the recorded
runs — the failure is purely the stage-3 mirror at line 66. So H5 is a *latent*
flake source, NOT the cause of the observed 10/10. Lowest rank for THIS signal.
**Decisive measurement:** none needed for the current failure (stage-2 passed);
revisit only if a future run fails at line 46 or 52.

---

## 3. WHAT THE UI TEST MEASURES vs WHAT USERS EXPERIENCE — NOT the same thing

**The test measures:** end-to-end wall time for a *cold* foreign agent to spin
up AND generate a full reply AND have it cross the gateway broadcast AND be
adopted+rendered — all inside ONE 150s `waitForExistence` with a fire-and-forget
trigger. It conflates **three independent latencies** into a single pass/fail:
(a) foreign server agent-turn time (model generation — not a mirror property at
all), (b) gateway broadcast/fan-out latency (the actual cross-client mirror
property), (c) app adoption+render latency. Only (b)+(c) are "mirror latency";
(a) is the LLM. A slow model alone fails the test while the mirror works
perfectly.

**What users actually experience:** a user already has the session open and is
watching; the desktop is *mid-turn or finishing* a turn the user can see
progressing. The user-perceived mirror latency is **(b)+(c) only** — the
delta from "a frame is emitted server-side" to "it shows on my phone" — typically
sub-second (40ms flush + one main-actor hop + REST backfill). Users do NOT
perceive (a): they were already waiting on the model regardless of which client
submitted.

**Consequences:**
- The test's 150s ceiling is a proxy for "model finished within 150s", which is
  about the **agent**, not the **mirror**. A green test ≠ good mirror latency; a
  red test ≠ bad mirror latency. They are only loosely correlated.
- The fire-and-forget 2nd submit means the test can't distinguish "mirror
  dropped the frame" from "the turn never completed" — the two user-visible
  outcomes are wildly different (a real bug vs a slow/failed model) but produce
  the identical assertion failure.
- A correct mirror-latency test would **decouple** the three: wait for the
  foreign `message.complete` (proves the turn finished + gives a server-side
  timestamp), THEN assert the app rendered it within a *small* budget (e.g.
  5–10s), measuring only (b)+(c). The current test cannot make this distinction
  and therefore cannot certify what it claims to certify.

---

## 4. INSTRUMENTATION POINTS for a latency budget (timestamp capture)

Capture a monotonic timestamp + the runtime `session_id` + stored
`session_key` + frame `type` at each, for the MIRRORTEST `message.delta`(first)
and `message.complete`:

| # | Stage | Where (file:line) | Timestamp name |
|---|-------|-------------------|----------------|
| T0 | Owner submit accepted | `server.dispatch(prompt.submit)` entry / `prompt.submit` handler in `server.py` | `submit_received` |
| T1 | **Server emit** (agent event produced) | `server._emit` / `write_json` (`server.py:433-438, 406-430`) | `server_emit` |
| T2 | **Broadcast write** (per mirror client, post-enrichment) | inside `_broadcast_event` loop just before/after `listener.write(obj)` (`server.py:397-401`); also log `stored_session_id` (`:395`) and the 10s `fut.result` wait span (`ws.py:108-113`) | `broadcast_write_start/end` |
| T3 | **Client receive** (frame off the wire) | `HermesGatewayClient.receiveLoop` after `task.receive()` (`HermesGatewayClient.swift:188`) / `eventsContinuation.yield` (`:240`) | `client_recv` |
| T4 | Route onto MainActor | `ConnectionStore.route` entry (`ConnectionStore.swift:290`) | `route_main` |
| T5 | Mirror-gate decision | `ChatStore.handle` at the gate (`ChatStore.swift:133, 142, 143`) — record adopt vs which `return` (drop reason) | `gate_decision` |
| T6 | **Store mutation** (buffer→messages) | `ChatStore.flushBuffers` (`:406-417`) and `handleMessageComplete` (`:280-301`) | `store_mutate` |
| T7 | **Render** (UI observes the text) | ChatView body re-eval driven by `transcriptGeneration` (`ChatView.swift:179-192`); in test terms, `waitForExistence` resolve time | `render` |

**Derived budgets:**
- **Agent latency (a)** = T1(first delta) − T0 — the LLM, NOT mirror.
- **Server fan-out (b1)** = T2_end − T1, includes head-of-line blocking (watch
  for ~10s steps = a wedged co-client, `ws.py:112`).
- **Wire + actor (b2/c)** = T4 − T2_end, and T6 − T4.
- **Mirror latency (user-perceived)** = T7 − T1 (what §3 says actually matters).
- **Drop detector:** if T3 fires for a frame but T5 logs a `return` (drop), the
  frame arrived and the *app gate* discarded it — distinguishes H2/H3 (app drop)
  from H4 (frame never arrived → no T3) from H1 (turn never completed → no T1
  for `message.complete`).

The single most diagnostic pair is **T1 vs T5-drop-reason**: it splits "real
latency / slow model" (H1/H4) from "frame arrived and was dropped by the
adoption gate" (H2/H3) — the two root-cause families this investigation must
separate, and which the current fire-and-forget test cannot.

---

## Bottom line

The "chronic flakiness" is, on the recorded evidence, **NOT flaky — it is a
deterministic 10/10 failure caused primarily by a test-harness + contract
defect (H1):** the runs drove a fire-and-forget second agent turn against the
LIVE 9119 backend (CONTRACT-F2 violation) and never verified the foreign turn
completed, so an uncompleted/slow/queued turn surfaces identically to a mirror
drop. Broadcast IS enabled on 9119 now (measured), refuting the "broadcast off"
theory. The genuine *mirror* risk surface (H2 isStreaming-drop, H3
stored-id-correlation) is real and silent-by-design but unproven as the cause;
it is masked by H1 and can only be isolated by (1) running against own 9123, (2)
waiting for the foreign `message.complete`, and (3) instrumenting T1/T5 per §4.
The UI test does not measure user-perceived mirror latency (§3) and cannot, in
its current form, distinguish a mirror bug from a slow model.
