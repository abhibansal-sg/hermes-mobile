# HRP/2 pairing

Pairing enrolls one device key set and creates two route grants. It never puts
a Gateway token, Agent route credential, push send capability, or session
identifier in the QR code.

## Offer

`hermes mobile pair` persists a five-minute offer by default. The QR is compact
JSON or CBOR with the exact fields below; it is not a URL with query secrets.

```json
{
  "v": 2,
  "hub": "https://relay.example",
  "relay_route": "rte_agent",
  "offer_route": "off_mailbox",
  "offer_id": "ofr_random",
  "offer_transport_token": "base64url-32-bytes",
  "expires_at_ms": 1784450000000,
  "relay_kem_pub": "base64url-x25519-public-key",
  "relay_sign_pub": "base64url-ed25519-public-key",
  "pair_secret": "base64url-32-bytes"
}
```

The transport token authorizes only the offer mailbox. The pairing secret
authenticates only the `PairInit` transcript. Neither becomes a long-term
device credential.

## Hosted first-device activation

A new hosted Agent has a short-lived provisional route. That route may only:

- create, read, and cancel a tightly quota-bound pairing offer;
- receive the offer-ready signal or poll its offer;
- redeem a first-device activation token.

It cannot create general routes/grants, send messages, open a normal socket,
or become durable without activation.

If push is enabled, endpoint registration returns the activation token along
with a one-time push bind token. If push is disabled, the official app obtains
only an activation token from `POST /v2/hub-activations`; that endpoint contains
no APNs token or push capability. A self-hosted Hub may instead use an operator
enrollment token, in which case `hub_activation_token` is explicitly `null`.

The QR has one public bootstrap origin (`hub`) by design. In the hosted
deployment, that origin forwards only `/v2/attest/challenge`,
`/v2/hub-activations`, `/v2/endpoints/register`, and
`/v2/endpoints/token-refresh` to the separately deployed Push Gateway. It does
not forward binding exchange, send, or revocation authority. This keeps the QR
exact and lets the phone obtain attested enrollment material without merging
the Hub and Push applications or their databases.

## Duplex sequence

1. Agent persists an offer and idempotently registers it with the Hub.
2. Phone scans the QR and creates three key pairs: agreement, signing, and
   notification-preview agreement.
3. Phone persists the exact pending transaction before network access.
4. Phone creates `PairInit`, including nullable push/activation tokens and an
   HMAC of the complete transcript using `pair_secret`.
5. Phone HPKE-base-encrypts `PairInit` to the Agent and posts the exact
   `{v, offer_id, enc, ct}` to `/v2/offers/{offer_route}/messages` with the
   one-time bearer.
6. Agent signed-polls `/v2/offers/{offer_id}`, authenticates/decrypts the
   message, atomically claims the device-key hash, and displays the same
   six-digit verification code as the phone.
7. After explicit confirmation (or explicit `--auto-approve`), the Agent
   activates its provisional route if necessary.
8. Agent creates one pending device route and two pending grants, exchanges the
   optional push bind token, and persists the exact authenticated-HPKE
   `PairAccept` before posting it.
9. Phone bearer-polls `/v2/offers/{offer_route}/accept`. A waiting response is
   exactly `{"status":"waiting","offer_id":"..."}`.
10. Phone verifies/decrypts `PairAccept`, persists the account identity, and
    creates one normal signed HRP/2 `pair.confirm` control envelope.
11. Agent applies that envelope and calls the signed confirm endpoint with both
    ciphertext hashes and the device route.
12. Hub atomically activates route and grants, removes live offer authority,
    and retains only a non-secret, time-limited exact-response receipt.
13. Agent activates the local device and erases pairing secrets.

## Crash and retry rules

Every mutating request has a stable request identity and exact-response
receipt. If a response is lost, the caller resends the byte-identical request.
The Hub returns the original result or a conflict; it never creates a second
route, grant, offer message, or activation.

The phone persists the generated keys, `PairInit`, mailbox hashes,
`PairAccept`, and `PairConfirm` boundaries. Killing the app must resume the
same transaction, not generate new keys or a different cryptographic request.

The Agent retains an offer after an ambiguous registration response and retries
that exact offer. Cancelling/expiry revokes pending routes, grants, and push
bindings. The offer is associated with its provisional device before any
grant or Push exchange is attempted, so terminal cleanup can atomically
fail-close every local authority and queue the exact remote work. If a Push
exchange response was lost, cleanup uses its persisted exchange ID and bind
token through the revoke-only exchange endpoint; the Push tombstone prevents a
late exchange request from resurrecting the binding. Pairing and cleanup
secrets are erased only after their local terminal state and required remote
revocation confirmations are durable.

## Verification and revocation

Interactive pairing displays the device name and a six-digit code derived from
the complete transcript. Device records are independent: revoking one device
atomically revokes its Hub route/grants, local key authority, pending mailbox
traffic, approval capabilities, and push binding without affecting another
paired device.
