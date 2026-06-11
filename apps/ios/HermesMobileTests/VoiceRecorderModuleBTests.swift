import AVFoundation
import XCTest
@testable import HermesMobile

/// UX-1 Module B coverage (ABH-74 — voice hold/stop state machine):
///   - B3 recording watchdog auto-stop,
///   - B4 `AVAudioSession.interruptionNotification` ends a capture (never wedges),
///   - the R1 #92 generation/cancel invariant survives the new salvage paths,
///   - B6 the dedicated 60s transcription timeout,
///   - the existing `normalizedPower` curve stays green.
///
/// The watchdog / interruption tests use the DEBUG-only `_testBeginRecordingForTests`
/// seam to drive `.recording` WITHOUT the audio hardware (headless unit hosts have
/// no mic / live `AVAudioRecorder`). With no `rest` client held, the salvage paths
/// take the `cancel()` branch — exactly the "capture ENDS, never stuck `.recording`"
/// guarantee the contract pins.
@MainActor
final class VoiceRecorderModuleBTests: XCTestCase {

    // MARK: - B3 watchdog

    /// Driving past the (test-shortened) cap auto-stops the recording: state
    /// returns to idle and `lastError` carries the 2-minute-limit note.
    func testWatchdogFiresAndReturnsToIdle() async throws {
        let recorder = VoiceRecorder()
        recorder.watchdogDuration = 0.05   // short cap so the test doesn't wait 2 min
        recorder._testBeginRecordingForTests()
        XCTAssertTrue(recorder.isRecording, "Seam should put the recorder in .recording")

        // Wait out the cap + the main-actor salvage hop.
        try await Self.waitUntil(timeout: 2.0) { recorder.state == .idle }

        XCTAssertEqual(recorder.state, .idle, "Watchdog must auto-stop a wedged recording")
        XCTAssertEqual(
            recorder.lastError, "Recording stopped at the 2-minute limit.",
            "Watchdog expiry should surface the cap note for the strip/composer"
        )
    }

    /// A normal stop BEFORE the cap cancels the watchdog — it must not later fire
    /// and stomp an already-idle (or freshly restarted) recorder.
    func testWatchdogCanceledByCancel() async throws {
        let recorder = VoiceRecorder()
        recorder.watchdogDuration = 0.05
        recorder._testBeginRecordingForTests()  // clears lastError to nil
        recorder.cancel()                         // cancel does not write lastError
        XCTAssertEqual(recorder.state, .idle)
        XCTAssertNil(recorder.lastError, "A clean cancel leaves no error")

        // Give the (now-cancelled) watchdog window time to (not) fire.
        try await Self.sleep(0.2)
        XCTAssertEqual(recorder.state, .idle, "Cancelled watchdog must stay quiet")
        XCTAssertNil(
            recorder.lastError,
            "A cancelled watchdog must not later write the cap note over an idle recorder"
        )
    }

    // MARK: - B4 interruption observer

    /// An interruption `.began` while recording ENDS the capture (no `rest` → the
    /// cancel branch) — the recorder must leave `.recording`, never wedge.
    func testInterruptionBeganEndsRecording() async throws {
        let recorder = VoiceRecorder()
        recorder.watchdogDuration = 60  // keep the watchdog out of this test's way
        recorder._testBeginRecordingForTests()
        XCTAssertTrue(recorder._testHasInterruptionObserver, "start() should install the observer")

        recorder._testHandleInterruption(.began)
        try await Self.waitUntil(timeout: 2.0) { recorder.state == .idle }

        XCTAssertEqual(recorder.state, .idle, "Interruption.began must end the capture")
        XCTAssertFalse(recorder.isRecording, "Recorder must not be left stuck .recording")
    }

    /// An interruption `.ended` does NOT auto-resume or alter a non-recording
    /// recorder (single-shot; the user re-taps).
    func testInterruptionEndedIsNoOpWhenIdle() async throws {
        let recorder = VoiceRecorder()
        XCTAssertEqual(recorder.state, .idle)
        recorder._testHandleInterruption(.ended)
        try await Self.sleep(0.05)
        XCTAssertEqual(recorder.state, .idle, "Interruption.ended must not start/resume anything")
    }

    /// The observer is installed for the capture and removed on teardown so
    /// install/remove stay balanced.
    func testInterruptionObserverBalancedAcrossLifecycle() async throws {
        let recorder = VoiceRecorder()
        recorder.watchdogDuration = 60
        XCTAssertFalse(recorder._testHasInterruptionObserver, "No observer before recording")
        recorder._testBeginRecordingForTests()
        XCTAssertTrue(recorder._testHasInterruptionObserver, "Observer armed while recording")
        recorder.cancel()
        XCTAssertFalse(recorder._testHasInterruptionObserver, "Observer removed on cancel")
    }

    // MARK: - R1 #92 invariant (salvage must respect cancellation)

    /// A salvaged transcript must NOT be delivered if the capture was cancelled
    /// while the salvage was airborne — the generation guard inside
    /// `stopAndTranscribe` makes the salvage callback a no-op after a cancel.
    /// Here: with no `rest` held, the interruption takes the cancel branch and the
    /// salvage callback never fires regardless — asserting the callback stays
    /// unfired across an interruption-ends-then-idle cycle.
    func testSalvageCallbackNotFiredOnCancelPath() async throws {
        let recorder = VoiceRecorder()
        recorder.watchdogDuration = 60
        var salvaged: [String] = []
        recorder.onSalvagedTranscript = { salvaged.append($0) }

        recorder._testBeginRecordingForTests()  // activeRest == nil → cancel branch
        recorder._testHandleInterruption(.began)
        try await Self.waitUntil(timeout: 2.0) { recorder.state == .idle }

        XCTAssertTrue(salvaged.isEmpty, "No-rest interruption must cancel, not deliver a transcript")
    }

    // MARK: - B6 transcription timeout

    /// The dedicated transcription timeout is the pinned 60s constant, distinct
    /// from the shared 15s default everything else uses.
    func testTranscribeTimeoutConstantIs60() {
        XCTAssertEqual(RestClient.transcribeTimeout, 60)
    }

    // MARK: - normalizedPower curve (existing behavior, kept green)

    func testNormalizedPowerFloorsBelowNoiseFloor() {
        XCTAssertEqual(VoiceRecorder.normalizedPower(-60), 0)
        XCTAssertEqual(VoiceRecorder.normalizedPower(-50), 0)
        XCTAssertEqual(VoiceRecorder.normalizedPower(.nan), 0)
    }

    func testNormalizedPowerSaturatesAtZeroDB() {
        XCTAssertEqual(VoiceRecorder.normalizedPower(0), 1)
        XCTAssertEqual(VoiceRecorder.normalizedPower(5), 1)
    }

    func testNormalizedPowerMidpoint() {
        // -25 dB sits halfway between the -50 floor and 0 → 0.5.
        XCTAssertEqual(VoiceRecorder.normalizedPower(-25), 0.5, accuracy: 0.0001)
    }

    // MARK: - Helpers

    /// Poll `condition` until true or `timeout` elapses (the salvage paths hop the
    /// main actor via `Task`, so the state change is not synchronous with the call).
    /// `@MainActor` like the test class, so the closure touches recorder state
    /// directly without an extra hop.
    @MainActor
    private static func waitUntil(
        timeout: TimeInterval,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await sleep(0.02)
        }
        if condition() { return }
        XCTFail("Condition not met within \(timeout)s")
    }

    private static func sleep(_ seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
