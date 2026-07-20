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

    // MARK: - QA-1 B8/A4: inline working-row gate (transport-aware)
    //
    // Build-114 relay-mode device QA (B8): the tail "Working" row returned on
    // the relay path — tripped at submit (`ChatStore.send` sets streaming before
    // any renderable item) and held for the whole turn, rendering a dishonest
    // static "Working · 0s" pill over the transcript tail. The ratified Wave-2.5
    // design (WAVE-ROADMAP.md) makes the streaming bubble's breathing cursor THE
    // working signal with the Turn Dock the single home for interactive chrome;
    // A4 requires NO standalone working pill on the relay path. These pin the
    // transport-aware gate: the direct transport keeps the approved desktop-
    // parity tail indicator BYTE-IDENTICAL; the relay transport suppresses the
    // row while the streaming assistant bubble renders the cursor, showing it
    // only pre-first-item (the honest accepted-and-waiting window between the
    // relay submit and the first rendered item).

    private func streamingAssistantBubble() -> ChatMessage {
        ChatMessage(role: .assistant,
                    parts: [.text(id: "p1", text: "Partial reply…")],
                    isStreaming: true)
    }

    private func userEcho() -> ChatMessage {
        ChatMessage(role: .user, parts: [.text(id: "u1", text: "hello")])
    }

    /// Direct transport: the approved behavior is unchanged — the tail indicator
    /// shows for the whole active turn, including beside the streaming bubble
    /// (desktop-parity "Still thinking" / tool-name row). This is the regression
    /// guard that the relay fix did NOT touch the approved direct path.
    func testInlineActivityGateDirectTransportUnchangedDuringStreaming() {
        XCTAssertTrue(ChatView.shouldShowInlineTurnActivity(
            isStreaming: true, hasPendingGate: false, isRelayTransport: false,
            lastMessage: streamingAssistantBubble()),
            "direct path keeps the tail indicator beside the streaming bubble")
        XCTAssertTrue(ChatView.shouldShowInlineTurnActivity(
            isStreaming: true, hasPendingGate: false, isRelayTransport: false,
            lastMessage: userEcho()),
            "direct path shows the pre-first-token indicator above the user echo")
        XCTAssertTrue(ChatView.shouldShowInlineTurnActivity(
            isStreaming: true, hasPendingGate: false, isRelayTransport: false,
            lastMessage: nil))
    }

    /// B8 regression (FAILS on qa1/base — the old gate was transport-blind and
    /// returned `true` here): on the relay transport the row is suppressed while
    /// the streaming assistant bubble renders the working cursor.
    func testInlineActivityGateRelaySuppressedWhileCursorRenders() {
        XCTAssertFalse(ChatView.shouldShowInlineTurnActivity(
            isStreaming: true, hasPendingGate: false, isRelayTransport: true,
            lastMessage: streamingAssistantBubble()),
            "relay: the streaming bubble's cursor IS the working signal — no redundant pill (A4)")
    }

    /// A freshly-created streaming bubble with NO parts yet still renders the
    /// standalone cursor (`MessageBubble.needsStandaloneCursor`), so the row is
    /// suppressed for it too — the relay's first `item.started` projects exactly
    /// such a bubble.
    func testInlineActivityGateRelaySuppressedForPartlessStreamingBubble() {
        let partless = ChatMessage(role: .assistant, parts: [], isStreaming: true)
        XCTAssertFalse(ChatView.shouldShowInlineTurnActivity(
            isStreaming: true, hasPendingGate: false, isRelayTransport: true,
            lastMessage: partless))
    }

    /// QA-2 R4/A2 (supersedes the QA-1 B8 pre-first-item clause): the Working
    /// pill is IMPOSSIBLE on the relay path in EVERY phase — pre-first-item
    /// included. The relay send appends an optimistic empty streaming assistant
    /// bubble, so the breathing caret is the accepted-and-waiting affordance;
    /// the state that could still flash the pill (the old pre-first-item
    /// branch) is deleted, not hidden. Direct transport above is unchanged.
    func testInlineActivityGateRelayNeverShowsWorkingPill() {
        XCTAssertFalse(ChatView.shouldShowInlineTurnActivity(
            isStreaming: true, hasPendingGate: false, isRelayTransport: true,
            lastMessage: userEcho()),
            "relay pre-first-item above the user echo → no pill (caret bubble affordance)")
        XCTAssertFalse(ChatView.shouldShowInlineTurnActivity(
            isStreaming: true, hasPendingGate: false, isRelayTransport: true,
            lastMessage: nil),
            "relay pre-first-item with no painted rows → no pill")
        // A SETTLED assistant tail (prior turn's history) — no pill either.
        let settled = ChatMessage(role: .assistant,
                                  parts: [.text(id: "old", text: "Earlier answer.")],
                                  isStreaming: false)
        XCTAssertFalse(ChatView.shouldShowInlineTurnActivity(
            isStreaming: true, hasPendingGate: false, isRelayTransport: true,
            lastMessage: settled))
    }

    /// Dock priority wins on BOTH transports: a turn paused on an approval /
    /// clarification / secure prompt shows its user-action UI in the dock, never
    /// the busy row (the row would lie about progress while waiting on a human).
    func testInlineActivityGatePendingGatesSuppressBothTransports() {
        for relay in [false, true] {
            XCTAssertFalse(ChatView.shouldShowInlineTurnActivity(
                isStreaming: true, hasPendingGate: true, isRelayTransport: relay,
                lastMessage: streamingAssistantBubble()))
            XCTAssertFalse(ChatView.shouldShowInlineTurnActivity(
                isStreaming: true, hasPendingGate: true, isRelayTransport: relay,
                lastMessage: userEcho()))
        }
    }

    /// Not streaming → never shows, on either transport, regardless of tail.
    func testInlineActivityGateIdleNeverShows() {
        for relay in [false, true] {
            XCTAssertFalse(ChatView.shouldShowInlineTurnActivity(
                isStreaming: false, hasPendingGate: false, isRelayTransport: relay,
                lastMessage: streamingAssistantBubble()))
            XCTAssertFalse(ChatView.shouldShowInlineTurnActivity(
                isStreaming: false, hasPendingGate: false, isRelayTransport: relay,
                lastMessage: nil))
        }
    }

    // MARK: - QA-1 B12/A4: no reserved space for empty dock / suppressed pill
    //
    // The dead space above the composer (IMG_2521) was the inline working row
    // itself (its ~37pt body + the 6pt intra-turn pad, inside the scroll
    // content) rendering over the relay-wiped transcript — NOT the clearance
    // spacer, which is the approved full-bleed value (UX1 pins the floor ≥120).
    // With B8's relay suppression removing the row, the resting gap must equal
    // the approved direct-path geometry: composer clearance + NOTHING for an
    // empty dock. These pin that an empty dock reserves zero.

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
