import XCTest
@testable import HermesMobile

/// ABH-194 regression test: ``SessionStore/restAPI`` must track the live
/// connection token (``ConnectionStore/currentToken``), not the Keychain value.
///
/// ## Root cause
/// Before the fix, ``SessionStore/restAPI`` re-read ``KeychainService/loadToken``
/// on each call. When ``ConnectionStore/currentToken`` was updated (re-pair,
/// device-token upgrade, or a Keychain write that lagged behind the in-memory
/// update) without the Keychain item keeping pace, ``restAPI`` sent the stale
/// Keychain token on session-management REST calls (search / rename / archive /
/// export) and received HTTP 401 -- while WS auth and transcript-fetch paths that
/// correctly used ``connection?.rest``/``currentToken`` worked fine.
///
/// ## Fix
/// ``restAPI`` was changed to return ``connection?.rest`` directly (the same
/// ``RestClient`` built from the authoritative in-memory ``currentToken``),
/// eliminating the second token source.
///
/// ## What these tests pin
/// 1. ``testRestAPIUsesLiveConnectionTokenNotStaleKeychain`` -- the PRIMARY
///    invariant: with `currentToken = "live-token"` in ``ConnectionStore`` AND
///    "stale-token" in the Keychain, ``SessionStore/restAPITokenForTesting``
///    (the DEBUG seam into ``restAPI``) must equal "live-token". This test
///    FAILS on the pre-fix code (``restAPI`` read the Keychain and returned
///    "stale-token") and PASSES on the fixed code.
/// 2. ``testRestAPIReturnsNilWhenNoLiveToken`` -- cold-launch safety: before
///    any ``configure()`` succeeds, ``restAPI`` must return nil even when a
///    stale Keychain item exists, so callers surface "Not connected." correctly.
@MainActor
final class SessionStoreTokenSourceTests: XCTestCase {

    private let testServer = "http://127.0.0.1:19423"
    private let liveToken  = "live-abh194-token"
    private let staleToken = "stale-abh194-token"

    // MARK: - Fixtures

    private func makeStore() -> (ConnectionStore, SessionStore) {
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        let attachments = AttachmentStore()
        chat.attach(connection: connection, sessions: sessions, attachments: attachments)
        sessions.attach(connection: connection, chat: chat)
        return (connection, sessions)
    }

    // MARK: - ABH-194: single token-source invariant

    /// Seed the in-memory connection with `liveToken`, plant `staleToken` in the
    /// Keychain for the same server, and assert that ``SessionStore/restAPITokenForTesting``
    /// (the DEBUG seam into the private ``restAPI`` computed property) returns
    /// `liveToken` -- NOT the stale Keychain value.
    ///
    /// ### Fails-without / passes-with proof
    /// Pre-fix ``restAPI`` body:
    ///   `token = KeychainService.loadToken(server: urlString)  // "stale-abh194-token"`
    ///   -> `restAPITokenForTesting` would equal `staleToken` -> XCTAssertEqual FAILS.
    ///
    /// Post-fix ``restAPI`` body:
    ///   `connection?.rest`  // token sourced from `currentToken` = "live-abh194-token"
    ///   -> `restAPITokenForTesting` equals `liveToken` -> XCTAssertEqual PASSES.
    func testRestAPIUsesLiveConnectionTokenNotStaleKeychain() async {
        let (connection, sessions) = makeStore()

        // Clean up any pre-existing Keychain item for this test server so we
        // start from a known state.  The defer ensures cleanup even on failure.
        KeychainService.deleteToken(server: testServer)
        defer { KeychainService.deleteToken(server: testServer) }

        // Inject a no-op fake transport so the reconnect loop completes without
        // opening a real socket.  Pattern mirrors ConnectionStoreReconnectTests.
        connection.connectRPC = { _, _, _ in }

        // Seed in-memory state as a prior configure() would have left it:
        //   serverURLString = testServer, currentToken = liveToken.
        // This models the divergence scenario: configure() wrote currentToken but
        // the Keychain write via `try?` silently failed (or a re-pair updated
        // currentToken before the Keychain item was refreshed).
        connection._seedAndStartReconnect(serverURL: testServer, token: liveToken)

        // Wait for the reconnect loop task to complete so the store settles before
        // we write the stale Keychain value.
        await connection.waitForReconnectForTesting()

        // Plant the stale token in the Keychain -- simulating the divergent state:
        //   currentToken = liveToken  (in-memory, authoritative)
        //   Keychain     = staleToken (stale, should be ignored)
        // Pre-fix restAPI would read this stale Keychain value and send it to the server.
        try? KeychainService.saveToken(staleToken, server: testServer)

        // Verify the divergence is real (Keychain != currentToken) so this test
        // is meaningful -- without this, the test would not exercise the bug scenario.
        let keychainValue = KeychainService.loadToken(server: testServer)
        XCTAssertEqual(keychainValue, staleToken,
            "Pre-condition: Keychain must hold the stale token to confirm the divergence scenario")

        // PRIMARY ASSERTION: restAPI must carry the LIVE token, not the stale one.
        // restAPITokenForTesting is a #if DEBUG seam into the private restAPI property.
        // Post-fix: restAPI == connection?.rest, token = currentToken = liveToken.
        // Pre-fix:  restAPI read Keychain, token = staleToken -> this assertion FAILS.
        XCTAssertEqual(
            sessions.restAPITokenForTesting, liveToken,
            "restAPI (SessionStore session-management client) must carry the live " +
            "currentToken, not the stale Keychain value (ABH-194 regression)")
        XCTAssertNotEqual(
            sessions.restAPITokenForTesting, staleToken,
            "restAPI must NOT use the stale Keychain token (ABH-194 regression)")
    }

    /// When ``ConnectionStore`` has no live token at all (fresh install, pre-configure),
    /// ``restAPI`` must return nil and callers must surface "Not connected." --
    /// identical to the old ``restAPI`` nil path.
    ///
    /// Cold-launch safety invariant: the fix (using ``connection?.rest``) must not
    /// break the "no connection yet" guard, even when a stale Keychain item exists.
    func testRestAPIReturnsNilWhenNoLiveToken() async {
        let (connection, sessions) = makeStore()
        // No _seedAndStartReconnect, no configure() -- currentToken is nil.
        // Plant a stale Keychain item: the OLD code would have returned it;
        // the NEW code must NOT (connection.rest requires currentToken != nil).
        defer { KeychainService.deleteToken(server: testServer) }
        try? KeychainService.saveToken("any-stale-token", server: testServer)

        // connection.rest requires both serverURLString and currentToken to be set;
        // without a prior configure() both are empty/nil -> rest == nil.
        // Consequently restAPITokenForTesting is nil.
        XCTAssertNil(connection.rest,
            "connection.rest must be nil before configure() sets currentToken, " +
            "even if a stale Keychain item exists")
        XCTAssertNil(sessions.restAPITokenForTesting,
            "restAPITokenForTesting must be nil when currentToken is nil " +
            "(cold-launch safety -- no stale Keychain fallback)")

        // Verify the callers' guard paths still work: a session-management op
        // with no live token must surface "Not connected." (not a Keychain-sourced 401).
        let target = SessionSummary(
            id: "arch-1", title: nil, preview: nil, startedAt: nil,
            messageCount: nil, source: nil, lastActive: nil, cwd: nil
        )
        sessions.archivedSessions = [target]
        await sessions.unarchive(target)

        XCTAssertFalse(sessions.archivedSessions.isEmpty,
            "unarchive with no live token must not remove the row (failure path)")
        XCTAssertEqual(sessions.sessionActionError?.action, "Unarchive",
            "unarchive with no live token must populate sessionActionError.action")
        XCTAssertEqual(sessions.sessionActionError?.message, "Not connected.",
            "unarchive with no live token must surface 'Not connected.' message")
    }
}
