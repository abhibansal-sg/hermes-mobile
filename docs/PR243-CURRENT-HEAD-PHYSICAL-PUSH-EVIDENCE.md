# PR #243 current-head physical push evidence

Date: 2026-07-24  
Code head: `518fde7e409f47ca96d7f61a074384b35ac816d1`  
Device: physical iPhone 16 Pro Max,
`07EE6E1F-3258-5E27-8167-C7CF8842E62D`

## Isolation

- gateway: `127.0.0.1:9142`
- byte-transparent co-located relay: `192.168.4.92:9143`
- repository `server/push-relay`: `127.0.0.1:9144`
- isolated `HERMES_HOME`
- Apple sandbox APNs
- local model proxy backed by Qwen 3.8 Max
- no simulator
- no access to live gateway `9119` or live relay `8788`

The hosted push deployment at `https://push.tryfetchapp.com` rejected
`ai.hermes.app` with HTTP 400 `unsupported bundle id`. That is hosted
deployment drift, not a branch-code result. The physical proof therefore used
the repository's current push-relay source locally with the same real Apple
sandbox APNs credentials. No hosted or production service was changed.

## Completion push

The physical test was:

```text
HermesMobileUITests/CrossClientSyncUITests/
testDesktopCompletionPushOpensOwningSession
```

The stock phone driver created and drove:

```json
{
  "timestamp": "2026-07-24T06:11:28.489294+00:00",
  "marker": "PR243-518-COMP-COMPLETE",
  "runtime_session_id": "2184c6b0",
  "stored_session_id": "20260724_141124_882b5a",
  "submit_result": {
    "status": "streaming",
    "accepted": true,
    "deduplicated": false
  },
  "complete_text": "PR243-518-COMP-COMPLETE"
}
```

The push relay recorded one delivery:

```text
type=replies session_id=2184c6b0 device_count=1
created_utc=2026-07-24 06:11:28
```

The device received the real APNs alert, tapped it, opened the owning stored
session, painted the marker, and proved there was no duplicate notification.
Result: `** TEST SUCCEEDED **`.

Artifacts outside the repository:

- `/Volumes/MainData/Developer/hermes-tmp/evidence/pr243-518fde7e4-completion.log`
- `/Volumes/MainData/Developer/hermes-tmp/evidence/pr243-518fde7e4-completion.xcresult`

## Actionable approval push

The physical test was:

```text
HermesMobileUITests/ChatFlowUITests/
testApprovalPushOpensOwningGateAndResumesTurn
```

Qwen invoked the stock terminal tool with a bounded nonexistent `/tmp` target.
The gateway emitted the stock approval request:

```json
{
  "timestamp": "2026-07-24T06:09:11.621568+00:00",
  "runtime_session_id": "cfac686c",
  "stored_session_id": "20260724_140904_a13242",
  "request_id": "398d7ca1103cc0a5c677773d2134fd86",
  "command": "rm -rf /tmp/PR243-518-APP-COMMAND"
}
```

The push relay recorded the attention alert, the device opened the owning
approval gate, and the device's **Approve** action resumed the blocked stock
turn. The same driver then observed:

```json
{
  "timestamp": "2026-07-24T06:09:27.067486+00:00",
  "runtime_session_id": "cfac686c",
  "stored_session_id": "20260724_140904_a13242",
  "approval_seen": true,
  "complete_text": "PR243-518-APP-ANSWERED"
}
```

The broker recorded exactly the expected two events:

```text
attention cfac686c 1 2026-07-24 06:09:11
replies   cfac686c 1 2026-07-24 06:09:27
```

The phone painted `PR243-518-APP-ANSWERED`. Result:
`** TEST SUCCEEDED **`.

Artifacts outside the repository:

- `/Volumes/MainData/Developer/hermes-tmp/evidence/pr243-518fde7e4-approval.log`
- `/Volumes/MainData/Developer/hermes-tmp/evidence/pr243-518fde7e4-approval.xcresult`

## Exact defect found by this gate

The first actionable-approval run proved the alert, owning gate, approval
response, and gateway completion, but the foreground phone did not paint the
final answer. The gateway correctly sent the completion to the driving socket,
and APNs correctly sent a foreground completion notification to the phone.
`NotificationLaunchCoordinator.willPresent` displayed that notification but
did not invalidate the active transcript.

Commit `518fde7e4` corrects that existing edge only:

1. a decodable foreground Hermes push requests reconciliation;
2. the existing handler refreshes the inbox, performs the existing one-shot
   transcript `backfill()`, and refreshes the drawer.

It adds no fan-out protocol, polling loop, coordinator, transcript store,
replay type, identity map, or gateway method.

## Additional physical gates on the same code head

All used `scripts/ios-build.sh` against the physical device:

- `NotificationLaunchCoordinatorTests` + `NotificationActionTests`:
  `** TEST SUCCEEDED **`
- `LiveTurnReentryTests` + `ContextMeterTests`:
  `** TEST SUCCEEDED **`

Artifacts:

- `/Volumes/MainData/Developer/hermes-tmp/evidence/pr243-518fde7e4-notification-coordinator.log`
- `/Volumes/MainData/Developer/hermes-tmp/evidence/pr243-518fde7e4-rebase-ios-gates.log`

## Gate result

The independent review's three merge blockers are closed in branch code:

1. current-head physical completion APNs proof: green;
2. current-head actionable approval APNs proof: green;
3. stale Live Activity mocks and post-rebase physical gates: green.

The hosted broker allow-list drift remains a separate deployment prerequisite
before production notification testing or release.
