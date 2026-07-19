# Migrating relay v1 to HRP/2

Relay v1 is a prototype transport with a shared pairing bearer and a
connection-scoped replay stream. HRP/2 introduces per-device identities,
durable streams, authenticated encryption, route grants, encrypted push
previews, and operation idempotency. Those trust models are not wire-compatible.

## Migration rule

Every device must explicitly re-pair for v2. Existing v1 pairing secrets,
socket acknowledgements, replay-ring sequence numbers, notification endpoint
authority, and direct-Gateway notification actions are not imported as HRP/2
credentials.

A failed v2 connection must never silently reconnect using v1. If an operator
temporarily keeps v1 available during rollout, it is an explicit separately
labelled mode with a separate endpoint/configuration and an announced removal
date.

## Agent upgrade

`hermes mobile enable` may import only non-secret legacy preferences such as a
chosen hosted URL and whether notifications were enabled. It writes the new
non-secret `mobile:` configuration to `config.yaml` and marks old values
deprecated. New Agent identity, route enrollment, per-device database, and
service definition are created independently.

Legacy credentials are not copied into the new v2 authority. After all devices
are re-paired and v2 health is proven, revoke/delete the legacy relay bearer and
remove the old service/environment entries.

## iOS upgrade

The app keeps legacy account UI available only long enough to explain that
re-pairing is required. Scanning an HRP/2 QR creates a new account record,
Keychain identity, GRDB stream/projection, and command outbox. It does not
overwrite a usable v1 account until the v2 `PairConfirm` transaction is durable.

Unsent legacy operations are not translated automatically because v1 lacks the
stable v2 `op_id`/request hash needed to prove safe replay. The UI should ask
the user to review and resubmit them after pairing.

## Push transition

Register a new App-Attested v2 endpoint and preview key. Do not reuse the old
plaintext notification registration or shared bearer. Only the one-time v2
bind token crosses to the Agent inside encrypted `PairInit`.

Once the v2 device is active, revoke the old endpoint and disable direct
Gateway action URLs/tokens. HRP/2 approval actions always re-authenticate the
encrypted descriptor and enter the durable Hub command outbox.

## Suggested rollout

1. Deploy Hub/Push v2 and migrations without enabling public enrollment.
2. Deploy Agent Relay v2 to internal machines; keep v1 explicitly available
   only for rollback.
3. Ship the iOS build to internal TestFlight and validate physical-device
   pairing, background reconnect, APNs/NSE, action, and revoke behavior.
4. Enable a small tester cohort and monitor content-free health/queue metrics.
5. Require re-pairing; show protocol version and transport domain in account
   settings.
6. Revoke v1 credentials/endpoints for migrated testers.
7. Expand cohort only after response-loss and incident drills pass.
8. Remove v1 service/config code after the announced compatibility window.

## Rollback

Rolling the software back does not convert HRP/2 devices into v1 devices. Keep
v2 identities and databases intact, stop the v2 service, and restore the
previous explicitly configured v1 service only if the user accepts its older
security model. When v2 resumes, its durable outboxes and streams continue from
their committed state.

Never delete v2 keys/state merely because a deployment is rolled back. Use
`hermes mobile disable --purge` only for intentional revocation and destructive
cleanup.
