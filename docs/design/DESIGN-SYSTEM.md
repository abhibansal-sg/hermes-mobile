# Hermes Mobile — Design System Doctrine

Status: v1 (STR-308, DESIGN COMMISSION #1). Companion to `DESIGN.md` (normative
tokens) and `GATE-RUBRIC.md` (the review checklist that cites this document).

This is the prose layer of the Hermes Mobile design system: the *why* behind the
tokens, the component inventory measured against the current app, the Liquid
Glass adoption map, and the state patterns (empty / loading / error / offline).
It codifies direction that already lives, scattered, across `apps/ios/`
CONTRACT-UI-{A..I}, VISION.md, and the `Theme/` source — into one citable spec so
gate verdicts point to a section, not a taste.

**This is not a redesign.** Per Abhi's law (2026-07-05): existing surfaces stay;
this spec governs *new* work, bends the existing UI toward the native material
system where it fits, and gives the gate something to cite. The desktop app is
the elder sibling — same principles, adapted to touch. Parity of feel, not pixel
cloning.

---

## 1. The one law and its three clauses

> **Glass for chrome. Themes for content. Accent for identity.**

Everything below derives from this. When two rules seem to conflict, this law
wins.

**Clause 1 — Glass for chrome.** The floating chrome layer (toolbars, floating
pills, sheets, menus, the composer container, the drawer "New chat" capsule) is
rendered by the *system* on iOS 26+ as Liquid Glass. We do not paint it, tint it,
or draw fade masks under it. On iOS 17–25 it falls back to a solid `card` fill
with a hairline border and one soft lift shadow. Rationale (CONTRACT-UI-I):
our entire bug history — Settings hit-targets, fade-band seams, safe-area bleed —
lives in hand-rolled chrome. System components delete whole bug classes.

**Clause 2 — Themes for content.** The content plane (transcript, message
bubbles, code blocks, drawer body, the composer's inner fills, sheet content) is
*never* glassed. It is painted from the active `HermesTheme` palette. This is
what preserves the six-theme identity: glass is neutral, so content must carry
the theme.

**Clause 3 — Accent for identity.** A single accent role, `midground`, is the
brand carrier: global `.tint`, the send button, the streaming cursor, the active
pill. On iOS 26, where chrome fills defer to system glass, `midground` becomes
the *primary* theme carrier — it is what makes a system-chrome screen still read
as nous / midnight / ember / mono / cyberpunk / slate. **One accent. No second
saturated hue.**

---

## 2. The theme matrix

Six palettes. One structure (`HermesTheme` value type — 30 role tokens). Source
of truth: `Theme/HermesThemePresets.swift`. Do not add a seventh theme without a
direction pass; do not fork the token structure.

| theme | mode | canvas `bg` | brand `midground` | character |
|-------|------|-------------|-------------------|-----------|
| **nous** | adaptive (light+dark) | `#F8FAFF` / `#0D2F86` | `#0053FD` | default; glass neutrals, Nous blue; psyche-cream over deep blue in dark |
| **midnight** | forced dark | `#08081C` | `#8B80E8` | deep indigo, violet accent |
| **ember** | forced dark | `#160800` | `#D97316` | warm black, amber accent |
| **mono** | forced dark | `#0E0E0E` | `#9A9A9A` | grayscale; status trio stays chromatic |
| **cyberpunk** | forced dark | `#000A00` | `#00FF41` | matrix green monochrome |
| **slate** | forced dark | `#0D1117` | `#58A6FF` | GitHub-dark, cool blue accent |

**Rules the matrix enforces:**

- `nous` is the only adaptive set (a hand-tuned light+dark pair that follows the
  system). The other five pin `.preferredColorScheme(.dark)` so system glass,
  keyboards, and menus render dark to match a single-mode palette.
- Forced-dark themes rely on the system adapting glass to the pinned scheme — do
  not per-component override.
- Every new content surface must be **read in all six themes** before it ships.
  A screen that only looks right in `nous` is not done.
- Reduce Transparency is honored by the *system* for system materials; the
  17–25 fallback is already opaque. Do not reimplement it.

The picker preview strip shows five swatches per theme: `bg, midground, card,
primary, accent` — enough to read the mood at a glance (`AppearanceView.swift`).

---

## 3. Component inventory — spec vs current app

Each row: the component, where it lives, its current state (from the STR-308
audit of `apps/ios/HermesMobile/Views/` + the STR-244 perception recordings),
and the spec verdict. **Accessibility ids are contract** — never rename without
updating tests.

### 3.1 Chrome (glass plane)

| component | file / id | current state | spec verdict |
|-----------|-----------|---------------|--------------|
| **Drawer toggle pill** | ChatView `.toolbar` leading, id `drawerToggle` | hamburger in circular glass pill (26) / `card` circle (17–25) | ✅ conforms. Chrome glass, untinted, glyph = `fg`. |
| **New-chat + overflow** | ChatView `.toolbar` trailing, ids `newChatButton` `chatOverflowMenu` | system toolbar items → floating glass on 26 | ✅ conforms. Keep as system `.toolbar`, never hand-built pills. |
| **Scroll-to-bottom pill** | ChatView, id `scrollToBottom` | system Button `.buttonStyle(.glass)` gated / circle fallback | ✅ conforms. |
| **Drawer "New chat" capsule** | DrawerView, id `drawerNewChat` | `.glassProminent` gated / capsule fallback | ✅ conforms. **Note:** audit flags it as center-anchored over the peeking composer — verify no tap-target crowding at the right edge on the push-card seam (GATE §z-index). |
| **Attribution pill** ("Driven by Claude Code (local)") | header | **DEFECT** — styled as a filled blue capsule identical to the primary CTA; right-orphaned against a centered layout | ❌ **Fix owed.** A status/attribution chip must not equal a primary button. Demote to a quiet `secondary`/`muted` chip or move into the overflow menu / a status affordance. Tracked for a fix issue. |

### 3.2 Content (theme plane)

| component | file | current state | spec verdict |
|-----------|------|---------------|--------------|
| **Transcript** | ChatView, MessageBubble | full-width; agent prose = New York serif at `.body`; user = bubble | ✅ conforms. Serif-agent / sans-user duality is intentional (F3). |
| **User bubble** | MessageBubble | `userBubble` fill, `userBubbleBorder` hairline, `lg` radius | ✅ conforms. |
| **Code block** | Rendering/CodeBlockView | `codeBg` fill, monospaced, `md` radius, syntax highlight | ✅ conforms. Never serif, never glassed. |
| **Tool activity row** | ToolActivityRow, ThinkingView | line-weight icon + `mutedFg` label + `caption` timing | ✅ conforms. Keep icon line-weight consistent (audit praised iconography cohesion). |
| **Draft greeting** | ChatView (`greeting`) | centered theme glyph + serif "Morning./Morning, name." | ✅ conforms (Amendment E). Chat-as-home. |
| **Composer** | ComposerView, id `composerModelChip` | two-row card; glass container (26) / `card` (17–25); system TextField + buttons; model chip w/ context-meter tint; mic↔send morph | ✅ conforms. Preserve mic/hold, queue chip, attachment strip, interrupt morph bit-for-bit (CONTRACT-UI-I §I3). |

### 3.3 Lists & navigation

| component | file | current state | spec verdict |
|-----------|------|---------------|--------------|
| **Drawer session row** | DrawerSessionRow | 3-line: bold title / `mutedFg` truncated preview / `caption` timestamp + source glyph. **No leading icon.** | ⚠️ **Inconsistency.** Session rows lack the leading icon that nav rows (Archived/Inbox/Automation) carry, so equal-weight rows anchor to different left rails. Align to the 16pt rail: either give session rows a leading source glyph or de-weight nav-row icons. GATE §alignment. |
| **Drawer nav rows** | DrawerView | leading line-icon + label + chevron | ✅ icon style cohesive; see rail note above. |
| **Segmented control** (Sessions/Projects) | DrawerView | system-style pill segment, active = white + soft shadow | ✅ conforms (system segmented). |
| **Settings** | SettingsView | native `List` inset grouping, system rows | ✅ conforms (CONTRACT-UI-I §I2). |
| **Panels** (Models, Skills, Usage, Cron…) | Views/Panels/* | native List/Form | ✅ conforms; sweep stragglers for custom row containers. |

### 3.4 Banners & state affordances

| component | file | current state | spec verdict |
|-----------|------|---------------|--------------|
| **Offline / error banner** | ConnectionStatusBanner | full-width `destructive` fill, warning glyph, truncated message, **actionable Retry** | ✅ conforms. Canonical error pattern (see §5). Semantic color, actionable, dismissible-by-fix. |
| **Approval / clarify banner** | ApprovalBanner, ClarifyBanner, ApprovalCard | inline cards | ✅ conforms; must reach the runner while agent runs (gateway two-guard rule — behavior contract, not visual). |
| **Cross-session banner** | CrossSessionBanner | inline notice | ✅ conforms. |

---

## 4. Liquid Glass adoption map

The migration is **already executed** through CONTRACT-UI batches A–I and the
`scrollEdgeEffectStyle` geometry fix. This map records the end state as law so
the gate can verify future work stays inside it. **Native kit FIRST** — custom
code survives only where iOS ships no component.

| surface | iOS 26+ (native glass) | iOS 17–25 (painted fallback) | custom code allowed? |
|---------|------------------------|------------------------------|----------------------|
| Chat top chrome | system `.toolbar` → floating glass | classic system toolbar | none — system toolbar only |
| Transcript scroll edges | `.scrollEdgeEffectStyle(.soft)` top+bottom | `EdgeFadeMask` | fallback mask only |
| Scroll-to-bottom | `.buttonStyle(.glass)` | `card` circle | none |
| Settings / sheets | native `List`/`Form` (system inset redesign) | native List (classic) | none |
| Composer container | `.glassEffect(.regular.interactive())` | `theme.card` fill | **LAYOUT only** — no system chat composer exists; every element inside is a system primitive |
| Composer buttons | system Buttons, `.glass` where apt | system Buttons | none |
| Drawer mechanics | push-card gesture, width, scrim-less | same | **YES** — no system drawer; but internal rows use system Label/Button |
| Drawer "New chat" | `.buttonStyle(.glassProminent)` | capsule fallback | none |
| Floating pills | `.chromePill(theme, in:)` → `glassEffect` | `card` + border + soft shadow | none — use the shared modifier |

**The three legitimate custom surfaces** (and their justification):
1. **Drawer mechanics** — push-card interactive-pop gesture; iOS has no drawer.
2. **Composer layout** — two-row chat composer; iOS has no chat composer.
3. **Transcript rendering** — markdown/code/ANSI segmentation; app-specific.

Everything else is a system primitive. A PR that hand-rolls chrome that a system
component covers is a defect against this map (GATE §native-first).

**Glass discipline:**
- Glass is **untinted**. Identity is the glyph (`fg`) + `midground` tint + the
  content below, never a colored glass.
- Glass clips to a **concrete shape** (`Capsule`, `Circle`) via the shape
  argument — never the default unclipped effect over content.
- `.interactive()` on chrome that responds to touch (matches reference chrome
  shimmer).
- Use the shared `.chromePill(_:in:)` modifier (`Theme/ChromePill.swift`), not
  per-site glass calls — one place owns the glass/fallback branch.

---

## 5. State patterns (empty / loading / error / offline)

State screens are where craft shows. The pattern is fixed so every surface
handles the non-happy path the same way.

### Empty state
Structure: **theme glyph → serif headline → sans sub-copy → one primary CTA →
one secondary path.** The draft-chat greeting ("Morning.") and the drawer
Telegram empty ("No Telegram chats yet") are the references.
- Vertically centered with an `xxl` offset above true center (chat-as-home
  balance), not floating in a top-weighted void.
- Sub-copy must **not reference off-screen UI**. The launch empty state citing
  "the drawer" while no drawer affordance is visible is a defect — either show
  the affordance or rewrite the copy to what's on screen.
- Exactly one primary CTA. The secondary path is a text link (`midground`), not
  a second filled button.

### Loading state
- Use **skeletons** (`TranscriptSkeletonView`, `HydrationLoadingView`) for
  content that has a known shape; a spinner only for indeterminate/short waits.
- Skeletons paint from `muted`/`card`, animate with a slow shimmer that respects
  Reduce Motion (fall back to a static dim, no pulse).
- A loading state must **resolve or fail** — a skeleton that never resolves is a
  p1 defect (PERCEPTION-QA §3a: "loading states that never resolved").

### Error state
- **Actionable, specific, recoverable.** The offline banner is canonical:
  `destructive` fill, warning glyph, a one-line human message (not a raw
  exception), and a **Retry** affordance. Never a silent stall (VISION.md:
  "unreachable endpoints give actionable errors, never silent stalls").
- Full-width banner at the top of the affected surface, `md` radius (or `none`
  at a true screen edge).
- Errors use `statusError`/`destructive` — semantic color only.

### Offline / degraded
- A persistent status affordance (the "Offline" chip) states the mode plainly
  and offers the fix (Retry). It does not block the transcript; cached content
  stays readable (CONTRACT-OFFLINE-CACHE).
- Connection health uses the status trio dot: `statusOK` connected,
  `statusWarn` degraded/reconnecting, `statusError` down.

---

## 6. Density & rhythm

- **Screen margin = 16pt (`lg`).** One left rail; icons, labels, rows align to
  it. This is the single most-cited alignment rule at the gate.
- **Vertical rhythm** steps on the spacing scale: `md` inside a component,
  `lg` between rows/sections within a group, `xl` between distinct sections,
  `xxl` for hero breaks. No off-grid gaps.
- **Information density** is judged per size class against this spec (PERCEPTION-
  QA §3b/c). iPhone tolerates less density than iPad; a screen that's airy on
  iPad may be sparse-to-empty on iPhone (the drawer's large bottom void with one
  session is a mild instance — acceptable, but watch it).
- **Touch targets ≥44pt**, even when the glyph is smaller. Non-negotiable (HIG).
- **Dynamic Type** must not clip or overlap at accessibility sizes. Test at
  `.accessibility1`+ (PERCEPTION-QA §3: "truncation, overlapping, double-render").

---

## 7. Motion

- **Curves:** the app standardizes on `.snappy` (primary), `.easeInOut`
  (secondary), `.spring` (physical/gesture-driven). These three cover the app;
  a new curve needs a reason.
- **Gesture-driven motion** (drawer push-card, sheet detents) is
  interruptible and tracks the finger — never a fixed animation that ignores the
  drag.
- **Respect Reduce Motion.** Cross-fade or cut instead of translate/scale when
  the accessibility setting is on (already wired in ChatView / DrawerSessionRow /
  MessageBubble — extend the pattern, don't skip it).
- **Frame budget is law** (PERCEPTION-QA §1): 60fps sim = 16.7ms/frame; any
  streaming/scroll surface that hitches (>1 dropped frame, 33ms+) is a defect.
  The device lane (120Hz = 8.3ms) is the pre-ship truth for flagship flows.
- No motion for motion's sake. The streaming cursor and the interrupt morph earn
  their animation; decorative movement does not.

---

## 8. What this spec deliberately does NOT do

- It does not redesign any shipped surface. It records the end state of A–I as
  law and flags the *specific* defects the audit found (attribution-pill
  affordance, session-row rail) as fix issues, not a rebuild.
- It does not add a seventh theme, a second accent, or new custom chrome.
- It does not freeze pixel values into tests — the gate rubric asserts
  relationships (semantic style used? on-grid? one accent? glass untinted?),
  not snapshots (see GATE-RUBRIC.md).

---

## Appendix A — token → source-of-truth map

| token layer | source file | notes |
|-------------|-------------|-------|
| Color roles (30) | `Theme/HermesThemeModel.swift` | value type; per-theme literals in `HermesThemePresets.swift` |
| Theme resolution / tint / forced scheme | `Theme/ThemeEnvironment.swift`, `ThemeStore.swift` | `.hermesThemed(store)` at every sheet/stack root |
| Glass chrome | `Theme/ChromePill.swift` | `.chromePill(_:in:)`; glass/fallback branch |
| Hex parsing | `Theme/Color+Hex.swift` | |
| Spacing / radius / type | **hardcoded in Views** (no token layer yet) | §Layout/§Shapes normalize the scale; a `Metrics` enum is the natural next step but out of scope for this spec |

## Appendix B — audit provenance

- Token audit: `apps/ios/HermesMobile/Theme/*` + literal-frequency scan of
  `Views/` (spacing, font, radius, animation) — STR-308, 2026-07-06.
- Visual grounding: STR-244 perception cycle recordings
  (`work-products/STR-244-20260706-083445-perception-cycle/`), STR-75/142
  iPhone+iPad evidence, GPT-5.5 vision-pass descriptions of launch empty state,
  drawer-open, and draft-greeting/composer surfaces.
- Direction lineage: `apps/ios/VISION.md`, CONTRACT-UI-{A..I},
  `docs/PERCEPTION-QA.md`.
