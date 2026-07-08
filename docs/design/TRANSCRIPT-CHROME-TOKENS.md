---
version: alpha
name: Transcript Chrome Tokens
description: Motion + box tokens for clean transcript chrome — the single source T-2/T-3/T-4 compile against.
extends: DESIGN.md, DESIGN-SYSTEM.md
issue: STR-1002 (parent STR-989 TRANSCRIPT DESIGN)
motion:
  pulse-glow:
    period: 1.8s
    easing: easeInOut
    direction: alternate
    opacity-min: 0.55
    opacity-max: 1.0
    reduce-motion: static-at-max
  status-glow:
    color: "{colors.primary}"          # midground / Nous blue #0053FD
    rest-alpha: 0.55
    ring-radius: 1pt
    ring-alpha-min: 0.06
    ring-alpha-max: 0.12
    lift-radius-min: 8pt
    lift-radius-max: 32pt
    lift-alpha-min: 0.05
    lift-alpha-max: 0.10
    settle-in: 180ms
    settle-easing: easeOut
    reduce-motion: static-at-mid
  fade-mask:
    edge: top
    height-compact: 28pt
    height-regular: 36pt
    stops: [ [clear, 0.0], [opaque, 0.16], [opaque, 1.0] ]
box:
  mono-font: "{typography.code}"        # SF Mono, 14pt (DESIGN.md role) — no new number
  mono-body-ratio: 0.82                 # 14pt mono / 17pt body — STRICTLY smaller
  line-height: 1.45
  corner-radius: "{rounded.md}"         # 12pt, .circular (perf — DESIGN §Shapes)
  border: "{colors.hairline}"           # 1pt, theme.border
  background: codeBg
  pad-x-compact: 12pt
  pad-y-compact: 10pt
  pad-x-regular: 14pt
  pad-y-regular: 12pt
  inline-pad-x: 10pt
  inline-pad-y: 7pt
  copy-affordance: top-trailing
diff:
  add-fill-alpha: 0.12
  add-gutter: "{colors.success}"        # #34C759, 2pt left accent
  remove-fill-alpha: 0.12
  remove-gutter: "{colors.danger}"      # #C72E4D, 2pt left accent
  gutter-width: 2pt
  strip-markers: true                   # no +/- gutter chars; color carries meaning
  nesting: forbidden                    # inline over boxed-in-a-box
thinking:
  label-collapsed: "Thinking"
  label-streaming: "Thinking…"
  label-settled: "Thought for {n}s"
  glyph: none                           # NO brain emoji, NO systemImage
  faces-stripped: true
---

# Transcript Chrome Tokens

Motion + box design tokens for the STR-989 clean-chrome cluster. This document is
the **single token source of truth** the three build work-units compile against —
**T-2** (live thinking window), **T-3** (content boxes: terminal / code / diff /
copyable), **T-4** (status indicator, desktop-parity inline glow). It **extends**
STR-308 (`DESIGN.md` normative tokens + `DESIGN-SYSTEM.md` doctrine); it does not
restate them. Where a value already lives in `DESIGN.md`, this doc **references
the role**, never re-declares a hex.

It does **not** redesign shipped surfaces. It sets the values the three
clean-chrome WUs must all read so three implementations don't fork against
ad-hoc numbers. Every token below has a concrete value and, where parity with the
desktop app is claimed, names the exact desktop source file + line so build has a
target.

## When to use

Load this before building **any** STR-989 transcript-chrome WU, and cite it in
every gate review of one. The three consumers:

- **T-2** — live "thinking" streaming window (fade-mask + pulse-glow + thinking label).
- **T-3** — content boxes: the one "diff-render look" reused across terminal /
  code / diff / copyable (box tokens + diff tokens).
- **T-4** — status indicator with the desktop-parity inline blue elapsed glow
  (status-glow + thinking label collapse line).

## Prerequisites

- `DESIGN.md` (token roles: `colors.*`, `typography.*`, `spacing.*`, `rounded.*`).
- `DESIGN-SYSTEM.md` §7 Motion (the three sanctioned curves), §6 Density.
- Theme role names resolve in `apps/ios/HermesMobile/Theme/HermesThemeModel.swift`
  (`midground`, `codeBg`, `mutedFg`, `muted`, `border`, `statusOK`, `statusError`).

## Law inheritance

- **Glass for chrome, themes for content** (DS §1). Every surface here is
  **content** — transcript-plane, never glassed. No `glassEffect`, no material.
- **One accent** (`midground`, DS §1 clause 3). The status glow is the ONE place
  the blue may bloom; it never becomes a second saturated hue.
- **Semantic Dynamic Type** (DESIGN §Typography). Point sizes below are the
  Large-baseline reference; every text style binds a **semantic font** so it
  scales. **Do not fork point sizes per size class** — size-class variance is
  expressed in **padding/spacing**, not in frozen font points.
- **Reduce Motion is honored** on every motion token (DS §7). Each token names
  its static fallback.

---

## 1. Motion tokens

### 1.1 Pulse-glow — the active-step "alive" breath (T-2, T-4)

The active/streaming row breathes so it reads **alive, not spinning**. This is the
canonical "work is happening here" signal. **No spinner, ever** — a rotating
`ProgressView` is banned on any streaming transcript row (it reads as "stuck";
DS §5 loading). The one exception already in the tree — `ToolActivityRow`'s
per-tool `.running` state icon — is a discrete per-call status glyph, not a
transcript-level activity signal, and is out of this cluster's scope.

| token | value | notes |
|-------|-------|-------|
| `pulse.period` | **1.8s** | one full min→max→min breath. Parity: desktop `code-card-stream-glow 1.8s` (`apps/desktop/src/styles.css:1252`) and `quest-glow 1.8s` (`:628`). |
| `pulse.easing` | **`.easeInOut`** | DS §7 secondary curve. Never linear (reads mechanical). |
| `pulse.direction` | **alternate** | ease up then back down; no hard reset snap. |
| `pulse.opacityMin` | **0.55** | resting alpha. Matches the desktop live-signal cluster rest (`text-midground/55`, `activity-timer-text.tsx:17`). |
| `pulse.opacityMax` | **1.0** | peak — full-strength, not blown out. |
| `pulse.property` | **opacity + brightness** | breathe alpha; a subtle `brightness(1.0→1.06)` may ride along. Never scale/translate (that's motion-for-motion, DS §7). |
| `pulse.reduceMotion` | **static at `opacityMax`** | Reduce Motion → hold at full opacity, no animation (mirrors desktop `prefers-reduced-motion` → `animation: none`, `styles.css:1566`). |

SwiftUI shape: a repeating `.easeInOut(duration: 1.8).repeatForever(autoreverses: true)`
driving an `opacity` (and optional `brightness`) modifier, gated on
`@Environment(\.accessibilityReduceMotion)` → hold `opacityMax`.

### 1.2 Status glow — the inline blue elapsed treatment (T-4, desktop parity)

The elapsed-time / active-status affordance carries a **soft blue glow** so it
reads as part of the same live-signal cluster as the pulse — **desktop's exact
treatment, ported**. Reference chain, extract verbatim:

- **Color + rest alpha:** `--dt-midground` at 55% — `text-midground/55`
  (`apps/desktop/src/components/chat/activity-timer-text.tsx:17`). iOS role:
  **`theme.midground` @ 0.55**.
- **Glow ring + lift:** the desktop `code-card-stream-glow` keyframe
  (`apps/desktop/src/styles.css:1550–1564`). It rides the `--dt-ring` accent as a
  two-part shadow: an inner **ring** (`0 0 0 1px`) and an outer **lift**
  (`0 0.5rem 1.5rem` → `0 0.75rem 2rem`), both breathing in alpha.

| token | value | desktop source |
|-------|-------|----------------|
| `statusGlow.color` | **`theme.midground`** (Nous blue `#0053FD` on nous-light) | `--dt-midground` |
| `statusGlow.restAlpha` | **0.55** | `text-midground/55` |
| `statusGlow.ringRadius` | **1pt** (`0 0 0 1pt`) | `0 0 0 0.0625rem` |
| `statusGlow.ringAlphaMin` | **0.06** | `--dt-ring 6%` |
| `statusGlow.ringAlphaMax` | **0.12** | `--dt-ring 12%` |
| `statusGlow.liftRadiusMin` | **8pt** blur, **0** spread | `0 0.5rem 1.5rem` |
| `statusGlow.liftRadiusMax` | **32pt** blur | `0 0.75rem 2rem` |
| `statusGlow.liftAlphaMin` | **0.05** | `--dt-ring 5%` |
| `statusGlow.liftAlphaMax` | **0.10** | `--dt-ring 10%` |
| `statusGlow.appear` | **180ms `.easeOut`** settle-in | `180ms` delay on the desktop glow start |
| `statusGlow.breathe` | reuses **§1.1 pulse** (1.8s, alternate) | `code-card-stream-glow 1.8s … alternate` |
| `statusGlow.reduceMotion` | **static at mid** (ring 0.09, lift 0.075) — no breathe | `styles.css:1566` |

Typography of the elapsed string itself (T-4): **monospaced, `tabular-nums`,
`.caption2`-scale, `midground @ 0.55`, tracking `0.02em`** — parity with
`activity-timer-text.tsx:17` (`font-mono text-[0.56rem] tracking-[0.02em]
tabular-nums`). `tabular-nums` is **mandatory** so the seconds counter doesn't
reflow width as it ticks.

### 1.3 Fade-to-dark gradient mask — the live thinking window (T-2)

The live streaming-thinking window is height-bounded; older lines **fade out at
the top edge** while new tokens settle in from the bottom. This is desktop's
`thinking-preview` behavior (bottom-pinned scroll + top mask,
`message-parts.tsx:78–89`) and the pattern already proven in iOS's own
`ToolClusterView.boundedLiveToolWindow` (`ToolActivityRow.swift:103–113`).

| token | value | notes |
|-------|-------|-------|
| `fadeMask.edge` | **top** | fade the top; the newest line at the bottom is always fully opaque. |
| `fadeMask.stops` | **`[(.clear, 0.0), (.black, 0.16), (.black, 1.0)]`** | exact parity with the shipped iOS bounded-window mask (`ToolActivityRow.swift:104–112`). The 0.16 knee = the fade zone is the **top 16%** of the window. |
| `fadeMask.height` (compact) | **28pt** fade zone above a **~172pt** window | window height parity with `liveToolWindowHeight = 172` (`ToolActivityRow.swift:27`). |
| `fadeMask.height` (regular) | **36pt** | iPad affords a slightly taller fade so the taller window's top dissolve stays proportional. |
| `fadeMask.reduceMotion` | **unaffected** | a gradient mask is static geometry, not motion — it always applies. |

Apply via `.mask(alignment: .top) { LinearGradient(stops:…, startPoint: .top,
endPoint: .bottom) }`, with the scroll container **bottom-pinned**
(`scrollPosition(anchor: .bottom)`) so streaming reads as text settling up from
below.

---

## 2. Box tokens — the canonical "diff-render look" (T-3)

**One aesthetic, reused across terminal / code / diff / copyable.** A tool
result, a fenced code block, a diff, and a copyable snippet are **the same box** —
differentiated by content, never by a second chrome style. The rule that governs
all four:

> **Inline over boxed-in-a-box.** No nested backgrounds, no double borders. A box
> inside the transcript gutter is **one** surface: one `codeBg` fill, one hairline,
> one radius. A code block that already sits in a card does not get a second inner
> card.

### 2.1 Type — mono STRICTLY smaller than body

The audit's complaint: code currently renders at `.body`-monospaced (17pt) — the
**same size as prose**, so a box doesn't read as a distinct plane. Fixed:

| token | value | ratio to body |
|-------|-------|---------------|
| **`box.mono`** (canonical box body) | **`typography.code` — SF Mono, 14pt** (DESIGN.md role) | **14/17 = 0.82** — strictly smaller. |
| **`box.monoInline`** (dense one-line summary / metadata) | monospaced `.caption`, **12pt** | 0.71 — for the collapsed tool one-liner + argument previews only. |
| `box.lineHeight` | **1.45** | matches `typography.code.lineHeight` (DESIGN.md). |

Desktop parity: diff + tool-section content render at **`0.7rem` (≈11.2px)
monospace** (`diff-lines.tsx:68`, `fallback.tsx:97`) — well below its body. iOS
pegs to the existing **`typography.code`** role (14pt SF Mono, DESIGN.md) rather
than inventing a new size: it is already strictly-below-body and honors Dynamic
Type (we peg to a semantic role, never a frozen pt — DS §Typography). **Do not**
raise this to `.body` (17pt) for "readability"; the size *is* the signal that
this is a box, and it must not fork a second mono number off the `code` role.

### 2.2 Container

| token | value | source-of-truth |
|-------|-------|-----------------|
| `box.corner` | **`rounded.md` = 12pt**, `.circular` | radius per DESIGN §Shapes; `.circular` (not `.continuous`) is the shipped perf ruling (`CodeBlockView.swift:76–83`) — hold it. |
| `box.border` | **`theme.border` hairline, 1pt** | one hairline, DESIGN §Colors "Lines". Never two. |
| `box.background` | **`theme.codeBg`** | the neutral content fill; brand accent is reserved OUT of the box (`CodeBlockView.swift:9–12`). |
| `box.padX` (compact) | **12pt** | horizontal inset (`spacing.md`). |
| `box.padY` (compact) | **10pt** | vertical inset. Parity with shipped `CodeBlockView` body (h12/v10, `:150–151`). |
| `box.padX` (regular) | **14pt** | iPad breathing bump — **padding only**, font unchanged. |
| `box.padY` (regular) | **12pt** | `spacing.md`. |
| `box.inlinePad` | **h10 / v7** | the dense inline tool-row container (parity with shipped `ToolActivityRow` `:332–333`). |

### 2.3 Copy affordance

- **Placement:** **top-trailing** of the box header — parity with the shipped
  `CodeBlockView` header (`copyButton` trailing, `:109`). Every copyable box
  (terminal / code / diff / snippet) carries it in the same slot; a reader learns
  one location.
- **States:** idle = `doc.on.doc` in `mutedFg`; copied = `checkmark` in
  `statusOK` with `.symbolEffect(.replace)` + a light haptic (`:242–253`). Do not
  invent a second copy pattern.
- **Header chrome** (language badge, expand/collapse, copy) reads in
  **`mutedFg`** — the box body owns the ink; the chrome recedes.

### 2.4 Diff — red/green preserved, gutter-accent, no marker chars

Diffs are the same box with per-line tinting layered on. Desktop is the parity
target (`diff-lines.tsx:43–47, 55`):

| token | value | desktop source |
|-------|-------|----------------|
| `diff.addFill` | **`statusOK` @ 0.12** | `bg-emerald-500/12` |
| `diff.addGutter` | **`statusOK`, 2pt left border** | `border-emerald-500 border-l-2` |
| `diff.removeFill` | **`statusError` @ 0.12** | `bg-rose-500/12` |
| `diff.removeGutter` | **`statusError`, 2pt left border** | `border-rose-500 border-l-2` |
| `diff.linePad` | **h10 / v1** (`px-2.5 py-px`) | `diff-lines.tsx:55` |
| `diff.stripMarkers` | **true** | drop the leading `+`/`-`/space gutter char; **color + the 2pt accent carry the meaning**, "the way Cursor does" (`diff-lines.tsx:19–20, 84`). |
| `diff.headerStrip` | **true** | strip `diff --git` / `index` / `---` / `+++` / `@@` hunk noise (`diff-lines.tsx:97–134`). |

Diff tints use the **semantic status roles** (`statusOK`/`statusError`), the same
green/red as the connection trio — never a decorative green. On `mono` theme the
status trio stays chromatic by design (DS §2), so red/green diff survives even in
grayscale.

**Nesting ban restated for diffs:** a diff is `codeBg` + per-line tint. It does
**not** also sit in a bordered card that sits in the tool box. The diff lines
bleed to the box edge (desktop `-mx-1.5`, `diff-lines.tsx:61–68`); the box's own
radius clips them. One border, at the outer box.

---

## 3. Thinking-block chrome (T-2)

The current iOS thinking block uses `Label("Thinking…", systemImage: "brain")`
(`ThinkingView.swift:79`) — a **brain glyph** the desktop app does not carry.
Desktop's treatment is **plain text, no glyph** (`message-parts.tsx:98–106`).
Port it.

| token | value | notes |
|-------|-------|-------|
| `thinking.glyph` | **none** | remove `systemImage: "brain"`. No emoji, no SF Symbol on the label. The disclosure chevron is the only affordance glyph. |
| `thinking.labelStreaming` | **"Thinking…"** | while the turn streams. Rides the **§1.1 pulse** (opacity breathe) — parity with desktop `shimmer` on the pending label (`message-parts.tsx:102`). |
| `thinking.labelCollapsed` | **"Thinking"** | settled, un-expanded, when duration is unknown. |
| `thinking.labelSettled` | **"Thought for {n}s"** | settled with a known elapsed. `{n}` = whole seconds, **`tabular-nums`**. This is the quiet collapsed settle line — the reasoning block never dominates a finished transcript (mirrors the `ToolCluster` summary "· Xs" idiom, `ToolActivityRow.swift:227–233`). |
| `thinking.labelColor` | **`mutedFg`** | secondary text; the reasoning body, when expanded, is `mutedFg` italic `.caption` (shipped `:67–69`) — hold. |
| `thinking.elapsed` | reuse **§1.2 status-glow** typography | the "{n}s" tail is the same mono/tabular/midground-tinted elapsed treatment. |

### 3.1 Faces stripped at render

Kaomoji / ASCII spinner faces (`◉_◉ processing…`, `(¬‿¬) analyzing…`,
`¯\_(ツ)_/¯`) must be **stripped before render** — parity with desktop
`coerceThinkingText` (`apps/desktop/src/lib/chat-runtime.ts:130`). Extract its two
regexes verbatim as the build target:

- **Status-prefix strip** — a leading `[≤16 non-space chars] <verb>...` where verb
  ∈ {processing, thinking, reasoning, analyzing, pondering, contemplating,
  musing, cogitating, ruminating, deliberating, mulling, reflecting, computing,
  synthesizing, formulating, brainstorming} (`chat-runtime.ts:29–30`). The
  optional `[≤16 non-space]` group is what catches the leading face glyphs.
- **Empty-placeholder collapse** — coerce spinner-echo placeholders ("current
  rewritten thinking", "next thinking to process", …) to empty
  (`chat-runtime.ts:32–33`).

A reasoning group whose text is empty after coercion renders **nothing** — no
empty "Thinking" header eating a row (desktop `hasContent` gate,
`message-parts.tsx:160–168`). Build should port these as a Swift equivalent
(`AnsiText`-adjacent util) and unit-test against the desktop test vectors
(`chat-runtime.test.ts:73–81`).

---

## 4. Size-class variance (iPad + iPhone — universal)

The product is universal iOS + iPadOS; the gate checks **both** (DS §Layout). The
law: **variance lives in padding/spacing/width, not in font points** (Dynamic
Type owns the type ramp).

| token | compact (iPhone portrait) | regular (iPad, landscape Max) |
|-------|---------------------------|-------------------------------|
| `box.padX` | 12pt | **14pt** |
| `box.padY` | 10pt | **12pt** |
| `box.mono` | 13pt semantic `.footnote` | **13pt** (identical — Dynamic Type only) |
| `fadeMask.height` | 28pt / ~172pt window | **36pt** / taller window |
| box `max-width` | full gutter | **≤720pt reading measure, centered** (DESIGN §Layout — never edge-to-edge across a wide detail column) |
| diff/line pad | h10 / v1 | h10 / v1 (unchanged — density is intentional) |

The single most-common iPad failure is a stretched phone box running full-bleed
across the split-view detail column. Constrain every transcript box to the 720pt
reading measure on regular width (DESIGN §Layout, §Size classes).

---

## 5. Acceptance (self-check)

- [x] Every token has a **concrete value** — no "TBD".
- [x] Every parity claim names a **desktop source** (file:line).
- [x] T-2 / T-3 / T-4 can each be built from this doc with **zero further design
      decisions** (§1 → T-2/T-4 motion; §2 → T-3 boxes/diff; §3 → T-2 thinking).
- [x] **Size-class variance** specified (§4) — padding/width vary, font does not.
- [x] Every motion token names its **Reduce Motion** fallback.
- [x] No new accent, no glassed content, no spinner, no nested box, no frozen pt.

## Pitfalls

- **Don't** raise `box.mono` to `.body` for readability — the sub-body size *is*
  the "this is a box" signal. Dynamic Type already scales it for accessibility.
- **Don't** ship a spinner on any streaming transcript row — use §1.1 pulse. A
  `ProgressView` reads as "stuck".
- **Don't** freeze pt sizes per size class — vary padding/width, bind fonts to
  semantic styles (DS §Typography law).
- **Don't** tint the diff green with a decorative green — use `statusOK` /
  `statusError` (survives `mono` theme, semantic-color law).
- **Don't** nest a diff/code box inside another bordered card — one outer border,
  content bleeds to its clip.
- **Don't** leave the brain glyph on the thinking label — plain text only.

## Verification (build + gate)

- **Build:** each WU renders in **all six themes** (DS §2) — a box that only reads
  in `nous` is not done. Test faces-strip against the desktop vectors
  (`chat-runtime.test.ts:73–81`).
- **Gate:** the designer seat reviews every STR-989 build WU against STR-308
  (`DESIGN.md` / `DESIGN-SYSTEM.md` / `GATE-RUBRIC.md`) **and this doc** before it
  passes verifier. Cite the token id (e.g. `TRANSCRIPT-CHROME §1.2 statusGlow`) in
  every verdict — never bare taste.
- **Perception:** the vision-pass rubric (`docs/PERCEPTION-QA.md §3`) checks the
  rendered screenshot, not the a11y tree: pulse reads alive-not-spinning, the glow
  is one blue not a rainbow, the box mono is visibly smaller than prose, diff
  red/green survive, no brain glyph, no double border.

---

## Provenance

- Parent: STR-989 (TRANSCRIPT DESIGN, origin:abhi). Rubric: STR-308.
- Desktop parity sources (extracted verbatim, 2026-07-08):
  `apps/desktop/src/styles.css` (glow keyframes :1550–1564, fade mask :1263,
  quest-glow :611–625), `components/chat/activity-timer-text.tsx:17` (elapsed
  tint), `components/chat/diff-lines.tsx:43–68` (diff tints/box),
  `components/assistant-ui/tool/fallback.tsx:88–97` (tool box),
  `components/assistant-ui/thread/message-parts.tsx:98–168` (thinking label),
  `lib/chat-runtime.ts:29–133` (face strip).
- iOS current-state anchors: `Views/Chat/ThinkingView.swift` (brain glyph to
  remove), `Views/Chat/ToolActivityRow.swift` (bounded window + box),
  `Views/Chat/Rendering/CodeBlockView.swift` (code box, `.circular` corners).
