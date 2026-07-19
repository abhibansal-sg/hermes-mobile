# Hermes Mobile Relay v2

This directory describes the HRP/2 implementation on the isolated
`codex/mobile-relay-v2-proposal` branch.

The implementation has four independently deployable components:

1. **Agent Relay** — a first-class Hermes Gateway client that owns the local
   durable projection, device identities, end-to-end encryption, and RPC
   dispatch.
2. **Relay Hub** — a content-blind mailbox and route/grant service. It handles
   only signed encrypted envelopes.
3. **Push Gateway** — a separate APNs endpoint registry and sender. It handles
   only encrypted notification descriptors and cannot read previews.
4. **iOS app + Notification Service Extension** — the paired HRP/2 device,
   durable command outbox, local projection, and offline preview decryptor.

Start here:

- [Protocol and component contract](HRP-V2.md)
- [Pairing and first-device activation](PAIRING-V2.md)
- [Push privacy and App Attest](PUSH-V2.md)
- [Threat model](THREAT-MODEL.md)
- [Self-hosting](SELF-HOSTING.md)
- [Operations](OPERATIONS.md)
- [Verification record and remaining release gates](VERIFICATION.md)
- [Migration from relay v1](MIGRATION-V1-V2.md)
- [Original architecture proposal](HRP-V2-PROPOSAL.md)

The checked-in schema and deterministic cross-language fixtures live under
`protocol/hrp2/`. They are the wire source of truth. A protocol change must
update the schema, Python tests, hosted-service tests, and Swift tests in the
same commit.

## Validation boundary

The branch can prove local builds, deterministic cryptographic fixtures,
service tests, crash/retry behavior, and simulator behavior. Production APNs,
App Attest, TestFlight entitlements, and real-device background execution must
still be validated with Apple credentials and physical devices before a public
hosted rollout.
