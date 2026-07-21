# relay soak harness — desktop-only relay torture track

Proves the relay (`relay/hermes_relay`) is correct and durable under sustained
hostile conditions — pure desktop, no simulator, no iOS, no live services.
Implements `docs/RELAY-SOAK-SPEC.md` (invariants I1-I8, scenarios T1-T8).

## Run

```bash
# full short matrix (CI) against origin/main's relay, from this worktree:
tests/relay_soak/run_soak.sh /Volumes/MainData/Developer/products/hermes-mobile short

# one scenario, compressed 10× for a fast proof (SOAK_SCALE multiplies durations):
SOAK_SCALE=0.1 tests/relay_soak/run_soak.sh <relay_src> short t1_churn

# overnight soak at spec durations against the QA-3 tip:
tests/relay_soak/run_soak.sh <qa3_tip> soak

# reproducible seed:
SOAK_SEED=42 tests/relay_soak/run_soak.sh <relay_src> short
```

`run_soak.sh <relay_source_path> <mode> [scenario ...]`:

* provisions an isolated `python3.13` venv on `/Volumes/MainData` **from that
  source** (relay deps + `hypothesis`/`psutil`), one venv per source tree;
* runs the relay-under-test imported from `<relay_source_path>` (conftest pins
  `SOAK_RELAY_SOURCE/relay` on `sys.path` and the plugin dir at
  `SOAK_RELAY_SOURCE/plugins/hermes-mobile`) — the same harness re-soaks any tree;
* writes a per-scenario `verdict.json` (+ resource curves) under
  `/Volumes/MainData/Developer/hermes-tmp/evidence/relay-soak/run-<stamp>/`,
  then rolls them into one `SUMMARY.json` table.

Scenarios: `smoke t1_churn t2_flap t3_multi t4_kill t5_gateway t6_fuzz
t7_marathon t8_ring z_injected_fault`.

## Hard rules enforced

* NEVER the primary tree, NEVER a live gateway (9119) or live relay (8788) — not
  even a health curl. Real gateway/relay subprocesses bind the isolated band
  **9140-9160** with a temp `HERMES_HOME` under the evidence dir; `9130-9139`
  (QA-3 swarm) and `9119/8788` are refused defensively (`constants.py`).
* Mock APNs only (a recording `FakePush` sink — zero network, zero real APNs).
* No iOS builds. Long runs are `nice`d — the QA-3 swarm shares this machine;
  `SOAK_SCALE` compresses every duration.

## Layout

```
tests/relay_soak/
  constants.py        port discipline, evidence root, mock token
  soak_params.py      mode/duration/seed parameterization (SOAK_MODE/SCALE/SEED)
  conftest.py         fixtures: gateway (in-proc + subprocess), relay manager,
                      phone factory, resource sampler, evidence writer
  summarize.py        roll up per-scenario verdicts -> SUMMARY.json
  run_soak.sh         entry point (venv-from-source + run + summarize)
  infra/
    gateway.py        InProcGateway (default) + SoakGatewayProc (signal-able,
                      9140+, /control create_session + inject_event)
    soak_gateway_main.py  subprocess runner: ControllableMockGateway
    relay_manager.py  RelayManager: start / SIGTERM / restart, durable HOME
    phone_ext.py      SoakPhoneDriver (generation tagging, drop_if shim) +
                      churn / foreground-flap / ack-storm / cursor behaviors
    resources.py      ResourceSampler: RSS/FD/thread curve + growth detection
  invariants/
    transcript.py     reconcile fold (completed-authoritative) + reference diff
    checkers.py       I1 TurnTracker, I3 SeqCoverage, I4 Dedup, I5 OwnedLedger,
                      I7 NotifyRecorder (+FakePush), I8 Robustness
  scenarios/
    common.py         shared: deterministic reference runs + verdict assembly
    test_smoke.py ... test_t8_replay_ring.py, test_z_injected_fault.py
```

The upstream is the **deterministic scripted mock gateway** (reused verbatim
from `tests/e2e_daily_driver/mock_gateway`), so I2 byte-identical reconciliation
stays meaningful even while the gateway is paused/restarted. T5/T6 run it as a
subprocess (on 9140+) so it can be SIGSTOP/SIGCONT/SIGTERM'd and have raw events
injected.

## How each invariant is checked

Every checker folds OBSERVABLE evidence (the phone's recorded frame log, the
relay's `/healthz` status, the resource curve, or an in-process notifier drive)
into a `report()` with a `violations` list; a scenario asserts `ok` and dumps the
report as evidence. Checkers read wire-level shapes only — never the relay under
test — so the harness re-soaks any source.

* **I1 No lost turn** — `TurnTerminalTracker` folds `turn.started` /
  `turn.completed` / error-item frames AND resync `snapshot`s (a flapped phone
  may miss `turn.completed` yet recover the completed item via snapshot). Fails
  on a driven session with no terminal evidence (dead/eternal-working turn).
* **I2 Byte-identical reconcile** — `transcript.reconcile_transcript` folds the
  stream with the completed-is-authoritative rule (snapshot > completed >
  started; deltas skipped), exactly as the iOS store paints. Each tortured run of
  a deterministic script is diffed against a CLEAN reference of the same script;
  `userMessage` is exempt (it embeds the per-submit `client_message_id` — I4's
  job), the agent transcript must match.
* **I3 No dropped sub / seq contiguity** — `SeqCoverageChecker` tests each
  connection GENERATION (seq is per-connection, restarting at 1 per socket):
  received `set(seqs)` must be contiguous `[1..head]` (replay duplicates are
  fine). A permanently dropped downstream frame leaves a hole. Upstream-sub
  survival (the S8 class) is asserted by I1/I2 across T5 gateway abuse.
* **I4 Echo/dedup** — `DedupChecker`: a re-submit with the same
  `client_message_id` must resolve to one session with `deduplicated: True`, and
  each prompt must land on exactly ONE `userMessage` item_id despite replays.
* **I5 Owned-session lifecycle** — `OwnedSessionLedger` reads the relay's
  `/healthz` `owned_sessions` after every restart: driven sessions must be
  re-owned (durable re-resume), and the owned set must stay bounded (no zombie
  accumulation). T4 proves it across a kill loop.
* **I6 Resource bounds** — `ResourceSampler` samples RSS / FD / threads every
  ~30 s and fits a least-squares slope; flags monotonic growth past threshold
  (RSS > 64 MiB/run, FD > 32/run with positive slope). Full curve in evidence.
* **I7 Notify correctness** — `NotifyRecorder` runs the relay-under-test's REAL
  `Reframer`+`Notifier` in-process with a `FakePush` mock-APNs sink and a
  flappable foreground oracle, asserting §6: `turn_complete`/`task_complete` fire
  backgrounded / are suppressed foregrounded (decision tracks the oracle at fire
  time), `approval`/`clarify` always fire, and no notify is delivered to a
  dead/evicted token. (Decisions aren't observable over the wire — no APNs creds.)
* **I8 Protocol robustness** — `RobustnessChecker` (T6, hypothesis): malformed /
  truncated / oversized upstream frames + unknown methods + mutated gateway
  events; the relay must stay alive (`/healthz` 200) through the storm and every
  unknown method must return a clean JSON-RPC error.

## Injected-fault self-proof (`test_z_injected_fault.py`)

A harness whose invariants always pass is worthless. `z` corrupts the phone's
recorded stream via the `drop_if` wire-loss shim and asserts the checkers go RED
exactly where they should — and stay GREEN on an uncorrupted control: dropping
the authoritative `agentMessage` completion + `turn.completed` drives I2 and I1
red; dropping one mid-stream frame (seq 2) drives I3 red (a seq hole). The relay
under test is untouched — the corruption is on the observation path the checkers
inspect. This is the "drop a frame in a test shim and show I2 fails" proof.

## Modes & durations (`soak_params.py`)

* `short` — 2-5 min/scenario (CI). `soak` — spec durations (T4 1 h, T7 4 h+).
* `SOAK_SCALE` multiplies every duration (default 1.0; proof runs use ~0.1).
* `SOAK_SEED` drives every randomized behavior (reproducible; each scenario
  derives `random.Random(seed ^ salt)`).
