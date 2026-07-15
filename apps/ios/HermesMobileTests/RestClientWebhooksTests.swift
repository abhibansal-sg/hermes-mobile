import XCTest
@testable import HermesMobile

/// STR-338 — webhook subscription management REST client tests.
///
/// Pins the five ``RestClient`` webhook methods against the stock gateway
/// contract (`hermes_cli/web_server.py`):
///   1. every call site hangs off ABSOLUTE `/api/webhooks…` with the right HTTP
///      method — and, crucially, is INDEPENDENT of the client's ``APIPathStyle``
///      (these are stock routes, not the plugin mount, so `.plugin` must NOT
///      rewrite them under `/api/plugins/hermes-mobile`),
///   2. the wire shapes decode into ``WebhookRoute`` / ``WebhooksListResult`` /
///      ``WebhookEnableResult`` with the server's defaults (absent `enabled` →
///      `true`, absent `deliver` → `"log"`, redacted `secret_set`),
///   3. `createWebhook` carries the fields in the POST body and surfaces the
///      one-time `secret` sibling field, and
///   4. a non-2xx (the FastAPI `{"detail":…}` reject) surfaces as
///      ``RestError/badStatus`` for the caller's inline error.
///
/// Gateway-free: uses a `URLProtocol` stub transport (the same pattern
/// ``ProviderKeyRestTests`` uses) — no `HERMES_URL`/`HERMES_TOKEN` required.
final class RestClientWebhooksTests: XCTestCase {

    // MARK: - Recording stub transport

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

    private func makeClient(style: APIPathStyle = .legacy, script: [(Data, Int)]) -> RestClient {
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

    private var recordedMethods: [String] {
        RecordingProtocol.requests.compactMap { $0.httpMethod }
    }

    // MARK: - 1. Path + method per call site, independent of path family

    func testEveryCallSiteHitsStockRouteWithCorrectMethod() async throws {
        let listBody = Data(#"{"enabled":true,"base_url":"https://gw.example","subscriptions":[]}"#.utf8)
        let enableBody = Data(#"{"ok":true,"enabled":true,"needs_restart":false,"restart_started":true}"#.utf8)
        let createBody = Data(#"{"name":"gh","url":"https://gw.example/webhooks/gh","secret":"s3cr3t","enabled":true}"#.utf8)
        let deleteBody = Data(#"{"ok":true}"#.utf8)
        let toggleBody = Data(#"{"ok":true,"name":"gh","enabled":false}"#.utf8)

        // Assert BOTH families resolve to the SAME absolute /api/webhooks paths —
        // the stock-route posture (never rewritten under the plugin mount).
        for style in [APIPathStyle.legacy, .plugin] {
            var client = makeClient(style: style, script: [(listBody, 200)])
            _ = try await client.listWebhooks()
            XCTAssertEqual(recordedPaths, ["/api/webhooks"])
            XCTAssertEqual(recordedMethods, ["GET"])

            client = makeClient(style: style, script: [(enableBody, 200)])
            _ = try await client.enableWebhooks()
            XCTAssertEqual(recordedPaths, ["/api/webhooks/enable"])
            XCTAssertEqual(recordedMethods, ["POST"])

            client = makeClient(style: style, script: [(createBody, 200)])
            _ = try await client.createWebhook(name: "gh")
            XCTAssertEqual(recordedPaths, ["/api/webhooks"])
            XCTAssertEqual(recordedMethods, ["POST"])

            client = makeClient(style: style, script: [(deleteBody, 200)])
            _ = try await client.deleteWebhook(name: "gh")
            XCTAssertEqual(recordedPaths, ["/api/webhooks/gh"])
            XCTAssertEqual(recordedMethods, ["DELETE"])

            client = makeClient(style: style, script: [(toggleBody, 200)])
            _ = try await client.setWebhookEnabled(name: "gh", enabled: false)
            XCTAssertEqual(recordedPaths, ["/api/webhooks/gh/enabled"])
            XCTAssertEqual(recordedMethods, ["PUT"])
        }
    }

    // MARK: - 2. Wire-shape decoding + server defaults

    func testListDecodesReceiverStateAndSubscriptions() async throws {
        let body = Data(#"""
        {
          "enabled": true,
          "base_url": "https://gw.example",
          "subscriptions": [
            {"name":"github-push","description":"CI trigger","events":["push","pull_request"],
             "deliver":"telegram","deliver_only":true,"prompt":"do the thing","skills":["deploy"],
             "created_at":"2026-07-09T00:00:00Z","url":"https://gw.example/webhooks/github-push",
             "secret_set":true,"enabled":false},
            {"name":"bare","url":"https://gw.example/webhooks/bare"}
          ]
        }
        """#.utf8)
        let client = makeClient(script: [(body, 200)])
        let result = try await client.listWebhooks()

        XCTAssertTrue(result.enabled)
        XCTAssertEqual(result.baseURL, "https://gw.example")
        XCTAssertEqual(result.subscriptions.count, 2)

        let first = result.subscriptions[0]
        XCTAssertEqual(first.name, "github-push")
        XCTAssertEqual(first.events, ["push", "pull_request"])
        XCTAssertEqual(first.deliver, "telegram")
        XCTAssertTrue(first.deliverOnly)
        XCTAssertEqual(first.skills, ["deploy"])
        XCTAssertTrue(first.secretSet)
        XCTAssertFalse(first.enabled, "explicit enabled:false must be honored")

        // The bare row exercises the server-side defaults: absent `enabled`
        // decodes to true, absent `deliver` to "log", absent `secret_set` to false.
        let bare = result.subscriptions[1]
        XCTAssertEqual(bare.name, "bare")
        XCTAssertTrue(bare.enabled, "absent enabled must default to true")
        XCTAssertEqual(bare.deliver, "log", "absent deliver must default to log")
        XCTAssertFalse(bare.secretSet)
        XCTAssertTrue(bare.events.isEmpty)
    }

    func testListDecodesDisabledReceiverWithNoSubscriptions() async throws {
        let body = Data(#"{"enabled":false,"base_url":"","subscriptions":[]}"#.utf8)
        let client = makeClient(script: [(body, 200)])
        let result = try await client.listWebhooks()
        XCTAssertFalse(result.enabled)
        XCTAssertTrue(result.subscriptions.isEmpty)
    }

    func testEnableDecodesRestartOutcome() async throws {
        // restart_started:false → the caller shows a "restart manually" note.
        let body = Data(#"{"ok":true,"enabled":true,"needs_restart":true,"restart_started":false,"restart_error":"boom"}"#.utf8)
        let client = makeClient(script: [(body, 200)])
        let result = try await client.enableWebhooks()
        XCTAssertTrue(result.ok)
        XCTAssertTrue(result.enabled)
        XCTAssertTrue(result.needsRestart)
        XCTAssertEqual(result.restartStarted, false)
        XCTAssertEqual(result.restartError, "boom")
    }

    // MARK: - 3. Create carries body fields + surfaces the one-time secret

    func testCreateSendsBodyFieldsAndReturnsSecret() async throws {
        let body = Data(#"""
        {"name":"github-push","description":"CI","events":["push"],"deliver":"log",
         "deliver_only":false,"prompt":"","skills":[],"created_at":"2026-07-09T00:00:00Z",
         "url":"https://gw.example/webhooks/github-push","secret_set":true,"enabled":true,
         "secret":"one-time-abc123"}
        """#.utf8)
        let client = makeClient(script: [(body, 200)])

        let (route, secret) = try await client.createWebhook(
            name: "github-push",
            description: "CI",
            events: ["push"],
            prompt: "",
            skills: [],
            deliver: "log",
            deliverOnly: false
        )

        XCTAssertEqual(route.name, "github-push")
        XCTAssertEqual(route.url, "https://gw.example/webhooks/github-push")
        XCTAssertEqual(secret, "one-time-abc123", "the one-time secret rides the create response only")

        // The fields ride the JSON body, and the secret was never in the URL.
        let request = try XCTUnwrap(RecordingProtocol.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Hermes-Session-Token"), "tok")
        let object = try XCTUnwrap(jsonBody(for: request))
        XCTAssertEqual(object["name"] as? String, "github-push")
        XCTAssertEqual(object["description"] as? String, "CI")
        XCTAssertEqual(object["events"] as? [String], ["push"])
        XCTAssertEqual(object["deliver"] as? String, "log")
        XCTAssertEqual(object["deliver_only"] as? Bool, false)
    }

    func testCreateOmitsEmptyOptionalFields() async throws {
        let body = Data(#"{"name":"n","url":"https://gw.example/webhooks/n","secret":"s","enabled":true}"#.utf8)
        let client = makeClient(script: [(body, 200)])
        _ = try await client.createWebhook(name: "n")

        let request = try XCTUnwrap(RecordingProtocol.requests.first)
        let object = try XCTUnwrap(jsonBody(for: request))
        // Required fields always present; empty optionals are not sent.
        XCTAssertEqual(object["name"] as? String, "n")
        XCTAssertNotNil(object["deliver"])
        XCTAssertNotNil(object["deliver_only"])
        XCTAssertNil(object["description"], "empty description must be omitted")
        XCTAssertNil(object["events"], "empty events must be omitted")
        XCTAssertNil(object["prompt"], "empty prompt must be omitted")
        XCTAssertNil(object["skills"], "empty skills must be omitted")
    }

    // MARK: - 4. Non-2xx surfaces as badStatus (FastAPI {"detail":…} reject)

    func testCreateRejectSurfacesAsBadStatus() async {
        // e.g. deliver_only with deliver=="log", or an invalid name, or the
        // platform-not-enabled 400 — all arrive as a 400 with a `detail` body.
        let body = Data(#"{"detail":"Direct delivery requires a real target (telegram, discord, …), not 'log'."}"#.utf8)
        let client = makeClient(script: [(body, 400)])
        do {
            _ = try await client.createWebhook(name: "x", deliver: "log", deliverOnly: true)
            XCTFail("expected badStatus")
        } catch RestError.badStatus(let code, let errorBody) {
            XCTAssertEqual(code, 400)
            XCTAssertTrue(errorBody.contains("Direct delivery requires"))
        } catch {
            XCTFail("expected RestError.badStatus, got \(error)")
        }
    }

    func testDeleteUnknownSurfacesAsBadStatus() async {
        let body = Data(#"{"detail":"No subscription named 'ghost'"}"#.utf8)
        let client = makeClient(script: [(body, 404)])
        do {
            _ = try await client.deleteWebhook(name: "ghost")
            XCTFail("expected badStatus")
        } catch RestError.badStatus(let code, _) {
            XCTAssertEqual(code, 404)
        } catch {
            XCTFail("expected RestError.badStatus, got \(error)")
        }
    }

    // MARK: - 5. Toggle body + confirmed return

    func testSetEnabledPutsFlagInBodyAndReturnsConfirmedValue() async throws {
        let body = Data(#"{"ok":true,"name":"gh","enabled":false}"#.utf8)
        let client = makeClient(script: [(body, 200)])
        let confirmed = try await client.setWebhookEnabled(name: "gh", enabled: false)
        XCTAssertFalse(confirmed)

        let request = try XCTUnwrap(RecordingProtocol.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let object = try XCTUnwrap(jsonBody(for: request))
        XCTAssertEqual(object["enabled"] as? Bool, false)
    }

    func testNameIsPercentEncodedInPath() async throws {
        let body = Data(#"{"ok":true}"#.utf8)
        let client = makeClient(script: [(body, 200)])
        _ = try await client.deleteWebhook(name: "a b")
        // The space must be percent-encoded, not sent raw.
        let raw = try XCTUnwrap(RecordingProtocol.requests.first?.url?.absoluteString)
        XCTAssertTrue(raw.contains("/api/webhooks/a%20b"), "name must be percent-encoded: \(raw)")
    }

    // MARK: - 6. WebhookRoute value semantics

    func testWebhookRouteDecodeDefaults() {
        let route = WebhookRoute(json: try! JSONDecoder().decode(
            JSONValue.self, from: Data(#"{"name":"only-name"}"#.utf8)
        ))
        XCTAssertEqual(route.name, "only-name")
        XCTAssertEqual(route.deliver, "log")
        XCTAssertFalse(route.deliverOnly)
        XCTAssertTrue(route.enabled)
        XCTAssertFalse(route.secretSet)
        XCTAssertTrue(route.events.isEmpty)
        XCTAssertNil(route.script)
    }

    func testWebhookRouteCopyFlipsEnabledAndPreservesRest() {
        let original = WebhookRoute(
            name: "n", description: "d", events: ["e"], deliver: "telegram",
            deliverOnly: true, prompt: "p", script: "s", skills: ["k"],
            createdAt: "t", url: "u", secretSet: true, enabled: true
        )
        let flipped = original.copy(enabled: false)
        XCTAssertFalse(flipped.enabled)
        XCTAssertEqual(flipped.name, "n")
        XCTAssertEqual(flipped.deliver, "telegram")
        XCTAssertTrue(flipped.deliverOnly)
        XCTAssertEqual(flipped.events, ["e"])
        XCTAssertEqual(flipped.skills, ["k"])
        XCTAssertEqual(flipped.script, "s")
        XCTAssertTrue(flipped.secretSet)
    }

    // MARK: - Helpers

    private func jsonBody(for request: URLRequest) throws -> [String: Any]? {
        let data = try bodyData(for: request)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func bodyData(for request: URLRequest) throws -> Data {
        if let body = request.httpBody, !body.isEmpty { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var drained = Data()
        let bufferSize = 1_024
        while stream.hasBytesAvailable {
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read > 0 { drained.append(buffer, count: read) } else { break }
        }
        return drained
    }
}
