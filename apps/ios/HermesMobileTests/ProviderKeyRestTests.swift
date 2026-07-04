import XCTest
@testable import HermesMobile

/// ABH-183 — provider / API-key-entry REST client tests.
///
/// Pins the four ``RestClient`` provider/key-entry methods against the plugin
/// contract:
///   1. every call site builds the right URL under BOTH path families and the
///      right HTTP method (GET list / POST key / POST custom / DELETE),
///   2. the probe classifies available / unavailable / inconclusive,
///   3. the wire shapes decode into ``ProviderRow`` / ``ProviderDisconnectResult``
///      (incl. the `{id}`-object model list the key/custom responses carry),
///   4. the api_key rides the POST BODY (never the URL), and
///   5. a non-2xx surfaces as ``RestError/badStatus`` (the 4003 OAuth / 4006
///      managed rejects the caller maps to inline UI).
///
/// Gateway-free: uses a `URLProtocol` stub transport (the same pattern
/// `PathStyleTests` / `ArtifactsGalleryTests` use) — no `HERMES_URL` /
/// `HERMES_TOKEN` required (skip-guard friendly). The plugin's own Python tests
/// (`tests/plugins/hermes_mobile/test_provider_key_endpoints.py`) cover the
/// route-handler dispatch + security contract server-side.
final class ProviderKeyRestTests: XCTestCase {

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

    private var recordedMethods: [String] {
        RecordingProtocol.requests.compactMap { $0.httpMethod }
    }

    // MARK: - 1. Path family + method per call site

    func testPathFamilyAndMethodPerCallSite() async throws {
        let listBody = Data(#"{"providers":[]}"#.utf8)
        let providerBody = Data(#"{"provider":{"slug":"deepseek","name":"DeepSeek","auth_type":"api_key","is_current":false,"authenticated":true,"total_models":2,"models":[{"id":"deepseek-chat"}]}}"#.utf8)
        let disconnectBody = Data(#"{"slug":"deepseek","name":"DeepSeek","disconnected":true}"#.utf8)

        for style in [APIPathStyle.legacy, .plugin] {
            let prefix = style.mobileAPIPrefix

            var client = makeClient(style: style, script: [(listBody, 200)])
            _ = try await client.listProviders()
            XCTAssertEqual(recordedPaths, ["\(prefix)/providers"])
            XCTAssertEqual(recordedMethods, ["GET"])

            client = makeClient(style: style, script: [(providerBody, 200)])
            _ = try await client.setProviderKey(slug: "deepseek", apiKey: "sk-123")
            XCTAssertEqual(recordedPaths, ["\(prefix)/providers/deepseek/key"])
            XCTAssertEqual(recordedMethods, ["POST"])

            client = makeClient(style: style, script: [(providerBody, 200)])
            _ = try await client.addCustomProvider(
                name: "my-proxy", baseURL: "https://x.example", apiMode: .openai, apiKey: "sk-1"
            )
            XCTAssertEqual(recordedPaths, ["\(prefix)/providers/custom"])
            XCTAssertEqual(recordedMethods, ["POST"])

            client = makeClient(style: style, script: [(disconnectBody, 200)])
            _ = try await client.removeProviderKey(slug: "deepseek")
            XCTAssertEqual(recordedPaths, ["\(prefix)/providers/deepseek/key"])
            XCTAssertEqual(recordedMethods, ["DELETE"])
        }
    }

    // MARK: - 2. Probe classification

    func testProbeClassifiesAvailableUnavailableInconclusive() async {
        let body = Data(#"{"providers":[{"slug":"x"}]}"#.utf8)
        // available
        var client = makeClient(style: .plugin, script: [(body, 200)])
        var result = await client.probeProvidersEndpoint()
        XCTAssertEqual(result, .available)
        XCTAssertEqual(recordedPaths, ["/api/plugins/hermes-mobile/providers"])

        // unavailable (404)
        client = makeClient(style: .plugin, script: [(Data(), 404)])
        result = await client.probeProvidersEndpoint()
        XCTAssertEqual(result, .unavailable)

        // inconclusive: a 200 lacking the `providers` array
        client = makeClient(style: .plugin, script: [(Data(#"{"other":1}"#.utf8), 200)])
        result = await client.probeProvidersEndpoint()
        XCTAssertEqual(result, .inconclusive)

        // inconclusive: a 500 (or any non-200/404/405 status) falls through to
        // the probe's `default` branch. A genuine transport error (URLSession
        // throwing) is caught by the `catch` and also yields `.inconclusive`.
        client = makeClient(style: .plugin, script: [(Data(), 500)])
        result = await client.probeProvidersEndpoint()
        XCTAssertEqual(result, .inconclusive)
    }

    // MARK: - 3. Wire-shape decoding

    func testListProvidersDecodesProviderUniverse() async throws {
        let body = Data(#"""
        {"providers":[
            {"slug":"deepseek","name":"DeepSeek","auth_type":"api_key","is_current":false,"authenticated":false,"total_models":3},
            {"slug":"nous","name":"Nous Portal","auth_type":"oauth_device_code","is_current":true,"authenticated":false,"total_models":0}
        ]}
        """#.utf8)
        let client = makeClient(style: .plugin, script: [(body, 200)])
        let providers = try await client.listProviders()
        XCTAssertEqual(providers.count, 2)
        XCTAssertEqual(providers[0].slug, "deepseek")
        XCTAssertEqual(providers[0].authType, .apiKey)
        XCTAssertFalse(providers[0].authenticated)
        XCTAssertEqual(providers[1].slug, "nous")
        XCTAssertEqual(providers[1].authType, .oauthDeviceCode)
        XCTAssertFalse(providers[1].provisionableFromKey)  // OAuth → not mobile-provisionable
        XCTAssertTrue(providers[0].provisionableFromKey)
    }

    func testSetProviderKeyDecodesRefreshedRowWithModels() async throws {
        let body = Data(#"""
        {"provider":{"slug":"deepseek","name":"DeepSeek","auth_type":"api_key","is_current":false,"authenticated":true,"total_models":2,"models":[{"id":"deepseek-chat"},{"id":"deepseek-reasoner"}]}}
        """#.utf8)
        let client = makeClient(style: .plugin, script: [(body, 200)])
        let result = try await client.setProviderKey(slug: "deepseek", apiKey: "sk-123")
        XCTAssertEqual(result.row.slug, "deepseek")
        XCTAssertTrue(result.row.authenticated)
        XCTAssertEqual(result.row.models, ["deepseek-chat", "deepseek-reasoner"])
    }

    func testRemoveProviderKeyDecodesDisconnectResult() async throws {
        let body = Data(#"{"slug":"deepseek","name":"DeepSeek","disconnected":true}"#.utf8)
        let client = makeClient(style: .plugin, script: [(body, 200)])
        let result = try await client.removeProviderKey(slug: "deepseek")
        XCTAssertEqual(result.slug, "deepseek")
        XCTAssertEqual(result.name, "DeepSeek")
        XCTAssertTrue(result.disconnected)
    }

    // MARK: - 4. The api_key rides the POST body, never the URL

    func testApiKeyRidesBodyNotURL() async throws {
        let providerBody = Data(#"{"provider":{"slug":"deepseek","name":"DeepSeek","authenticated":true}}"#.utf8)
        let client = makeClient(style: .plugin, script: [(providerBody, 200)])
        _ = try await client.setProviderKey(slug: "deepseek", apiKey: "sk-secret")

        guard let request = RecordingProtocol.requests.first else {
            return XCTFail("no request recorded")
        }
        // The secret must NOT appear in the URL path or query.
        let urlString = request.url?.absoluteString ?? ""
        XCTAssertFalse(urlString.contains("sk-secret"), "api_key leaked into URL: \(urlString)")
        // It must appear in the body. URLSession may move `httpBody` into
        // `httpBodyStream` for an outgoing request, so drain the stream as a
        // fallback — the security property (key rides the BODY, never the URL)
        // holds either way.
        var bodyData = request.httpBody ?? Data()
        if bodyData.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var drained = Data()
            let bufferSize = 1_024
            while stream.hasBytesAvailable {
                var buffer = [UInt8](repeating: 0, count: bufferSize)
                let read = stream.read(&buffer, maxLength: bufferSize)
                if read > 0 { drained.append(buffer, count: read) } else { break }
            }
            stream.close()
            bodyData = drained
        }
        let bodyString = String(data: bodyData, encoding: .utf8) ?? ""
        XCTAssertTrue(bodyString.contains("sk-secret"), "api_key missing from body: \(bodyString)")
        // The auth header is the session token (carried by makeRequest).
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Hermes-Session-Token"), "tok")
    }

    // MARK: - 5. Non-2xx surfaces as badStatus (the 4003/4006 reject path)

    func testOAuthRejectSurfacesAsBadStatus() async {
        // The plugin's 4003 "set up on desktop" reject for an OAuth-only provider
        // arrives as a 400 with the error body — must surface as RestError.badStatus.
        let body = Data(#"{"error":"Nous Portal uses oauth_device_code auth — set it up on the desktop","code":4003}"#.utf8)
        let client = makeClient(style: .plugin, script: [(body, 400)])
        do {
            _ = try await client.setProviderKey(slug: "nous", apiKey: "sk-x")
            XCTFail("expected badStatus")
        } catch RestError.badStatus(let code, let errorBody) {
            XCTAssertEqual(code, 400)
            XCTAssertTrue(errorBody.contains("4003"))
        } catch {
            XCTFail("expected RestError.badStatus, got \(error)")
        }
    }

    func testManagedRejectSurfacesAsBadStatus() async {
        let body = Data(#"{"error":"managed install — credentials are read-only","code":4006}"#.utf8)
        let client = makeClient(style: .plugin, script: [(body, 400)])
        do {
            _ = try await client.addCustomProvider(
                name: "x", baseURL: "https://x.example", apiMode: .openai, apiKey: "k"
            )
            XCTFail("expected badStatus")
        } catch RestError.badStatus(let code, let errorBody) {
            XCTAssertEqual(code, 400)
            XCTAssertTrue(errorBody.contains("4006"))
        } catch {
            XCTFail("expected RestError.badStatus, got \(error)")
        }
    }
}

/// ABH-262 — non-model toolset credential REST client tests.
///
/// Pins the mobile toolset-key surface to the plugin contract: GET/PUT paths stay
/// under the shared RestClient path family, PUT carries the key/value in the JSON
/// body (including the empty-string clear path), and redacted responses decode
/// only `is_set` booleans — never stored secret values.
final class ToolsetCredentialRestTests: XCTestCase {

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

    private var recordedMethods: [String] {
        RecordingProtocol.requests.compactMap { $0.httpMethod }
    }

    func testGetToolsetConfigUsesPathFamilyAndDecodesRedactedStatusOnly() async throws {
        let body = Data(#"""
        {
          "name":"web",
          "has_category":true,
          "active_provider":"tavily",
          "providers":[{
            "name":"Tavily",
            "badge":"recommended",
            "tag":"tavily",
            "requires_nous_auth":false,
            "is_active":true,
            "post_setup":"Restart the gateway after saving.",
            "env_vars":[{
              "key":"TAVILY_API_KEY",
              "prompt":"Tavily API Key",
              "url":"https://app.tavily.com",
              "default":"",
              "is_set":true,
              "value":"redacted-payload-sentinel"
            }]
          }]
        }
        """#.utf8)

        for style in [APIPathStyle.legacy, .plugin] {
            let prefix = style.mobileAPIPrefix
            let client = makeClient(style: style, script: [(body, 200)])

            let config = try await client.getToolsetConfig(name: "web")

            XCTAssertEqual(recordedPaths, ["\(prefix)/toolsets/web/config"])
            XCTAssertEqual(recordedMethods, ["GET"])
            XCTAssertEqual(config.name, "web")
            XCTAssertEqual(config.displayName, "Web Search")
            XCTAssertTrue(config.hasCategory)
            XCTAssertEqual(config.activeProvider, "tavily")
            XCTAssertEqual(config.providers.count, 1)
            XCTAssertTrue(config.providers[0].isActive)
            XCTAssertEqual(config.providers[0].postSetup, "Restart the gateway after saving.")

            let envVar = try XCTUnwrap(config.providers.first?.envVars.first)
            XCTAssertEqual(envVar.key, "TAVILY_API_KEY")
            XCTAssertEqual(envVar.prompt, "Tavily API Key")
            XCTAssertEqual(envVar.url, "https://app.tavily.com")
            XCTAssertTrue(envVar.isSet, "redacted responses must drive status from is_set")
            let decodedFieldLabels = Set(Mirror(reflecting: envVar).children.compactMap(\.label))
            XCTAssertFalse(decodedFieldLabels.contains("value"), "ToolsetEnvVar must not retain a secret value field")
        }
    }

    func testSetToolsetCredentialPutsKeyAndTrimmedValueInBody() async throws {
        let response = Data(#"{"name":"web","providers":[]}"#.utf8)

        for style in [APIPathStyle.legacy, .plugin] {
            let prefix = style.mobileAPIPrefix
            let client = makeClient(style: style, script: [(response, 200)])

            _ = try await client.setToolsetCredential(
                name: "web",
                key: "TAVILY_API_KEY",
                value: "  tvly-test-token  "
            )

            XCTAssertEqual(recordedPaths, ["\(prefix)/toolsets/web/config"])
            XCTAssertEqual(recordedMethods, ["PUT"])
            let request = try XCTUnwrap(RecordingProtocol.requests.first)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertFalse(request.url?.absoluteString.contains("tvly-test-token") ?? true, "credential must not leak into URL")
            let object = try XCTUnwrap(jsonBody(for: request))
            XCTAssertEqual(object["key"] as? String, "TAVILY_API_KEY")
            XCTAssertEqual(object["value"] as? String, "tvly-test-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Hermes-Session-Token"), "tok")
        }
    }

    func testClearToolsetCredentialSendsEmptyValue() async throws {
        let response = Data(#"""
        {"name":"image_gen","providers":[{"name":"FAL","env_vars":[{"key":"FAL_KEY","prompt":"FAL Key","is_set":false}]}]}
        """#.utf8)
        let client = makeClient(style: .plugin, script: [(response, 200)])

        let config = try await client.setToolsetCredential(
            name: "image_gen",
            key: "FAL_KEY",
            value: nil
        )

        XCTAssertEqual(recordedPaths, ["/api/plugins/hermes-mobile/toolsets/image_gen/config"])
        XCTAssertEqual(recordedMethods, ["PUT"])
        let request = try XCTUnwrap(RecordingProtocol.requests.first)
        let object = try XCTUnwrap(jsonBody(for: request))
        XCTAssertEqual(object["key"] as? String, "FAL_KEY")
        XCTAssertEqual(object["value"] as? String, "", "nil clear must be sent as an empty value")
        XCTAssertFalse(try XCTUnwrap(config.providers.first?.envVars.first).isSet)
    }

    func testToolsetCatalogKeepsSettingsReachabilitySurfaceFocused() {
        // CONTRACT (not a frozen literal): every configurable name the iOS
        // client requests MUST be a key the gateway's
        // CONFIGURABLE_TOOLSETS (hermes_cli/tools_config.py) recognises —
        // otherwise _valid_toolset_config_names() silently drops the panel.
        // The known valid set today is {web, image_gen}. If a new panel is
        // added, extend this set, but never let the client drift off it.
        let gatewayValidToolsetKeys: Set<String> = ["web", "image_gen"]
        XCTAssertTrue(
            Set(ToolsetConfigCatalog.configurableNames).isSubset(of: gatewayValidToolsetKeys),
            "iOS configurableNames \(ToolsetConfigCatalog.configurableNames) must be a subset of " +
            "the gateway's valid toolset keys \(gatewayValidToolsetKeys)"
        )
        XCTAssertEqual(ToolsetConfig.displayName(for: "web"), "Web Search")
        XCTAssertEqual(ToolsetConfig.displayName(for: "image_gen"), "Image Generation")
    }

    func testCredentialEntryViewIsConstructedFromRedactedTargetOnly() {
        let target = ToolsetCredentialTarget(
            toolsetName: "web",
            toolsetDisplayName: "Web Search",
            providerName: "Tavily",
            envVar: ToolsetEnvVar(
                key: "TAVILY_API_KEY",
                prompt: "Tavily API Key",
                url: nil,
                defaultValue: nil,
                isSet: true
            )
        )
        let client = makeClient(style: .plugin, script: [(Data(#"{"name":"web","providers":[]}"#.utf8), 200)])
        let view = ToolsetCredentialEntryView(rest: client, target: target) { _ in }

        XCTAssertTrue(target.envVar.isSet, "configured status is carried as is_set only")
        XCTAssertFalse(
            Set(Mirror(reflecting: target.envVar).children.compactMap(\.label)).contains("value"),
            "entry targets must not carry a stored secret for SecureField prefill"
        )
        XCTAssertTrue(
            Mirror(reflecting: view).children.contains { $0.label == "target" },
            "entry view should be reachable from the redacted target model"
        )
    }

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
