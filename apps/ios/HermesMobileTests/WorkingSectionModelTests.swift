import XCTest
@testable import HermesMobile

/// Collapsed working-sections (owner spec) — deterministic coverage of the pure
/// grouping + summary model that `WorkingSectionView` renders from. No SwiftUI, no
/// I/O: every rule is a `nonisolated static` over value types.
///
/// SINGLE-FOLD CONTRACT (owner QA, 2026-07-19): within ONE agent turn, EVERYTHING
/// before the final answer text — reasoning, tool calls (BOTH item-layer `.item`
/// work AND the classic `.tools` clusters), and interim narration `.text` — folds
/// into ONE working node. The trailing answer `.text` (plus `.usage` / `.warning`
/// footers) stays OUTSIDE the fold as standalone parts. This applies to the classic
/// `ChatMessagePart` path too, not only the item layer.
final class WorkingSectionModelTests: XCTestCase {

    // MARK: - Builders

    private func item(
        _ id: String,
        _ type: ChatItemType,
        status: ChatItemStatus = .completed,
        summary: String? = nil,
        body: JSONValue = .null
    ) -> ChatMessagePart {
        .item(id: id, item: ChatItem(
            itemID: id, type: type, status: status, ord: 0, summary: summary, body: body
        ))
    }

    private func legacyTools(_ id: String) -> ChatMessagePart {
        .tools(
            id: id,
            tools: [ToolActivity(
                id: id, name: "read_file", argsSummary: "", progressText: "",
                resultPreview: "", state: .done, durationMs: nil, todos: nil,
                resultSummary: nil
            )],
            collapsed: false,
            turnElapsed: nil
        )
    }

    private func workingParts(of node: AssistantRenderNode) -> [ChatMessagePart]? {
        if case .working(_, let parts) = node { return parts }
        return nil
    }

    private func usageStats() -> UsageStats {
        JSONValue.object([:]).decoded(as: UsageStats.self)!
    }

    private func legacyTool(
        _ id: String,
        name: String = "read_file",
        state: ToolActivity.State = .done,
        argsSummary: String = "",
        resultPreview: String = "",
        durationMs: Double? = nil,
        resultSummary: String? = nil
    ) -> ToolActivity {
        ToolActivity(
            id: id, name: name, argsSummary: argsSummary, progressText: "",
            resultPreview: resultPreview, state: state, durationMs: durationMs,
            todos: nil, resultSummary: resultSummary
        )
    }

    // MARK: - Grouping (single-fold contract)

    func testReasoningPlusToolItemsFoldIntoOneWorkingNode() {
        let parts: [ChatMessagePart] = [
            .reasoning(id: "r1", text: "Reading the parser"),
            item("t1", .toolCall, summary: "read_file"),
            item("f1", .fileChange, summary: "Patched parser.swift"),
        ]
        let nodes = WorkingSectionModel.renderNodes(from: parts)
        XCTAssertEqual(nodes.count, 1, "reasoning + tool items must fold into a single working node")
        let run = try? XCTUnwrap(workingParts(of: nodes[0]))
        XCTAssertEqual(run?.count, 3)
    }

    func testClassicReasoningToolsTextFoldsIntoOneWorkingNodePlusAnswer() {
        // NEW single-fold contract: a classic blob-stream turn (reasoning → classic
        // .tools → answer text) folds the reasoning + the .tools cluster into ONE
        // working node, and the trailing answer text renders as a standalone part.
        let parts: [ChatMessagePart] = [
            .reasoning(id: "r1", text: "thinking"),
            legacyTools("c1"),
            .text(id: "x1", text: "Done."),
        ]
        let nodes = WorkingSectionModel.renderNodes(from: parts)
        XCTAssertEqual(nodes.count, 2, "classic turn folds pre-answer work + keeps the answer as a part")
        let fold = try? XCTUnwrap(workingParts(of: nodes[0]))
        XCTAssertEqual(fold?.count, 2, "reasoning + classic .tools fold together")
        XCTAssertNil(workingParts(of: nodes[1]), "the final answer text stays a standalone part")
        XCTAssertEqual(nodes[1].id, "x1")
    }

    func testInterimNarrationTextFoldsButFinalAnswerDoesNot() {
        // Interim `.text` (before a later work part) folds; the trailing answer
        // `.text` after the last work part stays out as the body.
        let parts: [ChatMessagePart] = [
            .reasoning(id: "r1", text: "plan"),
            .text(id: "n1", text: "Let me check the file."),  // interim narration
            item("t1", .toolCall, summary: "read_file"),
            .text(id: "a1", text: "Here is the answer."),      // final answer
        ]
        let nodes = WorkingSectionModel.renderNodes(from: parts)
        XCTAssertEqual(nodes.count, 2)
        let fold = try? XCTUnwrap(workingParts(of: nodes[0]))
        XCTAssertEqual(fold?.map(\.id), ["r1", "n1", "t1"],
                       "interim narration folds together with the reasoning + tool")
        XCTAssertNil(workingParts(of: nodes[1]))
        XCTAssertEqual(nodes[1].id, "a1")
    }

    func testUsageAndWarningFootersStayOutsideTheFold() {
        let parts: [ChatMessagePart] = [
            item("t1", .toolCall),
            .text(id: "a1", text: "Answer."),
            .warning(id: "w1", text: "heads up"),
            .usage(id: "u1", stats: usageStats()),
        ]
        let nodes = WorkingSectionModel.renderNodes(from: parts)
        // fold(t1) + a1 + w1 + u1
        XCTAssertEqual(nodes.map(\.id), ["working-t1", "a1", "w1", "u1"])
        XCTAssertNotNil(workingParts(of: nodes[0]))
        XCTAssertNil(workingParts(of: nodes[1]))
    }

    func testReasoningOnlyTurnFoldsIntoOneWorkingNode() {
        // A reasoning-only turn is "everything before a (nonexistent) answer" — it
        // folds so a settled turn collapses to a single "Worked for N" line.
        let parts: [ChatMessagePart] = [.reasoning(id: "r1", text: "just thinking")]
        let nodes = WorkingSectionModel.renderNodes(from: parts)
        XCTAssertEqual(nodes.count, 1)
        XCTAssertNotNil(workingParts(of: nodes[0]))
    }

    func testPureTextTurnNeverFolds() {
        // No work part → no fold; a plain prose answer decomposes to `.part` nodes.
        let parts: [ChatMessagePart] = [
            .text(id: "a1", text: "Hello."),
            .usage(id: "u1", stats: usageStats()),
        ]
        let nodes = WorkingSectionModel.renderNodes(from: parts)
        XCTAssertEqual(nodes.count, 2)
        XCTAssertNil(workingParts(of: nodes[0]))
        XCTAssertNil(workingParts(of: nodes[1]))
        XCTAssertEqual(nodes.map(\.id), ["a1", "u1"])
    }

    func testTwoWorkRunsSeparatedByTextCollapseIntoOneFold() {
        // Old behavior split this into two folds; the single-fold contract collapses
        // everything up to the LAST work part into ONE fold (interim text included).
        let parts: [ChatMessagePart] = [
            item("t1", .toolCall),
            .text(id: "x1", text: "midway"),
            item("t2", .toolCall),
        ]
        let nodes = WorkingSectionModel.renderNodes(from: parts)
        XCTAssertEqual(nodes.count, 1, "one fold spans up to the last work part")
        XCTAssertEqual(try XCTUnwrap(workingParts(of: nodes[0])).map(\.id), ["t1", "x1", "t2"])
    }

    func testSingleToolItemStillFolds() {
        let nodes = WorkingSectionModel.renderNodes(from: [item("t1", .toolCall)])
        XCTAssertEqual(nodes.count, 1)
        XCTAssertNotNil(workingParts(of: nodes[0]))
    }

    // MARK: - Eligibility (fold boundary)

    func testWorkingEligibility() {
        XCTAssertTrue(WorkingSectionModel.isWorkingEligible(.reasoning(id: "r", text: "x")))
        XCTAssertTrue(WorkingSectionModel.isWorkingEligible(item("t", .toolCall)))
        XCTAssertTrue(WorkingSectionModel.isWorkingEligible(item("e", .error)))
        XCTAssertTrue(WorkingSectionModel.isWorkingEligible(legacyTools("c")),
                      "classic .tools clusters are now work (they fold)")
        XCTAssertFalse(WorkingSectionModel.isWorkingEligible(.text(id: "x", text: "hi")),
                       "text is never itself work — interim text folds by position, not eligibility")
        XCTAssertFalse(WorkingSectionModel.isWorkingEligible(item("u", .usage)))
    }

    func testLastWorkIndexIsTheFoldBoundary() {
        let parts: [ChatMessagePart] = [
            .reasoning(id: "r1", text: "x"),
            legacyTools("c1"),
            .text(id: "a1", text: "answer"),
        ]
        XCTAssertEqual(WorkingSectionModel.lastWorkIndex(in: parts), 1)
        XCTAssertNil(WorkingSectionModel.lastWorkIndex(in: [.text(id: "a", text: "hi")]))
    }

    // MARK: - Failure surfacing

    func testRunHasFailureForFailedStatus() {
        let parts: [ChatMessagePart] = [
            item("t1", .toolCall, status: .completed),
            item("t2", .toolCall, status: .failed),
        ]
        XCTAssertTrue(WorkingSectionModel.runHasFailure(parts))
    }

    func testRunHasFailureForErrorType() {
        let parts: [ChatMessagePart] = [item("e1", .error, status: .completed)]
        XCTAssertTrue(WorkingSectionModel.runHasFailure(parts),
                      "an error item is a failure even if its status decoded to completed")
    }

    func testRunHasFailureAcrossClassicToolsCluster() {
        // A failed activity inside a classic `.tools` cluster must surface the
        // fold's failure badge just like a failed item.
        let parts: [ChatMessagePart] = [
            .tools(
                id: "c1",
                tools: [legacyTool("a", state: .done), legacyTool("b", state: .failed)],
                collapsed: false,
                turnElapsed: nil
            ),
        ]
        XCTAssertTrue(WorkingSectionModel.runHasFailure(parts),
                      "a failed classic-tool activity must not hide behind the fold")
    }

    func testCurrentWorkFollowsRunningClassicTool() {
        let parts: [ChatMessagePart] = [
            .tools(
                id: "c1",
                tools: [
                    legacyTool("a", name: "read_file", state: .done),
                    legacyTool("b", name: "bash", state: .running, argsSummary: "make test"),
                ],
                collapsed: false,
                turnElapsed: nil
            ),
        ]
        let current = WorkingSectionModel.currentWork(in: parts)
        XCTAssertEqual(current?.status, .inProgress)
        XCTAssertEqual(current?.summary, "Ran make test")
    }

    func testRunHasNoFailureWhenAllComplete() {
        let parts: [ChatMessagePart] = [
            item("t1", .toolCall, status: .completed),
            item("t2", .fileChange, status: .completed),
        ]
        XCTAssertFalse(WorkingSectionModel.runHasFailure(parts))
    }

    // MARK: - Duration + label

    func testRunDurationSumsItemDurations() {
        let parts: [ChatMessagePart] = [
            item("t1", .toolCall, body: ["duration_s": 0.4]),
            item("t2", .toolCall, body: ["duration_s": 1.1]),
        ]
        let seconds = WorkingSectionModel.runDurationSeconds(parts, settled: nil)
        XCTAssertEqual(try XCTUnwrap(seconds), 1.5, accuracy: 0.0001)
    }

    func testRunDurationPrefersSettledStamp() {
        let parts: [ChatMessagePart] = [item("t1", .toolCall, body: ["duration_s": 0.4])]
        XCTAssertEqual(WorkingSectionModel.runDurationSeconds(parts, settled: 42), 42)
    }

    func testRunDurationUsesClassicToolTurnElapsed() {
        let parts: [ChatMessagePart] = [
            .tools(id: "c1", tools: [legacyTool("a", durationMs: 400)], collapsed: false, turnElapsed: 3.5),
        ]
        XCTAssertEqual(try XCTUnwrap(WorkingSectionModel.runDurationSeconds(parts, settled: nil)), 3.5, accuracy: 0.0001)
    }

    func testRunDurationSumsClassicToolDurationsWhenNoTurnElapsed() {
        let parts: [ChatMessagePart] = [
            .tools(id: "c1", tools: [legacyTool("a", durationMs: 400), legacyTool("b", durationMs: 1_100)],
                   collapsed: false, turnElapsed: nil),
        ]
        XCTAssertEqual(try XCTUnwrap(WorkingSectionModel.runDurationSeconds(parts, settled: nil)), 1.5, accuracy: 0.0001)
    }

    func testWorkedLabelFormats() {
        XCTAssertEqual(WorkingSectionModel.workedLabel(seconds: nil), "Worked")
        XCTAssertEqual(WorkingSectionModel.workedLabel(seconds: 0), "Worked")
        XCTAssertEqual(WorkingSectionModel.workedLabel(seconds: 12), "Worked for 12s")
        XCTAssertEqual(WorkingSectionModel.workedLabel(seconds: 125), "Worked for 2m 5s")
    }

    func testSummaryAccessibilityLabelIncludesFailureClause() {
        XCTAssertEqual(
            WorkingSectionModel.summaryAccessibilityLabel(seconds: 12, hasFailure: false),
            "Worked for 12s"
        )
        XCTAssertEqual(
            WorkingSectionModel.summaryAccessibilityLabel(seconds: 12, hasFailure: true),
            "Worked for 12s, contains a failed step"
        )
    }

    // MARK: - Current tool line (live)

    func testCurrentWorkingItemPrefersInProgress() {
        let parts: [ChatMessagePart] = [
            item("t1", .toolCall, status: .completed),
            item("t2", .toolCall, status: .inProgress, summary: "grep"),
            item("t3", .toolCall, status: .completed),
        ]
        let current = WorkingSectionModel.currentWorkingItem(in: parts)
        XCTAssertEqual(current?.itemID, "t2", "the live line follows the in-progress tool")
    }

    func testCurrentWorkingItemFallsBackToLast() {
        let parts: [ChatMessagePart] = [
            item("t1", .toolCall, status: .completed),
            item("t2", .fileChange, status: .completed),
        ]
        XCTAssertEqual(WorkingSectionModel.currentWorkingItem(in: parts)?.itemID, "t2")
    }

    // MARK: - Step humanizer (approved design §2 — deterministic, no LLM)

    func testStepSummaryPrefersRelaySummary() {
        let it = ChatItem(itemID: "t1", type: .toolCall, status: .completed, ord: 0,
                          summary: "Ran alembic upgrade head",
                          body: ["name": "shell", "args": ["command": "alembic upgrade head"]])
        XCTAssertEqual(WorkingSectionModel.stepSummary(for: it), "Ran alembic upgrade head")
    }

    func testStepSummaryHumanizesReadFromArgs() {
        let it = ChatItem(itemID: "t1", type: .toolCall, status: .completed, ord: 0,
                          body: ["name": "read_file", "args": ["path": "auth.py"]])
        XCTAssertEqual(WorkingSectionModel.stepSummary(for: it), "Read auth.py")
    }

    func testStepSummaryHumanizesGrepFromPattern() {
        let it = ChatItem(itemID: "t1", type: .toolCall, status: .completed, ord: 0,
                          body: ["name": "grep", "args": ["pattern": "node_loop"]])
        XCTAssertEqual(WorkingSectionModel.stepSummary(for: it), "Grepped for node_loop")
    }

    func testStepSummaryHumanizesRunCommand() {
        let it = ChatItem(itemID: "t1", type: .toolCall, status: .completed, ord: 0,
                          body: ["name": "bash", "args": ["command": "alembic upgrade head"]])
        XCTAssertEqual(WorkingSectionModel.stepSummary(for: it), "Ran alembic upgrade head")
    }

    func testStepSummaryFileChangeUsesEditVerb() {
        let it = ChatItem(itemID: "f1", type: .fileChange, status: .completed, ord: 0,
                          body: ["name": "apply_patch", "args": ["path": "parser.swift"]])
        XCTAssertEqual(WorkingSectionModel.stepSummary(for: it), "Edited parser.swift")
    }

    func testStepSummaryFallsBackToPrettyToolName() {
        let it = ChatItem(itemID: "t1", type: ChatItemType(wire: "quantum_flux"), rawType: "quantum_flux",
                          status: .completed, ord: 0, body: ["name": "quantum_flux"])
        XCTAssertEqual(WorkingSectionModel.stepSummary(for: it), "Quantum flux")
    }

    func testStepSummaryCollapsesAndCapsLongTargets() {
        let long = String(repeating: "x", count: 200)
        let it = ChatItem(itemID: "t1", type: .toolCall, status: .completed, ord: 0,
                          body: .object(["name": .string("read"),
                                         "args": .object(["path": .string(long)])]))
        let summary = WorkingSectionModel.stepSummary(for: it)
        XCTAssertTrue(summary.hasPrefix("Read "))
        XCTAssertTrue(summary.hasSuffix("…"), "an over-long target is truncated with an ellipsis")
        XCTAssertLessThanOrEqual(summary.count, 80)
    }

    func testStepsBuildsReasoningThenToolInWireOrder() {
        let parts: [ChatMessagePart] = [
            .reasoning(id: "r1", text: "Reviewed the request\nand split the layers"),
            item("t1", .toolCall, body: ["name": "read", "args": ["path": "node.py"]]),
        ]
        let steps = WorkingSectionModel.steps(from: parts)
        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(steps[0].kind, .reasoning)
        XCTAssertEqual(steps[0].glyph, "bubble.left")
        XCTAssertEqual(steps[0].summary, "Reviewed the request")
        XCTAssertEqual(steps[0].body, "Reviewed the request\nand split the layers")
        XCTAssertEqual(steps[1].kind, .tool)
        XCTAssertEqual(steps[1].glyph, "terminal")
        XCTAssertEqual(steps[1].summary, "Read node.py")
    }

    func testStepsBuildOnePerClassicToolActivity() {
        // A classic `.tools` cluster expands to one step per activity, each with a
        // humanized summary and the terminal glyph (failed → triangle).
        let parts: [ChatMessagePart] = [
            .tools(
                id: "c1",
                tools: [
                    legacyTool("a", name: "read_file", state: .done, argsSummary: "auth.py"),
                    legacyTool("b", name: "bash", state: .failed, argsSummary: "make", resultPreview: "boom"),
                ],
                collapsed: false,
                turnElapsed: nil
            ),
        ]
        let steps = WorkingSectionModel.steps(from: parts)
        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(steps[0].kind, .tool)
        XCTAssertEqual(steps[0].glyph, "terminal")
        XCTAssertEqual(steps[0].summary, "Read auth.py")
        XCTAssertFalse(steps[0].isFailure)
        XCTAssertEqual(steps[1].summary, "Ran make")
        XCTAssertTrue(steps[1].isFailure)
        XCTAssertEqual(steps[1].glyph, "exclamationmark.triangle")
        XCTAssertEqual(steps[1].output, "boom")
    }

    func testStepsBuildNarrationStepFromInterimText() {
        let parts: [ChatMessagePart] = [
            .text(id: "n1", text: "Let me check the config.\nSecond line"),
            item("t1", .toolCall, body: ["name": "read", "args": ["path": "x.py"]]),
        ]
        let steps = WorkingSectionModel.steps(from: parts)
        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(steps[0].kind, .narration)
        XCTAssertEqual(steps[0].glyph, "text.alignleft")
        XCTAssertEqual(steps[0].summary, "Let me check the config.")
        XCTAssertEqual(steps[0].body, "Let me check the config.\nSecond line")
        XCTAssertEqual(steps[1].kind, .tool)
    }

    func testStepsSkipsEmptyReasoning() {
        let parts: [ChatMessagePart] = [
            .reasoning(id: "r1", text: "   "),
            item("t1", .toolCall, body: ["name": "read", "args": ["path": "x.py"]]),
        ]
        let steps = WorkingSectionModel.steps(from: parts)
        XCTAssertEqual(steps.count, 1, "an empty/whitespace reasoning part produces no step")
        XCTAssertEqual(steps[0].kind, .tool)
    }

    func testStepCarriesFailureAndOutputForSheet() {
        let it = ChatItem(itemID: "t1", type: .toolCall, status: .failed, ord: 0,
                          body: ["name": "bash", "args": ["command": "make"], "result": "error: boom"])
        let steps = WorkingSectionModel.steps(from: [.item(id: "t1", item: it)])
        XCTAssertEqual(steps.count, 1)
        XCTAssertTrue(steps[0].isFailure)
        XCTAssertEqual(steps[0].command, "make")
        XCTAssertEqual(steps[0].commandLanguage, "bash")
        XCTAssertEqual(steps[0].output, "error: boom")
    }

    func testGlyphMapping() {
        XCTAssertEqual(WorkingSectionModel.glyph(for: .toolCall), "terminal")
        XCTAssertEqual(WorkingSectionModel.glyph(for: .fileChange), "pencil")
        XCTAssertEqual(WorkingSectionModel.glyph(for: .browser), "safari")
        XCTAssertEqual(WorkingSectionModel.glyph(for: .image), "photo")
        XCTAssertEqual(WorkingSectionModel.glyph(for: .reasoning), "bubble.left")
    }
}
