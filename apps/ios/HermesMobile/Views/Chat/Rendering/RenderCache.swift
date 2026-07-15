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
    /// Conic-stroke hunt, third cut. The render leaf is a `Stroke<StrokeablePath>`
    /// filled with a SwiftUI-internal angular/radial gradient (`RadialGradient
    /// ._Paint` → `_setAngularGradientCenter`) — NO such gradient exists in app
    /// source, so it is SYSTEM-DRAWN. iOS 26 renders the SCROLL INDICATOR as a
    /// gradient-stroked capsule; the transcript ScrollView + every code block's
    /// horizontal ScrollView show indicators, each re-rasterizing its gradient
    /// stroke per scroll frame. This flag hides scroll indicators to attribute it:
    ///   HERMES_EXP_NO_SCROLL_INDICATORS=1 → `.scrollIndicators(.hidden)` on the
    ///   transcript + code blocks; conic collapse confirms the indicator is the hog.
    static let expNoScrollIndicators = ProcessInfo.processInfo.environment["HERMES_EXP_NO_SCROLL_INDICATORS"] == "1"

    /// Test/diagnostic hook: drop all cached entries.
    static func resetForTesting() {
        segmentCache.removeAll(); segmentOrder.removeAll()
        proseCache.removeAll(); proseOrder.removeAll()
        markdownBlockCache.removeAll(); markdownBlockOrder.removeAll()
        highlightCache.removeAll(); highlightOrder.removeAll()
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

    /// DEBUG conic-hunt: optionally hide scroll indicators on a ScrollView to
    /// measure the iOS-26 gradient-stroked indicator's per-frame render cost.
    @ViewBuilder
    func perfScrollIndicators() -> some View {
        #if DEBUG
        if RenderCache.expNoScrollIndicators {
            self.scrollIndicators(.hidden)
        } else {
            self
        }
        #else
        self
        #endif
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
