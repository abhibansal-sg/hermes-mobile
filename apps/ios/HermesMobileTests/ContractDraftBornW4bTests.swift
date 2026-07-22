import XCTest
import SwiftUI
import GRDB
@testable import HermesMobile

/// ROUND-4b — STORE-LEVEL contract tests for the **draft-born write-local-first
/// invariant** (`docs/INTERACTION-CONTRACT.md` §4 **I5 second half** + A4/A9/I20).
/// Same harness shape as `ContractReconcileW2dTests` (in-process fake relay
/// `RelaySessionCoordinatorTests.MockRelayTransport`, production decoders), plus
/// a REAL on-disk ``CacheStore`` so the force-close→reopen half exercises the
/// actual GRDB write path (`upsertSession` → `saveTranscript` →
/// ``MessageRowRecord/make``).
///
/// **The device bug (log-proven 2026-07-22):** the gateway created live runtime
/// id `684b5489` and durable stored id `20260722_140236_f61148`, but the relay
/// discarded the latter. iOS consequently cached the optimistic row under the
/// ephemeral runtime id while the drawer/relaunch used the durable id. The write
/// succeeded, yet every real open missed it. Simulator fixtures used one id for
/// both sides and could not reproduce the mismatch.
///
/// **The fix:** preserve both ids through the relay; stream on runtime, cache and
/// relaunch on stored; await the write-local-first seed; and use one relay
/// history read only when that cache genuinely misses.
///
/// The distinct-id regression is the device-shaped gap; the force-close case
/// proves the durable key survives a process boundary.
@MainActor
final class ContractDraftBornW4bTests: XCTestCase {

    private typealias MockRelayTransport = RelaySessionCoordinatorTests.MockRelayTransport

    private let relayURL = URL(string: "ws://127.0.0.1:9999/relay")!
    private let serverURL = "https://r4b.test:9443"
    private var cachePaths: [String] = []

    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(TransportPath.relay.rawValue, forKey: DefaultsKeys.transportPath)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: DefaultsKeys.transportPath)
        UserDefaults.standard.removeObject(forKey: DefaultsKeys.activeProfile)
        for path in cachePaths {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: path + "-wal")
            try? FileManager.default.removeItem(atPath: path + "-shm")
        }
        cachePaths.removeAll()
        super.tearDown()
    }

    // MARK: - Store graph (flag ON, mock relay, REAL disk cache)

    private struct Stores {
        let connection: ConnectionStore
        let sessions: SessionStore
        let chat: ChatStore
        let cache: CacheStore
        let transport: MockRelayTransport
        let coordinator: RelaySessionCoordinator
    }

    private func makeCache() throws -> CacheStore {
        let path = NSTemporaryDirectory() + "r4b-cache-\(UUID().uuidString).sqlite"
        cachePaths.append(path)
        return try CacheStore(testDB: DatabaseQueue(path: path))
    }

    /// Build one "process": a store graph on `cache` with a mock relay whose
    /// script answers every upstream; `snapshotFor` decides which sids an
    /// `open`/`resume` delivers a snapshot frame for (the real relay's RESUME
    /// answers the RPC WITHOUT a snapshot — `downstream.py` — so the created
    /// sid gets none by default; the force-close test models exactly that).
    private func makeStores(
        cache: CacheStore,
        createdSessionID: String,
        createdStoredSessionID: String? = nil,
        snapshotFor: @escaping @Sendable (String, String) -> Bool = { _, _ in false }
    ) async throws -> Stores {
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        chat.attach(connection: connection, sessions: sessions, attachments: AttachmentStore())
        sessions.attach(connection: connection, chat: chat)
        sessions.attachCache(cache)
        connection.serverURLString = serverURL

        let transport = MockRelayTransport(script: { upstream, relay in
            guard let id = upstream.id else { return }
            if upstream.method == "submit" {
                let sid = (upstream.params["session_id"] as? String) ?? createdSessionID
                var result: [String: JSONValue] = ["session_id": .string(sid)]
                if upstream.params["session_id"] == nil {
                    result["stored_session_id"] = .string(createdStoredSessionID ?? sid)
                }
                relay.deliverResult(id: id, result: .object(result))
                return
            }
            relay.deliverResult(id: id, result: .object(["ok": .bool(true)]))
            if upstream.method == "open" || upstream.method == "resume",
               let sid = upstream.params["session_id"] as? String,
               snapshotFor(upstream.method, sid) {
                relay.deliver(ContractDraftBornW4bTests.snapshotFrame(
                    sid: sid, seq: 1,
                    itemTexts: ContractDraftBornW4bTests.settledItems(sid: sid)))
            }
        })

        let coordinator = RelaySessionCoordinator(
            chatStore: chat,
            clientFactory: { RelayClient { _ in transport } }
        )
        try await coordinator.start(url: relayURL)
        connection.relayCoordinatorFactory = { coordinator }
        _ = connection.ensureRelayCoordinator()

        return Stores(connection: connection, sessions: sessions, chat: chat,
                      cache: cache, transport: transport, coordinator: coordinator)
    }

    // MARK: - Wire builders (same shapes as ContractReconcileW2dTests)

    private func summary(_ id: String) -> SessionSummary {
        SessionSummary(id: id, title: "Session \(id)", preview: nil, startedAt: nil,
                       messageCount: nil, source: nil, lastActive: nil, cwd: nil)
    }

    nonisolated private static func settledItems(sid: String, cmid: String? = nil,
                                     userText: String? = nil,
                                     assistantText: String? = nil) -> [String] {
        var userBody: [String: Any] = ["text": userText ?? "earlier question for \(sid)"]
        if let cmid { userBody["client_message_id"] = cmid }
        let user: [String: Any] = [
            "item_id": "\(sid)-u1", "type": "userMessage", "status": "completed",
            "ord": 1, "summary": "", "body": userBody,
        ]
        let assistant: [String: Any] = [
            "item_id": "\(sid)-a1", "type": "agentMessage", "status": "completed",
            "ord": 2, "summary": "",
            "body": ["text": assistantText ?? "settled answer from \(sid)"],
        ]
        return [user, assistant].map { item in
            String(decoding: (try? JSONSerialization.data(withJSONObject: item)) ?? Data(),
                   as: UTF8.self)
        }
    }

    nonisolated private static func snapshotFrame(sid: String, seq: Int, itemTexts: [String],
                                      turn: String = "t-snap") -> String {
        let items = itemTexts.compactMap { $0.data(using: .utf8) }
            .compactMap { try? JSONSerialization.jsonObject(with: $0) }
        let body: [String: Any] = ["items": items]
        let frame: [String: Any] = ["seq": seq, "sid": sid, "turn": turn,
                                    "kind": "snapshot", "body": body]
        return String(decoding: (try? JSONSerialization.data(withJSONObject: frame)) ?? Data(),
                      as: UTF8.self)
    }

    nonisolated private static func itemFrame(_ kind: String, sid: String, seq: Int, turn: String,
                                  itemID: String, type: String, status: String,
                                  ord: Int, body: [String: Any]) -> String {
        let frame: [String: Any] = [
            "seq": seq, "sid": sid, "turn": turn, "kind": kind,
            "body": ["item_id": itemID, "type": type, "status": status,
                     "ord": ord, "summary": "", "body": body],
        ]
        return String(decoding: (try? JSONSerialization.data(withJSONObject: frame)) ?? Data(),
                      as: UTF8.self)
    }

    nonisolated private static func turnFrame(_ kind: String, sid: String, seq: Int,
                                  turn: String, extraBody: [String: Any] = [:]) -> String {
        var body: [String: Any] = extraBody
        if kind == "turn.completed" {
            body["usage"] = [String: Any]()
            body["duration_s"] = 2.0
        }
        let frame: [String: Any] = ["seq": seq, "sid": sid, "turn": turn,
                                    "kind": kind, "body": body]
        return String(decoding: (try? JSONSerialization.data(withJSONObject: frame)) ?? Data(),
                      as: UTF8.self)
    }

    nonisolated private static func deltaFrame(sid: String, seq: Int, turn: String,
                                   itemID: String, appendText: String) -> String {
        let frame: [String: Any] = [
            "seq": seq, "sid": sid, "turn": turn, "kind": "item.delta",
            "body": ["item_id": itemID, "patch": ["text": appendText]],
        ]
        return String(decoding: (try? JSONSerialization.data(withJSONObject: frame)) ?? Data(),
                      as: UTF8.self)
    }

    private func waitUntil(
        _ condition: () -> Bool, timeout: TimeInterval = 3.0
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Async-condition variant (the ``CacheStore`` actor reads suspend).
    private func waitUntilAsync(
        _ condition: () async -> Bool, timeout: TimeInterval = 3.0
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) && Date() < deadline {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// The `client_message_id` the phone put on the wire at SUBMIT (the relay
    /// echoes it on the synthesized `userMessage` item — downstream.py:692).
    private func submittedCMID(_ s: Stores) -> String? {
        s.transport.upstreams().last { $0.method == "submit" }?
            .params["client_message_id"] as? String
    }

    private func identity(for sid: String) -> CacheIdentity {
        CacheIdentity(serverId: serverURL, profileId: "default", sessionId: sid)
    }

    // MARK: - 1. Draft-born paints its user row + reply from the store — no history fetch

    /// New-chat send: the relay CREATES the session; the store paints the user
    /// row + streamed reply from the per-session entry (live frames) with ZERO
    /// `history` RPCs; the created sid gets its one-shot OPEN (the R3 seed/bind
    /// edge the base wiring skipped — **RED on base: no `open` fires**); and the
    /// GRDB cache gains the session row + the user message row carrying the
    /// cmid (**RED on base: `loadTranscript` nil**) so the session is paintable
    /// from disk the instant the sid binds (write-local-first, I5 second half).
    func testDraftBorn_PaintsUserRowAndReply_FromStore_NoHistoryFetch() async throws {
        let cache = try makeCache()
        let sid = "r4b-created-1"
        let s = try await makeStores(cache: cache, createdSessionID: sid)

        s.sessions.startDraft()
        let accepted = await s.chat.send(text: "Simple greeting hello")
        XCTAssertTrue(accepted, "the relay submit must accept the draft send")

        // The optimistic echo painted ≤ this tick (local state, QA-2 A2).
        let echoID = s.chat.messages.first { $0.role == .user }?.id
        XCTAssertNotNil(echoID, "I8: the send paints the optimistic user echo")
        let cmid = submittedCMID(s)
        XCTAssertNotNil(cmid, "the submit carries the durable cmid on the wire")

        // The turn streams in (relay SUBMIT-synthesized userMessage carries the
        // SAME cmid — downstream.py:692 — so adoption is in-place).
        var userBody: [String: Any] = ["text": "Simple greeting hello"]
        if let cmid { userBody["client_message_id"] = cmid }
        s.transport.deliver(Self.turnFrame("turn.started", sid: sid, seq: 2, turn: "t1"))
        s.transport.deliver(Self.itemFrame(
            "item.completed", sid: sid, seq: 3, turn: "t1", itemID: "\(sid)-u1",
            type: "userMessage", status: "completed", ord: 1, body: userBody))
        s.transport.deliver(Self.itemFrame(
            "item.completed", sid: sid, seq: 4, turn: "t1", itemID: "\(sid)-a1",
            type: "agentMessage", status: "completed", ord: 2,
            body: ["text": "Hello! How can I help you today?"]))
        s.transport.deliver(Self.turnFrame("turn.completed", sid: sid, seq: 5, turn: "t1"))

        await waitUntil {
            s.chat.messages.contains { $0.relayProjected && $0.role == .assistant }
        }
        try? await Task.sleep(for: .milliseconds(150))   // room for a forbidden history read

        // Painted from the STORE — the user row + the reply, ONE user bubble
        // (the echo adopted IN PLACE by cmid — same row id, I8/G4).
        let userRows = s.chat.messages.filter { $0.role == .user }
        XCTAssertEqual(userRows.count, 1,
                       "I8: the stream's userMessage adopts the echo in place — one row")
        XCTAssertEqual(userRows.first?.id, echoID, "I8: in-place morph keeps the echo's row id")
        XCTAssertEqual(userRows.first?.text, "Simple greeting hello")
        XCTAssertTrue(
            s.chat.messages.contains {
                $0.relayProjected && $0.role == .assistant
                    && $0.text.contains("How can I help you today?")
            },
            "the reply paints from the session's entry (stream is the authority)")

        // I14 budget: live creation needs no transcript read. A later genuine
        // cold cache miss has its own exactly-once history fallback.
        let methods = s.transport.upstreams().map(\.method)
        XCTAssertEqual(methods.filter { $0 == "history" }.count, 0,
                       "I14: the draft-born session costs ZERO history fetches; got \(methods)")
        XCTAssertEqual(
            methods.filter { $0 == "open" || $0 == "resume" }.count, 0,
            "I14: creation needs no follow-up transcript read; got \(methods)")

        // WRITE-LOCAL-FIRST: the GRDB cache holds the session row + the user
        // message row, cmid intact. RED on base (nothing ever wrote them).
        await waitUntilAsync {
            ((try? await s.cache.hasTranscript(self.identity(for: sid))) ?? false) == true
        }
        let cached = try await s.cache.loadTranscript(identity(for: sid))
        XCTAssertEqual(cached?.count, 1,
                       "I5: landing the created session writes the user row to the GRDB cache")
        XCTAssertEqual(cached?.first?.role, "user")
        XCTAssertEqual(cached?.first?.text, "Simple greeting hello")
        XCTAssertEqual(cached?.first?.clientMessageID, cmid,
                       "I8: the cached row carries the send's cmid (reopen adoption identity)")
    }

    /// The stock gateway assigns a short live runtime id and a different durable
    /// stored id on create. The phone must stream on the former while every
    /// drawer/cache/relaunch identity uses the latter.
    func testDraftBorn_DistinctRuntimeAndStoredIDsStaySeparated() async throws {
        let cache = try makeCache()
        let runtimeID = "684b5489"
        let storedID = "20260722_140236_f61148"
        let s = try await makeStores(
            cache: cache,
            createdSessionID: runtimeID,
            createdStoredSessionID: storedID
        )

        s.sessions.startDraft()
        let accepted = await s.chat.send(text: "Identity split regression")
        XCTAssertTrue(accepted)

        XCTAssertEqual(s.sessions.activeRuntimeId, runtimeID)
        XCTAssertEqual(s.sessions.activeStoredId, storedID)
        XCTAssertEqual(s.coordinator.activeSessionID, runtimeID)
        XCTAssertEqual(s.coordinator.activeStoredSessionID, storedID)
        XCTAssertEqual(s.coordinator.outboxRuntimeID(forStored: storedID), runtimeID)

        let durableHasTranscript = try await cache.hasTranscript(identity(for: storedID))
        let runtimeHasTranscript = try await cache.hasTranscript(identity(for: runtimeID))
        XCTAssertTrue(durableHasTranscript)
        XCTAssertFalse(runtimeHasTranscript)

        s.transport.deliver(Self.itemFrame(
            "item.completed", sid: runtimeID, seq: 2, turn: "t-split",
            itemID: "\(runtimeID)-a1", type: "agentMessage", status: "completed",
            ord: 2, body: ["text": "Reply on the runtime stream"]
        ))
        await waitUntil {
            s.chat.messages.contains { $0.text.contains("Reply on the runtime stream") }
        }
        XCTAssertTrue(s.chat.messages.contains {
            $0.text.contains("Reply on the runtime stream")
        })
    }

    // MARK: - 2. Force-close immediately after the new-chat send → reopen paints from disk

    /// Kill the "process" right after the draft-born send, relaunch on the SAME
    /// cache file, open the created session: the transcript paints the user row
    /// FROM DISK with no history fetch (the relay `RESUME` answers WITHOUT a
    /// snapshot — exactly `downstream.py` — so the cache is the ONLY source).
    /// **RED on base (blank: the base tree wrote nothing to GRDB — the exact
    /// device symptom, cache-miss(reset) forever); GREEN after the fix.** A late
    /// resync snapshot (userMessage carrying the cmid + the reply) then
    /// reconciles to ONE user row — the cmid round-trip adopts the painted row
    /// in place (I3/I8 — no duplicate bubble after the stream heals).
    func testDraftBorn_ForceCloseSurvival_ReopenPaintsFromCache() async throws {
        let cache = try makeCache()
        let sid = "r4b-created-2"

        // --- Process 1: new-chat send, then "kill" (drop the graph). ---------
        let cmid: String?
        do {
            let s1 = try await makeStores(cache: cache, createdSessionID: sid)
            s1.sessions.startDraft()
            _ = await s1.chat.send(text: "Force close survival prompt")
            // The durable write landed before the kill (wait for disk truth).
            await waitUntilAsync {
                ((try? await s1.cache.hasTranscript(self.identity(for: sid))) ?? false) == true
            }
            let hasBeforeKill = (try? await s1.cache.hasTranscript(self.identity(for: sid))) == true
            XCTAssertTrue(hasBeforeKill,
                          "I5/I20: the cache row must survive the kill (written at create-land)")
            cmid = submittedCMID(s1)
        }

        // --- Process 2: relaunch on the same cache, open the created sid. ----
        // RESUME answers the RPC with NO snapshot (the real relay — the cache is
        // the sole paint source; the base tree wrote nothing ⇒ blank forever).
        let s2 = try await makeStores(cache: cache, createdSessionID: sid)
        s2.sessions.open(summary(sid))
        await s2.sessions.waitForPendingOpenForTesting()
        await waitUntil { !s2.chat.messages.isEmpty }
        try? await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(
            s2.chat.messages.filter({ $0.role == .user }).map(\.text),
            ["Force close survival prompt"],
            "I20/A9: force-close→reopen paints the user row FROM THE CACHE — the " +
            "base tree's blank (cache-miss(reset) forever) is the device bug")
        XCTAssertEqual(s2.transport.upstreams().filter { $0.method == "history" }.count, 0,
                       "I14: the reopen paints from disk — zero history fetches")

        // The stream heals behind the paint: a resync-style snapshot (the relay
        // store's replay) carries the userMessage WITH the cmid + the reply.
        // The painted row adopts IN PLACE — still exactly one user bubble.
        var userBody: [String: Any] = ["text": "Force close survival prompt"]
        if let cmid { userBody["client_message_id"] = cmid }
        let userItem: [String: Any] = [
            "item_id": "\(sid)-u1", "type": "userMessage", "status": "completed",
            "ord": 1, "summary": "", "body": userBody,
        ]
        let assistantItem: [String: Any] = [
            "item_id": "\(sid)-a1", "type": "agentMessage", "status": "completed",
            "ord": 2, "summary": "", "body": ["text": "Survived the kill, here I am."],
        ]
        let itemTexts = [userItem, assistantItem].map { item in
            String(decoding: (try? JSONSerialization.data(withJSONObject: item)) ?? Data(),
                   as: UTF8.self)
        }
        s2.transport.deliver(Self.snapshotFrame(sid: sid, seq: 9, itemTexts: itemTexts))
        await waitUntil {
            s2.chat.messages.contains { $0.relayProjected && $0.role == .assistant }
        }
        try? await Task.sleep(for: .milliseconds(120))

        let userRows = s2.chat.messages.filter { $0.role == .user }
        XCTAssertEqual(userRows.count, 1,
                       "I3/I8: the snapshot's userMessage adopts the cache-painted " +
                       "row in place (cmid round-trip) — no duplicate bubble")
        XCTAssertEqual(userRows.first?.text, "Force close survival prompt")
        XCTAssertTrue(s2.chat.messages.contains {
            $0.relayProjected && $0.text.contains("Survived the kill")
        }, "the reply reconciles over the cache paint (stream is the authority)")
    }

    // MARK: - 3. Existing session unaffected (regression guard)

    /// A send into an EXISTING session must not take the draft-born path: no
    /// create-land cache write (the `isDraft`/nil-pointer guard), the pinned
    /// target submits with its id (never nil), and the session keeps painting
    /// from its entry. Guards I5's existing-session half against the R4b write.
    func testExistingSession_SendDoesNotTakeDraftBornPath() async throws {
        let cache = try makeCache()
        let existing = "r4b-existing-1"
        // The existing session's resume DOES snapshot (a warm known session).
        let s = try await makeStores(
            cache: cache, createdSessionID: "UNUSED",
            snapshotFor: { _, sid in sid == existing })

        s.sessions.open(summary(existing))
        await s.sessions.waitForPendingOpenForTesting()
        await waitUntil {
            s.transport.upstreams().contains {
                $0.method == "resume" && ($0.params["session_id"] as? String) == existing
            }
        }
        await waitUntil { !s.chat.messages.isEmpty }

        let accepted = await s.chat.send(text: "Follow-up in the same chat")
        XCTAssertTrue(accepted)

        // Submit targeted the PINNED existing id (never nil — I5).
        let submit = s.transport.upstreams().last { $0.method == "submit" }
        XCTAssertEqual(submit?.params["session_id"] as? String, existing,
                       "I5: an existing-session send pins its target — never a nil create")

        // No draft-born cache write: the session has no GRDB transcript row
        // (nothing seeded it; the create-land writer must stay guarded off).
        try? await Task.sleep(for: .milliseconds(120))
        let cached = try await s.cache.loadTranscript(identity(for: existing))
        XCTAssertNil(cached,
                     "I5: the draft-born write-local-first seam is a NO-OP for an " +
                     "existing session (guard: isDraft/nil-pointer)")

        // And no create-adoption open fired for it (the send drove the warm
        // entry; the only transcript reads are the open's resume).
        XCTAssertEqual(s.transport.upstreams().filter { $0.method == "open" }.count, 0,
                       "no create-adoption open for an existing-session send")
        // The session still paints (resume snapshot rows present).
        XCTAssertFalse(s.chat.messages.isEmpty, "existing session keeps painting")
    }

    // MARK: - 4. New chat while the relay is mid-turn on ANOTHER session (I6 isolation)

    /// With session B mid-turn, a draft send creates A: A paints its own rows
    /// from its own entry; B's live frames keep folding into B's entry and NEVER
    /// leak into A's transcript (I6 structural isolation — the write-gate moved
    /// to A at adoption). The mid-turn relay state cannot blank the new chat.
    func testDraftBorn_RelayMidTurnOnOtherSession_NewChatIsolated() async throws {
        let cache = try makeCache()
        let a = "r4b-created-a"
        let b = "r4b-busy-b"
        let s = try await makeStores(cache: cache, createdSessionID: a)

        // Open B and start a turn on it (the real relay RESUME answers with NO
        // snapshot — B's entry seeds purely from its live frames).
        s.sessions.open(summary(b))
        await s.sessions.waitForPendingOpenForTesting()
        await waitUntil {
            s.transport.upstreams().contains {
                $0.method == "resume" && ($0.params["session_id"] as? String) == b
            }
        }
        s.transport.deliver(Self.turnFrame("turn.started", sid: b, seq: 2, turn: "tb"))
        s.transport.deliver(Self.itemFrame(
            "item.started", sid: b, seq: 3, turn: "tb", itemID: "\(b)-a1",
            type: "agentMessage", status: "in_progress", ord: 2, body: ["text": ""]))
        s.transport.deliver(Self.deltaFrame(
            sid: b, seq: 4, turn: "tb", itemID: "\(b)-a1",
            appendText: "B is still working on its turn"))
        await waitUntil { s.chat.messages.contains { $0.text.contains("B is still working") } }
        XCTAssertTrue(s.chat.messages.contains { $0.text.contains("B is still working") },
                      "precondition: B's live turn renders while B holds the write-gate")

        // New chat → send → relay creates A while B's turn is live.
        s.sessions.startDraft()
        _ = await s.chat.send(text: "Brand new chat while B is busy")
        await waitUntil { s.sessions.activeStoredId == a }
        let cmid = submittedCMID(s)

        // A's turn frames land (userMessage carries the cmid).
        var userBody: [String: Any] = ["text": "Brand new chat while B is busy"]
        if let cmid { userBody["client_message_id"] = cmid }
        s.transport.deliver(Self.turnFrame("turn.started", sid: a, seq: 5, turn: "ta"))
        s.transport.deliver(Self.itemFrame(
            "item.completed", sid: a, seq: 6, turn: "ta", itemID: "\(a)-u1",
            type: "userMessage", status: "completed", ord: 1, body: userBody))
        s.transport.deliver(Self.itemFrame(
            "item.completed", sid: a, seq: 7, turn: "ta", itemID: "\(a)-a1",
            type: "agentMessage", status: "completed", ord: 2,
            body: ["text": "A answers the brand new chat"]))
        s.transport.deliver(Self.turnFrame("turn.completed", sid: a, seq: 8, turn: "ta"))
        await waitUntil {
            s.chat.messages.contains { $0.relayProjected && $0.text.contains("A answers") }
        }
        // B keeps streaming in the background — its frame folds into B's entry.
        s.transport.deliver(Self.deltaFrame(
            sid: b, seq: 9, turn: "tb", itemID: "\(b)-a1", appendText: ", more bytes"))
        try? await Task.sleep(for: .milliseconds(120))

        // A's transcript shows A's rows ONLY — B's live turn never leaks in (I6).
        let allText = s.chat.messages.map(\.text).joined(separator: "\n")
        XCTAssertTrue(allText.contains("Brand new chat while B is busy"))
        XCTAssertTrue(allText.contains("A answers the brand new chat"))
        XCTAssertFalse(allText.contains("B is still working"),
                       "I6: B's mid-turn frames must not project into the new chat")
        // …but B's entry DID fold them (zero-refetch switch-back, I14).
        let bItems = s.coordinator.store(forSession: b)?.items ?? []
        XCTAssertTrue(bItems.contains { $0.textBody.contains("more bytes") },
                      "I2/I14: B's background entry keeps folding its own frames")
        // And A's write-local-first cache row landed despite the concurrent turn.
        let cached = try await s.cache.loadTranscript(identity(for: a))
        XCTAssertEqual(cached?.first?.text, "Brand new chat while B is busy",
                       "I5: the write-local-first seed lands even mid-turn elsewhere")
    }
}
