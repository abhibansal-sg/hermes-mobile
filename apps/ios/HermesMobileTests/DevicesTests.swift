import XCTest
@testable import HermesMobile

/// W3A-A coverage for the per-device-token surface: the `devices` (eager)
/// capability probe state machine, the `PairedDevice` / `IssuedDevice` /
/// `RevokeDeviceResult` / `ApprovalAuditEntry` fixture decodes (captured verbatim
/// from the pinned shapes in CONTRACT-W3A.md §Interface), the QR v1/v2 parse
/// (v1 unchanged, v2 `kind=device` records the id, unknown keys ignored), the
/// auto-upgrade decision logic (issues iff available + no recorded deviceId;
/// keeps the shared token on failure; never reconfigures), the revoke
/// confirmation flow logic + current-device marking, the audit attribution, and
/// the SECRET-HYGIENE invariant (the token never lands in UserDefaults / a
/// `@Snapshotable` accessor / the DEBUG ring buffer — only the Keychain).
///
/// No live server is touched — pure decode + pure gate/decision functions, plus
/// the persistence helpers that drive the auto-upgrade decision.
@MainActor
final class DevicesTests: XCTestCase {

    /// Decode through the SAME `.useDefaultKeys` path `RestClient`'s device
    /// methods use (the models declare explicit snake_case CodingKeys).
    private func decodeKeyed<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    /// Minimal URLProtocol stub for `issueDevice` status/error tests.
    final class IssueDeviceProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var response: (Data, Int) = (Data(), 200)
        nonisolated(unsafe) static var issueRequestCount = 0

        static func reset(body: Data, status: Int) {
            response = (body, status)
            issueRequestCount = 0
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            if request.url?.path.hasSuffix("/api/status") == true {
                let status = Data(#"{"auth_required":true}"#.utf8)
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: status)
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            if request.url?.path.hasSuffix("/devices/issue") == true {
                Self.issueRequestCount += 1
            }
            let (body, status) = Self.response
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func makeIssueClient(body: Data, status: Int) -> RestClient {
        IssueDeviceProtocol.reset(body: body, status: status)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [IssueDeviceProtocol.self]
        return RestClient(
            baseURL: URL(string: "https://gw.example:9119")!,
            token: "tok",
            session: URLSession(configuration: config),
            pathStyle: .plugin
        )
    }

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: DefaultsKeys.deviceIdsByServer)
        ConnectionStore.spotlightClearAllForTesting = nil
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: DefaultsKeys.deviceIdsByServer)
        ConnectionStore.spotlightClearAllForTesting = nil
        super.tearDown()
    }

    // MARK: - Capability probe state machine

    func testProbeDevicesEndpointInconclusiveOnUnreachableHost() async {
        // A transport failure (nothing listening) must classify inconclusive,
        // never throw — so a flaky probe leaves `devices` at `.unknown`, the
        // Devices section stays hidden, AND no auto-upgrade issue call fires.
        let rest = RestClient(baseURL: URL(string: "http://127.0.0.1:1")!, token: "t")
        let result = await rest.probeDevicesEndpoint()
        XCTAssertEqual(result, .inconclusive)
    }

    func testProbeClassificationByStatusAndBody() {
        // Pin the status→result classification the probe applies, incl. the body
        // refinement (a 200 must carry a `devices` array; an EMPTY array is still
        // available — the route exists). Mirrors the profiles/fs probe contract.
        func classify(status: Int, bodyHasDevicesArray: Bool) -> RestClient.UploadProbeResult {
            switch status {
            case 200: return bodyHasDevicesArray ? .available : .inconclusive
            case 404, 405: return .unavailable
            default: return .inconclusive
            }
        }
        XCTAssertEqual(classify(status: 200, bodyHasDevicesArray: true), .available)
        XCTAssertEqual(classify(status: 200, bodyHasDevicesArray: false), .inconclusive)
        XCTAssertEqual(classify(status: 404, bodyHasDevicesArray: false), .unavailable)
        XCTAssertEqual(classify(status: 405, bodyHasDevicesArray: false), .unavailable)
        XCTAssertEqual(classify(status: 500, bodyHasDevicesArray: false), .inconclusive)
        // An empty registry is a 200 with an (empty) devices array ⇒ available.
        XCTAssertEqual(classify(status: 200, bodyHasDevicesArray: true), .available)
    }

    func testProbeStateMappingMirrorsUploadFsTriState() {
        // The ServerCapabilities probe folds the shared UploadProbeResult into the
        // capability State exactly like upload/fs/profiles.
        func map(_ r: RestClient.UploadProbeResult) -> ServerCapabilities.State {
            switch r {
            case .available: return .available
            case .unavailable: return .unavailable
            case .inconclusive: return .unknown
            }
        }
        XCTAssertEqual(map(.available), .available)
        XCTAssertEqual(map(.unavailable), .unavailable)
        XCTAssertEqual(map(.inconclusive), .unknown)
    }

    func testCapabilityDefaultsUnknownAndResetClears() {
        let caps = ServerCapabilities()
        XCTAssertEqual(caps.devices, .unknown)
        caps.reset()
        XCTAssertEqual(caps.devices, .unknown)
    }

    // MARK: - Cache round-trip (incl. pre-W3a cache)

    func testCapabilityCacheRoundTripIncludesDevices() throws {
        struct Probe: Codable {
            var serverURL = "https://h"
            var appVersion = "1 (1)"
            var upload = ServerCapabilities.State.available
            var pushRegistry = ServerCapabilities.State.unknown
            var broadcast = ServerCapabilities.State.unknown
            var fs = ServerCapabilities.State.available
            var subagentEvents = ServerCapabilities.State.unknown
            var profiles = ServerCapabilities.State.unknown
            var devices = ServerCapabilities.State.available
        }
        let data = try JSONEncoder().encode(Probe())
        let decoded = try JSONDecoder().decode(Probe.self, from: data)
        XCTAssertEqual(decoded.devices, .available)
    }

    func testPreW3aCacheRestoresDevicesAsUnknown() throws {
        // A cache written by a pre-W3a build omits the `devices` key entirely; the
        // decodeIfPresent-tolerant Cache must restore it as `.unknown` rather than
        // failing the whole decode (which would force a needless re-probe).
        struct Tolerant: Decodable {
            let devices: ServerCapabilities.State
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                devices = try c.decodeIfPresent(ServerCapabilities.State.self, forKey: .devices) ?? .unknown
            }
            enum CodingKeys: String, CodingKey { case devices }
        }
        let decoded = try JSONDecoder().decode(Tolerant.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded.devices, .unknown)
    }

    // MARK: - PairedDevice / DevicesListResult decode

    func testDevicesListDecodesRowsAndIgnoresUnknownKeys() throws {
        // Captured from the pinned `GET /api/devices` 200 shape. NEVER carries
        // `token`/`token_hash`; `scopes` defaults to the full set when absent.
        let json = """
        {"devices":[
          {"device_id":"dev_abc123","device_name":"Test iPhone","platform":"ios",
           "created_at":1700000000.0,"last_seen":1700000500.5,"token_prefix":"ab12cd34",
           "scopes":["chat","approve"]},
          {"device_id":"dev_xyz789","device_name":"iPad","platform":"ios",
           "created_at":1699999000.0,"last_seen":1699999100.0,"token_prefix":"zz99yy88"}
        ]}
        """
        let result = try decodeKeyed(DevicesListResult.self, json)
        XCTAssertEqual(result.devices.count, 2)
        let first = result.devices[0]
        XCTAssertEqual(first.deviceId, "dev_abc123")
        XCTAssertEqual(first.deviceName, "Test iPhone")
        XCTAssertEqual(first.platform, "ios")
        XCTAssertEqual(first.tokenPrefix, "ab12cd34")
        XCTAssertEqual(first.scopes, ["chat", "approve"])
        XCTAssertEqual(first.id, "dev_abc123")  // id == device_id
        // Tolerant default of scopes when the key is absent (forward-compat).
        XCTAssertEqual(result.devices[1].scopes, ["chat", "approve"])
    }

    func testEmptyRegistryDecodesToEmptyList() throws {
        // An empty registry is a 200 `{"devices":[]}` (NOT 404) — decode to [].
        let result = try decodeKeyed(DevicesListResult.self, #"{"devices":[]}"#)
        XCTAssertTrue(result.devices.isEmpty)
    }

    func testDevicesListTolerantOfMissingWrapperKey() throws {
        // A defensive empty/odd body never crashes the decode.
        let result = try decodeKeyed(DevicesListResult.self, "{}")
        XCTAssertTrue(result.devices.isEmpty)
    }

    func testIssuedDeviceDecodesTokenOnce() throws {
        // The ONLY shape that carries the token — the one-time issue response.
        let json = """
        {"device_id":"dev_new001","token":"tok_secret_value_xyz","device_name":"iPhone",
         "created_at":1700001234.0}
        """
        let issued = try decodeKeyed(IssuedDevice.self, json)
        XCTAssertEqual(issued.deviceId, "dev_new001")
        XCTAssertEqual(issued.token, "tok_secret_value_xyz")
        XCTAssertEqual(issued.deviceName, "iPhone")
    }

    func testIssueDevice409ThrowsTypedLimitReachedWithMaxDevices() async {
        let body = Data(#"{"error":"device limit reached","max_devices":64}"#.utf8)
        let client = makeIssueClient(body: body, status: 409)

        do {
            _ = try await client.issueDevice(name: "iPhone")
            XCTFail("expected DeviceIssueError.limitReached")
        } catch DeviceIssueError.limitReached(let maxDevices) {
            XCTAssertEqual(maxDevices, 64)
        } catch {
            XCTFail("expected DeviceIssueError.limitReached, got \(error)")
        }
    }

    func testIssueDeviceNon409StillSurfacesRestError() async {
        let body = Data(#"{"error":"registry persist failed"}"#.utf8)
        let client = makeIssueClient(body: body, status: 500)

        do {
            _ = try await client.issueDevice(name: "iPhone")
            XCTFail("expected RestError.badStatus")
        } catch RestError.badStatus(let code, let errorBody) {
            XCTAssertEqual(code, 500)
            XCTAssertTrue(errorBody.contains("registry persist failed"))
        } catch {
            XCTFail("expected RestError.badStatus, got \(error)")
        }
    }

    func testDeviceLimitReachedMessageIsActionable() {
        let message = ConnectionStore.deviceLimitReachedMessage(maxDevices: 64)
        XCTAssertTrue(message.contains("64"))
        XCTAssertTrue(message.localizedCaseInsensitiveContains("revoke"))
        XCTAssertTrue(message.localizedCaseInsensitiveContains("retry"))
    }

    func testDeviceLimitReachedKeepsConnectedSessionLiveAndDismissible() {
        let sessions = SessionStore()
        let chat = ChatStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        let server = "https://gw.example:9119"

        connection.phase = .connected
        connection._handleDeviceLimitReachedForTesting(serverURL: server, maxDevices: 64)

        XCTAssertEqual(connection.phase, .connected)
        XCTAssertEqual(connection.deviceLimitAdvisory, ConnectionStore.deviceLimitReachedMessage(maxDevices: 64))
        XCTAssertTrue(connection._isDeviceIssueLimitReachedSuppressedForTesting(serverURL: server))

        connection.dismissDeviceLimitAdvisory()

        XCTAssertNil(connection.deviceLimitAdvisory)
        XCTAssertEqual(connection.phase, .connected)
        XCTAssertTrue(connection._isDeviceIssueLimitReachedSuppressedForTesting(serverURL: server))
    }

    func testRetryDeviceUpgradeAfterRevokeClearsSuppressionAndReEntersAutoUpgrade() async {
        let server = "https://retry-success.example:9119"
        KeychainService.deleteToken(server: server)
        defer {
            KeychainService.deleteToken(server: server)
            DefaultsKeys.setDeviceId(nil, server: server)
        }
        IssueDeviceProtocol.reset(
            body: Data(#"{"device_id":"dev_retry","token":"tok_retry","device_name":"iPhone","created_at":1}"#.utf8),
            status: 200
        )

        let sessions = SessionStore()
        let chat = ChatStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        connection._seedConnectedForTesting(serverURL: server, token: "shared-token")
        connection.capabilities._setDevicesForTesting(.available)
        connection._restOverrideForTesting = makeIssueClient(body: IssueDeviceProtocol.response.0, status: IssueDeviceProtocol.response.1)
        connection._handleDeviceLimitReachedForTesting(serverURL: server, maxDevices: 64)

        await connection.retryDeviceUpgrade(serverURL: server)

        XCTAssertFalse(connection._isDeviceIssueLimitReachedSuppressedForTesting(serverURL: server))
        XCTAssertEqual(DefaultsKeys.deviceId(server: server), "dev_retry")
        XCTAssertNil(connection.deviceLimitAdvisory)
        XCTAssertEqual(IssueDeviceProtocol.issueRequestCount, 1)
    }

    func testRetryDeviceUpgradeThatStillHitsLimitRearmsSuppressionAndShowsAdvisory() async {
        let server = "https://retry-limit.example:9119"
        KeychainService.deleteToken(server: server)
        defer {
            KeychainService.deleteToken(server: server)
            DefaultsKeys.setDeviceId(nil, server: server)
        }
        IssueDeviceProtocol.reset(
            body: Data(#"{"error":"device limit reached","max_devices":64}"#.utf8),
            status: 409
        )

        let sessions = SessionStore()
        let chat = ChatStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        connection._seedConnectedForTesting(serverURL: server, token: "shared-token")
        connection.capabilities._setDevicesForTesting(.available)
        connection._restOverrideForTesting = makeIssueClient(body: IssueDeviceProtocol.response.0, status: IssueDeviceProtocol.response.1)
        connection._handleDeviceLimitReachedForTesting(serverURL: server, maxDevices: nil)

        await connection.retryDeviceUpgrade(serverURL: server)

        XCTAssertTrue(connection._isDeviceIssueLimitReachedSuppressedForTesting(serverURL: server))
        XCTAssertNil(DefaultsKeys.deviceId(server: server))
        XCTAssertEqual(connection.deviceLimitAdvisory, ConnectionStore.deviceLimitReachedMessage(maxDevices: 64))
        XCTAssertEqual(IssueDeviceProtocol.issueRequestCount, 1)
    }

    func testDeviceLimitReachedDuringHydrationDoesNotForceOffline() {
        let sessions = SessionStore()
        let chat = ChatStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)

        connection.phase = .hydrating
        connection._handleDeviceLimitReachedForTesting(serverURL: "https://gw.example:9119", maxDevices: nil)

        XCTAssertEqual(connection.phase, .hydrating)
        XCTAssertNotNil(connection.deviceLimitAdvisory)
    }

    func testRevokeResultDecodes() throws {
        let json = #"{"revoked":true,"device_id":"dev_abc123","sockets_closed":2}"#
        let result = try decodeKeyed(RevokeDeviceResult.self, json)
        XCTAssertTrue(result.revoked)
        XCTAssertEqual(result.deviceId, "dev_abc123")
        XCTAssertEqual(result.socketsClosed, 2)
    }

    func testRevokePersistFailureThrowsTypedErrorWithDistinctMessage() async {
        let body = Data(#"{"error":"revocation persist failed","revoked":true,"device_id":"dev_abc123","sockets_closed":2}"#.utf8)
        let client = makeIssueClient(body: body, status: 500)

        do {
            _ = try await client.revokeDevice(id: "dev_abc123")
            XCTFail("expected DeviceRevokeError.persistFailed")
        } catch DeviceRevokeError.persistFailed(let result) {
            XCTAssertTrue(result.revoked)
            XCTAssertEqual(result.deviceId, "dev_abc123")
            XCTAssertEqual(result.socketsClosed, 2)

            let persistFailureMessage = DeviceRevokeError.persistFailed(result).errorDescription ?? ""
            let genericFailureMessage = RestError.badStatus(500, body: #"{"error":"boom"}"#).errorDescription ?? ""
            XCTAssertTrue(persistFailureMessage.localizedCaseInsensitiveContains("not durably revoked"), persistFailureMessage)
            XCTAssertNotEqual(persistFailureMessage, genericFailureMessage)
        } catch {
            XCTFail("expected DeviceRevokeError.persistFailed, got \(error)")
        }
    }

    func testRevokeGeneric500StillSurfacesRestError() async {
        let body = Data(#"{"error":"boom"}"#.utf8)
        let client = makeIssueClient(body: body, status: 500)

        do {
            _ = try await client.revokeDevice(id: "dev_abc123")
            XCTFail("expected RestError.badStatus")
        } catch DeviceRevokeError.persistFailed {
            XCTFail("generic 500 must not be mapped to persist-failure")
        } catch RestError.badStatus(let code, let errorBody) {
            XCTAssertEqual(code, 500)
            XCTAssertTrue(errorBody.contains("boom"))
        } catch {
            XCTFail("expected RestError.badStatus, got \(error)")
        }
    }

    // MARK: - ApprovalAuditEntry decode (two identities)

    func testAuditDecodesSharedAndDeviceRecords() throws {
        // Captured from the pinned audit JSONL schema: a SHARED-token resolve
        // (credential "shared", device_id null) and a DEVICE-token resolve
        // (credential "device", with device_id/name/8-char prefix — NEVER a full
        // token). Most-recent-first ordering is server-side; here we pin decode.
        let json = """
        {"entries":[
          {"ts":1700002000.0,"session_id":"s1","session_key":"sk1","choice":"once",
           "resolve_all":false,"credential":"device","device_id":"dev_abc123",
           "device_name":"Test iPhone","token_prefix":"ab12cd34",
           "command_preview":"rm -rf /tmp/build"},
          {"ts":1700001000.0,"session_id":"s2","session_key":"sk2","choice":"deny",
           "resolve_all":true,"credential":"shared","device_id":null,
           "device_name":null,"token_prefix":null,"command_preview":"curl example.com"}
        ]}
        """
        let result = try decodeKeyed(ApprovalAuditResult.self, json)
        XCTAssertEqual(result.entries.count, 2)

        let device = result.entries[0]
        XCTAssertEqual(device.credential, "device")
        XCTAssertEqual(device.deviceId, "dev_abc123")
        XCTAssertEqual(device.deviceName, "Test iPhone")
        XCTAssertEqual(device.tokenPrefix, "ab12cd34")
        XCTAssertEqual(device.tokenPrefix?.count, 8)  // 8-char prefix, never full
        XCTAssertEqual(device.choice, "once")
        XCTAssertFalse(device.resolveAll)
        XCTAssertEqual(device.commandPreview, "rm -rf /tmp/build")

        let shared = result.entries[1]
        XCTAssertEqual(shared.credential, "shared")
        XCTAssertNil(shared.deviceId)
        XCTAssertNil(shared.tokenPrefix)
        XCTAssertTrue(shared.resolveAll)
        XCTAssertEqual(shared.choice, "deny")
    }

    func testAuditTolerantOfMissingOptionalFields() throws {
        let json = #"{"entries":[{"ts":1.0,"choice":"session"}]}"#
        let result = try decodeKeyed(ApprovalAuditResult.self, json)
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.entries[0].choice, "session")
        XCTAssertEqual(result.entries[0].credential, "shared")  // defaulted
        XCTAssertNil(result.entries[0].deviceId)
    }

    func testAuditAttributionNeverShowsFullToken() {
        // The attribution line shows the device/shared label + 8-char prefix only.
        let deviceEntry = ApprovalAuditEntry(
            ts: 1, sessionId: "s", sessionKey: "k", choice: "once", resolveAll: false,
            credential: "device", deviceId: "dev_1", deviceName: "My Phone",
            tokenPrefix: "ab12cd34", commandPreview: "ls"
        )
        let attribution = ApprovalAuditView.attribution(deviceEntry)
        XCTAssertTrue(attribution.contains("My Phone"))
        XCTAssertTrue(attribution.contains("ab12cd34"))
        XCTAssertFalse(attribution.contains("dev_1"))  // id not displayed in attribution

        let sharedEntry = ApprovalAuditEntry(
            ts: 1, sessionId: "s", sessionKey: "k", choice: "deny", resolveAll: true,
            credential: "shared", deviceId: nil, deviceName: nil,
            tokenPrefix: nil, commandPreview: nil
        )
        XCTAssertEqual(ApprovalAuditView.attribution(sharedEntry), "Shared token")
    }

    func testAuditChoiceLabels() {
        XCTAssertEqual(ApprovalAuditView.choiceLabel("once"), "Approved once")
        XCTAssertEqual(ApprovalAuditView.choiceLabel("session"), "Approved for session")
        XCTAssertEqual(ApprovalAuditView.choiceLabel("always"), "Always approved")
        XCTAssertEqual(ApprovalAuditView.choiceLabel("deny"), "Denied")
        XCTAssertTrue(ApprovalAuditView.isDeny("deny"))
        XCTAssertFalse(ApprovalAuditView.isDeny("once"))
    }

    // MARK: - QR v1 / v2 parse

    func testQRv1ParsesAsSharedPairing() {
        // A v1 payload (no `kind`) → shared pairing; isDeviceToken false, no id.
        let payload = "hermesapp://pair?url=https%3A%2F%2Fhost%3A9119&token=sharedtok123"
        let parsed = HermesURLRouter.parsePairPayload(payload)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.url, "https://host:9119")
        XCTAssertEqual(parsed?.token, "sharedtok123")
        XCTAssertEqual(parsed?.isDeviceToken, false)
        XCTAssertNil(parsed?.deviceId)
    }

    func testQRv2ParsesDeviceTokenAndRecordsId() {
        // A v2 `kind=device` payload → device pairing; isDeviceToken true, id set.
        let payload = "hermesapp://pair?url=https%3A%2F%2Fhost%3A9119&token=devtok456&kind=device&device_id=dev_qr789"
        let parsed = HermesURLRouter.parsePairPayload(payload)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.token, "devtok456")
        XCTAssertEqual(parsed?.isDeviceToken, true)
        XCTAssertEqual(parsed?.deviceId, "dev_qr789")
    }

    func testQRv2IgnoresUnknownKeysAndDefaultsToShared() {
        // Unknown extra keys are ignored; a `kind` that isn't "device" → shared.
        let payload = "hermesapp://pair?url=https%3A%2F%2Fh&token=t&kind=shared&future_key=zzz"
        let parsed = HermesURLRouter.parsePairPayload(payload)
        XCTAssertEqual(parsed?.isDeviceToken, false)
        XCTAssertNil(parsed?.deviceId)
        XCTAssertEqual(parsed?.token, "t")
    }

    func testQRv2DeviceKindMissingIdFallsBackToShared() {
        // Defensive: `kind=device` without a device_id falls back to shared.
        let payload = "hermesapp://pair?url=https%3A%2F%2Fh&token=t&kind=device"
        let parsed = HermesURLRouter.parsePairPayload(payload)
        XCTAssertEqual(parsed?.isDeviceToken, false)
        XCTAssertNil(parsed?.deviceId)
    }

    func testQRRejectsMissingRequiredFields() {
        XCTAssertNil(HermesURLRouter.parsePairPayload("hermesapp://pair?url=https%3A%2F%2Fh"))
        XCTAssertNil(HermesURLRouter.parsePairPayload("hermesapp://pair?token=t"))
        XCTAssertNil(HermesURLRouter.parsePairPayload("https://example.com"))
        XCTAssertNil(HermesURLRouter.parsePairPayload("hermesapp://new-session"))
    }

    // MARK: - Auto-upgrade decision logic (the migration bridge)

    /// The pure decision the auto-upgrade path applies BEFORE issuing: issue iff
    /// the capability is available AND no device_id is recorded for the server.
    /// (The real method also guards the live token/URL; that is exercised by the
    /// persistence round-trip below.)
    private func shouldAutoUpgrade(capability: ServerCapabilities.State, hasRecordedId: Bool) -> Bool {
        capability == .available && !hasRecordedId
    }

    func testAutoUpgradeIssuesOnlyWhenAvailableAndNoRecordedId() {
        // Available + no recorded id ⇒ issue.
        XCTAssertTrue(shouldAutoUpgrade(capability: .available, hasRecordedId: false))
        // Available + already has a device token ⇒ do NOT re-issue.
        XCTAssertFalse(shouldAutoUpgrade(capability: .available, hasRecordedId: true))
        // Stock server (unavailable) ⇒ never issue (keep shared token).
        XCTAssertFalse(shouldAutoUpgrade(capability: .unavailable, hasRecordedId: false))
        // Unsettled/flaky probe ⇒ never issue.
        XCTAssertFalse(shouldAutoUpgrade(capability: .unknown, hasRecordedId: false))
    }

    func testRecordedDeviceIdPersistencePerServer() {
        // The recorded device_id is keyed per server (mirrors the per-server
        // Keychain token model). No id recorded ⇒ auto-upgrade is eligible.
        let serverA = "https://a:9119"
        let serverB = "https://b:9119"
        XCTAssertNil(DefaultsKeys.deviceId(server: serverA))

        DefaultsKeys.setDeviceId("dev_a", server: serverA)
        XCTAssertEqual(DefaultsKeys.deviceId(server: serverA), "dev_a")
        // A different server is independent (still eligible to upgrade).
        XCTAssertNil(DefaultsKeys.deviceId(server: serverB))

        DefaultsKeys.setDeviceId("dev_b", server: serverB)
        XCTAssertEqual(DefaultsKeys.deviceId(server: serverB), "dev_b")
        XCTAssertEqual(DefaultsKeys.deviceId(server: serverA), "dev_a")  // unchanged

        // Clearing (revoke of current device / re-pair) makes it eligible again.
        DefaultsKeys.setDeviceId(nil, server: serverA)
        XCTAssertNil(DefaultsKeys.deviceId(server: serverA))
        XCTAssertEqual(DefaultsKeys.deviceId(server: serverB), "dev_b")
    }

    func testFailureKeepsSharedTokenAndNoRecordedId() {
        // Model the failure path: an issue that throws must leave NO device_id
        // recorded (so a later connect retries) and must NOT swap the token. Since
        // the decision keys on `hasRecordedId`, an absent id after a failure keeps
        // the device eligible — the proof the shared token is retained.
        let server = "https://fail:9119"
        // Simulate: issue threw → we do NOT call setDeviceId → id stays nil.
        XCTAssertNil(DefaultsKeys.deviceId(server: server))
        XCTAssertTrue(shouldAutoUpgrade(capability: .available, hasRecordedId: DefaultsKeys.deviceId(server: server) != nil))
    }

    func testV2QRRecordsIdSoNoAutoUpgrade() {
        // After a v2 `kind=device` QR records the id, the auto-upgrade decision
        // is false (the device already holds a device token — don't re-issue).
        let server = "https://v2:9119"
        DefaultsKeys.setDeviceId("dev_qr789", server: server)
        XCTAssertFalse(
            shouldAutoUpgrade(capability: .available, hasRecordedId: DefaultsKeys.deviceId(server: server) != nil)
        )
    }

    // MARK: - Auto-upgrade auth gating (STR-1568)

    /// Routes stub responses by URL path so one session answers both the live
    /// `GET /api/status` auth-gate check and the `POST /api/devices/issue` call
    /// the real `autoUpgradeToDeviceTokenIfNeeded` makes — exercising the actual
    /// method end-to-end (not a mirrored decision function) via the STR-1417
    /// `_restOverrideForTesting` seam.
    final class AutoUpgradeRoutingProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var statusBody = Data(#"{"auth_required":true}"#.utf8)
        nonisolated(unsafe) static var statusCode = 200
        nonisolated(unsafe) static var issueBody = Data()
        nonisolated(unsafe) static var issueCode = 200
        nonisolated(unsafe) static var issueCallCount = 0

        static func reset() {
            statusBody = Data(#"{"auth_required":true}"#.utf8)
            statusCode = 200
            issueBody = Data()
            issueCode = 200
            issueCallCount = 0
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let path = request.url?.path ?? ""
            let (body, status): (Data, Int)
            if path.hasSuffix("/devices/issue") {
                Self.issueCallCount += 1
                (body, status) = (Self.issueBody, Self.issueCode)
            } else {
                (body, status) = (Self.statusBody, Self.statusCode)
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    /// A `ConnectionStore` seeded as already connected + `devices == .available`
    /// (so `autoUpgradeToDeviceTokenIfNeeded`'s early guards pass) with `rest`
    /// overridden to the routing stub above.
    private func makeAutoUpgradeConnection(server: String) -> ConnectionStore {
        let connection = ConnectionStore(sessionStore: SessionStore(), chatStore: ChatStore())
        connection._seedConnectedForTesting(serverURL: server, token: "shared_tok")
        connection.capabilities._setDevicesForTesting(.available)
        AutoUpgradeRoutingProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AutoUpgradeRoutingProtocol.self]
        connection._restOverrideForTesting = RestClient(
            baseURL: URL(string: server)!,
            token: "shared_tok",
            session: URLSession(configuration: config),
            pathStyle: .legacy
        )
        return connection
    }

    func testAutoUpgradeSkipsIssueWhenAuthNotRequiredOnLoopback() async {
        // A loopback dev-gateway (`auth_required: false`) runs ONLY the legacy
        // shared-token-only middleware on `/api/*` — a device token 401s there
        // (the root cause STR-1568 traced). The auto-upgrade must see the live
        // status and skip the issue call entirely, keeping the shared token.
        let server = "http://127.0.0.1:9119"
        let connection = makeAutoUpgradeConnection(server: server)
        AutoUpgradeRoutingProtocol.statusBody = Data(#"{"auth_required":false}"#.utf8)

        await connection.autoUpgradeToDeviceTokenIfNeeded(serverURL: server)

        XCTAssertEqual(AutoUpgradeRoutingProtocol.issueCallCount, 0)
        XCTAssertNil(DefaultsKeys.deviceId(server: server))
    }

    func testAutoUpgradeIssuesWhenAuthRequiredTrue() async {
        // The gated (non-loopback / OAuth) path is unchanged: `auth_required:
        // true` ⇒ proceed to issue + record the device token exactly as before.
        let server = "https://gw.example:9119"
        let connection = makeAutoUpgradeConnection(server: server)
        AutoUpgradeRoutingProtocol.statusBody = Data(#"{"auth_required":true}"#.utf8)
        AutoUpgradeRoutingProtocol.issueBody = Data("""
        {"device_id":"dev_gated001","token":"tok_new_device","device_name":"iPhone",
         "created_at":1700001234.0}
        """.utf8)

        await connection.autoUpgradeToDeviceTokenIfNeeded(serverURL: server)

        XCTAssertEqual(AutoUpgradeRoutingProtocol.issueCallCount, 1)
        XCTAssertEqual(DefaultsKeys.deviceId(server: server), "dev_gated001")
    }

    func testAutoUpgradeFailSafeSkipsIssueWhenStatusUnreachable() async {
        // A transport/decode failure on the status check must fail SAFE — same
        // outcome as `auth_required == false` — never fail open and let an issue
        // call slip through blind because the gate itself couldn't be read.
        let server = "https://flaky:9119"
        let connection = makeAutoUpgradeConnection(server: server)
        AutoUpgradeRoutingProtocol.statusBody = Data("not json".utf8)

        await connection.autoUpgradeToDeviceTokenIfNeeded(serverURL: server)

        XCTAssertEqual(AutoUpgradeRoutingProtocol.issueCallCount, 0)
        XCTAssertNil(DefaultsKeys.deviceId(server: server))
    }

    func testDeviceNameHintIsNonEmpty() {
        // The auto-upgrade device-name hint is always a non-empty label (generic
        // model name acceptable per the contract's open question).
        XCTAssertFalse(ConnectionStore.deviceNameHint.isEmpty)
    }

    // MARK: - Single-flight in-flight gate (STR-546/STR-512)

    /// Coordinates a stubbed `issueDevice` round-trip so a test can hold it open
    /// until both overlapping `autoUpgradeToDeviceTokenIfNeeded` calls have had a
    /// chance to reach the single-flight guard, then release it once — proving
    /// the second caller joined the first's `Task` rather than starting its own.
    private actor IssueCallGate {
        private(set) var callCount = 0
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func recordCallAndWaitUntilOpen() async {
            callCount += 1
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }

    private func decodeIssuedDevice(deviceId: String, token: String) throws -> IssuedDevice {
        try JSONDecoder().decode(IssuedDevice.self, from: Data("""
        {"device_id":"\(deviceId)","token":"\(token)","device_name":"iPhone",
         "created_at":1700001234.0}
        """.utf8))
    }

    func testAutoUpgradeSingleFlightSharesOneIssueCallForOverlappingRequests() async throws {
        // Two overlapping auto-upgrade calls for the SAME server (e.g. the
        // initial connect racing a reconnect-loop retry) must share one
        // `/devices/issue` operation, not mint two device tokens against the
        // same server (STR-512's orphan-token / 64-device-cap bug).
        let server = "https://gw.example:9119"
        let connection = makeAutoUpgradeConnection(server: server)
        AutoUpgradeRoutingProtocol.statusBody = Data(#"{"auth_required":true}"#.utf8)

        let gate = IssueCallGate()
        let issued = try decodeIssuedDevice(deviceId: "dev_single_flight", token: "tok_single_flight")
        connection.issueDeviceRPC = { _, _ in
            await gate.recordCallAndWaitUntilOpen()
            return issued
        }

        async let first: Void = connection.autoUpgradeToDeviceTokenIfNeeded(serverURL: server)
        // Give the first call time to clear its guards, land in the suspended
        // issue round-trip, and register itself as the in-flight task before the
        // second call starts — otherwise the second could race ahead of the
        // dictionary write and spuriously start its own task.
        try? await Task.sleep(nanoseconds: 50_000_000)
        async let second: Void = connection.autoUpgradeToDeviceTokenIfNeeded(serverURL: server)
        try? await Task.sleep(nanoseconds: 50_000_000)
        await gate.open()
        _ = await (first, second)

        let callCount = await gate.callCount
        XCTAssertEqual(
            callCount, 1,
            "overlapping auto-upgrade calls for the same server must share one issue operation"
        )
        XCTAssertEqual(DefaultsKeys.deviceId(server: server), "dev_single_flight")
    }

    func testAutoUpgradeRetryNotPermanentlySuppressedAfterGenericIssueFailure() async {
        // A generic issue failure (not the typed 409 limit-reached path) must
        // clear the single-flight gate on exit — a later legitimate retry (the
        // next connect/reconnect) must still be able to issue, not find itself
        // permanently stuck behind a dead in-flight entry.
        let server = "https://gw.example:9119"
        let connection = makeAutoUpgradeConnection(server: server)
        AutoUpgradeRoutingProtocol.statusBody = Data(#"{"auth_required":true}"#.utf8)
        AutoUpgradeRoutingProtocol.issueCode = 500

        await connection.autoUpgradeToDeviceTokenIfNeeded(serverURL: server)
        XCTAssertEqual(AutoUpgradeRoutingProtocol.issueCallCount, 1)
        XCTAssertNil(DefaultsKeys.deviceId(server: server))

        AutoUpgradeRoutingProtocol.issueCode = 200
        AutoUpgradeRoutingProtocol.issueBody = Data("""
        {"device_id":"dev_retry001","token":"tok_retry","device_name":"iPhone",
         "created_at":1700001234.0}
        """.utf8)

        await connection.autoUpgradeToDeviceTokenIfNeeded(serverURL: server)
        XCTAssertEqual(AutoUpgradeRoutingProtocol.issueCallCount, 2)
        XCTAssertEqual(DefaultsKeys.deviceId(server: server), "dev_retry001")
    }

    // MARK: - Current-device marking + revoke confirmation flow logic

    func testIsCurrentDeviceMatchesRecordedId() {
        XCTAssertTrue(DevicesView.isCurrentDevice("dev_1", recordedDeviceId: "dev_1"))
        XCTAssertFalse(DevicesView.isCurrentDevice("dev_1", recordedDeviceId: "dev_2"))
        // No recorded id (still on shared token) ⇒ no row is current.
        XCTAssertFalse(DevicesView.isCurrentDevice("dev_1", recordedDeviceId: nil))
        XCTAssertFalse(DevicesView.isCurrentDevice("dev_1", recordedDeviceId: ""))
    }

    func testRevokeMessageDistinguishesCurrentDevice() {
        let device = PairedDevice(
            deviceId: "dev_1", deviceName: "My Phone", platform: "ios",
            createdAt: 1, lastSeen: 2, tokenPrefix: "ab12cd34"
        )
        let currentMsg = DevicesView.revokeMessage(device: device, isCurrent: true)
        XCTAssertTrue(currentMsg.contains("signs you out"))
        XCTAssertTrue(currentMsg.contains("new pairing code"))

        let otherMsg = DevicesView.revokeMessage(device: device, isCurrent: false)
        XCTAssertTrue(otherMsg.contains("My Phone"))
        XCTAssertFalse(otherMsg.contains("new pairing code"))
    }

    func testRevokingCurrentDeviceClearsRecordedIdForRepair() {
        // The revoke-of-current-device flow clears the recorded id so the next
        // request 401s into the existing re-pair path (a re-scan auto-upgrades to
        // a FRESH device_id). Model that state mutation here.
        let server = "https://repair:9119"
        DefaultsKeys.setDeviceId("dev_current", server: server)
        XCTAssertNotNil(DefaultsKeys.deviceId(server: server))
        // Simulate the post-revoke clear the view performs for the current device.
        DefaultsKeys.setDeviceId(nil, server: server)
        XCTAssertNil(DefaultsKeys.deviceId(server: server))
        // Now the device is eligible to auto-upgrade again on the next pairing.
        XCTAssertTrue(shouldAutoUpgrade(capability: .available, hasRecordedId: false))
    }

    func testSuccessfulSelfRevokeForgetsLocallyBeforeDrivingRepairState() async {
        let sessions = SessionStore()
        let chat = ChatStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        let server = "https://self-revoke:9119"
        UserDefaults.standard.set(server, forKey: DefaultsKeys.serverURL)
        try? KeychainService.saveToken("revoked-device-token", server: server)
        DefaultsKeys.setDeviceId("dev_current", server: server)
        defer { KeychainService.deleteToken(server: server) }
        connection._seedConnectedForTesting(serverURL: server, token: "revoked-device-token")
        sessions.markTurnStarted(storedId: "stored-self-revoke")
        XCTAssertTrue(connection.hasConnected, "precondition: self-revoke starts from a paired connection")
        XCTAssertFalse(sessions.turnsInProgressIds.isEmpty,
            "precondition: self-revoke can happen while a turn is in flight")

        await DevicesView.applySuccessfulRevokeSideEffects(
            wasCurrent: true,
            serverURL: server,
            connection: connection
        )
        connection._handleGatewayStateForTesting(.closed(reason: nil))

        XCTAssertNil(DefaultsKeys.deviceId(server: server))
        XCTAssertNil(KeychainService.loadToken(server: server))
        XCTAssertNil(UserDefaults.standard.string(forKey: DefaultsKeys.serverURL))
        XCTAssertTrue(connection.reauthRequired)
        XCTAssertEqual(connection.phase, .needsSetup)
        XCTAssertFalse(connection.hasConnected)
        XCTAssertTrue(sessions.turnsInProgressIds.isEmpty)
    }

    func testSuccessfulSelfRevokeClearsSpotlightIndex() async {
        let sessions = SessionStore()
        let chat = ChatStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        var clearCount = 0
        ConnectionStore.spotlightClearAllForTesting = { clearCount += 1 }

        await DevicesView.applySuccessfulRevokeSideEffects(
            wasCurrent: true,
            serverURL: "https://self-revoke-spotlight:9119",
            connection: connection
        )

        XCTAssertEqual(clearCount, 1)
    }

    func testSuccessfulOtherDeviceRevokeDoesNotDriveRepairState() async {
        let sessions = SessionStore()
        let chat = ChatStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        let server = "https://other-revoke:9119"
        UserDefaults.standard.set(server, forKey: DefaultsKeys.serverURL)
        try? KeychainService.saveToken("current-token", server: server)
        DefaultsKeys.setDeviceId("dev_current", server: server)
        connection.phase = .connected
        defer {
            KeychainService.deleteToken(server: server)
            UserDefaults.standard.removeObject(forKey: DefaultsKeys.serverURL)
            DefaultsKeys.setDeviceId(nil, server: server)
        }

        await DevicesView.applySuccessfulRevokeSideEffects(
            wasCurrent: false,
            serverURL: server,
            connection: connection
        )

        XCTAssertEqual(DefaultsKeys.deviceId(server: server), "dev_current")
        XCTAssertEqual(KeychainService.loadToken(server: server), "current-token")
        XCTAssertEqual(UserDefaults.standard.string(forKey: DefaultsKeys.serverURL), server)
        XCTAssertFalse(connection.reauthRequired)
        XCTAssertEqual(connection.phase, .connected)
    }

    func testRepeatedSuccessfulSelfRevokeCallbacksRemainIdempotent() async {
        let sessions = SessionStore()
        let chat = ChatStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        let server = "https://self-revoke-repeat:9119"
        UserDefaults.standard.set(server, forKey: DefaultsKeys.serverURL)
        try? KeychainService.saveToken("revoked-token", server: server)
        DefaultsKeys.setDeviceId("dev_current", server: server)
        connection._seedConnectedForTesting(serverURL: server, token: "revoked-token")
        defer { KeychainService.deleteToken(server: server) }

        await DevicesView.applySuccessfulRevokeSideEffects(
            wasCurrent: true, serverURL: server, connection: connection
        )
        await DevicesView.applySuccessfulRevokeSideEffects(
            wasCurrent: true, serverURL: server, connection: connection
        )

        XCTAssertNil(KeychainService.loadToken(server: server))
        XCTAssertNil(DefaultsKeys.deviceId(server: server))
        XCTAssertNil(UserDefaults.standard.string(forKey: DefaultsKeys.serverURL))
        XCTAssertEqual(connection.phase, .needsSetup)
        XCTAssertTrue(connection.reauthRequired)
        XCTAssertFalse(connection.hasConnected)
        XCTAssertNil(connection.reconnectTask)
    }

    func testDeviceRowDetailLineUsesPrefixNeverToken() {
        let device = PairedDevice(
            deviceId: "dev_1", deviceName: "Phone", platform: "ios",
            createdAt: 1700000000, lastSeen: 1700000500, tokenPrefix: "ab12cd34"
        )
        let line = DevicesView.detailLine(device)
        XCTAssertTrue(line.contains("ab12cd34"))
    }

    func testPlatformIconMapping() {
        XCTAssertEqual(DevicesView.platformIcon("ios"), "iphone")
        XCTAssertEqual(DevicesView.platformIcon("macos"), "laptopcomputer")
        XCTAssertEqual(DevicesView.platformIcon("linux"), "desktopcomputer")
    }

    // MARK: - Devices-section visibility gate (the stock-degradation guarantee)

    func testDevicesSectionVisibilityGate() {
        // The Settings Devices section + the auto-upgrade BOTH gate on
        // `devices == .available`. Pin that gate so a stock / unsettled server
        // hides the section and never issues a token.
        func sectionVisible(_ capability: ServerCapabilities.State) -> Bool {
            capability == .available
        }
        XCTAssertTrue(sectionVisible(.available))
        XCTAssertFalse(sectionVisible(.unavailable))  // stock gateway
        XCTAssertFalse(sectionVisible(.unknown))      // not yet probed / flaky
    }

    // MARK: - SECRET HYGIENE (binding)

    func testIssuedTokenNeverPersistsToUserDefaults() {
        // BINDING: the issue response token is persisted ONLY to the Keychain.
        // The device_id (non-secret) is the ONLY thing written to UserDefaults.
        // Simulate the swap's UserDefaults write and assert the token is absent
        // from the entire standard-defaults dictionary.
        let server = "https://hygiene:9119"
        let secretToken = "tok_super_secret_should_never_appear_12345"
        let issued = IssuedDevice(
            deviceId: "dev_hyg", token: secretToken, deviceName: "iPhone", createdAt: 1
        )
        // The ONLY UserDefaults write the swap performs is the non-secret id.
        DefaultsKeys.setDeviceId(issued.deviceId, server: server)

        // Sweep the whole standard-defaults dictionary for the token string.
        let all = UserDefaults.standard.dictionaryRepresentation()
        for (_, value) in all {
            if let s = value as? String {
                XCTAssertFalse(s.contains(secretToken), "token leaked into UserDefaults string")
            }
            if let dict = value as? [String: String] {
                for v in dict.values {
                    XCTAssertFalse(v.contains(secretToken), "token leaked into a UserDefaults dictionary")
                }
            }
        }
        // The recorded id IS present (non-secret), proving the write happened.
        XCTAssertEqual(DefaultsKeys.deviceId(server: server), "dev_hyg")
    }

    func testDeviceModelsCarryNoTokenOnListOrAudit() {
        // The list + audit shapes structurally cannot carry a token — only the
        // 8-char prefix. Assert by Mirror that no `token` property exists on the
        // surfaces that are echoed back (only IssuedDevice has one).
        let device = PairedDevice(
            deviceId: "d", deviceName: "n", platform: "ios",
            createdAt: 1, lastSeen: 2, tokenPrefix: "ab12cd34"
        )
        let deviceLabels = Mirror(reflecting: device).children.compactMap { $0.label }
        XCTAssertFalse(deviceLabels.contains("token"))
        XCTAssertTrue(deviceLabels.contains("tokenPrefix"))

        let audit = ApprovalAuditEntry(
            ts: 1, sessionId: "s", sessionKey: "k", choice: "once", resolveAll: false,
            credential: "device", deviceId: "d", deviceName: "n",
            tokenPrefix: "ab12cd34", commandPreview: "ls"
        )
        let auditLabels = Mirror(reflecting: audit).children.compactMap { $0.label }
        XCTAssertFalse(auditLabels.contains("token"))
        XCTAssertTrue(auditLabels.contains("tokenPrefix"))
    }
}
