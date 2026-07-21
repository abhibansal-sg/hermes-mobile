import UserNotifications
import XCTest
@testable import HermesMobile

/// QA-1 B14 — relay-mode device-token registration + §6 foreground hygiene.
///
/// In relay mode the APNs token must be registered OVER THE RELAY SOCKET
/// (protocol §6a): the relay's Notifier reads the relay's own registry, so the
/// gateway-direct REST register is structurally wrong (unreachable off-LAN; a
/// different HERMES_HOME than the relay reads even on-LAN). These tests drive
/// the REAL `PushRegistrar` → `RelaySessionCoordinator` → `RelayClient` path
/// against an in-process mock relay transport (no network), plus the
/// scene-phase foreground clear/re-assert that keeps the §6 gate honest when
/// the app backgrounds without iOS killing the socket immediately.
@MainActor
final class PushRegistrarRelayModeTests: XCTestCase {

    // MARK: - In-process mock relay transport (same shape as the sibling suites)

    final class MockRelayTransport: RelayTransport, @unchecked Sendable {
        struct Upstream { let method: String; let id: String?; let params: [String: Any] }

        private let lock = NSLock()
        private var inbox: [URLSessionWebSocketTask.Message] = []
        private var waiter: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
        private var sent: [Upstream] = []
        private var cancelled = false

        var script: (@Sendable (Upstream, MockRelayTransport) -> Void)?

        init(script: (@Sendable (Upstream, MockRelayTransport) -> Void)? = nil) {
            self.script = script
        }

        func resume() {}

        func receive() async throws -> URLSessionWebSocketTask.Message {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled {
                    lock.unlock(); continuation.resume(throwing: URLError(.cancelled))
                } else if !inbox.isEmpty {
                    let next = inbox.removeFirst(); lock.unlock()
                    continuation.resume(returning: next)
                } else {
                    waiter = continuation; lock.unlock()
                }
            }
        }

        func send(_ message: URLSessionWebSocketTask.Message) async throws {
            guard case let .string(text) = message, let upstream = Self.parse(text) else { return }
            record(upstream)
            script?(upstream, self)
        }

        private func record(_ upstream: Upstream) {
            lock.lock(); defer { lock.unlock() }
            sent.append(upstream)
        }

        func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
            lock.lock(); cancelled = true; let parked = waiter; waiter = nil; lock.unlock()
            parked?.resume(throwing: URLError(.cancelled))
        }

        func deliverResult(id: String, result: JSONValue) {
            let payload: JSONValue = .object([
                "jsonrpc": .string("2.0"), "id": .string(id), "result": result,
            ])
            guard let data = try? JSONEncoder().encode(payload) else { return }
            deliver(String(decoding: data, as: UTF8.self))
        }

        private func deliver(_ text: String) {
            lock.lock()
            if let parked = waiter {
                waiter = nil; lock.unlock(); parked.resume(returning: .string(text))
            } else {
                inbox.append(.string(text)); lock.unlock()
            }
        }

        func upstreams() -> [Upstream] {
            lock.lock(); defer { lock.unlock() }
            return sent
        }

        private static func parse(_ text: String) -> Upstream? {
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = object["method"] as? String else { return nil }
            return Upstream(
                method: method, id: object["id"] as? String,
                params: object["params"] as? [String: Any] ?? [:]
            )
        }
    }

    // MARK: - Fixtures

    private var registrar: PushRegistrar { PushRegistrar.shared }
    private let url = URL(string: "ws://127.0.0.1:9999/relay")!
    private let defaultsKeys = [
        DefaultsKeys.pushEnabled,
        DefaultsKeys.pushLastDeviceToken,
        DefaultsKeys.pushLastEvents,
        DefaultsKeys.pushLastEnv,
        DefaultsKeys.pushLastRegistrationScope,
        DefaultsKeys.pushRegistrationHealthy,
        DefaultsKeys.notificationsDidRequestAuthorization,
        DefaultsKeys.transportPath,
        DefaultsKeys.deviceIdsByServer,
        DefaultsKeys.pushDeviceInstallId,
    ]

    override func setUp() async throws {
        try await super.setUp()
        resetState()
    }

    override func tearDown() async throws {
        resetState()
        try await super.tearDown()
    }

    private func resetState() {
        registrar.authorizationRequester = nil
        registrar.remoteNotificationsRegistrar = nil
        registrar.tokenRegisterOverride = nil
        registrar.relayTokenRegisterOverride = nil
        registrar.relayTokenUnregisterOverride = nil
        for key in defaultsKeys { UserDefaults.standard.removeObject(forKey: key) }
        registrar.setEnabled(false)
        for key in defaultsKeys { UserDefaults.standard.removeObject(forKey: key) }
    }

    /// A relay-mode ConnectionStore + coordinator over `transport`.
    private func makeRelayConnection(
        _ transport: MockRelayTransport
    ) -> (connection: ConnectionStore, coordinator: RelaySessionCoordinator) {
        UserDefaults.standard.set(TransportPath.relay.rawValue, forKey: DefaultsKeys.transportPath)
        let chat = ChatStore()
        let connection = ConnectionStore(sessionStore: SessionStore(), chatStore: chat)
        connection.relayCoordinatorFactory = {
            RelaySessionCoordinator(
                chatStore: chat,
                clientFactory: { RelayClient { _ in transport } }
            )
        }
        let coordinator = connection.ensureRelayCoordinator()
        registrar.attach(connection: connection)
        return (connection, coordinator)
    }

    private func waitUntil(
        _ condition: @autoclosure @MainActor () -> Bool,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<50 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTFail(message, file: file, line: line)
    }

    // MARK: - Tests

    /// B14 core: in relay mode the APNs token goes OVER THE RELAY SOCKET with
    /// the §6a params, never to gateway-direct REST, and a successful relay
    /// register marks the registration healthy (retry contract intact).
    func testRelayModeRegistersTokenOverRelaySocket() async throws {
        let transport = MockRelayTransport(script: { upstream, relay in
            guard let id = upstream.id else { return }
            if upstream.method == "push.register" {
                relay.deliverResult(id: id, result: .object(["registered": .bool(true)]))
            }
        })
        let (connection, coordinator) = makeRelayConnection(transport)
        try await coordinator.start(url: url)
        await waitUntil(coordinator.phase == .open, "relay socket should open")

        // A direct-path POST would be a bug in relay mode — make it loud.
        registrar.tokenRegisterOverride = { _, _ in
            XCTFail("relay mode must NOT register via gateway-direct REST")
            return .success
        }
        registrar.authorizationRequester = { _ in .authorized }
        registrar.remoteNotificationsRegistrar = {}

        registrar.ensureRegisteredForPairedGateway()
        registrar.didRegister(deviceToken: Data([0xab, 0xcd, 0xef, 0x01]))

        await waitUntil(
            transport.upstreams().contains { $0.method == "push.register" },
            "the token must be registered over the relay socket (§6a)"
        )
        let register = transport.upstreams().first { $0.method == "push.register" }
        XCTAssertEqual(register?.params["token"] as? String, "abcdef01")
        XCTAssertEqual(register?.params["platform"] as? String, "ios")
        XCTAssertEqual(
            register?.params["env"] as? String,
            PushTokenPoster.apnsEnvironment
        )
        let events = register?.params["events"] as? [String]
        XCTAssertEqual(
            events,
            ["approval", "clarify", "turn_complete", "turn_error", "background_done"]
        )
        await waitUntil(
            UserDefaults.standard.bool(forKey: DefaultsKeys.pushRegistrationHealthy),
            "a successful relay register must mark the registration healthy"
        )
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: DefaultsKeys.pushLastDeviceToken),
            "abcdef01"
        )

        await coordinator.stop()
        _ = connection  // keep the registrar's weak connection alive for the test
    }

    /// Direct mode is untouched: the relay overrides must never fire and the
    /// gateway-direct poster stays the registration path.
    func testGatewayDirectModeDoesNotUseRelayRegistration() async {
        UserDefaults.standard.set(
            TransportPath.gatewayDirect.rawValue, forKey: DefaultsKeys.transportPath
        )
        let chat = ChatStore()
        let connection = ConnectionStore(sessionStore: SessionStore(), chatStore: chat)
        registrar.attach(connection: connection)
        registrar.relayTokenRegisterOverride = { _, _ in
            XCTFail("gateway-direct mode must NOT use the relay registration path")
            return .success
        }
        var directPosts = 0
        registrar.tokenRegisterOverride = { _, _ in
            directPosts += 1
            return .success
        }
        registrar.authorizationRequester = { _ in .authorized }
        registrar.remoteNotificationsRegistrar = {}

        registrar.ensureRegisteredForPairedGateway()
        registrar.didRegister(deviceToken: Data([0x01, 0x02, 0x03, 0x04]))

        await waitUntil(directPosts == 1, "direct mode keeps the REST poster path")
    }

    /// `RelayClient` builds the ratified §6a wire shape for both RPCs.
    func testCoordinatorPushRegisterAndUnregisterWireShape() async throws {
        let transport = MockRelayTransport(script: { upstream, relay in
            guard let id = upstream.id else { return }
            if upstream.method == "push.register" {
                relay.deliverResult(id: id, result: .object(["registered": .bool(true)]))
            } else if upstream.method == "push.unregister" {
                relay.deliverResult(id: id, result: .object(["unregistered": .bool(true)]))
            }
        })
        let chat = ChatStore()
        let coordinator = RelaySessionCoordinator(
            chatStore: chat,
            clientFactory: { RelayClient { _ in transport } }
        )
        try await coordinator.start(url: url)
        await waitUntil(coordinator.phase == .open, "relay socket should open")

        let token = String(repeating: "ab", count: 32)
        _ = try await coordinator.registerPushToken(
            token, env: "sandbox", events: ["approval", "turn_complete"]
        )
        let reg = transport.upstreams().first { $0.method == "push.register" }
        XCTAssertEqual(reg?.params["token"] as? String, token)
        XCTAssertEqual(reg?.params["platform"] as? String, "ios")
        XCTAssertEqual(reg?.params["env"] as? String, "sandbox")
        XCTAssertEqual(reg?.params["events"] as? [String], ["approval", "turn_complete"])
        // No device id supplied → the key is ABSENT (legacy relay semantics).
        XCTAssertNil(reg?.params["device_id"])

        // QA-2 R1c: a supplied device id rides along for one-token-per-device dedup.
        _ = try await coordinator.registerPushToken(
            token, env: "sandbox", events: ["approval"], deviceID: "qa2-device-42"
        )
        let reg2 = transport.upstreams().last { $0.method == "push.register" }
        XCTAssertEqual(reg2?.params["device_id"] as? String, "qa2-device-42")

        _ = try await coordinator.unregisterPushToken(token)
        let unreg = transport.upstreams().first { $0.method == "push.unregister" }
        XCTAssertEqual(unreg?.params["token"] as? String, token)

        await coordinator.stop()
    }

    /// QA-2 R1c: the registrar's relay register carries the phone's STABLE
    /// per-install device id (so the relay registry converges to one entry per
    /// device); without a device id no key is sent.
    func testRelayRegisterCarriesStableDeviceId() async throws {
        let transport = MockRelayTransport(script: { upstream, relay in
            guard let id = upstream.id else { return }
            if upstream.method == "push.register" {
                relay.deliverResult(id: id, result: .object(["registered": .bool(true)]))
            }
        })
        let (connection, coordinator) = makeRelayConnection(transport)
        DefaultsKeys.setDeviceId("stable-device-7", server: connection.serverURLString)
        try await coordinator.start(url: url)
        await waitUntil(coordinator.phase == .open, "relay socket should open")

        registrar.authorizationRequester = { _ in .authorized }
        registrar.remoteNotificationsRegistrar = {}
        registrar.ensureRegisteredForPairedGateway()
        registrar.didRegister(deviceToken: Data([0xde, 0xad, 0xbe, 0xef]))

        await waitUntil(
            transport.upstreams().contains { $0.method == "push.register" },
            "the token must be registered over the relay socket (§6a)"
        )
        let register = try XCTUnwrap(
            transport.upstreams().first { $0.method == "push.register" }
        )
        XCTAssertEqual(register.params["device_id"] as? String, "stable-device-7")
        XCTAssertEqual(register.params["token"] as? String, "deadbeef")

        await coordinator.stop()
        _ = connection  // keep the registrar's weak connection alive for the test
    }

    /// QA-3 S13: when no v2 device id has been issued (relay-only phone on a
    /// pre-v2 shared-token pairing — exactly the build-116 install), the
    /// registrar MUST still send a non-empty device_id (the per-install
    /// fallback) so the relay registry can dedup by device from day one.
    /// This is the fix that makes QA-2's device-keyed eviction converge.
    func testRelayRegisterSendsPerInstallDeviceIdWhenNoV2Id() async throws {
        let transport = MockRelayTransport(script: { upstream, relay in
            guard let id = upstream.id else { return }
            if upstream.method == "push.register" {
                relay.deliverResult(id: id, result: .object(["registered": .bool(true)]))
            }
        })
        let (connection, coordinator) = makeRelayConnection(transport)
        // Precondition: no v2 device id on record (the build-116 install state).
        UserDefaults.standard.removeObject(forKey: DefaultsKeys.deviceIdsByServer)
        XCTAssertNil(DefaultsKeys.deviceId(server: connection.serverURLString))

        try await coordinator.start(url: url)
        await waitUntil(coordinator.phase == .open, "relay socket should open")

        registrar.authorizationRequester = { _ in .authorized }
        registrar.remoteNotificationsRegistrar = {}
        registrar.ensureRegisteredForPairedGateway()
        registrar.didRegister(deviceToken: Data([0xde, 0xad, 0xbe, 0xef]))

        await waitUntil(
            transport.upstreams().contains { $0.method == "push.register" },
            "the token must be registered over the relay socket (§6a)"
        )
        let register = try XCTUnwrap(
            transport.upstreams().first { $0.method == "push.register" }
        )
        // The device_id MUST be present and non-empty — never null like build 116.
        let sentDeviceId = try XCTUnwrap(register.params["device_id"] as? String)
        XCTAssertFalse(sentDeviceId.isEmpty, "relay register must carry a device id even without a v2 id")
        // The fallback is persisted and stable across a second registration, so
        // a re-register after a transient socket failure keys to the SAME id.
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: DefaultsKeys.pushDeviceInstallId),
            sentDeviceId
        )

        await coordinator.stop()
        _ = connection
    }

    /// Registering while the relay socket is down throws (so PushRegistrar
    /// marks unhealthy and retries next launch) — it never succeeds silently.
    func testRegisterPushTokenThrowsWhenRelayNotConnected() async {
        let transport = MockRelayTransport()
        let chat = ChatStore()
        let coordinator = RelaySessionCoordinator(
            chatStore: chat,
            clientFactory: { RelayClient { _ in transport } }
        )
        // Never started: phase == .idle.
        do {
            _ = try await coordinator.registerPushToken(
                String(repeating: "cd", count: 32), env: "production", events: nil
            )
            XCTFail("registering without a relay connection must throw")
        } catch {
            // RelayError.notConnected — the retry-on-launch contract.
        }
    }

    /// §6a hygiene: leaving the foreground sends `foreground: null` so a turn
    /// completing right after backgrounding is NOT suppressed by a WS iOS has
    /// not killed yet; returning re-asserts the driven session.
    func testScenePhaseClearsAndReassertsRelayForeground() async throws {
        let transport = MockRelayTransport(script: { upstream, relay in
            guard let id = upstream.id else { return }
            if upstream.method == "open" {
                relay.deliverResult(id: id, result: .object(["session_id": .string("S1")]))
            }
        })
        let (connection, coordinator) = makeRelayConnection(transport)
        try await coordinator.start(url: url)
        await waitUntil(coordinator.phase == .open, "relay socket should open")
        _ = try await coordinator.open("S1")
        await coordinator.reassertForeground()

        func foregrounds() -> [MockRelayTransport.Upstream] {
            transport.upstreams().filter { $0.method == "foreground" }
        }
        await waitUntil(
            foregrounds().last?.params["session_id"] as? String == "S1",
            "re-assert must foreground the driven session"
        )

        // Background: the clear is unconditional (no hasConnected gate).
        connection.handleScenePhase(.background)
        await waitUntil(
            foregrounds().last?.params["session_id"] is NSNull,
            "backgrounding must send foreground null (§6a)"
        )

        // Reassert covers the survived-socket return-to-foreground case.
        await coordinator.reassertForeground()
        await waitUntil(
            foregrounds().last?.params["session_id"] as? String == "S1",
            "returning to foreground must re-assert the driven session"
        )

        await coordinator.stop()
    }
}
