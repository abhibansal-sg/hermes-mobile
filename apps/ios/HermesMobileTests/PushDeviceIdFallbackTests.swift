import XCTest
@testable import HermesMobile

/// QA-3 S13: the relay push registry dedups by `device_id`. A relay-only phone
/// with no v2-issued device id MUST still send a stable id so the registry
/// converges to one row per device. These tests pin the accessor that backs
/// that contract.
final class PushDeviceIdFallbackTests: XCTestCase {

    private let server = "https://gateway.example.test"

    private func resetState() {
        UserDefaults.standard.removeObject(forKey: DefaultsKeys.deviceIdsByServer)
        UserDefaults.standard.removeObject(forKey: DefaultsKeys.pushDeviceInstallId)
    }

    override func setUp() {
        super.setUp()
        resetState()
    }

    override func tearDown() {
        resetState()
        super.tearDown()
    }

    func testV2DeviceIdWinsWhenPresent() {
        DefaultsKeys.setDeviceId("issued-v2-42", server: server)
        XCTAssertEqual(
            DefaultsKeys.pushRegistrationDeviceId(server: server),
            "issued-v2-42"
        )
    }

    func testFallbackMintsNonEmptyIdWhenNoV2Id() {
        XCTAssertNil(DefaultsKeys.deviceId(server: server))
        let resolved = DefaultsKeys.pushRegistrationDeviceId(server: server)
        XCTAssertFalse(resolved.isEmpty, "registration id must be non-empty even without a v2 id")
    }

    func testFallbackIsStableAcrossCalls() {
        let first = DefaultsKeys.pushRegistrationDeviceId(server: server)
        let second = DefaultsKeys.pushRegistrationDeviceId(server: server)
        XCTAssertEqual(first, second, "the per-install id must persist across calls")
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: DefaultsKeys.pushDeviceInstallId),
            first
        )
    }

    func testFallbackIsSharedAcrossServers() {
        // The per-install fallback identifies the physical install, not the
        // gateway — the same phone registering against two gateways still
        // converges to one row each (and a v2 id, when issued, overrides).
        let serverB = "https://other.example.test"
        let a = DefaultsKeys.pushRegistrationDeviceId(server: server)
        let b = DefaultsKeys.pushRegistrationDeviceId(server: serverB)
        XCTAssertEqual(a, b)
    }

    func testV2IdIssuedLaterOverridesFallback() {
        let fallback = DefaultsKeys.pushRegistrationDeviceId(server: server)
        XCTAssertFalse(fallback.isEmpty)
        DefaultsKeys.setDeviceId("issued-later", server: server)
        XCTAssertEqual(
            DefaultsKeys.pushRegistrationDeviceId(server: server),
            "issued-later",
            "a freshly-issued v2 id must take precedence over the fallback"
        )
    }
}
