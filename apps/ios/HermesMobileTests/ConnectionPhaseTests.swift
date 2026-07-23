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

    func testSecureRelayOverrideStaysSecure() {
        setenv("HERMES_RELAY_URL", "https://relay.example:9446/path?ignored=yes", 1)
        defer { unsetenv("HERMES_RELAY_URL") }
        let (connection, _, _) = makeStore()

        XCTAssertEqual(
            connection.stockProxyURL(
                forGateway: URL(string: "https://gateway.example:9443")!
            ).absoluteString,
            "https://relay.example:9446"
        )
    }

    #if DEBUG
    func testHydratingPhaseLabel() {
        // The DEBUG snapshot mirror (gstack bridge, UI-G) must carry a stable
        // label for the new phase so the StateServer accessor stays serializable.
        let (connection, _, _) = makeStore()
        connection.phase = .hydrating
        XCTAssertEqual(connection.phaseLabel, "hydrating")
    }

    func testConnectedPhaseLabelIsPlainWhenNotInGrace() {
        let (connection, _, _) = makeStore()
        connection.phase = .connected
        XCTAssertEqual(connection.phaseLabel, "connected")
    }

    func testConnectedPhaseLabelReflectsGrace() {
        // STR-973A: the StateServer bridge must be able to distinguish a
        // silent-grace `.connected` (transport actually down, reconnecting
        // underneath) from a genuinely healthy one — both keep
        // `phase == .connected`, so the label is the only observable.
        let (connection, _, _) = makeStore()
        connection.graceWindowOverride = .seconds(60)
        connection.connectRPC = { _, _, _ in throw URLError(.cannotConnectToHost) }
        connection._seedConnectedForTesting(serverURL: "http://localhost:9123", token: "test-stable-token")
        connection._handleGatewayStateForTesting(.failed("gateway process exited"))
        XCTAssertEqual(connection.phase, .connected)
        XCTAssertEqual(connection.phaseLabel, "connected(grace)")
    }
    #endif

    // MARK: - Hydration timeout fallback (the never-strand guarantee)

    func testHydrationTimeoutIsEightSeconds() {
        // The hard ceiling on the branded loading screen. Pinned so a regression
        // that lengthens (or removes) the fallback is caught — the loading screen
        // must proceed to `.connected` within this bound even if a probe hangs.
        XCTAssertEqual(ConnectionStore.hydrationTimeout, .seconds(8))
    }

    func testFreshnessStatesHaveDistinctVoiceOverTextAndAuthority() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let weekAgo = now.addingTimeInterval(-7 * 86_400)
        // #203 contract: every phase still resolves to a distinct VoiceOver
        // label and honest mutation authority. The `showsBanner` column was
        // dropped when the top status strip was removed completely on owner
        // order (2026-07-18) — freshness is no longer rendered as a full-width
        // banner, so there is no banner-visibility contract left to pin. The
        // underlying kind/label/authority state machinery is retained for the
        // surviving consumers (DrawerView, InboxView).
        let cases: [(ConnectionStore.Phase, ManifestFreshness, FreshnessPresentation.Kind, String)] = [
            (.connecting, .cached, .connecting, "Connecting to server"),
            (.hydrating, .cached, .syncing, "Synchronizing cached content"),
            (.connected, .fresh, .fresh, "Content is fresh"),
            (.offline("network unavailable"), .cached, .offline, "Offline. Last synced 1w ago"),
            (.offline("sync failed"), .cached, .failedCached, "Synchronization failed. Cached data is shown"),
            (.connected, .partial, .partial, "Partial synchronization result"),
        ]
        var labels = Set<String>()
        for (phase, freshness, kind, label) in cases {
            let value = FreshnessPresentation.resolve(
                phase: phase, manifestFreshness: freshness,
                lastSyncedAt: weekAgo, now: now
            )
            XCTAssertEqual(value.kind, kind)
            XCTAssertEqual(value.accessibilityLabel, label)
            labels.insert(value.accessibilityLabel)
            XCTAssertEqual(value.allowsRemoteMutations, kind == .fresh)
        }
        XCTAssertEqual(labels.count, cases.count)
    }

    func testCompactAndSplitLayoutsShareFreshnessValue() {
        let value = FreshnessPresentation.resolve(
            phase: .hydrating, manifestFreshness: .cached, lastSyncedAt: nil
        )
        // RootView computes this before its size-class branch, so both layouts
        // receive the same immutable presentation without changing selection.
        XCTAssertEqual(value.text, "Syncing")
        XCTAssertFalse(value.allowsRemoteMutations)
    }

    // MARK: - STR-973A named grace windows

    func testTransientGraceWindowIsTenSeconds() {
        // The silent-reconnect grace window for a transport drop witnessed live
        // during an active session. Pinned so a regression can't silently widen
        // (masking real outages behind a longer no-warning window) or shrink it
        // (flashing an error on blips that would have healed just past the old
        // bound) without the test catching it.
        XCTAssertEqual(ConnectionStore.transientGraceWindow, .seconds(10))
    }

    func testColdOpenGraceWindowIsFiveSeconds() {
        // Shorter than `transientGraceWindow` — a dead socket found on cold
        // open/foreground is far more often a stale-suspend reconnect than a
        // real outage. Reserved for the foreground/cold-open path; pinned here
        // regardless of current wiring so the constant can't drift unnoticed.
        XCTAssertEqual(ConnectionStore.coldOpenGraceWindow, .seconds(5))
    }

    func testColdOpenGraceWindowIsShorterThanTransientGraceWindow() {
        // The relative ordering is the actual contract STR-973A depends on:
        // whichever grace window is in effect, cold-open must never wait as
        // long as a live-witnessed transient drop.
        XCTAssertLessThan(ConnectionStore.coldOpenGraceWindow, ConnectionStore.transientGraceWindow)
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

    // MARK: - Replace-connection confirmation gate (Inc-4 Hardening #2)
    //
    // `ConnectionSetupView.connect()` and `ManualTokenPromptView.connect()` gate
    // on `connection.hasConnected` before calling `configure()` — showing a
    // destructive-confirmation alert instead of silently swapping the gateway.
    // These tests pin the store-side discriminators the view logic reads.

    func testFreshStoreDoesNotGateReplaceConfirmation() {
        // A brand-new store (never verified a connection) should NOT trigger the
        // replace-confirmation gate: the view's `if connection.hasConnected` is
        // false, so `connect()` proceeds directly to `performConnect()`.
        let (connection, _, _) = makeStore()
        XCTAssertFalse(connection.hasConnected,
                       "fresh store: no prior verified session → no confirmation needed")
    }

    func testConnectedStoreGatesReplaceConfirmation() {
        // Once the hydration convergence point is reached (= a verified session),
        // `hasConnected` is true and the view SHOULD show the confirmation alert
        // before calling `configure()`. The test drives the store to that state
        // and confirms the flag is set.
        let (connection, _, _) = makeStore()
        connection.phase = .hydrating
        connection.finishHydration()
        XCTAssertEqual(connection.phase, .connected)
        XCTAssertTrue(connection.hasConnected,
                      "after verified session: hasConnected == true → confirmation gate fires")
    }

    func testConnectedStoreExposesCurrentHostForAlertMessage() {
        // The confirmation alert message shows the CURRENT host being replaced.
        // This test verifies the host is derivable from `serverURLString` — the
        // property the view reads to populate the alert body.
        let (connection, _, _) = makeStore()
        // Directly set the persisted URL (simulating a previously-configured store).
        connection.serverURLString = "https://mymac.tailnet.ts.net:9443"
        let host = URL(string: connection.serverURLString)?.host(percentEncoded: false)
        XCTAssertEqual(host, "mymac.tailnet.ts.net",
                       "host is extractable from serverURLString for the alert message")
    }

    func testDisconnectResetsGateSoNextPairIsUnconfirmed() async {
        // After `disconnect()`, `hasConnected` is cleared — the NEXT configure
        // attempt is treated as first-run (no replace-confirmation shown).
        let (connection, _, _) = makeStore()
        connection.phase = .hydrating
        connection.finishHydration()
        XCTAssertTrue(connection.hasConnected)

        await connection.disconnect()

        XCTAssertFalse(connection.hasConnected,
                       "after disconnect: hasConnected resets → next pair skips confirmation")
    }
}
