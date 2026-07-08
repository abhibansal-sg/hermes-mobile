import SwiftUI
import UIKit
import WebKit

/// A fenced code block rendered as a rounded card: a header with the language
/// badge and a copy button, then horizontally-scrollable, syntax-highlighted,
/// monospaced code. Tall blocks are clamped to a max height with an
/// expand/collapse toggle so a long file never swallows the transcript.
///
/// Visual idiom matches the surrounding chat document: the container paints
/// `theme.codeBg`, chrome reads in `theme.mutedFg`, the brand accent is reserved
/// for nothing here (the card stays neutral so code reads cleanly), and
/// `textSelection` is enabled.
///
/// Rich fences (`mermaid`, `svg`) are routed by `RichFenceDecision` to a
/// bounded diagram card instead of the syntax-highlighted code card. Mermaid
/// diagrams are rendered by the real local mermaid.js library inside a
/// no-network WKWebView (`MermaidWebViewRenderer`); SVG is sanitized before
/// render. Any failure falls back to the source-preserving code card below.
struct CodeBlockView: View {
    /// The detected language hint (info string after the opening fence), or nil.
    let language: String?
    /// The raw code body (no fences).
    let code: String

    /// Collapsed code height cap, in points. Blocks taller than this show the
    /// expand affordance.
    private static let maxCollapsedHeight: CGFloat = 400

    /// ARCH37 STEP 5 — FIRST-PAINT-STABLE HEIGHT. A conservative line-height used to
    /// ESTIMATE the natural height from the code's line count BEFORE the
    /// GeometryReader measures it, so the clamp decision is correct on the FIRST
    /// layout pass (no full-height-then-shrink). The monospaced body renders at
    /// `.body` with vertical padding (10pt top + 10pt bottom); ~18pt per line is a
    /// safe-but-tight per-line height at the default Dynamic Type size. Using a
    /// per-line height that is at/above the real line height makes the estimate an
    /// UPPER bound on the natural content height, so a block tall enough to clamp is
    /// caught on the first pass; a block comfortably under the cap is never
    /// mis-clamped (and even a near-boundary false positive cannot SHRINK content
    /// already under the cap — `.frame(maxHeight:)` only caps, never expands).
    private static let estimatedLineHeight: CGFloat = 18
    /// Vertical chrome around the code text inside the scroll view (10pt top + 10pt
    /// bottom padding), added to the line estimate for the natural-height guess.
    private static let codeBodyVerticalPadding: CGFloat = 20

    @Environment(\.hermesTheme) private var theme

    @State private var isExpanded = false
    @State private var didCopy = false
    @State private var measuredHeight: CGFloat = 0

    var body: some View {
        switch RichFenceDecision.make(language: language, code: code) {
        case .code:
            codeCard
        case .mermaid(let diagram):
            MermaidDiagramCard(language: language, code: code, diagram: diagram) {
                codeCard
            }
        case .svg(let sanitized):
            SVGDiagramCard(language: language, code: code, sanitizedSVG: sanitized) {
                codeCard
            }
        }
    }

    private var codeCard: some View {
        #if DEBUG
        if RenderCache.expNoCodeCardChrome {
            // Conic-stroke hunt: strip ALL card chrome (bg fill + border stroke +
            // divider) to attribute the per-frame conic-gradient cost.
            return AnyView(VStack(alignment: .leading, spacing: 0) {
                header
                codeBody
            })
        }
        #endif
        return AnyView(VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(theme.border)
            codeBody
        }
        .background(theme.codeBg, in: cardShape)
        .overlay(
            cardShape
                .strokeBorder(theme.border, lineWidth: 1)
        )
        .perfRasterizeCard())
    }

    /// The card's rounded-rect shape. The corner STYLE is the round-2 scroll
    /// forensics lever: SwiftUI's default `RoundedRectangle(cornerRadius:)` uses
    /// `.continuous` (squircle) corners, whose stroke antialiasing RenderBox
    /// rasterizes via a per-pixel CONIC-GRADIENT coverage pass (`atan2f` per
    /// pixel). That pass dominated the main thread during scroll. `.circular`
    /// corners rasterize as cheap arcs. Default = circular; DEBUG
    /// `HERMES_EXP_CONTINUOUS_CORNERS=1` restores the old continuous look for A/B.
    private var cardShape: RoundedRectangle {
        #if DEBUG
        if RenderCache.expContinuousCorners {
            return RoundedRectangle(cornerRadius: 12, style: .continuous)
        }
        #endif
        return RoundedRectangle(cornerRadius: 12, style: .circular)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            languageBadge

            Spacer(minLength: 0)

            if isClampable {
                Button {
                    withAnimation(.snappy(duration: 0.22)) { isExpanded.toggle() }
                } label: {
                    Label(
                        isExpanded ? "Collapse" : "Expand",
                        systemImage: isExpanded ? "chevron.up" : "chevron.down"
                    )
                    .labelStyle(.iconOnly)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.mutedFg)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Collapse code" : "Expand code")
            }

            copyButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var languageBadge: some View {
        Text(badgeLabel)
            .font(.caption2.monospaced().weight(.semibold))
            .foregroundStyle(theme.mutedFg)
            .textCase(.uppercase)
    }

    private var badgeLabel: String {
        if let language, !language.isEmpty { return language }
        return "code"
    }

    private var copyButton: some View {
        Button {
            copy()
        } label: {
            Label(
                didCopy ? "Copied" : "Copy",
                systemImage: didCopy ? "checkmark" : "doc.on.doc"
            )
            .labelStyle(.iconOnly)
            .font(.caption.weight(.semibold))
            .foregroundStyle(didCopy ? theme.statusOK : theme.mutedFg)
            .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(didCopy ? "Copied to clipboard" : "Copy code")
    }

    // MARK: - Body

    private var codeBody: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Text(highlighted)
                .perfTextSelection()
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .fixedSize(horizontal: true, vertical: true)
                .background(
                    // Measure the natural (uncapped) height once so we know
                    // whether the clamp is doing anything.
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: CodeHeightKey.self,
                            value: proxy.size.height
                        )
                    }
                )
        }
        .perfScrollIndicators()
        .frame(maxHeight: heightCap, alignment: .top)
        .perfClampClip()
        .onPreferenceChange(CodeHeightKey.self) { height in
            // Only publish a meaningfully-changed height. The measured natural
            // height is stable once laid out; re-publishing the same value on
            // every layout pass invalidated the view needlessly during scroll.
            if abs(height - measuredHeight) > 0.5 { measuredHeight = height }
        }
        .overlay(alignment: .bottom) {
            if isClampable && !isExpanded {
                fadeFooter
            }
        }
    }

    /// A gradient hint that there is more code below when collapsed. Fades into
    /// the code container's own background (`codeBg`) so the scrim reads on any
    /// theme — a `systemBackground` scrim would render light over dark themes.
    private var fadeFooter: some View {
        LinearGradient(
            colors: [theme.codeBg.opacity(0), theme.codeBg],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 24)
        .allowsHitTesting(false)
    }

    // MARK: - Derived

    /// The syntax-highlighted attributed code. ANSI-bearing output is rendered
    /// via the ANSI path; everything else goes through the highlighter.
    private var highlighted: AttributedString {
        if code.contains("\u{1B}") {
            return AnsiText.stripOrRender(code, baseColor: theme.fg)
        }
        // Memoized highlight (RenderCache): `highlighted` is a computed property
        // re-evaluated on every body pass, so a flick-scroll re-realizing this
        // code block previously re-ran the full regex highlight from scratch.
        // The cache keys on (code, language, baseColor) so a re-render of
        // unchanged code is an O(1) lookup; a theme change yields a new key.
        return RenderCache.highlight(code, language: language, baseColor: theme.fg)
    }

    /// A conservative UPPER-bound estimate of the code's natural rendered height,
    /// from its line count — available BEFORE the GeometryReader measures, so the
    /// first layout pass can already clamp a tall block (ARCH37 Step 5). Counts
    /// newlines + 1 for the final line; a long single line that soft-wraps only
    /// makes the REAL height larger, so this stays a lower bound on the line count
    /// but the per-line height is set at/above the real line height — net, for a
    /// block whose line count alone exceeds the cap, the estimate reliably crosses
    /// the clamp threshold on first paint, which is the case that produced the shrink.
    private var estimatedNaturalHeight: CGFloat {
        let lineCount = code.reduce(into: 1) { count, ch in if ch == "\n" { count += 1 } }
        return CGFloat(lineCount) * Self.estimatedLineHeight + Self.codeBodyVerticalPadding
    }

    /// The best-known natural height: the MEASURED value once it has landed
    /// (authoritative), else the line-count ESTIMATE. So the clamp decision is
    /// stable from the FIRST layout pass and only ever refines toward the truth —
    /// it never flips from "full height" to "clamped" a pass later (the shrink).
    private var effectiveNaturalHeight: CGFloat {
        measuredHeight > 0 ? measuredHeight : estimatedNaturalHeight
    }

    /// True when the natural height exceeds the cap (so the toggle is useful).
    private var isClampable: Bool {
        effectiveNaturalHeight > Self.maxCollapsedHeight + 1
    }

    private var heightCap: CGFloat? {
        guard isClampable, !isExpanded else { return nil }
        return Self.maxCollapsedHeight
    }

    // MARK: - Actions

    private func copy() {
        // Copy clean source: strip ANSI so the clipboard never carries control
        // codes, but keep the original code otherwise verbatim.
        UIPasteboard.general.string = AnsiText.strip(code)
        // Haptic confirmation — light impact mirrors the system share-sheet
        // copy action and gives immediate tactile closure.
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.snappy) { didCopy = true }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.snappy) { didCopy = false }
        }
    }
}

/// Preference key carrying the measured natural height of the code text.
private struct CodeHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Rich fence routing

/// Pure, testable routing of a fenced code block to a render mode. This is the
/// seam unit-tested without a live WKWebView: it decides WHICH renderer a fence
/// selects. `mermaid`/`svg` route rich; everything else stays the code card.
enum RichFenceDecision: Equatable {
    case code
    case mermaid(MermaidDiagram)
    case svg(SanitizedSVG)

    static func make(language: String?, code: String) -> RichFenceDecision {
        switch normalizedLanguage(language) {
        case "mermaid":
            guard let diagram = MermaidDiagram.parse(code) else { return .code }
            return .mermaid(diagram)
        case "svg":
            guard let sanitized = SVGSanitizer.sanitize(code) else { return .code }
            return .svg(sanitized)
        default:
            return .code
        }
    }

    private static func normalizedLanguage(_ language: String?) -> String {
        guard let token = language?.split(whereSeparator: \.isWhitespace).first else { return "" }
        return token.lowercased()
    }
}

// MARK: - Mermaid model

/// Parsed representation of a `mermaid` fence. The `layout` case is the
/// testable decision seam that proves non-flowchart Mermaid selects the REAL
/// renderer (`.webRenderer`, the local mermaid.js WKWebView path) rather than a
/// source-only preview. `graph`/`flowchart` keep the lightweight native canvas;
/// every other supported family (sequenceDiagram, classDiagram, stateDiagram,
/// erDiagram, gantt, pie, …) routes to `.webRenderer`.
///
/// NOTE: `.sourcePreview` was the rejected STR-1078 approach (it showed raw DSL
/// as the "diagram"). It is intentionally absent here — valid non-flowchart
/// Mermaid must render a real diagram via `.webRenderer`, never source text.
struct MermaidDiagram: Equatable {
    /// Testable render-mode seam. `.flowchart` = native SwiftUI canvas;
    /// `.webRenderer` = real local mermaid.js render inside a no-network
    /// WKWebView. There is deliberately no source-preview case.
    enum Layout: Equatable {
        case flowchart
        case webRenderer
    }

    struct Node: Identifiable, Equatable {
        let id: String
        let label: String
    }

    struct Edge: Identifiable, Equatable {
        let id: String
        let from: String
        let to: String
        let label: String?
    }

    let layout: Layout
    let direction: Direction
    let nodes: [Node]
    let edges: [Edge]
    /// Verbatim DSL, carried so the web renderer can draw it and the copy
    /// button/fallback can always reproduce the original source.
    let source: String

    enum Direction: Equatable {
        case topDown
        case leftRight
    }

    static func parse(_ source: String) -> MermaidDiagram? {
        let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = source
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("%%") }

        guard let header = lines.first?.lowercased(),
              isSupportedHeader(header) else {
            return nil
        }

        // graph/flowchart keep the lightweight native canvas. Every other
        // supported family routes to the real local mermaid.js web renderer.
        guard header.hasPrefix("graph ") || header.hasPrefix("flowchart ") else {
            guard lines.count > 1 else { return nil }
            return MermaidDiagram(
                layout: .webRenderer,
                direction: .topDown,
                nodes: [],
                edges: [],
                source: trimmedSource
            )
        }

        let direction: Direction = header.contains(" lr") || header.hasSuffix("lr") ? .leftRight : .topDown
        var nodeByID: [String: Node] = [:]
        var order: [String] = []
        var edges: [Edge] = []

        for line in lines.dropFirst() {
            guard let edge = parseEdge(line) else { continue }
            for node in [edge.from, edge.to] where nodeByID[node.id] == nil {
                nodeByID[node.id] = node
                order.append(node.id)
            }
            edges.append(Edge(id: "\(edge.from.id)->\(edge.to.id)-\(edges.count)", from: edge.from.id, to: edge.to.id, label: edge.label))
        }

        guard !order.isEmpty, !edges.isEmpty else { return nil }
        return MermaidDiagram(
            layout: .flowchart,
            direction: direction,
            nodes: order.compactMap { nodeByID[$0] },
            edges: edges,
            source: trimmedSource
        )
    }

    private static func isSupportedHeader(_ header: String) -> Bool {
        if header.hasPrefix("graph ") || header.hasPrefix("flowchart ") {
            return true
        }

        let headerToken = header
            .split(whereSeparator: \.isWhitespace)
            .first
            .map(String.init) ?? header
        let tokenHeaders: Set<String> = [
            "sequencediagram",
            "classdiagram",
            "classdiagram-v2",
            "statediagram",
            "statediagram-v2",
            "erdiagram",
            "journey",
            "gantt",
            "pie",
            "quadrantchart",
            "requirementdiagram",
            "gitgraph",
            "mindmap",
            "timeline",
            "sankey-beta",
            "xychart-beta",
            "block-beta",
            "packet-beta",
            "architecture-beta",
            "radar-beta",
            "treemap-beta"
        ]
        if tokenHeaders.contains(headerToken) {
            return true
        }

        return headerToken.hasPrefix("c4context")
            || headerToken.hasPrefix("c4container")
            || headerToken.hasPrefix("c4component")
            || headerToken.hasPrefix("c4dynamic")
            || headerToken.hasPrefix("zenuml")
    }

    private static func parseEdge(_ line: String) -> (from: Node, to: Node, label: String?)? {
        let patterns = ["-->", "---", "-.->", "==>"]
        guard let marker = patterns.first(where: { line.contains($0) }),
              let range = line.range(of: marker) else {
            return nil
        }
        let lhs = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        let rhsAndLabel = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard let from = parseNode(lhs) else { return nil }

        var rhs = rhsAndLabel
        var label: String?
        if rhs.hasPrefix("|"), let end = rhs.dropFirst().firstIndex(of: "|") {
            label = String(rhs[rhs.index(after: rhs.startIndex)..<end]).trimmingCharacters(in: .whitespaces)
            rhs = String(rhs[rhs.index(after: end)...]).trimmingCharacters(in: .whitespaces)
        }
        guard let to = parseNode(rhs) else { return nil }
        return (from, to, label?.isEmpty == true ? nil : label)
    }

    private static func parseNode(_ token: String) -> Node? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let open = trimmed.firstIndex(where: { "[({".contains($0) }),
           let close = matchingCloseIndex(in: trimmed, open: open) {
            let id = String(trimmed[..<open]).trimmingCharacters(in: .whitespaces)
            let label = String(trimmed[trimmed.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
            guard isSafeIdentifier(id), !label.isEmpty else { return nil }
            return Node(id: id, label: label)
        }

        guard isSafeIdentifier(trimmed) else { return nil }
        return Node(id: trimmed, label: trimmed)
    }

    private static func matchingCloseIndex(in text: String, open: String.Index) -> String.Index? {
        let close: Character
        switch text[open] {
        case "[": close = "]"
        case "(": close = ")"
        case "{": close = "}"
        default: return nil
        }
        return text[open...].firstIndex(of: close)
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        return value.range(of: #"^[A-Za-z0-9_:-]+$"#, options: .regularExpression) != nil
    }
}

// MARK: - SVG sanitizer (untrusted model output)

struct SanitizedSVG: Equatable {
    let markup: String
}

/// Deterministic, WebKit-free SVG sanitizer. Treats all model output as
/// untrusted and rejects (falls back to the code card) anything carrying
/// scripts, event handlers, external/resource references, or malformed markup.
enum SVGSanitizer {
    static func sanitize(_ source: String) -> SanitizedSVG? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: #"(?is)^<svg\b"#, options: .regularExpression) != nil,
              trimmed.range(of: #"(?is)</svg>\s*$"#, options: .regularExpression) != nil,
              XMLWellFormedness.isWellFormed(trimmed),
              !containsBlockedSVGContent(trimmed) else {
            return nil
        }
        return SanitizedSVG(markup: trimmed)
    }

    private static func containsBlockedSVGContent(_ markup: String) -> Bool {
        let blockedPatterns = [
            // Script / foreign content / loaders that can execute or fetch.
            #"(?is)<\s*(script|foreignObject|iframe|object|embed|link|style|image|use)\b"#,
            // Inline event handlers (onclick, onload, on-anything).
            #"(?is)\s(on[a-zA-Z0-9_-]+)\s*="#,
            // Dangerous reference schemes (javascript:/data:/remote/file).
            #"(?is)\b(href|xlink:href|src)\s*=\s*['"]?\s*(javascript:|data:|https?:|//|file:)"#,
            // CSS-borne external fetches (url() / @import).
            #"(?is)\b(url\(|@import)"#
        ]
        return blockedPatterns.contains { pattern in
            markup.range(of: pattern, options: .regularExpression) != nil
        }
    }
}

private final class XMLWellFormedness: NSObject, XMLParserDelegate {
    private var didFail = false

    static func isWellFormed(_ source: String) -> Bool {
        guard let data = source.data(using: .utf8) else { return false }
        let delegate = XMLWellFormedness()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        return parser.parse() && !delegate.didFail
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        didFail = true
    }
}

// MARK: - Bundled mermaid.js asset

/// Loads the vendored mermaid.js library (`mermaid.min.js`) from the app bundle.
/// The asset is bundled locally so render-time NEVER needs the network — the
/// WKWebView loads it as an inline script with `baseURL: nil` and a CSP that
/// blocks every external fetch. A missing/unreadable asset makes the mermaid
/// renderer report failure so the card falls back to the source code card.
/// Loads the vendored mermaid.js library (`mermaid.min.js`) from the app bundle.
/// The asset is bundled locally so render-time NEVER needs the network — the
/// WKWebView loads it as an inline script with `baseURL: nil` and a CSP that
/// blocks every external fetch. A missing/unreadable asset makes the mermaid
/// renderer report failure so the card falls back to the source code card.
///
/// `static let` evaluates the file read exactly once, lazily, and thread-safely
/// (Swift dispatch_once semantics) — so the 2.5MB asset is read on first render
/// and never re-read, with no mutable shared state.
enum MermaidAsset {
    static let library: String? = {
        guard let url = Bundle.main.url(forResource: "mermaid", withExtension: "min.js"),
              let data = try? Data(contentsOf: url),
              let source = String(data: data, encoding: .utf8),
              !source.isEmpty else {
            return nil
        }
        return source
    }()
}

// MARK: - Mermaid diagram card

/// Non-generic metric holder: Swift forbids static stored properties on a
/// generic type, so the card's bounds live here and the generic card reads them.
private enum MermaidCardMetrics {
    static let defaultHeight: CGFloat = 280
    static let maxHeight: CGFloat = 460
}

private struct MermaidDiagramCard<Fallback: View>: View {
    let language: String?
    let code: String
    let diagram: MermaidDiagram
    let fallback: Fallback

    @Environment(\.hermesTheme) private var theme
    /// Live content height reported by the web renderer; clamped to `maxHeight`.
    @State private var renderHeight: CGFloat = MermaidCardMetrics.defaultHeight
    /// Flips to true on any render/asset failure → swap to the code-card fallback.
    @State private var renderFailed = false

    init(language: String?, code: String, diagram: MermaidDiagram, @ViewBuilder fallback: () -> Fallback) {
        self.language = language
        self.code = code
        self.diagram = diagram
        self.fallback = fallback()
    }

    var body: some View {
        Group {
            if renderFailed {
                fallback
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    richHeader(label: language ?? "mermaid", code: code)
                    Divider().overlay(theme.border)
                    ScrollView([.horizontal, .vertical], showsIndicators: true) {
                        Group {
                            switch diagram.layout {
                            case .flowchart:
                                MermaidDiagramCanvas(diagram: diagram)
                                    .padding(16)
                            case .webRenderer:
                                MermaidWebViewRenderer(
                                    source: diagram.source,
                                    contentHeight: $renderHeight,
                                    didFail: $renderFailed
                                )
                                .frame(height: min(renderHeight, MermaidCardMetrics.maxHeight))
                                .frame(maxWidth: .infinity)
                            }
                        }
                    }
                    .frame(maxHeight: MermaidCardMetrics.maxHeight)
                    .background(theme.codeBg)
                }
                .background(theme.codeBg, in: RoundedRectangle(cornerRadius: 12, style: .circular))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .circular).strokeBorder(theme.border, lineWidth: 1))
                .perfRasterizeCard()
            }
        }
    }
}

private struct MermaidDiagramCanvas: View {
    let diagram: MermaidDiagram

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        let columns = diagram.direction == .leftRight ? Array(repeating: GridItem(.fixed(150), spacing: 28), count: diagram.nodes.count) : [GridItem(.fixed(180), spacing: 16)]

        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
            ForEach(diagram.nodes) { node in
                VStack(spacing: 6) {
                    Text(node.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.fg)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .minimumScaleFactor(0.8)
                        .frame(width: 130)
                        .frame(minHeight: 44)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(theme.bg, in: RoundedRectangle(cornerRadius: 8, style: .circular))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .circular).strokeBorder(theme.border, lineWidth: 1))

                    ForEach(diagram.edges.filter { $0.from == node.id }) { edge in
                        HStack(spacing: 4) {
                            Image(systemName: diagram.direction == .leftRight ? "arrow.right" : "arrow.down")
                            if let label = edge.label {
                                Text(label).lineLimit(1)
                            }
                        }
                        .font(.caption2.monospaced())
                        .foregroundStyle(theme.mutedFg)
                    }
                }
            }
        }
        .frame(minWidth: diagram.direction == .leftRight ? CGFloat(max(diagram.nodes.count, 1)) * 178 : 220, alignment: .leading)
    }
}

// MARK: - Mermaid local web renderer (no-network WKWebView)

/// Renders a Mermaid diagram with the real, locally-bundled mermaid.js inside a
/// hardened WKWebView. Security model:
/// - **No network.** `loadHTMLString(_:baseURL: nil)` + a CSP of
///   `default-src 'none'` (only inline script/style for the bundled renderer)
///   means there is nothing to fetch against and no base URL to resolve.
/// - **No navigation.** The navigation delegate cancels every navigation except
///   the initial `about:blank` document load.
/// - **Non-persistent.** `websiteDataStore = .nonPersistent()` so nothing is
///   written to disk.
/// - **Strict mermaid.** `securityLevel: 'strict'` disables click handlers and
///   HTML in labels; `suppressErrorRendering` keeps parse failures from
///   injecting error art.
/// On any failure (missing asset, parse error, timeout) `didFail` flips and the
/// parent card swaps to the source-preserving code card.
private struct MermaidWebViewRenderer: UIViewRepresentable {
    let source: String
    @Binding var contentHeight: CGFloat
    @Binding var didFail: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let userContentController = WKUserContentController()
        userContentController.add(context.coordinator, name: Coordinator.bridgeName)
        configuration.userContentController = userContentController
        configuration.preferences.javaScriptEnabled = true
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.scrollView.maximumZoomScale = 4
        view.scrollView.minimumZoomScale = 1
        context.coordinator.bindings = (height: $contentHeight, didFail: $didFail)
        return view
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.bindings = (height: $contentHeight, didFail: $didFail)
        // Re-render only when the source actually changes — a scroll-driven
        // SwiftUI re-evaluation must not reload (and re-parse) the same diagram.
        guard context.coordinator.lastSource != source else { return }
        context.coordinator.lastSource = source
        context.coordinator.render(html: html(), in: webView)
    }

    private func html() -> String {
        guard let library = MermaidAsset.library else {
            return MermaidWebViewRenderer.errorDocument()
        }
        let sourceArray = MermaidWebViewRenderer.jsonArrayLiteral(for: source)
        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval'; style-src 'unsafe-inline'; img-src data:; font-src 'none'; connect-src 'none'; media-src 'none'; frame-src 'none'; object-src 'none';">
          <style>
            html, body { margin: 0; padding: 0; background: transparent; }
            #mtarget { padding: 12px; }
            #mtarget svg { display: block; max-width: 100%; height: auto; }
          </style>
        </head>
        <body>
          <div id="mtarget"></div>
          <script>\(library)</script>
          <script>
          (function () {
            var SRC = \(sourceArray);
            var raw = (SRC && SRC[0]) ? SRC[0] : "";
            var bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(Coordinator.bridgeName);
            var done = false;
            function report(o) { if (done) return; done = true; try { if (bridge) bridge.postMessage(JSON.stringify(o)); } catch (e) {} }
            // Backstop: never leave the card hanging if the promise never settles.
            setTimeout(function () { report({ ok: false }); }, 8000);
            try {
              if (typeof mermaid === "undefined" || !mermaid || typeof mermaid.initialize !== "function" || typeof mermaid.render !== "function") {
                report({ ok: false }); return;
              }
              mermaid.initialize({
                startOnLoad: false,
                securityLevel: "strict",
                theme: "default",
                suppressErrorRendering: true,
                flowchart: { useMaxWidth: true, htmlLabels: false },
                sequence: { useMaxWidth: true },
                gantt: { useMaxWidth: true }
              });
              var id = "m_" + Date.now() + "_" + Math.floor(Math.random() * 1e6);
              Promise.resolve(mermaid.render(id, raw)).then(function (out) {
                var target = document.getElementById("mtarget");
                target.innerHTML = (out && out.svg) ? out.svg : "";
                requestAnimationFrame(function () {
                  var h = Math.ceil((document.body.scrollHeight || document.documentElement.scrollHeight) || 0);
                  report({ ok: true, height: h });
                });
              }).catch(function () { report({ ok: false }); });
            } catch (e) { report({ ok: false }); }
          })();
          </script>
        </body>
        </html>
        """
    }

    private static func errorDocument() -> String {
        "<script>(function(){var b=window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers."
        + Coordinator.bridgeName
        + ";try{if(b)b.postMessage(JSON.stringify({ok:false}));}catch(e){}})();</script>"
    }

    /// Encodes `source` as a JSON array literal that is also a valid JS
    /// expression, then neutralises every `<` so a `</script>` substring in the
    /// model output cannot break out of the inline script element. `\u003c`
    /// decodes back to `<` inside a JS string, so the mermaid DSL is preserved.
    private static func jsonArrayLiteral(for source: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [source], options: [])) ?? Data("[\"\"]".utf8)
        var literal = String(data: data, encoding: .utf8) ?? "[\"\"]"
        literal = literal.replacingOccurrences(of: "<", with: "\\u003c")
        return literal
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let bridgeName = "mermaidBridge"

        var bindings: (height: Binding<CGFloat>, didFail: Binding<Bool>)?
        var lastSource: String?
        private var resolved = false

        func render(html: String, in webView: WKWebView) {
            resolved = false
            webView.loadHTMLString(html, baseURL: nil)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !resolved else { return }
            guard let body = message.body as? String,
                  let data = body.data(using: .utf8),
                  let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                fail()
                return
            }
            resolved = true
            let ok = (result["ok"] as? Bool) ?? false
            if ok, let height = (result["height"] as? Double) ?? (result["height"] as? Int).map(Double.init) {
                let clamped = CGFloat(max(80, min(height, 560)))
                DispatchQueue.main.async { self.bindings?.height.wrappedValue = clamped }
            } else {
                DispatchQueue.main.async { self.bindings?.didFail.wrappedValue = true }
            }
        }

        private func fail() {
            resolved = true
            DispatchQueue.main.async { self.bindings?.didFail.wrappedValue = true }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // Allow only the initial about:blank document load (the inline
            // HTML string). Every other navigation (file/http/data/…) is
            // cancelled — there is no legitimate off-document navigation.
            if navigationAction.navigationType == .other,
               let scheme = navigationAction.request.url?.scheme?.lowercased(),
               scheme == "about" {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }
    }
}

// MARK: - SVG diagram card

private struct SVGDiagramCard<Fallback: View>: View {
    let language: String?
    let code: String
    let sanitizedSVG: SanitizedSVG
    let fallback: Fallback

    @Environment(\.hermesTheme) private var theme

    init(language: String?, code: String, sanitizedSVG: SanitizedSVG, @ViewBuilder fallback: () -> Fallback) {
        self.language = language
        self.code = code
        self.sanitizedSVG = sanitizedSVG
        self.fallback = fallback()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            richHeader(label: language ?? "svg", code: code)
            Divider().overlay(theme.border)
            SVGWebView(markup: sanitizedSVG.markup)
                .frame(height: 320)
                .background(theme.codeBg)
        }
        .background(theme.codeBg, in: RoundedRectangle(cornerRadius: 12, style: .circular))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .circular).strokeBorder(theme.border, lineWidth: 1))
        .perfRasterizeCard()
    }
}

private func richHeader(label: String, code: String) -> some View {
    RichFenceHeader(label: label, code: code)
}

private struct RichFenceHeader: View {
    let label: String
    let code: String

    @Environment(\.hermesTheme) private var theme
    @State private var didCopy = false

    var body: some View {
        HStack(spacing: 8) {
            Text(label.isEmpty ? "diagram" : label)
                .font(.caption2.monospaced().weight(.semibold))
                .foregroundStyle(theme.mutedFg)
                .textCase(.uppercase)

            Spacer(minLength: 0)

            Button {
                UIPasteboard.general.string = AnsiText.strip(code)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.snappy) { didCopy = true }
                Task {
                    try? await Task.sleep(for: .seconds(1.6))
                    withAnimation(.snappy) { didCopy = false }
                }
            } label: {
                Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                    .labelStyle(.iconOnly)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(didCopy ? theme.statusOK : theme.mutedFg)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(didCopy ? "Copied to clipboard" : "Copy diagram source")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

private struct SVGWebView: UIViewRepresentable {
    let markup: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptEnabled = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.maximumZoomScale = 4
        view.scrollView.minimumZoomScale = 1
        return view
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let html = """
        <!doctype html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src 'none'; media-src 'none'; font-src 'none'; connect-src 'none'; script-src 'none'; style-src 'unsafe-inline';">
          <style>
            html, body { margin: 0; padding: 0; background: transparent; overflow: auto; }
            svg { display: block; max-width: 100%; height: auto; }
          </style>
        </head>
        <body>\(markup)</body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .other && navigationAction.request.url?.scheme == "about" {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }
    }
}
