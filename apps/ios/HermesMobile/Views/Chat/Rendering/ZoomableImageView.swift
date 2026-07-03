import SwiftUI
import UIKit

/// Full-screen image viewer with pinch-to-zoom, drag-to-pan, and a visible
/// dismiss affordance. The view is source-agnostic so any image surface can
/// reuse it without copying gesture math.
struct ZoomableImageView: View {
    let title: String
    let image: UIImage?
    let remoteURL: URL?
    let dataURL: String?
    let unavailableMessage: String

    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = ZoomableImageMetrics.minimumScale
    @State private var lastScale: CGFloat = ZoomableImageMetrics.minimumScale
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var remoteRetryID = UUID()
    @State private var dataRetryID = UUID()

    init(
        title: String,
        image: UIImage? = nil,
        remoteURL: URL? = nil,
        dataURL: String? = nil,
        unavailableMessage: String = "This image couldn't be loaded."
    ) {
        self.title = title
        self.image = image
        self.remoteURL = remoteURL
        self.dataURL = dataURL
        self.unavailableMessage = unavailableMessage
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.ignoresSafeArea()
                content(containerSize: proxy.size)
                chrome
            }
        }
        .statusBarHidden(true)
        .accessibilityIdentifier("zoomableImageView")
    }

    @ViewBuilder
    private func content(containerSize: CGSize) -> some View {
        if let image {
            zoomableImage(Image(uiImage: image), imageSize: image.size, containerSize: containerSize)
                .accessibilityLabel(title)
        } else if let dataURL {
            dataURLContent(dataURL, containerSize: containerSize)
                .id(dataRetryID)
        } else if let remoteURL {
            remoteContent(remoteURL, containerSize: containerSize)
                .id(remoteRetryID)
        } else {
            failureState(message: unavailableMessage, retry: { dataRetryID = UUID() })
        }
    }

    @ViewBuilder
    private func remoteContent(_ url: URL, containerSize: CGSize) -> some View {
        AsyncImage(url: url, transaction: Transaction(animation: .snappy(duration: 0.2))) { phase in
            switch phase {
            case .empty:
                loadingState
            case .success(let loadedImage):
                // AsyncImage does not expose the decoded pixel size. Use the
                // container as the fit basis so panning still clamps honestly.
                zoomableImage(loadedImage, imageSize: containerSize, containerSize: containerSize)
                    .accessibilityLabel(title)
            case .failure:
                failureState(message: "Couldn't load this image.", retry: { remoteRetryID = UUID() })
            @unknown default:
                failureState(message: "Couldn't load this image.", retry: { remoteRetryID = UUID() })
            }
        }
    }

    @ViewBuilder
    private func dataURLContent(_ value: String, containerSize: CGSize) -> some View {
        if let decoded = Self.decodeDataURL(value) {
            zoomableImage(Image(uiImage: decoded), imageSize: decoded.size, containerSize: containerSize)
                .accessibilityLabel(title)
        } else {
            failureState(message: "Couldn't decode this image.", retry: { dataRetryID = UUID() })
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(.white)
                .controlSize(.large)
            Text("Loading image…")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.82))
        }
        .accessibilityLabel("Loading image")
    }

    private func failureState(message: String, retry: @escaping () -> Void) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(.white.opacity(0.76))
            Text("Image unavailable")
                .font(.headline)
                .foregroundStyle(.white)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            HStack(spacing: 12) {
                Button("Retry", action: retry)
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(.black)
                Button("Close") { dismiss() }
                    .buttonStyle(.bordered)
                    .tint(.white)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("zoomableImageErrorState")
    }

    private func zoomableImage(_ image: Image, imageSize: CGSize, containerSize: CGSize) -> some View {
        let clampedOffset = ZoomableImageMetrics.clampedOffset(
            offset,
            imageSize: imageSize,
            boundsSize: containerSize,
            scale: scale
        )

        return image
            .resizable()
            .scaledToFit()
            .frame(maxWidth: containerSize.width, maxHeight: containerSize.height)
            .scaleEffect(scale)
            .offset(clampedOffset)
            .animation(.snappy(duration: 0.18), value: scale)
            .animation(.snappy(duration: 0.18), value: clampedOffset)
            .gesture(
                dragGesture(imageSize: imageSize, containerSize: containerSize)
                    .simultaneously(with: magnificationGesture(imageSize: imageSize, containerSize: containerSize))
            )
            .onTapGesture(count: 2) { toggleDoubleTapZoom() }
            .accessibilityHint("Pinch to zoom, drag to pan, or double-tap to zoom or reset")
    }

    private func magnificationGesture(imageSize: CGSize, containerSize: CGSize) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let nextScale = ZoomableImageMetrics.clampedScale(lastScale * value)
                scale = nextScale
                offset = ZoomableImageMetrics.clampedOffset(
                    offset,
                    imageSize: imageSize,
                    boundsSize: containerSize,
                    scale: nextScale
                )
            }
            .onEnded { value in
                let nextScale = ZoomableImageMetrics.clampedScale(lastScale * value)
                scale = nextScale
                lastScale = nextScale
                offset = ZoomableImageMetrics.clampedOffset(
                    offset,
                    imageSize: imageSize,
                    boundsSize: containerSize,
                    scale: nextScale
                )
                lastOffset = offset
            }
    }

    private func dragGesture(imageSize: CGSize, containerSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard scale > ZoomableImageMetrics.minimumScale else {
                    // At rest, a downward drag previews the swipe-to-dismiss path.
                    offset = CGSize(width: value.translation.width * 0.18,
                                    height: max(0, value.translation.height))
                    return
                }
                let proposed = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
                offset = ZoomableImageMetrics.clampedOffset(
                    proposed,
                    imageSize: imageSize,
                    boundsSize: containerSize,
                    scale: scale
                )
            }
            .onEnded { value in
                if ZoomableImageMetrics.shouldDismissAtRest(
                    scale: scale,
                    translation: value.translation
                ) {
                    dismiss()
                    return
                }

                let proposed = scale <= ZoomableImageMetrics.minimumScale
                    ? .zero
                    : CGSize(width: lastOffset.width + value.translation.width,
                             height: lastOffset.height + value.translation.height)
                offset = ZoomableImageMetrics.clampedOffset(
                    proposed,
                    imageSize: imageSize,
                    boundsSize: containerSize,
                    scale: scale
                )
                lastOffset = offset
            }
    }

    private var chrome: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 12)
                Button {
                    dismiss()
                } label: {
                    Label("Close", systemImage: "xmark")
                        .labelStyle(.titleAndIcon)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.white.opacity(0.16), in: Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .accessibilityIdentifier("zoomableImageCloseButton")
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 12)
            .background(
                LinearGradient(
                    colors: [.black.opacity(0.78), .black.opacity(0.0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea(edges: .top)
            )

            Spacer(minLength: 0)

            Text("Pinch to zoom • double-tap zoom/reset • swipe down to close")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.black.opacity(0.42), in: Capsule())
                .padding(.bottom, 24)
        }
    }

    private func resetZoom() {
        scale = ZoomableImageMetrics.minimumScale
        lastScale = ZoomableImageMetrics.minimumScale
        offset = .zero
        lastOffset = .zero
    }

    private func toggleDoubleTapZoom() {
        let nextScale = ZoomableImageMetrics.doubleTapScale(after: scale)
        scale = nextScale
        lastScale = nextScale
        offset = .zero
        lastOffset = .zero
    }

    static func decodeDataURL(_ value: String) -> UIImage? {
        guard value.hasPrefix("data:"),
              let comma = value.firstIndex(of: ",") else { return nil }
        let header = value[..<comma]
        guard header.contains(";base64") else { return nil }
        let payload = String(value[value.index(after: comma)...])
        guard let data = Data(base64Encoded: payload, options: [.ignoreUnknownCharacters]) else { return nil }
        return UIImage(data: data)
    }
}

/// Pure geometry helpers used by ``ZoomableImageView`` and unit tests.
enum ZoomableImageMetrics {
    static let minimumScale: CGFloat = 1.0
    static let doubleTapScale: CGFloat = 2.5
    static let maximumScale: CGFloat = 6.0
    private static let minimumScaleTolerance: CGFloat = 0.01
    private static let dismissVerticalThreshold: CGFloat = 120
    private static let dismissHorizontalLimit: CGFloat = 120

    static func clampedScale(_ scale: CGFloat) -> CGFloat {
        min(max(scale, minimumScale), maximumScale)
    }

    static func doubleTapScale(after currentScale: CGFloat) -> CGFloat {
        isAtMinimumScale(currentScale) ? doubleTapScale : minimumScale
    }

    static func shouldDismissAtRest(scale: CGFloat, translation: CGSize) -> Bool {
        isAtMinimumScale(scale)
            && translation.height > dismissVerticalThreshold
            && abs(translation.width) < dismissHorizontalLimit
    }

    private static func isAtMinimumScale(_ scale: CGFloat) -> Bool {
        scale <= minimumScale + minimumScaleTolerance
    }

    static func fittedSize(imageSize: CGSize, in boundsSize: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0,
              boundsSize.width > 0, boundsSize.height > 0 else { return .zero }
        let ratio = min(boundsSize.width / imageSize.width, boundsSize.height / imageSize.height)
        return CGSize(width: imageSize.width * ratio, height: imageSize.height * ratio)
    }

    static func maximumOffset(imageSize: CGSize, boundsSize: CGSize, scale: CGFloat) -> CGSize {
        let fitted = fittedSize(imageSize: imageSize, in: boundsSize)
        let scaled = CGSize(width: fitted.width * clampedScale(scale), height: fitted.height * clampedScale(scale))
        return CGSize(
            width: max(0, (scaled.width - boundsSize.width) / 2),
            height: max(0, (scaled.height - boundsSize.height) / 2)
        )
    }

    static func clampedOffset(
        _ offset: CGSize,
        imageSize: CGSize,
        boundsSize: CGSize,
        scale: CGFloat
    ) -> CGSize {
        let maxOffset = maximumOffset(imageSize: imageSize, boundsSize: boundsSize, scale: scale)
        return CGSize(
            width: min(max(offset.width, -maxOffset.width), maxOffset.width),
            height: min(max(offset.height, -maxOffset.height), maxOffset.height)
        )
    }
}
