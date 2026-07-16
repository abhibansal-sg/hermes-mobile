import Foundation

/// Bridges resolved share content into the protected app-group work database.
/// The extension only commits durable local work; it never contacts a gateway.
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

    /// Persist one share and all its assets into `WorkRepository`. A share
    /// captured before pairing intentionally starts in `waiting_for_scope`.
    /// Any protected-data or SQLite error is returned to the UI; success is
    /// never inferred from a best-effort `UserDefaults` write.
    @discardableResult
    nonisolated static func queue(
        content: SharedItemLoader.LoadedShareContent,
        comment: String?,
        configuration: WorkRepositoryConfiguration? = nil
    ) async throws -> WorkJob {
        let trimmedComment = comment?.trimmingCharacters(in: .whitespacesAndNewlines)
        let repository: WorkRepository
        do {
            if let configuration {
                repository = try WorkRepository(configuration: configuration)
            } else {
                repository = try await WorkRepository.openAppGroup(scope: nil)
            }
        } catch WorkRepositoryError.appGroupUnavailable {
            throw WriteError.appGroupUnavailable
        }
        let assets = content.images.map {
            WorkAssetInput(data: $0, mimeType: "image/jpeg", fileExtension: "jpg")
        }
        return try await repository.enqueueShare(
            WorkJobInput(
                kind: .share,
                scope: nil,
                text: content.text,
                sourceURL: content.url,
                comment: (trimmedComment?.isEmpty ?? true) ? nil : trimmedComment
            ),
            assets: assets
        )
    }
}
