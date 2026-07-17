import XCTest
@testable import HermesMobile

/// D1 (build125 render surgery): the streaming bubble must re-parse only the
/// in-progress block on each 40ms flush, not the whole growing body, while
/// staying render-equivalent to the monolithic `MessageSegmenter.segments`
/// parse at every intermediate frame and byte-identical on completion.
@MainActor
final class StreamingSegmentCacheTests: XCTestCase {

    override func setUp() {
        super.setUp()
        RenderCache.resetForTesting()
    }

    // MARK: - Render-equivalence contract

    /// The observable render model: what `assistantText` actually lays out. Two
    /// segment arrays that map to the SAME render model are visually identical, so
    /// this is the exact fidelity contract the incremental path must honour
    /// (adjacent `.prose` split at a blank line flattens to the same block list).
    private enum RenderUnit: Equatable {
        case paragraph(String)
        case table(MessageBubble.MarkdownTable)
        case blockquote(String)
        case alert(MessageBubble.MarkdownAlert)
        case taskItems([MessageBubble.MarkdownTaskItem])
        case listItems([MessageBubble.MarkdownListItem])
        case image(alt: String, source: String)
        case code(language: String?, body: String)
        case math(latex: String, display: Bool)
        case embed(String)
    }

    private func renderModel(_ segments: [MessageSegmenter.Segment]) -> [RenderUnit] {
        var units: [RenderUnit] = []
        for segment in segments {
            switch segment {
            case .prose(let body):
                for entry in MessageBubble.chatProseEntries(body) {
                    switch entry {
                    case .blocks(let blocks):
                        units.append(contentsOf: blocks.map(unit(for:)))
                    case .image(let alt, let source):
                        units.append(.image(alt: alt, source: source))
                    }
                }
            case .code(let language, let body):
                units.append(.code(language: language, body: body))
            case .math(let latex, let display):
                units.append(.math(latex: latex, display: display))
            case .embed(let descriptor):
                units.append(.embed(descriptor.id))
            }
        }
        return units
    }

    private func unit(for block: MessageBubble.MarkdownBlock) -> RenderUnit {
        switch block {
        case .paragraph(let text): return .paragraph(text)
        case .table(let table): return .table(table)
        case .blockquote(let text): return .blockquote(text)
        case .alert(let alert): return .alert(alert)
        case .taskItems(let items): return .taskItems(items)
        case .listItems(let items): return .listItems(items)
        }
    }

    /// Stream `text` one character at a time and assert the incremental path is
    /// render-equivalent to the full parse at EVERY prefix, and that the final
    /// settled render (non-streaming full parse) is byte-identical.
    private func assertStreamRenderEquivalent(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        RenderCache.resetForTesting()
        let chars = Array(text)
        var prefix = ""
        for ch in chars {
            prefix.append(ch)
            let incremental = RenderCache.streamingSegments(prefix)
            let full = MessageSegmenter.segments(prefix)
            XCTAssertEqual(
                renderModel(incremental),
                renderModel(full),
                "streaming render diverged at prefix length \(prefix.count) of \(chars.count)",
                file: file,
                line: line
            )
        }
        // The incremental frames are render-equivalent (adjacent `.prose` split at
        // a blank line flattens to the same block list) but NOT array-identical to
        // the monolithic parse — that is by design.
        XCTAssertEqual(
            renderModel(RenderCache.streamingSegments(text)),
            renderModel(MessageSegmenter.segments(text)),
            file: file,
            line: line
        )
        // Completion reconciliation: once the turn settles, the bubble renders
        // through the plain (non-streaming) `RenderCache.segments`, which is a pure
        // memo over `MessageSegmenter.segments` — byte-identical to today.
        XCTAssertEqual(RenderCache.segments(text), MessageSegmenter.segments(text), file: file, line: line)
    }

    func testPlainMultiParagraphProseStreamsEquivalently() {
        assertStreamRenderEquivalent("First paragraph line one.\nline two.\n\nSecond paragraph.\n\nThird one here.")
    }

    func testFencedCodeStreamsEquivalently() {
        assertStreamRenderEquivalent("Lead prose.\n\n```swift\nlet x = 1\nprint(x)\n```\n\nTrailing prose.")
    }

    func testInterleavedProseAndMultipleCodeBlocksStreamEquivalently() {
        assertStreamRenderEquivalent("intro\n\n```\nraw\n```\nmid text\n```py\ny=2\n```\nend")
    }

    func testInlineAndDisplayMathStreamEquivalently() {
        assertStreamRenderEquivalent("Use $x^2$ inline.\n\n$$\na + b\n= c\n$$\n\nAfter math.")
    }

    func testDisplayMathSpanningBlankLineIsNeverBisected() {
        // A `$$…$$` region straddling a blank line must stay a single math segment
        // — blank-line settling is disabled once a `$` appears.
        assertStreamRenderEquivalent("Before\n\n$$x\n\n+ y$$\n\nafter")
    }

    func testGFMTableAndListStreamEquivalently() {
        assertStreamRenderEquivalent("Report:\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n- one\n- two\n\ndone")
    }

    func testMarkdownImageInProseStreamsEquivalently() {
        assertStreamRenderEquivalent("look ![alt](https://ex.com/i.png) here\n\nnext para")
    }

    func testConsecutiveBlankLinesStreamEquivalently() {
        assertStreamRenderEquivalent("one\n\n\n\ntwo\n\n\nthree")
    }

    func testUnterminatedFenceTailStreamsEquivalently() {
        assertStreamRenderEquivalent("prose\n\n```swift\nlet a = 1\nlet b = 2")
    }

    // MARK: - O(delta) bound

    /// After many paragraphs settle, a flush must parse only the in-progress
    /// paragraph, never the whole body — this is the D1 cost contract.
    func testTailParseCostIsBoundedByInProgressBlockNotTotal() {
        RenderCache.resetForTesting()
        let paragraph = String(repeating: "word ", count: 40)   // ~200 chars
        // 9 settled paragraphs, then a partial 10th (the in-progress block).
        let settled = (0..<9).map { _ in paragraph }.joined(separator: "\n\n") + "\n\n"
        let inProgress = "partial tenth paragraph so far"
        let full = settled + inProgress

        // Warm the incremental slot by streaming the settled prefix, then the tail.
        _ = RenderCache.streamingSegments(settled)
        _ = RenderCache.streamingSegments(full)

        XCTAssertGreaterThan(full.count, 1500, "precondition: body is large")
        XCTAssertEqual(
            RenderCache.streamingTailParseChars,
            inProgress.count,
            "streaming flush must re-parse only the in-progress block"
        )
        XCTAssertLessThan(
            RenderCache.streamingTailParseChars,
            full.count / 5,
            "per-flush parse cost must be O(in-progress block), not O(total)"
        )
    }

    /// Per-flush tail cost stays bounded across a whole char-by-char stream of a
    /// long prose body: it never grows to the total length.
    func testPerFlushTailNeverScalesWithTotalLength() {
        RenderCache.resetForTesting()
        let body = (0..<8).map { "Paragraph number \($0) with some filler text to add length." }
            .joined(separator: "\n\n")
        var prefix = ""
        var maxTail = 0
        for ch in Array(body) {
            prefix.append(ch)
            _ = RenderCache.streamingSegments(prefix)
            maxTail = max(maxTail, RenderCache.streamingTailParseChars)
        }
        // The largest single-paragraph tail is far below the full body length.
        XCTAssertLessThan(maxTail, body.count / 3, "tail parse scaled with total length")
    }

    /// A brand-new streaming turn that is not an extension of the prior text must
    /// reset the slot rather than reuse stale settled blocks.
    func testNonExtensionResetsSlot() {
        RenderCache.resetForTesting()
        _ = RenderCache.streamingSegments("alpha beta\n\ngamma")
        let resetsBefore = RenderCache.streamingResetCount
        let fresh = RenderCache.streamingSegments("totally different body")
        XCTAssertEqual(RenderCache.streamingResetCount, resetsBefore + 1)
        XCTAssertEqual(renderModel(fresh), renderModel(MessageSegmenter.segments("totally different body")))
    }

    /// An exact-repeat call (a scroll re-realization of the same frame) returns
    /// the memoized result without re-parsing the tail.
    func testExactRepeatDoesNotReparse() {
        RenderCache.resetForTesting()
        _ = RenderCache.streamingSegments("hello world\n\nsecond")
        _ = RenderCache.streamingSegments("hello world\n\nsecond partial")
        let repeated = "hello world\n\nsecond partial"
        let first = RenderCache.streamingSegments(repeated)
        XCTAssertEqual(RenderCache.streamingTailParseChars, 0, "repeat must not re-parse")
        XCTAssertEqual(renderModel(first), renderModel(MessageSegmenter.segments(repeated)))
    }
}
