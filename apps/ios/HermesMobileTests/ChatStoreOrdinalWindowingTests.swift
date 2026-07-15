import XCTest
@testable import HermesMobile

/// ABH-4xx safety gate — `truncate_before_user_ordinal` is only safe when iOS
/// has a full, contiguous transcript. Windowed tails and ABH-401 around-window
/// prepends compute ordinals relative to whatever rows are loaded, while the
/// gateway interprets the ordinal against the full server history. These tests
/// pin the interim mitigation: edit/retry must force a full-transcript load
/// before attempting any truncate submit whenever the local window is partial or
/// non-contiguous.
@MainActor
final class ChatStoreOrdinalWindowingTests: XCTestCase {

    private func stored(role: String, text: String, wireId: Int) -> StoredMessage {
        StoredMessage(json: .object([
            "role": .string(role),
            "content": .string(text),
            "id": .number(Double(wireId)),
            "timestamp": .number(1_700_000_000 + Double(wireId)),
        ]))!
    }

    /// 40 user turns (80 rows total), sequential wire ids 1...80 so ordinal-vs-wireId
    /// math is easy to eyeball.
    private func longTranscript(userTurns: Int) -> [StoredMessage] {
        (0..<userTurns).flatMap { i -> [StoredMessage] in
            [
                stored(role: "user", text: "u\(i)", wireId: i * 2 + 1),
                stored(role: "assistant", text: "a\(i)", wireId: i * 2 + 2),
            ]
        }
    }

    private func makeStore(fullTranscript: [StoredMessage]) -> (ChatStore, FullLoadRecorder) {
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        let attachments = AttachmentStore()
        chat.attach(connection: connection, sessions: sessions, attachments: attachments)
        sessions.attach(connection: connection, chat: chat)
        sessions.activeStoredId = "s1"
        sessions.activeRuntimeId = "rt1"

        let recorder = FullLoadRecorder(rows: fullTranscript)
        chat.fullTranscriptFetch = { sessionId in
            XCTAssertEqual(sessionId, "s1")
            return try await recorder.fetch(sessionId)
        }
        return (chat, recorder)
    }

    func testEditFromWindowedTranscriptLoadsFullTranscriptBeforeOrdinalSubmit() async throws {
        let all = longTranscript(userTurns: 40)
        let (chat, recorder) = makeStore(fullTranscript: all)

        let windowed = Array(all.suffix(20)) // turns 30...39, wire ids 61...80
        chat.seed(from: windowed)
        chat.noteTranscriptPaging(oldestId: 61, hasMoreBefore: true)
        let target = try XCTUnwrap(chat.messages.first { $0.text == "u35" })
        XCTAssertEqual(chat.userOrdinals[target.id], 5,
                       "precondition: u35 is unsafe/window-relative in the tail window")

        await chat.editAndResend(messageId: target.id, newText: "u35 edited")

        let editFetchCount = await recorder.fetchCount
        XCTAssertEqual(editFetchCount, 1,
                       "edit must force a full-transcript load before computing a truncate ordinal")
        let reloadedTarget = try XCTUnwrap(chat.messages.first { $0.text == "u35" })
        XCTAssertEqual(chat.userOrdinals[reloadedTarget.id], 35,
                       "after the gate reloads the full transcript, u35 maps to the gateway's absolute user ordinal")
        XCTAssertFalse(chat.transcriptHasMoreBefore,
                       "the full-load gate must clear the partial-window flag before enabling truncation")
        XCTAssertEqual(chat.messages.first?.text, "u0")
        XCTAssertEqual(chat.messages.last?.text, "a39")
    }

    func testRetryFromWindowedTranscriptLoadsFullTranscriptBeforeOrdinalSubmit() async throws {
        let all = longTranscript(userTurns: 40)
        let (chat, recorder) = makeStore(fullTranscript: all)

        let windowed = Array(all.suffix(20))
        chat.seed(from: windowed)
        chat.noteTranscriptPaging(oldestId: 61, hasMoreBefore: true)
        let assistant = try XCTUnwrap(chat.messages.first { $0.text == "a35" })
        let unsafeUser = try XCTUnwrap(chat.messages.first { $0.text == "u35" })
        XCTAssertEqual(chat.userOrdinals[unsafeUser.id], 5,
                       "precondition: retry would otherwise send the tail-window ordinal")

        await chat.retry(fromAssistantId: assistant.id)

        let retryFetchCount = await recorder.fetchCount
        XCTAssertEqual(retryFetchCount, 1,
                       "retry must force a full-transcript load before computing a truncate ordinal")
        let reloadedUser = try XCTUnwrap(chat.messages.first { $0.text == "u35" })
        XCTAssertEqual(chat.userOrdinals[reloadedUser.id], 35)
        XCTAssertFalse(chat.transcriptHasMoreBefore)
    }

    func testRetryFromNonContiguousAroundWindowLoadsFullTranscriptEvenWhenNoMoreBefore() async throws {
        let all = longTranscript(userTurns: 40)
        let (chat, recorder) = makeStore(fullTranscript: all)

        let windowedTail = Array(all.suffix(20)) // wire ids 61...80
        chat.seed(from: windowedTail)
        chat.noteTranscriptPaging(oldestId: 61, hasMoreBefore: true)
        chat.transcriptAroundFetch = { _, messageId, radius in
            XCTAssertEqual(messageId, 5)
            let page = all.filter { row in
                guard let wire = row.wireId else { return false }
                return wire >= messageId - radius && wire <= messageId + radius
            }
            // There is no earlier history before this around page, but there IS a
            // gap between it and the already-loaded tail. The old hasMoreBefore-only
            // gate would treat this as safe; the new non-contiguous flag must not.
            return TranscriptAroundFetch(messages: page, oldestId: 1, hasMoreBefore: false, containsTarget: true)
        }

        let loaded = await chat.loadTranscriptAround(messageId: 5, radius: 4)
        XCTAssertTrue(loaded)
        XCTAssertFalse(chat.transcriptHasMoreBefore,
                       "precondition: hasMoreBefore alone cannot see the gap between around-window and tail")
        let assistant = try XCTUnwrap(chat.messages.first { $0.text == "a35" })

        await chat.retry(fromAssistantId: assistant.id)

        let nonContiguousFetchCount = await recorder.fetchCount
        XCTAssertEqual(nonContiguousFetchCount, 1,
                       "retry must force a full load for non-contiguous around+tail windows even when hasMoreBefore is false")
        let reloadedUser = try XCTUnwrap(chat.messages.first { $0.text == "u35" })
        XCTAssertEqual(chat.userOrdinals[reloadedUser.id], 35)
        XCTAssertFalse(chat.transcriptHasMoreBefore)
        XCTAssertEqual(chat.messages.map(\.text).prefix(4), ["u0", "a0", "u1", "a1"])
    }
}

private actor FullLoadRecorder {
    private let rows: [StoredMessage]
    private(set) var fetchCount = 0

    init(rows: [StoredMessage]) {
        self.rows = rows
    }

    func fetch(_ sessionId: String) async throws -> [StoredMessage] {
        fetchCount += 1
        return rows
    }
}
