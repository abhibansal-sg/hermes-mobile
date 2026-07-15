import Foundation
import Observation

/// The phases of a hands-free voice conversation turn. Mirrors desktop's
/// `ConversationStatus` (`apps/desktop/.../use-voice-conversation.ts`):
/// `idle → listening → transcribing → thinking → speaking → idle (re-arm)`.
///
/// `idle` is the only re-arm-safe state — every public control and every
/// stale-callback guard funnels back through it before a fresh listen begins.
struct VoiceConversationStatus: Equatable, Sendable {
    /// `idle`: not in a turn. Listening can be (re-)armed when enabled + unmuted.
    static let idle = Self(rawValue: "idle")
    /// `listening`: the microphone capture is active, waiting for speech / silence.
    static let listening = Self(rawValue: "listening")
    /// `transcribing`: the capture was stopped and is being transcribed.
    static let transcribing = Self(rawValue: "transcribing")
    /// `thinking`: the transcript was auto-submitted; the agent is generating.
    static let thinking = Self(rawValue: "thinking")
    /// `speaking`: the assistant reply is being played back via TTS.
    static let speaking = Self(rawValue: "speaking")

    let rawValue: String
}

/// Pure orchestration layer for the mobile hands-free voice loop
/// (STR-344 / ABH-378). This controller owns ONLY the turn state machine:
///
///   idle → listening → transcribing → thinking → speaking → idle
///
/// It performs no microphone, TTS, or network I/O itself. Every side effect is
/// an injected closure (``Dependencies``), so the full state machine is drivable
/// in a headless unit test with fakes — exactly the contract `engine-ios` pinned
/// for this unit. The UI wiring (STR-533) binds those closures to `VoiceRecorder`,
/// `SpeechPlayer`, and `ChatStore`.
///
/// ## Loop model
/// - `start()` enables conversation mode and begins listening (when unmuted).
/// - Silence / a manual stop ends listening: `stopTurn(forceTranscribe:)`
///   transcribes the capture, auto-submits a non-empty transcript, and enters
///   `thinking`.
/// - ``handleTurnComplete(replyText:)`` is the reply hand-off: the wiring calls
///   it from `ChatStore.onTurnComplete` with the assistant's reply. A non-empty
///   reply enters `speaking`; an empty/`nil` reply re-arms listening. After
///   speech finishes, listening re-arms.
/// - No-speech / empty-transcript re-arms listening without submitting.
/// - Muting cancels the in-flight capture and returns to `idle`; unmuting re-arms
///   if a turn isn't already in flight.
///
/// ## Stale-cancellation (generation guard)
/// Every await boundary that can re-arm (transcription completion, speech
/// completion) is generation-guarded: `end()` / `toggleMute()` (on) / a fresh
/// listen bumps ``generation``, so a callback landing AFTER a stop can never
/// restart the loop or clobber the settled state. This mirrors `VoiceRecorder`'s
/// and `SpeechPlayer`'s own generation invariants (R1 #92) at the orchestration
/// layer.
///
/// ## Non-goals (v1)
/// No VAD / silence detection (the wiring drives `stopTurn`), no barge-in while
/// speaking, no CarPlay/Bluetooth route picking. `VoiceRecorder`'s existing
/// tap/hold dictation is untouched — this controller never calls it directly.
@MainActor
@Observable
final class VoiceConversationController {

    // MARK: - Observable state

    /// Where the loop is in the current turn. Drive all conversation UI from this.
    private(set) var status: VoiceConversationStatus = .idle

    /// True while conversation mode is armed (between `start()` and `end()`).
    private(set) var isEnabled: Bool = false

    /// True when the user has muted the loop. While muted, listening never arms
    /// and an in-flight capture is cancelled; the rest of a turn in flight
    /// (transcribing/thinking/speaking) is allowed to settle. Toggled by
    /// ``toggleMute()`` and reset by ``start()``/``end()``.
    private(set) var muted: Bool = false

    /// Normalized 0...1 microphone level, read live from the injected capture
    /// dependency. `0` when nothing is recording. This is a computed view over
    /// the dependency so it stays in lockstep with `VoiceRecorder.level`; the UI
    /// wiring layer is responsible for any refresh cadence (the controller itself
    /// never polls).
    var level: Float { dependencies.level() }

    // MARK: - Dependencies

    /// The injected side effects. Held `var` so tests can swap fakes per-case if
    /// needed; production sets it once at construction.
    var dependencies: Dependencies

    // MARK: - Internals

    /// Stale-cancellation generation. Bumped by `end()`, `toggleMute()` (when
    /// muting), and at the top of every fresh listen. An await that can re-arm
    /// snapshots the generation it started on and refuses to act if it no longer
    /// matches — preventing a transcription/speech callback that landed after a
    /// stop from re-lighting `listening`.
    private var generation: Int = 0

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    // MARK: - Derived presentation

    /// A short, user-facing label for the current phase.
    var statusLabel: String {
        switch status {
        case .idle:        return "Idle"
        case .listening:   return "Listening"
        case .transcribing:return "Transcribing"
        case .thinking:    return "Thinking"
        case .speaking:     return "Speaking"
        default:           return status.rawValue.capitalized
        }
    }

    /// A VoiceOver-friendly description of the loop's state, including the mute
    /// gate. Reads like a sentence so a screen-reader user can follow the turn.
    var accessibilityLabel: String {
        let base = "Voice conversation \(statusLabel.lowercased())."
        return muted ? "\(base) Muted." : base
    }

    // MARK: - Public controls

    /// Begin a hands-free conversation: enable the mode, clear mute, and arm the
    /// first listen. Safe to call repeatedly — a mode already enabled first ends
    /// the prior session (hard stop) so `start()` is always a clean re-entry.
    func start() async {
        if isEnabled { end() }
        isEnabled = true
        muted = false
        await beginListening()
    }

    /// Hard stop. Cancels any pending listen / transcription / speech and
    /// returns to `idle`. Bumps ``generation`` so every in-flight callback
    /// (transcription landing, speech finishing) becomes a no-op — the settled
    /// `idle` state can never be clobbered by a stale completion.
    func end() {
        generation += 1
        dependencies.cancelListening()
        dependencies.stopSpeaking()
        isEnabled = false
        muted = false
        status = .idle
    }

    /// Stop the current listen and transcribe it, as if silence were detected.
    /// The single entry point the VAD / wiring / a manual "done talking" button
    /// call to close the listening phase. No-op outside `.listening`.
    ///
    /// - Parameter forceTranscribe: when `true`, the transcribe dependency is
    ///   asked to transcribe the capture even if the controller cannot prove
    ///   speech occurred (e.g. a manual tap that bypassed VAD). An empty/`nil`
    ///   transcript still re-arms rather than submitting, matching desktop.
    func stopTurn(forceTranscribe: Bool) async {
        guard status == .listening else { return }
        await handleTurn(forceTranscribe: forceTranscribe)
    }

    /// Flip the mute gate. Muting cancels the in-flight capture and drops to
    /// `idle` (the agent is allowed to finish a turn already in
    /// transcribing/thinking/speaking). Unmuting re-arms listening if the loop
    /// is enabled and idle. Bumps ``generation`` on mute so a capture completing
    /// after mute cannot re-arm.
    func toggleMute() async {
        muted.toggle()
        if muted {
            generation += 1
            dependencies.cancelListening()
            status = .idle
        } else if isEnabled, status == .idle {
            await beginListening()
        }
    }

    // MARK: - Reply hand-off (wiring → controller)

    /// Hand the assistant's reply to the loop. The UI wiring calls this from
    /// `ChatStore.onTurnComplete` with the just-finished turn's assistant text
    /// (or `nil`/empty when the turn produced no spoken reply).
    ///
    /// - A non-empty reply while `.thinking` enters `.speaking` and plays it;
    ///   on completion listening re-arms.
    /// - An empty/`nil` reply while `.thinking` re-arms listening (no-speech
    ///   path for the reply side).
    /// - Calls outside `.thinking` (idle/listening/already-speaking) are
    ///   ignored — the completion isn't ours, or we already moved on. This keeps
    ///   the controller from reacting to foreign turns.
    func handleTurnComplete(replyText: String?) async {
        guard status == .thinking else { return }
        let trimmed = (replyText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            status = .idle
            await rearmListening()
            return
        }
        let gen = generation
        status = .speaking
        await dependencies.speak(trimmed)
        // Stale guard: a hard stop / mute that bumped `generation` while TTS was
        // airborne must NOT re-arm listening after playback finishes.
        guard gen == generation else { return }
        status = .idle
        await rearmListening()
    }

    // MARK: - Loop internals

    /// Arm a fresh listen when enabled, unmuted, and idle. The entry point for
    /// the initial listen and every re-arm. Bumps ``generation`` so a callback
    /// from the PREVIOUS turn cannot collide with the new one.
    private func beginListening() async {
        guard isEnabled, !muted, status == .idle else { return }
        generation += 1
        status = .listening
        await dependencies.startListening()
    }

    /// Close the listening phase: stop + transcribe, then either auto-submit
    /// (→ `.thinking`) or re-arm on no-speech / empty transcript.
    private func handleTurn(forceTranscribe: Bool) async {
        let gen = generation
        status = .transcribing
        let transcript = await dependencies.stopAndTranscribe()
        // Stale guard: if the loop was stopped/muted while transcription was in
        // flight, do not touch state further — `end()`/`toggleMute` already
        // settled it.
        guard gen == generation else { return }

        let trimmed = (transcript ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // No speech detected (or transcription returned nothing). forceTranscribe
            // only asked the dependency to try; an empty result still re-arms rather
            // than sending a blank prompt. Matches desktop's `if (!transcript)` path.
            status = .idle
            await rearmListening()
            return
        }

        await dependencies.submitTranscript(trimmed)
        guard gen == generation else { return }   // stopped during submit
        status = .thinking
        // Wait for the wiring to call `handleTurnComplete(replyText:)`.
    }

    /// Re-arm listening after a turn leg completed, gated on the loop still
    /// being enabled and unmuted. Called from the empty-transcript, empty-reply,
    /// and post-speaking paths.
    private func rearmListening() async {
        guard isEnabled, !muted, status == .idle else { return }
        await beginListening()
    }
}

// MARK: - Dependencies

extension VoiceConversationController {

    /// The side effects the controller drives. Each is a closure so the full
    /// state machine is unit-testable with fakes — no `AVAudioSession`, mic,
    /// TTS endpoint, or gateway round-trip required. Production wires these to
    /// `VoiceRecorder` / `SpeechPlayer` / `ChatStore` in STR-533.
    struct Dependencies {
        /// Begin microphone capture (called when entering `.listening`).
        var startListening: () async -> Void
        /// Stop the capture and return its transcript (trimmed), or `nil` when
        /// nothing was recorded / transcription failed / no speech detected.
        /// Invoked when leaving `.listening` for `.transcribing`.
        var stopAndTranscribe: () async -> String?
        /// Cancel any in-flight capture immediately, discarding audio. Called by
        /// `end()` / mute. Must be safe to call when nothing is recording.
        var cancelListening: () -> Void
        /// Auto-submit a non-empty transcript as a new user turn (enters
        /// `.thinking`). Wired to `ChatStore.send` in production.
        var submitTranscript: (String) async -> Void
        /// Speak the assistant reply via TTS (enters `.speaking`). Resolves only
        /// after playback finishes (or fails). Wired to `SpeechPlayer.speak`.
        var speak: (String) async -> Void
        /// Stop any in-flight playback immediately. Called by `end()`. Must be
        /// safe to call when nothing is playing.
        var stopSpeaking: () -> Void
        /// Read the current normalized 0...1 microphone level (for the
        /// ``VoiceConversationController/level`` view).
        var level: () -> Float
    }
}
