# UI Batch F Contract — Claude-iOS Layering & Motion

## ENG-REVIEW AMENDMENTS (binding; supersede conflicting text below)

A. PREREQUISITE GATE: Batch E must be LANDED ON DISK before any F module
   starts — verify Stores/ServerCapabilities.swift exists and
   QuickCaptureView no longer hardcodes gbrain. If absent: STOP and report.
B. NEW MODULE F0 (runs FIRST, blocking F3): wire a running-model source.
   The header model chip has NEVER rendered (ChatView's modelName is nil at
   every call site; no store tracks the model). F0: ConnectionStore (or a
   small ModelStore) fetches control.modelInfo() on connect + after model
   switches, exposes `var activeModelName: String?`; ChatView/composer read
   it. Without F0 the composer chip is dead UI — do not relocate a chip
   that cannot render.
C. SEQUENCING: F3 (composer card) lands FIRST as an independently
   verifiable step. F1 and F2 land TOGETHER in one integration (removing
   the drawer footer gear before the avatar-sheet exists leaves Settings
   unreachable — never allow that window).
D. F1 IMPLEMENTATION CONSTRAINT: do NOT re-parent the existing
   NavigationStacks (chatStack and DrawerView's stack stay exactly where
   they are in the view tree). The push-card is a restyle of the EXISTING
   CompactLayout offset/drag math: drop the scrim, add cornerRadius ~28 +
   shadow on the displaced chatStack. Keep edge-only open gesture
   (edgeOpenZone 24pt, minimumDistance 8, startLocation guard) exactly;
   close-drag may extend to the displaced card only while open.
E. ADDITIONAL ACCEPTANCE CRITERIA:
   - The floating hamburger pill carries accessibilityIdentifier
     "drawerToggle"; "newChatButton" survives OUTSIDE any Menu (direct
     button in the trailing pill); "sessionRow" ids unchanged. Both live
     UI tests must pass unmodified except chrome-location updates.
   - composerModelChip id added; its UI test gates on a non-nil model.
   - Greeting fallback with hermes.displayName unset renders "Morning." /
     "Evening." (with period) — explicit test.
   - accessibilityHidden(drawer.isOpen) focus-trap behavior preserved on
     the displaced chat card.
   - Scroll-to-bottom pill AND error toast render ABOVE the bottom/top
     gradient masks.
   - ALL chrome changes (toolbar hidden, floating pills) gated
     horizontalSizeClass == .compact; iPad keeps its toolbar + inspector
     toggle; avatar→Settings sheet works from the iPad sidebar too. iPad
     smoke screenshot added to visual verification.
   - Serif applies ONLY to prose segments via MessageSegmenter (never code
     segments or the streaming cursor).
   - New UserDefaults keys (hermes.displayName) go into a new
     Support/DefaultsKeys.swift enum; migrate hermes.captureEnabled/
     capturePrefix references into it too.

Source of truth: live study of the Claude iOS app (June 2026 build) via iPhone
Mirroring — patterns below are observed, not guessed. Goal: clone the
LAYERING, MOTION, and CHAT ANATOMY while keeping the Hermes theme engine
(tokens, 6 themes) — we copy structure and physics, not Anthropic's brand
(no starburst, no cream hardcode, no "Claude" strings; theme tokens rule).
Batches A–E landed first — read POST-E state of every file.

## Observed reference (verbatim findings)

1. DRAWER = PUSH-CARD, NOT OVERLAY. Tapping the hamburger (or edge drag)
   slides the ENTIRE chat surface right by ~78% of screen width. The chat
   stays fully rendered and full-brightness (no dim scrim); it reads as a
   card sliding on the same canvas plane as the drawer beneath. Spring
   settle, interactive drag-follow both directions.
2. DRAWER CONTENT: header = wordmark left (serif) + avatar circle right;
   nav rows with thin line icons (Chats, Projects, Artifacts, Code,
   Dispatch); "Recents" muted section label; recent chats as PLAIN text
   rows, one line, truncated — selected row gets a soft rounded fill;
   FLOATING pill button "+ New chat" (black capsule, white text) bottom-
   right OVERLAPPING the list. No search field in the drawer itself.
3. SETTINGS = SHEET, opened from the drawer AVATAR. Full-height card sheet
   sliding up over the dimmed drawer (prior surface visibly dimmed behind
   rounded sheet corners). Header: X close pill left, centered bold title,
   info pill right. Content: account email card, then FLAT rows separated
   by hairlines (no grouped-card sections): icon + label + chevron; simple
   settings render INLINE values instead of pushing (e.g. "Appearance
   System ⌄" stepper, "EN >", toggles inline).
4. CHAT PAGE: NO opaque nav bar — floating circular pill controls (hamburger
   top-left; actions pill top-right) over the scrolling content, which FADES
   under them via a gradient mask (top AND bottom edges fade). Assistant
   text is full-width serif with generous line spacing; inline code in mono.
   Action row of thin line icons under each assistant turn (copy, share,
   play, thumbs up/down, retry). Scroll-to-bottom: a circular ↓ pill appears
   centered above the composer when scrolled up.
5. NEW CHAT: centered glyph + time-aware serif greeting ("Evening, Abhinav")
   over the empty canvas; same floating pills; composer at bottom.
6. COMPOSER = TWO-ROW CARD: large rounded-rect (solid surface, soft border +
   shadow). Row 1: placeholder/text ("Chat with Claude"). Row 2 inside the
   SAME card: "+" circle, MODEL CHIP ("Opus 4.8 Thinking" pill), spacer,
   mic icon, dark filled circle button (voice mode / morphs to send).

## Module F1 — drawer motion + content (owns Views/Shell/RootView.swift,
Views/Drawer/*)
- Replace the overlay/scrim drawer with push-card: ZStack(drawer beneath at
  x=0; chat surface above, offset.x animated 0 → drawerWidth(≈0.78*W)).
  While displaced: chat gets cornerRadius ~28 + soft shadow; NO opacity dim.
  Interactive: horizontal drag anywhere on the chat's leading 24pt edge +
  on the displaced chat card (to close); follows finger, velocity-aware
  spring release (response 0.40, damping 0.86 feel — tune to match
  reference). Status bar area: drawer owns it when open.
- Drawer content restructure: header (THEME wordmark "Hermes" — serif via
  .fontDesign(.serif), avatar circle right = circle with user initials from
  displayName, tap → Settings SHEET (F2)); nav rows w/ line icons: Chats
  (scrolls drawer list to top / no-op), Inbox (badge), Automations (cron
  filter toggle becomes a dedicated row toggling visibility); "Recents"
  label; plain recent rows (keep live-pulse + source glyphs, selected soft
  fill); floating "+ New chat" capsule bottom-right (theme.fg bg /
  theme.bg text — black-on-cream equivalent per theme) overlapping list.
  Quick-capture row stays gated by hermes.captureEnabled (E2).
- iPad regular width: keep NavigationSplitView (push-card is compact-only).

## Module F2 — settings as sheet (owns Views/Settings/SettingsView.swift +
presentation call sites)
- Presentation: sheet from drawer avatar (remove the footer gear push;
  drawer footer slims to just capture-if-enabled). Sheet root: X pill,
  centered "Settings" title, .presentationDragIndicator hidden, themed.
- Content restructure to Claude's flat pattern: account/server row card
  (server URL), then flat hairline rows: Appearance (INLINE current theme
  name + chevron-up-down → tap cycles or opens picker sheet), Model,
  Personality, Usage, Automations, Skills, Gateway Status (push within the
  sheet's own NavigationStack — sheet-internal pushes are fine, mirrors
  Claude), Notifications (inline toggle + per-event prefs push later),
  Security (Face ID toggle inline), Quick capture (toggle + prefix),
  Connection (Disconnect destructive), About (version inline).
- Inline-value pattern: simple toggles/values never push.

## Module F3 — chat page anatomy (owns Views/Chat/ChatView.swift,
MessageBubble.swift action row, ComposerView.swift)
- Kill the opaque nav bar on chat: .toolbar(.hidden) on compact; floating
  pill controls overlaid: leading circle pill (hamburger → drawer), trailing
  capsule pill (new-chat pencil + overflow "…" menu: session actions
  rename/export/archive). Content fades under pills: top + bottom gradient
  masks on the scroll view (mask with LinearGradient alpha).
- Scroll-to-bottom ↓ circular pill (appears when !atBottom, centered above
  composer, taps to bottom).
- Assistant text: .fontDesign(.serif) for prose segments (theme-respecting
  color), body 17 w/ existing lineSpacing; keep mono for code (CodeBlockView
  unchanged). User bubbles unchanged (theme.userBubble).
- Action row under each COMPLETED assistant turn: thin line icons —
  copy (doc.on.doc), share (square.and.arrow.up), speak (speaker.wave.2 →
  existing onSpeak), retry (arrow.counterclockwise → existing retry). 16pt,
  theme.mutedFg, 20pt spacing, no backgrounds.
- Draft greeting: replace B's version with time-aware serif greeting:
  "Morning/Afternoon/Evening, <displayName>" (UserDefaults
  "hermes.displayName", Settings field in F2; fallback to just
  "Morning./Evening." with period) + theme glyph above (reuse app sparkle
  asset tinted theme.midground).
- COMPOSER two-row card: rounded-rect theme.card fill, theme.border 1pt,
  subtle shadow; row 1 = TextField (axis vertical, 1–6 lines, placeholder
  "Message Hermes"); row 2 = "+" circle (attachments menu, capability-gated
  per E), MODEL CHIP (moves here from the nav header — same tap → model
  picker sheet; shows short model name), spacer, mic glyph (tap/hold per C2
  — preserve both modes + recording strip + queue logic), dark circle button
  (theme.fg bg): send arrow when text/attachments present, stop while
  streaming. Remove the old single-row pill styling. Keep ALL existing
  functional wiring (queue chip, attachment thumbnails strip above the card,
  TurnActivityBar placement above composer).
- The model chip leaving the header: ChatView principal title becomes just
  the session title (humanized), small; on draft = nothing (greeting owns
  the canvas).

## Integration
Same ritual: reconcile, xcodegen, build-fix (Swift 6 strict), full live test
suite (update UI tests for: model chip relocation — ModelPicker now reached
via composer chip; settings now a sheet via avatar — adjust any navigation in
tests; keep accessibility ids drawerToggle/newChatButton/sessionRow, add
composerModelChip/settingsAvatar), visual verification incl. drawer
mid-drag frozen state (mouse-held screenshot), settings sheet over dimmed
drawer, greeting, composer two-row card, fade-under-pills, scroll-to-bottom
pill. Device build sanity. Return standard JSON.
