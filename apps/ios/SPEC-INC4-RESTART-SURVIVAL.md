# SPEC — Connection Modes Increment 4: Restart Survival / Address Stability

Status: spec 2026-06-18. Parent: `CONTRACT-CONNECTION-MODES.md` §Increment 4.
Built via the Claude Code OS verify-loop. Tracked: ABH-169.

## What's already true (grounding — do NOT rebuild)

`ConnectionStore.swift` already gives us most of restart survival:
- **Persistence:** `configure()` writes `serverURL` (UserDefaults) + token (Keychain, keyed by URL) ONLY after a verified connect (~614-617). `bootstrap()` (~507-519) re-reads them on launch and re-runs `configure()` → **app-restart survival already works** for a stable URL+token.
- **Reconnect re-resolves the address:** `startReconnectLoop()` (~1038-1097) rebuilds `URL(string: serverURLString)` and calls `client.connect(...)` fresh on EVERY attempt → URLSession re-resolves DNS each time. A **MagicDNS hostname (stable name, changing IP) is handled by construction** — no iOS change needed.
- **No spurious re-pair:** `reauthRequired` flips true ONLY on a definitive 401/403 (`probeIsAuthRevoked`, after `authReprobeThreshold` consecutive failures). A gateway bounce with a still-valid token → the loop keeps retrying and recovers with `reauthRequired == false`.
- **Persistent token:** post-connect `autoUpgradeToDeviceTokenIfNeeded` swaps a shared token for a server-minted **per-device token** when the gateway advertises the `devices` capability → that token survives a gateway restart.

**Conclusion:** restart survival is WON or LOST at *pairing time*, by whether the phone is handed a STABLE address. If pairing hands an ephemeral `127.0.0.1:{ephemeral-port}` URL, no iOS cleverness saves it. If it hands a MagicDNS hostname or a fixed port, the existing iOS path already survives.

## Honest limit (must be stated, not hidden)

Pure **stock local mode** uses an ephemeral port AND a memory-only token. Address stability (this increment) fixes the port half via MagicDNS/fixed-port. The token half is only solved if the gateway advertises `devices` (→ persistent device token via the existing auto-upgrade). On a stock gateway WITHOUT `devices`, a local-mode restart still needs the user to re-enter the token — documented, not silently broken.

## Scope (two lanes)

### Lane 4a — Plugin: prefer a stable address at pair time (`plugins/hermes-mobile/mobile_pair.py`)
- When building the pair payload / resolving the dashboard URL, prefer in order:
  1. **Tailscale MagicDNS hostname** (`<host>.<tailnet>.ts.net`) if the node is on a tailnet — reuses the Serve→loopback path already trusted. Resolve via `tailscale status --json` (already a dependency of the Serve path) — read `Self.DNSName` / `MagicDNSSuffix`; do NOT shell out to anything new beyond what the Serve resolution already uses.
  2. **Fixed default port** (LAN fallback) — when a stable LAN address + fixed port is configured, prefer it over an ephemeral discovered port.
  3. Existing ephemeral/loopback discovery (unchanged fallback).
- Add an `address_stability` field to the payload: `"stable"` (MagicDNS/fixed) | `"ephemeral"` (loopback ephemeral) so the iOS side / tests can assert it.
- **Boundary:** all changes in `plugins/hermes-mobile/mobile_pair.py` ONLY. NO stock-core edits (`tui_gateway/`, `hermes_cli/`, `ui-tui/`). Reviewer must confirm.
- **Verify:** pytest — (i) MagicDNS hostname present → payload uses it + `address_stability="stable"`; (ii) only ephemeral loopback available → `address_stability="ephemeral"` + existing behavior unchanged; (iii) malformed/absent tailscale status → clean fallback, no crash.

### Lane 4b — iOS: prove + harden gateway-restart survival
- **Primary deliverable is the proof:** an integration test that connects to the isolated `:9123` rig, restarts the gateway at the SAME address+token, and asserts the phone returns to `.connected` with `reauthRequired == false` and NO re-pair prompt.
  - Unit-level (preferred, deterministic, CI-safe): a `ConnectionStore` test using the existing `#if DEBUG` seams + a fake client that fails once then succeeds → assert the loop drives `.reconnecting → .connected`, `reauthRequired == false`, `hasConnected` stays true. (Mirror the existing ChatStore DEBUG-hook test style; deterministic, no real socket.)
  - If a live variant is added, it MUST skip-guard when no `HERMES_URL`/`HERMES_TOKEN` (L4 — cloud runs the full plan).
- **Hardening (only if the test exposes a gap):** ensure a reconnect that ultimately re-pairs preserves the persisted address (so a manual token re-entry reuses the stable URL, not a stale ephemeral one). Likely already true (URL persists independently of token); add a test asserting it.
- **Boundary:** `apps/ios/` only. No transport rewrite — reuse the existing reconnect loop.
- **Verify:** `scripts/ios-build.sh test -only-testing:<the new test(s)>` green locally; full-plan green in Xcode Cloud after merge.

## Success criteria (maps to CONTRACT §End-state #4)
1. Plugin: a tailnet node yields a `stable` (MagicDNS) pair address; pytest proves it + the ephemeral fallback.
2. iOS: a gateway restart at a stable address+token → `.connected` recovers, `reauthRequired == false`, no re-pair (deterministic test).
3. The honest local-mode token limit is documented in `KNOWN-ISSUES.md` (or the connection-modes doc), not hidden.
4. Stock gateway untouched; all diffs in `plugins/hermes-mobile/` + `apps/ios/`.

## Critical files
- 4a: `plugins/hermes-mobile/mobile_pair.py` (discovery/pair payload), its pytest.
- 4b: `apps/ios/HermesMobile/Stores/ConnectionStore.swift` (reconnect ~1038, bootstrap ~507), a new `ConnectionStore` reconnect test under `HermesMobileTests/`.
