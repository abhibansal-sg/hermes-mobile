import Foundation

extension RestClient {
    func mobilePluginCapabilities() async throws -> MobilePluginCapabilitiesV1 {
        guard pathStyle == .plugin else {
            throw RestError.decoding("mobileCapabilitiesV1: plugin path required")
        }
        let data = try await get(path: "\(mobileAPIPrefix)/capabilities")
        let capabilities = try decode(
            MobilePluginCapabilitiesV1.self,
            from: data,
            context: "mobileCapabilitiesV1"
        )
        guard capabilities.schemaVersion == 1 else {
            throw RestError.decoding("mobileCapabilitiesV1: incompatible response")
        }
        return capabilities
    }

    func compactTurns(
        storedSessionID: String,
        profile: String,
        before: String? = nil,
        afterRevision: Int64 = 0,
        limit: Int = 30
    ) async throws -> CompactTurnPageV1 {
        guard pathStyle == .plugin,
              !storedSessionID.isEmpty,
              !profile.isEmpty,
              (1...100).contains(limit),
              afterRevision >= 0 else {
            throw RestError.decoding("compactTurnsV1: invalid request contract")
        }
        var items = [
            URLQueryItem(name: "profile", value: profile),
            URLQueryItem(name: "after_revision", value: String(afterRevision)),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if let before, !before.isEmpty {
            items.append(URLQueryItem(name: "before", value: before))
        }
        var components = URLComponents()
        components.queryItems = items
        let query = (components.percentEncodedQuery ?? "")
            .replacingOccurrences(of: "+", with: "%2B")
        let encodedSession = storedSessionID.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? storedSessionID
        let data = try await get(
            path: "\(mobileAPIPrefix)/sessions/\(encodedSession)/turns?\(query)"
        )
        let page = try decode(
            CompactTurnPageV1.self,
            from: data,
            context: "compactTurnsV1"
        )
        guard page.schemaVersion == 1,
              page.projectionVersion == 1,
              page.storedSessionID == storedSessionID else {
            throw RestError.decoding("compactTurnsV1: incompatible response")
        }
        return page
    }
}
