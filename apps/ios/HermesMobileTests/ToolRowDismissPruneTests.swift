import XCTest
@testable import HermesMobile

/// STR-1259 (STR-518 hardening) — the *body-level* dismissed-id pruning invariant.
///
/// `ToolClusterView` deliberately attaches `prunedDismissedIDs(_:toolIDs:)` at the
/// BODY level (see `ToolActivityRow.swift`, the `.onChange(of: tools.map(\.id))`
/// comment above the body) rather than inside `liveCluster`, so a stale dismissed
/// id can never survive a tool-id change — including in the collapsed/summary path
/// that never mounts `liveCluster`.
///
/// `RenderingTests.testPrunedDismissedIDsDropsStaleHides` already covers the pure
/// intersection for a single call. This file covers the harder invariant the
/// body-level attach was written to prevent: across a *tool-set change*, a
/// dismissed id for a now-absent tool is dropped so it cannot resurrect and hide a
/// NEW row that reuses a colliding id, while an id still present stays dismissed
/// across the re-render.
final class ToolRowDismissPruneTests: XCTestCase {

    /// Models the persisted `@State private var dismissedToolIDs` across renders:
    /// every tool-id change re-prunes the retained set exactly as the body-level
    /// `.onChange` does. This is the whole point of the body-level attach — the set
    /// is session-local and repruned on each tool-list mutation, not rebuilt.
    private struct DismissState {
        private(set) var dismissed: Set<String> = []

        /// A tool-id change fires the body-level prune against the new tool list.
        mutating func render(tools toolIDs: [String]) {
            dismissed = ToolClusterView.prunedDismissedIDs(dismissed, toolIDs: Set(toolIDs))
        }

        /// User dismisses a terminal row.
        mutating func dismiss(_ id: String) {
            dismissed.insert(id)
        }
    }

    // MARK: - (1) A dismissed id for a now-absent tool is pruned to empty

    func testDismissedIdIsPrunedWhenItsToolLeavesTheCluster() {
        var model = DismissState()
        // Cluster shows two finished tools; the user hides A.
        model.render(tools: ["A", "B"])
        model.dismiss("A")
        XCTAssertEqual(model.dismissed, ["A"], "A should be hidden after dismissal")

        // The tool set CHANGES so A is gone (e.g. a fresh turn / replaced call).
        model.render(tools: ["B", "C"])
        XCTAssertTrue(model.dismissed.isEmpty,
                      "A hide for a tool no longer in the cluster must be pruned, leaving the dismissed set empty")
    }

    // MARK: - (2) A new tool reusing the colliding id is NOT resurrected-into-hidden

    func testNewToolWithCollidingIdIsNotHidden() {
        var model = DismissState()
        // Hide A, then A's tool leaves the cluster — this prunes the hide.
        model.render(tools: ["A", "B"])
        model.dismiss("A")
        model.render(tools: ["B", "C"])
        XCTAssertTrue(model.dismissed.isEmpty, "precondition: A was pruned when it left")

        // A brand-new tool call reuses the id "A". Because the stale hide was
        // pruned, the fresh row must be VISIBLE — the exact resurrection the
        // body-level attach prevents.
        model.render(tools: ["A", "C"])
        XCTAssertFalse(model.dismissed.contains("A"),
                       "A new tool reusing a previously-dismissed id must not inherit the stale hide")
    }

    // MARK: - (3) An id still present stays dismissed across a re-render

    func testDismissedIdStillPresentSurvivesRerender() {
        var model = DismissState()
        model.render(tools: ["A", "B"])
        model.dismiss("B")
        XCTAssertEqual(model.dismissed, ["B"])

        // A pure re-render with B still present must keep B hidden.
        model.render(tools: ["A", "B"])
        XCTAssertEqual(model.dismissed, ["B"], "A hide must survive a re-render while its tool is still present")

        // Growing the cluster (B still present) must also keep B hidden while a
        // co-present sibling A is untouched.
        model.render(tools: ["A", "B", "C"])
        XCTAssertEqual(model.dismissed, ["B"],
                       "B stays dismissed and no other present id is spuriously hidden as the cluster grows")
    }
}
