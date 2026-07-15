import XCTest
@testable import HermesMobile

@MainActor
final class ConnectionOfflineModeTests: XCTestCase {
    private func makeStore() -> ConnectionStore {
        let sessions = SessionStore()
        let chat = ChatStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        let attachments = AttachmentStore()
        sessions.attach(connection: connection, chat: chat, attachments: attachments)
        chat.attach(connection: connection, sessions: sessions, attachments: attachments)
        return connection
    }

    func testGoOfflinePersistsAndBootstrapDoesNotReconnect() async {
        let defaults = UserDefaults.standard
        let oldOffline = defaults.object(forKey: DefaultsKeys.connectionOffline)
        defer {
            if let oldOffline { defaults.set(oldOffline, forKey: DefaultsKeys.connectionOffline) }
            else { defaults.removeObject(forKey: DefaultsKeys.connectionOffline) }
        }
        let connection = makeStore()
        await connection.goOffline()
        XCTAssertTrue(defaults.bool(forKey: DefaultsKeys.connectionOffline))

        var connected = false
        connection.connectRPC = { _, _, _ in connected = true }
        await connection.bootstrap()
        XCTAssertFalse(connected)
        XCTAssertEqual(connection.phase, .offline(nil))
    }

    func testExplicitReconnectClearsOfflineLatch() async {
        let defaults = UserDefaults.standard
        let oldServer = defaults.string(forKey: DefaultsKeys.serverURL)
        defaults.removeObject(forKey: DefaultsKeys.serverURL)
        defaults.set(true, forKey: DefaultsKeys.connectionOffline)
        defer {
            defaults.removeObject(forKey: DefaultsKeys.connectionOffline)
            if let oldServer { defaults.set(oldServer, forKey: DefaultsKeys.serverURL) }
        }
        let connection = makeStore()
        await connection.reconnect()
        XCTAssertFalse(defaults.bool(forKey: DefaultsKeys.connectionOffline))
    }
}
