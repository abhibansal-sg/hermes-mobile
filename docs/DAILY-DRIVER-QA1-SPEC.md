# OPERATION DAILY-DRIVER QA-1 — Device-QA Round 1 Fix Spec

**Date:** 2026-07-20 evening · **Owner:** Abhinav · **Authorized:** fix every device-QA finding from build 114, land to main, install build on iPhone Air (UDID 1D51F2FB-1DB2-52BF-818B-EFD2ACE7C0E7).
**Repo:** /Volumes/MainData/Developer/products/hermes-mobile · main @ 29804b344 (daily-driver landing).
**Context:** Build 114 (the daily-driver consolidation) passed all wire-level gates (169 relay pytest, 27 conformance, 11 E2E, both Opus gates) yet failed owner device QA in relay mode. **Root systemic gap: every E2E scenario drove the relay protocol with a Python phone-driver — nothing ever exercised the iOS render/interaction layer (RelayItemStore → ChatStore → SwiftUI view state).** QA-1 fixes the bugs AND closes that structural gap with render-level tests so this class cannot ship again.

## Evidence from owner (19 screenshots, ~/Downloads IMG_2510-2528, sequence + notes)
The owner ran the app in relay mode against the supervised relay (ai.hermes.relay, 8788 → live gateway 9119). Model pill: qwen3.8-max-preview.

## The bug ledger (B1-B15) — every one needs root cause + fix + regression test + evidence
- **B1. Cold-start "Resume Session Failed" alert** (IMG_2510): every cold open throws a modal "Resume Session Failed — Not connected to the Hermes gateway" over the painted transcript. Resume is racing transport bring-up. REQUIRED: resume waits for/queues on transport-ready (relay AND direct paths); NO error alert for self-healing conditions ever (north-star rule) — silent retry once connected.
- **B2. Session switching slow / stuck on skeleton** (IMG_2511, 2512): switching sessions sometimes sits on skeleton rows "forever". Cache-first paint must be instant from GRDB; network refresh must never block paint; add a signpost + test.
- **B3. Drawer does not close on session tap** (IMG_2511, 2514 — regression, was fixed once): tapping a session sometimes leaves the drawer open. Find the state race (probably selection change not driving dismissal when session id unchanged or during load) and pin with a test.
- **B4. Session loads to a fully blank screen** (IMG_2513, 2516): transcript area completely empty (no skeleton, no content) while composer fine. Likely the relay-path store returning empty items and view not falling back to cache. Blank-screen must be impossible: cache → skeleton → content, never void.
- **B5. Sent message not echoed** (IMG_2517, 2518, 2526): after send, the user's own message does not appear — not during streaming, not after turn completes (until force-close reload, IMG_2525). Optimistic user echo must render immediately on send (WhatsApp bar) and the relay userMessage item must reconcile with it, both live and after completion.
- **B6. Streaming turn renders "scattered" mid-screen without context** (IMG_2517): live turn text floats mid-viewport; prior transcript absent above it. Live items must append to the painted history, anchored bottom, not replace the view.
- **B7. Prior history disappears when a live turn starts / after send** (IMG_2520, 2522-2524, 2528; owner: "every time I sent the message the previous history of that session just disappeared"): scrolling to top shows only the latest answer. Relay live-turn view is REPLACING the transcript instead of coexisting with cached/settled history. History + live turn must coexist; scrollback intact during and after streaming.
- **B8. "Working" pill is back** (IMG_2517, 2526): the big working bar above the composer has returned on the relay path. Approved design: the breathing/streaming cursor IS the working signal; the dock pill only for tasks/approvals/clarifies per the ratified TurnDock rules. Remove the redundant working pill on relay path (match direct-path behavior that was approved).
- **B9. Composer "+" (attach) button missing** (all composer shots): the plus button for photos/camera/files is gone from the composer pill. Composer is FROZEN — this is a regression introduced by relay-ready gating or the files merge. Restore it identically in both modes (relay + direct), including attachment flows.
- **B10. Clarification card never renders** (IMG_2522-2525, 2527, 2528): agent asked a clarify question; phone shows only a spinner row "Asking Do you like the clarifications UI? ›" + "Still thinking" forever — no interactive card with choices, nothing tappable. The relay clarify item must render the interactive clarification card (options + custom answer), answer must round-trip, and the turn must settle. Same for approval cards — verify both.
- **B11. Selection granularity wrong** (IMG_2519): long-press selects the ENTIRE paragraph as one block with a Done button, and selection cannot extend past that paragraph. Required: long-press starts a native WORD-level selection with drag handles, extendable across the whole message prose (paragraphs are not selection walls). Cards (code/tables) stay non-selectable islands. If the current per-paragraph island architecture cannot do word-granularity + cross-paragraph, restructure prose into a single selectable container per message.
- **B12. Gap between last message and composer too large** (IMG_2521): dead vertical space above composer (likely empty-dock or working-pill space reserved). Tighten to spec.
- **B13. New-chat first send: nothing visible** (IMG_2526): fresh chat, sent "hello": greeting stays, no user bubble, Working pill, no streamed reply visible. Same family as B5/B7 but MUST be explicitly verified in the new-chat (no session id yet) flow.
- **B14. Zero notifications** (owner: none arrived at all): phone backgrounded during turns → no push. Diagnose the LIVE path end-to-end: iOS token registration → (relay mode: does the token reach the notifier?) → relay notifier → APNs send. Mock-APNs E2E passed, so the break is in live wiring: token registration through relay, notifier config/creds in the launchd service env, or suppression logic. Fix what is fixable in code/config + document exactly what remains owner-gated (e.g. APNs key present?). Evidence: a real device push received, or a precise blocked-on-X statement.
- **B15. Force-close recovery works for settled sessions** (IMG_2527 painted fine) — keep it that way; regression-guard it while fixing B4/B7.

## Root-cause hypotheses (validate, don't assume)
- B5/B6/B7/B13 smell like ONE defect family: on relay path the live-turn item view replaces the transcript data source instead of merging into it (RelayItemStore vs ChatStore cache union), and there is no optimistic user echo on the relay submit path.
- B1: session resume fires on scene-activate before ConnectionStore reaches ready on the relay phase bridge; alert surfaces a retryable condition.
- B8/B12: TurnDock/working-pill suppression rules not applied on the relay-driven state machine; reserved layout space when dock empty.
- B9: composer attach affordance gated behind a direct-mode-only capability check (files lane #225 wired to direct API?) or relay-ready gating hiding it.
- B10: relay clarify/approval items decode (conformance proved the wire) but the UI mapping to the interactive card was only wired on the direct/plugin path — render layer gap.
- B14: notifier fires per mock test, but in production the phone's push token never registers with the relay-owned session, or the service venv lacks APNs credentials/env that the gateway plugin had.

## Acceptance criteria (each with evidence in the evidence dir)
- **A1.** 5 consecutive cold opens in relay mode: zero error alerts/flashes; transcript paints from cache instantly; composer interactive ≤2s. (Automated where possible + instrumented log.)
- **A2.** Send in an existing session: user bubble appears immediately (optimistic), history stays fully scrollable during streaming, reply streams in below, after completion user msg + reply + full history all present. Same for a brand-new chat. Render-level XCTest + scripted sim evidence.
- **A3.** Clarify AND approval: interactive card renders from relay frames, tap answer round-trips, turn settles, dock behaves per ratified rules. Render-level XCTest feeding recorded relay frames through RelayItemStore→ChatStore asserting view-model state, + sim E2E against isolated gateway/relay.
- **A4.** No standalone Working pill on relay path; streaming cursor is the working signal; dock only for tasks/approvals/clarifies; composer gap tightened to design spec.
- **A5.** Composer "+" present and functional in relay + direct modes (photo/camera/file attach round-trip on relay path proven in isolated E2E).
- **A6.** Long-press on agent prose = word selection with native handles, extendable across the entire message; cards not selectable; Copy pill absent (islands rules intact).
- **A7.** Drawer closes on session tap 100% (test pinned); session switch paints cache ≤300ms in instrumented sim run; blank-screen state impossible (fallback chain test).
- **A8.** Notification live-path: either a real push hits the physical phone (preferred; owner can confirm) or the exact blocker is identified with the fix landed for everything code-side (token registration → notifier → APNs call attempted with real creds, logged) and a one-line owner action documented.
- **A9.** NEW STRUCTURAL GATE: `tests/render_conformance/` (XCTest) — recorded relay frame fixtures (from the E2E harness) replayed through RelayItemStore/ChatStore asserting render-model invariants: user echo present, history preserved during live turn, clarify/approval card produced, taskList → dock, no working-pill state on relay path. Wired into the E2E entry script so wire + render are gated together from now on.
- **A10.** All existing suites still green on the final tree (relay pytest full, conformance 27, e2e gate 11, iOS full build + touched suites). No regression to B15.
- **A11.** Landed on main, build 115 installed on the iPhone Air, relay service healthy, final smoke documented.

## Hard rules (unchanged from daily-driver, binding on every agent)
- NEVER touch the primary tree at /Volumes/MainData/Developer/products/hermes-mobile — worktrees under /Volumes/MainData/Developer/hermes-tmp/worktrees/ only (qa1-base + qa1-<lane>).
- NEVER test against live gateway 9119 (isolated 9130+ w/ temp HERMES_HOME; read-only health curls allowed). The live RELAY service (8788) may be read-health-checked only; deploy phase may restart it.
- iOS builds via scripts/ios-build.sh (machine mutex; SIGTERM never kill-9). Swift 6 strict concurrency clean.
- Composer layout/controls frozen EXCEPT restoring the missing "+" button (B9 is a regression fix, not a redesign). Image rendering untouched.
- All venvs/builds/evidence on /Volumes/MainData. Evidence: /Volumes/MainData/Developer/hermes-tmp/evidence/daily-driver-qa1/.
- No merges to main before the Land phase passes the Opus gates. Small commits, imperative messages. No secrets in evidence.
- Reuse the existing E2E harness (tests/e2e_daily_driver) and conformance fixtures — extend, don't fork.

## Non-goals
HRP/2, co-watch, new features, visual redesigns beyond the ratified Wave-2.5 spec, StraitsLab runtime patches, TestFlight. Direct/plugin-mode gateway crash root-cause (separate Codex track).
