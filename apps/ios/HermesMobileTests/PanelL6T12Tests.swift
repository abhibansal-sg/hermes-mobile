import XCTest
@testable import HermesMobile

/// Level-08 panel write-action tests (L6T12).
///
/// Covers:
///   - Cron CRUD: create, update, delete via mock REST responses
///   - Skills toggle: `PUT /api/skills/toggle` returns confirmed state
///   - GatewayStatus: `needsConfigUpgrade` computed property
///   - UsageDay: `totalTokens` now includes cache-read tokens
///   - SchedulePreset: humanizer + round-trip preset detection
///   - CronJob: `isPaused` semantics with state/enabled combinations
///
/// Uses a URLProtocol stub to intercept URLSession requests without hitting a
/// live server — the same technique used by the system's ephemeral session.
@MainActor
final class PanelL6T12Tests: XCTestCase {

    // MARK: - Helpers

    /// Build a ``RestClient`` whose URLSession routes all requests through
    /// ``StubProtocol``, which replies with the JSON string you supply.
    private func stubClient(returning json: String, status: Int = 200) -> RestClient {
        StubProtocol.nextResponse = (json.data(using: .utf8) ?? Data(), status)
        StubProtocol.lastRequest = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return RestClient(
            baseURL: URL(string: "http://127.0.0.1:9119")!,
            token: "test-token",
            session: URLSession(configuration: config)
        )
    }

    // MARK: - Cron create

    func testCreateCronJobDecodesName() async throws {
        let client = stubClient(returning: """
        {"id":"job-1","name":"Daily brief","prompt":"Summarise news","state":"scheduled",
         "enabled":true,"schedule_display":"Every day at 9:00 AM"}
        """)
        let job = try await client.createCronJob(
            name: "Daily brief",
            prompt: "Summarise news",
            schedule: "0 9 * * *",
            deliver: "local"
        )
        XCTAssertEqual(job.id, "job-1")
        XCTAssertEqual(job.name, "Daily brief")
        XCTAssertFalse(job.isPaused)
    }

    func testCreateCronJobWithoutNameUsesDefaultTitle() async throws {
        let client = stubClient(returning: """
        {"id":"job-2","name":"Untitled job","prompt":"Do stuff",
         "state":"scheduled","enabled":true}
        """)
        let job = try await client.createCronJob(
            name: nil,
            prompt: "Do stuff",
            schedule: "*/15 * * * *",
            deliver: nil
        )
        XCTAssertEqual(job.name, "Untitled job")
    }

    // MARK: - Cron update

    func testUpdateCronJobReflectsNewPrompt() async throws {
        let client = stubClient(returning: """
        {"id":"job-3","name":"Weekly review","prompt":"Updated prompt",
         "state":"scheduled","enabled":true}
        """)
        let job = try await client.updateCronJob(
            id: "job-3",
            name: "Weekly review",
            prompt: "Updated prompt",
            schedule: "0 9 * * 1",
            deliver: "telegram"
        )
        XCTAssertEqual(job.prompt, "Updated prompt")
    }

    // MARK: - Cron delete

    func testDeleteCronJobDoesNotThrowOn200() async throws {
        let client = stubClient(returning: #"{"ok":true}"#)
        // Should not throw
        try await client.deleteCronJob(id: "job-4")
    }

    func testDeleteCronJobThrowsOnBadStatus() async throws {
        let client = stubClient(returning: #"{"error":"Not found"}"#, status: 404)
        do {
            try await client.deleteCronJob(id: "missing")
            XCTFail("Expected RestError.badStatus but no error was thrown")
        } catch RestError.badStatus(let code, _) {
            XCTAssertEqual(code, 404)
        }
    }

    // MARK: - Cron pause / resume / trigger

    func testPauseCronJobReturnsPausedState() async throws {
        let client = stubClient(returning: """
        {"id":"job-5","name":"Hourly check","state":"paused","enabled":false}
        """)
        let job = try await client.pauseCronJob(id: "job-5")
        XCTAssertTrue(job.isPaused, "Paused job should have isPaused == true")
    }

    func testResumeCronJobReturnsScheduledState() async throws {
        let client = stubClient(returning: """
        {"id":"job-5","name":"Hourly check","state":"scheduled","enabled":true}
        """)
        let job = try await client.resumeCronJob(id: "job-5")
        XCTAssertFalse(job.isPaused, "Resumed job should have isPaused == false")
    }

    func testCronJobOutputsEndpointPathQueryAndMarkdownDecode() async throws {
        let client = stubClient(returning: """
        {
          "job_id": "job-1",
          "profile": "work",
          "outputs": [
            {
              "id": "out-1",
              "filename": "2026-07-06.md",
              "run_at": "2026-07-06T09:00:00Z",
              "created_at": "2026-07-06T09:00:03Z",
              "size": 42,
              "preview": "# Daily brief"
            }
          ],
          "latest": {
            "id": "out-1",
            "filename": "2026-07-06.md",
            "run_at": "2026-07-06T09:00:00Z",
            "created_at": "2026-07-06T09:00:03Z",
            "size": 42,
            "preview": "# Daily brief",
            "body": "# Daily brief\\n\\n- shipped **cron output**"
          },
          "limit": 20
        }
        """)

        let response = try await client.cronJobOutputs(
            jobId: "job-1",
            profile: "work",
            limit: 20,
            includeLatestBody: true
        )

        let request = try XCTUnwrap(StubProtocol.lastRequest)
        XCTAssertEqual(request.url?.path, "/api/cron/jobs/job-1/outputs")
        let queryItems = Dictionary(
            uniqueKeysWithValues: URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
                .queryItems?
                .compactMap { item -> (String, String)? in
                    guard let value = item.value else { return nil }
                    return (item.name, value)
                } ?? []
        )
        XCTAssertEqual(queryItems["profile"], "work")
        XCTAssertEqual(queryItems["limit"], "20")
        XCTAssertEqual(queryItems["include_latest_body"], "true")
        XCTAssertEqual(response.jobId, "job-1")
        XCTAssertEqual(response.profile, "work")
        XCTAssertEqual(response.outputs.first?.filename, "2026-07-06.md")
        XCTAssertEqual(response.outputs.first?.preview, "# Daily brief")
        XCTAssertEqual(response.latest?.body, "# Daily brief\n\n- shipped **cron output**")
    }

    // MARK: - Skill toggle

    func testToggleSkillReturnsConfirmedState() async throws {
        let client = stubClient(returning: #"{"ok":true,"name":"code-review","enabled":false}"#)
        let enabled = try await client.toggleSkill(name: "code-review", enabled: false)
        XCTAssertFalse(enabled)
    }

    func testToggleSkillFallsBackToRequestedValueWhenKeyMissing() async throws {
        let client = stubClient(returning: #"{"ok":true}"#)
        let enabled = try await client.toggleSkill(name: "qa", enabled: true)
        XCTAssertTrue(enabled, "Falls back to the requested value when response omits 'enabled'")
    }

    // MARK: - GatewayStatus config version

    func testNeedsConfigUpgradeTrueWhenCurrentLtLatest() {
        let json: JSONValue = .object([
            "config_version": 1,
            "latest_config_version": 3,
        ])
        let status = GatewayStatus(json: json)
        XCTAssertTrue(status.needsConfigUpgrade)
        XCTAssertEqual(status.configVersion, 1)
        XCTAssertEqual(status.latestConfigVersion, 3)
    }

    func testNeedsConfigUpgradeFalseWhenCurrent() {
        let json: JSONValue = .object([
            "config_version": 3,
            "latest_config_version": 3,
        ])
        let status = GatewayStatus(json: json)
        XCTAssertFalse(status.needsConfigUpgrade)
    }

    func testNeedsConfigUpgradeFalseWhenFieldsMissing() {
        let status = GatewayStatus(json: .object([:]))
        XCTAssertFalse(status.needsConfigUpgrade)
    }

    // MARK: - Build 120 reliability diagnostics

    func testReliabilityDiagnosticsIsBoundedAndKeepsNewestEvents() {
        let diagnostics = ReliabilityDiagnostics()
        for index in 0...ReliabilityDiagnostics.capacity {
            diagnostics.reconnectAttempt(number: index)
        }

        XCTAssertEqual(diagnostics.events.count, ReliabilityDiagnostics.capacity)
        XCTAssertEqual(diagnostics.events.first?.sequence, 1)
        XCTAssertEqual(diagnostics.events.last?.sequence, UInt64(ReliabilityDiagnostics.capacity))
    }

    func testReliabilityDiagnosticsRedactsIdentifiersAndUsesTypedKinds() throws {
        let diagnostics = ReliabilityDiagnostics()
        let secret = "session-token-prompt-title-body"
        diagnostics.sessionSelected(identifier: secret)
        diagnostics.cachePaintFinished(rowCount: 3, duration: .milliseconds(12))

        XCTAssertFalse(diagnostics.redactedJSON.contains(secret))
        XCTAssertTrue(diagnostics.redactedJSON.contains("session_select"))
        XCTAssertTrue(diagnostics.redactedJSON.contains("idHash"))
        XCTAssertTrue(diagnostics.redactedJSON.contains("durationMilliseconds"))
        XCTAssertEqual(diagnostics.events.first?.kind, .sessionSelect)
    }

    func testReliabilityDiagnosticsCoversLockedEventFamilies() {
        let diagnostics = ReliabilityDiagnostics()
        diagnostics.websocketConnect(epoch: 1)
        diagnostics.websocketReady(epoch: 1)
        diagnostics.websocketClose(epoch: 1)
        diagnostics.reconnectAttempt(number: 1)
        diagnostics.reconnectHeal(epoch: 2)
        diagnostics.graceStarted(duration: .seconds(1))
        diagnostics.graceExpired(attempt: 2)
        diagnostics.epochRejected(expected: 1, received: 2)
        diagnostics.sessionSelected(identifier: "a")
        diagnostics.sessionBound(identifier: "a", epoch: 2)
        diagnostics.sessionSuperseded(identifier: "a")
        diagnostics.cachePaintStarted(identifier: "a")
        diagnostics.cachePaintFinished(rowCount: 2, duration: .milliseconds(1))
        diagnostics.cachePaintFailed(rowCount: 0, duration: .milliseconds(1))
        diagnostics.outboxWait()
        diagnostics.outboxClaim(identifier: "job")
        diagnostics.outboxSubmit(identifier: "job")
        diagnostics.outboxAmbiguous(identifier: "job")
        diagnostics.backgroundFlushStarted()
        diagnostics.foregroundLiveness(alive: true)

        XCTAssertEqual(
            Set(diagnostics.events.map(\.kind)),
            Set(ReliabilityDiagnostics.Kind.allCases)
        )
    }

    func testGatewayStatusSeparatesPhoneReadinessFromGatewayProcess() {
        let ready = GatewayStatusView.phoneBadgeState(for: .ready(epoch: 3))
        let unavailable = GatewayStatusView.phoneBadgeState(for: .unavailable(epoch: 3))

        XCTAssertEqual(ready, GatewayBadgeSnapshot(state: "ready", running: true))
        XCTAssertEqual(unavailable, GatewayBadgeSnapshot(state: "offline", running: false))
    }

    // MARK: - UsageDay totalTokens (cache-read included)

    func testUsageDayTotalTokensIncludesCacheRead() {
        // Simulate a day with heavy cache reuse: 100 input, 50 output, 800 cache-read.
        // Old formula: 100+50=150. New formula: 100+50+800=950.
        let json = makeUsageDayJSON(input: 100, output: 50, cacheRead: 800)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let day = try! decoder.decode(UsageDay.self, from: json)
        XCTAssertEqual(day.totalTokens, 950,
                       "totalTokens must include cache-read tokens (100+50+800=950)")
    }

    func testUsageDayTotalTokensWithNilCacheReadEqualsInputPlusOutput() {
        let json = makeUsageDayJSON(input: 200, output: 100, cacheRead: nil)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let day = try! decoder.decode(UsageDay.self, from: json)
        XCTAssertEqual(day.totalTokens, 300)
    }

    private func makeUsageDayJSON(input: Int, output: Int, cacheRead: Int?) -> Data {
        var dict = """
        {"day":"2026-06-07","input_tokens":\(input),"output_tokens":\(output)
        """
        if let cr = cacheRead { dict += ",\"cache_read_tokens\":\(cr)" }
        dict += "}"
        return dict.data(using: .utf8)!
    }

    // MARK: - CronJob isPaused semantics

    func testCronJobIsPausedWhenStateIsPaused() {
        let job = CronJob(json: .object(["id": "x", "name": "x", "state": "paused", "enabled": true]))
        XCTAssertTrue(job.isPaused)
    }

    func testCronJobIsPausedWhenEnabledFalse() {
        let job = CronJob(json: .object(["id": "x", "name": "x", "state": "scheduled", "enabled": false]))
        XCTAssertTrue(job.isPaused)
    }

    func testCronJobIsNotPausedWhenScheduledAndEnabled() {
        let job = CronJob(json: .object(["id": "x", "name": "x", "state": "scheduled", "enabled": true]))
        XCTAssertFalse(job.isPaused)
    }

    // MARK: - CronJob lastError decoded

    func testCronJobDecodeLastError() {
        let json: JSONValue = .object([
            "id": "err-job",
            "name": "Failing job",
            "last_error": "Timeout after 30s",
            "state": "scheduled",
            "enabled": true,
        ])
        let job = CronJob(json: json)
        XCTAssertEqual(job.lastError, "Timeout after 30s")
    }
}

// MARK: - URLProtocol stub

/// Intercepts URLSession requests and returns a pre-configured response.
/// Registered on a per-test ephemeral configuration so tests are isolated.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    /// The response to serve for the next request. Set before creating the client.
    /// Nonisolated mutable state is acceptable in tests (single-threaded XCTest
    /// execution, no concurrent access across test cases).
    nonisolated(unsafe) static var nextResponse: (Data, Int) = (Data(), 200)
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        let (body, status) = Self.nextResponse
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
