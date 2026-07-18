import XCTest
import Foundation
import GRDB
@testable import HermesMobile

// MARK: - RepairSupersedesForgetTests
//
// LANE A — a STALE forget-tombstone must not suppress a RE-PAIRED server's cache.
//
// Ground truth (owner's device, 2026-07-18): a populated session cache for a
// currently-paired server, but `hermes.gatewayCleanupTombstone` still carried a
// PRIOR device's forget (`remoteRetryNeeded:true`) whose device id no longer
// matched the live pairing. Cold-open offline painted an empty "Not connected"
// drawer over that cache.
//
// These tests lock the whole-class fix:
//   1. Re-pairing under a NEW device supersedes forget: the cache-suppression is
//      void (cache paints), only the remote revoke of the OLD device is kept.
//   2. A tombstone whose device equals the current pairing keeps real forget
//      semantics (cache suppressed).
//   3. Offline open of a never-cached session shows a neutral empty state, not a
//      network error.
//
// Hermetic: in-memory CacheStore, injected fetch seams, no live gateway.

@MainActor
final class RepairSupersedesForgetTests: XCTestCase {

    private let server = "https://abbhinnavs-mac-studio.example:9443"
    private var savedServerURL: String?
    private var savedActiveProfile: String?

    override func setUp() {
        super.setUp()
        let d = UserDefaults.standard
        savedServerURL = d.string(forKey: DefaultsKeys.serverURL)
        savedActiveProfile = d.string(forKey: DefaultsKeys.activeProfile)
        d.removeObject(forKey: DefaultsKeys.serverURL)
        d.removeObject(forKey: DefaultsKeys.gatewayCleanupTombstone)
        d.set(DefaultsKeys.allProfilesScope, forKey: DefaultsKeys.activeProfile)
        DefaultsKeys.setDeviceId(nil, server: server)
        KeychainService.deleteToken(server: server)
    }

    override func tearDown() {
        let d = UserDefaults.standard
        d.removeObject(forKey: DefaultsKeys.gatewayCleanupTombstone)
        DefaultsKeys.setDeviceId(nil, server: server)
        KeychainService.deleteToken(server: server)
        if let savedServerURL { d.set(savedServerURL, forKey: DefaultsKeys.serverURL) }
        else { d.removeObject(forKey: DefaultsKeys.serverURL) }
        if let savedActiveProfile { d.set(savedActiveProfile, forKey: DefaultsKeys.activeProfile) }
        else { d.removeObject(forKey: DefaultsKeys.activeProfile) }
        super.tearDown()
    }

    // MARK: Harness

    private func makeInMemoryCache() throws -> CacheStore {
        var config = Configuration()
        config.prepareDatabase { db in try db.execute(sql: "PRAGMA foreign_keys = ON") }
        return try CacheStore(testDB: try DatabaseQueue(configuration: config))
    }

    private func makeGraph() -> (ConnectionStore, SessionStore, ChatStore) {
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        let attachments = AttachmentStore()
        chat.attach(connection: connection, sessions: sessions, attachments: attachments)
        sessions.attach(connection: connection, chat: chat)
        return (connection, sessions, chat)
    }

    private func makeSummary(_ id: String) -> SessionSummary {
        SessionSummary(
            id: id, title: "T-\(id)", preview: nil, startedAt: 1_000,
            messageCount: 3, source: "ios", lastActive: 100, cwd: nil, profile: nil
        )
    }

    private func writeTombstone(_ tombstone: GatewayCleanupTombstone) throws {
        let data = try JSONEncoder().encode(tombstone)
        UserDefaults.standard.set(data, forKey: DefaultsKeys.gatewayCleanupTombstone)
    }

    private func readTombstone() -> GatewayCleanupTombstone? {
        ConnectionStore.pendingCleanupTombstone(.standard)
    }

    // MARK: - Pure decision

    func testDecisionRepairedUnderNewDeviceVoidsSuppressionKeepsRevoke() {
        let decision = GatewayForgetCoordinator.evaluate(
            tombstone: GatewayCleanupTombstone(server: server, deviceId: "dev_OLD", remoteRetryNeeded: true),
            currentDeviceId: "dev_NEW",
            hasLivePairing: true
        )
        XCTAssertFalse(decision.suppressesCache, "a re-pair under a new device must void cache-suppression")
        XCTAssertEqual(decision.remoteRevokeDeviceId, "dev_OLD", "the OLD device is still owed a remote revoke")
        XCTAssertEqual(decision.rewrite, .supersede)
    }

    func testDecisionRepairedWithNoOwedRevokeRemovesTombstone() {
        let decision = GatewayForgetCoordinator.evaluate(
            tombstone: GatewayCleanupTombstone(server: server, deviceId: "dev_OLD", remoteRetryNeeded: false),
            currentDeviceId: "dev_NEW",
            hasLivePairing: true
        )
        XCTAssertFalse(decision.suppressesCache)
        XCTAssertNil(decision.remoteRevokeDeviceId)
        XCTAssertEqual(decision.rewrite, .remove, "nothing owed remotely — the tombstone has no remaining purpose")
    }

    func testDecisionSameDeviceKeepsForgetSemantics() {
        let decision = GatewayForgetCoordinator.evaluate(
            tombstone: GatewayCleanupTombstone(server: server, deviceId: "dev_CUR", remoteRetryNeeded: true),
            currentDeviceId: "dev_CUR",
            hasLivePairing: true
        )
        XCTAssertTrue(decision.suppressesCache, "the tombstone's device IS the current pairing — real forget stays")
        XCTAssertEqual(decision.rewrite, .keep)
    }

    func testDecisionNoLivePairingKeepsForgetSemantics() {
        let decision = GatewayForgetCoordinator.evaluate(
            tombstone: GatewayCleanupTombstone(server: server, deviceId: "dev_OLD", remoteRetryNeeded: true),
            currentDeviceId: "dev_NEW",
            hasLivePairing: false
        )
        XCTAssertTrue(decision.suppressesCache, "no live credential — this is a genuine pending forget")
        XCTAssertEqual(decision.rewrite, .keep)
    }

    // MARK: - Backward compatibility of the tombstone wire format

    func testLegacyTombstoneWithoutSupersededKeyStillDecodes() throws {
        // A tombstone persisted by an older build (no `supersededByRepair` key)
        // must decode, not be silently dropped — dropping it forfeits the owed
        // remote revoke.
        let legacy = #"{"server":"\#(server)","deviceId":"dev_OLD","remoteRetryNeeded":true}"#
        let decoded = try JSONDecoder().decode(GatewayCleanupTombstone.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.server, server)
        XCTAssertEqual(decoded.deviceId, "dev_OLD")
        XCTAssertTrue(decoded.remoteRetryNeeded)
        XCTAssertFalse(decoded.supersededByRepair)
    }

    // MARK: - Launch reconciliation: re-paired server -> cache paints

    func testRepairedServerColdOpenPaintsCacheAndKeepsRevokeRetry() async throws {
        let d = UserDefaults.standard
        // Currently paired to `server` under a NEW device (re-paired after the
        // forget), with the stale tombstone from the OLD device still resident.
        d.set(server, forKey: DefaultsKeys.serverURL)
        DefaultsKeys.setDeviceId("dev_NEW", server: server)
        try KeychainService.saveToken("live-token", server: server)
        try writeTombstone(GatewayCleanupTombstone(
            server: server, deviceId: "dev_OLD", remoteRetryNeeded: true
        ))

        let (connection, sessions, _) = makeGraph()
        let cache = try makeInMemoryCache()
        sessions.attachCache(cache)
        connection.serverURLString = server
        let scope = CacheScope(serverId: server, profileId: DefaultsKeys.allProfilesScope)
        try await cache.saveSessionList([makeSummary("s1"), makeSummary("s2")], scope: scope)

        // The launch reconciler must NOT resume a forget for a re-paired server.
        let resumed = await connection.reconcilePendingForgetTombstone()
        XCTAssertFalse(resumed, "re-pairing supersedes forget — bootstrap must not abort into forget")

        // Cache-first paint proceeds and the drawer fills from disk.
        await sessions.paintFromCache()
        XCTAssertEqual(Set(sessions.sessions.map(\.id)), ["s1", "s2"],
                       "the re-paired server's cache must paint")

        // The tombstone is rewritten to its superseded, retry-only form: cache
        // suppression is void, the OLD device's remote revoke is still owed.
        let after = readTombstone()
        XCTAssertNotNil(after, "the owed remote revoke of the old device must survive")
        XCTAssertEqual(after?.deviceId, "dev_OLD")
        XCTAssertTrue(after?.remoteRetryNeeded == true, "revoke retry for the old token stays queued")
        XCTAssertTrue(after?.supersededByRepair == true)
        // The live pairing is untouched.
        XCTAssertEqual(d.string(forKey: DefaultsKeys.serverURL), server)
        XCTAssertEqual(KeychainService.loadToken(server: server), "live-token")
    }

    func testRepairedServerReconcileIsIdempotent() async throws {
        let d = UserDefaults.standard
        d.set(server, forKey: DefaultsKeys.serverURL)
        DefaultsKeys.setDeviceId("dev_NEW", server: server)
        try KeychainService.saveToken("live-token", server: server)
        try writeTombstone(GatewayCleanupTombstone(
            server: server, deviceId: "dev_OLD", remoteRetryNeeded: true
        ))
        let (connection, _, _) = makeGraph()

        _ = await connection.reconcilePendingForgetTombstone()
        _ = await connection.reconcilePendingForgetTombstone()

        let after = readTombstone()
        XCTAssertEqual(after?.deviceId, "dev_OLD")
        XCTAssertTrue(after?.supersededByRepair == true)
        XCTAssertEqual(d.string(forKey: DefaultsKeys.serverURL), server)
    }

    // MARK: - Launch reconciliation: genuine forget -> cache suppressed

    func testPendingForgetForCurrentDeviceResumesAndSuppressesCache() async throws {
        let d = UserDefaults.standard
        // Post-forget state: URL + Keychain cleared, tombstone owed for the device
        // that was actually forgotten. No live pairing => forget semantics stay.
        d.removeObject(forKey: DefaultsKeys.serverURL)
        try writeTombstone(GatewayCleanupTombstone(
            server: server, deviceId: "dev_CUR", remoteRetryNeeded: false
        ))
        let (connection, sessions, _) = makeGraph()
        // Seed an in-memory drawer to prove the forget clears it.
        sessions.sessions = [makeSummary("stale")]

        let resumed = await connection.reconcilePendingForgetTombstone()

        XCTAssertTrue(resumed, "a genuine pending forget resumes and aborts bootstrap")
        XCTAssertTrue(sessions.sessions.isEmpty, "forget suppresses/clears the cache")
        XCTAssertEqual(connection.phase, .needsSetup)
    }

    // MARK: - Honest offline empty state (#4)

    func testOfflineNeverCachedSessionShowsNeutralEmptyNotError() {
        // Offline + empty, pristine transcript + a stale backfill error: the
        // offline signal must win with the neutral empty state.
        let placeholder = ChatView.transcriptPlaceholder(
            isDraft: false,
            messagesEmpty: true,
            transcriptGeneration: 0,
            isGatewayOffline: true,
            loadError: "Not connected to the Hermes gateway"
        )
        XCTAssertEqual(placeholder, .offlineNoCache,
                       "offline open of a never-cached session is a neutral empty, not a network error")
    }

    func testOnlineLoadFailureShowsErrorScreen() {
        let placeholder = ChatView.transcriptPlaceholder(
            isDraft: false,
            messagesEmpty: true,
            transcriptGeneration: 0,
            isGatewayOffline: false,
            loadError: "Server error"
        )
        XCTAssertEqual(placeholder, .loadError("Server error"),
                       "a reachable-but-failed load keeps the recoverable error + retry screen")
    }

    func testConnectedCacheMissShowsSkeleton() {
        let placeholder = ChatView.transcriptPlaceholder(
            isDraft: false,
            messagesEmpty: true,
            transcriptGeneration: 0,
            isGatewayOffline: false,
            loadError: nil
        )
        XCTAssertEqual(placeholder, .skeleton)
    }

    func testSeededTranscriptRendersRowsNoPlaceholder() {
        let placeholder = ChatView.transcriptPlaceholder(
            isDraft: false,
            messagesEmpty: true,
            transcriptGeneration: 4,
            isGatewayOffline: true,
            loadError: nil
        )
        XCTAssertEqual(placeholder, .transcript,
                       "a seeded-then-emptied transcript (generation > 0) never shows the offline placeholder")
    }

    func testDraftGreetingWinsWhenOffline() {
        let placeholder = ChatView.transcriptPlaceholder(
            isDraft: true,
            messagesEmpty: true,
            transcriptGeneration: 0,
            isGatewayOffline: true,
            loadError: nil
        )
        XCTAssertEqual(placeholder, .draftGreeting,
                       "a fresh draft is a greeting, not an offline-empty state")
    }
}
