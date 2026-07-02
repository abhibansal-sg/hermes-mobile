import XCTest
@testable import HermesMobile

@MainActor
extension SharedInboxDrainerTests {

    private func makeDrainStores() -> (
        connection: ConnectionStore,
        sessions: SessionStore,
        chat: ChatStore,
        attachments: AttachmentStore
    ) {
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        let attachments = AttachmentStore()
        chat.attach(connection: connection, sessions: sessions, attachments: attachments)
        sessions.attach(connection: connection, chat: chat)
        connection.phase = .connected
        return (connection, sessions, chat, attachments)
    }

    func testDrainKeepsFailedSendQueuedAndDoesNotCountIt() async {
        let s = makeDrainStores()
        let failed = SharedStore.SharedInboxItem(
            id: UUID(),
            text: "retry me",
            url: nil,
            comment: nil,
            imageFiles: [],
            createdAt: Date(timeIntervalSince1970: 1)
        )
        var remaining = [failed]
        var observedCounts: [Int] = []
        var processedIDs: [UUID] = []
        let attempted = expectation(description: "failed send attempted")

        SharedInboxDrainer.drain(
            connection: s.connection,
            sessions: s.sessions,
            chat: s.chat,
            attachments: s.attachments,
            onDrained: { count in observedCounts.append(count) },
            readInbox: { remaining },
            removeInboxItem: { item in remaining.removeAll { $0.id == item.id } },
            processItem: { item in
                processedIDs.append(item.id)
                attempted.fulfill()
                // Simulates ChatStore.send returning false: the item was not delivered.
                return nil
            }
        )

        await fulfillment(of: [attempted], timeout: 1)
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(processedIDs, [failed.id])
        XCTAssertEqual(remaining.map(\.id), [failed.id], "failed sends stay queued for retry")
        XCTAssertEqual(observedCounts, [], "failed sends are excluded from the drained count")
    }

    func testDrainRemovesOnlySuccessfulItemsAndCountsDeliveredItems() async {
        let s = makeDrainStores()
        let delivered = SharedStore.SharedInboxItem(
            id: UUID(),
            text: "delivered",
            url: nil,
            comment: nil,
            imageFiles: [],
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let failed = SharedStore.SharedInboxItem(
            id: UUID(),
            text: "retry later",
            url: nil,
            comment: nil,
            imageFiles: [],
            createdAt: Date(timeIntervalSince1970: 2)
        )
        var remaining = [delivered, failed]
        var processedIDs: [UUID] = []
        var observedCount: Int?
        let drained = expectation(description: "only successful item counted")

        SharedInboxDrainer.drain(
            connection: s.connection,
            sessions: s.sessions,
            chat: s.chat,
            attachments: s.attachments,
            onDrained: { count in
                observedCount = count
                drained.fulfill()
            },
            readInbox: { remaining },
            removeInboxItem: { item in remaining.removeAll { $0.id == item.id } },
            processItem: { item in
                processedIDs.append(item.id)
                guard item.id == delivered.id else {
                    // Simulates ChatStore.send returning false for the second item.
                    return nil
                }
                s.sessions.activeStoredId = "stored-delivered"
                s.sessions.activeRuntimeId = "runtime-delivered"
                return (storedId: "stored-delivered", runtimeId: "runtime-delivered")
            }
        )

        await fulfillment(of: [drained], timeout: 1)

        XCTAssertEqual(processedIDs, [delivered.id, failed.id])
        XCTAssertEqual(remaining.map(\.id), [failed.id], "only the delivered item is removed")
        XCTAssertEqual(observedCount, 1, "drained count reports delivered items, not raw batch size")
    }
}
