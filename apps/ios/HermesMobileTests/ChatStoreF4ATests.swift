import XCTest
@testable import HermesMobile

/// F4A-A2 — coverage for the chat-surface depth module: subagent-tree assembly,
/// sudo/secret prompt handling (incl. secret hygiene), branch-seed coercion,
/// checkpoint truncation-ordinal mapping, and event decode round-trips.
///
/// Drives `ChatStore.handle` directly with synthetic frames (no live gateway),
/// reusing the wiring pattern from `ChatStoreForeignMirrorTests`.
@MainActor
final class ChatStoreF4ATests: XCTestCase {

    private let activeRuntime = "rt-local"
    private let foreignRuntime = "rt-foreign"
    private let storedId = "stored-session-1"

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

    /// A frame on our OWN active runtime (classified `.local`).
    private func localFrame(type: String, payload: JSONValue = .null) -> GatewayEvent {
        GatewayEvent(params: .object([
            "type": .string(type),
            "session_id": .string(activeRuntime),
            "payload": payload,
        ]))!
    }

    /// A broadcast frame from a foreign runtime tagged with our open stored id.
    private func foreignFrame(type: String, payload: JSONValue = .null) -> GatewayEvent {
        GatewayEvent(params: .object([
            "type": .string(type),
            "session_id": .string(foreignRuntime),
            "stored_session_id": .string(storedId),
            "payload": payload,
        ]))!
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(80))
    }

    // MARK: - Event decode round-trips

    func testSubagentEventTypesDecode() {
        for raw in ["subagent.start", "subagent.thinking", "subagent.tool",
                    "subagent.progress", "subagent.complete",
                    "sudo.request", "secret.request"] {
            let event = GatewayEvent(params: .object([
                "type": .string(raw),
                "session_id": .string(activeRuntime),
                "payload": .object([:]),
            ]))
            XCTAssertNotNil(event, "\(raw) must parse")
            XCTAssertNotEqual(event?.type, .unknown, "\(raw) must NOT decode to .unknown")
        }
    }

    func testSubagentStartPayloadDecode() {
        let payload: JSONValue = .object([
            "goal": .string("Investigate the bug"),
            "task_count": .number(3),
            "task_index": .number(1),
            "subagent_id": .string("sa-1"),
            "parent_id": .string("sa-root"),
            "depth": .number(2),
            "model": .string("claude-opus-4"),
        ])
        let decoded = SubagentEventPayload(payload: payload)
        XCTAssertEqual(decoded.goal, "Investigate the bug")
        XCTAssertEqual(decoded.taskCount, 3)
        XCTAssertEqual(decoded.taskIndex, 1)
        XCTAssertEqual(decoded.subagentId, "sa-1")
        XCTAssertEqual(decoded.parentId, "sa-root")
        XCTAssertEqual(decoded.depth, 2)
        XCTAssertEqual(decoded.model, "claude-opus-4")
    }

    /// The timeout/error completion variant: status timeout, empty summary,
    /// preview carries the "Timed out after Ns" text.
    func testSubagentCompleteTimeoutVariant() async {
        let (chat, _) = makeStore()
        chat.handle(event: localFrame(type: "subagent.start", payload: .object([
            "goal": .string("Long task"),
            "subagent_id": .string("sa-1"),
        ])))
        chat.handle(event: localFrame(type: "subagent.complete", payload: .object([
            "subagent_id": .string("sa-1"),
            "status": .string("timeout"),
            "summary": .string(""),
            "text": .string("Timed out after 30s"),
            "duration_seconds": .number(30.0),
        ])))
        await settle()
        let node = chat.subagentRoots.first
        XCTAssertEqual(node?.status, .timeout)
        // The empty summary falls back to the preview text so the row isn't blank.
        XCTAssertEqual(node?.activity, "Timed out after 30s")
        XCTAssertEqual(node?.durationSeconds, 30.0)
    }

    // MARK: - Subagent tree assembly

    func testSubagentTreeAssemblesParentChild() async {
        let (chat, _) = makeStore()
        // Parent.
        chat.handle(event: localFrame(type: "subagent.start", payload: .object([
            "goal": .string("Root task"),
            "subagent_id": .string("root"),
            "depth": .number(0),
            "task_index": .number(0),
        ])))
        // Two children of root, arriving OUT of task order (1 then 0) to prove
        // they are sorted by task_index.
        chat.handle(event: localFrame(type: "subagent.start", payload: .object([
            "goal": .string("Child B"),
            "subagent_id": .string("child-b"),
            "parent_id": .string("root"),
            "depth": .number(1),
            "task_index": .number(1),
        ])))
        chat.handle(event: localFrame(type: "subagent.start", payload: .object([
            "goal": .string("Child A"),
            "subagent_id": .string("child-a"),
            "parent_id": .string("root"),
            "depth": .number(1),
            "task_index": .number(0),
        ])))
        await settle()

        XCTAssertEqual(chat.subagentRoots.count, 1)
        let root = chat.subagentRoots[0]
        XCTAssertEqual(root.id, "root")
        let children = chat.subagentChildren(of: root)
        XCTAssertEqual(children.map(\.id), ["child-a", "child-b"],
                       "children must be ordered by task_index regardless of arrival order")
        XCTAssertEqual(chat.subagentNodeCount, 3)
    }

    /// A child frame that arrives BEFORE its parent's start is adopted once the
    /// parent appears (the pending-children drain).
    func testSubagentOrphanAdoptedWhenParentArrives() async {
        let (chat, _) = makeStore()
        chat.handle(event: localFrame(type: "subagent.start", payload: .object([
            "goal": .string("Orphan child"),
            "subagent_id": .string("child"),
            "parent_id": .string("late-parent"),
            "task_index": .number(0),
        ])))
        await settle()
        // Before the parent arrives the child is not a root.
        XCTAssertTrue(chat.subagentRoots.isEmpty || chat.subagentRoots.first?.id != "child")

        chat.handle(event: localFrame(type: "subagent.start", payload: .object([
            "goal": .string("Late parent"),
            "subagent_id": .string("late-parent"),
            "task_index": .number(0),
        ])))
        await settle()
        XCTAssertEqual(chat.subagentRoots.map(\.id), ["late-parent"])
        XCTAssertEqual(chat.subagentChildren(of: chat.subagentRoots[0]).map(\.id), ["child"])
    }

    func testSubagentTreeResetsOnNewLocalTurn() async {
        let (chat, _) = makeStore()
        chat.handle(event: localFrame(type: "subagent.start", payload: .object([
            "subagent_id": .string("sa-1"), "goal": .string("t"),
        ])))
        await settle()
        XCTAssertTrue(chat.hasSubagentActivity)
        // A new local turn (message.start on our runtime) begins → tree resets.
        chat.handle(event: localFrame(type: "message.start", payload: .object([
            "role": .string("assistant"),
        ])))
        await settle()
        XCTAssertFalse(chat.hasSubagentActivity, "a fresh local turn clears the prior tree")
        XCTAssertEqual(chat.subagentNodeCount, 0)
    }

    // MARK: - Subagent on a LOCAL turn is never misclassified as foreign (the trap)

    /// A `subagent.*` frame carrying our OWN active runtime's session_id must be
    /// classified `.local` and fold into the tree — NOT adopted as a foreign
    /// mirror. (The contract's named trap: subagent frames carry the parent's
    /// session_id.)
    func testSubagentOnLocalTurnNotAdoptedAsForeign() async {
        let (chat, _) = makeStore()
        // Begin a genuinely-local turn.
        chat.handle(event: localFrame(type: "message.start", payload: .object([
            "role": .string("assistant"),
        ])))
        await settle()
        XCTAssertTrue(chat.isStreaming)

        // Subagent frames on the SAME (local) runtime arrive mid-turn.
        chat.handle(event: localFrame(type: "subagent.start", payload: .object([
            "goal": .string("Local delegation"),
            "subagent_id": .string("sa-1"),
        ])))
        chat.handle(event: localFrame(type: "subagent.thinking", payload: .object([
            "subagent_id": .string("sa-1"),
            "text": .string("thinking…"),
        ])))
        await settle()

        // The tree assembled, and NO foreign adoption happened.
        XCTAssertEqual(chat.subagentRoots.count, 1)
        XCTAssertEqual(chat.subagentRoots[0].activity, "thinking…")
        #if DEBUG
        XCTAssertEqual(chat.foreignMirrorTelemetry.foreignAdopted, 0,
                       "a subagent frame on the local turn must never be adopted as foreign")
        XCTAssertEqual(chat.foreignMirrorTelemetry.foreignDroppedWhileStreaming, 0)
        #endif
    }

    /// A subagent frame broadcast from a FOREIGN runtime (different runtime id,
    /// our stored id) renders into the tree of the adopted mirror — without ever
    /// being misrouted to the local path.
    func testSubagentOnForeignTurnRendersInTree() async {
        let (chat, sessions) = makeStore()
        sessions.activeRuntimeId = nil  // resume window: only the mirror is live

        chat.handle(event: foreignFrame(type: "message.start", payload: .object([
            "role": .string("assistant"),
        ])))
        chat.handle(event: foreignFrame(type: "subagent.start", payload: .object([
            "goal": .string("Foreign delegation"),
            "subagent_id": .string("fsa-1"),
        ])))
        await settle()
        XCTAssertEqual(chat.subagentRoots.map(\.goal), ["Foreign delegation"])
    }

    // MARK: - Secret hygiene (BINDING)

    /// The entered secret value must NEVER appear in any store-readable string:
    /// not in lastError, not in any DEBUG telemetry/streaming-setter/ring string,
    /// and the prompt must clear after the reply.
    func testSecretNeverPersistedOrTelemetered() async {
        let (chat, _) = makeStore()
        let secretValue = "SUPERSECRET-TOKEN-0xDEADBEEF"

        chat.handle(event: localFrame(type: "secret.request", payload: .object([
            "request_id": .string("abc12345"),
            "prompt": .string("Enter your API key"),
            "env_var": .string("OPENAI_API_KEY"),
        ])))
        XCTAssertNotNil(chat.pendingSecurePrompt)
        XCTAssertEqual(chat.pendingSecurePrompt?.kind, .secret)
        XCTAssertEqual(chat.pendingSecurePrompt?.envVar, "OPENAI_API_KEY")

        // Reply with the secret. The client isn't connected so the RPC throws and
        // is swallowed generically — but the value must never be retained.
        await chat.respondSecurePrompt(value: secretValue)

        XCTAssertNil(chat.pendingSecurePrompt, "the prompt must clear after replying")

        // The value must appear in NO store-readable string.
        let haystacks: [String?] = [
            chat.lastError,
            chat.pendingSecurePrompt?.prompt,
            chat.pendingSecurePrompt?.envVar,
        ]
        for haystack in haystacks {
            XCTAssertFalse(haystack?.contains(secretValue) ?? false,
                           "the secret value must never appear in a store-readable string")
        }
        #if DEBUG
        XCTAssertFalse(chat.lastStreamingSetter.contains(secretValue))
        XCTAssertFalse(chat.streamingRingJSON.contains(secretValue))
        #endif
    }

    /// A `secret.request` whose payload has no `request_id` must NOT present a
    /// prompt (there is nothing to reply to).
    func testSecretRequestWithoutRequestIdIgnored() {
        let (chat, _) = makeStore()
        chat.handle(event: localFrame(type: "secret.request", payload: .object([
            "prompt": .string("no id"),
        ])))
        XCTAssertNil(chat.pendingSecurePrompt)
    }

    func testSudoRequestStagesPasswordPrompt() {
        let (chat, _) = makeStore()
        chat.handle(event: localFrame(type: "sudo.request", payload: .object([
            "request_id": .string("def67890"),
        ])))
        XCTAssertEqual(chat.pendingSecurePrompt?.kind, .sudo)
        XCTAssertEqual(chat.pendingSecurePrompt?.requestId, "def67890")
        XCTAssertNil(chat.pendingSecurePrompt?.envVar)
    }

    /// `secret.request` metadata is decoded best-effort as string hints and is
    /// never load-bearing — non-string values are dropped.
    func testSecretMetadataBestEffort() {
        let payload: JSONValue = .object([
            "request_id": .string("r1"),
            "prompt": .string("p"),
            "env_var": .string("E"),
            "metadata": .object([
                "label": .string("Production key"),
                "sensitive": .bool(true),   // non-string → dropped
            ]),
        ])
        let decoded = SecretRequestPayload(payload: payload)
        XCTAssertEqual(decoded?.metadata["label"], "Production key")
        XCTAssertNil(decoded?.metadata["sensitive"], "non-string metadata is dropped")
    }

    /// A foreign-broadcast sudo/secret frame must be inert — we never present
    /// another client's secure prompt.
    func testForeignSecurePromptIsInert() async {
        let (chat, sessions) = makeStore()
        sessions.activeRuntimeId = nil
        chat.handle(event: foreignFrame(type: "secret.request", payload: .object([
            "request_id": .string("r"), "prompt": .string("p"), "env_var": .string("E"),
        ])))
        await settle()
        XCTAssertNil(chat.pendingSecurePrompt, "a mirrored secret prompt must not be presented")
    }

    // MARK: - Branch seed coercion (matches _coerce_seed_history)

    func testBranchSeedCoercion() {
        let (chat, _) = makeStore()
        // Seed a transcript with mixed roles incl. an empty-text tool row and a
        // blank user row that must both be dropped.
        chat.seed(from: [
            StoredMessage(json: .object(["role": .string("user"), "content": .string("first")])) ,
            StoredMessage(json: .object(["role": .string("assistant"), "content": .string("reply one")])) ,
            StoredMessage(json: .object(["role": .string("tool"), "content": .string("tool dump")])) ,
            StoredMessage(json: .object(["role": .string("user"), "content": .string("second")])) ,
            StoredMessage(json: .object(["role": .string("assistant"), "content": .string("reply two")])) ,
        ].compactMap { $0 })

        // Branch at the SECOND user message ("second").
        let target = chat.messages.first { $0.role == .user && $0.text == "second" }!
        let seed = chat.branchSeed(upToMessageId: target.id)

        // Every item is {role, content} ONLY, role ∈ {user, assistant, system},
        // tool rows dropped, and the seed stops AT the target (inclusive).
        let roles = seed.compactMap { $0["role"]?.stringValue }
        XCTAssertEqual(roles, ["user", "assistant", "user"],
                       "tool rows dropped; history stops at (and includes) the branch point")
        for item in seed {
            XCTAssertEqual(Set(item.objectValue!.keys), ["role", "content"],
                           "each seed item must be {role, content} ONLY")
            XCTAssertFalse(item["content"]!.stringValue!.isEmpty)
        }
    }

    func testBranchSeedDropsBlankContent() {
        let (chat, _) = makeStore()
        chat.seed(from: [
            StoredMessage(json: .object(["role": .string("user"), "content": .string("  ")])) ,
            StoredMessage(json: .object(["role": .string("assistant"), "content": .string("kept")])) ,
        ].compactMap { $0 })
        let seed = chat.branchSeed(upToMessageId: chat.messages.last!.id)
        XCTAssertEqual(seed.count, 1, "a blank-content row is coerced out like the server would")
        XCTAssertEqual(seed.first?["content"]?.stringValue, "kept")
    }

    // MARK: - Checkpoint truncation-ordinal mapping

    /// Restoring to the Nth user message must resubmit with
    /// `truncate_before_user_ordinal == N` (the gateway's user-history index).
    func testRestoreCheckpointMapsToUserOrdinal() async {
        var capturedOrdinal: Int?
        let (chat, sessions) = makeStore()
        // Intercept the outgoing prompt.submit by swapping in a recording client
        // is heavy; instead seed a transcript and assert the ordinal mapping via
        // the public seam: restore re-runs submitTruncating, which sends the
        // ordinal. We verify the ordinal the store WOULD compute by reading the
        // transcript structure (user messages at positions 0,1,2).
        chat.seed(from: [
            StoredMessage(json: .object(["role": .string("user"), "content": .string("u0")])) ,
            StoredMessage(json: .object(["role": .string("assistant"), "content": .string("a0")])) ,
            StoredMessage(json: .object(["role": .string("user"), "content": .string("u1")])) ,
            StoredMessage(json: .object(["role": .string("assistant"), "content": .string("a1")])) ,
            StoredMessage(json: .object(["role": .string("user"), "content": .string("u2")])) ,
        ].compactMap { $0 })
        _ = sessions

        // The SECOND user message ("u1") is ordinal 1 — assert the mapping via
        // the ordinal cache directly (the old proxy — observing the leftover
        // optimistic truncation after a FAILED submit — no longer exists:
        // since ABH-48, a submit the server never accepted rolls its
        // truncation back instead of leaving the transcript amputated).
        let u1 = chat.messages.first { $0.text == "u1" }!
        XCTAssertEqual(chat.userOrdinals[u1.id], 1,
                       "the second user message maps to truncate_before_user_ordinal == 1")

        // No live client → submitTruncating fails at the RPC → the optimistic
        // local truncation is rolled back (ABH-48 judge-round contract).
        await chat.restoreCheckpoint(toUserMessageId: u1.id)
        await settle()

        let texts = chat.messages.map(\.text)
        XCTAssertEqual(texts, ["u0", "a0", "u1", "a1", "u2"],
                       "a restore the server never accepted leaves the transcript untouched")
        _ = capturedOrdinal
    }

    // MARK: - Todo card derivation

    func testTodoListParsesResultJSON() {
        let json = """
        {"todos":[{"id":"1","content":"Write tests","status":"completed"},\
        {"id":"2","content":"Ship it","status":"in_progress"},\
        {"id":"3","content":"Celebrate","status":"pending"}],\
        "summary":{"total":3}}
        """
        let list = TodoList(resultJSON: json)
        XCTAssertNotNil(list)
        XCTAssertEqual(list?.items.count, 3)
        XCTAssertEqual(list?.items[0].status, .completed)
        XCTAssertEqual(list?.items[1].status, .inProgress)
        XCTAssertEqual(list?.items[2].status, .pending)
        XCTAssertEqual(list?.items[1].content, "Ship it")
    }

    func testTodoListRejectsNonTodoResult() {
        XCTAssertNil(TodoList(resultJSON: "plain text"))
        XCTAssertNil(TodoList(resultJSON: #"{"output":"no todos here"}"#))
        XCTAssertNil(TodoList(resultJSON: #"{"todos":[]}"#), "an empty list yields nil (nothing to render)")
    }

    func testTodoToolNameMatchesGateway() {
        // The gateway keys the todo special-case on name == "todo" (server.py).
        XCTAssertEqual(TodoList.toolName, "todo")
    }

    // MARK: - Unknown-event non-regression

    /// A genuinely unknown event still decodes to `.unknown` and is dropped —
    /// adding subagent/secure cases must not change that.
    func testTrulyUnknownEventStillUnknown() {
        let event = GatewayEvent(params: .object([
            "type": .string("some.future.event"),
            "session_id": .string(activeRuntime),
        ]))
        XCTAssertEqual(event?.type, .unknown)
    }
}
