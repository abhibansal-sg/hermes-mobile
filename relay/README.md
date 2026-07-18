# hermes-relay

The **mobile relay-client** for the stock Hermes gateway — the Wave 2 linchpin.
A ZERO-CORE-PATCH, co-located process that makes the phone a first-class client
of the unpatched gateway: it reframes the gateway's raw event stream into the
ratified **item-lifecycle envelope** (`docs/RELAY-PHONE-PROTOCOL.md`) and serves
it to the iOS app over a reliable **seq/ack/replay** WS, firing APNs for the
phone's own sessions.

Architecture + zero-patch ledger: `docs/MOBILE-RELAY-CLIENT-DESIGN.md`.
Wire contract (frozen v1): `docs/RELAY-PHONE-PROTOCOL.md`.
Proof it works end-to-end: `hermes-tmp/r0-relay-spike/VERDICT.md` (all 4 claims PASS).

## Why this home (`plugins/hermes-mobile`-reusing, but its own process)

`hermes-relay` is a **standalone service process**, not a gateway plugin hook —
it opens a durable *client* WS to `/api/ws?token=` and runs its own phone-facing
server. It therefore lives as its own package with its own `pyproject`, entry
point (`python -m hermes_relay`), and lifecycle, kept OUT of the gateway process
so the stock gateway stays byte-for-byte unchanged. It still **reuses** (never
forks) four `plugins/hermes-mobile` modules — `replay_ring`, `push_engine`,
`device_tokens`, `relay_client` — via `hermes_relay.plugin_bridge`, which puts
the (hyphen-named, not dotted-importable) plugin dir on `sys.path`. So it is
co-located with the mobile plumbing it depends on without being coupled into the
gateway's plugin-load path.

## Module map

```
relay/
  pyproject.toml            # packaging (name: hermes-relay); deps: websockets, httpx
  requirements-dev.txt      # venv/test note (external-volume venvs, 3.13)
  README.md                 # this file
  hermes_relay/
    __init__.py             # public surface (shared types + bus + state)
    types.py        [DONE]  # Frame envelope, Item, GatewayEvent, UpstreamRequest, enums
    bus.py          [DONE]  # EventBus: bounded fan-out pub/sub, 2 topics
    session_state.py[DONE]  # SessionState / SessionStore — resume-as-items accumulator
    plugin_bridge.py[DONE]  # locate + import the reused plugins/hermes-mobile modules
    gateway_client.py[SKEL] # LANE 1 — durable multiplexing WS client (§5)
    reframer.py      [SKEL] # LANE 2 — raw events -> item envelope (§2/§3)
    downstream.py    [SKEL] # LANE 3 — phone WS server + replay ring (§1/§4)
    notifier.py      [SKEL] # LANE 4 — owned-session APNs observer (§6)
    app.py           [SKEL] # composition root: wires the 4 lanes on one bus
    __main__.py      [SKEL] # entrypoint: python -m hermes_relay
  tests/
    test_types.py           # Frame/Item round-trip + seq-stamp guard
    test_session_state.py   # accumulator fold + snapshot
    test_bus.py             # fan-out + drop-oldest overflow
```

`[DONE]` = implemented shared contract/infra. `[SKEL]` = signatures + docstrings;
the four lanes build against the shared types and bus with no cross-lane coupling.

## Dataflow (one bus, two topics)

```
GatewayClient --GatewayEvent--> gateway.events
                                     |
                                  Reframer --Frame(seq=None)--> relay.frames
                                     |                              |
                              SessionStore.apply            DownstreamServer (stamp seq +
                              (snapshot truth)              ReplayRing + send to phone)
                                     |                              |
                                     +----------- Notifier (owned && !foregrounded -> APNs)
```

## The interface each lane implements against

| Lane | Class (module) | Consumes | Produces | Reuses | Key methods to implement |
|---|---|---|---|---|---|
| 1 GatewayClient | `GatewayClient` (`gateway_client.py`) | phone-driven RPC calls | `GatewayEvent` on `gateway.events` | — | `run/connect/close/call`, `session_list/create/resume`, `rest_history`, `prompt_submit`, `approval_respond`, `clarify_respond`, `session_interrupt`, `owns` |
| 2 Reframer | `Reframer` (`reframer.py`) | `GatewayEvent` (`gateway.events`) | `Frame` (seq=None) on `relay.frames` + folds `SessionStore` | `SessionStore` | `run`, `reframe(event)->list[Frame]`, `_tool_item_type` |
| 3 Downstream | `DownstreamServer` + `PhoneConnection` (`downstream.py`) | `Frame` (`relay.frames`) + phone `UpstreamRequest` | wire frames to phone; gateway RPCs | `replay_ring.ReplayRingManager`, `SessionStore` | `start/serve/close`, `handle_upstream`, `PhoneConnection.send_frame/replay/ack`, `session_has_live_phone` |
| 4 Notifier | `Notifier` (`notifier.py`) | `Frame` (`relay.frames`) | APNs pushes | `push_engine.notify` | `run`, `observe(frame)`, `_should_push`, `_fire` |

Contracts the lanes rely on (already implemented in `[DONE]` modules):
- **Envelope/item** — `types.Frame` (`seq` stamped LATE by Lane 3), `types.Item`
  (`completed` is authoritative). Enums: `FrameKind`, `ItemType`, `ItemStatus`,
  `UpstreamMethod`, `RawEvent`.
- **Bus** — `EventBus.publish/subscribe`; topics `TOPIC_GATEWAY_EVENTS`,
  `TOPIC_RELAY_FRAMES`.
- **Resume-as-items** — `SessionStore.apply(frame)` folds truth;
  `SessionStore.snapshot(sid, cursor)` builds the `snapshot` body for a ring-miss
  resync (Lane 3 calls it; Lane 2 keeps it current).
- **Gate** — `DownstreamServer.session_has_live_phone(sid)` is injected into the
  Notifier as the §6 foreground gate.

## Run (local, isolated — NEVER the live gateway on 9119)

```bash
/opt/homebrew/bin/python3.13 -m venv /Volumes/MainData/Developer/hermes-tmp/venvs/relay
source /Volumes/MainData/Developer/hermes-tmp/venvs/relay/bin/activate
pip install -e '.[dev]'         # from relay/
pytest                          # unit tests (no network)

# end-to-end against a STOCK isolated gateway on 9126+ with a temp HERMES_HOME
# (reuse r0-relay-spike/launch_gateway.sh, changing the port to 9126)
export HERMES_RELAY_GATEWAY_TOKEN=...   # HERMES_DASHBOARD_SESSION_TOKEN of the test gateway
export HERMES_RELAY_GATEWAY_PORT=9126
python -m hermes_relay
```

## Non-negotiables

- Never touch the `hermes-mobile` product working tree; build only in this
  worktree / a lane worktree on `/Volumes/MainData`.
- Never touch the live gateway on port **9119**. E2E uses a STOCK isolated
  gateway on **9126+** with a temp `HERMES_HOME`.
- ZERO CORE PATCH: no edits to `tui_gateway/`, `gateway/`, `run_agent.py`,
  `model_tools.py`, or `hermes_cli/` core. The relay is a client that reuses
  `plugins/hermes-mobile` plumbing only.
- No secrets in output/evidence (tokens, APNs creds, bearer tokens).
```
