import XCTest
import Foundation
import GRDB
@testable import HermesMobile

// MARK: - CacheLayerTests
//
// Unit tests for the CacheStore actor (P1) + the WhatsApp-bar additions.
// All tests use in-memory DatabaseQueues — no filesystem access, no live gateway.
//
// Covered:
//   - Round-trip persistence: write page -> read back identical (ordinal order)
//   - Cursor advance: maxMessageId tracks across saves
//   - Eviction: recent sessions exempt, old sessions evicted, session row preserved
//   - Migration v1: tables + fingerprint created; idempotent second apply
//   - Cron-exclusion: cron sessions never get transcript rows
//   - Eviction throttle: second call within 24h is a no-op (CacheStore-native)
//   - Transcript freshness: the prefetch skip-gate (transcriptIsFresh)

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

// MARK: - Eviction Throttle Tests (CacheStore-native — WhatsApp bar hygiene)
//
// The throttle that previously lived in the never-wired `SyncEngine` now lives in
// `CacheStore.evictStaleTranscriptsIfNeeded`, which is actually called post-
// hydration. These tests pin its once/24h throttle directly on CacheStore.

final class CacheEvictionThrottleTests: XCTestCase {

    func testEvictionStampsTimestampOnFirstRun() async throws {
        let store = try makeInMemoryStore()
        let before = try await store.readMeta(SyncMetaRecord.Key.evictionLastRunAt)
        XCTAssertNil(before)

        _ = try await store.evictStaleTranscriptsIfNeeded()
        let stamped = try await store.readMeta(SyncMetaRecord.Key.evictionLastRunAt)
        XCTAssertNotNil(stamped, "First eviction run must stamp the lastRunAt timestamp")
    }

    func testEvictionThrottledAfterRecentRun() async throws {
        let store = try makeInMemoryStore()

        // Stamp a "just ran" time so the next call is throttled.
        let justNow = String(Date().timeIntervalSince1970)
        try await store.writeMeta(SyncMetaRecord.Key.evictionLastRunAt, value: justNow)

        // The throttled call is a no-op and must not overwrite the timestamp.
        let evicted = try await store.evictStaleTranscriptsIfNeeded()
        XCTAssertEqual(evicted, 0, "A throttled run evicts nothing")
        let after = try await store.readMeta(SyncMetaRecord.Key.evictionLastRunAt)
        XCTAssertEqual(after, justNow, "Throttled: second run must not overwrite the timestamp")
    }

    func testEvictionRunsAfter24h() async throws {
        let store = try makeInMemoryStore()
        // Seed an OLD (non-pinned, stale) session whose transcript should evict.
        try await store.saveSessionList(
            [makeSession(id: "ancient", lastActive: 1)], scope: testScope)
        try await store.saveTranscript(
            sessionId: "ancient",
            messages: [makeStoredMessage(content: "old")])
        let hadAncient = try await store.hasTranscript("ancient")
        XCTAssertTrue(hadAncient)

        // Stamp lastRunAt to >24h ago so the throttle lets the sweep proceed.
        let twoDaysAgo = String(Date().timeIntervalSince1970 - 2 * 86400)
        try await store.writeMeta(SyncMetaRecord.Key.evictionLastRunAt, value: twoDaysAgo)

        let evicted = try await store.evictStaleTranscriptsIfNeeded(horizonDays: 365)
        XCTAssertEqual(evicted, 1, "A >24h-old throttle window must let the sweep run")
        let hasAncient = try await store.hasTranscript("ancient")
        XCTAssertFalse(hasAncient, "The stale transcript body is evicted")
    }
}

// MARK: - Transcript freshness (WhatsApp bar prefetch skip-gate)

final class CacheTranscriptFreshnessTests: XCTestCase {

    func testFreshWhenCachedAfterLastActive() async throws {
        let store = try makeInMemoryStore()
        try await store.saveSessionList(
            [makeSession(id: "f1", lastActive: 100)], scope: testScope)
        // saveTranscript stamps transcriptCachedAt = now (>> 100), so it is fresh.
        try await store.saveTranscript(
            sessionId: "f1", messages: [makeStoredMessage()])
        let fresh = try await store.transcriptIsFresh("f1", lastActive: 100)
        XCTAssertTrue(fresh)
    }

    func testStaleWhenLastActiveAdvancedPastCache() async throws {
        let store = try makeInMemoryStore()
        try await store.saveSessionList(
            [makeSession(id: "f2", lastActive: 1)], scope: testScope)
        try await store.saveTranscript(
            sessionId: "f2", messages: [makeStoredMessage()])
        // A NEW turn lands far in the future, after the cache stamp → stale.
        let future = Date().timeIntervalSince1970 + 10_000
        let fresh = try await store.transcriptIsFresh("f2", lastActive: future)
        XCTAssertFalse(fresh)
    }

    func testNotFreshWhenNoTranscript() async throws {
        let store = try makeInMemoryStore()
        try await store.saveSessionList(
            [makeSession(id: "f3", lastActive: 100)], scope: testScope)
        // Session row exists but no transcript was ever cached.
        let fresh = try await store.transcriptIsFresh("f3", lastActive: 100)
        XCTAssertFalse(fresh)
    }

    func testNilLastActiveFallsBackToHasTranscript() async throws {
        let store = try makeInMemoryStore()
        try await store.saveSessionList(
            [makeSession(id: "f4", lastActive: nil)], scope: testScope)
        try await store.saveTranscript(
            sessionId: "f4", messages: [makeStoredMessage()])
        // Can't prove staleness without lastActive → "has any transcript" wins.
        let fresh = try await store.transcriptIsFresh("f4", lastActive: nil)
        XCTAssertTrue(fresh)
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
