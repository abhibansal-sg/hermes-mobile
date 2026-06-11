import XCTest
@testable import HermesMobile

/// ABH-87 Batch E — reconcile/scroll.
///
/// Two surfaces:
///  1. SCROLL P0 — the seed-scroll policy gate (`ChatView.seedScrollDecision`):
///     a FRESH session OPEN always lands on the newest message; a SAME-session
///     reseed (backfill / mirror reconcile / foreground refresh) only auto-scrolls
///     if the reader was already at the bottom (§3.6 / D13 — never yank a reader
///     scrolled up reading history).
///  2. §3.7 FOREIGN-MIRROR IN-PLACE RECONCILE (D9) — a desktop-driven (foreign)
///     turn must reconcile IN PLACE: the placeholder is NOT removed-then-async-
///     backfilled (which made the mirrored reply blink out and pop back restacked).
///     The finalized reply adopts the placeholder's identity + slot, so the row
///     count does not churn and the bubble keeps its SwiftUI identity.
///  3. SAME-session reseed identity preservation — a backfill of an unchanged
///     transcript keeps every row's id (no restack under a reader).
@MainActor
final class ChatStoreBatchETests: XCTestCase {

    private let activeRuntime = "rt-local-e"
    private let foreignRuntime = "rt-foreign-e"
    private let storedId = "stored-session-e"

    private func makeStore(
        backfill: @escaping (String) async throws -> [StoredMessage] = { _ in [] }
    ) -> (ChatStore, SessionStore) {
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        let attachments = AttachmentStore()
        chat.attach(connection: connection, sessions: sessions, attachments: attachments)
        sessions.attach(connection: connection, chat: chat)
        sessions.activeRuntimeId = activeRuntime
        sessions.activeStoredId = storedId
        chat.backfillFetch = backfill
        return (chat, sessions)
    }

    private func foreignFrame(
        type: String, runtime: String, stored: String, payload: JSONValue = .null
    ) -> GatewayEvent {
        GatewayEvent(params: .object([
            "type": .string(type),
            "session_id": .string(runtime),
            "stored_session_id": .string(stored),
            "payload": payload,
        ]))!
    }

    private func storedMessage(role: String, text: String) -> StoredMessage {
        StoredMessage(json: .object([
            "role": .string(role),
            "content": .string(text),
        ]))!
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(120)) }

    // MARK: - 1. SCROLL P0 — seed-scroll policy gate

    /// A FRESH session OPEN always lands on the newest message, regardless of the
    /// PREVIOUS session's scroll position. This is the open-on-newest acceptance:
    /// opening a long session must NOT land mid-conversation or blank.
    func testFreshOpenAlwaysLandsOnNewest() {
        // No prior session (first open).
        XCTAssertEqual(
            ChatView.seedScrollDecision(seededSession: "A", lastSeededSession: nil, atBottom: true),
            .landOnNewest)
        // Even if the (previous) reader was scrolled UP, opening a DIFFERENT
        // session lands on its newest message — the scroll state belonged to the
        // session we navigated away from.
        XCTAssertEqual(
            ChatView.seedScrollDecision(seededSession: "B", lastSeededSession: "A", atBottom: false),
            .landOnNewest)
    }

    /// A SAME-session reseed while the reader is at the bottom keeps them pinned to
    /// the newest message (a backfill/mirror reconcile of the live tail).
    func testSameSessionReseedAtBottomKeepsPinned() {
        XCTAssertEqual(
            ChatView.seedScrollDecision(seededSession: "A", lastSeededSession: "A", atBottom: true),
            .keepPinned)
    }

    /// §3.6 / D13 — a SAME-session reseed while the reader scrolled UP must NOT
    /// yank them to the bottom. The reconnect/foreground/mirror backfill preserves
    /// the reader's position.
    func testSameSessionReseedScrolledUpPreservesPosition() {
        XCTAssertEqual(
            ChatView.seedScrollDecision(seededSession: "A", lastSeededSession: "A", atBottom: false),
            .preserveReaderPosition)
    }

    // MARK: - 2. §3.7 foreign-mirror in-place reconcile (D9)

    /// The headline §3.7 gate: a foreign turn completes and reconciles via the
    /// REST seed. The placeholder is NOT removed first — the finalized reply adopts
    /// its identity, so the assistant ROW COUNT does not churn and the bubble keeps
    /// its SwiftUI id (no blink-out, no restack).
    func testForeignMirrorReconcilesInPlaceWithoutCountChurn() async {
        let (chat, _) = makeStore { _ in
            [
                self.storedMessage(role: "user", text: "ping from desktop"),
                self.storedMessage(role: "assistant", text: "MIRRORTEST reply"),
            ]
        }

        // Adopt the foreign turn + stream a delta so the placeholder assistant row
        // exists and renders live.
        chat.handle(event: foreignFrame(
            type: "message.start", runtime: foreignRuntime, stored: storedId,
            payload: ["role": "assistant"]))
        chat.handle(event: foreignFrame(
            type: "message.delta", runtime: foreignRuntime, stored: storedId,
            payload: ["text": "MIRR"]))
        await settle()

        // The live placeholder is the trailing assistant row; capture its identity.
        guard let placeholder = chat.messages.last(where: { $0.role == .assistant }) else {
            return XCTFail("a foreign placeholder assistant row must exist while streaming")
        }
        let placeholderID = placeholder.id

        // The foreign turn completes → in-place reconcile (teardown preserves the
        // placeholder; the seed adopts its slot).
        chat.handle(event: foreignFrame(
            type: "message.complete", runtime: foreignRuntime, stored: storedId,
            payload: ["text": "MIRRORTEST reply", "status": "completed"]))
        await settle()

        XCTAssertFalse(chat.isStreaming, "streaming clears after the mirror reconciles")
        // The reconciled assistant reply kept the placeholder's identity (in-place
        // reconcile — no remove + re-add). This is what kills the blink/restack.
        guard let reconciled = chat.messages.last(where: { $0.role == .assistant }) else {
            return XCTFail("the reconciled assistant reply must be present")
        }
        XCTAssertEqual(reconciled.id, placeholderID,
                       "the finalized reply must adopt the placeholder's identity (no restack)")
        XCTAssertTrue(reconciled.text.contains("MIRRORTEST reply"),
                      "the reconciled reply carries the authoritative final text")
        XCTAssertFalse(reconciled.isStreaming, "the reconciled reply is settled")
        // Exactly one user + one assistant — the user prompt reconciled from REST,
        // the reply adopted the placeholder. No duplicate/blank rows.
        XCTAssertEqual(chat.messages.filter { $0.role == .assistant }.count, 1)
        XCTAssertEqual(chat.messages.filter { $0.role == .user }.count, 1)
    }

    /// A foreign complete whose reconcile FAILS (REST error) must not strand a
    /// spinning placeholder: the preserved row's own `isStreaming` is cleared, and
    /// the failure surfaces on `lastBackfillError`.
    func testForeignMirrorReconcileFailureClearsPlaceholderSpinner() async {
        struct ProbeError: LocalizedError { var errorDescription: String? { "REST 503" } }
        let (chat, _) = makeStore { _ in throw ProbeError() }

        chat.handle(event: foreignFrame(
            type: "message.start", runtime: foreignRuntime, stored: storedId,
            payload: ["role": "assistant"]))
        chat.handle(event: foreignFrame(
            type: "message.delta", runtime: foreignRuntime, stored: storedId,
            payload: ["text": "partial"]))
        await settle()
        chat.handle(event: foreignFrame(
            type: "message.complete", runtime: foreignRuntime, stored: storedId,
            payload: ["text": "final", "status": "completed"]))
        await settle()

        XCTAssertFalse(chat.isStreaming, "store streaming flag clears on teardown")
        XCTAssertEqual(chat.lastBackfillError, "REST 503", "the reconcile failure surfaces")
        // The preserved placeholder must not render a spinner forever.
        for message in chat.messages where message.role == .assistant {
            XCTAssertFalse(message.isStreaming,
                           "a preserved placeholder must not spin forever after a failed reconcile")
        }
    }

    // MARK: - 3. Same-session reseed identity preservation

    /// A backfill of an UNCHANGED transcript keeps every row's id, so SwiftUI does
    /// not remount the rows under a reader (the restack §3.6 calls out). Two seeds
    /// of the same deterministic history must yield the same message ids.
    func testReseedPreservesRowIdentity() {
        let (chat, _) = makeStore()
        let history = [
            storedMessage(role: "user", text: "hello"),
            storedMessage(role: "assistant", text: "world"),
        ]
        chat.seed(from: history)
        let idsAfterFirst = chat.messages.map(\.id)

        chat.seed(from: history)
        let idsAfterSecond = chat.messages.map(\.id)

        XCTAssertEqual(idsAfterFirst, idsAfterSecond,
                       "reseeding identical history must preserve row identity (no restack)")
        XCTAssertEqual(chat.messages.map(\.text), ["hello", "world"])
    }

    /// A reseed that APPENDS a new turn keeps the existing rows' identity and only
    /// adds the new row (no wholesale remount of the history above it).
    func testReseedAppendingTurnKeepsExistingIdentity() {
        let (chat, _) = makeStore()
        let base = [
            storedMessage(role: "user", text: "q1"),
            storedMessage(role: "assistant", text: "a1"),
        ]
        chat.seed(from: base)
        let baseIDs = chat.messages.map(\.id)

        chat.seed(from: base + [
            storedMessage(role: "user", text: "q2"),
            storedMessage(role: "assistant", text: "a2"),
        ])

        // The first two rows kept their identity; two new rows were appended.
        XCTAssertEqual(Array(chat.messages.prefix(2)).map(\.id), baseIDs,
                       "existing rows keep identity across an appending reseed")
        XCTAssertEqual(chat.messages.map(\.text), ["q1", "a1", "q2", "a2"])
    }
}
