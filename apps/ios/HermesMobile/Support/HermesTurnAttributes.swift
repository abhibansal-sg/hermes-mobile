import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Canonical Live Activity attributes for an in-flight Hermes turn.
///
/// This is the **single source of truth** for the activity's static + dynamic
/// shape. It is compiled into BOTH the app target (which starts/updates/ends the
/// activity via ``LiveActivityManager``) and the widget extension target (which
/// renders the lock-screen + Dynamic Island presentations). The two targets must
/// share the *exact same* type — ActivityKit matches activities to widget
/// presentations by the attributes type's name and codable layout, so a
/// divergent re-declaration in the extension would silently fail to render.
///
/// Per the Wave-1C contract the widget module (X1) declares an identical struct;
/// the parent must compile THIS file into both targets and delete X1's duplicate
/// definition so there is exactly one `HermesTurnAttributes` in the build.
///
/// `ActivityKit` is only available on iOS/iPadOS; the `#if canImport` guard keeps
/// the file compilable in any context (e.g. unit-test hosts) that lacks it, while
/// the inner `ContentState` stays defined everywhere so non-ActivityKit code can
/// still construct/inspect state values.
#if canImport(ActivityKit)
struct HermesTurnAttributes: ActivityAttributes, Sendable {
    /// The dynamic, per-update payload rendered on the lock screen / Dynamic
    /// Island. Kept flat + `Codable`/`Hashable` exactly as the X1 contract
    /// specifies so the widget extension can decode it without a shared model.
    public struct ContentState: Codable, Hashable, Sendable {
        /// Human-facing phase label, e.g. "Thinking", "Running tool", "Waiting".
        public var phase: String
        /// Name of the tool currently executing, when one is.
        public var toolName: String?
        /// Whole seconds elapsed since the turn began (drives the compact timer).
        public var elapsedSeconds: Int
        /// `true` when the turn is blocked on a user approval.
        public var needsApproval: Bool
        /// Wall-clock instant the turn began. When present the widget renders a
        /// locally-counting `Text(timerInterval:)` so the elapsed display
        /// advances continuously on-device — independent of update/push cadence
        /// (build-29 "timer stuck at 0": the static `elapsedSeconds` only moved
        /// on a remote push that never arrived). Optional + omitted from server
        /// pushes → decodes nil → static fallback (old payloads compatible).
        public var startedAt: Date?

        public init(
            phase: String,
            toolName: String? = nil,
            elapsedSeconds: Int = 0,
            needsApproval: Bool = false,
            startedAt: Date? = nil
        ) {
            self.phase = phase
            self.toolName = toolName
            self.elapsedSeconds = elapsedSeconds
            self.needsApproval = needsApproval
            self.startedAt = startedAt
        }
    }

    /// The runtime session this turn belongs to — fixed for the activity's lifetime.
    ///
    /// This lets a Live Activity tap route back to the in-flight turn it represents
    /// instead of falling through to the generic "new draft" root route.
    public var sessionId: String?

    /// The human-facing session title — fixed for the activity's lifetime.
    public var sessionTitle: String

    public init(sessionTitle: String, sessionId: String? = nil) {
        self.sessionId = sessionId
        self.sessionTitle = sessionTitle
    }
}
#else
/// Non-ActivityKit fallback so the `ContentState` shape is still available for
/// construction/inspection on platforms without ActivityKit. Kept structurally
/// identical to the real attributes' `ContentState`.
enum HermesTurnAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public var phase: String
        public var toolName: String?
        public var elapsedSeconds: Int
        public var needsApproval: Bool
        /// Wall-clock instant the turn began. When present the widget renders a
        /// locally-counting `Text(timerInterval:)` so the elapsed display
        /// advances continuously on-device — independent of update/push cadence
        /// (build-29 "timer stuck at 0": the static `elapsedSeconds` only moved
        /// on a remote push that never arrived). Optional + omitted from server
        /// pushes → decodes nil → static fallback (old payloads compatible).
        public var startedAt: Date?

        public init(
            phase: String,
            toolName: String? = nil,
            elapsedSeconds: Int = 0,
            needsApproval: Bool = false,
            startedAt: Date? = nil
        ) {
            self.phase = phase
            self.toolName = toolName
            self.elapsedSeconds = elapsedSeconds
            self.needsApproval = needsApproval
            self.startedAt = startedAt
        }
    }
}
#endif
