import CoreSpotlight
import XCTest
@testable import HermesMobile

/// L11 deep-link / App Intents plumbing tests.
///
/// Covers the logic-sensitive routing changes:
/// - `session/<id>` resolution + the no-silent-dead-end inbox fallback.
/// - the `capture` route removal (now an inert no-op).
/// - the `pair`-while-connected confirmation seam (unconfigured pairs directly;
///   configured defers to a confirmation request).
/// - the App Intents `.newSession` LOCAL-DRAFT parity change (no orphan session).
/// - the Spotlight / Handoff continuation receiver (`routeContinuedActivity`).
///
/// No live gateway is touched. Each store is built unconfigured (no `client`,
/// `rest == nil`), mirroring the pure-state style of `ConnectionPhaseTests`.
@MainActor
final class DeepLinkRouterTests: XCTestCase {

    // MARK: - Fixtures

    private struct Stores {
        let connection: ConnectionStore
        let sessions: SessionStore
        let chat: ChatStore
        let inbox: InboxStore
    }

    private func makeStores() -> Stores {
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        let attachments = AttachmentStore()
        let inbox = InboxStore()
        chat.attach(connection: connection, sessions: sessions, attachments: attachments)
        sessions.attach(connection: connection, chat: chat)
        inbox.attach(connection: connection)
        return Stores(connection: connection, sessions: sessions, chat: chat, inbox: inbox)
    }

    private func summary(id: String) -> SessionSummary {
        SessionSummary(
            id: id,
            title: "Session \(id)",
            preview: nil,
            startedAt: nil,
            messageCount: nil,
            source: nil,
            lastActive: nil,
            cwd: nil
        )
    }

    /// Spin the runloop until `condition` holds or a short budget elapses. The
    /// router's resolution fallback runs inside a `Task`, so the assertion must
    /// wait for that hop rather than read synchronously.
    private func waitUntil(
        _ condition: @escaping () -> Bool,
        timeout: TimeInterval = 2.0
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - session/<id> resolution

    func testSessionDeepLinkOpensWhenResolvable() {
        let s = makeStores()
        s.sessions.sessions = [summary(id: "abc123")]

        HermesURLRouter.route(
            URL(string: "hermesapp://session/abc123")!,
            connection: s.connection,
            sessions: s.sessions,
            chat: s.chat,
            inbox: s.inbox
        )

        // `open(_:)` activates synchronously (the gateway resume is a no-op
        // without a client), so the active stored id is set immediately.
        XCTAssertEqual(s.sessions.activeStoredId, "abc123")
        XCTAssertFalse(s.sessions.isDraft)
        // A resolvable id never touches the inbox.
        XCTAssertEqual(s.inbox.presentationRequestToken, 0)
    }

    func testSessionDeepLinkUnresolvableSurfacesInbox() async {
        let s = makeStores()
        // Empty fetch seam → the in-Task `refresh()` resolves to an empty list,
        // so the id stays unresolvable and the fallback must surface the inbox.
        s.sessions.sessionsFetch = { ([], 0) }
        let tokenBefore = s.inbox.presentationRequestToken

        HermesURLRouter.route(
            URL(string: "hermesapp://session/ghost")!,
            connection: s.connection,
            sessions: s.sessions,
            chat: s.chat,
            inbox: s.inbox
        )

        await waitUntil { s.inbox.presentationRequestToken > tokenBefore }
        XCTAssertEqual(
            s.inbox.presentationRequestToken, tokenBefore + 1,
            "An unresolvable session deep link must surface the inbox, not dead-end."
        )
        XCTAssertNil(s.sessions.activeStoredId)
    }

    func testSessionDeepLinkEmptyIdIsIgnored() {
        let s = makeStores()
        HermesURLRouter.route(
            URL(string: "hermesapp://session/")!,
            connection: s.connection,
            sessions: s.sessions,
            chat: s.chat,
            inbox: s.inbox
        )
        XCTAssertNil(s.sessions.activeStoredId)
        XCTAssertEqual(s.inbox.presentationRequestToken, 0)
    }

    // MARK: - new-session (local draft)

    func testNewSessionDeepLinkStartsLocalDraft() {
        let s = makeStores()
        HermesURLRouter.route(
            URL(string: "hermesapp://new-session")!,
            connection: s.connection,
            sessions: s.sessions,
            chat: s.chat,
            inbox: s.inbox
        )
        // Local draft: drafting, no active/stored ids, no server session created.
        XCTAssertTrue(s.sessions.isDraft)
        XCTAssertNil(s.sessions.activeStoredId)
        XCTAssertNil(s.sessions.activeRuntimeId)
    }

    func testNewSessionDeepLinkPreservesRunningTurnInsteadOfDraftReset() {
        let s = makeStores()
        s.sessions.sessions = [summary(id: "stored-live")]
        s.sessions.activeStoredId = "stored-live"
        s.sessions.activeRuntimeId = "runtime-live"
        s.chat.isStreaming = true
        var discarded = false
        s.chat.onTurnDiscarded = { discarded = true }

        HermesURLRouter.route(
            URL(string: "hermesapp://new-session")!,
            connection: s.connection,
            sessions: s.sessions,
            chat: s.chat,
            inbox: s.inbox
        )

        XCTAssertFalse(s.sessions.isDraft, "A widget tap during a live turn must not start a blank draft.")
        XCTAssertEqual(s.sessions.activeStoredId, "stored-live")
        XCTAssertEqual(s.sessions.activeRuntimeId, "runtime-live")
        XCTAssertTrue(s.chat.isStreaming)
        XCTAssertFalse(discarded, "Preserving the live turn must not fire the discard/Live Activity end seam.")
    }

    // MARK: - capture route removed

    func testCaptureRouteIsInertNoOp() {
        let s = makeStores()
        // The capture route was removed with Quick Capture. A capture URL must do
        // NOTHING — no draft, no session, no inbox surface.
        HermesURLRouter.route(
            URL(string: "hermesapp://capture?text=hello")!,
            connection: s.connection,
            sessions: s.sessions,
            chat: s.chat,
            inbox: s.inbox
        )
        XCTAssertFalse(s.sessions.isDraft)
        XCTAssertNil(s.sessions.activeStoredId)
        XCTAssertEqual(s.inbox.presentationRequestToken, 0)
    }

    // MARK: - pair confirmation seam

    func testPairOnUnconfiguredDoesNotRequestConfirmation() {
        let s = makeStores()
        XCTAssertNil(s.connection.rest, "fresh store must be unconfigured")
        var confirmationRequested = false

        HermesURLRouter.route(
            URL(string: "hermesapp://pair?url=https%3A%2F%2Fh%3A9119&token=tok")!,
            connection: s.connection,
            sessions: s.sessions,
            chat: s.chat,
            inbox: s.inbox,
            requestPairConfirmation: { _ in confirmationRequested = true }
        )

        // Unconfigured → pair directly (no confirmation needed; nothing to lose).
        XCTAssertFalse(
            confirmationRequested,
            "An unconfigured app must pair directly without a confirmation prompt."
        )
    }

    func testMalformedPairIsIgnoredEvenUnconfigured() {
        let s = makeStores()
        var confirmationRequested = false
        // Missing token → not a valid pair payload → ignored entirely.
        HermesURLRouter.route(
            URL(string: "hermesapp://pair?url=https%3A%2F%2Fh%3A9119")!,
            connection: s.connection,
            sessions: s.sessions,
            chat: s.chat,
            inbox: s.inbox,
            requestPairConfirmation: { _ in confirmationRequested = true }
        )
        XCTAssertFalse(confirmationRequested)
    }

    func testDeepLinkCoordinatorStashAndClear() {
        let coordinator = DeepLinkCoordinator()
        XCTAssertNil(coordinator.pendingPair)

        let first = HermesURLRouter.PairPayload(
            url: "https://a:9119", token: "t1", isDeviceToken: false, deviceId: nil, manualToken: false
        )
        coordinator.requestPairConfirmation(first)
        XCTAssertEqual(coordinator.pendingPair?.token, "t1")

        // Last-write-wins: a second link before the user answers replaces the first.
        let second = HermesURLRouter.PairPayload(
            url: "https://b:9119", token: "t2", isDeviceToken: false, deviceId: nil, manualToken: false
        )
        coordinator.requestPairConfirmation(second)
        XCTAssertEqual(coordinator.pendingPair?.token, "t2")

        coordinator.clear()
        XCTAssertNil(coordinator.pendingPair)
    }

    // MARK: - Inc-3b: manual_token pairing (Local-desktop)

    /// `manual_token=true` with no `token` param should parse successfully and set
    /// `manualToken = true` with an empty token string.
    func testManualTokenPairPayloadParsesWithNoToken() {
        let payload = "hermesapp://pair?url=http%3A%2F%2F127.0.0.1%3A9123&manual_token=true"
        let parsed = HermesURLRouter.parsePairPayload(payload)
        XCTAssertNotNil(parsed, "manual_token=true payload must parse even when token is absent")
        XCTAssertEqual(parsed?.url, "http://127.0.0.1:9123")
        XCTAssertEqual(parsed?.token, "")
        XCTAssertTrue(parsed?.manualToken == true, "manualToken must be true")
        XCTAssertFalse(parsed?.isDeviceToken == true)
    }

    /// A standard payload (no `manual_token` param) should have `manualToken == false`.
    func testStandardPairPayloadHasManualTokenFalse() {
        let payload = "hermesapp://pair?url=https%3A%2F%2Fh%3A9119&token=tok"
        let parsed = HermesURLRouter.parsePairPayload(payload)
        XCTAssertNotNil(parsed)
        XCTAssertFalse(parsed?.manualToken == true)
        XCTAssertEqual(parsed?.token, "tok")
    }

    /// A `manual_token=true` payload without a URL should still return nil.
    func testManualTokenWithNoURLReturnsNil() {
        let payload = "hermesapp://pair?manual_token=true"
        let parsed = HermesURLRouter.parsePairPayload(payload)
        XCTAssertNil(parsed, "URL is always required; manual_token=true without url must be nil")
    }

    /// When a `manual_token=true` link arrives, the router must call
    /// `requestManualTokenPair` and NOT call `requestPairConfirmation` or configure.
    func testManualTokenPairRouteCallsManualTokenSeam() {
        let s = makeStores()
        XCTAssertNil(s.connection.rest, "fresh store must be unconfigured")

        var manualTokenRequested = false
        var confirmationRequested = false

        HermesURLRouter.route(
            URL(string: "hermesapp://pair?url=http%3A%2F%2F127.0.0.1%3A9123&manual_token=true")!,
            connection: s.connection,
            sessions: s.sessions,
            chat: s.chat,
            inbox: s.inbox,
            requestPairConfirmation: { _ in confirmationRequested = true },
            requestManualTokenPair: { _ in manualTokenRequested = true }
        )

        XCTAssertTrue(
            manualTokenRequested,
            "manual_token=true must trigger requestManualTokenPair"
        )
        XCTAssertFalse(
            confirmationRequested,
            "manual_token=true must NOT trigger requestPairConfirmation"
        )
    }

    /// When a `manual_token=true` link arrives but no `requestManualTokenPair`
    /// seam is wired, the router must silently drop the link (no crash, no configure).
    func testManualTokenPairDroppedWithoutSeam() {
        let s = makeStores()
        let phaseBefore = s.connection.phase
        // Provide no requestManualTokenPair seam.
        HermesURLRouter.route(
            URL(string: "hermesapp://pair?url=http%3A%2F%2F127.0.0.1%3A9123&manual_token=true")!,
            connection: s.connection,
            sessions: s.sessions,
            chat: s.chat,
            inbox: s.inbox
        )
        // Phase must be unchanged — no configure attempt (configure would set it to .connecting
        // then .offline or .connected; both differ from the initial state which is .connecting,
        // but crucially no REST/WS call should have been fired). The phase is unchanged.
        XCTAssertEqual(s.connection.phase, phaseBefore,
                       "Dropping the link should leave the phase unchanged")
        // No session activation, no inbox request.
        XCTAssertNil(s.sessions.activeStoredId)
        XCTAssertEqual(s.inbox.presentationRequestToken, 0)
    }

    /// `DeepLinkCoordinator.requestManualTokenPair` stashes the payload; `clear()`
    /// wipes it. `clearManualTokenPair()` wipes only the manual-token payload.
    func testDeepLinkCoordinatorManualTokenStashAndClear() {
        let coordinator = DeepLinkCoordinator()
        XCTAssertNil(coordinator.pendingManualTokenPair)

        let payload = HermesURLRouter.PairPayload(
            url: "http://127.0.0.1:9123", token: "", isDeviceToken: false, deviceId: nil, manualToken: true
        )
        coordinator.requestManualTokenPair(payload)
        XCTAssertNotNil(coordinator.pendingManualTokenPair)
        XCTAssertEqual(coordinator.pendingManualTokenPair?.url, "http://127.0.0.1:9123")

        // clearManualTokenPair() leaves pendingPair untouched.
        let pending = HermesURLRouter.PairPayload(
            url: "https://b:9119", token: "t2", isDeviceToken: false, deviceId: nil, manualToken: false
        )
        coordinator.requestPairConfirmation(pending)
        coordinator.clearManualTokenPair()
        XCTAssertNil(coordinator.pendingManualTokenPair, "clearManualTokenPair must wipe the manual-token payload")
        XCTAssertNotNil(coordinator.pendingPair, "clearManualTokenPair must not touch pendingPair")

        // clear() wipes both.
        coordinator.requestManualTokenPair(payload)
        coordinator.clear()
        XCTAssertNil(coordinator.pendingManualTokenPair)
        XCTAssertNil(coordinator.pendingPair)
    }

    // MARK: - bare root

    func testBareRootStartsDraft() {
        let s = makeStores()
        HermesURLRouter.route(
            URL(string: "hermesapp://")!,
            connection: s.connection,
            sessions: s.sessions,
            chat: s.chat,
            inbox: s.inbox
        )
        XCTAssertTrue(s.sessions.isDraft)
    }

    func testBareRootWithLiveActivitySessionIdPreservesRunningTurn() {
        let s = makeStores()
        s.sessions.sessions = [summary(id: "stored-live")]
        s.sessions.activeStoredId = "stored-live"
        s.sessions.activeRuntimeId = "runtime-live"
        s.chat.isStreaming = true
        var discarded = false
        s.chat.onTurnDiscarded = { discarded = true }

        HermesURLRouter.route(
            URL(string: "hermesapp://?session_id=runtime-live")!,
            connection: s.connection,
            sessions: s.sessions,
            chat: s.chat,
            inbox: s.inbox
        )

        XCTAssertFalse(s.sessions.isDraft)
        XCTAssertEqual(s.sessions.activeStoredId, "stored-live")
        XCTAssertEqual(s.sessions.activeRuntimeId, "runtime-live")
        XCTAssertTrue(s.chat.isStreaming)
        XCTAssertFalse(discarded)
    }

    func testUnknownHostIsIgnored() {
        let s = makeStores()
        HermesURLRouter.route(
            URL(string: "hermesapp://bogus/thing")!,
            connection: s.connection,
            sessions: s.sessions,
            chat: s.chat,
            inbox: s.inbox
        )
        XCTAssertFalse(s.sessions.isDraft)
        XCTAssertNil(s.sessions.activeStoredId)
    }

    func testForeignSchemeIsIgnored() {
        let s = makeStores()
        HermesURLRouter.route(
            URL(string: "https://example.com/session/abc")!,
            connection: s.connection,
            sessions: s.sessions,
            chat: s.chat,
            inbox: s.inbox
        )
        XCTAssertFalse(s.sessions.isDraft)
        XCTAssertNil(s.sessions.activeStoredId)
    }

    // MARK: - Spotlight / Handoff continuation receiver

    func testContinuedHandoffActivityOpensSession() {
        let s = makeStores()
        s.sessions.sessions = [summary(id: "handoff-1")]
        let activity = SpotlightIndexer.userActivity(for: summary(id: "handoff-1"))

        let handled = HermesURLRouter.routeContinuedActivity(
            activity, sessions: s.sessions, inbox: s.inbox
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(s.sessions.activeStoredId, "handoff-1")
    }

    func testContinuedSpotlightTapOpensSession() {
        let s = makeStores()
        s.sessions.sessions = [summary(id: "spot-9")]
        // Simulate a Spotlight result tap: a CSSearchableItemActionType activity
        // whose userInfo carries the indexed item's unique id.
        let activity = NSUserActivity(activityType: CSSearchableItemActionType)
        activity.userInfo = [CSSearchableItemActivityIdentifier: "session:spot-9"]

        let handled = HermesURLRouter.routeContinuedActivity(
            activity, sessions: s.sessions, inbox: s.inbox
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(s.sessions.activeStoredId, "spot-9")
    }

    func testContinuedActivityUnresolvableSurfacesInbox() async {
        let s = makeStores()
        s.sessions.sessionsFetch = { ([], 0) }
        let tokenBefore = s.inbox.presentationRequestToken
        let activity = SpotlightIndexer.userActivity(for: summary(id: "vanished"))

        let handled = HermesURLRouter.routeContinuedActivity(
            activity, sessions: s.sessions, inbox: s.inbox
        )

        XCTAssertTrue(handled, "a recognized session activity is handled even when its id is gone")
        await waitUntil { s.inbox.presentationRequestToken > tokenBefore }
        XCTAssertEqual(s.inbox.presentationRequestToken, tokenBefore + 1)
    }

    func testContinuedUnknownActivityIsNotHandled() {
        let s = makeStores()
        let activity = NSUserActivity(activityType: "com.example.unrelated")
        let handled = HermesURLRouter.routeContinuedActivity(
            activity, sessions: s.sessions, inbox: s.inbox
        )
        XCTAssertFalse(handled)
        XCTAssertNil(s.sessions.activeStoredId)
        XCTAssertEqual(s.inbox.presentationRequestToken, 0)
    }
}
