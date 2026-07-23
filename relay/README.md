# hermes-relay

The co-located network edge for Hermes Mobile. It has two jobs:

1. authenticate the phone and byte-forward stock Hermes WS/HTTP traffic;
2. observe the same stock gateway events as Desktop and hand the small
   notification-worthy subset to the existing APNs engine.

It does not own sessions, transcripts, replay, event translation, or custom
status vocabulary.

## Data flow

```text
iPhone ── stock WS/HTTP ──> relay ── byte-for-byte ──> stock gateway
                              │
                              └── stock event observer ──> existing APNs engine
```

The gateway-side `hermes-mobile` adapter remains deliberately small. It uses
the stock plugin hooks to fan out owner-written stock event frames. The relay
renews a 15-second lease that:

- enables that existing fan-out while the relay is alive;
- makes the gateway-side APNs consumer stand down to avoid duplicates;
- expires automatically so gateway-side notification delivery resumes if the
  relay dies.

No Hermes core files are patched.

## Readiness

The authenticated `GET /healthz` response includes:

```json
{
  "service": "hermes_relay",
  "mode": "transparent_proxy",
  "notifications": {
    "connected": true,
    "claimed": true,
    "events_seen": 42,
    "tracked_sessions": 0
  }
}
```

`connected:true` proves the stock-event observer is connected.
`claimed:true` proves the gateway accepted the short notification lease.
Both must be true before relay-owned APNs delivery is ready.

## Local verification

Use an isolated gateway on port 9126 or higher. The CLI refuses the live
gateway port 9119 unless the supervised service passes
`--allow-live-gateway`.

```bash
cd relay
python3.13 -m venv /Volumes/MainData/Developer/hermes-tmp/venvs/relay
source /Volumes/MainData/Developer/hermes-tmp/venvs/relay/bin/activate
pip install -e '.[dev]'
pytest
```

The transparency tests assert that WS text/binary frames and HTTP bodies are
not parsed or rewritten.

## Supervised service

The only sanctioned daily-driver relay is the launchd service
`ai.hermes.relay`, serving the phone on port 8788 and dialing the live gateway
on loopback:

```bash
relay/scripts/decommission-old-relays.sh
relay/scripts/install-service.sh install
relay/scripts/install-service.sh status
```

Logs are written to `~/Library/Logs/Hermes/relay.log`.
