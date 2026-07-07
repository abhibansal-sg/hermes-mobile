import XCTest
@testable import HermesMobile

/// Focused coverage for the file viewer's rendered-markdown mode selection
/// (STR-659 arm A / STR-699). Exercises the pure, SwiftUI-free
/// ``FileViewerMarkdown`` helpers so the mode-detection contract is locked
/// independently of view rendering.
final class FileViewerMarkdownTests: XCTestCase {

    // MARK: - isMarkdownPath

    func testIsMarkdownPathAcceptsLowercaseMD() {
        XCTAssertTrue(FileViewerMarkdown.isMarkdownPath("README.md"))
        XCTAssertTrue(FileViewerMarkdown.isMarkdownPath("docs/intro.md"))
    }

    func testIsMarkdownPathAcceptsMarkdownExtension() {
        XCTAssertTrue(FileViewerMarkdown.isMarkdownPath("notes.markdown"))
        XCTAssertTrue(FileViewerMarkdown.isMarkdownPath("a/b/CHANGELOG.markdown"))
    }

    func testIsMarkdownPathIsCaseInsensitive() {
        XCTAssertTrue(FileViewerMarkdown.isMarkdownPath("README.MD"))
        XCTAssertTrue(FileViewerMarkdown.isMarkdownPath("Readme.Md"))
        XCTAssertTrue(FileViewerMarkdown.isMarkdownPath("Notes.MARKDOWN"))
    }

    func testIsMarkdownPathRejectsNonMarkdownExtensions() {
        XCTAssertFalse(FileViewerMarkdown.isMarkdownPath("notes.txt"))
        XCTAssertFalse(FileViewerMarkdown.isMarkdownPath("app.swift"))
        XCTAssertFalse(FileViewerMarkdown.isMarkdownPath("data.json"))
        XCTAssertFalse(FileViewerMarkdown.isMarkdownPath("image.png"))
        XCTAssertFalse(FileViewerMarkdown.isMarkdownPath("style.css"))
    }

    func testIsMarkdownPathRejectsNoExtensionOrBareName() {
        XCTAssertFalse(FileViewerMarkdown.isMarkdownPath("Makefile"))
        XCTAssertFalse(FileViewerMarkdown.isMarkdownPath("LICENSE"))
        XCTAssertFalse(FileViewerMarkdown.isMarkdownPath(""))
        XCTAssertFalse(FileViewerMarkdown.isMarkdownPath("no_extension"))
    }

    func testIsMarkdownPathOnlyConsidersFinalExtension() {
        // `.md` must be the actual extension, not a substring of another.
        XCTAssertFalse(FileViewerMarkdown.isMarkdownPath("archive.md.tar.gz"))
        XCTAssertTrue(FileViewerMarkdown.isMarkdownPath("weird.tar.md"))
        XCTAssertFalse(FileViewerMarkdown.isMarkdownPath("notmarkdown.txt"))
    }

    // MARK: - defaultViewMode

    func testDefaultViewModeMarkdownWithoutDiffIsRendered() {
        // Contract: a markdown file with no diff opens rendered.
        XCTAssertEqual(
            FileViewerMarkdown.defaultViewMode(isMarkdown: true, isDiffAvailable: false),
            .rendered
        )
    }

    func testDefaultViewModeMarkdownWithDiffIsSource() {
        // When a diff IS available the diff arm owns presentation; source is the
        // safe fallback and the user can still toggle to rendered.
        XCTAssertEqual(
            FileViewerMarkdown.defaultViewMode(isMarkdown: true, isDiffAvailable: true),
            .source
        )
    }

    func testDefaultViewModeNonMarkdownIsNil() {
        XCTAssertNil(FileViewerMarkdown.defaultViewMode(isMarkdown: false, isDiffAvailable: false))
        XCTAssertNil(FileViewerMarkdown.defaultViewMode(isMarkdown: false, isDiffAvailable: true))
    }

    // MARK: - ViewMode

    func testViewModeExposesRenderedAndSourceCases() {
        XCTAssertEqual(FileViewerMarkdown.ViewMode.allCases, [.rendered, .source])
    }

    func testViewModeIsEquatableAndHashableViaRawValue() {
        // Round-trip through the raw value so the toggle's persistence surface
        // (e.g. a future default) stays stable.
        XCTAssertEqual(FileViewerMarkdown.ViewMode(rawValue: "rendered"), .rendered)
        XCTAssertEqual(FileViewerMarkdown.ViewMode(rawValue: "source"), .source)
        XCTAssertNil(FileViewerMarkdown.ViewMode(rawValue: "other"))
    }
}
