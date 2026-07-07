import XCTest
@testable import HermesMobile

/// STR-344 / STR-531 — focused unit coverage for the voice-conversation
/// orchestration state machine. Drives the full loop with fakes (no mic / TTS /
/// network) because the controller performs no I/O itself — every effect is an
/// injected closure.
///
/// Coverage maps to the contract's required evidence:
///  - start → listening
///  - silence / no-speech re-arms listening (does not submit)
///  - non-empty transcript: transcribing → thinking, auto-submit
///  - reply speaking → idle → listening (re-arm)
///  - empty reply re-arms
///  - mute prevents re-arm / cancels the capture
///  - hard stop cancels stale transcription AND stale speech completion
///    (the generation guard — the core stale-cancellation invariant)
@MainActor
final class VoiceConversationControllerTests: XCTestCase {

    // MARK: - start → listening

    func testStartEnablesModeAndBeginsListening() async {
        let (controller, fake) = makeController()
        XCTAssertEqual(controller.status, .idle)
        XCTAssertFalse(controller.isEnabled)

        await controller.start()

        XCTAssertEqual(controller.status, .listening, "start() must arm the first listen")
        XCTAssertTrue(controller.isEnabled)
        XCTAssertEqual(fake.startListeningCount, 1)
        XCTAssertEqual(fake.cancelListeningCount, 0)
    }

    func testStartIsReentrantAndHardStopsPriorSession() async {
        let (controller, fake) = makeController()
        await controller.start()
        XCTAssertEqual(controller.status, .listening)

        // A second start() must end the prior session (hard stop) first.
        await controller.start()

        XCTAssertEqual(controller.status, .listening, "re-entry re-arms a clean listen")
        // cancelListening fires once for the end() inside the second start().
        XCTAssertGreaterThanOrEqual(fake.cancelListeningCount, 1)
    }

    // MARK: - no-speech / empty transcript re-arms (no submit)

    func testNilTranscriptRearmsListeningWithoutSubmitting() async {
        let (controller, fake) = makeController()
        fake.nextTranscript = nil
        await controller.start()

        await controller.stopTurn(forceTranscribe: false)

        XCTAssertEqual(controller.status, .listening, "no-speech must re-arm, not sit idle")
        XCTAssertEqual(fake.startListeningCount, 2, "re-arm begins a second listen")
        XCTAssertTrue(fake.submittedTranscripts.isEmpty, "nil transcript must never be submitted")
    }

    func testEmptyTranscriptRearmsListeningWithoutSubmitting() async {
        let (controller, fake) = makeController()
        fake.nextTranscript = "   "
        await controller.start()

        await controller.stopTurn(forceTranscribe: false)

        XCTAssertEqual(controller.status, .listening)
        XCTAssertTrue(fake.submittedTranscripts.isEmpty, "whitespace-only transcript must not submit")
        XCTAssertEqual(fake.startListeningCount, 2)
    }

    // MARK: - transcript auto-submit: transcribing → thinking

    func testNonEmptyTranscriptSubmitsAndEntersThinking() async {
        let (controller, fake) = makeController()
        fake.nextTranscript = "  hello there  "
        await controller.start()

        await controller.stopTurn(forceTranscribe: false)

        XCTAssertEqual(controller.status, .thinking, "submitted transcript enters thinking")
        XCTAssertEqual(fake.submittedTranscripts, ["hello there"], "transcript is trimmed then auto-submitted")
        XCTAssertEqual(fake.startListeningCount, 1, "no re-arm while thinking")
    }

    func testStopTurnIsNoOpOutsideListening() async {
        let (controller, fake) = makeController()
        fake.nextTranscript = "hello"
        await controller.start()
        await controller.stopTurn(forceTranscribe: false)
        XCTAssertEqual(controller.status, .thinking)

        // A stray stopTurn while thinking must do nothing.
        await controller.stopTurn(forceTranscribe: false)
        XCTAssertEqual(controller.status, .thinking)
        XCTAssertEqual(fake.submittedTranscripts.count, 1)
    }

    // MARK: - reply speaking → idle → listening (re-arm)

    func testNonEmptyReplySpeaksThenRearms() async {
        let (controller, fake) = makeController()
        await reachThinking(controller: controller, fake: fake)

        await controller.handleTurnComplete(replyText: "  hi there  ")

        XCTAssertEqual(controller.status, .listening, "after speaking the loop re-arms")
        XCTAssertEqual(fake.spokenTexts, ["hi there"], "reply is trimmed then spoken")
        // startListening: initial + re-arm after speaking.
        XCTAssertEqual(fake.startListeningCount, 2)
    }

    func testAutoSpeakHandoffSpeaksOnlyLatestNewCompletedAssistantReply() async {
        let (controller, fake) = makeController()
        let chat = ChatStore()
        let coordinator = VoiceConversationAutoSpeakCoordinator()
        let alreadySpokenId = UUID()
        let userId = UUID()
        let streamingId = UUID()
        let blankId = UUID()
        let firstReplyId = UUID()
        chat.messages = [
            ChatMessage(id: alreadySpokenId, role: .assistant, text: "old reply"),
            ChatMessage(id: userId, role: .user, text: "latest user row"),
            ChatMessage(id: streamingId, role: .assistant, text: "still streaming", isStreaming: true),
            ChatMessage(id: blankId, role: .assistant, text: "   "),
            ChatMessage(id: firstReplyId, role: .assistant, text: "  speak me  "),
        ]
        await reachThinking(controller: controller, fake: fake)

        await coordinator.handleTurnComplete(chat: chat, controller: controller)

        XCTAssertEqual(fake.spokenTexts, ["speak me"])
        XCTAssertEqual(controller.status, .listening, "speech completion re-arms through the controller")

        fake.nextTranscript = "second prompt"
        await controller.stopTurn(forceTranscribe: false)
        XCTAssertEqual(controller.status, .thinking)

        await coordinator.handleTurnComplete(chat: chat, controller: controller)

        XCTAssertEqual(
            fake.spokenTexts,
            ["speak me"],
            "a duplicate onTurnComplete/backfill for the same assistant id must not re-speak"
        )
        XCTAssertEqual(controller.status, .listening, "duplicate handoff re-arms without speech")

        let secondReplyId = UUID()
        chat.messages.append(ChatMessage(id: secondReplyId, role: .assistant, text: "new reply"))
        fake.nextTranscript = "third prompt"
        await controller.stopTurn(forceTranscribe: false)
        XCTAssertEqual(controller.status, .thinking)

        await coordinator.handleTurnComplete(chat: chat, controller: controller)

        XCTAssertEqual(fake.spokenTexts, ["speak me", "new reply"])
    }

    func testAutoSpeakHandoffRearmsWithoutSpeakingWhenNoCompletedAssistantReply() async {
        let (controller, fake) = makeController()
        let chat = ChatStore()
        let coordinator = VoiceConversationAutoSpeakCoordinator()
        chat.messages = [
            ChatMessage(role: .user, text: "latest user row"),
            ChatMessage(role: .assistant, text: "streaming reply", isStreaming: true),
            ChatMessage(role: .assistant, text: "   "),
        ]
        await reachThinking(controller: controller, fake: fake)

        await coordinator.handleTurnComplete(chat: chat, controller: controller)

        XCTAssertTrue(fake.spokenTexts.isEmpty)
        XCTAssertEqual(controller.status, .listening, "blank/streaming/user-only completions still re-arm")
        XCTAssertEqual(fake.startListeningCount, 2)
    }

    func testTurnCompletionPipelineRunsQueueDrainAndVoiceHandoff() {
        var queueDrainCount = 0
        var voiceHandoffCount = 0
        let pipeline = VoiceConversationTurnCompletionPipeline(
            drainQueue: { queueDrainCount += 1 },
            completeVoiceTurn: { voiceHandoffCount += 1 }
        )

        pipeline.run()

        XCTAssertEqual(queueDrainCount, 1, "conversation-mode wiring must not clobber queue drain")
        XCTAssertEqual(voiceHandoffCount, 1)
    }

    func testEmptyReplyRearmsWithoutSpeaking() async {
        let (controller, fake) = makeController()
        await reachThinking(controller: controller, fake: fake)

        await controller.handleTurnComplete(replyText: nil)

        XCTAssertEqual(controller.status, .listening, "empty reply re-arms listening")
        XCTAssertTrue(fake.spokenTexts.isEmpty, "nothing to speak for an empty reply")
        XCTAssertEqual(fake.startListeningCount, 2)
    }

    func testTurnCompleteOutsideThinkingIsIgnored() async {
        let (controller, fake) = makeController()
        await controller.start()
        XCTAssertEqual(controller.status, .listening)

        // Not thinking → a foreign turn's completion must not steal the loop.
        await controller.handleTurnComplete(replyText: "intruder")
        XCTAssertEqual(controller.status, .listening, "foreign turn completion is ignored")
        XCTAssertTrue(fake.spokenTexts.isEmpty)
    }

    // MARK: - mute prevents re-arm / cancels capture

    func testMuteCancelsListeningAndReturnsToIdle() async {
        let (controller, fake) = makeController()
        await controller.start()
        XCTAssertEqual(controller.status, .listening)

        await controller.toggleMute()

        XCTAssertTrue(controller.muted)
        XCTAssertEqual(controller.status, .idle, "mute cancels the in-flight capture")
        XCTAssertGreaterThanOrEqual(fake.cancelListeningCount, 1)
    }

    func testMutePreventsRearmAfterEmptyTranscript() async {
        let (controller, fake) = makeController()
        fake.nextTranscript = nil
        await controller.start()
        await controller.toggleMute()           // mute while idle after we stop listening
        XCTAssertTrue(controller.muted)

        await controller.stopTurn(forceTranscribe: false)

        XCTAssertEqual(controller.status, .idle, "re-arm must be suppressed while muted")
        XCTAssertEqual(fake.startListeningCount, 1, "no second listen while muted")
    }

    func testUnmuteRearmsWhenEnabledAndIdle() async {
        let (controller, _) = makeController()
        await controller.start()
        await controller.toggleMute()           // mute → idle
        XCTAssertEqual(controller.status, .idle)

        await controller.toggleMute()           // unmute → re-arm

        XCTAssertFalse(controller.muted)
        XCTAssertEqual(controller.status, .listening, "unmuting re-arms when enabled + idle")
    }

    // MARK: - hard stop cancels stale callbacks (generation guard)

    func testHardStopCancelsStaleTranscription() async throws {
        let (controller, fake) = makeController()
        fake.suspendTranscribe = true
        await controller.start()
        XCTAssertEqual(controller.status, .listening)

        // Drive stopTurn on a background task so transcribe can suspend mid-await.
        let stopTask = Task { await controller.stopTurn(forceTranscribe: false) }
        try await Self.waitUntil(timeout: 2.0) { fake.transcribeContinuation != nil }

        controller.end()                        // hard stop while transcription is airborne

        // Now release the suspended transcription with a non-empty result.
        fake.transcribeContinuation?.resume(returning: "hello")
        fake.transcribeContinuation = nil
        await stopTask.value

        XCTAssertEqual(controller.status, .idle, "stale transcription must not leave us thinking")
        XCTAssertFalse(controller.isEnabled)
        XCTAssertTrue(fake.submittedTranscripts.isEmpty, "stale transcript must not be submitted")
        XCTAssertEqual(fake.startListeningCount, 1, "stale callback must not re-arm listening")
    }

    func testHardStopCancelsStaleSpeechCompletion() async throws {
        let (controller, fake) = makeController()
        fake.suspendSpeak = true
        await reachThinking(controller: controller, fake: fake)
        XCTAssertEqual(controller.status, .thinking)

        // handleTurnComplete enters .speaking and suspends inside speak().
        let speakTask = Task { await controller.handleTurnComplete(replyText: "hello reply") }
        try await Self.waitUntil(timeout: 2.0) { fake.speakContinuation != nil }
        XCTAssertEqual(controller.status, .speaking)

        controller.end()                        // hard stop while TTS is airborne

        fake.speakContinuation?.resume()
        fake.speakContinuation = nil
        await speakTask.value

        XCTAssertEqual(controller.status, .idle, "stale speech completion must not re-arm")
        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(fake.startListeningCount, 1, "no re-arm after a stop-cancelled speak")
    }

    func testMuteInvalidatesInFlightTranscription() async throws {
        let (controller, fake) = makeController()
        fake.suspendTranscribe = true
        await controller.start()

        let stopTask = Task { await controller.stopTurn(forceTranscribe: false) }
        try await Self.waitUntil(timeout: 2.0) { fake.transcribeContinuation != nil }

        await controller.toggleMute()           // mute bumps generation (treated like a stop)

        fake.transcribeContinuation?.resume(returning: "hello")
        fake.transcribeContinuation = nil
        await stopTask.value

        XCTAssertEqual(controller.status, .idle, "muting mid-transcription settles to idle")
        XCTAssertTrue(controller.muted)
        XCTAssertTrue(fake.submittedTranscripts.isEmpty, "muted-then-completed transcript is dropped")
    }

    // MARK: - end() hard stop from various states

    func testEndFromListeningReturnsToIdle() async {
        let (controller, fake) = makeController()
        await controller.start()
        XCTAssertEqual(controller.status, .listening)

        controller.end()

        XCTAssertEqual(controller.status, .idle)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertFalse(controller.muted)
        XCTAssertGreaterThanOrEqual(fake.cancelListeningCount, 1)
        XCTAssertGreaterThanOrEqual(fake.stopSpeakingCount, 1)
    }

    func testEndFromThinkingReturnsToIdle() async {
        let (controller, fake) = makeController()
        await reachThinking(controller: controller, fake: fake)
        XCTAssertEqual(controller.status, .thinking)

        controller.end()

        XCTAssertEqual(controller.status, .idle)
        XCTAssertFalse(controller.isEnabled)
    }

    // MARK: - presentation

    func testStatusLabelAndAccessibilityAcrossStates() async {
        let (controller, fake) = makeController()
        XCTAssertEqual(controller.statusLabel, "Idle")
        XCTAssertEqual(controller.accessibilityLabel, "Voice conversation idle.")

        await controller.start()
        XCTAssertEqual(controller.statusLabel, "Listening")
        XCTAssertEqual(controller.accessibilityLabel, "Voice conversation listening.")

        fake.nextTranscript = "hi"
        await controller.stopTurn(forceTranscribe: false)
        XCTAssertEqual(controller.statusLabel, "Thinking")

        await controller.handleTurnComplete(replyText: "yo")
        XCTAssertEqual(controller.statusLabel, "Listening")  // re-armed after speaking
    }

    func testMutedAccessibilitySuffix() async {
        let (controller, _) = makeController()
        await controller.start()
        await controller.toggleMute()
        XCTAssertEqual(controller.accessibilityLabel, "Voice conversation idle. Muted.")
    }

    func testLevelReadsFromDependency() async {
        let (controller, fake) = makeController()
        fake.levelValue = 0.42
        XCTAssertEqual(controller.level, 0.42, accuracy: 0.001)
        fake.levelValue = 0
        XCTAssertEqual(controller.level, 0)
    }

    // MARK: - Helpers

    /// Build a controller wired to a fresh fake and return both.
    private func makeController() -> (VoiceConversationController, FakeVoiceDeps) {
        let fake = FakeVoiceDeps()
        let controller = VoiceConversationController(dependencies: fake.makeDependencies())
        return (controller, fake)
    }

    /// Drive a controller to `.thinking` with one submitted transcript, ready for
    /// a `handleTurnComplete` call. Uses the controller's own fake.
    private func reachThinking(
        controller: VoiceConversationController,
        fake: FakeVoiceDeps
    ) async {
        fake.nextTranscript = "prompt"
        await controller.start()
        await controller.stopTurn(forceTranscribe: false)
        XCTAssertEqual(controller.status, .thinking, "precondition: should be thinking")
    }

    @MainActor
    private static func waitUntil(
        timeout: TimeInterval,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        if condition() { return }
        XCTFail("Condition not met within \(timeout)s")
    }
}

// MARK: - Fake dependencies

/// Records every side effect the controller drives and lets a test script the
/// return values of `stopAndTranscribe` plus suspend the transcribe/speak awaits
/// (to exercise the generation guard against hard stops / mute).
@MainActor
private final class FakeVoiceDeps {

    // Call counters / captures
    var startListeningCount = 0
    var cancelListeningCount = 0
    var stopSpeakingCount = 0
    var submittedTranscripts: [String] = []
    var spokenTexts: [String] = []
    var levelValue: Float = 0

    // Scripted returns / suspension
    var nextTranscript: String? = nil
    var suspendTranscribe = false
    var transcribeContinuation: CheckedContinuation<String?, Never>?
    var suspendSpeak = false
    var speakContinuation: CheckedContinuation<Void, Never>?

    func makeDependencies() -> VoiceConversationController.Dependencies {
        .init(
            startListening: { [weak self] in
                self?.startListeningCount += 1
            },
            stopAndTranscribe: { [weak self] () -> String? in
                guard let self else { return nil }
                if self.suspendTranscribe {
                    return await withCheckedContinuation { cont in
                        self.transcribeContinuation = cont
                    }
                }
                return self.nextTranscript
            },
            cancelListening: { [weak self] in
                self?.cancelListeningCount += 1
            },
            submitTranscript: { [weak self] transcript in
                self?.submittedTranscripts.append(transcript)
            },
            speak: { [weak self] text in
                self?.spokenTexts.append(text)
                if self?.suspendSpeak == true {
                    await withCheckedContinuation { cont in
                        self?.speakContinuation = cont
                    }
                }
            },
            stopSpeaking: { [weak self] in
                self?.stopSpeakingCount += 1
            },
            level: { [weak self] in self?.levelValue ?? 0 }
        )
    }
}
