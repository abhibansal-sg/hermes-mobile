# Hermes Relay Protocol v2 — Architecture and Implementation Proposal

**Status:** IMPLEMENTATION CANDIDATE — isolated branch; not production-certified
**Published:** 2026-07-19
**Implementation base:** `origin/wave2/relay-turn-elements` at `ab570aa74`

This document preserves the complete architecture verdict and turns it into the
normative design candidate for a secure hosted Hermes mobile relay. It is
intentionally published on an isolated branch based on the newest focused relay
work. It does not modify or supersede that implementation branch, and it does
not claim that the current v1 local relay prototype already satisfies HRP/2.

This file preserves the original verdict and design rationale. The current
implementation contract and operator guidance are indexed in
[`docs/mobile-relay/README.md`](README.md); the machine-readable wire source of
truth is `protocol/hrp2/schema.json`. Physical-device APNs/App Attest/TestFlight
validation remains a release gate and is not claimed by this branch. Local
automated evidence and the remaining external gates are recorded in
[`VERIFICATION.md`](VERIFICATION.md).

---

# Verdict

**Approve the four-component direction. Reject the current draft as the implementation contract.**

The proposal has the right trust boundary: a trusted process beside the gateway, a content-blind rendezvous service, a separate APNs sender, and device-side decryption. But it currently understates the work required to turn the repository’s local relay prototype into a secure, durable, multi-device hosted system.

My assessment:

| Area | Assessment |
|---|---:|
| Architectural direction | **8/10** |
| Fit with the existing repository | **6/10** |
| Security specification | **5/10** |
| Reliability specification | **3/10** |
| Ready to implement as written | **3/10** |

The most important design correction is this:

> **Do not run the current relay-phone JSON stream through the existing hosted tunnel and call it E2EE. Ratify a v2 protocol with durable per-device streams, authenticated per-message encryption, idempotent operations, explicit pairing state, and an encrypted notification envelope.**

The current repository already has useful pieces:

- A co-located `GatewayClient`, `Reframer`, `SessionStore`, downstream relay server, and notifier.
- An item-lifecycle representation with `started → delta → completed`.
- A Swift relay client and item reducer.
- A durable iOS WorkRepository/outbox that should become the phone-side command authority.
- An existing APNs relay and reverse tunnel that can be mined for operational code, but not used as the new privacy boundary.

The four relay lanes and item-stream foundation are real, not hypothetical. The
Swift path is wired into the live app behind the default-off
`TransportPath.relay` feature flag, although some source comments still
incorrectly describe it as mock-only. HRP/2 must replace that prototype path
through an explicit migration; it must not assume the live wiring is absent.

---

# 1. Repository audit: critical findings

## P0 — unauthenticated phone fan-out

The current `DownstreamServer` accepts a WebSocket, gives it a random connection ID, and starts processing requests without a device handshake, device identity, authorization check, or session ACL.  Every relay frame is then dispatched to every connected phone.

That is tolerable only as an isolated local prototype. It is catastrophic when placed behind a hosted rendezvous service:

- Any holder of a shared tunnel credential can receive all sessions.
- Revocation cannot be enforced per device.
- A device cannot be restricted to its own route.
- “Every phone independently listed and revoked” is impossible with the current connection model.

**Required fix:** the Agent Relay must terminate an authenticated per-device E2EE channel and maintain a separate stream, subscription set, outbox, sequence space, and revocation state for each device.

---

## P0 — the existing Swift and Python wire contracts do not agree

On the audited implementation base, `origin/wave2/relay-turn-elements` at
`ab570aa74`:

- Swift sends prompt text as `prompt`; Python reads `text`.
- Swift approval sends `{request_id, approved}`; Python requires `session_id`, `request_id`, and `decision`.
- Swift clarification sends `{request_id, response}`; Python requires `session_id`, `request_id`, and `text`.
- Swift documents `open` as causing a snapshot frame, while Python currently just returns raw history in the JSON-RPC response.
- Python declares a `foreground` upstream method; Swift’s relay method enum does not contain it.

The open relay-turn-elements work recognizes and corrects some gateway parameter mappings, including mapping approval to the gateway’s `choice` field and clarification to `answer`.  Those corrections need to be absorbed, but that branch does not solve the hosted architecture.

**Required fix:** generate Python and Swift protocol fixtures from one checked-in schema and reject unknown/malformed required fields instead of relying on free-form dictionaries.

---

## P0 — the current sequence model is unsound across reconnects

The server’s `seq` is explicitly per connection.  A new socket begins again from zero, and unregistering drops that connection’s replay ring.

The Swift client, however, retains its item store, sequence watermark, and ACK watermark across reconnects.

Consequences:

- A new server frame with sequence 1 can be classified as a stale duplicate against an old watermark of 2,000.
- ACKs can refer to a previous connection’s sequence space.
- The server attempts to infer this situation from `last_seq > head`, but the protocol has no durable stream identity.
- A malicious relay can reset or splice sequence spaces without the client knowing whether it is a restart, replay, or new stream.

**Required fix:** introduce a random, persistent `stream_id` per Agent/device stream. Sequence numbers are meaningful only inside that stream ID. A reset requires a new `stream_id` plus an authoritative checkpoint.

---

## P0 — duplicate replay corrupts streamed text

`RelayItemStore.apply` classifies duplicate frames but still applies their payloads.  Text deltas are append operations.

Therefore replaying the same `item.delta` duplicates text. The implementation’s claim that replay is idempotent is false for deltas.

Example:

```text
Frame 91: append "hel"
Frame 92: append "lo"
Replay frame 91: append "hel"

Result: "hellohel"
```

`item.completed` may eventually heal the text, but:

- The user sees corrupted live text.
- A turn that crashes before completion stays corrupted.
- Tool/list patches can be applied twice.
- A malicious hub can repeatedly replay a valid encrypted delta to create UI churn.

**Required fix:** every mutable item needs a revision and every append needs an expected byte offset. Duplicate revisions must be ignored before applying payload content.

---

## P0 — the Swift item store mixes sessions

The current Swift reducer has one global `itemsByID`, one global arrival order, and one global sequence watermark.

Although synthesized item IDs currently contain the session ID, this is not a valid partitioning mechanism. It breaks:

- Per-session replacement snapshots.
- Session deletion and tombstones.
- Separate stream or subscription state.
- Cache eviction.
- Correct reconciliation when two sessions contain externally supplied matching IDs.

**Required fix:** storage must be keyed structurally by `(relay_account_id, session_id, item_id)`, never merely by a string convention embedded in `item_id`.

---

## P0 — synthesized IDs collide after Agent Relay restart

The current reframer synthesizes turn and item IDs from in-memory counters such as `<sid>:t1` and `<sid>:i1`.   The session accumulator is explicitly in-memory only.

After a relay restart, a session can produce `<sid>:i1` again. A phone with cached data may then replace an old item with unrelated new content.

**Required fix:** generated IDs must be random persistent UUIDs or include a persisted Agent epoch. Turn/item allocation and the resulting projection must be committed transactionally.

---

## P0 — “zero-knowledge Push Gateway” is incompatible with the current notifier

The current notifier constructs plaintext notification titles and bodies and puts real session, turn, and item identifiers into the outgoing payload.  The hosted push service likewise constructs plaintext APNs content containing session identifiers and caller-provided metadata.

This is not something that can be fixed by setting `allow_custom_body=false`. A generic body would hide preview text, but:

- Session IDs and action payloads remain visible.
- The push service still receives the plaintext fields.
- There is no encrypted preview envelope.
- The notification action path still expects gateway identifiers in plaintext.

**Required fix:** replace the notifier’s push descriptor with a per-device authenticated HPKE ciphertext. The Push Gateway must accept no `title`, `body`, `session_id`, `request_id`, tool data, or Hermes payload dictionary.

---

## P0 — the existing hosted tunnel is not end-to-end encrypted

The existing tunnel:

- Parses JSON.
- Reads frame type and RPC method.
- Uses a plaintext method allowlist to determine what may be buffered.
- Mutates frames by adding a connection ID.
- Optionally encrypts stored rows with an AES-GCM key held by the server itself.

That is a trusted application proxy, not a content-blind relay. Server-side encryption at rest does not create E2EE because the operator controls the decryption key.

**Required fix:** retire the existing tunnel for chat transport. The new Hub sees only an opaque outer envelope and ciphertext. It must never branch on an inner RPC method.

---

## P0 — pairing is currently one shared bearer, not per-device enrollment

The current hosted service stores one pairing hash per Agent and rotates that single value.  The current iOS deep link embeds the plaintext pairing secret in the URL query.

This causes several problems:

- The same capability can admit multiple devices.
- Rotating it can disrupt existing setup flows.
- It does not establish a device cryptographic identity.
- It cannot independently revoke devices.
- URL queries can leak through screenshots, pasteboards, logs, analytics, or support transcripts.

**Required fix:** pairing must enroll one device public-key set, atomically consume one offer, and produce one device-specific Hub grant and push binding.

---

## P0 — no Notification Service Extension or required key-sharing capability exists

The current Xcode project declares the main app, widget extension, and share extension, but no Notification Service Extension.  The app entitlement currently contains only an app group and APNs environment; there is no shared Keychain access group or App Attest entitlement.

Encrypted previews therefore cannot work until the project gains:

- A Notification Service Extension target.
- Keychain-sharing entitlements.
- A preview-only private key accessible to the extension.
- App Attest capability.
- NSE tests and signing configuration.

Apple requires a mutable alert payload and gives the extension only limited processing time; if it fails, the original notification content is displayed.  APNs regular notification payloads are limited to 4,096 bytes.

---

## P0 — notification actions still bypass the proposed relay

The existing approval action handler resolves a gateway URL and gateway token, then calls the gateway directly.

That does not work when:

- The phone has no inbound route to the gateway.
- The gateway is behind NAT.
- The Agent is offline and the command needs mailboxing.
- The official architecture intends the phone to hold no durable gateway credential.

**Required fix:** action handlers must enqueue an encrypted command in the existing durable WorkRepository, then attempt an HTTPS send to the Relay Hub. The gateway token remains only beside the Agent.

---

## P0 — operation idempotency is not crash-safe

The open relay work adds an in-memory `client_message_id` LRU around prompt submission.  That helps duplicate requests during one process lifetime, but does not survive:

- Agent restart.
- Crash after the gateway accepted a prompt but before the Agent persisted its response.
- Multiple Agent processes.
- Database restore or failover.

The gateway on this branch already exposes
`register_prompt_receipt_provider()`, and `plugins/hermes-mobile/prompt_receipts.py`
implements durable, profile-scoped `client_message_id` receipts. The current
relay nevertheless drops `client_message_id` in
`GatewayClient.prompt_submit()`, so it bypasses that durable authority and
falls back to its process-local LRU.

**Required fix:** define the durable Agent operation ledger for HRP/2 and pass
the WorkRepository `client_message_id` unchanged through the relay into the
existing gateway receipt provider. Do not build a competing gateway receipt
system. If the provider is unavailable or reports an indeterminate execution,
mark the operation `ambiguous`, reconcile against history, and never blindly
resubmit when acceptance cannot be proved.

The existing iOS outbox is already designed to retain ambiguous submissions using the same client ID; that should be reused rather than replaced.

---

## P1 — session resume may return a different live ID

The gateway resume API may return a live session ID distinct from the
requested/original session ID. An earlier relay prototype resumed the origin
but then submitted to the original ID. The audited branch corrects this in
memory by recording and using the returned live ID.

**Required fix:** persist `(origin_session_id, live_session_id)` aliases across
Agent restarts, return both to the phone, and always use the live ID for driving
and foreground presence.

---

## P1 — history is not JSON-RPC-only

The proposal says the Agent connects as a first-class JSON-RPC client. That is incomplete. The current gateway client correctly uses:

- JSON-RPC WebSocket for live events and operations.
- Authenticated REST for stored history, including dormant or foreign sessions.

**Required fix:** the specification must explicitly require both gateway surfaces.

---

## P1 — current foreground suppression is wrong for multiple devices

The current notifier asks whether **any** phone is watching a session.  If an iPad is open on a session, that can suppress the completion notification on an independently paired iPhone.

**Required fix:** notification suppression is per destination device. Device A’s foreground state must never suppress Device B’s push.

---

## P1 — slow-device head-of-line blocking

The downstream loop awaits each device send serially.  A slow or stuck socket can delay every subsequent device even though the comments claim otherwise.

**Required fix:** every device needs an independent bounded send worker. Publishing to a device queue must be non-blocking; overflow invokes a checkpoint/coalescing policy rather than blocking other devices.

---

## P1 — snapshot semantics cannot express deletion

The current Swift snapshot reducer retains local items absent from the snapshot.  This makes the snapshot a merge, not authoritative state.

That leaves stale:

- Deleted messages.
- Rolled-back tool items.
- Revoked approval cards.
- Superseded in-progress items.

**Required fix:** snapshots must specify scope and either:

- `replace: true`, or
- explicit tombstones with a snapshot revision.

---

# 2. Cryptographic decision: do not use Noise IK for the first hosted release

`Noise_IK_25519_ChaChaPoly_BLAKE2s` is a reasonable protocol for an ordered, live, peer-to-peer transport. It is a poor primary abstraction for a durable asynchronous mailbox.

Noise transport state uses ordered nonce/cipher state. The Noise specification assumes sequential handshake and transport processing.  To make Noise safe across offline mailboxes you would also need to design:

- Persisted handshake state.
- Session resumption.
- Skipped-message-key handling.
- Multiple concurrent devices and sessions.
- Reordering windows.
- Key-state rollback prevention.
- Crash-consistent nonce allocation.
- Rekeying while one side is offline.
- Recovery when a mailbox contains messages from an obsolete session.

That is effectively the beginning of a ratchet protocol.

## Recommended first-release primitive

Use **one authenticated HPKE context per message**:

- KEM: X25519-HKDF-SHA256.
- KDF: HKDF-SHA256.
- AEAD: ChaCha20-Poly1305.
- Mode: authenticated mode for paired devices.
- Fresh encapsulation for every outer message.
- Immutable routing fields bound as AEAD associated data.

RFC 9180 permits independent single-shot contexts; creating a new context per stored message avoids a shared ordered nonce state.  CryptoKit provides HPKE, authenticated sender support, and the required Curve25519/SHA-256/ChaChaPoly suite on the repository’s iOS 17 deployment target.

This gives:

- Independent decryption.
- Safe out-of-order delivery.
- Safe duplicate delivery.
- No shared transport nonce counter.
- One ciphertext per device.
- A simple mailbox model.
- Authenticated Agent-to-device notification previews.

It does **not** provide Signal-style post-compromise security. Bound that risk by rotating device KEM keys periodically and deleting obsolete keys after the mailbox grace period. A future version can add a ratchet or live Noise optimization after the basic system is correct.

Do not hand-roll HPKE. Pin a library, test it against RFC vectors, and obtain a focused cryptographic review. If a Python HPKE package is used, its own audit status must be considered rather than treating API compatibility tests as a security audit.

---

# 3. Proposed implementation specification: Hermes Relay Protocol v2

The following should replace the current draft as the normative specification.

---

## 3.1 Security and trust model

### Trusted

- Hermes gateway host.
- Agent Relay process and its local state directory.
- Paired iOS device and its Keychain.
- The user operating `hermes mobile`.
- Apple OS enforcement for Keychain, App Attest, and notification action authentication.

### Content-untrusted

- Relay Hub.
- Hermes Push Gateway.
- APNs.
- Reverse proxies, CDNs, and network intermediaries.
- Hosted PostgreSQL operator.

### Security guarantees

The system **MUST** guarantee:

1. Hub and Push Gateway cannot decrypt Hermes content.
2. Only an active paired device can send accepted device commands.
3. Only the paired Agent can produce valid Agent-to-device content.
4. Modification is detected before application.
5. Replayed messages do not change committed state.
6. A revoked device cannot create new accepted traffic.
7. No protocol downgrade from v2 encrypted transport to plaintext v1.
8. Gateway credentials never leave the Agent host.

### Explicit non-guarantees

The system does not prevent:

- Traffic analysis.
- IP, timing, message-size, routing-graph, or notification-class observation.
- Hub or Push Gateway denial of service.
- A malicious Hub delaying or reordering ciphertext.
- Access after compromise of the Agent or device endpoint.
- Retraction of ciphertext already delivered before revocation.
- Lock-screen observation of a preview the user elected to display.

The external wording should be **“content-blind E2EE relay”**, not an unrestricted “zero-knowledge” claim.

---

## 3.2 Key model

### Agent identity

The Agent generates and persists:

| Key | Algorithm | Purpose |
|---|---|---|
| `relay_kem` | X25519 | HPKE recipient and authenticated sender |
| `relay_sign` | Ed25519 | Hub route enrollment, grants, outer signatures |
| `relay_instance_id` | 128 random bits | Local identity namespace |
| `relay_epoch` | 128 random bits | Prevent synthesized-ID collision after reset |

### Device identity

Each iOS device generates:

| Key | Algorithm | Storage |
|---|---|---|
| `device_kem` | X25519 | Main-app Keychain, ThisDeviceOnly |
| `device_sign` | Ed25519 | Main-app Keychain, ThisDeviceOnly |
| `preview_kem` | X25519 | Keychain access group shared with NSE |
| `device_id` | 128 random bits | GRDB and Keychain metadata |

The Notification Service Extension receives only the preview private key. It does not receive the device command-signing or transport private keys.

### Key generations

Every KEM key has a `generation: UInt32`.

Established-device messages carry the intended recipient generation in the outer envelope. The receiver maintains:

- Current generation.
- Previous generation during a bounded rollover window.
- Revoked generations.

A rotation is prepared locally and sent as a durable `key_rotate` control
message. Hub acceptance proves only that the ciphertext was stored; it does
not activate the new generation for that peer. A device promotes its prepared
local generation only after receiving an authenticated inner
`delivery_receipt` for that exact rotation message ID. The Agent encrypts that
receipt to the prepared device generation so possession of the new private key
is proven before promotion.

For Agent KEM rotation, the Agent atomically stores its new global key and one
exact old-generation notice for every active device, then tracks activation
independently per device. Until device A has acknowledged the Agent's new
public key, all Agent-to-A messages—including notifications—continue to use the
last generation A proved it installed. Acknowledgement by device B must never
advance device A. Exact ciphertext and the semantic receipt ledger survive
crashes and replay, so a duplicate receipt cannot promote twice or create a
receipt-of-receipt loop.

The implementation treats overlap expiry as a revocation boundary. A device
that has not proved the new Agent generation is atomically quarantined with an
explicit re-pair requirement; retiring keys are hidden before external
erasure, and Hub route/grant plus Push binding deletion proceeds through
durable idempotent jobs. A lagging device therefore cannot block healthy-device
rotation or retain indefinite hosted authority after a transient response loss.

Recommended automatic rotation:

- Every 7 days, or
- Every 10,000 encrypted messages,
- Whichever comes first.

Previous private keys are deleted after:

```text
maximum mailbox TTL + 24-hour clock/retry grace
```

---

## 3.3 HPKE message construction

For established devices:

```text
suite = X25519 / HKDF-SHA256 / ChaCha20-Poly1305
mode  = Auth
```

The sender creates a fresh HPKE sender context for every message.

`info` is domain-separated:

```text
hermes-mobile/hrp2/{purpose}/{direction}
```

Examples:

```text
hermes-mobile/hrp2/chat/agent-to-device
hermes-mobile/hrp2/chat/device-to-agent
hermes-mobile/hrp2/notification/agent-to-device
hermes-mobile/hrp2/control/device-to-agent
```

AEAD associated data is the exact encoded immutable outer header:

```text
version
source route
destination route
message ID
message class
expiry
recipient key generation
collapse identifier, if any
```

The receiver **MUST** verify:

- HPKE authentication.
- Outer/inner message-ID equality.
- Recipient key generation.
- Expiry.
- Destination route.
- Replay ledger.
- Protocol version.

before parsing or applying the inner body.

---

## 3.4 Pairing protocol

### Pairing offer

`hermes mobile pair` creates a persisted offer with:

- Five-minute default lifetime.
- 256-bit pairing secret.
- Temporary Hub offer route.
- Separate one-time Hub transport token.
- Atomic state machine.
- Optional human confirmation.

The QR contains:

```json
{
  "v": 2,
  "hub": "https://relay.example",
  "relay_route": "rte_...",
  "offer_route": "off_...",
  "offer_id": "ofr_...",
  "offer_transport_token": "...",
  "expires_at_ms": 1784450000000,
  "relay_kem_pub": "...",
  "relay_sign_pub": "...",
  "pair_secret": "..."
}
```

It **MUST NOT** contain:

- Gateway token.
- Agent Hub long-term credential.
- Push send capability.
- Existing device credentials.
- Session IDs.

Encode this as CBOR or compact JSON directly in the QR. Do not put the pairing secret in a query-string deep link.

### Offer state machine

```text
pending
  -> claimed(device_key_hash)
  -> confirmed
  -> consumed

pending/claimed -> expired
pending/claimed -> cancelled
```

Claiming is an atomic compare-and-set transaction. The same device-key hash may resume a claimed pairing until expiry; another key is rejected.

### PairInit

The phone:

1. Generates its three key pairs.
2. Registers or refreshes its push endpoint.
3. Creates a `PairInit`.
4. Encrypts it in HPKE Base mode to `relay_kem_pub`.
5. Includes an HMAC over the pairing transcript using `pair_secret`.
6. Sends ciphertext through the temporary offer route.

Inner body:

```json
{
  "v": 2,
  "offer_id": "ofr_...",
  "device_name": "Aabi’s iPhone",
  "device_kem_pub": "...",
  "device_sign_pub": "...",
  "preview_kem_pub": "...",
  "device_nonce": "...",
  "push_bind_token": "...",
  "hub_activation_token": "...",
  "pair_mac": "..."
}
```

### Human confirmation

Default interactive pairing should display:

```text
Pair “Aabi’s iPhone”?
Verification code: 482 917
```

The phone displays the same six-digit code derived from the complete transcript.

`--auto-approve` may skip the prompt for headless deployments, but must be explicit.

### PairAccept

After confirmation, the Agent:

- Persists the device.
- Creates a device-specific Hub grant.
- Exchanges the push bind token for a push send capability.
- Creates the device stream.
- Sends `PairAccept` using authenticated HPKE to `device_kem_pub`.

It contains:

```json
{
  "device_id": "dev_...",
  "relay_instance_id": "...",
  "device_route": "rte_...",
  "stream_id": "...",
  "relay_key_generation": 1,
  "push_binding_id": "pb_...",
  "capabilities": [
    "chat",
    "history",
    "notifications",
    "approve_once",
    "deny"
  ]
}
```

### PairConfirm

The phone responds using authenticated HPKE with its newly enrolled static device KEM key. The Agent activates the device only after this confirmation.

The temporary route and tokens are then deleted.

### Concrete Hub pairing transaction

The hosted Hub wires those messages into one response-loss-safe transaction:

1. The Agent signs `POST /v2/offers` with client-generated `ofr_...` and
   `off_...` identifiers, the owner route, expiry, and
   `base64url(SHA256(raw transport token))`.
2. The phone submits exactly one opaque PairInit `enc`/`ct` pair to
   `POST /v2/offers/{offer_route}/messages` using the raw transport token as a
   bearer credential. `message_hash` is `SHA256(raw enc || raw ct)`.
3. The Agent signs `GET /v2/offers/{offer_id}`, creates a pending device route
   with `POST /v2/routes`, and creates both directional pending grants.
4. The Agent signs `POST /v2/offers/{offer_id}/accept` with `message_hash`, the
   pending device route, and opaque PairAccept `enc`/`ct`.
   `response_hash` is `SHA256(raw enc || raw ct)`.
5. The phone polls `GET /v2/offers/{offer_route}/accept` with the transport
   token. Before offer expiry, the pending device route may send exactly one
   new `control` envelope to its owning Agent, plus an exact retransmission.
6. After committing that PairConfirm control proof, the Agent signs
   `POST /v2/offers/{offer_id}/confirm` with both hashes and the device route.
   One database transaction activates the route and both grants and removes
   the offer.

Cancellation or expiry revokes the pending route and grants. Every mutation
has exact-retry semantics; reusing its idempotency identity with changed
content is a conflict. A bounded hash-only confirmation receipt makes a retry
safe after the successful transaction has already deleted the offer.

---

## 3.5 Hosted enrollment and accountless abuse control

App Attest should not be used as vague “registration protection.” It must bind a concrete challenge and request.

The repository already contains partial server-side App Attest infrastructure
in `server/push-relay/push_relay/attestation.py` and
`GET /v1/attest/challenge`. HRP/2 should adapt and harden that implementation,
adding request-hash assertions, counter validation, and the endpoint-binding
contract below. The iOS entitlement, client assertion flow, and Notification
Service Extension integration remain new work.

The Push Gateway issues a one-time challenge. The iOS app produces an assertion covering:

```text
challenge
SHA256(APNs token)
bundle ID
APNs environment
preview public key
installation nonce
requested operation
```

The server verifies the challenge, assertion, counter, App ID, and environment. App Attest keys do not survive reinstall or device migration, and not every environment supports them, so fallback behavior must be explicit.

For the hosted Hub:

- A new Agent may create a **provisional** route with a 10-minute lifetime and pairing-only quota.
- The first App-Attested device supplies a short-lived signed Hub activation token.
- The Agent redeems it to make the route durable.
- A push-disabled official app may still request an attestation-only activation token.
- Self-hosted deployments may instead require an operator enrollment token.
- Development builds may use a development-only registration token.
- Production must not silently fall back to public open enrollment.

`POST /v2/enroll/provisional` requires a caller-generated opaque
`enrollment_id`, route type, and Ed25519 authorization public key. An exact
retry during the lifetime returns the same route; changing the key or route
type conflicts. A provisional Agent may only create, read, or cancel its own
pair offer. Grants, pending routes, ordinary messages, PairAccept, PairConfirm,
and revocation remain active-route operations.

---

## 3.6 Relay Hub outer protocol

### Outer envelope

The Hub stores and routes only:

```json
{
  "v": 2,
  "src": "rte_...",
  "dst": "rte_...",
  "mid": "base64url-128-bit-random",
  "class": "state",
  "expires_at_ms": 1784450000000,
  "recipient_key_generation": 3,
  "collapse": "base64url-opaque-or-null",
  "enc": "base64url-hpke-encapsulation",
  "ct": "base64url-ciphertext",
  "sig": "base64url-ed25519-signature"
}
```

The Hub must not receive inner:

- Session ID.
- Turn ID.
- Item ID.
- Sequence number.
- RPC method.
- Prompt text.
- Tool arguments or output.
- Notification title/body.
- Approval request data.

### Outer signature

Each route has an Ed25519 authorization public key registered with the Hub.

`sig` covers a length-prefixed binary encoding of:

```text
"HRH2"
v
src
dst
mid
class
expires_at_ms
recipient_key_generation
collapse
SHA256(enc || ct)
```

The signature is for Hub authorization and route ACL enforcement. HPKE authentication remains the end-to-end sender-authentication boundary.

### Route grants

A device route can send only to its enrolled Agent route, and the Agent route can send only to enrolled device routes.

A Hub grant contains:

```json
{
  "grant_id": "...",
  "issuer_route": "relay-route",
  "source_route": "device-route",
  "destination_route": "relay-route",
  "permissions": ["send", "receive"],
  "expires_at_ms": null,
  "issuer_signature": "..."
}
```

The reverse grant is separately represented. Revocation deletes or disables both.

### Transport classes

| Class | Persistence | Max message | Behavior |
|---|---:|---:|---|
| `realtime` | No offline persistence | 64 KiB | Live deltas only |
| `state` | Up to 24 h | 256 KiB | Checkpoints, terminal items; collapsible |
| `command` | Up to 24 h | 64 KiB | Prompt/action commands; never silently evicted |
| `control` | Up to 24 h | 32 KiB | Pairing completion, rotation, revocation |

### Mailbox quota

Per destination route:

```text
256 records
4 MiB total
```

Reserve at least:

```text
64 records
512 KiB
```

for `command` and `control`.

Overflow policy:

- `realtime`: do not store when recipient is offline.
- `state`: replace an existing message with the same opaque collapse key.
- `state`: otherwise evict the oldest state record if needed.
- `command`/`control`: return `429 mailbox_full`; do not evict them.
- Sender retains command/control in its durable local outbox.

This prevents token deltas from consuming the entire mailbox and dropping an approval or prompt.

### Delivery and acknowledgement

There are three distinct acknowledgements:

1. **Hub acceptance:** ciphertext was accepted or deduplicated.
2. **Hub delivery ACK:** recipient decrypted and committed it; Hub may delete the row.
3. **Inner stream/application receipt:** recipient applied application frames
   through a sequence, or committed the exact control/RPC message ID.

Do not conflate them.

The recipient sends the Hub delivery ACK only after:

```text
decrypt -> validate -> database transaction commit
```

The Agent deletes its application outbox only after receiving the appropriate
E2EE stream ACK or application receipt—not merely because the Hub delivered the
ciphertext. Key rotation is therefore never promoted on Hub acceptance.

### Required HTTP and WebSocket surfaces

```text
POST   /v2/enroll/provisional
POST   /v2/enroll/activate
POST   /v2/routes
POST   /v2/grants
DELETE /v2/grants/{grant_id}

POST   /v2/offers
POST   /v2/offers/{offer_route}/messages
GET    /v2/offers/{offer_id}
POST   /v2/offers/{offer_id}/accept
GET    /v2/offers/{offer_route}/accept
POST   /v2/offers/{offer_id}/confirm
DELETE /v2/offers/{offer_id}/cancel

GET    /v2/socket
POST   /v2/messages
POST   /v2/acks
DELETE /v2/routes/{route_id}

GET    /healthz
GET    /readyz
```

HTTP POST is required because notification action handlers cannot depend on maintaining a live WebSocket.

### Idempotency

The database has a unique key on:

```text
(destination_route, message_id)
```

Resending the same envelope returns success without creating a second row. Resending the same ID with different ciphertext returns `409 message_id_conflict`.

### Availability semantics

The Hub may deliver duplicate ciphertext. Clients must deduplicate.

The Hub may reorder ciphertext. Clients must buffer or request a checkpoint.

The Hub may drop or delay traffic. This is not cryptographically preventable; the application surfaces stale/offline state and retries from its durable outbox.

The malicious-hub acceptance test is therefore:

> Tampering and replay never change committed application state; reordering either converges or triggers a checkpoint.

It should not claim that the Hub is incapable of reordering messages.

---

## 3.7 Inner secure-message protocol

Every HPKE plaintext is:

```json
{
  "v": 2,
  "mid": "same-as-outer-mid",
  "kind": "frame_batch",
  "sender_key_generation": 4,
  "created_at_ms": 1784449900000,
  "expires_at_ms": 1784450000000,
  "body": {}
}
```

Allowed `kind` values:

```text
pair.init
pair.accept
pair.confirm
frame_batch
checkpoint
rpc_request
rpc_response
stream_ack
sync_request
key_rotate
device_revoke
delivery_receipt
```

Unknown values are rejected as unsupported, not passed directly into the gateway.

---

## 3.8 Durable per-device stream

Each Agent/device binding has:

```text
stream_id: random 128-bit ID
next_seq: NonNegativeSafeJSONInteger
acked_through: NonNegativeSafeJSONInteger
checkpoint_revision: NonNegativeSafeJSONInteger
```

Although these values are logically unsigned, the HRP/2 JSON wire contract
caps them at `9007199254740991` (`2^53 - 1`). This is the largest integer that
round-trips exactly through every supported JSON implementation, including the
iOS app's `Double`-backed generic JSON value. Implementations must reject
larger JSON numbers before durable admission instead of rounding or coercing
them. Persisted SQLite and Swift representations remain signed 64-bit values.

A stream ID persists across socket reconnects and Agent restarts.

A new stream ID is created only when:

- The device is paired.
- The Agent state is deliberately reset.
- A protocol-breaking migration occurs.
- The old stream is cryptographically compromised.

### Frame batch

```json
{
  "stream_id": "str_...",
  "first_seq": 501,
  "frames": [
    {
      "sid": "session-id",
      "turn": "turn-id",
      "kind": "item.delta",
      "body": {}
    },
    {
      "sid": "session-id",
      "turn": "turn-id",
      "kind": "item.completed",
      "body": {}
    }
  ]
}
```

Sequences are consecutive:

```text
first_seq + array index
```

The Agent batches for up to:

```text
50 ms or 32 KiB plaintext
```

whichever comes first.

### Agent transaction order

For an outgoing batch:

1. Allocate sequence numbers.
2. Update the local session projection.
3. Create the exact encrypted outer envelope.
4. Insert the envelope into `outbox`.
5. Commit.
6. Send.

On crash after step 5, resend the identical `mid`, `enc`, and ciphertext. Do not re-encrypt it under the same logical sequence with a new message ID.

### Device transaction order

1. Verify route and HPKE.
2. Reject expired/replayed message.
3. For a frame batch, validate stream ID and sequence continuity. For a
   standalone checkpoint, validate stream ID plus a non-rollback checkpoint
   revision/boundary even if the current frame watermark has a gap.
4. Apply all frames.
5. Persist item state, stream watermark, and seen message ID in one GRDB transaction.
6. Commit.
7. Send Hub delivery ACK.
8. Send encrypted inner `stream_ack`.

---

## 3.9 Item lifecycle v2

### Full item

```json
{
  "item_id": "itm_...",
  "session_id": "sess_...",
  "turn_id": "turn_...",
  "type": "agentMessage",
  "status": "in_progress",
  "ord": 7,
  "rev": 14,
  "summary": "",
  "body": {
    "text": "Current content"
  }
}
```

Generated item and turn IDs are random UUIDs persisted before first emission.

### Delta

```json
{
  "item_id": "itm_...",
  "from_rev": 14,
  "to_rev": 15,
  "ops": [
    {
      "op": "append_utf8",
      "path": "/body/text",
      "offset": 387,
      "data": "new text"
    }
  ]
}
```

Client rules:

- `to_rev <= current.rev`: duplicate; ignore completely.
- `from_rev == current.rev` and offset matches: apply.
- `from_rev > current.rev`: gap; do not apply; request item/checkpoint.
- `from_rev < current.rev < to_rev`: conflict; request authoritative item.
- A delta after terminal completion is ignored unless the protocol explicitly introduces a higher full-item revision.

### Completion

`item.completed` carries the complete authoritative item, including final revision.

### Checkpoint

```json
{
  "stream_id": "str_...",
  "through_seq": 820,
  "session_id": "sess_...",
  "snapshot_revision": 31,
  "replace": true,
  "items": [],
  "tombstones": [
    {
      "item_id": "itm_old",
      "deleted_at_revision": 31
    }
  ]
}
```

`replace: true` means local items in that session that are absent and older than the checkpoint are removed, subject to unsent local optimistic work.

The checkpoint is carried as a standalone authenticated `checkpoint` secure
message. It is not assigned the next frame sequence; `through_seq` is the
authoritative boundary immediately before future frame allocation. This lets a
fresh or gapped device converge without first accepting the very sequence it
is missing. Apply is idempotent and rejects revision/boundary rollback; delayed
pre-boundary batches are ignored.

### Unknown item types

Unknown types render as a generic safe card. They are not interpreted as arbitrary commands and do not get privileged UI.

---

## 3.10 JSON-RPC v2

Use normal JSON-RPC inside encrypted `rpc_request` messages.

Request IDs are strings, not integers:

```json
{
  "jsonrpc": "2.0",
  "id": "rpc_019...",
  "method": "prompt.submit",
  "params": {},
  "op_id": "op_019...",
  "deadline_ms": 1784450000000
}
```

### Supported methods

```text
session.list
session.open
session.history
session.resume
prompt.submit
session.interrupt
approval.respond
clarify.respond
presence.set
item.fetch
sync.request
```

### Typed errors

Never send `str(exc)` across the protocol.

```text
INVALID_ARGUMENT
UNAUTHENTICATED
REVOKED
EXPIRED
UNSUPPORTED_VERSION
NOT_FOUND
CONFLICT
ALREADY_RESOLVED
GATEWAY_OFFLINE
GATEWAY_AMBIGUOUS
MAILBOX_FULL
RATE_LIMITED
INTERNAL
```

`INTERNAL` contains a correlation ID, not a Python exception string.

---

## 3.11 Durable operation ledger

Every side-effecting request has a device-generated `op_id`.

Agent table:

```sql
CREATE TABLE operations (
    device_id       TEXT NOT NULL,
    op_id           TEXT NOT NULL,
    request_hash    BLOB NOT NULL,
    method          TEXT NOT NULL,
    state           TEXT NOT NULL
                    CHECK (state IN (
                        'received',
                        'executing',
                        'succeeded',
                        'failed',
                        'ambiguous'
                    )),
    response_json   BLOB,
    error_code      TEXT,
    created_at_ms   INTEGER NOT NULL,
    updated_at_ms   INTEGER NOT NULL,
    PRIMARY KEY (device_id, op_id)
);
```

Rules:

- Same `(device_id, op_id)` and same request hash returns the cached result.
- Same ID with different content returns `CONFLICT`.
- Insert `received` before invoking the gateway.
- Persist `executing` before side effect.
- Persist final response before sending it.
- An Agent crash during `executing` becomes `ambiguous` on restart.

### Prompt submission

`prompt.submit` must include:

```json
{
  "client_message_id": "lowercase canonical UUID created by WorkRepository",
  "session_id": "origin or live ID",
  "text": "..."
}
```

Existing gateway receipt contract to reuse:

```text
UNIQUE(profile_home, client_message_id)
```

This is implemented as a per-profile receipt database with
`client_message_id` as its primary key. A successful submission returns a
persisted disposition such as:

```json
{
  "accepted": true,
  "client_message_id": "...",
  "deduplicated": false,
  "session_id": "live-session-id"
}
```

The relay must forward `client_message_id` to this existing provider and retain
the same ID through every retry. If the provider is disabled or returns an
indeterminate receipt, the Agent first reconciles history. If it cannot prove
acceptance, it returns `GATEWAY_AMBIGUOUS` and preserves the phone job.

### Gateway parameter mappings

The Agent must map:

```text
approval.respond:
  phone decision -> gateway choice
  approve_once   -> once
  deny           -> deny

clarify.respond:
  phone text -> gateway answer
```

The current open relay correction already documents why sending `decision` directly made approvals default incorrectly and why clarification must use `answer`.

---

## 3.12 Gateway integration

The Agent uses:

| Operation | Surface |
|---|---|
| Live events | Gateway WebSocket |
| `session.create` | JSON-RPC |
| `session.resume` | JSON-RPC |
| `prompt.submit` | JSON-RPC |
| Approval/clarify/interrupt | JSON-RPC |
| Session list | JSON-RPC |
| Dormant/foreign history | Authenticated REST |

### Session aliasing

Persist:

```sql
CREATE TABLE session_aliases (
    origin_session_id TEXT PRIMARY KEY,
    live_session_id   TEXT NOT NULL,
    updated_at_ms     INTEGER NOT NULL
);
```

After `session.resume`, use the returned live ID for:

- Prompt submission.
- Interruption.
- Foreground presence.
- Live event subscription.

Return both IDs to the phone so its stored-history identity remains stable.

### Open and subscribe

`session.open` must be atomic from the device’s perspective:

1. Establish the device’s subscription to the session.
2. Generate the authoritative checkpoint and `through_seq`.
3. Release the session lock.
4. Emit subsequent live frames with sequences greater than `through_seq`.

Do not make the RPC response promise a checkpoint while the server merely returns an unrelated raw message array.

### Foreign live sessions

The specification must retain this limitation:

> The Agent can list and read foreign/dormant sessions. It cannot necessarily receive a live stream for a session actively owned and driven by another independent gateway client unless the gateway exposes a broadcast/co-watch facility.

Do not claim universal live mirroring until that gateway capability exists.

---

# 4. Push Gateway specification

## 4.1 Component boundary

The Push Gateway is a separate deployable with:

- Separate database.
- Separate service account.
- APNs provider key.
- No Hub message access.
- No Agent chat ciphertext mailbox access.
- No session or request identifiers.

The current combined `server/push-relay` should be split:

```text
server/relay-hub/
server/push-gateway/
```

The Hub process must never receive APNs credentials.

---

## 4.2 Endpoint registration

### API

```text
GET  /v2/attest/challenge
POST /v2/hub-activations
POST /v2/endpoints/register
POST /v2/endpoints/token-refresh
POST /v2/bindings/exchange
POST /v2/send
DELETE /v2/bindings/{binding_id}
```

### Endpoint registration body

The phone sends:

```json
{
  "challenge": "...",
  "app_attest_key_id": "...",
  "assertion": "...",
  "attestation": "...",
  "apns_token": "...",
  "environment": "production",
  "bundle_id": "ai.hermes.app",
  "preview_kem_pub": "...",
  "installation_nonce": "...",
  "hub_route_id": "rte_..."
}
```

The server returns:

```json
{
  "endpoint_id": "ep_...",
  "bind_token": "one-time-256-bit-secret",
  "bind_token_expires_at_ms": 1784450000000
}
```

The bind token is delivered E2EE to the Agent during pairing.

The optional `attestation` is required on first use of an App Attest key. The
optional `hub_route_id` requests a short-lived activation token in the same
response. A push-disabled official app instead calls
`POST /v2/hub-activations`; its separate `HPG2ACTIVATE` transcript and response
create no endpoint, APNs-token, or bind row.

Registration stores an encrypted exact-response receipt before returning. An
exact retry with the same challenge and complete body returns the same endpoint
and bind token without consuming another App Attest counter. Reusing the
challenge with changed content conflicts. After that receipt expires, a fresh
challenge with the same attested key, installation nonce, preview key,
bundle, and environment recovers the existing endpoint and rotates its bind
token rather than creating a duplicate. This recovery request sets
`attestation` to null because the original verified leaf key is already
committed. An unknown/uncommitted key returns typed
`409 app_attest_initial_required`; an installation bound to a different
committed key returns terminal `409 installation_key_mismatch`. The
activation-only surface follows the same fresh-challenge and initial-key error
contract without creating endpoint or APNs artifacts.

---

## 4.3 Send capability

The Agent exchanges the one-time bind token using a persisted caller-generated
opaque `exchange_id` and optional requested class set:

```json
{
  "bind_token": "one-time-256-bit-secret",
  "exchange_id": "opaque-retry-identity",
  "requested_classes": ["update", "approval", "error"]
}
```

The server returns:

```json
{
  "binding_id": "pb_...",
  "send_capability": "256-bit-random-secret",
  "allowed_classes": ["update", "approval", "error"]
}
```

Server-side storage contains only a hash of the send capability.

A send capability maps to exactly:

```text
one relay installation
one endpoint
one bundle/environment
one allowed class set
one revocation state
```

Possession of it does not permit registering another APNs token.

The Agent retains `exchange_id` until this response is durable. An exact retry
returns the same binding and capability from an encrypted bounded receipt;
changing the bind token, exchange ID, or class set conflicts.

Because the exchange may commit remotely before its response is durable at the
Agent, the Push Gateway also exposes a revoke-only operation keyed by the
original exchange ID and bind token. It returns no capability, is idempotent
before or after exchange commit, and commits a durable non-resurrectable
exchange tombstone. Pair cancellation/expiry retains these cleanup credentials
until that revocation is confirmed; receipt/token expiry must not let a delayed
exchange recreate the binding.

---

## 4.4 Send request

The Agent sends only:

```json
{
  "v": 2,
  "class": "approval",
  "notification_id": "opaque-random-ID",
  "preview_enc": "...",
  "preview_ct": "...",
  "collapse_id": "opaque-random-or-HMAC-value",
  "expires_at_ms": 1784450000000,
  "sound": true
}
```

No:

```text
session_id
turn_id
item_id
request_id
title
body
approval command
model output
tool output
```

The capability itself identifies the endpoint.

---

## 4.5 APNs payload

The Push Gateway constructs:

```json
{
  "aps": {
    "alert": {
      "title": "Hermes",
      "body": "Hermes needs your attention."
    },
    "mutable-content": 1,
    "sound": "default"
  },
  "h_v": 2,
  "class": "approval",
  "nid": "...",
  "enc": "...",
  "ct": "...",
  "exp": 1784450000000,
  "collapse": null,
  "sound": true
}
```

The `aps.sound` key is omitted when `sound` is false; the authenticated outer
`sound` boolean is always present. The Gateway derives stable `apns-id` and,
when `collapse` is null, stable fallback collapse identifiers from the binding
and notification ID. Retries after timeout or ambiguous provider results reuse
the identical identifiers, payload, and expiration without charging quota a
second time.

The outer APNs payload must not include `HERMES_APPROVAL`.

Otherwise a decryption failure could leave actionable Approve/Deny buttons attached to generic, unverified content.

The Notification Service Extension sets the real category only after successful authenticated decryption.

### Size budget

Use:

```text
maximum preview plaintext: 1,200 UTF-8 bytes
maximum serialized APNs body: 3,900 bytes
absolute rejection threshold: 4,096 bytes
```

Truncate at a valid Unicode boundary before encryption.

---

## 4.6 Token protection

Hosted production stores APNs tokens using envelope encryption:

```text
KMS master key
  -> wraps per-row or per-batch data-encryption key
  -> AES-GCM token ciphertext in PostgreSQL
```

The database contains:

```text
token_ciphertext
token_nonce
key_version
environment
bundle_id
endpoint status
```

It must never log:

- APNs token.
- Preview plaintext.
- Send capability.
- App Attest assertion.
- Provider JWT.
- Provider private key.

Self-hosted Push Gateway uses an operator-provided master key.

---

# 5. Notification Service Extension and action specification

## 5.1 NSE behavior

On receipt:

1. Read `enc`, `ct`, `nid`, class, and version.
2. Load the preview private key from the shared Keychain access group.
3. HPKE-decrypt using the pinned Agent public key.
4. Verify notification ID, expiry, class, and Agent identity.
5. Set title/body/thread/category.
6. Call the content handler.

On any error:

- Do not expose the error.
- Do not install action buttons.
- Leave the generic fallback.
- Record only a content-free diagnostic counter.

The extension performs no network access.

### Key accessibility modes

Default:

```text
kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
```

This permits encrypted previews after the first post-reboot unlock.

Privacy mode:

```text
kSecAttrAccessibleWhenUnlockedThisDeviceOnly
```

This produces generic notifications while the device is locked.

The user should be able to choose:

```text
Show decrypted previews on lock screen
Generic notifications only
Notifications disabled
```

---

## 5.2 Decrypted preview schema

```json
{
  "v": 2,
  "notification_id": "nid_...",
  "class": "approval",
  "title": "Approval required",
  "body": "Run the deployment command?",
  "thread_token": "device-local-opaque-token",
  "category": "HERMES_APPROVAL",
  "expires_at_ms": 1784450000000,
  "action": {
    "capability": "...",
    "request_id": "...",
    "session_id": "...",
    "allowed_decisions": ["approve_once", "deny"],
    "destructive": false
  }
}
```

Everything in this object is encrypted before it leaves the Agent.

The NSE uses `thread_token`; it does not expose a real session ID to APNs.

---

## 5.3 Approval capability state machine

The Agent creates a separate random capability per device:

```sql
CREATE TABLE approval_capabilities (
    capability_hash   BLOB PRIMARY KEY,
    request_id        TEXT NOT NULL,
    device_id         TEXT NOT NULL,
    device_generation INTEGER NOT NULL,
    allowed_decisions TEXT NOT NULL,
    expires_at_ms     INTEGER NOT NULL,
    state             TEXT NOT NULL
                      CHECK (state IN (
                          'pending',
                          'claimed',
                          'succeeded',
                          'failed_retryable',
                          'expired',
                          'revoked',
                          'superseded'
                      )),
    claimed_decision  TEXT,
    op_id             TEXT,
    created_at_ms     INTEGER NOT NULL,
    updated_at_ms     INTEGER NOT NULL
);
```

Validation requires:

- Correct active device.
- Correct key generation.
- Matching request.
- Unexpired capability.
- Allowed decision.
- Request still pending.
- Capability not previously claimed.

The first valid decision atomically:

1. Marks the underlying approval request claimed.
2. Records the decision and `op_id`.
3. Marks sibling device capabilities superseded.
4. Calls the gateway.
5. Caches the final result.

If the gateway call is ambiguous, only the same decision and same `op_id` may retry. An opposite decision is rejected.

### Allowed lock-screen decisions

First release:

```text
approve_once
deny
```

Not allowed from a notification:

```text
approve_for_session
always_allow
modify_command
text reply
```

Those require foreground UI.

---

## 5.4 Device authentication

Both Approve and Deny actions should use `UNNotificationActionOptionAuthenticationRequired`.

That option requires the device to be unlocked before the action is delivered; it is not equivalent to a guaranteed new biometric challenge.

For a destructive operation:

- The preview should normally expose only “Open Hermes.”
- If an inline decision is deliberately retained, perform an explicit `LAContext` authentication before enqueueing it.

The existing code already applies a second `LAContext` check for destructive actions; preserve that behavior while changing the network destination from the gateway to the Relay Hub.

---

## 5.5 Durable action delivery

Notification action flow:

1. Decrypt and verify the preview again in the main app.
2. Authenticate the user as required.
3. Create an `approval.respond` command with stable `op_id`.
4. Commit it to WorkRepository.
5. Attempt an HTTPS Hub send.
6. Finish the notification callback after durable enqueue.
7. The normal outbox retries until E2EE RPC receipt, expiry, revocation, or final conflict.

This reuses the repository’s existing durable outbox design rather than creating a second action queue. The current outbox already separates durable job state from transient transport readiness.

Text replies remain disabled for Relay v2 first release, even though the legacy direct-gateway app currently contains clarification-reply code.

---

# 6. Agent Relay durable state

Use SQLite in WAL mode under:

```text
$HERMES_HOME/mobile-relay/
```

Do not hardcode `~/.hermes`; profile-specific `HERMES_HOME` must be respected.

Recommended tables:

```text
meta
relay_identity
devices
device_keys
pair_offers
hub_routes
hub_grants
streams
outbox
seen_messages
operations
session_aliases
owned_sessions
session_items
session_tombstones
approval_requests
approval_capabilities
push_bindings
```

### Minimum permissions

POSIX:

```text
directory: 0700
files:     0600
```

Windows:

```text
ACL: current user + SYSTEM only
inheritance disabled
```

Private identity keys should be wrapped using the platform credential store when available. File permissions alone are the fallback, not the preferred protection.

### Durable versus rebuildable

Durable authority:

- Relay/device identities.
- Pairing and revocation.
- Stream IDs and watermarks.
- Unacknowledged encrypted outbox.
- Operation ledger.
- Approval capabilities.
- Session aliases.
- Owned session list.

Rebuildable projection:

- Completed session items.
- Notification summaries.
- Search indexes.
- Temporary replay batches.

---

# 7. iOS storage

Use the existing GRDB infrastructure.

Recommended tables:

```text
relay_accounts
relay_devices
relay_streams
relay_seen_messages
relay_session_items
relay_session_tombstones
relay_checkpoints
```

Primary item key:

```text
(relay_account_id, session_id, item_id)
```

Stream primary key:

```text
(relay_account_id, device_id, stream_id)
```

Applying a frame batch must update:

- Items.
- Tombstones.
- Sequence watermark.
- Seen message ID.

in one transaction.

The WorkRepository remains the source of truth for unsent commands and prompts.

---

# 8. CLI and service-management specification

## Commands

```text
hermes mobile enable [--hub URL] [--push-url URL | --no-push] [--system]
hermes mobile relay run
hermes mobile status [--json]
hermes mobile pair [--ttl 300] [--auto-approve]
hermes mobile devices
hermes mobile revoke <device-id>
hermes mobile logs [--follow]
hermes mobile disable [--purge]
```

## `enable`

Must be idempotent:

1. Validate gateway availability.
2. Create state directory.
3. Generate identity if absent.
4. Migrate legacy relay configuration.
5. Register a provisional/durable Hub route.
6. Write non-secret config.
7. Install or update the service.
8. Start it.
9. Verify health.
10. Roll back only newly created service artifacts if installation fails.

## `disable`

Default:

- Stop and uninstall service.
- Keep identity and devices for reversible disable.

`--purge`:

- Revoke Hub routes.
- Revoke push bindings.
- Mark all devices revoked.
- Delete local cryptographic material after successful revocation attempts.
- Require an explicit destructive confirmation.

## Configuration

`config.yaml`:

```yaml
mobile:
  enabled: true
  hub_url: https://relay.hermes.example
  push_enabled: true
  preview_policy: after_first_unlock
  mailbox_ttl_seconds: 86400
  log_level: info
```

Secrets do not belong in this file.

The present relay-push implementation is environment and `.env` based.  A migration must import the old URL/credentials once and then remove or mark them deprecated.

## Service machinery

The repository already has a backend-neutral `ServiceManager` protocol in
`hermes_cli/service_manager.py`, with systemd, launchd, Windows, and s6
adapters. Host adapters currently provide lifecycle control for predeclared
services, while s6 also supports runtime profile registration. Extend this
abstraction rather than introducing a parallel service-management framework.

If a declarative specification is needed, add it beside and route it through
the existing `ServiceManager` implementations:

```python
@dataclass(frozen=True)
class ServiceSpec:
    name: str
    description: str
    command: list[str]
    working_directory: Path
    environment: dict[str, str]
    stdout_path: Path
    stderr_path: Path
    restart_policy: str
```

Widen the existing launchd, systemd user/system, Windows, and s6 adapters to
install the Agent Relay from `ServiceSpec`, preserving their current gateway
behavior. Register the `hermes mobile` commands from the mobile package/plugin
surface, and retain `hermes mobile-pair` as a compatibility alias during the
command-hierarchy migration.

Service names must include a stable hash of the active `HERMES_HOME` so multiple profiles do not collide.

---

# 9. Concrete immediate fixes to land before HRP/2

These are prerequisite correctness fixes even if the hosted architecture takes longer.

## 9.1 Fix Swift request parameters

```swift
func submit(
    sessionID: String? = nil,
    prompt: String,
    clientMessageID: String
) async throws -> JSONValue {
    var params: [String: JSONValue] = [
        "text": .string(prompt),
        "client_message_id": .string(clientMessageID),
    ]
    if let sessionID {
        params["session_id"] = .string(sessionID)
    }
    return try await request(.submit, params: .object(params))
}

func approve(
    sessionID: String,
    requestID: String,
    decision: String
) async throws -> JSONValue {
    try await request(.approve, params: .object([
        "session_id": .string(sessionID),
        "request_id": .string(requestID),
        "decision": .string(decision),
    ]))
}

func clarify(
    sessionID: String,
    requestID: String,
    text: String
) async throws -> JSONValue {
    try await request(.clarify, params: .object([
        "session_id": .string(sessionID),
        "request_id": .string(requestID),
        "text": .string(text),
    ]))
}
```

Add `foreground` to the Swift enum, or remove it from the v1 server. Do not leave one side believing it exists.

---

## 9.2 Stop applying duplicate deltas

Minimum v1 band-aid:

```swift
mutating func apply(_ frame: RelayFrame) -> SeqAdmission {
    let admission = classify(seq: frame.seq)

    if case .duplicate = admission {
        return admission
    }

    // Existing mutation logic follows.
    // This is still not sufficient without stream_id and item revisions.
    ...
}
```

The complete fix is HRP/2 `stream_id` plus item revisions and offsets.

---

## 9.3 Validate upstream schemas

Replace ad hoc dictionary access with strict models:

```python
from typing import Literal
from pydantic import BaseModel, ConfigDict, Field

class SubmitParams(BaseModel):
    model_config = ConfigDict(extra="forbid")

    text: str = Field(min_length=1, max_length=1_000_000)
    session_id: str | None = Field(default=None, min_length=1, max_length=256)
    client_message_id: str = Field(min_length=16, max_length=128)
    title: str | None = Field(default=None, max_length=200)
    model: str | None = Field(default=None, max_length=200)
    provider: str | None = Field(default=None, max_length=200)


class ApprovalParams(BaseModel):
    model_config = ConfigDict(extra="forbid")

    session_id: str
    request_id: str
    decision: Literal["once", "session", "always", "deny", "approve"]
    all: bool = False
```

Return `INVALID_ARGUMENT` rather than exposing `KeyError` text.

---

## 9.4 Persist the submit ledger

```python
async def submit_once(device_id: str, op_id: str, params: SubmitParams) -> dict:
    request_hash = hash_canonical_request("prompt.submit", params.model_dump())

    row = operations.get(device_id, op_id)
    if row:
        if row.request_hash != request_hash:
            raise ProtocolConflict("op_id reused with different request")
        if row.state == "succeeded":
            return row.response
        if row.state == "ambiguous":
            raise GatewayAmbiguous(op_id)
        if row.state in {"received", "executing"}:
            raise OperationInProgress(op_id)

    operations.insert_received(
        device_id=device_id,
        op_id=op_id,
        request_hash=request_hash,
        method="prompt.submit",
    )

    operations.mark_executing(device_id, op_id)
    try:
        result = await gateway_prompt_submit(params)
    except ConnectionError:
        operations.mark_ambiguous(device_id, op_id)
        raise GatewayAmbiguous(op_id)

    operations.mark_succeeded(device_id, op_id, result)
    return result
```

The database calls around each transition must be transactions.

---

## 9.5 Split per-device send workers

```python
class DeviceSender:
    def __init__(self, device_id: str, max_pending: int = 256) -> None:
        self.device_id = device_id
        self.queue: asyncio.Queue[OutboundWork] = asyncio.Queue(max_pending)

    def offer(self, work: OutboundWork) -> bool:
        try:
            self.queue.put_nowait(work)
            return True
        except asyncio.QueueFull:
            return False
```

The main Reframer publishes state changes once. Each device router decides:

- Whether the device is subscribed.
- Whether to send a live delta.
- Whether to coalesce a checkpoint.
- Whether to generate a push.

A device socket must never be awaited in the global event pump.

---

# 10. Deployment layout

Recommended repository layout:

```text
relay/
  hermes_relay/
    app.py
    gateway_client.py
    reframer.py
    projection.py
    storage.py
    identity.py
    pairing.py
    crypto.py
    hub_client.py
    device_router.py
    frame_batcher.py
    operations.py
    notification_sender.py
    protocol/
      v2_models.py
      errors.py

server/
  relay-hub/
    relay_hub/
    migrations/
    tests/
    Dockerfile

  push-gateway/
    push_gateway/
    migrations/
    tests/
    Dockerfile

apps/ios/
  HermesMobile/
    RelayV2/
      RelayAccountStore.swift
      RelayCrypto.swift
      RelayTransport.swift
      RelayReducer.swift
      RelayCommandSender.swift
      PairingCoordinator.swift

  HermesNotificationService/
    NotificationService.swift
    PreviewCrypto.swift

docs/mobile-relay/
  THREAT-MODEL.md
  HRP-V2.md
  PAIRING-V2.md
  PUSH-V2.md
  OPERATIONS.md
  SELF-HOSTING.md
```

For self-hosted Hub:

```text
relay-hub
postgres or sqlite
reverse proxy example
health checks
migration job
purge job
```

The official Push Gateway remains separately hosted.

A custom app bundle may self-host the Push Gateway with its own APNs credentials.

---

# 11. Database requirements

## Hosted Hub PostgreSQL

Minimum schema:

```sql
CREATE TABLE routes (
    route_id        TEXT PRIMARY KEY,
    auth_public_key BYTEA NOT NULL,
    route_type      TEXT NOT NULL,
    status          TEXT NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL,
    revoked_at      TIMESTAMPTZ
);

CREATE TABLE grants (
    grant_id          TEXT PRIMARY KEY,
    source_route      TEXT NOT NULL REFERENCES routes(route_id),
    destination_route TEXT NOT NULL REFERENCES routes(route_id),
    permissions       INTEGER NOT NULL,
    issuer_signature  BYTEA NOT NULL,
    revoked_at        TIMESTAMPTZ,
    UNIQUE (source_route, destination_route)
);

CREATE TABLE messages (
    destination_route TEXT NOT NULL REFERENCES routes(route_id),
    message_id        BYTEA NOT NULL,
    source_route      TEXT NOT NULL,
    message_class     SMALLINT NOT NULL,
    expires_at        TIMESTAMPTZ NOT NULL,
    collapse_id       BYTEA,
    key_generation    INTEGER NOT NULL,
    hpke_enc          BYTEA NOT NULL,
    ciphertext        BYTEA NOT NULL,
    sender_signature  BYTEA NOT NULL,
    size_bytes        INTEGER NOT NULL,
    created_at        TIMESTAMPTZ NOT NULL,
    delivered_at      TIMESTAMPTZ,
    PRIMARY KEY (destination_route, message_id)
);
```

There must be no schema columns named:

```text
session_id
turn_id
item_id
prompt
title
body
tool_args
tool_result
```

The operations dashboard may show:

```text
route
class
size
age
delivery state
```

only.

## Retention

- Active mailbox row: delete after authenticated delivery ACK or expiry.
- PostgreSQL WAL and backups: document a maximum retention, recommended seven days for deleted ciphertext.
- Logs: no ciphertext body by default; log message ID hash, class, byte count, and status.
- Self-hosted SQLite: `VACUUM`/secure-delete policy must be documented honestly; “deleted” does not necessarily mean immediately unrecoverable from filesystem snapshots.

---

# 12. Verification plan

## Cryptography

- RFC 9180 HPKE test vectors.
- Python-to-Swift and Swift-to-Python fixtures.
- Authenticated sender mismatch.
- Wrong recipient generation.
- AAD mutation.
- Ciphertext truncation.
- Duplicate `mid`.
- Expired message.
- Key rotation overlap.
- Removed old-key behavior.

## Pairing

- Five-minute expiry.
- Atomic concurrent claim.
- Same-device resume.
- Different-device race.
- QR screenshot attacker race.
- Human confirmation rejection.
- Agent restart while offer pending.
- Hub provisional route expiry.
- Push bind token one-time use.
- PairConfirm never received.
- Version downgrade attempt.
- Revoked offer.

## Stream and state

- Duplicate delta does not append twice.
- Out-of-order batch triggers sync.
- Gap within retained range replays.
- Gap outside range produces checkpoint.
- Agent crash after sequence allocation.
- Agent crash after outbox commit.
- Device crash before GRDB commit.
- Device crash after commit but before Hub ACK.
- Stream reset.
- Snapshot replacement and tombstones.
- Two sessions with the same item ID.
- Agent restart cannot reuse item/turn IDs.
- A slow device does not delay another.

## Commands

- Duplicate `op_id`, same content.
- Duplicate `op_id`, different content.
- Prompt accepted, response lost.
- Agent crash during gateway call.
- Resume returns different live ID.
- Approval first-device-wins.
- Opposite decision after claimed decision.
- Expired approval.
- Revoked device action.
- Hub delivers action twice.
- Gateway already resolved.
- Offline Agent and 24-hour mailbox boundary.
- Mailbox full retains local WorkRepository job.

## Malicious Hub

- Reads no inner content.
- Modifies outer route.
- Modifies ciphertext.
- Replaces encapsulated key.
- Replays a valid message.
- Reorders batches.
- Withholds a batch.
- Sends another device’s ciphertext.
- Duplicates a checkpoint.
- Lies about Hub acceptance.
- Deletes before delivery.

Expected result:

```text
No unauthorized content is committed.
No side effect executes twice merely because transport duplicated traffic.
State either converges or enters an explicit synchronization/error state.
```

## Push

- App Attest challenge reuse.
- Counter rollback.
- Wrong App ID.
- Development assertion against production.
- Token rotation.
- APNs 410 pruning.
- Production and sandbox tokens separated.
- Serialized payload at 3,900 and 4,097 bytes.
- NSE successful preview.
- Wrong Agent key.
- NSE timeout.
- Device rebooted but never unlocked.
- Privacy mode while locked.
- Approval category appears only after decryption.
- Revoked push binding.
- Capability class escalation.
- Capability quota exhaustion.
- Real TestFlight production APNs device.

## Service installation

- launchd user service.
- systemd user service.
- systemd system service.
- Windows service.
- Upgrade in place.
- Repeated enable.
- Repeated disable.
- Multiple `HERMES_HOME` profiles.
- Paths containing spaces.
- State directory permission checks.
- Gateway unavailable during startup.
- Hub unavailable during startup.
- Rollback after partial installation.

## Logging and privacy

Automated scans must prove logs do not contain:

```text
gateway tokens
pair secrets
private keys
send capabilities
APNs tokens
preview plaintext
prompt text
tool arguments
tool output
session IDs in Hub/Push logs
```

---

# 13. Implementation order

## Phase 0 — repair the present relay contract

Before hosted work:

1. Absorb the gateway parameter and live-session corrections.
2. Fix Swift/Python request schemas.
3. Stop duplicate delta application.
4. Partition Swift state by session.
5. Add stream identity or force an explicit snapshot reset on every connection.
6. Make `open` behavior match its documented contract.
7. Add strict protocol validation.
8. Add per-device send workers even for local tests.

Do not call the current direct WebSocket path production-ready after these fixes; this is only a trustworthy baseline.

## Phase 1 — durable Agent core

1. SQLite storage.
2. Persistent identity.
3. Device registry.
4. Pairing offer state machine.
5. Durable stream/outbox.
6. Operation ledger.
7. Session alias persistence.
8. Per-device subscriptions and presence.
9. Protocol-v2 fixtures.

## Phase 2 — Relay Hub

1. Route and grant APIs.
2. Signed outer envelopes.
3. PostgreSQL and SQLite backends.
4. WebSocket and HTTP delivery.
5. Quotas and class-specific overflow.
6. Authenticated delivery ACK.
7. Purge and retention jobs.
8. Self-host Compose package.

## Phase 3 — iOS E2EE transport

1. Device keys.
2. Pairing scanner.
3. Authenticated HPKE.
4. GRDB stream state.
5. HRP/2 reducer.
6. WorkRepository command adapter.
7. Feature-flagged live cutover.
8. Legacy direct-gateway fallback only when explicitly configured—not silent downgrade.

## Phase 4 — encrypted push

1. Split Push Gateway.
2. App Attest endpoint registration.
3. Per-binding send capabilities.
4. Notification Service Extension target.
5. Shared preview Keychain group.
6. Encrypted preview rendering.
7. Durable approval action path.
8. Production APNs physical-device validation.

## Phase 5 — migration and rollout

1. Pair v2 devices separately from legacy relay devices.
2. Do not reuse the existing shared pairing secret.
3. Run local/direct and hosted-v2 modes side by side behind explicit configuration.
4. Require re-pairing for v2.
5. Remove plaintext push metadata only after all supported app builds understand encrypted previews.
6. Disable the existing chat tunnel in production.
7. Remove legacy credentials after a defined migration window.

---

# Bottom line

The proposal’s component split is correct, but three changes are non-negotiable:

1. **Replace Noise transport with independently decryptable authenticated HPKE messages for the initial mailbox protocol.**
2. **Replace per-connection seq/ack with a durable per-device stream ID, revisioned item operations, checkpoints, and a crash-safe operation ledger.**
3. **Replace—not wrap—the current plaintext push/tunnel path with an opaque Hub envelope and a per-device encrypted APNs preview.**

The existing GatewayClient, Reframer concept, item views, and WorkRepository are worth retaining. The current downstream server, replay semantics, shared pairing capability, relay-fired plaintext notifier, and hosted tunnel must be treated as prototypes rather than the foundation of the security boundary.

Until those changes land, the strongest accurate description is:

> **A local relay-client prototype with item streaming and APNs integration—not yet a secure hosted E2EE relay architecture.**
