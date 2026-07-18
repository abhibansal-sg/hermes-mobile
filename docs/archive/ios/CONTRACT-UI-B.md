# UI Batch B Contract — Drawer Navigation + Flow Skeleton

Rules: INTERFACES.md + CONTRACT-WAVE1.md rules recap apply. Theme engine is
LIVE (HermesMobile/Theme/ — read it; consume tokens via @Environment(\.hermesTheme),
roots use .hermesThemed(themeStore)). 100 tests green — keep them green.
Locked design decisions (do not relitigate): ChatGPT-style drawer, chat-as-home,
fresh-local chat on launch, quiet-when-nominal status, model chip, push
deep-links, Settings as pushes, QR pairing.

## B1 shell — owns Views/Shell/RootView.swift (rewrite), new Views/Drawer/*
Chat is home. Compact (iPhone):
- ZStack: ChatView (full screen, always the active or draft session) + slide-over
  DrawerView from leading edge (width ~82%, scrim tap-to-close, interactive
  edge-swipe open + drag-to-close, spring animation). Drawer state owned by a
  small @Observable DrawerState (isOpen) injectable so ChatView's toolbar
  button can toggle it.
Regular (iPad): NavigationSplitView(sidebar: DrawerView, detail: ChatView) —
keep the existing inspector (InboxView) wiring.
DrawerView (new):
- Top: search field (drawer-local @State, debounced via sessionStore.searchQuery
  machinery — reuse, don't duplicate).
- Rows: "New chat" (square.and.pencil) → sessionStore.startDraft() (B3 API) +
  close drawer; "Inbox" with badge (inbox.pendingCount) → present InboxView sheet.
- Pinned section, Recent section (header has a small Menu: "Hide automations"
  toggle persisted as today).
- Session rows: title (15 semibold), preview (13 mutedFg, 1 line), relative time
  (11) — NO message count. Source GLYPH only (paperplane=telegram,
  terminal=cli/tui, clock.arrow.circlepath=cron, desktopcomputer=desktop;
  mutedFg, no capsule). Live pulse: if a broadcast event for that stored session
  arrived <10s ago show a small pulsing dot in theme.midground (SessionStore
  gains lastActivityAt: [String: Date] fed by ConnectionStore router — B3 adds
  the store API; you consume it).
- Footer bar: Settings (gear) → push SettingsView (B5) inside drawer's own
  NavigationStack OR present full-screen — coordinate with B5's
  integrationNotes; Capture (brain) → QuickCaptureView sheet.
- Selection: tapping a row → sessionStore.open(summary) + close drawer.
SessionListView.swift: retire from navigation (keep the file compiling if other
code references helper types — move shared row components into Drawer/ and slim
it, or delete it and fix references; your call, document it).
Status banner: when connection.phase is .reconnecting/.offline, a slim banner
under the chat nav bar (theme.statusWarn/.statusError bg, white text, retry
button on offline). Remove ConnectionStatusPill from toolbars entirely.

## B2 chat-header — owns Views/Chat/ChatView.swift toolbar region ONLY
(coordinate: B1 owns the rest of nav; you own ChatView file this round)
- Leading: drawer button (line.3.horizontal) toggling DrawerState (B1's type).
- Principal: VStack(title 15 semibold lineLimit 1, model CHIP underneath —
  capsule, theme.secondary bg, theme.secondaryFg text, 11pt, shows current model
  short name from session info / config; tap → present ModelPickerView sheet).
  Human cron titles: derive "Automation · <job>" when title starts with
  "[IMPORTANT:" or source==cron (read C3 in /tmp/hermes-design-audit.md).
- Trailing: new-chat pencil → sessionStore.startDraft().
- Opaque themed nav bar (toolbarBackground(theme.toolbarBg, for: .navigationBar)
  + .visible).
- Draft/empty state: when sessionStore is in draft mode show a centered greeting
  ("What's on your mind?" caption mutedFg + Hermes glyph) instead of empty
  transcript.

## B3 flow-stores — owns Stores/SessionStore.swift, Stores/ChatStore.swift,
Stores/ConnectionStore.swift (minimal diffs)
1. DRAFT SESSIONS (kill empty-session litter): SessionStore.startDraft() sets
   activeRuntimeId=nil, activeStoredId=nil, isDraft=true, chat.reset()+seed([]).
   ChatStore.send(): when sessions.isDraft → first call session.create (96 cols),
   set active ids, isDraft=false, THEN submit prompt. openNew() becomes
   startDraft() (keep openNew as deprecated alias calling startDraft so existing
   callers compile; migrate callers you own). On launch (bootstrap success path)
   → startDraft() so the app lands on a fresh chat.
2. lastActivityAt registry: ConnectionStore router stamps
   sessionStore.noteActivity(storedSessionId or session_id→stored mapping) on
   message.delta/start events; SessionStore exposes func isLive(_ summary:) ->
   Bool (<10s). Lightweight, no timers except a 10s cleanup task.
3. Search machinery: ensure searchQuery/searchResults work headless (drawer
   consumes them; SessionListView may be retired).
PRESERVE: instant-open race token, REST-first refresh, mirror handling,
backfill semantics, queue drain hooks, spotlight hook.

## B4 pairing — owns Views/Onboarding/* (new), Support/QRScanner.swift (new),
App/HermesURLRouter.swift (pair route), AND server file
~/.hermes/hermes-agent/hermes_cli/mobile_pair.py (new) +
registering the subcommand (read hermes_cli/main.py argparse wiring; add
"mobile-pair" minimally where other subcommands register).
- WelcomeView: brand moment (app icon asset, "Hermes" title, one-liner),
  buttons: "Scan pairing code" (primary, theme.midground) + "Enter manually"
  (secondary → existing ConnectionSetupView pushed). Replaces bare setup as
  the needsSetup phase root (RootView shows it — coordinate with B1: B1 renders
  ConnectionStore.phase == .needsSetup → WelcomeView; you own WelcomeView).
- QRScannerView: AVCaptureSession + AVCaptureMetadataOutput (qr), camera
  permission handling, torch toggle; on scan of hermesapp://pair?url=...&token=...
  → connectionStore.configure(urlString:token:) → success transitions phase.
- HermesURLRouter: add the pair route (same params) so a tapped link works too.
- Server mobile-pair: python command printing (a) the hermesapp://pair URL with
  url=https Serve URL (auto-detect: read tailscale serve config via
  `tailscale serve status --json` for the first https proxy to the dashboard
  port, fall back to printing instructions) and token (read
  ~/.hermes/dashboard.token; HERMES_DASHBOARD_SESSION_TOKEN env override), and
  (b) an ANSI QR rendered in-terminal. QR: try `import qrcode` (pip install
  qrcode into the venv as part of your work; add to integrationNotes for
  upstream requirements), render with qrcode's ascii/ansi output. Token must
  NOT be logged anywhere else.
- Keep ConnectionSetupView as the manual fallback (it stays, polished later in D).

## B5 settings+push — owns Views/Chat/SettingsSheet.swift → rewrite as
Views/Settings/SettingsView.swift (push-based), Support/NotificationService.swift
(tap routing)
- SettingsView: NavigationStack-pushable root (NOT a sheet): sections
  Appearance (push AppearanceView) / Control panels (push each panel —
  navigationDestination, kill all inner .sheet) / Notifications / Security /
  Connection / Session / About. Panels already exist; they keep their own
  Done-less pushed form (strip their internal NavigationStack+Done when pushed
  — make panels presentation-agnostic: accept a `pushed: Bool` or detect via
  environment; simplest: remove their own NavigationStack wrappers and let the
  hosting stack provide the bar; verify AppearanceView too).
- Where it lives: pushed inside the drawer's NavigationStack (footer gear) —
  coordinate with B1 integrationNotes.
- Push tap routing: UNUserNotificationCenterDelegate didReceive(response) in
  NotificationService's delegate → extract session_id from userInfo (server
  sends {"session_id": sid} in payload; aps category in push_notify payloads) →
  hop to MainActor → route: approval/clarify → open that session (sessions.open
  after refresh-find) + ensure inbox visible if not found; turn_complete →
  open the session. Reuse HermesURLRouter.apply-style plumbing. Document any
  AppDelegate changes needed (PushRegistrar's delegate exists — extend, don't
  duplicate).
SettingsSheet.swift: delete after migrating references (SessionListView ref may
also be retiring under B1 — coordinate via integrationNotes; integrator resolves).

Return JSON: files, publicAPI, integrationNotes, risks. Parse-check Swift; ast
syntax-check Python.
