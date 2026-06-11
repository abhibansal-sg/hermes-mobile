import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

/// Indexes the session list into Spotlight (Core Spotlight) and mints
/// `NSUserActivity` handles for Handoff-lite continuation of the open session.
///
/// ## Spotlight
/// Sessions are indexed as `CSSearchableItem`s under a single domain
/// (``domainIdentifier``) so the whole set can be re-published or wiped in one
/// call. The integrator calls ``index(sessions:)`` from `SessionStore.refresh`
/// after the list lands; rows the user deletes/archives are reconciled by the
/// same wholesale republish (the domain is cleared and rewritten), so no
/// per-row delete bookkeeping is required. A tapped Spotlight result re-opens
/// the app with the session's `stored_session_id` carried in the
/// `userInfo`/`uniqueIdentifier`; ``sessionId(fromSpotlight:)`` decodes it.
///
/// ## Handoff-lite
/// ``userActivity(for:)`` builds a searchable, Handoff-eligible `NSUserActivity`
/// that the open session view adopts (`.userActivity(...)`), advertising the
/// active session so a peer device (or a Spotlight tap) can resume it.
/// ``sessionId(fromActivity:)`` reads the id back out on the receiving side.
///
/// All Core Spotlight work is dispatched off the calling actor (the framework's
/// index is thread-safe), so the type is `nonisolated` and its entry points can
/// be called from `SessionStore` (the main actor) without a hop. The methods
/// touch only thread-safe Core Spotlight APIs and immutable `Sendable` inputs.
enum SpotlightIndexer {
    /// Domain grouping every session item, so the set can be republished or
    /// purged atomically.
    static let domainIdentifier = "ai.hermes.app.sessions"

    /// Activity type advertised for an open session (must also be listed under
    /// `NSUserActivityTypes` in Info.plist — see integration notes).
    static let openSessionActivityType = "ai.hermes.app.openSession"

    /// `userInfo` / Spotlight key carrying the `stored_session_id`.
    static let sessionIdKey = "sessionId"

    /// Prefix on the `CSSearchableItem.uniqueIdentifier` so a Spotlight tap can
    /// be told apart from other item namespaces and the raw id recovered.
    private static let itemPrefix = "session:"

    // MARK: - Indexing

    /// Republish the full session set into Spotlight: clears the domain, then
    /// indexes the current rows (title + preview). Best-effort — indexing
    /// failures are swallowed so they never block a list refresh.
    ///
    /// Cron/automation sessions are skipped: they are machine-generated and
    /// would flood the user's Spotlight results.
    static func index(sessions: [SessionSummary]) {
        // Capture only the Sendable `[SessionSummary]` across the actor hop and
        // build the (non-Sendable) `CSSearchableItem`s inside the detached task,
        // so nothing un-Sendable crosses the boundary under strict concurrency.
        let rows = sessions.filter { ($0.source ?? "").lowercased() != "cron" }
        let domain = domainIdentifier

        Task.detached(priority: .utility) {
            let items = rows.map(searchableItem(for:))
            let index = CSSearchableIndex.default()
            // Wipe the domain first so deleted/archived sessions disappear, then
            // republish the current set. Both steps are best-effort.
            await withCheckedContinuation { continuation in
                index.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in
                    continuation.resume()
                }
            }
            guard !items.isEmpty else { return }
            await withCheckedContinuation { continuation in
                index.indexSearchableItems(items) { _ in
                    continuation.resume()
                }
            }
        }
    }

    /// Remove every Hermes session item from Spotlight (e.g. on sign-out /
    /// disconnect). Best-effort.
    static func clearAll() {
        let domain = domainIdentifier
        Task.detached(priority: .utility) {
            await withCheckedContinuation { continuation in
                CSSearchableIndex.default()
                    .deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in
                        continuation.resume()
                    }
            }
        }
    }

    /// Build the Spotlight item for a single session.
    private static func searchableItem(for summary: SessionSummary) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = summary.displayTitle
        if let preview = summary.preview, !preview.isEmpty {
            attributes.contentDescription = preview
        }
        if let date = summary.displayDate {
            attributes.contentModificationDate = date
        }
        // Keyword hooks so "hermes" / the source surface the session.
        var keywords = ["Hermes"]
        if let source = summary.source, !source.isEmpty {
            keywords.append(source)
        }
        attributes.keywords = keywords

        let item = CSSearchableItem(
            uniqueIdentifier: itemPrefix + summary.id,
            domainIdentifier: domainIdentifier,
            attributeSet: attributes
        )
        return item
    }

    // MARK: - Handoff-lite (NSUserActivity)

    /// Build a Handoff-eligible, Spotlight-searchable activity advertising an
    /// open session. The session view adopts it via `.userActivity(...)`; on a
    /// peer device the activity is handed off and ``sessionId(fromActivity:)``
    /// recovers the id to resume.
    static func userActivity(for summary: SessionSummary) -> NSUserActivity {
        let activity = NSUserActivity(activityType: openSessionActivityType)
        activity.title = summary.displayTitle
        activity.userInfo = [sessionIdKey: summary.id]
        activity.requiredUserInfoKeys = [sessionIdKey]
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = true
        activity.persistentIdentifier = itemPrefix + summary.id

        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = summary.displayTitle
        if let preview = summary.preview, !preview.isEmpty {
            attributes.contentDescription = preview
        }
        activity.contentAttributeSet = attributes
        return activity
    }

    // MARK: - Decoding a continuation

    /// Recover a `stored_session_id` from a Spotlight-result continuation
    /// (`CSSearchableItemActionType`). Returns `nil` for unrelated activities.
    static func sessionId(fromSpotlight userInfo: [AnyHashable: Any]) -> String? {
        guard let identifier = userInfo[CSSearchableItemActivityIdentifier] as? String,
              identifier.hasPrefix(itemPrefix) else {
            return nil
        }
        return String(identifier.dropFirst(itemPrefix.count))
    }

    /// Recover a `stored_session_id` from a handed-off / restored
    /// `NSUserActivity`. Handles both the Handoff activity (id in `userInfo`)
    /// and a Spotlight-result tap delivered through the same activity object.
    static func sessionId(fromActivity activity: NSUserActivity) -> String? {
        if activity.activityType == CSSearchableItemActionType {
            return sessionId(fromSpotlight: activity.userInfo ?? [:])
        }
        if activity.activityType == openSessionActivityType,
           let id = activity.userInfo?[sessionIdKey] as? String, !id.isEmpty {
            return id
        }
        return nil
    }
}
