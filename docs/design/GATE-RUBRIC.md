# Hermes Mobile — Design Gate Rubric

Status: v1 (STR-308). The checklist the **designer seat** applies when gating any
UI-touching PR. Every verdict cites a section here or in `DESIGN.md` /
`DESIGN-SYSTEM.md` — **never bare taste.** If a finding can't cite a spec
section, either the spec is missing a rule (patch it) or the finding is a
preference (state it as advisory, not a block).

## How to use this

1. The gate runs on **UI-touching PRs** — new screens, changed layouts, new
   components, theme/chrome edits. Not on pure logic/networking diffs.
2. Severity follows the **HUMAN path, not the accessibility tree.** A control the
   a11y tree lists but the human can't see or reach is broken (PERCEPTION-QA
   §3d). Verify on the actual screenshot/recording, iPhone AND iPad.
3. Score each dimension **PASS / BLOCK / ADVISORY**. Any BLOCK holds the merge.
   ADVISORY is logged, not blocking.
4. Cite the evidence: `<screenshot/recording path>` + the rule id (e.g.
   `[R3 one-accent]`, `[DESIGN §Shapes]`, `[DS §4 native-first]`).
5. Ledger the verdict (team-management): one entry per gated PR in
   `team-ledgers/<seat>.jsonl`.

## The rubric — 9 dimensions

Each dimension: what to check, the citable rule, and the instant-BLOCK line.

### R1 — Token fidelity (color)
- Every chrome/content color reaches the view through a `HermesTheme` role, not
  a literal hex.
- The screen is verified in **all six themes** + light/dark for `nous`.
- Status colors (`statusOK/Warn/Error`) used for state only, never decoration.
- **Sanctioned raw-color exception:** semantic syntax-highlight and ANSI terminal
  palettes (`SyntaxHighlighter.swift`, `AnsiText.swift`) carry raw literals by
  necessity — a language token / ANSI code maps to a fixed color, not a theme
  role. These are allowed; a raw hex on *chrome or a themed content surface* is
  not.
- Cite: `DESIGN §Colors`, `DS §2`.
- **BLOCK:** a hardcoded hex on chrome or a themed surface; a surface that only
  resolves correctly in one theme; a decorative use of a status color. **Not a
  block:** raw colors inside the syntax/ANSI palettes.

### R2 — Type discipline
- Text uses semantic Dynamic Type styles (`.body`, `.footnote`, …) **or**
  `@ScaledMetric(relativeTo:)`-backed sizing. A **fixed** `.system(size: N)` on
  text is the defect — not the act of naming a size, but naming one that won't
  scale. Glyph/icon sizing via `@ScaledMetric` is the house pattern and passes.
- Serif (New York) confined to the three brand slots: wordmark, greeting,
  assistant prose. Everything else SF Pro.
- ≤3 weights (regular / semibold / bold-for-CTA-and-greeting).
- No clip/overlap at accessibility text sizes (test `.accessibility1`+).
- Cite: `DESIGN §Typography`, `DS §6`.
- **BLOCK:** a fixed-literal `.system(size:)` on text (no `@ScaledMetric`, not a
  decorative glyph); serif leaking into a control/label; text clipping at large
  Dynamic Type. **Not a block:** `@ScaledMetric(relativeTo:)` glyph/field sizing.

### R3 — One accent
- A single accent (`midground`) carries identity. No second saturated hue.
- A status/attribution chip must **not** read like a primary CTA.
- Exactly one primary (high-emphasis) action per screen.
- Cite: `DESIGN §Colors (tertiary=primary)`, `DESIGN §Don'ts`, `DS §1 clause 3`.
- **BLOCK:** a second competing accent; a status chip styled as a filled CTA
  (the "Driven by Claude Code" pill is the reference defect); two primary
  buttons fighting on one screen.

### R4 — Native-first / glass discipline
- A system component is used where one exists (`.toolbar`, `List`, `Form`,
  `.glassEffect`, `.buttonStyle(.glass/.glassProminent)`). Custom chrome only on
  the three sanctioned surfaces (drawer mechanics, composer layout, transcript
  rendering).
- Chrome glass is **untinted**, clipped to a concrete shape, via the shared
  `.chromePill(_:in:)` modifier.
- Content is never glassed; chrome is never painted with a hand-rolled shadow
  (except the one sanctioned 17–25 fallback).
- iOS 26 path AND 17–25 fallback both present and correct.
- Cite: `DS §4` (adoption map), `DESIGN §Elevation`, `CONTRACT-UI-I`.
- **BLOCK:** hand-rolled chrome that a system component covers; tinted chrome
  glass; a new drop-shadow literal; a missing 17–25 fallback on gated 26 API;
  content surface wrapped in glass.

### R5 — Spacing & alignment (grid)
- Spacing snaps to the 8-derived scale (`hair/xs/sm/md/base/lg/xl/xxl`). No
  off-grid literals (`5/7/9/20`).
- One 16pt (`base`) screen-margin rail; icons, labels, rows align to it.
- Radii snap to `sm/md/lg/xl/capsule`; no `10/14`. Nested corners concentric.
- Cite: `DESIGN §Layout`, `DESIGN §Shapes`, `DS §6`.
- **BLOCK:** off-grid spacing/radius introduced by the PR; rows anchoring to
  different left rails (the drawer session-row-vs-nav-row defect).

### R6 — Touch & reachability (size-class truth)
- Every tappable target ≥44×44pt, even with a smaller glyph.
- iPhone (compact) AND iPad (regular) both evaluated as their own layout.
- No z-index/tap crowding at seams (e.g. drawer "New chat" over the peeking
  composer).
- The a11y tree's controls are **visible and human-reachable** on the pixels.
- Cite: `DESIGN §Layout (44pt)`, `DS §3/§6`, `PERCEPTION-QA §3c/d`.
- **BLOCK:** a <44pt tap target; a control present in the tree but not reachable
  on screen; an iPad layout that's just the iPhone one stretched.

### R7 — State completeness
- Empty / loading / error / offline all handled per `DS §5`.
- Empty state: glyph → serif headline → sans sub-copy → one CTA → one secondary
  path; copy references only on-screen UI.
- Loading resolves or fails (no forever-skeleton).
- Errors are actionable + specific + recoverable (Retry), never a silent stall.
- Cite: `DS §5`, `PERCEPTION-QA §3a`, `VISION.md`.
- **BLOCK:** a loading state that can hang unresolved; a raw exception shown to
  the user; an error with no recovery affordance; empty-state copy citing
  off-screen UI.

### R8 — Motion & performance
- Curves from the sanctioned set (`.snappy/.easeInOut/.spring`); gesture motion
  interruptible and finger-tracking.
- Reduce Motion honored (cross-fade/cut, not translate/scale).
- No frame hitches on streaming/scroll surfaces: 60fps sim budget 16.7ms/frame;
  33ms+ (a dropped frame) is a defect; device lane (8.3ms @120Hz) for flagship
  flows pre-ship.
- Cite: `DS §7`, `PERCEPTION-QA §1/§2`.
- **BLOCK:** a new animation curve without reason; Reduce Motion ignored; a
  measured hitch (per frame-forensics) on a scroll/stream surface.

### R9 — Craft zoom-in (the Ive lens)
- Details survive magnification: spacing rhythm even, motion curves land,
  state transitions clean, no double-render/collision/placeholder-leak
  (PERCEPTION-QA §3).
- Nothing feels assembled-not-designed; no decoration hiding structural
  confusion.
- Cite: `DS §6/§7`, crucible IVE lens.
- **ADVISORY by default; BLOCK** only when the defect is a *visible* break
  (overlap, collision, leaked placeholder, jitter a human sees) — taste-only
  polish is advisory and routed to a follow-up, never a hard block.

## Verdict template (paste into the PR review)

```
DESIGN GATE — <PR title> — <iPhone+iPad evidence path>
R1 token         PASS | BLOCK | ADVISORY  — <cite + note>
R2 type          ...
R3 one-accent    ...
R4 native/glass  ...
R5 grid          ...
R6 touch/size    ...
R7 state         ...
R8 motion/perf   ...
R9 craft         ...
VERDICT: APPROVE | REQUEST CHANGES (blocks: R#, R#)
Cited spec: DESIGN §…, DS §…
```

## What is NOT a gate block

- A taste preference with no spec citation → state as advisory or patch the spec
  first, then cite it.
- A pre-existing defect the PR doesn't touch → file separately, don't block the
  PR for it.
- A deliberate, documented exception (e.g. the three sanctioned custom surfaces)
  → not a native-first violation.
- Anything on a **non-UI** diff → the gate doesn't run.

## Spec maintenance

When a gate finding recurs and the spec has no rule for it, **patch the spec**
(add the rule to `DESIGN.md`/`DESIGN-SYSTEM.md`, then reference it here) rather
than re-litigating taste each PR. The rubric is a living contract; a finding you
can't cite is a gap in the spec, not license to block on vibes.
