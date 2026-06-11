import XCTest
@testable import HermesMobile

/// Coverage for UI Batch H2 workspace grouping: ``SessionSummary`` `cwd` decode
/// + workspace key/label derivation, and ``SessionStore/workspaceGroups()``
/// ordering rules (recency group order, `startedAt` DESC within a group, the
/// no-workspace bucket, pinned exclusion, and the cron filter applying inside
/// groups). Replicates the desktop sidebar's `workspaceGroupsFor` semantics
/// (apps/desktop/src/app/chat/sidebar/index.tsx).
final class WorkspaceGroupingTests: XCTestCase {

    // MARK: - cwd decode

    func testSessionSummaryDecodesCwdFromRestRow() {
        let row: JSONValue = [
            "id": "s1",
            "started_at": 1_700_000_000.0,
            "cwd": "/Users/me/code/hermes"
        ]
        let summary = row.decoded(as: SessionSummary.self)
        XCTAssertEqual(summary?.id, "s1")
        XCTAssertEqual(summary?.cwd, "/Users/me/code/hermes")
    }

    func testSessionSummaryCwdDecodesNilWhenAbsent() {
        // The WS `session.list` RPC shape omits cwd.
        let row: JSONValue = ["id": "s2", "started_at": 1.0]
        let summary = row.decoded(as: SessionSummary.self)
        XCTAssertNotNil(summary)
        XCTAssertNil(summary?.cwd)
    }

    // MARK: - workspaceKey / workspaceLabel / basename

    func testWorkspaceKeyTrimsAndFallsBackToSentinel() {
        XCTAssertEqual(makeSummary(cwd: "/a/b/proj").workspaceKey, "/a/b/proj")
        XCTAssertEqual(makeSummary(cwd: "  /a/b/proj  ").workspaceKey, "/a/b/proj")
        XCTAssertEqual(makeSummary(cwd: nil).workspaceKey, SessionSummary.noWorkspaceKey)
        XCTAssertEqual(makeSummary(cwd: "   ").workspaceKey, SessionSummary.noWorkspaceKey)
    }

    func testWorkspaceLabelIsBasenameElseNoWorkspace() {
        XCTAssertEqual(makeSummary(cwd: "/Users/me/code/hermes").workspaceLabel, "hermes")
        // Trailing separators are stripped before taking the basename.
        XCTAssertEqual(makeSummary(cwd: "/Users/me/code/hermes/").workspaceLabel, "hermes")
        // Windows-style separators are honoured too.
        XCTAssertEqual(makeSummary(cwd: #"C:\Users\me\proj"#).workspaceLabel, "proj")
        // A root-only path has no basename, so it falls back to the full path
        // verbatim — matching the desktop `baseName(path) || path || 'No workspace'`
        // (baseName("/") is undefined, so `path` ("/") wins, NOT "No workspace").
        XCTAssertEqual(makeSummary(cwd: "/").workspaceLabel, "/")
        // Only a blank / absent cwd reaches the "No workspace" fallback.
        XCTAssertEqual(makeSummary(cwd: nil).workspaceLabel, SessionSummary.noWorkspaceLabel)
        XCTAssertEqual(makeSummary(cwd: "   ").workspaceLabel, SessionSummary.noWorkspaceLabel)
    }

    func testBasenameHelper() {
        XCTAssertEqual(SessionSummary.basename(of: "/a/b/c"), "c")
        XCTAssertEqual(SessionSummary.basename(of: "/a/b/c/"), "c")
        XCTAssertEqual(SessionSummary.basename(of: "solo"), "solo")
        XCTAssertNil(SessionSummary.basename(of: "/"))
        XCTAssertNil(SessionSummary.basename(of: ""))
    }

    // MARK: - workspaceGroups() ordering

    @MainActor
    func testGroupsKeepRecencyOrderFromInput() {
        let store = SessionStore()
        // REST `order=recent` order: alpha first (most recent), then beta, then
        // alpha again (older). Group order must be first-seen: alpha, beta.
        store.sessions = [
            makeSummary(id: "a1", startedAt: 100, cwd: "/ws/alpha"),
            makeSummary(id: "b1", startedAt: 90, cwd: "/ws/beta"),
            makeSummary(id: "a2", startedAt: 80, cwd: "/ws/alpha"),
        ]
        let groups = store.workspaceGroups()
        XCTAssertEqual(groups.map(\.id), ["/ws/alpha", "/ws/beta"])
        XCTAssertEqual(groups.map(\.label), ["alpha", "beta"])
    }

    @MainActor
    func testRowsWithinGroupSortByStartedAtDescending() {
        let store = SessionStore()
        // Input arrives in recency (last_active) order, NOT creation order, so
        // the within-group startedAt-DESC sort must reorder them.
        store.sessions = [
            makeSummary(id: "old-created", startedAt: 10, cwd: "/ws/alpha"),
            makeSummary(id: "new-created", startedAt: 50, cwd: "/ws/alpha"),
            makeSummary(id: "mid-created", startedAt: 30, cwd: "/ws/alpha"),
        ]
        let groups = store.workspaceGroups()
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(
            groups[0].sessions.map(\.id),
            ["new-created", "mid-created", "old-created"]
        )
    }

    @MainActor
    func testNoWorkspaceBucketGetsSentinelKeyAndLabel() {
        let store = SessionStore()
        store.sessions = [
            makeSummary(id: "n1", startedAt: 5, cwd: nil),
            makeSummary(id: "n2", startedAt: 9, cwd: "   "),
            makeSummary(id: "w1", startedAt: 7, cwd: "/ws/proj"),
        ]
        let groups = store.workspaceGroups()
        // First-seen: the no-workspace bucket (from n1), then /ws/proj.
        XCTAssertEqual(groups.map(\.id), [SessionSummary.noWorkspaceKey, "/ws/proj"])
        let noWs = groups.first { $0.id == SessionSummary.noWorkspaceKey }
        XCTAssertEqual(noWs?.label, SessionSummary.noWorkspaceLabel)
        // Both blank-cwd rows land in the no-workspace bucket, startedAt DESC.
        XCTAssertEqual(noWs?.sessions.map(\.id), ["n2", "n1"])
    }

    @MainActor
    func testPinnedSessionsExcludedFromGroups() {
        // Pins persist in UserDefaults; clear so a prior run can't leave "p1"
        // already pinned (a second toggle would then UNpin it).
        UserDefaults.standard.removeObject(forKey: DefaultsKeys.pinnedSessions)
        let store = SessionStore()
        store.sessions = [
            makeSummary(id: "p1", startedAt: 100, cwd: "/ws/alpha"),
            makeSummary(id: "u1", startedAt: 90, cwd: "/ws/alpha"),
        ]
        store.togglePin(makeSummary(id: "p1", startedAt: 100, cwd: "/ws/alpha"))
        XCTAssertTrue(store.isPinned(makeSummary(id: "p1")))
        let groups = store.workspaceGroups()
        XCTAssertEqual(groups.count, 1)
        // The pinned session is gone; only the unpinned row remains in the group.
        XCTAssertEqual(groups[0].sessions.map(\.id), ["u1"])
        UserDefaults.standard.removeObject(forKey: DefaultsKeys.pinnedSessions)
    }

    @MainActor
    func testCronFilterAppliesInsideGroups() {
        let store = SessionStore()
        store.sessions = [
            makeSummary(id: "human", startedAt: 50, cwd: "/ws/alpha", source: "telegram"),
            makeSummary(id: "robot", startedAt: 40, cwd: "/ws/alpha", source: "cron"),
        ]
        store.hideCron = true
        let groups = store.workspaceGroups()
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].sessions.map(\.id), ["human"])
    }

    @MainActor
    func testGroupByWorkspaceDefaultsFalseAndPersists() {
        // Clean the key so the default-false assertion is meaningful.
        UserDefaults.standard.removeObject(forKey: DefaultsKeys.groupByWorkspace)
        let store = SessionStore()
        XCTAssertFalse(store.groupByWorkspace)
        store.groupByWorkspace = true
        XCTAssertTrue(UserDefaults.standard.bool(forKey: DefaultsKeys.groupByWorkspace))
        UserDefaults.standard.removeObject(forKey: DefaultsKeys.groupByWorkspace)
    }

    // MARK: - Fixtures

    private func makeSummary(
        id: String = "id",
        startedAt: Double? = nil,
        cwd: String? = nil,
        source: String? = nil
    ) -> SessionSummary {
        SessionSummary(
            id: id,
            title: nil,
            preview: nil,
            startedAt: startedAt,
            messageCount: nil,
            source: source,
            lastActive: nil,
            cwd: cwd
        )
    }
}
