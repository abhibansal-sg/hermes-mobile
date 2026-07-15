# UI Batch I Contract — FULL NATIVE (rewritten per user direction 2026-06-06)

PRINCIPLE (binding, from the user): "full native — use the native Liquid
Glass UI kit, be clever so styling stays true to both iOS/iPadOS and
Hermes; discourage custom elements and other UI kits." Translation:
SYSTEM COMPONENTS render chrome; Hermes identity expresses through TINT,
typography, and content surfaces. Custom code survives only where iOS has
no component (drawer mechanics, chat composer LAYOUT) — and even there,
every ELEMENT inside is a system primitive. Rationale we all agree on:
our bug history lives in hand-rolled chrome (Settings hit-targets, fade
bands, safe-area bleed); system components delete whole bug classes.

Batches A-H + geometry fix LANDED. Read current disk. The geometry fix
already replaced the drawer fade with scrollEdgeEffectStyle — that's the
pattern: extend it. Swift 6 strict, iOS 17 base, availability-gate iOS 26
API (verify signatures against the 26.5 SDK swiftinterface like the
geometry-fix agent did — its method is the house standard now).

## I1 chat chrome → system toolbar (ChatView.swift, RootView seams)
- DELETE the hand-built floating pills + hand-rolled top/bottom fade masks.
- Real `.toolbar`: leading ToolbarItem = drawer button (keep id
  drawerToggle), trailing = new-chat (newChatButton) + overflow menu
  (chatOverflowMenu). On iOS 26 the system renders these as floating glass
  automatically; on 17-25 system toolbar renders classic — both correct,
  zero custom drawing. Title = humanized session title (principal).
- Transcript scroll: system `.scrollEdgeEffectStyle(.soft)` top AND bottom
  on iOS 26 (replacing EdgeFadeMask), mask fallback 17-25 (keep existing
  EdgeFadeMask for fallback only).
- Scroll-to-bottom pill: system Button, `.buttonStyle(.glass)` gated /
  current circle fallback (keep id scrollToBottom).
- The toolbar must coexist with the push-card displacement (the card
  carries its own NavigationStack — toolbar rides inside it; verify no
  regression to the geometry fix's chatCardSurface at rest/mid-drag).
- iPad: same system toolbar; inspector toggle stays.

## I2 Settings + sheets → native List/Form (SettingsView.swift, InboxView,
QuickCaptureView, panels)
- SettingsView: custom flat-row ScrollView → native `List` (system inset
  grouping; iOS 26 gives it the new design automatically). Rows: system
  NavigationLink / LabeledContent / Toggle / Button — no custom row types.
  Close via standard toolbar Done item (keep settingsClose id;
  settingsAppearanceRow id on the Appearance NavigationLink).
- Panels already mostly native — sweep them for custom row containers and
  nativize stragglers.
- InboxView cards + QuickCapture: native List sections / Form where
  applicable; keep detents.
- KEEP: account/server header card can be a Section header — system
  patterns only.

## I3 composer → system primitives in a custom LAYOUT (ComposerView.swift)
- The two-row card layout stays (no system chat composer exists) but:
  container = `glassEffect` (verified API) on iOS 26 / theme.card fill
  17-25; buttons = system Buttons with system styles (.glass gated where
  apt); TextField stays system; model chip = system Button w/ capsule
  background tint (composerModelChip id + context meter fill from H —
  preserve the meter, re-expressed as a tint overlay compatible with the
  glass chip).
- PRESERVE bit-for-bit behaviors: mic tap/hold, RecordingControls, queue
  chip + queue-while-streaming, attachment strip + capability gating,
  interrupt morph, Dictate message label, accessibility ids.

## I4 drawer internals → native elements (DrawerView.swift)
- Mechanics (push-card gesture, width, scrim-less layering) UNCHANGED.
- Internals: rows/sections move to system List (plainStyle) IF it
  coexists with the drawer's gesture + scroll edge effect (test first; if
  List's gesture system fights the drawer drag, keep ScrollView but ensure
  every row is built from system components — Label, Button — not custom
  shapes). New-chat capsule = system Button `.buttonStyle(.glassProminent)`
  gated / current capsule fallback (drawerNewChat id). Workspace grouping
  sections (H2) become system Section headers.

## I5 theme system adaptation (Theme/ — minimal edits)
- iOS 26: chrome defers to system materials — RETIRE for chrome use:
  toolbarBg, card-as-chrome-fill, popover-as-sheet-fill (keep the tokens;
  they remain the 17-25 fallback + content uses). PERSIST everywhere: bg
  (window canvas), fg/mutedFg, userBubble(+border), codeBg, midground
  (global tint — this is now the PRIMARY theme carrier on 26), statusOK/
  Warn/Error, destructive. Forced-dark themes keep preferredColorScheme
  (system glass adapts). Add a short doc header in HermesTheme.swift
  explaining the two-mode philosophy (26: accent-led over system
  materials; 17-25: fully painted).
- Respect Reduce Transparency (system handles it for system materials —
  verify, don't reimplement).

## I6 integration + verification
Standard ritual + matrix: {nous-light, midnight, ember} × {iPhone 17 Pro
26.5, iPhone Air 26.5} key screens (chat+toolbar, drawer open, settings
List, composer) — READ all; plus iPad smoke; plus mid-drag geometry
regression check (chatCardSurface intact); plus 17-25 fallback evidence
(iOS 18 sim if installed, else compile-gates review + screenshots of
fallback paths via forced-unavailability if practical, else document).
Full live suite green (130 tests; known-flaky cross-client policy). All
accessibility ids verified present. Device build sanity. Standard JSON.
