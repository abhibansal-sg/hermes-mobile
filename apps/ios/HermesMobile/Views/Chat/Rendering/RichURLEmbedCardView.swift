import SwiftUI
import WebKit

/// Pure sizing/label helpers for ``RichURLEmbedCardView``, split out from the
/// view so they can be unit-tested without hosting SwiftUI.
enum RichURLEmbedLayout {
    /// Fallback aspect ratio for a descriptor that specifies neither
    /// `fixedHeight` nor `aspectRatio`. Not hit by any provider `RichURLEmbedDetector`
    /// currently produces, but keeps `height(for:width:)` total.
    static let fallbackAspectRatio: Double = 16 / 9

    /// The card's rendered width for a given available column width: capped at
    /// the descriptor's `maxWidth`, never wider than what the transcript column
    /// actually offers.
    static func width(for descriptor: RichURLEmbedDescriptor, availableWidth: Double) -> Double {
        min(descriptor.maxWidth, max(availableWidth, 0))
    }

    /// The card's content height for a resolved `width`: a fixed height (Spotify)
    /// wins outright; otherwise the aspect ratio is solved against the actual
    /// rendered width so a narrower column still keeps correct proportions.
    static func height(for descriptor: RichURLEmbedDescriptor, width: Double) -> Double {
        if let fixedHeight = descriptor.fixedHeight { return fixedHeight }
        let aspectRatio = descriptor.aspectRatio ?? fallbackAspectRatio
        guard aspectRatio > 0 else { return width * fallbackAspectRatio }
        return width / aspectRatio
    }

    /// Label for the external-open affordance, both as the header button and as
    /// the load-failed / unsupported fallback card's call to action.
    static func openLabel(for descriptor: RichURLEmbedDescriptor) -> String {
        "Open \(descriptor.label)"
    }
}

/// Reports the card's own rendered width up to `RichURLEmbedCardView` so it
/// can re-solve content height against the real (possibly `maxWidth`-capped)
/// column width rather than a static seed.
private struct RichURLEmbedWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// A reusable rounded card that renders a rich URL embed (YouTube, Spotify,
/// Google Maps, OpenStreetMap) inside a sandboxed `WKWebView`, driven entirely
/// by the provider-agnostic ``RichURLEmbedDescriptor`` from
/// `RichURLEmbedDetector`. Not wired into message parsing by this view — the
/// caller decides when a descriptor exists and hands it in.
///
/// Visual idiom matches ``CodeBlockView``/``MathSegmentView``: a rounded card
/// painted `theme.codeBg` with a `theme.border` stroke, a small chrome header,
/// and content clipped to the same corner radius. If the frame provider fails
/// to load, the card swaps to an external-open affordance pointing at
/// `sourceURL` rather than showing a dead embed.
struct RichURLEmbedCardView: View {
    @Environment(\.hermesTheme) private var theme
    @Environment(\.openURL) private var openURL

    let descriptor: RichURLEmbedDescriptor

    @State private var loadFailed = false
    @State private var measuredWidth: CGFloat?

    private static let cornerRadius: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(theme.border)
            content(width: resolvedWidth, height: resolvedHeight)
                .frame(width: resolvedWidth, height: resolvedHeight)
        }
        .frame(maxWidth: descriptor.maxWidth, alignment: .leading)
        .background(widthProbe)
        .background(theme.codeBg, in: cardShape)
        .overlay(cardShape.strokeBorder(theme.border, lineWidth: 1))
        .id(descriptor.id)
    }

    /// Measures the card's own rendered width — already capped at
    /// `descriptor.maxWidth` by the `.frame(maxWidth:)` above — via a
    /// preference so `resolvedHeight` can solve the aspect ratio against the
    /// width the card actually renders at. Solving height from
    /// `descriptor.maxWidth` unconditionally (instead of the real column
    /// width) left a gap below the `WKWebView` whenever the column was
    /// narrower than `maxWidth`, since the outer container stayed tall while
    /// the content shrank to fit.
    private var widthProbe: some View {
        GeometryReader { proxy in
            Color.clear
                .preference(key: RichURLEmbedWidthPreferenceKey.self, value: proxy.size.width)
        }
        .onPreferenceChange(RichURLEmbedWidthPreferenceKey.self) { newWidth in
            guard newWidth > 0, newWidth != measuredWidth else { return }
            measuredWidth = newWidth
        }
    }

    private var resolvedWidth: CGFloat {
        RichURLEmbedLayout.width(for: descriptor, availableWidth: measuredWidth ?? descriptor.maxWidth)
    }

    private var resolvedHeight: CGFloat {
        RichURLEmbedLayout.height(for: descriptor, width: resolvedWidth)
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .circular)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text(descriptor.label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(theme.mutedFg)
                .lineLimit(1)

            Spacer(minLength: 0)

            openExternallyButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var openExternallyButton: some View {
        Button {
            openURL(descriptor.sourceURL)
        } label: {
            Label("Open", systemImage: "arrow.up.right.square")
                .labelStyle(.iconOnly)
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.mutedFg)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(RichURLEmbedLayout.openLabel(for: descriptor))
    }

    // MARK: - Content

    @ViewBuilder
    private func content(width: Double, height: Double) -> some View {
        if loadFailed {
            fallback(height: height)
        } else {
            RichURLEmbedWebView(url: descriptor.embedURL) {
                loadFailed = true
            }
            .clipShape(
                UnevenRoundedRectangle(
                    bottomLeadingRadius: Self.cornerRadius,
                    bottomTrailingRadius: Self.cornerRadius,
                    style: .circular
                )
            )
        }
    }

    private func fallback(height: Double) -> some View {
        Button {
            openURL(descriptor.sourceURL)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "arrow.up.right.square")
                    .font(.title3)
                Text(RichURLEmbedLayout.openLabel(for: descriptor))
                    .font(.footnote.weight(.medium))
                Text(descriptor.sourceURL.absoluteString)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(theme.mutedFg)
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .foregroundStyle(theme.fg)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(RichURLEmbedLayout.openLabel(for: descriptor))
    }
}

/// Thin `WKWebView` wrapper that loads a single frame-provider URL and reports
/// load failure so the host card can fall back to an external-open affordance.
/// Scrolling/zooming inside the frame is disabled — the web view is a fixed
/// content pane, not a mini-browser.
private struct RichURLEmbedWebView: UIViewRepresentable {
    let url: URL
    let onLoadFailed: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onLoadFailed: onLoadFailed)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard webView.url != url else { return }
        webView.load(URLRequest(url: url))
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onLoadFailed: () -> Void

        init(onLoadFailed: @escaping () -> Void) {
            self.onLoadFailed = onLoadFailed
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onLoadFailed()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onLoadFailed()
        }
    }
}
