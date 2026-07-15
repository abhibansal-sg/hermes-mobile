import XCTest
@testable import HermesMobile

/// Focused coverage for the STR-659/STR-701 file-viewer mode logic:
/// auto-selection order (Diff > Rendered > Source), which modes the toolbar
/// picker should offer, markdown-extension detection, and the diff-text
/// normalization that maps a best-effort loader's raw result (clean file,
/// non-repo workspace, or a failed/unavailable endpoint) onto one "no diff"
/// signal. These are pure functions — no REST client, no view hierarchy — so
/// they exercise the exact decision points the desktop-parity contract cares
/// about without needing a simulator.
final class FileViewerModeTests: XCTestCase {

    // MARK: - Auto-selection (desktop parity: Diff > Rendered > Source)

    func testAutoSelectMarkdownCleanPicksRendered() {
        let mode = FileViewerMode.autoSelect(diffText: nil, isMarkdown: true)
        XCTAssertEqual(mode, .rendered)
    }

    func testAutoSelectMarkdownChangedPicksDiff() {
        let mode = FileViewerMode.autoSelect(diffText: "+ added line", isMarkdown: true)
        XCTAssertEqual(mode, .diff)
    }

    func testAutoSelectNonMarkdownChangedPicksDiff() {
        let mode = FileViewerMode.autoSelect(diffText: "- removed line", isMarkdown: false)
        XCTAssertEqual(mode, .diff)
    }

    func testAutoSelectCleanNonMarkdownPicksSource() {
        let mode = FileViewerMode.autoSelect(diffText: nil, isMarkdown: false)
        XCTAssertEqual(mode, .source)
    }

    /// An endpoint failure is indistinguishable from "clean" / "non-repo" to
    /// the view — `diffText` is already normalized to `nil` by the time it
    /// reaches `autoSelect`, so a failed markdown-file diff fetch still falls
    /// through to Rendered, and a failed non-markdown fetch falls to Source.
    func testAutoSelectEndpointFailureFallsThroughLikeClean() {
        XCTAssertEqual(FileViewerMode.autoSelect(diffText: nil, isMarkdown: true), .rendered)
        XCTAssertEqual(FileViewerMode.autoSelect(diffText: nil, isMarkdown: false), .source)
    }

    // MARK: - Available modes (toolbar picker options)

    func testAvailableModesCleanNonMarkdownIsSourceOnly() {
        XCTAssertEqual(FileViewerMode.availableModes(diffText: nil, isMarkdown: false), [.source])
    }

    func testAvailableModesCleanMarkdownOffersRendered() {
        XCTAssertEqual(FileViewerMode.availableModes(diffText: nil, isMarkdown: true), [.source, .rendered])
    }

    func testAvailableModesChangedNonMarkdownOffersDiff() {
        XCTAssertEqual(FileViewerMode.availableModes(diffText: "+x", isMarkdown: false), [.source, .diff])
    }

    func testAvailableModesChangedMarkdownOffersAllThree() {
        XCTAssertEqual(
            FileViewerMode.availableModes(diffText: "+x", isMarkdown: true),
            [.source, .rendered, .diff]
        )
    }

    // MARK: - Markdown extension detection

    func testIsMarkdownRecognizesMdAndMarkdownExtensions() {
        XCTAssertTrue(FileViewerModeDetection.isMarkdown(path: "docs/README.md"))
        XCTAssertTrue(FileViewerModeDetection.isMarkdown(path: "notes.MARKDOWN"))
    }

    func testIsMarkdownRejectsOtherExtensions() {
        XCTAssertFalse(FileViewerModeDetection.isMarkdown(path: "main.swift"))
        XCTAssertFalse(FileViewerModeDetection.isMarkdown(path: "no_extension"))
    }

    // MARK: - Diff-text normalization

    func testNormalizedDiffTextNilForNil() {
        XCTAssertNil(FileViewerModeDetection.normalizedDiffText(nil))
    }

    func testNormalizedDiffTextNilForEmptyOrWhitespace() {
        XCTAssertNil(FileViewerModeDetection.normalizedDiffText(""))
        XCTAssertNil(FileViewerModeDetection.normalizedDiffText("   \n  "))
    }

    func testNormalizedDiffTextPassesThroughRealDiff() {
        let diff = "@@ -1,1 +1,1 @@\n-old\n+new\n"
        XCTAssertEqual(FileViewerModeDetection.normalizedDiffText(diff), diff)
    }

    // MARK: - Diff parsing (unified diff → typed lines)

    func testDiffParserClassifiesAddedRemovedContext() {
        let raw = """
        diff --git a/a.txt b/a.txt
        index 111..222 100644
        --- a/a.txt
        +++ b/a.txt
        @@ -1,3 +1,3 @@
         context line
        -removed line
        +added line
        """
        let lines = DiffParser.parse(raw)
        XCTAssertEqual(lines.map(\.kind), [.context, .removed, .added])
        XCTAssertEqual(lines[0].oldLineNumber, 1)
        XCTAssertEqual(lines[0].newLineNumber, 1)
        XCTAssertEqual(lines[0].text, "context line")
        XCTAssertEqual(lines[1].oldLineNumber, 2)
        XCTAssertNil(lines[1].newLineNumber)
        XCTAssertEqual(lines[1].text, "removed line")
        XCTAssertNil(lines[2].oldLineNumber)
        XCTAssertEqual(lines[2].newLineNumber, 2)
        XCTAssertEqual(lines[2].text, "added line")
    }

    func testDiffParserInsertsHunkBreakBetweenMultipleHunks() {
        let raw = """
        @@ -1,1 +1,1 @@
        -a
        +b
        @@ -10,1 +10,1 @@
        -c
        +d
        """
        let lines = DiffParser.parse(raw)
        XCTAssertEqual(lines.map(\.kind), [.removed, .added, .hunkBreak, .removed, .added])
        // Second hunk's counters reset from the SECOND header, not the first.
        XCTAssertEqual(lines[3].oldLineNumber, 10)
        XCTAssertEqual(lines[4].newLineNumber, 10)
    }

    func testDiffParserDropsFileHeaderPreambleAndNoNewlineMarker() {
        let raw = """
        diff --git a/a.txt b/a.txt
        index 111..222 100644
        --- a/a.txt
        +++ b/a.txt
        @@ -1,1 +1,1 @@
        -old
        +new
        \\ No newline at end of file
        """
        let lines = DiffParser.parse(raw)
        XCTAssertEqual(lines.map(\.kind), [.removed, .added])
    }

    func testDiffParserEmptyInputYieldsNoLines() {
        XCTAssertTrue(DiffParser.parse("").isEmpty)
    }
}
