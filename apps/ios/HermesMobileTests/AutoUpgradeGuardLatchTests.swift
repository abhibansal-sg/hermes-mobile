import XCTest
@testable import HermesMobile

/// STR-1257: focused coverage for the early-return guards in
/// `ConnectionStore.autoUpgradeToDeviceTokenIfNeeded(serverURL:)` that protect
/// the 64-device registry cap — none of these were previously exercised
/// end-to-end. Drives the real method (not a mirrored decision function)
/// through the STR-1417 `_restOverrideForTesting` seam, reusing the
/// `DevicesTests.AutoUpgradeRoutingProtocol` path-routing stub so both files
/// answer the live `GET /api/status` auth-gate check and `POST
/// /api/devices/issue` identically.
@MainActor
final class AutoUpgradeGuardLatchTests: XCTestCase {

    /// A `ConnectionStore` seeded as already connected against `server` with
    /// `rest` overridden to the shared routing stub, mirroring
    /// `DevicesTests.makeAutoUpgradeConnection` (private to that file, so
    /// reconstructed here) but with the capability state made configurable per
    /// guard under test.
    private func makeConnection(
        server: String,
        capability: ServerCapabilities.State = .available
    ) -> ConnectionStore {
        let connection = ConnectionStore(sessionStore: SessionStore(), chatStore: ChatStore())
        connection._seedConnectedForTesting(serverURL: server, token: "shared_tok")
        connection.capabilities._setDevicesForTesting(capability)
        DevicesTests.AutoUpgradeRoutingProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DevicesTests.AutoUpgradeRoutingProtocol.self]
        connection._restOverrideForTesting = RestClient(
            baseURL: URL(string: server)!,
            token: "shared_tok",
            session: URLSession(configuration: config),
            pathStyle: .legacy
        )
        return connection
    }

    /// Guard (c): a 409 from `issueDevice` is PERMANENT, not transient. The
    /// first call must latch `serverURL` into `deviceIssueLimitReachedServers`;
    /// a SECOND call for the SAME server must return without re-touching the
    /// network at all — the latch guard fires before the `status()`/
    /// `issueDevice()` round-trip, so `issueCallCount` must not increment past
    /// the first attempt. A refactor that drops this latch would silently
    /// re-hammer `issueDevice` on every reconnect.
    func testFourZeroNineLatchesServerAndSuppressesSecondCall() async {
        let server = "https://cap-latch.example:9119"
        let connection = makeConnection(server: server)
        DevicesTests.AutoUpgradeRoutingProtocol.statusBody = Data(#"{"auth_required":true}"#.utf8)
        DevicesTests.AutoUpgradeRoutingProtocol.issueCode = 409
        DevicesTests.AutoUpgradeRoutingProtocol.issueBody = Data(
            #"{"error":"device limit reached","max_devices":64}"#.utf8
        )

        await connection.autoUpgradeToDeviceTokenIfNeeded(serverURL: server)

        XCTAssertEqual(DevicesTests.AutoUpgradeRoutingProtocol.issueCallCount, 1)
        XCTAssertTrue(connection._isDeviceIssueLimitReachedSuppressedForTesting(serverURL: server))
        XCTAssertNil(DefaultsKeys.deviceId(server: server))

        // Second call, same server: latched ⇒ no additional network round-trip.
        await connection.autoUpgradeToDeviceTokenIfNeeded(serverURL: server)

        XCTAssertEqual(DevicesTests.AutoUpgradeRoutingProtocol.issueCallCount, 1)
        XCTAssertNil(DefaultsKeys.deviceId(server: server))
    }

    /// Guard (b): a server with an already-recorded `device_id` (prior upgrade,
    /// or a v2 QR that handed us a device token) must never re-issue.
    func testSkipsIssueWhenDeviceIdAlreadyRecorded() async {
        let server = "https://cap-has-id.example:9119"
        DefaultsKeys.setDeviceId("dev_existing", server: server)
        defer { DefaultsKeys.setDeviceId(nil, server: server) }

        let connection = makeConnection(server: server)
        DevicesTests.AutoUpgradeRoutingProtocol.statusBody = Data(#"{"auth_required":true}"#.utf8)

        await connection.autoUpgradeToDeviceTokenIfNeeded(serverURL: server)

        XCTAssertEqual(DevicesTests.AutoUpgradeRoutingProtocol.issueCallCount, 0)
        XCTAssertEqual(DefaultsKeys.deviceId(server: server), "dev_existing")
    }

    /// Guard (a): a stock gateway (`capabilities.devices != .available`) must
    /// never issue — there is no route to call.
    func testSkipsIssueWhenCapabilityNotAvailable() async {
        let server = "https://cap-unavailable.example:9119"
        let connection = makeConnection(server: server, capability: .unavailable)
        DevicesTests.AutoUpgradeRoutingProtocol.statusBody = Data(#"{"auth_required":true}"#.utf8)

        await connection.autoUpgradeToDeviceTokenIfNeeded(serverURL: server)

        XCTAssertEqual(DevicesTests.AutoUpgradeRoutingProtocol.issueCallCount, 0)
        XCTAssertNil(DefaultsKeys.deviceId(server: server))
    }
}
