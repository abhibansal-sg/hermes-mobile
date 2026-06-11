import AVFoundation
import Foundation
import Observation

/// Plays assistant text aloud via the gateway's `/api/audio/speak` TTS endpoint.
///
/// One utterance at a time: a fresh `speak(...)` stops any in-flight playback
/// first. `speakingMessageId` lets a `MessageBubble` show a speaker/stop state
/// for the bubble it owns. All UI-facing state is main-actor isolated.
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

    private let session: AVAudioSession
    private var player: AVAudioPlayer?
    private var delegateProxy: PlayerDelegate?
    /// Guards against a stale request finishing after a newer one started.
    private var generation: UInt64 = 0

    init(session: AVAudioSession = .sharedInstance()) {
        self.session = session
    }

    /// Synthesize `text` and play it. Cancels any current utterance first.
    ///
    /// - Parameters:
    ///   - text: assistant text to speak (empty/whitespace is ignored).
    ///   - messageId: the bubble's id, mirrored into `speakingMessageId` so the
    ///     UI can show per-message state. Pass `nil` for ad-hoc playback.
    ///   - rest: the gateway REST client (from `ConnectionStore.rest`).
    func speak(text: String, messageId: UUID? = nil, rest: RestClient) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        stop()                       // tear down any current utterance
        lastError = nil
        generation &+= 1
        let myGeneration = generation
        speakingMessageId = messageId
        isActive = true

        let dataURL: String
        do {
            dataURL = try await rest.speak(text: trimmed)
        } catch {
            // A newer speak() may have superseded us while the request was in
            // flight — only surface the error if we are still the live request.
            if myGeneration == generation {
                lastError = (error as? LocalizedError)?.errorDescription
                    ?? "Speech failed: \(error.localizedDescription)"
                clearState()
            }
            return
        }

        guard myGeneration == generation else { return }   // superseded

        guard let audioData = Self.decodeAudioDataURL(dataURL) else {
            lastError = "Received malformed audio from the server."
            clearState()
            return
        }

        do {
            try configureSessionForPlayback()
            let player = try AVAudioPlayer(data: audioData)
            let proxy = PlayerDelegate { [weak self] in
                // Hop to the main actor; ignore if a newer utterance started.
                Task { @MainActor [weak self] in
                    guard let self, myGeneration == self.generation else { return }
                    self.clearState()
                }
            }
            player.delegate = proxy
            player.prepareToPlay()
            guard player.play() else {
                throw PlaybackError.couldNotStart
            }
            self.player = player
            self.delegateProxy = proxy
        } catch {
            lastError = "Could not play audio: \(error.localizedDescription)"
            clearState()
        }
    }

    /// Stop any current playback and reset state immediately.
    func stop() {
        // Bump the generation so a pending request/delegate callback no-ops.
        generation &+= 1
        player?.stop()
        clearState()
    }

    // MARK: - Internals

    private func clearState() {
        player?.delegate = nil
        player = nil
        delegateProxy = nil
        speakingMessageId = nil
        isActive = false
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func configureSessionForPlayback() throws {
        // `.playback` so audio is audible even with the ring/silent switch on;
        // `.duckOthers` lowers background audio for the utterance.
        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try session.setActive(true, options: [])
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

    private enum PlaybackError: Error { case couldNotStart }
}

/// Bridges `AVAudioPlayerDelegate` (an `NSObject` Obj-C callback) to a Swift
/// closure. Marked `@unchecked Sendable` because AVFoundation invokes the
/// delegate on an arbitrary thread; the stored closure immediately hops to the
/// main actor, so no mutable state is shared unsafely.
private final class PlayerDelegate: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    private let onFinish: @Sendable () -> Void

    init(onFinish: @escaping @Sendable () -> Void) {
        self.onFinish = onFinish
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        onFinish()
    }
}
