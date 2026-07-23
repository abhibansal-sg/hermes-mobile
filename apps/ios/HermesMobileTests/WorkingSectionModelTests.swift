import XCTest
@testable import HermesMobile

final class WorkingSectionModelTests: XCTestCase {
    private func tool(
        id: String = "tool-1",
        state: ToolActivity.State = .done,
        durationMs: Double? = 250
    ) -> ToolActivity {
        ToolActivity(
            id: id,
            name: "terminal",
            argsSummary: "device-check",
            progressText: "Checking",
            resultPreview: "connected",
            state: state,
            durationMs: durationMs,
            todos: nil,
            resultSummary: "Connected"
        )
    }

    func testReasoningAndToolsAreWork() {
        XCTAssertTrue(WorkingSectionModel.isWorkingEligible(.reasoning(id: "r", text: "Think")))
        XCTAssertTrue(WorkingSectionModel.isWorkingEligible(
            .tools(id: "t", tools: [tool()], collapsed: false, turnElapsed: nil)
        ))
        XCTAssertFalse(WorkingSectionModel.isWorkingEligible(.text(id: "a", text: "Answer")))
    }

    func testFinalTextStaysOutsideSingleWorkFold() throws {
        let parts: [ChatMessagePart] = [
            .reasoning(id: "r", text: "Think"),
            .tools(id: "t", tools: [tool()], collapsed: false, turnElapsed: nil),
            .text(id: "a", text: "Answer"),
        ]
        let nodes = WorkingSectionModel.renderNodes(from: parts)
        XCTAssertEqual(nodes.count, 2)
        guard case .working(_, let folded) = nodes[0] else { return XCTFail("expected work fold") }
        XCTAssertEqual(folded.count, 2)
        guard case .part(.text(_, let text)) = nodes[1] else { return XCTFail("expected final text") }
        XCTAssertEqual(text, "Answer")
    }

    func testCurrentWorkPrefersRunningTool() {
        let parts: [ChatMessagePart] = [.tools(
            id: "t",
            tools: [tool(id: "done"), tool(id: "running", state: .running)],
            collapsed: false,
            turnElapsed: nil
        )]
        XCTAssertEqual(WorkingSectionModel.currentWork(in: parts)?.status, .running)
    }

    func testDurationUsesTurnElapsedThenToolDurations() {
        let stamped: [ChatMessagePart] = [.tools(
            id: "t", tools: [tool()], collapsed: false, turnElapsed: 2
        )]
        XCTAssertEqual(WorkingSectionModel.runDurationSeconds(stamped, settled: nil), 2)

        let summed: [ChatMessagePart] = [.tools(
            id: "t", tools: [tool(durationMs: 250), tool(id: "tool-2", durationMs: 750)],
            collapsed: false,
            turnElapsed: nil
        )]
        XCTAssertEqual(WorkingSectionModel.runDurationSeconds(summed, settled: nil), 1)
    }

    func testToolFailureSurfacesInFoldAndStep() throws {
        let parts: [ChatMessagePart] = [.tools(
            id: "t", tools: [tool(state: .failed)], collapsed: false, turnElapsed: nil
        )]
        XCTAssertTrue(WorkingSectionModel.runHasFailure(parts))
        let step = try XCTUnwrap(WorkingSectionModel.steps(from: parts).first)
        XCTAssertTrue(step.isFailure)
        XCTAssertEqual(step.glyph, "exclamationmark.triangle")
    }
}
