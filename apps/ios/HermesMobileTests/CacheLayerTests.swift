import XCTest
import Foundation
import GRDB
@testable import HermesMobile

// MARK: - CacheLayerTests
//
// Unit tests for P1 (CacheStore) + P2 (SyncEngine).
// All tests use in-memory DatabaseQueues — no filesystem access, no live gateway.
// Injectable SessionListFetcher and TranscriptFetcher seams keep tests hermetic.
//
// Covered:
//   - Round-trip persistence: write page -> read back identical (ordinal order)
//   - List diff: added/dirty/removed/unchanged classification
//   - Cursor advance: maxMessageId tracks across saves
//   - Eviction: recent sessions exempt, old sessions evicted, session row preserved
//   - Migration v1: tables + fingerprint created; idempotent second apply
//   - Cron-exclusion: cron sessions never get transcript rows
//   - Dirty-set management via broadcast frames
//   - Eviction throttle: second call within 24h is a no-op

// MARK: - Helpers

/// A default test scope so the P1/P2 round-trip tests (which predate P4
/// scoping) keep exercising one canonical (server, profile) partition.
private let testScope = CacheScope(serverId: "https://test.example", profileId: "all")

private func makeInMemoryStore() throws -> CacheStore {
    var config = Configuration()
    config.prepareDatabase { db in
        try db.execute(sql: "PRAGMA foreign_keys = ON")
    }
    let queue = try DatabaseQueue(configuration: config)
    return try CacheStore(testDB: queue)
}

private func makeSession(
    id: String,
    lastActive: Double? = 100,
    messageCount: Int? = 5,
    source: String? = nil,
    title: String? = "Test"
) -> SessionSummary {
    SessionSummary(
        id: id,
        title: title,
        preview: nil,
        startedAt: 1_000_000,
        messageCount: messageCount,
        source: source,
        lastActive: lastActive,
        cwd: nil
    )
}

private func makeStoredMessage(
    role: String = "assistant",
    content: String = "Hello"
) -> StoredMessage {
    StoredMessage(
        role: role,
        content: .string(content),
        timestamp: 1_000_000
    )
}

// MARK: - Mock fetchers

private final class MockListFetcher: SessionListFetcher, @unchecked Sendable {
    var sessions: [SessionSummary] = []
    func fetchSessionList() async throws -> [SessionSummary] { sessions }
}

private final class MockTranscriptFetcher: TranscriptFetcher, @unchecked Sendable {
    var messages: [StoredMessage] = []
    func fetchTranscript(sessionId: String) async throws -> [StoredMessage] { messages }
}

// MARK: - Migration Tests

final class CacheMigrationTests: XCTestCase {

    func testV1CreatesTables() async throws {
        let store = try makeInMemoryStore()
        // If tables don't exist, saving would throw
        let summary = makeSession(id: "s1")
        try await store.saveSessionList([summary], scope: testScope)
        let loaded = try await store.loadSessionList(scope: testScope)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].id, "s1")
    }

    func testV1StampsSchemaFingerprint() async throws {
        let store = try makeInMemoryStore()
        let version = try await store.readMeta(SyncMetaRecord.Key.schemaVersion)
        XCTAssertEqual(version, CacheSchema.currentFingerprint)
    }

    func testMigrationsIdempotent() throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let queue = try DatabaseQueue(configuration: config)
        // Apply v1 twice — must not throw
        XCTAssertNoThrow(try CacheSchema.makeV1Migrator().migrate(queue))
        XCTAssertNoThrow(try CacheSchema.makeV1Migrator().migrate(queue))
    }
}

// MARK: - Round-Trip Persistence Tests

final class CacheRoundTripTests: XCTestCase {

    func testSessionSummaryEncodesAndDecodes() throws {
        let original = makeSession(id: "abc", lastActive: 999.5, messageCount: 42, title: "My Session")
        let record = try SessionCacheRecord.make(from: original, scope: testScope)
        let decoded = try record.decodeSummary()
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.title, original.title)
        XCTAssertEqual(decoded.lastActive, original.lastActive)
        XCTAssertEqual(decoded.messageCount, original.messageCount)
    }

    func testStoredMessageMirrorRoundTripWithToolCalls() throws {
        let toolCall = WireToolCall(callId: "tc1", name: "bash", arguments: "{\"cmd\":\"ls\"}")
        let original = StoredMessage(
            role: "assistant",
            content: .string("Running tool"),
            timestamp: 12345.0,
            toolCalls: [toolCall],
            toolCallId: nil,
            toolName: nil,
            reasoning: "Let me run that",
            finishReason: "tool_calls"
        )
        let mirror = original.toMirror()
        let data = try JSONEncoder().encode(mirror)
        let decoded = try JSONDecoder().decode(StoredMessageMirror.self, from: data)
        let reconstructed = decoded.toStoredMessage()

        XCTAssertEqual(reconstructed.role, original.role)
        XCTAssertEqual(reconstructed.content, original.content)
        XCTAssertEqual(reconstructed.timestamp, original.timestamp)
        XCTAssertEqual(reconstructed.reasoning, original.reasoning)
        XCTAssertEqual(reconstructed.finishReason, original.finishReason)
        XCTAssertEqual(reconstructed.toolCalls?.count, 1)
        XCTAssertEqual(reconstructed.toolCalls?[0].callId, "tc1")
        XCTAssertEqual(reconstructed.toolCalls?[0].name, "bash")
    }

    func testTranscriptWriteReadRoundTripPreservesOrder() async throws {
        let store = try makeInMemoryStore()
        try await store.saveSessionList([makeSession(id: "sess1")], scope: testScope)

        let messages = [
            makeStoredMessage(role: "user", content: "Hello"),
            makeStoredMessage(role: "assistant", content: "World"),
            makeStoredMessage(role: "user", content: "Bye"),
        ]
        try await store.saveTranscript(sessionId: "sess1", messages: messages)

        let loaded = try await store.loadTranscript("sess1")
        XCTAssertEqual(loaded?.count, 3)
        XCTAssertEqual(loaded?[0].role, "user")
        XCTAssertEqual(loaded?[0].content, .string("Hello"))
        XCTAssertEqual(loaded?[1].role, "assistant")
        XCTAssertEqual(loaded?[2].content, .string("Bye"))
    }

    func testHasTranscriptLifecycle() async throws {
        let store = try makeInMemoryStore()
        try await store.saveSessionList([makeSession(id: "sess2")], scope: testScope)

        let before = try await store.hasTranscript("sess2")
        XCTAssertFalse(before)

        try await store.saveTranscript(sessionId: "sess2", messages: [makeStoredMessage()])

        let after = try await store.hasTranscript("sess2")
        XCTAssertTrue(after)
    }

    func testCronExclusion() async throws {
        let store = try makeInMemoryStore()
        let cronSession = makeSession(id: "cron1", source: "cron")
        try await store.saveSessionList([cronSession], scope: testScope)
        try await store.saveTranscript(sessionId: "cron1", messages: [makeStoredMessage()])

        let has = try await store.hasTranscript("cron1")
        XCTAssertFalse(has, "Cron sessions must never have transcript rows")
    }

    func testJSONValueComplexRoundTripThroughMirror() throws {
        let complex: JSONValue = .object([
            "key": .string("value"),
            "num": .number(42),
            "arr": .array([.bool(true), .null])
        ])
        let msg = StoredMessage(role: "user", content: complex)
        let mirror = msg.toMirror()
        let data = try JSONEncoder().encode(mirror)
        let decoded = try JSONDecoder().decode(StoredMessageMirror.self, from: data)
        let reconstructed = decoded.toStoredMessage()
        XCTAssertEqual(reconstructed.content, complex)
    }
}

// MARK: - Cursor Tests

final class CacheCursorTests: XCTestCase {

    func testMaxMessageIdAdvancesToHighestWireId() async throws {
        let store = try makeInMemoryStore()
        try await store.saveSessionList([makeSession(id: "s10")], scope: testScope)

        let messages = [makeStoredMessage(), makeStoredMessage(), makeStoredMessage()]
        let wireIds: [Int?] = [100, 200, 150]
        try await store.saveTranscript(sessionId: "s10", messages: messages, wireIds: wireIds)

        let cursor = try await store.maxMessageId(for: "s10")
        XCTAssertEqual(cursor, 200)
    }

    func testCursorNilWhenNoWireIdsProvided() async throws {
        let store = try makeInMemoryStore()
        try await store.saveSessionList([makeSession(id: "s11")], scope: testScope)
        try await store.saveTranscript(sessionId: "s11", messages: [makeStoredMessage()])

        let cursor = try await store.maxMessageId(for: "s11")
        XCTAssertNil(cursor)
    }

    func testMarkTranscriptDirtyClearsCursorAndCachedAt() async throws {
        let store = try makeInMemoryStore()
        try await store.saveSessionList([makeSession(id: "s12")], scope: testScope)
        try await store.saveTranscript(sessionId: "s12",
                                       messages: [makeStoredMessage()],
                                       wireIds: [500])

        let cursorBefore = try await store.maxMessageId(for: "s12")
        XCTAssertEqual(cursorBefore, 500)
        let hasBefore = try await store.hasTranscript("s12")
        XCTAssertTrue(hasBefore)

        try await store.markTranscriptDirty("s12")

        let cursorAfter = try await store.maxMessageId(for: "s12")
        XCTAssertNil(cursorAfter)
        let hasAfter = try await store.hasTranscript("s12")
        XCTAssertFalse(hasAfter)
    }
}

// MARK: - Eviction Tests

final class CacheEvictionTests: XCTestCase {

    func testRecentSessionNotEvicted() async throws {
        let store = try makeInMemoryStore()
        let recentTime = Date().timeIntervalSince1970 - (10 * 86400) // 10 days ago
        let session = makeSession(id: "recent1", lastActive: recentTime)
        try await store.saveSessionList([session], scope: testScope)
        try await store.saveTranscript(sessionId: "recent1", messages: [makeStoredMessage()])

        let evicted = try await store.evictStaleTranscripts(horizonDays: 365)
        XCTAssertEqual(evicted, 0)
        let hasRecent = try await store.hasTranscript("recent1")
        XCTAssertTrue(hasRecent)
    }

    func testOldNonPinnedSessionTranscriptIsEvicted() async throws {
        let store = try makeInMemoryStore()
        let oldTime = Date().timeIntervalSince1970 - (400 * 86400) // 400 days ago
        let session = makeSession(id: "old1", lastActive: oldTime)
        try await store.saveSessionList([session], scope: testScope)
        try await store.saveTranscript(sessionId: "old1", messages: [makeStoredMessage()])

        let evicted = try await store.evictStaleTranscripts(horizonDays: 365)
        XCTAssertGreaterThanOrEqual(evicted, 1)
        let hasOld1 = try await store.hasTranscript("old1")
        XCTAssertFalse(hasOld1, "Transcript for old session must be evicted")
    }

    func testSessionListRowPreservedAfterEviction() async throws {
        let store = try makeInMemoryStore()
        let oldTime = Date().timeIntervalSince1970 - (400 * 86400)
        let session = makeSession(id: "old2", lastActive: oldTime)
        try await store.saveSessionList([session], scope: testScope)
        try await store.saveTranscript(sessionId: "old2", messages: [makeStoredMessage()])

        try await store.evictStaleTranscripts(horizonDays: 365)

        // Session-list row must persist (drawer still shows it)
        let list = try await store.loadSessionList(scope: testScope)
        XCTAssertNotNil(list.first(where: { $0.id == "old2" }),
                        "Session list row must survive eviction")
        // Transcript must be gone
        let hasOld2 = try await store.hasTranscript("old2")
        XCTAssertFalse(hasOld2)
    }

    func testMixedEviction_OldEvictedRecentSpared() async throws {
        let store = try makeInMemoryStore()
        let oldTime = Date().timeIntervalSince1970 - (400 * 86400)
        let recentTime = Date().timeIntervalSince1970 - (5 * 86400)

        try await store.saveSessionList([
            makeSession(id: "evict_me", lastActive: oldTime),
            makeSession(id: "keep_me", lastActive: recentTime),
        ], scope: testScope)
        try await store.saveTranscript(sessionId: "evict_me", messages: [makeStoredMessage()])
        try await store.saveTranscript(sessionId: "keep_me", messages: [makeStoredMessage()])

        try await store.evictStaleTranscripts(horizonDays: 365)

        let hasEvicted = try await store.hasTranscript("evict_me")
        XCTAssertFalse(hasEvicted)
        let hasKept = try await store.hasTranscript("keep_me")
        XCTAssertTrue(hasKept)
    }
}

// MARK: - List Diff Tests

final class SyncEngineListDiffTests: XCTestCase {

    private func makeEngine() throws -> (SyncEngine, MockListFetcher, MockTranscriptFetcher) {
        let store = try makeInMemoryStore()
        let listFetcher = MockListFetcher()
        let txFetcher = MockTranscriptFetcher()
        let engine = SyncEngine(
            cache: store,
            listFetcher: listFetcher,
            transcriptFetcher: txFetcher,
            scope: testScope
        )
        return (engine, listFetcher, txFetcher)
    }

    func testNewSessionClassifiedAsAdded() async throws {
        let (engine, _, _) = try makeEngine()
        let live = [makeSession(id: "new1")]
        let diff = try await engine.diffSessionList(live)
        XCTAssertTrue(diff.added.contains(where: { $0.id == "new1" }))
        XCTAssertTrue(diff.dirty.isEmpty)
    }

    func testChangedLastActiveMarksDirty() async throws {
        let (engine, listFetcher, _) = try makeEngine()
        listFetcher.sessions = [makeSession(id: "s1", lastActive: 100, messageCount: 5)]
        try await engine.syncSessionList()

        let updated = [makeSession(id: "s1", lastActive: 200, messageCount: 6)]
        let diff = try await engine.diffSessionList(updated)
        XCTAssertTrue(diff.dirty.contains(where: { $0.id == "s1" }))
        XCTAssertTrue(diff.added.isEmpty)
        XCTAssertTrue(diff.unchanged.isEmpty)
    }

    func testIdenticalRowClassifiedAsUnchanged() async throws {
        let (engine, listFetcher, _) = try makeEngine()
        listFetcher.sessions = [makeSession(id: "s2", lastActive: 100, messageCount: 5, title: "Same")]
        try await engine.syncSessionList()

        let same = [makeSession(id: "s2", lastActive: 100, messageCount: 5, title: "Same")]
        let diff = try await engine.diffSessionList(same)
        XCTAssertTrue(diff.unchanged.contains(where: { $0.id == "s2" }))
        XCTAssertTrue(diff.dirty.isEmpty)
    }

    func testAbsentSessionsAppearInRemoved() async throws {
        let (engine, listFetcher, _) = try makeEngine()
        listFetcher.sessions = [
            makeSession(id: "a", lastActive: 100),
            makeSession(id: "b", lastActive: 100),
        ]
        try await engine.syncSessionList()

        let live = [makeSession(id: "a", lastActive: 100)]
        let diff = try await engine.diffSessionList(live)
        XCTAssertTrue(diff.removed.contains("b"))
        XCTAssertFalse(diff.removed.contains("a"))
    }

    func testMixedDiffAllClassifications() async throws {
        let (engine, listFetcher, _) = try makeEngine()
        listFetcher.sessions = [
            makeSession(id: "keep",   lastActive: 100, messageCount: 5),
            makeSession(id: "change", lastActive: 100, messageCount: 5),
            makeSession(id: "drop",   lastActive: 100, messageCount: 5),
        ]
        try await engine.syncSessionList()

        let live = [
            makeSession(id: "keep",      lastActive: 100, messageCount: 5),
            makeSession(id: "change",    lastActive: 200, messageCount: 6),
            makeSession(id: "brand_new", lastActive: 300),
        ]
        let diff = try await engine.diffSessionList(live)
        XCTAssertTrue(diff.unchanged.contains(where: { $0.id == "keep" }))
        XCTAssertTrue(diff.dirty.contains(where: { $0.id == "change" }))
        XCTAssertTrue(diff.added.contains(where: { $0.id == "brand_new" }))
        XCTAssertTrue(diff.removed.contains("drop"))
    }
}

// MARK: - Broadcast Frame Tests

final class SyncEngineBroadcastTests: XCTestCase {

    func testMessageCompleteMarksDirty() async throws {
        let store = try makeInMemoryStore()
        let engine = SyncEngine(
            cache: store,
            listFetcher: MockListFetcher(),
            transcriptFetcher: MockTranscriptFetcher(),
            scope: testScope
        )
        await engine.applyBroadcastFrame(.messageComplete(sessionId: "sess99"))
        let dirty = await engine.isDirty("sess99")
        XCTAssertTrue(dirty)
    }

    func testMessageDeltaIsIgnored() async throws {
        let store = try makeInMemoryStore()
        let engine = SyncEngine(
            cache: store,
            listFetcher: MockListFetcher(),
            transcriptFetcher: MockTranscriptFetcher(),
            scope: testScope
        )
        await engine.applyBroadcastFrame(.messageDelta)
        let snapshot = await engine.dirtySnapshot()
        XCTAssertTrue(snapshot.isEmpty)
    }
}

// MARK: - Eviction Throttle Tests

final class SyncEngineEvictionThrottleTests: XCTestCase {

    func testEvictionThrottledAfterRecentRun() async throws {
        let store = try makeInMemoryStore()
        let engine = SyncEngine(
            cache: store,
            listFetcher: MockListFetcher(),
            transcriptFetcher: MockTranscriptFetcher(),
            scope: testScope
        )

        // First run stamps the timestamp
        try await engine.runEvictionIfNeeded()
        let first = try await store.readMeta(SyncMetaRecord.Key.evictionLastRunAt)
        XCTAssertNotNil(first)

        // Stamp a "just ran" time so the second call is throttled
        let justNow = String(Date().timeIntervalSince1970)
        try await store.writeMeta(SyncMetaRecord.Key.evictionLastRunAt, value: justNow)

        // Second call should be a no-op (throttled); lastRunAt unchanged
        try await engine.runEvictionIfNeeded()
        let second = try await store.readMeta(SyncMetaRecord.Key.evictionLastRunAt)
        XCTAssertEqual(second, justNow, "Throttled: second run must not overwrite the timestamp")
    }
}

// MARK: - Lazy Transcript Tests

final class SyncEngineEnsureTranscriptTests: XCTestCase {

    func testEnsureTranscriptFetchesAndCachesOnFirstCall() async throws {
        let store = try makeInMemoryStore()
        try await store.saveSessionList([makeSession(id: "et1")], scope: testScope)

        let txFetcher = MockTranscriptFetcher()
        txFetcher.messages = [makeStoredMessage(role: "user", content: "cached content")]

        let engine = SyncEngine(
            cache: store,
            listFetcher: MockListFetcher(),
            transcriptFetcher: txFetcher,
            scope: testScope
        )
        let messages = try await engine.ensureTranscript(sessionId: "et1")

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].content, .string("cached content"))
        let hasEt1 = try await store.hasTranscript("et1")
        XCTAssertTrue(hasEt1)
    }

    func testEnsureTranscriptReturnsCachedWithoutFetchWhenClean() async throws {
        let store = try makeInMemoryStore()
        try await store.saveSessionList([makeSession(id: "et2")], scope: testScope)

        let stale = MockTranscriptFetcher()
        stale.messages = [makeStoredMessage(role: "assistant", content: "stale")]
        let seedEngine = SyncEngine(
            cache: store,
            listFetcher: MockListFetcher(),
            transcriptFetcher: stale,
            scope: testScope
        )
        _ = try await seedEngine.ensureTranscript(sessionId: "et2")

        // A fresh engine with different content — NOT dirty, so cache wins
        let fresh = MockTranscriptFetcher()
        fresh.messages = [makeStoredMessage(role: "assistant", content: "fresh")]
        let engine = SyncEngine(cache: store, listFetcher: MockListFetcher(), transcriptFetcher: fresh, scope: testScope)

        let messages = try await engine.ensureTranscript(sessionId: "et2")
        XCTAssertEqual(messages[0].content, .string("stale"),
                       "Clean cache must be served without hitting the network")
    }

    func testEnsureTranscriptRefetchesWhenDirty() async throws {
        let store = try makeInMemoryStore()
        try await store.saveSessionList([makeSession(id: "et3")], scope: testScope)

        let stale = MockTranscriptFetcher()
        stale.messages = [makeStoredMessage(role: "assistant", content: "stale")]
        let seedEngine = SyncEngine(
            cache: store,
            listFetcher: MockListFetcher(),
            transcriptFetcher: stale,
            scope: testScope
        )
        _ = try await seedEngine.ensureTranscript(sessionId: "et3")

        // Now set up fresh engine AND mark dirty
        let fresh = MockTranscriptFetcher()
        fresh.messages = [makeStoredMessage(role: "assistant", content: "updated")]
        let engine = SyncEngine(cache: store, listFetcher: MockListFetcher(), transcriptFetcher: fresh, scope: testScope)
        await engine.markDirty("et3")

        let messages = try await engine.ensureTranscript(sessionId: "et3")
        XCTAssertEqual(messages[0].content, .string("updated"),
                       "Dirty session must re-fetch from the gateway")
    }
}

// MARK: - Scope (P4) Tests
//
// Per-(server, profile) scoping: profile switch (same server) keeps both
// profiles' rows isolated; server switch clears other servers' rows; the v2
// migration backfills legacy rows to the sentinel scope; cache-miss for the
// active scope is empty (byte-identical to today's cold-launch behavior).

final class CacheScopeNormalizationTests: XCTestCase {

    func testBlankProfileNormalizesToAll() {
        XCTAssertEqual(CacheScope(serverId: "s", profileId: "").profileId, "all")
        XCTAssertEqual(CacheScope(serverId: "s", profileId: "   ").profileId, "all")
    }

    func testAllSentinelStaysAll() {
        XCTAssertEqual(CacheScope(serverId: "s", profileId: "all").profileId, "all")
    }

    func testNamedProfilePreserved() {
        XCTAssertEqual(CacheScope(serverId: "s", profileId: "work").profileId, "work")
        XCTAssertEqual(CacheScope(serverId: "s", profileId: "default").profileId, "default")
    }

    func testServerIdTrimmed() {
        XCTAssertEqual(CacheScope(serverId: "  https://host  ", profileId: "all").serverId, "https://host")
    }
}

final class CacheScopePartitionTests: XCTestCase {

    private let serverA = "https://a.example"
    private let serverB = "https://b.example"

    func testProfilesCoexistIsolatedOnSameServer() async throws {
        let store = try makeInMemoryStore()
        let workScope = CacheScope(serverId: serverA, profileId: "work")
        let homeScope = CacheScope(serverId: serverA, profileId: "home")

        try await store.saveSessionList([makeSession(id: "w1"), makeSession(id: "w2")], scope: workScope)
        try await store.saveSessionList([makeSession(id: "h1")], scope: homeScope)

        let work = try await store.loadSessionList(scope: workScope)
        let home = try await store.loadSessionList(scope: homeScope)

        XCTAssertEqual(Set(work.map(\.id)), ["w1", "w2"])
        XCTAssertEqual(Set(home.map(\.id)), ["h1"])
    }

    func testAggregateScopeIsolatedFromNamedProfile() async throws {
        let store = try makeInMemoryStore()
        let allScope = CacheScope(serverId: serverA, profileId: "all")
        let namedScope = CacheScope(serverId: serverA, profileId: "client-x")

        try await store.saveSessionList([makeSession(id: "agg1")], scope: allScope)
        try await store.saveSessionList([makeSession(id: "named1")], scope: namedScope)

        let agg = try await store.loadSessionList(scope: allScope)
        let named = try await store.loadSessionList(scope: namedScope)
        XCTAssertEqual(agg.map(\.id), ["agg1"])
        XCTAssertEqual(named.map(\.id), ["named1"])
    }

    func testServersIsolated() async throws {
        let store = try makeInMemoryStore()
        let scopeA = CacheScope(serverId: serverA, profileId: "all")
        let scopeB = CacheScope(serverId: serverB, profileId: "all")

        try await store.saveSessionList([makeSession(id: "a1"), makeSession(id: "a2")], scope: scopeA)
        try await store.saveSessionList([makeSession(id: "b1")], scope: scopeB)

        let a = try await store.loadSessionList(scope: scopeA)
        let b = try await store.loadSessionList(scope: scopeB)
        XCTAssertEqual(Set(a.map(\.id)), ["a1", "a2"])
        XCTAssertEqual(Set(b.map(\.id)), ["b1"])
    }

    func testMissForActiveScopeIsEmpty() async throws {
        // Cache-miss == today's cold-launch behavior: loading a never-written
        // scope returns an empty list (not another scope's rows).
        let store = try makeInMemoryStore()
        try await store.saveSessionList([makeSession(id: "x1")],
                                        scope: CacheScope(serverId: serverA, profileId: "all"))
        let miss = try await store.loadSessionList(scope: CacheScope(serverId: serverB, profileId: "all"))
        XCTAssertTrue(miss.isEmpty)
    }

    func testClearOtherServersKeepsActiveAndDropsOthers() async throws {
        let store = try makeInMemoryStore()
        let scopeA = CacheScope(serverId: serverA, profileId: "all")
        let scopeB = CacheScope(serverId: serverB, profileId: "work")

        try await store.saveSessionList([makeSession(id: "a1")], scope: scopeA)
        try await store.saveSessionList([makeSession(id: "b1")], scope: scopeB)

        let deleted = try await store.clearSessionsForOtherServers(keepingServerId: serverA)
        XCTAssertEqual(deleted, 1, "Only the other server's row is deleted")

        let keptA = try await store.loadSessionList(scope: scopeA)
        let clearedB = try await store.loadSessionList(scope: scopeB)
        XCTAssertEqual(keptA.map(\.id), ["a1"])
        XCTAssertTrue(clearedB.isEmpty)
    }

    func testClearOtherServersCascadesTranscripts() async throws {
        let store = try makeInMemoryStore()
        let scopeA = CacheScope(serverId: serverA, profileId: "all")
        let scopeB = CacheScope(serverId: serverB, profileId: "all")

        try await store.saveSessionList([makeSession(id: "a1")], scope: scopeA)
        try await store.saveSessionList([makeSession(id: "b1")], scope: scopeB)
        try await store.saveTranscript(sessionId: "b1", messages: [makeStoredMessage()])
        let hadB1 = try await store.hasTranscript("b1")
        XCTAssertTrue(hadB1)

        try await store.clearSessionsForOtherServers(keepingServerId: serverA)

        // b1's session row is gone, so its transcript rows cascaded away too.
        let hasB1 = try await store.hasTranscript("b1")
        XCTAssertFalse(hasB1, "FK cascade must drop the other server's transcript rows")
    }

    func testProfileSwitchPreservesInstantPaintForBothScopes() async throws {
        // The instant-paint guarantee for a profile switch: after writing both
        // profiles, switching back and forth re-reads each profile's rows from
        // disk with no clear — no network needed.
        let store = try makeInMemoryStore()
        let p1 = CacheScope(serverId: serverA, profileId: "p1")
        let p2 = CacheScope(serverId: serverA, profileId: "p2")
        try await store.saveSessionList([makeSession(id: "one")], scope: p1)
        try await store.saveSessionList([makeSession(id: "two")], scope: p2)

        // Switch p1 -> p2 -> p1: each read still has its rows.
        let first = try await store.loadSessionList(scope: p1)
        let second = try await store.loadSessionList(scope: p2)
        let third = try await store.loadSessionList(scope: p1)
        XCTAssertEqual(first.map(\.id), ["one"])
        XCTAssertEqual(second.map(\.id), ["two"])
        XCTAssertEqual(third.map(\.id), ["one"])
    }

    func testUpsertRestampsScopeWhenRowMovesProfiles() async throws {
        // A session id is globally unique; if the same id is upserted under a new
        // profile scope (the aggregate rail tags rows with their own profile), the
        // row's scope follows the active scope it was last written under.
        let store = try makeInMemoryStore()
        let p1 = CacheScope(serverId: serverA, profileId: "p1")
        let p2 = CacheScope(serverId: serverA, profileId: "p2")
        try await store.upsertSession(makeSession(id: "moving"), scope: p1)
        let inP1 = try await store.loadSessionList(scope: p1)
        XCTAssertEqual(inP1.map(\.id), ["moving"])

        try await store.upsertSession(makeSession(id: "moving"), scope: p2)
        let leftP1 = try await store.loadSessionList(scope: p1)
        let movedP2 = try await store.loadSessionList(scope: p2)
        XCTAssertTrue(leftP1.isEmpty, "Row left the old profile scope")
        XCTAssertEqual(movedP2.map(\.id), ["moving"])
    }
}

// MARK: - v2 Migration Tests

final class CacheV2MigrationTests: XCTestCase {

    func testV2StampsFingerprintV2() async throws {
        let store = try makeInMemoryStore()
        let version = try await store.readMeta(SyncMetaRecord.Key.schemaVersion)
        XCTAssertEqual(version, "v2")
        XCTAssertEqual(CacheSchema.currentFingerprint, "v2")
    }

    func testV2ScopeColumnsExistAndAreQueryable() async throws {
        // A scoped save+load round-trip exercises the v2 columns + index; a
        // missing column would throw on bind.
        let store = try makeInMemoryStore()
        let scope = CacheScope(serverId: "https://x", profileId: "y")
        try await store.saveSessionList([makeSession(id: "m1")], scope: scope)
        let loaded = try await store.loadSessionList(scope: scope)
        XCTAssertEqual(loaded.map(\.id), ["m1"])
    }

    func testLegacyV1RowsBackfilledToSentinelScope() throws {
        // Build a v1-only DB (the OLD migrator state), insert a row WITHOUT scope
        // columns, then apply the full migrator (v1+v2). The legacy row must
        // survive, carry the sentinel scope, and be invisible to any real scope.
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let queue = try DatabaseQueue(configuration: config)

        // Apply ONLY v1 by registering the same v1 block the shipped schema uses.
        // We re-create the v1 table shape directly to simulate a pre-v2 DB.
        try queue.write { db in
            try db.create(table: "session_cache", ifNotExists: true) { t in
                t.primaryKey("id", .text)
                t.column("summaryJSON", .blob).notNull()
                t.column("lastActive", .double)
                t.column("messageCount", .integer)
                t.column("source", .text)
                t.column("archived", .boolean).notNull().defaults(to: false)
                t.column("isPinned", .boolean).notNull().defaults(to: false)
                t.column("lastAccessedAt", .double).notNull().defaults(to: 0)
                t.column("transcriptCachedAt", .double)
                t.column("maxMessageId", .integer)
            }
            try db.create(table: "sync_meta", ifNotExists: true) { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
            // Mark v1 as applied so the migrator only runs v2 on top.
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            try db.execute(sql: "INSERT OR IGNORE INTO grdb_migrations(identifier) VALUES ('v1')")
            // A legacy row with no scope columns yet.
            let summaryData = try JSONEncoder().encode(makeSession(id: "legacy1"))
            try db.execute(
                sql: "INSERT INTO session_cache (id, summaryJSON, lastActive, archived, isPinned, lastAccessedAt) VALUES (?, ?, ?, 0, 0, 0)",
                arguments: ["legacy1", summaryData, 100.0]
            )
        }

        // Apply v2 on top.
        try CacheSchema.makeMigrator().migrate(queue)

        // The legacy row's scope columns were backfilled to the sentinel.
        let (serverId, profileId): (String, String) = try queue.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT serverId, profileId FROM session_cache WHERE id = 'legacy1'")
            return (row?["serverId"] ?? "", row?["profileId"] ?? "")
        }
        XCTAssertEqual(serverId, CacheScope.legacy.serverId)
        XCTAssertEqual(profileId, CacheScope.legacy.profileId)
    }
}
