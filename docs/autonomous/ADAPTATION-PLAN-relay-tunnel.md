# Adaptation Plan — Optional Relay Mode (ABH-208) + Reverse Tunnel (ABH-202)

Status: FOR REVIEW (architect output, no code written)
Reference impl: `/tmp/fetch-plugin-src/` (Fetch plugin + push-relay server, read in full)
Target: `plugins/hermes-mobile/`
Mandate: **reuse Fetch's implementation, adapt — do not reinvent.** Direct mode stays DEFAULT.

---

## 0. The single most important finding

Fetch's relay server is **already Hermes-branded at the env layer**. Every knob is
`HERMES_RELAY_*` / `HERMES_APNS_*` (`app.py:85-119` `Settings.from_env`). Only TWO
Fetch-brand literals exist in the entire relay:

- `app.py:44` — `_DEFAULT_ALLOWED_BUNDLE_IDS = frozenset({"com.brentwarner.fetch"})`
- `app.py:35-39` — `_GENERIC_COPY` bodies ("Fetch replied", "Fetch needs your attention", "Fetch update")
- `app.py:821` — `FastAPI(title="Fetch Push Relay", ...)`

That means the relay server is a **near-verbatim lift**, not a rewrite. The real
design work is on the *plugin* side, where our direct-mode `push_engine.py` and the
relay's fan-out model must coexist behind one opt-in switch.

---

## 1. LIFT vs REWRITE (file-by-file)

### LIFT VERBATIM (copy, change ≤3 literals)

| Source file | Dest | Change |
|---|---|---|
| `server/push-relay/push_relay/app.py` (1043L) | `server/push-relay/push_relay/app.py` | `app.py:44` bundle id → `ai.hermes.app`; `app.py:35-39` copy → "Hermes …"; `app.py:821` title → "Hermes Push Relay". Nothing else. |
| `server/push-relay/push_relay/attestation.py` (105L) | same | **Zero changes.** Platform-agnostic `Verifier` protocol; `app_id` is injected from `settings.apple_app_id` (`app.py:795`). The raw-nonce comment (`attestation.py:35-40`) is a correctness invariant — preserve verbatim. |
| `server/push-relay/push_relay/tunnel.py` (275L) | same | **Zero changes.** Relay-side WS broker (`ConnectionManager`/`TunnelRegistry`, `agent_tunnel`/`app_tunnel`, `TransitCipher`). Auth uses `store.authenticate_agent` / `authenticate_pairing`, agnostic to branding. |
| `server/push-relay/push_relay/__init__.py`, `Dockerfile`, `fly.toml`, `railway.json`, `requirements.txt`, `.env.example`, `scripts/*.sh` | same | Deploy scaffold. `.env.example` gets our bundle id + a comment that self-hosting is supported. |
| `server/push-relay/tests/*` (4 files) | same | Adjust the two bundle-id fixtures; otherwise lift. These are behavior tests (attestation dual-env, collapse, tunnel), not change-detectors. |

The relay is a **new top-level `server/` tree in the repo** (Fetch ships it as a
sibling of the plugin). It is NOT imported by the plugin — they share only the HTTP
contract + the on-disk creds file. Zero core-schema footprint (Footprint Ladder
rung 2/4: CLI-managed service + plugin client).

### LIFT + LIGHT ADAPT (plugin client — the real work)

| Source file | Dest | Adaptation |
|---|---|---|
| `fetch-plugin/_relay.py` (410L) | `plugins/hermes-mobile/relay_client.py` | (a) `DEFAULT_RELAY_URL` (`_relay.py:34`) → **empty/None**; relay mode is opt-in, no hosted default. (b) env prefix `HERMES_FETCH_*` → `HERMES_MOBILE_RELAY_*`. (c) creds path `push/fetch-relay.json` (`_relay.py:352`) → `push/relay.json`. (d) `body={"app": "fetch-ios"}` (`_relay.py:179`) → `"hermes-ios"`. Everything else (0o600 atomic `_write_credentials` `_relay.py:308-326`, 401 re-mint, `NeedsAttestation`, dedupe) lifts verbatim — it already matches our `device_tokens.py` atomic-write pattern. |
| `fetch-plugin/_tunnel.py` (561L) | `plugins/hermes-mobile/tunnel_client.py` | Agent-side reverse tunnel. Lift `AgentTunnel`, `TunnelOwnerLock` (0o600 `O_EXCL` `_tunnel.py:138` — same posture as our registries), `_LoopHealth`, websockets 12-15 shim (`_tunnel.py:328`). Change: `DEFAULT_DASHBOARD` port `9119` (`_tunnel.py:52`) → our dashboard port; header `X-Hermes-Session-Token` (`_tunnel.py:492`) already correct. Rename log channels `fetch_plugin.*` → `hermes_mobile.*`. |
| `fetch-plugin/_runtime.py` (356L) | `plugins/hermes-mobile/relay_runtime.py` | Headless dashboard keep-alive. Lift wholesale; rename env `HERMES_FETCH_TUNNEL_*` → `HERMES_MOBILE_TUNNEL_*`, pid file `fetch-relay-runtime.pid` → `mobile-relay-runtime.pid`, and `_command_looks_like_runtime` needle (`_runtime.py:81`). |

### KEEP OURS — do NOT replace (direct mode)

| Our file | Why it stays authoritative |
|---|---|
| `push_engine.py` (1403L) | Our **direct-mode** APNs sender. `notify()` :803, `notify_live_activity()` :899, `_get_provider_jwt()` :750 already do ES256 JWT cache, HTTP/2, 410-prune, sandbox/prod split. The relay's `APNsClient` (`app.py:588-653`) is a *remote copy* of this exact logic. Direct mode is DEFAULT → this is the primary path; relay is the alternative transport. |
| `device_tokens.py` (427L) | Hash-at-rest bearer, deny-set, live-WS cut. **Untouched** — the relay uses `agent_id`+`agent_secret` for a *different* trust boundary (host↔relay), orthogonal to device↔host. |
| `dashboard/api.py` push routes (`:780-825`) | `/push/register` etc. stay as the direct-mode device registry. Relay mode adds NEW routes (see §3), does not modify these. |

---

## 2. DIVERGENCES (must handle, not skip)

1. **Push taxonomy mismatch.** Relay `PushKind = replies | attention | proactive`
   (`app.py:26`). Our direct engine uses `approval | clarify | turn_complete`
   (`push_engine.py:414` `PUSH_EVENT_KINDS`). The relay client's `send_event(kind=…)`
   must **map our kinds → relay kinds** at the seam (approval→attention,
   clarify→attention, turn_complete→replies). Do the mapping in `relay_client.py`,
   NOT by editing the relay (keep the relay a clean lift).

2. **Bundle ID.** `ai.hermes.app` (our `push_engine.py:67` `DEFAULT_TOPIC`,
   `PushRegistrar.swift` stamps `env=production`). Change the relay's
   `_DEFAULT_ALLOWED_BUNDLE_IDS`; the plugin's device registration already sends the
   right bundle id.

3. **No hosted relay default.** Fetch hard-codes `push.tryfetchapp.com`
   (`_relay.py:34`). ABH-208 requires self-hosted. Relay URL is **required config**
   when relay mode is on; empty = relay mode off. No fallback to anyone's server.

4. **Transport selection.** Direct mode = APNs key on host (`push_engine`). Relay mode
   = key on relay, host holds only `agent_id`+`agent_secret`. These are mutually
   exclusive *push* paths but the **reverse tunnel is independent of both** — it can
   run in either mode (it carries the dashboard, not pushes).

5. **Tailscale coexistence (ABH-202).** The tunnel must be **additive**. Our
   `mobile_pair.py` resolves a Tailscale Serve URL (`_detect_dashboard_url` :421).
   The tunnel is a SECOND reachability path, selected by relay pairing, never
   replacing Serve. `_spawn_tunnel` (`__init__.py:417`) already gates on pairing
   presence + `HERMES_MOBILE_TUNNEL_ENABLED`, default-off on a fresh host.

---

## 3. SLICES (review + approval gates between each)

**Slice A — Relay server lift (deployable, no plugin wiring).**
Copy `server/push-relay/` tree; change the 3 literals; adjust 2 test fixtures.
Verify: `pytest server/push-relay/tests/` green; `docker build` succeeds; `/healthz`
returns `{apns_configured:…}`. No plugin changes. **Ship-independent.**

**Slice B — Relay client (opt-in push transport).**
Add `relay_client.py` (adapt `_relay.py`) + config gate `HERMES_MOBILE_RELAY_URL`.
Add kind-mapping. In `push_engine.notify()`, branch: if relay configured →
`relay_client.send_event_background(...)`; else existing direct APNs path. One `if`
at the top of `notify()`/`notify_live_activity()`; direct path byte-unchanged when
relay is off. Verify: unit test both branches; E2E against a local relay (Slice A)
with a temp `HERMES_HOME`.

**Slice C — Reverse tunnel (additive reachability).**
Add `tunnel_client.py` + `relay_runtime.py` (adapt `_tunnel.py`/`_runtime.py`). Wire
`_spawn_tunnel()` into our `register()` (`__init__.py:136`) — a new `try/except`
block mirroring the existing seam-wiring guards, gated on pairing + tunnel-enabled.
Add the relay-registration routes to `dashboard/api.py` (`/relay/attest/challenge`,
`/relay/register`, `/relay/diagnostics` — adapt `plugin_api.py:279-330`). Verify:
tunnel connects to local relay, app request flows relay→tunnel→dashboard→back;
Tailscale Serve still works simultaneously (both reach the same dashboard).

**Slice D — Pairing variant + setup UX.**
Extend `mobile_pair.py` with a relay pairing code: `hermesapp://pair?relay=<url>&
agent=<agent_id>&pairing=<secret>&kind=relay` from `relay_client.relay_pairing()`
(adapt `_relay.py:217`). Keep the existing Tailscale QR as default; relay QR is the
alt. Verify: both QR shapes parse; secret printed once, never logged.

---

## 4. WHAT FETCH ALREADY ANSWERS (don't re-solve)

- **Creds at rest**: `_relay.py:308-326` = atomic `os.replace` + `chmod 0o600`.
  Identical to our `device_tokens._save`. Lift, don't redesign.
- **Single-uplink contention**: `TunnelOwnerLock` (`_tunnel.py:116-290`) — cross-proc
  `O_EXCL` pidfile with stale/foreign/reclaim states. Solved. Lift.
- **Reconnect storms**: `_LoopHealth` + jittered backoff capped below the ws-orphan
  reap grace (`_tunnel.py:53`). Solved.
- **Sleeping-agent delivery**: relay `TransitCipher` store-and-forward with TTL +
  AES-GCM-at-rest (`tunnel.py:114-136`, buffer only `prompt.submit`/`session.steer`/
  `session.create` `tunnel.py:48`). Solved.
- **Multi-tenant key isolation**: relay `authenticate_agent` + per-agent device cap
  (`app.py:869`, `max_devices_per_agent`). Solved.
- **Dual APNs env on one relay**: `attest_allow_both_environments` (`app.py:70`,
  `attestation.py:81-83`). Solved.

## 5. RISK CALL

- **Cache safety**: none of this touches the model tool schema or system prompt.
  Plugin-only + a new `server/` tree. Zero prompt-cache impact. ✅
- **Footprint**: rung 2 (relay = CLI-managed service) + rung 4 (plugin client). No
  new core tool. ✅
- **Biggest risk**: the push-taxonomy mapping (§2.1). If mis-mapped, relay-mode
  pushes land under the wrong interruption level. Mitigation: pin the mapping in a
  single dict in `relay_client.py` + a unit test asserting each of our 3 kinds maps
  to a valid relay `PushKind`.
- **Second risk**: relay-mode users lose the direct engine's per-event preference
  filtering (`push_engine._entry_wants_event` :435) — the relay stores its own
  `notify_replies/attention/proactive` columns (`app.py:30-34`). Acceptable: the
  relay has an equivalent per-category toggle; document that prefs live on the relay
  in relay mode.

**Recommendation:** approve Slices A→B→C→D in order. A and B alone deliver ABH-208
(optional relay). C+D deliver ABH-202 (reverse tunnel). Each slice is independently
reviewable and revertible; direct mode is never at risk because every relay branch is
an additive `if` guarded by empty-by-default config.
