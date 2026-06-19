import Foundation

// MARK: - Artifact model

/// One artifact from `GET /api/plugins/hermes-mobile/artifacts` (`results[]`).
///
/// The plugin endpoint scans message transcripts and surfaces three kinds of
/// artifact: images (multimodal content parts), files (tool-call path
/// arguments), and links (http/https URLs from prose). Each row is flat — one
/// artifact per entry — and carries the source session + message so the gallery
/// can open the origin transcript.
///
/// Explicit snake_case `CodingKeys` let us pass `.useDefaultKeys` to the
/// decoder so the global `.convertFromSnakeCase` strategy is not applied
/// (avoiding double-conversion) — the same idiom used by
/// ``PluginSessionSearchResult``.
struct Artifact: Decodable, Identifiable, Sendable, Equatable {
    /// The message that produced this artifact (wire key `message_id`).
    ///
    /// NOT used as the `Identifiable.id` directly — the server can emit multiple
    /// artifacts for the same `message_id` (e.g. several links extracted from one
    /// message, or a message with both an image part and an extracted link in
    /// `type=all`). `ForEach` on a non-unique id silently drops duplicates.
    let messageId: Int
    let sessionId: String
    let sessionTitle: String?
    /// `"image"`, `"file"`, or `"link"`.
    let kind: String
    /// The primary locator: a URL (images/links) or a filesystem path (files).
    let urlOrPath: String
    let filename: String?
    let mimeType: String?
    /// Server-reported byte count for files/images; `nil` for links.
    let size: Int?
    /// For links: the surrounding prose fragment; otherwise `nil`.
    let snippet: String?
    /// Unix-seconds message timestamp.
    let timestamp: Double?

    /// Gallery-position index — assigned by ``ArtifactsGalleryModel`` when a
    /// page lands, NOT decoded from JSON (it is absent from `CodingKeys`).
    ///
    /// Zero by default; always overwritten before the artifact enters
    /// ``ArtifactsGalleryModel/artifacts``.
    var galleryIndex: Int = 0

    /// Positional identity: `gallery_position + ":" + message_id + ":" + url_or_path`.
    ///
    /// Three-part key so that two genuinely-distinct artifacts from the SAME
    /// message with the SAME url (e.g. the same link mentioned twice in one
    /// message, or an image URL reused in two content parts) are not silently
    /// collapsed by SwiftUI's `ForEach` or the cross-page dedupe. The
    /// `galleryIndex` makes every position unique while `messageId:urlOrPath`
    /// still identifies TRUE cross-page duplicates when the indices match (same
    /// page position → same artifact from the same fetch).
    var id: String { "\(galleryIndex):\(messageId):\(urlOrPath)" }

    private enum CodingKeys: String, CodingKey {
        case messageId    = "message_id"
        case sessionId    = "session_id"
        case sessionTitle = "session_title"
        case kind
        case urlOrPath    = "url_or_path"
        case filename
        case mimeType     = "mime"
        case size
        case snippet
        case timestamp
    }

    /// Best display name: filename if present, last path component of the
    /// URL/path, or the raw locator when neither yields a non-empty string.
    var displayName: String {
        if let fn = filename, !fn.isEmpty { return fn }
        let last = urlOrPath.components(separatedBy: "/").last ?? urlOrPath
        return last.isEmpty ? urlOrPath : last
    }

    /// `true` when the locator is an inline data URL (base-64 embedded bytes
    /// from a multimodal attachment). These bypass `AsyncImage` — they're too
    /// large for a thumbnail network call.
    var isDataURL: Bool {
        urlOrPath.hasPrefix("data:")
    }

    /// The URL suitable for `AsyncImage`, or `nil` when the locator is a local
    /// path or data URL (async loading is not meaningful for either).
    var remoteURL: URL? {
        guard !isDataURL,
              urlOrPath.hasPrefix("http://") || urlOrPath.hasPrefix("https://")
        else { return nil }
        return URL(string: urlOrPath)
    }

    /// Build an ``AttachmentBlobCache/Key`` for thumbnail look-up / storage.
    /// Returns `nil` when `serverId` is empty or `size` is absent (links never
    /// carry a size, so they are never cached).
    func blobCacheKey(serverId: String, profileId: String) -> AttachmentBlobCache.Key? {
        let trimmed = serverId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let sz = size else { return nil }
        return AttachmentBlobCache.Key(
            serverId: trimmed,
            profileId: profileId,
            sessionId: sessionId,
            path: urlOrPath,
            size: sz
        )
    }
}

// MARK: - Page envelope

/// The paginated response envelope from the artifacts endpoint.
struct ArtifactPage: Decodable, Sendable {
    let type: String
    let results: [Artifact]
    /// Total matched count BEFORE pagination — a "N found" display counter,
    /// not the page size. v1 fetches a single page (limit ~50) so callers do
    /// not need to read beyond this for paging logic.
    let total: Int
    let offset: Int

    private enum CodingKeys: String, CodingKey {
        case type, results, total, offset
    }
}

// MARK: - Endpoint

extension RestClient {
    /// `GET /api/plugins/hermes-mobile/artifacts?type=&limit=&offset=&q=` —
    /// cross-session artifact gallery (images, files, links).
    ///
    /// `type` selects which kinds to return:
    /// - `"all"`    — all three kinds (default)
    /// - `"images"` — multimodal image / document parts
    /// - `"files"`  — tool-call path arguments
    /// - `"links"`  — http/https URLs extracted from prose
    ///
    /// `q` filters by substring on `url_or_path` / `filename`. `total` in the
    /// response is the full matched count before pagination (not the page size).
    ///
    /// Only available when this client speaks `.plugin` path style. On older
    /// gateways without the plugin the gateway returns 404; callers catch
    /// `RestError.badStatus(404, _)` and degrade gracefully. Real 500 /
    /// transport errors are re-thrown.
    func artifacts(
        type: String = "all",
        limit: Int = 50,
        offset: Int = 0,
        q: String? = nil
    ) async throws -> ArtifactPage {
        guard pathStyle == .plugin else {
            throw RestError.badStatus(404, body: "plugin path style not active")
        }

        var items: [URLQueryItem] = [
            URLQueryItem(name: "type", value: type),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if offset > 0 {
            items.append(URLQueryItem(name: "offset", value: String(offset)))
        }
        if let q {
            let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                items.append(URLQueryItem(name: "q", value: trimmed))
            }
        }
        var components = URLComponents()
        components.queryItems = items
        let encodedQuery = components.percentEncodedQuery ?? ""
        let base = "\(mobileAPIPrefix)/artifacts"
        let path = encodedQuery.isEmpty ? base : "\(base)?\(encodedQuery)"

        let data = try await get(path: path)

        // Artifact uses explicit snake_case CodingKeys — pass .useDefaultKeys so
        // the global .convertFromSnakeCase strategy is not applied (it would
        // double-convert already-camelCase property names).
        return try decode(
            ArtifactPage.self, from: data,
            context: "artifacts", strategy: .useDefaultKeys
        )
    }
}
