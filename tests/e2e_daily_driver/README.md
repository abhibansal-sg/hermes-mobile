# tests/e2e_daily_driver — device-shaped E2E gate (N8, A3–A6, A8)

The merge gate for Operation Daily-Driver. Spans the **real consolidated relay**
(unchanged source from `relay/hermes_relay/`) end-to-end:

```
   phone-driver (ratified protocol)  ──WS──▶  relay   ──WS──▶  gateway
   (Python, speaks RelayClient frame       (real)         (mock scripted-echo
    envelope + JSON-RPC upstream)                          OR stock isolated)
```

Everything is hermetic by default:

* **Gateway:** a Python **scripted-echo mock** (`mock_gateway/server.py`) that
  speaks the exact JSON-RPC wire protocol the relay expects
  (`ws://host:port/api/ws?token=…`, `method:"event"` with
  `{type, session_id, payload}`, RPC responses `{jsonrpc,id,result|error}`).
  Deterministic, offline, no model key required — the bar for a merge gate.
  A real stock-gateway path is also wired (`launch_gateway.sh`) for occasional
  live-model sanity; the entry script exposes it via `E2E_USE_LIVE_GATEWAY=1`.
* **Relay:** the actual `python -m hermes_relay` from this branch, launched as
  a subprocess against the isolated gateway on 9130+ ports (never 9119).
* **Phone driver:** a `websockets` client speaking the ratified downstream
  frame envelope (`{seq, sid, turn, kind, body}`) and the upstream JSON-RPC
  methods (`submit`, `approve`, `clarify`, `list`, `history`, `open`,
  `interrupt`, `ack`, `resync`, `foreground`) — exactly what the iOS
  `RelayClient` sends/receives.

## Scenarios (each a pytest module)

| # | File | Acceptance | What it proves |
|---|---|---|---|
| a | `test_a_submit_stream_complete.py` | A3 / A4 | submit → item.started → item.delta* → item.completed; deltas + completed reconstruct byte-identical agentMessage text. |
| b | `test_b_approval_roundtrip.py` | A5 | approval.request → phone `approve` → turn resumes (never silent-deny). |
| c | `test_c_clarify_roundtrip.py` | A5 | clarify.request → phone `clarify` → answer arrives non-empty at the gateway. |
| d | `test_d_tasklist_lifecycle.py` | A5 | `taskList` item started/delta/completed; counts; `all_complete`. |
| e | `test_e_relay_sigterm_resync.py` | A6 | SIGTERM relay mid-session → restart → phone resync gap-free → queued submit drains. |
| f | `test_f_ws_flap_chaos.py` | A4 | 10× WS kill mid-turn → final transcript byte-identical to a clean run. |
| g | `test_g_notifier_apns.py` | A8 | mock-APNs: turn_complete/task_complete suppressed when foregrounded; approval/clarify bypass gate. |
| j | `test_j_contract_rpc_spy.py` | R4 contract I4/I5/I11/I12/I13/I14/I17 | Round-4 INTERACTION-CONTRACT wire oracles: draft nil-target on the wire + create/adoption (I5/I6); S4 drift split — existing-pin row drains once to the PINNED id w/ cmid dedup, nil-pin echo drop + orphan isolation (I11); gate MOVES with the session and survives switches, post-switch answer routes by (sid, request_id) (I12/G1/I18); 20× bg/fg cycles ⇒ zero gateway connects, dense seq spine (I13); reconcile budget — 1 read/open, 0 warm switch-back, relay-local resync, 0 gap-fills (I14); flap ops retry once open, zero surfaced errors (I17); cancel-spy — superseded open RPC-cancelled, foreground ends on B (I4). |

R4 W0b also adds the RENDER-layer I7/I19 void-geometry UI tests
(`apps/ios/HermesMobileUITests/VoidGeometryUITests.swift`, driven by
`scripts/r4-void-evidence.sh` against this harness's mock gateway + worktree
relay) and the RED-BY-DESIGN relay lane stubs
(`relay/tests/test_round4_lane_stubs.py`, L1–L4 + L6; L5 dropped — see
`evidence/round4/w0b-red-matrix.md`).

## Run

```bash
# Default: deterministic mock gateway. One entry script.
/Volumes/MainData/Developer/hermes-tmp/worktrees/dd-e2egate/tests/e2e_daily_driver/run_gate.sh

# Optional live stock gateway (needs ~/.hermes/.env model key; informational only —
# byte-identical A4 chaos assertion is mock-only because live-model output is
# non-deterministic).
E2E_USE_LIVE_GATEWAY=1 .../run_gate.sh
```

Evidence (per-run artifacts: phone frame log, relay log, gateway log, scenario
verdict JSON) lands in `/Volumes/MainData/Developer/hermes-tmp/evidence/daily-driver/e2e/`.

## Hard-rule compliance

* Never touches the primary tree at `/Volumes/MainData/Developer/products/hermes-mobile`.
* Never dials 9119; isolated 9130+ range only. The relay's own 9119 refusal is
  the backstop.
* All artifacts under `/Volumes/MainData`.
* No secrets in evidence (tokens are fixed e2e-only constants; live-gateway
  mode redacts the model key).
