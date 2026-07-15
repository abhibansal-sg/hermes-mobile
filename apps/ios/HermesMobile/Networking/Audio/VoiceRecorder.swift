import AVFoundation
import Foundation
import Observation

/// Records a short voice memo to AAC `.m4a` and transcribes it via the gateway's
/// `/api/audio/transcribe` endpoint. Drives the composer's mic button.
///
/// Lifecycle: `start()` → `recording(elapsed:)` with live `level` metering →
/// `stopAndTranscribe(rest:)` (uploads + returns the transcript) or `cancel()`
/// (discards). One recording at a time. All state mutation is on the main actor
/// so SwiftUI observes it directly; the actual file I/O and the network call are
/// awaited off the hop where possible.
@MainActor
@Observable
final class VoiceRecorder {
    /// Where the recorder is in its lifecycle.
    enum State: Equatable {
        case idle
        /// Actively recording. `elapsed` is wall-clock seconds since `start()`.
        case recording(elapsed: TimeInterval)
        /// File closed; transcription request in flight.
        case transcribing
    }

    /// Microphone authorization, surfaced so the UI can prompt / deep-link to
    /// Settings when denied.
    enum Permission: Equatable {
        case undetermined
        case granted
        case denied
    }

    private(set) var state: State = .idle

    /// Normalized 0...1 input level, polled ~10Hz from the recorder's average
    /// power meter while recording (0 when idle). Drive a waveform/bar from this.
    private(set) var level: Float = 0

    private(set) var permission: Permission

    /// Set when `start()` or `stopAndTranscribe` fails (mic denied, encoder
    /// error, transcription error). Cleared on the next `start()`.
    private(set) var lastError: String?

    /// True while a recording is active (convenience for button enable logic).
    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    /// True while the current capture was initiated via the composer's
    /// hold-to-talk gesture (long-press the mic, record while held, release to
    /// transcribe) rather than the tap-to-record strip flow. Additive presentation
    /// flag: the recording strip reads it to swap its affordance copy ("release to
    /// transcribe") and hide the explicit stop/cancel chrome that only the
    /// tap flow needs. The capture lifecycle itself is unchanged — hold-to-talk
    /// reuses `start()` / `stopAndTranscribe(rest:)` / `cancel()` exactly as the
    /// tap flow does. Cleared on `cancel()` and at the end of
    /// `stopAndTranscribe(rest:)`; set by ``beginHoldToTalk()``.
    private(set) var isHoldToTalk: Bool = false

    /// Mark the upcoming / in-flight capture as hold-to-talk before (or right
    /// after) calling `start()`. Purely a presentation hint for the recording
    /// strip; it does not alter recording or transcription behavior. Idempotent.
    func beginHoldToTalk() {
        isHoldToTalk = true
    }

    /// Invoked when a capture that the user did NOT explicitly stop is salvaged
    /// — the recording watchdog (B3) or an audio-session interruption (B4) ends
    /// the recording and transcribes the audio captured so far. The composer
    /// registers this so a salvaged dictation still lands in the field instead of
    /// being silently dropped. The closure receives the trimmed, non-empty
    /// transcript and is generation-guarded (R1 #92): it is NOT called if the
    /// capture was cancelled while the salvage transcription was in flight.
    var onSalvagedTranscript: ((String) -> Void)?

    private let session: AVAudioSession
    private var recorder: AVAudioRecorder?
    private var fileURL: URL?
    private var startedAt: Date?

    /// Single timer task driving both elapsed-time and level updates (~10Hz).
    private var meterTask: Task<Void, Never>?

    /// Last-resort cap task: auto-stops a recording that has run past the max
    /// duration so a wedged `.recording` (a dropped hold-release, B1/B2 escape
    /// hatch) can never persist indefinitely (B3). Armed in `start()` alongside
    /// `meterTask`, invalidated by `cancel()`/`stopAndTranscribe`/the next
    /// `start()` exactly like `meterTask` (and additionally generation-guarded).
    private var watchdogTask: Task<Void, Never>?

    /// Whether an `AVAudioSession.interruptionNotification` observer is currently
    /// installed (added in `start()`, removed on teardown) so install/remove stay
    /// balanced even across the salvage paths.
    private var interruptionObserver: NSObjectProtocol?

    /// REST client held for the duration of a capture so the watchdog / an
    /// interruption can salvage-transcribe the audio without a caller present.
    /// nil when the capture was started without one (e.g. quick-capture's
    /// no-arg `start()`), in which case salvage falls back to `cancel()`.
    private var activeRest: RestClient?

    /// MIME for AAC-in-MP4 (`.m4a`) — server maps `audio/mp4` → `.mp4` and the
    /// transcription providers accept the AAC payload.
    static let mimeType = "audio/mp4"

    private static let meterInterval: Duration = .milliseconds(100)

    /// Hard ceiling on a single recording (B3). A generous mobile-dictation cap;
    /// on expiry the watchdog salvage-transcribes (if a `rest` client is held)
    /// or cancels, so the meter never freezes forever.
    static let maxRecordingDuration: TimeInterval = 120

    /// The watchdog cap actually used to arm the timer. Defaults to
    /// ``maxRecordingDuration``; overridable so unit tests can drive the cap in a
    /// fraction of a second instead of waiting two real minutes. Production never
    /// changes it.
    var watchdogDuration: TimeInterval = VoiceRecorder.maxRecordingDuration

    init(session: AVAudioSession = .sharedInstance()) {
        self.session = session
        switch AVAudioApplication.shared.recordPermission {
        case .granted: self.permission = .granted
        case .denied: self.permission = .denied
        case .undetermined: self.permission = .undetermined
        @unknown default: self.permission = .undetermined
        }
    }

    // MARK: - Permission

    /// Ask for mic access if undetermined; returns the resolved decision.
    /// Safe to call repeatedly — already-determined states return immediately.
    /// Uses the iOS 17 `AVAudioApplication` permission API.
    @discardableResult
    func requestPermission() async -> Permission {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            permission = .granted
            return .granted
        case .denied:
            permission = .denied
            return .denied
        case .undetermined:
            let granted = await AVAudioApplication.requestRecordPermission()
            permission = granted ? .granted : .denied
            return permission
        @unknown default:
            permission = .undetermined
            return .undetermined
        }
    }

    // MARK: - Recording

    /// Begin a new recording. Requests mic permission if needed, configures the
    /// audio session, and starts the AAC encoder. No-op if already recording.
    /// On failure, sets `lastError` and leaves `state == .idle`.
    ///
    /// - Parameter rest: optional REST client retained for the capture's lifetime
    ///   so the recording watchdog (B3) and the interruption observer (B4) can
    ///   salvage-transcribe the audio without a caller present. Pass the live
    ///   client when one exists; when nil, those last-resort paths `cancel()`
    ///   instead of salvaging. Default nil keeps the existing no-arg call sites
    ///   (e.g. quick-capture) source-compatible.
    func start(rest: RestClient? = nil) async {
        guard case .idle = state else { return }
        // A fresh lifecycle invalidates any straggling transcribe await from a
        // prior recording (R1 #92).
        generation += 1
        lastError = nil
        level = 0
        activeRest = rest

        let myGeneration = generation
        let decision = await requestPermission()
        guard decision == .granted else {
            lastError = decision == .denied
                ? "Microphone access is denied. Enable it in Settings to dictate."
                : "Microphone permission is required to dictate."
            activeRest = nil
            return
        }
        // Re-guard after the permission suspension (release audit P2): a
        // cancel() while the system dialog was up cleared `activeRest` —
        // resuming into hardware start would create a ghost recording with no
        // delivery target.
        guard generation == myGeneration, activeRest != nil else { return }

        do {
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP]
            )
            try session.setActive(true, options: [])
        } catch {
            lastError = "Could not start audio session: \(error.localizedDescription)"
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
            activeRest = nil
            return
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-voice-\(UUID().uuidString).m4a")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000.0,           // speech-optimized; plenty for STT
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            AVEncoderBitRateKey: 32_000,
        ]

        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                throw RecorderError.couldNotStart
            }
            self.recorder = recorder
            self.fileURL = url
            self.startedAt = Date()
            self.state = .recording(elapsed: 0)
            startMetering()
            startWatchdog(for: generation)
            installInterruptionObserver()
        } catch {
            lastError = "Could not start recording: \(error.localizedDescription)"
            cleanupFile(url)
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
            self.recorder = nil
            self.fileURL = nil
            self.activeRest = nil
            self.state = .idle
        }
    }

    /// Lifecycle generation. Bumped by `cancel()` (and each `start()`) so an
    /// in-flight `stopAndTranscribe` await can detect that the user cancelled
    /// while the transcription round-trip was airborne — pre-R1-#92 the
    /// transcript came back anyway and the caller inserted text the user had
    /// explicitly thrown away.
    private var generation = 0

    /// Discard the current recording without transcribing. Tears down the
    /// encoder, removes the temp file, and returns to `.idle`. Also
    /// invalidates any in-flight transcribe await (R1 #92).
    func cancel() {
        generation += 1
        meterTask?.cancel()
        meterTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        removeInterruptionObserver()
        activeRest = nil
        recorder?.stop()
        recorder = nil
        if let url = fileURL { cleanupFile(url) }
        fileURL = nil
        startedAt = nil
        level = 0
        isHoldToTalk = false
        deactivateSession()
        state = .idle
    }

    /// Stop recording, read the file, and transcribe it via `rest`.
    ///
    /// Returns the transcript (trimmed) on success, or `nil` if there was no
    /// active recording, the recording was empty/too short, or transcription
    /// failed (in which case `lastError` is set). The temp file is always
    /// removed and the audio session deactivated before returning.
    func stopAndTranscribe(rest: RestClient) async -> String? {
        guard case .recording = state, let recorder, let url = fileURL else {
            return nil
        }
        // Snapshot the lifecycle generation: a `cancel()` (or fresh `start()`)
        // during either await below invalidates this transcription — the
        // transcript must not be returned/inserted after the user cancelled
        // (R1 #92).
        let gen = generation
        meterTask?.cancel()
        meterTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        removeInterruptionObserver()
        recorder.stop()
        self.recorder = nil
        deactivateSession()
        level = 0
        startedAt = nil
        state = .transcribing

        defer {
            cleanupFile(url)
            fileURL = nil
            isHoldToTalk = false
            activeRest = nil
            // Only fall back to idle if we are still in `transcribing` (a fresh
            // `start()` racing in would have moved us on — but @MainActor
            // serializes, so this is just defensive).
            if state == .transcribing { state = .idle }
        }

        // Read bytes off the main actor — file is closed, so this is safe.
        let data: Data
        do {
            data = try await Task.detached(priority: .userInitiated) {
                try Data(contentsOf: url)
            }.value
        } catch {
            lastError = "Could not read recording: \(error.localizedDescription)"
            return nil
        }
        guard gen == generation else { return nil }  // cancelled mid-read (R1 #92)

        guard !data.isEmpty else {
            lastError = "Recording was empty."
            return nil
        }

        let dataURL = "data:\(Self.mimeType);base64,\(data.base64EncodedString())"
        do {
            let transcript = try await rest.transcribe(dataURL: dataURL, mimeType: Self.mimeType)
            // Cancelled while the transcription round-trip was in flight: the
            // user threw this recording away — never hand its text back to be
            // inserted into the composer (R1 #92).
            guard gen == generation else { return nil }
            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                lastError = "No speech detected."
                return nil
            }
            return trimmed
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription
                ?? "Transcription failed: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Metering

    private func startMetering() {
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.meterInterval)
                guard let self else { return }
                if Task.isCancelled { return }
                self.tickMeter()
            }
        }
    }

    private func tickMeter() {
        guard case .recording = state, let recorder, let startedAt else { return }
        recorder.updateMeters()
        level = Self.normalizedPower(recorder.averagePower(forChannel: 0))
        state = .recording(elapsed: Date().timeIntervalSince(startedAt))
    }

    /// Map AVAudioRecorder average power (dBFS, roughly -160...0) to 0...1.
    /// Uses a -50 dB noise floor so quiet rooms read near zero and speech fills
    /// the bar. Exposed `nonisolated` for unit testing the curve.
    nonisolated static func normalizedPower(_ decibels: Float) -> Float {
        let floor: Float = -50
        if decibels.isNaN || decibels < floor { return 0 }
        if decibels >= 0 { return 1 }
        return (decibels - floor) / -floor
    }

    // MARK: - Watchdog (B3)

    /// Arm the max-duration cap for the recording started at `gen`. Mirrors
    /// `meterTask`'s cancelable-`Task` shape; on expiry it salvages the audio if
    /// a `rest` client is held (`stopAndTranscribe`), else `cancel()`s — so a
    /// wedged `.recording` (a dropped hold-release that B1/B2 should already
    /// prevent) can never persist past the cap. Generation-guarded: a `cancel()`/
    /// `stopAndTranscribe`/next `start()` that bumped `generation` makes the timer
    /// fire-out a no-op, and the timer is also `Task`-cancelled by those paths.
    private func startWatchdog(for gen: Int) {
        watchdogTask?.cancel()
        let duration = watchdogDuration
        watchdogTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            if Task.isCancelled { return }
            guard let self else { return }
            await self.fireWatchdog(generation: gen)
        }
    }

    /// Watchdog expiry handler (main-actor): if still recording the same
    /// generation, set the cap note and salvage-or-cancel.
    private func fireWatchdog(generation gen: Int) async {
        guard gen == generation, case .recording = state else { return }
        lastError = "Recording stopped at the 2-minute limit."
        await salvageOrCancel()
    }

    // MARK: - Interruption observer (B4)

    /// Observe `AVAudioSession.interruptionNotification` for the duration of a
    /// capture. A phone call / Siri firing `.began` while we are recording must
    /// not leave the recorder stuck `.recording` with a frozen meter. The
    /// notification can arrive on a background queue, so the handler hops to the
    /// main actor before touching state.
    private func installInterruptionObserver() {
        removeInterruptionObserver()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: nil
        ) { [weak self] note in
            guard
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                let type = AVAudioSession.InterruptionType(rawValue: raw)
            else { return }
            // Hop to the main actor — the notification may be delivered on a
            // background queue, but all recorder state is main-actor isolated.
            Task { @MainActor [weak self] in
                self?.handleInterruption(type)
            }
        }
    }

    private func removeInterruptionObserver() {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        interruptionObserver = nil
    }

    /// On `.began` while recording: end the capture, salvaging the audio so far
    /// if a `rest` client is held, else cancel — never leave it stuck
    /// `.recording`. On `.ended`: do nothing (recording is single-shot; the user
    /// re-taps to resume).
    private func handleInterruption(_ type: AVAudioSession.InterruptionType) {
        switch type {
        case .began:
            guard case .recording = state else { return }
            if lastError == nil {
                lastError = "Recording stopped by an interruption."
            }
            Task { await salvageOrCancel() }
        case .ended:
            return
        @unknown default:
            return
        }
    }

    // MARK: - Salvage

    /// Shared end-the-capture path for the watchdog / interruption: if a `rest`
    /// client is held, transcribe the audio captured so far and deliver it via
    /// `onSalvagedTranscript` (generation-guarded inside `stopAndTranscribe`, so a
    /// race-cancel never inserts text — R1 #92); otherwise discard via `cancel()`.
    /// Either way the recorder leaves `.recording`.
    private func salvageOrCancel() async {
        guard case .recording = state else { return }
        guard let rest = activeRest else {
            cancel()
            return
        }
        if let transcript = await stopAndTranscribe(rest: rest), !transcript.isEmpty {
            onSalvagedTranscript?(transcript)
        }
    }

    // MARK: - Teardown

    private func deactivateSession() {
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func cleanupFile(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // No `deinit` observer cleanup: the interruption observer is balanced on every
    // capture-teardown path (`cancel()` / `stopAndTranscribe`), and the recorder is
    // a process-lifetime singleton (one instance in `AppEnvironment`), so it never
    // deallocates mid-capture. (A nonisolated `deinit` also cannot read the
    // main-actor-isolated `interruptionObserver` under Swift 6 strict concurrency.)

    private enum RecorderError: Error { case couldNotStart }
}

#if DEBUG
extension VoiceRecorder {
    /// Test seam (DEBUG only): force the recorder into `.recording` WITHOUT the
    /// audio hardware so the watchdog (B3) and interruption (B4) paths can be
    /// driven deterministically in a headless unit test (where mic permission /
    /// a live `AVAudioRecorder` is unavailable). Arms the watchdog + interruption
    /// observer exactly as `start()` does, but with NO file/recorder and no
    /// `rest` client — so the salvage paths take the `cancel()` branch, which is
    /// what the unit assertions exercise ("capture ENDS, leaves `.recording`").
    /// Never compiled into Release.
    func _testBeginRecordingForTests() {
        generation += 1
        lastError = nil
        level = 0
        activeRest = nil
        startedAt = Date()
        state = .recording(elapsed: 0)
        startWatchdog(for: generation)
        installInterruptionObserver()
    }

    /// Test accessor for the armed-observer presence (balance assertion).
    var _testHasInterruptionObserver: Bool { interruptionObserver != nil }

    /// Drive the interruption handler directly (DEBUG only) so a test need not
    /// post a system notification and race the main-actor hop.
    func _testHandleInterruption(_ type: AVAudioSession.InterruptionType) {
        handleInterruption(type)
    }
}
#endif
