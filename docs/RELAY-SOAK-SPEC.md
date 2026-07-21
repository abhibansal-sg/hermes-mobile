# RELAY SOAK-HARDENING SPEC — desktop-only relay torture track

**Date:** 2026-07-21 · **Owner:** Abhinav · **Goal:** prove the relay (relay/hermes_relay) is correct and durable under sustained hostile conditions — pure desktop, no simulator, no iOS. Output: either "relay holds every invariant for hours under torture" or a precise defect list with reproducers.
**Repo:** /Volumes/MainData/Developer/products/hermes-mobile. Test target: the relay at origin/main (QA-2 tip 893ff52b3 now; RE-RUN against the QA-3 tip when it lands — the harness must take the relay source path as a parameter).
**Context:** relay wire behavior is well-tested at the scenario level (pytest ~197, conformance 27, e2e 13). What is NOT proven: long-horizon durability, hostile interleavings, resource behavior over hours. Suspect classes from device QA: S8-like dead turns (lost gateway sub?), reconnect edge cases, seq/replay-ring boundary conditions, owned-session lifecycle leaks.

## Invariants (the contract — every scenario asserts all that apply)
- **I1 No lost turn:** every submitted turn reaches a terminal state (completed/error) visible to the phone-driver; no eternal-working.
- **I2 Byte-identical reconcile:** transcript reconstructed after ANY disruption == undisrupted reference run.
- **I3 No dropped subscription:** relay's gateway sub survives gateway restarts/slowness; frames resume gap-free (seq contiguity per session).
- **I4 Echo/dedup:** duplicate submits (same client_message_id) never create a second turn; replayed frames never double-apply.
- **I5 Owned-session lifecycle:** owned sessions persist across relay restarts, re-resume correctly, and are cleanly releasable; no zombie sessions accumulating.
- **I6 Resource bounds:** RSS, FD count, and replay-ring size bounded over hours; no monotonic growth (leak detection with thresholds).
- **I7 Notify correctness:** notification decisions (fire/suppress per foreground state) correct under rapid foreground flapping; no notify for dead/evicted tokens (mock APNs).
- **I8 Protocol robustness:** malformed/fuzzed downstream frames never crash the relay; unknown methods get clean errors; oversized payloads bounded.

## Torture scenarios (tests/relay_soak/, each parameterized by duration + seed)
- T1 connect churn: phone-driver connects/disconnects at randomized 0.1-5s intervals for N min while turns stream (I1/I2/I3).
- T2 foreground flap storm: rapid foreground/background transitions mid-turn (I7 + reconnect single-flight).
- T3 multi-session interleave: 5-10 concurrent sessions streaming, random switching, submits into each (I1/I2/I4 per session).
- T4 kill loop: kill -TERM the relay every 30-120s (randomized) for an hour under live turns; durable re-resume each time (I5/I2).
- T5 gateway abuse: isolated gateway restarted / paused (SIGSTOP-SIGCONT) / made slow while relay serves (I3/I1 — this is the S8 class).
- T6 fuzz: property-based (hypothesis) fuzzing of downstream frames + upstream gateway event mutations (I8).
- T7 marathon: the full mix at low intensity for 4+ hours; resource sampling every 30s (I6).
- T8 replay-ring boundaries: ack storms, ancient-cursor resubscribes, ring overflow (I2/I4).

## Deliverables
1. tests/relay_soak/ harness (isolated gateway launcher on ports 9140+, temp HERMES_HOME, synthetic phone-driver extensions, invariant checker library, resource sampler) — committed on branch soak/relay off main.
2. Soak run vs origin/main relay: full report per scenario (pass/fail per invariant, defects with minimal reproducers, resource curves).
3. Fixes for defects found (small, surgical, on the soak branch, each with the reproducer as its regression test) — defects that overlap QA-3's in-flight work get REPORTED not fixed (avoid collision; hand to the coordinator).
4. Re-run entry point: one script that re-soaks any given relay source tree (for the QA-3 tip re-run and future CI).

## Hard rules (binding)
- NEVER touch the primary tree; worktree /Volumes/MainData/Developer/hermes-tmp/worktrees/soak-relay (branch soak/relay).
- NEVER touch live gateway 9119 or live relay 8788 (not even health curls — this track has zero business with live services). Isolated gateways on 9140-9160 with temp HERMES_HOME under the evidence dir.
- Ports 9130-9139 are reserved for QA-3 lanes — do not use.
- No iOS builds at all (do not touch the build mutex). Python via /opt/homebrew/bin/python3.13 venvs on /Volumes/MainData.
- git stash BANNED. Evidence: /Volumes/MainData/Developer/hermes-tmp/evidence/relay-soak/. No secrets. Mock APNs only — zero real APNs traffic from this track.
- Total CPU discipline: the QA-3 swarm is running — cap concurrent soak scenarios so load average stays sane (nice the marathon).
