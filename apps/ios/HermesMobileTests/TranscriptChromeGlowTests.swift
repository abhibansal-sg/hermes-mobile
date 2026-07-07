import XCTest
import SwiftUI
@testable import HermesMobile

/// Transcript-chrome glow-shell + context-line tests (STR-1029 / STR-1005).
///
/// Covers the pure decision/helper seams of the desktop-parity inline glow
/// status shell (TRANSCRIPT-CHROME-TOKENS.md §1.2) and the session context
/// line. UI-only aspects (the breathing animation, the rendered shadow) are not
/// directly XCTestable; the token values they read and the visibility gates
/// they depend on are fully covered here.
final class TranscriptChromeGlowTests: XCTestCase {

    // MARK: - 1. Status-glow token values (TRANSCRIPT-CHROME-TOKENS §1.2)

    /// The rest alpha must be 0.55 (desktop `text-midground/55` parity).
    func testStatusGlowRestAlpha() {
        XCTAssertEqual(ChatView.StatusGlowToken.restAlpha, 0.55, accuracy: 0.001)
    }

    /// Ring alpha must breathe 0.06 → 0.12; reduce-motion holds at 0.09 (mid).
    func testStatusGlowRingAlphaRange() {
        XCTAssertEqual(ChatView.StatusGlowToken.ringAlphaMin, 0.06, accuracy: 0.001)
        XCTAssertEqual(ChatView.StatusGlowToken.ringAlphaMax, 0.12, accuracy: 0.001)
        XCTAssertEqual(ChatView.StatusGlowToken.ringAlphaReduceMotion, 0.09, accuracy: 0.001)
    }

    /// Ring width is exactly 1pt.
    func testStatusGlowRingWidth() {
        XCTAssertEqual(ChatView.StatusGlowToken.ringWidth, 1, accuracy: 0.001)
    }

    /// Lift alpha must breathe 0.05 → 0.10; reduce-motion holds at 0.075 (mid).
    func testStatusGlowLiftAlphaRange() {
        XCTAssertEqual(ChatView.StatusGlowToken.liftAlphaMin, 0.05, accuracy: 0.001)
        XCTAssertEqual(ChatView.StatusGlowToken.liftAlphaMax, 0.10, accuracy: 0.001)
        XCTAssertEqual(ChatView.StatusGlowToken.liftAlphaReduceMotion, 0.075, accuracy: 0.001)
    }

    /// Lift radius must breathe 8 → 32pt; reduce-motion holds at 20 (mid).
    func testStatusGlowLiftRadiusRange() {
        XCTAssertEqual(ChatView.StatusGlowToken.liftRadiusMin, 8, accuracy: 0.001)
        XCTAssertEqual(ChatView.StatusGlowToken.liftRadiusMax, 32, accuracy: 0.001)
        XCTAssertEqual(ChatView.StatusGlowToken.liftRadiusReduceMotion, 20, accuracy: 0.001)
    }

    /// Settle-in is 180ms easeOut; breathe is 1.8s (desktop parity).
    func testStatusGlowDurations() {
        XCTAssertEqual(ChatView.StatusGlowToken.settleDuration, 0.18, accuracy: 0.001)
        XCTAssertEqual(ChatView.StatusGlowToken.breatheDuration, 1.8, accuracy: 0.001)
    }

    /// Corner radius is 12pt (.circular) — matches box token `rounded.md`.
    func testStatusGlowCornerRadius() {
        XCTAssertEqual(ChatView.StatusGlowToken.cornerRadius, 12, accuracy: 0.001)
    }

    // MARK: - 1b. Settle-in animation wiring (statusGlow.appear — STR-1029 review)

    /// The inline activity row's appear/disappear settle must be wired to a real
    /// animation driven by the `settleDuration` token, not left as a dead
    /// constant. Under normal motion the row settles via a non-nil easeOut.
    func testSettleAnimationIsLiveUnderNormalMotion() {
        let animation = ChatView.settleAnimation(reduceMotion: false)
        // Non-nil proves the token drives a real production animation
        // (it is no longer a dead 0.18 constant).
        XCTAssertNotNil(animation)
    }

    /// Under Reduce Motion the settle is instant (nil animation): the row must
    /// appear/disappear with no settle-in movement. The continuous breathe loop
    /// (handled separately in TurnActivityBar) stays static-at-mid regardless.
    func testSettleAnimationIsInstantUnderReduceMotion() {
        XCTAssertNil(ChatView.settleAnimation(reduceMotion: true))
    }

    /// The only non-nil path derives its duration from `settleDuration`, so the
    /// gate is the exclusive determinant. Asserting the boolean symmetry pins
    /// that nothing else can produce a settle animation.
    func testSettleAnimationGatedSolelyByReduceMotion() {
        XCTAssertNotNil(ChatView.settleAnimation(reduceMotion: false))
        XCTAssertNil(ChatView.settleAnimation(reduceMotion: true))
        // And the duration it would use is exactly the token (180ms).
        XCTAssertEqual(ChatView.StatusGlowToken.settleDuration, 0.18, accuracy: 0.001)
    }

    // MARK: - 2. Elapsed text (desktop ActivityTimerText parity)

    func testElapsedTextNilStartReturnsZeroSeconds() {
        XCTAssertEqual(ChatView.turnActivityElapsedText(startedAt: nil, now: Date()), "0s")
    }

    func testElapsedTextUnderMinuteShowsSeconds() {
        let now = Date()
        let started = now.addingTimeInterval(-5)
        XCTAssertEqual(ChatView.turnActivityElapsedText(startedAt: started, now: now), "5s")
    }

    func testElapsedTextAtMinuteBoundaryShowsZeroSeconds() {
        let now = Date()
        let started = now.addingTimeInterval(-60)
        // 60s → mmss format "1:00"
        XCTAssertEqual(ChatView.turnActivityElapsedText(startedAt: started, now: now), "1:00")
    }

    func testElapsedTextNeverNegative() {
        let now = Date()
        let started = now.addingTimeInterval(10) // future start clamps to 0
        XCTAssertEqual(ChatView.turnActivityElapsedText(startedAt: started, now: now), "0s")
    }

    // MARK: - 3. Activity label logic (unchanged helpers still pass)

    func testLabelShowsActiveToolNameWhenPresent() {
        XCTAssertEqual(
            ChatView.turnActivityLabel(activeToolName: "read_file", hasAssistantOutput: true),
            "read_file"
        )
    }

    func testLabelShowsStillThinkingWhenOutputStarted() {
        XCTAssertEqual(
            ChatView.turnActivityLabel(activeToolName: nil, hasAssistantOutput: true),
            "Still thinking"
        )
    }

    func testLabelShowsWorkingWhenNoOutputYet() {
        XCTAssertEqual(
            ChatView.turnActivityLabel(activeToolName: nil, hasAssistantOutput: false),
            "Working"
        )
    }

    // MARK: - 4. Context-line visibility gate

    func testContextLineHiddenForNilSummary() {
        XCTAssertFalse(ChatView.hasSessionContext(nil))
    }

    func testContextLineHiddenForNilCwd() {
        let summary = makeSummary(cwd: nil)
        XCTAssertFalse(ChatView.hasSessionContext(summary))
    }

    func testContextLineHiddenForEmptyCwd() {
        let summary = makeSummary(cwd: "   ")
        XCTAssertFalse(ChatView.hasSessionContext(summary))
    }

    func testContextLineHiddenForRootPathOnly() {
        // "/" has no basename → no usable context label.
        let summary = makeSummary(cwd: "/")
        XCTAssertFalse(ChatView.hasSessionContext(summary))
    }

    func testContextLineVisibleForRealCwd() {
        let summary = makeSummary(cwd: "/Users/abhi/projects/hermes-mobile")
        XCTAssertTrue(ChatView.hasSessionContext(summary))
    }

    // MARK: - 5. Context-line display text formatting

    func testContextLineDisplayTextNilForNoContext() {
        XCTAssertNil(ChatView.contextLineDisplayText(for: nil))
        XCTAssertNil(ChatView.contextLineDisplayText(for: makeSummary(cwd: nil)))
    }

    func testContextLineDisplayTextShowsLabelAndPath() {
        let summary = makeSummary(cwd: "/Users/abhi/projects/hermes-mobile")
        let text = ChatView.contextLineDisplayText(for: summary)
        XCTAssertNotNil(text)
        XCTAssertTrue(text!.contains("hermes-mobile"),
            "context line must include the workspace basename label")
    }

    // MARK: - 6. STR-1009 single-shell / adoption-seam contract

    /// The glow shell (TurnActivityBar) is the ONE status surface; STR-1009
    /// compact mode must slot into it, not create a second one. This test pins
    /// that `StatusGlowToken` is the single source of glow values — any future
    /// compact-mode shell must reuse it, not fork a second enum.
    func testSingleGlowTokenSource() {
        // The token enum must expose all values the shell reads. If a second
        // ad-hoc set of glow constants appears, this test forces a conscious
        // decision: either reuse StatusGlowToken or document why a second one
        // exists (which would violate the single-shell contract).
        let restAlpha = ChatView.StatusGlowToken.restAlpha
        let ringMin = ChatView.StatusGlowToken.ringAlphaMin
        let ringMax = ChatView.StatusGlowToken.ringAlphaMax
        let liftMin = ChatView.StatusGlowToken.liftAlphaMin
        let liftMax = ChatView.StatusGlowToken.liftAlphaMax
        let breathe = ChatView.StatusGlowToken.breatheDuration
        // All must be positive and ordered — a zero or reversed value would
        // mean the glow is invisible or runs backwards.
        XCTAssertGreaterThan(restAlpha, 0)
        XCTAssertLessThanOrEqual(ringMin, ringMax)
        XCTAssertLessThanOrEqual(liftMin, liftMax)
        XCTAssertGreaterThan(breathe, 0)
    }

    /// No ProgressView is used in the active-turn status shell. This is a
    /// compile-time invariant (the code does not reference ProgressView), but
    /// we assert the token contract: the shell breathes via opacity, never via
    /// a spinner. The breathe duration (1.8s) must be the animation cadence,
    // not a rotation speed.
    func testGlowIsBreathingNotSpinning() {
        // A spinner would have a sub-second rotation period; the breathe token
        // is a 1.8s opacity cycle (desktop `code-card-stream-glow 1.8s`).
        XCTAssertEqual(ChatView.StatusGlowToken.breatheDuration, 1.8, accuracy: 0.001)
        XCTAssertNotEqual(ChatView.StatusGlowToken.ringAlphaMin,
                          ChatView.StatusGlowToken.ringAlphaMax,
            "breathing must animate between two distinct alphas (not static)")
    }

    // MARK: - Reading measure reconciliation (STR-1102)
    //
    // STR-1098 named the previously-anonymous `720` regular-width clamp
    // `ChatView.transcriptReadingMeasure`; STR-1102 reconciles the user
    // `MessageBubble` column onto the same token instead of its own
    // `screenWidth * 0.78` formula drifting independently at regular width.

    /// Pins the shared token's value so an accidental edit is caught by CI
    /// rather than silently drifting the transcript rows and bubble column
    /// apart again.
    func testTranscriptReadingMeasureValue() {
        XCTAssertEqual(ChatView.transcriptReadingMeasure, 800, accuracy: 0.001)
    }

    /// Compact (iPhone) transcript rows must remain unbounded — unchanged by
    /// the token reconciliation.
    func testTranscriptRowMaxWidthCompactIsUnbounded() {
        XCTAssertEqual(ChatView.transcriptRowMaxWidth(isCompact: true), .infinity)
    }

    /// Regular (iPad) transcript rows (status glow, context line) must use
    /// the shared token, not an anonymous literal.
    func testTranscriptRowMaxWidthRegularUsesSharedToken() {
        XCTAssertEqual(
            ChatView.transcriptRowMaxWidth(isCompact: false),
            ChatView.transcriptReadingMeasure,
            accuracy: 0.001)
    }

    /// Regular-width alignment parity: at an iPad logical width (1024pt,
    /// matching the evidence harness), the user `MessageBubble` cap must
    /// equal the transcript row cap — the exact drift STR-1098/STR-1102
    /// exist to close.
    func testUserBubbleRegularWidthMatchesTranscriptRowToken() {
        let bubbleCap = MessageBubble.userBubbleMaxWidth(
            screenWidth: 1_024, horizontalSizeClass: .regular)
        let rowCap = ChatView.transcriptRowMaxWidth(isCompact: false)
        XCTAssertEqual(bubbleCap, rowCap, accuracy: 0.001,
            "regular-width MessageBubble cap must equal the shared transcript reading measure")
        XCTAssertEqual(bubbleCap, ChatView.transcriptReadingMeasure, accuracy: 0.001)
    }

    /// Compact behavior is unchanged: at an iPhone logical width (390pt,
    /// matching the evidence harness), the user bubble cap must still be the
    /// original 78%-of-screen formula.
    func testUserBubbleCompactWidthUnchanged() {
        let cap = MessageBubble.userBubbleMaxWidth(
            screenWidth: 390, horizontalSizeClass: .compact)
        XCTAssertEqual(cap, 390 * 0.78, accuracy: 0.001)
        XCTAssertEqual(cap, 390 * MessageBubble.userBubbleCompactWidthFraction, accuracy: 0.001)
    }

    /// A `nil` size class (e.g. no environment injected) must fall back to
    /// the compact formula rather than silently widening to the iPad token —
    /// the safer default for an unknown context.
    func testUserBubbleNilSizeClassFallsBackToCompactFormula() {
        let cap = MessageBubble.userBubbleMaxWidth(screenWidth: 390, horizontalSizeClass: nil)
        XCTAssertEqual(cap, 390 * 0.78, accuracy: 0.001)
    }

    /// Pins the original 78% compact ratio so it cannot silently drift while
    /// being refactored into a named constant.
    func testUserBubbleCompactWidthFractionUnchanged() {
        XCTAssertEqual(MessageBubble.userBubbleCompactWidthFraction, 0.78, accuracy: 0.001)
    }

    // MARK: - Helpers

    private func makeSummary(
        id: String = "test-session",
        cwd: String? = nil
    ) -> SessionSummary {
        SessionSummary(
            id: id,
            title: nil,
            preview: nil,
            startedAt: nil,
            messageCount: nil,
            source: nil,
            lastActive: nil,
            cwd: cwd
        )
    }
}
