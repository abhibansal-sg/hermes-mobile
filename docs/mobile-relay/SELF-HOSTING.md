# Self-hosting HRP/2

There are two useful self-hosted shapes:

1. **Local Agent Relay with hosted transport** — the Relay runs as a service on
   the Hermes computer, while ciphertext mailboxes and optional APNs delivery
   use hosted services.
2. **Fully self-hosted Hub** — the Agent Relay and Relay Hub are yours. The Push
   Gateway is optional; operating it requires Apple App Attest/APNs credentials.

The Agent Relay is always local to the Gateway. Do not place the Gateway token
on a public Hub or Push host.

## Local-only evaluation

For development, the Hub and Push Gateway can use SQLite and loopback HTTP with
their explicit development settings. This is not a production topology and
must not be exposed to a network. Production mode refuses SQLite, automatic
schema creation, open enrollment, APNs-disabled push service, and development
App Attest fallbacks.

## Production container stacks

Choose the checked-in stack that matches the services you operate:

- `server/compose.hrp2.yml` runs the Hub and optional Push Gateway together,
  with separate PostgreSQL databases and ingress networks.
- `server/compose.hub-only.yml` runs only the Hub, its PostgreSQL database,
  migration job, and a Hub-only Caddy TLS ingress. It has no Push/APNs
  variables, services, routes, secrets, or network attachments.

Both stacks use one-shot migrations, read-only application containers,
dropped capabilities, an internal database network, and Caddy TLS termination.

Configure Hub and Push locations as credential-free origins only
(`https://host` or `https://host:port`). Do not put usernames, passwords,
paths, queries, or fragments in either URL; the Relay rejects them rather than
risk leaking credentials into request construction or logs.

The QR contains only the Hub public origin. The checked-in Caddy configuration
therefore proxies the phone-only App Attest challenge, endpoint registration,
token refresh, and Hub-activation paths on that origin to the isolated Push
Gateway. Do not remove those routes in a hosted deployment unless the app is
given an equivalent trusted discovery mechanism. Agent binding/send/revocation
paths stay on the Push hostname and are not included in the Hub-origin alias.

Copy secrets into an operator-controlled environment file or secret manager;
do not commit them. The combined Hub-and-Push stack requires:

```text
HRH_POSTGRES_PASSWORD
HRH_OPERATOR_ENROLLMENT_TOKEN or HRH_ACTIVATION_PUBLIC_KEY_B64
HPG_POSTGRES_PASSWORD
HPG_TOKEN_MASTER_KEY_B64
HPG_CAPABILITY_PEPPER_B64
HPG_APPLE_APP_ID
HPG_APNS_KEY_ID
HPG_APNS_TEAM_ID
HPG_APNS_KEY_FILE
HRH_PUBLIC_HOST
HPG_PUBLIC_HOST
ACME_EMAIL
```

Generate the token master key and capability pepper independently. Mount the
APNs `.p8` file as a container secret. If the Push Gateway issues hosted Hub
activation tokens, set its Ed25519 private seed and configure the matching
public key on the Hub.

Local Docker Compose uses a bind mount for file-backed secrets. On Linux, make
an owner-only deployment copy readable by the image's fixed unprivileged
identity before starting the stack:

```sh
sudo install -o 999 -g 999 -m 0400 AuthKey_XXXXXXXXXX.p8 /secure/path/apns-key.p8
```

Set `HPG_APNS_KEY_FILE=/secure/path/apns-key.p8`. Do not loosen the file to a
group- or world-readable mode; the Push Gateway deliberately refuses it.

Before starting:

1. Point both public DNS names at the host.
2. Restrict ports so only 80/443 are public; PostgreSQL stays internal.
3. Review mailbox, challenge, and rate quotas in the two `.env.example` files.
   Also size the Hub's per-socket/global queued-byte ceilings and both
   services' bounded database-worker pools for the host.
4. Verify database volumes and backups are encrypted.
5. Apply the checked-in migrations; keep automatic schema creation disabled.
6. Start the stack and wait for both `/readyz` endpoints.
7. Confirm Caddy forwards the real client source address according to your
   trusted-proxy policy; source quotas are ineffective if every request appears
   to originate at the proxy.

Challenge and provisional-enrollment admission is PostgreSQL-coordinated, not
process-local. Source identifiers are keyed hashes; IPv6 privacy addresses are
aggregated to `/64` and IPv4-mapped IPv6 addresses use their IPv4 bucket.

Start the combined stack from the repository root with:

```bash
docker compose --env-file /secure/path/hrp2.env \
  -f server/compose.hrp2.yml up -d
```

### Hub-only production stack (`--no-push`)

The Hub-only stack requires only `HRH_POSTGRES_PASSWORD`, `HRH_PUBLIC_HOST`,
`ACME_EMAIL`, and one Hub enrollment authority:
`HRH_OPERATOR_ENROLLMENT_TOKEN` or `HRH_ACTIVATION_PUBLIC_KEY_B64`. For the
documented self-hosted `--no-push` flow, use an operator enrollment token.

Point the Hub hostname at the server, place those values in an owner-controlled
environment file, then validate and start exactly this stack:

```bash
docker compose --env-file /secure/path/hrp2-hub.env \
  -f server/compose.hub-only.yml config --quiet
docker compose --env-file /secure/path/hrp2-hub.env \
  -f server/compose.hub-only.yml up -d
```

Only Caddy publishes host ports. The Hub application and PostgreSQL database
remain reachable solely on their isolated Compose networks. The Hub-only
Caddyfile intentionally exposes no App Attest, endpoint-registration, Push
binding, APNs, or notification-send alias; pairing and chat use the Hub routes
directly.

## Agent Relay service

On each Hermes computer, configure non-secret behavior under `mobile:` in
Hermes `config.yaml`, then use `hermes mobile enable`. The command creates or
loads protected identity material, enrolls the route, installs a profile-scoped
service using launchd/systemd/Task Scheduler/s6, starts it, and verifies health.

For the full two-hostname stack, pass both independently deployed endpoints:

```bash
hermes mobile enable \
  --hub https://relay.example \
  --push-url https://push.example
```

The command does not treat the Hub as a Push Gateway. It verifies the Hub route
and the Push service's APNs readiness separately, so a swapped or mistyped
hostname fails before setup is reported healthy.

Moving an Agent between Hub deployments is deliberately not an implicit URL
edit. Purge the old Hub enrollment while that Hub remains reachable, confirm
remote cleanup, and then enable against the new Hub.

Use `--no-push` when you do not run a Push Gateway. Chat still works; pairing
uses the self-hosted operator enrollment authority and `PairAccept` omits the
notifications capability.

For first activation, put the operator token in an owner-only file and pass
only that path:

```bash
chmod 600 "$HERMES_HOME/hub-enrollment.token"
hermes mobile enable \
  --hub https://relay.example \
  --no-push \
  --hub-enrollment-token-file "$HERMES_HOME/hub-enrollment.token"
```

The token value is never written to `config.yaml`, argv, a service definition,
or logs. The file path is retained so an interrupted exact activation can
resume safely.

The Hermes wheel/sdist includes the Relay runtime. Its focused HPKE dependency
is installed through the existing opt-in lazy dependency gate when Mobile is
enabled. Packagers that prohibit runtime installs should install
`hermes-agent[mobile]` up front.

Service names include a stable hash of the active Hermes profile, so multiple
profiles do not collide. Service definitions contain non-secret values only;
route credentials and private keys stay in protected relay storage.

## Trust verification for testers

Publish:

- the repository commit and release checksums;
- signed/notarized macOS artifacts and package provenance where applicable;
- the exact Hub/Push domains and TLS policy;
- a concise statement that hosted services see metadata and ciphertext, not
  Hermes content;
- retention, deletion, incident, and key-rotation policies;
- a reproducible self-host path so users are not forced to trust your hosted
  transport.

The phone pins the Agent public keys learned from the local QR, not a hosted
operator identity. Moving between hosted and self-hosted transport therefore
does not grant the transport access to plaintext, but it is still a deliberate
configuration change and should not happen silently.

## Backups and deletion

Back up Hub/Push databases and their encryption keys separately. Without the
Push token master key, encrypted APNs tokens are unrecoverable. Keep old key
versions until all rows are rewrapped.

Mailbox and receipt rows expire and are purged. PostgreSQL WAL, replicas,
snapshots, and operator backups can retain deleted ciphertext longer than the
primary database; document the real retention window. SQLite self-hosters
should checkpoint WAL and vacuum during maintenance for best-effort physical
cleanup.
