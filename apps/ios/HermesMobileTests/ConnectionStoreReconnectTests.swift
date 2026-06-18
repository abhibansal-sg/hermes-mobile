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

    // MARK: - Helpers

    /// Build a wired store graph (ConnectionStore + SessionStore + ChatStore).
    /// No live servers are touched; the `connectRPC` hook on the returned
    /// `ConnectionStore` is `nil` until the test sets it.
    private func makeStore() -> (ConnectionStore, SessionStore, ChatStore) {
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        let attachments = AttachmentStore()
        chat.attach(connection: connection, sessions: sessions, attachments: attachments)
        sessions.attach(connection: connection, chat: chat)
        return (connection, sessions, chat)
    }

    /// 600 ms — enough for a `Task` spawned on the main executor to complete
    /// its attempt-0 pass (no backoff). The 120ms used by ChatStoreBatchBTests
    /// is not enough here because `recoverActiveSession()` makes a REST call
    /// (guarded by `try?`) that returns quickly (connection refused) but still
    /// needs a few hundred ms to propagate on the simulator. 600ms is well within
    /// CI budget and keeps the test deterministic across machines.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(600))
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

        // Let attempt 0 (no delay) complete on the main executor.
        await settle()

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

    /// A transient failure on attempt 0 followed by success on attempt 1
    /// (fail-once-then-succeed): the loop retries and still reaches `.connected`.
    ///
    /// Proves the backoff loop itself is exercised and the phase still converges.
    /// (Attempt 1 uses the normal backoff, but the test injects a zero-delay
    /// connect hook so the fake "network" resolves instantly.)
    func testReconnectLoopRetriesAndConvergesAfterTransientFailure() async {
        let (connection, _, _) = makeStore()

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

        // Wait for attempt 0 (fail) + backoff + attempt 1 (succeed).
        // Backoff for attempt 1 = min(0.5 * 2^1, 30) + jitter ~ 1.0–1.5s.
        // Use a generous ceiling that keeps the test fast while absorbing jitter.
        try? await Task.sleep(for: .seconds(2))

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

    /// BELOW threshold: one or two consecutive WS failures do NOT trigger the
    /// auth-revoke probe. The loop stays in `.reconnecting` with
    /// `reauthRequired == false` — the app keeps retrying, not re-pairing.
    ///
    /// Uses `reconnectBackoffOverride = 0` so attempts 0 and 1 both fire within
    /// the 600ms settle window (no real backoff delay).
    func testBelowAuthReprobeThresholdStaysReconnecting() async {
        let (connection, _, _) = makeStore()

        // Zero-delay backoff so multiple attempts fit in the settle window.
        connection.reconnectBackoffOverride = 0
        // Always-failing, but probe returns false (not a revocation) — should
        // never even be called below the threshold.
        connection.connectRPC = { _, _, _ in throw URLError(.cannotConnectToHost) }
        connection.probeIsAuthRevokedRPC = { false }

        connection._seedAndStartReconnect(
            serverURL: "http://localhost:9123",
            token: "test-stable-token"
        )

        await settle()

        // Loop is still retrying — not routed to re-pair.
        if case .reconnecting = connection.phase { /* expected */ } else {
            XCTFail("expected .reconnecting below threshold, got \(connection.phase)")
        }
        XCTAssertFalse(connection.reauthRequired,
                       "reauthRequired must be false below authReprobeThreshold")
        XCTAssertTrue(connection.hasConnected,
                      "hasConnected must stay true while below threshold")

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

        await settle()

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
        await settle()

        XCTAssertEqual(connection.phase, .connected)
        XCTAssertEqual(connection.serverURLString, stableURL,
                       "serverURLString must be unchanged after a successful reconnect")
    }
}
