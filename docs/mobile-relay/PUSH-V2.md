# HRP/2 push notifications

The Push Gateway is deliberately separate from the Relay Hub. The Hub routes
chat/control ciphertext; the Push Gateway stores APNs endpoints and sends
encrypted previews. Compromise of either service alone must not expose Hermes
content.

For pairing, the official phone uses the single Hub origin carried by the QR.
The deployment edge forwards only the four phone registration/activation paths
to the Push Gateway. Agent-only binding, send, and revocation paths are not
available through that alias. Operators may additionally expose a distinct
Push hostname for the Agent Relay; the services remain separate either way.

## Endpoint registration

The app obtains a short-lived one-time challenge, then submits an App Attest
bound request to `POST /v2/endpoints/register`. The assertion transcript binds:

```text
challenge
SHA256(APNs device token)
bundle ID
APNs environment
preview public key
installation nonce
requested operation
```

The server verifies the App ID/environment, attested key, assertion counter,
challenge freshness, and exact request digest. A first registration may carry
attestation; later requests use the stored attested key and monotonically
increasing assertions.

The response contains an opaque endpoint ID, a one-time bind token, its expiry,
and (for hosted first pairing) a short-lived Hub activation token. The app
persists the exact request before sending. Exact response lookup occurs before
re-verifying a consumed assertion so a lost response can be recovered without
violating the App Attest counter contract.

An attested installation can recover/re-register after a lost receipt or
expired bind token without knowing the old endpoint ID. A changed APNs token
uses the authenticated token-refresh flow.

## Push-disabled activation

The official app can activate a first hosted Agent without enabling
notifications:

```text
POST /v2/hub-activations
```

The exact request contains only `challenge`, App Attest key/assertion or initial
attestation, bundle/environment, installation nonce, and target Hub route. Its
domain-separated transcript uses `HPG2ACTIVATE` and the literal operation
`hub-activate`. The response contains only an activation token and expiry. No
APNs token, endpoint ID, bind token, preview key, or send capability is created.

## Binding exchange

The app sends its one-time bind token to the Agent inside encrypted `PairInit`.
The Agent exchanges it with a persisted `exchange_id`. The Push Gateway returns
one binding ID and one random 256-bit send capability, scoped to that Agent
installation, endpoint, bundle/environment, and allowed notification classes.
Only a hash of the send capability is stored server-side.

The capability cannot register or change an APNs token. Revocation deletes the
binding and erases the Agent's protected local capability only after the remote
revocation attempt is durably accounted for.

An exchange response can be lost after the Push Gateway has committed the
binding but before the Agent stores the returned capability. To close that
boundary, the Agent retains the original `exchange_id` and bind token and may
call `POST /v2/bindings/exchange/revoke`. This revoke-only endpoint never
returns a send capability. It is idempotent both before and after exchange
commit, and its durable content-free tombstone prevents a delayed exchange
request from recreating the binding after pairing has been cancelled or
expired. The Agent erases those protected cleanup credentials only after the
remote revocation is confirmed.

## Encrypted send

The Agent sends only the strict descriptor below:

```json
{
  "v": 2,
  "class": "approval",
  "notification_id": "nid_opaque",
  "preview_enc": "base64url-hpke-encapsulation",
  "preview_ct": "base64url-authenticated-ciphertext",
  "collapse_id": "opaque-or-null",
  "expires_at_ms": 1784450000000,
  "sound": true
}
```

It does not send title, body, session/turn/item/request IDs, approval command,
model output, or tool output. Presence is evaluated separately for each
destination device and may defer a terminal/error notification while that
device holds a fresh renewable foreground lease; it never discards the
notification. The exact encrypted descriptor remains in the Agent's durable
per-device outbox and is sent after a background update or lease expiry.

The Push Gateway constructs a generic APNs alert with `mutable-content: 1` and
opaque HRP/2 fields (`h_v`, `class`, `nid`, `enc`, `ct`, `exp`, `collapse`,
`sound`). The outer payload never installs an approval category. The same
stable APNs ID and collapse ID are reused across ambiguous/transient retries.
Each notification ID also has one database-fenced APNs attempt lease. An exact
concurrent request receives a retryable `425` without making a second provider
call; an expired attempt can be reclaimed with a new random fence token, and a
late older completion cannot overwrite the newer terminal receipt.

## Notification Service Extension

The NSE performs no network access. It loads only preview keys from the shared
Keychain group, decrypts with the pinned Agent agreement public key, verifies
class/ID/expiry, and then sets title, body, thread token, and category.

Any failure returns a generic non-actionable notification. The main app
re-decrypts the original opaque descriptor before enqueuing an action; the NSE
is not treated as a trust oracle.

An approval preview contains a random per-device capability, request/session
scope, allowed decisions (`approve_once`, `deny`), destructive flag, device ID,
and key generation. Approve and Deny require device authentication. Destructive
inline actions require an additional local-authentication check; otherwise the
user opens the app.

## Storage and logging

Production APNs tokens are encrypted at rest with an operator-provided/KMS
master key. Exact response receipts containing capabilities are encrypted and
expire. Logs must never contain APNs tokens, assertions/attestations, provider
JWTs/private keys, bind/send capabilities, or preview plaintext.

Preview plaintext is limited to 1,200 UTF-8 bytes; serialized APNs payloads are
kept below 3,900 bytes and rejected above Apple's 4,096-byte limit.
