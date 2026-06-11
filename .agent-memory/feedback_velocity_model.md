---
name: velocity-model
description: "Tiered dev-velocity model for Hermes Mobile (user-approved 2026-06-07): feel-tweaks inline, feature work fast-mode (no full gate), hardening gate only at checkpoints. Core engine always gated."
metadata: 
  node_type: memory
  type: feedback
  originSessionId: c6271256-6b41-4b30-a2e2-057a9325db34
---

User wants high-speed development now, finetuning/bugfix in a dedicated pass after — NOT a full gate per change. Tiered model:

- **Tier 0 — feel tweaks** (spacing, color, copy, fades): edit → build-to-sim → screenshot → commit. No tests, no gate.
- **Tier 1 — feature / multi-file (FAST MODE, default during a build sprint):** compile + quick targeted sim check → commit directly. NO full gate, NO full 490-suite. Integration bugs are accepted and caught later (user validates on-device + the hardening checkpoint).
- **Tier 2 — hardening checkpoint** (end of sprint / before a milestone phone build): ONE full gate — whole suite + adversarial review + regression sweep across everything accumulated. Correctness enforced once, batched, not per-change.

**Guardrail (non-negotiable):** anything touching the CORE ENGINE — ChatStore, the transcript model (ChatModels), ConnectionStore/ownership machinery — STILL gets a full gate even in fast mode. A silent regression there is catastrophic and hard to trace. Views/panels/settings go fast-mode.

**Speed cuts (always):** drop the redundant Release-*sim* build (only the device build needs Release); build-to-device only at checkpoints, not every change; run test suite + sim-verify concurrently, not serially; reuse derivedData (incremental, not clean builds); keep a warm sim.

**Why:** the full suite is only ~3 min of a ~20-min gate — the real bottleneck is 3 sequential compiles + serial sim verification. So speed comes from cutting compiles/serialization, not from skipping tests. See [[model-tiering-policy]] (which model runs each node) — this is the orthogonal "how heavy a gate" axis.

**How to apply:** during the Levels 06-12 feature walk, default to Tier 1. Reserve Tier 2 gates for core-engine batches (e.g. transcript Batch E) and pre-phone-milestone checkpoints.

**SPRINT-MODE AMENDMENT (user, 2026-06-08 — velocity-max):** "Prioritize speed of build-out. Spin out as many sub-agents/workflows as needed (100/200/300, whatever) on whatever models fit, to maximize output — NOT at the cost of quality. Defer the test suite (esp. the slow UI test suite / full xctest run) toward the END. Right now: push code → build app → I QA on my phone with you." So during this sprint: builders compile-check only (fast, catches breakage); integrators apply + ONE whole-app compile + commit, NO full xctest run; ship TestFlight; the USER's device walk is the verification. The full 561-test + UI suite becomes a single hardening gate near public release, not per-change. Fan out maximally with disjoint-file batches + one integrator per wave to serialize commits. Offline-first local cache = the LAST feature before public release (not now)."
