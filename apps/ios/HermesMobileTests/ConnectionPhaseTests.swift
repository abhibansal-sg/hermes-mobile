import XCTest
@testable import HermesMobile

/// ABH-82 coverage for the `ConnectionStore` phase machine, focused on the new
/// branded-hydration phase and its mandatory timeout fallback.
///
/// The `configure()` connect path itself touches the network (REST probe + WS
/// handshake), so the genuinely-testable surface is the phase transitions either
/// side of it: the `.hydrating → .connected` convergence point that BOTH race
/// branches (real hydration and the 8s timeout) flow through, the guard that
/// makes a late/duplicate finish a no-op, the draft-landing on completion, and
/// the teardown paths (`disconnect`, an invalid-URL `configure`) that must never
/// leave the user stranded on the loading screen.
///
/// No live server is touched — pure phase/state assertions, mirroring the
/// pure-decision style of `DevicesTests`.
@MainActor
final class ConnectionPhaseTests: XCTestCase {

    private func makeStore() -> (ConnectionStore, SessionStore, ChatStore) {
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        let attachments = AttachmentStore()
        chat.attach(connection: connection, sessions: sessions, attachments: attachments)
        sessions.attach(connection: connection, chat: chat)
        return (connection, sessions, chat)
    }

    // MARK: - Phase value semantics

    func testPhaseEquatableIncludesHydrating() {
        XCTAssertEqual(ConnectionStore.Phase.hydrating, .hydrating)
        XCTAssertNotEqual(ConnectionStore.Phase.hydrating, .connected)
        XCTAssertNotEqual(ConnectionStore.Phase.hydrating, .connecting)
        XCTAssertNotEqual(ConnectionStore.Phase.hydrating, .needsSetup)
    }

    func testInitialPhaseIsConnecting() {
        // The store boots into `.connecting` (the launch splash) until bootstrap
        // resolves to a saved config or `.needsSetup` — the hydration phase must
        // not change that initial value.
        let (connection, _, _) = makeStore()
        XCTAssertEqual(connection.phase, .connecting)
    }

    #if DEBUG
    func testHydratingPhaseLabel() {
        // The DEBUG snapshot mirror (gstack bridge, UI-G) must carry a stable
        // label for the new phase so the StateServer accessor stays serializable.
        let (connection, _, _) = makeStore()
        connection.phase = .hydrating
        XCTAssertEqual(connection.phaseLabel, "hydrating")
    }
    #endif

    // MARK: - Hydration timeout fallback (the never-strand guarantee)

    func testHydrationTimeoutIsEightSeconds() {
        // The hard ceiling on the branded loading screen. Pinned so a regression
        // that lengthens (or removes) the fallback is caught — the loading screen
        // must proceed to `.connected` within this bound even if a probe hangs.
        XCTAssertEqual(ConnectionStore.hydrationTimeout, .seconds(8))
    }

    func testFinishHydrationFromHydratingLandsConnectedOnFreshDraft() {
        // The convergence point both race branches (real hydration + timeout)
        // flow through: from `.hydrating`, with nothing active, it must reveal
        // the connected UI on a FRESH new-chat draft.
        let (connection, sessions, _) = makeStore()
        XCTAssertFalse(sessions.isDraft)
        connection.phase = .hydrating

        connection.finishHydration()

        XCTAssertEqual(connection.phase, .connected)
        XCTAssertTrue(sessions.isDraft, "completion lands on a fresh new-chat draft")
        XCTAssertNil(sessions.activeStoredId)
    }

    func testFinishHydrationDoesNotStompAnActiveSession() {
        // A manual re-configure while a session is open must not stomp it: the
        // draft is started ONLY when nothing is active.
        let (connection, sessions, _) = makeStore()
        sessions.activeStoredId = "stored-open-session"
        connection.phase = .hydrating

        connection.finishHydration()

        XCTAssertEqual(connection.phase, .connected)
        XCTAssertFalse(sessions.isDraft, "an open session is preserved, no draft forced")
        XCTAssertEqual(sessions.activeStoredId, "stored-open-session")
    }

    func testFinishHydrationIsNoOpWhenNotHydrating() {
        // The losing branch of the race (or a stale late timeout after a
        // disconnect/re-configure) calls in while the phase has already moved on.
        // It must be a harmless no-op — never bounce a settled phase back to
        // `.connected` and never force a draft.
        let (connection, sessions, _) = makeStore()

        // From `.connecting` (e.g. a re-configure already in flight): unchanged.
        connection.phase = .connecting
        connection.finishHydration()
        XCTAssertEqual(connection.phase, .connecting)
        XCTAssertFalse(sessions.isDraft)

        // From `.offline` (a teardown raced the timeout): unchanged.
        connection.phase = .offline("dropped")
        connection.finishHydration()
        XCTAssertEqual(connection.phase, .offline("dropped"))
        XCTAssertFalse(sessions.isDraft)

        // From `.needsSetup` (disconnected mid-hydration): unchanged.
        connection.phase = .needsSetup
        connection.finishHydration()
        XCTAssertEqual(connection.phase, .needsSetup)
        XCTAssertFalse(sessions.isDraft)
    }

    func testFinishHydrationIsIdempotent() {
        // A second finish (e.g. the timeout branch firing just after the real
        // hydration won) must not re-create a draft or otherwise mutate state.
        let (connection, sessions, _) = makeStore()
        connection.phase = .hydrating
        connection.finishHydration()
        XCTAssertEqual(connection.phase, .connected)
        XCTAssertTrue(sessions.isDraft)

        // Now overwrite the draft flag to a sentinel and finish again: because the
        // phase is no longer `.hydrating`, the second call is a no-op and does NOT
        // re-start a draft.
        sessions.activeStoredId = "now-active"
        connection.finishHydration()
        XCTAssertEqual(connection.phase, .connected)
        XCTAssertEqual(sessions.activeStoredId, "now-active")
    }

    // MARK: - Teardown paths must never strand the loading screen

    func testDisconnectFromHydratingReturnsToNeedsSetup() async {
        // A disconnect mid-hydration cancels the coordinator and lands on
        // `.needsSetup` — the loading screen is torn down, never stranded.
        let (connection, _, _) = makeStore()
        connection.phase = .hydrating

        await connection.disconnect()

        XCTAssertEqual(connection.phase, .needsSetup)
        XCTAssertFalse(connection.reauthRequired)
    }

    func testConfigureWithInvalidURLGoesOfflineNotHydrating() async {
        // A malformed URL fails validation BEFORE any connect, so it must land on
        // `.offline` with a message — never enter `.hydrating` (which would
        // strand on the loading screen with no live socket behind it).
        let (connection, _, _) = makeStore()
        let failure = await connection.configure(urlString: "not a url", token: "tok")
        XCTAssertNotNil(failure)
        XCTAssertEqual(connection.phase, .offline("Invalid server URL"))
    }

    func testConfigureWithEmptyTokenGoesOfflineNotHydrating() async {
        let (connection, _, _) = makeStore()
        let failure = await connection.configure(urlString: "https://host:9443", token: "   ")
        XCTAssertNotNil(failure)
        XCTAssertEqual(connection.phase, .offline("Missing token"))
    }

    // MARK: - P0 validation-bypass gate (ABH-82 follow-up + WhatsApp-bar cache-first)
    //
    // The reported bug: garbage URL/token entered on the manual sheet (or a
    // garbage QR) transitioned the app INTO the main UI in a disconnected state.
    // Root cause was `RootView` routing `.offline` → `mainUI` unconditionally.
    // `RootView` now gates the shell on
    //   `hasConnected || isBootstrapping || hasSavedConfiguration`
    // (the third condition is the CACHE-FIRST addition: a previously-paired user
    // launching offline gets the cached drawer + ribbon instead of WelcomeView).
    // These tests pin the store-side discriminators the gate proves on, plus the
    // end-to-end "failed configure never sets hasConnected / hasSavedConfiguration"
    // guarantee — a garbage configure persists nothing, so ALL THREE stay false and
    // the user remains in onboarding. (The `hasSavedConfiguration` discriminator is
    // exercised directly in CacheFirstLaunchTests.)

    func testFreshStoreHasNotConnectedAndIsNotBootstrapping() {
        // The clean first-run state the `RootView` gate reads: a brand-new store
        // has never verified a connection and is not in a launch reconnect, so a
        // `.offline`/`.connecting` failure phase must route to onboarding, not the
        // shell.
        let (connection, _, _) = makeStore()
        XCTAssertFalse(connection.hasConnected)
        XCTAssertFalse(connection.isBootstrapping)
    }

    func testFailedConfigureNeverMarksHasConnected() async {
        // The crux of the bypass fix: a `configure` that fails validation must
        // leave `hasConnected` false, so `RootView` keeps the user in onboarding
        // (with the inline error behind the sheet/cover) rather than dropping
        // them into the chat shell. Covers both the well-formedness reject and an
        // empty token — neither reaches the verified-connect flag.
        let (connection, _, _) = makeStore()

        _ = await connection.configure(urlString: "not a url", token: "tok")
        XCTAssertFalse(connection.hasConnected,
                       "a malformed URL must not flip the verified-connection flag")
        XCTAssertEqual(connection.phase, .offline("Invalid server URL"))

        _ = await connection.configure(urlString: "https://host:9443", token: "  ")
        XCTAssertFalse(connection.hasConnected,
                       "an empty token must not flip the verified-connection flag")
        XCTAssertEqual(connection.phase, .offline("Missing token"))

        // And the launch-splash exception is NOT spuriously set by a failed
        // manual/QR configure — only `bootstrap()` arms it.
        XCTAssertFalse(connection.isBootstrapping)
    }

    func testDisconnectClearsHasConnected() async {
        // After a verified session is torn down, the verified-connection flag is
        // cleared — so a subsequent setup attempt is gated as first-run again and
        // a failed re-configure can't ride `.offline` back into the shell.
        let (connection, _, _) = makeStore()
        // Simulate a prior verified connection by driving the convergence point.
        connection.phase = .hydrating
        connection.finishHydration()
        XCTAssertEqual(connection.phase, .connected)

        await connection.disconnect()
        XCTAssertFalse(connection.hasConnected)
        XCTAssertEqual(connection.phase, .needsSetup)
    }

    func testConfigureWithInvalidURLLeavesNothingPersisted() async {
        // On a validation failure nothing is persisted: no saved URL, no in-memory
        // server string, no live REST client — the gate has no stale credential to
        // resurrect a shell from. (Mirrors the "nothing persisted" clause of the
        // verbatim spec.)
        let (connection, _, _) = makeStore()
        _ = await connection.configure(urlString: "not a url", token: "tok")
        XCTAssertEqual(connection.serverURLString, "")
        XCTAssertNil(connection.rest)
    }
}
