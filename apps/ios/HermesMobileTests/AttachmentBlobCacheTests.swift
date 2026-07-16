import XCTest
import UIKit
@testable import HermesMobile

final class AttachmentBlobCacheTests: XCTestCase {
    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ value: Date) { self.value = value }
        func now() -> Date { lock.withLock { value } }
        func advance(_ interval: TimeInterval) { lock.withLock { value.addTimeInterval(interval) } }
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("attachment-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func key(_ version: String, server: String = "gateway-a", profile: String = "default",
                     path: String = "/image.png") -> AttachmentBlobCache.Key {
        .init(serverId: server, profileId: profile, sessionId: "session", path: path,
              contentVersion: version)
    }

    private func png(width: Int = 80, height: Int = 40, color: UIColor = .red) -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        return renderer.pngData { context in color.setFill(); context.fill(renderer.format.bounds) }
    }

    func testWriteEvictsLRUAndStaysAtOrBelowCap() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let first = png(color: .red), second = png(color: .blue)
        // PNG compression size varies by renderer/runtime. Give the cache room
        // for either single blob, but not both, so the assertion tests LRU
        // behavior instead of depending on red encoding larger than blue.
        let singleBlobCapacity = Int64(max(first.count, second.count))
        let cache = try AttachmentBlobCache(directory: directory(), capacity: singleBlobCapacity,
                                            clock: clock.now)
        await cache.store(first, for: key("v1"))
        clock.advance(61)
        await cache.store(second, for: key("v2", path: "/other.png"))
        let stats = await cache.statistics()
        XCTAssertLessThanOrEqual(stats.byteCount, singleBlobCapacity)
        let containsFirst = await cache.contains(key("v1"))
        let containsSecond = await cache.contains(key("v2", path: "/other.png"))
        XCTAssertFalse(containsFirst)
        XCTAssertTrue(containsSecond)
    }

    func testMaintenanceRemovesExpiredMissingAndOrphanFiles() async throws {
        let dir = try directory()
        let clock = TestClock(Date(timeIntervalSince1970: 2_000))
        let cache = try AttachmentBlobCache(directory: dir, capacity: 1_000_000, ttl: 30, clock: clock.now)
        await cache.store(png(), for: key("expired"))
        clock.advance(31)
        let orphan = dir.appendingPathComponent("orphan.blob")
        try Data([1, 2, 3]).write(to: orphan)
        await cache.performMaintenance()
        var stats = await cache.statistics()
        XCTAssertEqual(stats.entryCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))

        await cache.store(png(), for: key("missing"))
        let blob = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "blob" }))
        try FileManager.default.removeItem(at: blob)
        await cache.performMaintenance()
        stats = await cache.statistics()
        XCTAssertEqual(stats.entryCount, 0)
    }

    func testScopePurgeDoesNotAffectAnotherScope() async throws {
        let cache = try AttachmentBlobCache(directory: directory())
        let a = key("a", server: "gateway-a")
        let b = key("b", server: "gateway-b")
        await cache.store(png(color: .red), for: a)
        await cache.store(png(color: .blue), for: b)
        let purged = await cache.purge(scope: a.scope)
        let containsA = await cache.contains(a)
        let containsB = await cache.contains(b)
        XCTAssertEqual(purged, 1)
        XCTAssertFalse(containsA)
        XCTAssertTrue(containsB)
    }

    func testConcurrentReadsAndWritesRemainConsistent() async throws {
        let cache = try AttachmentBlobCache(directory: directory(), capacity: 20_000_000)
        let bytes = png(width: 400, height: 200)
        let items = (0..<30).map { key("v\($0)", path: "/\($0).png") }
        await withTaskGroup(of: Void.self) { group in
            for item in items {
                group.addTask {
                    await cache.store(bytes, for: item)
                    _ = await cache.image(for: item, maxPixelSize: CGSize(width: 50, height: 50))
                }
            }
        }
        let stats = await cache.statistics()
        XCTAssertEqual(stats.entryCount, 30)
    }

    func testImageIsDownsampledToRequestedPixelDimensions() async throws {
        let cache = try AttachmentBlobCache(directory: directory())
        let item = key("large")
        await cache.store(png(width: 800, height: 400), for: item)
        let result = await cache.image(for: item, maxPixelSize: CGSize(width: 100, height: 100))
        let image = try XCTUnwrap(result)
        XCTAssertLessThanOrEqual(image.cgImage?.width ?? .max, 100)
        XCTAssertLessThanOrEqual(image.cgImage?.height ?? .max, 100)
        XCTAssertEqual(image.cgImage?.width, 100)
        XCTAssertEqual(image.cgImage?.height, 50)
    }

    func testMemoryWarningDropsDecodedObjectButPreservesDiskEntry() async throws {
        let cache = try AttachmentBlobCache(directory: directory())
        let item = key("memory")
        await cache.store(png(), for: item)
        let beforeWarning = await cache.image(for: item)
        XCTAssertNotNil(beforeWarning)
        await cache.handleMemoryWarning()
        let remainsOnDisk = await cache.contains(item)
        let afterWarning = await cache.image(for: item)
        XCTAssertTrue(remainsOnDisk)
        XCTAssertNotNil(afterWarning)
    }

    func testLowDiskAggressivelyReducesUsage() async throws {
        let bytes = png(width: 300, height: 300)
        let cap = Int64(bytes.count * 4)
        let cache = try AttachmentBlobCache(directory: directory(), capacity: cap)
        for index in 0..<4 { await cache.store(bytes, for: key("v\(index)", path: "/\(index).png")) }
        await cache.handleLowDisk()
        let stats = await cache.statistics()
        XCTAssertLessThanOrEqual(stats.byteCount, cap / 2)
    }

    func testSameSizeContentVersionsRemainDistinctAndCorruptionMisses() async throws {
        let dir = try directory()
        let cache = try AttachmentBlobCache(directory: dir)
        var red = png(color: .red), blue = png(color: .blue)
        let sameSize = max(red.count, blue.count)
        red.append(Data(repeating: 0, count: sameSize - red.count))
        blue.append(Data(repeating: 0, count: sameSize - blue.count))
        XCTAssertEqual(red.count, blue.count)
        await cache.store(red, for: key("sha-red"))
        await cache.store(blue, for: key("sha-blue"))
        let cachedRed = await cache.data(for: key("sha-red"))
        let cachedBlue = await cache.data(for: key("sha-blue"))
        XCTAssertEqual(cachedRed, red)
        XCTAssertEqual(cachedBlue, blue)

        let blobs = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "blob" }
        XCTAssertEqual(blobs.count, 2)
        for blob in blobs { try Data([0, 1, 2]).write(to: blob) }
        let miss = await cache.image(for: key("sha-red"))
        XCTAssertNil(miss, "corrupt cache entries must fall through to network")
    }
}
