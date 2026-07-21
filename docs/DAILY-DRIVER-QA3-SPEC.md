# OPERATION DAILY-DRIVER QA-3 — Device-QA Round 3 (build 116) Fix Spec

**Date:** 2026-07-21 ~11:45 · **Owner:** Abhinav · **Authorized:** fix all round-3 findings, land, install build 117 on iPhone Air (UDID 1D51F2FB-1DB2-52BF-818B-EFD2ACE7C0E7).
**Repo:** /Volumes/MainData/Developer/products/hermes-mobile · main @ 893ff52b3 (QA-2 landing).
**Progress signal:** notifications now WORK (owner confirmed; relay log shows sandbox routing 200s to the phone token). Round 3 = ordering/latency/leak correctness + polish.

## Evidence
- **18 screenshots:** ~/Downloads/IMG_2577.PNG … IMG_2594.PNG, taken 10:42–11:30 local 2026-07-21, owner dictation in old→new order (ledger below maps it).
- Relay log ~/Library/Logs/Hermes/relay.log: push.register at 10:36:35 (x2); APNs fan-outs at 10:46:25 and 10:49:04 — NOTE each fan-out posts to THREE tokens: 2 stale production (…cb1f27, …920549) + 1 sandbox (…bd6b4a = the phone). Dedup/eviction incomplete (S13).
- The owner's session activity ~09:00-11:30 today is the reconciliation window.

## Bug ledger (S1-S13) — each needs root cause + fix + regression test + evidence
- **S1. Cursor not breathing + layout gap:** the blue streaming cursor is static — it must pulse/breathe softly (the approved StreamingCursor spec: theme-bound, soft opacity breathing). Also too much vertical gap between project-name/CWD row and the composer.
- **S2. Working affordance latency (P0):** "working" appeared ~35s after send. QA-2's A2 required the affordance ≤100ms driven by LOCAL send state, not server frames — either that fix regressed, didn't cover this path, or the affordance is gated on a relay frame that arrives late. Root-cause the actual trigger chain on device (submit → outbox → relay ack → turnStarted) and make the affordance appear on SEND (local), with the turn timer starting locally and reconciling later.
- **S3. ONE working affordance, not two (design):** owner: the pulsing cursor IS the working signal — it pulses, types the status word ("working"), keeps pulsing. NO separate spinner line + timer row above it. Merge the collapsed-working-line concept INTO the cursor line: single line = breathing cursor + inline status + per-turn timer, tap to expand bifurcation. Delete the second affordance.
- **S4. Message ordering wrong in live merge (P0):** answer rendered ABOVE the user's message that prompted it (user msg appeared after the answer; scroll-up showed it also duplicated/positioned at top correctly — i.e. ordering inconsistent within one view). Session switch away+back fixed it (cache order correct, live merged order wrong). Root-cause the merged-timeline ORDERING (relay item ordering vs optimistic echo insertion point vs stable sort key). The timeline must be strictly chronological and stable across live/cache reconcile.
- **S5. Unknown error code shown on send in another session:** an error code/toast surfaced (see forensics for exact text). Identify origin (relay? gateway? iOS?), map to condition, and either fix the condition or handle silently if self-healing (C3 rule). No raw error codes to the user.
- **S6. Sent prompt vanished in second session (P0):** message sent in session B → nothing happened; returning later showed only "working tool call" rows, the user prompt missing, sequencing wrong. Same family as S4 + echo persistence — the optimistic echo must be durable (survive session switch + store rebuild) until reconciled.
- **S7. Blank space on scroll-up (still):** scrolling up hit pure blank space. Windowing/lazy-load or item-height estimation bug in the merged timeline. Must be impossible: content or skeleton, never void (QA-1 B4 rule extended to scrollback).
- **S8. Turn never completed, no response ever (P0):** the "??" session showed working for previous AND current turn, nothing ever arrived; no error, no recovery. Reconcile with relay/gateway logs at that timestamp — did the gateway turn die, did the relay lose the sub, or did iOS stop consuming? The turn state machine needs a liveness fallback: no frames + no completion within a window → resync snapshot from relay/cache (self-healing, silent), never an eternal double-working.
- **S9. Drawer stuck after tap (still, 3rd round):** QA-2's dismiss-forward didn't hold. Find the real race this time with a UI test that reproduces it (tap during in-flight session load). This is now a recurring-regression — pin it structurally.
- **S10. Projects broken (P0 feature):** projects list/detail — sessions don't load inside a project. Was working post-#224/#227; find what QA-1/QA-2 broke (likely the session-list source or auth fallback path) and restore, with a test.
- **S11. Cross-session leak into new chat (P0):** owner tapped New Chat, was typing, and another session's working/tool-call rows appeared in the new-chat view. The chat view is showing items from a previous/other session — store not reset/scoped on new-chat entry (session-id nil path). Related to QA-2 R13 scoping but on the chat surface. Must be impossible: a new chat renders ONLY its own (empty) timeline.
- **S12. Notification deep-link wrong:** tapping a notification opens the Inbox, not the session it belongs to. The push payload has the session id (relay composes it) — iOS notification-tap routing must deep-link to that session's chat view.
- **S13. Push fan-out still hits 3 tokens (2 stale production):** relay log 10:46/10:49 posts to …cb1f27 + …920549 (production, stale) + …bd6b4a (sandbox, real). The QA-2 dedup keyed on device_id — the stale entries have device_id:null so they survived and Apple 200s them into the void. Migration: on any successful device_id-keyed registration, evict ALL null-device_id entries (or age them out); registry should converge to exactly 1 entry for the phone. Verify iOS actually sends device_id now (if not, that's the iOS-side bug to fix).

## Cross-cutting (carried from QA-2, still binding)
- **C1 native-first UI · C2 compact chrome · C3 no error theater** (S5 falls under C3).
- Chronology invariant (new, from S4/S6/S7): the rendered timeline is a stable chronological merge; no item ever renders out of order, disappears, or leaves void gaps — extend tests/render_conformance with ordering + persistence invariants replayed from THIS round's recorded sequences.

## Acceptance (evidence per item)
- **A1 (S2/S3):** send → single breathing-cursor working line (inline status + per-turn timer) ≤100ms, local-state-driven (test: affordance present with relay frames artificially delayed 10s); no second spinner line exists in code.
- **A2 (S4/S6):** render tests from recorded sequences: strict chronological order live and after reconcile; echo durable across session switch; no case where answer precedes its prompt.
- **A3 (S7):** scrollback never shows void (windowing test with tall histories).
- **A4 (S8):** liveness fallback: simulated dead turn (no frames, no completion) → silent resync within N s → correct settled state; eternal-working impossible (state-machine test).
- **A5 (S9):** UI test tap-during-load; drawer always dismisses into the session.
- **A6 (S10):** projects E2E: project list → project sessions load → open session (isolated gateway test + iOS test).
- **A7 (S11):** new-chat isolation test: with another session mid-turn, new chat shows empty timeline only.
- **A8 (S12):** notification tap deep-links to the owning session (routing unit test + manual device proof).
- **A9 (S13):** after a fresh 117 registration, registry = exactly 1 phone entry (sandbox, non-null device_id); stale null-id entries evicted; fan-out posts to 1 token. iOS sends device_id (fix if absent).
- **A10:** S1 cursor breathes (animation spec'd + implemented; screenshot/video evidence) + composer gap tightened.
- **A11:** all gates green on final tree (relay pytest, conformance, run_gate incl render_conformance w/ NEW ordering invariants); no QA-1/QA-2 regressions.
- **A12:** landed on main; build 117 installed on iPhone; relay redeployed if changed; smoke + one live push.

## Hard rules (unchanged, binding)
- NEVER touch the primary tree; worktrees under /Volumes/MainData/Developer/hermes-tmp/worktrees/ (qa3-base + qa3-<lane>).
- NEVER test against live gateway 9119 (isolated 9130+; read-only health/log reads OK). Live relay 8788 read-only; redeploy only at Land. Bounded sandbox APNs test sends to the owner's own token allowed for A9/A12.
- iOS builds via scripts/ios-build.sh (mutex, SIGTERM never kill-9, MAX 2 concurrent iOS lanes building; back off 5-10 min when busy).
- git stash BANNED. Temp commits or patch files. Swift 6 strict clean. All artifacts on /Volumes/MainData; evidence: /Volumes/MainData/Developer/hermes-tmp/evidence/daily-driver-qa3/. No secrets in evidence. No merges to main before Land. Small commits.
- Reuse/extend tests/e2e_daily_driver, tests/conformance, tests/render_conformance — never fork.

## Non-goals
New features; HRP/2; direct-mode crash root-cause; TestFlight; redesigns beyond the ratified rules + this ledger.
