import XCTest
@testable import HermesMobile

/// UX1 polish regression tests.
///
/// Covers the testable invariants introduced by the four on-device polish items:
///
/// 1. **Shared baseline constant** — `HermesLayoutConstants.controlBottomBaseline`
///    exists, is a positive `CGFloat`, and matches the expected value so that
///    both the composer and the drawer New-chat capsule share the same bottom
///    inset. A change here is intentional (re-tune both controls at once) but
///    must not be accidental.
///
/// 2. **Archived Chats entry point relocation** — the `settingsArchivedChats`
///    accessibility identifier no longer exists in `SettingsView`; the canonical
///    entry point is now `drawerArchivedChats` in `DrawerView`. These tests pin
///    the identifier strings (compile-time constants, so a typo surfaces as a
///    build error in production code AND a test failure here) and assert the
///    presence/absence logic through the store's archive seam so we do not
///    depend on a live gateway.
///
/// 3. **Full-bleed composer inset** — `ChatView.composerFloatInset` is large
///    enough to clear the floating composer in full-bleed layout (the transcript
///    now draws to the absolute screen edges, so the inset is the sole source of
///    bottom clearance below the last message). A regression to 0 would hide the
///    last message under the glass card.
final class UX1PolishTests: XCTestCase {

    // MARK: - 1. Shared baseline constant

    /// The constant must be positive — a zero or negative value would place the
    /// composer and capsule flush with or below the home indicator on Face ID
    /// devices, making them unreadable / unreachable.
    func testControlBottomBaselineIsPositive() {
        XCTAssertGreaterThan(
            HermesLayoutConstants.controlBottomBaseline,
            0,
            "controlBottomBaseline must be positive to clear the home indicator"
        )
    }

    /// The constant's current value. This is a deliberate pin: if someone changes
    /// the value they must also update this assertion, making the change visible in
    /// review. Both the composer overlay and the New-chat capsule share this value
    /// (defined in a single place — `HermesLayoutConstants`) so an update here
    /// moves both controls together.
    func testControlBottomBaselineMatchesExpected() {
        XCTAssertEqual(
            HermesLayoutConstants.controlBottomBaseline,
            16,
            "controlBottomBaseline changed — update both controls' bottom insets "
            + "and this assertion together to keep the shared baseline contract. "
            + "16 is the USER-APPROVED value (the ~1-2mm-higher nudge after 8 pt "
            + "read too low); do not change the constant without user sign-off."
        )
    }

    // MARK: - 2. Archived Chats entry point relocation

    /// The `drawerArchivedChats` identifier must match the string stamped directly
    /// on the `archivedRevealRow` button in `DrawerView`. This test asserts
    /// against the production constant defined in `AccessibilityIDs` (or the
    /// inline string where none exists), so a rename in the production code
    /// surfaces here as a build error or a test failure — not a silent UI-test
    /// miss. The prior version compared two string literals defined entirely
    /// within the test body, which provided zero coverage of production code.
    func testDrawerArchivedChatsIdentifierString() {
        // The identifier is stamped in DrawerView's `archivedRevealRow`.
        // We verify it against the known stable value; any rename in that file
        // must be paired with an update here.
        XCTAssertEqual(
            DrawerView.archivedChatsAccessibilityIdentifier,
            "drawerArchivedChats",
            "DrawerView.archivedChatsAccessibilityIdentifier changed — update "
            + "both the production identifier and this assertion together"
        )
    }

    /// `settingsArchivedChats` must NOT be the active accessibility identifier for
    /// the Archived Chats entry point — the entry point relocated from Settings to
    /// the drawer (ABH-80). This test asserts that the active identifier is the
    /// drawer's `drawerArchivedChats`, confirming the relocation is in effect. The
    /// prior version compared two literals both defined in the test, touching no
    /// production code.
    func testSettingsArchivedChatsIdentifierIsRetired() {
        // The canonical identifier is now in the drawer, not in Settings.
        // Asserting the drawer id is NOT the retired settings id means any
        // accidental reuse of the retired string in the production identifier
        // constant will fail this test immediately.
        XCTAssertNotEqual(
            DrawerView.archivedChatsAccessibilityIdentifier,
            "settingsArchivedChats",
            "The Archived Chats entry point moved from Settings to the drawer — "
            + "the production identifier must not be the retired settingsArchivedChats id"
        )
        // Belt-and-suspenders: the identifier must start with "drawer" (not
        // "settings"), confirming the surface the entry point lives on.
        XCTAssertTrue(
            DrawerView.archivedChatsAccessibilityIdentifier.hasPrefix("drawer"),
            "archivedChatsAccessibilityIdentifier must be drawer-scoped, not settings-scoped"
        )
    }

    // MARK: - 3. Composer float inset

    /// The full-bleed layout removes safe-area margins from the transcript scroll
    /// surface. `composerFloatInset` is now the sole source of bottom padding below
    /// the last message. It must be large enough to clear the glass composer card
    /// (~100-130 pt) plus the home indicator (~34 pt on Face ID devices) plus some
    /// breathing room. A value below 120 would hide content under the glass card.
    func testComposerFloatInsetClearsGlassCard() {
        // `ChatView.composerFloatInset` is `private static let` — we access it via
        // the @testable import. If it becomes inaccessible (e.g. moved to internal),
        // replace this with a hard-coded known minimum and a comment.
        let inset = ChatView.composerFloatInset
        XCTAssertGreaterThanOrEqual(
            inset, 120,
            "composerFloatInset must be at least 120 pt to clear the glass composer "
            + "and home indicator in the full-bleed layout"
        )
    }

    // MARK: - 4. Header-clearance top inset (FIX 2)

    /// The transcript top inset must clear the floating header so the first
    /// message RESTS below it (not jammed under the pills). It is composed from the
    /// status-bar inset + the header pill height + a breathing gap, so for any
    /// realistic status-bar inset it must exceed the pill height by at least the
    /// gap. A regression to a flat small value (e.g. the old 12 pt) would jam the
    /// first message under the header.
    func testTranscriptTopInsetClearsFloatingHeader() {
        // iPhone 17 Pro status bar ≈ 59 pt.
        let safeTop: CGFloat = 59
        let inset = ChatView.transcriptTopInset(compactTopInset: safeTop)
        XCTAssertGreaterThan(
            inset, safeTop + ChatView.floatingHeaderHeight,
            "the first resting message must sit strictly BELOW the header pills' "
            + "bottom edge (status-bar inset + pill height), with a breathing gap"
        )
    }

    /// FIX 2 reconciliation with the EdgeFadeMask: the resting inset must clear the
    /// top FADE band, not just the pills. A message resting inside the fade reads as
    /// muted/jammed under the header (the device-confirmed symptom when the inset
    /// was only the ≈117 pt chrome clearance, below the 135 pt fade band). The inset
    /// floors at the fade band + the breathing gap so the first message rests in the
    /// CLEAR zone below the dissolve.
    func testTranscriptTopInsetClearsFadeBand() {
        // Nominal device: the fade-band clearance (135 + 12) must win over the
        // chrome clearance (59 + 46 + 12 = 117).
        let inset = ChatView.transcriptTopInset(compactTopInset: 59)
        XCTAssertGreaterThanOrEqual(
            inset, ChatView.transcriptTopFadeBand + ChatView.headerRestingGap,
            "the resting first message must clear the EdgeFadeMask top band so it "
            + "rests in the CLEAR zone, not muted inside the fade"
        )
        XCTAssertGreaterThan(
            inset, ChatView.transcriptTopFadeBand,
            "the resting inset must exceed the fade band height itself"
        )
    }

    /// The top inset scales with the device's status-bar inset ONCE the chrome
    /// clearance dominates (very tall status bars), so the header is always cleared.
    /// Below that crossover the inset floors at the fade-band clearance (the common
    /// case) — verified separately in `testTranscriptTopInsetFloorsAtFadeBand`.
    func testTranscriptTopInsetScalesWithStatusBar() {
        // Both insets are large enough that the CHROME clearance dominates the
        // fade-band floor (status bar + 46 + 12 > 135 + 12 ⇒ status bar > 89).
        let tall = ChatView.transcriptTopInset(compactTopInset: 100)
        let taller = ChatView.transcriptTopInset(compactTopInset: 142)
        XCTAssertGreaterThan(
            taller, tall,
            "a taller status bar must yield a larger top inset so the header is "
            + "always cleared once chrome clearance dominates"
        )
        XCTAssertEqual(taller - tall, 42, accuracy: 0.001,
            "in the chrome-dominated regime the inset delta must equal the "
            + "status-bar inset delta (the header + gap terms are constant)")
    }

    /// In the common case (realistic status bars ≤ ~89 pt) the inset floors at the
    /// fade-band clearance, so a smaller status bar does NOT drop the first message
    /// into the fade. Both 20 pt (legacy) and 59 pt (iPhone 17 Pro) floor to the
    /// same fade-band clearance.
    func testTranscriptTopInsetFloorsAtFadeBand() {
        let floor = ChatView.transcriptTopFadeBand + ChatView.headerRestingGap
        XCTAssertEqual(ChatView.transcriptTopInset(compactTopInset: 20), floor, accuracy: 0.001)
        XCTAssertEqual(ChatView.transcriptTopInset(compactTopInset: 59), floor, accuracy: 0.001)
    }

    /// The header-clearance inset is a SEPARATE, larger value than Batch D's
    /// per-turn rhythm gaps — it must not be confused with (nor collapse into) the
    /// inter-turn spacing. The first row's Batch D `topGap` is 0 (`after: nil`), so
    /// the header-clearance inset is the SOLE top clearance for the first message
    /// and there is no double-spacing of later turns.
    func testHeaderClearanceInsetIsLargerThanInterTurnGap() {
        let inset = ChatView.transcriptTopInset(compactTopInset: 59)
        XCTAssertGreaterThan(
            inset, ChatView.interTurnGap,
            "the header-clearance inset must dwarf the inter-turn gap — it clears "
            + "the whole status-bar + header zone, not just the rhythm between turns"
        )
        // The first row contributes NO per-row top gap, so the header-clearance
        // inset does not stack with Batch D spacing on the first element.
        XCTAssertEqual(
            ChatView.topGap(above: sampleUserMessage, after: nil), 0,
            "Batch D's first-row topGap must remain 0 so the header-clearance inset "
            + "is the sole top clearance and later-turn spacing is not doubled"
        )
    }

    /// A minimal user message for the topGap reconciliation assertion above.
    private var sampleUserMessage: ChatMessage {
        ChatMessage(role: .user, text: "hi")
    }

    // MARK: - 5. Composer clearance composition (SCROLL P0 rebuild)

    /// At rest (keyboard closed) the clearance is the MEASURED composer height plus
    /// the breathing gap — but never below the `composerFloatInset` floor, so the
    /// UX1 ≥120 gate holds and a short / pre-measurement composer never under-clears.
    func testComposerClearanceAtRestFloorsAtFloatInset() {
        // A short measured composer (below the floor) clamps to the floor.
        let short = ChatView.composerClearance(composerHeight: 90, keyboardHeight: 0)
        XCTAssertEqual(short, ChatView.composerFloatInset, accuracy: 0.001,
            "a measured composer below the floor must clamp to composerFloatInset")
        // A tall measured composer (multi-line) reserves measured + breathing room.
        let tall = ChatView.composerClearance(composerHeight: 180, keyboardHeight: 0)
        XCTAssertEqual(tall, 180 + ChatView.composerBreathingGap, accuracy: 0.001,
            "a tall composer reserves its measured height plus the breathing gap")
        XCTAssertGreaterThanOrEqual(short, 120,
            "the at-rest clearance must always satisfy the UX1 ≥120 floor")
    }

    /// When the keyboard opens, the clearance GROWS by the keyboard region above the
    /// shared bottom baseline (which the composer already reserves), so the last
    /// message clears BOTH the risen composer AND the keyboard. The growth is exactly
    /// `keyboardHeight - baseline` on top of the resting clearance — deterministic.
    func testComposerClearanceGrowsWithKeyboard() {
        let baseline = HermesLayoutConstants.controlBottomBaseline
        let rest = ChatView.composerClearance(composerHeight: 140, keyboardHeight: 0)
        let withKeyboard = ChatView.composerClearance(composerHeight: 140, keyboardHeight: 336)
        XCTAssertEqual(withKeyboard - rest, 336 - baseline, accuracy: 0.001,
            "the clearance must grow by exactly (keyboardHeight - baseline) when the "
            + "keyboard opens, so the content rises with the composer by the keyboard height")
        XCTAssertGreaterThan(withKeyboard, rest,
            "an open keyboard must increase the bottom clearance")
    }

    /// A keyboard shorter than the baseline (a degenerate / mid-animation frame)
    /// never SHRINKS the clearance below the resting value — the keyboard term floors
    /// at 0, so the last message is never pulled under the composer.
    func testComposerClearanceNeverShrinksBelowResting() {
        let rest = ChatView.composerClearance(composerHeight: 140, keyboardHeight: 0)
        let tinyKeyboard = ChatView.composerClearance(
            composerHeight: 140,
            keyboardHeight: HermesLayoutConstants.controlBottomBaseline - 4)
        XCTAssertEqual(tinyKeyboard, rest, accuracy: 0.001,
            "a keyboard shorter than the baseline must not reduce the clearance")
    }

    /// The at-bottom threshold (drives the streaming auto-stick gate + the pill
    /// visibility) is a positive, modest distance — large enough to absorb sub-row
    /// jitter at the tail, small enough that a reader who scrolled up a screen
    /// disarms stickiness (so they are not yanked, preserving the Batch E §3.6 gate).
    func testAtBottomThresholdIsModestPositive() {
        XCTAssertGreaterThan(ChatView.atBottomThreshold, 0)
        XCTAssertLessThan(ChatView.atBottomThreshold, 200,
            "the at-bottom threshold must be smaller than a screenful so a reader "
            + "scrolled up reading history is not treated as parked at the tail")
    }

    // MARK: - 6. at-bottom decision
    //
    // The iOS-17 fallback `atBottom(anchorMaxY:viewportHeight:threshold:)` static
    // method was deleted with the phase-2 simplification (the R2 bottom-anchor
    // onGeometryChange fallback is no longer needed — the fleet is iOS 26 and the
    // R1 `ScrollAtBottomTracker`/`onScrollGeometryChange` is the sole signal;
    // iOS 17 degrades gracefully with atBottom defaulting true). The two tests
    // that called it are retired:
    //
    //   testAtBottomDecisionFromAnchorGeometry  — deleted (no static atBottom method)
    //   testAtBottomDefaultsTrueBeforeMeasurement — deleted
    //
    // The `atBottomThreshold` constant is still tested by
    // `testAtBottomThresholdIsModestPositive`.

    // MARK: - 7. Eager transcript window (R39 / Defect 2)

    /// The eager-tail window (the last `transcriptWindow` messages rendered with NO
    /// lazy height estimation) is a positive, substantial size — large enough to
    /// cover the vast majority of real sessions in a single window (so the open
    /// lands on exact geometry without a "Load earlier" tap), but bounded so eager
    /// construction stays cheap. A deliberate, pinned choice: changing it is a
    /// perf/UX decision, not an accident.
    func testTranscriptWindowIsBoundedPositive() {
        XCTAssertGreaterThanOrEqual(ChatView.transcriptWindow, 50,
            "the eager window must cover most real sessions in a single window so "
            + "the open lands on exact-geometry tail content without a Load-earlier tap")
        XCTAssertLessThanOrEqual(ChatView.transcriptWindow, 500,
            "the eager window must stay bounded so eager row construction (even with "
            + "RenderCache memoization) does not regress hitch counts on a huge session")
    }
}
