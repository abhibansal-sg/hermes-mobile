# Hermes Mobile native-stock architecture handoff

**Prepared:** 2026-07-24  
**Review branch:** `codex/native-stock-architecture`  
**Draft PR:** [#243 — refactor(mobile): adopt stock notification and session architecture](https://github.com/abhibansal-sg/hermes-mobile/pull/243)  
**Product implementation head:** `a651d3a49acd6cb3306bf0e3efcf37ac09bbf37d`  
**Finalize-oracle correction:** `174aed949`  
**PR merge base:** `82c2545662905b80bf86e6d85c15358918eb5f80`  
**Current `origin/main` when this was written:** `f890a1d12dec7763ea61c55861d441c60240d9a7`

This is the reviewer handoff for the complete Hermes Mobile simplification
exercise. In this document, “custom scene” is interpreted as **custom seam**:
a deliberate, generic addition inside stock Hermes core that the external
Hermes Mobile plugin cannot implement by itself.

## Executive result

The mobile chat architecture now has one conversation protocol:

1. iOS creates, resumes, watches, submits, interrupts, and receives live events
   through the stock Hermes JSON-RPC protocol.
2. When configured, the co-located chat relay authenticates and forwards stock
   WebSocket/HTTP traffic without parsing or translating it. Without the
   optional proxy address, iOS uses the paired gateway address with the same
   stock protocol.
3. The stock gateway remains the authoritative owner of conversations,
   transcripts, live runtimes, and events.
4. iOS keeps only a durable send outbox and a reconstructible local cache.
5. Mobile-only edge behavior lives in `plugins/hermes-mobile`.
6. Five generic core seams remain: S4, S5, S6, S11, and S13.

The current PR deletes the second frame-delivery/replay/status architecture:
**565 additions and 4,494 deletions** relative to its merge base. Its second
commit alone is **117 additions and 4,085 deletions**.

This PR is not merged or released by this handoff. It did not modify the live
gateway, live relay, production configuration, TestFlight, or `main`.

## The whole system at a glance

There are two different services historically called “relay.” They must not be
treated as one component:

```mermaid
flowchart LR
    UI["Native iPhone UI"]
    OUTBOX["WorkRepository<br/>durable send outbox"]
    CLIENT["HermesGatewayClient<br/>stock JSON-RPC"]
    CHATRELAY["Optional co-located chat proxy<br/>relay/hermes_relay<br/>stateless"]
    GATEWAY["Stock Hermes gateway<br/>/api/ws + /api/*"]
    COREDB["Hermes SessionDB<br/>authoritative transcript"]
    PLUGIN["Hermes Mobile plugin<br/>edge adapter"]
    PUSHRELAY["Hosted APNs broker<br/>server/push-relay<br/>stateful delivery metadata"]
    APNS["Apple APNs"]
    CACHE["iOS CacheStore<br/>reconstructible GRDB projection"]

    UI --> OUTBOX
    OUTBOX --> CLIENT
    CLIENT --> CHATRELAY
    CLIENT -. "same protocol when proxy unset" .-> GATEWAY
    CHATRELAY --> GATEWAY
    GATEWAY --> COREDB
    GATEWAY -- "stock events" --> CHATRELAY
    CHATRELAY -- "unchanged stock frames" --> CLIENT
    CLIENT --> CACHE
    CACHE --> UI

    GATEWAY -- "stock lifecycle hooks" --> PLUGIN
    PLUGIN -- "mobile push event" --> PUSHRELAY
    PUSHRELAY --> APNS
    APNS --> UI
```

### Component ownership

| Component | Owns | Explicitly does not own |
|---|---|---|
| Stock Hermes gateway | Durable sessions, transcript, live runtime, drive ownership, stock RPC/event semantics | APNs registration, iOS cache, mobile credentials |
| `plugins/hermes-mobile` | Pairing, device tokens, mobile REST routes, prompt receipts, pending-attention projection, approval audit, push/Live Activity adaptation | Chat transcript, a second gateway protocol, frame replay |
| `relay/hermes_relay` | Optional local phone authentication, upstream credential substitution, byte-transparent WS/HTTP proxying | Sessions, transcripts, event translation, replay, SQLite |
| `server/push-relay` | Agent/device enrollment, APNs tokens/preferences, push delivery metadata, APNs delivery | Hermes conversations or transcripts |
| iOS `WorkRepository` | Durable user intent and retry state | Render truth |
| iOS `CacheStore` | Fast local paint, offline search, project/session projections | Authoritative server truth |
| iOS stores/UI | Selection, drive/watch policy, rendering stock events, local interaction state | Server session persistence |

## What “the adapter” means now

The adapter is the external plugin in
[`plugins/hermes-mobile/`](../plugins/hermes-mobile/). It is loaded by the
stock plugin manager and uses the stock dashboard router and CLI command
registration surfaces.

It contains five categories of behavior.

### 1. Stock lifecycle hooks to mobile push

[`push_engine.py`](../plugins/hermes-mobile/push_engine.py) registers:

| Stock hook | Mobile edge interpretation |
|---|---|
| `pre_llm_call` | Turn started; begin/update Live Activity |
| `post_llm_call` | Final reply ready; completion push and transcript invalidation |
| `on_session_end` | Interrupted-turn cleanup |
| `pre_tool_call` | Tool activity, or clarification request |
| `post_tool_call` | Tool completion, or clarification resolved |
| `api_request_error` | Non-retryable provider error |
| `pre_approval_request` | Redacted actionable approval push |
| `post_approval_response` | Approval resolved and activity returns to thinking |
| `on_session_finalize` | Durable-ID Live Activity cleanup fallback |

The adapter keeps a bounded in-process turn-start map so it can calculate
activity timing and suppress unrelated callbacks. These event names are
internal to the push adapter; they are not a second chat wire protocol.

The final completion hook is `post_llm_call`, emitted by the stock turn
finalizer. `on_session_finalize` is not used as a turn-complete event.

### 2. Mobile REST edge

[`dashboard/api.py`](../plugins/hermes-mobile/dashboard/api.py) is mounted at
`/api/plugins/hermes-mobile/` and exposes:

- attachment upload/fetch;
- pending attention and approval/clarification response;
- debug sharing;
- device issue/list/revoke/foreground;
- approval audit;
- sandboxed file list/read/diff;
- hosted-relay pairing;
- APNs and Live Activity token registration;
- session search and paginated transcript reads;
- artifact gallery;
- toolset/provider configuration;
- memory approval/configuration.

This is a wide mobile product edge, but it is outside Hermes core. A reviewer
should distinguish “outside core” from “strictly required by ABH-519”: not
every route is part of chat/session correctness.

### 3. Pairing and device identity

[`mobile_pair.py`](../plugins/hermes-mobile/mobile_pair.py) registers the
stock CLI command:

```text
hermes mobile-pair
```

The direct pairing path is:

```mermaid
sequenceDiagram
    participant Operator
    participant Plugin as Hermes Mobile plugin
    participant Phone as iPhone app
    participant Endpoint as Paired endpoint
    participant Gateway as Stock gateway

    Operator->>Plugin: hermes mobile-pair
    Plugin->>Plugin: issue revocable per-device token
    Plugin-->>Operator: hermesapp://pair deep link + QR
    Operator->>Phone: open link or scan QR
    Phone->>Endpoint: connect with device token
    alt Endpoint is the configured proxy
        Endpoint->>Plugin: timing-safe token match
        Endpoint->>Gateway: forward with gateway credential
    else Endpoint is the gateway
        Endpoint->>Gateway: S5 authenticates the device token
    end
    Gateway-->>Phone: stock gateway.ready and JSON-RPC
```

[`device_tokens.py`](../plugins/hermes-mobile/device_tokens.py) persists only
hashed per-device credentials in `<HERMES_HOME>/device_tokens.json`. It also
keeps bounded process-local maps for open device sockets, foreground session
selection, and runtime-to-device correlation. Revocation closes indexed
device sockets; shared-token sockets are not indexed as devices.

There is also a hosted-relay pairing route at
`/api/plugins/hermes-mobile/relay/pair`. That produces a different
`kind=relay` link for the hosted broker/tunnel capability. It must not be
confused with direct gateway/device-token pairing. The iOS parser recognizes
this payload, but `HermesURLRouter.applyPair` currently returns without applying
it, so it is not a working connection path today.

### 4. Durable sends and pending interactions

[`prompt_receipts.py`](../plugins/hermes-mobile/prompt_receipts.py) owns the
profile-scoped SQLite receipt provider used by S11. It reserves a
`client_message_id` before prompt mutation and records the accepted
disposition so an ambiguous retry is deduplicated.

[`pending_attention.py`](../plugins/hermes-mobile/pending_attention.py) reads
the safe owner snapshots exposed by S13 and builds an authorization-partitioned
full snapshot or bounded delta with signed cursors and tombstones. It does not
own the approval or clarification waiters.

[`audit_log.py`](../plugins/hermes-mobile/audit_log.py) records the identity of
the REST/WS device that actually resolved an approval. Stock pre/post approval
hooks run in the waiting thread and cannot supply resolver identity, so this
uses the generic S5 resolve-observer context.

### 5. Other plugin-local policy/helpers

- [`manifest_invalidation.py`](../plugins/hermes-mobile/manifest_invalidation.py)
  keeps a coalesced revision journal and emits silent refresh pushes.
- [`transcript_sync.py`](../plugins/hermes-mobile/transcript_sync.py) shapes
  bounded REST transcript pages; it is not a transcript store.
- [`ios_turn_context.py`](../plugins/hermes-mobile/ios_turn_context.py) injects
  concise mobile-output guidance only for authenticated mobile turns.
- [`kanban_spec_guard.py`](../plugins/hermes-mobile/kanban_spec_guard.py) blocks
  under-specified agent-created kanban cards.
- [`gitbranch.py`](../plugins/hermes-mobile/gitbranch.py) is a small branch
  lookup helper.

The last two policy modules are not necessary for transport, caching, or push.
Their continued placement in the Hermes Mobile adapter is a legitimate
independent review question. The mobile-output hook also deserves a prompt
cache/instruction-stability review even though it uses a stock hook.

## What remains custom inside Hermes core

The adapter is not completely zero-seam. The current
[`CONTRACT-DEPATCH.md`](../CONTRACT-DEPATCH.md) retains exactly five generic
host seams.

| Seam | Core files | What core exposes | What stays in the plugin | Why stock v0.19 is insufficient |
|---|---|---|---|---|
| S4 | `tui_gateway/server.py` | Session-scoped `fast` override carried through create/config/agent build | No mobile state | Stock has session model/reasoning overrides, but not the complete hot fast-tier override path |
| S5 | `hermes_cli/dashboard_auth/token_auth.py` plus guarded dashboard/WS/resolver call sites | Generic token authenticators, identity validators, socket observers, resolver identity context | Device registry, hash policy, liveness, revoke races, socket index, audit record | Stock auth providers do not cover WS tickets, live revocation, device metadata, socket lifecycle, and resolver identity end-to-end |
| S6 | `tui_gateway/server.py` | `session.delete` safely interrupts/tears down a matching live runtime and reports `evicted` | Nothing mobile-specific | Stock returns 4023 rather than deleting a live session |
| S11 | `tui_gateway/server.py` | Structural prompt-receipt provider registry and pre-mutation call | SQLite schema, scoping, retention, liveness and disposition | Stock `prompt.submit` has no durable idempotency receipt |
| S13 | `tools/approval.py`, `tui_gateway/server.py` | Lock-safe redacted pending approval/clarification snapshots, clarification resolver, resolve observers | Auth visibility, signed cursors, bounded delta/tombstones, REST route | The waiter maps and locks are private to core and cannot be safely reconstructed by a plugin |

These seams are intentionally provider-neutral and are candidates for
upstreaming independently. They must not import Hermes Mobile, APNs, GRDB, or
mobile paths.

### Behavior on pristine public v0.19

The plugin **registers without crashing** on pristine public v0.19 because
optional registries are feature-detected. That is loading compatibility, not
full feature parity:

- no S11 means `client_message_id` has no durable gateway receipt;
- no S5 means the complete device-token WS/ticket/revocation lifecycle is
  unavailable;
- no S13 means watched-session attention reconciliation/response is
  unavailable;
- no S6 means live delete retains stock 4023 behavior;
- no S4 means the full per-session fast override behavior is unavailable.

Do not summarize the current result as “the plugin needs no Hermes changes.”
The accurate statement is: **chat and notification semantics use stock
protocols/hooks; five narrow generic host seams remain.**

## What was deleted

The current PR removes:

- plugin gateway-frame observer intake;
- plugin broadcast/fan-out engine;
- plugin replay ring;
- the external watcher script;
- gateway observer executor and frame observer hooks;
- iOS structured `session.status` model and fallback call;
- old status fixtures and observer/replay/broadcast tests;
- stale monolithic `scripts/seams.patch`.

The seam ledger now records:

- S1 foreign-frame fan-out — removed;
- S2 frame observation/transformation — removed;
- S3 custom finalize metadata — superseded;
- S7 custom WebSocket transport — superseded by stock;
- S8 source filtering — upstream;
- S9 desktop foreign-frame adoption — obsolete;
- S10 old REST live-delete/embedded guards — obsolete or folded into S6;
- S12 structured machine `session.status` — removed.

No second chat protocol, transcript, replay ring, semantic relay session, or
custom status vocabulary should survive this PR.

## End-to-end chat flow

### New chat and first send

```mermaid
sequenceDiagram
    participant UI as iPhone UI
    participant Work as WorkRepository
    participant Client as HermesGatewayClient
    participant Proxy as Transparent chat proxy
    participant Gateway as Stock gateway
    participant Cache as CacheStore

    UI->>Work: enqueue prompt with client_message_id
    Work->>Client: session.create
    Client->>Proxy: stock JSON-RPC frame
    Proxy->>Gateway: same frame, gateway credential
    Gateway-->>Client: stored ID + runtime ID
    Work->>Client: prompt.submit(session_id, client_message_id)
    Client->>Proxy: stock JSON-RPC frame
    Proxy->>Gateway: same frame
    Gateway-->>Client: stock live events
    Client->>Cache: persist authoritative complete rows under stored ID
    Cache-->>UI: render/repaint
    Gateway-->>Work: accepted receipt disposition through S11
    Work->>Work: mark job accepted/completed
```

The durable stored ID is the cache/UI identity. The runtime ID is the live
command target. They are not interchangeable.

### Open, drive, and watch

Before resuming an existing session, iOS calls stock
`session.active_list`:

- if another client is actively driving the session, the phone enters
  **watch** mode and does not call `session.resume`;
- otherwise the phone may **drive** by calling `session.resume`;
- a deliberate submit from a watched session is the ownership transition.

This avoids stock resume’s ownership-rebind behavior stealing a desktop/CLI
runtime. The resume response supplies the stock `running`, status, and bounded
inflight snapshot. `session.usage` seeds the context meter. There is no custom
`session.status` RPC.

### Switching and force-close

1. Selection changes to a stored session ID.
2. `CacheStore` paints that exact `(server, profile, stored session)` scope.
3. Network reconciliation uses stock resume/history semantics appropriate to
   drive/watch.
4. Authoritative complete events rewrite the same scoped cache rows.
5. After process death, the same stored ID repaints from GRDB before network
   reconciliation.

The gateway transcript remains authoritative. The cache is deliberately
reconstructible and cache failure remains non-fatal.

## Notification and attention flow

```mermaid
sequenceDiagram
    participant Gateway as Stock gateway
    participant Hook as Stock lifecycle hook
    participant Adapter as push_engine
    participant Broker as Hosted push relay
    participant APNs
    participant Phone as iPhone
    participant REST as Plugin REST attention route

    Gateway->>Hook: turn/tool/approval/error lifecycle
    Hook->>Adapter: stock hook kwargs
    Adapter->>Adapter: redact, map, foreground-suppress
    Adapter->>Broker: authenticated /v1/push/events
    Broker->>APNs: APNs payload
    APNs-->>Phone: notification
    Phone->>Phone: open owning stored session
    Phone->>REST: fetch pending attention if needed
    REST-->>Phone: safe approval/clarification record
    Phone->>REST: respond
    REST->>Gateway: resolve owner waiter through S13/S5
    Gateway-->>Phone: continuation arrives as stock events/history
```

The hosted push relay stores delivery metadata, not conversation data. It may
forward title/body copy depending on its privacy configuration.

## Every durable store and what it means

### Stock gateway

The Hermes `SessionDB` and session transcript files are authoritative. The
live `tui_gateway.server._sessions` map is process-local runtime state, not a
second durable transcript.

### iOS cache database

[`CacheSchema.swift`](../apps/ios/HermesMobile/Cache/CacheSchema.swift) contains:

| Table | Purpose |
|---|---|
| `session_cache` | Scoped drawer/session summaries |
| `message_row_cache` | Scoped rendered transcript rows |
| `sync_meta` | Cache schema/bookkeeping |
| `offline_message_cache` | Scope-safe offline transcript mirror |
| `transcript_fts` | Offline full-text search |
| `offline_search_backfill` | Search backfill progress |
| `manifest_scope_state` | Server manifest/cursor metadata |
| `pending_attention_cache` | Killed-app approval/clarification projection |
| `attention_reconciliation_meta` | Attention cursor/instance metadata |
| `active_turn_cache` | Reconstructible active-turn projection |
| `transcript_head_cache` | Reconstructible transcript-head projection |
| `last_opened_session` | Last stored session by server/manifest scope |
| `project_cache` | Cache-first project list |
| `project_session_cache` | Cache-first sessions within a project |
| `attachment_blob` | Local attachment blob cache |

The migrated schema repairs the Apple SQLite foreign-key rename behavior that
caused populated device databases to fail while fresh simulator databases
passed.

### iOS work database

[`WorkSchema.swift`](../apps/ios/HermesMobile/Work/WorkSchema.swift) contains:

| Table | Purpose |
|---|---|
| `drafts` | Durable composer state by server/profile/context |
| `work_jobs` | Prompt/share/App Intent jobs and retry/acceptance lifecycle |
| `work_assets` | Local asset metadata |
| `job_assets` | Ordered assets attached to a queued job |
| `draft_assets` | Ordered assets attached to a draft |
| `transfers` | Background upload/download state |

This database owns user intent until the gateway gives an authoritative
acceptance disposition. It is not used to reconstruct agent replies.

### Plugin-local storage

| Store | Purpose |
|---|---|
| `<HERMES_HOME>/device_tokens.json` | Hashed revocable device credentials |
| `<profile>/plugins/hermes-mobile/prompt_receipts.sqlite3` / `prompt_receipts` | S11 idempotency reservations/dispositions |
| approval audit file | Bounded resolver audit trail |
| `mobile_manifest_revisions.json` | Coalesced silent-refresh revisions |
| `<HERMES_HOME>/push/relay.json` | Hosted push-relay agent credentials/pairing |

Pending-attention cursor journals, foreground maps, live socket indexes, and
turn-start tracking are bounded process-local state.

### Hosted APNs broker

[`server/push-relay/`](../server/push-relay/) has its own SQLite store:

| Table | Purpose |
|---|---|
| `agents` | Anonymous gateway/plugin identity and hashed credentials/pairing |
| `devices` | APNs tokens, environment, bundle ID, notification preferences |
| `push_events` | Delivery metadata |
| `attest_challenges` | App Attest challenge replay protection |
| `transit` | Broker tunnel/transit state |

It does not store Hermes sessions or transcripts.

The broker README still says “Fetch Push Relay” and uses some `HERMES_FETCH_*`
examples. That naming is inherited reuse, not the current Hermes Mobile product
boundary, and should be reviewed/cleaned separately rather than hidden.

## Work completed before this PR

The recorded ABH-519 sequence is:

1. **Phase 0:** proved a pullable physical-device logging channel.
2. **Phase 1:** added the authenticated transparent stock WS/HTTP proxy and
   proved unchanged stock frames against an isolated gateway.
3. **Phase 2:** moved the iOS vertical slice to explicit stock
   `session.create` → `prompt.submit`, stored/runtime identity, and drive/watch;
   proved cache write/HIT/repaint on device.
4. **Phase 3:** proved parity for live follow, approvals, clarifications,
   pagination, push navigation, and foreground suppression using retained
   seams.
5. **Phase 4:** deleted the legacy item-stream/reframer/session-state stack and
   retained one stock gateway protocol.
6. **Post-merge hardening:** routed watched-session approval/clarification
   responses through S13, tightened ACK-only clearing, and ran two-device
   physical gates.
7. **PR #241/main consolidation:** removed further divergent project/session
   paths.
8. **PR #243/current:** replaces the last frame-observer notification intake
   with stock hooks and deletes S1/S2/replay/status remnants.

Evidence:

- [`ABH519-PHASE0-DEVICE-LOG-EVIDENCE.md`](ABH519-PHASE0-DEVICE-LOG-EVIDENCE.md)
- [`ABH519-PHASE1-TRANSPARENT-PROXY-EVIDENCE.md`](ABH519-PHASE1-TRANSPARENT-PROXY-EVIDENCE.md)
- [`ABH519-PHASE2-IOS-VERTICAL-SLICE-EVIDENCE.md`](ABH519-PHASE2-IOS-VERTICAL-SLICE-EVIDENCE.md)
- [`ABH519-PHASE3-PARITY-EVIDENCE.md`](ABH519-PHASE3-PARITY-EVIDENCE.md)
- [`ABH519-PHASE4-DELETION-EVIDENCE.md`](ABH519-PHASE4-DELETION-EVIDENCE.md)
- [`ABH519-POST-MERGE-HARDENING-EVIDENCE.md`](ABH519-POST-MERGE-HARDENING-EVIDENCE.md)
- [`STOCK-PROTOCOL-MAP.md`](STOCK-PROTOCOL-MAP.md)
- [`CONTRACT-DEPATCH.md`](../CONTRACT-DEPATCH.md)

The Phase 3 document describes S1/S2 as retained at that historical point.
PR #243 intentionally supersedes that part of the Phase 3 architecture; its
device results remain historical evidence, not proof of the new stock-hook
push intake.

## Current PR verification

Recorded on the implementation head:

- physical iPhone 16 Pro Max:
  `LiveTurnReentryTests` and `ContextMeterTests` passed;
- focused gateway suite: 6 passed;
- plugin notification/registration suite: 48 passed;
- complete retained relay suite: 27 passed;
- plugin registration against pristine public v0.19 passed;
- Python compile and `git diff --check` passed;
- full mobile-plugin sweep: 636 passed with five known baseline failures.

The five plugin failures are:

- four stale Live Activity mocks that do not accept the current `priority`
  argument or assert old event behavior;
- one environment-dependent provider-auth backfill assertion.

GitHub CI initially failed one stale test that still required removed S3
`runtime_session_id` finalize metadata. Commit `174aed949` changes only that
test expectation and corrects the S3 ledger wording. The complete focused file
then passed: **18 passed**.

## Important limits and open review findings

1. **Current PR push behavior lacks a new physical APNs proof.** The physical
   session-resume/context tests are green, but the completion/approval/
   clarification notification device evidence predates the switch from frame
   observers to stock hooks. A reviewer should require at least one
   current-head physical notification for completion and one actionable gate.
2. **The four stale Live Activity mock failures touch the subsystem changed by
   this PR.** Calling them pre-existing is historically accurate, but they
   should not be allowed to conceal a new push regression.
3. **S5 is the broadest retained core seam.** Review it for the minimum generic
   registries/call sites and confirm no device policy leaked into core.
4. **The plugin manifest says `provides_hooks: []` while `register(ctx)`
   dynamically registers stock hooks.** Confirm this is valid manifest
   semantics or update the declaration/documentation.
5. **The hosted broker retains Fetch naming and tunnel capabilities.** Confirm
   which hosted functions Hermes Mobile actually deploys; do not accidentally
   merge the stateful APNs broker with the stateless co-located chat proxy.
6. **Hosted `kind=relay` pairing is currently dormant/incomplete.** The plugin
   can mint the link and iOS can parse it, but `HermesURLRouter.applyPair`
   explicitly ignores it. Do not describe that route as zero-setup mobile
   connectivity unless it is either completed under an approved plan or
   deleted.
7. **`ios_turn_context` and `kanban_spec_guard` are policy, not transport.**
   Review whether they belong in this adapter and whether mobile context
   injection preserves the project’s prompt-cache contract.
8. **Pristine-stock registration is graceful degradation, not zero-seam
   parity.** Test both “loads” and the actual absence behavior for each optional
   seam.
9. **The branch was created from `82c254566`; `origin/main` advanced to
   `f890a1d12` while this work was in progress.** GitHub reports it mergeable,
   but the reviewer must inspect the three-dot diff against current main and
   rerun the affected gates after the gated update/merge.
10. **No live production validation belongs to this branch.** Production
   gateway wiring, TestFlight release, and owner data truth must be a separate,
   explicitly approved deployment gate.

## Reviewer reproduction commands

Run from an isolated checkout of `codex/native-stock-architecture`.

```sh
git fetch origin
git diff --stat origin/main...origin/codex/native-stock-architecture
git diff --check origin/main...origin/codex/native-stock-architecture
git log --oneline origin/main..origin/codex/native-stock-architecture
```

Verify relay transparency and absence of state/translation:

```sh
PYTHONPATH=relay python -m pytest -q relay/tests
git diff -U0 origin/main...HEAD -- relay/ |
  rg 'json\\.loads|json\\.dumps|sqlite|transcript|replay|reframe|session_state'
```

Verify the removed observer/replay architecture stays absent:

```sh
rg -n 'FRAME_OBSERVERS|POST_EMIT_EVENT_OBSERVERS|broadcast|ReplayRing|replay_ring' \
  tui_gateway hermes_cli plugins/hermes-mobile relay
```

Verify stock-hook notification wiring:

```sh
python -m pytest -q \
  tests/plugins/hermes_mobile/test_push_intake.py \
  plugins/hermes-mobile/tests/test_push_alert_event_kinds.py \
  plugins/hermes-mobile/tests/test_register_late_wiring.py \
  tests/plugins/hermes_mobile/test_plugin_register.py
```

Verify the corrected finalize contract:

```sh
python -m pytest -q tests/test_lazy_session_regressions.py
```

Inspect retained seams directly:

```sh
rg -n \
  'create_service_tier_override|TOKEN_AUTHENTICATORS|IDENTITY_VALIDATORS|SOCKET_OBSERVERS|PROMPT_RECEIPT_PROVIDERS|pending_approval_snapshot|pending_prompt_snapshot|evicted' \
  tui_gateway hermes_cli tools
```

For iOS, use physical hardware and the repository mutex wrapper only:

```sh
scripts/ios-build.sh test \
  -scheme HermesMobile \
  -destination 'platform=iOS,id=<PHYSICAL_DEVICE_UDID>' \
  -collect-test-diagnostics never
```

Do not use the live gateway/relay for review. Use isolated gateway ports 9130+
and an isolated proxy. Do not start a simulator on the owner’s Mac Studio.

## Requested independent review

Please review, in this order:

1. Confirm the co-located relay is truly byte-transparent and stateless.
2. Confirm stock RPC/event semantics are the only chat protocol used by iOS.
3. Confirm S1, S2, S3, S7, S9, S10, and S12 have no surviving runtime
   implementation.
4. Audit S4/S5/S6/S11/S13 for genericity, minimum footprint, and graceful
   plugin-disabled behavior.
5. Trace one new-chat send from `WorkRepository` through stock
   `session.create`/`prompt.submit` to scoped cache persistence.
6. Trace drive/watch and prove `session.active_list` cannot steal a foreign
   runtime.
7. Trace completion, approval, clarification, error, and interrupt push from
   the exact stock hook to APNs.
8. Decide whether `ios_turn_context` and `kanban_spec_guard` belong in the
   mobile adapter.
9. Distinguish and audit the stateless chat proxy and stateful APNs broker as
   separate systems, including the currently ignored `kind=relay` pairing.
10. Require current-head physical notification evidence before approval.

The acceptance standard is architectural deletion, not merely passing tests:
no new coordinator, transcript store, replay type, identity map beyond the
single stored/runtime owner binding, custom gateway method, or second
implementation of existing stock behavior.
