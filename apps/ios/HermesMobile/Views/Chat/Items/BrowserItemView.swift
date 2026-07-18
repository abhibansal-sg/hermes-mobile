import SwiftUI

/// A `browser` item (docs/RELAY-PHONE-PROTOCOL.md §2) — any `browser_*` tool
/// (navigate / snapshot / screenshot), rendered as a card that leads with the
/// page URL and shows the captured screenshot/snapshot when one is present.
///
/// The screenshot reuses the same remote/data-URL classification and the shared
/// `ZoomableImageView` lightbox as `ImageItemView`, so a browser capture zooms
/// like any other image. With no screenshot the card degrades to a labelled URL
/// row — still a first-class, legible browser item, never a bare generic card.
struct BrowserItemView: ChatItemContentView {
    let item: ChatItem

    @Environment(\.hermesTheme) private var theme
    @State private var presentZoom = false
    @State private var remoteRetryID = UUID()

    init(item: ChatItem) {
        self.item = item
    }

    private var screenshot: ItemImageSource? {
        item.browserScreenshot.map(ItemImageSource.init(reference:))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let url = item.browserURL, !url.isEmpty {
                Label(url, systemImage: "link")
                    .font(.caption2.monospaced())
                    .foregroundStyle(theme.mutedFg)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            screenshotView
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(theme.muted, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("browserItemCard")
    }

    private var header: some View {
        HStack(spacing: 6) {
            ChatItemStatusIcon(status: item.status)
                .frame(width: 16, height: 16)
            Image(systemName: "globe")
                .font(.caption2)
                .foregroundStyle(theme.mutedFg)
            Text(item.summary ?? item.toolName)
                .font(.caption.weight(.medium))
                .foregroundStyle(theme.fg)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Browser \(item.summary ?? item.toolName), \(item.statusWord)")
    }

    @ViewBuilder
    private var screenshotView: some View {
        switch screenshot {
        case .remote(let url):
            remoteShot(url)
        case .dataURL(let value):
            if let decoded = AttachmentBlobCache.decodeDataURLSynchronously(value)?.image {
                tappableShot(Image(uiImage: decoded))
            } else {
                EmptyView()
            }
        case .opaque, nil:
            EmptyView()
        }
    }

    private func remoteShot(_ url: URL) -> some View {
        AsyncImage(url: url, transaction: Transaction(animation: .snappy(duration: 0.2))) { phase in
            switch phase {
            case .empty:
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.bg.opacity(0.5))
                    .overlay { ProgressView().controlSize(.small) }
                    .frame(maxWidth: 360, minHeight: 160)
                    .accessibilityLabel("Loading snapshot")
            case .success(let image):
                tappableShot(image)
            case .failure:
                Label("Couldn't load the snapshot.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(theme.statusError)
            @unknown default:
                EmptyView()
            }
        }
        .id(remoteRetryID)
    }

    private func tappableShot(_ image: Image) -> some View {
        Button {
            presentZoom = true
        } label: {
            image
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 360, maxHeight: 420, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.mutedFg.opacity(0.18), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.summary ?? "Browser snapshot")
        .accessibilityHint("Double-tap to zoom")
        .accessibilityIdentifier("browserItemImage")
        .fullScreenCover(isPresented: $presentZoom) {
            let title = item.summary ?? "Browser snapshot"
            switch screenshot {
            case .remote(let url):
                ZoomableImageView(title: title, remoteURL: url)
            case .dataURL(let value):
                ZoomableImageView(title: title, dataURL: value)
            default:
                ZoomableImageView(title: title)
            }
        }
    }
}

#if DEBUG
#Preview("Browser item") {
    VStack(alignment: .leading, spacing: 12) {
        BrowserItemView(item: ChatItem(
            itemID: "b1", type: .browser, status: .completed, ord: 0,
            summary: "Snapshot of example.com",
            body: ["name": "browser_snapshot", "url": "https://example.com",
                   "screenshot": "https://example.com/shot.png"]
        ))
        BrowserItemView(item: ChatItem(
            itemID: "b2", type: .browser, status: .completed, ord: 1,
            summary: "Navigated to docs",
            body: ["name": "browser_navigate", "url": "https://docs.example.com/guide"]
        ))
    }
    .padding()
}
#endif
