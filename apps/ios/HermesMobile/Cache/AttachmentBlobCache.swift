import Foundation
import UIKit
import CryptoKit

/// On-disk, cache-on-ACCESS store for attachment / file-viewer image blobs.
///
/// This is the P4 attachment half of the offline cache (see
/// `CONTRACT-OFFLINE-CACHE.md`). It is deliberately SEPARATE from the GRDB
/// `CacheStore` actor: image bytes belong on the filesystem, not inside SQLite,
/// and this cache needs no migrations, no schema, and no `AppEnvironment`
/// wiring. It is a stateless singleton utility (mirroring the `SharedStore`
/// pattern) so the attachment file-set never collides with the scoping file-set
/// over `AppEnvironment`.
///
/// **Cache-on-access, never pre-fetch.** Nothing here is populated eagerly. An
/// image blob is written ONLY after the user has actually opened/viewed (or
/// downloaded) it in the file viewer and the bytes decoded successfully; on a
/// later view of the same file the bytes are served from disk instead of going
/// back over Tailscale. If the cache is absent or misses, the caller falls
/// straight through to the network path — behaviour is byte-identical to today.
///
/// **Scope key.** Keyed by the composite `(serverId, profileId, sessionId,
/// path)` consistent with the session/transcript scoping builder's key shape
/// (`serverId` = trimmed `ConnectionStore.serverURLString`; `profileId` =
/// normalized `SessionStore.activeProfile`, blank/`"all"` → the canonical
/// aggregate key). `size` (the server's reported byte count) is folded into the
/// on-disk filename as a cheap content/version discriminator, so a file that
/// changed length re-fetches instead of serving a stale blob.
///
/// **Eviction.** A 365-day horizon is DEFINED here (mirroring the cache scope
/// decision) but, per the P4 scope, NO periodic evict is wired — `evictStale`
/// exists for a future activation and is never called on the hot path.
final class AttachmentBlobCache: @unchecked Sendable {

    /// Shared instance. Stateless beyond the (immutable) base directory URL and
    /// a serial queue guarding disk writes, so a singleton is safe and needs no
    /// dependency injection.
    static let shared = AttachmentBlobCache()

    /// Canonical scope-key components for a blob lookup/store. Mirrors the
    /// `(serverId, profileId)` composite the session/transcript scoping builder
    /// keys on, extended with the per-image `(sessionId, path, size)` identity.
    struct Key: Sendable, Hashable {
        let serverId: String
        let profileId: String
        let sessionId: String
        let path: String
        /// Server-reported byte count — a cheap freshness/version discriminator
        /// folded into the filename so a changed file re-fetches.
        let size: Int

        init(serverId: String, profileId: String, sessionId: String, path: String, size: Int) {
            self.serverId = Self.normalizeServer(serverId)
            self.profileId = Self.normalizeProfile(profileId)
            self.sessionId = sessionId
            self.path = path
            self.size = size
        }

        /// Trimmed server URL string (the same identity used for the Keychain
        /// token + device-id maps).
        static func normalizeServer(_ raw: String) -> String {
            raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// Blank/`"all"` collapse to one canonical aggregate key; any other
        /// value (incl. `"default"` and named profiles) is used literally —
        /// matching `SessionStore.isAllProfilesScope`.
        static func normalizeProfile(_ raw: String) -> String {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == "all" { return "all" }
            return trimmed
        }
    }

    /// 365-day retention horizon — DEFINED per the cache scope decision but NOT
    /// wired to any periodic sweep in P4.
    static let evictionHorizon: TimeInterval = 365 * 24 * 60 * 60

    private let baseURL: URL?
    /// Serialises disk writes so concurrent viewers can't corrupt a blob file.
    private let ioQueue = DispatchQueue(label: "hermes.attachmentBlobCache.io")

    private init() {
        self.baseURL = Self.makeBaseDirectory()
    }

    // MARK: - Directory

    /// `Caches/HermesMobile/imageblobs/` — reconstructible, so it lives under
    /// Caches (the system may purge it under pressure, which is fine) and is
    /// explicitly excluded from iCloud backup (mirrors `CacheStore.dbURL`).
    private static func makeBaseDirectory() -> URL? {
        let fm = FileManager.default
        guard let caches = try? fm.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let dir = caches
            .appendingPathComponent("HermesMobile", isDirectory: true)
            .appendingPathComponent("imageblobs", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableDir = dir
            try? mutableDir.setResourceValues(values)
            return dir
        } catch {
            return nil
        }
    }

    // MARK: - Filename

    /// A stable, collision-resistant filename: SHA-256 of the scope-qualified
    /// identity, with the byte `size` appended as a version discriminator. A
    /// changed file (different `size`) maps to a different filename, so the old
    /// blob is naturally bypassed (and aged out by a future evict).
    private func fileURL(for key: Key) -> URL? {
        guard let baseURL else { return nil }
        let identity = [
            key.serverId,
            key.profileId,
            key.sessionId,
            key.path,
        ].joined(separator: "\u{1f}") // unit separator — can't appear in a path
        let digest = SHA256.hash(data: Data(identity.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return baseURL.appendingPathComponent("\(hex)-\(key.size).blob")
    }

    // MARK: - Read

    /// Return the on-disk image for `key`, or `nil` on a miss (caller then
    /// fetches from the network — today's path, unchanged). Decodes the stored
    /// bytes into a `UIImage`; a stored blob that no longer decodes is treated
    /// as a miss (and best-effort removed).
    func image(for key: Key) -> UIImage? {
        guard let url = fileURL(for: key),
              let data = try? Data(contentsOf: url) else { return nil }
        guard let image = UIImage(data: data) else {
            // Corrupt/undecodable blob — drop it and miss.
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return image
    }

    /// Return the raw on-disk bytes for `key`, or `nil` on a miss. Exposed for
    /// callers that want the original bytes (e.g. a download/share action)
    /// without a decode round-trip.
    func data(for key: Key) -> Data? {
        guard let url = fileURL(for: key) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// True when a blob for `key` is already on disk (cheap existence check, no
    /// decode).
    func contains(_ key: Key) -> Bool {
        guard let url = fileURL(for: key) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Write (cache-on-access)

    /// Persist `data` for `key` after a successful view/download. Fire-and-forget
    /// off the UI path; failures are swallowed (the cache is an accelerator,
    /// never a correctness dependency). Skips empty data.
    func store(_ data: Data, for key: Key) {
        guard !data.isEmpty, let url = fileURL(for: key) else { return }
        ioQueue.async {
            // Atomic write so a concurrent reader never sees a half-written blob.
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Eviction (DEFINED, NOT wired in P4)

    /// Delete blob files not modified within ``evictionHorizon``. DEFINED for a
    /// future activation; per the P4 scope this is NOT called on any periodic
    /// schedule or hot path. Kept here so the retention policy lives with the
    /// store it governs.
    func evictStale(horizon: TimeInterval = AttachmentBlobCache.evictionHorizon,
                    now: Date = Date()) {
        guard let baseURL else { return }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = now.addingTimeInterval(-horizon)
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let modified, modified < cutoff {
                try? fm.removeItem(at: entry)
            }
        }
    }

    /// Drop EVERY cached blob — the nuclear reset (e.g. a sign-out / re-pair).
    /// Not wired in P4; provided so a future server-switch policy can clear
    /// image blobs the same way the session cache clears other-server rows.
    func clearAll() {
        guard let baseURL else { return }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for entry in entries {
            try? fm.removeItem(at: entry)
        }
    }
}
