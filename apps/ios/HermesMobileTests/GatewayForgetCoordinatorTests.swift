import XCTest
@testable import HermesMobile

@MainActor
final class GatewayForgetCoordinatorTests: XCTestCase {
    private func makeStore() -> (ConnectionStore, QueueStore, InboxStore) {
        let sessions = SessionStore()
        let chat = ChatStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        let queue = QueueStore()
        let inbox = InboxStore()
        connection.queueStore = queue
        connection.inboxStore = inbox
        return (connection, queue, inbox)
    }

    func testRemoteFailureCannotBlockLocalForgetAndLeavesMinimalTombstone() async throws {
        let server = "https://forget.example"
        let defaults = UserDefaults.standard
        defaults.set(server, forKey: DefaultsKeys.serverURL)
        defaults.set(true, forKey: DefaultsKeys.pushRegistrationHealthy)
        DefaultsKeys.setDeviceId("device-1", server: server)
        PendingIntent.ask(prompt: "private").park()
        defer {
            defaults.removeObject(forKey: DefaultsKeys.gatewayCleanupTombstone)
            defaults.removeObject(forKey: DefaultsKeys.pendingIntentPrompt)
        }
        let (connection, queue, _) = makeStore()
        _ = queue.enqueue("private queued prompt")

        await connection.forgetGateway(remoteCleanup: {
            throw URLError(.notConnectedToInternet)
        })

        XCTAssertNil(defaults.string(forKey: DefaultsKeys.serverURL))
        XCTAssertNil(DefaultsKeys.deviceId(server: server))
        XCTAssertFalse(defaults.bool(forKey: DefaultsKeys.pushRegistrationHealthy))
        XCTAssertTrue(queue.items.isEmpty)
        XCTAssertNil(PendingIntent.takePending())
        let data = try XCTUnwrap(defaults.data(forKey: DefaultsKeys.gatewayCleanupTombstone))
        let tombstone = try JSONDecoder().decode(GatewayCleanupTombstone.self, from: data)
        XCTAssertEqual(tombstone, GatewayCleanupTombstone(server: server, deviceId: "device-1", remoteRetryNeeded: true))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private"))
    }

    func testForgetIsIdempotentAndDoesNotClearAnotherGatewayIdentity() async {
        let defaults = UserDefaults.standard
        let server = "https://forgotten.example"
        let other = "https://other.example"
        defaults.set(server, forKey: DefaultsKeys.serverURL)
        DefaultsKeys.setDeviceId("forgotten-device", server: server)
        DefaultsKeys.setDeviceId("other-device", server: other)
        try? KeychainService.saveToken("forgotten-token", server: server)
        defer {
            DefaultsKeys.setDeviceId(nil, server: other)
            KeychainService.deleteToken(server: server)
        }
        let (connection, _, _) = makeStore()
        await connection.forgetGateway()
        await connection.forgetGateway()
        XCTAssertNil(KeychainService.loadToken(server: server))
        XCTAssertEqual(DefaultsKeys.deviceId(server: other), "other-device")
        XCTAssertEqual(connection.phase, .needsSetup)
        XCTAssertFalse(connection.hasConnected)
        XCTAssertNil(connection.reconnectTask)
    }
}
