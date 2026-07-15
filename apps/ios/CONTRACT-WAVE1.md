# Wave 1 Contract — Engine Modules

Read INTERFACES.md first (all its rules apply). The app is LIVE and green —
72 tests. Engines in this batch create NEW FILES ONLY unless a file is
explicitly assigned to you. Integration into shared surfaces (ComposerView,
MessageBubble wiring, toolbars, AppEnvironment) happens in a later serial
pass — do NOT edit shared files outside your assignment, even if it means
your module isn't reachable from the UI yet.

## Verified server surfaces (all live on 127.0.0.1:9119, token-auth)

- `POST /api/audio/transcribe` {data_url: "data:<mime>;base64,...", mime_type}
  → {ok, transcript, provider}
- `POST /api/audio/speak` {text} → {ok, audio: "data:audio/...;base64,..."}
  (shape: read web_server.py:1381 for exact response keys before coding)
- `GET /api/sessions/search?q=<query>&limit=20` → {results: [...]} (FTS5;
  read web_server.py:1542 for row shape)
- `PATCH /api/sessions/{id}` body {"title": "..."} or {"archived": true}
- `GET /api/sessions/{id}/export` → transcript export (check format at :4552)
- `GET /api/cron/jobs`, `POST /api/cron/jobs/{id}/pause|resume|trigger`
- `GET /api/model/options`, `GET /api/model/info`, `POST /api/model/set`
- `GET /api/analytics/usage` (read :6422 for params/shape)
- `GET /api/skills` (read :6203)
- `GET /api/config` → includes agent.personalities map; set via WS RPC
  config.set {key: "personality", value: name, session_id?}
- WS RPC: prompt.submit accepts truncate_before_user_ordinal (Int, 1-based
  ordinal of user messages; error 4018 = stale)

Add new RestClient endpoints as EXTENSIONS in your own file
(`RestClient+<Area>.swift` in your directory) — never edit RestClient.swift.
Mirror its conventions: makeRequest is private, so build your own URLRequest
helpers in your extension file if needed (Host: 127.0.0.1 + X-Hermes-Session-Token
headers, 15s timeout); or route via a small internal helper you own.

## Module assignments

### E1 voice — owns `HermesMobile/Networking/Audio/`
- `VoiceRecorder.swift`: @MainActor @Observable. AVAudioSession (.playAndRecord,
  .measurement), AVAudioRecorder AAC .m4a; states idle/recording(elapsed)/
  transcribing; level metering (averagePower polled ~10Hz into `var level: Float`);
  `start()`, `cancel()`, `func stopAndTranscribe(rest:) async -> String?`
  (reads file → data URL "data:audio/mp4;base64," → transcribe endpoint).
  Mic permission flow (NSMicrophoneUsageDescription is already in project.yml —
  verify; if missing note it in your return, do not edit project.yml).
- `SpeechPlayer.swift`: @MainActor @Observable singleton-ish player:
  `speak(text:rest:) async` → /api/audio/speak → decode base64 data URL →
  AVAudioPlayer; `stop()`; `var speakingMessageId: UUID?` so bubbles can show
  state. One utterance at a time.
- `RestClient+Audio.swift`: transcribe(dataURL:mimeType:) + speak(text:).

### E2 queue — owns `HermesMobile/Stores/QueueStore.swift`
@MainActor @Observable. `struct QueuedPrompt: Identifiable, Codable {id: UUID,
text: String, createdAt: Date}`. API: `enqueue(_:)`, `update(id:text:)`,
`remove(id:)`, `var items: [QueuedPrompt]`, `func drain(chat: ChatStore) async`
— sends items FIFO via chat.send when chat not streaming; stops when streaming
starts (next drain on completion). Persistence: JSON in UserDefaults
"hermes.queue" on every mutation, loaded in init → THIS IS ALSO THE OFFLINE
OUTBOX (compose while disconnected → queued → drains on reconnect; document it).
Do not wire drain triggers (integration does).

### E3 rendering — owns `HermesMobile/Views/Chat/Rendering/`
- `MessageSegmenter.swift`: split markdown text into `[Segment]` where
  `enum Segment: Identifiable { case prose(String), code(language: String?,
  body: String) }` on ``` fences (handle unterminated fence while streaming —
  treat tail as code).
- `SyntaxHighlighter.swift`: regex-based AttributedString highlighter, NO deps.
  Languages: swift, python, javascript/typescript, bash/sh/zsh, json, yaml,
  go, rust, sql, html, css; default = plain monospaced. Theme: system colors
  (keywords .purple-ish, strings .red/.orange, comments .secondary, numbers
  .blue) — use Color(uiColor:) semantic-ish choices that read in dark+light.
  Keep it FAST: precompiled NSRegularExpression per language, cached.
- `CodeBlockView.swift`: rounded card, language badge, copy button
  (UIPasteboard + checkmark feedback), horizontal scroll, highlighter output,
  max-height 400 w/ expand toggle.
- `AnsiText.swift`: parse SGR codes (30-37/90-97 fg, bold, reset) →
  AttributedString; func `stripOrRender(_ text: String) -> AttributedString`.
- Unit tests welcome in `HermesMobileTests/RenderingTests.swift` (segmenter
  fences incl. streaming-tail, highlighter smoke, ANSI parse).

### E4 sessions — owns `HermesMobile/Stores/SessionStore.swift`,
`HermesMobile/Views/Shell/SessionListView.swift`,
`HermesMobile/Networking/Rest/RestClient+Sessions.swift` (new)
- Search: `.searchable` on the list; ≥2 chars → debounced (300ms)
  /api/sessions/search; render result rows (session title + matched snippet)
  → tapping opens the session (sessions.open with a SessionSummary built from
  the result or fetched).
- Pins: `Set<String>` in UserDefaults "hermes.pinnedSessions"; pinned section
  on top; swipe/context action Pin/Unpin (pin.fill icon).
- Rename: context menu → alert with TextField → PATCH {title}; update row.
- Archive: swipe action → PATCH {archived: true}; remove from list.
- Export: context menu → fetch /api/sessions/{id}/export → ShareLink/
  UIActivityViewController with the markdown text.
- Cron filter: toolbar Menu toggle "Hide automation sessions" (persisted
  "hermes.hideCron"); filters source=="cron" client-side.
- Keep ALL existing behavior (instant open, status pill, etc.) intact.

### E5 panels — owns `HermesMobile/Views/Panels/` +
`HermesMobile/Networking/Rest/RestClient+Control.swift` (new)
- `ModelPickerView.swift`: GET /api/model/options (read shape first) grouped
  list, current from /api/model/info, select → POST /api/model/set → confirm.
- `PersonalityPickerView.swift`: personalities from GET /api/config
  (agent.personalities keys + prompt preview) → config.set via WS
  {key:"personality", value:<name>, session_id: active runtime} (read
  tui_gateway/server.py config.set handler ~:4850 to confirm key name —
  adjust to what the server actually accepts; if per-session unsupported,
  apply globally and say so in a footnote in the UI).
- `GatewayStatusView.swift`: /api/status rendered: version, gateway state,
  platform states (telegram etc.), active sessions; pull-to-refresh.
- `UsageView.swift`: GET /api/analytics/usage (read :6422 first) — totals,
  per-day bars (simple Charts framework — first-party, allowed), per-skill
  table if available.
- `CronJobsView.swift`: GET /api/cron/jobs list (name, schedule, enabled,
  last run/status), actions: trigger now / pause / resume (POST endpoints).
- `SkillsBrowserView.swift`: GET /api/skills — grouped, searchable, read-only
  v1 (no toggle writes).
- Each view self-contained taking `rest: RestClient` (+ client where needed)
  via init; presentable in a sheet/push. NO toolbar wiring (integration does).

### E6 edit/retry/timer — owns `HermesMobile/Stores/ChatStore.swift`,
`HermesMobile/Views/Chat/ChatView.swift`, `HermesMobile/Views/Chat/MessageBubble.swift`
- ChatStore: track per-message user ordinal (assign when building/seeding:
  1-based count of user messages in transcript; store in ChatMessage? NO —
  Models are frozen; keep `private var userOrdinals: [UUID: Int]` rebuilt on
  seed and maintained on send/stream). Add:
  `func editAndResend(messageId: UUID, newText: String) async` →
  prompt.submit {text: newText, truncate_before_user_ordinal: ordinal} →
  on success locally truncate transcript before that user msg + append new
  user msg + streaming. Handle 4018 (stale) → backfill + lastError.
  `func retry(fromAssistantId: UUID) async` — find preceding user message,
  resubmit its text with its ordinal.
- MessageBubble: contextMenu on user bubbles (Edit, Copy), on assistant
  (Retry, Copy, Speak — Speak just posts a notification-style closure hook
  `var onSpeak: ((ChatMessage) -> Void)?` parameter defaulting nil; wiring
  later).
- ChatView: edit sheet (TextField prefilled, Save/Cancel); turn activity bar
  while streaming: thin bar above composer showing elapsed (timer from
  turnStartedAt — expose `var turnStartedAt: Date?` as private(set)) + current
  tool name + interrupt shortcut.
- PRESERVE all existing streaming/mirror/approval behavior. Run the existing
  unit tests mentally; do not break public API used by ConnectionStore.

## Rules recap
Swift 6 strict, iOS 17, @Observable, no third-party deps (Charts/AppIntents/
WidgetKit/AVFoundation/LocalAuthentication/VisionKit are first-party = fine).
Parse-check every file. Return structured: files, publicAPI, integrationNotes
(exact wiring the integrator must do), risks.
