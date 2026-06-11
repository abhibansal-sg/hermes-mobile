import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Drives the in-flight-turn Live Activity (lock screen + Dynamic Island) from
/// the chat turn lifecycle.
///
/// One activity is live at a time, mirroring the single active turn. The manager
/// is intentionally **no-throw**: ActivityKit calls are wrapped so a failure
/// (activities disabled by the user, OS budget exceeded, unsupported device)
/// degrades to a silent no-op rather than surfacing into the chat flow. It also
/// guards `ActivityAuthorizationInfo().areActivitiesEnabled` before starting, so
/// nothing is attempted when the user has turned Live Activities off.
///
/// Lifecycle mapping (hooks wired by the parent — see integration notes):
/// - `message.start`     → ``start(sessionTitle:)``      (phase "Thinking")
/// - `tool.start`        → ``update(toolName:)``         (phase "Running <tool>")
/// - `approval.request`  → ``markNeedsApproval()``       (phase "Waiting for approval")
/// - tool/approval clear → ``update(toolName: nil)`` / ``clearNeedsApproval()``
/// - `message.complete`  → ``end()`` (dismissed after a ~2s grace so the user
///   sees the final state before it disappears)
///
/// `elapsedSeconds` is recomputed from a stored start `Date` on each update; the
/// caller doesn't have to track it. Because ActivityKit isn't available on every
/// build target/platform, all real work sits behind `#if canImport(ActivityKit)`
/// and the public API stays callable (as no-ops) everywhere.
@MainActor
final class LiveActivityManager {

    /// Shared instance the app-side hooks call into.
    static let shared = LiveActivityManager()

    init() {}

    #if canImport(ActivityKit)
    /// The currently-running activity, if any.
    private var activity: Activity<HermesTurnAttributes>?
    /// When the current turn began, for `elapsedSeconds`.
    private var startedAt: Date?
    /// Latest known tool / approval state, so a partial update preserves the rest.
    private var currentToolName: String?
    private var currentNeedsApproval = false
    /// The deferred-end task, cancellable if a new turn starts within the grace.
    private var endTask: Task<Void, Never>?

    /// Runtime session id the live activity belongs to — the key the gateway's
    /// `/api/push/live-activity` registry upserts/prunes by (A3). `nil` when the
    /// turn started without a known session id, in which case remote LA updates
    /// can't be routed and we run the activity locally only.
    private var sessionId: String?
    /// The most recently registered LA push token (hex), so a rotation re-POSTs
    /// and the end-time DELETE can target it.
    private var registeredLAToken: String?
    /// Long-lived task observing `activity.pushTokenUpdates`. Cancelled on end.
    private var tokenObservationTask: Task<Void, Never>?

    /// Tail of the FIFO delivery chain (R1 #3): every ActivityKit content push
    /// awaits its predecessor, so racing unstructured Tasks can no longer apply
    /// snapshots out of spawn order and settle the lock screen on a stale
    /// "Running <tool>"/"Waiting for approval" frame.
    private var deliveryTask: Task<Void, Never>?
    /// Bumped by ``end()`` so queued-but-undelivered updates from the dying
    /// turn become no-ops instead of chasing (or overtaking) the end frame.
    private var deliveryGeneration = 0

    /// Lifecycle token for the token-registration round-trip (R1 #32/#97): a
    /// register POST that resumes after ``end()`` (or after a new lifecycle
    /// began) must not record — or leave the gateway holding — a token for a
    /// dismissed activity. Bumped on every `start()`/`end()`.
    private var registrationGeneration = 0

    /// A detached activity awaiting its grace dismissal (R1 #53). `end()` hands
    /// the activity off here and clears the manager synchronously; a
    /// back-to-back `start()` fast-forwards the finish instead of reusing an
    /// activity that ActivityKit may already have ended.
    private var pendingEnd: (box: ActivityBox, content: ActivityContent<HermesTurnAttributes.ContentState>)?

    /// Grace period after `message.complete` before the activity is dismissed,
    /// so the final state is visible briefly.
    private static let endGrace: Duration = .seconds(2)
    /// Stale horizon for live frames (R1 #26): if neither local events nor
    /// server pushes refresh the activity within this window, ActivityKit
    /// marks it stale — so a frame orphaned by a dead app/server can't sit on
    /// the Dynamic Island as a fresh-looking "Thinking" forever. Generous
    /// enough that any genuinely-running turn (whose every event refreshes the
    /// horizon) never goes stale.
    private static let staleAfter: TimeInterval = 15 * 60
    /// Stale horizon for the terminal "Done" frame: just past the dismissal
    /// grace, as a belt against the finish itself being lost.
    private static let endStaleAfter: TimeInterval = 30
    #endif

    // MARK: - Lifecycle

    /// Start a Live Activity for a new turn, if activities are enabled and none
    /// is already running. No-op when ActivityKit is unavailable or disabled.
    ///
    /// - Parameters:
    ///   - sessionTitle: the lock-screen / Dynamic Island title (fixed for the
    ///     activity's lifetime).
    ///   - sessionId: the runtime session id this turn belongs to, used to key the
    ///     gateway's `/api/push/live-activity` registry so remote LA updates land
    ///     on the right activity (A3). Omit for a local-only activity.
    func start(sessionTitle: String, sessionId: String? = nil) {
        #if canImport(ActivityKit)
        // A new turn supersedes any pending dismissal from the previous one —
        // by FAST-FORWARDING the old activity's finish, never by reusing it
        // (R1 #53: the old reuse path could adopt an activity ActivityKit had
        // already ended, leaving a dead LA with a stale sessionId/token and no
        // re-registration).
        if let pending = pendingEnd {
            endTask?.cancel()
            endTask = nil
            pendingEnd = nil
            Task { await Self.finish(pending.content, on: pending.box) }
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // `end()` detaches + clears synchronously, so a non-nil `activity` here
        // means a genuinely-live turn already owns the surface (e.g. a second
        // start signal within one turn). Refresh it rather than stacking.
        guard activity == nil else {
            update(phaseOverride: "Thinking")
            return
        }

        startedAt = Date()
        currentToolName = nil
        currentNeedsApproval = false
        self.sessionId = sessionId
        registeredLAToken = nil
        // New lifecycle: invalidate any straggling registration round-trip
        // from a previous activity (R1 #32/#97).
        registrationGeneration += 1

        let attributes = HermesTurnAttributes(
            sessionTitle: sessionTitle.isEmpty ? "Hermes" : sessionTitle
        )
        let state = HermesTurnAttributes.ContentState(
            phase: "Thinking",
            toolName: nil,
            elapsedSeconds: 0,
            needsApproval: false,
            startedAt: startedAt
        )
        do {
            // `pushType: .token` so ActivityKit issues a remote push token the
            // gateway can target for server-driven content-state updates (A3).
            // `Activity.request(attributes:content:pushType:)` is iOS 16.2+
            // (verified against the SDK swiftinterface); the deployment base is
            // iOS 17, so it's unconditionally available.
            let started = try Activity.request(
                attributes: attributes,
                content: ActivityContent(
                    state: state,
                    // R1 #26: an orphaned frame self-stales instead of posing
                    // as live forever (`staleDate: nil` never staled).
                    staleDate: Date().addingTimeInterval(Self.staleAfter)
                ),
                pushType: .token
            )
            activity = started
            // Observe the push token (and its rotations) and register each with
            // the gateway. Only meaningful when we have a session id to key by.
            observePushToken(for: started)
        } catch {
            // Disabled, over budget, or unsupported — silently skip.
            activity = nil
            startedAt = nil
            self.sessionId = nil
        }
        #endif
    }

    /// Update the running activity's tool name (and derived phase). Pass `nil`
    /// to clear the tool (e.g. on tool completion); the phase falls back to
    /// "Thinking" unless an approval is pending.
    func update(toolName: String?) {
        #if canImport(ActivityKit)
        currentToolName = toolName
        pushState()
        #endif
    }

    /// Mark the turn as blocked on a user approval.
    func markNeedsApproval() {
        #if canImport(ActivityKit)
        currentNeedsApproval = true
        pushState()
        #endif
    }

    /// Clear the pending-approval flag (the user answered, turn resumes).
    func clearNeedsApproval() {
        #if canImport(ActivityKit)
        currentNeedsApproval = false
        pushState()
        #endif
    }

    /// End the activity after a short grace so the final state is visible.
    /// Idempotent: calling it with nothing running is a no-op.
    ///
    /// The manager's state is detached and cleared SYNCHRONOUSLY (R1 #49/#53):
    /// the deferred task only delivers the terminal frame and dismisses the
    /// already-detached activity, so a back-to-back `start()` always builds a
    /// fresh activity with a fresh token observation — the old path deferred
    /// the state reset behind the grace sleep, where a cancellation window
    /// after ActivityKit's `end` could leave a DEAD activity installed for the
    /// reuse branch, and `registeredLAToken` survived to suppress the next
    /// turn's re-registration.
    func end() {
        #if canImport(ActivityKit)
        guard let activity else { return }
        // Stop observing token rotations and drop the gateway registration up
        // front — the activity is on its way out, so no further remote LA pushes
        // should be routed to it.
        tokenObservationTask?.cancel()
        tokenObservationTask = nil
        unregisterLAToken()
        // Invalidate any in-flight registration round-trip (R1 #32/#97): its
        // post-await write must not resurrect a registration the DELETE above
        // just removed.
        registrationGeneration += 1
        let content = ActivityContent(
            state: makeState(phaseOverride: "Done"),
            staleDate: Date().addingTimeInterval(Self.endStaleAfter)
        )
        let box = ActivityBox(activity: activity)
        // Detach + clear NOW (see doc comment).
        self.activity = nil
        startedAt = nil
        currentToolName = nil
        currentNeedsApproval = false
        sessionId = nil
        registeredLAToken = nil
        // Queued-but-undelivered updates from this turn are stale: bump the
        // generation BEFORE enqueueing the end frame so they no-op while the
        // end frame (enqueued under the new generation, FIFO behind anything
        // already in flight) still delivers in order (R1 #3).
        deliveryGeneration += 1
        let endPush = enqueueDelivery(content, to: box)
        pendingEnd = (box, content)
        endTask?.cancel()
        endTask = Task { @MainActor [weak self] in
            await endPush.value
            try? await Task.sleep(for: Self.endGrace)
            // Cancelled ⇒ a new start() fast-forwarded the finish itself.
            guard !Task.isCancelled else { return }
            await Self.finish(content, on: box)
            self?.pendingEnd = nil
            self?.endTask = nil
        }
        #endif
    }

    // MARK: - State assembly

    #if canImport(ActivityKit)
    /// Recompute and push the current content state to the live activity.
    private func update(phaseOverride: String? = nil) {
        guard let activity else { return }
        let content = ActivityContent(
            state: makeState(phaseOverride: phaseOverride),
            // Every live frame refreshes the self-stale horizon (R1 #26).
            staleDate: Date().addingTimeInterval(Self.staleAfter)
        )
        enqueueDelivery(content, to: ActivityBox(activity: activity))
    }

    /// Push using the derived phase (no override).
    private func pushState() { update(phaseOverride: nil) }

    /// Append a content push to the FIFO delivery chain (R1 #3). Each delivery
    /// awaits its predecessor, so ActivityKit applies frames in enqueue order —
    /// the old per-update unstructured `Task`s raced, letting a stale
    /// "Running <tool>" overtake "Waiting for approval". A delivery whose
    /// generation was superseded by ``end()`` no-ops instead of chasing the
    /// terminal frame.
    @discardableResult
    private func enqueueDelivery(
        _ content: ActivityContent<HermesTurnAttributes.ContentState>,
        to box: ActivityBox
    ) -> Task<Void, Never> {
        let generation = deliveryGeneration
        let previous = deliveryTask
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, self.deliveryGeneration == generation else { return }
            await Self.push(content, to: box)
        }
        deliveryTask = task
        return task
    }

    // MARK: - ActivityKit boundary
    //
    // `Activity<HermesTurnAttributes>` is not `Sendable` under the Swift 6 SDK,
    // so handing it to ActivityKit's `nonisolated async` `update`/`end` from a
    // `@MainActor` context trips strict-concurrency's region check. ActivityKit
    // marshals these calls internally and the activity is only ever produced /
    // consumed here, so the crossing is sound: we route it through a one-shot
    // `@unchecked Sendable` transfer box rather than aliasing the value.

    /// `@unchecked Sendable` carrier for the non-Sendable `Activity` so it can be
    /// passed into the nonisolated ActivityKit calls. Single-producer/consumer.
    private struct ActivityBox: @unchecked Sendable {
        let activity: Activity<HermesTurnAttributes>
    }

    private static func push(
        _ content: ActivityContent<HermesTurnAttributes.ContentState>,
        to box: ActivityBox
    ) async {
        await box.activity.update(content)
    }

    // MARK: - Push token registration (A3)

    /// Observe an activity's push token + rotations and register each with the
    /// gateway. `pushTokenUpdates` is an `AsyncSequence` of `Data` (verified
    /// against the SDK swiftinterface); the loop ends when the activity ends or
    /// the task is cancelled.
    ///
    /// The `Activity` is non-Sendable, so it crosses into the observation task
    /// through the same one-shot `ActivityBox` transfer used elsewhere; the token
    /// `Data` it yields IS Sendable and is hopped back to the main actor for the
    /// registration POST.
    private func observePushToken(for activity: Activity<HermesTurnAttributes>) {
        tokenObservationTask?.cancel()
        let box = ActivityBox(activity: activity)
        tokenObservationTask = Task { @MainActor [weak self] in
            for await tokenData in box.activity.pushTokenUpdates {
                if Task.isCancelled { return }
                let hex = tokenData.map { String(format: "%02x", $0) }.joined()
                await self?.registerLAToken(hex)
            }
        }
    }

    /// Register (or re-register on rotation) the LA push token with the gateway.
    /// No-op without a session id (nothing to key the registry by) or an empty
    /// token. A re-POST with the same token is skipped.
    ///
    /// The registration generation is snapshotted before the network await and
    /// re-checked after (R1 #32/#97): `end()` (or a fresh `start()`) during the
    /// round-trip invalidates this registration — the post-await write must not
    /// re-arm a token for a dismissed activity, and a register that landed
    /// server-side for a dead lifecycle is compensated with a DELETE rather
    /// than left for a future 410 to prune.
    private func registerLAToken(_ hex: String) async {
        guard let sessionId, !sessionId.isEmpty, !hex.isEmpty else { return }
        guard registeredLAToken != hex else { return }
        let generation = registrationGeneration
        guard let endpoint = PushRegistrar.shared.resolveEndpoint() else { return }
        let env = PushRegistrar.apnsEnvironment
        let rest = RestClient(
            baseURL: endpoint.url, token: endpoint.token, pathStyle: endpoint.pathStyle
        )
        let outcome = await rest.registerLiveActivity(
            token: hex,
            sessionId: sessionId,
            env: env
        )
        guard generation == registrationGeneration else {
            // The lifecycle died mid-flight but the gateway accepted the
            // registration — take it back, UNLESS a newer lifecycle now owns
            // the SAME session id (consecutive turns share the runtime sid and
            // the gateway registry upserts one token per sid): a DELETE keyed
            // by that sid could land after the new turn's register and clobber
            // its routing (ABH-49 judge round). When skipped, the new turn's
            // own upsert supersedes this row; if the two POSTs reordered
            // server-side, the next token rotation or the server's 410-prune /
            // age-GC reconciles.
            if case .success = outcome, self.sessionId != sessionId {
                Task {
                    _ = await rest.unregisterLiveActivity(
                        token: hex, sessionId: sessionId, env: env
                    )
                }
            }
            return
        }
        if case .success = outcome {
            registeredLAToken = hex
        }
    }

    /// Tell the gateway to drop the LA token for this session (DELETE), so the
    /// pruned-on-end registry doesn't keep pushing to a dead activity.
    private func unregisterLAToken() {
        guard let sessionId, !sessionId.isEmpty, let hex = registeredLAToken, !hex.isEmpty else {
            return
        }
        guard let endpoint = PushRegistrar.shared.resolveEndpoint() else { return }
        let env = PushRegistrar.apnsEnvironment
        // Fire-and-forget: the activity is already ending; a failed unregister is
        // pruned server-side on the next 410/BadDeviceToken anyway.
        Task {
            let rest = RestClient(
                baseURL: endpoint.url, token: endpoint.token, pathStyle: endpoint.pathStyle
            )
            _ = await rest.unregisterLiveActivity(token: hex, sessionId: sessionId, env: env)
        }
    }

    private static func finish(
        _ content: ActivityContent<HermesTurnAttributes.ContentState>,
        on box: ActivityBox
    ) async {
        await box.activity.end(content, dismissalPolicy: .immediate)
    }

    /// Build a content state from the manager's current bookkeeping.
    private func makeState(phaseOverride: String?) -> HermesTurnAttributes.ContentState {
        let elapsed = startedAt.map { Int(Date().timeIntervalSince($0)) } ?? 0
        let phase = phaseOverride ?? derivedPhase()
        return HermesTurnAttributes.ContentState(
            phase: phase,
            toolName: currentToolName,
            elapsedSeconds: max(0, elapsed),
            needsApproval: currentNeedsApproval,
            startedAt: startedAt
        )
    }

    /// Phase label derived from the current tool / approval state.
    private func derivedPhase() -> String {
        if currentNeedsApproval { return "Waiting for approval" }
        if let tool = currentToolName, !tool.isEmpty { return "Running \(tool)" }
        return "Thinking"
    }
    #endif
}
