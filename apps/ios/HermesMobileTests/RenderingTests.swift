import XCTest
import SwiftUI
@testable import HermesMobile

/// Coverage for the E3 rendering engine: markdown fence segmentation
/// (including the streaming-tail case), syntax-highlighter smoke tests, and
/// ANSI SGR parsing / stripping.
final class RenderingTests: XCTestCase {

    // MARK: - MessageSegmenter

    func testPlainProseIsSingleSegment() {
        let segments = MessageSegmenter.segments("just some prose\nwith two lines")
        XCTAssertEqual(segments.count, 1)
        guard case .prose(let body) = segments[0] else {
            return XCTFail("expected prose, got \(segments[0])")
        }
        XCTAssertEqual(body, "just some prose\nwith two lines")
    }

    func testEmptyInputYieldsNoSegments() {
        XCTAssertTrue(MessageSegmenter.segments("").isEmpty)
    }

    func testSingleFencedBlockWithLanguage() {
        let text = """
        here is code:
        ```swift
        let x = 1
        print(x)
        ```
        done
        """
        let segments = MessageSegmenter.segments(text)
        XCTAssertEqual(segments.count, 3)

        guard case .prose(let lead) = segments[0] else { return XCTFail("seg0 not prose") }
        XCTAssertEqual(lead, "here is code:")

        guard case .code(let lang, let body) = segments[1] else { return XCTFail("seg1 not code") }
        XCTAssertEqual(lang, "swift")
        XCTAssertEqual(body, "let x = 1\nprint(x)")

        guard case .prose(let tail) = segments[2] else { return XCTFail("seg2 not prose") }
        XCTAssertEqual(tail, "done")
    }

    func testFenceWithoutLanguageHasNilLanguage() {
        let text = "```\nraw\n```"
        let segments = MessageSegmenter.segments(text)
        XCTAssertEqual(segments.count, 1)
        guard case .code(let lang, let body) = segments[0] else { return XCTFail("not code") }
        XCTAssertNil(lang)
        XCTAssertEqual(body, "raw")
    }

    func testUnterminatedFenceWhileStreamingTreatsTailAsCode() {
        // Mid-stream: opening fence arrived, closing fence has not yet.
        let text = """
        building the function now:
        ```python
        def greet(name):
            return f"hi {name}"
        """
        let segments = MessageSegmenter.segments(text)
        XCTAssertEqual(segments.count, 2)

        guard case .prose(let lead) = segments[0] else { return XCTFail("seg0 not prose") }
        XCTAssertEqual(lead, "building the function now:")

        guard case .code(let lang, let body) = segments[1] else { return XCTFail("seg1 not code") }
        XCTAssertEqual(lang, "python")
        XCTAssertEqual(body, "def greet(name):\n    return f\"hi {name}\"")
    }

    func testEmptyCodeBlockYieldsEmptyBody() {
        let segments = MessageSegmenter.segments("```\n```")
        XCTAssertEqual(segments.count, 1)
        guard case .code(_, let body) = segments[0] else { return XCTFail("not code") }
        XCTAssertEqual(body, "")
    }

    func testMultipleCodeBlocks() {
        let text = """
        first:
        ```js
        a()
        ```
        between
        ```sql
        SELECT 1
        ```
        """
        let segments = MessageSegmenter.segments(text)
        // prose, code, prose, code → 4
        XCTAssertEqual(segments.count, 4)
        guard case .code(let l1, _) = segments[1] else { return XCTFail("seg1 not code") }
        XCTAssertEqual(l1, "js")
        guard case .code(let l2, _) = segments[3] else { return XCTFail("seg3 not code") }
        XCTAssertEqual(l2, "sql")
    }

    func testIndentedFenceIsRecognised() {
        // CommonMark allows up to leading whitespace before a fence.
        let text = "  ```bash\n  echo hi\n  ```"
        let segments = MessageSegmenter.segments(text)
        XCTAssertEqual(segments.count, 1)
        guard case .code(let lang, _) = segments[0] else { return XCTFail("not code") }
        XCTAssertEqual(lang, "bash")
    }

    func testLanguageHintIsLowercasedAndFirstTokenOnly() {
        let text = "```Swift extra info\ncode\n```"
        let segments = MessageSegmenter.segments(text)
        guard case .code(let lang, _) = segments[0] else { return XCTFail("not code") }
        XCTAssertEqual(lang, "swift")
    }

    func testBlankLinesBetweenBlocksDoNotProduceEmptyProse() {
        let text = "```\nx\n```\n\n```\ny\n```"
        let segments = MessageSegmenter.segments(text)
        // Two code segments, no empty prose between them.
        XCTAssertEqual(segments.count, 2)
        for segment in segments {
            if case .prose = segment { XCTFail("unexpected prose: \(segment)") }
        }
    }

    // MARK: - SyntaxHighlighter

    func testHighlighterReturnsSameCharactersAsInput() {
        // Highlighting must never lose or reorder characters — only styles.
        let code = "func add(_ a: Int, _ b: Int) -> Int { a + b }"
        let attributed = SyntaxHighlighter.highlight(code, language: "swift")
        XCTAssertEqual(String(attributed.characters), code)
    }

    func testHighlighterUnknownLanguageStillMonospacedPlain() {
        let code = "some random text 123"
        let attributed = SyntaxHighlighter.highlight(code, language: "brainfuck")
        XCTAssertEqual(String(attributed.characters), code)
    }

    func testHighlighterNilLanguageDoesNotCrashAndPreservesText() {
        let code = "{ \"a\": 1 }"
        let attributed = SyntaxHighlighter.highlight(code, language: nil)
        XCTAssertEqual(String(attributed.characters), code)
    }

    func testHighlighterAppliesKeywordColor() {
        // A Swift keyword should be coloured differently from the plain default.
        let code = "let x = 1"
        let attributed = SyntaxHighlighter.highlight(code, language: "swift")
        // Find the run covering "let" and assert it carries a foreground color
        // distinct from the default plain colour.
        var sawKeywordColor = false
        for run in attributed.runs {
            let slice = String(attributed[run.range].characters)
            if slice.contains("let"), let color = run.foregroundColor, color == SyntaxHighlighter.Theme.keyword {
                sawKeywordColor = true
            }
        }
        XCTAssertTrue(sawKeywordColor, "expected 'let' to be keyword-coloured")
    }

    func testHighlighterLanguageAliasesResolve() {
        XCTAssertTrue(SyntaxHighlighter.isSupported("ts"))
        XCTAssertTrue(SyntaxHighlighter.isSupported("py"))
        XCTAssertTrue(SyntaxHighlighter.isSupported("zsh"))
        XCTAssertTrue(SyntaxHighlighter.isSupported("YAML"))
        XCTAssertFalse(SyntaxHighlighter.isSupported("cobol"))
        XCTAssertFalse(SyntaxHighlighter.isSupported(nil))
    }

    func testHighlighterSmokeEveryLanguage() {
        let samples: [(String, String)] = [
            ("swift", "let n: Int = 0x1F // hi"),
            ("python", "def f(): return 'x'  # c"),
            ("javascript", "const a = `t${1}`"),
            ("typescript", "interface A { x: number }"),
            ("bash", "echo $HOME # comment"),
            ("json", "{\"k\": true, \"n\": 1}"),
            ("yaml", "key: value # note"),
            ("go", "func main() { var x = 1 }"),
            ("rust", "fn main() { let x = 1; }"),
            ("sql", "SELECT * FROM t WHERE id = 1"),
            ("html", "<div class=\"a\">x</div>"),
            ("css", ".a { color: red; }")
        ]
        for (lang, code) in samples {
            let attributed = SyntaxHighlighter.highlight(code, language: lang)
            XCTAssertEqual(String(attributed.characters), code, "lang \(lang) altered text")
        }
    }

    // MARK: - AnsiText

    func testStripOrRenderPlainTextUnchanged() {
        let attributed = AnsiText.stripOrRender("hello world")
        XCTAssertEqual(String(attributed.characters), "hello world")
    }

    func testAnsiSequencesAreRemovedFromRenderedCharacters() {
        // ESC[31m red ESC[0m  →  visible text is "red text" only.
        let raw = "\u{1B}[31mred\u{1B}[0m text"
        let attributed = AnsiText.stripOrRender(raw)
        XCTAssertEqual(String(attributed.characters), "red text")
    }

    func testStripRemovesAllEscapes() {
        let raw = "\u{1B}[1;32mgreen bold\u{1B}[0m done"
        XCTAssertEqual(AnsiText.strip(raw), "green bold done")
    }

    func testStripIsIdentityWithoutEscapes() {
        XCTAssertEqual(AnsiText.strip("no codes here"), "no codes here")
    }

    func testStripRemovesNonSGRSequences() {
        // Cursor move (\u{1B}[2J) and colour both stripped.
        let raw = "\u{1B}[2J\u{1B}[33myellow\u{1B}[0m"
        XCTAssertEqual(AnsiText.strip(raw), "yellow")
    }

    func testColoredRunGetsForegroundColor() {
        let raw = "\u{1B}[31mRED\u{1B}[0m"
        let attributed = AnsiText.stripOrRender(raw)
        var coloredScalarCount = 0
        for run in attributed.runs where run.foregroundColor != nil {
            coloredScalarCount += String(attributed[run.range].characters).count
        }
        XCTAssertEqual(coloredScalarCount, 3, "all of 'RED' should be coloured")
    }

    func testBrightForegroundParsed() {
        let raw = "\u{1B}[92mbright green\u{1B}[0m"
        let attributed = AnsiText.stripOrRender(raw)
        XCTAssertEqual(String(attributed.characters), "bright green")
        let hasColor = attributed.runs.contains { $0.foregroundColor != nil }
        XCTAssertTrue(hasColor)
    }

    func testResetClearsStyleForSubsequentText() {
        // After reset, the trailing text should have no explicit foreground.
        let raw = "\u{1B}[31mred\u{1B}[0mplain"
        let attributed = AnsiText.stripOrRender(raw)
        // The "plain" tail run must exist with no foreground color.
        let plainHasNoColor = attributed.runs.contains { run in
            String(attributed[run.range].characters).contains("plain") && run.foregroundColor == nil
        }
        XCTAssertTrue(plainHasNoColor)
    }

    func testTruncatedEscapeAtEndDoesNotCrash() {
        // A dangling escape (stream cut mid-sequence) must be handled safely.
        let raw = "text\u{1B}["
        let stripped = AnsiText.strip(raw)
        XCTAssertEqual(stripped, "text")
        let rendered = AnsiText.stripOrRender(raw)
        XCTAssertEqual(String(rendered.characters), "text")
    }

    func testBackgroundCodesAreParsedButNotRenderedAsForeground() {
        // 44 = blue background; visible text intact, no crash.
        let raw = "\u{1B}[44mon blue\u{1B}[0m"
        let attributed = AnsiText.stripOrRender(raw)
        XCTAssertEqual(String(attributed.characters), "on blue")
    }

    // MARK: - image_generate native tool card

    func testGeneratedImageToolResultPrefersHostImage() {
        let result = GeneratedImageToolResult(resultJSON: """
        {"host_image":" https://cdn.example.com/generated.png ","image":"https://fallback.example.com/other.png","agent_visible_image":"/tmp/agent.png"}
        """)

        XCTAssertEqual(result?.reference, "https://cdn.example.com/generated.png")
        XCTAssertEqual(result?.remoteURL?.absoluteString, "https://cdn.example.com/generated.png")
        XCTAssertFalse(result?.isServerLocalPath ?? true)
    }

    func testGeneratedImageToolResultFallsThroughToFirstNonEmptyLocator() {
        let result = GeneratedImageToolResult(resultJSON: """
        {"host_image":"   ","image":"","agent_visible_image":"/tmp/hermes-generated.png"}
        """)

        XCTAssertEqual(result?.reference, "/tmp/hermes-generated.png")
        XCTAssertNil(result?.remoteURL)
        XCTAssertTrue(result?.isServerLocalPath ?? false)
    }

    func testGeneratedImageToolResultNilForEmptyOrMissingLocator() {
        XCTAssertNil(GeneratedImageToolResult(resultJSON: ""))
        XCTAssertNil(GeneratedImageToolResult(resultJSON: "{\"ok\":true}"))
    }

    func testToolClusterGeneratedImageBranchOnlyForImageGenerate() {
        let preview = "{\"image\":\"https://cdn.example.com/generated.png\"}"
        let imageTool = ToolActivity(
            id: "tool-1",
            name: GeneratedImageToolResult.toolName,
            argsSummary: "{}",
            progressText: "",
            resultPreview: preview,
            state: .done,
            durationMs: 1200,
            todos: nil
        )
        let nonImageTool = ToolActivity(
            id: "tool-2",
            name: "web_search",
            argsSummary: "{}",
            progressText: "",
            resultPreview: preview,
            state: .done,
            durationMs: nil,
            todos: nil
        )

        XCTAssertEqual(ToolClusterView.generatedImageResult(for: imageTool)?.reference,
                       "https://cdn.example.com/generated.png")
        XCTAssertNil(ToolClusterView.generatedImageResult(for: nonImageTool),
                     "Only image_generate should take the native image-card branch")
    }
}
