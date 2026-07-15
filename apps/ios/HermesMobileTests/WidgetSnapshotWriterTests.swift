import XCTest
@testable import HermesMobile

@MainActor
final class WidgetSnapshotWriterTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "WidgetSnapshotWriterTests.\(UUID().uuidString)")!
        SharedStore.testSnapshotURL = directory.appendingPathComponent("snapshot.json")
        SharedStore.testDefaults = defaults
    }

    override func tearDownWithError() throws {
        SharedStore.testSnapshotURL = nil
        SharedStore.testDefaults = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func testColdProcessRetainDoesNotEraseDiskValues() throws {
        writeFull(revision: "7", tokens: 900, open: 4)
        WidgetSnapshotWriter.write(.init())
        let value = try snapshot()
        XCTAssertEqual(value.tokensToday, 900)
        XCTAssertEqual(value.openSessionCount, 4)
    }

    func testDiskIsMergeSourceAndRetainSetClearAreDistinct() throws {
        writeFull(revision: "7", tokens: 900, open: 4)
        var patch = WidgetSnapshotWriter.Patch()
        patch.openSessionCount = .set(0)
        patch.tokensToday = .clear
        WidgetSnapshotWriter.write(patch)
        let value = try snapshot()
        XCTAssertEqual(value.openSessionCount, 0, "explicit zero is not nil")
        XCTAssertNil(value.tokensToday, "only explicit clear erases")
        XCTAssertEqual(value.activeTurnCount, 2, "unspecified disk field is retained")
    }

    func testLegacyDefaultsMigrationPreservesUsage() throws {
        struct Legacy: Codable {
            let connected: Bool; let activeSessions: Int; let pendingApprovals: Int
            let tokensToday: Int?; let costTodayUSD: Double?; let updatedAt: Date
        }
        let legacy = Legacy(connected: true, activeSessions: 3, pendingApprovals: 2,
                            tokensToday: 123, costTodayUSD: 1.25, updatedAt: Date())
        defaults.set(try JSONEncoder().encode(legacy), forKey: SharedStore.snapshotKey)
        WidgetSnapshotWriter.write(.init())
        let value = try snapshot()
        XCTAssertEqual(value.schemaVersion, 2)
        XCTAssertEqual(value.tokensToday, 123)
        XCTAssertEqual(value.costToday, 1.25)
        XCTAssertNil(defaults.data(forKey: SharedStore.snapshotKey))
    }

    func testAtomicReplacementLeavesDecodableCompleteFile() throws {
        writeFull(revision: "1", tokens: 1, open: 1)
        for revision in 2...30 { writeFull(revision: "\(revision)", tokens: revision, open: revision) }
        let value = try snapshot()
        XCTAssertEqual(value.serverRevision, "30")
        XCTAssertEqual(value.tokensToday, 30)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".tmp").path))
    }

    func testOlderRevisionCannotReplaceCommittedSnapshot() throws {
        writeFull(revision: "12", tokens: 12, open: 12)
        writeFull(revision: "11", tokens: 11, open: 11)
        XCTAssertEqual(try snapshot().serverRevision, "12")
        XCTAssertEqual(try snapshot().openSessionCount, 12)
    }

    func testFailedPersistenceCannotAdvanceRevisionOrData() throws {
        writeFull(revision: "12", tokens: 12, open: 12)
        let goodURL = SharedStore.testSnapshotURL
        SharedStore.testSnapshotURL = directory.appendingPathComponent("missing/child.json")
        writeFull(revision: "13", tokens: 13, open: 13)
        SharedStore.testSnapshotURL = goodURL
        XCTAssertEqual(try snapshot().serverRevision, "12")
        XCTAssertEqual(try snapshot().tokensToday, 12)
    }

    func testEffectiveStalenessRequiresConnectionRevisionAndFreshFetch() {
        let now = Date(timeIntervalSince1970: 10_000)
        var value = makeSnapshot(revision: "1", fetchedAt: now.addingTimeInterval(-899))
        XCTAssertFalse(value.isEffectivelyStale(at: now))
        value.fetchedAt = now.addingTimeInterval(-901)
        XCTAssertTrue(value.isEffectivelyStale(at: now))
        value.fetchedAt = now; value.connectionState = .offline
        XCTAssertTrue(value.isEffectivelyStale(at: now))
        value.connectionState = .connected; value.serverRevision = nil
        XCTAssertTrue(value.isEffectivelyStale(at: now))
    }

    private func writeFull(revision: String, tokens: Int, open: Int) {
        var patch = WidgetSnapshotWriter.Patch()
        patch.serverScope = .set("server/profile")
        patch.serverRevision = .set(revision)
        patch.connectionState = .set(.connected)
        patch.openSessionCount = .set(open)
        patch.activeTurnCount = .set(2)
        patch.pendingAttentionCount = .set(1)
        patch.tokensToday = .set(tokens)
        patch.costToday = .set(0.5)
        patch.fetchedAt = .set(Date())
        patch.isStale = .set(false)
        WidgetSnapshotWriter.write(patch)
    }

    private func snapshot() throws -> SharedStore.WidgetSnapshot {
        try XCTUnwrap(SharedStore.readSnapshot())
    }

    private func makeSnapshot(revision: String?, fetchedAt: Date?) -> SharedStore.WidgetSnapshot {
        .init(serverScope: "scope", serverRevision: revision, connectionState: .connected,
              openSessionCount: 1, activeTurnCount: 1, pendingAttentionCount: 0,
              tokensToday: nil, costToday: nil, fetchedAt: fetchedAt,
              writtenAt: Date(), isStale: false)
    }
}
