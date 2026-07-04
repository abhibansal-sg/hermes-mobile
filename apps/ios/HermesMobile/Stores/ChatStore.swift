import Foundation
import SwiftUI  // A2: withTransaction(Transaction(animation: nil)) on the finalize flip
import os
#if DEBUG
import DebugBridgeCore  // @Snapshotable marker for the gstack debug bridge (UI-G)
#endif

struct TranscriptPageFetch: Sendable {
    let messages: [StoredMessage]
    let oldestId: Int?
    let hasMoreBefore: Bool
}

/// Plugin-only backward-paged transcript fetch. Kept outside RestClient.swift for
/// ABH-400's narrow scope fence; it reuses RestClient's internal request/JSON
/// helpers without changing the existing no-param delta handshake method.
func fetchTranscriptPage(
    rest: RestClient,
    sessionId: String,
    limit: Int,
    before: Int? = nil
) async -> TranscriptPageFetch? {
    guard rest.pathStyle == .plugin else { return nil }
    let encodedId = sessionId.addingPercentEncoding(
        withAllowedCharacters: .urlPathAllowed
    ) ?? sessionId
    var path = "\(rest.pathStyle.mobileAPIPrefix)/sessions/\(encodedId)/messages"
        + "?limit=\(max(1, limit))"
    if let before, before > 0 {
        path += "&before=\(before)"
    }
    do {
        let data = try await rest.get(path: path)
        let root = try rest.decodeJSONValue(from: data, context: "messagesPage")
        guard let array = root["messages"]?.arrayValue else { return nil }
        let page = root["page"]
        return TranscriptPageFetch(
            messages: array.compactMap(StoredMessage.init(json:)),
            oldestId: page?["oldest_id"]?.intValue,
            hasMoreBefore: page?["has_more_before"]?.boolValue ?? false
        )
    } catch {
        return nil
    }
}

/// Subsystem logger for transcript reconciliation. Backfill failures used to be
/// swallowed by a bare `catch`; they now surface here (and, in DEBUG, on the
/// bridge-readable counters) so a future REST-error mirror drop is not invisible.
private let chatLog = Logger(subsystem: "ai.hermes.HermesMobile", category: "ChatStore")

#if DEBUG
/// DEBUG-only telemetry for the foreign-mirror adoption gate (F3-H). Counts the
/// decisions the gate makes so a live DEBUG build can prove, via the UI-G
/// StateServer bridge, that foreign frames are adopted/applied/reconciled rather
/// than silently dropped. The whole type is `#if DEBUG`-gated and is never
/// referenced from a Release build, so it compiles out entirely — preserving
/// Release purity (no symbols, no counter mutations on the hot path).
struct ForeignMirrorTelemetry: Sendable, Equatable {
    /// Foreign `message.start` frames that were adopted (mirroringRuntimeId set).
    var foreignAdopted = 0
    /// Foreign stream deltas applied to the transcript for the adopted runtime.
    var foreignDeltasApplied = 0
    /// Foreign stream frames dropped by the `:isStreaming` gate (the bug surface).
    var foreignDroppedWhileStreaming = 0
    /// Foreign `message.complete` frames that triggered a reconcile (teardown+backfill).
    var foreignCompletesReconciled = 0
    /// Times `backfill()` actually ran a REST refetch.
    var backfillRuns = 0
    /// Times `backfill()`'s REST refetch threw.
    var backfillFailures = 0
}

/// DEBUG-only record of a single `isStreaming` write — who set it, to what, and
/// in what event context. F3-H2: round-1's relocated drop site was REFUTED at
/// the gate because `isStreaming` was already true (and `streamingIsForeign`
/// false) by the time the foreign frames arrived, so the foreign turn was
/// misclassified as local and dropped. The round-1 counters proved the *drop*
/// but could not NAME the writer that set `isStreaming=true` first. This record
/// closes that gap: every write to `isStreaming` stamps `lastStreamingSetter`
/// and appends to a bounded ring buffer of transitions, so a live DEBUG build
/// can read — via the StateServer bridge — exactly which code path (and which
/// inbound event's `session_id`/`stored_session_id` vs. the app's active ids)
/// flipped streaming on before the mirror gate ever ran. Compiled out of Release.
struct StreamingTransition: Sendable, Equatable {
    /// Monotonic order index (0-based) of this transition within the app run.
    var seq: Int
    /// `Date.timeIntervalSinceReferenceDate` when the write happened.
    var at: Double
    /// New value `isStreaming` was set to.
    var value: Bool
    /// Short setter label: `function · reason · eventType · evSid=… evStored=…
    /// activeRid=… activeStored=… foreign=<streamingIsForeign>`.
    var setter: String

    /// One compact line for JSON/log readers.
    var line: String { "#\(seq) \(value ? "TRUE " : "false") \(setter)" }
}
#endif

/// Observable owner of the active session's transcript and streaming UX.
///
/// Gateway events are routed here by `ConnectionStore`'s event router. Streaming
/// text (message/thinking/reasoning deltas) is coalesced: deltas accumulate in
/// private buffers and a single scheduled task flushes them into the `messages`
/// array at most every 40ms, so the UI observes one mutation per frame rather
/// than one per token. The back-references to the other stores are set once in
/// ``attach(connection:sessions:)`` and live for the lifetime of the app; the
/// resulting reference cycle is intentional.
@MainActor
@Observable
final class ChatStore {
    /// The visible transcript for the active session.
    var messages: [ChatMessage] = []
    /// True while the agent is producing a streaming turn.
    #if DEBUG
    @Snapshotable
    #endif
    var isStreaming: Bool = false
    /// An approval the user must answer, or `nil`.
    var pendingApproval: PendingApproval?
    /// A clarification the user must answer, or `nil`.
    var pendingClarification: PendingClarification?

    /// A pending secure prompt (sudo password / secret value) the user must
    /// answer, or `nil` (F4A-A2). Unlike approvals these are TRANSIENT and
    /// session-local — they are NOT routed to the global ``InboxStore`` and a
    /// value is NEVER stored here (only the request side: what to ask and which
    /// `request_id` / session to reply on). The entered value lives solely in a
    /// `SecurePromptView` `@State` and is cleared the instant the reply is sent.
    var pendingSecurePrompt: PendingSecurePrompt?

    /// The subagent delegation tree for the active turn, assembled from the
    /// stream of `subagent.*` events (F4A-A2). Empty until the agent delegates;
    /// reset on a fresh turn / open / reset. The view renders ``subagentRoots``
    /// + ``subagentChildren(of:)`` so it never touches the assembly map.
    #if DEBUG
    @Snapshotable
    #endif
    private(set) var subagentNodeCount: Int = 0

    #if DEBUG
    /// DEBUG-only bridge accessor for the integration gate: the KIND of the active
    /// secure prompt (`"sudo"` / `"secret"` / `"none"`) so the gate can assert a
    /// prompt is up WITHOUT ever reading the entered value (which is never held in
    /// the store at all — see ``PendingSecurePrompt``). Bridge-exposed as a String.
    @Snapshotable
    var activeSecurePromptKind: String {
        pendingSecurePrompt?.kind.rawValue ?? "none"
    }
    #endif
    /// Last user-facing error (busy, send failure, …), or `nil`.
    #if DEBUG
    @Snapshotable
    #endif
    var lastError: String?

    /// Last `backfill()` REST failure, or `nil` if the most recent backfill
    /// succeeded or none has run. Observability for the mirror-recovery path:
    /// a foreign turn whose live stream was dropped relies entirely on backfill,
    /// so a silent REST error there means a permanently-missing mirror. Surfaced
    /// here (and logged via `chatLog`) instead of being swallowed by a bare
    /// `catch`. Not user-facing chrome — it drives diagnostics and the DEBUG
    /// bridge — so it never clobbers `lastError`.
    #if DEBUG
    @Snapshotable
    #endif
    private(set) var lastBackfillError: String?

    #if DEBUG
    /// DEBUG-only adoption-gate telemetry, bridge-exposed via the UI-G
    /// StateAccessor pattern. Release builds never reference this.
    @Snapshotable
    private(set) var foreignMirrorTelemetry = ForeignMirrorTelemetry()

    /// DEBUG-only label of the most recent `isStreaming` write (F3-H2). Names the
    /// function + reason + the inbound event's ids vs. the active ids, so the gate
    /// can read which path flipped streaming on. Bridge-exposed as a String.
    @Snapshotable
    private(set) var lastStreamingSetter: String = "(none)"

    /// DEBUG-only ordered ring buffer of the last `streamingRingCapacity`
    /// `isStreaming` transitions (every write, value-change or not), newest last.
    /// Bridge-exposed as a single JSON string (`streamingRing`) so the gate poller
    /// can reconstruct the full causal chain of who set streaming and when.
    private(set) var streamingRing: [StreamingTransition] = []
    private static let streamingRingCapacity = 20
    /// Monotonic counter feeding `StreamingTransition.seq`.
    private var streamingSeq = 0

    /// JSON encoding of `streamingRing` for the StateServer bridge (the bridge's
    /// JSONSerialization sink can't serialize the struct array directly, so we
    /// hand it a compact JSON string — the same workaround the per-counter Int
    /// accessors use for `ForeignMirrorTelemetry`).
    var streamingRingJSON: String {
        let items = streamingRing.map { t -> [String: Any] in
            ["seq": t.seq, "at": t.at, "value": t.value, "setter": t.setter]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: items),
              let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }
    #endif

    /// Context-window occupancy of the active session (H1), or `nil` when no
    /// occupancy is known yet (fresh draft, or a session whose `usage` carried no
    /// context fields). Drives the composer model-chip meter, the model-picker
    /// stats header, and the per-turn ctx footer.
    ///
    /// Semantics: this reflects occupancy of the **last API prompt** — it updates
    /// once per completed turn (`message.complete`), not per streamed token, and
    /// is seeded once from `session.status` after a resume so a reopened session
    /// shows occupancy before its first new turn. Reset to `nil` on open/draft.
    private(set) var contextUsage: (used: Int, max: Int, percent: Int, compressions: Int)?

    /// Optional hook fired after a turn finalizes (`message.complete`). Set by
    /// `AppEnvironment` to drive the queue drain ("send next queued prompt").
    /// ChatStore holds no `QueueStore` reference, so this closure is the seam.
    var onTurnComplete: (() -> Void)?

    /// Turn-lifecycle seams driving the Live Activity (X3 `LiveActivityManager`),
    /// set by `AppEnvironment`. ChatStore stays decoupled from ActivityKit — these
    /// closures fire at the exact same points the transcript state transitions, so
    /// the activity mirrors the in-flight turn:
    /// - `onTurnStart`      — `message.start` of a fresh turn (no turn was live).
    /// - `onToolChange`     — `tool.start` (name) / its `tool.complete` (`nil`).
    /// - `onApprovalChange` — an approval becomes pending (`true`) / is answered
    ///   or the turn ends (`false`).
    /// - `onTurnComplete` (above) also marks the activity's end.
    /// - `onTurnDiscarded`  — the rendered turn was torn down WITHOUT a
    ///   completion (session switch / new draft / connection drop / transcript
    ///   rewrite). Before this seam, only `message.complete` ended the
    ///   activity, so every discard path orphaned it on the Dynamic Island and
    ///   the next turn adopted the stale activity (R1 #26, #73).
    var onTurnStart: (() -> Void)?
    var onToolChange: ((String?) -> Void)?
    var onApprovalChange: ((Bool) -> Void)?
    var onTurnDiscarded: (() -> Void)?

    private var connection: ConnectionStore?
    private var sessions: SessionStore?
    private var attachments: AttachmentStore?

    /// The offline-first local cache (P1/P2 layer). Optional and defaulting to
    /// `nil` so every unit test that never injects one behaves EXACTLY as before:
    /// a `nil` cache means the network-only path is taken verbatim (cache-miss ==
    /// today's behavior, byte-for-byte). Wired once by
    /// `AppEnvironment.attachCache(_:)`. ChatStore only WRITES through it (the
    /// open-path READ lives in `SessionStore.seedTranscript`); `backfill()` keeps
    /// the cache warm on every foreground/reconnect reconcile.
    private var cacheStore: CacheStore?

    /// Inject the offline cache. Separate from `attach(...)` so the frozen
    /// `attach` signature — called by every store-graph test — is untouched.
    func attachCache(_ cache: CacheStore) {
        self.cacheStore = cache
    }

    /// `id` of the assistant message currently being streamed into.
    private var streamingMessageID: UUID?
    /// Coalescing buffers for the in-flight streaming message.
    private var textBuffer: String = ""
    private var thinkingBuffer: String = ""
    /// The single in-flight flush task (deduped so we mutate at most every 40ms).
    private var flushTask: Task<Void, Never>?
    /// When the current streaming turn began. Used to gate the turn-complete
    /// haptic so it only fires for turns that actually kept the user waiting,
    /// and exposed (read-only) to drive the elapsed-time turn activity bar.
    /// `nil` whenever no turn is in flight.
    private(set) var turnStartedAt: Date?
    /// Name of the tool currently executing in the in-flight turn, surfaced in
    /// the turn activity bar. `nil` when no tool is running. Set on `tool.start`
    /// and cleared on that tool's `tool.complete` / turn completion.
    #if DEBUG
    @Snapshotable
    #endif
    private(set) var activeToolName: String?
    /// `tool_call_id` backing `activeToolName`, so completion of an *earlier*
    /// tool doesn't clear a label that belongs to a later one.
    private var activeToolCallId: String?

    /// Zero-based ordinal of each user message — the count of user-role messages
    /// that precede it in the transcript. Matches the gateway's
    /// `truncate_before_user_ordinal` index into its user-message history (see
    /// `prompt.submit` in tui_gateway/server.py). Rebuilt on every wholesale
    /// transcript replacement (seed) and maintained incrementally on send.
    // `private(set)`: tests read the cache to pin the ordinal mapping (the old
    // behavioral proxy — a failed submit's leftover truncation — was removed
    // when ABH-48 made unaccepted truncations roll back).
    private(set) var userOrdinals: [UUID: Int] = [:]

    /// The subagent tree, keyed by node id. Insertion-ordered child lists live on
    /// each node (``SubagentNode.childIds``), ordered by `taskIndex`. The map is
    /// the assembly state; the view reads the derived ``subagentRoots`` /
    /// ``subagentChildren(of:)`` projections. Reset per turn / open / reset.
    private var subagentNodes: [String: SubagentNode] = [:]
    /// Top-level node ids (no parent), in first-seen order. Kept separate so the
    /// view can render roots without scanning the whole map each frame.
    private var subagentRootIds: [String] = []

    private static let flushInterval: Duration = .milliseconds(40)
    /// Only buzz on completion for turns that streamed longer than this.
    private static let turnCompleteHapticThreshold: TimeInterval = 10

    init() {}

    /// Wire up the store graph. Called exactly once by `AppEnvironment`.
    func attach(connection: ConnectionStore, sessions: SessionStore, attachments: AttachmentStore) {
        self.connection = connection
        self.sessions = sessions
        self.attachments = attachments
    }

    private var client: HermesGatewayClient? { connection?.client }
    private var activeSessionId: String? { sessions?.activeRuntimeId }

    // MARK: - Event handling

    /// Runtime id of a *foreign* session we are currently mirroring — another
    /// client (e.g. the desktop) driving the same stored session, delivered
    /// via the gateway's multi-client broadcast. Nil when the stream we're
    /// rendering is our own.
    private var mirroringRuntimeId: String?

    /// True while the *current streaming turn was adopted from a foreign
    /// runtime* (set when a foreign `message.start` is adopted, cleared on that
    /// runtime's `message.complete` / teardown). This is the single fact that
    /// distinguishes a foreign-owned `isStreaming==true` from a genuinely-local
    /// in-flight turn, so the `message.complete` reconcile can tear down the
    /// adopted foreign stream — and only that — without ever disturbing a local
    /// turn. A locally-owned turn never sets this, so foreign frames can never
    /// trip the foreign-teardown path while we own the stream.
    private var streamingIsForeign = false

    /// Explicit token identifying a genuinely-LOCAL in-flight turn (F3-H2).
    ///
    /// Round-1 derived "a local turn is in flight" from an `isStreaming` heuristic
    /// (`isStreaming && !streamingIsForeign`). That broke because a FOREIGN
    /// `message.start` arriving while `activeRuntimeId` was still `nil` (the
    /// `session.resume` window) was routed down the DIRECT, non-mirror path —
    /// `beginStreamingMessage()` set `isStreaming = true` with
    /// `streamingIsForeign = false`, i.e. it *looked* exactly like a local turn —
    /// so every later foreign frame was dropped by that heuristic.
    ///
    /// The lesson (and the design principle): local-turn ownership must NEVER be
    /// inferred from streaming state. It is an explicit fact, set ONLY where the
    /// user genuinely begins a local turn — `send()`, edit/retry
    /// (`submitTruncating`), or an attachment upload that precedes one — and
    /// cleared when that turn ends (complete / interrupt / error / reset /
    /// truncation). The foreign-adoption gate keys on this token (`no local turn`
    /// in flight) instead of on `isStreaming`, so a foreign `message.start` that
    /// was *never* started by the user can never masquerade as local and can never
    /// block adoption of the foreign turn — regardless of what `isStreaming` was
    /// flipped to by a stray frame.
    ///
    /// A `UUID` (not a `Bool`) so a late callback from a superseded turn can be
    /// distinguished from the current one if that ever matters; today only its
    /// nil-ness is read.
    private var localTurnToken: UUID?

    /// Whether a genuinely-local turn is currently in flight. The single source of
    /// truth for "the user owns this stream", read by the adoption gate — and by
    /// the user-action gates (edit/retry/checkpoint) and the composer, which must
    /// reflect LOCAL ownership rather than the display-level `isStreaming`
    /// (R1 #30, Batch C). Never derived from `isStreaming`.
    var localTurnInFlight: Bool { localTurnToken != nil }

    /// The active STORED session id (`SessionStore.activeStoredId`), exposed so
    /// the queue can stamp prompts with the session they were composed for and
    /// drain them only into that session (R1 #17, Batch C).
    var activeStoredSessionId: String? { sessions?.activeStoredId }

    /// ABH-400: cold opens fetch/render only a recent tail window, then page
    /// older transcript rows backward on demand.
    nonisolated static let transcriptOpenWindowLimit = 50
    private(set) var transcriptHasMoreBefore = false
    private(set) var isLoadingEarlierTranscript = false
    private var oldestLoadedTranscriptWireId: Int?

    /// Runtime sessions whose gateway status currently reports a mid-turn
    /// context compaction. Keyed by runtime `session_id` (desktop parity): a
    /// background session can compact without lighting up the foreground
    /// transcript, and the active transcript derives its marker from the active
    /// runtime id only.
    private var compactingSessionIds: Set<String> = []

    /// Per-session local dismissals for the inline marker. Dismissal hides the
    /// current compacting episode only; the next non-compacting status clear then
    /// a later compacting status shows it again.
    private var dismissedCompactionSessionIds: Set<String> = []

    /// Whether the foreground transcript should show the auto-compaction marker.
    /// This is intentionally separate from manual `isCompressingContext` in
    /// `ChatView`: it reflects only the gateway's real `status.update` compaction
    /// signal and never fakes a marker for user-triggered manual compression.
    var isActiveSessionCompacting: Bool {
        visibleCompactingSessionId != nil
    }

    /// User dismissed the inline marker for the active compaction episode.
    func dismissActiveCompactionIndicator() {
        guard let sessionId = visibleCompactingSessionId else { return }
        dismissedCompactionSessionIds.insert(sessionId)
    }

    private var visibleCompactingSessionId: String? {
        [activeSessionId, mirroringRuntimeId].compactMap { $0 }.first { sessionId in
            compactingSessionIds.contains(sessionId)
                && !dismissedCompactionSessionIds.contains(sessionId)
        }
    }

    private func setSessionCompacting(_ sessionId: String?, _ compacting: Bool) {
        guard let sessionId = sessionId ?? activeSessionId, !sessionId.isEmpty else { return }
        if compacting {
            let wasAlreadyCompacting = compactingSessionIds.contains(sessionId)
            compactingSessionIds.insert(sessionId)
            if !wasAlreadyCompacting {
                dismissedCompactionSessionIds.remove(sessionId)
            }
        } else {
            compactingSessionIds.remove(sessionId)
            dismissedCompactionSessionIds.remove(sessionId)
        }
    }

    private func handleStatusUpdate(_ event: GatewayEvent) {
        setSessionCompacting(event.sessionId, event.payload["kind"]?.stringValue == "compacting")
    }

    private func clearAllCompactionIndicators() {
        compactingSessionIds = []
        dismissedCompactionSessionIds = []
    }

    /// Begin a genuinely-local turn: stamp the explicit ownership token and drop
    /// any foreign-mirror ownership we were holding (the user is now driving this
    /// stored session locally, so a stray foreign `message.complete` must never
    /// tear our turn down). Called from every user-initiated send path.
    private func beginLocalTurn() {
        localTurnToken = UUID()
        mirroringRuntimeId = nil
        streamingIsForeign = false
        // A fresh local turn starts with no delegation tree (F4A-A2); the prior
        // turn's subagent branches belong to a finished turn. Subagent frames for
        // THIS turn rebuild it as the agent delegates.
        resetSubagentTree()
    }

    /// End the local-turn ownership token (turn complete / interrupt / error /
    /// reset / truncation). Idempotent.
    private func endLocalTurn() {
        localTurnToken = nil
    }

    /// REST fetch backing ``backfill()``, injected for tests. In the app it
    /// resolves the live `connection?.rest` and calls `messages(sessionId:)`;
    /// the default is set lazily on first use because `connection` is wired
    /// after `init`. Returns the stored transcript or throws the REST error
    /// (which ``backfill()`` now surfaces rather than swallows).
    var backfillFetch: ((String) async throws -> [StoredMessage])?

    /// Context of the event currently being routed through ``handle(event:)``,
    /// used only to enrich the DEBUG streaming-setter telemetry so a write that
    /// happens *inside* event handling can name the inbound frame's ids. `nil`
    /// outside event handling (e.g. a write from `send()`).
    #if DEBUG
    private var routingEvent: GatewayEvent?
    #endif

    /// The single funnel for every `isStreaming` write. In DEBUG it stamps
    /// `lastStreamingSetter` and appends a `StreamingTransition` to the ring
    /// buffer naming the caller (`reason`), the value, and — when a frame is being
    /// routed — that frame's `session_id`/`stored_session_id` against the active
    /// runtime/stored ids and the current `streamingIsForeign` flag. This is the
    /// fact round-1 could not produce: the identity of the writer that set
    /// streaming true *before* the foreign mirror gate ran. In Release this
    /// collapses to a plain `isStreaming = value` (the whole telemetry block is
    /// `#if DEBUG`), so there is zero hot-path cost and no symbols.
    private func setStreaming(_ value: Bool, reason: String) {
        isStreaming = value
        #if DEBUG
        let ev = routingEvent
        let evType = ev?.rawType ?? "-"
        let evSid = ev?.sessionId ?? "-"
        let evStored = ev?.storedSessionId ?? "-"
        let activeRid = activeSessionId ?? "-"
        let activeStored = sessions?.activeStoredId ?? "-"
        let setter = "\(reason) ev=\(evType) evSid=\(evSid) evStored=\(evStored) "
            + "activeRid=\(activeRid) activeStored=\(activeStored) "
            + "foreign=\(streamingIsForeign) mirroring=\(mirroringRuntimeId ?? "-")"
        lastStreamingSetter = setter
        streamingRing.append(StreamingTransition(
            seq: streamingSeq,
            at: Date.timeIntervalSinceReferenceDate,
            value: value,
            setter: setter
        ))
        streamingSeq += 1
        if streamingRing.count > Self.streamingRingCapacity {
            streamingRing.removeFirst(streamingRing.count - Self.streamingRingCapacity)
        }
        #endif
    }

    /// Classify an inbound frame's *ownership* (F3-H2). This is the single
    /// decision point that round-1 got wrong, and it is made HERE, at the routing
    /// source, before any state is mutated — not inferred downstream from
    /// `isStreaming`.
    ///
    /// - `.local`  — the frame belongs to our own active runtime turn.
    /// - `.foreign`— another client is driving the *same stored session* we have
    ///   open (broadcast/mirror). Crucially this is recognised even while our
    ///   `activeRuntimeId` is still `nil` (the `session.resume` window): the round-1
    ///   bug was that a foreign frame arriving in that window fell through to the
    ///   LOCAL path because the old gate's `let active = activeSessionId` binding
    ///   failed on nil. A foreign frame is identified by its `storedSessionId`
    ///   correlating with our open stored id while its runtime id is NOT ours —
    ///   independent of whether our runtime id is known yet.
    /// - `.unrelated` — neither ours nor a mirror of our open session; ignored.
    private enum FrameOwnership { case local, foreign, unrelated }

    private func ownership(of event: GatewayEvent) -> FrameOwnership {
        let active = activeSessionId
        // A frame on our own active runtime is unambiguously local.
        if let sid = event.sessionId, let active, sid == active {
            return .local
        }
        // Correlate the broadcast stored id with the session we have open (H3:
        // trim both sides; the wire id is already trimmed in `GatewayEvent`).
        let activeStored = sessions?.activeStoredId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let correlatesToOpenSession = event.storedSessionId != nil
            && activeStored?.isEmpty == false
            && event.storedSessionId == activeStored
        if correlatesToOpenSession {
            // It mirrors our open stored session. If its runtime id is ours it's
            // local (a stored-enriched frame for our own turn); otherwise — INCLUDING
            // the case where our runtime id is still `nil` during resume — it is a
            // FOREIGN turn. This is the exact window the round-1 culprit slipped
            // through: with `active == nil` the runtime ids cannot be equal, so the
            // frame is correctly classified foreign instead of leaking to local.
            if let sid = event.sessionId, let active, sid == active {
                return .local
            }
            return .foreign
        }
        // A frame carrying no stored id and no runtime id (or one that matches no
        // open session) is treated as local only when we actually have a local
        // turn or active runtime to attribute it to; otherwise it's unrelated.
        // In practice our own runtime frames always carry our `sessionId`, handled
        // above. A frame with neither id is a malformed/global frame — route it
        // through the local switch unchanged (legacy behavior) so nothing that
        // used to render stops rendering.
        if event.sessionId == nil && event.storedSessionId == nil {
            return .local
        }
        return .unrelated
    }

    /// Route a gateway event into the transcript.
    ///
    /// Ownership is decided up front by ``ownership(of:)`` (local / foreign /
    /// unrelated). A foreign turn is adopted only when no genuinely-local turn is
    /// in flight (the explicit ``localTurnInFlight`` token — never an `isStreaming`
    /// heuristic), and once adopted we follow that single foreign runtime until its
    /// `message.complete` so two sources can't interleave one transcript.
    func handle(event: GatewayEvent) {
        #if DEBUG
        routingEvent = event
        defer { routingEvent = nil }
        #endif

        switch ownership(of: event) {
        case .unrelated:
            // Not ours and not a mirror of our open session — drop it.
            return
        case .foreign:
            handleForeignFrame(event)
            return
        case .local:
            break  // fall through to the local switch below
        }

        // Any in-flight streaming frame on our OWN active runtime is a
        // genuinely-local turn (whether the user kicked it off here via `send()`
        // or another tab of our own runtime did, and regardless of whether the
        // `message.start` or an early delta/tool lands first). Claim local
        // ownership explicitly so subsequent local frames are never mistaken for
        // adoptable foreign ones. This is the SAFE counterpart to the round-1
        // culprit: ownership is claimed here ONLY for a frame the routing layer
        // classified `.local` — a foreign frame can never reach this switch (it is
        // intercepted by `handleForeignFrame`). `message.complete` is excluded: it
        // ENDS a turn, it does not begin one.
        switch event.type {
        case .messageStart, .messageDelta, .thinkingDelta, .reasoningDelta,
             .toolStart, .toolProgress, .toolComplete:
            if !localTurnInFlight, !streamingIsForeign { beginLocalTurn() }
        case .messageComplete, .approvalRequest, .clarifyRequest,
             .gatewayReady, .statusUpdate, .unknown,
             // F4A-A2: subagent frames are SCAFFOLDING inside a turn that some
             // message/tool frame already began — they must NOT themselves begin a
             // local turn (a subagent.start arriving before the parent's
             // message.start would otherwise claim ownership the same way the
             // round-1 culprit did with a foreign start). The parent turn's own
             // message/tool frames own the turn. Secure prompts are likewise
             // prompts, not turn-starters — handled like approval/clarify.
             .subagentStart, .subagentThinking, .subagentTool,
             .subagentProgress, .subagentComplete,
             .sudoRequest, .secretRequest,
             // ABH-46: `error` ENDS a turn (like message.complete), never begins one.
             .error,
             // ABH-84: session.info carries model/reasoning/fast hot-swap state;
             // handled upstream in ConnectionStore, not a turn-lifecycle frame.
             .sessionInfo:
            break
        }

        switch event.type {
        case .messageStart:
            beginStreamingMessage()
        case .messageDelta:
            if let text = event.payload["text"]?.stringValue, !text.isEmpty {
                textBuffer += text
                scheduleFlush()
            }
        case .thinkingDelta, .reasoningDelta:
            if let text = event.payload["text"]?.stringValue, !text.isEmpty {
                thinkingBuffer += text
                scheduleFlush()
            }
        case .toolStart:
            handleToolStart(event.payload)
        case .toolProgress:
            handleToolProgress(ToolProgressPayload(payload: event.payload))
        case .toolComplete:
            handleToolComplete(ToolCompletePayload(payload: event.payload))
        case .messageComplete:
            setSessionCompacting(event.sessionId, false)
            handleMessageComplete(event.payload)
        case .approvalRequest:
            handleApprovalRequest(event)
        case .clarifyRequest:
            handleClarifyRequest(event)
        case .subagentStart, .subagentThinking, .subagentTool,
             .subagentProgress, .subagentComplete:
            handleSubagentEvent(type: event.type, payload: event.payload)
        case .sudoRequest:
            handleSudoRequest(event)
        case .secretRequest:
            handleSecretRequest(event)
        case .error:
            handleGatewayError(event.payload)
        case .statusUpdate:
            handleStatusUpdate(event)
        case .gatewayReady, .unknown,
             // ABH-84: session.info is handled by ConnectionStore, not ChatStore.
             .sessionInfo:
            break
        }
    }

    /// Turn-level failure from the gateway (`error` event, payload
    /// `{"message": ...}` — server.py 813 "agent init failed" / 4674 turn
    /// exception). Before ABH-46 this event was dropped at every routing layer,
    /// so a failed turn left the spinner streaming forever with no explanation.
    /// Finalize the in-flight message, clear all streaming/tool state, release
    /// local-turn ownership, and surface the message via `lastError` (the
    /// existing toast seam).
    private func handleGatewayError(_ payload: JSONValue) {
        setSessionCompacting(activeSessionId, false)
        flushBuffersImmediately()
        let message = payload["message"]?.stringValue ?? "The agent hit an error"
        if streamingMessageID != nil {
            mutateStreaming { msg in
                msg.isStreaming = false
                if msg.text.isEmpty {
                    msg.applyFinalText("⚠️ \(message)")
                } else {
                    msg.setWarningPart(message)
                }
            }
            streamingMessageID = nil
        }
        // Any tool still advertised as running is dead with the turn.
        activeToolName = nil
        activeToolCallId = nil
        onToolChange?(nil)
        endLocalTurn()
        setStreaming(false, reason: "gatewayError")
        // `error` is a turn TERMINAL just like `message.complete` — the
        // turn's pending asks died with it server-side, so every card
        // (secure prompt included: answering a dead `request_id` is a
        // swallowed 4009 that looks like success) is stale from here.
        expireTurnScopedPrompts(includeSecure: true)
        // The errored turn's Live Activity dies with it (ABH-49 judge round):
        // this was the ONE turn terminal firing no LA seam, leaving the
        // activity frozen on "Thinking"/"Running <tool>" until the stale
        // horizon — and, because it was never ended, the NEXT turn's start()
        // reused the orphan. A discard (not a completion) because the queue
        // should not auto-drain into a session that just errored.
        onTurnDiscarded?()
        lastError = message
    }

    /// Handle a frame classified as FOREIGN by ``ownership(of:)`` — another client
    /// driving the same stored session we have open. The adoption gate keys on the
    /// explicit ``localTurnInFlight`` token: a foreign turn is adopted only when the
    /// user is NOT running a local one. A foreign-owned stream never blocks
    /// adoption (so a prior mirrored turn's residue can't refuse the next mirror),
    /// and — critically — a foreign frame that arrives while `activeRuntimeId` is
    /// still `nil` is handled HERE (it can no longer leak to `beginStreamingMessage()`
    /// and masquerade as local). The runtime id is non-nil for a real broadcast
    /// frame; `sid` falls back to the empty string only for a malformed frame, which
    /// the stored-id correlation in `ownership(of:)` already vetted.
    private func handleForeignFrame(_ event: GatewayEvent) {
        if event.type == .statusUpdate {
            handleStatusUpdate(event)
            return
        }
        let sid = event.sessionId ?? ""
        let isPrompt = event.type == .approvalRequest || event.type == .clarifyRequest
        if let current = mirroringRuntimeId {
            // Already adopted this foreign runtime: a *second* concurrent foreign
            // runtime on the same stored session is dropped, but every frame of the
            // adopted runtime is followed through — including its live deltas, even
            // though `isStreaming` is true for the foreign stream we adopted.
            guard sid == current else { return }
        } else {
            // Adopt a foreign turn only when the user is NOT running a local one
            // (explicit token — never an `isStreaming` heuristic). A residual
            // foreign-owned `isStreaming` does not block adoption.
            // Approvals/clarifications are always relevant regardless of streaming.
            guard isPrompt || !localTurnInFlight else {
                #if DEBUG
                foreignMirrorTelemetry.foreignDroppedWhileStreaming += 1
                #endif
                return
            }
            if !isPrompt {
                mirroringRuntimeId = sid
                streamingIsForeign = true
                #if DEBUG
                foreignMirrorTelemetry.foreignAdopted += 1
                #endif
            }
        }
        #if DEBUG
        if !isPrompt,
           event.type == .messageDelta || event.type == .thinkingDelta
            || event.type == .reasoningDelta {
            foreignMirrorTelemetry.foreignDeltasApplied += 1
        }
        #endif
        if event.type == .messageComplete || event.type == .error {
            setSessionCompacting(event.sessionId, false)
            #if DEBUG
            foreignMirrorTelemetry.foreignCompletesReconciled += 1
            #endif
            // Tear down ONLY the adopted foreign stream state — never a
            // genuinely-local turn (`streamingIsForeign` guards that) — so the
            // subsequent `backfill()` is not no-op'd by its own `guard
            // !isStreaming`. The foreign user's prompt bubble never streamed to us,
            // so we reconcile the full transcript from the server once the mirrored
            // turn lands. A foreign `error` ends the mirrored turn the same way —
            // tear down and reconcile rather than leave an adopted stream spinning.
            //
            // §3.7 IN-PLACE RECONCILE (D9): preserve the placeholder row across the
            // teardown so the immediately-following `backfill()`/`seed()` reconciles
            // the finalized reply ONTO it (no blink-out + restack). The teardown
            // records the placeholder id in `pendingForeignReconcileID`; the seed's
            // `reconcileMessages` consumes it.
            teardownForeignStream(preservePlaceholderForReconcile: true)
            let backfillTask = Task {
                await self.backfill()
                // A foreign-mirrored turn ending is a turn completion too: the
                // stored session just went idle, so let the queue drain into it
                // (R1 #29 — previously only a LOCAL complete triggered the
                // drain, stranding queued prompts whenever the completing turn
                // was a mirror). Fired AFTER the reconcile so the drained
                // prompt's send can't race the seed (the post-await guard
                // would discard the mirror's reconciled text).
                self.onTurnComplete?()
            }
            #if DEBUG
            lastForeignBackfillTask = backfillTask
            #endif
            // The REST backfill is the authoritative reconcile for a mirrored turn;
            // we do not also run the frame through `handleMessageComplete` (which
            // would mutate a now torn-down streaming message).
            return
        }

        // A live foreign frame just landed — (re)arm the staleness watchdog so a
        // mirror whose source goes silent is ended instead of spinning forever
        // (the "can't send after the desktop touched the session" bug).
        armForeignMirrorWatchdog()

        // Apply the adopted foreign frame through the same transcript switch a
        // local frame uses — begin/delta/tool — so the mirrored turn renders live.
        switch event.type {
        case .messageStart:
            beginStreamingMessage(foreign: true)
            // ABH-159 — surface the foreign turn's USER prompt NOW. The gateway
            // never broadcasts the user message as a frame (only assistant
            // frames), so a mirror's ONLY delivery of the user bubble is the
            // message.complete backfill — a single fragile point that's missed
            // whenever `complete` is dropped/late (the same "mirror goes silent"
            // failure the watchdog compensates for), leaving the user bubble
            // absent until a force-quit reseed. Append-only by deterministic id,
            // so the later backfill reconciles in place — never a duplicate — and
            // it never tears down or races the live foreign assistant stream.
            mergeForeignUserRows()
        case .messageDelta:
            if let text = event.payload["text"]?.stringValue, !text.isEmpty {
                textBuffer += text
                scheduleFlush()
            }
        case .thinkingDelta, .reasoningDelta:
            if let text = event.payload["text"]?.stringValue, !text.isEmpty {
                thinkingBuffer += text
                scheduleFlush()
            }
        case .toolStart:
            handleToolStart(event.payload)
        case .toolProgress:
            handleToolProgress(ToolProgressPayload(payload: event.payload))
        case .toolComplete:
            handleToolComplete(ToolCompletePayload(payload: event.payload))
        case .approvalRequest:
            handleApprovalRequest(event)
        case .clarifyRequest:
            handleClarifyRequest(event)
        case .subagentStart, .subagentThinking, .subagentTool,
             .subagentProgress, .subagentComplete:
            // A mirrored (foreign) turn that delegates renders its subagent tree
            // too, so the desktop's delegation is visible on the phone.
            handleSubagentEvent(type: event.type, payload: event.payload)
        case .messageComplete, .gatewayReady, .statusUpdate, .unknown,
             // Secure prompts are session-local and never broadcast-mirrored
             // (the gateway emits them only to the requesting runtime), so a
             // foreign sudo/secret frame is inert — we never present another
             // client's password/secret prompt.
             .sudoRequest, .secretRequest,
             // `.error` returned early above (teardown + reconcile) — listed
             // here only for exhaustiveness.
             .error,
             // ABH-84: session.info is session-local (config hot-swap feedback),
             // handled in ConnectionStore, never applies to a foreign session.
             .sessionInfo:
            break  // messageComplete handled above; the rest are inert here.
        }
    }

    /// Begin (or reuse) the streaming assistant message for a turn. `foreign`
    /// declares the ownership EXPLICITLY at the call site — the routing layer has
    /// already classified the frame, so this never re-derives ownership. A local
    /// `message.start` must NOT be reachable for a foreign frame: that was the
    /// round-1 culprit, where a foreign start ran this with `foreign:false` and
    /// claimed local ownership.
    private func beginStreamingMessage(foreign: Bool = false) {
        // Never crash the client on an out-of-order ownership marker. The router
        // should set `streamingIsForeign` before this path, but a gateway restart
        // / buffered-frame edge must degrade to a conservative foreign stream, not
        // trip a debug assertion while the reconnect recovery is trying to run.
        if foreign, !streamingIsForeign {
            chatLog.warning("foreign message.start reached beginStreamingMessage without streamingIsForeign; coercing foreign ownership")
            streamingIsForeign = true
        }
        // A tool event may already have created the streaming message; reuse it.
        if streamingMessageID == nil {
            if !foreign,
               let reconnectID = pendingReconnectReconcileID,
               let index = messages.firstIndex(where: { $0.id == reconnectID && $0.role == .assistant }) {
                // ABH-276: after a transport drop, the half-streamed local reply is
                // left visible with a "Connection lost" warning. If the gateway
                // resumes that same server turn before the reconnect backfill
                // settles, stream back INTO that interrupted row. Appending a
                // fresh assistant here creates the duplicate-bubble race: warning
                // row + resumed row for one logical reply.
                streamingMessageID = reconnectID
                messages[index].isStreaming = true
            } else {
                let message = ChatMessage(role: .assistant, isStreaming: true)
                streamingMessageID = message.id
                messages.append(message)
            }
        } else {
            mutateStreaming { $0.isStreaming = true }
        }
        markTurnStartedIfNeeded()
        setStreaming(true, reason: foreign ? "beginStreamingMessage(foreign)" : "beginStreamingMessage")
    }

    /// Ensure there is a streaming assistant message and return its id. Tools can
    /// fire before `message.start`, so this lazily creates one when needed.
    @discardableResult
    private func ensureStreamingMessage() -> UUID {
        if let id = streamingMessageID { return id }
        let message = ChatMessage(role: .assistant, isStreaming: true)
        streamingMessageID = message.id
        messages.append(message)
        markTurnStartedIfNeeded()
        setStreaming(true, reason: "ensureStreamingMessage")
        return message.id
    }

    /// Stamp `turnStartedAt` on the first event of a turn and fire the
    /// `onTurnStart` Live Activity seam exactly once per turn (at the nil→date
    /// transition). Both `message.start` and an early `tool.start` route here, so
    /// the activity starts on whichever lands first.
    private func markTurnStartedIfNeeded() {
        guard turnStartedAt == nil else { return }
        turnStartedAt = Date()
        onTurnStart?()
    }

    private func handleToolStart(_ payload: JSONValue) {
        guard let start = ToolStartPayload(payload: payload) else { return }
        // Preserve the desktop-style assistant grammar: text/reasoning that
        // arrived before a tool belongs before that tool in the transcript, even
        // though deltas are normally coalesced on a 40ms timer.
        flushBuffersImmediately()
        ensureStreamingMessage()
        activeToolName = start.name
        activeToolCallId = start.toolCallId
        onToolChange?(start.name)
        let activity = ToolActivity(
            id: start.toolCallId,
            name: start.name,
            argsSummary: String(start.args.compactDescription.prefix(200)),
            progressText: "",
            resultPreview: "",
            state: .running,
            durationMs: nil,
            todos: nil
        )
        mutateStreaming { $0.upsertToolActivity(activity) }
    }

    private func handleToolProgress(_ payload: ToolProgressPayload) {
        guard let id = payload.toolCallId, let text = payload.text else { return }
        mutateTool(id: id) { $0.progressText = text }
    }

    private func handleToolComplete(_ payload: ToolCompletePayload) {
        guard let id = payload.toolCallId else { return }
        let failed = Self.indicatesFailure(name: payload.name, result: payload.result)
        let preview = String(payload.result.compactDescription.prefix(300))
        // Retain the full structured todo array from the untruncated result so
        // the TodoCardView never re-parses the 300-char preview (which would
        // fail JSON parsing on any non-trivial list). The gateway puts the
        // list inside the result object under `todos` for the `todo` tool
        // (tui_gateway/server.py:2077 _on_tool_complete) and also mirrors it to
        // a top-level `payload.todos`; read either.
        let todos = payload.result["todos"]?.arrayValue ?? payload.todos
        mutateTool(id: id) { tool in
            tool.state = failed ? .failed : .done
            tool.resultPreview = preview
            tool.durationMs = payload.durationMs
            tool.todos = todos
        }
        // Clear the activity-bar tool label only when the tool that finished is
        // the one currently advertised, so a later tool's label survives.
        if activeToolCallId == id {
            activeToolName = nil
            activeToolCallId = nil
            onToolChange?(nil)
        }
    }

    /// A tool is considered failed if its result carries an `error` key or its
    /// name suggests a failure outcome.
    private static func indicatesFailure(name: String?, result: JSONValue) -> Bool {
        if let object = result.objectValue, object["error"] != nil, !(object["error"]?.isNull ?? true) {
            return true
        }
        if let name = name?.lowercased(),
           name.contains("error") || name.contains("fail") {
            return true
        }
        return false
    }

    private func handleMessageComplete(_ payload: JSONValue) {
        flushBuffersImmediately()
        let completion = payload.decoded(as: MessageCompletePayload.self)
        let id = ensureStreamingMessage()
        let failedStatuses = ["error", "failed", "interrupted", "cancelled", "canceled"]
        let completionStatus = completion?.status?.lowercased()
        let completionFailed = completionStatus.map { failedStatuses.contains($0) } ?? false
        let shouldClearReconnectWarning = completion != nil
            && pendingReconnectReconcileID == id
            && completion?.warning == nil
            && !completionFailed
            && (completionStatus == nil || completionStatus == "completed")
        // Wall-clock the turn took, used to label a collapsed tool cluster.
        let elapsed = turnStartedAt.map { Date().timeIntervalSince($0) }
        // A2 (scarf): suppress the implicit animation on the streaming→final flip.
        // The finalized content is value-equal to what streamed (isStreaming=false +
        // per-cluster tool collapse + authoritative final text), so SwiftUI would
        // otherwise animate a no-op structural diff — the turn-end flash / height
        // jump on the last bubble. The cursor's own fade (cursorView.onChange) is a
        // separate in-view `withAnimation` and is unaffected by this transaction.
        withTransaction(Transaction(animation: nil)) {
        mutateStreaming { message in
            if let text = completion?.text, !text.isEmpty {
                message.applyFinalText(text)
            }
            // Authoritative final reasoning (ABH-46 item 5): replaces whatever
            // streamed in via thinking/reasoning deltas — the gateway's
            // `message.complete.reasoning` is the complete, settled text, and a
            // throttled/broadcast client may have missed deltas.
            if let reasoning = completion?.reasoning, !reasoning.isEmpty {
                message.applyFinalReasoning(reasoning)
            }
            if let warning = completion?.warning {
                message.setWarningPart(warning)
            }
            // Non-success terminal status (ABH-46 item 5): surface it on the
            // bubble. `status` is "completed" on the happy path; anything
            // error-like becomes the warning strip (without clobbering an
            // explicit warning the server already sent).
            if let status = completion?.status,
               failedStatuses.contains(status.lowercased()),
               message.warning == nil {
                message.setWarningPart("Turn \(status)")
            }
            if shouldClearReconnectWarning {
                message.clearWarningPart()
            }
            message.setUsagePart(completion?.usage)
            message.isStreaming = false
            // PER-CLUSTER collapse (ABH-87 Batch D / contract §3.2, fixes D8):
            // each finalized `.tools` cluster decides independently — a cluster of
            // ≥2 consecutive tools folds into one "N tool calls" summary; a
            // single-tool cluster keeps its lone row. So a turn that interleaves
            // `text→toolA→text→toolB` shows TWO separate single-tool rows, not two
            // "1 tool call" capsules. The decision now lives entirely inside
            // `collapseFinishedToolClusters` (no turn-total gate here); calling it
            // unconditionally is a no-op for a turn with no ≥2-tool cluster. Seeded
            // transcripts never reach this path.
            message.collapseFinishedToolClusters(turnElapsed: elapsed)
        }
        }  // withTransaction(animation: nil) — A2
        if streamingMessageID == id { streamingMessageID = nil }
        if pendingReconnectReconcileID == id { pendingReconnectReconcileID = nil }
        // The local turn finalized. This path is only ever reached for a LOCAL
        // frame — a foreign `message.complete` is intercepted in
        // `handleForeignFrame` and returns before here — so releasing the
        // local-turn token here is exactly the turn's own completion. ownership=LOCAL.
        endLocalTurn()
        setStreaming(false, reason: "handleMessageComplete")
        // Context-window occupancy updates once per completed turn (H1): the
        // just-finished turn's usage describes the occupancy of the last API
        // prompt. A turn whose usage omits the context fields leaves the prior
        // reading in place (occupancy doesn't reset just because one frame
        // lacked it).
        applyContextUsage(from: completion?.usage)
        textBuffer = ""
        thinkingBuffer = ""
        if activeToolName != nil {
            activeToolName = nil
            activeToolCallId = nil
            onToolChange?(nil)
        } else {
            activeToolCallId = nil
        }

        // Success haptic only for turns that kept the user waiting a while.
        if let started = turnStartedAt,
           Date().timeIntervalSince(started) > Self.turnCompleteHapticThreshold {
            NotificationService.turnCompleteHaptic()
        }
        turnStartedAt = nil

        // The turn ended, so any prompt card still up is stale — it was
        // resolved elsewhere (desktop/inbox) or the agent moved on without it.
        // Leaving it pinned invites a re-send against an already-resolved
        // request (R1 #52). Mirrors InboxStore's expire-on-complete. The
        // secure prompt is left to its own RPC lifecycle (cleared up-front in
        // `respondSecurePrompt`).
        expireTurnScopedPrompts(includeSecure: false)

        // The turn finished — let the queue drain its next item (if any).
        onTurnComplete?()
    }

    /// Expire the turn-scoped prompt cards: a pending approval/clarification
    /// belongs to an in-flight turn, so when that turn ends (local
    /// `message.complete` / `error`) or the transcript is authoritatively
    /// reconciled after a reconnect/restart (`backfill()` seed), the card is
    /// stale and answering it would target a stale — possibly dead — runtime
    /// (R1 #51/#52). `includeSecure` additionally drops a transient
    /// sudo/secret prompt — ONLY on paths that prove its turn is over (the
    /// `error` terminal, a transport drop): unlike approvals it has no inbox
    /// fallback, so a reconcile that proves nothing about its turn (e.g. a
    /// live-socket `broadcast_gap` backfill) must leave it alone. The
    /// complete path leaves it to `respondSecurePrompt`'s own lifecycle.
    private func expireTurnScopedPrompts(includeSecure: Bool) {
        if pendingApproval != nil {
            pendingApproval = nil
            onApprovalChange?(false)
        }
        pendingClarification = nil
        if includeSecure {
            pendingSecurePrompt = nil
        }
    }

    // MARK: - Context-window occupancy (H1)

    /// Project a `UsageStats` onto `contextUsage`. Requires all three of
    /// used/max/percent (a usage block without the context fields — older turns,
    /// providers that don't report it — is ignored and leaves the prior reading
    /// intact). `compressions` defaults to 0 when absent.
    private func applyContextUsage(from usage: UsageStats?) {
        guard let usage,
              let used = usage.contextUsed,
              let max = usage.contextMax,
              let percent = usage.contextPercent
        else { return }
        contextUsage = (used: used, max: max, percent: percent,
                        compressions: usage.compressions ?? 0)
    }

    /// Seed `contextUsage` once from `session.status` after a resume, so a
    /// reopened session shows its occupancy *before* the first new turn lands
    /// (the status result's `usage` carries the same context fields the
    /// `message.complete` usage does). No-op while a turn is streaming (a live
    /// turn's own `message.complete` is the fresher source) and when the status
    /// usage omits the context fields. Callers pass the runtime id they just
    /// resumed; a mismatch with the now-active session means a newer open
    /// superseded this one, so the seed is dropped.
    func seedContextUsageFromStatus(runtimeId: String) async {
        guard !isStreaming else { return }
        guard let client else { return }
        // `session.usage` returns the usage dict FLAT as the RPC result —
        // including `context_used`/`context_max`/`context_percent` when the
        // agent has a context compressor (`tui_gateway/server.py` `_get_usage`)
        // — which is exactly the UsageStats shape. `session.status` nests a
        // usage block too, but the flat RPC is the canonical occupancy source
        // (ABH-46 item 3) and avoids decoding the unrelated status metadata.
        let usage: UsageStats? = try? await client.request(
            "session.usage",
            params: .object(["session_id": .string(runtimeId)]),
            timeout: .seconds(30)
        )
        // A newer open may have activated a different session while we awaited.
        guard runtimeId == activeSessionId, !isStreaming else { return }
        applyContextUsage(from: usage)
    }

    /// Reconcile a freshly-resumed session against the live runtime state.
    ///
    /// Opening a stored session can resume into a runtime that is already running
    /// (for example, the user re-enters a chat whose turn was started elsewhere or
    /// before navigating away). The REST transcript only contains persisted rows;
    /// it does NOT prove the current runtime is idle. After the open seed has
    /// landed, ask the gateway for `session.status` and, if it reports `running`,
    /// re-create the local in-flight UI state: a streaming assistant placeholder,
    /// the global `isStreaming` flag, the local-turn ownership token (so mutable
    /// actions are disabled), and the Stop target (`activeSessionId`).
    ///
    /// This is deliberately idempotent: a live websocket `message.start` that wins
    /// the race simply means the streaming row already exists, and a superseded
    /// open drops out via the runtime-id guard.
    func reconcileLiveTurnStatus(runtimeId: String) async {
        guard let fetch = resolvedLiveTurnStatusFetch else { return }
        let status = try? await fetch(runtimeId)
        guard runtimeId == activeSessionId else { return }
        if let usage = status?.usage, !isStreaming {
            applyContextUsage(from: usage)
        }
        guard status?.running == true else { return }
        beginLocalTurn()
        beginStreamingMessage()
    }

    /// Injectable seam for `reconcileLiveTurnStatus` tests. The live path uses the
    /// gateway `session.status` RPC; tests can answer synchronously without a socket.
    var liveTurnStatusFetch: ((String) async throws -> SessionStatusResult)?

    private var resolvedLiveTurnStatusFetch: ((String) async throws -> SessionStatusResult)? {
        if let liveTurnStatusFetch { return liveTurnStatusFetch }
        guard let client else { return nil }
        return { runtimeId in
            try await client.request(
                "session.status",
                params: .object(["session_id": .string(runtimeId)]),
                timeout: .seconds(30)
            )
        }
    }

    private func handleApprovalRequest(_ event: GatewayEvent) {
        let request = ApprovalRequestPayload(payload: event.payload)
        let sessionId = event.sessionId ?? activeSessionId ?? ""
        pendingApproval = PendingApproval(id: request.id, sessionId: sessionId, request: request)
        onApprovalChange?(true)
        guard DefaultsKeys.pushEventEnabled(DefaultsKeys.pushEventApproval) else { return }
        // First approval/clarify of the session is when we ask for permission.
        NotificationService.requestAuthorizationIfNeeded()
        NotificationService.postApprovalNotification(
            title: request.title,
            body: request.descriptionText ?? request.target ?? "Tap to review."
        )
        NotificationService.approvalHaptic()
    }

    private func handleClarifyRequest(_ event: GatewayEvent) {
        let request = ClarifyRequestPayload(payload: event.payload)
        let sessionId = event.sessionId ?? activeSessionId ?? ""
        pendingClarification = PendingClarification(sessionId: sessionId, request: request)
        guard DefaultsKeys.pushEventEnabled(DefaultsKeys.pushEventClarify) else { return }
        // First approval/clarify of the session is when we ask for permission.
        NotificationService.requestAuthorizationIfNeeded()
        NotificationService.postClarifyNotification(question: request.question)
        NotificationService.approvalHaptic()
    }

    // MARK: - Subagent tree (F4A-A2)

    /// Derived projection: the top-level subagent branches, in first-seen order.
    /// Read by `SubagentTreeView`; never exposes the mutable assembly map.
    var subagentRoots: [SubagentNode] {
        subagentRootIds.compactMap { subagentNodes[$0] }
    }

    /// Derived projection: the ordered children of `node`.
    func subagentChildren(of node: SubagentNode) -> [SubagentNode] {
        node.childIds.compactMap { subagentNodes[$0] }
    }

    /// Whether any subagent activity has been recorded for the active turn — the
    /// view gate for showing the tree surface at all.
    var hasSubagentActivity: Bool { !subagentNodes.isEmpty }

    /// Fold a `subagent.*` frame into the tree. Node identity is the
    /// `subagent_id`; an id-less emitter falls back to a synthesized
    /// `parent|taskIndex` key so a flat tree still renders one row per branch.
    /// The same node is updated in place across start → thinking/tool/progress →
    /// complete, so the tree mutates rather than appending duplicate rows.
    private func handleSubagentEvent(type: GatewayEventType, payload rawPayload: JSONValue) {
        let payload = SubagentEventPayload(payload: rawPayload)
        let nodeId = subagentNodeId(for: payload)
        let parentId = payload.parentId
        let isNew = subagentNodes[nodeId] == nil

        var node = subagentNodes[nodeId] ?? SubagentNode(
            id: nodeId,
            parentId: parentId,
            depth: payload.depth ?? 0,
            taskIndex: payload.taskIndex ?? 0,
            taskCount: payload.taskCount ?? 1,
            goal: payload.goal ?? "Subagent",
            model: payload.model,
            activity: "",
            status: .running,
            summary: nil,
            durationSeconds: nil,
            inputTokens: nil,
            outputTokens: nil,
            reasoningTokens: nil,
            apiCalls: nil,
            costUsd: nil,
            filesRead: [],
            filesWritten: [],
            childIds: []
        )

        // Stable identity/structure fields fill in as later frames carry them
        // (an early thinking frame may precede the start that has the goal).
        if let parentId { node.parentId = parentId }
        if let depth = payload.depth { node.depth = depth }
        if let taskIndex = payload.taskIndex { node.taskIndex = taskIndex }
        if let taskCount = payload.taskCount { node.taskCount = taskCount }
        if let goal = payload.goal, !goal.isEmpty { node.goal = goal }
        if let model = payload.model { node.model = model }

        switch type {
        case .subagentStart:
            node.status = .running
            if let goal = payload.goal, !goal.isEmpty { node.activity = goal }
        case .subagentThinking:
            if let text = payload.text, !text.isEmpty { node.activity = text }
        case .subagentTool:
            // Prefer the explicit tool name + preview; fall back to the free text.
            let toolName = payload.toolName ?? ""
            let preview = payload.toolPreview ?? payload.text ?? ""
            node.activity = [toolName, preview]
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
        case .subagentProgress:
            if let text = payload.text, !text.isEmpty { node.activity = text }
        case .subagentComplete:
            node.status = SubagentNode.Status(completionStatus: payload.status)
            node.summary = payload.summary
            node.durationSeconds = payload.durationSeconds
            node.inputTokens = payload.inputTokens
            node.outputTokens = payload.outputTokens
            node.reasoningTokens = payload.reasoningTokens
            node.apiCalls = payload.apiCalls
            node.costUsd = payload.costUsd
            if let read = payload.filesRead { node.filesRead = read }
            if let written = payload.filesWritten { node.filesWritten = written }
            // On a timeout/error the summary is empty; surface the preview/text so
            // the row is not blank.
            if (node.summary ?? "").isEmpty, let text = payload.text, !text.isEmpty {
                node.activity = text
            }
        default:
            break
        }

        subagentNodes[nodeId] = node

        if isNew {
            // Link into the tree exactly once, when the node is first created.
            if let parentId, var parent = subagentNodes[parentId] {
                insertChild(nodeId, into: &parent)
                subagentNodes[parentId] = parent
            } else if parentId != nil {
                // Parent frame hasn't been seen yet — record the edge so the
                // parent picks the child up when it arrives (handled below).
                pendingSubagentChildren[parentId!, default: []].append(nodeId)
            } else {
                subagentRootIds.append(nodeId)
            }
            // If THIS node is the late-arriving parent of earlier orphans, adopt
            // them now in their task order.
            if let orphans = pendingSubagentChildren.removeValue(forKey: nodeId) {
                var parent = subagentNodes[nodeId]!
                for child in orphans { insertChild(child, into: &parent) }
                subagentNodes[nodeId] = parent
            }
            subagentNodeCount = subagentNodes.count
        }
    }

    /// Edges whose parent node hasn't been seen yet (a child frame arrived before
    /// its parent's start). Drained when the parent is created.
    private var pendingSubagentChildren: [String: [String]] = [:]

    /// Insert `childId` into `parent.childIds` keeping the list ordered by the
    /// child's `taskIndex` (siblings render in spawn order regardless of frame
    /// arrival order). Idempotent.
    private func insertChild(_ childId: String, into parent: inout SubagentNode) {
        guard !parent.childIds.contains(childId) else { return }
        let childIndex = subagentNodes[childId]?.taskIndex ?? .max
        let insertAt = parent.childIds.firstIndex {
            (subagentNodes[$0]?.taskIndex ?? .max) > childIndex
        } ?? parent.childIds.count
        parent.childIds.insert(childId, at: insertAt)
    }

    /// Resolve a stable node id: the `subagent_id` when present, else a
    /// synthesized `<parent>|<taskIndex>` key so an id-less emitter still keys
    /// one node per branch.
    private func subagentNodeId(for payload: SubagentEventPayload) -> String {
        if let sid = payload.subagentId, !sid.isEmpty { return sid }
        let parent = payload.parentId ?? "root"
        let index = payload.taskIndex ?? 0
        return "\(parent)|\(index)"
    }

    /// Clear the subagent tree (per-turn / open / reset).
    private func resetSubagentTree() {
        guard !subagentNodes.isEmpty || !subagentRootIds.isEmpty
            || !pendingSubagentChildren.isEmpty else { return }
        subagentNodes = [:]
        subagentRootIds = []
        pendingSubagentChildren = [:]
        subagentNodeCount = 0
    }

    // MARK: - Secure prompts: sudo / secret (F4A-A2)

    /// Handle a `sudo.request` event: stage a transient secure prompt for a
    /// password. NEVER persisted, NEVER routed to the inbox. The reply goes back
    /// on `sudo.respond` keyed by `request_id` (handled by `respondSecurePrompt`).
    private func handleSudoRequest(_ event: GatewayEvent) {
        guard let request = SudoRequestPayload(payload: event.payload) else { return }
        let sessionId = event.sessionId ?? activeSessionId ?? ""
        pendingSecurePrompt = PendingSecurePrompt(
            kind: .sudo,
            requestId: request.requestId,
            sessionId: sessionId,
            prompt: "Enter your sudo password to continue.",
            envVar: nil,
            metadata: [:]
        )
        // A secure prompt needs the user's attention even when backgrounded; reuse
        // the approval notification/haptic seam (no secret content is included).
        NotificationService.requestAuthorizationIfNeeded()
        NotificationService.approvalHaptic()
    }

    /// Handle a `secret.request` event: stage a transient secure prompt for a
    /// secret value. The PROMPT side only — the entered value is held solely in
    /// the view's `@State` and never reaches the store.
    private func handleSecretRequest(_ event: GatewayEvent) {
        guard let request = SecretRequestPayload(payload: event.payload) else { return }
        let sessionId = event.sessionId ?? activeSessionId ?? ""
        pendingSecurePrompt = PendingSecurePrompt(
            kind: .secret,
            requestId: request.requestId,
            sessionId: sessionId,
            prompt: request.prompt,
            envVar: request.envVar,
            metadata: request.metadata
        )
        NotificationService.requestAuthorizationIfNeeded()
        NotificationService.approvalHaptic()
    }

    /// Reply to the pending secure prompt and clear it.
    ///
    /// - Parameter value: the password / secret the user entered, or `nil` to
    ///   SKIP (an empty reply, which the gateway treats as `skipped:true`). The
    ///   value is forwarded straight to the RPC and is never logged, stored, or
    ///   retained after this call returns.
    ///
    /// SECRET HYGIENE: this method takes the value, sends it on the correct RPC
    /// (`sudo.respond` key `password`, `secret.respond` key `value`) keyed by
    /// `request_id`, and returns — it keeps no copy. The error path surfaces a
    /// GENERIC message that never includes the value.
    func respondSecurePrompt(value: String?) async {
        guard let prompt = pendingSecurePrompt else { return }
        // Clear the pending prompt up front so the UI dismisses immediately and a
        // duplicate reply can't be sent. The value lives only in the local
        // parameter for the duration of this call.
        pendingSecurePrompt = nil
        guard let client else { return }
        // The gateway's `_respond` router (server.py:5058) routes the reply purely
        // by `request_id` — it carries no `session_id` param — so the prompt's
        // session is not needed on the wire.
        // An empty string is the gateway's SKIP signal; a nil means the same.
        let replyValue = value ?? ""
        let method: String
        let valueKey: String
        switch prompt.kind {
        case .sudo:
            method = "sudo.respond"
            valueKey = "password"
        case .secret:
            method = "secret.respond"
            valueKey = "value"
        }
        do {
            _ = try await client.requestRaw(
                method,
                params: .object([
                    "request_id": .string(prompt.requestId),
                    valueKey: .string(replyValue),
                ])
            )
        } catch let GatewayError.rpc(code, _) where code == GatewayErrorCode.sessionBusy {
            // 4009 here is "no pending <key> request" — the prompt already
            // expired/was answered elsewhere. Nothing to surface; the prompt is
            // already cleared. (GatewayErrorCode.sessionBusy == 4009, shared.)
            _ = code
        } catch {
            // GENERIC error — never echo the value. Session-local; not chrome.
            lastError = "Couldn't send the response. Please try again."
        }
        // `replyValue` / `value` go out of scope here; no copy is retained.
    }

    // MARK: - Branch / checkpoint (F4A-A2)

    /// Restore the conversation to a checkpoint: re-run from the chosen USER
    /// message, discarding everything after it. Maps the message to its
    /// `visibleUserOrdinal` and re-submits its (unchanged) text with
    /// `truncate_before_user_ordinal`, exactly mirroring the gateway's history
    /// index (`prompt.submit`, server.py:4131). The `4018` stale-target path is
    /// handled by ``submitTruncating`` (re-sync via backfill + friendly error).
    ///
    /// This is the user-message counterpart to ``retry(fromAssistantId:)``: retry
    /// re-runs the turn an ASSISTANT message belongs to; restore re-runs from the
    /// USER message itself. Both truncate to BEFORE the user message at that
    /// ordinal, so the chosen turn is regenerated and later turns are dropped.
    func restoreCheckpoint(toUserMessageId messageId: UUID) async {
        // Gate on LOCAL ownership, not display state: an adopted foreign mirror
        // sets `isStreaming` while the user owns no turn, and preemptively
        // claiming "busy" off that heuristic blocked these actions whenever
        // another client was active (R1 #30). If the session IS genuinely busy,
        // the server's own 4009 says so (and `submitTruncating` restores the
        // transcript it optimistically rewrote).
        guard !localTurnInFlight else {
            lastError = "Agent is busy"
            return
        }
        guard let index = messages.firstIndex(where: { $0.id == messageId }),
              messages[index].role == .user else { return }
        let text = messages[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let ordinal = userOrdinal(at: index)
        await submitTruncating(text: text, truncateBeforeUserOrdinal: ordinal, truncateFromIndex: index)
    }

    /// Build the `messages[]` seed for a branch-in-new-chat from the transcript
    /// UP TO AND INCLUDING `messageId`. The seed obeys the gateway's
    /// `_coerce_seed_history` rules (server.py:2917) so the create call accepts
    /// every item:
    ///   - role ∈ {`user`, `assistant`, `system`} ONLY (tool/other rows dropped),
    ///   - a NON-EMPTY string `content`,
    ///   - normalized to `{role, content}` ONLY (no tool_calls, usage, etc.).
    /// Collapsed/scaffolding rows whose `text` is empty are dropped just like the
    /// server would drop them. Returns the JSON array to pass as `messages` to
    /// `session.create`. An unknown `messageId` branches the WHOLE transcript.
    func branchSeed(upToMessageId messageId: UUID) -> [JSONValue] {
        let cutoff = messages.firstIndex(where: { $0.id == messageId }).map { $0 + 1 }
            ?? messages.count
        return messages[..<cutoff].compactMap { message -> JSONValue? in
            // Only the three seedable roles survive (mirrors _coerce_seed_history).
            let role: String
            switch message.role {
            case .user: role = "user"
            case .assistant: role = "assistant"
            case .system: role = "system"
            case .tool: return nil
            }
            let content = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return nil }
            return .object(["role": .string(role), "content": .string(content)])
        }
    }

    // MARK: - Coalesced flushing

    /// Schedule a single flush of the accumulated buffers ~40ms out. Repeated
    /// calls while a flush is pending are no-ops (one mutation per frame).
    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: ChatStore.flushInterval)
            guard let self, !Task.isCancelled else { return }
            self.flushTask = nil
            self.flushBuffers()
        }
    }

    /// Apply the buffered text/thinking to the streaming message and clear buffers.
    private func flushBuffers() {
        guard !textBuffer.isEmpty || !thinkingBuffer.isEmpty else { return }
        ensureStreamingMessage()
        let pendingText = textBuffer
        let pendingThinking = thinkingBuffer
        textBuffer = ""
        thinkingBuffer = ""
        mutateStreaming { message in
            // Wire-order rule (contract §2.5 / D3): reasoning streams as its own
            // block BEFORE the answer text it precedes, so when BOTH land in one
            // ~40ms flush window the reasoning delta must be applied FIRST — else
            // the open trailing text run swallows the position and reasoning is
            // forced into a later run (text-before-reasoning). Applying reasoning
            // first opens/extends the reasoning run, then text opens a fresh run
            // after it: `parts:[reasoning, text]`, matching the seed producer's
            // fixed within-row order and the desktop's delta arrival order.
            message.appendReasoningDelta(pendingThinking)
            message.appendAssistantTextDelta(pendingText)
        }
    }

    /// Flush synchronously, cancelling any pending scheduled flush. Used on
    /// `message.complete`.
    private func flushBuffersImmediately() {
        flushTask?.cancel()
        flushTask = nil
        flushBuffers()
    }

    #if DEBUG
    /// DEBUG-only crash-guard probe for ABH-355.
    ///
    /// Drives the exact out-of-order ownership-marker condition that used to be a
    /// DEBUG assertion: `beginStreamingMessage(foreign: true)` reached while the
    /// caller had not yet marked `streamingIsForeign`. The production fix must
    /// degrade to a conservative foreign stream instead of crashing.
    func simulateOutOfOrderForeignOwnershipMarkerForTesting() {
        beginStreamingMessage(foreign: true)
    }

    /// DEBUG-only crash-guard probe for ABH-355.
    ///
    /// Synthesizes the inconsistent edge that used to assert in
    /// `teardownForeignStream`: a foreign teardown arrives while a local turn token
    /// is still held. The guarded behavior is to preserve local ownership, clear
    /// the stale foreign marker, and let the normal connection-drop path finalize
    /// the local turn.
    func simulateForeignTeardownWithLocalTurnTokenForTesting() {
        beginLocalTurn()
        streamingIsForeign = true
        if streamingMessageID == nil {
            let message = ChatMessage(role: .assistant, isStreaming: true)
            streamingMessageID = message.id
            messages.append(message)
            markTurnStartedIfNeeded()
        }
        setStreaming(true, reason: "simulateForeignTeardownWithLocalTurnTokenForTesting")
        teardownForeignStream()
    }

    /// DEBUG-only deterministic drain hook for unit tests.
    ///
    /// Cancels the pending 40ms coalescing Task and calls the SAME `flushBuffers()`
    /// the production path would call — guaranteeing the buffered text/thinking is
    /// applied to `messages` synchronously, with no wall-clock dependency.
    ///
    /// Zero production-behavior change: the method is `#if DEBUG`-gated and only
    /// force-runs logic that already runs in production (on the flush Task's
    /// natural firing). Never compiled into Release.
    func drainFlushForTesting() {
        flushTask?.cancel()
        flushTask = nil
        flushBuffers()
    }

    /// DEBUG-only handle to the most recent foreign-complete backfill Task.
    /// Stored by `handleForeignFrame` when a foreign `message.complete` (or
    /// `error`) fires the `Task { await backfill() }`. Tests await this to
    /// deterministically wait for the REST reconcile without wall-clock settle().
    /// Never compiled into Release.
    private(set) var lastForeignBackfillTask: Task<Void, Never>?

    /// DEBUG-only: await the most recently spawned foreign-backfill Task, then
    /// yield once so any main-actor mutations have propagated before assertions.
    func waitForPendingForeignBackfillForTesting() async {
        await lastForeignBackfillTask?.value
        await Task.yield()
    }

    /// DEBUG-only handle to the most recent `mergeForeignUserRows` Task.
    /// Stored by `mergeForeignUserRows()` when a foreign `message.start` fires
    /// the start-time user-bubble fetch. Tests await this to deterministically
    /// wait for the user row to land without wall-clock settle().
    /// Never compiled into Release.
    private(set) var lastForeignUserRowMergeTask: Task<Void, Never>?

    /// DEBUG-only: await the most recently spawned foreign user-row merge Task,
    /// then yield once so any main-actor mutations have propagated before assertions.
    func waitForPendingForeignUserRowMergeForTesting() async {
        await lastForeignUserRowMergeTask?.value
        await Task.yield()
    }
    #endif

    // MARK: - Streaming-message mutation helpers

    /// Apply `transform` to the current streaming message in place.
    private func mutateStreaming(_ transform: (inout ChatMessage) -> Void) {
        guard let id = streamingMessageID,
              let index = messages.firstIndex(where: { $0.id == id }) else { return }
        transform(&messages[index])
    }

    /// Apply `transform` to the tool with `id` within the streaming message.
    private func mutateTool(id: String, _ transform: (inout ToolActivity) -> Void) {
        mutateStreaming { $0.updateToolActivity(id: id, transform) }
    }

    // MARK: - Outbound actions

    enum SlashCommandOutcome: Equatable, Sendable {
        case handled
        case prefill(String)
        case failed(String)
    }

    /// Run a slash command through the gateway's generic slash-command surface.
    ///
    /// Read-only commands render their textual output as a system row. Commands
    /// that resolve to a prompt (`send` / skill invocations) flow through the
    /// normal ``send(text:includeAttachments:)`` path so the transcript and
    /// streaming lifecycle stay identical to a typed prompt.
    func executeSlashCommand(_ rawCommand: String, depth: Int = 0) async -> SlashCommandOutcome {
        guard depth < 5 else {
            let message = "Slash command alias loop"
            appendSystemNotice(message)
            return .failed(message)
        }
        guard let invocation = SlashCommandInvocation.parse(rawCommand) else {
            let message = "Invalid slash command"
            appendSystemNotice(message)
            return .failed(message)
        }
        guard let client else {
            let message = "No active session"
            lastError = message
            return .failed(message)
        }
        guard let sessionId = await activeSlashSessionId() else {
            let message = "No active session"
            lastError = message
            return .failed(message)
        }

        let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let result = try await client.executeSlash(sessionId: sessionId, command: command)
            if let dispatch = SlashCommandDispatch(json: result) {
                return await handleSlashDispatch(dispatch, invocation: invocation, depth: depth)
            }
            let output = slashOutput(from: result, commandName: invocation.name)
            appendSystemNotice(output)
            return .handled
        } catch {
            // Fall back to command.dispatch for skill/send/alias directives, matching
            // the desktop implementation and covering slash-worker failures.
        }

        do {
            let result = try await client.dispatchCommand(
                sessionId: sessionId,
                name: invocation.name,
                arg: invocation.arg
            )
            guard let dispatch = SlashCommandDispatch(json: result) else {
                let message = "error: invalid response: command.dispatch"
                appendSystemNotice(message)
                return .failed(message)
            }
            return await handleSlashDispatch(dispatch, invocation: invocation, depth: depth)
        } catch {
            let message = "error: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            appendSystemNotice(message)
            lastError = message
            return .failed(message)
        }
    }

    private func activeSlashSessionId() async -> String? {
        if sessions?.isDraft == true {
            do {
                try await sessions?.createDraftSession()
            } catch {
                lastError = sessions?.lastError
                    ?? (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                return nil
            }
        }
        if let activeSessionId { return activeSessionId }
        return await sessions?.ensureActiveRuntime()
    }

    private func handleSlashDispatch(
        _ dispatch: SlashCommandDispatch,
        invocation: SlashCommandInvocation,
        depth: Int
    ) async -> SlashCommandOutcome {
        switch dispatch.kind {
        case .exec, .plugin:
            appendSystemNotice(dispatch.output?.trimmedNonEmpty ?? "(no output)")
            return .handled
        case .alias:
            guard let target = dispatch.target?.trimmedNonEmpty else {
                let message = "/\(invocation.name): alias target missing"
                appendSystemNotice(message)
                return .failed(message)
            }
            let next = "/\(target)\(invocation.arg.isEmpty ? "" : " \(invocation.arg)")"
            return await executeSlashCommand(next, depth: depth + 1)
        case .send, .skill:
            if let notice = dispatch.notice?.trimmedNonEmpty {
                appendSystemNotice(notice)
            }
            guard let message = dispatch.message?.trimmedNonEmpty else {
                let error = "/\(invocation.name): empty message"
                appendSystemNotice(error)
                return .failed(error)
            }
            if dispatch.kind == .skill, let name = dispatch.name?.trimmedNonEmpty {
                appendSystemNotice("⚡ loading skill: \(name)")
            }
            guard !localTurnInFlight else {
                let error = "session busy — interrupt the current turn before sending this command"
                appendSystemNotice(error)
                return .failed(error)
            }
            let accepted = await send(text: message, includeAttachments: false)
            return accepted ? .handled : .failed(lastError ?? "Slash command send failed")
        case .prefill:
            if let notice = dispatch.notice?.trimmedNonEmpty {
                appendSystemNotice(notice)
            }
            return .prefill(dispatch.message ?? "")
        }
    }

    private func slashOutput(from result: JSONValue, commandName: String) -> String {
        let output = result["output"]?.stringValue?.trimmedNonEmpty ?? "/\(commandName): no output"
        if let warning = result["warning"]?.stringValue?.trimmedNonEmpty {
            return "warning: \(warning)\n\(output)"
        }
        return output
    }

    private func appendSystemNotice(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        messages.append(ChatMessage(role: .system, text: trimmed))
    }

    /// Send a user prompt: optionally upload queued image attachments, append the
    /// user bubble immediately, then `prompt.submit`.
    ///
    /// `prompt.submit` requires non-empty text, but the user may send images with
    /// no caption. In that case we substitute a neutral default prompt so the
    /// agent is told to look at what was just attached.
    /// A busy session (`4009`) surfaces as a friendly error without resetting state.
    ///
    /// Returns whether the server ACCEPTED the prompt (`prompt.submit` resolved
    /// without throwing). This is the acceptance fact the queue drain keys on —
    /// it must NOT be inferred from `isStreaming`, which is flipped by the
    /// separate event-router task (`message.start` may not have been routed yet
    /// when this returns) and can be cleared by a concurrent `open()/reset()`
    /// mid-RPC; both inferences re-enqueued an already-delivered prompt
    /// (double-send, ABH-48 judge round).
    ///
    /// `includeAttachments: false` makes the send deterministic text-only —
    /// drained queue prompts use it so a prompt composed earlier can never
    /// grab whatever attachments happen to be pending at drain time.
    @discardableResult
    func send(text: String, includeAttachments: Bool = true) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasAttachments = includeAttachments && (attachments?.hasPending ?? false)
        guard !trimmed.isEmpty || hasAttachments else { return false }
        guard let connection, let client else {
            lastError = "No active session"
            return false
        }

        // Draft sessions: the first prompt materializes the real session
        // (session.create) before anything is uploaded or submitted. On failure
        // the user keeps their text and can retry without a half-started turn.
        // After this, `activeSessionId` is non-nil for the rest of the send.
        if sessions?.isDraft == true {
            do {
                try await sessions?.createDraftSession()
            } catch {
                lastError = sessions?.lastError
                    ?? (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                return false
            }
        }

        // Resolve the runtime id, self-healing the "No active session" trap. A
        // desktop-driven / cold-path session can leave `activeRuntimeId` nil (its
        // gateway resume timed out or never landed), and NOTHING on the send/drain
        // path re-attempts the resume — so every send AND every queue drain wedges
        // here forever. Re-resume on demand before giving up; the queue drain calls
        // send too, so this single edge fixes both.
        let sessionId: String
        if let rid = activeSessionId {
            sessionId = rid
        } else if let rid = await sessions?.ensureActiveRuntime() {
            sessionId = rid
        } else {
            lastError = "No active session"
            return false
        }

        // The user has committed to a local turn. Claim local ownership NOW —
        // BEFORE the (awaited) attachment upload — so any foreign frame that
        // arrives during the upload is correctly refused adoption by the explicit
        // `localTurnInFlight` token rather than racing an `isStreaming` heuristic.
        // `beginLocalTurn()` also drops any foreign-mirror ownership: the user is
        // now driving this stored session locally, so a stray foreign
        // `message.complete` can never tear our turn down. ownership/display:
        // LOCAL.
        pendingReconnectReconcileID = nil
        beginLocalTurn()

        // Upload + attach any queued images first; abort the send on failure so
        // the user keeps their text and can retry without a half-attached turn.
        var uploadedImagePaths: [String] = []
        if hasAttachments, let attachments {
            setStreaming(true, reason: "send.uploadAttachments")  // display-only; ownership=LOCAL via token
            lastError = nil
            do {
                uploadedImagePaths = try await attachments.uploadAndAttach(sessionId: sessionId, connection: connection)
            } catch {
                endLocalTurn()
                setStreaming(false, reason: "send.uploadFailed")
                lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                return false
            }
        }

        // Images-with-no-caption: prompt.submit needs text, so supply a default.
        let outgoing = trimmed.isEmpty ? "Please look at the attached image." : trimmed
        let localDisplay = Self.localSentImageDisplayText(
            outgoing: outgoing,
            uploadedImagePaths: uploadedImagePaths
        )
        let userMessage = ChatMessage(role: .user, text: localDisplay)
        userOrdinals[userMessage.id] = messages.lazy.filter { $0.role == .user }.count
        messages.append(userMessage)
        setStreaming(true, reason: "send.localTurn")  // ownership=LOCAL (token already held)
        lastError = nil
        do {
            _ = try await client.requestRaw(
                "prompt.submit",
                params: .object([
                    "session_id": .string(sessionId),
                    "text": .string(outgoing),
                ])
            )
            return true
        } catch let GatewayError.rpc(code, _) where code == GatewayErrorCode.sessionBusy {
            endLocalTurn()
            setStreaming(false, reason: "send.busy")
            lastError = "Agent is busy"
            return false
        } catch {
            endLocalTurn()
            setStreaming(false, reason: "send.error")
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    /// Build the local echo text for a just-sent user row after mobile has already
    /// uploaded + `image.attach`'d its queued images. The gateway's persisted row
    /// later carries the same `[Image attached at: …]` hints through native image
    /// routing, but the app-native immediate echo is created before that persisted
    /// row is re-fetched. Mirroring the hint lines here lets `MessageBubble` render
    /// the thumbnail immediately and keeps cross-surface/backfill parsing on the
    /// same single marker contract.
    nonisolated static func localSentImageDisplayText(
        outgoing: String,
        uploadedImagePaths: [String]
    ) -> String {
        let trimmed = outgoing.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !uploadedImagePaths.isEmpty else { return outgoing }
        let markers = uploadedImagePaths
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { "[Image attached at: \($0)]" }
        guard !markers.isEmpty else { return outgoing }
        return ([trimmed].filter { !$0.isEmpty } + markers).joined(separator: "\n\n")
    }

    // MARK: - Edit & retry

    /// Edit a previously-sent user message and re-run the conversation from
    /// that point. Truncates the gateway's history to *before* the target user
    /// message (via `truncate_before_user_ordinal`), then resubmits `newText`
    /// as a fresh user turn.
    ///
    /// On success the local transcript is rewritten to match: everything from
    /// the original user message onward is dropped and the edited message is
    /// appended, after which streaming resumes into a new assistant turn. A
    /// stale target (`4018`) means our ordinal no longer maps to the server's
    /// history (e.g. another client mutated it); we re-sync via `backfill()`
    /// and surface a friendly error rather than corrupting the transcript.
    func editAndResend(messageId: UUID, newText: String) async {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Local ownership gate, not `isStreaming` — see restoreCheckpoint (R1 #30).
        guard !localTurnInFlight else {
            lastError = "Agent is busy"
            return
        }
        guard let index = messages.firstIndex(where: { $0.id == messageId }),
              messages[index].role == .user else { return }
        let ordinal = userOrdinal(at: index)
        await submitTruncating(text: trimmed, truncateBeforeUserOrdinal: ordinal, truncateFromIndex: index)
    }

    /// Re-run the turn that produced `assistantId`: find the user message that
    /// prompted it and resubmit that text unchanged, regenerating the response.
    func retry(fromAssistantId assistantId: UUID) async {
        // Local ownership gate, not `isStreaming` — see restoreCheckpoint (R1 #30).
        guard !localTurnInFlight else {
            lastError = "Agent is busy"
            return
        }
        guard let assistantIndex = messages.firstIndex(where: { $0.id == assistantId }) else { return }
        // Walk back to the nearest preceding user message.
        guard let userIndex = messages[..<assistantIndex].lastIndex(where: { $0.role == .user }) else { return }
        let text = messages[userIndex].text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let ordinal = userOrdinal(at: userIndex)
        await submitTruncating(text: text, truncateBeforeUserOrdinal: ordinal, truncateFromIndex: userIndex)
    }

    /// Zero-based ordinal of the user message at `index`: its cached value if
    /// known, else recomputed by counting user messages before it (robust to
    /// any cache drift).
    private func userOrdinal(at index: Int) -> Int {
        if let cached = userOrdinals[messages[index].id] { return cached }
        return messages[..<index].lazy.filter { $0.role == .user }.count
    }

    /// Shared edit/retry submit: truncate the local transcript from
    /// `truncateFromIndex`, append the (possibly edited) user message, then
    /// `prompt.submit` with `truncate_before_user_ordinal`. Handles busy
    /// (`4009`) and stale-target (`4018`) the same way `send` handles busy.
    private func submitTruncating(
        text: String,
        truncateBeforeUserOrdinal ordinal: Int,
        truncateFromIndex index: Int
    ) async {
        guard let client, let sessionId = activeSessionId else {
            lastError = "No active session"
            return
        }

        // Drop the streaming-message bookkeeping for any rows we're about to
        // remove, then rewrite the transcript: keep history up to (not
        // including) the target user message and append the new user turn.
        // Snapshot the removed tail first: if the server refuses the turn the
        // optimistic amputation is undone LOCALLY (`restoreTruncation`) — a
        // backfill restore would be discarded by its own post-await
        // `!isStreaming` guard whenever the refusal came from a concurrent
        // foreign turn that re-adopts during the fetch (ABH-48 judge round).
        cancelStreaming()
        let removedTail = Array(messages[index...])
        let newUserMessage = ChatMessage(role: .user, text: text)
        messages = Array(messages[..<index])
        userOrdinals[newUserMessage.id] = ordinal
        messages.append(newUserMessage)
        // Ordinals for kept rows are unchanged (they precede the target); rows
        // after the target are gone. Rebuild defensively to stay consistent.
        rebuildUserOrdinals()

        /// Undo the optimistic rewrite: drop the appended user message and
        /// re-insert the removed tail where it was. Deterministic and seed-free,
        /// so it works even while a foreign mirror is streaming (rows a mirror
        /// appended meanwhile end up after the restored tail; the mirror's own
        /// complete-reconcile reorders authoritatively).
        func restoreTruncation() {
            messages.removeAll { $0.id == newUserMessage.id }
            messages.insert(contentsOf: removedTail, at: min(index, messages.count))
            rebuildUserOrdinals()
        }

        // Edit/retry is a genuinely-local turn: `cancelStreaming()` above cleared
        // the prior token, so claim a fresh one. ownership=LOCAL.
        pendingReconnectReconcileID = nil
        beginLocalTurn()
        setStreaming(true, reason: "submitTruncating.localTurn")
        lastError = nil
        do {
            _ = try await client.requestRaw(
                "prompt.submit",
                params: .object([
                    "session_id": .string(sessionId),
                    "text": .string(text),
                    "truncate_before_user_ordinal": .number(Double(ordinal)),
                ])
            )
        } catch let GatewayError.rpc(code, _) where code == GatewayErrorCode.sessionBusy {
            endLocalTurn()
            setStreaming(false, reason: "submitTruncating.busy")
            lastError = "Agent is busy"
            // The server refused the turn — undo the optimistic amputation
            // locally (reachable now that edit/retry gate on ownership: a 4009
            // usually means a concurrent foreign turn, whose re-adoption would
            // make a backfill restore no-op on its `!isStreaming` guard).
            restoreTruncation()
        } catch let GatewayError.rpc(code, _) where code == GatewayErrorCode.staleTruncation {
            // The target user message is no longer in the server's history.
            // Restore locally first (deterministic), then re-sync from the
            // server — its history genuinely changed, so the backfill is the
            // authoritative view when it lands.
            endLocalTurn()
            setStreaming(false, reason: "submitTruncating.stale")
            lastError = "That message is no longer available — refreshing."
            restoreTruncation()
            await backfill()
        } catch {
            endLocalTurn()
            setStreaming(false, reason: "submitTruncating.error")
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            // A transport/RPC failure also leaves the amputation unaccepted.
            restoreTruncation()
        }
    }

    /// Interrupt the turn that owns the VISIBLE stream (`session.interrupt`).
    ///
    /// An adopted foreign mirror streams from its OWN runtime — the docked STOP
    /// must target that runtime, not our local `activeSessionId` (which isn't
    /// the one streaming, and is `nil` outright during the resume window), or
    /// the visible stream can never be stopped from this device (R1 #2).
    func interrupt() async {
        guard let client, let sessionId = interruptTarget else { return }
        do {
            _ = try await client.requestRaw(
                "session.interrupt",
                params: .object(["session_id": .string(sessionId)])
            )
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// The runtime ``interrupt()`` targets: the adopted foreign mirror's own
    /// runtime when one is live, else the local active session. Factored out
    /// so the routing fact (R1 #2) is directly assertable in tests.
    var interruptTarget: String? { mirroringRuntimeId ?? activeSessionId }

    // MARK: - Manual context compression

    /// Outcome of a user-initiated `session.compress` RPC call.
    enum ContextCompressionOutcome: Sendable {
        case compressed(beforeTokens: Int, afterTokens: Int, removedMessages: Int)
        case error(String)
    }

    /// Gateway response shape for `session.compress`.
    struct SessionCompressResponse: Decodable, Sendable {
        let status: String
        let removed: Int
        let beforeMessages: Int
        let afterMessages: Int
        let beforeTokens: Int
        let afterTokens: Int
        let usage: UsageStats?
    }

    /// Force context compression for the active runtime (`session.compress`).
    ///
    /// This is a manual maintenance action, not a chat turn: iOS must not start
    /// or stop local streaming state. The gateway owns the compression lifecycle
    /// and returns before/after token counts for user feedback.
    func compressContext(focus: String? = nil) async -> ContextCompressionOutcome {
        guard let client, let sessionId = activeSessionId else {
            return .error("No active session")
        }
        var params: [String: JSONValue] = ["session_id": .string(sessionId)]
        let trimmedFocus = focus?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedFocus.isEmpty {
            params["focus_topic"] = .string(trimmedFocus)
        }
        do {
            let response: SessionCompressResponse = try await client.request(
                "session.compress",
                params: .object(params),
                timeout: .seconds(180)
            )
            applyContextUsage(from: response.usage)
            return .compressed(
                beforeTokens: response.beforeTokens,
                afterTokens: response.afterTokens,
                removedMessages: response.removed
            )
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            lastError = msg
            return .error(msg)
        }
    }

    // MARK: - Steer

    /// Outcome of a `session.steer` RPC call.
    ///
    /// - `queued`: the gateway accepted the steering text and will inject it
    ///   into the running turn's next context window.
    /// - `rejected`: the gateway declined (e.g. turn already completing or the
    ///   session is not currently streaming). The UI should keep the text so the
    ///   user can queue it instead.
    /// - `error(String)`: transport or RPC failure; the message is also written
    ///   to `lastError` for the standard error-banner path.
    enum SteerOutcome: Equatable, Sendable {
        case queued
        case rejected
        case error(String)
    }

    /// Gateway response shape for `session.steer`.
    struct SessionSteerResponse: Decodable, Sendable {
        let status: String
        /// Optional human-readable note from the gateway (not currently surfaced
        /// in UI but preserved for future diagnostic use).
        let text: String?
    }

    #if DEBUG
    /// Injectable hook for tests — replaces the live `session.steer` RPC when
    /// set. `nil` in production (inert). Receives `(sessionId, trimmedText)` and
    /// returns the response that `steer(text:)` maps to a `SteerOutcome`.
    ///
    /// Pattern mirrors `ConnectionStore.connectRPC` (the reconnect-test seam).
    var steerRPC: ((_ sessionId: String, _ text: String) async throws -> SessionSteerResponse)?
    #endif

    /// Inject steering text into the turn that owns the VISIBLE stream
    /// (`session.steer`).
    ///
    /// Routing follows ``interrupt()`` exactly: an adopted foreign mirror streams
    /// from its OWN runtime, so `interruptTarget` (= `mirroringRuntimeId ??
    /// activeSessionId`) is the correct target — NOT `activeSessionId` alone,
    /// which would miss a foreign turn or be `nil` during the resume window.
    ///
    /// This is fire-and-forget from the iOS client's perspective: the gateway
    /// owns the running turn and decides whether to accept the steer text. iOS
    /// MUST NOT call `beginLocalTurn`, `setStreaming`, or `cancelStreaming` — the
    /// turn's streaming context is entirely server-managed.
    ///
    /// - Returns: `.queued` if accepted, `.rejected` if the gateway declined,
    ///   `.error` on transport/RPC failure (also sets `lastError`).
    func steer(text: String) async -> SteerOutcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .rejected }
        guard let client, let sessionId = interruptTarget else {
            return .error("No active session")
        }
        do {
            let response: SessionSteerResponse
            #if DEBUG
            if let hook = steerRPC {
                response = try await hook(sessionId, trimmed)
            } else {
                response = try await client.request(
                    "session.steer",
                    params: .object(["session_id": .string(sessionId),
                                     "text": .string(trimmed)])
                )
            }
            #else
            response = try await client.request(
                "session.steer",
                params: .object(["session_id": .string(sessionId),
                                 "text": .string(trimmed)])
            )
            #endif
            switch response.status {
            case "queued":   return .queued
            case "rejected": return .rejected
            default:
                // Defensive: unknown status from a future gateway version is
                // treated as a soft rejection — don't clear the user's text.
                return .rejected
            }
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            lastError = msg
            return .error(msg)
        }
    }

    /// Answer a pending approval (`approval.respond`) and clear it.
    func respondApproval(approve: Bool, all: Bool) async {
        // Answer against the session the approval came from — for mirrored
        // approvals (broadcast from another client's turn) that is a foreign
        // runtime id, not our own.
        let approvalSession = pendingApproval?.sessionId
        guard let client,
              let sessionId = (approvalSession?.isEmpty == false ? approvalSession : activeSessionId)
        else { return }
        let choice = approve ? "approve" : "deny"
        pendingApproval = nil
        onApprovalChange?(false)
        do {
            _ = try await client.requestRaw(
                "approval.respond",
                params: .object([
                    "session_id": .string(sessionId),
                    "choice": .string(choice),
                    "all": .bool(all),
                ])
            )
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Answer a pending clarification (`clarify.respond`) and clear it.
    ///
    /// The reply MUST echo the frame's `request_id`: the gateway routes the
    /// answer by `_pending[request_id]` (the generic `_respond`,
    /// `tui_gateway/server.py:5059`) — a reply without it 4009s ("no pending
    /// clarify request") and the agent stays blocked on the prompt forever.
    func respondClarification(_ answer: String) async {
        let pending = pendingClarification
        let clarifySession = pending?.sessionId
        guard let client,
              let sessionId = (clarifySession?.isEmpty == false ? clarifySession : activeSessionId)
        else { return }
        pendingClarification = nil
        var params: [String: JSONValue] = [
            "session_id": .string(sessionId),
            "answer": .string(answer),
        ]
        if let rid = pending?.request.requestId {
            params["request_id"] = .string(rid)
        }
        do {
            _ = try await client.requestRaw("clarify.respond", params: .object(params))
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Working directory (F4A-A2 — picker wired to session.cwd.set)

    /// Change the active session's working directory via `session.cwd.set`
    /// (server.py:3249). The ``WorkingDirPicker`` (A1) returns a RELATIVE path
    /// under the file-browser `root`; A2 joins it to the absolute cwd
    /// (``WorkingDirectory/absolutePath(root:relative:)``) and sends that as the
    /// `cwd` param. On success the gateway emits a `session.info` event and
    /// returns the new info; the caller refreshes the file browser + composer
    /// @-file cwd (re-listing for the same `session_id` reflects the new root).
    ///
    /// Returns `true` on success. On failure it surfaces the native inline error
    /// for the gateway's pinned codes (4009 busy / 4016 empty / 4017 missing dir)
    /// via ``lastError`` and returns `false` so the caller leaves the picker /
    /// browser as-is.
    @discardableResult
    func setWorkingDirectory(root: String, relativePath: String) async -> Bool {
        guard let client, let sessionId = activeSessionId, !sessionId.isEmpty else {
            lastError = "No active session"
            return false
        }
        let cwd = WorkingDirectory.absolutePath(root: root, relative: relativePath)
        lastError = nil
        do {
            _ = try await client.requestRaw(
                "session.cwd.set",
                params: .object([
                    "session_id": .string(sessionId),
                    "cwd": .string(cwd),
                ])
            )
            return true
        } catch {
            lastError = WorkingDirectory.mapSetError(error).message
            return false
        }
    }

    // MARK: - Seeding & backfill

    /// Replace the transcript from stored history. Tool/system rows with no
    /// text are skipped; nothing is left streaming.
    /// Bumped whenever the transcript is wholesale replaced (open, backfill,
    /// mirror reconciliation) so the view can snap to the newest message.
    private(set) var transcriptGeneration = 0

    #if DEBUG
    /// DEBUG-ONLY deterministic transcript seed for sim scroll verification
    /// (`HERMES_UITEST_SEED`). Replaces the transcript and bumps
    /// `transcriptGeneration` exactly as the real seed does, so `ChatView`'s
    /// open-on-newest path (`handleSeedScroll`) runs identically to production —
    /// without needing a live gateway. Never compiled into Release.
    func debugSeedTranscript(_ seeded: [ChatMessage]) {
        cancelStreaming()
        messages = seeded
        rebuildUserOrdinals()
        transcriptGeneration += 1
    }

    /// DEBUG-ONLY: drive the REAL streaming path with a synthesized gateway
    /// delta, exactly as a WS `message.delta` frame would. The event carries
    /// neither a `session_id` nor a `stored_session_id`, so `ownership(of:)`
    /// classifies it `.local` (the malformed/global-frame branch) and it flows
    /// through `handle(event:)` → `beginLocalTurn` → `scheduleFlush` →
    /// `flushBuffers` → `mutateStreaming` — the same coalesced 40ms render path
    /// the device exercises. Used by the `stream` UITestSeed stress mode to make
    /// the streaming jitter measurable on the sim without a live gateway.
    func debugInjectDelta(_ text: String) {
        guard let event = GatewayEvent(params: .object([
            "type": .string("message.delta"),
            "payload": .object(["text": .string(text)]),
        ])) else { return }
        handle(event: event)
    }

    /// DEBUG-ONLY: end the synthesized stream (a `message.complete`), so the
    /// streaming row settles (cursor stops, action row appears) like a real turn.
    func debugCompleteStream() {
        guard let event = GatewayEvent(params: .object([
            "type": .string("message.complete"),
            "payload": .object([:]),
        ])) else { return }
        handle(event: event)
    }
    #endif

    func seed(from stored: [StoredMessage]) {
        // ARCH37 STEP 2 — normalize on the CURRENT actor (main here, for the
        // synchronous/foreign-mirror callers) then apply. The off-main open/backfill
        // path instead pre-normalizes on its fetch Task and calls `seed(normalized:)`
        // directly (one main-actor hop for the assignment only). Both routes funnel
        // through `seed(normalized:)` so the foreign-mirror bail + in-place reconcile
        // semantics are identical regardless of where the normalize ran.
        seed(normalized: Self.toChatMessages(stored))
    }

    /// Apply an ALREADY-NORMALIZED seed (`toChatMessages` output) onto the
    /// transcript. The pure `toChatMessages` transform may have run OFF the main
    /// actor (ARCH37 Step 2 — the off-main open/backfill path), so this method is the
    /// single MAIN-ACTOR hop that mutates `messages`: the foreign-mirror bail, the
    /// in-place reconcile, the ordinal rebuild, and the `transcriptGeneration` bump.
    func seed(normalized: [ChatMessage]) {
        // A slow REST seed must never wipe a LIVE adopted foreign mirror
        // (R1 #61): open() the session another client is driving, the foreign
        // `message.start` adopts mid-fetch, then the stale seed lands here and
        // `cancelStreaming()` would tear the mirror down mid-turn (truncated
        // reply, corrupted re-adoption). Bail instead — the mirror is already
        // rendering live, and its `message.complete` runs the authoritative
        // teardown + backfill reconcile (which clears the flag before seeding).
        guard !streamingIsForeign else { return }
        cancelStreaming()
        // IN-PLACE RECONCILE (contract Batch E §3.7, fixes D9): merge the new
        // seed onto the existing transcript by identity instead of a wholesale
        // `messages = …` replace. A wholesale replace remounts every row (new
        // SwiftUI identity) and — for a foreign-mirror reconcile — first removes
        // the placeholder (`teardownForeignStream`) then re-adds the finalized
        // reply from REST, so the mirrored reply BLINKS OUT and pops back
        // restacked. The merge keeps identity for rows whose deterministic ids
        // match across reseeds (no restack), and adopts the foreign placeholder's
        // slot for the reconciled trailing reply (no blink, no count churn).
        reconcileMessages(with: normalized)
        rebuildUserOrdinals()
        transcriptGeneration += 1
    }

    /// Update the backward-paging cursor carried by the latest authoritative
    /// transcript seed. ``stored`` may be only the recent tail window; the server
    /// page metadata tells us whether older rows exist beyond the first loaded id.
    func noteTranscriptPaging(oldestId: Int?, hasMoreBefore: Bool) {
        oldestLoadedTranscriptWireId = oldestId
        transcriptHasMoreBefore = hasMoreBefore
    }

    /// Convenience for callers that only have the fetched rows (cache / legacy
    /// fallback). A full 50-row tail may have older rows; clicking once verifies
    /// against the server and clears the affordance if not.
    func noteTranscriptSeedWindow(_ stored: [StoredMessage]) {
        noteTranscriptPaging(
            oldestId: stored.first?.wireId,
            hasMoreBefore: stored.count >= Self.transcriptOpenWindowLimit
        )
    }

    /// Fetch and prepend one older server page. Used by ChatView's top affordance
    /// once the locally-loaded rows no longer have hidden in-memory rows above.
    func loadEarlierTranscript() async {
        guard !isStreaming,
              !isLoadingEarlierTranscript,
              transcriptHasMoreBefore,
              let storedId = sessions?.activeStoredId,
              let before = oldestLoadedTranscriptWireId,
              let rest = connection?.rest else { return }
        isLoadingEarlierTranscript = true
        defer { isLoadingEarlierTranscript = false }
        guard let page = await fetchTranscriptPage(
            rest: rest,
            sessionId: storedId,
            limit: Self.transcriptOpenWindowLimit,
            before: before
        ) else { return }
        if !page.messages.isEmpty {
            let older = Self.toChatMessages(page.messages)
            seed(normalized: older + messages)
        }
        noteTranscriptPaging(oldestId: page.oldestId, hasMoreBefore: page.hasMoreBefore)
    }

    /// The id of a foreign-mirror placeholder assistant row that
    /// `teardownForeignStream` left in place (contract Batch E §3.7) for the
    /// recovery `backfill()`/`seed()` to reconcile ONTO — rather than removing it
    /// first (which made the mirrored reply blink out). The next `seed()` adopts
    /// this id's slot for the reconciled trailing assistant reply so identity and
    /// row count are preserved (no blink, no restack). Cleared once consumed.
    private var pendingForeignReconcileID: UUID?

    /// The id of a genuinely-local assistant row that was cut off by a transport
    /// drop and left visible with a "Connection lost" warning (ABH-276/278).
    ///
    /// During reconnect, REST backfill and resumed WS frames race each other:
    ///  - if REST returns first, the server may not have persisted the resumed
    ///    assistant row yet, so a normal reconcile would evict the warning row;
    ///  - if WS returns first, `message.start` would normally append a fresh
    ///    streaming assistant row, duplicating the interrupted bubble for one turn.
    /// This marker lets both paths treat the interrupted row as the reconnect
    /// placeholder until the resumed turn settles or a fresh user action starts a
    /// new local turn.
    private var pendingReconnectReconcileID: UUID?

    /// Merge `incoming` (a freshly-built seed) onto `messages` IN PLACE, preserving
    /// SwiftUI identity wherever it can so a reseed/reconcile does not remount rows
    /// (contract Batch E §3.7 / D9):
    ///
    ///  1. Rows whose deterministic id already exists keep their slot — only their
    ///     `parts`/`isStreaming`/`timestamp`/`presentation` are updated in place.
    ///     Because seeded ids are deterministic (`deterministicID(seedKey:)`), the
    ///     same wire row maps to the same id across every reseed, so a backfill /
    ///     foreground refresh of an unchanged transcript mutates NOTHING that the
    ///     diff can see and the reader's scroll position is undisturbed.
    ///  2. The foreign-mirror placeholder (a streaming row with a runtime UUID id,
    ///     recorded in `pendingForeignReconcileID`) has no deterministic-id match,
    ///     so it would normally be dropped and the finalized reply added — the
    ///     blink. Instead, the FIRST unmatched trailing assistant row in `incoming`
    ///     ADOPTS the placeholder's id + slot: its content is written onto the
    ///     existing row in place. The reply transitions placeholder → finalized
    ///     with zero count churn and a stable identity.
    ///  3. Anything else in `incoming` with no match is a genuinely-new row,
    ///     inserted in wire order. Existing rows absent from `incoming` are removed.
    ///
    /// The final array is byte-identical in content to `incoming` — only the
    /// element IDENTITIES are reused where possible. (So every existing test that
    /// asserts `messages.map(\.text)` after a reconcile still holds.)
    private func reconcileMessages(with incoming: [ChatMessage]) {
        let placeholderID = pendingForeignReconcileID
        pendingForeignReconcileID = nil
        let reconnectID = pendingReconnectReconcileID

        // Fast path: nothing to preserve identity against.
        guard !messages.isEmpty else {
            messages = incoming
            return
        }

        var existingByID: [UUID: ChatMessage] = [:]
        for message in messages { existingByID[message.id] = message }

        // The placeholder is adopted by at most ONE incoming row (the first
        // unmatched trailing assistant), so track whether it has been consumed.
        var placeholderConsumed = false
        let placeholderRow: ChatMessage? = placeholderID.flatMap { existingByID[$0] }
        var reconnectConsumed = false
        let reconnectRow: ChatMessage? = reconnectID.flatMap { existingByID[$0] }
        let reconnectAdoptTargetID: UUID? = reconnectRow == nil
            ? nil
            : incoming.last(where: { $0.role == .assistant })?.id

        var rebuilt: [ChatMessage] = []
        rebuilt.reserveCapacity(incoming.count)

        for newMessage in incoming {
            if var existing = existingByID[newMessage.id] {
                // Same identity across reseeds — keep the slot, update content in
                // place so SwiftUI diffs the parts rather than remounting the row.
                existing.parts = newMessage.parts
                existing.isStreaming = newMessage.isStreaming
                existing.timestamp = newMessage.timestamp
                existing.presentation = newMessage.presentation
                rebuilt.append(existing)
            } else if !placeholderConsumed,
                      let placeholder = placeholderRow,
                      newMessage.role == .assistant,
                      placeholder.role == .assistant {
                // The reconciled foreign reply adopts the in-flight placeholder's
                // identity + slot (no blink, no restack). Build a new value with
                // the placeholder's id so the row updates in place.
                placeholderConsumed = true
                let adopted = ChatMessage(
                    id: placeholder.id,
                    role: newMessage.role,
                    parts: newMessage.parts,
                    isStreaming: newMessage.isStreaming,
                    timestamp: newMessage.timestamp,
                    presentation: newMessage.presentation
                )
                rebuilt.append(adopted)
            } else if !reconnectConsumed,
                      let reconnect = reconnectRow,
                      let reconnectAdoptTargetID,
                      newMessage.id == reconnectAdoptTargetID,
                      newMessage.role == .assistant,
                      reconnect.role == .assistant {
                // ABH-278: the persisted final assistant row belongs to the local
                // reply whose socket died. Adopt the interrupted warning row's
                // identity for the TRAILING assistant in the authoritative seed so
                // reconnect updates in place instead of replacing the bubble. If
                // REST is temporarily behind and has no assistant yet, the row is
                // preserved below and the marker stays armed.
                reconnectConsumed = true
                pendingReconnectReconcileID = nil
                let adopted = ChatMessage(
                    id: reconnect.id,
                    role: newMessage.role,
                    parts: newMessage.parts,
                    isStreaming: newMessage.isStreaming,
                    timestamp: newMessage.timestamp,
                    presentation: newMessage.presentation
                )
                rebuilt.append(adopted)
            } else {
                // Genuinely-new row.
                rebuilt.append(newMessage)
            }
        }
        if !reconnectConsumed,
           let reconnect = reconnectRow,
           !rebuilt.contains(where: { $0.id == reconnect.id }) {
            // ABH-278: REST can be a moment behind the resumed turn. Preserve the
            // interrupted local row instead of evicting the in-flight reply /
            // warning just because the backfill snapshot does not include it yet.
            // Keep `pendingReconnectReconcileID` armed so a later seed containing
            // the final assistant row can still adopt this identity.
            rebuilt.append(reconnect)
        } else if reconnectID != nil, reconnectRow == nil {
            pendingReconnectReconcileID = nil
        }
        messages = rebuilt
    }

    /// Recompute `userOrdinals` from scratch: each user message's zero-based
    /// position among the user messages in `messages`, in transcript order.
    /// This mirrors the gateway's `user_indices` enumeration so the ordinal we
    /// send as `truncate_before_user_ordinal` lines up with its history.
    private func rebuildUserOrdinals() {
        var ordinals: [UUID: Int] = [:]
        var count = 0
        for message in messages where message.role == .user {
            ordinals[message.id] = count
            count += 1
        }
        userOrdinals = ordinals
    }

    // MARK: - Seed producer (ABH-87 Batch B, contract §2.4)
    //
    // Port of the desktop normalizer `toChatMessages` (chat-messages.ts:661-810):
    // the single most important algorithm for seed/stream structural parity. It
    // turns the flat wire history into the SAME ordered-interleaved-`parts[]`
    // shape the stream producer accumulates, so a reopened session renders
    // identically to one watched live.
    //
    // Behavior (in wire order):
    //  1. role:tool rows are NEVER their own message — their result is merged onto
    //     the matching pending/emitted `.tools` activity by `tool_call_id` (then
    //     `tool_name`); an unmatched result becomes a synthetic activity buffered
    //     for the next assistant flush.
    //  2. Per assistant row, parts are built in fixed within-row order:
    //     reasoning → text → tool-call activities (from `tool_calls[]`).
    //     User rows strip Attached-Context / Context-Warnings scaffolding and
    //     hoist `@ref` chips.
    //  3. Turn coalescing: a tool-only assistant row is buffered, then flushed
    //     onto the ACTIVE assistant message; an assistant row with text merges
    //     into the active assistant when either side has a tool call. Net: a long
    //     agentic turn `[reason→tool→tool-result→…→final text]` becomes ONE
    //     assistant `ChatMessage` with ordered mixed `parts[]`.
    //  4. Empty filter: drop messages with no text and no non-text part.
    //  5. Final pass: enforce globally-unique-but-stable part ids
    //     (`withUniqueToolCallIds` analogue, §2.2).
    //
    // Machine scaffolding (cron preambles, system prompts, raw tool dumps that
    // surface as standalone collapsible rows) keeps its `.collapsed` presentation
    // (an iOS-native affordance with no desktop conflict).
    // ARCH37 STEP 2 — `nonisolated` so the seed normalize runs OFF the main actor.
    // `toChatMessages` is a pure transform `[StoredMessage] → [ChatMessage]` over
    // Sendable value types with NO instance state, so it is safe to run on the
    // background fetch Task; SessionStore hops to main ONLY for the `messages =`
    // assignment (`seed(from:normalized:)`). This removes the single largest
    // unyielded main-actor block on the open/backfill path (the rare-freeze root —
    // `mergeToolResult`'s scan + `withUniqueSeedPartIds`' nested loops + the dict
    // build all ran on main inside one @Observable write). The whole transitive
    // static helper set below is `nonisolated` for the same reason. Output is
    // byte-identical (SeedParityTests / RenderingTests exercise the pure path).
    nonisolated static func toChatMessages(_ stored: [StoredMessage]) -> [ChatMessage] {
        var result: [ChatMessage] = []
        // Tool-call activities buffered from tool-only assistant rows and
        // synthetic unmatched tool results, awaiting flush onto an assistant.
        var pendingTools: [ToolActivity] = []
        var pendingToolsTimestamp: Double?
        // Index in `result` of the assistant message currently accumulating a
        // turn (nil when the active turn has ended, e.g. after a user row).
        var activeAssistantIndex: Int?

        func clearPendingTools() {
            pendingTools = []
            pendingToolsTimestamp = nil
        }

        // Append parts onto the active assistant message; false if there is none.
        func appendToActiveAssistant(_ activities: [ToolActivity], timestamp: Double?) -> Bool {
            guard let index = activeAssistantIndex,
                  result.indices.contains(index),
                  result[index].role == .assistant else {
                activeAssistantIndex = nil
                return false
            }
            for activity in activities {
                result[index].appendSeedToolActivity(activity)
            }
            return true
        }

        // Flush buffered tools onto the active assistant, or emit a synthetic
        // tool-only assistant message (desktop `flushPendingTools`).
        func flushPendingTools(index: Int) {
            guard !pendingTools.isEmpty else { return }
            if !appendToActiveAssistant(pendingTools, timestamp: pendingToolsTimestamp) {
                let ts = pendingToolsTimestamp
                let key = Self.seedMessageID(timestamp: ts, index: index, role: .assistant)
                let message = ChatMessage(
                    id: ChatMessage.deterministicID(seedKey: key),
                    role: .assistant,
                    parts: [.tools(id: pendingTools[0].id, tools: pendingTools, collapsed: false, turnElapsed: nil)],
                    timestamp: ts.map { Date(timeIntervalSince1970: $0) } ?? Date()
                )
                result.append(message)
                activeAssistantIndex = result.count - 1
            }
            clearPendingTools()
        }

        // Merge a role:tool result onto a tool activity, searching the pending
        // buffer first, then emitted assistant messages backward. Returns true if
        // merged.
        //
        // ARCH37 STEP 2 — mergeToolResult COMPLEXITY VERDICT: kept O(rows) backward
        // scan; NOT linearized to a reverse index map. A map cannot preserve
        // semantics here without per-step mutation tracking (which IS a semantic
        // change):
        //  • the by-NAME branch matches the first `state == .running` activity, so a
        //    static `name → index` map goes stale the instant the first result flips
        //    that slot to `.done` — the next same-name result must skip it, which a
        //    build-time map cannot express.
        //  • the by-callId branch relies on the NEWEST-first scan to land on the most
        //    recent occurrence of a DUPLICATE call id (the wire can carry dupes; they
        //    are only de-duped in the later `withUniqueSeedPartIds` pass). A
        //    forward-built `callId → index` map would resolve to the OLDEST, inverting
        //    the order.
        // The realistic cost is bounded anyway: the common case (a result following
        // its own assistant's pending tools) hits the O(pending) `pendingTools` fast
        // path below and never reaches the backward scan — which is the fallback only
        // for results whose cluster was already flushed into `result`. Crucially, the
        // ENTIRE normalize now runs OFF the main actor (Step 2), so even the worst-
        // case tool-dense scan no longer blocks the UI — the actual freeze root.
        // SeedParityTests/RenderingTests must stay green, which a map risks breaking.
        func mergeToolResult(_ row: StoredMessage) -> Bool {
            let callId = row.toolCallId
            let name = row.toolName ?? "tool"
            let preview = String(row.text.prefix(300))
            let failed = row.text.isEmpty ? false : Self.seedIndicatesFailure(name: name, content: row.content)
            func matches(_ activity: ToolActivity) -> Bool {
                if let callId { return activity.id == callId }
                return activity.name == name
            }
            // Pending buffer first.
            if let i = pendingTools.firstIndex(where: matches) {
                pendingTools[i].resultPreview = preview
                pendingTools[i].state = failed ? .failed : .done
                pendingTools[i].todos = row.content["todos"]?.arrayValue
                return true
            }
            // Emitted assistant messages, newest first.
            for mi in result.indices.reversed() where result[mi].role == .assistant {
                if result[mi].mergeSeedToolResult(
                    matching: callId, name: name, preview: preview, failed: failed,
                    todos: row.content["todos"]?.arrayValue
                ) {
                    return true
                }
            }
            return false
        }

        for (index, row) in stored.enumerated() {
            let role = ChatRole(rawValue: row.role) ?? .assistant

            // 1. role:tool — never its own message.
            if role == .tool {
                if mergeToolResult(row) { continue }
                // Unmatched: synthesize an activity buffered for the next flush.
                let activity = ToolActivity(
                    id: row.toolCallId ?? "stored-tool-\(index)",
                    name: row.toolName ?? "tool",
                    argsSummary: "",
                    progressText: "",
                    resultPreview: String(row.text.prefix(300)),
                    state: .done,
                    durationMs: nil,
                    todos: row.content["todos"]?.arrayValue
                )
                pendingTools.append(activity)
                pendingToolsTimestamp = pendingToolsTimestamp ?? row.timestamp
                continue
            }

            // 2. Build this row's parts in fixed within-row order.
            let display = Self.seedDisplayContent(role: role, stored: row)
            var rowParts: [ChatMessagePart] = []
            // ARCH37 STEP 4 — prefer the STABLE WIRE ID for identity. When the
            // gateway emitted a per-row `id`, key both the message id and every part
            // id on it (`w{wireId}-{role}`), so the same wire row maps to the same
            // identity across cache<->network drift — no positional re-key, no tail
            // remount. Falls back to the positional `{ts}-{index}-{role}` key when
            // the wire id is absent (stock/old gateways) — unchanged behavior.
            let baseID = Self.seedMessageID(
                timestamp: row.timestamp, index: index, role: role, wireId: row.wireId)

            if role == .assistant, let reasoning = row.reasoning, !reasoning.isEmpty {
                rowParts.append(.reasoning(id: "\(baseID)-reasoning-0", text: reasoning))
            }
            if !display.isEmpty {
                rowParts.append(.text(id: "\(baseID)-text-0", text: display))
            }
            let toolActivities: [ToolActivity] = (role == .assistant ? (row.toolCalls ?? []) : [])
                .map { call in
                    ToolActivity(
                        id: call.callId,
                        name: call.name,
                        argsSummary: String(call.arguments.prefix(200)),
                        progressText: "",
                        resultPreview: "",
                        state: .running,
                        durationMs: nil,
                        todos: nil
                    )
                }
            if !toolActivities.isEmpty {
                rowParts.append(.tools(
                    id: toolActivities[0].id, tools: toolActivities,
                    collapsed: false, turnElapsed: nil
                ))
            }

            // Empty-part rows end/flush the active turn (desktop :745-755).
            if rowParts.isEmpty {
                if role != .assistant {
                    flushPendingTools(index: index)
                    activeAssistantIndex = nil
                }
                continue
            }

            // A tool-only assistant row is buffered, not emitted (desktop :757-763).
            let isToolOnlyAssistant = role == .assistant
                && rowParts.allSatisfy { if case .tools = $0 { return true }; return false }
            if isToolOnlyAssistant {
                pendingTools.append(contentsOf: toolActivities)
                pendingToolsTimestamp = pendingToolsTimestamp ?? row.timestamp
                continue
            }

            // 3. Turn coalescing.
            if role == .assistant {
                // Drain any buffered tools onto the active assistant, else prepend
                // them to this row's parts (desktop :766-772).
                if !pendingTools.isEmpty {
                    if !appendToActiveAssistant(pendingTools, timestamp: row.timestamp ?? pendingToolsTimestamp) {
                        rowParts.insert(
                            .tools(id: pendingTools[0].id, tools: pendingTools, collapsed: false, turnElapsed: nil),
                            at: 0
                        )
                    }
                    clearPendingTools()
                }
                // Merge into the active assistant when either side has a tool call
                // (desktop :774-787): keeps a long agentic turn as ONE message.
                if let active = activeAssistantIndex,
                   result.indices.contains(active),
                   result[active].role == .assistant {
                    let currentHasTool = !toolActivities.isEmpty
                    let activeHasTool = result[active].parts.contains {
                        if case .tools = $0 { return true }; return false
                    }
                    if currentHasTool || activeHasTool {
                        result[active].appendSeedParts(rowParts)
                        if let ts = row.timestamp {
                            result[active].timestamp = Date(timeIntervalSince1970: ts)
                        }
                        continue
                    }
                }
            } else {
                flushPendingTools(index: index)
            }

            // Emit a fresh message.
            let presentation = Self.seedPresentation(role: role, stored: row, display: display)
            let message = ChatMessage(
                id: ChatMessage.deterministicID(seedKey: baseID), role: role, parts: rowParts,
                timestamp: row.timestamp.map { Date(timeIntervalSince1970: $0) } ?? Date(),
                presentation: presentation
            )
            result.append(message)
            activeAssistantIndex = role == .assistant ? result.count - 1 : nil
        }
        flushPendingTools(index: stored.count)

        // 4. Empty filter.
        let filtered = result.filter { msg in
            if !msg.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
            return msg.parts.contains { if case .text = $0 { return false }; return true }
        }
        // 4b. Renumber text/reasoning run-index ids across the COALESCED bubble so
        // they match the stream producer's `newRunID` (`"{messageID}-{kind}-{n}"`,
        // contract §2.2). A row builds its parts with `-0` suffixes in isolation;
        // once N rows merge into one assistant bubble the 2nd, 3rd, … same-kind
        // runs must take ordinals 1, 2, … or seed and stream diverge (the
        // structural-equivalence property test catches exactly this). Cluster /
        // warning / usage ids are left untouched (tool ids are wire-stable; the
        // de-dup pass handles collisions).
        let renumbered = filtered.map(renumberRunIDs(in:))
        // 5. unique-but-stable ids (global de-dup safety net, §2.2).
        return withUniqueSeedPartIds(renumbered)
    }

    /// Renumber `.text`/`.reasoning` run-index ids within a message so they read
    /// `"{message.id}-{kind}-{ordinal}"` with the ordinal being the run's position
    /// among same-kind runs in the FINAL coalesced bubble — matching the stream
    /// reducer's `newRunID`. (Per-row construction can only mint `-0`; coalescing
    /// is when the true ordinal is known.)
    nonisolated private static func renumberRunIDs(in message: ChatMessage) -> ChatMessage {
        var copy = message
        var textRun = 0
        var reasoningRun = 0
        let base = message.id.uuidString
        copy.parts = message.parts.map { part in
            switch part {
            case .text(_, let text):
                defer { textRun += 1 }
                return .text(id: "\(base)-text-\(textRun)", text: text)
            case .reasoning(_, let text):
                defer { reasoningRun += 1 }
                return .reasoning(id: "\(base)-reasoning-\(reasoningRun)", text: text)
            default:
                return part
            }
        }
        return copy
    }

    /// Deterministic seed message id. ARCH37 STEP 4: when the gateway emitted a
    /// stable per-row `wireId`, key on it (`"w{wireId}-{role}"`) — STABLE across
    /// count/compression/truncation drift, so a cache<->network reconcile preserves
    /// identity in place. Otherwise fall back to the legacy positional key
    /// (`"{ts}-{index}-{role}"`, contract §2.2; a missing timestamp degrades to a
    /// stable per-index key) — byte-identical to pre-ARCH37 for stock gateways.
    nonisolated private static func seedMessageID(
        timestamp: Double?, index: Int, role: ChatRole, wireId: Int? = nil
    ) -> String {
        if let wireId { return "w\(wireId)-\(role.rawValue)" }
        let ts = timestamp.map { String(Int($0 * 1000)) } ?? "0"
        return "\(ts)-\(index)-\(role.rawValue)"
    }

    /// ABH-192 (jump-to-exact-message): the deterministic `ChatMessage.id` a
    /// seeded row with wire id `messageId` and the given role would receive.
    /// Mirrors the `"w{wireId}-{role}"` key the seed producer
    /// (``seedMessageID``) folds through ``ChatMessage/deterministicID(seedKey:)``.
    /// Used by the jump-to-message scroll to resolve the target row id WITHOUT a
    /// scan when the role is known (the per-message plugin search carries it).
    /// `role` is required because it is part of the seed key; callers without a
    /// role hint should try both `user` and `assistant` via
    /// ``messageJumpCandidateIDs(for:)``.
    nonisolated static func messageJumpID(wireMessageId messageId: Int, role: ChatRole) -> UUID {
        ChatMessage.deterministicID(seedKey: "w\(messageId)-\(role.rawValue)")
    }

    /// ABH-192: the set of `ChatMessage.id` candidates a wire `messageId` could
    /// map to when the role is unknown. The seed key embeds the role, so without
    /// a role hint the jump must consider both `user` and `assistant`. Ordered
    /// user-first (the more common jump target from search). Tool rows are never
    /// their own message (the seed producer folds them onto an assistant turn),
    /// so they are not candidates.
    nonisolated static func messageJumpCandidateIDs(for wireMessageId: Int) -> [UUID] {
        [messageJumpID(wireMessageId: wireMessageId, role: .user),
         messageJumpID(wireMessageId: wireMessageId, role: .assistant)]
    }

    /// The `withUniqueToolCallIds` analogue (desktop chat-messages.ts:625-659,
    /// contract §2.2 + Batch A gate scrutiny note #1).
    ///
    /// The run-index id scheme (`"{messageID}-{kind}-{runIndex}"`) and the
    /// `tool_call_id`-derived cluster ids are stable ONLY while the
    /// consecutive-run invariant holds and tool ids are unique. The seed producer
    /// already enforces the run invariant by construction (it merges consecutive
    /// same-kind content rather than opening duplicate runs — see
    /// `appendSeedParts`), so reasoning/text ids cannot collide within a message.
    /// The remaining hazard is the wire delivering DUPLICATE `tool_call_id`s
    /// (across the whole transcript), which would collide cluster *and* per-tool
    /// ids. This pass is the global de-dup safety net: it walks every part id and
    /// every tool id, and on a collision mints a unique suffix — never re-keying a
    /// non-colliding part, so identity is preserved across reseed.
    nonisolated static func withUniqueSeedPartIds(_ messages: [ChatMessage]) -> [ChatMessage] {
        var seenPartIDs = Set<String>()
        var seenToolIDs = Set<String>()
        return messages.map { message in
            var changed = false
            let newParts: [ChatMessagePart] = message.parts.enumerated().map { partIndex, part in
                func uniquePartID(_ id: String) -> String {
                    if seenPartIDs.insert(id).inserted { return id }
                    changed = true
                    var candidate = "\(id)-\(message.id)-\(partIndex)"
                    while !seenPartIDs.insert(candidate).inserted {
                        candidate += "-x"
                    }
                    return candidate
                }
                switch part {
                case .reasoning(let id, let text):
                    return .reasoning(id: uniquePartID(id), text: text)
                case .text(let id, let text):
                    return .text(id: uniquePartID(id), text: text)
                case .warning(let id, let text):
                    return .warning(id: uniquePartID(id), text: text)
                case .usage(let id, let stats):
                    return .usage(id: uniquePartID(id), stats: stats)
                case .tools(let id, let tools, let collapsed, let elapsed):
                    var toolsChanged = false
                    let newTools: [ToolActivity] = tools.map { tool in
                        if seenToolIDs.insert(tool.id).inserted { return tool }
                        toolsChanged = true
                        changed = true
                        var candidate = "\(tool.id)-\(message.id)-\(partIndex)"
                        while !seenToolIDs.insert(candidate).inserted { candidate += "-x" }
                        return ToolActivity(
                            id: candidate, name: tool.name, argsSummary: tool.argsSummary,
                            progressText: tool.progressText, resultPreview: tool.resultPreview,
                            state: tool.state, durationMs: tool.durationMs, todos: tool.todos
                        )
                    }
                    // The cluster id is the first tool's id; re-derive after de-dup.
                    let clusterID = uniquePartID(newTools.first?.id ?? id)
                    if toolsChanged || clusterID != id { changed = true }
                    return .tools(id: clusterID, tools: newTools, collapsed: collapsed, turnElapsed: elapsed)
                }
            }
            guard changed else { return message }
            var copy = message
            copy.parts = newParts
            return copy
        }
    }

    /// Whether a stored tool-result row indicates failure (mirrors the streaming
    /// `indicatesFailure`, but reads from the stored `content` envelope).
    nonisolated private static func seedIndicatesFailure(name: String, content: JSONValue) -> Bool {
        if let object = content.objectValue, object["error"] != nil,
           !(object["error"]?.isNull ?? true) {
            return true
        }
        let lowered = name.lowercased()
        return lowered.contains("error") || lowered.contains("fail")
    }

    /// Displayable body for a seed row. Assistant/system/tool: the flattened
    /// `content`. User: desktop `displayContentForMessage` — strip
    /// Attached-Context / Context-Warnings scaffolding and hoist `@ref` chips.
    nonisolated private static func seedDisplayContent(role: ChatRole, stored: StoredMessage) -> String {
        let raw = stored.text
        guard role == .user else { return raw }
        return displayContentForUserMessage(raw)
    }

    /// Presentation for a freshly-emitted seed message — preserves the
    /// `.collapsed` machine-scaffolding affordance for system prompts and cron /
    /// automation preambles (a standalone tool dump is never emitted by the
    /// producer — tool rows merge — so only system/user-cron collapse here).
    nonisolated private static func seedPresentation(
        role: ChatRole, stored: StoredMessage, display: String
    ) -> ChatMessage.Presentation {
        switch role {
        case .system:
            return .collapsed(label: "System prompt")
        case .user:
            if display.hasPrefix("[") && display.count > 280 {
                return .collapsed(label: "Automation instructions")
            }
            return .normal
        default:
            return .normal
        }
    }

    // Desktop `displayContentForMessage` user-row markers (chat-messages.ts:113-115).
    // ARCH37 Step 2 — `nonisolated` so the now-nonisolated `displayContentForUserMessage`
    // (run off-main in the seed normalize) can reference them. Immutable Sendable
    // Strings, so this is safe.
    nonisolated private static let attachedContextMarker = "--- Attached Context ---"
    nonisolated private static let contextWarningsMarker = "--- Context Warnings ---"

    /// Port of desktop `displayContentForMessage` for user rows: strip the
    /// `--- Attached Context ---` / `--- Context Warnings ---` scaffolding and
    /// hoist deduped `@ref` chips (`@file:`/`@folder:`/`@url:`/`@image:`/`@tool:`/
    /// `@terminal:`) above the visible text.
    nonisolated static func displayContentForUserMessage(_ text: String) -> String {
        // Strip a trailing Context-Warnings block wherever it appears.
        func stripWarnings(_ s: String) -> String {
            guard let range = s.range(of: contextWarningsMarker) else { return s }
            return String(s[..<range.lowerBound])
        }
        guard let markerRange = text.range(of: attachedContextMarker) else {
            return stripWarnings(text).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let visible = stripWarnings(String(text[..<markerRange.lowerBound]))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let attached = String(text[markerRange.upperBound...])
        let refs = extractContextRefs(attached)
        let chips = refs.joined(separator: "\n")
        let joined = [chips, visible].filter { !$0.isEmpty }.joined(separator: "\n\n")
        return joined.isEmpty ? visible : joined
    }

    /// `@kind:value` chip extraction (desktop CONTEXT_REF_RE), order-preserving +
    /// deduped.
    nonisolated private static func extractContextRefs(_ text: String) -> [String] {
        let kinds = ["file", "folder", "url", "image", "tool", "terminal"]
        let pattern = "@(?:\(kinds.joined(separator: "|"))):(?:\"[^\"\\n]+\"|'[^'\\n]+'|`[^`\\n]+`|\\S+)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        var seen = Set<String>()
        var refs: [String] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let chip = ns.substring(with: match.range)
            if seen.insert(chip).inserted { refs.append(chip) }
        }
        return refs
    }

    /// Cheap REST refetch to re-sync the transcript after a reconnect or
    /// foregrounding, and the authoritative reconcile for a mirrored foreign
    /// turn. No-op while a *local* turn is streaming (so we never stomp our own
    /// live turn); an adopted foreign stream is torn down by the caller before
    /// this runs (see `teardownForeignStream`), so by the time we get here
    /// `isStreaming` reflects only a local turn.
    func backfill() async {
        guard !isStreaming else { return }
        guard let storedId = sessions?.activeStoredId else { return }
        let fetch = resolvedBackfillFetch
        guard let fetch else { return }
        #if DEBUG
        foreignMirrorTelemetry.backfillRuns += 1
        #endif
        do {
            let stored = try await fetch(storedId)
            // The world may have moved while the REST fetch was in flight
            // (R1 #12/#21): a local turn the user just started must not be
            // wiped by `seed()`'s unconditional `cancelStreaming()`, and a
            // session switched away from must not have the OLD session's
            // history seeded over it (the stale fetch result is simply
            // dropped — the new session runs its own seed). Mirrors the
            // post-await guard in `seedContextUsageFromStatus`.
            guard !isStreaming, storedId == sessions?.activeStoredId else { return }
            seed(from: stored)
            noteTranscriptSeedWindow(stored)
            // P3 write-through: the foreground/reconnect reconcile re-fetched the
            // authoritative transcript — persist it so the next open paints from
            // disk. Fire-and-forget, OFF the UI path; CacheStore no-ops for cron
            // sessions (never transcript-cached, per the decided scope).
            if let cacheStore {
                Task { try? await cacheStore.saveTranscript(sessionId: storedId, messages: stored) }
            }
            // The seed is the authoritative post-reconnect/post-restart
            // reconcile: any approval/clarify card still up belongs to a turn
            // that is no longer in flight (a live turn's `guard !isStreaming`
            // would have no-op'd us), so answering it would mis-resolve
            // against a stale — possibly dead — runtime (R1 #51). The inbox
            // remains the durable surface for prompts that are genuinely
            // pending. The SECURE prompt is deliberately excluded: it has NO
            // inbox fallback, and this path also runs on live-socket
            // reconciles (`broadcast_gap`) where the agent may genuinely
            // still be waiting on it — its expiry belongs to the transport
            // drop (`handleConnectionDrop`) and the `error` terminal, never
            // to a reconcile that proves nothing about its turn.
            expireTurnScopedPrompts(includeSecure: false)
            lastBackfillError = nil
        } catch {
            // Backfill is best-effort for the transcript (we keep what we have),
            // but the failure must NOT be invisible: a mirrored foreign turn
            // whose live stream was dropped relies entirely on this path, so a
            // silent REST error here is a permanently-missing mirror. Surface it.
            #if DEBUG
            foreignMirrorTelemetry.backfillFailures += 1
            #endif
            // A failure from a superseded fetch (the session switched while it
            // was in flight) belongs to a session that is no longer on screen —
            // never surface it on the NEW session (R1 #21's catch-side twin).
            guard storedId == sessions?.activeStoredId else { return }
            let description = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            lastBackfillError = description
            chatLog.error("backfill failed for session \(storedId, privacy: .public): \(description, privacy: .public)")
        }
    }

    /// The injected `backfillFetch`, or the default that resolves the live REST
    /// client. Built lazily because `connection` is wired after `init`; tests
    /// override `backfillFetch` directly.
    private var resolvedBackfillFetch: ((String) async throws -> [StoredMessage])? {
        if let backfillFetch { return backfillFetch }
        guard let rest = connection?.rest else { return nil }
        // ABH-400: plugin gateways serve only the recent tail window on
        // foreground/reconnect; legacy gateways keep the existing full/delta path.
        return { [cacheStore] sessionId in
            if let page = await fetchTranscriptPage(
                rest: rest,
                sessionId: sessionId,
                limit: ChatStore.transcriptOpenWindowLimit
            ) {
                return page.messages
            }
            return try await fetchTranscriptDeltaAware(rest: rest, cacheStore: cacheStore, sessionId: sessionId)
        }
    }

    /// ABH-159 — surface a foreign-mirrored turn's USER prompt at message.start,
    /// instead of waiting for the (fragile) complete-time `backfill()`.
    ///
    /// The gateway broadcasts ONLY assistant frames (message.start has no payload,
    /// then deltas/tool/complete); the user's prompt text is written to the
    /// session DB but never `_emit`'d, so the S1 fan-out can never deliver it to a
    /// mirror. Today the foreign user bubble's only delivery is the complete-time
    /// `backfill()` reconcile — a single point that's missed whenever
    /// `message.complete` is dropped/late, leaving the user bubble absent until a
    /// force-quit reseed.
    ///
    /// This is APPEND-ONLY and uses the SAME `toChatMessages` transform the
    /// authoritative backfill uses, so the surfaced user row carries the exact
    /// DETERMINISTIC id (`deterministicID(seedKey:)`, never `UUID()`) the later
    /// `reconcileMessages` keys on — it matches by id and updates in place, NEVER
    /// a duplicate. It never calls `cancelStreaming()`/`seed()` (which bail on a
    /// live foreign mirror anyway), and the streaming row is located by id on
    /// every flush (`mutateStreaming`), so inserting a row ahead of it cannot
    /// corrupt the live assistant stream.
    private func mergeForeignUserRows() {
        guard streamingIsForeign, let storedId = sessions?.activeStoredId else { return }
        let mergeTask = Task { [weak self] in
            guard let self else { return }
            guard let fetch = self.resolvedBackfillFetch else { return }
            guard let stored = try? await fetch(storedId) else { return }
            // The world may have moved during the fetch: only apply if THIS
            // foreign mirror for THIS session is still live (otherwise the
            // authoritative seed owns the transcript). Same guard shape as
            // `backfill()`'s post-await check.
            guard self.streamingIsForeign,
                  storedId == self.sessions?.activeStoredId else { return }
            let normalized = Self.toChatMessages(stored)
            // The current foreign turn's prompt is the TRAILING user row. Surface
            // only that one if it isn't already present — appending an older row
            // here could mis-position it, and the complete-time reconcile remains
            // the authoritative full rebuild for everything else.
            guard let userRow = normalized.last(where: { $0.role == .user }),
                  !self.messages.contains(where: { $0.id == userRow.id }) else { return }
            if let placeholderIdx = self.messages.firstIndex(where: { $0.isStreaming }) {
                self.messages.insert(userRow, at: placeholderIdx)
            } else {
                self.messages.append(userRow)
            }
            self.rebuildUserOrdinals()
        }
        #if DEBUG
        lastForeignUserRowMergeTask = mergeTask
        #endif
    }

    // MARK: - Reset

    /// Clear all transcript state for a fresh session. `transcriptGeneration`
    /// returns to 0, which the view reads as "transcript still loading" until
    /// the first seed lands.
    func reset() {
        cancelStreaming()
        messages = []
        userOrdinals = [:]
        pendingApproval = nil
        pendingClarification = nil
        // A transient secure prompt belongs to the session being torn down; drop
        // it (no value is held here — see PendingSecurePrompt). The view's
        // `@State` value clears itself on dismissal.
        pendingSecurePrompt = nil
        resetSubagentTree()
        lastError = nil
        // Occupancy belongs to the session being torn down (H1); the next
        // session re-seeds from its own session.status / first turn.
        contextUsage = nil
        // A backfill/seed failure belongs to the session being torn down too —
        // a stale error must not render in the next session's empty-transcript
        // state (see ChatView's loading/error split, R1 #79).
        lastBackfillError = nil
        transcriptHasMoreBefore = false
        isLoadingEarlierTranscript = false
        oldestLoadedTranscriptWireId = nil
        // A pending foreign-reconcile adoption belongs to the session being torn
        // down (§3.7); never let it bleed into the next session's first seed.
        pendingForeignReconcileID = nil
        pendingReconnectReconcileID = nil
        clearAllCompactionIndicators()
        transcriptGeneration = 0
    }

    /// Surface a failed `open()`-path transcript seed the same way a failed
    /// `backfill()` is surfaced, so ChatView renders a recoverable error state
    /// (with retry via `backfill()`) instead of the infinite "Loading
    /// conversation…" spinner (R1 #79). `SessionStore.seedTranscript` calls
    /// this from its catch — `lastBackfillError` is `private(set)` here.
    func noteTranscriptLoadFailure(_ description: String) {
        lastBackfillError = description
    }

    private func cancelStreaming() {
        flushTask?.cancel()
        flushTask = nil
        streamingMessageID = nil
        textBuffer = ""
        thinkingBuffer = ""
        turnStartedAt = nil
        activeToolName = nil
        activeToolCallId = nil
        setStreaming(false, reason: "cancelStreaming")
        mirroringRuntimeId = nil
        streamingIsForeign = false
        // A wholesale reset (reset / open-seed / draft / pre-truncation) ends any
        // local turn too. ownership=NONE after this.
        endLocalTurn()
        // The rendered turn (if any) was discarded without completing — end its
        // Live Activity instead of orphaning it (R1 #26/#73). cancelStreaming is
        // the single funnel for every discard path: reset (open/draft/switch),
        // connection drop, and the pre-truncation rewrite. Idempotent when no
        // activity is live; an edit/retry's fresh turn re-starts one.
        onTurnDiscarded?()
    }

    /// Tear down the streaming state of the *adopted foreign* turn so the
    /// recovery `backfill()` can run (its `guard !isStreaming` would otherwise
    /// no-op the very reconcile it exists to perform). This clears the foreign
    /// stream's bookkeeping and never touches a genuinely-local in-flight turn: if
    /// `isStreaming` is true but the stream is NOT foreign-owned
    /// (`streamingIsForeign == false`), this is a no-op on the streaming flags and
    /// leaves the local turn intact.
    ///
    /// `preservePlaceholderForReconcile` (contract Batch E §3.7, fixes D9):
    ///  - `true` (the mirror-COMPLETE path, where `backfill()` runs IMMEDIATELY
    ///    after): the half-rendered placeholder assistant row is LEFT in place and
    ///    its id is recorded in `pendingForeignReconcileID`, so the following
    ///    `seed()` reconciles the finalized reply ONTO it in place — the reply
    ///    transitions placeholder → final without blinking out and popping back
    ///    restacked (the old remove-then-async-backfill window).
    ///  - `false` (the connection-DROP path, where a successful backfill is NOT
    ///    guaranteed): the placeholder is REMOVED as before, so a drop that never
    ///    reconciles does not strand a blank streaming bubble.
    /// Watchdog that ends an adopted FOREIGN mirror whose source went silent. A
    /// foreign stream (mirroring e.g. the desktop's turn) is normally torn down by
    /// its `message.complete`; if the source disconnects mid-turn that frame never
    /// arrives and the mirror spins forever — `isStreaming` stays true, the composer
    /// is stuck in queue-mode, and the outbox can never drain ("can't send after the
    /// desktop touched the session"). Re-armed on every adopted foreign frame; after
    /// `foreignMirrorStaleTimeout` of silence it runs the SAME teardown + backfill +
    /// drain a real completion would. Foreign-only — a local turn is never touched.
    private var foreignMirrorWatchdog: Task<Void, Never>?
    private static let foreignMirrorStaleTimeout: Duration = .seconds(30)

    /// (Re)arm the foreign-mirror staleness watchdog.
    private func armForeignMirrorWatchdog() {
        foreignMirrorWatchdog?.cancel()
        foreignMirrorWatchdog = Task { [weak self] in
            try? await Task.sleep(for: ChatStore.foreignMirrorStaleTimeout)
            guard let self, !Task.isCancelled, self.streamingIsForeign else { return }
            self.fireForeignMirrorWatchdog()
        }
    }

    /// The adopted foreign mirror went silent past the staleness window: end the
    /// mirrored turn exactly as a `message.complete` would — teardown, authoritative
    /// REST reconcile, then drain the outbox into the now-idle session.
    private func fireForeignMirrorWatchdog() {
        guard streamingIsForeign else { return }
        chatLog.warning("foreign-mirror watchdog fired: mirrored turn went silent past the staleness window — ending it so queued sends unblock")
        teardownForeignStream(preservePlaceholderForReconcile: true)
        Task { [weak self] in
            await self?.backfill()
            self?.onTurnComplete?()
        }
    }

    private func teardownForeignStream(preservePlaceholderForReconcile: Bool = false) {
        foreignMirrorWatchdog?.cancel()
        foreignMirrorWatchdog = nil
        mirroringRuntimeId = nil
        guard streamingIsForeign else { return }
        if localTurnToken != nil {
            chatLog.warning("foreign stream teardown saw a local turn token; preserving local ownership and clearing foreign marker")
            streamingIsForeign = false
            return
        }
        flushTask?.cancel()
        flushTask = nil
        if let id = streamingMessageID {
            if preservePlaceholderForReconcile,
               let index = messages.firstIndex(where: { $0.id == id }) {
                // In-place reconcile (§3.7): keep the placeholder row; the next
                // seed adopts its slot for the finalized reply (no blink). Clear
                // its own `isStreaming` so that if the recovery backfill FAILS
                // (no seed lands) the row does not render a spinner forever — the
                // backfill error surfaces its own retry affordance instead.
                messages[index].isStreaming = false
                pendingForeignReconcileID = id
            } else if let index = messages.firstIndex(where: { $0.id == id }) {
                // Drop the placeholder assistant row this foreign stream was
                // streaming into; the reconnect seed (if any) re-creates the
                // finalized message from server history.
                messages.remove(at: index)
            }
        }
        streamingMessageID = nil
        textBuffer = ""
        thinkingBuffer = ""
        turnStartedAt = nil
        activeToolName = nil
        activeToolCallId = nil
        streamingIsForeign = false
        setStreaming(false, reason: "teardownForeignStream")
    }

    /// Tear down whatever stream the just-dropped transport was feeding. A dead
    /// socket can never deliver the in-flight turn's `message.complete`, so
    /// leaving `isStreaming` set wedges the transcript in a fake "streaming"
    /// state forever: the post-reconnect `backfill()` no-ops on its own
    /// `guard !isStreaming` (R1 #9 for a local turn, R1 #42 for an adopted
    /// foreign mirror). Called from every connection-loss path
    /// (`ConnectionStore.handle(state:)`, `disconnect()`, the dead-socket
    /// scene-phase probe). Idempotent — a no-op when nothing is streaming.
    func handleConnectionDrop() {
        clearAllCompactionIndicators()
        // An adopted foreign mirror dies with its transport: clear the mirror
        // bookkeeping (and its placeholder row) so the reconnect backfill can
        // reconcile from server history (#42). No-op for a local turn.
        teardownForeignStream()
        // A mirrored turn's Live Activity dies with the transport too — the
        // local-turn path below reaches this via cancelStreaming, but the
        // foreign-only drop returns at the guard and would orphan it (R1 #26).
        // Idempotent when nothing is live.
        onTurnDiscarded?()
        guard isStreaming || localTurnInFlight else { return }
        // A genuinely-local in-flight turn: finalize the half-streamed bubble
        // in place — the server keeps producing without us, and the reconnect
        // backfill re-seeds the authoritative transcript — and mark it so the
        // user knows this render was cut, not completed (#9).
        flushBuffersImmediately()
        mutateStreaming { message in
            message.isStreaming = false
            // Route through setWarningPart (not a direct legacy-field write) so a
            // local turn that already accumulated ordered parts (text/tool) lands
            // the warning as an in-order `.warning` part too — keeping the part
            // list consistent with every other warning path (review fix #1).
            if message.warning == nil { message.setWarningPart("Connection lost") }
        }
        pendingReconnectReconcileID = streamingMessageID
        if activeToolName != nil { onToolChange?(nil) }
        cancelStreaming()
        // Every prompt card rode the transport that just died. The secure
        // prompt in particular MUST go here (it has no inbox fallback, and a
        // post-restart stale card mis-resolves silently — `respondSecurePrompt`
        // swallows the 4009); approvals/clarifications re-surface via the
        // inbox when still genuinely pending.
        expireTurnScopedPrompts(includeSecure: true)
    }
}
