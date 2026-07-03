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

/// ABH-382: iOS composer @-context trigger parity with the gateway's
/// complete.path response. Pure logic coverage so the picker can stay a thin
/// SwiftUI surface over the RPC result.
final class MentionContextTriggerTests: XCTestCase {

    func testBareAtContextHintsParseFromCompletePathResponse() {
        let raw: JSONValue = [
            "items": [
                ["text": "@diff", "display": "@diff", "meta": "git diff"],
                ["text": "@staged", "display": "@staged", "meta": "staged diff"],
                ["text": "@file:", "display": "@file:", "meta": "attach file"],
                ["text": "@folder:", "display": "@folder:", "meta": "attach folder"],
                ["text": "@url:", "display": "@url:", "meta": "fetch url"],
                ["text": "@git:", "display": "@git:", "meta": "git log"]
            ]
        ]

        let items = MentionPicker.parse(raw)

        XCTAssertEqual(items.map(\.text), ["@diff", "@staged", "@file:", "@folder:", "@url:", "@git:"])
        XCTAssertEqual(items.map(\.label), ["@diff", "@staged", "@file:", "@folder:", "@url:", "@git:"])
    }

    func testSelectingSimpleContextHintsInsertsBareToken() {
        XCTAssertEqual(replacingBareAt(with: "@diff"), "inspect @diff ")
        XCTAssertEqual(replacingBareAt(with: "@staged"), "inspect @staged ")
    }

    func testSelectingArgumentContextHintsLeavesCursorAfterPrefix() {
        XCTAssertEqual(replacingBareAt(with: "@file:"), "inspect @file:")
        XCTAssertEqual(replacingBareAt(with: "@folder:"), "inspect @folder:")
        XCTAssertEqual(replacingBareAt(with: "@url:"), "inspect @url:")
        XCTAssertEqual(replacingBareAt(with: "@git:"), "inspect @git:")
    }

    func testSelectingTypedContextValuePreservesKindPrefix() {
        XCTAssertEqual(replacingBareAt(with: "@folder:Sources/"), "inspect @folder:Sources/ ")
        XCTAssertEqual(replacingBareAt(with: "@file:Sources/App.swift"), "inspect @file:Sources/App.swift ")
        XCTAssertEqual(replacingBareAt(with: "@git:HEAD~1..HEAD"), "inspect @git:HEAD~1..HEAD ")
    }

    func testLegacyBarePathStillInsertsFileTokenByteIdentically() {
        XCTAssertEqual(replacingBareAt(with: "Sources/App.swift"), "inspect @file:Sources/App.swift ")
    }

    private func replacingBareAt(with completionText: String) -> String {
        let text = "inspect @"
        let mention = MentionCompletion.activeMention(in: text)!
        return MentionCompletion.insert(path: completionText, replacing: mention, in: text)
    }
}
