---
name: project_weave
description: Weave — independent conversational engine (RESONATE-MS + PBR-F). One objective L (DP-CRP-Gaussian = MDL = free-energy). 4 ports; Hermes/GBrain optional adapters. Linear ABH is source of truth.
metadata: 
  node_type: memory
  type: project
  originSessionId: 14214ff0-a256-4254-a041-24d23e131bd1
---

Weave (started 2026-06-08) is now framed as an **independent conversational engine**, NOT a Hermes feature. Core depends only on **4 abstract ports** (Embedding, Runtime, Memory, Model); a reference adapter "Weave-Local" runs the whole engine on **pgvector + any LLM + any embedder** with NO Hermes and NO GBrain. Hermes = optional RuntimePort host; GBrain = optional MemoryPort enrichment.

**Theory:** ONE STATE (prototype tree over embeddings) + TWO RHYTHMS (fast per-utterance `place` = online greedy descent; slow `consolidate` = batch descent) + ONE BELIEF STORE (PBR-F: non-prioritized paraconsistent partial-entrenchment belief revision; retain-both/foreground-one; co-foreground = top antichain; never last-write-wins). Unifying objective **L** = neg-log-joint of a DP/nested-CRP spherical-Gaussian mixture = two-part MDL = variational free energy (coincident via bits-back coding). Fast = online descent on collapsed `L_hard` (= L as σ→0); slow = monotone batch descent on L. Absorb/spawn threshold **derived**: λ = 2σ·log(α/(1+ρ/σ)^{d/2}) (Kulis–Jordan DP-means). Honest verdict: holds in the weak/conditional sense; ~6 constants → ~2 priors (α, ρ/σ) + ~3 heuristics. R5 cross-axis coherence = separate weighted-MaxSAT (NP-hard general, sparse-tractable), outside L. Cosine = the semantic floor, isolated behind EmbeddingPort. PBR-F↔L derivation = open conjecture.

**Source of truth:** Linear project "Weave — Branching Turns for Hermes" (team ABH) — https://linear.app/abhinav-bansal/project/weave-branching-turns-for-hermes-89ee2d8551be . Canonical docs: "Architecture & Theory (v1)" + "Theory & Foundations (v1)"; Kernel/PBR-F/Decision-Log are derivation/pointer views. Issues ABH-117..136: build gate = ABH-134; independent core/ports/reference adapter = ABH-135; theory bulletproofing = ABH-136; PBR-F/R1 = ABH-118; cross-axis R5 = ABH-130.

Confident to build a scoped depth-1 MVP / the Weave-Local reference adapter; full multi-weft vision gated on R5 + calibration evidence. GBrain is the optional warp enrichment — see [[project_openclaw_stack]]. Targets but does NOT depend on the hermes-agent runtime; relates to [[project_hermes_mobile]].
