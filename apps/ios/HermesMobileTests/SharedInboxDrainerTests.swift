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

    func testPendingInboxCountReportsNonEmptyInbox() {
        let item = SharedStore.SharedInboxItem(
            id: UUID(),
            text: "queued",
            url: nil,
            comment: nil,
            imageFiles: [],
            createdAt: Date(timeIntervalSince1970: 1)
        )

        XCTAssertEqual(
            SharedStore.pendingInboxCount(readInbox: { [item] }),
            1,
            "a non-empty share-extension inbox must produce a visible pending count"
        )
    }

    func testConnectedTransitionInvokesSharedInboxDrainer() {
        var ensureRegisteredCalls = 0
        var notifyCalls = 0
        var drainCalls = 0

        SharedInboxDrainConnectionTrigger.handle(
            .connected,
            ensureRegisteredForPairedGateway: { ensureRegisteredCalls += 1 },
            notifyInboxDidChange: { notifyCalls += 1 },
            drain: { drainCalls += 1 }
        )

        XCTAssertEqual(ensureRegisteredCalls, 1)
        XCTAssertEqual(notifyCalls, 1)
        XCTAssertEqual(drainCalls, 1, ".connected must retry the share-inbox drain even without a scenePhase edge")
    }

    func testDoubleDrainTriggerDoesNotDoubleDeliverQueuedItem() async {
        let s = makeDrainStores()
        let item = SharedStore.SharedInboxItem(
            id: UUID(),
            text: "deliver once",
            url: nil,
            comment: nil,
            imageFiles: [],
            createdAt: Date(timeIntervalSince1970: 1)
        )
        var remaining = [item]
        var processCalls = 0
        var observedCounts: [Int] = []
        let started = expectation(description: "first drain started")
        let drained = expectation(description: "first drain completed")

        let processItem: SharedInboxDrainer.ProcessItemOverride = { item in
            processCalls += 1
            started.fulfill()
            try? await Task.sleep(for: .milliseconds(120))
            return (storedId: "stored-\(item.id.uuidString)", runtimeId: "runtime-\(item.id.uuidString)")
        }

        SharedInboxDrainer.drain(
            connection: s.connection,
            sessions: s.sessions,
            chat: s.chat,
            attachments: s.attachments,
            onDrained: { count in
                observedCounts.append(count)
                drained.fulfill()
            },
            readInbox: { remaining },
            removeInboxItem: { item in remaining.removeAll { $0.id == item.id } },
            processItem: processItem
        )

        await fulfillment(of: [started], timeout: 1)

        // Simulates scenePhase.active and connectionPhase.connected firing for the
        // same inbox. The in-flight guard should coalesce the second trigger.
        SharedInboxDrainer.drain(
            connection: s.connection,
            sessions: s.sessions,
            chat: s.chat,
            attachments: s.attachments,
            onDrained: { count in observedCounts.append(count) },
            readInbox: { remaining },
            removeInboxItem: { item in remaining.removeAll { $0.id == item.id } },
            processItem: processItem
        )

        await fulfillment(of: [drained], timeout: 1)

        XCTAssertEqual(processCalls, 1, "overlapping drain triggers must not double-deliver the same app-group item")
        XCTAssertEqual(observedCounts, [1])
        XCTAssertTrue(remaining.isEmpty)
    }
}
