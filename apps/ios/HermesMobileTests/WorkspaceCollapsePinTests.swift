import XCTest
@testable import HermesMobile

/// Unit tests for the workspace-group collapse/pin feature added to
/// ``SessionStore`` (feat/group-collapse-pin).
///
/// Coverage:
/// 1. **Collapse/expand** — ``SessionStore/toggleCollapsed(workspaceKey:)`` flips
///    a key in `collapsedWorkspaces` and persists it to UserDefaults.
/// 2. **Pin/unpin** — ``SessionStore/togglePinnedWorkspace(_:)`` flips a key in
///    `pinnedWorkspaceKeys` and persists it.
/// 3. **Pinned-group ordering in workspaceGroups()** — pinned groups are returned
///    first (hoisted tier), preserving recency order within each tier.
/// 4. **UserDefaults round-trip** — both sets survive a fresh `SessionStore()`.
@MainActor
final class WorkspaceCollapsePinTests: XCTestCase {

    // MARK: - Helpers

    private func cleanDefaults() {
        UserDefaults.standard.removeObject(forKey: DefaultsKeys.collapsedWorkspaces)
        UserDefaults.standard.removeObject(forKey: DefaultsKeys.pinnedWorkspaces)
        UserDefaults.standard.removeObject(forKey: DefaultsKeys.pinnedSessions)
    }

    private func makeStore() -> SessionStore {
        cleanDefaults()
        return SessionStore()
    }

    private func makeSummary(
        id: String,
        startedAt: Double? = nil,
        cwd: String? = nil
    ) -> SessionSummary {
        SessionSummary(
            id: id,
            title: nil,
            preview: nil,
            startedAt: startedAt,
            messageCount: nil,
            source: nil,
            lastActive: nil,
            cwd: cwd
        )
    }

    // MARK: - 1. Collapse / expand

    /// Fresh store: no workspaces are collapsed.
    func testCollapsedWorkspacesDefaultsEmpty() {
        let store = makeStore()
        XCTAssertTrue(store.collapsedWorkspaces.isEmpty,
            "collapsedWorkspaces must default to empty")
    }

    /// Toggling an uncollapsed key collapses it.
    func testToggleCollapsesExpandedGroup() {
        let store = makeStore()
        store.toggleCollapsed(workspaceKey: "/ws/alpha")
        XCTAssertTrue(store.collapsedWorkspaces.contains("/ws/alpha"),
            "After toggle, /ws/alpha must be in collapsedWorkspaces")
    }

    /// Toggling a collapsed key expands it.
    func testToggleExpandsCollapsedGroup() {
        let store = makeStore()
        store.toggleCollapsed(workspaceKey: "/ws/alpha")
        store.toggleCollapsed(workspaceKey: "/ws/alpha")
        XCTAssertFalse(store.collapsedWorkspaces.contains("/ws/alpha"),
            "Second toggle must remove /ws/alpha from collapsedWorkspaces")
    }

    /// Collapsing one workspace does not affect other workspaces.
    func testCollapseIsPerWorkspaceKey() {
        let store = makeStore()
        store.toggleCollapsed(workspaceKey: "/ws/alpha")
        XCTAssertFalse(store.collapsedWorkspaces.contains("/ws/beta"),
            "Collapsing /ws/alpha must not affect /ws/beta")
    }

    // MARK: - 2. Pin / unpin

    /// Fresh store: no workspaces are pinned.
    func testPinnedWorkspaceKeysDefaultsEmpty() {
        let store = makeStore()
        XCTAssertTrue(store.pinnedWorkspaceKeys.isEmpty,
            "pinnedWorkspaceKeys must default to empty")
    }

    /// Toggling an unpinned workspace pins it.
    func testTogglePinsWorkspace() {
        let store = makeStore()
        store.togglePinnedWorkspace("/ws/alpha")
        XCTAssertTrue(store.pinnedWorkspaceKeys.contains("/ws/alpha"),
            "After toggle, /ws/alpha must be in pinnedWorkspaceKeys")
    }

    /// Toggling a pinned workspace unpins it.
    func testToggleUnpinsWorkspace() {
        let store = makeStore()
        store.togglePinnedWorkspace("/ws/alpha")
        store.togglePinnedWorkspace("/ws/alpha")
        XCTAssertFalse(store.pinnedWorkspaceKeys.contains("/ws/alpha"),
            "Second toggle must remove /ws/alpha from pinnedWorkspaceKeys")
    }

    // MARK: - 3. Pinned groups are hoisted first in workspaceGroups()

    /// A pinned group that appears last in recency order is hoisted to position 0.
    func testPinnedGroupHoistsToTop() {
        let store = makeStore()
        // Recency order from unpinnedSessions: alpha (most recent), beta, gamma.
        store.sessions = [
            makeSummary(id: "a1", startedAt: 100, cwd: "/ws/alpha"),
            makeSummary(id: "b1", startedAt: 90,  cwd: "/ws/beta"),
            makeSummary(id: "g1", startedAt: 80,  cwd: "/ws/gamma"),
        ]
        // Pin gamma (recency-last).
        store.togglePinnedWorkspace("/ws/gamma")

        let groups = store.workspaceGroups()
        XCTAssertEqual(groups.first?.id, "/ws/gamma",
            "Pinned group must be returned first regardless of recency position")
        XCTAssertEqual(groups.map(\.id), ["/ws/gamma", "/ws/alpha", "/ws/beta"],
            "Pinned tier first, then recency order for unpinned")
    }

    /// Multiple pinned groups maintain recency order among themselves.
    func testMultiplePinnedGroupsPreserveRecencyOrderWithinTier() {
        let store = makeStore()
        store.sessions = [
            makeSummary(id: "a1", startedAt: 100, cwd: "/ws/alpha"),  // recency 0
            makeSummary(id: "b1", startedAt: 90,  cwd: "/ws/beta"),   // recency 1
            makeSummary(id: "g1", startedAt: 80,  cwd: "/ws/gamma"),  // recency 2
        ]
        // Pin alpha and gamma; beta stays unpinned.
        store.togglePinnedWorkspace("/ws/alpha")
        store.togglePinnedWorkspace("/ws/gamma")

        let groups = store.workspaceGroups()
        // Pinned tier: alpha (saw first in recency order), then gamma.
        // Unpinned tier: beta.
        XCTAssertEqual(groups.map(\.id), ["/ws/alpha", "/ws/gamma", "/ws/beta"],
            "Within the pinned tier, recency order is preserved (alpha before gamma)")
    }

    /// When no groups are pinned, workspaceGroups() is identical to the pre-pin
    /// recency-ordered output.
    func testNoPinsPreservesRecencyOrder() {
        let store = makeStore()
        store.sessions = [
            makeSummary(id: "a1", startedAt: 100, cwd: "/ws/alpha"),
            makeSummary(id: "b1", startedAt: 90,  cwd: "/ws/beta"),
        ]
        let groups = store.workspaceGroups()
        XCTAssertEqual(groups.map(\.id), ["/ws/alpha", "/ws/beta"],
            "Without pins, group order is pure recency (unchanged from H2 baseline)")
    }

    // MARK: - 4. UserDefaults round-trip

    /// collapsedWorkspaces survives a store reconstruction from UserDefaults.
    func testCollapsedWorkspacesPersists() {
        let store1 = makeStore()
        store1.toggleCollapsed(workspaceKey: "/ws/alpha")
        store1.toggleCollapsed(workspaceKey: "/ws/beta")

        // Reconstruct without cleaning defaults — simulates an app restart.
        let store2 = SessionStore()
        XCTAssertTrue(store2.collapsedWorkspaces.contains("/ws/alpha"),
            "collapsedWorkspaces must be restored from UserDefaults after restart")
        XCTAssertTrue(store2.collapsedWorkspaces.contains("/ws/beta"))

        cleanDefaults()
    }

    /// pinnedWorkspaceKeys survives a store reconstruction from UserDefaults.
    func testPinnedWorkspacesPersists() {
        let store1 = makeStore()
        store1.togglePinnedWorkspace("/ws/gamma")

        // Reconstruct without cleaning defaults.
        let store2 = SessionStore()
        XCTAssertTrue(store2.pinnedWorkspaceKeys.contains("/ws/gamma"),
            "pinnedWorkspaceKeys must be restored from UserDefaults after restart")

        cleanDefaults()
    }

    /// Unpinning a workspace removes it from the persisted set.
    func testUnpinnedWorkspaceRemovedFromDefaults() {
        let store1 = makeStore()
        store1.togglePinnedWorkspace("/ws/alpha")
        store1.togglePinnedWorkspace("/ws/alpha")  // unpin

        let store2 = SessionStore()
        XCTAssertFalse(store2.pinnedWorkspaceKeys.contains("/ws/alpha"),
            "Unpinned workspace must not appear in the restored store")

        cleanDefaults()
    }
}
