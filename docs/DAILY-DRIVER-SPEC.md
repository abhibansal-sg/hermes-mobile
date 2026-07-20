# OPERATION DAILY-DRIVER — Consolidation & Stability One-Shot Spec

**Date:** 2026-07-20 · **Owner:** Abhinav · **Authorized:** consolidate all open work and land it; make the app a stable daily driver.
**Repo:** /Volumes/MainData/Developer/products/hermes-mobile (github abhibansal-sg/hermes-mobile) · main @ 98ce66e36

## Mission
One coherent landing: consolidate PRs #220,#221,#222,#223,#224,#225,#226,#227,#228,#229 + the five fixes inside #230 (codex/wave25-relay-device-qa) into a single verified line, harden connect/caching/outbox to daily-driver grade, land to main, deploy the relay as a supervised service, and install the build on the owner's iPhone Air (UDID 1D51F2FB-1DB2-52BF-818B-EFD2ACE7C0E7).

## Acceptance criteria (the bar; each must have EVIDENCE)
A1. **Connect budget:** app cold-open → cached transcript painted immediately; transport connected + composer interactive in ≤2s on the local network (relay path). Measured via timestamped logs in an instrumented run (simulator acceptable; device preferred).
A2. **Zero silent wire failures:** a cross-language conformance suite proves every iOS RelayClient upstream payload field is read by the relay downstream handler, and every downstream frame field is decoded by iOS — the prompt/text, decision/choice, text/answer class of bug becomes structurally impossible (generated from one source of truth or exhaustively asserted).
A3. **Outbox robustness:** a queued send drains ≤2s after transport ready; survives app force-close; survives RELAY restart (durable owned sessions re-resume, then drain); no duplicate turn on retry after ambiguous failure (client_message_id dedupe through relay submit).
A4. **Reconnect:** kill the WS 10× mid-turn (chaos) → transcript reconciles byte-identical to an undropped run (no doubled text, no lost items); reconnect is single-flight with capped backoff; no visible error flash for self-healing conditions.
A5. **Approval/clarify round-trip:** live E2E — approve proceeds (never silent-deny), clarify answer arrives non-empty, taskList streams to the dock (iOS decodes type "taskList" natively, not generic fallback).
A6. **Relay restart survival:** kill -TERM the relay mid-session → phone reconnects, resyncs gap-free, owned sessions still drive; queued sends drain.
A7. **Single relay, supervised:** exactly ONE relay runs on this Mac, as a launchd service (auto-start, KeepAlive, log rotation), pointed at the live gateway with the dashboard token; the second/stale relay decommissioned.
A8. **Notification path (existing feature made trustworthy):** notifier fires on turn-complete/approval/clarify/task-complete for owned sessions with mock-APNs E2E evidence; suppressed when phone foregrounded. (Physical APNs delivery remains owner device-QA.)
A9. **All tests green:** full relay pytest, full iOS suites touched by the consolidation, on the FINAL merged tree (not per-branch).
A10. **Landed + deployed:** consolidation merged to main, pushed; absorbed PRs closed with landing references; #206 closed as superseded; device build from the landed line installed on the iPhone.

## Consolidation order (integration branch `consolidation/daily-driver` off main)
1. #220 wave2/convergence → 2. #221 wave2/relay-reliability → 3. #223 wave2/relay-turn-elements → 4. #229 fix/relay-duplicate-delta-doubling → 5. #226 wave25/session-surface (includes QA-round-1 fixes) → 6. #227 w25/fix-projects-auth (folds #224 base first: merge #224 w25/projects before it) → 7. #228 w25/reconnect-soften → 8. #222 w25/settings → 9. #225 w25/files → 10. ABSORB #230: cherry-pick/merge the five fixes from codex/wave25-relay-device-qa (durable owned_sessions in durable_state.py + gateway_client re-resume; wait_ready gate in downstream handle_upstream; iOS foreground re-establish + RelayUpstreamMethod.foreground + setForeground; downstream accepts prompt AND text; ConnectionStore phase bridge + scene-phase relay check + composer relay-ready gating). Resolve conflicts by intent: the STACK is the base; #230 fixes are surgical patches on top. Do NOT absorb unrelated #230 checkpoint noise (84 files — take only the fix surfaces + their tests).
11. Commit governance docs: WAVE-ROADMAP.md 2026-07-19 revision (extract read-only from the main repo `git show stash@{0}:docs/WAVE-ROADMAP.md`), docs/RELAY-PHONE-PROTOCOL.md + docs/MOBILE-RELAY-CLIENT-DESIGN.md (copy from primary tree untracked files, read-only), this spec as docs/DAILY-DRIVER-SPEC.md. Update RELAY-PHONE-PROTOCOL.md with: taskList item type (already on #223's branch doc), durable owned sessions, readiness gate, client_message_id.

## Known conflict map (from the sweep — resolve with these intents)
- relay/hermes_relay/downstream.py: #221 SUBMIT dedupe + #223 approval/clarify routing + #230 wait_ready + prompt/text. All four must survive.
- relay/hermes_relay/gateway_client.py: #223 field fixes (choice/answer) + #230 durable owned re-resume. Both survive.
- apps/ios .../ConnectionStore.swift: #228 single-flight/backoff + #230 phase bridge + scene-phase check. Both survive; #228 backoff wraps #230 reconnect triggers.
- apps/ios .../RelaySessionCoordinator.swift: #221 resync watermark + #230 foreground re-establish + onPhaseChange. All survive.
- SettingsView: #222 restructure is the base; keep relay toggle working under Advanced.
- pbxproj: always resolve by `xcodegen generate` (project.yml union) — never hand-merge.

## New work items (beyond merges)
N1. **Wire conformance suite (A2):** tests/conformance/ — parse Swift RelayClient/RelayProtocol payload construction and relay downstream.py/gateway_client.py readers; assert key-for-key agreement for every RPC + frame kind. Pure static+fixture based; runs in pytest + XCTest (shared JSON fixtures).
N2. **client_message_id idempotency (A3):** iOS sends client_message_id per submit; relay downstream dedupes (bounded LRU already exists from #221 — key it by client_message_id when present); document in protocol.
N3. **Connect fast-path instrumentation (A1):** timestamped signposts: cold-open → cache paint → socket open → ready → composer enabled. Fix any serial waits found (parallelize cache paint and connect; no blocking status round-trips before interactivity).
N4. **taskList decoding on iOS (A5):** ChatItemType gains taskList; RelayItemStore/dock consume it (dock already reads ChatStore todos — bridge relay taskList items into the same accessor on the relay path).
N5. **Selection-island boundary fix:** remove .perfTextSelection() from table cells (MessageBubble.swift:1846 area) and code blocks (CodeBlockView.swift:171 area) on the consolidated branch — cards must not be selectable (approved design).
N6. **Relay launchd service (A7):** ai.hermes.relay plist template + install script (relay/scripts/install-service.sh): runs `python -m hermes_relay --gateway-host 127.0.0.1 --gateway-port 9119 --listen 0.0.0.0:8788 --token-file ~/.hermes/dashboard.token`, KeepAlive, stdout/err to ~/Library/Logs/Hermes/relay.log. The __main__ 9119 refusal gains an explicit `--allow-live-gateway` flag (default off; service passes it) — tests still refuse 9119 by default.
N7. **Gateway middleware hardening (in-repo hermes_cli):** BaseHTTPMiddleware auth gates catch downstream exceptions → 500 JSONResponse; WS routes exempted/WebSocketDisconnect caught. In-repo only (helps future runtime updates); tests included. Do NOT touch the live StraitsLab runtime clone.
N8. **E2E device-shaped gate (A3-A6):** tests/e2e_daily_driver/ — harness: isolated gateway (port 913x, temp HERMES_HOME) + consolidated relay + Python phone-driver speaking the ratified protocol. Scenarios: submit→stream→complete; approve round-trip; clarify round-trip; taskList; relay SIGTERM restart mid-session → resync + drain; 10× ws_flap chaos → byte-identical reconcile; mock-APNs notify assertions. Runnable via one script; used as the merge gate now and CI later.

## Hard rules (every agent)
- NEVER touch the primary working tree at /Volumes/MainData/Developer/products/hermes-mobile — worktrees under /Volumes/MainData/Developer/hermes-tmp/worktrees/ only.
- NEVER run tests against the live gateway 127.0.0.1:9119 — isolated gateways on 9130+ with temp HERMES_HOME (pattern: /Volumes/MainData/Developer/hermes-tmp/r0-relay-spike/launch_gateway.sh). The ONLY live-gateway interactions allowed are: the final deployment phase (service install, relay swap) and read-only health curls.
- iOS builds via scripts/ios-build.sh (machine-global mutex; SIGTERM never kill-9). Swift 6 strict concurrency clean. Composer layout/controls FROZEN. Image rendering untouched.
- All venvs/builds/evidence on /Volumes/MainData (internal disk ~15GB free). Evidence dir: /Volumes/MainData/Developer/hermes-tmp/evidence/daily-driver/.
- Python via /opt/homebrew/bin/python3.13 venvs; relay deps per relay/requirements.
- No secrets in logs/evidence. Small commits, imperative messages.
- Merges to MAIN happen ONLY in the final Land phase after the Opus gates pass. Everything before that stays on consolidation/daily-driver.

## Non-goals (explicitly out)
HRP/2 hosted relay (banked, Wave 6); foreign-session co-watch; outbound tunnel; new UX features beyond the approved Wave-2.5 surface; physical-device APNs/TestFlight validation (owner gate); fixing the StraitsLab runtime clone in place.
