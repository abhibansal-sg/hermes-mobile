import XCTest
@testable import HermesMobile

/// Live integration coverage for the W3A-A device-token REST surface against a
/// running W3a hermes gateway — the issue→list→revoke round-trip from the
/// `RestClient` layer (NOT the UI), per CONTRACT-W3A.md §VERIFY.
///
/// Requires a W3a dashboard reachable with credentials in the test-runner env
/// (TEST_RUNNER_HERMES_URL / TEST_RUNNER_HERMES_TOKEN → HERMES_URL / HERMES_TOKEN
/// here). Skips (rather than fails) when credentials are absent so the unit suite
/// stays green in CI without a backend — mirroring `RestClientLiveTests`.
///
/// SAFETY: this issues + revokes a THROWAWAY device on whatever instance the env
/// points at. Per the contract it must ONLY be run against an own throwaway
/// instance (never the live 9119 / shared backend).
final class DevicesLiveTests: XCTestCase {

    private func liveClient() async throws -> RestClient {
        let env = ProcessInfo.processInfo.environment
        guard let urlString = env["HERMES_URL"], let token = env["HERMES_TOKEN"],
              !urlString.isEmpty, !token.isEmpty,
              let url = URL(string: urlString) else {
            throw XCTSkip("HERMES_URL/HERMES_TOKEN not provided; skipping live devices test")
        }
        // Mirror production (ABH-88): probe the plugin mount once and pin the
        // path family the gateway actually serves.
        let probe = RestClient(baseURL: url, token: token)
        let mount = await probe.probePluginMountEndpoint()
        return probe.withPathStyle(mount == .available ? .plugin : .legacy)
    }

    /// The full issue→list→revoke round-trip through the typed `RestClient`
    /// methods, asserting the decode shapes match the pinned contract and the
    /// list NEVER echoes a full token (only the 8-char prefix).
    func testLiveIssueListRevokeRoundTrip() async throws {
        let client = try await liveClient()

        // Probe must classify the W3a route as available (200 + {devices:[]}).
        let probe = await client.probeDevicesEndpoint()
        XCTAssertEqual(probe, .available, "W3a server should advertise /api/devices")

        // ISSUE — the token is returned exactly once.
        let issued = try await client.issueDevice(name: "W3A-A Live Roundtrip")
        XCTAssertFalse(issued.deviceId.isEmpty)
        XCTAssertFalse(issued.token.isEmpty)
        XCTAssertEqual(issued.deviceName, "W3A-A Live Roundtrip")

        // LIST — the device appears with its token_prefix; the FULL token is
        // never present anywhere in the list response (secrets hygiene).
        let listed = try await client.devicesList()
        guard let row = listed.first(where: { $0.deviceId == issued.deviceId }) else {
            return XCTFail("Issued device \(issued.deviceId) not present in list")
        }
        XCTAssertEqual(row.tokenPrefix, String(issued.token.prefix(8)))
        XCTAssertEqual(row.platform, "ios")
        XCTAssertEqual(row.scopes, ["chat", "approve"])
        XCTAssertNotEqual(row.tokenPrefix, issued.token, "list must not echo the full token")

        // The issued device token itself authenticates a gated REST call
        // (device-token acceptance path).
        if let url = URL(string: ProcessInfo.processInfo.environment["HERMES_URL"]!) {
            let deviceClient = RestClient(
                baseURL: url, token: issued.token, pathStyle: client.pathStyle
            )
            // A real gated call: listing devices with the DEVICE token works.
            let viaDevice = try await deviceClient.devicesList()
            XCTAssertTrue(viaDevice.contains { $0.deviceId == issued.deviceId })
        }

        // REVOKE — the row disappears and the call reports success.
        let revoke = try await client.revokeDevice(id: issued.deviceId)
        XCTAssertTrue(revoke.revoked)
        XCTAssertEqual(revoke.deviceId, issued.deviceId)

        let afterRevoke = try await client.devicesList()
        XCTAssertFalse(
            afterRevoke.contains { $0.deviceId == issued.deviceId },
            "Revoked device must not appear in the list"
        )
    }

    /// The audit-read endpoint decodes (it may be empty on a fresh instance —
    /// that is a valid 200 `{entries:[]}`, the route exists).
    func testLiveApprovalAuditDecodes() async throws {
        let client = try await liveClient()
        let entries = try await client.approvalAudit(limit: 50)
        // No assertion on count (a fresh instance has none); the round-trip
        // proving the decode + route is the test. Any entry, if present, carries
        // a credential and never a full token field (structural — see unit tests).
        XCTAssertNotNil(entries)
    }
}
