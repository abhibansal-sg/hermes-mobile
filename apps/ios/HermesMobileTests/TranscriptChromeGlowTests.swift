import XCTest
import SwiftUI
@testable import HermesMobile

/// Transcript context, reasoning, and layout tests (STR-1029 / STR-1005).
final class TranscriptChromeGlowTests: XCTestCase {

    // MARK: - 2b. Clean thinking block helpers (STR-1062)

    func testThinkingDisplayStripsStatusFacesWithoutDroppingReasoning() {
        let raw = """
        ◉_◉ processing... Reading files
        (¬‿¬) analyzing… Checking the store
        Keep the actual reasoning sentence.
        """

        let cleaned = ThinkingDisplay.cleanedText(raw)

        XCTAssertFalse(cleaned.contains("◉_◉"))
        XCTAssertFalse(cleaned.contains("(¬‿¬)"))
        XCTAssertFalse(cleaned.localizedCaseInsensitiveContains("processing..."))
        XCTAssertFalse(cleaned.localizedCaseInsensitiveContains("analyzing…"))
        XCTAssertTrue(cleaned.contains("Reading files"))
        XCTAssertTrue(cleaned.contains("Checking the store"))
        XCTAssertTrue(cleaned.contains("Keep the actual reasoning sentence."))
    }

    func testThinkingDisplayCollapsesSpinnerPlaceholderToEmpty() {
        XCTAssertEqual(ThinkingDisplay.cleanedText("next thinking to process"), "")
    }

    func testThinkingDisplaySettledDurationFormat() {
        XCTAssertEqual(ThinkingDisplay.settledLabel(duration: nil), "Thinking")
        XCTAssertEqual(ThinkingDisplay.settledLabel(duration: 4.9), "Thought for 4s")
        XCTAssertEqual(ThinkingDisplay.settledLabel(duration: 65), "Thought for 1m 5s")
    }

    // MARK: - 2c. Reasoning accordion auto-collapse (stuck-expanded regression)

    /// The streaming-driven default with no user choice: open while the turn
    /// streams, collapsed the moment it settles. This is the core auto-collapse
    /// contract a settled reasoning block must honor.
    func testReasoningExpansionAutoDefaultFollowsStreaming() {
        XCTAssertTrue(ThinkingDisplay.expansionResolved(userOverride: nil, streaming: true),
                      "a live turn opens its reasoning so the reader watches it stream")
        XCTAssertFalse(ThinkingDisplay.expansionResolved(userOverride: nil, streaming: false),
                       "a settled turn auto-collapses to the compact one-line affordance")
    }

    /// A deliberate user toggle (a value that crosses the current default) wins
    /// over the auto default and is remembered.
    func testReasoningExpansionUserToggleWins() {
        // Opened by hand on a settled turn → stays open.
        XCTAssertTrue(ThinkingDisplay.expansionResolved(userOverride: true, streaming: false))
        // Closed by hand while streaming → stays closed.
        XCTAssertFalse(ThinkingDisplay.expansionResolved(userOverride: false, streaming: true))
    }

    /// The regression guard: a DisclosureGroup echo write equal to the current
    /// default must NOT latch as an override — otherwise the settle transition's
    /// echo would pin the section open and it would never auto-collapse. A cross
    /// of the default is the only genuine user toggle.
    func testReasoningExpansionOverrideIgnoresEchoWrites() {
        // Echo equal to the streaming default → no override (auto default resumes).
        XCTAssertNil(ThinkingDisplay.expansionOverride(forWrite: true, streaming: true))
        XCTAssertNil(ThinkingDisplay.expansionOverride(forWrite: false, streaming: false))
        // Deliberate toggle crossing the default → latches.
        XCTAssertEqual(ThinkingDisplay.expansionOverride(forWrite: true, streaming: false), true)
        XCTAssertEqual(ThinkingDisplay.expansionOverride(forWrite: false, streaming: true), false)
    }

    /// End-to-end of the stuck-expanded fix: a turn opens while streaming, the
    /// group echoes its open state back through the setter (equal to the default),
    /// and when the turn settles the resolved state collapses instead of staying
    /// pinned open.
    func testReasoningSettleCollapsesAfterEchoWrite() {
        // Streaming: default open.
        var override = ThinkingDisplay.expansionOverride(forWrite: true, streaming: true) // echo
        XCTAssertNil(override, "echo write while streaming does not latch")
        XCTAssertTrue(ThinkingDisplay.expansionResolved(userOverride: override, streaming: true))
        // Turn settles: no override, so it collapses.
        XCTAssertFalse(ThinkingDisplay.expansionResolved(userOverride: override, streaming: false),
                       "settled reasoning collapses; the streaming echo never pinned it open")
        override = ThinkingDisplay.expansionOverride(forWrite: false, streaming: false) // settle echo
        XCTAssertNil(override)
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

    /// Regular (iPad) transcript rows must use the shared token.
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
            availableWidth: 1_024, horizontalSizeClass: .regular)
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
            availableWidth: 390, horizontalSizeClass: .compact)
        XCTAssertEqual(cap, 390 * 0.78, accuracy: 0.001)
        XCTAssertEqual(cap, 390 * MessageBubble.userBubbleCompactWidthFraction, accuracy: 0.001)
    }

    /// A `nil` size class (e.g. no environment injected) must fall back to
    /// the compact formula rather than silently widening to the iPad token —
    /// the safer default for an unknown context.
    func testUserBubbleNilSizeClassFallsBackToCompactFormula() {
        let cap = MessageBubble.userBubbleMaxWidth(availableWidth: 390, horizontalSizeClass: nil)
        XCTAssertEqual(cap, 390 * 0.78, accuracy: 0.001)
    }

    /// Pins the original 78% compact ratio so it cannot silently drift while
    /// being refactored into a named constant.
    func testUserBubbleCompactWidthFractionUnchanged() {
        XCTAssertEqual(MessageBubble.userBubbleCompactWidthFraction, 0.78, accuracy: 0.001)
    }

    // MARK: - QA-1 B12/A4: no reserved space for an empty dock
    //
    // The resting gap must equal the composer clearance plus nothing for an
    // empty dock.

    /// An empty Turn Dock (`TurnDockContent.none` → `EmptyView`) must reserve no
    /// clearance: dockHeight 0 adds nothing to the spacer, so the resting gap on
    /// the relay path (no dock, no pill) is byte-identical to the approved
    /// composer-only full-bleed clearance.
    func testEmptyDockReservesNoComposerClearance() {
        XCTAssertEqual(
            TurnDockContent.resolve(hasApproval: false, hasClarification: false,
                                    hasTasks: false, hasQueued: false),
            .none,
            "no pending surfaces → the dock shows nothing")
        let noDock = ChatView.composerClearance(composerHeight: 90, keyboardHeight: 0)
        let emptyDock = ChatView.composerClearance(composerHeight: 90, keyboardHeight: 0,
                                                   dockHeight: 0)
        XCTAssertEqual(emptyDock, noDock, accuracy: 0.001,
            "an empty dock must add zero reserved clearance")
        XCTAssertEqual(noDock, ChatView.composerFloatInset, accuracy: 0.001,
            "resting clearance stays the approved full-bleed floor (composer frozen)")
    }

    /// A live dock surface (approval/clarify/tasks) DOES reserve its measured
    /// height — the ratified dock behavior is unchanged by B8/B12 (the dock is
    /// the one home for interactive chrome and must keep clearing the last row).
    func testLiveDockStillReservesItsHeight() {
        let rest = ChatView.composerClearance(composerHeight: 90, keyboardHeight: 0)
        let withDock = ChatView.composerClearance(composerHeight: 90, keyboardHeight: 0,
                                                  dockHeight: 120)
        XCTAssertEqual(withDock, rest + 120 + ChatView.bottomStackSpacing, accuracy: 0.001)
    }

    // MARK: - QA-3 S1/A10: CWD-row → composer gap tightened

    /// QA-3 S1/A10 — the project/CWD row sat in a dead band above the composer
    /// (owner: "too much vertical gap"). The resting clearance floor drops from
    /// build-116's 140 to the ratified UX1 floor (120 — exactly clears the glass
    /// composer) and the breathing pad from 16 to 8: ~20-28 pt of void removed
    /// at rest (compact chrome, C2), keyboard + dock composition UNCHANGED.
    func testQA3S1_ComposerClearanceTightened() {
        XCTAssertEqual(ChatView.composerFloatInset, 120, accuracy: 0.001,
            "spec S1/A10: the resting floor is the UX1 minimum (120), not the 140 dead band")
        XCTAssertEqual(ChatView.composerBreathingGap, 8, accuracy: 0.001,
            "spec S1/A10: the breathing pad is 8 pt (was 16)")
        // A typical measured composer (~100 pt): clearance clamps to the floor —
        // 20 pt tighter than build 116's 140.
        XCTAssertEqual(ChatView.composerClearance(composerHeight: 100, keyboardHeight: 0),
                       120, accuracy: 0.001)
        // A tall measured composer: measured + 8 breathing (was + 16).
        XCTAssertEqual(ChatView.composerClearance(composerHeight: 180, keyboardHeight: 0),
                       188, accuracy: 0.001)
        // Keyboard + dock composition is byte-identical to the approved formula.
        let composed = ChatView.composerClearance(
            composerHeight: 100, keyboardHeight: 336, dockHeight: 64)
        XCTAssertEqual(
            composed,
            120 + 64 + ChatView.bottomStackSpacing + max(0, 336 - HermesLayoutConstants.controlBottomBaseline),
            accuracy: 0.001,
            "keyboard + dock clearance composition is unchanged by the gap tightening")
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
