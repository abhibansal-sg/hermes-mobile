# Hermes Relay Hub v2

The Relay Hub is the content-blind HRP/2 rendezvous service. It knows opaque
route identifiers, grants, transport classes, expiry, and encrypted blobs. It
does not import Push Gateway code, hold APNs credentials, or receive inner
session, turn, item, prompt, tool, preview, or approval fields.

SQLite is supported for local single-process development. Production mode
requires PostgreSQL and explicit migrations.

## Local development

From this directory:

```bash
python -m venv .venv
.venv/bin/pip install -r requirements.txt -r requirements-test.txt
HRH_OPERATOR_ENROLLMENT_TOKEN="$(openssl rand -hex 32)" \
  .venv/bin/uvicorn relay_hub.app:create_app --factory --port 8080
.venv/bin/pytest -q tests
```

The default local database is `./data/relay-hub.db`. Do not use the local
defaults on a public interface.

## Production startup

The combined [`../compose.hrp2.yml`](../compose.hrp2.yml) starts separate Hub
and Push Gateway processes, separate PostgreSQL databases, one-shot migrations,
and TLS ingress. Copy `.env.example` values into a deployment secret store,
configure DNS for distinct Hub and Push Gateway hostnames, then run from the
repository root:

```bash
docker compose --env-file /secure/path/hrp2.env \
  -f server/compose.hrp2.yml up -d
```

When notifications are intentionally disabled, use the standalone
[`../compose.hub-only.yml`](../compose.hub-only.yml). It contains no Push/APNs
services, routes, secrets, or required variables:

```bash
docker compose --env-file /secure/path/hrp2-hub.env \
  -f server/compose.hub-only.yml config --quiet
docker compose --env-file /secure/path/hrp2-hub.env \
  -f server/compose.hub-only.yml up -d
```

The Hub-only environment needs `HRH_POSTGRES_PASSWORD`, `HRH_PUBLIC_HOST`,
`ACME_EMAIL`, and either `HRH_OPERATOR_ENROLLMENT_TOKEN` or
`HRH_ACTIVATION_PUBLIC_KEY_B64`. Pair Agent Relays with
`hermes mobile enable --hub https://relay.example --no-push` (and the
owner-only enrollment-token file for first activation); no Push hostname or
Apple credential is involved.

Production is fail closed. `HRH_PRODUCTION=true` requires all of:

- PostgreSQL, not SQLite.
- `HRH_AUTO_CREATE_SCHEMA=false` and a successful migration.
- Either an operator enrollment token or an Ed25519 activation public key.
- No development activation token.
- HTTPS/WSS at the edge. Do not expose port 8080 directly.

All synchronous SQLAlchemy operations run in a dedicated bounded worker pool;
request and WebSocket event loops never execute database I/O. The defaults are
8 concurrent database operations (`HRH_DATABASE_MAX_CONCURRENCY`) and a
1-second admission wait (`HRH_DATABASE_ACQUIRE_TIMEOUT_SECONDS`). Saturation
returns `503 database_busy` with `Retry-After: 1`; WebSockets close retryably
with code 1013 when database admission is unavailable. Work is admitted before
submission, so there is no unbounded executor queue, and a disconnected request
retains its permit until its transaction actually finishes.

The Caddy example limits Hub request bodies to 400 KB; the application enforces
the same limit before JSON parsing or database work. The combined Compose gives
Caddy a fixed address on an isolated Hub-ingress network and configures Uvicorn
to trust forwarded client identity from that address only. Caddy overwrites
incoming `X-Forwarded-*` values from the public request, and the Hub has no
published host port. If either ingress subnet changes, update Caddy's fixed IP
and `FORWARDED_ALLOW_IPS` together. Never use `FORWARDED_ALLOW_IPS=*` or expose
port 8080 directly.

`GET /healthz` is process liveness. `GET /readyz` verifies database readiness.

## Authentication and enrollment

Except for public provisional enrollment and phone submission/polling with a
pair transport bearer token, route operations use these headers:

```text
X-Hermes-Route: rte_...
X-Hermes-Timestamp: Unix epoch milliseconds
X-Hermes-Nonce: unpadded base64url of 16 random bytes
X-Hermes-Signature: unpadded base64url Ed25519 signature
```

The signed request transcript is `HRH2REQ` followed by 32-bit big-endian
length-prefixed values for uppercase method, URL path, route, decimal
timestamp, raw nonce, and `SHA256(raw request body)`. Nonces are recorded only
after signature verification. Pairing, credentials, and ciphertext responses
carry `Cache-Control: no-store`.

Provisional enrollment is deliberately narrow:

```text
POST /v2/enroll/provisional
{enrollment_id, route_type, auth_public_key}
```

An exact retry within the ten-minute lifetime returns the same route. Reusing
an enrollment ID with a different key or route type is a conflict. A
provisional Agent route may only create, read, or cancel its own pair offer. It
cannot create grants, send ordinary traffic, accept/confirm pairing, or revoke
routes until activation through `POST /v2/enroll/activate`.

Official deployments verify a short-lived Ed25519 activation token minted by
the separately deployed, App-Attest-protected Push Gateway. Self-hosters may
instead send `X-Hermes-Enrollment-Token` with the operator token.

Signing-key overlap is supported without changing the two-segment activation
token format. `HRH_ACTIVATION_PUBLIC_KEYS_JSON` (or the mutually exclusive
`HRH_ACTIVATION_PUBLIC_KEYS_FILE`) is a JSON object of at most eight
`{"kid":"standard-base64-32-byte-Ed25519-public-key"}` entries. New tokens
carry the selected `kid` in their signed payload; an unknown `kid` never falls
back to another key. Tokens minted before key IDs existed are bounded-verified
against the overlap set. `HRH_ACTIVATION_PUBLIC_KEY_B64` remains supported as
the `legacy` key.

## Two-way pairing transaction

Pairing is a bounded transaction with response-loss-safe retries:

1. The Agent signs `POST /v2/offers` with an opaque `ofr_...` offer ID, an
   opaque `off_...` phone route, and `SHA256(raw 32-byte transport token)`.
2. The phone posts one opaque PairInit HPKE pair to
   `POST /v2/offers/{offer_route}/messages` using that raw transport token as a
   bearer credential. `message_hash` is `SHA256(raw enc || raw ct)`.
3. The Agent signs `GET /v2/offers/{offer_id}`, then creates one pending device
   route with signed `POST /v2/routes` and two pending directional grants with
   `POST /v2/grants`.
4. The Agent stores opaque PairAccept with signed
   `POST /v2/offers/{offer_id}/accept`. `response_hash` uses the same raw
   `enc || ct` convention.
5. The phone polls `GET /v2/offers/{offer_route}/accept` with the transport
   bearer token. Before expiry, that pending device route may send exactly one
   new control envelope to the owning Agent, plus an exact retransmission.
6. After receiving that control proof, the Agent signs
   `POST /v2/offers/{offer_id}/confirm`. One database transaction activates the
   device route and both grants and removes the offer.

Cancel or expiry revokes all pending pairing state. Exact retries return the
same offer, route, grant, acceptance, or confirmation result; the service
rejects the same idempotency identity with changed content. A bounded
hash-only confirmation receipt makes a retry safe even after the offer was
deleted.

## Messaging, quotas, and revocation

`POST /v2/messages` accepts only the strict signed HRH2 envelope. The primary
idempotency key is `(destination_route, message_id)`. Exact replay is success;
changed ciphertext with the same key is `409 message_id_conflict`.

Per destination, durable storage is capped at 256 records and 4 MiB, with 64
records and 512 KiB reserved for `command` and `control`. Durable receipt and
accepted-message rate limits also reserve capacity for those classes.
`realtime` is never stored offline. A slow WebSocket loses realtime frames
first; if its durable queue overflows, the Hub emits `reconnect_required` and
closes it so the client can reconnect and replay the durable mailbox. Other
connections are not blocked.

Live sockets are also capped independently of Uvicorn: 512 process-wide by
default (`HRH_MAXIMUM_SOCKET_CONNECTIONS`) and 4 per route
(`HRH_MAXIMUM_SOCKET_CONNECTIONS_PER_ROUTE`). Each socket queue is bounded by
both `HRH_SOCKET_QUEUE_DEPTH` and `HRH_SOCKET_QUEUE_MAX_BYTES`; when the byte
setting is omitted it equals the durable mailbox byte budget (4 MiB by
default). `HRH_SOCKET_QUEUE_TOTAL_MAX_BYTES` caps serialized queued frames
process-wide at 64 MiB by default. Accounting uses the exact compact UTF-8 JSON
text sent on the wire, including envelope wrappers and base64 expansion. The
Hub reserves enough room for one `reconnect_required` control frame per live
socket, so either a record or byte overflow deterministically drains that
socket's queue and closes it with WebSocket code 1013. Dequeue and disconnect
release both per-socket and process-global accounting.

The recipient calls `POST /v2/acks` only after decrypt, validation, and local
commit. `DELETE /v2/routes/{device_route}` may be signed by that route or its
owning active Agent. It atomically revokes the route, both grants, and pending
mailbox rows; owner retries return the same sorted grant IDs.

## Retention and recovery

Provisional-enrollment rate events are enforced transactionally in the shared
database, alongside the global live-route cap. The Hub stores only a keyed
32-byte source bucket, never the raw peer address; IPv6 privacy addresses are
aggregated by /64. At most 20,000 live source buckets are tracked by default
(`HRH_MAXIMUM_PROVISIONAL_RATE_LIMIT_SOURCES`), after which new sources fail
closed. Exact enrollment retries are resolved before quota admission and return
the original route without consuming another event.

Expired messages, enrollment events, nonces, pair offers, and bounded receipts
are purged every minute. Keep PostgreSQL backups and WAL retention within the privacy policy;
deleting a live row does not erase older backups.

SQLite deletion does not guarantee immediate physical erasure from snapshots
or WAL files. During a maintenance window with the Hub stopped, run
`deploy/purge-and-vacuum.sh` with `HRH_SQLITE_PATH` set for best-effort local
cleanup.

Logs contain only a truncated opaque message-ID hash, transport class, byte
count, and delivery state. Ciphertext and enrollment credentials are not
logged.

## Verification boundary

The automated suite covers signed requests/envelopes, enrollment abuse limits,
the full first-device pairing transaction, idempotent response recovery,
mailbox/rate reserves, slow-socket overflow, revocation, request-size limits,
and storage/log privacy. It does not prove internet deployment, multi-region
operation, or Apple platform behavior.
