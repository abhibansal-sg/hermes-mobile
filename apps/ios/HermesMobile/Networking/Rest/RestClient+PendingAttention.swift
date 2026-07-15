import Foundation

extension RestClient {
    /// Fetch the authenticated, visibility-scoped pending-attention delta.
    /// Legacy gateways intentionally fall through as 404 so live-event Inbox
    /// behavior remains available without claiming durable reconciliation.
    func pendingAttention(cursor: String?) async throws -> PendingAttentionEnvelope {
        guard pathStyle == .plugin else {
            throw RestError.badStatus(404, body: "pending attention unavailable")
        }
        var components = URLComponents()
        if let cursor, !cursor.isEmpty {
            components.queryItems = [URLQueryItem(name: "cursor", value: cursor)]
        }
        let suffix = components.percentEncodedQuery.map { "?\($0)" } ?? ""
        let data = try await get(path: "\(mobileAPIPrefix)/pending-attention\(suffix)")
        return try decode(PendingAttentionEnvelope.self, from: data, context: "pendingAttention")
    }
}
