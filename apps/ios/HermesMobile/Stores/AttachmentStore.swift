import SwiftUI
import UIKit

/// Owns the composer's pending image attachments and drives the two-step
/// upload → attach flow (`POST /api/upload` then the `image.attach` RPC).
///
/// Any picked image — including HEIC from the photo picker, which the gateway
/// rejects — is normalised to JPEG (≤ 0.85 quality, longest side ≤ 2048px) the
/// moment it is added, so everything held here is already upload-ready. The
/// back-reference to ChatStore is wired once via ``attach(chat:)`` (mirroring
/// the other stores' `attach` pattern); the resulting cycle is intentional.
@MainActor
@Observable
final class AttachmentStore {
    /// A single image queued for the next prompt.
    struct PendingAttachment: Identifiable {
        enum State: Equatable {
            case ready
            case uploading
            case failed(String)
        }

        let id = UUID()
        /// A small preview for the composer strip (may be nil if decode failed,
        /// though `add(data:)` rejects images it can't decode).
        var thumbnail: UIImage?
        /// Normalised JPEG bytes ready for `POST /api/upload`.
        let jpegData: Data
        var state: State = .ready
    }

    /// Images queued for the next `prompt.submit`, in pick order.
    private(set) var pending: [PendingAttachment] = []

    /// Longest-edge cap applied during normalisation.
    private static let maxDimension: CGFloat = 2048
    /// JPEG compression quality for normalised attachments.
    private static let jpegQuality: CGFloat = 0.85

    init() {}

    /// True when there is at least one attachment to send.
    var hasPending: Bool { !pending.isEmpty }

    // MARK: - Attachment image-blob cache (P4 cache-on-access)
    //
    // The OUTBOUND composer flow above is unchanged. These helpers make
    // AttachmentStore the single coordination surface for the on-disk
    // attachment image-blob cache (`AttachmentBlobCache`), so any caller that
    // views/downloads an attachment image — primarily `FileViewerView` — can
    // read-then-fetch-then-cache through one place, scoped per (server, profile)
    // consistently with the session/transcript scoping key. Cache-on-access by
    // construction: nothing here pre-fetches; `cache(_:scope:)` is only called
    // AFTER an image has actually been viewed/downloaded and decoded.

    /// Return a previously cached attachment image for this scope+file, or `nil`
    /// on a miss (the caller then fetches over the network — today's path,
    /// unchanged). A `nil`/empty `serverId` bypasses the cache entirely.
    func cachedImage(
        serverId: String,
        profileId: String,
        sessionId: String,
        path: String,
        size: Int
    ) -> UIImage? {
        guard let key = Self.blobKey(serverId: serverId, profileId: profileId,
                                     sessionId: sessionId, path: path, size: size)
        else { return nil }
        return AttachmentBlobCache.shared.image(for: key)
    }

    /// Persist freshly-viewed/downloaded attachment image bytes to the on-disk
    /// blob cache. No-op when the scope is incomplete. Fire-and-forget.
    func cache(
        _ data: Data,
        serverId: String,
        profileId: String,
        sessionId: String,
        path: String,
        size: Int
    ) {
        guard let key = Self.blobKey(serverId: serverId, profileId: profileId,
                                     sessionId: sessionId, path: path, size: size)
        else { return }
        AttachmentBlobCache.shared.store(data, for: key)
    }

    /// Build the composite blob-cache key, or `nil` when `serverId` is blank
    /// (scope incomplete → cache bypassed, behaviour byte-identical to today).
    private static func blobKey(
        serverId: String,
        profileId: String,
        sessionId: String,
        path: String,
        size: Int
    ) -> AttachmentBlobCache.Key? {
        let trimmedServer = serverId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedServer.isEmpty else { return nil }
        return AttachmentBlobCache.Key(
            serverId: trimmedServer,
            profileId: profileId,
            sessionId: sessionId,
            path: path,
            size: size
        )
    }

    // MARK: - Mutation

    /// Normalise arbitrary input image data to an upload-ready JPEG and queue it.
    ///
    /// Handles HEIC/PNG/etc. transparently by round-tripping through `UIImage`:
    /// the result is always baseline JPEG (the only-with-a-handful-of-others
    /// format the server accepts), downscaled so the longest side is ≤ 2048px.
    /// Returns silently if the data can't be decoded as an image.
    @discardableResult
    func add(data: Data) -> Bool {
        guard let image = UIImage(data: data) else { return false }
        let normalised = Self.downscaled(image, maxDimension: Self.maxDimension)
        guard let jpeg = normalised.jpegData(compressionQuality: Self.jpegQuality) else {
            return false
        }
        pending.append(PendingAttachment(thumbnail: normalised, jpegData: jpeg))
        return true
    }

    /// Remove a single queued attachment.
    func remove(id: UUID) {
        pending.removeAll { $0.id == id }
    }

    /// Drop every queued attachment (after a successful send, or a discard).
    func removeAll() {
        pending.removeAll()
    }

    // MARK: - Upload + attach

    /// Upload every pending attachment, bind it to the session, and return the
    /// server-local upload paths that were attached in send order.
    ///
    /// For each pending image: `rest.upload` → `image.attach {session_id, path}`.
    /// A successfully attached image is removed from `pending` as it completes,
    /// so a retry after a mid-batch failure only re-sends what's left. Throws
    /// with a readable message on the first failure (the offending attachment is
    /// marked `.failed` and kept).
    @discardableResult
    func uploadAndAttach(sessionId: String, connection: ConnectionStore) async throws -> [String] {
        guard let rest = connection.rest else {
            throw AttachmentError.notConfigured
        }
        let client = connection.client
        var attachedPaths: [String] = []

        // Snapshot ids up front; `pending` mutates as items succeed.
        let ids = pending.map(\.id)
        for id in ids {
            guard let index = pending.firstIndex(where: { $0.id == id }) else { continue }
            let jpeg = pending[index].jpegData
            pending[index].state = .uploading

            do {
                let upload = try await rest.upload(
                    data: jpeg,
                    filename: "\(UUID().uuidString).jpg",
                    mimeType: "image/jpeg"
                )
                _ = try await client.requestRaw(
                    "image.attach",
                    params: .object([
                        "session_id": .string(sessionId),
                        "path": .string(upload.path),
                    ]),
                    timeout: .seconds(30)
                )
                attachedPaths.append(upload.path)
                // Success: drop it so a partial-batch retry doesn't double-attach.
                pending.removeAll { $0.id == id }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                if let failIndex = pending.firstIndex(where: { $0.id == id }) {
                    pending[failIndex].state = .failed(message)
                }
                throw AttachmentError.failed(message)
            }
        }
        return attachedPaths
    }

    // MARK: - Image normalisation

    /// Return `image` scaled so its longest side is `maxDimension`, or the image
    /// unchanged when it already fits. Redraws at scale 1 so `jpegData` reflects
    /// pixel dimensions, not points.
    private static func downscaled(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxDimension, longest > 0 else {
            // Still re-render to flatten orientation/format into a plain bitmap.
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

/// Failures surfaced by ``AttachmentStore``.
enum AttachmentError: Error, LocalizedError, Sendable {
    case notConfigured
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Not connected — can't upload attachments."
        case .failed(let message):
            return "Attachment failed: \(message)"
        }
    }
}
