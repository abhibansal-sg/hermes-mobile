import XCTest
@testable import HermesMobile

/// Inc-4 lane 4b — deterministic proof of gateway-restart survival + auth-revoke
/// threshold (Task #5 follow-up).
///
/// SPEC (SPEC-INC4-RESTART-SURVIVAL.md §Lane 4b): a gateway restart at a
/// STABLE address+token must drive the reconnect loop to `.connected` with
/// `reauthRequired == false` and `hasConnected` still true — no re-pair prompt.
///
/// All tests use the injectable `connectRPC` seam so no live socket is required
/// (deterministic, CI-safe). The loop's attempt-0 path fires immediately (no
/// backoff), so a single `settle()` window captures the phase transition.
///
/// The three core assertions mirror the spec success criteria:
///   1. `.reconnecting → .connected` when the gateway comes back up.
///   2. `reauthRequired == false` — the app does NOT prompt for re-pair.
///   3. `hasConnected` stays `true` — no first-run onboarding bounce.
///
/// Auth-revoke threshold (Task #5):
///   4. After ≥ authReprobeThreshold consecutive WS failures + REST probe
///      returning true → `reauthRequired` flips `true` (re-pair prompt fires).
///   5. Below the threshold: stays `.reconnecting`, `reauthRequired == false`.
///   6. Success after a sub-threshold blip clears the failure count (no
///      spurious re-pair on the next failure run).
///
/// These use the `#if DEBUG probeIsAuthRevokedRPC` + `reconnectBackoffOverride`
/// seams added alongside `connectRPC` to drive multiple consecutive failures
/// without live servers or real wall-clock backoff.
@MainActor
final class ConnectionStoreReconnectTests: XCTestCase {

    private actor SuspensionGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var didEnter = false

        func suspend() async {
            didEnter = true
            await withCheckedContinuation { continuation = $0 }
        }

        func waitUntilEntered() async {
            while !didEnter { await Task.yield() }
        }

        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    private actor ResumeCallLog {
        private var values: [String] = []

        func append(_ value: String) {
            values.append(value)
        }

        func calls(for storedId: String) -> Int {
            values.filter { $0 == storedId }.count
        }
    }

    // MARK: - Helpers

    /// Build a wired store graph (ConnectionStore + SessionStore + ChatStore).
    /// No live servers are touched; the `connectRPC` hook on the returned
    /// `ConnectionStore` is `nil` until the test sets it.
    ///
    /// `_restOverrideForTesting` (STR-1481) is seeded here — not just in
    /// `configureWithoutGateway` — because `recoverActiveSession()` (exercised
    /// by the `_seedAndStartReconnect`/`_seedConnectedForTesting` tests below,
    /// not just the `configure()`-path ones) has its own fire-and-forget REST
    /// probe on `self.rest`. Without this every hermetic test in this file
    /// leaks a real request at a fake host, flooding CI logs with hundreds of
    /// `-1004`/"HTTP load failed" lines.
    #if DEBUG
    private func makeStore() -> (ConnectionStore, SessionStore, ChatStore) {
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        let attachments = AttachmentStore()
        chat.attach(connection: connection, sessions: sessions, attachments: attachments)
        sessions.attach(connection: connection, chat: chat)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [InstantFailureProtocol.self]
        connection._restOverrideForTesting = RestClient(
            baseURL: URL(string: "https://stub.invalid")!,
            token: "stub",
            session: URLSession(configuration: config),
            pathStyle: .legacy
        )
        return (connection, sessions, chat)
    }
    #endif

    /// 600 ms — enough for a `Task` spawned on the main executor to complete
    /// its attempt-0 pass (no backoff). The 120ms used by ChatStoreBatchBTests
    /// is not enough here because `recoverActiveSession()` makes a REST call
    /// (guarded by `try?`) that returns quickly (connection refused) but still
    /// needs a few hundred ms to propagate on the simulator. 600ms is well within
    /// CI budget and keeps the test deterministic across machines.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(600))
    }

    private func frame(
        type: String,
        runtime: String,
        payload: JSONValue = .null
    ) -> GatewayEvent {
        GatewayEvent(params: .object([
            "type": .string(type),
            "session_id": .string(runtime),
            "payload": payload,
        ]))!
    }

    private func storedMessage(role: String, text: String) -> StoredMessage {
        StoredMessage(json: .object([
            "role": .string(role),
            "content": .string(text),
        ]))!
    }

    private func sessionSummary(_ id: String) -> SessionSummary {
        SessionSummary(
            id: id,
            title: "Stale session",
            preview: nil,
            startedAt: nil,
            messageCount: nil,
            source: "ios",
            lastActive: nil,
            cwd: nil
        )
    }

    private func stagedResumeResult(sessionId: String, resumed: String) -> SessionOpenResult {
        JSONValue.object([
            "session_id": .string(sessionId),
            "resumed": .string(resumed),
        ]).decoded(as: SessionOpenResult.self)!
    }

    #if DEBUG
    /// Fails every request instantly (`cannotConnectToHost`) — no real DNS
    /// lookup or socket attempt. Backs the stub `_restOverrideForTesting`
    /// client seeded in `makeStore()` (STR-1481): without it, every hermetic
    /// test's fire-and-forget REST probe (`configure()`'s capability probe /
    /// auto-upgrade, `recoverActiveSession()`'s reattach probe) tries to reach
    /// a fake host and floods CI logs with hundreds of "HTTP load failed" /
    /// `-1004` lines — which is what pushed the real failing assertion out of
    /// the CI log's `tail -100` window. It is NOT the cause of the two
    /// `configure()` state-corruption failures below — that turned out to be
    /// `CODE_SIGNING_ALLOWED=NO` on the test host breaking Keychain
    /// entitlements (see `.github/workflows/ios-tests.yml`) — but it's still
    /// needed so hermetic runs make no real network calls at all.
    private final class InstantFailureProtocol: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
        }
        override func stopLoading() {}
    }

    private func configureWithoutGateway(
        _ connection: ConnectionStore,
        serverURL: String,
        token: String,
        issuedDeviceId: String? = nil
    ) async -> String? {
        connection.statusRPC = { _, _ in }
        connection.connectRPC = { _, _, _ in }
        return await connection.configure(
            urlString: serverURL,
            token: token,
            issuedDeviceId: issuedDeviceId
        )
    }
    #endif

    // MARK: - ABH-355: mid-turn gateway death survives + re-attaches

    #if DEBUG
    func testSavedTokenConfigurePreservesRecordedDeviceIdWhenIssuedDeviceIdIsNil() async {
        let (connection, _, _) = makeStore()
        let serverURL = "https://gw.example:9119"
        let priorServerURL = UserDefaults.standard.string(forKey: DefaultsKeys.serverURL)
        KeychainService.deleteToken(server: serverURL)
        defer {
            KeychainService.deleteToken(server: serverURL)
            DefaultsKeys.setDeviceId(nil, server: serverURL)
            if let priorServerURL {
                UserDefaults.standard.set(priorServerURL, forKey: DefaultsKeys.serverURL)
            } else {
                UserDefaults.standard.removeObject(forKey: DefaultsKeys.serverURL)
            }
        }
        try? KeychainService.saveToken("stored-device-token", server: serverURL)
        DefaultsKeys.setDeviceId("dev_existing", server: serverURL)

        let failure = await configureWithoutGateway(
            connection,
            serverURL: serverURL,
            token: "stored-device-token"
        )

        XCTAssertNil(failure)
        XCTAssertEqual(
            DefaultsKeys.deviceId(server: serverURL),
            "dev_existing",
            "saved-token bootstrap/retry configure must not erase the recorded device_id"
        )
    }

    func testConfigureClearsStaleDeviceIdWhenNilIssuedDeviceIdUsesDifferentToken() async {
        let (connection, _, _) = makeStore()
        let serverURL = "https://gw.example:9121"
        let priorServerURL = UserDefaults.standard.string(forKey: DefaultsKeys.serverURL)
        KeychainService.deleteToken(server: serverURL)
        defer {
            KeychainService.deleteToken(server: serverURL)
            DefaultsKeys.setDeviceId(nil, server: serverURL)
            if let priorServerURL {
                UserDefaults.standard.set(priorServerURL, forKey: DefaultsKeys.serverURL)
            } else {
                UserDefaults.standard.removeObject(forKey: DefaultsKeys.serverURL)
            }
        }
        try? KeychainService.saveToken("stored-device-token", server: serverURL)
        DefaultsKeys.setDeviceId("dev_stale", server: serverURL)

        let failure = await configureWithoutGateway(
            connection,
            serverURL: serverURL,
            token: "manual-shared-token"
        )

        XCTAssertNil(failure)
        XCTAssertNil(
            DefaultsKeys.deviceId(server: serverURL),
            "nil-id configure with a different token must clear stale device_id so auto-upgrade can issue a fresh device token"
        )
        XCTAssertEqual(KeychainService.loadToken(server: serverURL), "manual-shared-token")
    }

    func testConfigureRecordsNonNilIssuedDeviceId() async {
        let (connection, _, _) = makeStore()
        let serverURL = "https://gw.example:9120"
        let priorServerURL = UserDefaults.standard.string(forKey: DefaultsKeys.serverURL)
        KeychainService.deleteToken(server: serverURL)
        defer {
            KeychainService.deleteToken(server: serverURL)
            DefaultsKeys.setDeviceId(nil, server: serverURL)
            if let priorServerURL {
                UserDefaults.standard.set(priorServerURL, forKey: DefaultsKeys.serverURL)
            } else {
                UserDefaults.standard.removeObject(forKey: DefaultsKeys.serverURL)
            }
        }
        DefaultsKeys.setDeviceId("dev_old", server: serverURL)

        let failure = await configureWithoutGateway(
            connection,
            serverURL: serverURL,
            token: "qr-v2-device-token",
            issuedDeviceId: "dev_new"
        )

        XCTAssertNil(failure)
        XCTAssertEqual(
            DefaultsKeys.deviceId(server: serverURL),
            "dev_new",
            "QR v2/device-token configure must replace the recorded device_id"
        )
    }

    func testOutOfOrderForeignOwnershipMarkerDegradesWithoutCrashing() async {
        let (_, sessions, chat) = makeStore()
        sessions.activeStoredId = "stored-foreign-guard"
        sessions.activeRuntimeId = "rt-local"

        chat.simulateOutOfOrderForeignOwnershipMarkerForTesting()

        XCTAssertTrue(chat.isStreaming, "the out-of-order foreign marker should still render as a conservative stream")
        XCTAssertFalse(chat.localTurnInFlight, "coercing a foreign marker must not claim local ownership")

        chat.handleConnectionDrop()

        XCTAssertFalse(chat.isStreaming, "the coerced foreign stream must be tear-downable after a transport drop")
        XCTAssertFalse(chat.localTurnInFlight, "the foreign guard path must not leak a local ownership token")
    }

    func testForeignTeardownWithLocalTokenDegradesThenConnectionDropFinalizesLocalTurn() async {
        let (_, sessions, chat) = makeStore()
        sessions.activeStoredId = "stored-foreign-teardown"
        sessions.activeRuntimeId = "rt-local"

        chat.simulateForeignTeardownWithLocalTurnTokenForTesting()

        XCTAssertTrue(chat.isStreaming, "the local turn must survive the refused foreign teardown")
        XCTAssertTrue(chat.localTurnInFlight, "foreign teardown must preserve local ownership instead of crashing")

        chat.handleConnectionDrop()

        XCTAssertFalse(chat.isStreaming, "a later real transport drop should finalize the still-local turn")
        XCTAssertFalse(chat.localTurnInFlight, "the transport-drop finalizer releases local ownership")
        XCTAssertEqual(chat.messages.last?.warning, "Connection lost")
    }
    #endif

    func testGatewayDiesMidTurnFinalizesReconnectingThenReattachesAndBackfills() async {
        let (connection, sessions, chat) = makeStore()
        let storedId = "stored-midturn"
        let oldRuntime = "rt-before-drop"
        let resumedRuntime = "rt-after-reconnect"
        var connectCount = 0
        var resumeCount = 0
        var backfillCount = 0

        connection.connectRPC = { _, _, _ in connectCount += 1 }
        sessions.resumeRPC = { stored, _ in
            resumeCount += 1
            XCTAssertEqual(stored, storedId)
            return self.stagedResumeResult(sessionId: resumedRuntime, resumed: storedId)
        }
        chat.backfillFetch = { stored in
            backfillCount += 1
            XCTAssertEqual(stored, storedId)
            return [
                self.storedMessage(role: "user", text: "prompt before gateway died"),
                self.storedMessage(role: "assistant", text: "authoritative recovered reply"),
            ]
        }

        connection._seedConnectedForTesting(serverURL: "http://localhost:9123", token: "test-stable-token")
        sessions.activeStoredId = storedId
        sessions.activeRuntimeId = oldRuntime
        chat.handle(event: frame(type: "message.start", runtime: oldRuntime))
        chat.handle(event: frame(
            type: "message.delta",
            runtime: oldRuntime,
            payload: .object(["text": .string("half a reply…")])
        ))
        chat.drainFlushForTesting()
        XCTAssertTrue(chat.isStreaming, "precondition: the gateway dies during an active stream")

        connection._handleGatewayStateForTesting(.failed("gateway process exited"))

        await connection.waitForReconnectForTesting()

        XCTAssertEqual(connection.phase, .connected)
        XCTAssertEqual(connectCount, 1, "the reconnect loop should reconnect once")
        XCTAssertEqual(resumeCount, 1, "the active stored session must be re-attached")
        XCTAssertEqual(backfillCount, 1, "the transcript must be refreshed after re-attach")
        XCTAssertEqual(sessions.activeRuntimeId, resumedRuntime)
        XCTAssertEqual(chat.messages.map(\.text), ["prompt before gateway died", "authoritative recovered reply"])
        XCTAssertFalse(chat.isStreaming, "the interrupted stream must not survive as a fake spinner")
        XCTAssertFalse(chat.localTurnInFlight, "local turn ownership must be released on transport loss")
        XCTAssertFalse(connection.reauthRequired, "a gateway restart must not be treated as token revocation")
        XCTAssertTrue(connection.hasConnected, "the shell must stay in the paired state while reconnecting")
    }

    // MARK: - Success criteria §1 + §2 + §3 — the core restart-survival proof

    /// Gateway restart at stable address+token: loop recovers to `.connected`
    /// with `reauthRequired == false` and `hasConnected` still `true`.
    ///
    /// This is the DEFINITIVE inc-4b assertion — maps directly to
    /// CONTRACT §End-state #4 + SPEC success criteria 2.
    func testReconnectLoopRecoversToDotConnectedAfterGatewayRestart() async {
        let (connection, _, _) = makeStore()

        // Inject an always-succeeding fake transport so no socket is opened.
        connection.connectRPC = { _, _, _ in
            // Simulates the gateway answering on the same stable address+token
            // (the restart-survival case: same URL, valid token, new process).
        }

        // Seed the in-memory state a prior configure() would have left:
        // serverURLString + token + hasConnected = true.
        connection._seedAndStartReconnect(
            serverURL: "http://localhost:9123",
            token: "test-stable-token"
        )

        // Await the task directly — deterministic on any VM speed.
        await connection.waitForReconnectForTesting()

        // §1: loop converges to .connected.
        XCTAssertEqual(connection.phase, .connected,
                       "a stable address+token must bring the phase to .connected")
        // §2: no re-pair prompt.
        XCTAssertFalse(connection.reauthRequired,
                       "a successful reconnect must NOT set reauthRequired")
        // §3: hasConnected must stay true (no first-run bounce).
        XCTAssertTrue(connection.hasConnected,
                      "hasConnected must remain true after a gateway restart recovery")
    }

    /// STR-249/STR-248: a transport drop that interrupts the initial hydration
    /// race sends `phase` to `.reconnecting` before the race resolves, which
    /// makes `finishHydration()`'s `phase == .hydrating` guard a no-op. Without
    /// the reconnect-success draft-entry call, a cold launch that blips once
    /// during connect strands the user on the "No conversation" placeholder
    /// (activeStoredId == nil, isDraft == false) instead of the composer.
    func testReconnectSuccessEntersDraftWhenNoActiveSession() async {
        let (connection, sessions, _) = makeStore()

        connection.connectRPC = { _, _, _ in }
        XCTAssertNil(sessions.activeStoredId)
        XCTAssertFalse(sessions.isDraft)

        connection._seedAndStartReconnect(
            serverURL: "http://localhost:9123",
            token: "test-stable-token"
        )
        await connection.waitForReconnectForTesting()

        XCTAssertEqual(connection.phase, .connected)
        XCTAssertTrue(sessions.isDraft,
                      "reconnect success with no active session must land on a draft chat, not the empty-state placeholder")
    }

    /// The other half of the same fix: a reconnect that resumes a REAL active
    /// session must NOT be stomped by the shared draft-entry call.
    func testReconnectSuccessDoesNotClobberActiveSession() async {
        let (connection, sessions, _) = makeStore()

        connection.connectRPC = { _, _, _ in }
        sessions.activeStoredId = "already-active-session"
        sessions.resumeRPC = { stored, _ in
            self.stagedResumeResult(sessionId: "runtime-after-reconnect", resumed: stored)
        }

        connection._seedAndStartReconnect(
            serverURL: "http://localhost:9123",
            token: "test-stable-token"
        )
        await connection.waitForReconnectForTesting()

        XCTAssertEqual(connection.phase, .connected)
        XCTAssertEqual(sessions.activeStoredId, "already-active-session",
                       "an already-active session must survive a reconnect-success draft-entry call")
        XCTAssertFalse(sessions.isDraft)
    }

    /// A live socket is not enough: the selected durable session must also have
    /// a runtime attachment. If `session.resume` fails transiently, reconnect
    /// must keep retrying instead of publishing `.connected` with a nil runtime
    /// and leaving restart as the only recovery path.
    func testReconnectRetriesWhenSessionResumeFailsTransiently() async {
        let (connection, sessions, _) = makeStore()
        let storedID = "stored-resume-retry"
        let runtimeID = "runtime-after-resume-retry"
        var connectCount = 0
        var resumeCount = 0

        connection.reconnectBackoffOverride = 0
        connection.connectRPC = { _, _, _ in connectCount += 1 }
        sessions.activeStoredId = storedID
        sessions.resumeRPC = { stored, _ in
            resumeCount += 1
            XCTAssertEqual(stored, storedID)
            if resumeCount == 1 { throw URLError(.timedOut) }
            return self.stagedResumeResult(sessionId: runtimeID, resumed: stored)
        }

        connection._seedAndStartReconnect(
            serverURL: "http://localhost:9123",
            token: "test-stable-token"
        )
        await connection.waitForReconnectForTesting()

        XCTAssertEqual(resumeCount, 2,
                       "a transient resume failure must remain inside the reconnect loop")
        XCTAssertEqual(connectCount, 2)
        XCTAssertEqual(sessions.activeRuntimeId, runtimeID)
        XCTAssertEqual(connection.phase, .connected)
    }

    /// A transient failure on attempt 0 followed by success on attempt 1
    /// (fail-once-then-succeed): the loop retries and still reaches `.connected`.
    ///
    /// Proves the backoff loop itself is exercised and the phase still converges.
    /// (Attempt 1 uses the normal backoff, but the test injects a zero-delay
    /// connect hook so the fake "network" resolves instantly.)
    func testReconnectLoopRetriesAndConvergesAfterTransientFailure() async {
        let (connection, _, _) = makeStore()

        // Zero-delay backoff so attempt 1 fires immediately after the failure,
        // regardless of VM speed.
        connection.reconnectBackoffOverride = 0

        var callCount = 0
        connection.connectRPC = { _, _, _ in
            callCount += 1
            if callCount == 1 {
                // Simulate the gateway being momentarily unreachable.
                throw URLError(.cannotConnectToHost)
            }
            // Second attempt succeeds (gateway restarted and is now answering).
        }

        connection._seedAndStartReconnect(
            serverURL: "http://localhost:9123",
            token: "test-stable-token"
        )

        // Await the task directly — no fixed sleep, deterministic on any VM.
        await connection.waitForReconnectForTesting()

        XCTAssertEqual(connection.phase, .connected,
                       "a transient connect failure must not prevent recovery")
        XCTAssertFalse(connection.reauthRequired,
                       "a transient failure must not set reauthRequired")
        XCTAssertTrue(connection.hasConnected,
                      "hasConnected must survive a fail-once-then-succeed loop")
        XCTAssertEqual(callCount, 2,
                       "the loop must have attempted exactly two connects")
    }

    // MARK: - Guard: loop stays in .reconnecting, not .needsSetup, on non-auth failure

    /// A single WS failure that is NOT an auth rejection must leave the phase
    /// in `.reconnecting` (keep retrying), not flip to `.needsSetup`.
    ///
    /// This pins the boundary between "gateway bounced" (retry) and "token
    /// revoked" (route to re-pair) — the core correctness guarantee of D3.
    func testSingleNonAuthFailureKeepsLoopReconnecting() async {
        let (connection, _, _) = makeStore()

        // connectRPC always fails with a non-auth transport error.
        connection.connectRPC = { _, _, _ in
            throw URLError(.timedOut)
        }

        connection._seedAndStartReconnect(
            serverURL: "http://localhost:9123",
            token: "test-stable-token"
        )

        // Let attempt 0 fail and the loop advance to attempt 1.
        await settle()

        // A single non-auth failure → still retrying, not re-pair.
        if case .reconnecting = connection.phase {
            // expected
        } else {
            XCTFail("expected .reconnecting after a single non-auth failure, got \(connection.phase)")
        }
        XCTAssertFalse(connection.reauthRequired,
                       "a non-auth failure must not set reauthRequired")
        XCTAssertTrue(connection.hasConnected,
                      "hasConnected must remain true while the loop is retrying")

        // Clean up: cancel the reconnect task so the test-process loop doesn't
        // keep running after the assertion window.
        await connection.disconnect()
    }

    // MARK: - Auth-revoke threshold (Task #5) — deterministic coverage

    /// Probe returning false → loop stays `.reconnecting` with `reauthRequired == false`.
    ///
    /// The WS always throws (`cannotConnectToHost`) so the loop hits
    /// `authReprobeThreshold` (3) quickly and calls `probeIsAuthRevoked`.
    /// With `probeIsAuthRevokedRPC = { false }` (no revocation) the loop must
    /// keep retrying, never flipping `reauthRequired` or routing to `.needsSetup`.
    ///
    /// `reconnectBackoffOverride = 0` eliminates backoff delay so many attempts
    /// fire within the 600ms settle window.
    func testBelowAuthReprobeThresholdStaysReconnecting() async {
        let (connection, _, _) = makeStore()

        // Zero-delay backoff so multiple attempts complete inside the settle window.
        connection.reconnectBackoffOverride = 0
        // Always-failing WS; probe returns false — gateway unreachable, not revoked.
        connection.connectRPC = { _, _, _ in throw URLError(.cannotConnectToHost) }
        connection.probeIsAuthRevokedRPC = { false }

        connection._seedAndStartReconnect(
            serverURL: "http://localhost:9123",
            token: "test-stable-token"
        )

        await settle()

        // Loop is still retrying — not routed to re-pair.
        if case .reconnecting = connection.phase { /* expected */ } else {
            XCTFail("expected .reconnecting when probe returns false, got \(connection.phase)")
        }
        XCTAssertFalse(connection.reauthRequired,
                       "reauthRequired must be false when probe returns false")
        XCTAssertTrue(connection.hasConnected,
                      "hasConnected must stay true while retrying")

        await connection.disconnect()
    }

    /// AT/ABOVE threshold with a positive REST probe: the loop sets
    /// `reauthRequired = true` and routes to `.needsSetup` — the re-pair prompt
    /// fires. This is the DEFINITIVE Task #5 assertion.
    ///
    /// `connectRPC` always throws (token revoked at the WS level).
    /// `reconnectBackoffOverride = 0` makes all ≥ threshold attempts fire fast.
    /// `probeIsAuthRevokedRPC` returns `true` on the first call (definitive 401).
    func testAtAuthReprobeThresholdWithRevocationSetsReauthRequired() async {
        let (connection, _, _) = makeStore()

        // Zero-delay backoff: threshold (3) consecutive failures fire quickly.
        connection.reconnectBackoffOverride = 0
        // Always failing — simulates a permanently revoked token at the WS gate.
        connection.connectRPC = { _, _, _ in throw URLError(.cannotConnectToHost) }
        // REST probe confirms revocation.
        connection.probeIsAuthRevokedRPC = { true }

        connection._seedAndStartReconnect(
            serverURL: "http://localhost:9123",
            token: "revoked-token"
        )

        // With zero backoff and threshold = 3, 3 attempts complete in < 50ms on
        // the main actor. A 600ms settle window is more than sufficient.
        await settle()

        // The loop must have escalated to re-pair.
        XCTAssertTrue(connection.reauthRequired,
                      "reauthRequired must flip true at authReprobeThreshold with revocation")
        XCTAssertEqual(connection.phase, .needsSetup,
                       "phase must be .needsSetup after auth revocation")
        // hasConnected is intentionally cleared when reauthRequired is set —
        // the user must go through re-pair, not be left on the shell.
        // (The loop sets phase = .needsSetup AND reconnectTask = nil, so the
        // loop has exited; hasConnected is NOT cleared by the loop itself —
        // it is cleared by disconnect() or a fresh configure().)
    }

    /// A sub-threshold auth blip followed by a successful connect clears the
    /// failure counter — a later run of failures starts fresh without a spurious
    /// re-pair trigger.
    ///
    /// This pins that `consecutiveReconnectFailures` is reset to 0 on success,
    /// so two separate 2-failure episodes (each below threshold) do not
    /// accumulate to trigger a false revocation.
    func testSuccessAfterSubThresholdBlipClearsFailureCount() async {
        let (connection, _, _) = makeStore()

        connection.reconnectBackoffOverride = 0
        // Probe always returns false — a spurious call would be a bug.
        connection.probeIsAuthRevokedRPC = { false }

        var callCount = 0
        connection.connectRPC = { _, _, _ in
            callCount += 1
            if callCount <= 2 {
                // Two sub-threshold failures (threshold = 3).
                throw URLError(.cannotConnectToHost)
            }
            // Third attempt succeeds — clears the counter.
        }

        connection._seedAndStartReconnect(
            serverURL: "http://localhost:9123",
            token: "test-stable-token"
        )

        // Await the task directly — deterministic on any VM speed.
        await connection.waitForReconnectForTesting()

        // Loop converged — failure count must have been cleared.
        XCTAssertEqual(connection.phase, .connected,
                       "loop must reach .connected after sub-threshold blip + success")
        XCTAssertFalse(connection.reauthRequired,
                       "a sub-threshold blip followed by success must not set reauthRequired")
        XCTAssertTrue(connection.hasConnected,
                      "hasConnected must stay true through a blip-then-recover cycle")
        XCTAssertEqual(callCount, 3,
                       "exactly 3 connect attempts: 2 fail + 1 succeed")
    }

    // MARK: - Stable URL is preserved after a reconnect (hardening)

    /// The persisted server URL must survive a reconnect cycle — the URL the
    /// test seeds is the same URL the loop reads during the reconnect attempt.
    ///
    /// If the URL were cleared or mangled mid-loop the guard at line ~1056 would
    /// hit `serverURLString` being empty and bail to `.needsSetup`. This test
    /// pins the "URL is never clobbered by the loop itself" property.
    func testServerURLIsPreservedThroughReconnectCycle() async {
        let (connection, _, _) = makeStore()
        // Use loopback (fast connection-refused on the sim, not a routable LAN
        // address that could time out). The assertion is on URL identity, not
        // on the host value — any valid URL proves the property.
        let stableURL = "http://localhost:9123"

        connection.connectRPC = { url, _, _ in
            // Assert the URL the loop resolved matches what was seeded.
            XCTAssertEqual(url.absoluteString, stableURL,
                           "reconnect loop must use the saved stable URL verbatim")
        }

        connection._seedAndStartReconnect(serverURL: stableURL, token: "tok")
        await connection.waitForReconnectForTesting()

        XCTAssertEqual(connection.phase, .connected)
        XCTAssertEqual(connection.serverURLString, stableURL,
                       "serverURLString must be unchanged after a successful reconnect")
    }

    // MARK: - STR-973A silent reconnect grace

    /// The core "never flash an error on a quick heal" guarantee: a transport
    /// drop whose attempt-0 reconnect succeeds inside the grace window must
    /// never surface `.reconnecting` and must never stamp a "Connection lost"
    /// warning — the interrupted stream is still finalized silently (so
    /// `backfill()` can run) but with no visible trace of the blip.
    func testHealInsideGraceProducesNoWarningAndNoVisibleReconnecting() async {
        let (connection, sessions, chat) = makeStore()

        // A long grace window: attempt 0 must heal well inside it, proving the
        // heal — not the timer — is what ends grace.
        connection.graceWindowOverride = .seconds(30)
        connection.connectRPC = { _, _, _ in }

        // Deliberately no `activeStoredId`: `recoverActiveSession()` then skips
        // `backfill()` entirely, so the transcript below is left exactly as the
        // silent finalize (or a stray visible warning) leaves it — a direct
        // window onto `handleConnectionDrop(stampWarning:)`, undisturbed by a
        // backfill overwrite that would trivially satisfy a "no warning" check
        // regardless of what the finalize actually did.
        connection._seedConnectedForTesting(serverURL: "http://localhost:9123", token: "test-stable-token")
        sessions.activeRuntimeId = "rt-before-drop"
        chat.handle(event: frame(type: "message.start", runtime: "rt-before-drop"))
        chat.handle(event: frame(
            type: "message.delta",
            runtime: "rt-before-drop",
            payload: .object(["text": .string("half a reply…")])
        ))
        chat.drainFlushForTesting()
        XCTAssertTrue(chat.isStreaming, "precondition: the gateway dies during an active stream")

        connection._handleGatewayStateForTesting(.failed("gateway process exited"))

        // Synchronously, right after the drop: grace is live and the phase has
        // NOT moved to a visible .reconnecting.
        XCTAssertTrue(connection.isInGrace, "a fresh drop must enter grace, not go straight visible")
        XCTAssertEqual(connection.phase, .connected, "phase must stay .connected while grace is live")

        await connection.waitForReconnectForTesting()

        XCTAssertEqual(connection.phase, .connected,
                       "attempt-0 healing inside grace must converge to .connected")
        XCTAssertFalse(connection.isInGrace, "a successful heal must end grace")
        XCTAssertFalse(chat.isStreaming, "the interrupted stream must still be finalized silently")
        XCTAssertNil(chat.messages.last?.warning,
                     "a heal inside grace must never stamp a visible Connection lost warning")
    }

    /// STR-1126 regression: a grace timer that expires WHILE `recoverActiveSession()`
    /// is still suspended on network I/O must never flash a visible
    /// `.reconnecting` state on a reconnect that already succeeded.
    ///
    /// Before the fix, `endGrace()` ran AFTER the awaited
    /// `recoverActiveSession()` call. `recoverActiveSession()` has genuine
    /// `await` suspension points (`resumeActiveAfterReconnect`/`backfill`),
    /// during which the MainActor is free — so the armed `graceTask`
    /// continuation could fire `escalateGraceExpiry()`, whose only guard is
    /// `isInGrace` (still `true`, since `endGrace()` hadn't run yet). That
    /// unconditionally flipped `phase` to `.reconnecting` even though the
    /// socket had already reconnected, only for the loop to silently
    /// overwrite it back to `.connected` once `recoverActiveSession()`
    /// finally returned — a spurious banner flash invisible to a
    /// final-state-only assertion.
    ///
    /// This test seeds `activeStoredId` so `recoverActiveSession()` takes the
    /// real `resumeActiveAfterReconnect()` + `backfill()` path, and stubs
    /// `resumeRPC` to sleep well past a short `graceWindowOverride` deadline —
    /// so the grace timer's expiry genuinely straddles the suspension. It then
    /// inspects `phase`/`isInGrace` mid-flight (before `recoverActiveSession()`
    /// resolves) to catch the race a final-state check would miss.
    func testSuccessfulHealSurvivesGraceExpiryDuringSuspendedRecovery() async {
        let (connection, sessions, chat) = makeStore()

        // Short grace window: it WILL elapse before the resume stub below
        // resolves, so the timer fires while the loop is still suspended
        // inside `recoverActiveSession()`.
        connection.graceWindowOverride = .milliseconds(50)
        connection.connectRPC = { _, _, _ in }

        // `activeStoredId` routes `recoverActiveSession()` through
        // `resumeActiveAfterReconnect()` — the genuine network await this
        // regression needs. The stub sleeps well past the grace deadline so
        // the suspension straddles expiry.
        sessions.activeStoredId = "stored-race"
        sessions.resumeRPC = { stored, _ in
            try? await Task.sleep(for: .milliseconds(300))
            return self.stagedResumeResult(sessionId: "rt-after-reconnect", resumed: stored)
        }
        chat.backfillFetch = { _ in [] }

        connection._seedConnectedForTesting(serverURL: "http://localhost:9123", token: "test-stable-token")
        sessions.activeRuntimeId = "rt-before-drop"
        chat.handle(event: frame(type: "message.start", runtime: "rt-before-drop"))
        chat.handle(event: frame(
            type: "message.delta",
            runtime: "rt-before-drop",
            payload: .object(["text": .string("half a reply…")])
        ))
        chat.drainFlushForTesting()
        XCTAssertTrue(chat.isStreaming, "precondition: the gateway dies during an active stream")

        connection._handleGatewayStateForTesting(.failed("gateway process exited"))
        XCTAssertTrue(connection.isInGrace, "a fresh drop must enter grace")

        // Land after the 50ms grace deadline but well before the 300ms resume
        // stub resolves — recoverActiveSession() is still suspended here.
        try? await Task.sleep(for: .milliseconds(150))

        XCTAssertFalse(connection.isInGrace,
                       "a successful connect must end grace immediately, not leave it dangling into the suspended recovery")
        XCTAssertEqual(connection.phase, .connected,
                       "grace expiring mid-recovery must never flash .reconnecting on a reconnect that already succeeded")

        await connection.waitForReconnectForTesting()

        XCTAssertEqual(connection.phase, .connected,
                       "the loop must converge to .connected once recovery finishes")
        XCTAssertFalse(connection.isInGrace, "grace must stay ended after the full recovery completes")
        XCTAssertNil(chat.messages.last?.warning,
                     "grace expiring mid-recovery must never stamp a spurious Connection lost warning on a healed reconnect")
    }

    /// The escalation path: grace expires while the reconnect loop is STILL
    /// failing. Only then may the stranded turn be dropped visibly — exactly
    /// one "Connection lost" warning, and the phase becomes `.reconnecting`.
    func testGraceExpiryWithOngoingFailureStampsOneWarningAndEscalates() async {
        let (connection, sessions, chat) = makeStore()

        // A short, deterministic grace window; zero-delay backoff so the loop
        // keeps retrying (and failing) fast underneath it.
        connection.graceWindowOverride = .milliseconds(50)
        connection.reconnectBackoffOverride = 0
        connection.connectRPC = { _, _, _ in throw URLError(.cannotConnectToHost) }
        connection.probeIsAuthRevokedRPC = { false }

        connection._seedConnectedForTesting(serverURL: "http://localhost:9123", token: "test-stable-token")
        sessions.activeStoredId = "stored-grace-expiry"
        sessions.activeRuntimeId = "rt-before-drop"
        chat.handle(event: frame(type: "message.start", runtime: "rt-before-drop"))
        chat.handle(event: frame(
            type: "message.delta",
            runtime: "rt-before-drop",
            payload: .object(["text": .string("half a reply…")])
        ))
        chat.drainFlushForTesting()
        XCTAssertTrue(chat.isStreaming, "precondition: the gateway dies during an active stream")

        connection._handleGatewayStateForTesting(.failed("gateway process exited"))
        XCTAssertTrue(connection.isInGrace, "a fresh drop must enter grace")

        // Wait past the 50ms grace window; the retry loop is still failing
        // throughout, so escalation must fire.
        await settle()

        XCTAssertFalse(connection.isInGrace, "grace must have expired and ended")
        if case .reconnecting = connection.phase { /* expected */ } else {
            XCTFail("expected .reconnecting after grace expiry with ongoing failure, got \(connection.phase)")
        }
        XCTAssertFalse(chat.isStreaming, "the stranded stream must be finalized on escalation")
        XCTAssertEqual(chat.messages.last?.warning, "Connection lost",
                       "exactly one visible warning must land once grace actually expires")

        await connection.disconnect()
    }

    /// A hard auth revocation must never be swallowed by grace, no matter how
    /// long the grace window is — the re-pair escalation is unconditional.
    func testAuthRevocationDuringGraceStillRoutesToReauth() async {
        let (connection, sessions, _) = makeStore()

        // Deliberately long grace — proves the auth-revoke branch bypasses
        // grace entirely rather than waiting for the timer.
        connection.graceWindowOverride = .seconds(30)
        connection.reconnectBackoffOverride = 0
        connection.connectRPC = { _, _, _ in throw URLError(.cannotConnectToHost) }
        connection.probeIsAuthRevokedRPC = { true }

        connection._seedConnectedForTesting(serverURL: "http://localhost:9123", token: "revoked-token")
        sessions.activeStoredId = "stored-grace-auth"

        connection._handleGatewayStateForTesting(.failed("gateway process exited"))
        XCTAssertTrue(connection.isInGrace, "a fresh drop must enter grace")

        await connection.waitForReconnectForTesting()

        XCTAssertTrue(connection.reauthRequired,
                      "an auth revocation must still flip reauthRequired even while grace was live")
        XCTAssertEqual(connection.phase, .needsSetup,
                       "an auth revocation must still route to .needsSetup regardless of grace")
        XCTAssertFalse(connection.isInGrace, "grace must be ended, not left dangling, on auth revoke")
    }

    // MARK: - Build 120 transport readiness / epoch contract

    /// A silent reconnect may preserve `.connected` for presentation, but it
    /// must revoke operational readiness immediately. The waiter must survive
    /// that transient unavailable state and resolve only after the replacement
    /// socket has completed its ready handshake (represented by `connectRPC`).
    func testGraceRevokesTransportReadinessUntilNewEpochIsAccepted() async {
        let (connection, _, _) = makeStore()
        let gate = SuspensionGate()

        connection._seedConnectedForTesting(
            serverURL: "http://127.0.0.1:9123", token: "test-token"
        )
        let priorEpoch = connection.transportEpoch
        XCTAssertTrue(connection.isTransportReady)
        XCTAssertEqual(connection.transportReadiness, .ready(epoch: priorEpoch))

        connection.connectRPC = { _, _, _ in await gate.suspend() }
        connection._handleGatewayStateForTesting(.failed("background socket dropped"))
        await gate.waitUntilEntered()

        XCTAssertEqual(connection.phase, .connected,
                       "grace deliberately preserves the presentation phase")
        XCTAssertTrue(connection.isInGrace)
        XCTAssertFalse(connection.isTransportReady,
                       "presentation grace must never admit transport work")
        XCTAssertEqual(
            connection.transportReadiness,
            .connecting(epoch: priorEpoch + 1),
            "the reconnect attempt owns a fresh transport epoch"
        )

        let readinessWaiter = Task { await connection.waitForTransportReady(timeout: .seconds(2)) }
        await Task.yield()
        await gate.release()

        let becameReady = await readinessWaiter.value
        XCTAssertTrue(becameReady)
        await connection.waitForReconnectForTesting()
        XCTAssertTrue(connection.isTransportReady)
        XCTAssertEqual(connection.transportReadiness, .ready(epoch: priorEpoch + 1))
    }

    /// Timeout, cancellation, and terminal teardown must resolve a readiness
    /// waiter with `false`; no caller may remain parked after its connection
    /// generation is deliberately invalidated.
    func testTransportReadinessWaiterTimeoutsCancelsAndTeardownResolvesFalse() async {
        let (connection, _, _) = makeStore()
        let gate = SuspensionGate()
        connection._seedConnectedForTesting(
            serverURL: "http://127.0.0.1:9123", token: "test-token"
        )
        connection.connectRPC = { _, _, _ in await gate.suspend() }
        connection._handleGatewayStateForTesting(.failed("background socket dropped"))
        await gate.waitUntilEntered()

        let timedOutResult = await connection.waitForTransportReady(timeout: .milliseconds(20))
        XCTAssertFalse(timedOutResult)

        let cancelledWaiter = Task {
            await connection.waitForTransportReady(timeout: .seconds(30))
        }
        await Task.yield()
        cancelledWaiter.cancel()
        let cancelledResult = await cancelledWaiter.value
        XCTAssertFalse(cancelledResult)

        let terminalWaiter = Task {
            await connection.waitForTransportReady(timeout: .seconds(30))
        }
        await Task.yield()
        await connection.disconnect()
        let terminalResult = await terminalWaiter.value
        XCTAssertFalse(terminalResult)

        // The injected hook is intentionally not cancellation-aware; release it
        // so this deterministic test leaves no parked test task behind.
        await gate.release()
        await connection.waitForReconnectForTesting()
    }

    func testTransportDropInvalidatesRuntimeButRetainsLatestStoredSelection() async {
        let (connection, sessions, _) = makeStore()
        let gate = SuspensionGate()
        connection._seedConnectedForTesting(
            serverURL: "http://127.0.0.1:9123", token: "test-token"
        )
        sessions.activeStoredId = "A"
        sessions.resumeRPC = { requested, _ in
            XCTAssertEqual(requested, "A")
            return self.stagedResumeResult(sessionId: "runtime-A", resumed: "A")
        }
        let resumed = await sessions.resumeActiveAfterReconnect()
        XCTAssertEqual(resumed, "runtime-A")
        XCTAssertEqual(sessions.activeRuntimeId, "runtime-A")

        connection.connectRPC = { _, _, _ in await gate.suspend() }
        connection._handleGatewayStateForTesting(.failed("background socket dropped"))
        await gate.waitUntilEntered()

        XCTAssertEqual(sessions.activeStoredId, "A",
                       "the durable drawer selection survives transient reconnect")
        XCTAssertNil(sessions.activeRuntimeId,
                     "a runtime from the dropped transport epoch may not be reused")
        XCTAssertNil(sessions.sessionActionError,
                     "transport loss is not a user-visible session-open failure")

        await gate.release()
        await connection.waitForReconnectForTesting()
    }

    func testLateEpochFailureIsIgnoredAfterReplacementTransportBecomesReady() async {
        let (connection, sessions, _) = makeStore()
        let gate = SuspensionGate()
        connection._seedConnectedForTesting(
            serverURL: "http://127.0.0.1:9123", token: "test-token"
        )
        let epochN = connection.transportEpoch
        sessions.activeStoredId = "A"
        sessions.resumeRPC = { _, _ in
            await gate.suspend()
            throw URLError(.networkConnectionLost)
        }

        let resume = Task { await sessions.resumeActiveAfterReconnect() }
        await gate.waitUntilEntered()

        // The failed RPC belongs to epoch N. A replacement ready epoch must
        // fence its catch path before it can set an alert on the current UI.
        connection._seedConnectedForTesting(
            serverURL: "http://127.0.0.1:9123", token: "test-token"
        )
        XCTAssertEqual(connection.transportEpoch, epochN + 1)
        await gate.release()
        let resumed = await resume.value
        XCTAssertNil(resumed)

        XCTAssertNil(sessions.sessionActionError)
        XCTAssertNil(sessions.lastError)
        XCTAssertNil(sessions.activeRuntimeId)
    }

    func testOpenDuringReconnectAndRecoveryIssueOneResumeForLatestSelection() async {
        let (connection, sessions, _) = makeStore()
        let reconnectGate = SuspensionGate()
        let calls = ResumeCallLog()
        connection._seedConnectedForTesting(
            serverURL: "http://127.0.0.1:9123", token: "test-token"
        )
        sessions.activeStoredId = "A"
        sessions.resumeRPC = { stored, _ in
            await calls.append(stored)
            return self.stagedResumeResult(sessionId: "runtime-\(stored)", resumed: stored)
        }
        connection.connectRPC = { _, _, _ in await reconnectGate.suspend() }

        connection._handleGatewayStateForTesting(.failed("background socket dropped"))
        await reconnectGate.waitUntilEntered()
        sessions.open(self.sessionSummary("B"))

        await reconnectGate.release()
        await connection.waitForReconnectForTesting()
        await sessions.waitForPendingOpenForTesting()

        let aCalls = await calls.calls(for: "A")
        let bCalls = await calls.calls(for: "B")
        XCTAssertEqual(aCalls, 0)
        XCTAssertEqual(bCalls, 1,
                       "readiness-released open(B) and recovery must share one resume")
        XCTAssertEqual(sessions.activeStoredId, "B")
        XCTAssertEqual(sessions.activeRuntimeId, "runtime-B")
    }

    // MARK: - ABH-448 connection-generation fencing

    func testLateOpenAndClosedFromForgottenGenerationCannotRestoreConnection() async {
        let (connection, _, _) = makeStore()
        let server = "https://generation-socket.example"
        UserDefaults.standard.set(server, forKey: DefaultsKeys.serverURL)
        connection._seedConnectedForTesting(serverURL: server, token: "revoked")
        let staleGeneration = connection._connectionGenerationForTesting

        await connection.forgetGateway()
        connection._handleGatewayStateForTesting(.open, generation: staleGeneration)
        connection._handleGatewayStateForTesting(.closed(reason: nil), generation: staleGeneration)
        connection._handleGatewayStateForTesting(.open)

        XCTAssertEqual(connection.phase, .needsSetup)
        XCTAssertFalse(connection.hasConnected)
        XCTAssertNil(connection.reconnectTask)
    }

    func testSuspendedBootstrapCannotPublishAfterForgetChangesGeneration() async {
        let (connection, _, _) = makeStore()
        let gate = SuspensionGate()
        let server = "https://generation-bootstrap.example"
        UserDefaults.standard.set(server, forKey: DefaultsKeys.serverURL)
        try? KeychainService.saveToken("token", server: server)
        connection._skipEnvironmentBootstrapForTesting = true
        connection.statusRPC = { _, _ in await gate.suspend() }
        connection.connectRPC = { _, _, _ in }
        defer { KeychainService.deleteToken(server: server) }

        let bootstrap = Task { await connection.bootstrap() }
        await gate.waitUntilEntered()
        await connection.forgetGateway()
        await gate.release()
        await bootstrap.value

        XCTAssertEqual(connection.phase, .needsSetup)
        XCTAssertFalse(connection.hasConnected)
        XCTAssertNil(connection.reconnectTask)
    }

    func testSuspendedHydrationCannotFinishAfterForgetChangesGeneration() async {
        let (connection, sessions, _) = makeStore()
        let gate = SuspensionGate()
        let server = "https://generation-hydrate.example"
        sessions.sessionsFetch = {
            await gate.suspend()
            return ([self.sessionSummary("stale-hydration")], 1)
        }

        let configureError = await configureWithoutGateway(
            connection, serverURL: server, token: "token"
        )
        XCTAssertNil(configureError)
        await gate.waitUntilEntered()
        await connection.forgetGateway()
        await gate.release()
        await settle()

        XCTAssertEqual(connection.phase, .needsSetup)
        XCTAssertFalse(connection.hasConnected)
        XCTAssertNil(connection.reconnectTask)
        XCTAssertTrue(sessions.sessions.isEmpty,
                      "stale hydration must not repopulate forgotten session surfaces")
    }

    func testSuspendedReconnectCompletionCannotPublishConnectedAfterForget() async {
        let (connection, _, _) = makeStore()
        let gate = SuspensionGate()
        let server = "https://generation-connect.example"
        UserDefaults.standard.set(server, forKey: DefaultsKeys.serverURL)
        connection.connectRPC = { _, _, _ in await gate.suspend() }

        connection._seedAndStartReconnect(serverURL: server, token: "token")
        await gate.waitUntilEntered()
        await connection.forgetGateway()
        await gate.release()
        await connection.waitForReconnectForTesting()

        XCTAssertEqual(connection.phase, .needsSetup)
        XCTAssertFalse(connection.hasConnected)
        XCTAssertNil(connection.reconnectTask)
    }

    func testSuspendedSessionRecoveryCannotPublishConnectedAfterForget() async {
        let (connection, sessions, _) = makeStore()
        let gate = SuspensionGate()
        let server = "https://generation-recover.example"
        UserDefaults.standard.set(server, forKey: DefaultsKeys.serverURL)
        connection.connectRPC = { _, _, _ in }
        sessions.activeStoredId = "stored-stale"
        sessions.resumeRPC = { stored, _ in
            await gate.suspend()
            return self.stagedResumeResult(sessionId: "runtime-stale", resumed: stored)
        }

        connection._seedAndStartReconnect(serverURL: server, token: "token")
        await gate.waitUntilEntered()
        await connection.forgetGateway()
        await gate.release()
        await connection.waitForReconnectForTesting()

        XCTAssertEqual(connection.phase, .needsSetup)
        XCTAssertFalse(connection.hasConnected)
        XCTAssertNil(connection.reconnectTask)
        XCTAssertNil(sessions.activeRuntimeId,
                     "stale recovery must not bind its runtime into the forgotten session")
    }

    func testSuspendedForegroundHealthProbeCannotScheduleReconnectAfterForget() async {
        let (connection, _, _) = makeStore()
        let gate = SuspensionGate()
        let server = "https://generation-scene.example"
        UserDefaults.standard.set(server, forKey: DefaultsKeys.serverURL)
        connection._seedConnectedForTesting(serverURL: server, token: "token")
        connection.clientStateOverrideForScenePhase = .open
        connection.probeLivenessRPC = { _ in
            await gate.suspend()
            return false
        }

        connection.handleScenePhase(.active)
        await gate.waitUntilEntered()
        await connection.forgetGateway()
        await gate.release()
        await settle()

        XCTAssertEqual(connection.phase, .needsSetup)
        XCTAssertFalse(connection.hasConnected)
        XCTAssertNil(connection.reconnectTask)
    }

    func testSuspendedAuthProbeCannotEscalateOrReconnectAfterForget() async {
        let (connection, _, _) = makeStore()
        let gate = SuspensionGate()
        let server = "https://generation-auth-probe.example"
        UserDefaults.standard.set(server, forKey: DefaultsKeys.serverURL)
        connection.reconnectBackoffOverride = 0
        connection.connectRPC = { _, _, _ in throw URLError(.cannotConnectToHost) }
        connection.probeIsAuthRevokedRPC = {
            await gate.suspend()
            return true
        }

        connection._seedAndStartReconnect(serverURL: server, token: "token")
        await gate.waitUntilEntered()
        await connection.forgetGateway()
        await gate.release()
        await connection.waitForReconnectForTesting()

        XCTAssertEqual(connection.phase, .needsSetup)
        XCTAssertFalse(connection.reauthRequired)
        XCTAssertFalse(connection.hasConnected)
        XCTAssertNil(connection.reconnectTask)
    }

    // MARK: - S3: self-reconnect when the network returns (NWPathMonitor seam)

    #if DEBUG
    /// Deterministic fake `NetworkPathMonitoring`: records lifecycle and lets a
    /// test push path transitions synchronously on the main actor.
    @MainActor
    private final class FakePathMonitor: NetworkPathMonitoring {
        var onPathUpdate: ((NetworkPathStatus) -> Void)?
        private(set) var started = false
        private(set) var cancelled = false
        func start() { started = true }
        func cancel() { cancelled = true }
        func emit(_ status: NetworkPathStatus) { onPathUpdate?(status) }
    }

    private func withSavedServer(
        _ server: String,
        token: String,
        _ body: () async -> Void
    ) async {
        let priorServerURL = UserDefaults.standard.string(forKey: DefaultsKeys.serverURL)
        let priorOffline = UserDefaults.standard.bool(forKey: DefaultsKeys.connectionOffline)
        KeychainService.deleteToken(server: server)
        UserDefaults.standard.removeObject(forKey: DefaultsKeys.connectionOffline)
        UserDefaults.standard.set(server, forKey: DefaultsKeys.serverURL)
        try? KeychainService.saveToken(token, server: server)
        defer {
            KeychainService.deleteToken(server: server)
            if let priorServerURL {
                UserDefaults.standard.set(priorServerURL, forKey: DefaultsKeys.serverURL)
            } else {
                UserDefaults.standard.removeObject(forKey: DefaultsKeys.serverURL)
            }
            UserDefaults.standard.set(priorOffline, forKey: DefaultsKeys.connectionOffline)
        }
        await body()
    }

    /// S3 core: a cold-launch-offline store (REST probe failed → terminal
    /// `.offline`, `hasConnected == false`) reconnects BY ITSELF when the path
    /// becomes `.satisfied` — no force-quit, no foreground event.
    func testPathSatisfiedLiftsColdLaunchOfflineAndReconnects() async {
        let (connection, _, _) = makeStore()
        connection._skipEnvironmentBootstrapForTesting = true
        let server = "https://s3-cold.example:9119"
        await withSavedServer(server, token: "tok") {
            let fake = FakePathMonitor()
            connection._pathMonitorForTesting = fake
            connection.networkReconnectDebounceOverride = .milliseconds(5)

            // Cold-launch-offline: the REST probe throws, so configure returns
            // terminal `.offline` with `hasConnected == false`, but the monitor
            // was armed before the probe.
            connection.statusRPC = { _, _ in throw URLError(.notConnectedToInternet) }
            connection.connectRPC = { _, _, _ in }
            _ = await connection.configure(urlString: server, token: "tok")

            guard case .offline = connection.phase else {
                return XCTFail("cold configure failure must land in .offline, got \(connection.phase)")
            }
            XCTAssertFalse(connection.hasConnected)
            XCTAssertTrue(fake.started, "monitor must be armed even when configure fails offline")

            // Network returns: the probe now succeeds. Emitting `.satisfied`
            // must self-heal without any further user action.
            connection.statusRPC = { _, _ in }
            fake.emit(.satisfied)
            await settle()

            XCTAssertTrue(connection.hasConnected, "path-satisfied must reconnect from cold offline")
            if case .offline = connection.phase {
                XCTFail("still offline after path-satisfied reconnect: \(connection.phase)")
            }
        }
    }

    /// A rapidly flapping path (satisfied/unsatisfied/satisfied…) collapses to a
    /// SINGLE reconnect attempt via the trailing-edge debounce.
    func testFlappingPathDebouncesToSingleReconnectAttempt() async {
        let (connection, _, _) = makeStore()
        connection._skipEnvironmentBootstrapForTesting = true
        let server = "https://s3-flap.example:9119"
        await withSavedServer(server, token: "tok") {
            let fake = FakePathMonitor()
            connection._pathMonitorForTesting = fake
            connection.networkReconnectDebounceOverride = .milliseconds(30)

            let connectCalls = ResumeCallLog()
            connection.statusRPC = { _, _ in throw URLError(.notConnectedToInternet) }
            connection.connectRPC = { _, _, _ in await connectCalls.append(server) }
            _ = await connection.configure(urlString: server, token: "tok")
            guard case .offline = connection.phase else {
                return XCTFail("cold configure failure must land in .offline, got \(connection.phase)")
            }
            // Probe reachable now; only the trailing debounce should reconnect.
            connection.statusRPC = { _, _ in }

            // Burst of transitions inside one debounce window (all synchronous on
            // the main actor, so every `.satisfied` cancels the prior pending
            // kick before it can run).
            fake.emit(.satisfied)
            fake.emit(.unsatisfied)
            fake.emit(.satisfied)
            fake.emit(.unsatisfied)
            fake.emit(.satisfied)
            await settle()

            let calls = await connectCalls.calls(for: server)
            XCTAssertEqual(calls, 1, "flapping path must debounce to a single reconnect attempt")
            XCTAssertTrue(connection.hasConnected)
        }
    }

    /// An already-connected store ignores a `.satisfied` path event — no
    /// reconnect loop, no churn.
    func testPathSatisfiedIsNoOpWhenAlreadyConnected() async {
        let (connection, _, _) = makeStore()
        let server = "https://s3-connected.example:9119"
        let connectCalls = ResumeCallLog()
        connection.networkReconnectDebounceOverride = .milliseconds(5)
        connection.connectRPC = { _, _, _ in await connectCalls.append(server) }
        let fake = FakePathMonitor()
        connection._pathMonitorForTesting = fake
        connection._startPathMonitorForTesting()
        connection._seedConnectedForTesting(serverURL: server, token: "tok")
        XCTAssertEqual(connection.phase, .connected)

        fake.emit(.satisfied)
        await settle()

        XCTAssertEqual(connection.phase, .connected)
        XCTAssertNil(connection.reconnectTask, "a live connection must not spawn a reconnect loop")
        let calls = await connectCalls.calls(for: server)
        XCTAssertEqual(calls, 0, "path-satisfied must be a no-op while connected")
    }
    #endif

    // MARK: - WS-RECONNECT-SOFTEN (b): single-flight reconnect across triggers

    #if DEBUG
    /// The core single-flight regression: a network-path-satisfied event that
    /// arrives while the CURRENT reconnect attempt's handshake is already in
    /// flight must NOT cancel and restart it. Before this guard, an overlapping
    /// trigger during a flapping path could repeatedly abort an attempt just
    /// before it would have succeeded — livelocking reconnection during exactly
    /// the flappy window these triggers exist to help.
    func testNetworkPathSatisfiedDuringInFlightHandshakeDoesNotRestartAttempt() async {
        let (connection, _, _) = makeStore()
        let server = "https://s3-inflight.example:9119"
        let gate = SuspensionGate()
        let connectCalls = ResumeCallLog()
        connection.networkReconnectDebounceOverride = .milliseconds(5)
        connection.connectRPC = { _, _, _ in
            await connectCalls.append(server)
            // Suspend forever (until released) to represent a handshake that is
            // genuinely still in flight when the network trigger fires.
            await gate.suspend()
        }
        let fake = FakePathMonitor()
        connection._pathMonitorForTesting = fake
        connection._startPathMonitorForTesting()
        connection._seedAndStartReconnect(serverURL: server, token: "tok")

        await gate.waitUntilEntered()
        XCTAssertEqual(connection.phase, .reconnecting(attempt: 0))
        var calls = await connectCalls.calls(for: server)
        XCTAssertEqual(calls, 1)

        // The path "returns" while attempt 0's handshake is still suspended
        // inside `connectRPC`. Single-flight must leave it alone.
        fake.emit(.satisfied)
        await settle()

        calls = await connectCalls.calls(for: server)
        XCTAssertEqual(
            calls, 1,
            "an in-flight handshake must not be cancelled and restarted by an overlapping network-return trigger"
        )
        XCTAssertEqual(
            connection.phase, .reconnecting(attempt: 0),
            "the in-flight attempt must still be the original attempt 0, not restarted"
        )

        // Let the original attempt resolve — it must still be able to succeed.
        await gate.release()
        await settle()
        XCTAssertEqual(connection.phase, .connected)
    }

    /// Control case: a network-path-satisfied event that arrives while the loop
    /// is PARKED in backoff (no handshake in flight) still resets it to an
    /// immediate retry — the single-flight guard must not suppress this, only
    /// an actively in-flight handshake.
    func testNetworkPathSatisfiedDuringParkedBackoffStillResetsToImmediateRetry() async {
        let (connection, _, _) = makeStore()
        let server = "https://s3-parked.example:9119"
        // A long fixed backoff so the loop is reliably parked in
        // `Task.sleep` (not connecting) when the path event fires.
        connection.reconnectBackoffOverride = 30
        connection.networkReconnectDebounceOverride = .milliseconds(5)
        let connectCalls = ResumeCallLog()
        connection.connectRPC = { _, _, _ in
            await connectCalls.append(server)
            if await connectCalls.calls(for: server) == 1 {
                throw URLError(.cannotConnectToHost)
            }
        }
        let fake = FakePathMonitor()
        connection._pathMonitorForTesting = fake
        connection._startPathMonitorForTesting()
        connection._seedAndStartReconnect(serverURL: server, token: "tok")

        // Attempt 0 fires immediately and fails, parking the loop in its
        // (overridden, 30s) backoff sleep before attempt 1.
        await settle()
        var calls = await connectCalls.calls(for: server)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(connection.phase, .reconnecting(attempt: 1))

        // Network "returns" while parked in backoff — must reset to an
        // immediate retry rather than waiting out the 30s window.
        fake.emit(.satisfied)
        await settle()

        calls = await connectCalls.calls(for: server)
        XCTAssertEqual(
            calls, 2,
            "a network-return while parked in backoff must kick an immediate retry"
        )
        XCTAssertEqual(connection.phase, .connected)
    }
    #endif

    // MARK: - WS-RECONNECT-SOFTEN (c): capped exponential backoff with jitter

    /// Attempts 1…4 follow `0.5 * 2^attempt` before the cap, each with a
    /// `[0, 0.5)` jitter term layered on top — i.e. roughly 1s/2s/4s/8s.
    func testBackoffDelayGrowsExponentiallyBelowCap() {
        for attempt in 1...4 {
            let expectedBase = min(0.5 * pow(2.0, Double(attempt)), 8.0)
            let delay = ConnectionStore.backoffDelay(attempt: attempt)
            XCTAssertGreaterThanOrEqual(delay, expectedBase, "attempt \(attempt)")
            XCTAssertLessThan(delay, expectedBase + 0.5, "attempt \(attempt) jitter must stay within [0, 0.5)")
        }
    }

    /// The base delay is capped at 8s (not the old 30s) so a client retrying
    /// against a crash-looping gateway never backs off further than that —
    /// verified well past the attempt where the cap engages.
    func testBackoffDelayCapsAtEightSecondsPlusJitter() {
        for attempt in [5, 6, 10, 20] {
            let delay = ConnectionStore.backoffDelay(attempt: attempt)
            XCTAssertGreaterThanOrEqual(delay, 8.0, "attempt \(attempt) must never back off below the 8s cap")
            XCTAssertLessThan(delay, 8.5, "attempt \(attempt) must never exceed the 8s cap + max jitter")
        }
    }

    /// Attempt 0 has no caller-side delay (fired immediately by the reconnect
    /// loop, not through `backoffDelay`) — but the function itself is still
    /// well-defined and small for attempt 0, matching `0.5 * 2^0 = 0.5` base.
    func testBackoffDelayAtAttemptZeroIsSmallBase() {
        let delay = ConnectionStore.backoffDelay(attempt: 0)
        XCTAssertGreaterThanOrEqual(delay, 0.5)
        XCTAssertLessThan(delay, 1.0)
    }
}
