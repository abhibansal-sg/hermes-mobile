# iOS Chat Thread Ordered Parts — 2026-06-07

## Summary

The iOS chat thread now uses the desktop chat surface as the semantic reference
without cloning the desktop UI. Assistant turns can carry ordered native parts:

- `reasoning`
- `tools`
- `text`
- `warning`
- `usage`

The legacy `ChatMessage.text`, `thinking`, `tools`, `warning`, and `usage`
fields remain as the compatibility layer for existing copy/retry/checkpoint
behavior and tests.

## Files Changed

- `apps/ios/HermesMobile/Models/ChatModels.swift`
  - Added `ChatMessagePart`.
  - Added `ChatMessage.assistantRenderParts`.
  - Added mutation helpers that keep legacy fields and ordered parts in sync.
- `apps/ios/HermesMobile/Stores/ChatStore.swift`
  - Streaming text/reasoning deltas now append ordered parts.
  - Tool start/progress/complete updates ordered tool clusters.
  - Pending text/reasoning buffers flush before `tool.start`, preserving
    desktop-style `text -> tool -> text` transcript order.
  - Completion/warning/usage updates flow through the ordered part model.
- `apps/ios/HermesMobile/Views/Chat/MessageBubble.swift`
  - Assistant body now renders `assistantRenderParts` using native SwiftUI
    renderers (`ThinkingView`, `ToolClusterView`, markdown/code text, warning,
    usage footer).
- `apps/ios/HermesMobileTests/ProtocolParityABH46Tests.swift`
  - Added `testAssistantPartsPreserveTextToolTextOrder`.

## Verification

Environment:

- Project: `apps/ios/HermesMobile.xcodeproj`
- Scheme: `HermesMobile`
- Simulator: iPhone 17 Pro, iOS 26.5

Commands run through XcodeBuildMCP:

- Simulator build: passed.
- `HermesMobileTests`: passed, 357 passed / 4 skipped.
- Focused regression:
  `HermesMobileTests/ProtocolParityABH46Tests/testAssistantPartsPreserveTextToolTextOrder`
  passed.

## What This Does Not Yet Solve

- Stored-history reconstruction still mostly seeds assistant text from REST and
  collapses raw tool/system rows; it does not yet rebuild full ordered tool
  timelines from historical tool-call records.
- Markdown/media parity is still below desktop: no full desktop-equivalent
  table/math/media/preview rendering yet.
- This was not live-tested against a real gateway turn in the simulator UI.

## Manual Test Path

1. Launch the iOS app against the shared Hermes gateway.
2. Send a prompt that forces text before and after a tool call, for example:
   `Say "before", run a harmless shell command like pwd, then say "after".`
3. Expected native transcript shape:
   - user bubble remains trailing/native
   - assistant document/gutter remains native
   - first assistant text appears
   - tool row appears inline after that text
   - later assistant text appears after the tool row
4. Also test a normal no-tool prompt and a multi-tool prompt to confirm the
   existing text-only and collapsed tool-cluster paths still behave normally.
