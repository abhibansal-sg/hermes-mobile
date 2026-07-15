import Foundation

extension RestClient {
    /// Plugin-only manifest page. A legacy path style is deliberately rejected,
    /// allowing the coordinator to enter its existing session-list fallback.
    func syncManifest(scope: CacheScope, cursor: String?) async throws -> SyncManifestPage {
        guard pathStyle == .plugin else { throw RestError.badStatus(404, body: "sync manifest unavailable") }
        var items = [URLQueryItem(name: "profile", value: scope.profileId)]
        if let cursor, !cursor.isEmpty { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        var components = URLComponents()
        components.queryItems = items
        let query = (components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
        let data = try await get(path: "\(mobileAPIPrefix)/sync-manifest?\(query)")
        return try decode(SyncManifestPage.self, from: data, context: "syncManifest")
    }
}
