import CryptoKit
import Foundation
import GRDB

enum LegacyImportCrashPoint: Equatable, Sendable {
    case afterQueueCommit
    case afterPendingIntentCommit
    case afterShareCommit
}

struct LegacyWorkImportSource: @unchecked Sendable {
    let appDefaults: UserDefaults
    let sharedDefaults: UserDefaults?
    let sharedImagesDirectory: URL?
    let scope: WorkScope?
    let injectCrash: @Sendable (LegacyImportCrashPoint) throws -> Void

    init(
        appDefaults: UserDefaults = .standard,
        sharedDefaults: UserDefaults? = SharedStore.defaults,
        sharedImagesDirectory: URL? = SharedStore.sharedImagesDirectory,
        scope: WorkScope?,
        injectCrash: @escaping @Sendable (LegacyImportCrashPoint) throws -> Void = { _ in }
    ) {
        self.appDefaults = appDefaults
        self.sharedDefaults = sharedDefaults
        self.sharedImagesDirectory = sharedImagesDirectory
        self.scope = scope
        self.injectCrash = injectCrash
    }
}

extension WorkRepository {
    private static var legacyQueueKey: String { "hermes.queue" }
    private static var legacyPendingIntentKey: String { "hermes.pendingIntentPrompt" }
    private static var legacyShareInboxKey: String { "hermes.sharedInbox" }

    /// Imports all pre-WorkRepository writers. Source cleanup happens only after
    /// the corresponding rows commit. Unique legacy keys make a crash between
    /// commit and cleanup harmless on the next open.
    func importLegacyWork(from source: LegacyWorkImportSource) async throws {
        try await importLegacyQueue(from: source)
        try await importLegacyPendingIntent(from: source)
        try await importLegacyShares(from: source)
    }

    private func importLegacyQueue(from source: LegacyWorkImportSource) async throws {
        guard let data = source.appDefaults.data(forKey: Self.legacyQueueKey) else { return }
        let prompts = try JSONDecoder().decode([LegacyQueuedPrompt].self, from: data)
        for prompt in prompts {
            let key = "queue:\(prompt.id.uuidString.lowercased())"
            guard try !containsLegacyImport(key) else { continue }
            do {
                _ = try await enqueue(WorkJobInput(
                    jobID: prompt.id,
                    kind: .prompt,
                    scope: source.scope,
                    text: prompt.text,
                    storedSessionID: prompt.storedSessionId,
                    legacyImportKey: key,
                    createdAt: prompt.createdAt
                ))
            } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
                guard try containsLegacyImport(key) else { throw error }
            }
        }
        try source.injectCrash(.afterQueueCommit)
        source.appDefaults.removeObject(forKey: Self.legacyQueueKey)
    }

    private func importLegacyPendingIntent(from source: LegacyWorkImportSource) async throws {
        guard let raw = source.appDefaults.dictionary(forKey: Self.legacyPendingIntentKey)
            as? [String: String],
              let kind = raw["kind"] else { return }

        let intentKind: WorkIntentKind
        let text: String?
        switch kind {
        case "ask":
            let prompt = (raw["prompt"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty else { return }
            intentKind = .askHermes
            text = prompt
        case "openSessions":
            intentKind = .openSessions
            text = nil
        case "newSession":
            intentKind = .newSession
            text = nil
        default:
            return
        }

        let canonical = "\(intentKind.rawValue)|\(text ?? "")"
        let hash = Self.legacySHA256(Data(canonical.utf8))
        let key = "pending-intent:v1:\(hash)"
        if try !containsLegacyImport(key) {
            do {
                _ = try await enqueueAppIntent(
                    kind: intentKind,
                    text: text,
                    scope: source.scope,
                    legacyImportKey: key
                )
            } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
                guard try containsLegacyImport(key) else { throw error }
            }
        }
        try source.injectCrash(.afterPendingIntentCommit)
        source.appDefaults.removeObject(forKey: Self.legacyPendingIntentKey)
    }

    private func importLegacyShares(from source: LegacyWorkImportSource) async throws {
        guard let defaults = source.sharedDefaults,
              let data = defaults.data(forKey: Self.legacyShareInboxKey) else { return }
        let shares = try JSONDecoder().decode([LegacySharedInboxItem].self, from: data)
        for share in shares {
            let key = "share:\(share.id.uuidString.lowercased())"
            guard try !containsLegacyImport(key) else { continue }
            let assets = try share.imageFiles.map { name -> WorkAssetInput in
                guard Self.isSafeLegacyFilename(name), let directory = source.sharedImagesDirectory else {
                    throw WorkRepositoryError.invalidRelativePath
                }
                let data = try Data(contentsOf: directory.appendingPathComponent(name))
                let ext = (name as NSString).pathExtension.isEmpty
                    ? "jpg"
                    : (name as NSString).pathExtension
                return WorkAssetInput(data: data, mimeType: "image/jpeg", fileExtension: ext)
            }
            do {
                _ = try await enqueue(WorkJobInput(
                    jobID: share.id,
                    kind: .share,
                    scope: source.scope,
                    text: share.text,
                    sourceURL: share.url,
                    comment: share.comment,
                    expiresAt: share.createdAt.addingTimeInterval(14 * 24 * 60 * 60),
                    legacyImportKey: key,
                    createdAt: share.createdAt
                ), assets: assets)
            } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
                guard try containsLegacyImport(key) else { throw error }
            }
        }
        try source.injectCrash(.afterShareCommit)
        // Do not call SharedStore.removeInboxItem: that would delete the legacy
        // image bytes before the one-release import window is over.
        defaults.removeObject(forKey: Self.legacyShareInboxKey)
    }

    private func containsLegacyImport(_ key: String) throws -> Bool {
        try database.read { db in
            try WorkJob
                .filter(Column("legacy_import_key") == key)
                .fetchCount(db) > 0
        }
    }

    private static func isSafeLegacyFilename(_ name: String) -> Bool {
        !name.isEmpty
            && !name.hasPrefix("/")
            && !name.contains("..")
            && !name.contains("\\")
            && (name as NSString).pathComponents.count == 1
    }

    private static func legacySHA256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct LegacyQueuedPrompt: Decodable {
    let id: UUID
    let text: String
    let createdAt: Date
    let storedSessionId: String?
}

private struct LegacySharedInboxItem: Decodable {
    let id: UUID
    let text: String?
    let url: String?
    let comment: String?
    let imageFiles: [String]
    let createdAt: Date
}
