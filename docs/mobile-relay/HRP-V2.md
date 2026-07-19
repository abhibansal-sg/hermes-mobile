# Hermes Relay Protocol v2

HRP/2 is the end-to-end protocol between one Agent Relay and its paired iOS
devices. The hosted Relay Hub and Push Gateway are transport services, not
trusted application peers.

## Component boundaries

```text
Hermes Gateway <-local JSON-RPC/REST-> Agent Relay
                                         |
                                  Auth-HPKE + Ed25519
                                         |
                                    Relay Hub
                                         |
                                  Auth-HPKE + Ed25519
                                         |
                                      iOS app

Agent Relay --encrypted preview + capability--> Push Gateway --APNs--> NSE
```

The Agent Relay is the only component that translates Hermes Gateway events
and methods. The Hub never receives an RPC method, prompt, session identifier,
tool output, or notification plaintext. The Push Gateway never receives a
notification title, body, approval request identifier, or session identifier.

## Cryptography

HRP/2 uses:

- X25519 for static agreement keys.
- Ed25519 for Hub route authorization.
- HPKE authenticated mode with X25519/HKDF-SHA256/ChaCha20-Poly1305 for paired
  Agent/device traffic and notification previews.
- HPKE base mode plus a pairing-secret HMAC for the one-time `PairInit`.
- Canonical unpadded base64url and sorted, compact UTF-8 JSON.
- Length-prefixed binary transcripts for outer AAD and signatures.

The HPKE information strings are domain-separated by purpose and direction:

```text
hermes-mobile/hrp2/chat/agent-to-device
hermes-mobile/hrp2/chat/device-to-agent
hermes-mobile/hrp2/control/agent-to-device
hermes-mobile/hrp2/control/device-to-agent
hermes-mobile/hrp2/notification/agent-to-device
```

Private keys, route credentials, push capabilities, and pending one-time
pairing material are protected at rest. Non-secret behavior belongs in Hermes
`config.yaml`; credentials do not.

## Outer envelope

The Hub accepts only the strict outer object in
`protocol/hrp2/schema.json#/$defs/outerEnvelope`:

```json
{
  "v": 2,
  "src": "rte_sender",
  "dst": "rte_recipient",
  "mid": "ABEiM0RVZneImaq7zN3u_w",
  "class": "state",
  "expires_at_ms": 1784450000000,
  "recipient_key_generation": 1,
  "collapse": null,
  "enc": "base64url-hpke-encapsulation",
  "ct": "base64url-ciphertext",
  "sig": "base64url-ed25519-signature"
}
```

The Ed25519 signature authorizes routing. Authenticated HPKE proves the
end-to-end sender. A receiver validates the route, signature, key generation,
expiry, HPKE authentication, outer/inner message-ID equality, kind/class
compatibility, and replay ledger before applying content.

Transport classes are intentionally narrow:

| Outer class | Allowed direction and inner use |
| --- | --- |
| `realtime` | Agent to device `frame_batch` |
| `state` | Agent to device `frame_batch` or authoritative `checkpoint` |
| `command` | Device to Agent `rpc_request` |
| `control` | Pair confirmation, RPC response, receipts, sync, rotation, revoke |

Live deltas, thinking-status chunks, and transient turn lifecycle frames use
`realtime`; the Hub does not retain them for an offline device. Terminal full items, interactive
approval/clarification state, and other convergence material use `state`.
Missing realtime data is therefore repaired by the terminal full item or an
authoritative checkpoint instead of replaying stale deltas hours later.

The HPKE purpose is fixed by this semantic split: `realtime`, `state`, and the
device-to-Agent `command` lane use `chat`; `control` uses `control`.
`PairAccept` also uses `control`, while notification descriptors use
`notification`. Implementations must not infer a different purpose merely
because a chat command is carried in the `command` transport class.

## Durable per-device stream

Each paired device gets an independent random `stream_id`, monotonic sequence,
outbox, and bounded sender. The Agent commits projection changes and the exact
encrypted envelope before sending. A retry reuses the same `mid`, `enc`, and
`ct`; it never re-encrypts an already-committed logical message.

All HRP/2 JSON sequence, revision, operation, and millisecond timestamp values
are non-negative integers capped at `9007199254740991` (`2^53 - 1`), the
largest value that round-trips exactly through every supported JSON
implementation. Values above that limit are rejected before durable admission,
never rounded. A `frame_batch.first_seq` starts at one; a fresh stream
checkpoint may legitimately describe `through_seq` zero.

The device applies a batch, advances its stream watermark, records the message
ID, and creates its exact encrypted `stream_ack` in one database transaction.
It acknowledges the Hub mailbox only after that commit. `delivery_receipt`
separately proves that an RPC/control message reached the application layer.

Hub acceptance therefore means “durably stored by transport,” not “applied by
the peer.” Agent outbox rows remain until the encrypted application receipt.
Encrypted notification descriptors follow the same exact-retry rule. A fresh
per-device foreground lease can defer a terminal/error push, but cannot erase
it; background transition or lease expiry releases the durable descriptor.

Key rotation uses that distinction as a causal barrier. A device promotes its
prepared local generation only after an authenticated `delivery_receipt` names
the exact `key_rotate` message. The Agent encrypts that receipt to the prepared
device generation, proving that the device retained the matching private key.
For an Agent rotation, the new global key and old-generation notices are stored
atomically, but its sender generation is activated separately for each device:
one device's receipt cannot move another device forward, and all messages and
previews for an unacknowledged device continue using its last proven Agent
generation. Receipt ciphertext is retried exactly until Hub acceptance, while
a persistent semantic ledger prevents receipt recursion and duplicate
promotion.

If a device remains on the old Agent generation when the bounded overlap
expires, it is atomically quarantined as revoked and explicitly requires
re-pairing. Retiring Agent keys become unavailable before external credential
erasure begins. Hub route/grant and Push binding revocation are durable,
idempotent follow-up jobs; healthy devices continue rotating while those remote
deletions retry.

## Projection and checkpoints

`frame_batch` contains consecutive frames beginning at `first_seq`. Items use
stable random identifiers and increasing revisions. Text deltas are byte-exact
`append_utf8` operations; a gap or offset mismatch requests authoritative state
instead of guessing.

A checkpoint is a standalone authenticated secure message, not another
sequenced frame. It identifies its stream/session, the authoritative
`through_seq` boundary, snapshot revision, replacement policy, full items, and
tombstones. A device may therefore apply a newer checkpoint even when its
current watermark has a gap. Applying the snapshot, advancing the watermark,
recording the checkpoint message ID, and creating its exact receipt are one
transaction. Delayed batches at or below the accepted boundary are ignored.
A checkpoint with an older boundary/revision cannot roll state back. Every
different authoritative projection advances `snapshot_revision`; equal
revision with different snapshot content is a protocol conflict and must be
rejected rather than replacing local state. Unknown item types render as
non-privileged generic cards.

## Encrypted RPC

Commands use strict JSON-RPC 2.0 inside `rpc_request`. Side-effecting methods
require stable `op_id`; responses are cached against the operation hash. A
reused operation ID with different content is a conflict.

`prompt.submit.client_message_id` is a lowercase canonical UUID. It is created
once by the iOS WorkRepository and forwarded unchanged through the Relay to the
Gateway's durable receipt provider.

Supported methods are:

```text
session.list        session.open       session.history
session.resume      prompt.submit      session.interrupt
approval.respond    clarify.respond    presence.set
item.fetch          sync.request
```

Only stable typed errors cross the protocol. A transport loss after a
side-effect may have reached the Gateway returns `GATEWAY_AMBIGUOUS`; it must
not be silently retried as a fresh operation. Approval retries additionally
require the same device capability, decision, and operation ID.

## Forward compatibility

HRP/2 rejects unknown envelope, secure-message, control, pairing, RPC, and
approval-action fields. Unknown presentation-only item types are the deliberate
exception and render generically. Version 1 is not an automatic fallback: a v2
device must explicitly re-pair, and a v2 failure never downgrades to the shared
v1 bearer path.
