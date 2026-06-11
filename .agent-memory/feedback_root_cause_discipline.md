---
name: root-cause-discipline
description: "Engineering discipline (user, 2026-06-08): never surface-tweak. Trace the full hierarchy root→symptom, fix where the cause actually lives, verify with hard evidence — don't run in circles."
metadata: 
  node_type: memory
  type: feedback
  originSessionId: c6271256-6b41-4b30-a2e2-057a9325db34
---

User directive (2026-06-08, reaffirmed): "Don't try to tweak things at the surface. Always understand the entire hierarchy from root to that point so we don't end up running in circles like we did fixing the chat transcript canvas."

**The rule:** when a symptom appears at point X, do NOT adjust X reflexively. Trace the full chain — for UI: window → root view → container/shell → the view; for data: gateway/wire → store → model → render — and locate where the cause ACTUALLY lives. Fix it there. The cause is often several layers ABOVE or BELOW the symptom.

**Why (the canvas saga, the cautionary tale):** the full-bleed "white strip" bug took ~5 rounds because early fixes tweaked the transcript's OWN ignoresSafeArea/fade (the symptom's location). The real causes were higher in the hierarchy: (1) iOS-26 nav-bar glass platter, (2) the push-card container letterboxing, (3) the NavigationStack reserving its hidden bar's safe-area inset. Only a root→symptom LAYER AUDIT (window→RootView→card→NavigationStack→ScrollView) found it. Same pattern with the 30-default fill (root cause was concurrent-refresh token-abort, not the loop) and the scroll-on-open (root cause was a timer racing layout, fixed by a deterministic native anchor — not more timer tuning).

**Two companion rules learned the same way:**
1. VERIFY WITH HARD EVIDENCE, not impressions. Pixel-sample screenshots (the eyeball misread small screenshots and wrongly declared full-bleed fixed). Read logs/payloads. "Intermittent / sometimes works" == a race == wrong approach, not wrong tuning — make it correct BY CONSTRUCTION (deterministic), never by timing luck.
2. This applies even under velocity-max ([[velocity-model]]): go FAST but go DEEP — speed comes from parallelism + skipping the slow test suite, NOT from shallow patches. Depth of understanding is non-negotiable; cutting corners is not the same as moving fast.

**How to apply:** for any non-trivial fix, the builder/investigator brief must require reading the full hierarchy around the symptom first and stating the actual root cause before patching. For bugs, prefer a forensics pass (read-only root-cause) before the fix. Reject "tweak the symptom" solutions in gate review.
