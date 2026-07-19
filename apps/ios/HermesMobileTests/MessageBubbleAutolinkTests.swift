import XCTest
import SwiftUI
@testable import HermesMobile

/// Wave 25 link fixes — unit tests for the pure post-processors added to
/// `MessageBubble`'s markdown pipeline:
///
/// 1. `autolinkBareURLs(in:)` — detects a bare `http(s)://` URL that
///    `AttributedString(markdown:)`'s inline-only parse left as dead text and
///    sets `.link` on it, without disturbing markdown links the parser already
///    linkified or URLs shown as inline code.
/// 2. `attributed(_:linkColor:)` — the full pipeline (markdown parse →
///    autolink → explicit link style), confirmed to give every link run
///    (markdown `[label](url)` and newly-autolinked bare URLs alike) the
///    `linkColor` tint + underline instead of leaving it to inherit only the
///    ambient global tint.
///
/// Both are `nonisolated static` pure functions over `AttributedString` — no
/// view instantiation, no `@MainActor` needed.
final class MessageBubbleAutolinkTests: XCTestCase {

    // MARK: - Helpers

    /// Returns the `.link` URL of the run(s) covering `substring`'s first
    /// occurrence in `text`, or nil if that span has no link / isn't found.
    private func linkURL(in attributed: AttributedString, for substring: String) -> URL? {
        let plain = String(attributed.characters)
        guard let range = plain.range(of: substring) else { return nil }
        guard let attrRange = Range(range, in: attributed) else { return nil }
        // A single token should be a single run; take the first run's link.
        return attributed[attrRange].runs.first?.link
    }

    private func underline(in attributed: AttributedString, for substring: String) -> Bool {
        let plain = String(attributed.characters)
        guard let range = plain.range(of: substring) else { return false }
        guard let attrRange = Range(range, in: attributed) else { return false }
        return attributed[attrRange].runs.first?.underlineStyle != nil
    }

    // MARK: - 1. autolinkBareURLs — bare URL detection

    func testBareHTTPSURLGetsLinked() {
        let plain = AttributedString("see https://example.com for details")
        let result = MessageBubble.autolinkBareURLs(in: plain)
        XCTAssertEqual(linkURL(in: result, for: "https://example.com"),
                       URL(string: "https://example.com"),
                       "a bare https URL with no markdown wrapper must be autolinked")
    }

    func testBareHTTPURLGetsLinked() {
        let plain = AttributedString("http://example.com is old-school")
        let result = MessageBubble.autolinkBareURLs(in: plain)
        XCTAssertEqual(linkURL(in: result, for: "http://example.com"),
                       URL(string: "http://example.com"),
                       "bare http (not just https) URLs must also be autolinked")
    }

    func testTrailingSentencePunctuationNotSwallowed() {
        let plain = AttributedString("Check out https://example.com/docs. It's great.")
        let result = MessageBubble.autolinkBareURLs(in: plain)
        // NSDataDetector trims the trailing period itself — the link must not
        // extend into (or swallow) the sentence-ending punctuation.
        XCTAssertEqual(linkURL(in: result, for: "https://example.com/docs"),
                       URL(string: "https://example.com/docs"))
        let plainText = String(result.characters)
        XCTAssertTrue(plainText.hasSuffix("docs. It's great."),
                      "the trailing period must remain part of the sentence, not the link")
    }

    func testNoBareURLIsNoOp() {
        let plain = AttributedString("no links in this sentence at all")
        let result = MessageBubble.autolinkBareURLs(in: plain)
        XCTAssertNil(linkURL(in: result, for: "sentence"))
        XCTAssertEqual(String(result.characters), String(plain.characters))
    }

    func testEmptyStringIsNoOp() {
        let result = MessageBubble.autolinkBareURLs(in: AttributedString(""))
        XCTAssertEqual(String(result.characters), "")
    }

    // MARK: - 2. autolinkBareURLs — protected runs are left untouched

    func testExistingMarkdownLinkIsNotReplaced() throws {
        // A real markdown link's *destination* need not equal its label text —
        // if autolinking blindly re-set `.link` from the visible text it would
        // clobber a deliberately different destination.
        let markdown = try XCTUnwrap(AttributedString(
            markdown: "[click here](https://real-destination.example.com)",
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ))
        XCTAssertEqual(linkURL(in: markdown, for: "click here"),
                       URL(string: "https://real-destination.example.com"),
                       "sanity: the markdown parser itself must have linked the label")
        let result = MessageBubble.autolinkBareURLs(in: markdown)
        XCTAssertEqual(linkURL(in: result, for: "click here"),
                       URL(string: "https://real-destination.example.com"),
                       "an already-linked run must be left untouched by the bare-URL pass")
    }

    func testMarkdownLinkWithBareURLAsLabelIsNotDoubleProcessed() throws {
        // `[https://example.com](https://example.com)` — the visible text IS a
        // bare URL, but the run already carries `.link` from the markdown
        // parse, so the autolink pass must skip it (not merely a no-op
        // re-assignment, but a genuine skip per `hasProtectedLinkAttributes`).
        let markdown = try XCTUnwrap(AttributedString(
            markdown: "[https://example.com](https://example.com)",
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ))
        let result = MessageBubble.autolinkBareURLs(in: markdown)
        XCTAssertEqual(linkURL(in: result, for: "https://example.com"),
                       URL(string: "https://example.com"))
    }

    func testBareURLInsideInlineCodeIsNotLinked() throws {
        let markdown = try XCTUnwrap(AttributedString(
            markdown: "run `https://example.com` verbatim",
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ))
        let result = MessageBubble.autolinkBareURLs(in: markdown)
        XCTAssertNil(linkURL(in: result, for: "https://example.com"),
                    "a URL rendered as inline code must stay dead text, not become tappable")
    }

    func testMultipleBareURLsAllLinked() {
        let plain = AttributedString("first https://one.example.com then https://two.example.com")
        let result = MessageBubble.autolinkBareURLs(in: plain)
        XCTAssertEqual(linkURL(in: result, for: "https://one.example.com"),
                       URL(string: "https://one.example.com"))
        XCTAssertEqual(linkURL(in: result, for: "https://two.example.com"),
                       URL(string: "https://two.example.com"))
    }

    // MARK: - 3. attributed(_:linkColor:) — full pipeline styling

    func testAttributedAppliesLinkColorAndUnderlineToBareURL() {
        let result = MessageBubble.attributed("visit https://example.com now", linkColor: .red)
        XCTAssertEqual(linkURL(in: result, for: "https://example.com"),
                       URL(string: "https://example.com"),
                       "the full pipeline must autolink, not just the raw markdown parse")
        XCTAssertTrue(underline(in: result, for: "https://example.com"),
                      "a linked run must carry an underline style")
    }

    func testAttributedAppliesLinkColorToMarkdownLink() {
        let result = MessageBubble.attributed("[docs](https://example.com/docs)", linkColor: .red)
        XCTAssertEqual(linkURL(in: result, for: "docs"), URL(string: "https://example.com/docs"))
        XCTAssertTrue(underline(in: result, for: "docs"),
                      "an explicit markdown link must also get the explicit transcript link style")
    }

    func testAttributedPlainTextUnaffected() {
        let result = MessageBubble.attributed("just plain prose, nothing to link", linkColor: .red)
        XCTAssertEqual(String(result.characters), "just plain prose, nothing to link")
        XCTAssertNil(linkURL(in: result, for: "plain"))
    }
}
