import XCTest
@testable import HermesMobile

/// ABH-4xx (scout-bugs finding, filed off ABH-401 cross-provider review) —
/// `truncate_before_user_ordinal` is computed WINDOW-RELATIVE on iOS but
/// interpreted ABSOLUTE by the gateway.
///
/// `ChatStore.userOrdinal(at:)` / `rebuildUserOrdinals()` count user rows
/// positionally over whatever is CURRENTLY in `messages` (ChatStore.swift
/// ~2037-2040, ~2690-2698). Since ABH-400, a cold open seeds only the newest
/// `transcriptOpenWindowLimit` (50) rows — so for a long session, `messages`
/// is a TAIL SLICE of the true history, not the full transcript. The ordinal
/// `editAndResend`/`retry`/`restoreCheckpoint` compute for a given user row
/// therefore depends on how much of the transcript happens to be loaded, NOT
/// on that row's true position in the session.
///
/// The gateway (`tui_gateway/server.py` `prompt.submit`, ~8265-8279) has no
/// way to know the ordinal was window-relative: it builds `user_indices` over
/// its OWN full `session["history"]` and indexes into it directly. A
/// window-relative ordinal sent from a long session silently truncates the
/// WRONG (much earlier) turn — an unrecoverable history loss — rather than
/// raising the `4018` stale-target error (which only fires when the ordinal
/// is out of range, not when it's in-range-but-wrong).
///
/// These tests pin the CLIENT-SIDE half of the bug reproducibly: the exact
/// same transcript row maps to a DIFFERENT `userOrdinal` depending solely on
/// how much history happens to be loaded locally. That is precisely the
/// property that makes the value unsafe to send as an absolute gateway index.
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

    /// ROOT CAUSE: the SAME user row's computed ordinal changes depending only
    /// on how much of the transcript is currently loaded — proving the value
    /// is window-relative, not an absolute index into the gateway's history.
    ///
    /// `u35` is the 36th user turn (absolute ordinal 35) in a 40-turn session.
    /// Seeding the FULL transcript gives it ordinal 35 (correct, matches the
    /// gateway's `user_indices[35]`). Re-seeding with ONLY the newest 20 rows —
    /// exactly what ABH-400's cold-open window does for a long session — makes
    /// `rebuildUserOrdinals()` recount from zero over just that slice, so the
    /// IDENTICAL row now reports a much smaller ordinal. If the client sent
    /// that windowed ordinal to `prompt.submit`, the gateway would truncate at
    /// the wrong (far earlier) turn instead of the one the user actually chose.
    func testUserOrdinalIsWindowRelativeNotAbsolute() {
        let chat = ChatStore()
        let all = longTranscript(userTurns: 40)

        // Phase 1: full transcript loaded (as if the session were short enough
        // to seed in one page, or after `loadEarlierTranscript()` fully backfilled).
        chat.seed(from: all)
        let u35Full = chat.messages.first { $0.text == "u35" }!
        let fullOrdinal = chat.userOrdinals[u35Full.id]
        XCTAssertEqual(fullOrdinal, 35,
                        "u35 is the 36th user turn — its ordinal over the FULL transcript "
                        + "must equal the gateway's absolute user_indices[35]")

        // Phase 2: ABH-400 cold-open windowing — only the newest 20 rows seed
        // (mirrors `fetchTranscriptPage(limit: transcriptOpenWindowLimit)` +
        // `seed(normalized: cached.suffix(50))` at a smaller scale for a fast test).
        let windowed = Array(all.suffix(20))
        chat.seed(from: windowed)
        let u35Windowed = chat.messages.first { $0.text == "u35" }!
        let windowedOrdinal = chat.userOrdinals[u35Windowed.id]

        XCTAssertNotEqual(windowedOrdinal, fullOrdinal,
            "BUG: the identical user row (u35) maps to a DIFFERENT truncate_before_user_ordinal "
            + "purely because fewer rows are loaded locally. userOrdinal(at:) counts user rows "
            + "positionally over whatever is CURRENTLY in `messages` (ChatStore.swift ~2037-2040), "
            + "so it is window-relative — but tui_gateway/server.py prompt.submit "
            + "(user_indices = [i for i,m in enumerate(history) if role==user]; "
            + "history[:user_indices[ordinal]]) interprets the value as an ABSOLUTE index "
            + "into its own full history. Sending the windowed ordinal for a real edit/retry "
            + "would truncate the gateway's history at the wrong (far earlier) turn — silent, "
            + "unrecoverable data loss, not a 4018 the client could catch.")

        // Document the concrete magnitude of the corruption: the 20-row window is
        // the last 10 user/assistant PAIRS (turns 30...39), so u35 is the 6th user
        // row within that window (ordinal 5) — not the 36th (ordinal 35) it truly
        // is in the session. A discrepancy the client cannot detect locally,
        // because it has no absolute anchor (ChatMessage carries only a UUID,
        // ChatModels.swift:56 — no wireId, no absolute ordinal).
        XCTAssertEqual(windowedOrdinal, 5,
            "the windowed ordinal undercounts by exactly the number of earlier user turns "
            + "that fell outside the loaded window (30 of them: turns 0...29)")
    }

    /// ABH-401's non-contiguous `[around] + gap + [tail]` prepend (`loadTranscriptAround`,
    /// ChatStore.swift ~2518-2544) makes the corruption WORSE for the sparse case: the
    /// ordinal for a tail row shifts again once older rows are prepended across a gap,
    /// even though the tail row's TRUE position in the session never moved.
    func testJumpPrependShiftsOrdinalForUnrelatedTailMessage() async {
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        let attachments = AttachmentStore()
        chat.attach(connection: connection, sessions: sessions, attachments: attachments)
        sessions.attach(connection: connection, chat: chat)
        sessions.activeStoredId = "s1"

        let all = longTranscript(userTurns: 40) // wire ids 1...80
        let windowed = Array(all.suffix(20))     // newest 20 rows (wire ids 41...80)
        chat.seed(from: windowed)
        chat.noteTranscriptPaging(oldestId: 41, hasMoreBefore: true)

        let u35BeforeJump = chat.messages.first { $0.text == "u35" }!
        let ordinalBeforeJump = chat.userOrdinals[u35BeforeJump.id]

        // Install a fake around-fetch for an OLDER, UNRELATED jump target (wire id 5,
        // i.e. u2) with radius 2 — mirrors a drawer-search / deep-link / artifacts jump
        // to some earlier message, same mechanism ABH-401 ships.
        chat.transcriptAroundFetch = { _, messageId, radius in
            XCTAssertEqual(messageId, 5)
            let page = all.filter { row in
                guard let wire = row.wireId else { return false }
                return wire >= messageId - radius && wire <= messageId + radius
            }
            return TranscriptAroundFetch(messages: page, oldestId: 3, hasMoreBefore: true, containsTarget: true)
        }

        let loaded = await chat.loadTranscriptAround(messageId: 5, radius: 2)
        XCTAssertTrue(loaded, "the around-window fetch should resolve the jump target")

        let u35AfterJump = chat.messages.first { $0.text == "u35" }!
        let ordinalAfterJump = chat.userOrdinals[u35AfterJump.id]

        XCTAssertNotEqual(ordinalAfterJump, ordinalBeforeJump,
            "BUG (ABH-401 compounding ABH-400): u35's truncate_before_user_ordinal shifted "
            + "from \(String(describing: ordinalBeforeJump)) to \(String(describing: ordinalAfterJump)) "
            + "purely because an UNRELATED older jump target got prepended across a gap. "
            + "rebuildUserOrdinals() counts across the full non-contiguous `messages` array "
            + "(ChatStore.swift ~2690-2698), so every row's ordinal is perturbed by any jump "
            + "the user makes elsewhere in the transcript — even though none of those rows "
            + "changed position in the actual session history the gateway holds.")
    }

    /// The destructive action path must load every earlier page before exposing
    /// the ordinal that `prompt.submit` interprets against full server history.
    /// Normal opening remains lazy; only the explicit retry/edit action pays
    /// this bounded paging cost.
    func testTruncationTargetBackfillsTailBeforeReturningAbsoluteOrdinal() async {
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        chat.attach(connection: connection, sessions: sessions, attachments: AttachmentStore())
        sessions.attach(connection: connection, chat: chat)
        sessions.activeStoredId = "s1"

        let all = longTranscript(userTurns: 40)
        let tail = Array(all.suffix(20))
        chat.seed(from: tail)
        chat.noteTranscriptPaging(oldestId: tail.first?.wireId, hasMoreBefore: true)
        let targetId = chat.messages.first { $0.text == "u35" }!.id
        var fetches = 0
        chat.transcriptPageFetch = { _, _, _ in
            fetches += 1
            return TranscriptPageFetch(
                messages: Array(all.prefix(60)),
                oldestId: all.first?.wireId,
                hasMoreBefore: false
            )
        }

        let target = await chat.truncationTarget(for: targetId)

        XCTAssertEqual(fetches, 1)
        XCTAssertEqual(target?.ordinal, 35)
        XCTAssertEqual(chat.messages.count, 80)
        XCTAssertNil(chat.lastError)
    }

    /// A page failure must never fall through to the tail-relative ordinal.
    /// This is the observed "message no longer available" class made safe:
    /// retain the transcript, surface a retryable error, send no truncation.
    func testTruncationTargetFailsClosedWhenEarlierPageCannotLoad() async {
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        chat.attach(connection: connection, sessions: sessions, attachments: AttachmentStore())
        sessions.attach(connection: connection, chat: chat)
        sessions.activeStoredId = "s1"

        let tail = Array(longTranscript(userTurns: 40).suffix(20))
        chat.seed(from: tail)
        chat.noteTranscriptPaging(oldestId: tail.first?.wireId, hasMoreBefore: true)
        let targetId = chat.messages.first { $0.text == "u35" }!.id
        chat.transcriptPageFetch = { _, _, _ in nil }

        let target = await chat.truncationTarget(for: targetId)

        XCTAssertNil(target)
        XCTAssertEqual(chat.messages.count, 20)
        XCTAssertEqual(chat.lastError, "Couldn’t load the complete history. Try again.")
    }
}
