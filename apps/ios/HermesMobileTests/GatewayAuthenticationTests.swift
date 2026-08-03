import XCTest
@testable import HermesMobile

final class GatewayAuthenticationTests: XCTestCase {
    private final class StubProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var handler:
            ((URLRequest) throws -> (status: Int, body: String))?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            do {
                let result = try Self.handler!(request)
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: result.status,
                    httpVersion: nil,
                    headerFields: nil
                )!
                client?.urlProtocol(
                    self,
                    didReceive: response,
                    cacheStoragePolicy: .notAllowed
                )
                client?.urlProtocol(self, didLoad: Data(result.body.utf8))
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }

    private func client(token: String = "") -> RestClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return RestClient(
            baseURL: URL(string: "https://gateway.example")!,
            token: token,
            session: URLSession(configuration: configuration)
        )
    }

    override func tearDown() {
        StubProtocol.handler = nil
        super.tearDown()
    }

    func testOpenGatewaySelectsTokenAuthWithoutProviderProbe() async throws {
        var paths: [String] = []
        StubProtocol.handler = { request in
            paths.append(request.url!.path)
            return (200, #"{"version":"0.19","auth_required":false}"#)
        }

        let probe = try await client().authProbe()

        XCTAssertEqual(probe.mode, .token)
        XCTAssertEqual(paths, ["/api/status"])
    }

    func testGatedGatewaySelectsSessionAuthAndAdvertisesPassword() async throws {
        StubProtocol.handler = { request in
            switch request.url!.path {
            case "/api/status":
                return (200, #"{"version":"0.19","auth_required":true}"#)
            case "/api/auth/providers":
                return (
                    200,
                    #"{"providers":[{"name":"password","display_name":"Password","supports_password":true}]}"#
                )
            default:
                return (404, "")
            }
        }

        let probe = try await client().authProbe()

        XCTAssertEqual(probe.mode, .session)
        XCTAssertEqual(
            probe.providers,
            [GatewayAuthProvider(
                name: "password",
                displayName: "Password",
                supportsPassword: true
            )]
        )
    }

    func testTicketMintUsesCookiePathWithoutTokenHeader() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/auth/ws-ticket")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Hermes-Session-Token"))
            return (200, #"{"ticket":"fresh-ticket"}"#)
        }

        let ticket = try await client().webSocketTicket()
        XCTAssertEqual(ticket, "fresh-ticket")
    }

    func testRemoteRestRequestDoesNotSpoofLoopbackHost() async throws {
        StubProtocol.handler = { request in
            XCTAssertNotEqual(request.value(forHTTPHeaderField: "Host"), "127.0.0.1")
            return (200, #"{"version":"0.19","auth_required":false}"#)
        }

        _ = try await client(token: "token").status()
    }
}
