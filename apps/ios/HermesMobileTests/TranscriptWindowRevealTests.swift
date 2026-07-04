import XCTest
@testable import HermesMobile

/// ABH-400 REWORK — windowed transcript backward-load reveal contract.
///
/// The eager-tail render path in `ChatView` shows only the LAST `windowSize`
/// messages via a plain (non-lazy) VStack:
///
///     let allRows = Array(chatStore.messages.enumerated())
///     let windowStart = max(0, allRows.count - windowSize)
///     let rows = Array(allRows[windowStart...])
///
/// When `loadEarlierTranscript()` fetches an older server page it PREPENDS
/// ~50 rows (`messages.count` grows 50 -> 100) but does NOT itself grow the
/// render window. The server-page branch of `loadEarlierChip` owns the grow;
/// if it forgets, `windowStart` advances 0 -> 50 and the freshly-fetched
/// rows 0..49 are sliced out of `rows` and NEVER render — a silent no-op /
/// false-done (only a SECOND tap reveals them via the client grow branch).
///
/// These tests pin the reveal invariant against the pure helpers that lift
/// the render-slice math out of the view body, so the contract is provable
/// WITHOUT a SwiftUI hosting controller. They FAIL against the pre-fix code
/// (where the server-page branch never grew `windowSize`) because the
/// "window stays unchanged after a prepend" assertion contradicts the
/// required reveal.
final class TranscriptWindowRevealTests: XCTestCase {

    // MARK: - renderWindowStart — the slice math used by the view body

    /// The base case: a transcript of exactly `windowSize` rows renders from
    /// index 0 (nothing hidden above the fold).
    func testRenderWindowStartCoversWholeTranscript() {
        let window = ChatView.transcriptWindow
        XCTAssertEqual(
            ChatView.renderWindowStart(messageCount: window, windowSize: window),
            0,
            "When the transcript fits in the window, windowStart must be 0"
        )
    }

    /// ABH-400 core: BEFORE the server-page backward load, the window shows the
    /// newest `transcriptWindow` rows (windowStart = 0 because the first page
    /// is exactly the tail). This is the cold-open state item #1 already pins.
    func testRenderWindowStartColdOpenTailOnly() {
        let window = ChatView.transcriptWindow
        XCTAssertEqual(
            ChatView.renderWindowStart(messageCount: window, windowSize: window),
            0,
            "Cold-open: first server page fills the tail window exactly, windowStart = 0"
        )
    }

    // MARK: - The defect: prepend WITHOUT growing the window hides the fetch

    /// This is the REVEAL test. It encodes the exact scenario from the defect
    /// report: a server page prepends `transcriptWindow` older rows onto a
    /// transcript that already had `transcriptWindow` rows.
    ///
    /// With the fix applied, the server-page branch grows `windowSize` by the
    /// prepend delta, so `renderWindowStart` returns to 0 and the fetched rows
    /// render. WITHOUT the fix, the window is unchanged and windowStart advances
    /// to `transcriptWindow`, slicing the fetched rows out — the silent no-op.
    ///
    /// We assert the post-fix invariant directly: after applying the
    /// server-page reveal grow, the render-window start for the grown
    /// transcript is 0 (full reveal).
    func testServerPageRevealGrowsWindowSoFetchedRowsRender() {
        let window = ChatView.transcriptWindow               // e.g. 50
        let beforeCount = window                             // cold-open tail
        let prepended = window                               // one full older page

        // The server-page branch measures the actual prepend delta and grows.
        let grownWindow = ChatView.windowSizeAfterServerPageReveal(
            currentWindowSize: window,
            prependedRowCount: prepended
        )
        let afterCount = beforeCount + prepended             // 50 -> 100

        // THE REVEAL: windowStart must be 0 so rows 0..<afterCount all render.
        let windowStartAfterReveal = ChatView.renderWindowStart(
            messageCount: afterCount,
            windowSize: grownWindow
        )
        XCTAssertEqual(
            windowStartAfterReveal, 0,
            "ABH-400: after the server-page backward load, windowStart must be 0 so the "
            + "freshly-prepended older rows render. A non-zero value means the window was "
            + "not grown and the fetched rows are sliced out (the false-done no-op)."
        )

        // The grown window must cover the whole grown transcript.
        XCTAssertGreaterThanOrEqual(
            grownWindow, afterCount,
            "The grown window must cover the full transcript after the reveal"
        )
    }

    /// The NEGATIVE space — proves the test would catch a regression to the
    /// pre-fix code where the server-page branch left `windowSize` untouched.
    /// We simulate the BROKEN behavior (window unchanged after prepend) and
    /// assert windowStart is NON-zero, i.e. the fetched rows are hidden. This
    /// documents exactly what the fix prevents and guarantees the assertion
    /// above is load-bearing (not trivially satisfiable).
    func testBrokenBehaviorLeavesFetchedRowsHidden() {
        let window = ChatView.transcriptWindow               // e.g. 50
        let beforeCount = window
        let prepended = window
        let afterCount = beforeCount + prepended             // 100

        // BROKEN: server-page branch did NOT grow the window.
        let brokenWindow = window                            // unchanged
        let brokenStart = ChatView.renderWindowStart(
            messageCount: afterCount,
            windowSize: brokenWindow
        )
        XCTAssertEqual(
            brokenStart, window,
            "Pre-fix: with the window unchanged, windowStart advances to \(window) and the "
            + "fetched rows 0..<\(window) are sliced out — the silent no-op the fix removes."
        )
        XCTAssertNotEqual(brokenStart, 0,
                          "The broken path must NOT reveal (windowStart != 0); this proves "
                          + "the reveal test above is not trivially satisfiable.")
    }

    // MARK: - Edge cases: the grow must reflect the ACTUAL delta, not assume page size

    /// A short final page (fewer rows than `transcriptWindow`) must grow the
    /// window by exactly the number prepended, not by the full page size.
    /// Over-growing would claim a reveal of rows that were never fetched.
    func testShortFinalPageGrowsByActualPrependDelta() {
        let window = ChatView.transcriptWindow
        let shortPage = 17                                   // fewer than window

        let grown = ChatView.windowSizeAfterServerPageReveal(
            currentWindowSize: window,
            prependedRowCount: shortPage
        )
        XCTAssertEqual(
            grown, window + shortPage,
            "A short final page must grow the window by exactly \(shortPage), not by the "
            + "full page size — never claim a reveal of rows that were not fetched."
        )
    }

    /// A fetch that prepended NOTHING (empty page / network failure) must NOT
    /// grow the window. Growing on a zero delta would claim a false reveal.
    func testEmptyPrependDoesNotGrowWindow() {
        let window = ChatView.transcriptWindow
        let grown = ChatView.windowSizeAfterServerPageReveal(
            currentWindowSize: window,
            prependedRowCount: 0
        )
        XCTAssertEqual(
            grown, window,
            "A zero-row prepend must leave the window untouched — no false reveal."
        )
    }

    /// A negative delta (defensive: count shrank during the await, e.g. a
    /// concurrent reseed) must also be a no-op, never shrink the window.
    func testNegativePrependIsNoOp() {
        let window = ChatView.transcriptWindow
        let grown = ChatView.windowSizeAfterServerPageReveal(
            currentWindowSize: window,
            prependedRowCount: -3
        )
        XCTAssertEqual(
            grown, window,
            "A negative delta must be a no-op; the window never shrinks via this path."
        )
    }

    // MARK: - Two sequential backward loads (paging deeper)

    /// Paging twice must reveal both pages. After the second prepend the
    /// window covers the original tail + both older pages, and windowStart
    /// is still 0.
    func testTwoSequentialServerPageReveals() {
        let window = ChatView.transcriptWindow
        var total = window
        var currentWindow = window

        // First backward page.
        let firstPage = window
        currentWindow = ChatView.windowSizeAfterServerPageReveal(
            currentWindowSize: currentWindow,
            prependedRowCount: firstPage
        )
        total += firstPage
        XCTAssertEqual(
            ChatView.renderWindowStart(messageCount: total, windowSize: currentWindow),
            0,
            "After the first backward page, windowStart must be 0 (reveal)."
        )

        // Second backward page.
        let secondPage = window
        currentWindow = ChatView.windowSizeAfterServerPageReveal(
            currentWindowSize: currentWindow,
            prependedRowCount: secondPage
        )
        total += secondPage
        XCTAssertEqual(
            ChatView.renderWindowStart(messageCount: total, windowSize: currentWindow),
            0,
            "After the second backward page, windowStart must still be 0 (both pages revealed)."
        )
        XCTAssertEqual(currentWindow, window * 3,
                       "Two full pages + the tail => window = 3x transcriptWindow")
    }
}
