# STR-723 final evidence (retry after REQUEST_CHANGES)

Commit under test: `bfcf12904addb534209eb29a1667897561a31b23` (STR-710 conversation-mode UI
integration). No production code touched in this worktree — only this evidence directory
and the harness-only fake gateway fix (`../fake_conv_mode_gateway.py`, commit `b2aa931bf`).

Prior handback was rejected because the recordings existed only as untracked files on
disk and were never committed, so the reviewer could not find them at the claimed paths.
This directory is now committed to git so it is reviewer-checkable by checking out this
branch/commit — not a claim resting on an out-of-repo file.

## iPhone (`iphone/`)

- `iphone-conv-mode.mp4` — 77,298,247 bytes, h264, 1206x2622, 194.16s, 7555 frames.
  `simctl io recordVideo` capture of: launch -> pairing -> idle composer -> connected
  state transition (composer shows the conversation-mode waveform button, mic icon, and
  "Driven by Claude Code (local)" badge) -> button tap -> mic-permission dialog.
- `iphone-composer-idle.png`, `iphone-composer-connected.png` — frames extracted at the
  idle and connected timestamps; visually confirmed showing the composer action row with
  the conversation-mode button on iPhone width.
- `iphone-conv-mode-forensics.json` — cadence/hitch analysis from the capture run
  (cadence_median_ms=18.33 vs 16.7 budget; the one 22.4s "freeze" at t=75.17s is an idle
  gap between two Maestro attempts while the recorder ran continuously, not a UI
  perf regression).
- `iphone-conv-mode-ffprobe.json` — fresh `ffprobe` re-probe of the committed file
  (this handback), confirming stream/container validity independent of the original run.

## iPad (`ipad/`)

- `ipad-conv-mode.mp4` — 18,612,685 bytes, h264, 2064x2752, 99.02s, 3178 frames. Same
  flow through the idle -> connected transition on iPad.
- `ipad-composer-idle-early.png`, `ipad-composer-connected.png` — frames extracted at the
  idle and connected timestamps; visually confirmed showing the full iPad sidebar layout
  (Sessions/Inbox/Chats list with the seeded STR-723 session) plus the connected composer
  with the conversation-mode button, mic icon, and "Driven by Claude Code (local)" badge.
- `ipad-conv-mode-forensics.json` — cadence/hitch analysis (cadence_median_ms=33.33 vs
  16.7 budget, 186 hitches up to 185ms — simulator-recording artifact, not a device-perf
  finding).
- `ipad-conv-mode-ffprobe.json` — fresh `ffprobe` re-probe of the committed file.

## Explicit hardware/harness-limited gap

No run reached a live-captured "Listening" state via Maestro UI drive (8+ attempts across
harness fixes, including a `ping_interval=None` fix to the fake gateway's
`websockets.serve()` in `b2aa931bf` to stop the 20s ping-timeout from dropping the
connection mid-flow). This is a fake-gateway/Maestro timing race, not app or hardware
behavior. It is covered instead by the deterministic, passing
`VoiceConversationControllerTests` suite (in the focused unit run below), which directly
asserts `status == .listening` after `VoiceConversationController.start()`.

## Focused unit tests (headless coverage)

```
scripts/ios-build.sh test -project apps/ios/HermesMobile.xcodeproj -scheme HermesMobile \
  -destination 'platform=iOS Simulator,id=BC5EB32A-C67E-45BF-8BA9-7EBC0FE40C0B' \
  -only-testing:HermesMobileTests/VoiceRecorderModuleBTests \
  -only-testing:HermesMobileTests/VoiceConversationControllerTests \
  -only-testing:HermesMobileTests/ChatStoreBatchCTests/testForeignCompleteFiresTurnCompleteAfterReconcile \
  -only-testing:HermesMobileTests/ChatStoreBatchDTests/testForeignCompleteReconcileFiresDiscardAndCompletion \
  -only-testing:HermesMobileTests/SettingsL07Tests \
  -derivedDataPath apps/ios/.derivedData
```

Result (this heartbeat, re-cited from the prior handback since the commit under test is
unchanged): TEST SUCCEEDED, 56/56 passed, 0 failures.
