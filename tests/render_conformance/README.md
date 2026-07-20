# render_conformance — the RENDER half of the device-shaped gate (QA-1 A9)

**The gap this closes:** every E2E scenario in `tests/e2e_daily_driver/` drove
the relay protocol with a Python phone-driver — nothing exercised the iOS
render lane (`RelayItemStore` → `ChatStore` → SwiftUI view state). Build 114
passed all 169 relay pytest + 27 conformance + 11 E2E wire gates yet failed
owner device QA in relay mode (B5/B6/B7/B8/B10/B13: sent message never echoed,
history wiped mid-turn, clarify/approval cards never rendered, working pill
back). This gate makes that class structurally impossible: the SAME recorded
relay frame streams the phone saw are replayed through the REAL iOS render
lane, and render-model invariants are asserted against the spec contract.

## Layout

- `fixtures/*.json` — **recorded** relay downstream frame streams (verbatim
  `{seq, sid, turn, kind, body}` envelopes in arrival order) plus replay
  metadata: the `submit` that drove the turn, the `cached_history` the GRDB
  transcript cache paints before any relay frame lands, and the `open` RPC
  result messages. Byte-stable across runs (fixed session ids, fixed gate
  request ids, deterministic mock-gateway scripts, fresh relay per test ⇒
  dense seqs from 1; the tasklist script's one random id is normalized).
  `render_live_fold.json` (QA-2 R5/R6/A3) is HAND-AUTHORED to the same wire
  format (the harness's mock gateway has no deterministic reasoning+tool
  script yet); it carries its provenance in its `recorded_by` field.
- The XCTest suite itself lives in the iOS test target (XCTest requirement):
  `apps/ios/HermesMobileTests/RenderConformanceTests.swift`, with the fixtures
  bundled into that target via `apps/ios/project.yml`. It replays the frames
  byte-for-byte through the production decoders (no live network — the
  coordinator's `RelayClient` runs over the in-process fake relay).

## Recording (extend, don't fork)

The fixtures are recorded by the E2E harness itself:
`tests/e2e_daily_driver/test_z_record_render_fixtures.py` reuses the existing
harness (mock gateway + real relay subprocess + phone driver), drives the same
deterministic scripts as scenarios (a)–(d), and dumps the phone's frame log
via `phone_driver.render_fixture(…)` / `write_render_fixture(…)`. Running the
E2E gate (`tests/e2e_daily_driver/run_gate.sh`) refreshes the recordings, so
the render gate always replays what the relay emits TODAY — e.g. once the
Family-1 lane lands the relay-synthesized `userMessage` item, re-recording
adds it to `render_submit_stream.json` and the echo-reconciliation invariant
exercises the full echo↔item path.

## Invariants (spec contract, not the buggy present)

| Fixture | Invariant | Spec | qa1/base |
|---|---|---|---|
| render_submit_stream | user echo present immediately after relay submit | B5/A2 | FAILS (no echo; relay emits no userMessage item) |
| render_submit_stream | cached history preserved during AND after the live turn | B6/B7/A2 | FAILS (`applyRelayItems` replaces `messages` wholesale) |
| render_submit_stream | exactly one user bubble after completion (echo reconciles) | B5/A2 | FAILS (zero bubbles) |
| render_submit_stream | settled agent text reconstructed; turn not streaming | A9 | passes (pin) |
| render_submit_stream (new chat) | first send shows the user bubble | B13 | FAILS |
| render_approval_gate | approval.request → `pendingApproval` card model + dock `.approval`; answer round-trips over relay | B10/A3 | FAILS (frame dropped at `RelayItemStore`; responder hardwired to the gateway client) |
| render_clarify_gate | clarify.request → `pendingClarification` card model + dock `.clarify`; answer round-trips over relay | B10/A3 | FAILS (same) |
| render_tasklist | taskList lifecycle → `latestTodoList` dock accessor + dock `.tasks` | A3/A4 | passes (pin) |
| — | streaming assistant bubble suppresses the standalone Working pill on relay | B8/A4 | FAILS (`shouldShowInlineTurnActivity` transport-agnostic) |
| — | dock never resolves a working surface | A4 | passes (pin) |
| — | seeded-then-emptied transcript never renders the void (skeleton/cache) | B4/A7 | FAILS (placeholder hole at generation > 0) |
| — | session switch never voids a painted transcript | B4/A7 | FAILS (open-path reset wipes `messages`) |
| — | idle-session open keeps the transcript non-empty | B4/B15 | FAILS (reset + empty snapshot) |
| — | cold cache paints with zero relay frames | B15 | passes (regression guard) |
| render_live_fold (QA-2) | send → optimistic caret bubble + streaming instantly, no frames | R4/A2 | FAILS on qa2/base (send appends nothing) |
| render_live_fold (QA-2) | terminal `userMessage` frame keeps the turn streaming (turn-scoped) | R4/A2 | FAILS (projection clears `isStreaming`) |
| — (QA-2) | Working pill impossible on relay — every phase incl. pre-first-item | A2 | FAILS (pre-first-item clause returns true) |
| render_live_fold (QA-2) | live turn = ONE assistant row → ONE working node; raw tool state reads "Working…" | R5/A3/N2 | FAILS (stacked live rows; raw names surface) |
| render_live_fold (QA-2) | resolved tool rides inline: "Working… · ‹tool›" | R5/A3 | FAILS |
| — (QA-2) | live working section measures one line (< 60pt), never the 172pt window | R6/A3 | FAILS (172pt ThinkingView) |
| render_live_fold (QA-2) | settled relay turn stamps "Worked for Ns"; survives the next turn's re-projection | R5/A3 | FAILS (bare "Worked"; relay items carry no timestamps) |

## Running

```sh
# The whole gate (wire + render), one entry script:
tests/e2e_daily_driver/run_gate.sh

# Render half only (after recording has produced the fixtures):
scripts/ios-build.sh test -scheme HermesMobile \
  -destination 'platform=iOS Simulator,name=iPhone Air' \
  -only-testing:HermesMobileTests/RenderConformanceTests

# Refresh the recordings only:
tests/e2e_daily_driver/run_gate.sh tests/e2e_daily_driver/test_z_record_render_fixtures.py
```

RED evidence on unfixed qa1/base:
`/Volumes/MainData/Developer/hermes-tmp/evidence/daily-driver-qa1/`.
