# Relay Connection Hardening — Handover Document

**Date:** 2026-07-20
**Branch:** `codex/wave25-relay-device-qa`
**Latest commit:** `de6e6b7cd`
**Linear:** [ABH-513](https://linear.app/abhinav-bansal/issue/ABH-513)
**PR:** [#230](https://github.com/abhibansal-sg/hermes-mobile/pull/230) (WIP — do not merge)

---

## What was done

The mobile app's relay connection was unusable — sends failed with `-32000`, the connection indicator was unreliable, and opening the app triggered reconnect churn. Four commits fix the root causes across both the relay (Python) and the iOS app (Swift).

### Commits (in order)

| Commit | Layer | What it fixes |
|--------|-------|---------------|
| `c9e0c90d3` | Relay + iOS | Restart survival, gateway-readiness gate, foreground re-establishment |
| `e8d66f99b` | Relay | Field-name mismatch (`"prompt"` vs `"text"`) causing `-32000` on every send |
| `de6e6b7cd` | iOS | Connection state bridge, foreground reconnect churn, composer gating |

### Root causes (5 total)

1. **Relay restart lost owned sessions.** `GatewayClient._owned` was in-memory only. A relay restart emptied it, so the relay never re-resumed sessions it was driving. The phone's outbox then reported "destination session not active."
   - **Fix:** Owned sessions persist to `DurableState` (SQLite `owned_sessions` table), re-seed on startup, `run()` re-resumes them on the fresh gateway connection. Only stable origin ids are persisted — connection-local live ids stay in-memory.
   - **Files:** `relay/hermes_relay/durable_state.py`, `relay/hermes_relay/gateway_client.py`, `relay/hermes_relay/app.py`

2. **Gateway-readiness gap after restart.** After a relay restart the phone reconnects to the downstream server immediately, but the relay's gateway connection may not be up yet. A submit/resume arriving in that window failed.
   - **Fix:** `handle_upstream` gates on `wait_ready(10s)` before any gateway-hitting RPC. Local-only methods (ack/resync/foreground) bypass the gate.
   - **Files:** `relay/hermes_relay/gateway_client.py` (`wait_ready`), `relay/hermes_relay/downstream.py` (gate in `handle_upstream`)

3. **iOS foreground not re-established on reconnect.** On reconnect the phone didn't re-send `foreground{session_id}` or re-open the active session. The relay's new PhoneConnection had no foreground set (spurious APNs) and no seen_sids (empty resync snapshot).
   - **Fix:** Coordinator re-sends foreground + re-opens active session when state crosses `.open`. Added missing `.foreground` case to `RelayUpstreamMethod` enum + `RelayClient.setForeground()`.
   - **Files:** `apps/ios/HermesMobile/Models/RelayProtocol.swift`, `apps/ios/HermesMobile/Networking/Relay/RelayClient.swift`, `apps/ios/HermesMobile/Stores/RelaySessionCoordinator.swift`

4. **Field-name mismatch.** iOS `RelayClient.submit()` sends `{"prompt": "..."}` but the relay's SUBMIT handler read `p["text"]` → `KeyError` → generic `-32000` JSON-RPC error on every send.
   - **Fix:** Relay now accepts both: `p.get("prompt") or p.get("text") or ""`.
   - **Files:** `relay/hermes_relay/downstream.py`

5. **iOS connection state frozen + foreground reconnect churn.** Three sub-causes:
   - The banner + composer read `connection.phase`, stamped `.connected` once at startup, never updated when the relay dropped/recovered. → Added `onPhaseChange` to `RelaySessionCoordinator`, bridged to `connection.phase` in `ensureRelayCoordinator`.
   - `handleScenePhase` checked the gateway client's state (idle in relay mode → always `.closed`), triggering a spurious reconnect on every app open. → Now checks the relay socket in relay mode.
   - Composer `isConnected` was gated on a gateway `activeRuntimeId` the relay path never sets. → Now treats an open relay socket as ready in relay mode.
   - **Files:** `apps/ios/HermesMobile/Stores/ConnectionStore.swift`, `apps/ios/HermesMobile/Stores/RelaySessionCoordinator.swift`, `apps/ios/HermesMobile/Views/Chat/ChatView.swift`

---

## Current state

| Surface | Status |
|---------|--------|
| **Local worktree** | Clean, all committed. Path: `/Volumes/MainData/Developer/hermes-tmp/worktrees/wave25-relay-device-qa` |
| **GitHub** | All 4 commits pushed to `codex/wave25-relay-device-qa`. PR #230 updated with full description. |
| **Linear** | ABH-513 updated with comment + description reflecting all fixes. |
| **Relay tests** | 168/168 pass |
| **iOS relay tests** | All pass (RelaySessionCoordinator, RelayClient, RelayItemStore) |
| **iOS build** | Compiles clean, installed on physical device (iPhone Air, `1D51F2FB-1DB2-52BF-818B-EFD2ACE7C0E7`) |
| **Relay process** | Running (PID 80725) on `100.93.152.82:8797`, connected to gateway 9119 |

---

## What's NOT done yet

1. **E2E device verification.** The critical test: open app → send a message → kill the relay process → confirm the queued prompt drains after the relay restarts. This has not been confirmed on the physical device yet.

2. **PRs #220–#229 remain untouched.** These are the convergence/reliability/reconnect-softening/duplicate-delta PRs from the Wave 2.5 work. They may conflict with or complement the fixes here.

3. **iOS-owner review.** Per ABH-513 acceptance criteria, no merge until iOS-owner review and approval.

4. **FIX 4 (downstream pending-drain).** The existing seq/ack/resync mechanism plus FIX 3's session re-open should handle replay on reconnect, but this hasn't been explicitly verified as a separate test case.

5. **Documentation.** `docs/WAVE-ROADMAP.md` and `docs/RELAY-PHONE-PROTOCOL.md` have not been updated to reflect the new durable owned-session persistence or the gateway-readiness gate.

---

## How to run things

### Relay
```bash
cd /Volumes/MainData/Developer/hermes-tmp/worktrees/wave25-relay-device-qa/relay
/Volumes/MainData/Developer/hermes-tmp/venvs/relay/bin/python -m hermes_relay \
  --gateway-host 127.0.0.1 --gateway-port 9119 \
  --listen 100.93.152.82:8797 --health-path /healthz \
  --token-file "/Users/abbhinnav/Library/Application Support/StraitsLab/HermesControl/dashboard.token" \
  --log-level INFO
```

### Relay tests
```bash
cd /Volumes/MainData/Developer/hermes-tmp/worktrees/wave25-relay-device-qa/relay
/Volumes/MainData/Developer/hermes-tmp/venvs/relay/bin/python -m pytest tests/ -q
```

### iOS build + install to device
```bash
cd /Volumes/MainData/Developer/hermes-tmp/worktrees/wave25-relay-device-qa/apps/ios
xcodebuild -project HermesMobile.xcodeproj -scheme HermesMobile \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/hermes-device-build -allowProvisioningUpdates build

xcrun devicectl device install app \
  --device 1D51F2FB-1DB2-52BF-818B-EFD2ACE7C0E7 \
  /tmp/hermes-device-build/Build/Products/Debug-iphoneos/HermesMobile.app
```

### iOS relay tests
```bash
cd /Volumes/MainData/Developer/hermes-tmp/worktrees/wave25-relay-device-qa/apps/ios
xcodebuild test -project HermesMobile.xcodeproj -scheme HermesMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:HermesMobileTests/RelaySessionCoordinatorTests \
  -only-testing:HermesMobileTests/RelayClientTests \
  -only-testing:HermesMobileTests/RelayItemStoreTests
```

### Relay health check
```bash
TOKEN=$(cat "/Users/abbhinnav/Library/Application Support/StraitsLab/HermesControl/dashboard.token")
curl -s -H "Authorization: Bearer $TOKEN" http://100.93.152.82:8797/healthz
```

---

## Architecture notes for the next agent

- **The relay** (`relay/hermes_relay/`) is a standalone Python WebSocket proxy between the iOS app and the stock Hermes gateway. It owns session state, seq/ack/replay, and reframes gateway events into item envelopes.
- **The iOS app** connects to the relay (not the gateway directly) when `transportPath == .relay`. The `RelaySessionCoordinator` manages the relay socket; `ConnectionStore` manages the app-level connection state.
- **The gateway** (port 9119) is the stock Hermes gateway. The relay connects to it as a WebSocket client. The relay does NOT modify gateway core.
- **DurableState** (`relay/hermes_relay/durable_state.py`) is the relay's SQLite-backed persistent store. It now holds: attention state, sync manifests, AND owned sessions.
- **The frozen protocol** is in `docs/RELAY-PHONE-PROTOCOL.md`. The relay-phone protocol is ratified and should not be changed without explicit approval.
- **PR #230 is WIP.** Do not merge. The branch is `codex/wave25-relay-device-qa`.
- **The worktree** is at `/Volumes/MainData/Developer/hermes-tmp/worktrees/wave25-relay-device-qa` — the branch cannot be checked out in the main repo because it's already checked out here.
- **The relay venv** is at `/Volumes/MainData/Developer/hermes-tmp/venvs/relay/bin/python` — system python3.13 is missing `yaml` and other deps.
