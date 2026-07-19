# hermes-relay

`hermes-relay` is the trusted, co-located Agent component of Hermes Relay
Protocol v2 (HRP/2). It connects to the stock Hermes Gateway on loopback and to
a content-untrusted Relay Hub, giving each paired iOS device an independent,
authenticated, end-to-end encrypted mailbox and durable stream.

The stock Gateway is not modified. Gateway credentials never leave this host;
Hub, Push Gateway, APNs, and network intermediaries see routing metadata and
ciphertext, not Hermes content.

Normative contract and operations:

- `docs/mobile-relay/HRP-V2.md`
- `docs/mobile-relay/PAIRING-V2.md`
- `docs/mobile-relay/PUSH-V2.md`
- `docs/mobile-relay/OPERATIONS.md`
- `docs/mobile-relay/THREAT-MODEL.md`

## HRP/2 capabilities

- X25519/HKDF-SHA256/ChaCha20-Poly1305 authenticated HPKE per message.
- Strict shared Python/Swift wire schemas and conformance fixtures.
- Protected, profile-scoped SQLite identity, pairing, route, grant, stream,
  outbox, replay, operation, approval-capability, and projection state.
- One independently revocable identity and send worker per device.
- Durable `stream_id` plus revision/offset-safe deltas and authoritative
  checkpoints.
- Crash-safe exact-idempotent pairing, Hub requests, delivery receipts,
  operations, Push binding, and revocation.
- Encrypted per-device notification previews; Push never receives titles,
  bodies, session IDs, request IDs, or action authority in plaintext.
- Explicit v1 compatibility. HRP/2 never silently downgrades to v1.

## Package layout

```text
relay/
  pyproject.toml
  hermes_relay/
    __main__.py          explicit v1/v2 process entry point
    gateway_client.py    stock Gateway WS + authenticated REST client
    reframer.py          Gateway events -> item lifecycle
    downstream.py        legacy v1 local transport
    v2/
      app.py             HRP/2 composition root
      protocol.py        strict schemas and canonical encoding
      crypto.py          authenticated HPKE + envelope signatures
      protection.py      Keychain/DPAPI/keyring/fallback protection
      storage.py         crash-consistent local authority
      enrollment.py      provisional + operator activation lifecycle
      pairing.py         PairInit/PairAccept/PairConfirm state machine
      hub_client.py      opaque Hub transport
      push_client.py     encrypted Push descriptor transport
      device_router.py   independent durable per-device senders
      inbound.py         decrypt/replay/receipt/dispatch pipeline
      rpc.py             durable operation ledger + Gateway mapping
      projection.py      revisioned items/checkpoints/session aliases
      notification_sender.py
      revocation.py
  tests/
    v2/
```

## Run HRP/2 directly

Use the operator CLI for normal installation:

```bash
hermes plugins enable hermes-mobile
hermes mobile enable \
  --hub https://relay.example \
  --push-url https://push.example
hermes mobile pair
hermes mobile status --json
```

The foreground package entry point is useful for isolated development:

```bash
python -m hermes_relay \
  --protocol v2 \
  --gateway-host 127.0.0.1 \
  --gateway-port 9127 \
  --token-file "$TEST_HERMES_HOME/dashboard.token" \
  --hub-url http://127.0.0.1:9130 \
  --push-url http://127.0.0.1:9131 \
  --state-dir "$TEST_HERMES_HOME/mobile-relay" \
  --allow-insecure-local-services
```

For self-hosted operation without a Push Gateway, the first activation needs an
owner-only operator token file:

```bash
chmod 600 "$TEST_HERMES_HOME/hub-enrollment.token"
hermes mobile enable \
  --hub http://127.0.0.1:9130 \
  --no-push \
  --hub-enrollment-token-file "$TEST_HERMES_HOME/hub-enrollment.token" \
  --allow-insecure-local-services
```

Only file paths appear in service definitions and `config.yaml`; token contents
never appear in argv, environment, config, or logs.

HRP/2 normally connects to the real co-located Gateway on loopback port 9119.
Tests and development probes must use isolated ports 9123+ and must never touch
a user's live 9119 process. The legacy v1 entry point retains its runtime
refusal of 9119 as an additional test-safety guard.

## Test and package

```bash
uv sync --extra dev --python 3.13
.venv/bin/python -m pytest -q
uv build
```

Runtime and build dependencies are exact-pinned in `pyproject.toml`. Release
verification installs both the wheel and sdist into clean environments, imports
the v2 modules, and exercises the CLI parser.

## Security boundaries

- No edits to stock Gateway/TUI/Desktop core are required by this package.
- The Gateway endpoint must be loopback; HRP/2 refuses a remote Gateway host.
- v2 accepts the real loopback 9119 Gateway only when authentication is loaded
  from `--token-file`; it refuses argv/environment token sources.
- Pair secrets, private keys, Hub/Push capabilities, APNs tokens, prompt text,
  tool data, session identifiers, approval plaintext, and encrypted envelopes
  are never emitted to normal logs.
- `hermes mobile disable` retains authority for reversible shutdown.
  `hermes mobile disable --purge` requires explicit confirmation, revokes remote
  authority first, then erases OS credential handles and local state.
