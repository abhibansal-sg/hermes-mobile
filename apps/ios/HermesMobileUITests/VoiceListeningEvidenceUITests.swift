import XCTest

/// STR-1649 evidence: proves the app can reach `VoiceConversationController`'s
/// live `.listening` state — not just the "connected" composer state a prior
/// evidence review rejected (STR-344/STR-1328 child; PR#64 "hands-free voice
/// conversation mode").
///
/// ROOT CAUSE of every prior no-Listening-video attempt (8+, see the STR-723
/// evidence README): all of them raced a system mic-permission alert the
/// harness couldn't reliably dismiss. That alert is irrelevant to reaching
/// Listening — `VoiceConversationController.beginListening()`
/// (`Networking/Audio/VoiceConversationController.swift`) sets
/// `status = .listening` SYNCHRONOUSLY, before the awaited mic-hardware start,
/// so the live "Listening" UI renders immediately on tap regardless of mic
/// permission or gateway health. Granting mic permission at the OS level
/// BEFORE launch (`xcrun simctl privacy <udid> grant microphone ai.hermes.app`,
/// done out-of-band by the capture script, NOT by this test) simply keeps the
/// (irrelevant but visually obstructive) system alert from ever appearing.
///
/// This test touches ZERO production code paths beyond what
/// `ChatFlowUITests`/`ConnectionModePickerUITests` already exercise: it drives
/// the existing, unmodified `HERMES_URL`/`HERMES_TOKEN` DEBUG dev-bootstrap
/// seam (`ConnectionStore.bootstrap()`) against a disposable local harness
/// gateway (`work-products/STR-723-conv-mode-evidence/final-evidence/
/// str-1649-listening/harness/fake_conv_mode_gateway.py` — the STR-723
/// evidence run's own fixture, reused verbatim), reaches the connected
/// draft-chat shell exactly like `ChatFlowUITests`, then taps the real
/// `composerConversationModeButton`.
///
/// Requires `HERMES_URL`/`HERMES_TOKEN` in the test-runner environment (the
/// harness gateway above, started out-of-band before the test run — see the
/// evidence README for the exact commands). Skip-guarded like the other live
/// UITests so it stays green in CI without a gateway.
final class VoiceListeningEvidenceUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testReachesListeningStateAndReArms() throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["HERMES_URL"], let token = env["HERMES_TOKEN"],
              !url.isEmpty, !token.isEmpty else {
            throw XCTSkip("HERMES_URL/HERMES_TOKEN not provided; skipping live voice-listening capture")
        }

        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        // Clear any saved config so this is a fresh, deterministic first-run
        // launch (same convention as ConnectionModePickerUITests).
        app.launchArguments += ["-hermes.serverURL", ""]
        app.launchArguments += ["-hermes.connectionMode", ""]
        // Mutes TTS auto-speak only (UITestAudioGuard) — does not affect
        // reaching `.listening`, just avoids a hang waiting on real playback
        // for audio the harness gateway can never produce.
        app.launchArguments += ["--uitest-mute-audio"]
        app.launchEnvironment["HERMES_URL"] = url
        app.launchEnvironment["HERMES_TOKEN"] = token
        app.launch()

        // 1. Connected chat shell (draft home). `drawerToggle` (the STR-723/
        //    ChatFlowUITests "connected" proof) is iPhone-only — on iPad the
        //    sidebar is a permanently-visible NavigationSplitView column with
        //    no hamburger toggle, so that identifier never exists there
        //    (confirmed via a live capture: the connected draft home, model
        //    chip, and composer all render identically on iPad, just without
        //    a `drawerToggle` element). Wait on `composerModelChip` instead —
        //    it exists on both idioms and only renders once `configure()`
        //    has verified the connection.
        let modelChip = app.buttons["composerModelChip"]
        XCTAssertTrue(
            modelChip.waitForExistence(timeout: 30),
            "Connected chat shell (draft home) did not appear"
        )
        attach(app.screenshot(), name: "01-idle-connected")

        // 2. The conversation-mode button is `.disabled(!isConnected)`; a fresh
        //    draft satisfies `isConnected` the instant the phase is `.connected`
        //    (see ChatView.isConnected), so it should become enabled quickly.
        let convButton = app.buttons["composerConversationModeButton"]
        XCTAssertTrue(
            convButton.waitForExistence(timeout: 15),
            "composerConversationModeButton did not appear"
        )
        XCTAssertTrue(
            waitUntilEnabled(convButton, timeout: 15),
            "composerConversationModeButton never became enabled (isConnected never true)"
        )
        convButton.tap()

        // 3. `voice.start()` -> `beginListening()` sets `status = .listening`
        //    SYNCHRONOUSLY before any mic/network I/O, so the ConversationModeStrip
        //    (mute / status-label / done-talking / stop) should mount almost
        //    immediately.
        let muteButton = app.buttons["conversationModeMuteButton"]
        XCTAssertTrue(
            muteButton.waitForExistence(timeout: 10),
            "ConversationModeStrip (conversationModeMuteButton) did not mount — voice.start() did not enable conversation mode"
        )

        // 4. PRIMARY, deterministic Listening proof: `conversationModeDoneTalkingButton`
        //    is `.disabled(!isListening)` in ComposerView's `ConversationModeStrip` —
        //    its `isEnabled` flag is a direct, non-fuzzy proxy for
        //    `VoiceConversationController.status == .listening`.
        let doneTalking = app.buttons["conversationModeDoneTalkingButton"]
        XCTAssertTrue(doneTalking.waitForExistence(timeout: 5), "conversationModeDoneTalkingButton not found")
        XCTAssertTrue(
            waitUntilEnabled(doneTalking, timeout: 10),
            "Never reached Listening — conversationModeDoneTalkingButton stayed disabled"
        )
        attach(app.screenshot(), name: "02-listening")

        // 5. SECONDARY, human-readable proof (best-effort, not a hard requirement):
        //    `Text(controller.statusLabel)` lives inside a `VStack` wrapped in
        //    `.accessibilityElement(children: .combine)`, so "Listening" may not
        //    surface as a distinct `staticTexts["Listening"]` element — search all
        //    descendants for ANY element whose label mentions "listening".
        let listeningLabel = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] %@", "listening")
        ).firstMatch
        _ = listeningLabel.waitForExistence(timeout: 5)  // informational only; see README

        // 6. Exercise one "listen -> stop -> re-arm" cycle. The harness gateway
        //    implements no `/api/audio/transcribe` endpoint, so `stopAndTranscribe`
        //    always comes back nil/empty — which RE-ARMS Listening rather than
        //    submitting a turn (see `VoiceConversationController.handleTurn`'s
        //    empty-transcript path). This is the honest "no-speech re-arm" leg of
        //    the loop, NOT a full listen->response->re-listen cycle (no real
        //    STT/LLM exists in this harness) — see the evidence README.
        doneTalking.tap()
        XCTAssertTrue(
            waitUntilEnabled(doneTalking, timeout: 15),
            "Did not re-arm to Listening after Done-talking (no-speech re-arm path)"
        )
        attach(app.screenshot(), name: "03-relistening")

        // 7. Clean hard-stop so the run doesn't leave conversation mode armed.
        let stopButton = app.buttons["conversationModeStopButton"]
        if stopButton.waitForExistence(timeout: 5) {
            stopButton.tap()
        }
    }

    // MARK: - Helpers

    private func attach(_ screenshot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Waits for `element.isEnabled` to become true, using the standard
    /// XCUITest predicate-expectation mechanism (polls the accessibility tree
    /// without busy-looping the test's own thread).
    private func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "isEnabled == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
