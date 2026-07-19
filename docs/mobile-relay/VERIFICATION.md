# HRP/2 verification record

**Date:** 2026-07-19
**Branch:** `codex/mobile-relay-v2-proposal`
**Base:** `origin/wave2/relay-turn-elements` at `ab570aa74`
**Status:** implementation candidate; not production-certified

This record covers the isolated HRP/2 implementation on this branch. It does
not certify a public deployment and does not imply that the branch has been
merged into any other line of work.

## Automated evidence

| Surface | Result |
| --- | --- |
| Agent Relay, locked Python 3.11 environment | 309 passed |
| Agent Relay, locked Python 3.12 environment | 309 passed |
| Agent Relay, locked Python 3.13 environment | 309 passed |
| iOS HRP/2 full simulator suite | 91 passed |
| iOS adjacent notification, push, and forget-flow suite | 36 passed |
| iOS app + Notification Service Extension safe-wrapper build | succeeded |
| Relay Hub | 38 passed |
| Push Gateway | 49 passed |
| Managed-service, plugin, distribution, and protocol evidence set | 148 passed |
| Legacy service-manager regression set | 66 passed |
| CI change-classifier regression set | 38 passed |
| Real local Agent, Hub, Push, and privacy-boundary E2E | 4 passed |
| HRP/2 schema and cross-language conformance subset | 9 passed |
| Full Compose topology with PostgreSQL 17.10, Caddy, and schema migrations | passed |

The suites exercise, among other contracts:

- authenticated HPKE fixtures shared by Python and Swift;
- one-time pairing, human confirmation, restart recovery, and per-device
  revocation;
- independent durable streams, duplicate delta rejection, checkpoints,
  tombstones, and session partitioning;
- 2,048 separate one-delta commits with restart/rollback/terminal replacement,
  constant-time persisted UTF-8 offsets, and 2,048 indexed UI projection
  patches without rebuilding the transcript location map;
- crash-safe operation IDs, ambiguous Gateway results, first-device-wins
  approvals, FIFO command draining, immediate-response waiter ordering, lost
  wake-up recovery, and disconnect-fenced drain ownership;
- content-blind Hub storage, route/grant authorization, quotas, retention,
  request bounds, replay, and opaque mailbox delivery;
- App Attest request verification boundaries, encrypted preview descriptors,
  exact APNs retry identity, push token protection, and registration recovery;
- per-device foreground leases, durable deferred notifications, and
  Notification Service Extension decryption behavior;
- authenticated key rotation, exact-ciphertext replay, per-device Agent key
  activation, notification sender generation selection, and prevention of
  receipt recursion;
- crash-idempotent Agent-key retirement, immediate hiding of retiring keys,
  automatic fail-closed quarantine of devices that miss the bounded overlap,
  and independent continuation for healthy devices;
- durable Hub-route/grant and Push-binding revocation after quarantine,
  including lost responses, process restarts, temporarily unconfigured Push,
  pending binding-exchange recovery, and delayed local credential erasure;
- fresh and upgraded iOS databases, including the complete HRP/2 command-kind
  migration and protection of canonical items from late optimistic writes.

Additional gates completed:

- the root and standalone Relay lockfiles resolve with `uv lock --check`;
- root and standalone Relay wheel/sdist builds install cleanly, with HRP/2's
  HPKE dependency remaining an explicit `mobile` extra in the root package;
- Python byte-compilation, JSON Schema validation, Swift parsing, focused
  Swift type-checking, XcodeGen regeneration, plist/entitlement validation,
  and `git diff --check` pass;
- Ruff reports no lint findings across the changed Python implementation;
- Gitleaks reports no secrets in the HRP/2 protocol, Agent Relay, hosted
  services, iOS HRP/2, documentation, plugin, or remaining tracked diff;
- fresh installed Relay, Hub, and Push runtime dependency sets report no known
  vulnerabilities;
- both full-stack and Hub-only Compose configurations render successfully, and
  the checked-in Caddy configurations validate with the pinned image;
- the complete production-shaped Compose topology builds and starts, all
  one-shot migrations finish before application startup, both readiness probes
  and Caddy routing succeed, real Hub/Push PostgreSQL writes are verified, and
  the containers, networks, and volumes are removed afterward.

These are isolated branch-owned gates. The unrelated repository-wide root test
suite was not used as a substitute for them; it discovers local externally
managed plugins and other host-specific state outside this branch on a developer
machine, while the checked-in CI lanes run in a clean checkout.

## Adversarial closure

The final correctness review specifically rechecked the original high-risk
areas: per-device isolation, duplicate/reordered delivery, pre-WAL validation,
crash boundaries, operation idempotency, waiter races, foreground clearing,
and causal key promotion. Any remaining P0/P1 finding must block promotion of
this branch; the review result is recorded in the commit handoff.

## Release gates that remain external

The following require operator infrastructure or Apple production facilities
and are deliberately not claimed by this local verification:

1. Apply and roll back the PostgreSQL migrations against the production
   topology; then prove backup/restore, replica behavior, retention jobs, and
   failover.
2. Deploy with real DNS, TLS/ACME, secrets, rate limits, monitoring, and alerting;
   run load, soak, and failure-injection tests against the intended capacity.
3. Validate production App Attest and APNs credentials, signing profiles,
   application groups, Keychain access groups, and TestFlight entitlements.
4. On physical locked and unlocked devices, validate Notification Service
   Extension time limits, preview policies, action authentication, background
   execution, token rotation, and multi-device revocation.
5. Publish the hosted-service privacy, retention, deletion, incident-response,
   and key-rotation policies before inviting external testers.
6. Complete a focused cryptographic review. The pinned Python `pyhpke` 0.6.5
   [project reports RFC 9180 vector compatibility but no formal
   audit](https://github.com/dajiaji/pyhpke/blob/v0.6.5/README.md#security);
   passing fixtures and dependency scans do not close that gate.

The protocol intentionally does not hide IP addresses, timing, message sizes,
routing relationships, or notification class. A malicious Hub can delay,
reorder, or drop ciphertext, and compromise of an Agent or paired device exposes
content available to that endpoint. A device offline beyond the bounded Agent
key overlap is automatically quarantined as revoked with `re_pair_required`;
its hosted Hub and Push authority is retried to confirmed revocation, while
healthy devices continue rotating. It never downgrades to v1 or silently
promotes an unproved key.
