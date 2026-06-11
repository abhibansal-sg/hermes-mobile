import XCTest
@testable import HermesMobile

/// ABH-88 W3 — REST path-family migration tests.
///
/// The gateway's mobile endpoints (upload / devices / approvals / fs / push)
/// moved from legacy top-level routes to the hermes-mobile plugin mount. The
/// app probes which family the server speaks (``ServerCapabilities/pluginMount``)
/// and pins it per server; background flows carry a one-shot alternate-family
/// 404 retry. These tests pin:
///   1. every mobile call site builds the right URL under BOTH families,
///   2. the self-healing retries fire exactly once and only on route-404,
///   3. the plugin-mount probe classification + path-style resolution,
///   4. the persisted snapshot round-trips `pluginMount` and
///      ``ServerCapabilities/cachedPathStyle(serverURL:)`` reads it back.
final class PathStyleTests: XCTestCase {

    // MARK: - Recording stub transport

    /// Intercepts URLSession requests, records every URL, and serves scripted
    /// responses in order (the last entry repeats once the script runs out).
    final class RecordingProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var requests: [URLRequest] = []
        nonisolated(unsafe) static var script: [(Data, Int)] = [(Data(), 200)]
        nonisolated(unsafe) static var served = 0

        static func reset(script: [(Data, Int)]) {
            requests = []
            self.script = script
            served = 0
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.requests.append(request)
            let index = min(Self.served, Self.script.count - 1)
            Self.served += 1
            let (body, status) = Self.script[index]
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

    private func makeClient(style: APIPathStyle, script: [(Data, Int)]) -> RestClient {
        RecordingProtocol.reset(script: script)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecordingProtocol.self]
        return RestClient(
            baseURL: URL(string: "https://gw.example:9119")!,
            token: "tok",
            session: URLSession(configuration: config),
            pathStyle: style
        )
    }

    private var recordedPaths: [String] {
        RecordingProtocol.requests.compactMap { $0.url?.path }
    }

    // MARK: - 1. Path family per call site

    func testPrefixSwapCoversEveryMobileCallSite() async throws {
        // (call, legacy path, plugin path) — every moved endpoint.
        let ok = Data("{}".utf8)
        let devices = Data(#"{"devices":[]}"#.utf8)
        let entries = Data(#"{"entries":[]}"#.utf8)
        let upload = Data(#"{"path":"/tmp/x.png","size":1}"#.utf8)
        let issued = Data(#"{"device_id":"d1","token":"t","device_name":"n"}"#.utf8)
        let revoked = Data(#"{"revoked":true,"device_id":"d1","sockets_closed":0}"#.utf8)
        let fsList = Data(#"{"root":"/","path":"","entries":[]}"#.utf8)
        let fsRead = Data(#"{"path":"a","size":1,"encoding":"utf-8","content":"x","truncated":false}"#.utf8)

        for style in [APIPathStyle.legacy, .plugin] {
            let prefix = style.mobileAPIPrefix

            var client = makeClient(style: style, script: [(upload, 200)])
            _ = try await client.upload(data: Data([1]), filename: "x.png", mimeType: "image/png")
            XCTAssertEqual(recordedPaths, ["\(prefix)/upload"])

            client = makeClient(style: style, script: [(devices, 200)])
            _ = try await client.devicesList()
            XCTAssertEqual(recordedPaths, ["\(prefix)/devices"])

            client = makeClient(style: style, script: [(issued, 200)])
            _ = try await client.issueDevice(name: "n")
            XCTAssertEqual(recordedPaths, ["\(prefix)/devices/issue"])

            client = makeClient(style: style, script: [(revoked, 200)])
            _ = try await client.revokeDevice(id: "d1")
            XCTAssertEqual(recordedPaths, ["\(prefix)/devices/d1"])

            client = makeClient(style: style, script: [(entries, 200)])
            _ = try await client.approvalAudit(limit: 5)
            XCTAssertEqual(recordedPaths, ["\(prefix)/approvals/audit"])

            client = makeClient(style: style, script: [(ok, 200)])
            _ = await client.respondToApproval(sessionId: "s", approve: true, all: false)
            XCTAssertEqual(recordedPaths, ["\(prefix)/approvals/respond"])

            client = makeClient(style: style, script: [(fsList, 200)])
            _ = try await client.fsList(sessionId: "s", path: "")
            XCTAssertEqual(recordedPaths, ["\(prefix)/fs/list"])

            client = makeClient(style: style, script: [(fsRead, 200)])
            _ = try await client.fsRead(sessionId: "s", path: "a")
            XCTAssertEqual(recordedPaths, ["\(prefix)/fs/read"])

            client = makeClient(style: style, script: [(ok, 200)])
            _ = await client.registerLiveActivity(token: "t", sessionId: "s", env: "sandbox")
            XCTAssertEqual(recordedPaths, ["\(prefix)/push/live-activity"])
        }
    }

    func testPluginMountProbeUsesAbsolutePathRegardlessOfStyle() async {
        for style in [APIPathStyle.legacy, .plugin] {
            let client = makeClient(
                style: style, script: [(Data(#"{"devices":[]}"#.utf8), 200)]
            )
            let result = await client.probePluginMountEndpoint()
            XCTAssertEqual(result, .available)
            XCTAssertEqual(recordedPaths, ["/api/plugins/hermes-mobile/devices"])
        }
    }

    func testCapabilityProbesFollowTheClientStyle() async {
        // The connect-time stage-2 probes must target the RESOLVED family —
        // a de-patched server 404s the legacy paths, so probing legacy there
        // would wrongly hide upload/fs/devices affordances.
        let client = makeClient(style: .plugin, script: [(Data(), 400)])
        _ = await client.probeUploadEndpoint()
        _ = await client.probeFsEndpoint()
        _ = await client.probeDevicesEndpoint()
        XCTAssertEqual(recordedPaths, [
            "/api/plugins/hermes-mobile/upload",
            "/api/plugins/hermes-mobile/fs/list",
            "/api/plugins/hermes-mobile/devices",
        ])
    }

    // MARK: - 2. Self-healing alternate-family retries

    func testRespondToApprovalRetriesAlternateFamilyOnRouteMiss() async {
        // First attempt (plugin) route-404s, second (legacy) resolves — the
        // stale-cache shape after a server swap under the same URL.
        let client = makeClient(style: .plugin, script: [
            (Data(), 404),
            (Data(#"{"resolved":true}"#.utf8), 200),
        ])
        let outcome = await client.respondToApproval(sessionId: "s", approve: true, all: false)
        XCTAssertEqual(outcome, .resolved)
        XCTAssertEqual(recordedPaths, [
            "/api/plugins/hermes-mobile/approvals/respond",
            "/api/approvals/respond",
        ])
    }

    func testRespondToApprovalDoubleRouteMissIsAlreadyHandled() async {
        let client = makeClient(style: .legacy, script: [(Data(), 404)])
        let outcome = await client.respondToApproval(sessionId: "s", approve: false, all: false)
        XCTAssertEqual(outcome, .alreadyHandled)
        XCTAssertEqual(RecordingProtocol.requests.count, 2)
    }

    func testRespondToApprovalDoesNotRetryOnSuccessOrHardFailure() async {
        // 200 → no second request.
        var client = makeClient(style: .plugin, script: [(Data(#"{"resolved":false}"#.utf8), 200)])
        _ = await client.respondToApproval(sessionId: "s", approve: true, all: false)
        XCTAssertEqual(RecordingProtocol.requests.count, 1)
        // 401 → no second request (credential problem, not a route miss).
        client = makeClient(style: .plugin, script: [(Data(), 401)])
        let outcome = await client.respondToApproval(sessionId: "s", approve: true, all: false)
        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(RecordingProtocol.requests.count, 1)
    }

    func testLiveActivityRetriesAlternateFamilyAndReportsNotDeployedOnDouble404() async {
        var client = makeClient(style: .legacy, script: [
            (Data(), 404),
            (Data("{}".utf8), 200),
        ])
        let healed = await client.registerLiveActivity(token: "t", sessionId: "s", env: "sandbox")
        XCTAssertEqual(healed, .success)
        XCTAssertEqual(recordedPaths, [
            "/api/push/live-activity",
            "/api/plugins/hermes-mobile/push/live-activity",
        ])

        client = makeClient(style: .legacy, script: [(Data(), 404)])
        let dead = await client.registerLiveActivity(token: "t", sessionId: "s", env: "sandbox")
        XCTAssertEqual(dead, .notDeployed)
        XCTAssertEqual(RecordingProtocol.requests.count, 2)
    }

    // MARK: - 3. Style resolution

    func testWithPathStyleSwapsOnlyTheFamily() {
        let base = makeClient(style: .legacy, script: [(Data(), 200)])
        let swapped = base.withPathStyle(.plugin)
        XCTAssertEqual(swapped.mobileAPIPrefix, "/api/plugins/hermes-mobile")
        XCTAssertEqual(swapped.baseURL, base.baseURL)
        XCTAssertEqual(swapped.token, base.token)
        XCTAssertEqual(base.mobileAPIPrefix, "/api")
    }

    @MainActor
    func testResolvedPathStyleRequiresConcludedMountProbe() {
        let caps = ServerCapabilities()
        // unknown → legacy (safe against today's live server)
        XCTAssertEqual(caps.resolvedPathStyle, .legacy)
    }

    // MARK: - 4. Cache round-trip

    @MainActor
    func testCachedPathStyleReadsThePersistedSnapshot() async {
        defer { UserDefaults.standard.removeObject(forKey: DefaultsKeys.serverCapabilities) }

        // A probe against a de-patched server: mount 200 {"devices":[]} then
        // the four stage-2 probes (status alone decides; one shared script
        // entry with 400 classifies upload/fs as available — enough to trip
        // the persist guard).
        RecordingProtocol.reset(script: [
            (Data(#"{"devices":[]}"#.utf8), 200),  // stage 1: plugin mount
            (Data(), 400),                          // stage 2: everything else
        ])
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecordingProtocol.self]
        let rest = RestClient(
            baseURL: URL(string: "https://gw.example:9119")!,
            token: "tok",
            session: URLSession(configuration: config)
        )

        let caps = ServerCapabilities()
        await caps.probe(serverURL: "https://gw.example:9119", rest: rest)

        XCTAssertEqual(caps.pluginMount, .available)
        XCTAssertEqual(caps.resolvedPathStyle, .plugin)
        // Stage 1 went out FIRST and on the absolute plugin path.
        XCTAssertEqual(recordedPaths.first, "/api/plugins/hermes-mobile/devices")

        // The static reader (background flows) sees the same decision…
        XCTAssertEqual(
            ServerCapabilities.cachedPathStyle(serverURL: "https://gw.example:9119"),
            .plugin
        )
        // …and a foreign server falls back to legacy.
        XCTAssertEqual(
            ServerCapabilities.cachedPathStyle(serverURL: "https://other.example"),
            .legacy
        )
    }
}
