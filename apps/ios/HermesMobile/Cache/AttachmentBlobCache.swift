import Foundation
import UIKit
import CryptoKit
import ImageIO
import GRDB

/// Bounded, cache-on-access attachment store. The actor is the isolation
/// boundary for both SQLite metadata and filesystem access, so callers on the
/// main actor only suspend while cache work runs on the cooperative executor.
actor AttachmentBlobCache {
    static let diskCapacity: Int64 = 256 * 1_024 * 1_024
    static let decodedMemoryCapacity = 64 * 1_024 * 1_024
    static let timeToLive: TimeInterval = 30 * 24 * 60 * 60

    static let shared: AttachmentBlobCache = {
        do { return try AttachmentBlobCache() }
        catch { fatalError("Unable to create attachment cache: \(error)") }
    }()

    struct Scope: Sendable, Hashable {
        let serverId: String
        let profileId: String

        init(serverId: String, profileId: String) {
            self.serverId = Key.normalizeServer(serverId)
            self.profileId = Key.normalizeProfile(profileId)
        }
    }

    struct Key: Sendable, Hashable {
        let serverId: String
        let profileId: String
        let sessionId: String
        let path: String
        let contentVersion: String

        var scope: Scope { Scope(serverId: serverId, profileId: profileId) }

        init(serverId: String, profileId: String, sessionId: String,
             path: String, contentVersion: String) {
            self.serverId = Self.normalizeServer(serverId)
            self.profileId = Self.normalizeProfile(profileId)
            self.sessionId = sessionId
            self.path = path
            self.contentVersion = contentVersion
        }

        static func normalizeServer(_ raw: String) -> String {
            raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        static func normalizeProfile(_ raw: String) -> String {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty || value == "all" ? "all" : value
        }
    }

    struct Statistics: Sendable, Equatable {
        let entryCount: Int
        let byteCount: Int64
    }

    typealias Clock = @Sendable () -> Date

    private let directory: URL
    private let db: DatabaseQueue
    private let capacity: Int64
    private let ttl: TimeInterval
    private let clock: Clock
    private let fileManager: FileManager
    private let decoded = NSCache<NSString, UIImage>()
    private var lastAccessWrite: [String: Date] = [:]
    private let accessWriteInterval: TimeInterval = 60

    init(directory: URL? = nil,
         capacity: Int64 = AttachmentBlobCache.diskCapacity,
         ttl: TimeInterval = AttachmentBlobCache.timeToLive,
         decodedMemoryCapacity: Int = AttachmentBlobCache.decodedMemoryCapacity,
         clock: @escaping Clock = Date.init,
         fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        self.capacity = max(0, capacity)
        self.ttl = max(0, ttl)
        self.clock = clock
        self.directory = try directory ?? Self.defaultDirectory(fileManager: fileManager)
        try fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = self.directory
        try? mutableDirectory.setResourceValues(values)

        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        let queue = try DatabaseQueue(
            path: self.directory.appendingPathComponent("metadata.sqlite").path,
            configuration: configuration
        )
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS attachment_blob (
                    cacheKey TEXT PRIMARY KEY NOT NULL,
                    serverId TEXT NOT NULL,
                    profileId TEXT NOT NULL,
                    sessionId TEXT NOT NULL,
                    path TEXT NOT NULL,
                    contentVersion TEXT NOT NULL,
                    mimeType TEXT,
                    byteCount INTEGER NOT NULL,
                    relativeFilename TEXT NOT NULL UNIQUE,
                    createdAt DOUBLE NOT NULL,
                    lastAccessAt DOUBLE NOT NULL
                )
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS attachment_blob_lru ON attachment_blob(lastAccessAt)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS attachment_blob_scope ON attachment_blob(serverId, profileId)")
        }
        self.db = queue
        decoded.totalCostLimit = decodedMemoryCapacity
    }

    private static func defaultDirectory(fileManager: FileManager) throws -> URL {
        let caches = try fileManager.url(for: .cachesDirectory, in: .userDomainMask,
                                         appropriateFor: nil, create: true)
        return caches.appendingPathComponent("HermesMobile", isDirectory: true)
            .appendingPathComponent("imageblobs", isDirectory: true)
    }

    private func cacheKey(for key: Key) -> String {
        let identity = [key.serverId, key.profileId, key.sessionId, key.path,
                        key.contentVersion].joined(separator: "\u{1f}")
        return SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private func blobURL(filename: String) -> URL {
        directory.appendingPathComponent(filename, isDirectory: false)
    }

    /// Returns a display-sized image. ImageIO decodes directly to a thumbnail,
    /// avoiding a transient full-resolution bitmap.
    func image(for key: Key, maxPixelSize: CGSize = CGSize(width: 2_048, height: 2_048)) -> UIImage? {
        let id = cacheKey(for: key)
        let memoryKey = "\(id):\(Int(maxPixelSize.width))x\(Int(maxPixelSize.height))" as NSString
        if let image = decoded.object(forKey: memoryKey) {
            touch(id)
            return image
        }
        guard let filename = metadataFilename(id: id) else { return nil }
        let url = blobURL(filename: filename)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat else {
            remove(id: id, filename: filename)
            return nil
        }
        let sourceMaximum = max(width, height)
        let scale = min(1, maxPixelSize.width / width, maxPixelSize.height / height)
        let thumbnailMaximum = max(1, floor(sourceMaximum * scale))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaximum,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            remove(id: id, filename: filename)
            return nil
        }
        let image = UIImage(cgImage: cgImage)
        decoded.setObject(image, forKey: memoryKey,
                          cost: cgImage.bytesPerRow * cgImage.height)
        touch(id)
        return image
    }

    func data(for key: Key) -> Data? {
        let id = cacheKey(for: key)
        guard let filename = metadataFilename(id: id) else { return nil }
        do {
            let value = try Data(contentsOf: blobURL(filename: filename), options: .mappedIfSafe)
            touch(id)
            return value
        } catch {
            remove(id: id, filename: filename)
            return nil
        }
    }

    func contains(_ key: Key) -> Bool {
        let id = cacheKey(for: key)
        guard let filename = metadataFilename(id: id) else { return false }
        guard fileManager.fileExists(atPath: blobURL(filename: filename).path) else {
            remove(id: id, filename: filename)
            return false
        }
        touch(id)
        return true
    }

    /// Atomic blob write followed by a metadata upsert. Eviction completes
    /// before this method returns, so callers can rely on the configured cap.
    func store(_ data: Data, for key: Key, mimeType: String? = nil) {
        guard !data.isEmpty else { return }
        let id = cacheKey(for: key)
        let filename = "\(id).blob"
        let url = blobURL(filename: filename)
        do {
            try data.write(to: url, options: .atomic)
            let timestamp = clock().timeIntervalSince1970
            try db.write { db in
                try db.execute(sql: """
                    INSERT INTO attachment_blob
                    (cacheKey, serverId, profileId, sessionId, path, contentVersion,
                     mimeType, byteCount, relativeFilename, createdAt, lastAccessAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(cacheKey) DO UPDATE SET
                      mimeType=excluded.mimeType, byteCount=excluded.byteCount,
                      relativeFilename=excluded.relativeFilename,
                      lastAccessAt=excluded.lastAccessAt
                    """, arguments: [id, key.serverId, key.profileId, key.sessionId,
                                      key.path, key.contentVersion, mimeType, data.count,
                                      filename, timestamp, timestamp])
            }
            evict(to: capacity)
        } catch {
            try? fileManager.removeItem(at: url)
        }
    }

    /// TTL, missing-file, orphan-file, and capacity reconciliation.
    func performMaintenance() {
        reconcileMissingFilesAndExpiredEntries()
        reconcileOrphans()
        evict(to: capacity)
    }

    /// More aggressive policy used when the volume reports low capacity.
    func handleLowDisk() {
        performMaintenance()
        evict(to: capacity / 2)
    }

    /// Checks the cache volume without involving a MainActor caller.
    func respondToLowAvailableCapacity(threshold: Int64 = 512 * 1_024 * 1_024) {
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values?.volumeAvailableCapacityForImportantUsage,
           available < threshold {
            handleLowDisk()
        }
    }

    func handleMemoryWarning() {
        decoded.removeAllObjects()
    }

    @discardableResult
    func purge(scope: Scope) -> Int {
        let rows = (try? db.read { db in
            try Row.fetchAll(db, sql: "SELECT cacheKey, relativeFilename FROM attachment_blob WHERE serverId = ? AND profileId = ?",
                             arguments: [scope.serverId, scope.profileId])
        }) ?? []
        for row in rows {
            let id: String = row["cacheKey"]
            let filename: String = row["relativeFilename"]
            remove(id: id, filename: filename)
        }
        return rows.count
    }

    func clearAll() {
        let rows = allRows()
        for row in rows { remove(id: row.id, filename: row.filename) }
        decoded.removeAllObjects()
    }

    func statistics() -> Statistics {
        (try? db.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT COUNT(*) AS count, COALESCE(SUM(byteCount), 0) AS bytes FROM attachment_blob")
            return Statistics(entryCount: row?["count"] ?? 0, byteCount: row?["bytes"] ?? 0)
        }) ?? Statistics(entryCount: 0, byteCount: 0)
    }

    private func metadataFilename(id: String) -> String? {
        try? db.read { db in
            try String.fetchOne(db, sql: "SELECT relativeFilename FROM attachment_blob WHERE cacheKey = ?", arguments: [id])
        }
    }

    private func touch(_ id: String) {
        let now = clock()
        if let last = lastAccessWrite[id], now.timeIntervalSince(last) < accessWriteInterval { return }
        lastAccessWrite[id] = now
        try? db.write { db in
            try db.execute(sql: "UPDATE attachment_blob SET lastAccessAt = ? WHERE cacheKey = ?",
                           arguments: [now.timeIntervalSince1970, id])
        }
    }

    private func allRows() -> [(id: String, filename: String)] {
        (try? db.read { db in
            try Row.fetchAll(db, sql: "SELECT cacheKey, relativeFilename FROM attachment_blob")
                .map { ($0["cacheKey"], $0["relativeFilename"]) }
        }) ?? []
    }

    private func remove(id: String, filename: String) {
        try? fileManager.removeItem(at: blobURL(filename: filename))
        try? db.write { db in
            try db.execute(sql: "DELETE FROM attachment_blob WHERE cacheKey = ?", arguments: [id])
        }
        lastAccessWrite.removeValue(forKey: id)
        // Size-specific memory keys cannot be enumerated by NSCache; clearing is
        // rare and guarantees removed scope/version objects cannot linger.
        decoded.removeAllObjects()
    }

    private func reconcileMissingFilesAndExpiredEntries() {
        let cutoff = clock().addingTimeInterval(-ttl).timeIntervalSince1970
        let rows = (try? db.read { db in
            try Row.fetchAll(db, sql: "SELECT cacheKey, relativeFilename, lastAccessAt FROM attachment_blob")
        }) ?? []
        for row in rows {
            let id: String = row["cacheKey"]
            let filename: String = row["relativeFilename"]
            let accessed: Double = row["lastAccessAt"]
            if accessed < cutoff || !fileManager.fileExists(atPath: blobURL(filename: filename).path) {
                remove(id: id, filename: filename)
            }
        }
    }

    private func reconcileOrphans() {
        let known = Set(allRows().map(\.filename))
        let files = (try? fileManager.contentsOfDirectory(at: directory,
                            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for file in files where file.pathExtension == "blob" && !known.contains(file.lastPathComponent) {
            try? fileManager.removeItem(at: file)
        }
    }

    private func evict(to target: Int64) {
        var total = statistics().byteCount
        guard total > target else { return }
        let rows = (try? db.read { db in
            try Row.fetchAll(db, sql: "SELECT cacheKey, relativeFilename, byteCount FROM attachment_blob ORDER BY lastAccessAt ASC, createdAt ASC")
        }) ?? []
        for row in rows where total > target {
            let id: String = row["cacheKey"]
            let filename: String = row["relativeFilename"]
            let bytes: Int64 = row["byteCount"]
            remove(id: id, filename: filename)
            total -= bytes
        }
    }

    /// Decode data URLs away from the caller's actor and downsample without a
    /// full-size UIKit decode. The original bytes are retained for disk cache.
    nonisolated static func decodeDataURL(_ value: String,
                                          maxPixelSize: CGFloat = 2_048) async -> (image: UIImage, data: Data)? {
        await Task.detached(priority: .userInitiated) {
            guard value.hasPrefix("data:"), let comma = value.firstIndex(of: ","),
                  value[..<comma].contains(";base64"),
                  let data = Data(base64Encoded: String(value[value.index(after: comma)...]),
                                  options: [.ignoreUnknownCharacters]),
                  let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return (UIImage(cgImage: cgImage), data)
        }.value
    }

    /// Compatibility for render-only SwiftUI branches that cannot suspend.
    /// ImageIO still creates only the bounded thumbnail (never a full bitmap).
    nonisolated static func decodeDataURLSynchronously(
        _ value: String,
        maxPixelSize: CGFloat = 2_048
    ) -> (image: UIImage, data: Data)? {
        guard value.hasPrefix("data:"), let comma = value.firstIndex(of: ","),
              value[..<comma].contains(";base64"),
              let data = Data(base64Encoded: String(value[value.index(after: comma)...]),
                              options: [.ignoreUnknownCharacters]),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return (UIImage(cgImage: image), data)
    }
}
