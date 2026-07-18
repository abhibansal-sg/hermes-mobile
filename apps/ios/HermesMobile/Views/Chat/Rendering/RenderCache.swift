import SwiftUI

/// Main-actor memoization layer for the per-row rendering pipeline.
///
/// The transcript re-renders an assistant row on every streaming flush AND on
/// every scroll-driven realization. Each render previously re-ran three pure but
/// non-trivial transforms from scratch over identical input text:
///
///   1. `MessageSegmenter.segments(fullText)` — an O(n) line scan of the WHOLE
///      growing body (MessageBubble.assistantText).
///   2. `MessageBubble.prose(body)` → `AttributedString(markdown:)` — a markdown
///      parse per prose segment.
///   3. `SyntaxHighlighter.highlight(code, language:)` — a regex highlight pass
///      per code segment (CodeBlockView).
///
/// During a flick-scroll through a long transcript this re-parsing of rows that
/// have not changed is pure waste and was the dominant main-thread cost behind
/// the scroll hitching (round-2 forensics ROOT D). These caches make a render of
/// unchanged text O(1) (a dictionary lookup), so realized rows never re-parse on
/// scroll and a streaming flush only pays for the genuinely-new tail text.
/// A fourth cache covers the ABH-360 GFM block pass (tables/task lists/
/// blockquotes/lists) before paragraph text falls through to inline markdown.
///
/// **Invalidation by construction.** Every cache is keyed on the *input value*
/// (the exact text / code+language+colour). Identical input always maps to
/// identical output, so there is no staleness window: when streaming extends or
/// `applyFinalText` rewrites a part, the text value differs and the key misses,
/// producing a fresh parse. No manual clear on `isStreaming` flips, seeds, or
/// reconciles is required — a different value is simply a different key.
///
/// Each cache is bounded (FIFO eviction past `limit`) so a long session cannot
/// grow them without limit. The transforms remain pure static functions
/// (`MessageSegmenter.segments`, `MessageBubble.prose`, `SyntaxHighlighter
/// .highlight`) — these caches *wrap* them and never change their behaviour, so
/// the existing `RenderingTests` continue to exercise the uncached pure paths.
@MainActor
enum RenderCache {

    #if DEBUG
    /// DEBUG instrumentation: cumulative hit/miss counts across all three caches,
    /// surfaced by PerfHitchLogger so a scroll/stream scenario can prove the
    /// cache is actually relieving the per-render parse cost (round-2 diagnosis).
    static var hits = 0
    static var misses = 0
    #endif

    // MARK: - Segmentation

    private static var segmentCache: [String: [MessageSegmenter.Segment]] = [:]
    private static var segmentOrder: [String] = []
    private static let segmentLimit = 256

    /// Memoized `MessageSegmenter.segments`. Keyed on the full text value.
    static func segments(_ text: String) -> [MessageSegmenter.Segment] {
        if let hit = segmentCache[text] {
            #if DEBUG
            hits += 1
            #endif
            return hit
        }
        #if DEBUG
        misses += 1
        #endif
        let value = MessageSegmenter.segments(text)
        store(text, value, in: &segmentCache, order: &segmentOrder, limit: segmentLimit)
        return value
    }

    // MARK: - Markdown prose

    private static var proseCache: [String: AttributedString] = [:]
    private static var proseOrder: [String] = []
    private static let proseLimit = 512

    /// Memoized `MessageBubble.prose`. Keyed on the prose body value. The prose
    /// builder does NOT bake in any theme colour (the bubble applies
    /// `.foregroundStyle(theme.fg)` on the `Text`), so the text value is a
    /// complete key.
    static func prose(_ text: String) -> AttributedString {
        if let hit = proseCache[text] {
            #if DEBUG
            hits += 1
            #endif
            return hit
        }
        #if DEBUG
        misses += 1
        #endif
        let value = MessageBubble.prose(text)
        store(text, value, in: &proseCache, order: &proseOrder, limit: proseLimit)
        return value
    }

    // MARK: - GFM blocks

    private static var markdownBlockCache: [String: [MessageBubble.MarkdownBlock]] = [:]
    private static var markdownBlockOrder: [String] = []
    private static let markdownBlockLimit = 512

    /// Memoized GFM block parse. This is the cheap structural pass that detects
    /// tables/task lists/blockquotes/lists inside prose segments before the view
    /// falls back to the existing inline markdown renderer for paragraph text.
    static func markdownBlocks(_ text: String) -> [MessageBubble.MarkdownBlock] {
        if let hit = markdownBlockCache[text] {
            #if DEBUG
            hits += 1
            #endif
            return hit
        }
        #if DEBUG
        misses += 1
        #endif
        let value = MessageBubble.markdownBlocks(text)
        store(text, value, in: &markdownBlockCache, order: &markdownBlockOrder, limit: markdownBlockLimit)
        return value
    }

    // MARK: - Syntax highlight

    private static var highlightCache: [String: AttributedString] = [:]
    private static var highlightOrder: [String] = []
    private static let highlightLimit = 256

    /// Memoized `SyntaxHighlighter.highlight`. The highlighter bakes `baseColor`
    /// (routed from `theme.fg`) into the output, so the key includes the colour
    /// description — a theme switch yields a new key and re-highlights once.
    static func highlight(_ code: String, language: String?, baseColor: Color) -> AttributedString {
        let key = "\(baseColor.description)\u{1F}\(language ?? "")\u{1F}\(code)"
        if let hit = highlightCache[key] {
            #if DEBUG
            hits += 1
            #endif
            return hit
        }
        #if DEBUG
        misses += 1
        #endif
        let value = SyntaxHighlighter.highlight(code, language: language, baseColor: baseColor)
        store(key, value, in: &highlightCache, order: &highlightOrder, limit: highlightLimit)
        return value
    }

    // MARK: - Streaming incremental segmentation (D1)

    /// Single-slot incremental state for the ONE actively-streaming assistant
    /// tail. `segments(_:)` is keyed on the whole text value, so during a stream
    /// every 40ms flush extends `text` → a fresh key → a full O(total) re-scan of
    /// the growing body (the exact cost D1 removes). This path instead keeps the
    /// segments of the *settled* prefix (everything before the current in-progress
    /// block) and, on each flush, re-parses only the in-progress tail, so per-flush
    /// parse cost is O(current block), not O(total).
    ///
    /// **Fidelity.** The settled boundary only ever falls at a point where
    /// splitting is render-equivalent to the monolithic parse: at a fenced-code
    /// transition (a code block never spans a fence, so the split is *exact*), or —
    /// only when no LaTeX delimiter (`$` / `\`) has appeared — at a blank line.
    /// A blank-line split of a prose run yields adjacent `.prose` segments whose
    /// downstream GFM blocks (`chatProseEntries` → `markdownBlocks`) flatten into
    /// the identical sibling list the single prose segment would produce (blocks
    /// never straddle a blank line). When math delimiters are present the prose run
    /// is left whole in the tail, so multi-line `$$…$$` / `\[…\]` can never be
    /// bisected. On stream completion the bubble is rendered non-streaming through
    /// the plain `segments(_:)` full parse, so the settled output is byte-identical
    /// to today — this path only accelerates the in-progress frames.
    private static var streamPrevText = ""
    private static var streamResult: [MessageSegmenter.Segment] = []
    private static var streamSettledSegments: [MessageSegmenter.Segment] = []
    private static var streamSettledLen = 0
    private static var streamInCode = false
    private static var streamMathSeen = false

    #if DEBUG
    /// D1 instrumentation: characters handed to `MessageSegmenter.segments` for
    /// the in-progress tail on the most recent streaming flush (the per-flush
    /// parse cost the test bounds), and how many times the slot fell back to a
    /// full reset parse. `streamSettledCount` is the settled-segment count reused
    /// without re-parsing.
    static var streamingTailParseChars = 0
    static var streamingResetCount = 0
    static var streamingSettledCount = 0
    #endif

    /// Incremental segmentation for the actively-streaming tail. Render-equivalent
    /// to `segments(_:)` at every flush; falls back to a full parse when `text` is
    /// not an extension of the previous streamed value (new turn / rewrite).
    static func streamingSegments(_ text: String) -> [MessageSegmenter.Segment] {
        guard !text.isEmpty else {
            resetStreaming()
            return []
        }

        // Exact repeat (a scroll re-realization of the same streaming frame) — the
        // memoized result, no re-parse.
        if text == streamPrevText {
            #if DEBUG
            streamingTailParseChars = 0
            #endif
            return streamResult
        }

        // A non-extension (new streaming turn, or an `applyFinalText` rewrite) —
        // drop the settled prefix and rebuild from scratch.
        if streamPrevText.isEmpty || !text.hasPrefix(streamPrevText) {
            resetStreaming()
            #if DEBUG
            streamingResetCount += 1
            #endif
        }

        // Advance the settled boundary over any newly-complete blocks in the
        // unsettled region, parsing each settled block exactly once.
        let settledIndex = text.index(text.startIndex, offsetBy: streamSettledLen)
        var unsettled = text[settledIndex...]

        let advance = advanceSettledBoundary(in: unsettled, inCode: streamInCode, mathSeen: streamMathSeen)
        if advance.settledCount > 0 {
            let boundary = unsettled.index(unsettled.startIndex, offsetBy: advance.settledCount)
            let newlySettled = String(unsettled[..<boundary])
            streamSettledSegments.append(contentsOf: MessageSegmenter.segments(newlySettled))
            streamSettledLen += advance.settledCount
            streamInCode = advance.inCode
            streamMathSeen = advance.mathSeen
            unsettled = unsettled[boundary...]
        }

        let tail = String(unsettled)
        let tailSegments = MessageSegmenter.segments(tail)
        var result = streamSettledSegments
        result.append(contentsOf: tailSegments)

        streamPrevText = text
        streamResult = result
        #if DEBUG
        streamingTailParseChars = tail.count
        streamingSettledCount = streamSettledSegments.count
        #endif
        return result
    }

    private static func resetStreaming() {
        streamPrevText = ""
        streamResult = []
        streamSettledSegments = []
        streamSettledLen = 0
        streamInCode = false
        streamMathSeen = false
    }

    /// Scan the complete lines of `unsettled` (the final newline-less line is the
    /// in-progress tail and never settles) and return the number of characters up
    /// to the last render-safe boundary, plus the fold state there. A boundary is
    /// safe at a fenced-code transition (always) or at a blank line while not in
    /// code and no math delimiter has yet appeared.
    private static func advanceSettledBoundary(
        in unsettled: Substring,
        inCode: Bool,
        mathSeen: Bool
    ) -> (settledCount: Int, inCode: Bool, mathSeen: Bool) {
        var localInCode = inCode
        var localMathSeen = mathSeen
        var boundaryCount = 0
        var boundaryInCode = inCode
        var boundaryMathSeen = mathSeen

        var lineStart = unsettled.startIndex
        var consumed = 0            // characters consumed up to `lineStart`
        while let newline = unsettled[lineStart...].firstIndex(of: "\n") {
            let line = unsettled[lineStart..<newline]
            let afterNewline = unsettled.index(after: newline)
            let lineWithBreak = unsettled.distance(from: lineStart, to: afterNewline)

            let hadMath = localMathSeen
            if lineHasMathDelimiter(line) { localMathSeen = true }

            if isFenceLine(line) {
                if localInCode {
                    // Closing fence: the code block completes after this line.
                    localInCode = false
                    boundaryCount = consumed + lineWithBreak
                    boundaryInCode = false
                    boundaryMathSeen = localMathSeen
                } else {
                    // Opening fence: settle the prose up to (not including) it.
                    boundaryCount = consumed
                    boundaryInCode = false
                    boundaryMathSeen = hadMath
                    localInCode = true
                }
            } else if !localInCode,
                      line.trimmingCharacters(in: .whitespaces).isEmpty,
                      !localMathSeen {
                boundaryCount = consumed + lineWithBreak
                boundaryInCode = false
                boundaryMathSeen = false
            }

            consumed += lineWithBreak
            lineStart = afterNewline
        }

        return (boundaryCount, boundaryInCode, boundaryMathSeen)
    }

    /// A fence line, recognised exactly as `MessageSegmenter` does (``` after
    /// optional leading whitespace).
    private static func isFenceLine(_ line: Substring) -> Bool {
        var index = line.startIndex
        while index < line.endIndex, line[index] == " " || line[index] == "\t" {
            index = line.index(after: index)
        }
        return line[index...].hasPrefix("```")
    }

    /// True when the line carries a LaTeX math delimiter opener (`$` or a
    /// backslash escape). Conservative: any such char disables blank-line settling
    /// so a multi-line math region can never be bisected.
    private static func lineHasMathDelimiter(_ line: Substring) -> Bool {
        line.contains("$") || line.contains("\\")
    }

    // MARK: - Bounded store

    /// Insert `value` for `key`, evicting the oldest entries past `limit` (FIFO).
    private static func store<V>(
        _ key: String,
        _ value: V,
        in cache: inout [String: V],
        order: inout [String],
        limit: Int
    ) {
        cache[key] = value
        order.append(key)
        if order.count > limit {
            let overflow = order.count - limit
            for evicted in order.prefix(overflow) {
                cache.removeValue(forKey: evicted)
            }
            order.removeFirst(overflow)
        }
    }

    /// Runtime scroll-indicator flag, available in RELEASE builds (D2).
    ///
    /// The iOS-26 scroll indicator renders as a gradient-stroked capsule; on the
    /// transcript ScrollView and every code block's horizontal ScrollView it
    /// re-rasterizes its gradient stroke per scroll frame (round-2 conic hunt).
    /// Promoting this from the DEBUG-only experiment set to a runtime flag lets a
    /// profiler pass flip it in a release build later WITHOUT shipping a code
    /// change. It is DEFAULT OFF — with `HERMES_EXP_NO_SCROLL_INDICATORS` unset
    /// the app is byte-for-byte visually identical to today (indicators shown).
    ///   HERMES_EXP_NO_SCROLL_INDICATORS=1 → `.scrollIndicators(.hidden)` on the
    ///   transcript + code blocks.
    static let expNoScrollIndicators = ProcessInfo.processInfo.environment["HERMES_EXP_NO_SCROLL_INDICATORS"] == "1"

    #if DEBUG
    /// Round-2 scroll-cost differential experiment flags (DEBUG only). Each is a
    /// launch-env opt-in so a single suspected scroll cost can be stripped and the
    /// hitch-rate delta attributed to it WITHOUT shipping the change:
    ///   HERMES_EXP_NO_TEXTSEL=1  → drop `.textSelection(.enabled)` on chat rows
    ///   HERMES_EXP_NO_MASK=1     → code-block clamp uses `.clipShape` not `.mask`
    /// These are diagnostic scaffolding; the convicted fix is applied directly.
    static let expNoTextSelection = ProcessInfo.processInfo.environment["HERMES_EXP_NO_TEXTSEL"] == "1"
    static let expNoMask = ProcessInfo.processInfo.environment["HERMES_EXP_NO_MASK"] == "1"
    /// Restore the old `.continuous` (squircle) card corners for A/B (default is
    /// now the cheap `.circular` corner that avoids the conic-gradient stroke).
    static let expContinuousCorners = ProcessInfo.processInfo.environment["HERMES_EXP_CONTINUOUS_CORNERS"] == "1"
    /// Opt IN to `.drawingGroup()` rasterization of the code card (A/B the
    /// flatten-to-bitmap approach against the corner-style fix).
    static let expRasterizeCard = ProcessInfo.processInfo.environment["HERMES_EXP_RASTERIZE_CARD"] == "1"
    /// Round-2 ROOT-FINDING (conic-gradient stroke hunt). The Time Profiler put
    /// 84% of the main thread in ONE `PaintShapeLayer.draw` →
    /// `CGContextDrawConicGradient` (`argb32_shade_conic_RGB` → `atan2f`) — a
    /// software per-pixel angular-gradient stroke re-rasterized every frame. No
    /// AngularGradient exists in app source, so the owner is a SYSTEM surface: the
    /// iOS-26 `.glassEffect(.regular.interactive())` specular rim (an angular
    /// sweep around the pill/card silhouette) is the prime suspect. These flags
    /// strip glass per-surface so the conic cost can be attributed by difference
    /// in a Time Profiler / `sample` run, WITHOUT shipping the strip:
    ///   HERMES_EXP_NO_GLASS=1        → ALL glass surfaces use the solid fallback
    ///   HERMES_EXP_NO_GLASS_INTERACTIVE=1 → glass stays but drops `.interactive()`
    /// `.interactive()` is the cheaper hypothesis (the touch-reactive shimmer is
    /// the angular sweep); the no-glass flag is the upper-bound control.
    static let expNoGlass = ProcessInfo.processInfo.environment["HERMES_EXP_NO_GLASS"] == "1"
    static let expNoGlassInteractive = ProcessInfo.processInfo.environment["HERMES_EXP_NO_GLASS_INTERACTIVE"] == "1"
    /// Conic-stroke hunt, second cut. Glass was ruled OUT (strip → no change). The
    /// sample's owning leaf is `StrokeBorderShapeView` (our `.strokeBorder` of a
    /// RoundedRectangle) rasterized inside a `PaintShapeLayer`. The heavy
    /// transcript renders one CodeBlockView card per assistant row (a stroked +
    /// filled rounded-rect). These flags strip the per-row card chrome to attribute
    /// the conic cost to the code card vs the message bubbles vs row shadows:
    ///   HERMES_EXP_NO_CODECARD_CHROME=1 → code card drops its stroke+bg+divider
    ///   HERMES_EXP_NO_BUBBLE_BG=1       → user/assistant bubble backgrounds off
    ///   HERMES_EXP_NO_ROW_SHADOW=1      → strip any per-row drop shadow
    static let expNoCodeCardChrome = ProcessInfo.processInfo.environment["HERMES_EXP_NO_CODECARD_CHROME"] == "1"
    static let expNoBubbleBg = ProcessInfo.processInfo.environment["HERMES_EXP_NO_BUBBLE_BG"] == "1"
    static let expNoRowShadow = ProcessInfo.processInfo.environment["HERMES_EXP_NO_ROW_SHADOW"] == "1"
    /// Test/diagnostic hook: drop all cached entries.
    static func resetForTesting() {
        segmentCache.removeAll(); segmentOrder.removeAll()
        proseCache.removeAll(); proseOrder.removeAll()
        markdownBlockCache.removeAll(); markdownBlockOrder.removeAll()
        highlightCache.removeAll(); highlightOrder.removeAll()
        resetStreaming()
        streamingTailParseChars = 0
        streamingResetCount = 0
        streamingSettledCount = 0
    }
    #endif
}

extension View {
    /// `.textSelection(.enabled)`, optionally stripped under the DEBUG
    /// `HERMES_EXP_NO_TEXTSEL` experiment to measure its scroll-compositing cost.
    @ViewBuilder
    func perfTextSelection() -> some View {
        #if DEBUG
        if RenderCache.expNoTextSelection {
            self
        } else {
            self.textSelection(.enabled)
        }
        #else
        self.textSelection(.enabled)
        #endif
    }

    /// The code-block clamp clip. Defaults to a rounded `.clipShape` (a cheap
    /// rectangular-path clip). Under DEBUG `HERMES_EXP_NO_MASK` it falls through
    /// to the legacy `.mask(RoundedRectangle)` so the offscreen-mask cost can be
    /// measured by difference. `.clipShape` is the shipped behaviour.
    @ViewBuilder
    func perfClampClip() -> some View {
        #if DEBUG
        if RenderCache.expNoMask {
            self.mask(RoundedRectangle(cornerRadius: 12, style: .circular).padding(.top, 0))
        } else {
            self.clipShape(RoundedRectangle(cornerRadius: 12, style: .circular))
        }
        #else
        self.clipShape(RoundedRectangle(cornerRadius: 12, style: .circular))
        #endif
    }

    /// Runtime conic-hunt flag (D2): optionally hide scroll indicators on a
    /// ScrollView to measure the iOS-26 gradient-stroked indicator's per-frame
    /// render cost. Available in release builds; DEFAULT OFF, so with the env var
    /// unset this is a no-op and the indicators render exactly as today.
    @ViewBuilder
    func perfScrollIndicators() -> some View {
        if RenderCache.expNoScrollIndicators {
            self.scrollIndicators(.hidden)
        } else {
            self
        }
    }

    /// DEBUG A/B: optionally `.drawingGroup()`-rasterize the code card so its
    /// rounded-rect stroke is flattened to a cached bitmap and never re-rasterized
    /// per scroll frame. Ships OFF (the corner-style fix is the chosen path).
    @ViewBuilder
    func perfRasterizeCard() -> some View {
        #if DEBUG
        if RenderCache.expRasterizeCard {
            self.drawingGroup()
        } else {
            self
        }
        #else
        self
        #endif
    }
}
