import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Writes the home-screen widgets' data snapshot into the shared app group and
/// asks WidgetKit to refresh.
///
/// The widgets (X1: `StatusWidget`, `UsageWidget`) read ``SharedStore/WidgetSnapshot``
/// JSON from `group.ai.hermes.app`; this is the only writer of that key. The
/// snapshot is assembled from values the caller already has on hand — there is no
/// networking here — so the app stays the single source of truth and the widget
/// extension never needs gateway access.
///
/// All entry points are `@MainActor`: they're driven from the app's observable
/// stores, and `WidgetCenter.reloadAllTimelines()` is cheap and main-safe. Writes
/// are debounced-by-equality: an identical snapshot (ignoring `updatedAt`) is not
/// re-written, so high-frequency store mutations don't thrash WidgetKit reloads.
///
/// Hook points (the parent wires these; see integration notes):
/// - `ConnectionStore.phase` changes  → `connected` / `activeSessions`
/// - `InboxStore.pendingCount` changes → `pendingApprovals`
/// - `SessionStore.sessions` changes   → `activeSessions`
/// - a usage fetch on foreground       → `tokensToday` / `costTodayUSD`
@MainActor
enum WidgetSnapshotWriter {
    enum FieldPatch<Value> {
        case retain
        case set(Value)
        case clear
    }

    struct Patch {
        var serverScope: FieldPatch<String> = .retain
        var serverRevision: FieldPatch<String> = .retain
        var connectionState: FieldPatch<SharedStore.WidgetSnapshot.ConnectionState> = .retain
        var openSessionCount: FieldPatch<Int> = .retain
        var activeTurnCount: FieldPatch<Int> = .retain
        var pendingAttentionCount: FieldPatch<Int> = .retain
        var tokensToday: FieldPatch<Int> = .retain
        var costToday: FieldPatch<Double> = .retain
        var fetchedAt: FieldPatch<Date> = .retain
        var isStale: FieldPatch<Bool> = .retain
    }

    /// Last snapshot we wrote, used to skip no-op rewrites. Compared on the
    /// meaningful fields only (`updatedAt` always differs, so it's excluded).
    private static var lastWritten: SharedStore.WidgetSnapshot?

    /// Assemble a snapshot from the given inputs and publish it to the widgets.
    ///
    /// `updatedAt` is stamped here (`Date()`), so callers pass only the live
    /// values. Usage figures are optional — pass `nil` to leave whatever the last
    /// usage fetch published in place (see ``update(tokensToday:costTodayUSD:)``).
    ///
    /// - Parameters:
    ///   - connected: whether the gateway WebSocket is currently established.
    ///   - activeSessions: count of live sessions (server-reported or local).
    ///   - pendingApprovals: number of approval/clarify prompts awaiting the user.
    ///   - tokensToday: today's token total, if a usage fetch has resolved.
    ///   - costTodayUSD: today's estimated cost in USD, if available.
    static func write(_ patch: Patch, now: Date = Date()) {
        let disk = loadLatest(now: now)
        var snapshot = disk ?? SharedStore.WidgetSnapshot(
            serverScope: nil, serverRevision: nil, connectionState: .offline,
            openSessionCount: nil, activeTurnCount: nil, pendingAttentionCount: nil,
            tokensToday: nil, costToday: nil, fetchedAt: nil,
            writtenAt: now, isStale: true
        )
        apply(patch.serverScope, to: &snapshot.serverScope)
        apply(patch.serverRevision, to: &snapshot.serverRevision)
        apply(patch.connectionState, to: &snapshot.connectionState)
        applyNonnegative(patch.openSessionCount, to: &snapshot.openSessionCount)
        applyNonnegative(patch.activeTurnCount, to: &snapshot.activeTurnCount)
        applyNonnegative(patch.pendingAttentionCount, to: &snapshot.pendingAttentionCount)
        applyNonnegative(patch.tokensToday, to: &snapshot.tokensToday)
        apply(patch.costToday, to: &snapshot.costToday)
        apply(patch.fetchedAt, to: &snapshot.fetchedAt)
        apply(patch.isStale, to: &snapshot.isStale)
        if case .set(let proposed) = patch.serverRevision,
           let current = disk?.serverRevision,
           compareRevision(proposed, current) == .orderedAscending {
            return
        }
        snapshot.schemaVersion = SharedStore.WidgetSnapshot.currentSchemaVersion
        snapshot.writtenAt = now

        var comparable = snapshot
        comparable.writtenAt = disk?.writtenAt ?? now
        guard disk != comparable else { lastWritten = disk; return }
        guard persistAtomically(snapshot) else { return }
        lastWritten = snapshot // no-op optimization only; never a merge source
        reloadWidgets()
    }

    /// Update only the usage figures, carrying the rest of the last snapshot
    /// forward. Convenience for the foreground usage fetch hook, which knows
    /// nothing about connection/session/approval state.
    ///
    /// If nothing has been written yet, seeds a disconnected baseline so the
    /// usage values aren't dropped on the floor.
    static func update(tokensToday: Int?, costTodayUSD: Double?) {
        var patch = Patch()
        patch.tokensToday = tokensToday.map(FieldPatch.set) ?? .retain
        patch.costToday = costTodayUSD.map(FieldPatch.set) ?? .retain
        write(patch)
    }

    /// Forces the authoritative in-memory/disk snapshot through the atomic file
    /// writer before suspension. No network fetch or WidgetKit keepalive occurs.
    static func flush() {
        guard let snapshot = lastWritten ?? SharedStore.readSnapshot() else { return }
        if persistAtomically(snapshot) { lastWritten = snapshot }
    }

    /// True when any user-visible field differs (ignoring `updatedAt`), so we
    /// only touch WidgetKit when the widgets would actually render differently.
    private static func loadLatest(now: Date) -> SharedStore.WidgetSnapshot? {
        if let current = SharedStore.readSnapshot() { return current }
        guard let data = SharedStore.defaults?.data(forKey: SharedStore.snapshotKey),
              let legacy = try? JSONDecoder().decode(LegacySnapshot.self, from: data) else { return nil }
        let migrated = SharedStore.WidgetSnapshot(
            serverScope: nil, serverRevision: nil,
            connectionState: legacy.connected ? .connected : .offline,
            openSessionCount: legacy.activeSessions,
            activeTurnCount: nil, pendingAttentionCount: legacy.pendingApprovals,
            tokensToday: legacy.tokensToday, costToday: legacy.costTodayUSD,
            fetchedAt: legacy.updatedAt, writtenAt: now, isStale: true
        )
        if persistAtomically(migrated) {
            SharedStore.defaults?.removeObject(forKey: SharedStore.snapshotKey)
        }
        return migrated
    }

    private struct LegacySnapshot: Codable {
        var connected: Bool
        var activeSessions: Int
        var pendingApprovals: Int
        var tokensToday: Int?
        var costTodayUSD: Double?
        var updatedAt: Date
    }

    private static func apply<T>(_ patch: FieldPatch<T>, to value: inout T?) {
        switch patch { case .retain: break; case .set(let new): value = new; case .clear: value = nil }
    }

    private static func apply<T>(_ patch: FieldPatch<T>, to value: inout T) {
        if case .set(let new) = patch { value = new }
    }

    private static func applyNonnegative(_ patch: FieldPatch<Int>, to value: inout Int?) {
        switch patch { case .retain: break; case .set(let new): value = max(0, new); case .clear: value = nil }
    }

    private static func compareRevision(_ lhs: String, _ rhs: String) -> ComparisonResult {
        if let left = Int64(lhs), let right = Int64(rhs) {
            if left < right { return .orderedAscending }
            if left > right { return .orderedDescending }
            return .orderedSame
        }
        return lhs.compare(rhs, options: .numeric)
    }

    private static func persistAtomically(_ snapshot: SharedStore.WidgetSnapshot) -> Bool {
        guard let destination = SharedStore.snapshotURL,
              let data = try? JSONEncoder().encode(snapshot) else { return false }
        let fm = FileManager.default
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fm.moveItem(at: temporary, to: destination)
            }
            return true
        } catch {
            try? fm.removeItem(at: temporary)
            return false
        }
    }

    private static func reloadWidgets() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}
