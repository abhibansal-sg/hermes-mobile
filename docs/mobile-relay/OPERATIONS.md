# HRP/2 operations

## Agent commands

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

`enable` is idempotent: it validates Gateway access, creates/loads protected
identity, enrolls the Hub route, writes non-secret config, installs the
profile-scoped service, starts it, and checks health. Installation failure rolls
back only artifacts created by that attempt.

A first push-enabled setup requires both component endpoints explicitly:

```bash
hermes mobile enable \
  --hub https://relay.example \
  --push-url https://push.example
```

The Hub and Push Gateway are separate services and may not be inferred from
one another. Readiness proves the configured Hub route and checks that the Push
endpoint identifies itself as an APNs-configured Push Gateway. Use `--no-push`
for a Hub-only installation. Changing a Push endpoint is rejected while the old
endpoint still has binding authority; disable Push and complete its durable
cleanup before selecting another endpoint.

Both endpoint values are canonical, credential-free origins: `https://host` or
`https://host:port`, with no username, password, path, query, or fragment.
Default ports and a trailing slash are normalized. Remote plaintext HTTP is
rejected; loopback HTTP remains available for local development.

Agent routes are likewise scoped to one Hub deployment. `enable --hub` rejects
an endpoint change while requested, provisional, or active Agent authority
exists. Run `hermes mobile disable --purge --yes` against the old Hub and let
all remote cleanup finish before enrolling with a different Hub.

`disable` stops/uninstalls the service but retains identity and devices.
`disable --purge` requires destructive confirmation, attempts Hub route/grant
and Push binding revocation, marks devices revoked, then removes local key
material. It reports any remote revocation that could not be confirmed.

`mobile-pair` remains a compatibility alias during the command migration, but
it uses the v2 pairing workflow; it is not a silent legacy protocol fallback.

## Routine checks

- `hermes mobile status --json` should report service state, Gateway
  connectivity, Hub route state, active/revoked devices, pending/accepted
  outbox counts, oldest pending age, stream watermarks, and last content-free
  error code. Treat `re_pair_required`, pending Hub revocation, or pending Push
  credential cleanup as operator-visible work, not completed revocation.
- Hub and Push `/healthz` prove the process is alive; `/readyz` additionally
  proves required database/production configuration.
- Alert on sustained mailbox growth, old Agent outbox rows, repeated
  `GATEWAY_AMBIGUOUS`, provisional capacity exhaustion, challenge/receipt
  capacity, database-worker saturation, socket-byte overflow, APNs permanent
  rejection, provider `Retry-After` cooling, and purge failures.
- Metrics and logs must remain content-free and local/operator controlled. No
  outbound analytics or tester attribution is enabled by this feature.

## Logs

Agent logs live in the active Hermes profile's log directory and are readable
with `hermes mobile logs`. Secret and plaintext fields are never emitted.

Hub logging may include a truncated hash of message ID, route class, byte
count, status, and latency. Push logging may include a truncated binding hash,
notification class, byte count, provider status, and prune decision. Never log
envelope ciphertext at normal levels, APNs tokens, assertions/attestations,
private/provider keys, bind/send/activation capabilities, prompts, session IDs,
approval data, or decrypted previews.

## Retention and maintenance

- Expire mailboxes at the envelope deadline and purge authenticated ACKed rows.
- Retain hash-only idempotency/confirmation receipts only for their configured
  recovery window (24 hours by default for pairing confirmation).
- Expire provisional routes, offers, pending routes/grants, challenges, bind
  tokens, and encrypted exact-response receipts. Retain hash-only binding
  exchange revocation authorities/tombstones for at least the maximum delayed
  exchange and retry window; receipt expiry must not permit resurrection.
- Run PostgreSQL migrations as one-shot jobs before the application rollout.
- Test restore procedures. A database backup without the corresponding Push
  token master-key versions cannot restore APNs endpoints.
- Cap backup, replica, and WAL retention according to the published privacy
  policy.

## Key rotation

Rotate independently:

1. TLS/ACME material.
2. Hub activation signing key (publish overlap, then retire).
3. Push token master key (add new version, rewrap every row, verify, then
   retire the old version).
4. Push capability pepper (requires a planned re-binding strategy; hashes
   cannot be re-derived without live capabilities).
5. APNs provider key.
6. Agent/device agreement and preview keys using explicit generations and an
   overlap deadline.

The Push token keyring is bounded to 16 versions. After every writer selects
the new current version, run `python -m push_gateway rewrap-token-keys`, verify
that only the current version remains in use, and only then remove the old key.
The Hub and Push activation-signing overlap sets are independently bounded to
eight key IDs. Provider throttling is durable: the Push Gateway combines its
local backoff with a bounded APNs `Retry-After` value and will not reserve a new
provider attempt before that time.

Agent and device KEM maintenance is automatic: rotate after seven days or
10,000 encrypted messages, whichever comes first. Never reuse a retired
generation number. A device key rotation is an authenticated, crash-safe
control operation and must preserve the previous private key for at least the
maximum mailbox TTL plus 24 hours of clock/retry grace before erasure.

Treat Hub acceptance as transport durability only. Do not promote a prepared
device KEM generation until the Agent returns an authenticated
`delivery_receipt` for the exact rotation message. Agent sender generations are
acknowledged and advanced per device after its atomically queued rotation
notice; a successful rotation on one phone must not move any other phone.
After a crash, retry the persisted exact ciphertext and consult the durable
semantic receipt ledger before emitting another receipt.

When a device does not acknowledge an Agent generation before the bounded
overlap expires, the Relay atomically quarantines it as revoked with
`re_pair_required` and reason `relay_kem_overlap_expired`. Local device keys,
grants, subscriptions, queued work, and notification authority fail closed
immediately. Hub route/grant deletion and Push binding revocation then run as
durable, idempotent remote jobs. Their protected revoke capabilities are erased
only after remote confirmation; outages and lost responses remain pending and
visible across restarts. These jobs do not block healthy devices from receiving
the next Agent generation.

## Incident response

### Suspected device compromise

Run `hermes mobile revoke <device-id>`. Verify local device state, Hub route and
both grants, approval capabilities, pending mail, and Push binding are revoked.
Other devices remain active. If the compromised device could read Agent
content, rotate the Agent agreement key after revocation.

### Suspected Agent compromise

Stop the service, revoke every device/route/binding from a trusted environment,
rotate Gateway credentials, replace the Agent identity, and require re-pairing.
Do not restore the old relay credential database into the new identity.

### Hub compromise

Assume metadata and ciphertext were exposed. Rotate Hub operational secrets and
TLS, audit route/grant state, and force checkpoint convergence. Authenticated
HPKE keys need rotation only if an endpoint was also compromised; the Hub does
not possess them.

### Push compromise

Rotate APNs provider credentials, token master keys, activation signing key,
and capability authority as applicable. Revoke/rebind endpoints. Notification
plaintext remains protected unless an endpoint/Agent preview key was also
compromised.

## Release verification

Run, at minimum:

- Relay v1 compatibility and full v2 unit/integration suites.
- Hub and Push suites against isolated SQLite plus migration parity checks.
- Deterministic Python/Swift HPKE fixtures and malformed-schema rejection.
- Wheel build and import in a clean virtual environment.
- iOS safe-wrapper build and test suite.
- Docker Compose configuration validation and container health checks.
- Response-loss, process-kill, replay, reorder, overflow, expiry, and revoke
  scenarios across component boundaries.
- Diff/secret/privacy scans.

The Python implementation currently pins `pyhpke` 0.6.5. Its upstream project
states that it passes the RFC 9180 vectors but [has not been formally
audited](https://github.com/dajiaji/pyhpke/blob/v0.6.5/README.md#security).
Interoperability tests and dependency scanning are necessary evidence, not a
substitute for the focused cryptographic review required before a public hosted
test.

Production APNs, App Attest, TestFlight signing, NSE deadlines, and background
action delivery must also pass on physical devices; simulator green is not a
substitute.
