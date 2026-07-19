# Hermes Push Gateway v2

The Push Gateway is an HRP/2 service with its own process and database. It has
APNs credentials and App Attest state, but no access to Relay Hub routes,
mailboxes, ciphertext traffic, or application plaintext. Its send API accepts
only an encrypted notification descriptor.

## Local development

Create explicit development credentials; there is no anonymous registration
fallback:

```bash
python -m venv .venv
.venv/bin/pip install -r requirements.txt -r requirements-test.txt
export HPG_TOKEN_MASTER_KEY_B64="$(openssl rand -base64 32)"
export HPG_CAPABILITY_PEPPER_B64="$(openssl rand -base64 32)"
export HPG_DEVELOPMENT_REGISTRATION_TOKEN="$(openssl rand -hex 32)"
export HPG_REQUIRE_APNS=false
.venv/bin/uvicorn push_gateway.app:create_app --factory --port 8081
.venv/bin/pytest -q tests
```

Development-token mode exists only for local protocol work. It is rejected
when `HPG_PRODUCTION=true`.

## Production prerequisites

Before deployment, provision:

- A PostgreSQL database dedicated to this process.
- Two independent random 32-byte secrets: the token master key and capability
  pepper. Token-key rotation uses a bounded versioned keyring; preserve old
  keys until every encrypted row has been rewrapped.
- Apple Team ID, exact App ID (`TEAMID.bundle.id`), allowed bundle IDs, and the
  correct production App Attest environment.
- An APNs token-signing `.p8` key, its key ID, and Team ID. Mount the key as a
  runtime secret; do not bake it into an image.
- Optionally, an Ed25519 activation seed whose public key is configured on the
  official Relay Hub.
- HTTPS at a hostname distinct from the Relay Hub.

The combined [`../compose.hrp2.yml`](../compose.hrp2.yml) supplies separate
processes, databases, networks, migrations, and Caddy TLS ingress. Production
mode refuses SQLite, automatic schema creation, missing APNs/App Attest
configuration, APNs-disabled mode, and every development-attestation fallback.

The edge caps requests at 128 KB and the application independently enforces
the same limit before parsing or database work. The combined Compose gives
Caddy a fixed address on an isolated Push-ingress network and Uvicorn trusts
forwarded identity from that address only. Caddy overwrites public
`X-Forwarded-*` input, and the Gateway has no published host port. If either
ingress subnet changes, update Caddy's fixed IP and `FORWARDED_ALLOW_IPS`
together. The standalone Compose binds to loopback and trusts no non-loopback
proxy by default; set `HPG_FORWARDED_ALLOW_IPS` to the exact proxy address or
CIDR when adding one. Never use a wildcard trust value.

`GET /healthz` is process liveness. `GET /readyz` verifies database readiness.
All request, purge, and readiness database work uses a dedicated non-queuing
pool bounded by `HPG_DATABASE_MAX_CONCURRENCY`; saturation returns `503` with
`Retry-After` instead of growing the process-wide executor queue.

## Envelope-key rotation

The legacy single-key configuration remains supported:

```text
HPG_TOKEN_MASTER_KEY_B64=<standard-base64 32-byte key>
HPG_TOKEN_KEY_VERSION=1
```

For rotation, configure exactly one bounded keyring source instead. The JSON
is an object whose canonical positive integer keys are versions and whose
values are standard-base64 32-byte keys (maximum 16 entries):

```text
HPG_TOKEN_MASTER_KEYS_FILE=/run/secrets/push-token-keyring.json
HPG_TOKEN_KEY_VERSION=2
```

The file in this example contains `{"1":"<old>","2":"<new>"}`. An inline
`HPG_TOKEN_MASTER_KEYS_JSON` is also accepted when a secret-file facility is
unavailable. Do not set the legacy and keyring sources together. New envelopes
always use `HPG_TOKEN_KEY_VERSION`; retained versions are decrypt-only.

Every file-backed private key or keyring must be a regular, single-link file
with mode `0400` or `0600`. The Gateway opens it without following symlinks,
validates that same descriptor, and enforces a small read limit before parsing.
For local Docker Compose on Linux, prepare a deployment copy owned by the
image's fixed runtime identity (`999:999`), because Compose implements local
file secrets as bind mounts and cannot portably apply `uid`, `gid`, or `mode`:

```sh
sudo install -o 999 -g 999 -m 0400 AuthKey_XXXXXXXXXX.p8 /secure/path/apns-key.p8
```

Point `HPG_APNS_KEY_FILE` at that deployment copy. Swarm or an external secret
manager may instead set the mounted secret's ownership and mode directly.

Rotate without token or recovery-receipt loss:

1. Add the new version/key while retaining every version reported in use, set
   it current, apply migrations, and restart every Gateway writer.
2. Run `python -m push_gateway rewrap-token-keys` once against the database.
   It locks and atomically rewraps endpoint tokens plus registration,
   activation, and binding-exchange response envelopes without decrypting
   their payload ciphertext. The command requires
   `HPG_AUTO_CREATE_SCHEMA=false`, preventing a mistyped database URL from
   silently creating and "rewrapping" an empty database.
3. Confirm the command reports only the current version remaining, then remove
   old keys and restart. Startup rejects retirement if any retained row still
   names a missing version.

Run the rewrap only after every writer uses the new current version. The
command prints versions and row counts only; it never prints keys or tokens.

Hub activation signing keys have a parallel overlap mode. The legacy
`HPG_HUB_ACTIVATION_PRIVATE_KEY_B64` continues to mint tokens without a `kid`.
For rotation, use `HPG_HUB_ACTIVATION_PRIVATE_KEYS_FILE` (or the mutually
exclusive `..._JSON`) containing at most eight `{kid: base64-seed}` entries and
select `HPG_HUB_ACTIVATION_KEY_ID`. Keyring-minted tokens carry that `kid` in
their signed canonical payload. Publish both old and new public keys to the Hub
before switching the signer. Once every Push writer selects the new `kid`, the
old private seed can leave the Push keyring; retain its public key on the Hub
until the last old activation token has expired, then retire that verifier too.

## App Attest registration and recovery

`GET /v2/attest/challenge` issues a one-time 32-byte challenge, limited per
source and by a global live-challenge cap. The raw source address is not stored;
the database holds a keyed digest. IPv4-mapped addresses normalize to IPv4 and
IPv6 privacy addresses share their network's `/64` bucket. PostgreSQL issuance
uses a cluster-wide non-waiting transaction advisory lock, so multiple hosted
workers cannot race the count-and-insert decision; lock contention fails closed
with `429` and `Retry-After`.

Registration, activation, and token refresh durably reserve that exact live
challenge and request hash before parsing certificates or verifying ECDSA. An
unknown, expired, changed, or concurrently reserved challenge therefore cannot
trigger expensive crypto. Verification runs off the async server loop behind a
non-queuing `HPG_ATTESTATION_MAX_CONCURRENCY` bound. Exact concurrent retries
wait briefly for the one encrypted receipt and never validate twice; overload
returns a typed `429` without consuming the legitimate challenge. A rejected
verification conditionally releases its reservation, while a crashed lease can
live only until the already bounded challenge expiry.

Registration binds the exact ordered, length-prefixed `HPG2ATTEST` transcript:

```text
challenge
SHA256(canonical APNs token bytes)
bundle ID
APNs environment
preview KEM public key
installation nonce
requested operation
optional opaque Hub route
```

For a first App Attest key, the server validates the attestation object,
certificate chain, key ID, credential, App ID, and environment, then stores its
public key. Assertions receive `SHA256(transcript)` exactly once and must
advance the stored counter.

`POST /v2/endpoints/register` records an encrypted exact-response receipt
before returning. An exact retry with the same challenge and body returns the
same endpoint and bind token without re-verifying or advancing the counter;
changed content conflicts. If that short receipt has expired, a fresh
challenge with the same attested key, installation nonce, bundle/environment,
and preview key plus `attestation: null` recovers the existing endpoint and
rotates its bind token rather than creating a duplicate. An unknown key in
this recovery form is terminal `409 app_attest_initial_required`; an
installation already bound to another committed key is terminal
`409 installation_key_mismatch`. Recovery also tombstones every earlier unused
bind token for that endpoint in the same transaction, so a lost enrollment
response cannot later create stale authority.

`POST /v2/endpoints/token-refresh` uses operation `token-refresh`; it may
reactivate an endpoint disabled by APNs `410 Unregistered` after a valid token
change.

A push-disabled official app uses `POST /v2/hub-activations`. Its separate
`HPG2ACTIVATE` transcript covers only the challenge, bundle/environment,
installation nonce, literal `hub-activate`, and Hub route. It returns a
short-lived Hub activation token and creates no endpoint, APNs-token, or bind
row. Exact retries are recovered from an encrypted receipt.
After receipt expiry it uses the same endpoint with a fresh challenge/assertion
and `attestation: null`; an unknown key receives the same typed 409 initial-key
error.

## Bind exchange and send capability

The one-time endpoint bind token is exchanged at
`POST /v2/bindings/exchange` with a caller-generated opaque `exchange_id` and
the requested subset of `update`, `approval`, and `error`. The Agent must
persist that exchange ID until it durably stores the response. Exact retries
return the same binding ID and capability; changing token, ID, or class set is
a conflict. The capability response is envelope-encrypted in its bounded
recovery receipt.

The database stores only keyed hashes of bind tokens and send capabilities.
Possessing a send capability permits pushes for exactly one endpoint and class
set; it cannot register or replace an APNs token.

If the exchange commits but its capability response is lost, the Agent calls
`POST /v2/bindings/exchange/revoke` with that same exchange ID and bind token.
The endpoint is revoke-only and never discloses the capability. It works before
or after exchange commit and stores a durable content-free tombstone, so a
delayed exchange cannot resurrect a binding after pairing cancellation or
expiry even when the short exact-response receipt has already been purged.

`POST /v2/send` uses the capability as a bearer token. The strict request is:

```json
{
  "v": 2,
  "class": "approval",
  "notification_id": "opaque-random-ID",
  "preview_enc": "base64url-hpke-encapsulation",
  "preview_ct": "base64url-ciphertext",
  "collapse_id": null,
  "expires_at_ms": 1784450000000,
  "sound": true
}
```

The Gateway derives stable `apns-id` and fallback collapse identifiers from
the binding and notification ID. A retry after timeout or process response
loss reuses the identical APNs identifiers, expiration, and body without
charging quota twice. Terminal success and permanent rejection deduplicate;
ambiguous, `429`, `5xx`, and network failures remain safely retryable. APNs
`410 Unregistered` disables the endpoint.

Every durable send reservation maps to exactly one APNs HTTP call. Initial and
retry attempts share the same hourly/day limits in a durable attempt ledger;
retryable and ambiguous receipts use capped exponential backoff and return
`Retry-After` while cooling down. A bounded APNs `Retry-After` seconds or HTTP
date is persisted and takes precedence when it is later than local backoff;
malformed or excessive values cannot pin a receipt indefinitely. Terminal exact retries remain free
deduplications, and expired crash leases remain resumable with the same APNs ID,
collapse ID, expiration, and bytes.

## APNs privacy contract

The complete generic HRN2 outer payload is:

```json
{
  "aps": {
    "alert": {"title": "Hermes", "body": "Hermes needs your attention."},
    "mutable-content": 1,
    "sound": "default"
  },
  "h_v": 2,
  "class": "approval",
  "nid": "opaque-random-ID",
  "enc": "base64url-hpke-encapsulation",
  "ct": "base64url-ciphertext",
  "exp": 1784450000000,
  "collapse": null,
  "sound": true
}
```

The `aps.sound` key is omitted when `sound` is false, while the authenticated
outer `sound` boolean is always present. There is never an actionable APNs
category. The Notification Service Extension may replace the generic fallback
and attach a category only after authenticated decryption.

Serialized payloads over 3,900 bytes are rejected, retaining headroom below
Apple's 4,096-byte regular-notification limit. APNs tokens are envelope-
encrypted with AES-256-GCM data keys wrapped by the operator master key.

Logs contain only a binding-ID hash, class, byte count, provider status, and
prune decision. They never contain APNs tokens, assertions, capabilities,
preview plaintext, provider JWTs, or token-bearing APNs URLs.

## Verification boundary

The automated suite covers transcript encoding, real App-Attest-format assertion
verification, one-time counter semantics, exact-response recovery, endpoint
recovery, activation-only issuance, bind idempotency, payload shape/size,
stable APNs retry identifiers, APNs response classification, rate/capacity
limits, request-size limits, and storage/log privacy. It does not claim a real
Apple attestation, TestFlight install, APNs delivery, or Notification Service
Extension execution; those require Apple credentials and physical-device or
TestFlight evidence.
