import Foundation
import UniformTypeIdentifiers
import UIKit

/// Pulls text, URLs and images out of the `NSExtensionItem`s that the system
/// hands a share extension and packages them into a single
/// ``LoadedShareContent`` value, ready to be queued as a
/// ``SharedStore/SharedInboxItem``.
///
/// All `NSItemProvider` loading is funnelled through `async` wrappers so the
/// `ShareViewController` can `await` a fully resolved payload before showing
/// any UI — no completion-handler soup in the view layer.
///
/// Images are normalised to baseline JPEG here (the only family the Hermes
/// gateway's `/api/upload` accepts, HEIC is rejected), downscaled so the
/// longest side is ≤ 2048px, mirroring the in-app `AttachmentStore` so an
/// image shared from another app is byte-for-byte handled like one picked
/// inside Hermes.
enum SharedItemLoader {

    /// The fully resolved result of walking every attachment of every
    /// extension item. Plain value type so it can cross actor boundaries.
    struct LoadedShareContent: Sendable {
        /// Concatenated plain-text snippets (newline-joined), if any.
        var text: String?
        /// The first shared web URL, as an absolute string, if any.
        var url: String?
        /// Normalised JPEG payloads, in the order encountered, capped at
        /// ``maxImages``.
        var images: [Data]

        var isEmpty: Bool {
            (text?.isEmpty ?? true) && (url?.isEmpty ?? true) && images.isEmpty
        }
    }

    /// Hard cap on attached images, matching the activation rule advertised in
    /// the extension's Info.plist (`NSExtensionActivationSupportsImageWithMaxCount`).
    static let maxImages = 4

    /// Longest-edge cap applied during normalisation (matches `AttachmentStore`).
    private static let maxDimension: CGFloat = 2048
    /// JPEG compression quality for normalised images (matches `AttachmentStore`).
    private static let jpegQuality: CGFloat = 0.85

    // MARK: - Entry point

    /// Resolve every provider across the supplied extension items into one
    /// payload. Never throws: an item that fails to load is simply skipped so
    /// a single bad attachment can't block the whole share.
    ///
    /// `@MainActor`-isolated so the (non-Sendable) `NSExtensionItem`/
    /// `NSItemProvider` values never cross an actor boundary — the caller
    /// (`ShareViewController`) is also `@MainActor`, so under Swift 6 strict
    /// concurrency the array is passed within one isolation region. The actual
    /// provider loads are async (continuation-bridged), so the main actor stays
    /// responsive while attachments resolve.
    @MainActor
    static func load(from extensionItems: [NSExtensionItem]) async -> LoadedShareContent {
        var textParts: [String] = []
        var firstURL: String?
        var images: [Data] = []

        for item in extensionItems {
            for provider in item.attachments ?? [] {
                if images.count >= maxImages,
                   provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    continue
                }

                // Order matters: a provider can advertise multiple types
                // (e.g. a URL that is also loadable as text). Prefer the most
                // specific interpretation, falling through otherwise.
                if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    if let data = await loadImage(provider) {
                        images.append(data)
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    if let url = await loadURL(provider) {
                        // file:// URLs that are actually images are rare here;
                        // treat anything web-like as a URL, otherwise as text.
                        if url.isFileURL {
                            if let data = await loadImageFromFileURL(url),
                               images.count < maxImages {
                                images.append(data)
                            }
                        } else if firstURL == nil {
                            firstURL = url.absoluteString
                        } else {
                            textParts.append(url.absoluteString)
                        }
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
                            || provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
                    if let text = await loadText(provider) {
                        textParts.append(text)
                    }
                }
            }
        }

        let joined = textParts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        return LoadedShareContent(
            text: joined.isEmpty ? nil : joined,
            url: firstURL,
            images: Array(images.prefix(maxImages))
        )
    }

    // MARK: - Per-type provider loaders
    //
    // All `@MainActor`-isolated so the non-Sendable `NSItemProvider`/decoded
    // item values stay in the same isolation region as the `@MainActor` entry
    // point — no value is "sent" across an actor boundary (Swift 6 strict
    // concurrency). The provider loads themselves are continuation-bridged async,
    // so the main actor isn't blocked while attachments resolve.

    @MainActor
    private static func loadText(_ provider: NSItemProvider) async -> String? {
        let typeID: String = provider
            .hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
            ? UTType.plainText.identifier
            : UTType.text.identifier
        let object = await loadItem(provider, typeID: typeID)
        switch object {
        case let string as String:
            return string
        case let data as Data:
            return String(data: data, encoding: .utf8)
        case let attributed as NSAttributedString:
            return attributed.string
        default:
            return nil
        }
    }

    @MainActor
    private static func loadURL(_ provider: NSItemProvider) async -> URL? {
        let object = await loadItem(provider, typeID: UTType.url.identifier)
        switch object {
        case let url as URL:
            return url
        case let string as String:
            return URL(string: string)
        case let data as Data:
            return String(data: data, encoding: .utf8).flatMap(URL.init(string:))
        default:
            return nil
        }
    }

    @MainActor
    private static func loadImage(_ provider: NSItemProvider) async -> Data? {
        let object = await loadItem(provider, typeID: UTType.image.identifier)
        switch object {
        case let image as UIImage:
            return normalisedJPEG(from: image)
        case let url as URL:
            return await loadImageFromFileURL(url)
        case let data as Data:
            return UIImage(data: data).flatMap(normalisedJPEG(from:))
        default:
            return nil
        }
    }

    @MainActor
    private static func loadImageFromFileURL(_ url: URL) async -> Data? {
        guard let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else { return nil }
        return normalisedJPEG(from: image)
    }

    /// Bridge `NSItemProvider`'s completion-handler API into `async`. Uses the
    /// untyped `loadItem` so we accept whatever coerced representation the
    /// provider offers (URL/String/Data/UIImage/NSAttributedString).
    ///
    /// The provider's completion handler runs on an arbitrary queue and delivers
    /// a non-`Sendable` `any NSSecureCoding`. Under Swift 6 strict concurrency,
    /// resuming the (`@MainActor`) continuation with that value crosses an
    /// isolation boundary, so we carry it through a one-shot `@unchecked Sendable`
    /// transfer box. This is sound: the provider produces the value exactly once
    /// and we consume it exactly once on resume — there is no shared mutation.
    @MainActor
    private static func loadItem(
        _ provider: NSItemProvider,
        typeID: String
    ) async -> (any NSSecureCoding)? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeID, options: nil) { item, _ in
                let transfer = UncheckedTransfer(item)
                continuation.resume(returning: transfer.value)
            }
        }
    }

    /// One-shot, single-consumer transfer box for moving a non-`Sendable` value
    /// across an isolation boundary (a legacy completion handler → an `async`
    /// continuation). Safe because the wrapped value is never shared or mutated.
    private struct UncheckedTransfer<Value>: @unchecked Sendable {
        let value: Value
        init(_ value: Value) { self.value = value }
    }

    // MARK: - Image normalisation (mirrors AttachmentStore)

    /// Downscale to a ≤ ``maxDimension`` longest side, flatten orientation, and
    /// encode baseline JPEG. Returns nil if encoding fails.
    static func normalisedJPEG(from image: UIImage) -> Data? {
        let downscaled = self.downscaled(image, maxDimension: maxDimension)
        return downscaled.jpegData(compressionQuality: jpegQuality)
    }

    private static func downscaled(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxDimension, longest > 0 else {
            return redraw(image, size: size)
        }
        let ratio = maxDimension / longest
        let target = CGSize(width: size.width * ratio, height: size.height * ratio)
        return redraw(image, size: target)
    }

    private static func redraw(_ image: UIImage, size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
