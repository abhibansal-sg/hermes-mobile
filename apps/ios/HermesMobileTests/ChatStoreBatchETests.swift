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

    /// A stored row carrying a stable wire `id` (ARCH37 Step 4) — the shape the
    /// patched gateway emits. `ts` lets a cache copy (older) and network copy share
    /// content while differing in count, exercising the in-place reconcile.
    private func storedMessage(role: String, text: String, wireId: Int, ts: Double = 1_700_000_000) -> StoredMessage {
        StoredMessage(json: .object([
            "role": .string(role),
            "content": .string(text),
            "id": .number(Double(wireId)),
            "timestamp": .number(ts),
        ]))!
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(120)) }

    // MARK: - 1. Open-on-newest (now handled natively by .defaultScrollAnchor(.bottom))
    //
    // The imperative seed-scroll gate (`seedScrollDecision`/`handleSeedScroll`) was
    // deleted with the phase-2 simplification. `.defaultScrollAnchor(.bottom)` +
    // per-session ScrollView identity (.id(activeStoredSessionId)) now give
    // open-on-newest natively. The three policy-gate unit tests below are retired:
    //
    //   testFreshOpenAlwaysLandsOnNewest      — deleted (no SeedScrollDecision)
    //   testSameSessionReseedAtBottomKeepsPinned — deleted
    //   testSameSessionReseedScrolledUpPreservesPosition — deleted
    //
    // The behavioural contract (open-on-newest, reader-not-yanked) is verified by
    // the harness matrix (long/asynclong/netlong/switchlong/iddrift/stream cases).

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
        // Deterministic drain: flush the 40ms coalescing buffer so the delta's
        // text lands and the placeholder row exists before we capture its id.
        #if DEBUG
        chat.drainFlushForTesting()
        #else
        await settle()
        #endif

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
        // Deterministic drain: await the foreign-complete backfill Task.
        #if DEBUG
        await chat.waitForPendingForeignBackfillForTesting()
        #else
        await settle()
        #endif

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
        // Deterministic drain: flush the delta buffer so the placeholder exists.
        #if DEBUG
        chat.drainFlushForTesting()
        #else
        await settle()
        #endif
        chat.handle(event: foreignFrame(
            type: "message.complete", runtime: foreignRuntime, stored: storedId,
            payload: ["text": "final", "status": "completed"]))
        // Deterministic drain: await the foreign-complete backfill Task (which
        // throws and surfaces the error, then clears the placeholder spinner).
        #if DEBUG
        await chat.waitForPendingForeignBackfillForTesting()
        #else
        await settle()
        #endif

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

    // MARK: - 4. ARCH37 Step 4 — stable wire identity reconcile

    /// THE keystone gate: a CACHE copy that is SHORTER than the NETWORK copy (count
    /// drift) reconciles IN PLACE on the rows whose content matches, with NO remount
    /// of the matching tail — because both copies carry the stable per-row wire `id`,
    /// so identity is keyed on the id, not the positional `{ts}-{index}-{role}`.
    /// With the OLD positional scheme the extra network rows would shift the indices
    /// and re-key every row from the divergence → mass remount.
    func testWireIdReconcileKeepsIdentityAcrossCountDrift() {
        let (chat, _) = makeStore()
        // Cache copy: 3 rows (older fetch), each with its stable wire id.
        let cache = [
            storedMessage(role: "user", text: "q1", wireId: 0),
            storedMessage(role: "assistant", text: "a1", wireId: 1),
            storedMessage(role: "user", text: "q2", wireId: 2),
        ]
        chat.seed(from: cache)
        let cacheIDs = chat.messages.map(\.id)
        XCTAssertEqual(chat.messages.map(\.text), ["q1", "a1", "q2"])

        // Network copy: the SAME 3 rows (identical wire ids) PLUS a new turn. The
        // first three rows MUST keep their identity (in-place), only the new rows
        // append — no tail remount despite the count growing.
        let network = cache + [
            storedMessage(role: "assistant", text: "a2", wireId: 3),
            storedMessage(role: "user", text: "q3", wireId: 4),
        ]
        chat.seed(from: network)

        XCTAssertEqual(Array(chat.messages.prefix(3)).map(\.id), cacheIDs,
                       "rows matched by stable wire id keep identity across count drift (no remount)")
        XCTAssertEqual(chat.messages.map(\.text), ["q1", "a1", "q2", "a2", "q3"])
    }

    /// The wire id makes identity INVARIANT to a positional shift: if a network
    /// fetch drops an early empty row (so later rows' POSITIONS change) but the
    /// surviving rows keep their wire ids, identity is preserved — the exact case
    /// the positional key got wrong (gateway compresses / drops empty-content rows).
    func testWireIdReconcileSurvivesPositionalShift() {
        let (chat, _) = makeStore()
        // Cache copy keyed on wire ids 10, 11, 12 (note: non-contiguous start to
        // prove identity does not depend on the array index).
        let cache = [
            storedMessage(role: "user", text: "hello", wireId: 10),
            storedMessage(role: "assistant", text: "world", wireId: 11),
        ]
        chat.seed(from: cache)
        let helloID = chat.messages.first { $0.text == "hello" }?.id
        let worldID = chat.messages.first { $0.text == "world" }?.id
        XCTAssertNotNil(helloID); XCTAssertNotNil(worldID)

        // Network copy PREPENDS an older row (id 9) — every cached row's array index
        // shifts by 1, but their wire ids are unchanged, so identity holds.
        let network = [
            storedMessage(role: "assistant", text: "earlier", wireId: 9),
        ] + cache
        chat.seed(from: network)

        XCTAssertEqual(chat.messages.first { $0.text == "hello" }?.id, helloID,
                       "wire-id identity survives a positional shift (index changed, id did not)")
        XCTAssertEqual(chat.messages.first { $0.text == "world" }?.id, worldID,
                       "wire-id identity survives a positional shift")
        XCTAssertEqual(chat.messages.map(\.text), ["earlier", "hello", "world"])
    }

    /// FALLBACK: rows WITHOUT a wire id (stock/old gateway) still key on the legacy
    /// positional `{ts}-{index}-{role}` — unchanged behavior, no regression.
    func testNoWireIdFallsBackToPositionalIdentity() {
        let (chat, _) = makeStore()
        let history = [
            storedMessage(role: "user", text: "hi"),       // no wire id
            storedMessage(role: "assistant", text: "yo"),  // no wire id
        ]
        chat.seed(from: history)
        let first = chat.messages.map(\.id)
        chat.seed(from: history)
        XCTAssertEqual(chat.messages.map(\.id), first,
                       "stock-gateway rows (no wire id) keep stable positional identity across reseed")
    }

    /// CACHE-WITHOUT-IDS vs NETWORK-WITH-IDS (the realistic interim): a cache copy
    /// written by a PRE-Step-4 build (no wire ids) reconciles against a network copy
    /// from the PATCHED gateway (with wire ids). The rows whose CONTENT matches must
    /// reconcile without churning their text — even though the identity key flips
    /// from positional to wire-id (a one-time re-key on the first patched fetch,
    /// after which both sides carry ids and stay in place). Asserts content integrity
    /// (no blink/duplication), which is the user-visible contract.
    func testCacheWithoutIdsReconcilesAgainstNetworkWithIds() {
        let (chat, _) = makeStore()
        // Cache copy (pre-Step-4): positional identity, no wire ids.
        let cache = [
            storedMessage(role: "user", text: "q1"),
            storedMessage(role: "assistant", text: "a1"),
        ]
        chat.seed(from: cache)
        XCTAssertEqual(chat.messages.map(\.text), ["q1", "a1"])

        // Network copy (patched gateway): same content, now WITH wire ids, plus a
        // new turn. Content must end up correct with no duplication.
        let network = [
            storedMessage(role: "user", text: "q1", wireId: 0),
            storedMessage(role: "assistant", text: "a1", wireId: 1),
            storedMessage(role: "user", text: "q2", wireId: 2),
        ]
        chat.seed(from: network)
        XCTAssertEqual(chat.messages.map(\.text), ["q1", "a1", "q2"],
                       "cache(no ids)->network(ids) reconciles to correct content, no duplication")
    }
}
