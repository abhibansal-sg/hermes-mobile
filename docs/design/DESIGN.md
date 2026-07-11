---
version: alpha
name: Hermes Mobile
description: Liquid Glass over a calm editorial canvas — chrome floats, content stays themed.
colors:
  primary: "#0053FD"
  secondary: "#666678"
  tertiary: "#FFE6CB"
  neutral: "#F8FAFF"
  surface: "#FFFFFF"
  ink: "#17171A"
  muted: "#666678"
  hairline: "#0053FD38"
  success: "#34C759"
  warning: "#FF9F0A"
  danger: "#C72E4D"
typography:
  display:
    fontFamily: New York
    fontSize: 34px
    fontWeight: 600
    lineHeight: 1.1
    letterSpacing: "0.01em"
  title:
    fontFamily: SF Pro
    fontSize: 22px
    fontWeight: 600
    lineHeight: 1.2
  headline:
    fontFamily: SF Pro
    fontSize: 17px
    fontWeight: 600
    lineHeight: 1.3
  body:
    fontFamily: SF Pro
    fontSize: 17px
    fontWeight: 400
    lineHeight: 1.4
  callout:
    fontFamily: SF Pro
    fontSize: 16px
    fontWeight: 400
    lineHeight: 1.4
  subheadline:
    fontFamily: SF Pro
    fontSize: 15px
    fontWeight: 400
    lineHeight: 1.4
  footnote:
    fontFamily: SF Pro
    fontSize: 13px
    fontWeight: 400
    lineHeight: 1.35
  caption:
    fontFamily: SF Pro
    fontSize: 12px
    fontWeight: 400
    lineHeight: 1.3
  label:
    fontFamily: SF Pro
    fontSize: 12px
    fontWeight: 600
    lineHeight: 1.2
    letterSpacing: "0.06em"
  code:
    fontFamily: SF Mono
    fontSize: 14px
    fontWeight: 400
    lineHeight: 1.45
spacing:
  xs: 4px
  sm: 8px
  md: 12px
  lg: 16px
  xl: 24px
  xxl: 32px
rounded:
  sm: 8px
  md: 12px
  lg: 14px
  xl: 22px
  pill: 999px
components:
  composer-card:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.ink}"
    rounded: "{rounded.xl}"
    padding: 14px
  primary-button:
    backgroundColor: "{colors.primary}"
    textColor: "#FCFCFC"
    rounded: "{rounded.pill}"
    padding: 12px
  secondary-button:
    backgroundColor: "#EDF3FF"
    textColor: "#242432"
    rounded: "{rounded.pill}"
    padding: 12px
  session-row:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.ink}"
    rounded: "{rounded.md}"
    padding: 12px
  section-label:
    textColor: "{colors.muted}"
    typography: "{typography.label}"
  error-banner:
    backgroundColor: "{colors.danger}"
    textColor: "#FFFFFF"
    rounded: "{rounded.lg}"
    padding: 12px
  status-pill-error:
    backgroundColor: "{colors.danger}"
    textColor: "#FFFFFF"
    rounded: "{rounded.pill}"
    padding: 8px
  status-dot-ok:
    backgroundColor: "{colors.success}"
    textColor: "#0B3D1A"
    rounded: "{rounded.pill}"
    size: 8px
  status-dot-warn:
    backgroundColor: "{colors.warning}"
    textColor: "#3D2A00"
    rounded: "{rounded.pill}"
    size: 8px
  canvas:
    backgroundColor: "{colors.neutral}"
    textColor: "{colors.ink}"
  hairline-rule:
    backgroundColor: "{colors.hairline}"
    height: 1px
---

## Overview

Hermes Mobile is a personal AI-agent client. Its job is to make a powerful,
sometimes-scary system (an agent that runs your terminal, spends money, and acts
on your behalf) feel **calm, legible, and trustworthy in the hand.** The desktop
app is the elder sibling; this spec adapts its principles to touch — parity of
*feel*, not a pixel clone.

The whole system rests on one architectural sentence, inherited from the iOS
theme layer (`apps/ios/HermesMobile/Theme/`):

> **Glass for chrome, themes for content.**

- **Chrome** — the floating layer that sits *over* scrolling content: the
  hamburger pill, the trailing-actions pill, the scroll-to-bottom pill, the
  drawer's "New chat" capsule, toolbars, sheets, menus. On iOS 26+ this layer is
  **native Liquid Glass** (`glassEffect(.regular.interactive())`), left
  **untinted and neutral** so it reads over any transcript. Below iOS 26 it falls
  back to a solid themed pill (`card` fill + `border` hairline + soft lift). This
  is the Liquid Glass law: **native material first**, custom chrome only where
  the native kit genuinely cannot express the need.
- **Content** — the transcript, message bubbles, the composer's inner card, code
  blocks, list bodies, drawer body. Content is **never glassed.** It is painted
  from the active theme palette so the six skins (nous / midnight / ember / mono
  / cyberpunk / slate) keep their identity.

Identity on iOS 26 is carried by the **`midground` accent tint** (set once via
`.tint()`) plus the themed content surfaces below the glass — *not* by tinting
the glass. This is why a system-chrome screen still looks like Hermes.

This document is the **normative token spec** for that system: the tokens below
are the values and the prose tells you why they exist and when to apply them. It
has two companions (see the final section): `DESIGN-SYSTEM.md` (prose doctrine +
component inventory + adoption map) and `GATE-RUBRIC.md` (the review checklist
the design gate applies to UI PRs). Every gate verdict cites a rule in those or a
`DESIGN §…` section here — never bare taste.

### What this spec is not

- Not a redesign mandate. Existing surfaces stay. This governs **new** specs,
  gate judgments, and the direction of incremental polish.
- Not a second source of truth for color values. The palette lives in code
  (`HermesThemePresets.swift`); the front matter transcribes the **default
  `nous` light** palette as the canonical reference. When code and this file
  disagree on a hex, **code wins** and this file is stale — file a fix.
  Drift is catchable: the front-matter `colors.primary` (`#0053FD`) must equal
  `HermesThemePresets.nousLight.midground`, `neutral` (`#F8FAFF`) its `bg`,
  `surface` its `card`, `ink` its `fg`, `danger` its `destructive`. A one-line
  grep in CI (or a gate spot-check) keeps the two honest.

## Colors

Hermes ships **six themes**, five forced-dark and one adaptive. The front-matter
palette is the canonical **`nous` (light)** set — the default skin — so tokens
have concrete values to lint against. Every theme resolves the same **semantic
roles**; a component references the role, never a raw hex.

**Brand & accent**

- **Primary `#0053FD` (Nous blue):** the single brand action color. Send button,
  active pill, primary CTA fill, streaming cursor, global `.tint`. In code this
  is the `midground` / `primary` slot. On iOS 26 it is *the* identity carrier —
  the neutral glass defers to it. One accent, used with discipline.
- **Tertiary `#FFE6CB` (Psyche warm):** the warm counter-tone that appears as
  `primary` on dark themes and as accent warmth. Reserved; not a second CTA color.

**Canvas & surface**

- **Neutral `#F8FAFF`:** the window canvas — a barely-cool off-white, never pure
  `#FFFFFF`, so white chips (active tab, cards, bubbles) can lift off it.
- **Surface `#FFFFFF`:** cards, composer inner fill, session rows, sheet bodies.
- **Ink `#17171A`:** primary labels, titles, nav-bar tint. Near-black, not pure
  black.
- **Muted `#666678`:** secondary text — snippets, timestamps, helper copy,
  section labels.

**Lines**

- **Hairline `#0053FD38`:** the tinted 22%-alpha blue border. All in-panel
  separation is **one hairline**, never a nested box. Prefer whitespace to lines.

**State (semantic — never decorative)**

- **Success `#34C759`:** connection OK, validated key, completed run.
- **Warning `#FF9F0A`:** degraded, unverified, needs-attention.
- **Danger `#C72E4D`:** offline banner, destructive action, error status dot,
  rejected key. Red is *only* error/destructive — never an accent or emphasis.

**Discipline:** the top status badge ("Driven by … (local)") must **not** reuse
the primary CTA blue at full strength — sharing the exact accent makes an
informational chip read as the primary action (see audit finding, empty state).
Informational chrome is neutral glass or muted; the CTA owns the accent.

## Typography

**Two families, one intentional contrast.**

- **New York (serif)** — the editorial display face. Used *only* for brand /
  greeting moments: the "Morning." transcript greeting, the "Hermes Agent"
  wordmark. It is a warmth signal, deployed sparingly. A serif that appears
  *everywhere* stops being special; a serif orphaned with no supporting subtext
  reads unfinished — pair a display line with body context or a clear action.
- **SF Pro (system sans)** — everything functional: titles, body, labels,
  buttons, list rows, banners. Dynamic Type is honored; sizes below are the
  default (Large) content-size baseline, and every text style must scale with
  `@ScaledMetric` / semantic font styles rather than freezing point sizes.
- **SF Mono** — code blocks, logs, terminal snippets, file paths. Never for prose.

**The scale** maps to iOS semantic styles so accessibility scaling is free:

| Token | iOS style | Use |
| --- | --- | --- |
| `display` | `largeTitle` (serif override) | greeting, brand wordmark |
| `title` | `title2` | screen titles, sheet headers |
| `headline` | `headline` | row titles, emphasized labels |
| `body` | `body` | message text, primary reading copy |
| `callout` | `callout` | secondary reading copy |
| `subheadline` | `subheadline` | supporting copy, field labels |
| `footnote` | `footnote` | timestamps, metadata |
| `caption` | `caption` / `caption2` | dense metadata, counts |
| `label` | `caption` + tracking + caps | SECTION HEADERS (small-caps, `0.06em`) |
| `code` | monospaced `subheadline` | code, logs, paths |

Section labels (`CHATS`, `TELEGRAM`, `PROJECT`) are the one place letter-spacing
is applied — small-caps uppercase muted text with `0.06em` tracking. Body copy
never gets tracking.

## Layout

**A soft grid, flush-left, generous gutters.**

- **Spacing scale** — a 4-pt base ramp: `xs 4 · sm 8 · md 12 · lg 16 · xl 24 ·
  xxl 32`. The measured reality of the app already clusters here (8, 6, 10, 12,
  4 dominate); new work **snaps to the ramp** rather than inventing 7s and 14s.
  Legacy odd values (7, 14) are tolerated in place but not added.
- **Screen inset** — `lg (16)` horizontal is the standard content margin. The
  status badge and any floating chrome must respect the same right inset as body
  content — the audit caught the badge kissing the right edge tighter than the
  content margin.
- **Left alignment column** — icons and section headers share the same left edge
  as row text (a ~48-pt icon column in the drawer). One alignment grid; no
  per-row indentation that fights flush headers.
- **Control baseline** — the floating composer and the drawer New-chat capsule
  share `HermesLayoutConstants.controlBottomBaseline` (16 pt from the absolute
  screen edge) so their bottom edges sit on one visual line. This is a single
  source; tune it there, never per-call-site.
- **Grouping by whitespace, not dividers.** A single hairline only when a list
  genuinely needs one. No card-in-card.

### Size classes — iPhone AND iPad are both first-class

The gate checks **both**. The app already has the right *bones* on iPad — a
`NavigationSplitView` (sidebar `min 280 / ideal 320 / max 380`) + an
`.inspector()` column (`min 280 / ideal 340 / max 460`, currently the
subagent tree, toggle-gated) in `Views/Shell/RootView.swift`. The iPad audit's
failure is not missing structure — it is that the **default detail column is a
stretched phone layout**: a centered phone greeting floating in ~70% dead
whitespace and a full-width composer trough, with the inspector collapsed and
unpopulated.

Rules for regular width (iPad, landscape iPhone Max):

- **Constrain reading + input width.** The composer and transcript get a
  `max-width` (~`720`pt reading measure), centered — never edge-to-edge across a
  wide detail column. A full-bleed input trough is a stretched-phone tell.
- **Populate the inspector, don't just ship the toggle.** The `.inspector()`
  already exists; the regular width class is *exploited* when session metadata /
  tools / files / subagents fill it, not merely *acknowledged* by a collapsed
  column. If a surface has structured detail, it belongs there.
- **Earn the width or collapse it.** When there is genuinely no inspector
  content, the detail pane centers a constrained column; it does not stretch one
  phone layout to fill the pane.
- **One shared top-bar baseline** across the split. The sidebar header and the
  detail toolbar align on the same grid line — the audit caught a ragged top edge.

## Elevation & Depth

**Three layers, no more.**

1. **Canvas** (`neutral`) — the window, flush, zero elevation.
2. **Content surfaces** (`surface`, bubbles, rows) — lifted off canvas by
   *contrast and a hairline*, not heavy shadows. On iOS 26 the composer
   *container* is system glass (chrome, self-lifting); its inner fills are
   content. Where the pre-26 fallback (or a low-contrast theme) leaves the
   composer reading white-on-near-white, strengthen the ring toward `hairline`
   so the input never dissolves into the canvas — advisory polish, verified per
   theme; the shipped composer is preserved per `DESIGN-SYSTEM.md §3.2`.
3. **Floating chrome** (glass pills, sheets, menus) — the top layer. On iOS 26+
   it is Liquid Glass: the system paints the blur, the lift, the touch shimmer.
   Below 26 it falls back to `card` fill + `border` hairline + a soft shadow
   (`black @ 8%, radius 6, y 1`). **One elevation token, applied by the system or
   the fallback** — never a per-pill bespoke shadow.

**Reduce Transparency** is honored automatically: the system swaps glass for
opaque material when the setting is on, and the pre-26 fallback is already opaque.
Never reimplement this by hand.

## Shapes

Rounded, continuous corners throughout (`RoundedRectangle(style: .continuous)`).

- **`sm 8`** — small chips, count badges, code-inline.
- **`md 12`** — session rows, cards, tool rows, banners.
- **`lg 14`** — larger cards, sheets.
- **`xl 22`** — the composer card (large, friendly radius).
- **`pill 999`** — all capsules: primary/secondary buttons, status badges,
  segmented control, the New-chat CTA, floating chrome pills.

Glass pills clip to their exact silhouette (`Capsule`/`Circle` passed to
`glassEffect(in:)`) so the material follows the shape.

## Components

The composer row is the app's most-touched control and the audit's worst craft
offender — **three inconsistent button styles in one row** (solid charcoal `+`,
outlined lightning pill, bare mic glyph). The spec's rule: **one button system,
picked by role.**

- **`primary-button`** — the accent CTA (New Chat, Send). Filled `primary`,
  white glyph, pill. One per context. Owns the accent.
- **`secondary-button`** — soft-fill quiet action (`#EDF3FF` fill, dark text,
  pill). The default non-primary look.
- Composer controls (`+`, commands, mic) are **one family** — same container
  treatment, same size, differentiated by icon, not by three different chrome
  styles. A bare glyph next to a filled circle next to an outlined pill is a
  fork; unify them.
- **`composer-card`** — `surface` fill, `xl 22` radius, `14`-pt padding,
  `composerRing` outline (must be visible — see Elevation). The inner fills are
  content, never glassed.
- **`session-row`** — title (`headline`) / snippet (`subheadline` muted, single
  truncation) / metadata (`footnote` muted) + a source glyph. Borderless, flush,
  spacing-separated.
- **`section-label`** — small-caps muted `label` with `0.06em` tracking + count.
- **`error-banner`** — `danger` fill, white text, `md`/`lg` radius. Icon + bold
  headline + one human-readable sentence + a clear action (Retry). **Never leak
  raw JSON/HTTP payloads** — the iPad audit caught `HTTP 503: {"detail": …}`
  surfaced verbatim. Map transport errors to human copy; keep the raw string for
  logs.
- **`status-pill-error`** — the Offline badge: `danger` fill, alert glyph, white
  label, pill. Semantic red only.

Floating chrome pills use the `chromePill(theme, in:)` modifier — **never** a
hand-rolled background. New chrome adopts that one modifier so glass-vs-fallback
stays centralized.

## Do's and Don'ts

**Do**

- Reach for the **native Liquid Glass material first** for any floating chrome;
  justify custom chrome only when the native kit cannot express the need.
- Keep glass **neutral/untinted**; carry identity with the `midground` accent
  tint and themed content below.
- Snap spacing to the 4-pt ramp; use one hairline + whitespace for grouping.
- Give every text style a semantic font so Dynamic Type scales it.
- Constrain reading/input width on iPad; fill the width with real structure
  (inspector) or center a constrained column.
- Map errors to human sentences; keep the raw payload in logs.
- Verify contrast and the *rendered screenshot*, not just the a11y tree — the
  tree is not the screen.

**Don't**

- Don't glass content surfaces (transcript, bubbles, composer inner, code).
- Don't tint the glass or let an informational chip reuse the CTA accent at full
  strength.
- Don't stretch one phone layout edge-to-edge across the iPad canvas.
- Don't fork the button system — no three chrome styles in one row.
- Don't ship a composer that dissolves into the canvas (weak ring/contrast).
- Don't hand-roll a per-pill shadow or a bespoke glass background.
- Don't leak JSON/HTTP/debug strings into user-facing copy.
- Don't clip or z-collide floating pills (the "Driven by…" badge overlapping the
  action pills is a recurring layout bug — reserve the trailing chrome's width).

---

## Companion documents

This file is the **normative token layer**. Two companions complete the system
and are the source of truth for doctrine and gating — do not duplicate their
content here:

- **`DESIGN-SYSTEM.md`** (DS) — the prose doctrine: the one law and its three
  clauses, the six-theme matrix, the full component inventory measured against
  the current app (with accessibility ids and the `CONTRACT-UI-{A..I}` lineage),
  the Liquid Glass adoption map (incl. the three sanctioned custom surfaces),
  the state patterns, density/rhythm, and motion.
- **`GATE-RUBRIC.md`** — the 9-dimension PASS/BLOCK/ADVISORY checklist the design
  gate applies to every UI-touching PR, with a paste-in verdict template. Every
  gate verdict cites a rule there or a `DESIGN §…` section here.

When this file and the companions disagree, the companions own doctrine/gating
and this file owns token values; align to the relevant owner and file a fix for
the drift.
