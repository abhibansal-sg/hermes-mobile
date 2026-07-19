import SwiftUI
import UIKit
import UniformTypeIdentifiers

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
        contentVersion: String?
    ) async -> UIImage? {
        guard let key = Self.blobKey(serverId: serverId, profileId: profileId,
                                     sessionId: sessionId, path: path,
                                     contentVersion: contentVersion)
        else { return nil }
        return await AttachmentBlobCache.shared.image(for: key)
    }

    /// Persist freshly-viewed/downloaded attachment image bytes to the on-disk
    /// blob cache. No-op when the scope is incomplete. Fire-and-forget.
    func cache(
        _ data: Data,
        serverId: String,
        profileId: String,
        sessionId: String,
        path: String,
        contentVersion: String?
    ) async {
        guard let key = Self.blobKey(serverId: serverId, profileId: profileId,
                                     sessionId: sessionId, path: path,
                                     contentVersion: contentVersion)
        else { return }
        await AttachmentBlobCache.shared.store(data, for: key)
    }

    /// Build the composite blob-cache key, or `nil` when `serverId` is blank
    /// (scope incomplete → cache bypassed, behaviour byte-identical to today).
    private static func blobKey(
        serverId: String,
        profileId: String,
        sessionId: String,
        path: String,
        contentVersion: String?
    ) -> AttachmentBlobCache.Key? {
        let trimmedServer = serverId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedServer.isEmpty,
              let version = contentVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
              !version.isEmpty else { return nil }
        return AttachmentBlobCache.Key(
            serverId: trimmedServer,
            profileId: profileId,
            sessionId: sessionId,
            path: path,
            contentVersion: version
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

    func draftAssetInputs() -> [WorkAssetInput] {
        pending.map { WorkAssetInput(data: $0.jpegData, mimeType: "image/jpeg", fileExtension: "jpg") }
    }

    // MARK: - Non-image file attachments (W25 files-phase-1)
    //
    // Images ride the multipart `POST /api/upload` → `image.attach` path above,
    // which the gateway restricts to a small image-extension whitelist. Arbitrary
    // files (PDF, CSV, source, archives, …) are 415'd by that route, so they take
    // the gateway's `file.attach` RPC instead: the bytes are base64-inlined as a
    // `data:<mime>;base64,…` payload, the gateway materialises the file inside the
    // session workspace, and it returns a workspace-relative `@file:` reference
    // that the composer appends to the prompt (the same ref surface the file
    // browser's "@" button and `agent.context_references` already use). No image
    // decode, no re-encode — the original bytes round-trip untouched.

    /// Server-side cap mirrored from the gateway upload/attach bridge (25 MB).
    /// Enforced client-side so an oversized pick fails fast with a clear message
    /// instead of a round-trip that ends in a 413.
    static let maxFileAttachmentBytes = 25 * 1024 * 1024

    /// Human-readable form of ``maxFileAttachmentBytes`` (e.g. "25 MB") for
    /// oversize error messages. Shared by the pre-read size guard (ComposerView)
    /// and the post-read ``validateFileAttachment`` check so both report the same
    /// cap.
    nonisolated static var maxFileAttachmentCapDescription: String {
        ByteCountFormatter.string(fromByteCount: Int64(maxFileAttachmentBytes), countStyle: .file)
    }

    /// Outcome of a successful ``attachFile(data:filename:sessionId:connection:)``.
    struct FileAttachResult: Sendable, Equatable {
        /// Filename the gateway stored the attachment under (may be de-duplicated).
        let name: String
        /// Absolute path of the materialised file on the gateway.
        let path: String
        /// Workspace-relative ref path (no `@file:` prefix / quoting).
        let refPath: String
        /// Ready-to-insert composer token, e.g. `@file:report.pdf` (already quoted
        /// by the gateway when the path needs it).
        let refText: String
    }

    /// Best-effort MIME type for a picked file, inferred from its extension via
    /// `UTType`. Falls back to `application/octet-stream` for unknown/extension-
    /// less names — the gateway's `file.attach` accepts any media type, so an
    /// imperfect guess never blocks the upload; it only labels the data URL.
    static func detectedMimeType(forFilename filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        guard !ext.isEmpty,
              let type = UTType(filenameExtension: ext),
              let mime = type.preferredMIMEType else {
            return "application/octet-stream"
        }
        return mime
    }

    /// Build a `data:<mime>;base64,<payload>` URL for `data`. The gateway's
    /// `file.attach` decoder tolerates any media type here (unlike the image-only
    /// `image.attach_bytes` path).
    nonisolated static func fileDataURL(_ data: Data, mimeType: String) -> String {
        "data:\(mimeType);base64,\(data.base64EncodedString())"
    }

    /// Read a picked file's bytes for attachment, enforcing ``maxFileAttachmentBytes``
    /// BEFORE the read so an over-cap pick (a `.fileImporter` accepting `.item` can
    /// hand back a multi-GB video/archive) is rejected off the fast path without ever
    /// loading it into memory — the earlier post-read cap could hang the UI and OOM
    /// the app first. Acquires the URL's security scope for the read only.
    ///
    /// `nonisolated` so the composer runs it off the main actor via `Task.detached`;
    /// returns a ready-to-display message (not an `AttachmentError`, whose prefix
    /// would double up) on an over-cap file or unreadable path.
    nonisolated static func readPickedFileData(at url: URL) -> Result<Data, String> {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > maxFileAttachmentBytes {
            return .failure("File is too large (max \(maxFileAttachmentCapDescription)).")
        }
        do {
            // Fully resident read (NOT .mappedIfSafe): the size guard above bounds
            // this to <= 25 MB, and the mapped variant would fault pages lazily
            // after the security scope is released on return — risking SIGBUS when
            // the bytes are base64-encoded later.
            return .success(try Data(contentsOf: url))
        } catch {
            return .failure("Couldn't read \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Validate a freshly-picked non-image file before any network work: reject
    /// an empty read and anything over ``maxFileAttachmentBytes``. Pure + sync so
    /// it is unit-testable without a live connection. Returns the resolved MIME
    /// type on success.
    static func validateFileAttachment(data: Data, filename: String) throws -> String {
        guard !data.isEmpty else {
            throw AttachmentError.failed("The file is empty.")
        }
        guard data.count <= maxFileAttachmentBytes else {
            throw AttachmentError.failed("File is too large (max \(maxFileAttachmentCapDescription)).")
        }
        return detectedMimeType(forFilename: filename)
    }

    /// Upload one arbitrary (non-image) file to the active session via the
    /// gateway `file.attach` RPC and return the `@file:` reference the composer
    /// should append to the outgoing prompt. Throws ``AttachmentError`` on an
    /// empty/oversized file, a missing connection, or an RPC failure.
    ///
    /// Unlike the image path this does NOT queue anything in ``pending``: the file
    /// is materialised on the gateway immediately and represented purely by its
    /// `@file:` ref in the composer text, exactly like a browsed-file mention.
    @discardableResult
    func attachFile(
        data: Data,
        filename: String,
        sessionId: String,
        connection: ConnectionStore
    ) async throws -> FileAttachResult {
        let mime = try Self.validateFileAttachment(data: data, filename: filename)
        let trimmedSession = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSession.isEmpty else {
            throw AttachmentError.notConfigured
        }
        let client = connection.client
        // Base64-encode off the main actor: for a file at the 25 MB cap this is a
        // multi-MB string build that would otherwise block the UI on @MainActor.
        let dataURL = await Task.detached(priority: .userInitiated) {
            Self.fileDataURL(data, mimeType: mime)
        }.value
        let result: JSONValue
        do {
            result = try await client.requestRaw(
                "file.attach",
                params: .object([
                    "session_id": .string(trimmedSession),
                    "name": .string(filename),
                    "data_url": .string(dataURL),
                ]),
                timeout: .seconds(60)
            )
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            throw AttachmentError.failed(message)
        }
        guard let refText = result["ref_text"]?.stringValue, !refText.isEmpty else {
            throw AttachmentError.failed("The gateway did not return a file reference.")
        }
        return FileAttachResult(
            name: result["name"]?.stringValue ?? filename,
            path: result["path"]?.stringValue ?? "",
            refPath: result["ref_path"]?.stringValue ?? refText,
            refText: refText
        )
    }

    func restoreDraftAssets(_ data: [Data]) {
        pending = data.compactMap { bytes in
            guard let image = UIImage(data: bytes) else { return nil }
            return PendingAttachment(thumbnail: image, jpegData: bytes)
        }
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
