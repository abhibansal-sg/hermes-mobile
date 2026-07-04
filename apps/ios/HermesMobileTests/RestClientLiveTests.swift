import XCTest
@testable import HermesMobile

/// Live integration coverage for `RestClient.upload` against a running hermes
/// gateway.
///
/// Requires the shared dashboard to be reachable, with credentials supplied via
/// the test-runner environment:
///   TEST_RUNNER_HERMES_URL / TEST_RUNNER_HERMES_TOKEN on the xcodebuild
///   invocation (surfaced to the process here as HERMES_URL / HERMES_TOKEN).
/// Skips (rather than fails) when credentials are absent so the unit suite stays
/// green in CI without a backend — mirroring the env-skip pattern in
/// `HermesMobileUITests/ChatFlowUITests.swift`.
final class RestClientLiveTests: XCTestCase {

    func testTranscriptPageFetchUsesPluginLimitAndBeforeCursor() async {
        TranscriptPageStubProtocol.nextResponse = (
            #"{"messages":[{"id":41,"role":"user","content":"older"}],"page":{"oldest_id":41,"has_more_before":true}}"#.data(using: .utf8)!,
            200
        )
        TranscriptPageStubProtocol.requestedPath = nil
        TranscriptPageStubProtocol.requestedQuery = nil
        let rest = transcriptPageStubClient(pathStyle: .plugin)

        let page = await fetchTranscriptPage(rest: rest, sessionId: "s 1", limit: 50, before: 42)

        XCTAssertEqual(TranscriptPageStubProtocol.requestedPath, "/api/plugins/hermes-mobile/sessions/s%201/messages")
        XCTAssertEqual(TranscriptPageStubProtocol.requestedQuery, "limit=50&before=42")
        XCTAssertEqual(page?.messages.map(\.wireId), [41])
        XCTAssertEqual(page?.oldestId, 41)
        XCTAssertEqual(page?.hasMoreBefore, true)
    }

    func testTranscriptPageFetchIsPluginOnly() async {
        TranscriptPageStubProtocol.requestedPath = nil
        let rest = transcriptPageStubClient(pathStyle: .legacy)

        let page = await fetchTranscriptPage(rest: rest, sessionId: "s1", limit: 50)

        XCTAssertNil(page)
        XCTAssertNil(TranscriptPageStubProtocol.requestedPath)
    }

    /// `GET /api/sessions?order=recent` must round-trip with its query string
    /// intact (regression: appendingPathComponent percent-encoded the "?" and
    /// the server 404'd, silently degrading the app to creation-ordered
    /// listings) and decode into recency-ordered summaries with lastActive.
    func testLiveSessionsAreRecencyOrdered() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let urlString = env["HERMES_URL"], let token = env["HERMES_TOKEN"],
              !urlString.isEmpty, !token.isEmpty,
              let url = URL(string: urlString) else {
            throw XCTSkip("HERMES_URL/HERMES_TOKEN not provided; skipping live sessions test")
        }

        let client = RestClient(baseURL: url, token: token)
        let sessions = try await client.sessions(limit: 50)

        XCTAssertFalse(sessions.isEmpty, "Live gateway should report sessions")
        let actives = sessions.compactMap(\.lastActive)
        XCTAssertFalse(actives.isEmpty, "REST rows should carry last_active")
        XCTAssertEqual(
            actives, actives.sorted(by: >),
            "Sessions must be ordered most-recently-active first"
        )
    }

    /// Round-trip a tiny PNG through `POST /api/upload` and assert the server
    /// hands back a stored path under `/uploads/` keeping the `.png` extension.
    func testLiveUploadReturnsUploadsPath() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let urlString = env["HERMES_URL"], let token = env["HERMES_TOKEN"],
              !urlString.isEmpty, !token.isEmpty,
              let url = URL(string: urlString) else {
            throw XCTSkip("HERMES_URL/HERMES_TOKEN not provided; skipping live upload test")
        }

        // Mirror production (ABH-88): pin the path family the gateway serves.
        let probe = RestClient(baseURL: url, token: token)
        let mount = await probe.probePluginMountEndpoint()
        let client = probe.withPathStyle(mount == .available ? .plugin : .legacy)
        let png = Self.makeTinyPNG()
        XCTAssertFalse(png.isEmpty, "Failed to generate test PNG")

        let result = try await client.upload(
            data: png,
            filename: "\(UUID().uuidString).png",
            mimeType: "image/png"
        )

        XCTAssertTrue(
            result.path.hasSuffix(".png"),
            "Upload path should keep the .png extension, got \(result.path)"
        )
        XCTAssertTrue(
            result.path.contains("/uploads/"),
            "Upload path should be served from /uploads/, got \(result.path)"
        )
    }

    /// `GET /api/cron/delivery-targets` keeps snake_case target metadata intact
    /// and exposes both configured and needs-home-channel states to the cron
    /// editor. This is stubbed (not live) so CI pins the decoder without a
    /// configured gateway channel.
    func testCronDeliveryTargetsDecodeHomeTargetState() async throws {
        CronDeliveryTargetsStubProtocol.nextResponse = (
            data: #"{"targets":[{"id":"local","name":"Local (save only)","home_target_set":true,"home_env_var":null},{"id":"telegram","name":"Telegram","home_target_set":true,"home_env_var":"TELEGRAM_HOME_CHAT_ID"},{"id":"discord","name":"Discord","home_target_set":false,"home_env_var":"DISCORD_HOME_CHANNEL_ID"}]}"#.data(using: .utf8)!,
            status: 200
        )
        CronDeliveryTargetsStubProtocol.requestedPath = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CronDeliveryTargetsStubProtocol.self]
        let client = RestClient(
            baseURL: URL(string: "http://127.0.0.1:9119")!,
            token: "test-token",
            session: URLSession(configuration: config)
        )

        let targets = try await client.cronDeliveryTargets()

        XCTAssertEqual(CronDeliveryTargetsStubProtocol.requestedPath, "/api/cron/delivery-targets")
        XCTAssertEqual(targets.map(\.id), ["local", "telegram", "discord"])
        XCTAssertEqual(targets[0].name, "Local (save only)")
        XCTAssertTrue(targets[0].homeTargetSet)
        XCTAssertNil(targets[0].homeEnvVar)
        XCTAssertTrue(targets[1].homeTargetSet)
        XCTAssertEqual(targets[1].homeEnvVar, "TELEGRAM_HOME_CHAT_ID")
        XCTAssertFalse(targets[2].homeTargetSet)
        XCTAssertEqual(targets[2].homeEnvVar, "DISCORD_HOME_CHANNEL_ID")
    }

    // MARK: - Test fixtures

    /// A minimal, valid 1x1 opaque-red PNG, built in-code so the test carries no
    /// asset dependency. Bytes are the canonical smallest single-pixel PNG:
    /// 8-byte signature + IHDR + a single zlib-deflated IDAT scanline + IEND,
    /// each chunk carrying its correct CRC-32.
    private static func makeTinyPNG() -> Data {
        let bytes: [UInt8] = [
            // PNG signature
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            // IHDR chunk: 1x1, 8-bit, color type 2 (truecolor)
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
            0xDE,
            // IDAT chunk: one zlib-deflated scanline (filter 0 + R,G,B)
            0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41, 0x54,
            0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00, 0x00,
            0x03, 0x01, 0x01, 0x00,
            0x18, 0xDD, 0x8D, 0xB0,
            // IEND chunk
            0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44,
            0xAE, 0x42, 0x60, 0x82,
        ]
        return Data(bytes)
    }

    private func transcriptPageStubClient(pathStyle: APIPathStyle) -> RestClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TranscriptPageStubProtocol.self]
        return RestClient(
            baseURL: URL(string: "http://127.0.0.1:9119")!,
            token: "test-token",
            session: URLSession(configuration: config),
            pathStyle: pathStyle
        )
    }
}

private final class TranscriptPageStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var nextResponse: (data: Data, status: Int)?
    nonisolated(unsafe) static var requestedPath: String?
    nonisolated(unsafe) static var requestedQuery: String?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestedPath = request.url?.path
        Self.requestedQuery = request.url?.query
        guard let (data, status) = Self.nextResponse else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class CronDeliveryTargetsStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var nextResponse: (data: Data, status: Int)?
    nonisolated(unsafe) static var requestedPath: String?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestedPath = request.url?.path
        guard let (data, status) = Self.nextResponse else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
