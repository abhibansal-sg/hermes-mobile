# OPERATION DAILY-DRIVER QA-2 — Device-QA Round 2 (build 115) Fix Spec

**Date:** 2026-07-21 ~02:45 · **Owner:** Abhinav · **Authorized:** fix all round-2 findings, land, install build 116 on iPhone Air (UDID 1D51F2FB-1DB2-52BF-818B-EFD2ACE7C0E7).
**Repo:** /Volumes/MainData/Developer/products/hermes-mobile · main @ 1fcffe3d5 (QA-1 landing).
**Owner verdict on 115:** "definitely a major improvement… but needs fine-tuning and polishing." Round-2 is polish + the remaining hard bugs. A NEW cross-cutting requirement: **NATIVE iOS UI everywhere** (see C1).

## Evidence
- **48 screenshots**: ~/Downloads/IMG_2529.PNG … IMG_2576.PNG, taken 02:14-02:37 local on 2026-07-21. Owner deliberately timestamped them for reconciliation with backend logs. Relay log: ~/Library/Logs/Hermes/relay.log (APNs attempts at 02:27:46, 02:35:29-30, 02:36:52-53). The image-forensics phase MUST read every image and produce a per-image finding ledger keyed to timestamp.
- Relay push evidence (already gathered): APNs POSTs going out; tokens ...984a0b/...562bcb/...bd6b4a → **400 BadDeviceToken**; tokens 0ac44e7d/0fce4f7f → 200 OK. push_tokens.json has 5 registered tokens, events [approval, clarify, turn_complete]. Phone received NOTHING.

## Cross-cutting criteria (bind every UI lane)
- **C1 NATIVE-FIRST UI:** use native SwiftUI/iOS-26 components (Liquid Glass materials, native sheets, native buttons/capsules, SF Symbols, system spacing) for every interactive element — clarification/approval cards, task pills, dock, sheets. Stop hand-rolling card chrome. Where a custom container is unavoidable it must use system materials + standard corner radii/spacing so it is indistinguishable from native. This is an owner acceptance criterion.
- **C2 COMPACT CHROME:** no element wider than it needs to be; nothing wider than the composer; no dead whitespace bands in the live-turn stack.
- **C3 NO ERROR THEATER:** never surface "not connected" style errors for self-healing/transition states (north star).

## Bug ledger (R1-R16) — each needs root cause + fix + regression test + evidence
- **R1. Notifications broken end-to-end (P0).** Evidence above. Fix BOTH sides: (a) relay push_engine must route per-token APNs environment — dev-signed builds produce SANDBOX tokens → api.sandbox.push.apple.com; production/TestFlight tokens → api.push.apple.com. iOS must report its aps-environment (entitlement introspection or build flag) with the token registration; relay stores env per token and posts to the matching host. (b) Prune dead tokens: on 400 BadDeviceToken/410 Unregistered, evict the token (with log). (c) De-dup: exactly ONE token per device (re-register replaces, keyed by a stable device id), not 5 accumulating. Prove: real push received on the owner's phone from a dev-signed build (sandbox path) in an isolated test; token store converges to 1 entry for the phone.
- **R2. Drawer still imperfect:** sometimes stuck; and the accepted-tap animation "snaps back" before the session opens (open-motion plays reversed). Fix the animation sequencing: tap → drawer dismisses forward INTO the session (no snap-back), session paint begins under it. Pin with UI test if feasible.
- **R3. Session load still not clean** (skeleton hangs, delayed paint). Continue B2/B4 work: cache paint instant, no dead skeleton states.
- **R4. Send does not enter working mode (P0):** after send (esp. short prompts), NO blue streaming cursor, NO stop button; reply just appears later. Once, the big blue Working pill FLASHED <1s (that pill must never appear on relay — QA-1's B8 fix is incomplete: the state that briefly shows it still exists). Required: send → immediate working affordance (streaming cursor bubble) → stop button available for the whole turn → reply streams. The working signal must not depend on the first delta arriving.
- **R5. Working-section collapse missing in live turn (P0 render):** live turn shows "Worked" + a red toolCall line stacked as separate rows. Required (ratified Wave-2.5 rule): during a live turn ONE single collapsed line ("Working… ‹global turn timer›", current tool inline) — tap to expand the bifurcation (thinking + tool timeline). Settled turns: one "Worked for Nm Ns ›" line. The per-item timers visible per row are wrong; the timer is per-TURN.
- **R6. Live-turn stacking has big whitespace gaps** (02:19 photo + several): empty vertical bands between items while streaming. Likely empty item containers/reserved rows. Kill the gaps.
- **R7. Clarification card not native/clean:** looks hacked together; must be rebuilt with native components per C1 (Liquid Glass card, native buttons/list rows, proper text wrapping).
- **R8. Post-answer clarify state unclean:** after answering, large gaps/leftover chrome. The answered card should collapse to a compact settled row.
- **R9. Keyboard handling around clarify (UX):** when a clarification card appears, the keyboard should DISMISS (composer resigns); tapping "type answer" brings the keyboard back. Composer + card + keyboard must never stack to consume the screen.
- **R10. Long clarification text unhandled:** >N chars overflows/clips the card. Native text wrapping + scrollable card body for long questions.
- **R11. Turn control broken during live run (P0):** stop button → error "Not connected to the Hermes gateway"; steer-mode send → same error; queue-mode send → message DISAPPEARED (no outbox pill); pressing stop then showed the pending pill. Root-cause the relay-path turn-control RPCs (interrupt/steer/queue) — they appear to route via the direct-gateway client even in relay mode. Every control action must work over relay; queue must always show in the outbox pill; nothing silently disappears (C3: and no error alerts for transitions).
- **R12. Task pill (dock) wrong (design + behavior):** wider than the composer, huge whitespace, "tasks 0 out of 0" stuck, red stop stuck with no live turn; had to FORCE-CLOSE to regain session control (P0). Fix behavior: pill reflects real task state, clears when the turn ends, stop state cannot wedge; and REDESIGN per owner: task pill matches the pending pill's height/visual language (native capsule), width-to-fit centered — when task + pending pills are both visible they sit side-by-side (task centered next to pending). Never full-width.
- **R13. Task list surface unclean + wrong ownership model:** the task sheet UI needs native polish (C1). Ownership: a taskList belongs to the SESSION/turn that created it (desktop semantics): visible while that session's agent owns it, closed/short-closed by the agent, never randomly reappearing in other contexts. Make dock/task-sheet visibility strictly session-scoped and turn-lifecycle-driven.
- **R14. Outbox tombstone not persisted (P0 data):** owner cleared a queued message from the outbox, force-closed quickly, reopened → the message SENT anyway. The removal must be durably persisted (synchronous tombstone write before UI confirms removal) and honored on relaunch drain. Also initial queue-send didn't show the outbox pill (see R11).
- **R15. Transcript segment goes missing after the stuck episode:** conversation between two messages absent until switching to another session and back (cache reload repaired it). The in-memory merged timeline dropped a segment that the cache still had — find the eviction/merge bug in the QA-1 merged-timeline code and pin it with a render test.
- **R16. Live Activity (lock/home) broken:** timer runs endlessly (not tied to turn end), design rough. Tie Live Activity lifecycle to turn lifecycle (end/complete/error terminates it) and restyle minimal native (progress + session title + elapsed; ends at turn end).

## Acceptance (evidence per item; sim acceptable where device-only impossible, device preferred)
- **A1 (R1):** real APNs push received on the phone (sandbox path from dev build) — token store shows 1 phone token w/ correct env; BadDeviceToken evictions logged.
- **A2 (R4):** render test + sim run: send → working affordance ≤100ms (cursor bubble + stop) independent of first delta; blue Working pill impossible on relay path (state deleted, not just hidden).
- **A3 (R5/R6):** live turn = single collapsed working line w/ per-turn timer, tap expands; no whitespace bands (layout test); settled = one Worked line. Fixtures through render_conformance.
- **A4 (R7-R10):** clarify/approval cards rebuilt on native components; keyboard dismiss/restore behavior; long-text card scrolls; answered card collapses. Screenshot evidence vs the 02:2x images.
- **A5 (R11):** relay-path interrupt/steer/queue all function in isolated E2E (extend phone-driver + e2e scenarios); queue always visible in outbox pill; zero "not connected" alerts in the flow.
- **A6 (R12/R13):** task pill compact/native/centered, coexists with pending pill, reflects live state, cannot wedge (stop clears on turn end even without frames); taskList strictly session-scoped (test: taskList in session A never shows in session B; cleared on agent close).
- **A7 (R14):** outbox removal survives force-close (persistence test kills the process after tombstone); drained sends never resurrect removed items; queue-send always shows the pill.
- **A8 (R15):** regression render test reproducing the drop (from the recorded frame/cache state) then proving the merged timeline never loses cached segments the store still holds.
- **A9 (R16):** Live Activity ends when turn ends (unit/integration test on the activity lifecycle manager).
- **A10:** all existing gates green on final tree (relay pytest, conformance, e2e incl. render_conformance) + iOS build; no QA-1 regressions (the 15 B-bugs stay fixed — spot render tests).
- **A11:** landed on main; build 116 on the iPhone; relay service redeployed if relay changed; final smoke.

## Hard rules (binding, same as QA-1)
- NEVER touch the primary tree; worktrees under /Volumes/MainData/Developer/hermes-tmp/worktrees/ (qa2-base + qa2-<lane>).
- NEVER test against live gateway 9119 (isolated 9130+; read-only health curls OK). Live relay 8788: read-only health/log reads; redeploy only at Land.
- APNs: the sandbox endpoint with the owner's real key/env MAY be used from an isolated relay run for the A1 proof (it targets only the owner's own device token; that is the point). Never spam: max a handful of test pushes.
- iOS builds via scripts/ios-build.sh (mutex, SIGTERM never kill-9; **max 2 concurrent iOS-building lanes — coordinate via lane reports; the mutex starvation of QA-1 must not repeat**). Swift 6 strict clean.
- git stash BANNED (repo-global race across worktrees — QA-1 incident). Temp commits or patch files.
- All artifacts on /Volumes/MainData. Evidence: /Volumes/MainData/Developer/hermes-tmp/evidence/daily-driver-qa2/. No secrets (tokens/keys) in evidence.
- No merges to main before Land passes gates. Small commits.

## Non-goals
New features; HRP/2; direct-mode gateway crash; TestFlight; visual redesign beyond C1/C2 scope + ratified Wave-2.5 rules.
