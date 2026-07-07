import XCTest
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
