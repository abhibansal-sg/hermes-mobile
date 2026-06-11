import XCTest
@testable import HermesMobile

/// ABH-87 Batch D — render contract: per-cluster collapse (§3.2), turn-aware
/// spacing (§3.4). These exercise the PURE, testable surfaces of the render
/// contract (the SwiftUI-bound auto-open thinking and the action-row gate are
/// covered structurally elsewhere — ProtocolParityABH46Tests — since the test
/// target has no view-inspection harness).
@MainActor
final class RenderContractBatchDTests: XCTestCase {

    // MARK: - §3.2 per-cluster collapse (model-level)

    /// Build an assistant message whose parts are exactly the given (text/tools)
    /// shape, then settle it. `tools` clusters carry the listed tool count.
    private func toolActivity(_ id: String) -> ToolActivity {
        ToolActivity(id: id, name: "shell", argsSummary: "", progressText: "",
                     resultPreview: "ok", state: .done, durationMs: 100, todos: nil)
    }

    /// text→toolA→text→toolB → TWO single-tool clusters → NEITHER collapses.
    func testPerClusterCollapse_interleavedSingleToolClustersStayExpanded() {
        var message = ChatMessage(role: .assistant, parts: [
            .text(id: "m-text-0", text: "A "),
            .tools(id: "c1", tools: [toolActivity("c1")], collapsed: false, turnElapsed: nil),
            .text(id: "m-text-1", text: "B "),
            .tools(id: "c2", tools: [toolActivity("c2")], collapsed: false, turnElapsed: nil),
        ])
        message.collapseFinishedToolClusters(turnElapsed: 3.0)

        let collapses = message.parts.compactMap { part -> Bool? in
            if case .tools(_, _, let collapsed, _) = part { return collapsed }
            return nil
        }
        XCTAssertEqual(collapses, [false, false],
                       "two single-tool clusters never collapse (per-cluster, §3.2)")
        XCTAssertFalse(message.toolsCollapsed, "no cluster collapsed → derived flag false")
    }

    /// Consecutive toolA,toolB (one cluster of 2) → ONE collapsed cluster.
    func testPerClusterCollapse_consecutiveToolsCollapseAsOne() {
        var message = ChatMessage(role: .assistant, parts: [
            .tools(id: "c1", tools: [toolActivity("c1"), toolActivity("c2")],
                   collapsed: false, turnElapsed: nil),
        ])
        message.collapseFinishedToolClusters(turnElapsed: 5.0)

        guard case .tools(_, let tools, let collapsed, let elapsed) = message.parts.first else {
            return XCTFail("expected one tools cluster")
        }
        XCTAssertEqual(tools.count, 2, "the cluster carries both tools")
        XCTAssertTrue(collapsed, "a ≥2-tool cluster collapses")
        XCTAssertEqual(elapsed, 5.0, "the turn wall-clock labels the collapsed summary")
        XCTAssertTrue(message.toolsCollapsed)
    }

    /// A mixed turn: one single-tool cluster (stays expanded) AND one two-tool
    /// cluster (collapses). The per-cluster decision is independent per cluster.
    func testPerClusterCollapse_mixedClustersDecideIndependently() {
        var message = ChatMessage(role: .assistant, parts: [
            .tools(id: "solo", tools: [toolActivity("solo")], collapsed: false, turnElapsed: nil),
            .text(id: "m-text-0", text: "between "),
            .tools(id: "pair", tools: [toolActivity("p1"), toolActivity("p2")],
                   collapsed: false, turnElapsed: nil),
        ])
        message.collapseFinishedToolClusters(turnElapsed: 2.0)

        let collapses = message.parts.compactMap { part -> Bool? in
            if case .tools(_, _, let collapsed, _) = part { return collapsed }
            return nil
        }
        XCTAssertEqual(collapses, [false, true],
                       "single-tool cluster expanded, two-tool cluster collapsed")
        // The whole-turn elapsed is attached only to the collapsed cluster.
        let elapsedByCluster = message.parts.compactMap { part -> TimeInterval?? in
            if case .tools(_, _, _, let e) = part { return .some(e) }
            return nil
        }
        XCTAssertEqual(elapsedByCluster.count, 2)
        XCTAssertNil(elapsedByCluster[0] ?? nil, "expanded single-tool cluster carries no summary elapsed")
        XCTAssertEqual(elapsedByCluster[1] ?? nil, 2.0, "collapsed cluster carries the turn elapsed")
    }

    // MARK: - §3.4 turn-aware spacing

    private func msg(_ role: ChatRole, collapsed: Bool = false) -> ChatMessage {
        ChatMessage(role: role, text: "x",
                    presentation: collapsed ? .collapsed(label: "scaffold") : .normal)
    }

    func testTopGap_firstRowHasNoGap() {
        XCTAssertEqual(ChatView.topGap(above: msg(.user), after: nil), 0)
    }

    func testTopGap_newUserRowOpensTurnWithLargerGap() {
        // assistant (end of previous turn) → user (new turn) = inter-turn gap.
        XCTAssertEqual(ChatView.topGap(above: msg(.user), after: msg(.assistant)),
                       ChatView.interTurnGap)
    }

    func testTopGap_assistantAfterUserIsTightIntraTurnGap() {
        XCTAssertEqual(ChatView.topGap(above: msg(.assistant), after: msg(.user)),
                       ChatView.intraTurnGap)
    }

    func testTopGap_assistantAfterAssistantStaysIntraTurn() {
        XCTAssertEqual(ChatView.topGap(above: msg(.assistant), after: msg(.assistant)),
                       ChatView.intraTurnGap)
    }

    func testTopGap_systemRowGetsScaffoldingGap() {
        XCTAssertEqual(ChatView.topGap(above: msg(.system), after: msg(.user)),
                       ChatView.scaffoldingGap)
        XCTAssertEqual(ChatView.topGap(above: msg(.user), after: msg(.system)),
                       ChatView.scaffoldingGap)
    }

    func testTopGap_collapsedScaffoldingGetsScaffoldingGap() {
        // A collapsed (cron/system-prompt) row sits outside the turn rhythm even
        // when its role is user/assistant.
        XCTAssertEqual(ChatView.topGap(above: msg(.user, collapsed: true), after: msg(.assistant)),
                       ChatView.scaffoldingGap)
    }

    func testScaffoldingClassification() {
        XCTAssertTrue(ChatView.isScaffolding(msg(.system)))
        XCTAssertTrue(ChatView.isScaffolding(msg(.user, collapsed: true)))
        XCTAssertFalse(ChatView.isScaffolding(msg(.user)))
        XCTAssertFalse(ChatView.isScaffolding(msg(.assistant)))
    }

    func testSpacingConstants_intraIsTighterThanInter() {
        XCTAssertLessThan(ChatView.intraTurnGap, ChatView.interTurnGap,
                          "intra-turn rhythm must be tighter than the gap between turns")
        XCTAssertGreaterThanOrEqual(ChatView.scaffoldingGap, ChatView.interTurnGap,
                                    "scaffolding rows are set apart at least as far as turns")
    }
}
