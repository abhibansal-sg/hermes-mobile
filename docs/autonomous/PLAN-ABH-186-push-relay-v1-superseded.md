# ABH-186 — Hosted Push Relay for TestFlight Testers

**Profile:** ARCHITECT (plan only — no code in this pass)
**Status:** Awaiting DESIGN DECISION approval before any slice starts
**Grounded against:** `plugins/hermes-mobile/push_engine.py`, `device_tokens.py`,
`dashboard/api.py`, `apps/ios/HermesMobile/Support/PushRegistrar.swift`,
`apps/ios/KNOWN-ISSUES.md` (read 2026-07-01)

---

## 1. Problem (root-caused, line-level)

TestFlight builds are signed with the **publisher's** Apple cert + bundle id
`ai.hermes.app`, so the APNs device tokens iOS issues to them are **production
tokens bound to the publisher's APNs signing key**. A self-hoster's gateway
mints its own provider JWT from `HERMES_APNS_KEY_FILE` (a *different* team's
`.p8`) — Apple rejects those pushes (`403 InvalidProviderToken` / topic
mismatch). Documented in `apps/ios/KNOWN-ISSUES.md:36-43`.

Where it manifests in code — the send path is fully local today:

- `push_engine.py:750 _get_provider_jwt()` → mints ES256 JWT from the local
  `.p8`.
- `push_engine.py:786 _send_one()` → `POST https://api.push.apple.com/3/device/{token}`
  directly over httpx HTTP/2.
- `notify()` (`:803`) and `notify_live_activity()` (`:899`) are the only two
  callers; both go straight to Apple.

So the fix has exactly **two insertion points** in the gateway
(`notify`, `notify_live_activity`) plus a new hosted service and its auth.

## 2. What already works (do not regress)

- Registry, per-event prefs, env routing (sandbox/prod), 410-pruning, LA token
  upsert/GC — all in `push_engine.py`. **Relay reuses all of it unchanged.**
- REST registration routes `POST/DELETE /push/register` + `/push/live-activity`
  (`dashboard/api.py:780-825`), gated by `_has_dashboard_api_auth`.
- iOS `PushRegistrar` already stamps `env` = `production` on TestFlight and
  self-heals path family (`PushRegistrar.swift:305`, `:342`). **No token-shape
  change needed on the client.** The iOS app is untouched by this feature
  except possibly a capability hint (Slice 5, optional).

## 3. DESIGN DECISION (recommended — needs Abhi's ✅ before Slice 1)

**Publisher-hosted relay: a thin HTTPS service holding the publisher APNs key,
that the self-hoster's gateway calls instead of Apple when armed for relay
mode. Per-gateway bearer credential (issued by publisher), payload-blind
forwarding.**

Request shape (gateway → relay):
```
POST https://push-relay.hermes.app/v1/relay
Authorization: Bearer <per-gateway-relay-token>
{ "device_token": "...", "env": "production",
  "apns_headers": { "apns-push-type": "...", "apns-topic": "...",
                    "apns-priority": "...", "apns-expiration": "...",
                    "apns-collapse-id"?: "..." },
  "payload": { ...opaque aps+hermes JSON, already built by build_alert_payload... } }
```
Relay verifies the bearer, injects `authorization: bearer <publisher-JWT>` (its
own key it never shares), forwards to `api.push.apple.com`/sandbox, and returns
Apple's `{status, apns_id, reason}` so the gateway's existing 410-prune logic
still works.

**Custody:** publisher `.p8` lives only in relay infra. Never distributed. One
blast-radius.

**Auth (gateway → relay):** each registered gateway gets a unique opaque bearer
token (`secrets.token_urlsafe(32)`, publisher stores only `sha256`). Per-gateway
revocation; mirrors the exact pattern already proven in `device_tokens.py`
(hash-at-rest, timing-safe `compare_digest`, deny-set). **Reuse that module's
design, not a new HMAC scheme** — simpler, already reviewed, already in-repo.

**Privacy floor:** relay is **payload-blind by policy but not by cryptography**
— it sees `device_token`, APNs headers, and the alert JSON in transit (it must,
to forward). Honest disclosure required in `KNOWN-ISSUES.md`: "with relay ON,
notification title/body preview transits publisher infra." True end-to-end
encryption is impossible here because APNs itself needs the cleartext payload
to render the alert. **Do not over-promise E2E.** Mitigation: relay logs
metadata only (never payload body), TLS in transit, short retention.

### Rejected alternatives
- **Share the publisher `.p8` with self-hosters** — rejected: distributes the
  one key that must stay contained; a leak re-keys every tester.
- **Apple entitlement/cert sharing for one bundle id** — rejected: Apple does
  not allow cross-provider key sharing for the same bundle id on TestFlight.
- **HMAC-signed requests** — rejected in favor of the bearer+hash pattern
  already implemented and reviewed in `device_tokens.py` (less new surface).

### OPEN QUESTIONS (need Abhi's call — blocks Slice 1 scope)
1. **Relay hosting** — standalone microservice, or a route on an existing
   publisher-run backend? (Affects Slice 1 size + ops.)
2. **Relay opt-in gating** — per the repo rubric, no new `HERMES_*` non-secret
   env var for behavior. Relay **toggle** goes in `config.yaml`
   (`push.relay.enabled`); only the **relay bearer token** (a secret) goes in
   `.env` as `HERMES_PUSH_RELAY_TOKEN`. Confirm this split.
3. **Rate limiting / abuse quota** per gateway at the relay — needed for v1 or
   fast-follow?
4. **Enrollment** — how does a self-hoster obtain their relay bearer? Manual
   issue by publisher for the beta cohort, or a self-serve `hermes push relay
   enroll` flow? (Beta = manual is fine; note as follow-up.)

## 4. Slice decomposition (after approval + per-slice E2E)

Ordered; each slice independently shippable and testable.

**Slice 1 — Relay service scaffold (publisher infra, NEW; not in this repo's
runtime).** `POST /v1/relay` + `/v1/relay/live-activity`; bearer-hash auth
middleware reusing the `device_tokens.py` pattern; publisher JWT mint (lift
`build_provider_jwt`/`_get_provider_jwt` logic); httpx HTTP/2 forward to Apple;
return Apple status passthrough. Deps: OPEN QUESTION 1. Risk: **med** (new
service, key custody). E2E: real device token from a TestFlight build receives
a push routed through the relay to Apple sandbox+prod.

**Slice 2 — Gateway relay client in `push_engine.py`.** Add a `relay` branch to
the send path: a `_send_via_relay(...)` helper and a config check so `notify()`
(`:803`) and `notify_live_activity()` (`:899`) POST to the relay instead of
Apple when relay mode is armed. Reuse `build_push_headers` /
`build_alert_payload` / `build_live_activity_*` **unchanged** — relay takes the
same headers+payload. Preserve 410-prune: map relay's returned Apple status
back through the existing `stale`/`_drop_tokens` path. Risk: **low-med** (two
call sites, additive branch). E2E: gateway with relay config + no local `.p8`
delivers a background push to a real TestFlight device.

**Slice 3 — Config + arming.** New `APNsConfig` awareness of relay mode:
`config.yaml push.relay.enabled` + `HERMES_PUSH_RELAY_URL`
(non-secret → config, bridged) + `HERMES_PUSH_RELAY_TOKEN` (secret → `.env`).
`is_armed()` must accept **relay-armed** (relay url+token, no local key) as a
valid armed state alongside the existing local-key path. Wire into `hermes
tools` / setup UX (rubric: no raw env var docs). Risk: **low**. E2E: temp
`HERMES_HOME`, relay-armed config with no `.p8`, `is_armed()` true and send path
picks relay.

**Slice 4 — Relay enrollment + revocation surface.** Minimal `hermes push relay`
CLI (enroll/status/revoke) OR documented manual-issue for the beta. Audit log
relay auth events via existing `audit_log.py`. Risk: **low**. E2E: revoke kills
a gateway's relay access within one request.

**Slice 5 (optional) — iOS capability hint.** Surface "background push via
hosted relay" state so the app can show notifications as available on TestFlight.
Likely just a capability flag; the token POST is already correct. Risk: **low**.

## 5. RISK CALL

The sharp edge is **not** the gateway code (two additive call sites) — it is
**operating a service that holds the one APNs key for every tester** and being
honest that the relay sees notification previews in transit. Recommend: ship
Slices 1-3 behind an explicit opt-in for the beta cohort, land the
`KNOWN-ISSUES.md` privacy disclosure in the SAME slice that turns relay on, and
defer self-serve enrollment (Slice 4 CLI) to a fast-follow.

## 6. Rubric compliance notes (pre-empting review)

- No new core model tool. Capability rides existing gateway send path +
  config + a skill/CLI — Footprint Ladder rung 1-2.
- Non-secret relay toggle → `config.yaml`; only the bearer secret → `.env`.
- No mid-conversation cache break, no message-alternation impact (push is a
  gateway-side side effect, not in the model loop).
- Reuses `device_tokens.py` auth pattern rather than inventing HMAC.
- Payload-blind claim stated honestly (not cryptographic E2E) — disclosed in
  `KNOWN-ISSUES.md` in the enabling slice.
