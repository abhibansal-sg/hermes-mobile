import XCTest
@testable import HermesMobile

/// Coverage for the composer's `@`-mention trigger detection and token
/// insertion (Module F4A-A1, `MentionCompletion`). Pure logic — no view.
final class MentionCompletionTests: XCTestCase {

    // MARK: - Trigger detection

    func testNoMentionInPlainText() {
        XCTAssertNil(MentionCompletion.activeMention(in: ""))
        XCTAssertNil(MentionCompletion.activeMention(in: "just some text"))
    }

    func testMentionAtStartOfBuffer() {
        let mention = MentionCompletion.activeMention(in: "@main")
        XCTAssertNotNil(mention)
        XCTAssertEqual(mention?.query, "main")
    }

    func testMentionAfterWhitespace() {
        let text = "look at @src/m"
        let mention = MentionCompletion.activeMention(in: text)
        XCTAssertEqual(mention?.query, "src/m")
        // The range must cover the "@src/m" tail.
        if let range = mention?.range {
            XCTAssertEqual(String(text[range]), "@src/m")
        } else {
            XCTFail("no range")
        }
    }

    func testEmptyQueryRightAfterAtSign() {
        let mention = MentionCompletion.activeMention(in: "hello @")
        XCTAssertNotNil(mention)
        XCTAssertEqual(mention?.query, "")
    }

    func testNoMentionAfterSpaceTerminatesWord() {
        // A space after the @word ends the mention — the cursor is past it.
        XCTAssertNil(MentionCompletion.activeMention(in: "@file done "))
    }

    func testEmailDoesNotTrigger() {
        // `@` glued to a non-boundary char (an email local part) is not a mention.
        XCTAssertNil(MentionCompletion.activeMention(in: "mail me at a@b"))
    }

    func testMentionWordIncludesPathChars() {
        let mention = MentionCompletion.activeMention(in: "@a/b-c_d.txt")
        XCTAssertEqual(mention?.query, "a/b-c_d.txt")
    }

    func testNewlineTerminatesMention() {
        XCTAssertNil(MentionCompletion.activeMention(in: "@file\nmore"))
    }

    // MARK: - Completion word

    func testCompletionWordPrefixesAtSign() {
        XCTAssertEqual(MentionCompletion.completionWord(for: "src/m"), "@src/m")
        XCTAssertEqual(MentionCompletion.completionWord(for: ""), "@")
    }

    // MARK: - Token insertion

    func testInsertReplacesMentionWithFileToken() {
        let text = "see @ma"
        guard let mention = MentionCompletion.activeMention(in: text) else {
            return XCTFail("no mention")
        }
        let result = MentionCompletion.insert(
            path: "src/main.swift",
            replacing: mention,
            in: text
        )
        XCTAssertEqual(result, "see @file:src/main.swift ")
    }

    func testInsertAtBufferStart() {
        let text = "@m"
        let mention = MentionCompletion.activeMention(in: text)!
        let result = MentionCompletion.insert(path: "Makefile", replacing: mention, in: text)
        XCTAssertEqual(result, "@file:Makefile ")
    }

    func testInsertStripsServerSidePrefix() {
        let text = "@x"
        let mention = MentionCompletion.activeMention(in: text)!
        // The server may hand back a path already carrying a `@file:` prefix.
        let result = MentionCompletion.insert(path: "@file:docs/readme.md", replacing: mention, in: text)
        XCTAssertEqual(result, "@file:docs/readme.md ")
    }

    func testNormalizedPathStripsKnownPrefixes() {
        XCTAssertEqual(MentionCompletion.normalizedPath("@file:a/b"), "a/b")
        XCTAssertEqual(MentionCompletion.normalizedPath("@folder:dir"), "dir")
        XCTAssertEqual(MentionCompletion.normalizedPath("@bare"), "bare")
        XCTAssertEqual(MentionCompletion.normalizedPath("plain/path"), "plain/path")
    }

    func testInsertPreservesSurroundingText() {
        let text = "prefix text @que"
        let mention = MentionCompletion.activeMention(in: text)!
        let result = MentionCompletion.insert(path: "q.txt", replacing: mention, in: text)
        XCTAssertEqual(result, "prefix text @file:q.txt ")
    }

    // MARK: - appendMention (file-viewer "@" button; build-31 #4 wiring)

    func testAppendMentionIntoEmptyBuffer() {
        XCTAssertEqual(
            MentionCompletion.appendMention(path: "src/main.swift", to: ""),
            "@file:src/main.swift "
        )
    }

    func testAppendMentionAddsSeparatorAfterNonSpace() {
        XCTAssertEqual(
            MentionCompletion.appendMention(path: "a.txt", to: "look at"),
            "look at @file:a.txt "
        )
    }

    func testAppendMentionNoDoubleSpaceWhenBufferEndsInWhitespace() {
        XCTAssertEqual(
            MentionCompletion.appendMention(path: "a.txt", to: "look at "),
            "look at @file:a.txt "
        )
        XCTAssertEqual(
            MentionCompletion.appendMention(path: "a.txt", to: "line\n"),
            "line\n@file:a.txt "
        )
    }

    func testAppendMentionStripsExistingPrefix() {
        XCTAssertEqual(
            MentionCompletion.appendMention(path: "@file:a/b", to: ""),
            "@file:a/b "
        )
    }
}
