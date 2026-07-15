import XCTest
@testable import HermesMobile

/// Focused coverage for the file viewer's rendered-markdown path detection
/// (STR-659 arm A / STR-699). The Source / Rendered / Diff mode contract lives
/// in `FileViewerModeTests`; this file only locks the shared markdown
/// eligibility heuristic.
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
}
