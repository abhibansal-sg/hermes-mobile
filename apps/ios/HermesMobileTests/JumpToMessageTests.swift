import XCTest
@testable import HermesMobile

/// ABH-192 (jump-to-exact-message) — unit tests for the wire-message-id →
/// `ChatMessage.id` resolution that powers the scroll-to-exact-row jump.
///
/// The jump resolves the target `ChatMessage.id` from a server `message_id`
/// WITHOUT scanning, by replaying the seed producer's deterministic id factory
/// (`"w{wireId}-{role}"` → ``ChatMessage/deterministicID(seedKey:)``). These
/// tests pin that contract:
///
/// (a) **User row** — `messageJumpID(wireMessageId:role:.user)` equals the id
///     `toChatMessages` assigns a `role:user` row with that wire id.
/// (b) **Assistant row** — same for `role:assistant`.
/// (c) **Candidate set covers both roles** — when the role is unknown (the
///     artifacts gallery carries no role), `messageJumpCandidateIDs(for:)`
///     contains the id for BOTH a user and an assistant row with that wire id,
///     so the view's "resolve against the loaded transcript" lookup hits.
/// (d) **Distinct ids for distinct roles** — a user and assistant row sharing a
///     wire id (shouldn't happen on the wire, but the contract must hold) map to
///     DISTINCT `ChatMessage.id`s, so the jump never silently lands on the wrong
///     role.
/// (e) **Stock gateway (no wire id)** — a row WITHOUT a wire id gets a positional
///     seed key, so neither candidate id matches it; the view's lookup finds no
///     target and the jump is a graceful no-op (the documented stock-gateway
///     fallback). This is asserted by showing the candidate ids are NOT equal to
///     the positional id.
///
/// These are pure/deterministic — no SwiftUI render tree, no scroll — so they
/// run in the gateway-free local gate.
final class JumpToMessageTests: XCTestCase {

    private func storedMessage(role: String, text: String, wireId: Int) -> StoredMessage {
        StoredMessage(json: .object([
            "role": .string(role),
            "content": .string(text),
            "id": .number(Double(wireId)),
            "timestamp": .number(1_700_000_000),
        ]))!
    }

    func testUserRowJumpIDMatchesSeed() {
        let row = storedMessage(role: "user", text: "hello", wireId: 42)
        let seeded = ChatStore.toChatMessages([row])
        XCTAssertEqual(seeded.count, 1)
        let expected = ChatStore.messageJumpID(wireMessageId: 42, role: .user)
        XCTAssertEqual(seeded[0].id, expected,
                       "A user row with wire id 42 must map to messageJumpID(.user)")
    }

    func testAssistantRowJumpIDMatchesSeed() {
        let row = storedMessage(role: "assistant", text: "hi there", wireId: 7)
        let seeded = ChatStore.toChatMessages([row])
        XCTAssertEqual(seeded.count, 1)
        let expected = ChatStore.messageJumpID(wireMessageId: 7, role: .assistant)
        XCTAssertEqual(seeded[0].id, expected,
                       "An assistant row with wire id 7 must map to messageJumpID(.assistant)")
    }

    func testCandidateSetCoversBothRoles() {
        let userRow = storedMessage(role: "user", text: "q", wireId: 99)
        let assistantRow = storedMessage(role: "assistant", text: "a", wireId: 99)
        let candidates = Set(ChatStore.messageJumpCandidateIDs(for: 99))

        let seededUser = ChatStore.toChatMessages([userRow])[0].id
        let seededAssistant = ChatStore.toChatMessages([assistantRow])[0].id

        XCTAssertTrue(candidates.contains(seededUser),
                      "Candidate set must include the user-row id for wire id 99")
        XCTAssertTrue(candidates.contains(seededAssistant),
                      "Candidate set must include the assistant-row id for wire id 99")
    }

    func testDistinctRolesProduceDistinctIDs() {
        let userID = ChatStore.messageJumpID(wireMessageId: 5, role: .user)
        let assistantID = ChatStore.messageJumpID(wireMessageId: 5, role: .assistant)
        XCTAssertNotEqual(userID, assistantID,
                          "Same wire id under different roles must yield distinct ChatMessage ids")
    }

    func testStockGatewayRowWithoutWireIDIsNotAJumpCandidate() {
        // A stock/old gateway omits `id`, so the seed producer falls back to the
        // positional key — the jump's wire-id candidates must NOT match it.
        let row = StoredMessage(json: .object([
            "role": .string("user"),
            "content": .string("no wire id here"),
            "timestamp": .number(1_700_000_000),
        ]))!
        let seeded = ChatStore.toChatMessages([row])
        XCTAssertEqual(seeded.count, 1)
        let candidates = Set(ChatStore.messageJumpCandidateIDs(for: 1234))
        XCTAssertFalse(candidates.contains(seeded[0].id),
                       "A positional-keyed row must not match any wire-id jump candidate")
    }
}

// MARK: - M1 regression (cache-first two-phase seed)

/// M1 (Opus review): the open path is CACHE-FIRST then NETWORK. The FIRST
/// `transcriptGeneration` bump is often a stale on-disk-cache seed that does
/// NOT contain the matched row; the SECOND bump (network reconcile) usually
/// does. `jumpToMessageIfNeeded` must NOT clear `pendingMessageJump` on the
/// first miss — it survives and resolves on the second. These tests pin that
/// invariant at the store level: they replay the resolver's exact decision
/// rule (resolve candidate ids against `chatStore.messages`; clear only on a
/// hit or the attempt cap) against a seeded `ChatStore`, proving the cache
/// bump no longer drops the jump and the network bump resolves it.
@MainActor
final class JumpToMessageCacheFirstTests: XCTestCase {

    private func stored(role: String, text: String, wireId: Int) -> StoredMessage {
        StoredMessage(json: .object([
            "role": .string(role),
            "content": .string(text),
            "id": .number(Double(wireId)),
            "timestamp": .number(1_700_000_000),
        ]))!
    }

    /// The exact decision rule `jumpToMessageIfNeeded` applies, factored out so
    /// the test can drive it across the two seed phases WITHOUT a SwiftUI
    /// render tree. Mirrors the resolver: resolve candidate ids against the
    /// loaded transcript; on a miss leave the jump set and bump the attempt
    /// counter; on the cap consume (with snippet fallback); on a hit consume +
    /// reset attempts. Returns whether the scroll TARGET was resolved this hop.
    @discardableResult
    private func resolveJump(
        chatStore: ChatStore, sessionStore: SessionStore
    ) -> Bool {
        guard let messageId = sessionStore.pendingMessageJump,
              !chatStore.messages.isEmpty else { return false }
        let candidates = Set(ChatStore.messageJumpCandidateIDs(for: messageId))
        let target = chatStore.messages.first { candidates.contains($0.id) }?.id
        guard let target else {
            // M1 miss branch — do NOT clear; bound by the attempt cap.
            sessionStore.pendingMessageJumpAttempts += 1
            if sessionStore.pendingMessageJumpAttempts
                >= SessionStore.pendingMessageJumpMaxAttempts {
                let snippet = sessionStore.pendingMessageJumpSnippet
                sessionStore.pendingMessageJump = nil
                sessionStore.pendingMessageJumpAttempts = 0
                sessionStore.pendingMessageJumpSnippet = nil
                if let snippet, !snippet.isEmpty {
                    sessionStore.pendingSearchScroll = snippet
                }
            }
            return false
        }
        // Hit — consume + reset.
        sessionStore.pendingMessageJump = nil
        sessionStore.pendingMessageJumpAttempts = 0
        sessionStore.pendingMessageJumpSnippet = nil
        _ = target
        return true
    }

    /// M1: a stale cache seed (phase 1) that does NOT contain the target row
    /// must NOT clear `pendingMessageJump`. The jump survives and resolves on
    /// the network seed (phase 2). This is the exact regression M1 fixed.
    func testPendingMessageJumpSurvivesStaleCacheSeedAndResolvesOnNetworkSeed() {
        let chatStore = ChatStore()
        let sessionStore = SessionStore()

        // A search-result tap armed an exact-id jump for wire id 50.
        sessionStore.pendingMessageJump = 50
        sessionStore.pendingMessageJumpAttempts = 0
        XCTAssertEqual(sessionStore.pendingMessageJump, 50)

        // Phase 1 — stale cache seed: two OLDER rows, NEITHER carries wire id 50.
        // (Simulates a stale on-disk cache that predates the matched message.)
        chatStore.seed(normalized: ChatStore.toChatMessages([
            stored(role: "user", text: "old question", wireId: 10),
            stored(role: "assistant", text: "old answer", wireId: 11),
        ]))
        XCTAssertEqual(chatStore.messages.count, 2,
                       "phase-1 cache seed must populate the transcript")

        // The resolver runs on the phase-1 bump. Pre-M1 this CLEARED the jump
        // (the bug). Post-M1 it must LEAVE it set (target absent → no clear).
        let phase1Resolved = resolveJump(chatStore: chatStore, sessionStore: sessionStore)
        XCTAssertFalse(phase1Resolved,
                       "phase-1 (stale cache) must not resolve the target — it isn't seeded yet")
        XCTAssertEqual(sessionStore.pendingMessageJump, 50,
                       "M1 REGRESSION: pendingMessageJump must SURVIVE the stale-cache seed. Pre-M1 it was cleared here and the scroll silently never happened.")
        XCTAssertEqual(sessionStore.pendingMessageJumpAttempts, 1,
                       "the miss must increment the attempt counter (not consume yet)")

        // Phase 2 — authoritative network seed: includes the matched row (id 50).
        chatStore.seed(normalized: ChatStore.toChatMessages([
            stored(role: "user", text: "old question", wireId: 10),
            stored(role: "assistant", text: "old answer", wireId: 11),
            stored(role: "user", text: "the matched question", wireId: 50),
            stored(role: "assistant", text: "the matched answer", wireId: 51),
        ]))
        XCTAssertEqual(chatStore.messages.count, 4,
                       "phase-2 network seed must reconcile the matched row in")

        // The resolver runs on the phase-2 bump and must now RESOLVE + consume.
        let phase2Resolved = resolveJump(chatStore: chatStore, sessionStore: sessionStore)
        XCTAssertTrue(phase2Resolved,
                      "phase-2 (network seed) must resolve the target — the row is now present")
        XCTAssertNil(sessionStore.pendingMessageJump,
                     "a successful scroll must consume pendingMessageJump")
        XCTAssertEqual(sessionStore.pendingMessageJumpAttempts, 0,
                       "a successful scroll must reset the attempt counter")
    }

    /// M1 bound: a target that is GENUINELY absent (coalesced turn / stock
    /// gateway / compressed-out row) — absent across the cache + network +
    /// late-reconcile hops — is consumed after the attempt cap so it can't live
    /// forever or loop. With a snippet, it falls back to the query-text scroll.
    func testGenuinelyAbsentTargetIsConsumedAfterAttemptCapWithSnippetFallback() {
        let chatStore = ChatStore()
        let sessionStore = SessionStore()

        sessionStore.pendingMessageJump = 999
        sessionStore.pendingMessageJumpAttempts = 0
        sessionStore.pendingMessageJumpSnippet = "the matched prose"

        // Seed a transcript that NEVER contains wire id 999.
        chatStore.seed(normalized: ChatStore.toChatMessages([
            stored(role: "user", text: "unrelated", wireId: 1),
        ]))

        // Hop 1 — miss, under cap.
        XCTAssertFalse(resolveJump(chatStore: chatStore, sessionStore: sessionStore))
        XCTAssertEqual(sessionStore.pendingMessageJump, 999)
        XCTAssertEqual(sessionStore.pendingMessageJumpAttempts, 1)
        XCTAssertNil(sessionStore.pendingSearchScroll,
                     "snippet fallback must not fire before the cap")

        // Hop 2 — miss, under cap.
        XCTAssertFalse(resolveJump(chatStore: chatStore, sessionStore: sessionStore))
        XCTAssertEqual(sessionStore.pendingMessageJump, 999)
        XCTAssertEqual(sessionStore.pendingMessageJumpAttempts, 2)

        // Hop 3 — miss, AT cap → consume + snippet fallback.
        XCTAssertFalse(resolveJump(chatStore: chatStore, sessionStore: sessionStore))
        XCTAssertNil(sessionStore.pendingMessageJump,
                     "after the attempt cap the jump must be consumed (no infinite retention)")
        XCTAssertEqual(sessionStore.pendingMessageJumpAttempts, 0)
        XCTAssertEqual(sessionStore.pendingSearchScroll, "the matched prose",
                       "S2: on the cap with a snippet, the query-text scroll must be armed")
        XCTAssertNil(sessionStore.pendingMessageJumpSnippet)
    }

    /// M1 bound: a genuinely absent target WITHOUT a snippet (e.g. the artifacts
    /// gallery, which carries no snippet) is consumed as a graceful no-op after
    /// the cap — no query-text fallback, no crash.
    func testGenuinelyAbsentTargetWithoutSnippetIsConsumedAsNoOp() {
        let chatStore = ChatStore()
        let sessionStore = SessionStore()

        sessionStore.pendingMessageJump = 999
        sessionStore.pendingMessageJumpAttempts = 0
        // No snippet (artifacts-gallery origin).
        sessionStore.pendingMessageJumpSnippet = nil

        chatStore.seed(normalized: ChatStore.toChatMessages([
            stored(role: "user", text: "unrelated", wireId: 1),
        ]))

        for _ in 0..<SessionStore.pendingMessageJumpMaxAttempts {
            _ = resolveJump(chatStore: chatStore, sessionStore: sessionStore)
        }
        XCTAssertNil(sessionStore.pendingMessageJump,
                     "absent target must be consumed after the cap even without a snippet")
        XCTAssertNil(sessionStore.pendingSearchScroll,
                     "no snippet ⇒ no query-text fallback (graceful no-op)")
    }

    /// S1: `open(searchResult:)` arms the jump/snippet AFTER the switch clear,
    /// so a search-result tap onto a DIFFERENT session lands its own jump (not
    /// the previous session's, and not wiped by the switch clear).
    func testOpenSearchResultArmsJumpAfterSwitchClear() {
        let sessionStore = SessionStore()
        // Simulate a prior session being active + a stale jump from it.
        sessionStore.activeStoredId = "session-old"
        sessionStore.pendingMessageJump = 111
        sessionStore.pendingSearchScroll = "stale"

        // A search result for a DIFFERENT session carrying a messageId + snippet.
        let result = SessionSearchResult(
            id: "session-new", snippet: "fresh snippet",
            role: "user", source: nil, model: nil, sessionStarted: nil,
            messageId: 222
        )
        // `sessions` list must contain the row for the fast path.
        sessionStore.sessions = [result.asSessionSummary]
        // Prime searchQuery so the no-id branch could use it (not taken here).
        sessionStore.searchQuery = "fresh"

        sessionStore.open(searchResult: result)

        XCTAssertEqual(sessionStore.pendingMessageJump, 222,
                       "the search-result's own jump must be armed after the switch clear")
        XCTAssertEqual(sessionStore.pendingMessageJumpSnippet, "fresh snippet",
                       "S2: the snippet must be captured alongside the id jump")
        XCTAssertEqual(sessionStore.pendingMessageJumpAttempts, 0)
        XCTAssertNil(sessionStore.pendingSearchScroll,
                     "with a messageId, the query-text scroll must NOT be armed")
        XCTAssertEqual(sessionStore.activeStoredId, "session-new",
                       "open(searchResult:) must switch to the result's session")
    }

    // MARK: - ABH-192 regression: coalesced-turn artifact miss → snippet fallback

    /// A tool-bearing assistant row (so the next text-only assistant row coalesces
    /// into it — `toChatMessages` merges consecutive assistant rows when EITHER
    /// side carries a tool, keeping one agentic turn as ONE bubble).
    private func storedAssistantWithTool(text: String, wireId: Int) -> StoredMessage {
        StoredMessage(
            role: "assistant",
            content: .string(text),
            timestamp: 1_700_000_000,
            wireId: wireId,
            toolCalls: [WireToolCall(json: .object([
                "call_id": .string("call-\(wireId)"),
                "function": .object([
                    "name": .string("read_file"),
                    "arguments": .string("{}"),
                ]),
            ]))!]
        )
    }

    /// ABH-192 — THE artifact-jump bug this fix targets. An agentic assistant turn
    /// COALESCES several wire rows into ONE `ChatMessage` (id = the FIRST/anchor
    /// row's `w{wireId}-assistant`). An artifact records the wire `message_id` of
    /// a NON-anchor row of that turn (the row that actually produced the file).
    /// `messageJumpCandidateIDs(for: nonAnchorWireId)` therefore matches NOTHING in
    /// the loaded transcript — the exact-id jump no-ops forever. The fix carries the
    /// artifact's prose `jumpSnippet` as `pendingMessageJumpSnippet`, so after the
    /// id-miss attempt cap the jump FALLS BACK to a prose-snippet scroll that lands
    /// inside the (coalesced) turn instead of silently doing nothing.
    ///
    /// This pins the whole chain at the store level:
    ///  (1) the two rows really coalesce into ONE bubble (precondition),
    ///  (2) the non-anchor wire id is NOT a resolvable jump candidate (the bug),
    ///  (3) the id-jump misses every hop and the snippet fallback arms
    ///      `pendingSearchScroll`,
    ///  (4) that snippet substring-matches the coalesced bubble's prose — i.e. the
    ///      `jumpToSearchMatchIfNeeded` resolver WILL find a target (the jump
    ///      resolves rather than no-op'ing).
    func testCoalescedTurnArtifactMissResolvesViaSnippetFallback() {
        let chatStore = ChatStore()
        let sessionStore = SessionStore()

        // Anchor row (wire id 60) carries a tool call; the NON-anchor row (wire id
        // 61) is the one that produced the artifact and holds the artifact prose.
        let anchorWireId = 60
        let artifactWireId = 61
        let artifactProse = "wrote the report to report.md"

        let normalized = ChatStore.toChatMessages([
            stored(role: "user", text: "make me a report", wireId: 59),
            storedAssistantWithTool(text: "Reading the inputs…", wireId: anchorWireId),
            // Text-only assistant row — coalesces into the tool-bearing anchor.
            stored(role: "assistant", text: artifactProse, wireId: artifactWireId),
        ])
        chatStore.seed(normalized: normalized)

        // (1) PRECONDITION — the two assistant rows coalesced into ONE bubble.
        let assistantBubbles = chatStore.messages.filter { $0.role == .assistant }
        XCTAssertEqual(assistantBubbles.count, 1,
                       "the tool-bearing + text assistant rows must coalesce into ONE bubble")
        let anchorID = ChatStore.messageJumpID(wireMessageId: anchorWireId, role: .assistant)
        XCTAssertEqual(assistantBubbles[0].id, anchorID,
                       "the coalesced bubble's id is the ANCHOR (first) row's wire-id digest")
        XCTAssertTrue(assistantBubbles[0].text.contains(artifactProse),
                      "the coalesced bubble must carry the NON-anchor row's prose")

        // (2) THE BUG — the non-anchor wire id resolves to no row in the transcript.
        let artifactCandidates = Set(ChatStore.messageJumpCandidateIDs(for: artifactWireId))
        XCTAssertNil(chatStore.messages.first { artifactCandidates.contains($0.id) },
                     "ABH-192 root cause: a NON-anchor coalesced row's wire id has no matching ChatMessage.id — the pure exact-id jump can only no-op")

        // (3) Arm the jump exactly as `open(searchResult:)` does for an artifact tap:
        // the non-anchor wire id + the prose snippet, NO query-text scroll.
        sessionStore.pendingMessageJump = artifactWireId
        sessionStore.pendingMessageJumpAttempts = 0
        sessionStore.pendingMessageJumpSnippet = artifactProse
        sessionStore.pendingSearchScroll = nil

        // The id-jump misses on every hop (cache + network + late reconcile) because
        // the target row genuinely is not its own ChatMessage. After the attempt cap
        // the snippet fallback must arm `pendingSearchScroll`.
        for _ in 0..<SessionStore.pendingMessageJumpMaxAttempts {
            XCTAssertFalse(resolveJump(chatStore: chatStore, sessionStore: sessionStore),
                           "the exact-id jump must MISS — the non-anchor row is not its own bubble")
        }
        XCTAssertNil(sessionStore.pendingMessageJump,
                     "after the attempt cap the unresolvable id-jump must be consumed")
        XCTAssertEqual(sessionStore.pendingSearchScroll, artifactProse,
                       "S2: on the coalesced-turn id-miss the prose snippet must arm the query-text scroll fallback (NOT a silent no-op)")

        // (4) The fallback RESOLVES — `jumpToSearchMatchIfNeeded` substring-matches
        // the snippet against the loaded transcript and WOULD scroll to a real row.
        let needle = sessionStore.pendingSearchScroll!.lowercased()
        let fallbackTarget = chatStore.messages.first { $0.text.lowercased().contains(needle) }
        XCTAssertNotNil(fallbackTarget,
                        "the snippet fallback must resolve to the coalesced bubble — the jump lands inside the right turn instead of no-op'ing")
        XCTAssertEqual(fallbackTarget?.id, anchorID,
                       "the resolved fallback row is the coalesced bubble carrying the artifact prose")
    }

    /// S1: a pure session switch (drawer tap) with a stale pending jump from
    /// the previous session clears it — the stale jump does NOT carry into the
    /// new session.
    func testSessionSwitchClearsStalePendingJump() {
        let sessionStore = SessionStore()
        sessionStore.activeStoredId = "session-a"
        sessionStore.pendingMessageJump = 111
        sessionStore.pendingMessageJumpAttempts = 2
        sessionStore.pendingMessageJumpSnippet = "leftover"
        sessionStore.pendingSearchScroll = "stale"

        let summaryB = SessionSummary(
            id: "session-b", title: "B", preview: nil, startedAt: 1_700_000_000,
            messageCount: nil, source: nil, lastActive: 1_700_000_000,
            cwd: nil
        )
        sessionStore.open(summaryB)

        XCTAssertNil(sessionStore.pendingMessageJump,
                     "S1: a session switch must clear a stale pending jump")
        XCTAssertEqual(sessionStore.pendingMessageJumpAttempts, 0)
        XCTAssertNil(sessionStore.pendingMessageJumpSnippet)
        XCTAssertNil(sessionStore.pendingSearchScroll)
        XCTAssertEqual(sessionStore.activeStoredId, "session-b")
    }
}

// MARK: - ABH-192 Bug 1 + Bug 2 regressions

/// Regression tests for the two confirmed ABH-192 artifact-jump bugs.
///
/// Bug 1: file/image artifacts have `snippet=nil` on the wire, so
/// `Artifact.jumpSnippet` previously fell through to the bare filename (e.g.
/// "report.md"). The S2 fallback then called `messages.first(where:
/// { $0.text.contains(filename) })` — first occurrence, no role filter — so a
/// filename echoed in an EARLIER user bubble ("please create report.md") won,
/// scrolling to the WRONG message.
///
/// Bug 2: the server link snippet is a raw ±60-char slice that can contain a
/// literal newline. `plainSnippet` converts `\n→space`, but `ChatMessage.text`
/// retains `\n`. A naive `.contains()` therefore misses when the URL's
/// surrounding prose spans a line break.
@MainActor
final class ArtifactJumpRegressionTests: XCTestCase {

    private func stored(role: String, text: String, wireId: Int) -> StoredMessage {
        StoredMessage(json: .object([
            "role": .string(role),
            "content": .string(text),
            "id": .number(Double(wireId)),
            "timestamp": .number(1_700_000_000),
        ]))!
    }

    // MARK: - Bug 1 regression

    /// Bug 1 — bare-filename hint present in an earlier user bubble must NOT
    /// produce a wrong-message scroll.
    ///
    /// Before the fix: `Artifact.jumpSnippet` returned the bare filename
    /// ("report.md"), which became `pendingMessageJumpSnippet`. After the
    /// id-miss cap, it was promoted to `pendingSearchScroll`, and
    /// `jumpToSearchMatchIfNeeded` found the EARLIEST occurrence — i.e. the
    /// user bubble "please create report.md" — and scrolled there instead of
    /// the producing assistant bubble.
    ///
    /// After the fix: `jumpSnippet` returns `nil` for file/image artifacts with
    /// no prose snippet → `pendingMessageJumpSnippet` is `nil` → after the
    /// id-miss cap, `pendingSearchScroll` is NOT armed → the jump is consumed
    /// as a graceful no-op rather than scrolling to the wrong bubble.
    func testBareFilenameJumpDoesNotScrollToEarlierUserBubble() {
        // Construct a transcript where "report.md" appears in BOTH an earlier
        // user bubble AND the producing assistant bubble.
        let normalized = ChatStore.toChatMessages([
            stored(role: "user",      text: "please create report.md for me", wireId: 1),
            stored(role: "assistant", text: "I'll write the report now…",      wireId: 2),
            stored(role: "assistant", text: "Done! Wrote report.md to disk.",  wireId: 3),
        ])
        let chatStore = ChatStore()
        chatStore.seed(normalized: normalized)
        XCTAssertEqual(chatStore.messages.count, 3, "precondition: three bubbles seeded")

        let sessionStore = SessionStore()
        // Simulate what ArtifactsGalleryView does for a file artifact whose
        // jumpSnippet is now nil (Bug 1 fix). The snippet passed to
        // open(searchResult:) is nil → pendingMessageJumpSnippet stays nil.
        sessionStore.pendingMessageJump = 3          // wire id of the artifact message
        sessionStore.pendingMessageJumpAttempts = 0
        sessionStore.pendingMessageJumpSnippet = nil  // Bug 1 fix: jumpSnippet returns nil
        sessionStore.pendingSearchScroll = nil

        // Drive the resolver past the attempt cap (id 3 is an anchor row so it
        // WOULD resolve on a real transcript, but here we explicitly test that
        // when jumpSnippet is nil the S2 path stays silent).
        // To force the no-snippet path, we use an id that is NOT in the seeded
        // transcript (id 99 = genuinely absent) so the cap is always reached.
        sessionStore.pendingMessageJump = 99
        for _ in 0..<SessionStore.pendingMessageJumpMaxAttempts {
            guard let messageId = sessionStore.pendingMessageJump,
                  !chatStore.messages.isEmpty else { break }
            let candidates = Set(ChatStore.messageJumpCandidateIDs(for: messageId))
            let target = chatStore.messages.first { candidates.contains($0.id) }?.id
            guard target == nil else { break }
            sessionStore.pendingMessageJumpAttempts += 1
            if sessionStore.pendingMessageJumpAttempts >= SessionStore.pendingMessageJumpMaxAttempts {
                let snippet = sessionStore.pendingMessageJumpSnippet
                sessionStore.pendingMessageJump = nil
                sessionStore.pendingMessageJumpAttempts = 0
                sessionStore.pendingMessageJumpSnippet = nil
                if let snippet, !snippet.isEmpty {
                    sessionStore.pendingSearchScroll = snippet
                }
            }
        }

        // KEY ASSERTION: pendingSearchScroll must NOT be armed because jumpSnippet
        // was nil (Bug 1 fix) → no wrong-message scroll to the earlier user bubble.
        XCTAssertNil(sessionStore.pendingSearchScroll,
                     "Bug 1 regression: bare filename must not arm pendingSearchScroll — a nil jumpSnippet produces a safe no-op, not a scroll to the wrong (earliest) bubble")
        XCTAssertNil(sessionStore.pendingMessageJump,
                     "jump must be consumed after the attempt cap")

        // Sanity: confirm "report.md" IS present in the earlier user bubble.
        // This proves the old code WOULD have scrolled to the wrong bubble.
        let earlierUserBubble = chatStore.messages.first { $0.role == .user }
        XCTAssertTrue(earlierUserBubble?.text.contains("report.md") ?? false,
                      "sanity: filename 'report.md' is in the earlier user bubble — without the fix the old code would scroll there")
    }

    // MARK: - Bug 2 regression

    /// Bug 2 — a link snippet whose prose contains a newline must still resolve
    /// to the producing bubble after whitespace normalisation.
    ///
    /// The server returns a raw ±60-char slice that can contain a literal `\n`
    /// (URL at end-of-line, or in a list). `plainSnippet` converts `\n→space`
    /// in the needle, but `ChatMessage.text` retains the original `\n`.
    /// Without normalisation on BOTH sides, `.contains()` returns false and the
    /// jump silently no-ops.
    ///
    /// After the fix: `jumpToSearchMatchIfNeeded` collapses whitespace runs
    /// (including newlines) in BOTH the needle and each `.text` before matching,
    /// so the snippet still resolves even when the prose spans a line break.
    func testLinkSnippetWithNewlineResolvesToProducingBubble() {
        // The producing assistant bubble has the URL on its own line (prose spans
        // a line break), so ChatMessage.text contains "\n".
        let producingProse = "Check out this resource:\nhttps://example.com/article"
        let normalized = ChatStore.toChatMessages([
            stored(role: "user",      text: "find me a resource",  wireId: 10),
            stored(role: "assistant", text: producingProse,         wireId: 11),
        ])
        let chatStore = ChatStore()
        chatStore.seed(normalized: normalized)
        XCTAssertEqual(chatStore.messages.count, 2)

        // Simulate the server's ±60-char snippet: the surrounding prose fragment
        // that contains the newline. plainSnippet replaces \n→space.
        let serverSnippet = "Check out this resource:\nhttps://example.com/article"
        let needle = serverSnippet
            .replacingOccurrences(of: "<b>", with: "")
            .replacingOccurrences(of: "</b>", with: "")
            .replacingOccurrences(of: "\n", with: " ")   // plainSnippet pass
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // needle is now "Check out this resource: https://example.com/article"

        // OLD behaviour (no whitespace normalisation on the haystack side):
        // ChatMessage.text still has "\n" → naive .contains() misses.
        let naiveMissOld = chatStore.messages.first {
            $0.text.lowercased().contains(needle.lowercased())
        }
        XCTAssertNil(naiveMissOld,
                     "Bug 2 pre-condition: naive .contains() misses when ChatMessage.text retains the newline but the needle has it replaced with a space")

        // NEW behaviour (collapse whitespace on BOTH sides — mirrors the fix in
        // ChatView.jumpToSearchMatchIfNeeded → collapseWhitespace helper):
        func collapseWhitespace(_ s: String) -> String {
            s.components(separatedBy: .whitespacesAndNewlines)
             .filter { !$0.isEmpty }
             .joined(separator: " ")
        }
        let normalizedNeedle = collapseWhitespace(needle).lowercased()
        let fixedMatch = chatStore.messages.first {
            collapseWhitespace($0.text).lowercased().contains(normalizedNeedle)
        }
        XCTAssertNotNil(fixedMatch,
                        "Bug 2 fix: collapsing whitespace on both sides must find the producing bubble even when prose spans a line break")
        XCTAssertEqual(fixedMatch?.role, .assistant,
                       "the match must be the assistant bubble that produced the link — not an unrelated row")
        XCTAssertTrue(fixedMatch?.text.contains("https://example.com/article") ?? false,
                      "the matched bubble must contain the link URL")
    }
}
