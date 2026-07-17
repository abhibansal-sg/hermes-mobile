import Foundation

extension RestClient {
    /// Fetch one exact schema-v2 manifest page. Continuation cursors are
    /// transient; only a final resume cursor may be persisted by the cache.
    func syncManifest(
        scope: String,
        resumeCursor: String?,
        continuationCursor: String?,
        limit: Int = 500
    ) async throws -> SyncManifestHTTPPage {
        guard pathStyle == .plugin else { throw RestError.badStatus(404, body: "sync manifest unavailable") }
        guard scope == "all" || scope.hasPrefix("profile:pf_"),
              (1...500).contains(limit),
              resumeCursor == nil || continuationCursor == nil else {
            throw RestError.decoding("syncManifestV2: invalid request contract")
        }
        var items = [
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if let resumeCursor, !resumeCursor.isEmpty {
            items.append(URLQueryItem(name: "resume_cursor", value: resumeCursor))
        }
        if let continuationCursor, !continuationCursor.isEmpty {
            items.append(URLQueryItem(name: "continuation_cursor", value: continuationCursor))
        }
        var components = URLComponents()
        components.queryItems = items
        let query = (components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
        let data = try await get(path: "\(mobileAPIPrefix)/sync/manifest?\(query)")
        let page = try decode(SyncManifestPage.self, from: data, context: "syncManifestV2")
        guard page.schemaVersion == 2 else {
            throw RestError.decoding("syncManifestV2: unsupported schema")
        }
        return SyncManifestHTTPPage(
            page: page,
            encodedData: data,
            encodedByteCount: data.count
        )
    }
}
