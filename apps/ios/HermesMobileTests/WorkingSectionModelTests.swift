import XCTest
@testable import HermesMobile

/// Wave-2 collapsed working-sections (owner spec) — deterministic coverage of the
/// pure grouping + summary model that `WorkingSectionView` renders from. No
/// SwiftUI, no I/O: every rule is a `nonisolated static` over value types.
///
/// The load-bearing invariant here is COMPAT: the fold is item-model only, so a
/// legacy turn (reasoning + a `.tools` cluster + text) must NOT fold into a
/// working section — it decomposes back to the exact parts the old renderer drew.
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

    // MARK: - Grouping

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

    func testLegacyReasoningToolsTextDoesNotFold() {
        // COMPAT: a legacy blob-stream turn (reasoning → legacy .tools → text)
        // must decompose to individual parts — the `.tools` cluster keeps its own
        // `ToolClusterView` rendering and NOTHING folds.
        let parts: [ChatMessagePart] = [
            .reasoning(id: "r1", text: "thinking"),
            legacyTools("c1"),
            .text(id: "x1", text: "Done."),
        ]
        let nodes = WorkingSectionModel.renderNodes(from: parts)
        XCTAssertEqual(nodes.count, 3, "legacy turn must not fold")
        for node in nodes {
            XCTAssertNil(workingParts(of: node), "no working node may be produced for the legacy path")
        }
        XCTAssertEqual(nodes.map(\.id), ["r1", "c1", "x1"])
    }

    func testReasoningOnlyRunDecomposesToParts() {
        // A pure-thinking run (no items) must NOT become a "Worked for N" fold;
        // it decomposes so `ThinkingView` renders it as today.
        let parts: [ChatMessagePart] = [.reasoning(id: "r1", text: "just thinking")]
        let nodes = WorkingSectionModel.renderNodes(from: parts)
        XCTAssertEqual(nodes.count, 1)
        XCTAssertNil(workingParts(of: nodes[0]))
    }

    func testTextBreaksWorkingRunsIntoSeparateFolds() {
        let parts: [ChatMessagePart] = [
            item("t1", .toolCall),
            .text(id: "x1", text: "midway"),
            item("t2", .toolCall),
        ]
        let nodes = WorkingSectionModel.renderNodes(from: parts)
        XCTAssertEqual(nodes.count, 3)
        XCTAssertNotNil(workingParts(of: nodes[0]))
        XCTAssertNil(workingParts(of: nodes[1]))
        XCTAssertNotNil(workingParts(of: nodes[2]))
    }

    func testSingleToolItemStillFolds() {
        let nodes = WorkingSectionModel.renderNodes(from: [item("t1", .toolCall)])
        XCTAssertEqual(nodes.count, 1)
        XCTAssertNotNil(workingParts(of: nodes[0]))
    }

    // MARK: - Eligibility

    func testWorkingEligibility() {
        XCTAssertTrue(WorkingSectionModel.isWorkingEligible(.reasoning(id: "r", text: "x")))
        XCTAssertTrue(WorkingSectionModel.isWorkingEligible(item("t", .toolCall)))
        XCTAssertTrue(WorkingSectionModel.isWorkingEligible(item("e", .error)))
        XCTAssertFalse(WorkingSectionModel.isWorkingEligible(.text(id: "x", text: "hi")))
        XCTAssertFalse(WorkingSectionModel.isWorkingEligible(legacyTools("c")),
                       "legacy .tools clusters are never working-eligible")
        XCTAssertFalse(WorkingSectionModel.isWorkingEligible(item("u", .usage)))
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
