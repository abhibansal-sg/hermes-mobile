import SwiftUI

/// An `image` item (docs/RELAY-PHONE-PROTOCOL.md §2) — a first-class inline image
/// (generated image, attachment, or a markdown image the relay promoted to an
/// item). Inline first-class images are a GAP in today's app; this is the
/// relay-path renderer that closes it.
///
/// A remote URL loads through `AsyncImage`; an inline `data:` URL decodes through
/// the shared `AttachmentBlobCache` decoder (the same one the generated-image
/// tool card and the prose-image lightbox use); anything else (e.g. a
/// server-local path that needs an authenticated gateway read) renders as a
/// labelled reference chip rather than a broken image. Tapping a loaded image
/// opens the shared `ZoomableImageView` lightbox.
struct ImageItemView: ChatItemContentView {
    let item: ChatItem

    @Environment(\.hermesTheme) private var theme
    @State private var presentZoom = false
    @State private var remoteRetryID = UUID()

    init(item: ChatItem) {
        self.item = item
    }

    private var source: ItemImageSource? {
        item.imageReference.map(ItemImageSource.init(reference:))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            content
            if let alt = item.imageAlt, !alt.isEmpty {
                Text(alt)
                    .font(.caption2)
                    .foregroundStyle(theme.mutedFg)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(theme.muted, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("imageItemCard")
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "photo")
                .font(.caption2)
                .foregroundStyle(theme.mutedFg)
            Text(item.summary ?? "Image")
                .font(.caption.weight(.medium))
                .foregroundStyle(theme.mutedFg)
                .lineLimit(1)
            Spacer(minLength: 0)
            if item.status == .inProgress {
                ProgressView().controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch source {
        case .remote(let url):
            remoteImage(url)
        case .dataURL(let value):
            if let decoded = AttachmentBlobCache.decodeDataURLSynchronously(value)?.image {
                tappableImage(Image(uiImage: decoded))
            } else {
                unavailable("Couldn't decode this image.")
            }
        case .opaque(let reference):
            referenceChip(reference)
        case nil:
            unavailable("No image was provided.")
        }
    }

    private func remoteImage(_ url: URL) -> some View {
        AsyncImage(url: url, transaction: Transaction(animation: .snappy(duration: 0.2))) { phase in
            switch phase {
            case .empty:
                loadingPlaceholder
            case .success(let image):
                tappableImage(image)
            case .failure:
                unavailable("Couldn't load this image.")
            @unknown default:
                unavailable("Couldn't load this image.")
            }
        }
        .id(remoteRetryID)
    }

    private func tappableImage(_ image: Image) -> some View {
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
        .accessibilityLabel(item.imageAlt ?? item.summary ?? "Image")
        .accessibilityHint("Double-tap to zoom")
        .accessibilityIdentifier("imageItemImage")
        .fullScreenCover(isPresented: $presentZoom) {
            zoomLightbox
        }
    }

    @ViewBuilder
    private var zoomLightbox: some View {
        let title = item.imageAlt ?? item.summary ?? "Image"
        switch source {
        case .remote(let url):
            ZoomableImageView(title: title, remoteURL: url)
        case .dataURL(let value):
            ZoomableImageView(title: title, dataURL: value)
        default:
            ZoomableImageView(title: title)
        }
    }

    private var loadingPlaceholder: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(theme.bg.opacity(0.5))
            .overlay {
                ProgressView().controlSize(.small)
            }
            .frame(maxWidth: 360, minHeight: 160)
            .accessibilityLabel("Loading image")
    }

    /// A locator we can't render inline (server-local path etc.): show the name
    /// with a photo glyph so the item is honest about what it references.
    private func referenceChip(_ reference: String) -> some View {
        let name = reference.components(separatedBy: "/").last.flatMap { $0.isEmpty ? nil : $0 } ?? reference
        return HStack(spacing: 8) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.body)
                .foregroundStyle(theme.mutedFg)
            Text(name)
                .font(.caption.monospaced())
                .foregroundStyle(theme.fg)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .padding(.vertical, 10)
        .frame(maxWidth: 360, alignment: .leading)
    }

    private func unavailable(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(theme.statusError)
            if case .remote = source {
                Button("Retry") { remoteRetryID = UUID() }
                    .font(.caption.weight(.medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.midground)
            }
        }
        .frame(maxWidth: 360, alignment: .leading)
    }
}

#if DEBUG
#Preview("Image item") {
    VStack(alignment: .leading, spacing: 12) {
        ImageItemView(item: ChatItem(
            itemID: "i1", type: .image, status: .completed, ord: 0,
            summary: "Generated diagram",
            body: ["url": "https://example.com/diagram.png", "alt": "A flow diagram"]
        ))
        ImageItemView(item: ChatItem(
            itemID: "i2", type: .image, status: .completed, ord: 1,
            summary: "Screenshot",
            body: ["path": "~/.hermes/uploads/shot.png"]
        ))
    }
    .padding()
}
#endif
