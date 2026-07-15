import Foundation

/// Bridges resolved share content into the app-group inbox using the
/// parent-owned ``SharedStore`` conventions. The extension writes; the app's
/// `SharedInboxDrainer` (X3) reads and clears.
///
/// Image bytes are written as individual JPEG files under
/// ``SharedStore/sharedImagesDirectory``; only their *relative* filenames are
/// stored in the `SharedInboxItem.imageFiles` array, exactly as the drainer
/// expects (it resolves them against the same directory).
enum SharedInboxWriter {

    /// Failures the share UI surfaces to the user before bailing out.
    enum WriteError: Error, LocalizedError {
        case appGroupUnavailable

        var errorDescription: String? {
            switch self {
            case .appGroupUnavailable:
                return "Couldn’t reach Hermes’ shared storage. Check the app is installed."
            }
        }
    }

    /// Persist one share into the inbox. Writes any image data to the shared
    /// images directory first, then appends a single `SharedInboxItem`
    /// referencing those files. The whole append is one `UserDefaults` write,
    /// so a half-written item can never be observed by the drainer.
    ///
    /// - Returns: the queued item (its `id` is fresh).
    @discardableResult
    static func queue(
        content: SharedItemLoader.LoadedShareContent,
        comment: String?
    ) throws -> SharedStore.SharedInboxItem {
        guard SharedStore.defaults != nil else {
            throw WriteError.appGroupUnavailable
        }

        let id = UUID()
        let imageFiles = writeImages(content.images, itemID: id)

        let trimmedComment = comment?.trimmingCharacters(in: .whitespacesAndNewlines)

        let item = SharedStore.SharedInboxItem(
            id: id,
            text: content.text,
            url: content.url,
            comment: (trimmedComment?.isEmpty ?? true) ? nil : trimmedComment,
            imageFiles: imageFiles,
            createdAt: Date()
        )

        SharedStore.appendInboxItem(item)
        return item
    }

    /// Write each image to its own file under the shared images directory and
    /// return the relative filenames. Filenames are namespaced by the item id
    /// so two shares queued back-to-back can't collide.
    private static func writeImages(_ images: [Data], itemID: UUID) -> [String] {
        guard !images.isEmpty, let dir = SharedStore.sharedImagesDirectory else {
            return []
        }
        var names: [String] = []
        for (index, data) in images.enumerated() {
            let name = "\(itemID.uuidString)-\(index).jpg"
            let fileURL = dir.appendingPathComponent(name, isDirectory: false)
            do {
                try data.write(to: fileURL, options: .atomic)
                names.append(name)
            } catch {
                // Skip the unwritable image rather than failing the whole share;
                // the text/url payload is still worth queueing.
                continue
            }
        }
        return names
    }
}
