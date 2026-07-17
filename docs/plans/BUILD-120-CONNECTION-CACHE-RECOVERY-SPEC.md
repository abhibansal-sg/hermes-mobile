# Hermes Mobile Build 120 — Connection and Cache Recovery Integrity

**Status:** Implementation and verification in progress
**Target:** TestFlight build 120
**Tracking:** Linear ABH-504 (related: ABH-503), draft PR #206
**Reviewed by:** GPT-5.6 Luna architecture pass, two GPT-5.6 Terra execution passes

## Context

Build 119 fixed the background/foreground crash, but physical-device testing exposed a split-brain recovery state. After returning from the background, the current chat can appear connected and may even accept a prompt, while opening any other session fails with “Not connected to the Hermes Gateway.” Settings can also look connected because REST configuration is available even when the phone's WebSocket is not ready.

The second user-visible failure is loss of local continuity. During reconnect or after force quit, the drawer or last transcript can be absent even though cache-first restoration exists. Build 120 must make connection truth operationally correct and make cached state reliably visible without waiting for the gateway.

## User outcome

After backgrounding, force quitting, losing network, or restarting the gateway:

1. The cached drawer and last transcript paint without network.
2. A session tap always changes the local selection immediately.
3. Transport-dependent work waits for a ready WebSocket instead of failing with a transient “Not connected” popup.
4. Reconnection resumes the latest selected session, not a stale runtime.
5. Prompts remain in the durable outbox until the transport is ready and are delivered once.
6. The UI distinguishes gateway configuration/REST reachability from the phone's live session transport.

## Verified current state

| Surface | What exists | Gap |
|---|---|---|
| Silent reconnect | `ConnectionStore` holds `phase == .connected` for a 10-second grace window | Consumers incorrectly treat the presentation phase as WebSocket readiness |
| JSON-RPC client | `HermesGatewayClient` owns an actor-isolated connection state and waits for `gateway.ready` during connect | `requestRaw` admits work from task existence rather than authoritative `.open` state |
| Session opening | Cache-first transcript paint and `openToken` supersession already exist | `open()` starts `session.resume` without waiting for transport readiness and surfaces transient disconnect errors |
| Reconnect recovery | The active stored session is resumed after reconnect | A different session selected during reconnect has no retained open intent |
| Outbox | `WorkRepository` and `OutboxProcessor` provide durable prompt delivery and crash recovery | `canProcessPrompt` checks UI phase, so it can drain during silent grace |
| Cached drawer | `paintFromCache()` runs before network probing and can restore the last-opened session | It calls `open()`, causing a WebSocket action during cache restoration; its latch can also be consumed before scope exists |
| Cached transcript | A cached transcript is painted before REST reconciliation | Stale tasks can cross profile/server boundaries; some failure paths reset already-painted content |
| Cache cleanup | Gateway and session purge APIs exist | Last-opened, legacy session, and transcript rows have deletion omissions |
| Diagnostics | DEBUG phase labels and focused tests exist | No bounded redacted reliability trace links lifecycle, readiness, selection, cache paint, and outbox events |

## Root cause

`ConnectionStore.phase` currently has two incompatible meanings:

- presentation policy: keep cached chat usable and suppress a reconnect banner during a brief outage;
- operational capability: allow WebSocket JSON-RPC work.

During grace, the first meaning is intentional and the second is false. `SessionStore.open()` and `AppEnvironment` use the presentation meaning as if it proved capability. The current session can later self-heal through reconnect and `ensureActiveRuntime()`, while another session's one-shot `session.resume` fails immediately. This produces the exact physical-device asymmetry.

Cache restoration compounds the issue by calling `open()` before bootstrap creates a ready transport. Separately, cache scope, cancellation, and cleanup races can select the wrong profile, persist stale last-opened state, write a completed fetch into a newer scope, or resurrect deleted rows.

## Locked invariants

1. `phase == .connected` never implies that WebSocket RPC is permitted.
2. WebSocket RPC is permitted only when the current client generation has reached `GatewayConnectionState.open` and silent grace is not holding a dropped transport.
3. `activeStoredId` is durable user selection. `activeRuntimeId` is ephemeral and valid only for the transport epoch that created it.
4. Cache painting never starts `session.resume`.
5. A session tap during reconnect is retained as the latest open intent and resumes after readiness.
6. Superseded session, server, profile, and transport work cannot publish or persist into the current scope.
7. Outbox jobs remain durable and unclaimed while transport is not ready.
8. A transient refresh, cancellation, reconnect, or unavailable gateway never clears a valid cached drawer or transcript.
9. Explicit Forget Gateway purges local gateway state. Authentication repair without an explicit forget keeps local history readable but disables remote mutations.
10. Prompt/model context is untouched. No system prompt, historical message, toolset, or prompt prefix changes are allowed.

## Proposed change

### 1. Add one operational transport-readiness contract

`ConnectionStore` remains the sole reconnect policy owner. Add a current-generation readiness state and waiter:

```swift
enum TransportReadiness: Equatable {
    case unconfigured
    case connecting(epoch: UInt64)
    case ready(epoch: UInt64)
    case unavailable(epoch: UInt64)
    case reauthRequired
}

var isTransportReady: Bool { get }
func waitForTransportReady(timeout: Duration) async -> Bool
```

Rules:

- Set `connecting` before an attempt.
- Set `ready` only after `HermesGatewayClient.connect()` completes its `gateway.ready` handshake.
- Set `unavailable` when the current transport closes or fails, including during presentation grace.
- Increment the transport epoch for every accepted new connection generation.
- Resolve all waiters on readiness, terminal authentication/setup failure, cancellation, or timeout.
- Keep `phase` and the existing grace behavior as presentation policy.
- Use the existing reconnect loop. Do not add a second retry controller.

`HermesGatewayClient.requestRaw()` must also require actor state `.open`; task existence is not sufficient.

### 2. Make cached selection presentation-only

Split `SessionStore.open()` into two conceptual stages without creating a new store:

1. **Select and paint:** synchronously update `activeStoredId`, clear the old runtime, persist the guarded last-opened identity, and paint cached transcript.
2. **Bind runtime:** retain the latest selected stored-session intent, wait for transport readiness, then issue `session.resume` with existing profile and `openToken` guards.

`paintFromCache()` restores the last selected session and transcript through the first stage only. It must not perform an RPC. Bootstrap/reconnect invokes the runtime-binding stage after readiness.

Transient transport errors while binding do not set `sessionActionError`. Authentication, authorization, not-found, or schema errors remain actionable and visible.

### 3. Fence runtime and outbox work

- Bind `activeRuntimeId` to the current transport epoch.
- Clear or invalidate the binding immediately when the transport becomes unavailable.
- Reject late resume/status/event results from an older transport epoch.
- Change `AppEnvironment`'s `canProcessPrompt` to require `isTransportReady` plus the existing streaming/local-turn checks.
- Direct prompt submission and outbox runtime resolution use the same readiness contract.
- A prompt submitted during grace is persisted first and waits. It is not optimistically attempted against a dead task.

### 4. Close cache restoration and scope races

1. Do not set `didColdReadCache` until a valid cache scope exists and a read attempt actually begins. Make the latch scope-aware.
2. Require exact normalized profile equality when restoring `last_opened_session`, including All Profiles mode.
3. Guard last-opened persistence with the originating `openToken` so a late A write cannot overwrite a later B selection.
4. Rotate `openToken` on server binding invalidation and profile changes.
5. Capture `CacheIdentity` before network awaits and use that captured identity for persistence.
6. Make transcript prefetch profile-aware end to end.
7. Check task cancellation after every manifest page fetch, before staging, and immediately before commit.
8. Preserve an already-painted cached transcript if network reconciliation fails.

### 5. Fix cleanup omissions

- `purgeGateway` deletes `last_opened_session` for the gateway scope.
- `removeSession` deletes the scoped `session_cache` row so foreign-key cascades remove legacy message rows.
- Forget Gateway continues to purge local privacy surfaces.
- Reauthentication without explicit forget shows cached history behind a repair blocker and disables remote mutations.

### 6. Add bounded reliability diagnostics

Add a privacy-safe in-memory ring of the last 100 events. Record IDs and counts only, never tokens, URLs, prompts, titles, or message bodies.

Required event families:

- WebSocket connect/ready/close and reconnect attempt/heal
- grace start/expiry
- transport epoch rejection
- session selection/bind/supersession
- cache paint start/finish/failure with row counts and duration
- outbox wait/claim/submit/ambiguous receipt
- background flush and foreground liveness result

Expose the ring through the existing DEBUG bridge and redacted diagnostics export.

## Parallel work plan

```text
Lane A: Transport truth (Luna owner)
  A1 readiness/epoch contract
  A2 strict JSON-RPC admission
  A3 reconnect + foreground grace
           |
           +------> Integration gate
           |
Lane B: Session/outbox (Terra owner)
  B1 select-vs-bind split
  B2 pending latest-open intent
  B3 runtime epoch + outbox readiness

Lane C: Cache integrity (Terra owner)
  C1 cache latch/profile/last-opened races
  C2 prefetch + manifest cancellation
  C3 purge/delete omissions

Lane D: Verification (root integration owner)
  D1 deterministic unit/integration tests
  D2 redacted reliability trace
  D3 Xcode Cloud build/test
  D4 TestFlight physical-device matrix
```

Lane A publishes the readiness API first. Lanes B and C may prepare tests and independent cache fixes in parallel, but B cannot merge readiness consumers until A is integrated. Root owns shared-file conflict resolution, project generation, versioning, PR/Linear updates, and release evidence.

## Acceptance criteria

1. With cached sessions A and B and A selected, background long enough to lose the socket, foreground, and immediately tap B. B paints from cache and no transient “Not connected” popup appears.
2. If reconnection succeeds within 10 seconds, no reconnect banner or transcript warning appears. B, as the latest selection, is the session resumed.
3. If reconnection exceeds grace, exactly one visible reconnect treatment appears; cached content remains interactive.
4. After recovery, opening A, B, and C in sequence succeeds without force quit or manual retry.
5. `activeRuntimeId` from a prior transport epoch cannot submit, receive, or bind into the current selection.
6. A prompt submitted during grace is present in `WorkRepository` before any WebSocket call, remains queued while not ready, and is delivered once after readiness.
7. Force quit with the gateway unreachable restores the cached drawer and last transcript before any network completion.
8. Failed list, transcript, manifest, or prefetch work leaves the previous cached publication intact.
9. Duplicate stored session IDs across profiles restore the exact saved profile.
10. Rapid A→B selection persists B as last opened even when A's persistence task completes late.
11. Server/profile switch during an in-flight fetch cannot publish or persist the old response into the new scope.
12. Cancelling manifest synchronization before commit leaves the prior revision and resume cursor unchanged.
13. Deleting a session prevents it and its legacy transcript from reappearing on offline cold launch.
14. Forget Gateway removes last-opened and scoped cache rows. Authentication repair without forget preserves readable cache but blocks remote actions.
15. No new raw tool/reasoning/terminal persistence is introduced and prompt-cache inputs remain byte-stable.

## Testing plan

| Layer | Required tests |
|---|---|
| Unit | Transport readiness transitions; strict `.open` request admission; grace blocks outbox; runtime epoch fencing; cancellation checks; cache latch retry; profile-exact restore; guarded last-opened write; purge/delete completeness |
| Integration | Session A→B switch during reconnect; late A resume/frame cannot affect B; offline cold paint with real temporary GRDB; gateway-backed `client_message_id` retry produces one server turn |
| UI/Xcode Cloud | Cached shell before network; no quick-heal banner; delayed reconnect treatment; repeated session switching; live gateway tests must fail rather than skip when credentials are intended |
| Physical TestFlight | Airplane-mode force quit; within/outside grace; background 2–5 minutes; force quit during outbox submission; gateway restart; 10 background/foreground cycles; diagnostics export on failure |

The current local CoreSimulator device set cannot create a device. Xcode Cloud and physical TestFlight are the release authorities until that host issue is repaired. Simulator-independent `WorkRepositoryMacTests` remain mandatory.

## Files reference

| File | Change |
|---|---|
| `apps/ios/HermesMobile/Stores/ConnectionStore.swift` | Readiness/epoch contract, waiter, grace integration, diagnostics |
| `apps/ios/HermesMobile/Networking/HermesGatewayClient.swift` | Strict request admission and ready-timeout test seam |
| `apps/ios/HermesMobile/Stores/SessionStore.swift` | Selection/binding split, pending open, epoch fencing, cache-scope fixes |
| `apps/ios/HermesMobile/Stores/ChatStore.swift` | Readiness-aware direct send without changing outbox ownership |
| `apps/ios/HermesMobile/App/AppEnvironment.swift` | Outbox readiness predicate and cache initialization diagnostics |
| `apps/ios/HermesMobile/Cache/CacheStore.swift` | Correct gateway/session cleanup and guarded restoration support |
| `apps/ios/HermesMobile/Stores/SyncCoordinator.swift` | Cancellation-before-stage/commit |
| `apps/ios/HermesMobile/Views/Panels/GatewayStatusView.swift` | Distinguish gateway REST/process status from phone WebSocket state |
| `apps/ios/HermesMobileTests/ConnectionStoreReconnectTests.swift` | Readiness, grace, open-intent, epoch tests |
| `apps/ios/HermesMobileTests/WSLivenessTests.swift` | Foreground dead-socket grace |
| `apps/ios/HermesMobileTests/CacheFirstLaunchTests.swift` | Offline process reconstruction and profile-exact restore |
| `apps/ios/HermesMobileTests/OutboxProcessorTests.swift` | No claim/drain before transport readiness |
| `apps/ios/HermesMobileTests/CacheStoreManifestAtomicTests.swift` | Cancellation preserves prior revision |

## Rollback plan

- The projection/cache schema does not require a destructive migration.
- Revert readiness consumers and return to the previous reconnect paths if release testing fails.
- Keep new diagnostic events inert if disabled.
- Do not delete legacy cache rows as part of Build 120 rollout beyond user-requested gateway/session deletion.
- Do not merge or ship until Xcode Cloud tests and the physical-device acceptance matrix pass.

## Out of scope

- New notification categories, quiet hours, or push payload redesign
- New background task types or background audio
- Full compact-turn presentation rollout
- Deep-detail persistence or UI redesign
- Stable-asset protocol expansion
- Conditional mutation expansion beyond existing prompt delivery
- Localization and broad accessibility redesign
- Upstream Hermes transport seam work

## Definition of done

Build 120 is done when cached state is always available without network, the UI never confuses presentation grace with transport readiness, session switching self-heals after background/foreground without manual retry, queued prompts remain durable and deliver once, the focused test suite is green, Xcode Cloud produces the build, and the physical-device matrix passes with attached diagnostics.
