import XCTest
@testable import HermesMobile

/// ABH-52 (R1 Batch G, iOS half) — connection lifecycle and diagnostics.
///
/// Covered here: #57 (capabilities cache must not survive a forced re-probe
/// after a dropped socket) and the #19 client half (the gateway's readable
/// 4403 "chat disabled" close surfaces as actionable guidance, not a generic
/// transport error / ready-timeout). #11 (never cancelling the single-consumer
/// AsyncStream tasks) is structural — `ConnectionStore.disconnect()` simply no
/// longer cancels them — and is compile-verified; the client is not injectable
/// into ConnectionStore for a full-path harness.
@MainActor
final class BatchGTests: XCTestCase {

    // MARK: - #57: forced re-probe bypasses both cache layers

    func testForcedProbeBypassesDiskCacheAfterReconnect() async {
        let url = "http://127.0.0.1:1"  // nothing listens: probes stay .unknown
        let key = DefaultsKeys.serverCapabilities
        defer { UserDefaults.standard.removeObject(forKey: key) }

        // A persisted snapshot for this exact server + app version, claiming a
        // PATCHED gateway (fs/upload available) — what a pre-restart probe
        // would have left behind.
        let cached = """
        {"serverURL":"\(url)","appVersion":"\(ServerCapabilities.currentAppVersion)",
         "upload":"available","pushRegistry":"unknown","broadcast":"unknown",
         "fs":"available","subagentEvents":"unknown","profiles":"unknown",
         "devices":"unknown"}
        """
        UserDefaults.standard.set(Data(cached.utf8), forKey: key)
        let rest = RestClient(baseURL: URL(string: url)!, token: "t")

        // Unforced probe (initial connect): the disk cache applies — this is
        // contract E1 and must keep working.
        let warm = ServerCapabilities()
        await warm.probe(serverURL: url, rest: rest)
        XCTAssertEqual(warm.fs, .available, "unforced probe restores the snapshot")

        // Forced probe (the reconnect path, socket genuinely dropped): the
        // snapshot must NOT be restored — the same URL may now serve a stock
        // gateway. Against a dead server the probes settle .unknown, proving
        // the stale .available did not survive.
        let cold = ServerCapabilities()
        await cold.probe(serverURL: url, rest: rest, force: true)
        XCTAssertNotEqual(cold.fs, .available,
                          "a forced re-probe must not resurrect the pre-restart snapshot")
        XCTAssertNotEqual(cold.upload, .available)

        // Judge round: the entirely-INCONCLUSIVE forced probe must not have
        // poisoned the disk cache with all-unknowns — a later unforced probe
        // (fresh launch) still restores the last CONCLUSIVE snapshot.
        let relaunch = ServerCapabilities()
        await relaunch.probe(serverURL: url, rest: rest)
        XCTAssertEqual(relaunch.fs, .available,
                       "an inconclusive forced probe must not overwrite the good snapshot")
    }

    func testForcedProbeResetsPassiveStates() async {
        let url = "http://127.0.0.1:1"
        defer { UserDefaults.standard.removeObject(forKey: DefaultsKeys.serverCapabilities) }
        let rest = RestClient(baseURL: URL(string: url)!, token: "t")

        let caps = ServerCapabilities()
        caps.noteSubagentObserved()
        caps.noteBroadcastObserved()
        XCTAssertEqual(caps.subagentEvents, .available)

        await caps.probe(serverURL: url, rest: rest, force: true)

        // Passive observations belonged to the PRE-restart server instance;
        // the forced fresh probe resets them to be re-learned live.
        XCTAssertEqual(caps.subagentEvents, .unknown)
        XCTAssertEqual(caps.broadcast, .unknown)
    }

    // MARK: - #19 client half: readable chat-disabled close

    /// A transport whose receive fails after a server-side application close
    /// carrying the gateway's chat-disabled reason (the post-ABH-52-server
    /// behavior: accept, then close(4403, reason)).
    private final class ChatDisabledSocket: GatewayWebSocketTask, @unchecked Sendable {
        func resume() {}
        func send(_ message: URLSessionWebSocketTask.Message) async throws {}
        func receive() async throws -> URLSessionWebSocketTask.Message {
            // Give connect() time to install the ready continuation so the
            // failure routes through it (mirrors the real ordering: the close
            // arrives after the WS handshake completes).
            try? await Task.sleep(for: .milliseconds(100))
            throw URLError(.networkConnectionLost)
        }
        func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {}
        var closeReason: Data? {
            Data("chat disabled: start dashboard with --tui or set HERMES_DASHBOARD_TUI=1".utf8)
        }
    }

    func testChatDisabledCloseSurfacesActionableMessage() async {
        let client = HermesGatewayClient(transportFactory: { _ in ChatDisabledSocket() })

        do {
            try await client.connect(baseURL: URL(string: "http://127.0.0.1:1")!, token: "t")
            XCTFail("connect must fail against a chat-disabled gateway")
        } catch {
            let message = (error as? GatewayError)?.errorDescription
                ?? error.localizedDescription
            XCTAssertTrue(
                message.contains("--tui") || message.contains("HERMES_DASHBOARD_TUI"),
                "the close reason must surface as actionable setup guidance, got: \(message)"
            )
            XCTAssertFalse(message.contains("gateway.ready"),
                           "must not present as the misleading ready-timeout")
        }
    }

    /// A non-chat-disabled application close still beats the generic transport
    /// error: whatever reason the server gave is what the user sees.
    private final class ReasonedCloseSocket: GatewayWebSocketTask, @unchecked Sendable {
        func resume() {}
        func send(_ message: URLSessionWebSocketTask.Message) async throws {}
        func receive() async throws -> URLSessionWebSocketTask.Message {
            try? await Task.sleep(for: .milliseconds(100))
            throw URLError(.networkConnectionLost)
        }
        func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {}
        var closeReason: Data? { Data("owner write backlog overflow".utf8) }
    }

    func testApplicationCloseReasonBeatsGenericTransportError() async {
        let client = HermesGatewayClient(transportFactory: { _ in ReasonedCloseSocket() })

        do {
            try await client.connect(baseURL: URL(string: "http://127.0.0.1:1")!, token: "t")
            XCTFail("connect must fail")
        } catch {
            let message = (error as? GatewayError)?.errorDescription
                ?? error.localizedDescription
            XCTAssertTrue(message.contains("owner write backlog overflow"),
                          "the server's close reason is more actionable than "
                          + "a generic transport error, got: \(message)")
        }
    }
}
