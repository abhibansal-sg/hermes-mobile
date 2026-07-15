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

    func testLongMarkdownTableCellsSurviveSegmentationAndParsing() {
        let longSentence = String(repeating: "A complete table cell sentence. ", count: 12)
        let unbrokenToken = String(repeating: "abcdefghij", count: 8)
        let markdown = """
        | Description | Token |
        | --- | --- |
        | \(longSentence) | \(unbrokenToken) |
        """

        let segments = MessageSegmenter.segments(markdown)
        XCTAssertEqual(segments.count, 1)
        guard case .prose(let prose) = segments[0] else {
            return XCTFail("expected markdown table to remain a prose segment")
        }
        XCTAssertEqual(prose, markdown)

        let blocks = MessageBubble.markdownBlocks(prose)
        XCTAssertEqual(blocks.count, 1)
        guard case .table(let table) = blocks[0] else {
            return XCTFail("expected native markdown table block")
        }
        XCTAssertEqual(
            table.rows,
            [[longSentence.trimmingCharacters(in: .whitespaces), unbrokenToken]]
        )
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

    func testInlineDollarMathBecomesMathSegment() {
        let segments = MessageSegmenter.segments("Use $x^2$ here")
        XCTAssertEqual(segments.count, 3)
        XCTAssertProse(segments[0], "Use ")
        XCTAssertMath(segments[1], latex: "x^2", display: false)
        XCTAssertProse(segments[2], " here")
    }

    func testDisplayDollarMathBecomesDisplayMathSegment() {
        let segments = MessageSegmenter.segments("Before\n$$x^2 + y^2 = z^2$$\nAfter")
        XCTAssertEqual(segments.count, 3)
        XCTAssertProse(segments[0], "Before\n")
        XCTAssertMath(segments[1], latex: "x^2 + y^2 = z^2", display: true)
        XCTAssertProse(segments[2], "\nAfter")
    }

    func testDisplayDollarMathAllowsCommonMultilineBlock() {
        let segments = MessageSegmenter.segments("Before\n$$\nx^2 + y^2 = z^2\n$$\nAfter")
        XCTAssertEqual(segments.count, 3)
        XCTAssertProse(segments[0], "Before\n")
        XCTAssertMath(segments[1], latex: "\nx^2 + y^2 = z^2\n", display: true)
        XCTAssertProse(segments[2], "\nAfter")
    }

    func testBracketDisplayMathBecomesDisplayMathSegment() {
        let segments = MessageSegmenter.segments("Before \\[x^2 + y^2 = z^2\\] after")
        XCTAssertEqual(segments.count, 3)
        XCTAssertProse(segments[0], "Before ")
        XCTAssertMath(segments[1], latex: "x^2 + y^2 = z^2", display: true)
        XCTAssertProse(segments[2], " after")
    }

    func testParenMathBecomesInlineMathSegment() {
        let segments = MessageSegmenter.segments("Use \\(x^2\\) here")
        XCTAssertEqual(segments.count, 3)
        XCTAssertProse(segments[0], "Use ")
        XCTAssertMath(segments[1], latex: "x^2", display: false)
        XCTAssertProse(segments[2], " here")
    }

    func testEscapedDollarRemainsProse() {
        let segments = MessageSegmenter.segments("Cost is \\$5, not math")
        XCTAssertEqual(segments.count, 1)
        XCTAssertProse(segments[0], "Cost is \\$5, not math")
    }

    func testCurrencyDollarRunsRemainProse() {
        let text = "Costs are $5 and $10 today"
        let segments = MessageSegmenter.segments(text)
        XCTAssertEqual(segments.count, 1)
        XCTAssertProse(segments[0], text)
    }

    func testMathInsideFencedCodeStaysCode() {
        let text = """
        ```text
        $x^2$
        \\[y\\]
        ```
        """
        let segments = MessageSegmenter.segments(text)
        XCTAssertEqual(segments.count, 1)
        guard case .code(let language, let body) = segments[0] else {
            return XCTFail("expected code, got \(segments[0])")
        }
        XCTAssertEqual(language, "text")
        XCTAssertEqual(body, "$x^2$\n\\[y\\]")
    }

    // STR-695: markdown image syntax inside a fenced code block must stay raw
    // code text — the chat-local image splitter only ever runs against `.prose`
    // segments, so it never sees (and never hoists) an image reference that a
    // model echoes back inside a code fence.
    func testMarkdownImageSyntaxInsideFencedCodeStaysCodeNotHoisted() {
        let text = """
        Here is the markup:

        ```md
        ![alt](https://example.com/x.png)
        ```

        Done.
        """
        let segments = MessageSegmenter.segments(text)
        XCTAssertEqual(segments.count, 3)
        guard case .prose(let lead) = segments[0] else {
            return XCTFail("expected leading prose, got \(segments[0])")
        }
        XCTAssertEqual(lead.trimmingCharacters(in: .whitespacesAndNewlines), "Here is the markup:")
        guard case .code(let language, let body) = segments[1] else {
            return XCTFail("expected the fenced block to stay code, got \(segments[1])")
        }
        XCTAssertEqual(language, "md")
        XCTAssertEqual(body, "![alt](https://example.com/x.png)")

        // The code segment's body is never handed to the image splitter, but
        // prove the negative directly too: chatProseEntries applied to the raw
        // fenced body still hoists it (proving the fence — not the parser — is
        // what keeps it out of the prose path in the real render pipeline).
        let entries = MessageBubble.chatProseEntries(body)
        XCTAssertEqual(entries.count, 1)
        guard case .image = entries[0] else {
            return XCTFail("chatProseEntries alone has no fence awareness by design")
        }
    }

    func testUnclosedMathDelimiterRemainsProseWhileStreaming() {
        let text = "Streaming $x^2"
        let segments = MessageSegmenter.segments(text)
        XCTAssertEqual(segments.count, 1)
        XCTAssertProse(segments[0], text)
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

    // MARK: - Rich fences (mermaid / svg routing)

    func testMermaidFlowchartRoutesToRichDiagramMode() {
        let code = """
        graph TD
          A[Start] --> B[Finish]
        """

        guard case .mermaid(let diagram) = RichFenceDecision.make(language: "mermaid", code: code) else {
            return XCTFail("expected mermaid rich fence route")
        }

        XCTAssertEqual(diagram.layout, .flowchart)
        XCTAssertEqual(diagram.nodes.map(\.id), ["A", "B"])
        XCTAssertEqual(diagram.edges.count, 1)
    }

    /// Regression for the rejected STR-1078 source-preview path: a non-flowchart
    /// family MUST select the real local mermaid.js renderer (`.webRenderer`),
    /// never a source-only preview. This is the decision seam the contract
    /// requires — it is asserted without a live WKWebView.
    func testNonFlowchartMermaidRoutesToWebRenderer() {
        let code = """
        sequenceDiagram
          participant User
          User->>Hermes: Render this
        """

        guard case .mermaid(let diagram) = RichFenceDecision.make(language: "mermaid", code: code) else {
            return XCTFail("expected sequenceDiagram to use the mermaid rich fence route")
        }

        XCTAssertEqual(diagram.layout, .webRenderer, "non-flowchart mermaid must use the real local web renderer, not a source-only preview")
        XCTAssertEqual(diagram.source, code, "verbatim DSL must be carried for the renderer + copy/fallback")
    }

    func testMermaidRecognizesDesktopSupportedDiagramFamilies() {
        let samples = [
            """
            classDiagram
              class Animal
            """,
            """
            stateDiagram-v2
              [*] --> Ready
            """,
            """
            erDiagram
              USER ||--o{ ORDER : places
            """,
            """
            pie title Pets
              "Dogs" : 3
            """,
            """
            gantt
              title A plan
              section Done
              Task :a1, 2024-01-01, 3d
            """
        ]

        for code in samples {
            guard case .mermaid(let diagram) = RichFenceDecision.make(language: "mermaid", code: code) else {
                return XCTFail("expected rich mermaid route for:\n\(code)")
            }
            XCTAssertEqual(diagram.layout, .webRenderer, "non-flowchart family must route to the web renderer")
        }
    }

    func testMermaidWebRendererSourceIsPreservedVerbatim() {
        // Whatever the model emitted must round-trip unchanged so the renderer
        // draws the real diagram and the copy button reproduces the source.
        let code = "sequenceDiagram\n  A->>B: hi <there> & \"x\""

        guard case .mermaid(let diagram) = RichFenceDecision.make(language: "mermaid", code: code) else {
            return XCTFail("expected mermaid route")
        }
        XCTAssertEqual(diagram.source, code)
    }

    func testSvgFenceRoutesToRichDiagramModeWhenSanitizedAndValid() {
        let code = #"<svg viewBox="0 0 10 10"><circle cx="5" cy="5" r="4"/></svg>"#

        guard case .svg(let sanitized) = RichFenceDecision.make(language: "svg", code: code) else {
            return XCTFail("expected svg rich fence route")
        }

        XCTAssertEqual(sanitized.markup, code)
    }

    func testUnknownFenceLanguageUsesCodeMode() {
        XCTAssertEqual(RichFenceDecision.make(language: "swift", code: "let x = 1"), .code)
        XCTAssertEqual(RichFenceDecision.make(language: nil, code: "plain"), .code)
        XCTAssertEqual(RichFenceDecision.make(language: "python extra info", code: "print(1)"), .code)
    }

    func testMalformedMermaidFallsBackToCodeMode() {
        XCTAssertEqual(RichFenceDecision.make(language: "mermaid", code: "not a mermaid diagram"), .code)
        XCTAssertEqual(RichFenceDecision.make(language: "mermaid", code: "graph TD\nA -->"), .code)
    }

    func testUnsafeSvgFallsBackToCodeModeAndPreservesSourceForCodeCard() {
        let unsafe = #"<svg viewBox="0 0 10 10" onclick="alert(1)"><script>alert(1)</script><image href="https://example.com/x.png"/></svg>"#

        XCTAssertEqual(RichFenceDecision.make(language: "svg", code: unsafe), .code)
        XCTAssertNil(SVGSanitizer.sanitize(unsafe))
        // The original markup survives ANSI-strip so the code-card copy keeps it.
        XCTAssertEqual(AnsiText.strip(unsafe), unsafe)
    }

    func testSvgSanitizerRejectsExternalReferences() {
        let externalHref = #"<svg><a href="javascript:alert(1)"><text>bad</text></a></svg>"#
        let dataHref = #"<svg><use href="data:image/svg+xml;base64,AAAA"/></svg>"#
        let remoteStyle = #"<svg><rect style="fill: url(https://example.com/a.svg#x)"/></svg>"#

        XCTAssertNil(SVGSanitizer.sanitize(externalHref))
        XCTAssertNil(SVGSanitizer.sanitize(dataHref))
        XCTAssertNil(SVGSanitizer.sanitize(remoteStyle))
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

    // MARK: - Tool row copy payload (STR-518)

    func testCopyPayloadPrefersSubstantialResultPreview() {
        // >16 chars of result wins (desktop `hasSubstantialOutput` threshold).
        let activity = ToolActivity(
            id: "tool-1", name: "execute_code",
            argsSummary: "{\"code\": \"print('hi')\"}",
            progressText: "",
            resultPreview: String(repeating: "x", count: 40),
            state: .done, durationMs: nil, todos: nil
        )
        XCTAssertEqual(ToolActivityRow.copyPayload(for: activity), String(repeating: "x", count: 40))
    }

    func testCopyPayloadStripsANSIFromResult() {
        let activity = ToolActivity(
            id: "tool-1", name: "terminal",
            argsSummary: "", progressText: "",
            resultPreview: "\u{1B}[32mall good here, output is long\u{1B}[0m",
            state: .done, durationMs: nil, todos: nil
        )
        XCTAssertEqual(ToolActivityRow.copyPayload(for: activity), "all good here, output is long")
    }

    func testCopyPayloadFallsBackToArgsWhenResultIsShort() {
        // resultPreview ≤ 16 chars → args are the more useful payload.
        let activity = ToolActivity(
            id: "tool-1", name: "web_search",
            argsSummary: "rust async runtime", progressText: "",
            resultPreview: "no hits",
            state: .done, durationMs: nil, todos: nil
        )
        XCTAssertEqual(ToolActivityRow.copyPayload(for: activity), "rust async runtime")
    }

    func testCopyPayloadFallsBackToShortResultWhenNoArgs() {
        // Short non-empty result + no args must copy the RESULT, not the tool
        // name — desktop (fallback-model/index.ts:1216-1218) prefers any
        // non-empty detail over the title. Regression for STR-518 review fix.
        let activity = ToolActivity(
            id: "tool-1", name: "web_search",
            argsSummary: "", progressText: "",
            resultPreview: "no hits",
            state: .done, durationMs: nil, todos: nil
        )
        XCTAssertEqual(ToolActivityRow.copyPayload(for: activity), "no hits",
                       "A short result with no args must copy the result, not the tool name")
    }

    func testCopyPayloadFallsBackToNameWhenNoDetail() {
        let activity = ToolActivity(
            id: "tool-1", name: "mystery_tool", argsSummary: "   ",
            progressText: "", resultPreview: "   ",
            state: .running, durationMs: nil, todos: nil
        )
        XCTAssertEqual(ToolActivityRow.copyPayload(for: activity), "mystery_tool")
    }

    // MARK: - Tool row dismissal gate (STR-518)

    func testCanDismissOnlyForTerminalStates() {
        XCTAssertTrue(ToolClusterView.canDismiss(state: .done))
        XCTAssertTrue(ToolClusterView.canDismiss(state: .failed))
        XCTAssertFalse(ToolClusterView.canDismiss(state: .running),
                       "Running rows must stay visible and never be dismissible")
    }

    func testPrunedDismissedIDsDropsStaleHides() {
        let dismissed: Set<String> = ["a", "b", "z"]
        let current: Set<String> = ["a", "b", "c"]
        XCTAssertEqual(ToolClusterView.prunedDismissedIDs(dismissed, toolIDs: current),
                       ["a", "b"],
                       "Hides for ids no longer in the cluster must be pruned")
    }

    // MARK: - DiffRendering (STR-460 inline diff rendering for file-edit tools)

    func testDiffLineClassifiesAddAndRemove() {
        XCTAssertEqual(DiffRendering.classify("+foo"), .add)
        XCTAssertEqual(DiffRendering.classify("-foo"), .remove)
        XCTAssertEqual(DiffRendering.classify(" unchanged"), .context)
        XCTAssertEqual(DiffRendering.classify("@@ -1,3 +1,4 @@"), .context)
    }

    func testDiffLineFileHeadersDoNotCountAsAddOrRemove() {
        XCTAssertEqual(DiffRendering.classify("+++ b/file.swift"), .context)
        XCTAssertEqual(DiffRendering.classify("--- a/file.swift"), .context)
    }

    func testDiffStatsExcludeFileHeaders() {
        let diff = """
        diff --git a/file.swift b/file.swift
        index abc123..def456 100644
        --- a/file.swift
        +++ b/file.swift
        @@ -1,3 +1,4 @@
         unchanged line
        -removed line
        +added line one
        +added line two
        """
        let stats = DiffRendering.stats(for: diff)
        XCTAssertEqual(stats.added, 2)
        XCTAssertEqual(stats.removed, 1)
    }

    func testDiffLinesPreserveOrderAndKind() {
        let diff = "+add\n-remove\n context"
        let lines = DiffRendering.lines(in: diff)
        XCTAssertEqual(lines.map(\.kind), [.add, .remove, .context])
        XCTAssertEqual(lines.map(\.text), ["+add", "-remove", " context"])
    }

    func testToolActivityRowDefaultExpandedForFileEditDiff() {
        let diffTool = ToolActivity(
            id: "t1", name: "patch", argsSummary: "{}", progressText: "",
            resultPreview: "applied", state: .done, durationMs: 100, todos: nil,
            fullDiff: "+line"
        )
        XCTAssertTrue(ToolActivityRow.defaultExpanded(for: diffTool),
                      "a file-edit tool row carrying a diff must start expanded")
    }

    func testToolActivityRowDefaultExpandedForFailedFileEditTool() {
        let failedTool = ToolActivity(
            id: "t2", name: "write_file", argsSummary: "{}", progressText: "",
            resultPreview: "error: disk full", state: .failed, durationMs: nil, todos: nil
        )
        XCTAssertTrue(ToolActivityRow.defaultExpanded(for: failedTool),
                      "a failed file-edit tool must stay legible without an extra tap")
    }

    func testToolActivityRowNotDefaultExpandedForNonFileEditOrNoDiff() {
        let noDiffPatch = ToolActivity(
            id: "t3", name: "patch", argsSummary: "{}", progressText: "",
            resultPreview: "no changes", state: .done, durationMs: 50, todos: nil
        )
        let nonFileEdit = ToolActivity(
            id: "t4", name: "web_search", argsSummary: "{}",
            progressText: "", resultPreview: "results", state: .done,
            durationMs: nil, todos: nil
        )
        XCTAssertFalse(ToolActivityRow.defaultExpanded(for: noDiffPatch))
        XCTAssertFalse(ToolActivityRow.defaultExpanded(for: nonFileEdit))
    }

    // MARK: - STR-460 retry: multi-tool cluster must not hide a diff row

    /// A common `read_file -> patch` run: the cluster collapses (>=2 tools),
    /// but the `patch` row carries a diff, so the outer summary capsule must
    /// start expanded rather than hiding the diff behind a tap.
    func testToolClusterDefaultExpandedWhenAnyToolHasDiff() {
        let readTool = ToolActivity(
            id: "t1", name: "read_file", argsSummary: "{}", progressText: "",
            resultPreview: "file contents", state: .done, durationMs: 20, todos: nil
        )
        let patchTool = ToolActivity(
            id: "t2", name: "patch", argsSummary: "{}", progressText: "",
            resultPreview: "applied", state: .done, durationMs: 100, todos: nil,
            fullDiff: "+added line"
        )
        XCTAssertTrue(ToolClusterView.defaultExpanded(for: [readTool, patchTool]),
                      "a cluster containing a diff row must not start collapsed")
    }

    /// A `patch -> test` run where the patch failed: the failure carve-out
    /// (error must stay legible) must also keep the outer cluster expanded.
    func testToolClusterDefaultExpandedWhenAnyToolIsFailedFileEdit() {
        let failedPatch = ToolActivity(
            id: "t1", name: "patch", argsSummary: "{}", progressText: "",
            resultPreview: "error: conflict", state: .failed, durationMs: nil, todos: nil
        )
        let testTool = ToolActivity(
            id: "t2", name: "run_tests", argsSummary: "{}", progressText: "",
            resultPreview: "1 failed", state: .done, durationMs: 500, todos: nil
        )
        XCTAssertTrue(ToolClusterView.defaultExpanded(for: [failedPatch, testTool]))
    }

    func testToolClusterNotDefaultExpandedWithoutAnyDiffOrFailure() {
        let readTool = ToolActivity(
            id: "t1", name: "read_file", argsSummary: "{}", progressText: "",
            resultPreview: "file contents", state: .done, durationMs: 20, todos: nil
        )
        let searchTool = ToolActivity(
            id: "t2", name: "web_search", argsSummary: "{}",
            progressText: "", resultPreview: "results", state: .done,
            durationMs: 30, todos: nil
        )
        XCTAssertFalse(ToolClusterView.defaultExpanded(for: [readTool, searchTool]))
    }

    // MARK: - STR-608: live same-id transition must promote expansion

    /// The exact bug scenario: a `patch` tool starts running (no diff), the
    /// row is rendered and NOT expanded, then `tool.complete` arrives and
    /// mutates that SAME tool id in place to carry a diff. Because the id set
    /// is unchanged, only a content-based sync (not an id-set-based one)
    /// catches this — this proves `syncExpansion` does, and that it forces
    /// the outer cluster open too.
    func testToolClusterSyncExpansionPromotesLiveSameIdDiffTransition() {
        let runningPatch = ToolActivity(
            id: "t1", name: "patch", argsSummary: "{}", progressText: "editing",
            resultPreview: "", state: .running, durationMs: nil, todos: nil
        )
        let completedPatch = ToolActivity(
            id: "t1", name: "patch", argsSummary: "{}", progressText: "",
            resultPreview: "applied", state: .done, durationMs: 120, todos: nil,
            fullDiff: "+added line"
        )
        let sync = ToolClusterView.syncExpansion(
            previousTools: [runningPatch],
            previousExpandedToolIDs: [],
            tools: [completedPatch]
        )
        XCTAssertTrue(sync.expandedToolIDs.contains("t1"),
                      "the tool row must expand once its live update carries a diff")
        XCTAssertTrue(sync.clusterShouldExpand,
                      "a collapsed cluster must be forced open when a tool newly defaults to expanded")
    }

    /// A failed file-edit that arrives live (same id, running -> failed) must
    /// also be promoted — the error carve-out applies live, not just at init.
    func testToolClusterSyncExpansionPromotesLiveSameIdFailureTransition() {
        let runningWrite = ToolActivity(
            id: "t1", name: "write_file", argsSummary: "{}", progressText: "writing",
            resultPreview: "", state: .running, durationMs: nil, todos: nil
        )
        let failedWrite = ToolActivity(
            id: "t1", name: "write_file", argsSummary: "{}", progressText: "",
            resultPreview: "error: disk full", state: .failed, durationMs: nil, todos: nil
        )
        let sync = ToolClusterView.syncExpansion(
            previousTools: [runningWrite],
            previousExpandedToolIDs: [],
            tools: [failedWrite]
        )
        XCTAssertTrue(sync.expandedToolIDs.contains("t1"))
        XCTAssertTrue(sync.clusterShouldExpand)
    }

    /// Ids no longer present in the live update must still be pruned from the
    /// expansion set (existing behavior, must not regress), while unrelated
    /// already-expanded ids that are still present and still default-expanded
    /// are left alone (no unnecessary re-forcing of a user's manual collapse).
    func testToolClusterSyncExpansionPrunesRemovedIdsAndLeavesUnrelatedAlone() {
        let diffTool = ToolActivity(
            id: "t1", name: "patch", argsSummary: "{}", progressText: "",
            resultPreview: "applied", state: .done, durationMs: 100, todos: nil,
            fullDiff: "+line"
        )
        let sync = ToolClusterView.syncExpansion(
            previousTools: [diffTool],
            previousExpandedToolIDs: ["t1", "stale-removed-id"],
            tools: [diffTool]
        )
        XCTAssertEqual(sync.expandedToolIDs, ["t1"])
        XCTAssertFalse(sync.clusterShouldExpand,
                       "no tool newly transitioned to default-expanded, so the cluster must not be force-reopened")
    }

    private func XCTAssertProse(
        _ segment: MessageSegmenter.Segment,
        _ expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .prose(let body) = segment else {
            return XCTFail("expected prose, got \(segment)", file: file, line: line)
        }
        XCTAssertEqual(body, expected, file: file, line: line)
    }

    private func XCTAssertMath(
        _ segment: MessageSegmenter.Segment,
        latex: String,
        display: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .math(let actualLatex, let actualDisplay) = segment else {
            return XCTFail("expected math, got \(segment)", file: file, line: line)
        }
        XCTAssertEqual(actualLatex, latex, file: file, line: line)
        XCTAssertEqual(actualDisplay, display, file: file, line: line)
    }
}
