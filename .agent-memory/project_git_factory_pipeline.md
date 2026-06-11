---
name: Git Factory Pipeline Flow
description: Finalized issue lifecycle: Staff → QA → Release → CTO → CEO. Each gate has explicit handoff and evidence requirements.
type: project
originSessionId: 247467c5-73b8-4f37-81f3-a0f202fdaeca
---
Git Factory pipeline (decided 2026-04-16):

**Staff Engineer** (codex_local) → builds, posts evidence (files changed, test results, lint), reassigns to **QA Engineer**
**QA Engineer** (codex_local) → validates, posts "QA Report — PASS/FAIL", reassigns to **Release Engineer**
**Release Engineer** (claude_local) → runs /ship, creates PR, posts PR link + CI status, reassigns to **CTO (Atlas)**
**CTO (Atlas)** (hermes_local) → final technical review (architecture, regressions, clean diff), posts verdict, reassigns to **CEO (Hermes)**
**CEO (Hermes)** → executive acceptance, approves merge, marks goal closure

**Why:** Separates technical sign-off (CTO) from strategic sign-off (CEO). Gives Atlas a real recurring job. Prevents Release from being the terminal gate and CEO from reviewing code.

**How to apply:**
- Release Engineer must NOT mark issues done directly — always hand to CTO
- Release pickup requires QA evidence comment before acting
- CTO FAIL routes back to the appropriate lane (Staff for code fixes, QA for test gaps)
- COO (Kai) audits the whole chain for drift
