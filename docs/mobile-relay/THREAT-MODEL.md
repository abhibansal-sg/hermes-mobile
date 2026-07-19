# HRP/2 threat model

## Protected assets

- Gateway credentials and local Hermes content.
- Prompts, responses, tool input/output, session metadata, and approval data.
- Agent/device private keys and route credentials.
- APNs device tokens, App Attest material, push bind/send capabilities.
- Integrity and ordering of device projection and side-effecting commands.

## Trust boundaries

Trusted for application content:

- The user's Hermes Gateway and machine account.
- Agent Relay process and protected local storage.
- Paired iOS app, its Keychain records, and the offline NSE.
- Apple OS enforcement for Keychain, App Attest, and authenticated notification
  actions.

Not trusted for content:

- Relay Hub and its database/operator.
- Push Gateway and its database/operator.
- Networks, reverse proxies, APNs transport, and mailbox delivery order.

The hosted service operator can observe IP addresses, timing, ciphertext sizes,
route relationships, and notification class. HRP/2 does not claim to hide this
traffic analysis.

## Required security properties

1. Only an active paired device can create an accepted device command.
2. Only the paired Agent can create application state or actionable previews
   accepted by that device.
3. Hub tampering/replay cannot change committed state; reordering converges or
   triggers authoritative sync.
4. Push infrastructure cannot read preview plaintext or manufacture approval
   actions.
5. One compromised/revoked device does not authorize another device's route,
   stream, approval capability, or push endpoint.
6. Ambiguous side effects are surfaced and deduplicated; they are never blindly
   replayed as new operations.
7. No automatic v2-to-v1 downgrade crosses the per-device trust boundary.

## Threats and controls

| Threat | Control |
| --- | --- |
| Malicious Hub changes ciphertext/header | Ed25519 route signature plus Auth-HPKE AAD/authentication |
| Hub replays a message | Per-device message-ID ledger and idempotent application transaction |
| Hub reorders/drops messages | Stream ID/sequence continuity, checkpoint request, stale/offline UI |
| Mailbox response is lost | Exact persisted request/envelope and idempotent receipt |
| Push bind response is lost before local commit | Durable exchange authority, revoke-before/after-commit endpoint, and non-resurrectable exchange tombstone |
| Device misses the Agent-key overlap | Immediate local quarantine, explicit re-pair state, phased key erasure, and durable Hub/Push revocation retries |
| QR is photographed | Short expiry, one-time mailbox bearer, pair-secret transcript HMAC, human code |
| Different device races PairInit | Atomic claim bound to complete device-key hash |
| Provisional hosted Agent abuses Hub | Pairing-only route scope, short TTL, source/global quota, activation token |
| Push operator reads notification | Auth-HPKE preview; generic outer APNs alert |
| Push operator adds action buttons | Outer payload has no actionable category; NSE installs category only after decryption |
| Forged notification action | Main app re-decrypts descriptor; per-device capability and key generation |
| Approval races on two devices | First atomic capability claim supersedes siblings; exact ambiguous retry |
| APNs/send response is ambiguous or concurrent | Stable APNs identity, persisted attempt lease/fence, and monotonic terminal receipt |
| App is killed during pairing/send | Keychain/GRDB exact-request state machines and lease recovery |
| Local credential database is copied | OS credential protection/keychain handles; strict file permissions fallback |
| Logs leak secrets/content | Structured content-free errors, redaction tests, no plaintext storage columns |
| Oversized/flood requests exhaust service | Body limits, mailbox quotas, per-source/global admission limits, bounded sockets |

## Availability limits

Encryption cannot prevent the Hub, Push Gateway, APNs, or network from delaying
or dropping traffic. HRP/2 detects gaps/staleness and retries durable work, but
does not promise availability against a malicious operator.

## Residual and deployment risks

- A compromised Agent machine or unlocked paired phone can read the content it
  legitimately owns.
- Metadata/traffic analysis remains visible to hosted operators.
- Self-hosters must protect TLS, database, master keys, backups, and service
  accounts.
- Development activation tokens and App Attest bypasses must never be enabled
  in production.
- The pinned Python HPKE implementation reports RFC 9180 vector compatibility
  but no formal security audit. A focused review of the suite selection,
  transcript separation, key lifecycle, and dependency is a promotion gate.
- Apple entitlements, App Attest behavior, APNs delivery, NSE time limits, and
  background action execution require physical-device production validation.

## Release gate

Before a hosted public test, run adversarial tests for replay, reordered
batches, response loss at every mutation, route/grant revocation races,
assertion-counter reuse, APNs ambiguous sends, malformed schema fields, mailbox
overflow, process restart, and secret/log scanning. Complete a real-device
TestFlight matrix for production and sandbox APNs environments.
