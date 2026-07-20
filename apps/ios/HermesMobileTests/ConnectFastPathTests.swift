import XCTest
@testable import HermesMobile

/// DAILY-DRIVER SPEC N3 / A1 — connect fast-path.
///
/// Two guarantees, proven deterministically (no live socket, no wall clock):
///
///  1. ``ConnectTrace`` measures the cold-open → cache paint → socket open →
///     transport ready → composer interactive sequence correctly (delta math,
///     first-occurrence semantics, reset).
///  2. On the RELAY transport, `configure()` does NOT gate the socket open (and
///     therefore composer interactivity) behind the gateway REST `status()` probe
///     — the blocking status round-trip is demoted to a background auth check.
///     The gateway-direct path is asserted to STILL block on the probe (byte-for-
///     byte behaviour preserved), and the D3 re-pair flow (401/403 → reauth) is
///     preserved on the relay path via the background check.
@MainActor
final class ConnectFastPathTests: XCTestCase {

    // MARK: - Fakes / helpers

    /// Deterministic clock: `now()` returns the manually-advanced `current`.
    @MainActor
    private final class FakeClock: ConnectClock {
        var current: Double = 0
        func now() -> Double { current }
    }

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

    /// Fails every request instantly — keeps hermetic tests off the network.
    private final class InstantFailureProtocol: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
        }
        override func stopLoading() {}
    }

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

    // MARK: - ConnectTrace delta math

    func testTraceRecordsOrderedDeltasFromColdOpen() {
        let trace = ConnectTrace()
        let clock = FakeClock()
        trace.clock = clock

        clock.current = 100.000
        trace.begin()                              // cold_open_start @ 100.000
        clock.current = 100.040
        trace.mark(.cachePaint)                    // +40ms
        clock.current = 100.110
        trace.mark(.socketOpen)                    // +110ms
        clock.current = 100.112
        trace.mark(.transportReady)                // +112ms
        clock.current = 100.900
        trace.mark(.composerInteractive)           // +900ms

        XCTAssertEqual(trace.elapsedMs(to: .coldOpen) ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(trace.elapsedMs(to: .cachePaint) ?? -1, 40, accuracy: 0.0001)
        XCTAssertEqual(trace.elapsedMs(to: .socketOpen) ?? -1, 110, accuracy: 0.0001)
        XCTAssertEqual(trace.elapsedMs(to: .transportReady) ?? -1, 112, accuracy: 0.0001)
        XCTAssertEqual(trace.elapsedMs(to: .composerInteractive) ?? -1, 900, accuracy: 0.0001)
        // The A1 budget is the cold-open → composer-interactive span.
        XCTAssertLessThanOrEqual(trace.elapsedMs(to: .composerInteractive) ?? .infinity, 2000)
        // Segment deltas.
        XCTAssertEqual(trace.deltaMs(from: .cachePaint, to: .socketOpen) ?? -1, 70, accuracy: 0.0001)
        XCTAssertEqual(trace.deltaMs(from: .socketOpen, to: .transportReady) ?? -1, 2, accuracy: 0.0001)
    }

    func testTraceFirstOccurrenceWins() {
        let trace = ConnectTrace()
        let clock = FakeClock()
        trace.clock = clock

        clock.current = 0
        trace.begin()
        clock.current = 0.100
        trace.mark(.composerInteractive)
        clock.current = 5.000
        trace.mark(.composerInteractive)           // a reconnect crossing back — ignored

        XCTAssertEqual(trace.elapsedMs(to: .composerInteractive) ?? -1, 100, accuracy: 0.0001)
    }

    func testTraceBeginResetsMarks() {
        let trace = ConnectTrace()
        let clock = FakeClock()
        trace.clock = clock

        clock.current = 10
        trace.begin()
        trace.mark(.cachePaint)
        XCTAssertNotNil(trace.marks[.cachePaint])

        clock.current = 20
        trace.begin()                              // fresh run
        XCTAssertNil(trace.marks[.cachePaint])
        XCTAssertEqual(trace.elapsedMs(to: .coldOpen) ?? -1, 0, accuracy: 0.0001)
    }

    func testTraceElapsedNilBeforeMarked() {
        let trace = ConnectTrace()
        trace.clock = FakeClock()
        trace.begin()
        XCTAssertNotNil(trace.elapsedMs(to: .coldOpen))
        XCTAssertNil(trace.elapsedMs(to: .composerInteractive))
        XCTAssertNil(trace.deltaMs(from: .socketOpen, to: .transportReady))
    }

    // MARK: - Relay fast-path: connect is NOT gated by the REST probe

    #if DEBUG
    /// The relay transport must reach `transportReady` (socket dialed + accepted)
    /// while the gateway REST `status()` probe is STILL suspended — proving the
    /// probe no longer sits on the interactivity critical path.
    func testRelayConfigureDoesNotBlockOnStatusProbe() async {
        let (connection, _, _) = makeStore()
        let serverURL = "http://127.0.0.1:9131"
        UserDefaults.standard.set(TransportPath.relay.rawValue, forKey: DefaultsKeys.transportPath)
        UserDefaults.standard.set("ws://127.0.0.1:9999/relay", forKey: DefaultsKeys.relayURLOverride)
        let priorServer = UserDefaults.standard.string(forKey: DefaultsKeys.serverURL)
        defer {
            UserDefaults.standard.removeObject(forKey: DefaultsKeys.transportPath)
            UserDefaults.standard.removeObject(forKey: DefaultsKeys.relayURLOverride)
            if let priorServer { UserDefaults.standard.set(priorServer, forKey: DefaultsKeys.serverURL) }
            else { UserDefaults.standard.removeObject(forKey: DefaultsKeys.serverURL) }
            KeychainService.deleteToken(server: serverURL)
        }

        // The probe hangs forever; if configure awaited it, this test would stall.
        let gate = SuspensionGate()
        connection.statusRPC = { _, _ in await gate.suspend() }
        var relayDialed = false
        connection.relayConnectHook = { _, _ in relayDialed = true }

        var returned = false
        var configureResult: String? = "sentinel"
        let task = Task { @MainActor () -> String? in
            let r = await connection.configure(urlString: serverURL, token: "tok")
            returned = true
            return r
        }
        // Bound the wait: if the relay path wrongly blocks on the probe, we hit the
        // deadline, fail, and release the gate rather than hanging CI.
        let deadline = ContinuousClock.now + .seconds(3)
        while !returned, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(returned, "relay configure must NOT block on the REST status probe")
        configureResult = await task.value
        XCTAssertNil(configureResult)
        XCTAssertTrue(relayDialed, "relay socket must be dialed")
        XCTAssertTrue(connection.isTransportReady, "transport must be ready without the probe")
        // The probe was never awaited — release it so the background task can exit.
        await gate.release()
    }

    /// The D3 re-pair flow survives the demotion: a 401 on the background probe
    /// still flips `reauthRequired` + `.needsSetup` on the relay path.
    func testRelayBackgroundProbeStillRoutesAuthFailureToReauth() async {
        let (connection, _, _) = makeStore()
        let serverURL = "http://127.0.0.1:9131"
        UserDefaults.standard.set(TransportPath.relay.rawValue, forKey: DefaultsKeys.transportPath)
        UserDefaults.standard.set("ws://127.0.0.1:9999/relay", forKey: DefaultsKeys.relayURLOverride)
        let priorServer = UserDefaults.standard.string(forKey: DefaultsKeys.serverURL)
        defer {
            UserDefaults.standard.removeObject(forKey: DefaultsKeys.transportPath)
            UserDefaults.standard.removeObject(forKey: DefaultsKeys.relayURLOverride)
            if let priorServer { UserDefaults.standard.set(priorServer, forKey: DefaultsKeys.serverURL) }
            else { UserDefaults.standard.removeObject(forKey: DefaultsKeys.serverURL) }
            KeychainService.deleteToken(server: serverURL)
        }

        connection.statusRPC = { _, _ in throw RestError.badStatus(401, body: "unauthorized") }
        connection.relayConnectHook = { _, _ in }

        let result = await connection.configure(urlString: serverURL, token: "tok")
        XCTAssertNil(result, "relay connect itself succeeds; auth is checked in the background")

        // The background probe lands asynchronously; poll (bounded) for the reauth flip.
        let deadline = ContinuousClock.now + .seconds(3)
        while !connection.reauthRequired, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(connection.reauthRequired, "a 401 on the background probe must trigger re-pair")
        if case .needsSetup = connection.phase {} else {
            XCTFail("expected .needsSetup after auth rejection, got \(connection.phase)")
        }
    }

    /// Contrast: the gateway-direct path STILL gates the socket behind the REST
    /// probe (its behaviour is deliberately unchanged). The socket must not be
    /// dialed until the probe returns.
    func testGatewayDirectConfigureStillGatesOnProbe() async {
        let (connection, _, _) = makeStore()
        let serverURL = "https://gw.example:9119"
        UserDefaults.standard.removeObject(forKey: DefaultsKeys.transportPath)   // gateway-direct
        let priorServer = UserDefaults.standard.string(forKey: DefaultsKeys.serverURL)
        defer {
            if let priorServer { UserDefaults.standard.set(priorServer, forKey: DefaultsKeys.serverURL) }
            else { UserDefaults.standard.removeObject(forKey: DefaultsKeys.serverURL) }
            KeychainService.deleteToken(server: serverURL)
        }

        let gate = SuspensionGate()
        connection.statusRPC = { _, _ in await gate.suspend() }
        var connectDialed = false
        connection.connectRPC = { _, _, _ in connectDialed = true }

        var returned = false
        let task = Task { @MainActor () -> String? in
            let r = await connection.configure(urlString: serverURL, token: "tok")
            returned = true
            return r
        }
        // Let configure reach the probe and block.
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(returned, "gateway-direct configure must block on the REST probe")
        XCTAssertFalse(connectDialed, "gateway socket must not be dialed before the probe completes")

        await gate.release()
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertTrue(returned)
        XCTAssertTrue(connectDialed)
    }
    #endif
}
