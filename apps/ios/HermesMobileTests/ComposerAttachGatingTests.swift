// B9 regression tests — the composer "+" (attach) visibility gate.
//
// Build 114 hid the "+" in relay mode: its SOLE visibility gate was
// `capabilities.upload != .unavailable` (ComposerView), a verdict produced by
// a GATEWAY-REST probe chain the relay transport has no business depending on
// (mount probe → legacy path style → `POST /api/upload` 404 → `.unavailable`,
// persisted per server+app-version for the whole build). On the relay
// transport the attach flows ride the relay `attach` RPC instead, so the
// probe verdict must never hide the menu.
//
// The gate now lives on `ConnectionStore.attachMenuAvailable` (the view reads
// it verbatim): relay → always available; direct → the E1 probe gate,
// byte-for-byte. These tests pin BOTH halves: the B9 fix (relay shows "+")
// and the E1 guarantee (direct stock-gateway still hides it).

import XCTest
@testable import HermesMobile

@MainActor
final class ComposerAttachGatingTests: XCTestCase {

    /// Run `body` with a pinned persisted transport path, restoring whatever
    /// was there before (the key is shared machine state).
    private func withTransportPath(
        _ raw: String?,
        _ body: (ConnectionStore) throws -> Void
    ) throws {
        let env = ProcessInfo.processInfo.environment
        if env["HERMES_TRANSPORT"]?.lowercased() == "relay" || env["HERMES_RELAY_URL"] != nil {
            // The DEBUG launch-env override forces `.relay` regardless of
            // defaults — the direct-mode assertions are meaningless under it.
            try XCTSkipIf(true, "HERMES_TRANSPORT/HERMES_RELAY_URL env override active")
        }
        let key = DefaultsKeys.transportPath
        let previous = UserDefaults.standard.string(forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        if let raw {
            UserDefaults.standard.set(raw, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        try body(ConnectionStore(sessionStore: SessionStore(), chatStore: ChatStore()))
    }

    // MARK: - B9: relay shows "+" regardless of the gateway-REST probe verdict

    func testRelayShowsAttachMenuDespiteUploadProvenUnavailable() throws {
        try withTransportPath(TransportPath.relay.rawValue) { connection in
            connection.capabilities._setUploadForTesting(.unavailable)
            XCTAssertTrue(
                connection.attachMenuAvailable,
                "B9 regression: on the relay transport the attach flow rides the relay WS — a gateway-REST probe verdict must NEVER hide the composer '+'"
            )
        }
    }

    func testRelayShowsAttachMenuInEveryProbeState() throws {
        try withTransportPath(TransportPath.relay.rawValue) { connection in
            for state in [ServerCapabilities.State.unknown, .available, .unavailable] {
                connection.capabilities._setUploadForTesting(state)
                XCTAssertTrue(
                    connection.attachMenuAvailable,
                    "relay '+' must not depend on the probe (state=\(state))"
                )
            }
        }
    }

    // MARK: - E1 preserved: direct mode keeps the probe gate byte-for-byte

    func testDirectHidesAttachMenuWhenUploadProvenUnavailable() throws {
        try withTransportPath(TransportPath.gatewayDirect.rawValue) { connection in
            connection.capabilities._setUploadForTesting(.unavailable)
            XCTAssertFalse(
                connection.attachMenuAvailable,
                "E1: a stock gateway (probe-proven no upload) keeps '+' hidden in DIRECT mode"
            )
        }
    }

    func testDirectShowsAttachMenuWhenUnknownOrAvailable() throws {
        // Absent persisted value ⇒ gateway-direct (default OFF).
        try withTransportPath(nil) { connection in
            XCTAssertEqual(connection.transportPath, .gatewayDirect)
            connection.capabilities._setUploadForTesting(.unknown)
            XCTAssertTrue(
                connection.attachMenuAvailable,
                "optimistic: an unprobed server keeps '+' shown in direct mode"
            )
            connection.capabilities._setUploadForTesting(.available)
            XCTAssertTrue(connection.attachMenuAvailable)
        }
    }
}
