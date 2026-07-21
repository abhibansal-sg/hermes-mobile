import XCTest
import SwiftUI
@testable import HermesMobile

/// ROUND-4 W2d — STORE-LEVEL contract tests for **R3, the single reconcile
/// owner** (`docs/INTERACTION-CONTRACT.md` §4: **I3, I14, and the RPC-cancel
/// half of I4**; the plan's W2d exit gate). Extends the `tests/render_conformance`
/// suite — never forks it: same in-process fake relay
/// (`RelaySessionCoordinatorTests.MockRelayTransport`), same store-graph shape
/// as `RelayDeepLinkResumeTests` / `ContractInvariantsW0aTests`, production
/// decoders end-to-end. The RPC-SPY is `transport.upstreams()` — every
/// phone→relay frame verbatim, the XCTest analogue of the W0b e2e cancel-spy
/// (`phone.cancelled`) that pins the relay half of these same invariants.
///
/// **Budget unit (I14):** a "transcript read" is an `open` / `resume` /
/// `history` upstream — each costs the gateway exactly one REST read through
/// the relay (`downstream.py` OPEN/RESUME/HISTORY → `rest_history`). `resync`
/// is relay-LOCAL (ring replay / store snapshot — zero gateway hops, pinned by
/// the W0b I14 e2e scenario) and `foreground` / `ack` cost nothing.
///
/// **RED-on-base is the point (RR7):** the budget + cancel tests FAIL on
/// `r4/base` (the triple-fetch D6 + result-fencing-only supersession) — the
/// fail-before evidence is `hermes-tmp/evidence/round4/w2d-red-*.log`; the R3
/// rewire commits flip them green. The PIN tests guard already-correct
/// behavior (turn-end gap-fill silence, echo adoption) through the rewire.
@MainActor
final class ContractReconcileW2dTests: XCTestCase {

    private typealias MockRelayTransport = RelaySessionCoordinatorTests.MockRelayTransport

    private let relayURL = URL(string: "ws://127.0.0.1:9999/relay")!

    /// The I14 budget unit: upstream methods that cost the gateway a transcript
    /// REST read through the relay. Everything else (`resync`, `foreground`,
    /// `ack`, `submit`) is NOT a read.
    private static let transcriptReadMethods: Set<String> = ["open", "resume", "history"]

    // MARK: - Store graph (flag ON, mock transport, RPC-answering script)

    private struct Stores {
        let connection: ConnectionStore
        let sessions: SessionStore
        let chat: ChatStore
        let transport: MockRelayTransport
        let coordinator: RelaySessionCoordinator
    }

    /// Default fake-relay script: every upstream gets a result; `open`/`resume`
    /// additionally deliver the session's `snapshot` downstream (exactly what
    /// the real relay does — `downstream.py` answers the RPC AND emits the
    /// snapshot frame the render lane seeds from). `submit` echoes its target
    /// (or mints ``createdSessionID`` for a nil target).
    private func makeStores(
        snapshotItems: @escaping @Sendable (String) -> [String] =
            { ContractReconcileW2dTests.settledItems(sid: $0) },
        script: (@Sendable (MockRelayTransport.Upstream, MockRelayTransport) -> Void)? = nil
    ) async throws -> Stores {
        UserDefaults.standard.set(
            TransportPath.relay.rawValue, forKey: DefaultsKeys.transportPath)

        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        chat.attach(connection: connection, sessions: sessions, attachments: AttachmentStore())
        sessions.attach(connection: connection, chat: chat)

        let transport = MockRelayTransport(script: script ?? { upstream, relay in
            guard let id = upstream.id else { return }
            if upstream.method == "submit" {
                let sid = (upstream.params["session_id"] as? String) ?? "w2d-created-1"
                relay.deliverResult(id: id, result: .object(["session_id": .string(sid)]))
                return
            }
            relay.deliverResult(id: id, result: .object(["ok": .bool(true)]))
            if upstream.method == "open" || upstream.method == "resume",
               let sid = upstream.params["session_id"] as? String {
                relay.deliver(Self.snapshotFrame(
                    sid: sid, seq: 1, itemTexts: snapshotItems(sid)))
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
                      transport: transport, coordinator: coordinator)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: DefaultsKeys.transportPath)
        UserDefaults.standard.removeObject(forKey: DefaultsKeys.activeProfile)
        super.tearDown()
    }

    // MARK: - Wire builders (dense seqs, byte-stable by construction)

    private func summary(_ id: String) -> SessionSummary {
        SessionSummary(id: id, title: "Session \(id)", preview: nil, startedAt: nil,
                       messageCount: nil, source: nil, lastActive: nil, cwd: nil)
    }

    /// One settled turn's items as raw item-JSON dicts: a `userMessage` (carrying
    /// `client_message_id` when given, for echo-adoption asserts) + an assistant
    /// text item — the shape `ChatItem(json:)` decodes.
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
            "item_id": "\(sid)-a1", "type": "assistantMessage", "status": "completed",
            "ord": 2, "summary": "",
            "body": ["text": assistantText ?? "settled answer from \(sid)"],
        ]
        return [user, assistant].map { item in
            String(decoding: (try? JSONSerialization.data(withJSONObject: item)) ?? Data(),
                   as: UTF8.self)
        }
    }

    /// A downstream `snapshot` frame carrying full item dicts (body =
    /// `{items:[…], cursor}` — `RelaySnapshot` decode shape).
    nonisolated private static func snapshotFrame(sid: String, seq: Int, itemTexts: [String],
                                      cursor: Int? = nil) -> String {
        let items = itemTexts.compactMap { $0.data(using: .utf8) }
            .compactMap { try? JSONSerialization.jsonObject(with: $0) }
        var body: [String: Any] = ["items": items]
        if let cursor { body["cursor"] = cursor }
        let frame: [String: Any] = ["seq": seq, "sid": sid, "kind": "snapshot", "body": body]
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

    // MARK: - RPC-spy helpers

    /// Transcript reads (the I14 budget unit) observed on the wire, optionally
    /// since a baseline upstream count and/or for one session id.
    private func transcriptReads(
        _ s: Stores, since baseline: Int = 0, sid: String? = nil
    ) -> [MockRelayTransport.Upstream] {
        let all = s.transport.upstreams().dropFirst(baseline)
        return all.filter { up in
            guard Self.transcriptReadMethods.contains(up.method) else { return false }
            guard let sid else { return true }
            return (up.params["session_id"] as? String) == sid
        }
    }

    private func methods(_ s: Stores, since baseline: Int = 0) -> [String] {
        s.transport.upstreams().dropFirst(baseline).map(\.method)
    }

    private func waitUntil(
        _ condition: @escaping () -> Bool, timeout: TimeInterval = 3.0
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - I14 — reconcile budget

    /// Cold open costs paint + ≤1 snapshot (contract A1 budget). Today's relay
    /// cold open is a TRIPLE-FETCH (D6): the `resume` RPC (snapshot) PLUS the
    /// phase-2 network seed's `history` RPC — two gateway REST reads for one
    /// open. R3 deletes the phase-2 relay branch: the resume/open snapshot IS
    /// the seed. **RED on base (2 reads); GREEN after R3 (1).**
    func testI14_ColdOpenRelay_CostsExactlyOneTranscriptRead() async throws {
        let s = try await makeStores()
        s.sessions.open(summary("w2d-i14-cold"))
        await s.sessions.waitForPendingOpenForTesting()
        await waitUntil { !self.transcriptReads(s, sid: "w2d-i14-cold").isEmpty }
        // Settle window for any (forbidden) second read to land.
        try? await Task.sleep(for: .milliseconds(150))

        let reads = self.transcriptReads(s, sid: "w2d-i14-cold")
        XCTAssertEqual(
            reads.count, 1,
            "I14/A1: a relay cold open must cost exactly ONE transcript read " +
            "(paint + ≤1 snapshot); got \(reads.map(\.method)) — the phase-2 " +
            "network seed's history RPC is the double-fetch R3 deletes")
        // The snapshot seeded the transcript (the stream is the authority — the
        // deleted phase-2 fetch is not what painted these rows).
        XCTAssertFalse(s.chat.messages.isEmpty,
                       "I14/I3: the resume/open snapshot alone must seed the transcript")
    }

    /// Tapping the ALREADY-ACTIVE session is a cheap re-focus: zero RPCs
    /// (contract A12). Today every tap re-runs `resume` + the phase-2 `history`
    /// fetch. **RED on base; GREEN after R3 (warm rebind = foreground-only).**
    func testI14_TapActiveSession_CostsZeroRPCs() async throws {
        let s = try await makeStores()
        s.sessions.open(summary("w2d-i14-active"))
        await s.sessions.waitForPendingOpenForTesting()
        await waitUntil { s.transport.upstreams().contains { $0.method == "resume" } }
        try? await Task.sleep(for: .milliseconds(100))

        let baseline = s.transport.upstreams().count
        s.sessions.open(summary("w2d-i14-active"))        // re-tap the active row
        await s.sessions.waitForPendingOpenForTesting()
        try? await Task.sleep(for: .milliseconds(150))    // room for forbidden RPCs

        let reads = self.transcriptReads(s, since: baseline, sid: "w2d-i14-active")
        XCTAssertEqual(
            reads.count, 0,
            "I14/A12: re-opening the already-active session must cost ZERO " +
            "transcript RPCs; got \(reads.map(\.method))")
    }

    /// Warm switch-back budget: 0–1 reads (contract I14 assert). The phase-2
    /// `history` half of the old double-fetch is gone after R3; the lone
    /// rebind `resume` stays until R1's per-session entry map makes switch-back
    /// a pure re-projection (zero). **RED on base (2); GREEN after R3 (≤1).**
    func testI14_WarmSwitchBack_CostsAtMostOneRead() async throws {
        let s = try await makeStores()
        s.sessions.open(summary("w2d-i14-a"))
        await s.sessions.waitForPendingOpenForTesting()
        s.sessions.open(summary("w2d-i14-b"))
        await s.sessions.waitForPendingOpenForTesting()
        await waitUntil { s.transport.upstreams().filter { $0.method == "resume" }.count >= 2 }
        try? await Task.sleep(for: .milliseconds(100))

        let baseline = s.transport.upstreams().count
        s.sessions.open(summary("w2d-i14-a"))             // switch BACK to A
        await s.sessions.waitForPendingOpenForTesting()
        try? await Task.sleep(for: .milliseconds(150))

        let reads = self.transcriptReads(s, since: baseline, sid: "w2d-i14-a")
        XCTAssertLessThanOrEqual(
            reads.count, 1,
            "I14: a warm switch-back costs ≤1 transcript read after R3 " +
            "(zero once R1's entry map lands); got \(reads.map(\.method))")
    }

    /// PIN: a turn end WITH a streamed payload costs zero gap-fills (desktop
    /// `shouldHydrate` is false — the stream delivered the turn). Green on base
    /// (the relay path has no complete-time refetch) and must STAY green through
    /// the R3 rewire — the e2e I14 scenario pins the same property on the wire.
    func testI14_TurnEndWithStreamedPayload_CostsZeroGapFillReads() async throws {
        let s = try await makeStores()
        let sid = "w2d-i14-turn"
        s.sessions.open(summary(sid))
        await s.sessions.waitForPendingOpenForTesting()
        await waitUntil { s.transport.upstreams().contains { $0.method == "resume" } }
        try? await Task.sleep(for: .milliseconds(80))
        let baseline = s.transport.upstreams().count

        // A live turn that streams its payload, then settles.
        s.transport.deliver(Self.turnFrame("turn.started", sid: sid, seq: 2, turn: "t1"))
        s.transport.deliver(Self.itemFrame(
            "item.completed", sid: sid, seq: 3, turn: "t1", itemID: "\(sid)-u2",
            type: "userMessage", status: "completed", ord: 3,
            body: ["text": "streamed question"]))
        s.transport.deliver(Self.itemFrame(
            "item.completed", sid: sid, seq: 4, turn: "t1", itemID: "\(sid)-a2",
            type: "assistantMessage", status: "completed", ord: 4,
            body: ["text": "streamed answer"]))
        s.transport.deliver(Self.turnFrame("turn.completed", sid: sid, seq: 5, turn: "t1"))
        try? await Task.sleep(for: .milliseconds(200))    // room for a forbidden gap-fill

        let reads = self.transcriptReads(s, since: baseline)
        XCTAssertEqual(
            reads.count, 0,
            "I14: a turn end with a streamed payload must cost ZERO gap-fill " +
            "reads; got \(reads.map(\.method))")
    }

    /// The gap-fill-once rule (contract I14 + §1.3): a turn end where the stream
    /// delivered NO payload gets exactly ONE reconcile — and on relay that is a
    /// relay-LOCAL `resync{last_seq}` (ring replay / store snapshot; zero gateway
    /// hops), never a transcript read. **RED on base (nothing fires); GREEN
    /// after R3.**
    func testI14_TurnEndWithEmptyStream_FiresOneRelayLocalResync() async throws {
        let s = try await makeStores()
        let sid = "w2d-i14-empty"
        s.sessions.open(summary(sid))
        await s.sessions.waitForPendingOpenForTesting()
        await waitUntil { s.transport.upstreams().contains { $0.method == "resume" } }
        try? await Task.sleep(for: .milliseconds(80))
        let baseline = s.transport.upstreams().count

        // A turn that starts and completes with NO items between (the stream
        // delivered nothing — the gap-fill-once trigger).
        s.transport.deliver(Self.turnFrame("turn.started", sid: sid, seq: 2, turn: "t-empty"))
        s.transport.deliver(Self.turnFrame("turn.completed", sid: sid, seq: 3, turn: "t-empty"))
        await waitUntil { self.methods(s, since: baseline).contains("resync") }
        try? await Task.sleep(for: .milliseconds(150))    // room for a second (forbidden) fire

        let after = self.methods(s, since: baseline)
        let resyncs = after.filter { $0 == "resync" }.count
        XCTAssertEqual(
            resyncs, 1,
            "I14: a payload-less turn end must fire exactly ONE resync " +
            "(gap-fill-once); got \(resyncs) in \(after)")
        XCTAssertEqual(
            self.transcriptReads(s, since: baseline).count, 0,
            "I14: the gap-fill-once reconcile must be relay-local (resync), " +
            "never a transcript read")
    }

    // MARK: - I4 — superseded open is RPC-CANCELLED, not merely result-fenced

    /// open(A) fires, open(B) one tick later: A's in-flight `resume` must be
    /// RPC-CANCELLED (the iOS half of the W0b e2e cancel-spy — the phone driver's
    /// `cancel_call` mirrors `URLSessionTask.cancel()`/Task cancellation on the
    /// iOS RelayClient). A's request crossed the wire (the relay is stateless)
    /// but its late answer is observed-and-discarded, never applied; B binds.
    /// **RED on base (openToken fences the RESULT only — the RPC runs to
    /// completion); GREEN after R3 (the superseded Task is cancelled at the
    /// intent tick, pre-await).**
    func testI4_SupersededOpen_IsRPCCancelled_NotResultFenced() async throws {
        /// Lock-protected holder for A's withheld resume answer.
        final class HeldAnswer: @unchecked Sendable {
            private let lock = NSLock()
            private var answer: ((String) -> Void)?
            private var rid: String?
            func hold(_ id: String, answering: @escaping (String) -> Void) {
                lock.lock(); defer { lock.unlock() }
                rid = id; answer = answering
            }
            func release() {
                lock.lock()
                let (pendingID, pendingAnswer) = (rid, answer)
                rid = nil; answer = nil
                lock.unlock()
                if let pendingID, let pendingAnswer { pendingAnswer(pendingID) }
            }
        }
        let held = HeldAnswer()

        let s = try await makeStores(script: { upstream, relay in
            guard let id = upstream.id else { return }
            if upstream.method == "resume",
               (upstream.params["session_id"] as? String) == "w2d-i4-a" {
                // Withhold A's answer until the test releases it — the cancel
                // must land while the RPC is genuinely in flight.
                held.hold(id) { rid in
                    relay.deliverResult(id: rid, result: .object(["ok": .bool(true)]))
                }
                return
            }
            relay.deliverResult(id: id, result: .object(["ok": .bool(true)]))
            if upstream.method == "resume" || upstream.method == "open",
               let sid = upstream.params["session_id"] as? String {
                relay.deliver(ContractReconcileW2dTests.snapshotFrame(
                    sid: sid, seq: 1,
                    itemTexts: ContractReconcileW2dTests.settledItems(sid: sid)))
            }
        })

        // Fire open(A); its resume suspends on the withheld answer.
        s.sessions.open(summary("w2d-i4-a"))
        await waitUntil {
            s.transport.upstreams().contains {
                $0.method == "resume" && ($0.params["session_id"] as? String) == "w2d-i4-a"
            }
        }

        // One tick later, open(B) SUPERSEDES — the contract bumps the epoch
        // synchronously at intent and RPC-cancels A's in-flight resume.
        s.sessions.open(summary("w2d-i4-b"))
        #if DEBUG
        await waitUntil { s.sessions.supersededRelayRPCCancellations >= 1 }
        XCTAssertGreaterThanOrEqual(
            s.sessions.supersededRelayRPCCancellations, 1,
            "I4: the superseded open's in-flight resume must be RPC-cancelled " +
            "(Task cancellation → CancellationError), not merely result-fenced " +
            "after completion")
        #endif

        // Let B's resume answer + snapshot land and bind.
        await s.sessions.waitForPendingOpenForTesting()
        await waitUntil { s.sessions.activeRuntimeId == "w2d-i4-b" }
        XCTAssertEqual(s.sessions.activeRuntimeId, "w2d-i4-b",
                       "I4: B's resume must bind the runtime")

        // A's late answer now crosses the wire — observed-and-discarded: the
        // pending continuation is GONE (cancelled), so it must NOT bind A and
        // must NOT surface an error.
        held.release()
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(s.sessions.activeRuntimeId, "w2d-i4-b",
                       "I4: A's late resume answer must be discarded, never applied")
        XCTAssertNil(s.sessions.sessionActionError,
                     "I17: no alert for the superseded op")
        // The cancel-spy observed A's request on the wire (it was away before
        // the cancel — the relay is stateless) — cancelled, not unsent.
        XCTAssertTrue(
            s.transport.upstreams().contains {
                $0.method == "resume" && ($0.params["session_id"] as? String) == "w2d-i4-a"
            },
            "I4: A's resume crossed the wire before the cancel (observed-and-discarded)")
    }

    // MARK: - I3 — cache is seed, stream is authority

    /// Cache paint is the synchronous seed; the relay stream (the resume/open
    /// snapshot) is the SOLE authority that supersedes it — by item-id union,
    /// never by a second fetch. The optimistic user echo (a painted, untagged
    /// row carrying the outbox cmid) is adopted IN PLACE by the snapshot's
    /// `userMessage` item (one bubble, the echo's row id) — and no `history`
    /// RPC races the snapshot (the phase-2 double-fetch R3 deletes). The
    /// adoption half PINS the existing cmid machinery through the rewire; the
    /// read-count half is **RED on base, GREEN after R3**.
    func testI3_CachePaintIsSeed_StreamIsAuthority_EchoAdoptsInPlace() async throws {
        let s = try await makeStores(
            snapshotItems: { Self.settledItems(sid: $0, cmid: "w2d-i3-cmid",
                                               userText: "the question") })

        // Phase-1 cache paint (untagged rows — exactly what the GRDB seed
        // paints before any relay frame lands): the optimistic echo + a
        // settled tail row.
        let echo = ChatMessage(
            id: ChatMessage.deterministicID(seedKey: "w2d-i3-echo"),
            role: .user, clientMessageID: "w2d-i3-cmid",
            parts: [.text(id: "echo-text", text: "the question")],
            isStreaming: false, interrupted: false, relayProjected: false)
        let tail = ChatMessage(
            id: ChatMessage.deterministicID(seedKey: "w2d-i3-tail"),
            role: .assistant,
            parts: [.text(id: "tail-text", text: "settled tail from cache")],
            isStreaming: false, interrupted: false, relayProjected: false)
        s.chat.seed(normalized: [tail, echo])
        XCTAssertEqual(s.chat.messages.count, 2)
        let echoID = echo.id
        // Production-faithful drive (integration fix): a cache paint is one
        // the STORE records — every paint the store drives stamps the
        // `transcriptPaintedStoredId` provenance, and open()'s phase-1 keys
        // HIT/miss off it. A direct `chat.seed` bypasses that, so register
        // the warm snapshot exactly as the disk-HIT path does; otherwise
        // open()'s cache-MISS reset wipes the paint before the snapshot
        // arrives — a paint+miss state that never co-exists in production
        // (paint only ever comes from a HIT) and that defeats the in-place
        // adoption this test pins (I3/I8).
        s.sessions.rememberWarmOpenSnapshot([tail, echo], for: "w2d-i3-open")

        // Open: the resume snapshot (carrying the same cmid) is the sole
        // authoritative seed — no history RPC may race it.
        s.sessions.open(summary("w2d-i3-open"))
        await s.sessions.waitForPendingOpenForTesting()
        await waitUntil {
            s.chat.messages.contains { $0.relayProjected && $0.role == .assistant }
        }
        try? await Task.sleep(for: .milliseconds(150))    // room for a forbidden history read

        // The echo morphed IN PLACE (same row id — never removed-and-re-presented,
        // never duplicated): one user row carries the cmid.
        let userRows = s.chat.messages.filter {
            $0.role == .user && $0.clientMessageID == "w2d-i3-cmid"
        }
        XCTAssertEqual(userRows.count, 1,
                       "I3/I8: the snapshot's userMessage must adopt the echo in place — one row")
        XCTAssertEqual(userRows.first?.id, echoID,
                       "I8: adoption keeps the echo's row id (in-place morph)")

        // The stream's content won (store is authority over the paint)…
        XCTAssertTrue(
            s.chat.messages.contains { $0.relayProjected && $0.role == .assistant },
            "I3: the snapshot's rows must project (the stream is the authority)")
        // …and NO transcript read raced the snapshot — the paint's sole
        // successor is the stream, never a second fetch.
        let reads = self.transcriptReads(s, sid: "w2d-i3-open")
            .filter { $0.method == "history" }
        XCTAssertEqual(
            reads.count, 0,
            "I3/I14: the cache paint is superseded by the STREAM only — the " +
            "phase-2 history fetch is the double-fetch R3 deletes; got \(reads.count)")
    }
}
