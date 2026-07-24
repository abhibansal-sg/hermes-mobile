# hermes-relay

The relay is a small authenticated proxy between HermesMobile and a stock
Hermes gateway.

```text
iPhone -- device token --> relay -- stock gateway token --> Hermes /api/ws + /api/*
```

It has three jobs:

1. authenticate the paired phone locally;
2. forward WebSocket text/binary messages without decoding or reshaping them;
3. proxy HTTP bodies without decompressing or translating them.

Conversation state, session ownership, history, events, retries, and push
semantics stay in stock Hermes and the Hermes Mobile plugin. The relay has no
transcript store, reframer, replay model, or custom event vocabulary.

## Run

Use Python 3.13 and keep development environments on the external volume:

```bash
/opt/homebrew/bin/python3.13 -m venv /Volumes/MainData/Developer/hermes-tmp/venvs/relay
source /Volumes/MainData/Developer/hermes-tmp/venvs/relay/bin/activate
pip install -e 'relay[dev]'

python -m hermes_relay \
  --gateway-host 127.0.0.1 \
  --gateway-port 9127 \
  --token-file /path/to/gateway-token \
  --listen 127.0.0.1:8788
```

The CLI refuses the live gateway port `9119` unless
`--allow-live-gateway` is explicitly supplied. `GET /healthz` reports the
configured upstream and proxy mode.
