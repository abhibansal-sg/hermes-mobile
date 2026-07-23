# ABH-519 post-merge hardware hardening evidence

**Captured:** 2026-07-23 +08:00

**Branch:** `codex/ios-hardware-hardening`

**Base:** `origin/main` at `a7ed26ab9`

**Status:** The focused hardening gate is green on two physical iPhones. No
simulator was booted or used, and no change was made to stock Hermes core.

## Corrected defect

The phone is a read-only watcher of a desktop-driven runtime. Stock
`clarify.respond` and `approval.respond` correctly reject a watcher because
those WebSocket methods belong to the driving transport. The app nevertheless
used those stock methods for inline and Inbox responses, so the visible card
could disappear locally while the blocked turn remained unresolved.

The narrow correction keeps drive/watch ownership unchanged and routes those
responses through retained seam S13. The existing REST client owns both approval
and clarification response calls, including the existing ABH-88 alternate-path
retry. A card clears only after an authoritative `resolved` or
`alreadyHandled` result; transport/auth failures leave it retryable. The plugin
permits a paired phone to act on a live desktop-owned session, permits the owning
phone while its live WS socket is registered, treats a session with no live
device socket as shared among paired devices, and rejects unknown sessions or a
different phone while the owner's socket remains registered. No coordinator,
transcript store, replay type, identity map, gateway method, or relay state was
added.

## Corrected attention proof

These runs supersede the earlier approval/clarification evidence that did not
prove a genuinely desktop-owned runtime.

- Desktop-owned clarification runtime `5ec61e6e`: a separate stock driver
  received `clarify.request`; the phone received one notification, opened the
  owning stored session, rendered the real question and choices, answered
  `Left` through S13, cleared the card only after acknowledgement, rendered the
  exact final response, and the driver then received `message.complete`.
  XCUITest: `/tmp/ios-hardening-clarification-push-qwen-r10-internal.log`;
  driver: `/tmp/ios-hardening-clarification-driver-qwen-r10.log`.
- Desktop-owned approval runtime `83a2a97a`: a separate stock driver received
  `approval.request`; the stock hook emitted a generic redacted notification;
  the phone opened the owning card, verified the unique command inside the app,
  approved through S13, cleared only after acknowledgement, rendered the exact
  final response, and the driver then received `message.complete`. XCUITest:
  `/tmp/ios-hardening-approval-push-desktop-qwen-r4-internal.log`; driver:
  `/tmp/ios-hardening-approval-driver-qwen-r4.log`. This probe used
  `HERMES_TRANSPORT=gatewayDirect` against the isolated gateway; it did not
  traverse the relay.

Assistant-completion probes deliberately query assistant text views and
transformed model answers rather than prompt literals. A few structural probes
use `.any` only for unique exact labels, including the clarification-card header
and `TASK_DOCK_DONE`; those labels are not used as assistant-attribution
oracles.

## Two-device physical gate

- iPhone 16 Pro Max, iOS 26.5, UDID
  `00008140-000648640A33001C`: cross-client live follow passed in 18.601s;
  force-close repaint passed in 23.744s; TaskDock lifecycle passed in 61.271s;
  stock load-earlier during an active turn passed in 69.566s; completion push
  opened the owning transcript in 41.986s. Logs:
  `/tmp/ios-hardening-cross-client-live-qwen-r1.log`,
  `/tmp/ios-hardening-cross-client-cold-qwen-r1.log`,
  `/tmp/ios-hardening-task-dock-qwen-r4.log`,
  `/tmp/ios-hardening-pagination-qwen-r1.log`, and
  `/tmp/ios-hardening-completion-push-qwen-r7.log`.
- iPhone 16 Pro, iOS 26.5.2, UDID
  `00008140-001918EA3EF1801C`: after Xcode registered the device and regenerated
  the UI-test runner profile, the same TaskDock lifecycle passed in 61.339s.
  It observed `Tasks, 1 of 2 done`, expanded to both exact task rows, waited for
  `TASK_DOCK_DONE`, verified the live capsule disappeared, then expanded the
  settled Worked/Todos hierarchy and found the retained task data. Log:
  `/tmp/ios-hardening-task-dock-qwen-iphone16pro-r4-internal.log`; result bundle:
  `/Volumes/MainData/Developer/hermes-tmp/artifacts/ios-hardware-hardening-20260723/derivedData-secondary-passing/Logs/Test/Test-HermesMobile-2026.07.23_13-33-31-+0800.xcresult`.

Both phones were connected and running the isolated build concurrently. Xcode
build/test execution remained serialized through `scripts/ios-build.sh` because
the machine's `SWBBuildService` is a singleton.

## Focused automated gate

- S13 approval, clarification, ownership, and pending-attention slice:
  **30 passed**. Log: `/tmp/ios-hardening-s13-attention-pytest-r4.log`.
- Physical arm64 Swift slice covering path-family retry, ACK-only clearing,
  failure retention, cross-session echo prevention, and draft gate parking:
  **17 passed, 0 failed**. Log:
  `/tmp/ios-hardening-s13-swift-focused-r3-internal.log`.
- Hosted iOS on final head `6529117f5`:
  **1,894 executed, 6 skipped, 0 failures**. GitHub Actions run
  `29986583458`.
- `git diff --check`: pass.

The clarification, completion-push, and cross-client probes exercised the relay
path; the approval probe was gateway-direct as noted above. Every cited log has
zero references to the live gateway/relay ports 9119 and 8788, which attests
that those live services were not targeted. The specific isolated ports 9140
and 9141 and the Qwen 3.8 Max probe model are operator assertions: the surviving
artifacts do not record those values and therefore do not independently attest
them.

## Evidence process for future physical rounds

Persist the driver script in the repository, or retain and cite its durable
path. Each driver log line must include an ISO timestamp, runtime ID, stored
session ID, and marker; the paired XCUITest must print the same marker so the
phone and driver logs can be cross-correlated. The current phone-side proof is
strong, but its three-line, untimestamped driver stubs do not meet that future
attestation standard.
