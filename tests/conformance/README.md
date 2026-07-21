# Wire conformance suite (A2 / N1)

Cross-language proof that the iOS app and the relay agree on the wire,
key-for-key, for **every** upstream RPC payload and **every** downstream frame
field. The prompt/text, decision/choice, text/answer bug class (fields renamed
or dropped between two independently written stacks) becomes structurally
impossible: a mismatch fails BOTH test stacks, not just an E2E scenario.

## The three surfaces

```
iOS (Swift)                     relay (Python)                 gateway (Python, in-repo ground truth)
RelayClient builders      <->   downstream.handle_upstream     (phone -> relay)
RelayUpstreamMethod       <->   UpstreamMethod.ALL
RelayFrame / ChatItem     <->   Frame.to_wire / Item.to_dict   (relay -> phone)
RelayFrameKind wire strs  <->   FrameKind.ALL
gate payload decoders     <-    reframer passthrough bodies    (gateway payload verbatim)
                                gateway_client RPC params  ->  tui_gateway @method handlers
```

## Files

- `wire_contract.json` — **single source of truth.** Shared fixture: method
  sets, per-method required/optional param keys + examples + expected gateway
  mapping, downstream envelope/kinds/item shape/body contracts, one realistic
  sample frame per kind, and the gateway-edge reads/sends. Bundled into the
  iOS test target via `apps/ios/project.yml` (`buildPhase: resources`) so the
  XCTest side consumes the byte-identical file.
- `extract.py` — static surface extraction from live sources: Swift via regex
  (builders, enums, decoders), relay + gateway via `ast` (param readers, RPC
  dicts, handler reads). Nothing is hand-copied; the tests fail on ANY drift
  between the fixture and the code on either side.
- `conftest.py` — loads the contract, adds `relay/` to `sys.path`, provides a
  recording `FakeGateway` + `PhoneConnection` stack. Never touches a socket.
- `test_upstream_conformance.py` — phone -> relay: method-set agreement,
  fixture<->Swift sends, fixture<->ast reads, every iOS-sent field is
  relay-read, every relay-required field is iOS-sent, and BEHAVIORAL runs of
  the real iOS-shaped payloads through the real `handle_upstream` (the
  structural kill).
- `test_downstream_conformance.py` — relay -> phone: kind/envelope/item-shape
  agreement, item-type fold allowlist (`taskList` until N4-style native decode
  lands), reframer emission conformance driven from representative raw
  gateway events, gate identity keys (clarify `request_id` / approval `sid`),
  snapshot shape, shared-sample decode.
- `test_gateway_edge_conformance.py` — relay -> gateway: `gateway_client`
  sends vs in-repo gateway handler reads; the silent-default keys (`choice`,
  `answer`, `text`) must be always-sent with the phone's value mapped on.
  Declared `accepted_unread` forward-compat extras are allowed and asserted
  never to be an effective key.
- `apps/ios/HermesMobileTests/WireConformanceTests.swift` — the XCTest half:
  drives the REAL `RelayClient` builders through a capture transport and
  asserts the wire keys per method + envelope (requests carry an id,
  notifications must not), decodes every shared sample frame with the real
  `RelayFrame`/`ChatItem`/gate decoders, and checks the item-type fold.

## Running

```sh
# pytest half (repo root; relay venv on /Volumes/MainData):
/Volumes/MainData/Developer/hermes-tmp/venvs/relay/bin/python -m pytest tests/conformance/ -q

# XCTest half (machine-global mutex; never kill -9):
scripts/ios-build.sh test -scheme HermesMobile \
  -destination 'platform=iOS Simulator,name=iPhone Air' \
  -only-testing:HermesMobileTests/WireConformanceTests
```

## Extending the contract

- New upstream RPC: add the method to `RelayUpstreamMethod` + `UpstreamMethod`,
  the builder + handler, then a `payloads` entry (sends/reads/example/
  expect_gateway). The suite fails until all three surfaces + the fixture
  agree.
- New frame kind: add to `FrameKind` + `RelayFrameKind`, a `body_contract`
  entry, and a sample frame (XCTest decodes it automatically).
- Promoting a folded item type to a native iOS case (e.g. N4 `taskList`):
  add the `ChatItemType` case, move the type from `generic_fold` to
  `ios_native` in the fixture. `test_item_type_coverage_and_fold` fails until
  both are done.
- `accepted_unread` (gateway edge): only for documented forward-compat extras;
  an effective (silent-default) key is never allowed there.
- **Relay-first surface (R4 Wave-1 ratchet):** ROUND4-LEAN-PLAN.md §c deploys
  the relay lanes AHEAD of the iOS glue (additive; old iOS unaffected). A
  method the relay implements before its iOS builder exists goes under the
  fixture's top-level `relay_ahead.methods` (full spec: reads/example/
  expect_gateway, empty `ios_sends`) — NOT under `upstream.payloads`, which
  the XCTest consumer compares key-for-key against `RelayUpstreamMethod`.
  pytest holds the RELAY side to it (`UpstreamMethod.ALL` ==
  `upstream.payloads` KEYS ∪ `relay_ahead.methods`; the reads + behavioral
  tests cover the entries) while the Swift surface still equals
  `upstream.payloads` exactly. **Double-acting ratchet:** the moment Swift
  implements a relay_ahead method, `test_upstream_method_sets_agree…` FAILS
  and the adopter MOVES the spec into `upstream.payloads` (with real
  `ios_sends`) and DELETES it from `relay_ahead`. The section must be EMPTY
  at the Wave-4 exit (relay-only tree). Optional params these lanes add to
  EXISTING methods ride the host method's `relay_reads` (no Swift builder
  needed until iOS sends them). `branch` (R4 L2) is the first entry.
