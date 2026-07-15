# UI Batch C Contract — Chat Surface

Rules: INTERFACES.md rules recap; theme engine live (consume @Environment(\.hermesTheme));
Batch B landed first — READ the post-B state of every file you touch (drawer
navigation, draft sessions, model chip exist). Keep all tests green.
Locked decisions: hybrid tool rows, agent gutter, mic-in-field morph composer
with tap-to-record AND hold-to-talk, share lands in its session.

## C1 transcript — owns Stores/ChatStore.swift (tool-collapse state only),
Views/Chat/MessageBubble.swift, Views/Chat/ToolActivityRow.swift
1. HYBRID TOOL ROWS: while a turn streams, individual ToolActivityRow entries
   render live (current behavior, restyled: theme.muted container, 12pt indent,
   leading state icon, 6pt intra-cluster spacing). When message.complete
   finalizes the turn AND the turn had ≥2 tools, the rows collapse into ONE
   summary row: "⚙ N tool calls · Xs" (sum of durations or turn elapsed),
   theme.muted capsule, tap to expand the full timeline (DisclosureGroup).
   1 tool → keep the single row (no summary indirection). Persisted transcripts
   (seeded from REST) have no live phase: tool messages already collapse via
   the classify() presentation — leave that path; this applies to LIVE turns.
   Implementation: ChatMessage already holds tools[]; add a presentation flag
   on the message (toolsCollapsed: Bool, set true in handleMessageComplete) —
   Models are parent-owned but ChatModels.swift may be extended: add the var
   with default false (additive, safe).
2. AGENT GUTTER: assistant message body gets a 2pt vertical theme.midground
   rule (30% opacity) down the leading edge + 12pt content inset; user bubbles
   unchanged. Gutter spans thinking + tools + text as one visual unit.
3. PROSE: paragraph spacing 12 (spacing between segments), .lineSpacing(3.5)
   on prose Text, list rendering: detect markdown ordered/unordered list lines
   in MessageSegmenter prose and render with hanging indent (firstLineHeadIndent
   0, headIndent 18) via AttributedString paragraph styles + monospacedDigit
   for ordinals. Keep streaming-cursor behavior.

## C2 composer — owns Views/Chat/ComposerView.swift, Networking/Audio/VoiceRecorder.swift
(additive API only on the recorder)
Rebuild the composer per locked design:
- Leading: "+" (attachments menu: Photo Library / Camera / Scan Document —
  preserve all existing wiring incl. thumbnails strip + queue chip + recording
  permission alerts).
- Field: themed pill (theme.muted fill, theme.input border 1pt,
  theme.composerRing border when focused), placeholder "Message Hermes…".
- Trailing INSIDE the field: mic icon when text empty; morphs (symbolEffect
  .replace) to send arrow (theme.midground, filled circle) when text non-empty
  or attachments pending. While streaming: stop icon (interrupt) replaces both.
- TAP mic → existing recording strip flow (restyle: strip uses theme.card bg,
  waveform bars theme.midground, elapsed time, cancel X, checkmark →
  transcribe → insert into field).
- LONG-PRESS mic (≥0.35s) → hold-to-talk: record while pressed (strip shows
  "release to transcribe"), on release → stopAndTranscribe → insert. On slide-
  away-cancel (drag >80pt off the button) → cancel(). Use a
  LongPressGesture+DragGesture sequence; haptic on start/stop.
- Queue affordance preserved (chip above, queue icon while streaming per
  current behavior — verify it survives the rebuild).

## C3 share-landing — owns Support/SharedInboxDrainer.swift (+ minimal
SessionStore call)
After draining shared items into a new session, navigate there: call
sessionStore.open on the created session (the drainer creates sessions —
capture the stored/runtime id it produced; if multiple items → land on the
LAST created). Coordinate via existing store APIs only; document if you need
a B3 API that doesn't exist (integrator adds).

Return JSON: files, publicAPI, integrationNotes, risks. Parse-check everything.
