# UI Testing — Agent-Driven End-to-End Testing (the fourth scout sense)

> Abhi decision 2026-07-03: agents must be able to test the app THROUGH the UI —
> taps, swipes, typing — because the highest-value bug classes (drawer clutter,
> dead controls, zombie Live Activities, crash-on-disconnect) are only visible
> on the screen. This doc is the plan of record. Rollout is GATED: nothing
> enters the cron loop until each gate below passes.

## Architecture — three layers on two mechanisms

| Layer | Mechanism | What it catches | Cadence |
|---|---|---|---|
| L-explore: **ui-scout beat** | Live driving (Maestro MCP / AXe CLI) | Unknown unknowns: dead controls, visual lies, state desyncs | 2x/day when live |
| L-regress: **committed flows** | Maestro YAML in `tests/flows/` | Yesterday's bugs staying dead; CUJs as REAL taps | Per-change + pre-ship |
| L-sweep: **cloud XCUITest** | `xcodebuild test` on Xcode Cloud | Full matrix (iPhone+iPad, light/dark) off-Mac | Nightly |

## Toolchain (all free/OSS — decision 2026-07-03, cost concern resolved)

- **Maestro** (Apache 2.0, `brew install maestro`): drives sims via a PREBUILT
  XCUITest runner installed with simctl — zero xcodebuild at test time. MCP
  server ships in the CLI (`maestro mcp`): inspect_screen / tap_on / input_text /
  take_screenshot / run-YAML. Paid tier = their cloud + their LLM; we need
  neither (our agents ARE the AI). Known quirk: hardcoded port 22087 — ONE
  instance per machine; UI beats must serialize (they do anyway via cron).
- **AXe** (MIT, `brew install cameroncooke/axe/axe`): bare-shell lane —
  `axe describe-ui | tap --label | type | swipe | screenshot`. No server. The
  GLM/plain-shell agents' lane, and the fallback if Maestro's iOS 26 hierarchy
  inspection disappoints.
- **XCUITest** (Apple, already in repo — 7 files in HermesMobileUITests/):
  the L-sweep mechanism + the no-rug-pull floor. Wedge economics:
  `build-for-testing` ONCE under the ios-build.sh mutex, then UNLIMITED
  `test-without-building -xctestrun` runs with zero build-system involvement.
- **Explicitly rejected**: mobai.run (Jan-2026 repos, too young — retrial H2
  2026), hosted QA startups ($500+/mo, cloud-only), raw idb (unmaintained,
  macOS 26 breakage), Appium (heaviest stack, no added capability for us).
- **Xcode 27 watch items** (beta — we build on GA only): (a) Device Hub headless
  automation surface at GA -> evaluate as native replacement for Maestro/AXe;
  (b) test-plan crash-severity controls at GA -> fold into CUJ suite config.

## Wedge safety (the invariant that must never break)

UI driving NEVER invokes xcodebuild. The .app under test comes from:
1. PREFERRED: reuse an existing simulator build (verifier chain derivedData or
   a build-for-testing product) — `xcrun simctl install <udid> <path>.app`.
2. When none exists or it's stale: ONE `xcodebuild build-for-testing` run
   THROUGH scripts/ios-build.sh (the mutex), emitting both the .app and the
   .xctestrun for L-regress/L-sweep reuse.
Rule: any script in this system that shells out to raw `xcodebuild` is a bug.

## Repo structure

```
tests/flows/                    # Maestro YAML regression flows (L-regress)
  cuj/                          #   one flow per CUJ-CATALOG entry (cuj-01.yaml ...)
  regressions/                  #   graduated bug repros (abh-<n>-<slug>.yaml)
  _helpers/                     #   shared subflows (login/pair, reset-state)
scripts/ui-test.sh              # single entrypoint: build-artifact resolve +
                                #   sim boot + install + run flows + JSON verdict
docs/autonomous/UI-TESTING.md   # this doc
```

## Contracts (once live — see rollout gates)

- **ui-scout beat**: coverage-map-driven like scout-bugs (user-flow lens).
  Observes via hierarchy dump + screenshot, acts via tap/swipe/type, files
  Triage issues WITH the repro YAML + screenshot attached. Crash/data-loss
  findings go straight to Backlog p1. Evidence gate applies: no filing without
  a repro artifact.
- **Graduation rule**: every CONFIRMED UI bug fix ships with its repro flow
  committed to tests/flows/regressions/ (reviewer enforces, same as CUJ
  entries). Exploration findings become permanent regression coverage.
- **CUJ realization**: CUJ-CATALOG entries marked `smoke: ios-sim` get real
  flows in tests/flows/cuj/ — the catalog stops proxying UI journeys via REST.
- **Soak integration**: L-regress flow failures on staging-adjacent app builds
  are DO-NOT-SHIP evidence, same rank as CUJ smoke failures.

## Rollout gates (each gate needs evidence before the next step)

- **GATE 0 — smoke test (WITH ABHI, live)**: both tools installed; current app
  .app installed on a booted sim WITHOUT new wedge exposure; observe→act loop
  closes (hierarchy dump shows real elements; a tap visibly works; screenshot
  captures it) on iOS 26. PASS = proceed. FAIL on Maestro hierarchy = retry
  with AXe lane. FAIL on both = stop, reassess (XCUITest-only architecture).
- **GATE 1 — one real CUJ flow**: hand-written cuj-01 (cold launch -> session
  list visible) runs green 3x consecutively via scripts/ui-test.sh.
- **GATE 2 — agent-driven session**: an agent (not a human) completes one
  bounded exploration (e.g. settings screen walk) and produces one filed-quality
  finding or a clean report, within turn budget, no runaway.
- **GATE 3 — beat wiring**: only now does ui-scout get a profile + cron. Starts
  2x/day, findings reviewed by Abhi for taste-calibration for the first week
  before the refiner trusts them into the normal funnel.
- **GATE 4 — cloud sweep**: nightly Xcode Cloud test action (needs a Test
  action added to a workflow; separate from the Ship workflow).

## Current status

- [x] Research complete (two delegated deep-dives, 2026-07-03; landscape report
      at ~/.hermes/research/ios-agentic-ui-testing-landscape-2026.md)
- [x] Plan of record (this doc)
- [ ] GATE 0 smoke test with Abhi
- [ ] GATE 1..4
