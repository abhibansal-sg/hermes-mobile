# Relay stock-event notifications — verification

Date: 2026-07-23  
Branch: `codex/relay-stock-event-notifications`  
Base: `5ad42fbe577fd4bd0618e4d84c086b249d1e310d`

## Result

The relay remains a byte-transparent stock WS/HTTP proxy. A separate observer
receives the same stock event frames as Desktop, renews a short gateway-adapter
lease, and passes notification-worthy frames to the existing APNs engine.

There is no relay transcript/session persistence, replay protocol, item
translation, custom gateway RPC, or Hermes core patch. If the relay stops
renewing its 15-second lease, the gateway adapter automatically resumes APNs
ownership.

The device run also found and corrected one existing transport defect:
`ConnectionStore.stockProxyURL` downgraded a normal `https://` relay override to
`http://`. The correction preserves both `https` and `wss` as secure HTTP.

## Automated gates

- Relay suite under Python 3.13: `31 passed`.
- Focused adapter/auth/APNs suite: `27 passed`.
- Physical-device secure-relay regression:
  `ConnectionPhaseTests.testSecureRelayOverrideStaysSecure` passed.
- `compileall` and `git diff --check` passed.
- The plugin's broader suite still has the same five unrelated failures
  reproduced on unmodified main (four stale Live Activity expectations and one
  provider-auth config-pollution test); this branch does not change those paths.

## Isolated real-gateway proof

- Gateway: stock fork on `127.0.0.1:9138`.
- Relay: `127.0.0.1:8798`, temporarily exposed inside the tailnet over HTTPS on
  port 9446.
- `HERMES_GATEWAY_BROADCAST` was absent.
- Relay health after multiple lease renewals:
  `notifications.connected=true`, `notifications.claimed=true`.
- The stock Python phone driver completed `gateway.ready`,
  `session.active_list`, `session.create`, and stock event receipt through the
  relay with no legacy frame.
- Qwen 3.8 Max was used for all physical-device turns through the isolated local
  model proxy.

## Physical iPhone proof

Device: iPhone Air, iOS 26.5.2, physical hardware (no simulator).

1. Background completion:
   - external stock client created and completed stored session
     `20260723_225803_a563b8`;
   - relay observed the stock event;
   - both sandbox APNs requests returned HTTP 200;
   - the notification appeared;
   - tapping it opened the owning session;
   - the Qwen completion appeared in the transcript;
   - no duplicate notification remained.
2. Foreground live follow:
   - the phone opened stored session `20260723_225924_363636`;
   - an external stock client resumed and submitted a second turn;
   - the second Qwen completion streamed into the watching phone;
   - only the other registered device remained APNs-eligible.
3. Durable repaint:
   - force-close/reopen repainted the same second turn;
   - the pulled device GRDB cache contains the same stored session with
     `messageCount=4`, four message rows, and a non-null transcript cache stamp.

The current Debug app was also installed on the attached iPhone 16 Pro. Its
independent UI run requires that passcode-locked device to be unlocked.

## Evidence locations

- Device build log:
  `/Volumes/MainData/Developer/hermes-tmp/evidence/relay-stock-event-notifications/ios-device-build.log`
- First failing clear-text run and its device log archive:
  `/Volumes/MainData/Developer/hermes-tmp/evidence/relay-stock-event-notifications/air-push-extracted.logarchive`
- HTTPS device log archive:
  `/Volumes/MainData/Developer/hermes-tmp/evidence/relay-stock-event-notifications/air-push-tls.logarchive`
- Final pulled device cache:
  `/Volumes/MainData/Developer/hermes-tmp/evidence/relay-stock-event-notifications/air-cache-final`
- Successful Xcode result bundles are under:
  `apps/ios/.derivedData/Logs/Test/`
