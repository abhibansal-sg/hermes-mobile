# UI Batch D Contract — Screens Polish (final sprint batch)

Rules: INTERFACES.md recap; theme engine live; Batches B (drawer/chat-home/
QR pairing/Settings pushes) and C (chat surface/composer) LANDED — read the
POST-C state of everything you touch. Several audit findings are now obsolete
(session list toolbar, sheet-over-sheet, status pill) — if a file already
satisfies the intent, note it and move on. Audit reference:
/tmp/hermes-design-audit.md. Keep all tests green.

## D1 panels — owns Views/Panels/* (post-B5 pushed forms)
- ModelPickerView (audit M1/M2): names → theme.fg semibold; selected row →
  theme.accent tint + theme.midground check; "CURRENT" chip single accent;
  capability tags → neutral caption2 chips (theme.secondary bg / secondaryFg);
  bottom filter field → .searchable on the pushed stack (kills home-indicator
  clip).
- PersonalityPickerView (PE1): names fg semibold, selected midground + accent
  row tint, descriptions .footnote mutedFg lineLimit(2), consistent padding.
- UsageView (U1): range control → full-width Picker(.segmented) at top of
  content; loading → labeled ProgressView("Loading usage…") or simple skeleton
  rows; nav bar = title only.
- SkillsBrowserView (SK1/SK2): descriptions .footnote lineLimit(2), 6pt
  inter-row spacing, icon top-aligned to title, section headers
  .footnote.semibold mutedFg with top padding, .searchable on stack.
- GatewayStatusView: align section header treatment; status dots →
  statusOK/Warn/Error tokens (verify post-A).
- AppearanceView: verify swatch rows read well on all 6 themes; selected row
  accent tint.

## D2 sheets — owns Views/Inbox/InboxView.swift, Views/Capture/QuickCaptureView.swift
- Inbox (I1): present at .medium detent default ([.medium, .large]) from its
  presenters (drawer row + iPad inspector stays full); empty-state headline
  → .headline weight, mutedFg; card styling on theme.card with border token.
- QuickCapture (Q1): breathing room under the divider (10pt), min-height or
  hide empty-state at medium detent, .presentationBackground(theme.popover),
  themed mic button (midground).
- Sheet title standardization (P2x): .headline.semibold in fg on both.

## D3 search+onboarding — owns the drawer search results UI (post-B file —
locate it: Views/Drawer/ or SessionStore search consumers),
Views/Onboarding/WelcomeView.swift + ConnectionSetupView.swift, plus the
401/auth-failure path in Stores/ConnectionStore.swift (minimal)
- Search results (R1/R2): normalize snippets — strip JSON braces/quotes to
  plain excerpt text; .footnote with the matched query term bolded
  (AttributedString range highlight, theme.midground); monospace ONLY for
  structured content; ensure exactly one clear control (system searchable
  affordances only).
- Welcome/manual setup (O1): verify WelcomeView (B4) hierarchy — title
  .title2.bold fg; ConnectionSetupView: "Session token" label, Connect
  → .borderedProminent tinted midground when enabled, focused-field ring
  (composerRing), error text destructive token.
- RE-PAIR FLOW: in ConnectionStore, when a configured connection starts
  failing with HTTP 401/403 (RestError.badStatus 401/403 on probe, or WS
  rejects repeatedly), transition to a distinct phase or flag so RootView
  routes to WelcomeView with a friendly banner ("This device's pairing was
  revoked — scan a new code") instead of endless reconnect. Keep it minimal:
  detect on the configure/probe path + a reauthRequired flag the shell reads.

## D4 batch-B residuals — owns Views/Drawer/* (title fix), the three
openNew() callers, Views/Shell/Theme.swift orphan
- Drawer session rows: humanize cron/automation titles ("Automation · <name>"
  or first non-bracket line) — extract the existing ChatView.humanTitle logic
  into a shared helper (e.g. SessionSummary extension) and use it in BOTH
  the drawer rows and the chat header.
- Migrate the 3 deprecated openNew() callers (SharedInboxDrainer,
  PendingIntentRouter, QuickCaptureView) to the create-then-send contract
  intentionally (they need an eager session) — silence the deprecation
  properly: rename the eager API to createSessionNow() (non-deprecated,
  documented "programmatic flows only") and keep startDraft() for UI.
- Delete the orphan SessionSource type in Views/Shell/Theme.swift if truly
  unreferenced; delete HermesMobileUITests/ScreenTourTemp.swift (capture
  harness, no longer needed — the integrator re-creates tours ad hoc).

Return JSON: files, publicAPI, integrationNotes, risks. Parse-check everything.
