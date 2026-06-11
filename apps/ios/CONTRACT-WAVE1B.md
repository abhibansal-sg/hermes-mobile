# Wave 1B Contract — System Modules

Same ground rules as CONTRACT-WAVE1.md (read INTERFACES.md + that file's
"Rules recap"). These modules run AFTER the engine batch integrates, so the
engines (VoiceRecorder, SpeechPlayer, QueueStore, panels, rendering) exist
and are wired. New files only unless assigned.

## S1 approval-inbox — owns `HermesMobile/Stores/InboxStore.swift` +
`HermesMobile/Views/Inbox/InboxView.swift`
- InboxStore: @MainActor @Observable. Accumulates ALL approval.request /
  clarify.request events (every session — the gateway broadcast delivers
  them globally; events carry session_id + stored_session_id). Items:
  {id, sessionId, storedSessionId?, kind(approval|clarify), payload, receivedAt,
  state(pending|answered|expired)}. Answer via approval.respond /
  clarify.respond against the item's OWN sessionId. Remove on answer; mark
  expired when a message.complete arrives for that session (the turn moved on).
  Wired from ConnectionStore's router (integration will add one call — document
  the exact hook in integrationNotes).
- InboxView: list of pending items (session title lookup via SessionStore
  if loaded, else id), approve/deny/answer inline, empty state, badge count
  exposed as `var pendingCount: Int` for toolbar badges.

## S2 app-intents — owns `HermesMobile/Intents/`
AppIntents framework. Intents: AskHermesIntent (parameter: prompt String;
opens app to new session with prompt prefilled+sent — use a pending-intent
handoff via UserDefaults "hermes.pendingIntentPrompt" that HermesMobileApp
checks on scenePhase active — document hook), OpenSessionsIntent,
NewSessionIntent. AppShortcutsProvider with phrases ("Ask Hermes …").
Keep intents lightweight: they deep-link into the running app rather than
opening their own gateway connections.

## S3 security-capture — owns `HermesMobile/Support/AppLock.swift`,
`HermesMobile/Support/DocumentScanner.swift`, `HermesMobile/Support/TailscaleHint.swift`
- AppLock: LocalAuthentication; @Observable; if UserDefaults
  "hermes.appLockEnabled" → on launch + on foreground-after-5min, overlay
  blur + Face ID prompt. Toggle lives in SettingsSheet (integration wires).
- DocumentScanner: VisionKit VNDocumentCameraViewController wrapped for
  SwiftUI; returns scanned pages as JPEG Data array (feeds AttachmentStore).
- TailscaleHint: helper that, given a connection failure to a *.ts.net host,
  produces a hint banner model ("Is Tailscale connected?") with a button
  opening tailscale:// (UIApplication.open; canOpenURL needs
  LSApplicationQueriesSchemes "tailscale" — note for project.yml in
  integrationNotes, do not edit).
## S4 capture-misc — owns `HermesMobile/Support/SpotlightIndexer.swift`,
`HermesMobile/Views/Capture/QuickCaptureView.swift`
- SpotlightIndexer: CoreSpotlight; index sessions (title/preview) on refresh
  (hook documented, called from SessionStore.refresh by integrator);
  NSUserActivity per opened session for Handoff-lite.
- QuickCaptureView: "to GBrain" sheet — text field + mic button (VoiceRecorder)
  → sends to a NEW session with the prompt prefixed
  "Store this in the brain (gbrain): " then shows the turn inline minimal;
  presented from session list toolbar (integration wires).

## S5 ipad — owns `HermesMobile/Views/Shell/RootView.swift` (exclusive)
Three-column NavigationSplitView on regular width: sidebar (SessionListView),
content (ChatView), detail-or-inspector optional (InboxView toggleable).
Keyboard shortcuts: Cmd+N new session, Cmd+F search focus (via @FocusState
bridge — keep simple), Cmd+. interrupt. Preserve all existing compact-width
behavior and the connection-phase routing EXACTLY.

Return JSON: files, publicAPI, integrationNotes, risks.
