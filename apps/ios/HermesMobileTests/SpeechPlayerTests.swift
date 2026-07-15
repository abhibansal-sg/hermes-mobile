import XCTest
@testable import HermesMobile

/// STR-545 coverage for `SpeechPlayer`'s completion seam: `speak(...)` must
/// suspend until the utterance is truly idle and resolve with the correct
/// `SpeechPlaybackResult` on EVERY terminal path, exactly once — never
/// returning early at "playback started" (the gap the hands-free
/// conversation loop, STR-532, needs closed to know when it is safe to
/// re-arm the mic).
///
/// No live server or real audio hardware is touched: `RestClient.speak` is
/// driven through a stub `URLProtocol` (the same technique as
/// `PanelL6T12Tests`/`DevicesTests`), and playback is driven through a fake
/// `SpeechAudioPlayer` (`SpyAudioPlayer`) instead of `AVAudioPlayer`, so
/// completion is triggered deterministically by the test rather than by
/// decodable audio bytes or wall-clock duration.
@MainActor
final class SpeechPlayerTests: XCTestCase {
    override func tearDown() {
        UITestAudioGuard.argumentsForTesting = nil
        super.tearDown()
    }

    // MARK: - REST stubbing

    /// A `data:audio/mpeg;base64,...` URL that decodes cleanly (arbitrary
    /// bytes — never handed to a real audio decoder in these tests).
    private let validDataURL = "data:audio/mpeg;base64,QUJD"

    private func stubRest(dataURL: String, status: Int = 200) -> RestClient {
        let body = #"{"ok":true,"data_url":"\#(dataURL)","mime_type":"audio/mpeg"}"#
        SpeechSpeakStubProtocol.nextResponse = (Data(body.utf8), status)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SpeechSpeakStubProtocol.self]
        return RestClient(
            baseURL: URL(string: "http://127.0.0.1:9119")!,
            token: "test-token",
            session: URLSession(configuration: config)
        )
    }

    private func stubRestFailure(status: Int) -> RestClient {
        SpeechSpeakStubProtocol.nextResponse = (Data("server error".utf8), status)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SpeechSpeakStubProtocol.self]
        return RestClient(
            baseURL: URL(string: "http://127.0.0.1:9119")!,
            token: "test-token",
            session: URLSession(configuration: config)
        )
    }

    // MARK: - Normal finish

    func testNormalPlaybackFinishFiresCompletedExactlyOnce() async {
        let fake = SpyAudioPlayer()
        let sut = SpeechPlayer(makePlayer: { _ in fake })
        let rest = stubRest(dataURL: validDataURL)
        let messageId = UUID()

        let task = Task { await sut.speak(text: "hello there", messageId: messageId, rest: rest) }
        await fake.waitUntilPlayCalled()

        // Mid-flight: the seam must report "active" while playback is live.
        XCTAssertTrue(sut.isActive)
        XCTAssertEqual(sut.speakingMessageId, messageId)

        // A stray second finish callback (e.g. both finish+decode-error firing)
        // must not resume the continuation twice — proves "exactly once".
        fake.finishPlayback()
        fake.finishPlayback()

        let result = await task.value
        XCTAssertEqual(result, .completed)
        XCTAssertFalse(sut.isActive)
        XCTAssertNil(sut.speakingMessageId)
        XCTAssertNil(sut.lastError)
    }

    // MARK: - Explicit stop()

    func testExplicitStopFiresStoppedExactlyOnce() async {
        let fake = SpyAudioPlayer()
        let sut = SpeechPlayer(makePlayer: { _ in fake })
        let rest = stubRest(dataURL: validDataURL)

        let task = Task { await sut.speak(text: "hello there", rest: rest) }
        await fake.waitUntilPlayCalled()

        sut.stop()
        // A late finish callback after an explicit stop must be a no-op.
        fake.finishPlayback()

        let result = await task.value
        XCTAssertEqual(result, .stopped)
        XCTAssertFalse(sut.isActive)
        XCTAssertNil(sut.speakingMessageId)
        XCTAssertEqual(fake.stopCallCount, 1)
    }

    // MARK: - Superseded by a newer speak()

    func testNewSpeakSupersedesInFlightUtterance() async {
        let firstFake = SpyAudioPlayer()
        let secondFake = SpyAudioPlayer()
        var created: [SpyAudioPlayer] = [firstFake, secondFake]
        let sut = SpeechPlayer(makePlayer: { _ in created.removeFirst() })
        let rest = stubRest(dataURL: validDataURL)

        let firstTask = Task { await sut.speak(text: "first", messageId: UUID(), rest: rest) }
        await firstFake.waitUntilPlayCalled()

        let secondMessageId = UUID()
        let secondTask = Task { await sut.speak(text: "second", messageId: secondMessageId, rest: rest) }
        await secondFake.waitUntilPlayCalled()

        let firstResult = await firstTask.value
        XCTAssertEqual(firstResult, .superseded)
        // The superseding call still completes normally: one utterance at a
        // time, but the newer one is not itself cancelled by its own arrival.
        XCTAssertEqual(secondFake.playCallCount, 1)
        XCTAssertEqual(sut.speakingMessageId, secondMessageId)

        sut.stop()
        let secondResult = await secondTask.value
        XCTAssertEqual(secondResult, .stopped)
    }

    // MARK: - Malformed audio data URL

    func testMalformedAudioDataURLFiresMalformedAudio() async {
        let sut = SpeechPlayer(makePlayer: { _ in SpyAudioPlayer() })
        let rest = stubRest(dataURL: "not-a-data-url")

        let result = await sut.speak(text: "hello", rest: rest)

        XCTAssertEqual(result, .malformedAudio)
        XCTAssertFalse(sut.isActive)
        XCTAssertEqual(sut.lastError, "Received malformed audio from the server.")
    }

    // MARK: - Synthesis failure (RestClient.speak throws)

    func testSynthesisFailureFiresSynthesisFailed() async {
        let sut = SpeechPlayer(makePlayer: { _ in SpyAudioPlayer() })
        let rest = stubRestFailure(status: 500)

        let result = await sut.speak(text: "hello", rest: rest)

        guard case .synthesisFailed(let message) = result else {
            return XCTFail("expected .synthesisFailed, got \(result)")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertFalse(sut.isActive)
        XCTAssertEqual(sut.lastError, message)
    }

    // MARK: - Playback setup failure (player factory throws)

    func testPlaybackSetupFailureFiresPlaybackFailed() async {
        struct SetupError: Error {}
        let sut = SpeechPlayer(makePlayer: { _ in throw SetupError() })
        let rest = stubRest(dataURL: validDataURL)

        let result = await sut.speak(text: "hello", rest: rest)

        guard case .playbackFailed(let message) = result else {
            return XCTFail("expected .playbackFailed, got \(result)")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertFalse(sut.isActive)
    }

    // MARK: - Playback start failure (player.play() returns false)

    func testPlaybackStartFailureFiresPlaybackFailed() async {
        let fake = SpyAudioPlayer()
        fake.playReturnValue = false
        let sut = SpeechPlayer(makePlayer: { _ in fake })
        let rest = stubRest(dataURL: validDataURL)

        let result = await sut.speak(text: "hello", rest: rest)

        guard case .playbackFailed = result else {
            return XCTFail("expected .playbackFailed, got \(result)")
        }
        XCTAssertFalse(sut.isActive)
        XCTAssertNil(sut.speakingMessageId)
    }

    // MARK: - Empty input is a no-op, not a network call

    func testWhitespaceOnlyTextIsANoOp() async {
        let sut = SpeechPlayer(makePlayer: { _ in SpyAudioPlayer() })
        let rest = stubRest(dataURL: validDataURL)

        let result = await sut.speak(text: "   \n  ", rest: rest)

        XCTAssertEqual(result, .stopped)
        XCTAssertFalse(sut.isActive)
    }

    // MARK: - UI-test mute guard

    func testUITestMuteAudioReturnsCompletedWithoutSynthesizingOrPlaying() async {
        UITestAudioGuard.argumentsForTesting = { ["HermesMobileTests", "--uitest-mute-audio"] }
        var synthesizeCallCount = 0
        var makePlayerCallCount = 0
        let fake = SpyAudioPlayer()
        let rest = stubRest(dataURL: validDataURL)
        let sut = SpeechPlayer(
            makePlayer: { _ in
                makePlayerCallCount += 1
                return fake
            },
            synthesize: { _, _ in
                synthesizeCallCount += 1
                return self.validDataURL
            }
        )

        let result = await sut.speak(text: "hello", messageId: UUID(), rest: rest)

        XCTAssertEqual(result, .completed)
        XCTAssertEqual(synthesizeCallCount, 0)
        XCTAssertEqual(makePlayerCallCount, 0)
        XCTAssertEqual(fake.prepareToPlayCallCount, 0)
        XCTAssertEqual(fake.playCallCount, 0)
        XCTAssertEqual(fake.stopCallCount, 0)
        XCTAssertFalse(sut.isActive)
        XCTAssertNil(sut.speakingMessageId)
        XCTAssertNil(sut.lastError)
    }

    // MARK: - Regression: per-generation termination reason (review finding)

    /// A `stop()` while the FIRST utterance's synthesis request is still in
    /// flight, followed by a newer `speak()` before that first request
    /// resolves, must still report the first utterance as `.stopped` — not
    /// whatever the second utterance's own supersede/stop reason happens to
    /// be. Catches a prior bug where a single shared `terminationReason` var
    /// let the second utterance's `terminate(with:)` call clobber the first
    /// utterance's actual outcome before it was ever read.
    func testStopWhileSynthesisInFlightThenNewerSpeakReportsFirstAsStopped() async {
        let gateA = SynthesisGate()
        let secondFake = SpyAudioPlayer()
        let rest = stubRest(dataURL: validDataURL)
        let sut = SpeechPlayer(
            makePlayer: { _ in secondFake },
            synthesize: { [validDataURL] _, text in
                if text == "first" {
                    await gateA.markStarted()
                    await gateA.waitForRelease()
                }
                return validDataURL
            }
        )

        let firstTask = Task { await sut.speak(text: "first", rest: rest) }
        await gateA.waitUntilStarted()

        // Stop the first utterance while its synthesis request is still
        // unresolved, then start a newer one before that request returns.
        sut.stop()
        let secondTask = Task { await sut.speak(text: "second", rest: rest) }
        await secondFake.waitUntilPlayCalled()

        await gateA.release()   // let the first utterance's request resolve
        let firstResult = await firstTask.value
        XCTAssertEqual(firstResult, .stopped)

        sut.stop()
        let secondResult = await secondTask.value
        XCTAssertEqual(secondResult, .stopped)
    }

    /// A newer `speak()` superseding the first utterance while its synthesis
    /// request is still in flight, followed by `stop()` on that newer
    /// utterance before the first request resolves, must report the first
    /// utterance as `.superseded` and the newer one as `.stopped` — each
    /// utterance's own outcome, not whichever `terminate(with:)` call ran
    /// most recently.
    func testSupersedeWhileSynthesisInFlightThenStopNewerReportsEachOwnReason() async {
        let gateA = SynthesisGate()
        let gateB = SynthesisGate()
        let rest = stubRest(dataURL: validDataURL)
        let sut = SpeechPlayer(
            makePlayer: { _ in SpyAudioPlayer() },
            synthesize: { [validDataURL] _, text in
                if text == "first" {
                    await gateA.markStarted()
                    await gateA.waitForRelease()
                } else {
                    await gateB.markStarted()
                    await gateB.waitForRelease()
                }
                return validDataURL
            }
        )

        let firstTask = Task { await sut.speak(text: "first", rest: rest) }
        await gateA.waitUntilStarted()

        // Supersede with a second utterance while the first is still
        // synthesizing, then stop that second utterance before the first
        // utterance's request ever resolves.
        let secondTask = Task { await sut.speak(text: "second", rest: rest) }
        await gateB.waitUntilStarted()
        sut.stop()

        await gateA.release()
        let firstResult = await firstTask.value
        XCTAssertEqual(firstResult, .superseded)

        await gateB.release()
        let secondResult = await secondTask.value
        XCTAssertEqual(secondResult, .stopped)
    }

    // MARK: - Regression: terminationReasons must not leak (STR-690)

    /// A normal finish never suspends in synthesis when `terminate(with:)`
    /// runs, so nothing should ever be recorded into `terminationReasons` for
    /// it — the map must be empty once the utterance resolves.
    func testTerminationReasonsEmptyAfterNormalFinish() async {
        let fake = SpyAudioPlayer()
        let sut = SpeechPlayer(makePlayer: { _ in fake })
        let rest = stubRest(dataURL: validDataURL)

        let task = Task { await sut.speak(text: "hello there", rest: rest) }
        await fake.waitUntilPlayCalled()
        fake.finishPlayback()

        let result = await task.value
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(sut.terminationReasonCountForTesting, 0)
    }

    /// A second `speak()` after the first has already finished (idle
    /// supersede) tears down an idle generation — no in-flight synthesis
    /// request exists to ever read a stored reason, so nothing should be
    /// recorded for it either.
    func testTerminationReasonsEmptyAfterIdleSupersede() async {
        let firstFake = SpyAudioPlayer()
        let secondFake = SpyAudioPlayer()
        var created: [SpyAudioPlayer] = [firstFake, secondFake]
        let sut = SpeechPlayer(makePlayer: { _ in created.removeFirst() })
        let rest = stubRest(dataURL: validDataURL)

        let firstTask = Task { await sut.speak(text: "first", rest: rest) }
        await firstFake.waitUntilPlayCalled()
        firstFake.finishPlayback()
        _ = await firstTask.value

        let secondTask = Task { await sut.speak(text: "second", rest: rest) }
        await secondFake.waitUntilPlayCalled()
        secondFake.finishPlayback()
        _ = await secondTask.value

        XCTAssertEqual(sut.terminationReasonCountForTesting, 0)
    }
}

// MARK: - Test doubles

/// A controllable `SpeechAudioPlayer` fake. `play()` signals
/// `waitUntilPlayCalled()` so a test can deterministically resume once
/// `SpeechPlayer` has reached its "awaiting completion" suspension point,
/// with no wall-clock sleep involved (see `SpeechPlayerTests` header).
private final class SpyAudioPlayer: SpeechAudioPlayer, @unchecked Sendable {
    var onFinish: (@Sendable () -> Void)?
    var playReturnValue = true
    private(set) var prepareToPlayCallCount = 0
    private(set) var playCallCount = 0
    private(set) var stopCallCount = 0
    private var playContinuation: CheckedContinuation<Void, Never>?

    func prepareToPlay() -> Bool {
        prepareToPlayCallCount += 1
        return true
    }

    func play() -> Bool {
        playCallCount += 1
        playContinuation?.resume()
        playContinuation = nil
        return playReturnValue
    }

    func stop() {
        stopCallCount += 1
    }

    /// Suspends until `play()` is called. Must be set up (awaited) before the
    /// `speak()` task under test gets a chance to run — true for every test
    /// above, since creating a `Task` never runs it synchronously on the
    /// actor that created it.
    func waitUntilPlayCalled() async {
        await withCheckedContinuation { continuation in
            self.playContinuation = continuation
        }
    }

    func finishPlayback() {
        onFinish?()
    }
}

/// Lets a test hold a fake `synthesize` call "in flight" and release it on
/// demand — used to reproduce a `stop()`/newer `speak()` landing while an
/// earlier utterance's synthesis request is still unresolved, without any
/// wall-clock sleep or real networking.
private actor SynthesisGate {
    private var started = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    /// Called by the fake `synthesize` closure once its request "begins".
    func markStarted() {
        started = true
        startedWaiters.forEach { $0.resume() }
        startedWaiters.removeAll()
    }

    /// Called by the test to confirm the request has begun before it acts
    /// (stop/newer speak) on the player.
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    /// Called by the test to let the held-open request finally resolve.
    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }

    /// Called by the fake `synthesize` closure to suspend until released.
    func waitForRelease() async {
        if released { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }
}

/// FIFO `URLProtocol` stub for `/api/audio/speak`, same pattern as
/// `PanelL6T12Tests.StubProtocol` / `DevicesTests.IssueDeviceProtocol`.
private final class SpeechSpeakStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var nextResponse: (Data, Int) = (Data(), 200)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (body, status) = Self.nextResponse
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
