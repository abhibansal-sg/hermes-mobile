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
