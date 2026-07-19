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
    gateway_client.py[DONE] # LANE 1 — durable multiplexing WS client (§5)
    reframer.py      [DONE] # LANE 2 — raw events -> item envelope (§2/§3)
    downstream.py    [DONE] # LANE 3 — phone WS server + replay ring (§1/§4) + health
    notifier.py      [DONE] # LANE 4 — owned-session APNs observer (§6)
    app.py           [DONE] # composition root: wires the 4 lanes on one bus + status()
    __main__.py      [DONE] # entrypoint: python -m hermes_relay (argparse CLI)
  scripts/
    run-relay.sh            # canonical launcher (provisions venv, runs the CLI)
    launch_isolated_gateway.sh  # stock isolated gateway on 9133 (E2E upstream)
    launch_relay.sh         # env-var launcher co-located with the isolated gateway
  tests/
    test_types.py           # Frame/Item round-trip + seq-stamp guard
    test_session_state.py   # accumulator fold + snapshot
    test_bus.py             # fan-out + drop-oldest overflow
    test_downstream.py      # seq/ack/replay, upstream RPC, foreign-submit, health
    test_gateway_client.py  # RPC match, demux, reconnect, resume live-id remap
    test_cli.py             # CLI>env>default resolution + live-port refusal
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

## Run locally (isolated)

The one-liner launcher provisions the external-volume venv and starts the CLI:

```bash
# 1) start a STOCK isolated gateway (writes its loopback token to $EVID/.gwtoken)
scripts/launch_isolated_gateway.sh            # gateway on 127.0.0.1:9133

# 2) start the relay against it (reads the token file, serves the phone on 8788)
scripts/run-relay.sh                          # downstream ws://127.0.0.1:8788
```

Or drive `python -m hermes_relay` directly. Every knob is **CLI flag > env var >
default**:

```bash
/opt/homebrew/bin/python3.13 -m venv /Volumes/MainData/Developer/hermes-tmp/venvs/relay
source /Volumes/MainData/Developer/hermes-tmp/venvs/relay/bin/activate
pip install -e '.[dev]'         # from relay/  (runtime: websockets, httpx, pyyaml)
pytest                          # unit tests (no network)

python -m hermes_relay \
  --gateway-url ws://127.0.0.1:9133 \
  --token-file "$EVID/.gwtoken" \
  --listen 127.0.0.1:8788
```

CLI flags: `--gateway-url ws://host:port` (or `--gateway-host/--gateway-port`),
`--token`/`--token-file` (or `HERMES_RELAY_GATEWAY_TOKEN`), `--listen host:port`,
`--health-path /healthz` / `--no-health`, `--log-level`. Automated tests and
development use an isolated gateway on port 9130+; deployment may select 9119.

Env equivalents (used by `launch_relay.sh`): `HERMES_RELAY_GATEWAY_TOKEN`,
`HERMES_RELAY_GATEWAY_URL`, `HERMES_RELAY_GATEWAY_HOST`/`_PORT`,
`HERMES_RELAY_DOWNSTREAM_HOST`/`_PORT`, `HERMES_RELAY_HEALTH_PATH`.

### Health / status surface

The phone-facing port also answers a plain-HTTP **`GET /healthz`** (a normal GET,
not a WS upgrade) with a JSON status snapshot — connections, per-phone seq/ack
watermarks + foreground, owned sessions, and ring/serving state:

```bash
curl -s -H "Authorization: Bearer $(cat \"$EVID/.gwtoken\")" \
  http://127.0.0.1:8788/healthz
# {"listen":"127.0.0.1:8788","connections":0,"phones":[],"owned_sessions":[],
#  "ring_ready":true,"serving":true}
```

## Non-negotiables

- Never touch the `hermes-mobile` product working tree; build only in this
  worktree / a lane worktree on `/Volumes/MainData`.
- Never aim automated tests at the live gateway on port **9119**. E2E uses a
  STOCK isolated gateway on **9130+** with a temp `HERMES_HOME`.
- ZERO CORE PATCH: no edits to `tui_gateway/`, `gateway/`, `run_agent.py`,
  `model_tools.py`, or `hermes_cli/` core. The relay is a client that reuses
  `plugins/hermes-mobile` plumbing only.
- No secrets in output/evidence (tokens, APNs creds, bearer tokens).
```
