import AVFoundation
import Foundation
import Observation

/// Plays assistant text aloud via the gateway's `/api/audio/speak` TTS endpoint.
///
/// One utterance at a time: a fresh `speak(...)` stops any in-flight playback
/// first. `speakingMessageId` lets a `MessageBubble` show a speaker/stop state
/// for the bubble it owns. All UI-facing state is main-actor isolated.
///
/// STR-545: `speak` is an awaitable completion seam — it suspends until the
/// utterance is truly idle (played to completion, explicitly stopped,
/// superseded by a newer `speak`, or failed) rather than returning once
/// playback merely *starts*. A hands-free conversation loop (STR-532) awaits
/// this to know when it is safe to re-arm the mic, instead of racing playback.
@MainActor
@Observable
final class SpeechPlayer {
    /// The message currently being synthesized or played, so bubbles can render
    /// a "speaking" affordance keyed to their own id. `nil` when idle.
    private(set) var speakingMessageId: UUID?

    /// True from the moment `speak` is called until audio finishes / is stopped
    /// (covers the synthesis request window and playback).
    private(set) var isActive: Bool = false

    /// Set when synthesis or playback fails. Cleared at the start of `speak`.
    private(set) var lastError: String?

    /// Builds the live player for a decoded audio buffer. Overridden in tests
    /// to inject a fake `SpeechAudioPlayer` (see `SpeechPlayerTests`) so the
    /// completion seam is provable without decodable audio bytes or
    /// wall-clock playback duration.
    private let makePlayer: (Data) throws -> SpeechAudioPlayer
    /// `nil` only via the test-only initializer, so unit tests never touch the
    /// real audio session (deactivation below becomes a no-op).
    private let session: AVAudioSession?

    private var player: SpeechAudioPlayer?
    /// Guards against a stale request finishing after a newer one started.
    private var generation: UInt64 = 0
    /// The continuation for the utterance currently awaiting playback
    /// completion (set only once playback has actually started), keyed to the
    /// generation it belongs to so a stale resume never fires twice.
    private var pending: (generation: UInt64, continuation: CheckedContinuation<SpeechPlaybackResult, Never>)?
    /// The result `terminate(with:)` resolved a generation with, keyed by
    /// that generation's number — read by an in-flight synthesis request
    /// that gets superseded or stopped before it ever reaches playback, so
    /// it can report the terminal reason *its own* generation actually ended
    /// with. Keyed per-generation (not a single shared value) because a
    /// generation can be torn down by one `terminate(with:)` call and then a
    /// *later* generation torn down by another before the first request's
    /// `await` ever resumes — a single shared var would let the later call's
    /// reason clobber the earlier generation's before it's ever read.
    private var terminationReasons: [UInt64: SpeechPlaybackResult] = [:]
    /// Performs the network synthesis call. Defaults to the real
    /// `RestClient.speak`; overridden in tests to control exactly when an
    /// in-flight request resolves relative to a `stop()`/newer `speak()`.
    private let synthesize: (RestClient, String) async throws -> String

    init(session: AVAudioSession = .sharedInstance()) {
        self.session = session
        self.makePlayer = { data in
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true, options: [])
            return try LiveSpeechAudioPlayer(data: data)
        }
        self.synthesize = { rest, text in try await rest.speak(text: text) }
    }

    /// Test-only initializer: injects a player factory so tests can exercise
    /// every terminal path (finish/fail/supersede/stop) without AVFoundation,
    /// and optionally a synthesis seam so a test can hold a request "in
    /// flight" across a `stop()`/newer `speak()` call.
    init(
        makePlayer: @escaping (Data) throws -> SpeechAudioPlayer,
        synthesize: @escaping (RestClient, String) async throws -> String = { rest, text in try await rest.speak(text: text) }
    ) {
        self.session = nil
        self.makePlayer = makePlayer
        self.synthesize = synthesize
    }

    /// Synthesize `text` and play it, suspending until the utterance is truly
    /// idle. Cancels any current utterance first.
    ///
    /// - Parameters:
    ///   - text: assistant text to speak (empty/whitespace is ignored).
    ///   - messageId: the bubble's id, mirrored into `speakingMessageId` so the
    ///     UI can show per-message state. Pass `nil` for ad-hoc playback.
    ///   - rest: the gateway REST client (from `ConnectionStore.rest`).
    /// - Returns: the terminal reason this utterance ended. Empty/whitespace
    ///   `text` returns `.stopped` without starting anything.
    @discardableResult
    func speak(text: String, messageId: UUID? = nil, rest: RestClient) async -> SpeechPlaybackResult {
        guard !UITestAudioGuard.isUITestAudioMuted else { return .completed }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .stopped }

        terminate(with: .superseded)   // tear down any current utterance
        lastError = nil
        generation &+= 1
        let myGeneration = generation
        speakingMessageId = messageId
        isActive = true

        let dataURL: String
        do {
            dataURL = try await synthesize(rest, trimmed)
        } catch {
            // A newer speak()/stop() may have superseded us while the request
            // was in flight — only surface the error if we are still live.
            guard myGeneration == generation else { return consumeTerminationReason(for: myGeneration) }
            lastError = (error as? LocalizedError)?.errorDescription
                ?? "Speech failed: \(error.localizedDescription)"
            clearState()
            return .synthesisFailed(lastError ?? "Speech synthesis failed.")
        }

        guard myGeneration == generation else { return consumeTerminationReason(for: myGeneration) }   // superseded/stopped

        guard let audioData = Self.decodeAudioDataURL(dataURL) else {
            lastError = "Received malformed audio from the server."
            clearState()
            return .malformedAudio
        }

        let newPlayer: SpeechAudioPlayer
        do {
            newPlayer = try makePlayer(audioData)
        } catch {
            lastError = "Could not play audio: \(error.localizedDescription)"
            clearState()
            return .playbackFailed(lastError ?? "Could not start playback.")
        }

        newPlayer.onFinish = { [weak self] in
            Task { @MainActor [weak self] in
                self?.finishIfActive(generation: myGeneration, result: .completed)
            }
        }
        _ = newPlayer.prepareToPlay()
        guard newPlayer.play() else {
            lastError = "Could not play audio: playback failed to start."
            clearState()
            return .playbackFailed(lastError ?? "Could not start playback.")
        }
        self.player = newPlayer

        return await withCheckedContinuation { continuation in
            pending = (myGeneration, continuation)
        }
    }

    /// Stop any current playback and reset state immediately. If a `speak`
    /// call is currently awaiting completion, it resolves with `.stopped`.
    func stop() {
        terminate(with: .stopped)
    }

    // MARK: - Internals

    /// The single funnel that ends the current generation: resolves a pending
    /// completion continuation (if any) with `result`, tears down the player,
    /// and bumps `generation` so any stale in-flight work (synthesis request,
    /// late delegate callback) no-ops. Called by `stop()` (`.stopped`) and by
    /// `speak()` superseding a prior utterance (`.superseded`).
    private func terminate(with result: SpeechPlaybackResult) {
        terminationReasons[generation] = result
        if let pending, pending.generation == generation {
            pending.continuation.resume(returning: result)
        }
        pending = nil
        generation &+= 1
        clearState()   // also stops/tears down the player, if any
    }

    /// Reads and discards the stored terminal reason for `gen` — read
    /// exactly once, by the in-flight synthesis request that owned `gen`,
    /// when it notices (post-`await`) that it's no longer the live
    /// generation. Falls back to `.superseded` for a generation that was
    /// never explicitly terminated (defensive; every real supersede/stop
    /// path always records one first via `terminate(with:)`).
    private func consumeTerminationReason(for gen: UInt64) -> SpeechPlaybackResult {
        terminationReasons.removeValue(forKey: gen) ?? .superseded
    }

    /// Resolves the pending continuation for `generation` with `result`, iff
    /// that generation is still the live one — i.e. no `stop()`/supersede
    /// already claimed this utterance's terminal result. Used by the player's
    /// completion callback (natural finish or async playback failure).
    private func finishIfActive(generation callGeneration: UInt64, result: SpeechPlaybackResult) {
        guard callGeneration == generation else { return }   // already terminated
        if let pending, pending.generation == callGeneration {
            pending.continuation.resume(returning: result)
        }
        pending = nil
        clearState()
    }

    private func clearState() {
        player?.onFinish = nil
        player?.stop()
        player = nil
        speakingMessageId = nil
        isActive = false
        try? session?.setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// Decode a `data:<mime>;base64,<payload>` URL into raw audio bytes.
    /// Exposed `nonisolated static` for unit testing.
    nonisolated static func decodeAudioDataURL(_ dataURL: String) -> Data? {
        guard dataURL.hasPrefix("data:"),
              let commaIndex = dataURL.firstIndex(of: ",") else { return nil }
        let header = dataURL[dataURL.startIndex..<commaIndex]
        guard header.contains(";base64") else { return nil }
        let payload = String(dataURL[dataURL.index(after: commaIndex)...])
        return Data(base64Encoded: payload, options: [.ignoreUnknownCharacters])
    }
}

/// Terminal outcome of a `SpeechPlayer.speak` call — fires exactly once per
/// call, on every path: normal finish, explicit `stop()`, being superseded by
/// a newer `speak`, malformed synthesis payload, synthesis-request failure,
/// or a playback setup/start failure.
enum SpeechPlaybackResult: Equatable, Sendable {
    case completed
    case stopped
    case superseded
    case malformedAudio
    case synthesisFailed(String)
    case playbackFailed(String)
}

/// Test seam over the real audio-playback engine: the surface `SpeechPlayer`
/// needs to start playback and observe completion. `LiveSpeechAudioPlayer`
/// wraps a real `AVAudioPlayer`; tests substitute a fake so the completion
/// seam is provable without decodable audio bytes or wall-clock duration.
///
/// Deliberately NOT `@MainActor`: a real `AVAudioPlayerDelegate` callback can
/// land on an arbitrary thread (see `LiveSpeechAudioPlayer` below), so
/// `onFinish` must be callable from there. `SpeechPlayer` only ever mutates
/// player state from the main actor; `onFinish` itself hops back via `Task`.
protocol SpeechAudioPlayer: AnyObject {
    /// Invoked exactly once when playback ends, successfully or not (mirrors
    /// `AVAudioPlayerDelegate`'s finish/decode-error callbacks collapsed to one
    /// signal — `SpeechPlayer` treats either as `.completed` since a decode
    /// error after playback already started has no separate UI treatment).
    var onFinish: (@Sendable () -> Void)? { get set }
    func prepareToPlay() -> Bool
    func play() -> Bool
    func stop()
}

/// Production `SpeechAudioPlayer`: wraps a real `AVAudioPlayer`, bridging its
/// `NSObject`-based Obj-C delegate callback (invoked on an arbitrary thread)
/// to `onFinish`, hopping to the main actor before touching any state.
private final class LiveSpeechAudioPlayer: NSObject, SpeechAudioPlayer, AVAudioPlayerDelegate, @unchecked Sendable {
    var onFinish: (@Sendable () -> Void)?
    private let avPlayer: AVAudioPlayer

    init(data: Data) throws {
        avPlayer = try AVAudioPlayer(data: data)
        super.init()
        avPlayer.delegate = self
    }

    func prepareToPlay() -> Bool { avPlayer.prepareToPlay() }
    func play() -> Bool { avPlayer.play() }
    func stop() { avPlayer.stop() }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish?()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        onFinish?()
    }
}
