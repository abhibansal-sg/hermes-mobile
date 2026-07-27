import XCTest
@testable import HermesMobile

final class PersistedNotificationEndpointResolverTests: XCTestCase {
    func testResolvesURLTokenAndPathStyleFromPersistenceOwners() throws {
        var tokenLookup: String?
        let resolver = PersistedNotificationEndpointResolver(
            loadURLString: { "https://gateway.example:9443" },
            loadToken: { tokenLookup = $0; return "keychain-token" },
            loadAuthMode: { .token },
            loadPathStyle: { _ in .plugin }
        )

        let endpoint = try XCTUnwrap(resolver.resolve())
        XCTAssertEqual(endpoint.baseURL.absoluteString, "https://gateway.example:9443")
        XCTAssertEqual(endpoint.token, "keychain-token")
        XCTAssertEqual(endpoint.pathStyle, .plugin)
        XCTAssertEqual(tokenLookup, "https://gateway.example:9443")
    }

    func testMissingTokenIsRecoverableResolutionFailure() {
        let resolver = PersistedNotificationEndpointResolver(
            loadURLString: { "https://gateway.example" },
            loadToken: { _ in nil },
            loadAuthMode: { .token },
            loadPathStyle: { _ in .legacy }
        )
        XCTAssertNil(resolver.resolve())
    }

    func testInvalidOrMissingURLNeverReadsToken() {
        var tokenReads = 0
        for value in [nil, "", "not a URL"] as [String?] {
            let resolver = PersistedNotificationEndpointResolver(
                loadURLString: { value },
                loadToken: { _ in tokenReads += 1; return "secret" },
                loadAuthMode: { .token },
                loadPathStyle: { _ in .legacy }
            )
            XCTAssertNil(resolver.resolve())
        }
        XCTAssertEqual(tokenReads, 0)
    }

    func testSessionAuthUsesCookiePathWithoutReadingToken() throws {
        var tokenReads = 0
        let resolver = PersistedNotificationEndpointResolver(
            loadURLString: { "https://gateway.example" },
            loadToken: { _ in tokenReads += 1; return nil },
            loadAuthMode: { .session },
            loadPathStyle: { _ in .plugin }
        )

        let endpoint = try XCTUnwrap(resolver.resolve())
        XCTAssertEqual(endpoint.token, "")
        XCTAssertEqual(endpoint.pathStyle, .plugin)
        XCTAssertEqual(tokenReads, 0)
    }
}
