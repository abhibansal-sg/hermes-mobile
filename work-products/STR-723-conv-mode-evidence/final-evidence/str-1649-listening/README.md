# STR-1649 evidence: attempt to capture live "Listening" state (hands-free voice mode)

**Result: Listening was NOT reached, on either device.** This is not a harness/timing gap
like the prior STR-723 attempts — it is a newly-discovered, deterministic, reproducible,
device-idiom-independent **app bug**: tapping `composerConversationModeButton` never causes
`ConversationModeStrip` (the mute/status/done-talking/stop UI) to mount. See "What actually
happened" below for the full evidence chain.

Per the dispatching reviewer's explicit constraint for this remediation pass, **zero
production code was touched** — this evidence run is a pure XCUITest addition plus its
mechanical `xcodegen generate` project-file diff, and this evidence directory. See "Files
changed" at the end of this document for the complete, exhaustive list.

## Commit under test

`28f77351e6e8b629119c0d66d203c2a0ff092306` (tip of `origin/environment-and-workflows-overview`
at the time of this run — "Merge pull request #15 from
abhibansal-sg/worktree-str273-relay-actionable-payload"). This branch (`str-1649-listening-evidence`)
was created directly from that commit; no other commits are in its history besides this
evidence commit.

## Test added

`apps/ios/HermesMobileUITests/VoiceListeningEvidenceUITests.swift` —
`testReachesListeningStateAndReArms()`. Skip-guarded on `HERMES_URL`/`HERMES_TOKEN` (same
convention as `ChatFlowUITests`/`ConnectionModePickerUITests`), so it stays green in CI
without a live gateway. It:

1. Launches the app pointed at a disposable local harness gateway via the existing,
   unmodified `ConnectionStore.bootstrap()` DEBUG dev-bootstrap env seam.
2. Waits for the connected draft-chat shell (`composerModelChip`, which — unlike
   `drawerToggle` — exists on both iPhone and iPad idioms; see "iPad-specific test fix"
   below for why the initial version of this test used the wrong identifier).
3. Waits for `composerConversationModeButton` to become enabled, taps it.
4. Waits for `conversationModeMuteButton` (proof `ConversationModeStrip` mounted) — **this
   is where every run failed, on both devices** — then, if it had mounted, would have gone
   on to assert `conversationModeDoneTalkingButton.isEnabled` (the direct proxy for
   `VoiceConversationController.status == .listening`), and exercised one
   listen→stop→re-arm cycle.

## Harness gateway

`work-products/STR-723-conv-mode-evidence/final-evidence/str-1649-listening/harness/fake_conv_mode_gateway.py`
— copied verbatim from commit `b2aa931bf` (see its own provenance docstring), unmodified.
Run for this evidence pass as:

```
python3 work-products/STR-723-conv-mode-evidence/final-evidence/str-1649-listening/harness/fake_conv_mode_gateway.py \
  --port 9847 --log /tmp/str1649-fakegw.log
```

## Exact commands run (both devices)

```
xcrun simctl privacy <udid> grant microphone ai.hermes.app
xcrun simctl bootstatus <udid> -b

xcrun simctl io <udid> recordVideo --codec=h264 <out>.mp4 &   # backgrounded; kill -INT to stop cleanly

export TEST_RUNNER_HERMES_URL="http://127.0.0.1:9847"
export TEST_RUNNER_HERMES_TOKEN="fake-token-str1649"
scripts/ios-build.sh test -project apps/ios/HermesMobile.xcodeproj -scheme HermesMobile \
  -destination "platform=iOS Simulator,id=<udid>" \
  -only-testing:HermesMobileUITests/VoiceListeningEvidenceUITests \
  -derivedDataPath apps/ios/.derivedData
```

Devices used (per device policy — "iPhone Air" is deny-listed and was never used):
- iPhone 17 Pro, `0A7E9ADD-A221-40E9-8A23-FDF66B38F2A2`
- iPad Pro (13-inch) (M4), `E1F3DEEA-AD29-4031-BFBA-4AEA0CAE4AA4`

**Important self-correction during this run**: `scripts/ios-build.sh` auto-provisions live
`:9200` dev-gateway credentials into `TEST_RUNNER_HERMES_URL`/`TEST_RUNNER_HERMES_TOKEN`
*unless those exact variable names are already exported in the calling shell* — passing them
only as trailing xcodebuild-style CLI settings is not sufficient, because the script's own
pre-flight check runs before argument parsing. An earlier run in this pass accidentally hit
the real `:9200` gateway this way (confirmed via `composerModelChip` reading a real model
name and the drawer's session-group header reading a real session count) and was discarded.
All captures kept in this directory were re-run with `TEST_RUNNER_HERMES_URL`/
`TEST_RUNNER_HERMES_TOKEN` correctly exported beforehand, and independently confirmed
isolated via (a) `composerModelChip` reading `"Model: ui-evidence-fake"` in both UI hierarchy
dumps below, and (b) cross-referencing the fake gateway's own JSON event log
(`/tmp/str1649-fakegw.log`, not committed — ephemeral run log) timestamps against each test
run's start/end.

**iPad-specific test fix (test-only, not production code)**: the first two iPad attempts
failed waiting for `drawerToggle` (the hamburger button `ChatFlowUITests`/STR-723's iPhone
evidence uses as its "connected" proof) — it never appears on iPad, because iPad uses a
permanently-visible `NavigationSplitView` sidebar column with no hamburger toggle at all. A
screen-recording frame extracted from that run showed the iPad app was in fact fully
connected (see the identical connected-shell layout in `ipad-frame-19s.png` below) — the
failure was purely an identifier mismatch in the test's own precondition wait, not an app
connectivity problem. Fixed by waiting on `composerModelChip` instead (exists on both
idioms, only renders once `configure()` has verified the connection) — see the code comment
at `VoiceListeningEvidenceUITests.swift:61-69`.

## What actually happened

On **both** iPhone and iPad, with a confirmed-isolated fake gateway, the app reaches the
connected draft-chat shell, the conversation-mode button becomes enabled, and the tap is
delivered — but `ConversationModeStrip` never mounts. The test fails at the identical
assertion, with the identical message, on both devices:

- iPhone: `VoiceListeningEvidenceUITests.swift:90: XCTAssertTrue failed - ConversationModeStrip (conversationModeMuteButton) did not mount — voice.start() did not enable conversation mode`
- iPad: `VoiceListeningEvidenceUITests.swift:96: XCTAssertTrue failed - ConversationModeStrip (conversationModeMuteButton) did not mount — voice.start() did not enable conversation mode`

(Line numbers differ only because of the extra iPad-only doc comment added for the
`composerModelChip` fix.)

This was reproduced identically across 5 total independent verification mechanisms over the
course of this remediation effort (2 XCUITest runs before this evidence pass, 1 manual `axe`-driven
repro, plus the 2 clean, isolated-gateway XCUITest runs captured here) — it is not flaky, not
an artifact of gateway contamination (ruled out above), not a mic-permission-dialog
obstruction (no mic dialog exists in this app's flow prior to `ConversationModeStrip`
mounting — confirmed by the UI hierarchy dumps below showing no alert/dialog element at any
point), and not an XCUITest event-synthesis problem (the tap registers — the button's
accessibility hierarchy position doesn't change and no error is thrown by `.tap()`).

The `conversationModeMuteButton`/`conversationModeDoneTalkingButton`/
`conversationModeStopButton` elements never appear anywhere in the post-tap accessibility
tree on either device (see the `*-ui-hierarchy-at-failure.txt` dumps — grep for
`conversationMode` returns only `composerConversationModeButton` itself, still reading label
`"Start conversation mode"`, i.e. never transitioned to its active/toggled state).

**No production code investigation into the root cause was performed** beyond what was
necessary to build this test, per the dispatching reviewer's explicit "no production code
changes, ever" constraint for this remediation pass — this finding is reported, not fixed,
and no attempt was made to patch around it.

## iPhone (`iphone/`)

- `iphone-listening-attempt.mp4` — `simctl io recordVideo` capture, 14,999,425 bytes, h264,
  1206x2622, 44.418333s, 1202 frames. Shows: launch → connected draft shell → tap on the
  conversation-mode button → nothing further happens (idle draft screen persists for the
  remainder of the recording) → test's clean hard-stop / app teardown.
- `iphone-listening-attempt-ffprobe.json` — fresh `ffprobe` re-probe of the above file.
- `iphone-xcodebuild-autorecording.mp4` — the automatic xcodebuild-attached screen recording
  for the same test run (from the `.xcresult` bundle), 8,498,280 bytes, h264, 1206x2622,
  19.283333s.
- `iphone-01-idle-connected.png` — the test's own `01-idle-connected` XCTAttachment
  screenshot, taken right after the connected shell appears (step 1).
- `iphone-frame-02s.png`, `iphone-frame-06s.png`, `iphone-frame-10s.png`,
  `iphone-frame-14s.png`, `iphone-frame-18s.png` — `ffmpeg`-extracted frames from
  `iphone-xcodebuild-autorecording.mp4` at 2/6/10/14/18s. Visually confirmed (frame-by-frame
  read): all five frames show the identical connected idle-draft composer — "Evening."
  greeting, `ui-evidence-fake` model chip, waveform conversation-mode button, "Message
  Hermes..." placeholder, "Driven by Claude Code (local)" badge. `iphone-frame-06s.png`
  (pre-tap) and `iphone-frame-18s.png` (well after the tap, which happens ~9-10s into the
  test per the xcodebuild log) are pixel-identical — direct visual proof the tap produced no
  UI change.
- `iphone-ui-hierarchy-at-failure.txt` — full accessibility-tree dump captured by XCTest at
  the moment of failure. Confirms `composerModelChip` reads `"Model: ui-evidence-fake"`
  (isolated-gateway proof) and `composerConversationModeButton` still reads `"Start
  conversation mode"` (never transitioned); no `conversationMode*` strip elements exist
  anywhere in the tree.

## iPad (`ipad/`)

- `ipad-listening-attempt.mp4` — `simctl io recordVideo` capture, 23,241,863 bytes, h264,
  2064x2752, 55.005s, 884 frames. Same flow through connected shell → tap → no further
  change → clean teardown.
- `ipad-listening-attempt-ffprobe.json` — fresh `ffprobe` re-probe.
- `ipad-xcodebuild-autorecording.mp4` — automatic xcodebuild screen recording for the same
  run, 7,209,268 bytes, h264, 2064x2752, 20.271667s.
- `ipad-01-idle-connected.png` — the test's `01-idle-connected` XCTAttachment screenshot.
- `ipad-frame-02s.png`, `ipad-frame-08s.png`, `ipad-frame-14s.png`, `ipad-frame-19s.png` —
  extracted frames from `ipad-xcodebuild-autorecording.mp4`. All show the full iPad sidebar
  layout (Hermes Agent / Sessions / Projects / Archived Chats / Inbox / Automation / the
  seeded "STR-723 Conversation Mode..." chat) plus the connected composer with the
  `ui-evidence-fake` model chip and waveform conversation-mode button. `ipad-frame-19s.png`
  (well after the tap) is visually identical to the pre-tap frames — same conclusion as
  iPhone: no UI change after the tap.
- `ipad-ui-hierarchy-at-failure.txt` — accessibility-tree dump at failure. Same confirmation
  as iPhone: `composerModelChip` = `"Model: ui-evidence-fake"`,
  `composerConversationModeButton` still `"Start conversation mode"`, no `conversationMode*`
  strip elements present.

## Explicit, honest answers to the dispatcher's report-back questions

- **Was Listening reached on iPhone?** No. Evidence: `iphone-ui-hierarchy-at-failure.txt`,
  `iphone-listening-attempt.mp4`, the assertion failure at `VoiceListeningEvidenceUITests.swift:90`.
- **Was Listening reached on iPad?** No. Evidence: `ipad-ui-hierarchy-at-failure.txt`,
  `ipad-listening-attempt.mp4`, the assertion failure at `VoiceListeningEvidenceUITests.swift:96`.
- **Was a full listen→response→re-listen cycle reached on either?** No — the test never got
  past step 3 (waiting for `ConversationModeStrip` to mount) on either device, so steps 4-7
  (Listening confirmation, the no-speech re-arm cycle, and the clean stop) were never
  exercised. What stopped it: `conversationModeMuteButton` never appears in the
  accessibility tree after tapping `composerConversationModeButton`, on both devices,
  deterministically, with a confirmed-isolated gateway.
- **Production code touched?** Zero. See "Files changed" below for the complete list — every
  file is either the new test, work-products evidence, or the mechanical `xcodegen generate`
  project-file diff.

## Files changed on this branch (`str-1649-listening-evidence`, based on
`origin/environment-and-workflows-overview` @ `28f77351e`)

- `apps/ios/HermesMobileUITests/VoiceListeningEvidenceUITests.swift` (new) — the evidence
  test itself.
- `apps/ios/HermesMobile.xcodeproj/project.pbxproj` (mechanical `xcodegen generate` diff to
  register the new test file — 8 insertions, 4 deletions, no other changes).
- `work-products/STR-723-conv-mode-evidence/final-evidence/str-1649-listening/**` (new
  directory — this README, the harness gateway script, and all evidence files listed above).
  Does **not** modify or overwrite the pre-existing
  `work-products/STR-723-conv-mode-evidence/final-evidence/README.md` /
  `iphone/` / `ipad/` from the prior STR-723 run.

No other files were touched.
