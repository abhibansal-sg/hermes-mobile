import Foundation
import SwiftUI  // A2: withTransaction(Transaction(animation: nil)) on the finalize flip
import UIKit
import os
#if DEBUG
#endif

struct TranscriptPageFetch: Sendable {
    let messages: [StoredMessage]
    let oldestId: Int?
    let hasMoreBefore: Bool
}

struct TranscriptAroundFetch: Sendable {
    let messages: [StoredMessage]
    let oldestId: Int?
    let hasMoreBefore: Bool
    let containsTarget: Bool
}

/// Plugin-only backward-paged transcript fetch. Kept outside RestClient.swift for
/// ABH-400's narrow scope fence; it reuses RestClient's internal request/JSON
/// helpers without changing the existing no-param delta handshake method.
func fetchTranscriptPage(
    rest: RestClient,
    sessionId: String,
    limit: Int,
    before: Int? = nil,
    shape: String? = nil
) async -> TranscriptPageFetch? {
    guard rest.pathStyle == .plugin else { return nil }
    let encodedId = sessionId.addingPercentEncoding(
        withAllowedCharacters: .urlPathAllowed
    ) ?? sessionId
    // WS-5.1: `shape` is a PARAMETER now (was hardcoded `skeleton`, which stranded
    // reopened chats on text-only rows with no hydrate). Default `nil` ⇒ FULL; the
    // cold-open seed passes `skeleton` and pairs it with a background hydrate.
    var path = "\(rest.pathStyle.mobileAPIPrefix)/sessions/\(encodedId)/messages"
        + "?limit=\(max(1, limit))"
    if let before, before > 0 {
        path += "&before=\(before)"
    }
    if let shape, !shape.isEmpty {
        path += "&shape=\(shape)"
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

/// Plugin-only target-centered transcript fetch for jump/search/artifact opens.
/// Returns the target ± radius without forcing a full transcript load.
func fetchTranscriptAround(
    rest: RestClient,
    sessionId: String,
    around messageId: Int,
    radius: Int
) async -> TranscriptAroundFetch? {
    guard rest.pathStyle == .plugin else { return nil }
    let encodedId = sessionId.addingPercentEncoding(
        withAllowedCharacters: .urlPathAllowed
    ) ?? sessionId
    let path = "\(rest.pathStyle.mobileAPIPrefix)/sessions/\(encodedId)/messages/around"
        + "?around=\(messageId)&radius=\(max(0, radius))"
    do {
        let data = try await rest.get(path: path)
        let root = try rest.decodeJSONValue(from: data, context: "messagesAround")
        guard let array = root["messages"]?.arrayValue else { return nil }
        let page = root["page"]
        return TranscriptAroundFetch(
            messages: array.compactMap(StoredMessage.init(json:)),
            oldestId: page?["oldest_id"]?.intValue,
            hasMoreBefore: page?["has_more_before"]?.boolValue ?? false,
            containsTarget: page?["contains_target"]?.boolValue ?? false
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
    #endif
    var isStreaming: Bool = false

    /// QA-2 R12 — local-turn watchdog. Armed on every `isStreaming` false→true
    /// transition; if no relay item batch arrives for ``localTurnStaleTimeout``
    /// the turn is force-settled so the stop button, the dock task pill and the
    /// Live Activity can never wedge when the terminal `turn.completed` /
    /// `message.complete` frame is missed or dropped (owner device-QA: the
    /// "Tasks 0/0 + red stop stuck for 3m9s" episode that needed a force-close).
    /// Cancelled on every legitimate settle path (`setStreaming(false)`,
    /// `cancelStreaming`, `reset`, foreign-teardown). Foreign-mirror silence has
    /// its OWN watchdog (``foreignMirrorWatchdog``) — this one guards a turn WE
    /// are driving.
    private var localTurnWatchdog: Task<Void, Never>?
    /// Stage-2 settle window (fix-round 1): sized MATERIALLY above the worst-case
    /// OPAQUE-TOOL duration — a single long bash/build tool with no incremental
    /// output and no gateway heartbeat emits ZERO frames for its whole run, so
    /// nothing refreshes the silence clock while the turn is genuinely alive.
    /// 180 s false-positived on exactly that shape (the settle is healed by any
    /// late frame — `RelayItemStore.applyDelta` resurrects locally-settled items
    /// replace-not-drop — but the transient "Interrupted" fold on a healthy turn
    /// is still wrong). 480 s keeps eternal-working bounded while a healthy
    /// slow turn essentially never trips it; a genuinely dead turn still heals
    /// at stage 1 (45 s silent resync) whenever the authority merely dropped a
    /// terminal frame.
    private static let localTurnStaleTimeout: Duration = .seconds(480)
    /// QA-3 S8/A4 — per-turn LIVENESS fallback (kills eternal double-working,
    /// IMG_2591). The QA-2 watchdog was per-STORE and re-armed by ANY item
    /// batch — a dead turn 1 stayed "Working…" forever while turn 2's frames
    /// kept re-arming, and even when it fired, the next projection re-derived
    /// streaming from the still-`.inProgress` items. Liveness is now PER-TURN
    /// and two-stage, keyed off ``turnLivenessBaseline`` (refreshed ONLY by
    /// CURRENT-turn frames — `noteTurnLivenessFrame(isCurrentTurn:)` from the
    /// coordinator's ingest):
    ///   stage 1 — ``turnLivenessResyncAfter`` of silence: a SILENT
    ///     `resync{last_seq}` (snapshot when the gap exceeds the ring). A
    ///     dropped terminal frame heals here; the user sees nothing (C3).
    ///   stage 2 — ``localTurnStaleTimeout`` of silence: the turn is DEAD
    ///     (the resync recovered nothing, so the authority has nothing more).
    ///     The coordinator settles the stuck items locally (muted
    ///     "Interrupted" fold, never an error banner) and the live flag
    ///     clears. Eternal-working is unreachable by construction.
    private static let turnLivenessResyncAfter: Duration = .seconds(45)
    /// The watchdog's evaluation cadence (chunked sleep; staleness is computed
    /// off ``turnLivenessBaseline`` at each wake, so a frame landing mid-sleep
    /// simply defers the next stage instead of firing late-and-wrong).
    private static let turnLivenessTick: Duration = .seconds(5)
    /// Per-turn latch: stage 1 fires at most once per turn (reset on turn
    /// start / settle).
    private var turnLivenessResyncFired = false
    /// The current turn's last CURRENT-turn frame (turn start until the first
    /// frame). `nil` outside a turn.
    private var turnLivenessBaseline: ContinuousClock.Instant?
    #if DEBUG
    /// DEBUG observability for the liveness tests: how many stage-1 silent
    /// resyncs the watchdog (or the `_debug` seam) has fired.
    private(set) var turnLivenessResyncCount = 0
    #endif
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
    #endif
    private(set) var subagentNodeCount: Int = 0

    #if DEBUG
    /// DEBUG-only bridge accessor for the integration gate: the KIND of the active
    /// secure prompt (`"sudo"` / `"secret"` / `"none"`) so the gate can assert a
    /// prompt is up WITHOUT ever reading the entered value (which is never held in
    /// the store at all — see ``PendingSecurePrompt``). Bridge-exposed as a String.
    var activeSecurePromptKind: String {
        pendingSecurePrompt?.kind.rawValue ?? "none"
    }
    #endif
    /// Last user-facing error (busy, send failure, …), or `nil`.
    #if DEBUG
    #endif
    var lastError: String?

    /// Mobile undo/rollback phase for the active session. Kept separate from
    /// `lastError`: empty/success/loading are honest state, not failures.
    var undoRollbackPhase: UndoRollbackPhase = .idle

    /// A rollback checkpoint + diff awaiting the user's destructive restore
    /// confirmation. Non-nil drives the restore sheet; `rollback.restore` is never
    /// called while this is merely pending.
    var pendingRollbackRestore: PendingRollbackRestore?

    /// Test seam for the undo/rollback JSON-RPC chain. Production falls back to
    /// `HermesGatewayClient.requestRaw` through `undoRollbackRequest`.
    var undoRollbackRPC: ((String, JSONValue, Duration) async throws -> JSONValue)?

    // MARK: - Turn dock accessors (Wave 25)

    /// The latest todo list for the active session, or `nil` — the single
    /// evolving checklist the Turn Dock's task box mirrors. On the DIRECT
    /// (gateway) path, scans the visible transcript (`messages`, already scoped
    /// to the active session) in reverse for the most recent `todo` tool
    /// activity that yields a parseable list. On the RELAY path (N4/A5), the
    /// relay's ONE living `.taskList` item bridges into the SAME accessor via
    /// ``applyRelayItems(_:)`` (which refreshes the relay mirror on every
    /// projection; ``syncRelayTaskList(from:)`` is the store-shaped entry
    /// point) so the dock renders identically either way.
    /// `nil` when the session has no todo activity yet, or the newest one carries
    /// no list (e.g. a mid-run write before its first result).
    ///
    /// The dock renders THIS; while it shows the task box the transcript
    /// suppresses EVERY inline `TodoCardView` for the session — not just the one
    /// backing this list (owner QA §d). The dock is the single home for the
    /// checklist, and because the agent rewrites the one evolving list across
    /// several `todo` tool calls, suppressing only the latest still left the
    /// earlier snapshots of the same list rendering inline 2-3×. The suppression
    /// rule therefore lives in `ChatView.dockSuppressesTodoCards` as a pure
    /// `dockContent == .tasks` flag, not a per-`tool_call_id` match.
    var latestTodoList: TodoList? { latestTodo?.list }

    /// The `tool_call_id` of the activity backing ``latestTodoList`` — the
    /// identity of the newest todo list (exposed for tests and callers that need
    /// to key on the active list). NOTE: inline-card suppression no longer keys on
    /// this; the dock suppresses all todo cards wholesale while the task box is up
    /// (see ``latestTodoList``).
    var latestTodoToolID: String? { latestTodo?.id }

    /// The relay-path mirror of the dock's todo list (N4/A5): the latest
    /// `.taskList` item ingested from the relay item store, or `nil` when the
    /// relay path has produced no task list (or has dropped it via a snapshot
    /// that omits it). Held APART from the legacy `messages` scan so the two
    /// paths never corrupt each other; the app is on EXACTLY ONE path at a time,
    /// so when the relay mirror is populated it is authoritative for the dock
    /// (the relay's `taskList` item IS the gateway's `todo` tool reframed for the
    /// relay protocol — same list, same lifecycle, same data — RELAY-PHONE-
    /// PROTOCOL §2 "taskList semantics"). Production wiring: ``applyRelayItems``
    /// refreshes the mirror from the same reconciled items it projects into the
    /// transcript (flag-gated — only reached when `transportPath` is `.relay`,
    /// default OFF, so the gateway blob path is byte-unchanged). The convergence
    /// wave will eventually retire the legacy scan.
    private var relayLatestTaskList: (id: String, list: TodoList)?

    /// Re-derive the relay-path task-list mirror from a relay item store
    /// (N4/A5). The live projection caller is ``applyRelayItems`` (which passes
    /// the ACTIVE entry's reconciled items on every frame batch — R1: the
    /// mirror only ever sees the active session's store, so another session's
    /// list never mirrors, contract I15); this store-shaped entry point stays
    /// for callers/tests that hold a store directly. Refreshing includes
    /// CLEARING the mirror when no `.taskList` item remains (a snapshot that
    /// drops the list, or a session switch to one with no todo activity).
    /// Idempotent: re-running on an unchanged store is a no-op.
    func syncRelayTaskList(from store: RelayItemStore) {
        refreshRelayTaskListMirror(from: store.items)
    }

    /// Shared scan behind ``syncRelayTaskList(from:)`` and ``applyRelayItems``.
    /// Most-recent `.taskList` item wins; the relay drives ONE living list per
    /// session on a stable `<sid>:tasks` id, and the items are already in render
    /// order (ord ascending, ties by arrival — `RelayItemStore.items`), so a
    /// reverse scan returns the live one. Items whose body yields no parseable
    /// list are skipped (mirrors the legacy scan's skip-empty semantics — keeps
    /// the prior list rather than blanking the dock on a mid-stream delta).
    ///
    /// QA-2 R13 — SESSION-SCOPE: when a list is found we stamp
    /// ``taskListOwnerSessionId`` to the active runtime session so the dock can
    /// prove ownership (the pill never renders for a list a different session
    /// owns, even if both happen to be live). The owner clears together with
    /// the mirror — `reset()` (session teardown) and a fresh turn's send both
    /// drop it so a new session/turn starts with a clean dock.
    private func refreshRelayTaskListMirror(from items: [ChatItem]) {
        for item in items.reversed() where item.type == .taskList {
            if let list = item.taskListBody {
                relayLatestTaskList = (item.itemID, list)
                // R1: the owner is the session at the WRITE-GATE (the
                // coordinator's own record, moved atomically on switch —
                // SessionStore's `activeRuntimeId` trails the gate move, so
                // keying on it raced the switch-back projection; I15).
                taskListOwnerSessionId = relayWriteGateSessionID ?? activeSessionId
            }
            return
        }
        relayLatestTaskList = nil
        taskListOwnerSessionId = nil
    }

    /// The runtime session id that owns the currently-mirrored task list, or
    /// `nil` when no list is mirrored. QA-2 R13: the dock's task box is strictly
    /// session-scoped — a list mirrored for session A must NEVER render while
    /// session B is active. `reset()` clears this with the mirror on session
    /// teardown; ``refreshRelayTaskListMirror`` re-stamps it whenever a live
    /// list lands. Equal to `activeSessionId` for the owning session, so the
    /// visibility gate is a plain identity check (test A-vs-B, A6).
    private(set) var taskListOwnerSessionId: String?

    /// Wall clock of the most recent relay item batch applied (QA-2 R12). The
    /// ``localTurnWatchdog`` reconciles against this — a turn marked streaming
    /// whose frames have gone silent past ``localTurnStaleTimeout`` is force-
    /// settled so the stop state and the dock pill can never wedge when the
    /// terminal frame is missed (owner device-QA: "no force-close ever needed
    /// to regain control").
    private(set) var lastRelayItemFrameAt: Date?

    /// QA-2 R12 — the dock's task-box VISIBILITY gate. The list DATA stays in
    /// ``latestTodoList`` (the dock reads it when this is true, the inline
    /// transcript keeps rendering the item while false); this gate decides
    /// whether the dock surface owns the checklist RIGHT NOW. The pill is
    /// visible exactly when ALL hold:
    ///   1. a list exists (``latestTodoList`` non-nil);
    ///   2. the list belongs to the ACTIVE session — a list session A owns
    ///      never shows for session B (R13/A6);
    ///   3. a turn is live (``isStreaming``) — the pill is turn-lifecycle-
    ///      driven, clears the instant the owning turn ends (R12);
    ///   4. the list is NOT terminal — once every task is completed/cancelled
    ///      the agent has closed the list and the pill auto-dismisses (R13).
    /// (1)+(3) together also kill the cross-session resurrection the legacy
    /// context-free `messages` scan caused: a settled prior turn's cached todo
    /// activity can't reach the dock because no turn is live to gate it on.
    var dockShowsTaskBox: Bool {
        guard let list = latestTodoList, isStreaming else { return false }
        guard !Self.taskListIsTerminal(list) else { return false }
        // Owner check: nil-vs-nil (a brand-new session before any list) passes;
        // any mismatch hides the pill. Belt-and-braces over `reset()`'s mirror
        // clear — proves ownership independent of the teardown path.
        let owner = taskListOwnerSessionId
        let active = activeSessionId
        if let owner, let active, owner != active { return false }
        return true
    }

    /// A task list is terminal when every item is completed or cancelled — the
    /// agent has finished or abandoned the work and the dock pill should auto-
    /// dismiss instead of lingering at "N of N" (QA-2 R13: "closed/short-closed
    /// by the agent").
    private static func taskListIsTerminal(_ list: TodoList) -> Bool {
        guard !list.items.isEmpty else { return false }
        return list.items.allSatisfy { $0.status == .completed || $0.status == .cancelled }
    }

    /// Shared scan behind both dock accessors: the newest todo activity that
    /// yields a parseable list, with its identity. Prefers the relay mirror when
    /// populated (relay path is authoritative when active); otherwise falls back
    /// to the DIRECT (gateway) path's legacy scan of `messages`. Reverse order so
    /// the list the agent is actively updating wins. The parse mirrors
    /// `ToolClusterView.toolCard` exactly — structured `tool.todos` first, then
    /// the `resultPreview` JSON fallback — so the dock and the (suppressed)
    /// inline card would derive the identical list.
    private var latestTodo: (id: String, list: TodoList)? {
        if let relay = relayLatestTaskList { return relay }
        for message in messages.reversed() {
            for tool in message.tools.reversed() where tool.name == TodoList.toolName {
                if let list = tool.todos.flatMap({ TodoList(todosArray: $0) })
                    ?? TodoList(resultJSON: tool.resultPreview) {
                    return (tool.id, list)
                }
            }
        }
        return nil
    }

    /// Whether the most recent `send(text:)` call actually dispatched
    /// `prompt.submit` to the server, vs. refusing before ever asking (empty
    /// text, no connection, no resolvable runtime, attachment-upload
    /// failure). Reset to `false` at the top of every `send`; only
    /// meaningful immediately after a call returns `false`.
    ///
    /// Exists for programmatic callers that need to tell "the server never
    /// saw this" (safe to treat the attempt as if it never happened) apart
    /// from "we asked and lost the answer" (a `prompt.submit` transport
    /// failure could mean the server accepted it — never safe to assume
    /// otherwise). `PendingIntentRouter.deliverAskPrompt` uses this to decide
    /// whether it's safe to also delete a session it created solely for a
    /// refused `.ask` prompt, rather than just re-parking the prompt.
    private(set) var lastSendReachedServer = false

    /// Last `backfill()` REST failure, or `nil` if the most recent backfill
    /// succeeded or none has run. Observability for the mirror-recovery path:
    /// a foreign turn whose live stream was dropped relies entirely on backfill,
    /// so a silent REST error there means a permanently-missing mirror. Surfaced
    /// here (and logged via `chatLog`) instead of being swallowed by a bare
    /// `catch`. Not user-facing chrome — it drives diagnostics and the DEBUG
    /// bridge — so it never clobbers `lastError`.
    #if DEBUG
    #endif
    private(set) var lastBackfillError: String?

    #if DEBUG
    /// DEBUG-only adoption-gate telemetry, bridge-exposed via the UI-G
    /// StateAccessor pattern. Release builds never reference this.
    private(set) var foreignMirrorTelemetry = ForeignMirrorTelemetry()

    /// DEBUG-only label of the most recent `isStreaming` write (F3-H2). Names the
    /// function + reason + the inbound event's ids vs. the active ids, so the gate
    /// can read which path flipped streaming on. Bridge-exposed as a String.
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
    private weak var queueStore: QueueStore?

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

    func attachOutbox(_ queueStore: QueueStore) {
        self.queueStore = queueStore
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
    /// QA-2 R4/A2 — TURN-SCOPED relay streaming. The relay's submit handler fans
    /// out a **terminal** `userMessage` item immediately; the old projection
    /// derived `isStreaming` purely from item terminality
    /// (`rebuilt.contains { $0.isStreaming }`), so that first frame cleared the
    /// submit-time streaming flag and killed the cursor + stop button for the
    /// ENTIRE accepted-and-waiting window (fast turns showed NO working
    /// affordance at all — "the reply just appears later"). This flag makes
    /// `isStreaming` turn-scoped instead: true from the relay send until the
    /// turn settles via `turn.completed` (plumbed as `applyRelayItems`'
    /// `turnSettled:` argument) or is discarded (`cancelStreaming`), independent
    /// of per-item terminality. Never set on the direct path.
    private(set) var relayTurnLive = false
    /// QA-2 R5/A3 — settled relay turn durations, keyed by the settled assistant
    /// row's id. The relay projection REBUILDS every tagged row from the item
    /// store on every pass (items accumulate for the session), so a duration
    /// captured once on the settle edge must live OUTSIDE the rebuilt rows to
    /// survive later re-projections — without this, the second send's first
    /// frame would strip the prior turn's "Worked for Ns" back to a bare
    /// "Worked" (relay items carry no timestamps; IMG_2532). Cleared with the
    /// session (`reset()`).
    private var relaySettledElapsed: [UUID: TimeInterval] = [:]
    /// Name of the tool currently executing in the in-flight turn, surfaced in
    /// the turn activity bar. `nil` when no tool is running. Set on `tool.start`
    /// and cleared on that tool's `tool.complete` / turn completion.
    #if DEBUG
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
    #if DEBUG
    /// Focused notification-policy seams; production always resolves these
    /// values from the persisted PushRegistrar/connection state.
    var pushAlertAuthorityOverride: Bool?
    var notificationDeviceScopeOverride: String?
    var notificationForegroundOverride: Bool?
    #endif

    init() {
        // I23 (amendment G3): reload the DURABLE resolved-gate record so a
        // gate ANSWERED (or turn-ended) before a force-close stays DOWN on
        // cold-open resume — the resync ring replays it; the in-memory set
        // alone died with the process (the W0a RED).
        if let persisted = UserDefaults.standard.stringArray(
            forKey: Self.resolvedRelayGateIDsDefaultsKey
        ) {
            resolvedRelayGateIDs = Set(persisted)
        }
    }

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
    private(set) var isLoadingJumpTarget = false
    private(set) var jumpTargetLoadError: String?
    private var oldestLoadedTranscriptWireId: Int?
    private var jumpWindowFetchAttemptedMessageIds: Set<Int> = []

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

    /// Test seam for target-centered jump fetches. The live app resolves this
    /// through the plugin REST route in ``resolvedTranscriptAroundFetch``.
    var transcriptAroundFetch: ((String, Int, Int) async -> TranscriptAroundFetch?)?

    /// Test seam for the backward-page (``loadEarlierTranscript``) fetch. The
    /// live app resolves the module-level ``fetchTranscriptPage`` against
    /// `connection?.rest` directly; tests that need to control the timing of
    /// this specific fetch (e.g. proving the ABH-401 conflict guard against
    /// ``loadTranscriptAround``) inject an override here instead.
    var transcriptPageFetch: ((String, Int, Int?) async -> TranscriptPageFetch?)?

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
        let wasStreaming = isStreaming
        isStreaming = value
        // QA-2 R12 — stop-state wedge kill. Arm on rising edge so a missed
        // terminal frame can never leave `isStreaming` (and the dock pill, the
        // red stop button, the Live Activity) stuck forever; cancel on falling
        // edge so a normal settle never fires a spurious force-clear.
        if value && !wasStreaming {
            armLocalTurnWatchdog()
        } else if !value && wasStreaming {
            cancelLocalTurnWatchdog()
        }
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

        handleNotificationPolicy(event)

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
            handleSubagentEvent(type: event.type, payload: event.payload,
                                 sessionId: event.sessionId ?? activeSessionId ?? "")
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
            // too, so the desktop's delegation is visible on the phone. The
            // owning runtime is the ADOPTED foreign session (`sid` /
            // `mirroringRuntimeId`), never our own `activeSessionId` — the
            // `subagent.interrupt` RPC (STR-145) must target the runtime that
            // actually owns the branch, not whichever one is locally active.
            handleSubagentEvent(type: event.type, payload: event.payload, sessionId: sid)
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
        // R5: a new turn clears the prior turn's settle state — the compat
        // error-item flag, the id-less settle latch, and any lingering
        // local-STOP mark — so this turn's `turn.completed` fires its seam
        // normally. (The per-turn-ID latch is NOT cleared: replays of the
        // prior turn's boundary frames must stay suppressed — I21.)
        relayTurnSawErrorItem = false
        relayTurnSettleLatched = false
        relayTurnSettling = false
        // QA-3 S8/A4: a fresh turn starts with a clean liveness slate (covers
        // turns this phone did NOT send — a mid-turn resume projection; the
        // driven-send path resets at `relayTurnLive = true`).
        resetTurnLivenessState()
        turnLivenessBaseline = ContinuousClock.now
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
        // Derived from the FULL `payload.result` — before the 300-char
        // `resultPreview` truncation above — so a summary can still surface
        // fields that live past character 300 of the raw preview.
        let summary = ToolResultSummary.summaryLine(for: payload.result, failed: failed)
        // Retain the full structured todo array from the untruncated result so
        // the TodoCardView never re-parses the 300-char preview (which would
        // fail JSON parsing on any non-trivial list). The gateway puts the
        // list inside the result object under `todos` for the `todo` tool
        // (tui_gateway/server.py:2077 _on_tool_complete) and also mirrors it to
        // a top-level `payload.todos`; read either.
        let todos = payload.result["todos"]?.arrayValue ?? payload.todos
        // File-edit tools (patch/write_file/edit_file) carry a full unified diff
        // in the result that the 300-char `resultPreview` would truncate mid-hunk.
        // Retain it untruncated, mirroring desktop's `inlineDiffFromResult`.
        let fullDiff = InlineFileDiff.isFileEditTool(payload.name)
            ? InlineFileDiff.extract(from: payload.result)
            : nil
        mutateTool(id: id) { tool in
            tool.state = failed ? .failed : .done
            tool.resultPreview = preview
            tool.resultSummary = summary
            tool.durationMs = payload.durationMs
            tool.todos = todos
            tool.fullDiff = fullDiff
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
        let completionSucceeded = completionStatus == nil
            || completionStatus == "complete"
            || completionStatus == "completed"
        let shouldClearReconnectWarning = completion != nil
            && pendingReconnectReconcileID == id
            && completion?.warning == nil
            && !completionFailed
            && completionSucceeded
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
            message.setReasoningElapsed(elapsed)
            if let warning = completion?.warning {
                message.setWarningPart(warning)
            }
            // Non-success terminal status (ABH-46 item 5): surface it on the
            // bubble. The live gateway sends `status: "complete"` on the happy
            // path (`"completed"` is tolerated for legacy clients); anything
            // error-like becomes the warning strip without clobbering an explicit
            // warning the server already sent.
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
    /// landed, consume the resume snapshot when available; older gateways fall
    /// back to `session.status`. If either reports `running`,
    /// re-create the local in-flight UI state: a streaming assistant placeholder,
    /// the global `isStreaming` flag, the local-turn ownership token (so mutable
    /// actions are disabled), and the Stop target (`activeSessionId`).
    ///
    /// This is deliberately idempotent: a live websocket `message.start` that wins
    /// the race simply means the streaming row already exists, and a superseded
    /// open drops out via the runtime-id guard.
    func reconcileLiveTurnStatus(
        runtimeId: String,
        snapshotRunning: Bool? = nil,
        inflight: SessionInflightTurn? = nil
    ) async {
        guard runtimeId == activeSessionId else { return }
        if let snapshotRunning {
            guard snapshotRunning else { return }
            restoreInflightTurn(inflight)
            return
        }
        guard let fetch = resolvedLiveTurnStatusFetch else { return }
        let status = try? await fetch(runtimeId)
        guard runtimeId == activeSessionId else { return }
        if let usage = status?.usage, !isStreaming {
            applyContextUsage(from: usage)
        }
        guard status?.running == true else { return }
        restoreInflightTurn(nil)
    }

    private func restoreInflightTurn(_ inflight: SessionInflightTurn?) {
        let user = inflight?.user.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !user.isEmpty, !inflightUserPromptAlreadyRestored(user) {
            messages.append(ChatMessage(role: .user, text: user))
            rebuildUserOrdinals()
        }
        beginLocalTurn()
        beginStreamingMessage()
        if let assistant = inflight?.assistant, !assistant.isEmpty {
            mutateStreaming { $0.applyFinalText(assistant) }
        }
    }

    /// True when `user` is already the prompt row that opened the in-flight
    /// streaming turn, so a repeat `reconcileLiveTurnStatus` must not re-append a
    /// duplicate prompt bubble. `reconcileLiveTurnStatus` runs once at open and
    /// again on every reconnect-recovery resume for the same running turn; the
    /// prior guard (`lastUser?.text != user || messages.last?.role != .user`) was
    /// always satisfied once the streaming assistant row trailed the prompt, so
    /// each repeat call appended another copy of the same inflight prompt.
    private func inflightUserPromptAlreadyRestored(_ user: String) -> Bool {
        guard let streamingMessageID,
              let streamIndex = messages.firstIndex(where: { $0.id == streamingMessageID })
        else { return false }
        // Walk back from the streaming assistant row to the prompt that started
        // it; equality there means this exact inflight turn is already restored.
        var index = streamIndex - 1
        while index >= 0, messages[index].role != .user { index -= 1 }
        guard index >= 0 else { return false }
        return messages[index].text == user
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
    }

    private func handleClarifyRequest(_ event: GatewayEvent) {
        let request = ClarifyRequestPayload(payload: event.payload)
        let sessionId = event.sessionId ?? activeSessionId ?? ""
        pendingClarification = PendingClarification(sessionId: sessionId, request: request)
    }

    // MARK: - Wave-2 relay gate bridge (QA-1 B10 / A3)
    //
    // The relay delivers `approval.request` / `clarify.request` as downstream
    // FRAMES (body = the gateway's raw payload dict, passed through verbatim by
    // the reframer). They are NOT items — `RelayItemStore` drops them by design
    // — so without this bridge the Turn Dock's resolver (whose SOLE inputs are
    // `pendingApproval` / `pendingClarification`, set today only by the gateway
    // event router above) resolves `.none` forever on the relay path: no card,
    // nothing tappable (build 114 device QA, B10). Folding the frames into the
    // SAME state makes the relay path render the identical `ApprovalCard` /
    // `ClarifyBanner` in the identical dock — the card views are transport-
    // agnostic once this state is set.

    /// Ids of gates already ANSWERED or expired by a settled turn. Item frames
    /// have per-kind idempotency in `RelayItemStore`, but gates are ONE-SHOT: a
    /// `resync` after a socket flap replays ring frames the phone already dealt
    /// with, and re-folding an answered gate would resurrect a dead card. The
    /// bridge suppresses by id instead. Bounded (drop-all past 256 — replay
    /// windows are short, and a dropped key at worst re-surfaces a card that
    /// the next `turn.completed` clears); `reset()` drops the set with the
    /// session it belongs to.
    private var resolvedRelayGateIDs: Set<String> = []

    /// R1 (contract I12, amendment G1): gates PARK per session. The slots the
    /// views read (``pendingApproval`` / ``pendingClarification``) expose ONLY
    /// the gate owned by the session at the relay write-gate; gates for
    /// background sessions park in these maps and MOVE into the slot when
    /// their session takes the write-gate (``relayWriteGateMoved``) — the
    /// card leaves the screen with its session and re-appears on switch-back.
    /// ONLY turn end (any reason) or an explicit answer expires a gate,
    /// exactly once; a switch MOVES it — there is no expire-on-switch.
    private var parkedRelayApprovals: [String: PendingApproval] = [:]
    private var parkedRelayClarifications: [String: PendingClarification] = [:]
    /// Ids of gates folded in from the relay wire (slot OR parked) — what
    /// distinguishes a relay gate the write-gate MOVES from a direct-path
    /// gate (whose slot lifetime — cleared on `reset()` — is unchanged).
    private var relayOwnedGateIDs: Set<String> = []
    /// The session holding the relay write-gate (contract I2) — set by
    /// ``relayWriteGateMoved(toSession:items:)``. A gate frame folds into the
    /// SLOT only when its `sid` matches; any other sid parks.
    private var relayWriteGateSessionID: String?

    /// I23 (amendment G3): the DURABLE mirror key. The in-memory set is
    /// PROCESS-lifetime (integration: R1 requires suppression to survive
    /// session switches — gates MOVE with their session, so a switch-back
    /// resync must not re-raise an answered gate; the set is seeded from
    /// this record at init). The durable record ADDITIONALLY survives a kill
    /// in ANY session — cold-open suppression of an answered gate is exactly
    /// its purpose. Same 256 bound (drop-all). W2e design call (RED matrix
    /// flip map): phone-side durability instead of relay-side ring
    /// withholding — the store-level oracle cannot observe the relay ring,
    /// and the phone's own record is the local authority regardless.
    private static let resolvedRelayGateIDsDefaultsKey = "relay.resolvedGateIDs.v1"

    private func markRelayGateResolved(_ id: String) {
        guard !id.isEmpty else { return }
        resolvedRelayGateIDs.insert(id)
        relayOwnedGateIDs.remove(id)
        if resolvedRelayGateIDs.count > 256 { resolvedRelayGateIDs.removeAll() }
        if relayOwnedGateIDs.count > 256 { relayOwnedGateIDs.removeAll() }
        UserDefaults.standard.set(
            Array(resolvedRelayGateIDs), forKey: Self.resolvedRelayGateIDsDefaultsKey
        )
    }

    #if DEBUG
    /// DEBUG/test seam: drop the DURABLE resolved-gate record (I23) — contract
    /// suites clear it in teardown so persisted state never leaks across runs.
    static func _debugClearDurableResolvedGates() {
        UserDefaults.standard.removeObject(forKey: resolvedRelayGateIDsDefaultsKey)
    }
    #endif

    /// Relay analogue of `handleApprovalRequest`: fold a decoded
    /// `approval.request` frame into the SAME `pendingApproval` the Turn Dock's
    /// `ApprovalCard` reads. `sessionId` is the frame's `sid` — the responder
    /// answers against THAT session even when the gate was mirrored from a
    /// foreign turn (same semantics as the direct router's `event.sessionId`).
    func applyRelayApprovalRequest(_ frame: RelayFrame) {
        let request = ApprovalRequestPayload(payload: frame.body)
        guard !resolvedRelayGateIDs.contains(request.id) else { return }
        let gate = PendingApproval(id: request.id, sessionId: frame.sid, request: request)
        relayOwnedGateIDs.insert(request.id)
        // I12: the active session's gate takes the slot the views read; a
        // background session's gate PARKS until its session holds the
        // write-gate — never dropped because the session is unfocused.
        if frame.sid == relayWriteGateSessionID || relayWriteGateSessionID == nil {
            pendingApproval = gate
            onApprovalChange?(true)
        } else {
            parkedRelayApprovals[frame.sid] = gate
        }
    }

    /// Relay analogue of `handleClarifyRequest`: fold a decoded
    /// `clarify.request` frame into the SAME `pendingClarification` the dock's
    /// `ClarifyBanner` reads (options tappable + custom answer). The body's
    /// `request_id` is retained on the payload: the answer MUST echo it — the
    /// gateway matches the pending waiter by it (`_respond`, server.py:5059);
    /// a reply without it 4009s and the agent hangs.
    func applyRelayClarifyRequest(_ frame: RelayFrame) {
        let request = ClarifyRequestPayload(payload: frame.body)
        if let rid = request.requestId, resolvedRelayGateIDs.contains(rid) { return }
        let gate = PendingClarification(sessionId: frame.sid, request: request)
        if let rid = request.requestId { relayOwnedGateIDs.insert(rid) }
        if frame.sid == relayWriteGateSessionID || relayWriteGateSessionID == nil {
            pendingClarification = gate
        } else {
            parkedRelayClarifications[frame.sid] = gate
        }
    }

    /// Relay turn-end expiry, PER SESSION (contract I12/I21, amendment G1):
    /// expire the gate owned by `sessionID` — the slot's, when that session
    /// holds the write-gate, or its PARKED copy — and mark its id resolved so
    /// a resync replay cannot resurrect the card. Turn end (ANY reason) or an
    /// explicit answer are the ONLY edges that expire a gate, exactly once —
    /// a switch MOVES it (``relayWriteGateMoved``); there is no
    /// expire-on-switch. A background session's `turn.completed` expires ITS
    /// OWN parked gate and touches nothing on the active session (I1/I2).
    func expireRelayPendingGates(sessionID: String) {
        if let approval = pendingApproval, approval.sessionId == sessionID {
            markRelayGateResolved(approval.id)
            pendingApproval = nil
            onApprovalChange?(false)
        }
        if let parked = parkedRelayApprovals.removeValue(forKey: sessionID) {
            markRelayGateResolved(parked.id)
        }
        if let clarify = pendingClarification, clarify.sessionId == sessionID {
            if let rid = clarify.request.requestId { markRelayGateResolved(rid) }
            pendingClarification = nil
        }
        if let parked = parkedRelayClarifications.removeValue(forKey: sessionID) {
            if let rid = parked.request.requestId { markRelayGateResolved(rid) }
        }
    }

    /// R1 (contract I2, amendment G1): the relay WRITE-GATE moved to
    /// `sessionID` (`nil` = draft — the ABSENCE of a session). Atomically
    /// moves everything the contract moves with the gate:
    ///  (a) GATE MEMBERSHIP — the slot's relay gate parks under its own sid
    ///      and the incoming session's parked gate takes the slot: the card
    ///      LEAVES with its session and RE-APPEARS on switch-back; only turn
    ///      end or an explicit answer expires it (expire-on-switch deletes
    ///      outright — amendment G1);
    ///  (b) LIVE-ACTIVITY OWNERSHIP — the outgoing session's mirrored LA ends
    ///      as a DISCARD (the user stopped watching; its entry keeps folding
    ///      frames — nothing stream-side is torn down);
    ///  (c) PER-TURN TIMER — the outgoing turn's chrome clears;
    ///  (d) PROJECTION — the incoming entry's items repaint (warm, ZERO
    ///      refetch — I14); an empty entry is a no-op: the cache paint owns
    ///      the first frame, never void (QA-1 B4).
    func relayWriteGateMoved(toSession sessionID: String?, items: [ChatItem]) {
        relayWriteGateSessionID = sessionID
        // (a) park the outgoing relay gate / unpark the incoming one.
        if let approval = pendingApproval, relayOwnedGateIDs.contains(approval.id),
           approval.sessionId != sessionID {
            parkedRelayApprovals[approval.sessionId] = approval
            pendingApproval = nil
            onApprovalChange?(false)
        }
        if let clarify = pendingClarification,
           let rid = clarify.request.requestId, relayOwnedGateIDs.contains(rid),
           clarify.sessionId != sessionID {
            parkedRelayClarifications[clarify.sessionId] = clarify
            pendingClarification = nil
        }
        if let sessionID {
            if let parked = parkedRelayApprovals.removeValue(forKey: sessionID) {
                pendingApproval = parked
                onApprovalChange?(true)
            }
            if let parked = parkedRelayClarifications.removeValue(forKey: sessionID) {
                pendingClarification = parked
            }
        }
        // (b)+(c) the outgoing turn's LA ownership + chrome move off (discard).
        if turnStartedAt != nil {
            turnStartedAt = nil
            activeToolName = nil
            onTurnDiscarded?()
        }
        relayTurnLive = false
        resetTurnLivenessState()
        // (d) warm repaint from the incoming entry (empty ⇒ the cache paint
        // owns the first frame — never void, QA-1 B4).
        if !items.isEmpty {
            applyRelayItems(items)
        } else {
            setStreaming(false, reason: "relayWriteGateMoved")
        }
    }

    /// R1 write-through eviction (contract §1.2 / RR4): a settled background
    /// entry persists its transcript BEFORE the coordinator drops it, so the
    /// next open paints from disk (I3: the cache is a seed) and the relay
    /// snapshot reconciles over it (I14).
    func relayEntryEvictedWriteThrough(sessionID: String, items: [ChatItem]) {
        sessions?.persistRelayEntryWriteThrough(sessionID: sessionID, items: items)
    }

    /// R1/I6: a nil-target SUBMIT created the session at the relay — the
    /// draft BECOMES that session atomically. Unlike a switch this is the
    /// SAME user turn adopting its home: NO discard, NO chrome teardown (the
    /// turn chrome stamped at send now belongs to the created session). Only
    /// the write-gate identity moves — projection goes live and any parked
    /// gate for the new sid takes the slot.
    func relayCreatedSessionAdopted(_ sessionID: String) {
        relayWriteGateSessionID = sessionID
        if let parked = parkedRelayApprovals.removeValue(forKey: sessionID) {
            pendingApproval = parked
            onApprovalChange?(true)
        }
        if let parked = parkedRelayClarifications.removeValue(forKey: sessionID) {
            pendingClarification = parked
        }
    }

    /// One ownership decision for live approval/clarify/complete events. APNs is
    /// authoritative after a successful registration for this exact pairing;
    /// otherwise the correlated local request is the explicit fallback.
    private func handleNotificationPolicy(_ event: GatewayEvent) {
        let kind: NotificationService.AlertKind
        let preferenceKey: String
        let title: String
        let body: String
        switch event.type {
        case .approvalRequest:
            let request = ApprovalRequestPayload(payload: event.payload)
            kind = .approval
            preferenceKey = DefaultsKeys.pushEventApproval
            title = request.title
            body = request.descriptionText ?? request.target ?? "Tap to review."
        case .clarifyRequest:
            let request = ClarifyRequestPayload(payload: event.payload)
            kind = .clarify
            preferenceKey = DefaultsKeys.pushEventClarify
            title = "Agent needs input"
            body = request.question
        case .messageComplete:
            kind = .turnComplete
            preferenceKey = DefaultsKeys.pushEventTurnComplete
            title = "Hermes finished"
            let text = event.payload["text"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            body = text?.split(separator: "\n", maxSplits: 1).first.map(String.init)
                ?? "Tap to view the response."
        default:
            return
        }
        guard DefaultsKeys.pushEventEnabled(preferenceKey) else { return }

        let sessionId = event.sessionId ?? ""
        let eventId = event.payload["event_id"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let gatewayScope = event.payload["gateway_scope"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let correlated: NotificationService.CorrelatedAlert?
        if let eventId, !eventId.isEmpty,
           let gatewayScope, !gatewayScope.isEmpty,
           !sessionId.isEmpty {
            correlated = .init(
                kind: kind,
                eventId: eventId,
                gatewayScope: gatewayScope,
                sessionId: sessionId,
                storedSessionId: event.storedSessionId,
                requestId: event.payload["request_id"]?.stringValue
                    ?? event.payload["approval_id"]?.stringValue
                    ?? event.payload["turn_id"]?.stringValue
            )
        } else {
            correlated = nil
        }

        let selectedSession = sessionId == activeSessionId
            || (event.storedSessionId != nil
                && event.storedSessionId == sessions?.activeStoredId)
        #if DEBUG
        let authoritative = pushAlertAuthorityOverride
            ?? PushRegistrar.shared.isAlertAuthorityRegistered
        let deviceScope = notificationDeviceScopeOverride
            ?? PushRegistrar.shared.notificationScope
            ?? connection?.serverURLString
            ?? "unconfigured"
        let foreground = notificationForegroundOverride
            ?? (UIApplication.shared.applicationState == .active)
        #else
        let authoritative = PushRegistrar.shared.isAlertAuthorityRegistered
        let deviceScope = PushRegistrar.shared.notificationScope
            ?? connection?.serverURLString
            ?? "unconfigured"
        let foreground = UIApplication.shared.applicationState == .active
        #endif
        if !authoritative {
            NotificationService.requestAuthorizationIfNeeded()
        }
        NotificationService.handleLiveAlert(
            correlated,
            title: title,
            body: body,
            deviceScope: deviceScope,
            pushIsAuthoritative: authoritative,
            isActiveSession: selectedSession && foreground
        )
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
    private func handleSubagentEvent(type: GatewayEventType, payload rawPayload: JSONValue, sessionId ownerSessionId: String) {
        let payload = SubagentEventPayload(payload: rawPayload)
        let nodeId = subagentNodeId(for: payload)
        let parentId = payload.parentId
        let isNew = subagentNodes[nodeId] == nil

        var node = subagentNodes[nodeId] ?? SubagentNode(
            id: nodeId,
            sessionId: ownerSessionId,
            parentId: parentId,
            depth: payload.depth ?? 0,
            taskIndex: payload.taskIndex ?? 0,
            taskCount: payload.taskCount ?? 1,
            goal: payload.goal ?? "Subagent",
            model: payload.model,
            hasServerSubagentId: (payload.subagentId?.isEmpty == false),
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
        if !ownerSessionId.isEmpty { node.sessionId = ownerSessionId }
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
        subagentInterruptStates = [:]
    }

    // MARK: - Subagent interrupt (STR-145 / ABH-413)

    /// Per-node interrupt state for the Stop button on the subagent tree.
    /// Tracks the in-flight `subagent.interrupt` RPC so the UI shows honest
    /// stopping → stopped / failed transitions instead of a fake "ok".
    enum SubagentInterruptState: Sendable, Equatable {
        /// No interrupt requested (default). The Stop button is tappable.
        case idle
        /// Interrupt RPC in-flight. The Stop button is disabled with a spinner.
        case stopping
        /// The gateway confirmed it found and signalled the subagent. The node
        /// itself transitions to `.error` (status "interrupted") only when the
        /// `subagent.complete` frame arrives — until then the UI shows
        /// "Stopping…". Not a terminal state on its own.
        case stopped
        /// The interrupt RPC failed with a real transport/RPC error (NOT the
        /// benign `found:false` already-finished case — see
        /// `interruptSubagent(nodeId:)`). `message` is user-facing and the
        /// button remains retryable.
        case failed(message: String)
    }

    /// Gateway response shape for `subagent.interrupt` (server.py `_ok(rid,
    /// {"found": ok, "subagent_id": subagent_id})`).
    struct SubagentInterruptResponse: Decodable, Sendable {
        /// Whether the gateway found a live subagent matching `subagent_id`.
        /// `false` means it already finished (or the id was stale) — NOT an
        /// error; the caller must treat it as an idempotent no-op.
        let found: Bool
        let subagentId: String?
    }

    /// Interrupt state per subagent node id. Absent == `.idle`. Read by
    /// `SubagentTreeView` to drive the Stop button. Cleared on
    /// `resetSubagentTree`.
    private(set) var subagentInterruptStates: [String: SubagentInterruptState] = [:]

    #if DEBUG
    /// Injectable hook for tests — replaces the live `subagent.interrupt` RPC.
    /// Pattern mirrors `steerRPC`. `nil` in production (inert).
    var interruptSubagentRPC: ((_ sessionId: String, _ subagentId: String) async throws -> SubagentInterruptResponse)?
    #endif

    /// Whether `nodeId` can currently be targeted by the Stop button: running,
    /// carries a real (non-synthesized) `subagent_id`, and hasn't already been
    /// signalled.
    func isSubagentInterruptible(_ nodeId: String) -> Bool {
        guard let node = subagentNodes[nodeId], node.status == .running,
              node.hasServerSubagentId else { return false }
        return subagentInterruptStates[nodeId] != .stopped
    }

    /// Send `subagent.interrupt` for `nodeId`, targeting the owning runtime
    /// `session_id` (captured on the node when its branch was created — see
    /// `SubagentNode.sessionId`) plus the stable `subagent_id` from the event
    /// stream — never a row index, `task_index`, depth, or other synthesized
    /// display-order value.
    ///
    /// Late-tap / race handling: if the node already left `.running` (the
    /// `subagent.complete` frame beat the tap locally), this is a silent
    /// no-op — no RPC is sent. If the RPC itself resolves `found:false` (the
    /// subagent finished server-side before the tap landed there), this is
    /// ALSO treated as a no-op: the state quietly returns to `.idle` with no
    /// "cancelled" success signal and no error — the eventual/already-arrived
    /// `subagent.complete` frame is what updates the row. Only a genuine
    /// transport/RPC failure sets `.failed` (and `lastError`, matching
    /// `interrupt()` / `steer()`).
    func interruptSubagent(nodeId: String) async {
        guard let node = subagentNodes[nodeId], node.status == .running,
              subagentInterruptStates[nodeId] != .stopping,
              subagentInterruptStates[nodeId] != .stopped else { return }

        guard node.hasServerSubagentId, !node.sessionId.isEmpty, let client else {
            subagentInterruptStates[nodeId] = .failed(message: "This subagent can't be interrupted.")
            return
        }

        subagentInterruptStates[nodeId] = .stopping

        do {
            let response: SubagentInterruptResponse
            #if DEBUG
            if let hook = interruptSubagentRPC {
                response = try await hook(node.sessionId, nodeId)
            } else {
                response = try await client.request(
                    "subagent.interrupt",
                    params: .object([
                        "session_id": .string(node.sessionId),
                        "subagent_id": .string(nodeId),
                    ])
                )
            }
            #else
            response = try await client.request(
                "subagent.interrupt",
                params: .object([
                    "session_id": .string(node.sessionId),
                    "subagent_id": .string(nodeId),
                ])
            )
            #endif

            if response.found {
                subagentInterruptStates[nodeId] = .stopped
            } else {
                // Already finished / stale id server-side — quiet no-op, NOT a
                // failure: don't fake a cancelled toast, don't show an error.
                subagentInterruptStates[nodeId] = .idle
            }
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            subagentInterruptStates[nodeId] = .failed(message: msg)
            lastError = msg
        }
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

    // MARK: - Undo last turn + rollback restore (ABH-412)

    /// Undo the last user+assistant turn, then inspect the existing rollback
    /// checkpoints for file changes. The destructive disk restore is split into
    /// ``confirmPendingRollbackRestore()`` so the UI can show the diff and require
    /// explicit confirmation before `rollback.restore` is sent.
    func undoLastTurn() async {
        guard !localTurnInFlight else {
            lastError = "Agent is busy"
            undoRollbackPhase = .failed
            return
        }
        guard let sessionId = activeSessionId else {
            lastError = "No active session"
            undoRollbackPhase = .failed
            return
        }

        pendingRollbackRestore = nil
        undoRollbackPhase = .loading
        lastError = nil

        do {
            let undo = SessionUndoResult(json: try await undoRollbackRequest(
                "session.undo",
                params: .object(["session_id": .string(sessionId)])
            ))
            guard undo.removed > 0 else {
                undoRollbackPhase = .empty
                return
            }

            // Refresh transcript optimistically after the server accepted the undo.
            await backfill()

            let rollbackList = RollbackListResult(json: try await undoRollbackRequest(
                "rollback.list",
                params: .object(["session_id": .string(sessionId)])
            ))
            guard rollbackList.enabled, let checkpoint = rollbackList.checkpoints.first else {
                undoRollbackPhase = .restored
                return
            }

            let diff = RollbackDiffResult(json: try await undoRollbackRequest(
                "rollback.diff",
                params: .object([
                    "session_id": .string(sessionId),
                    "hash": .string(checkpoint.hash),
                ])
            ))
            pendingRollbackRestore = PendingRollbackRestore(checkpoint: checkpoint, diff: diff)
            undoRollbackPhase = .awaitingConfirmation
        } catch {
            pendingRollbackRestore = nil
            undoRollbackPhase = .failed
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// User cancelled the destructive restore prompt. The turn undo remains in
    /// place; only the pending file rollback is dismissed.
    func cancelPendingRollbackRestore() {
        pendingRollbackRestore = nil
        if undoRollbackPhase == .awaitingConfirmation {
            undoRollbackPhase = .restored
        }
    }

    /// Restore files from the checkpoint currently displayed in the confirmation
    /// sheet. The turn has already been removed by `session.undo`, so each restore
    /// is file-scoped; a full `rollback.restore` would pop another user+assistant
    /// turn from server history.
    func confirmPendingRollbackRestore() async {
        guard !localTurnInFlight else {
            lastError = "Agent is busy"
            undoRollbackPhase = .failed
            return
        }
        guard let sessionId = activeSessionId else {
            lastError = "No active session"
            undoRollbackPhase = .failed
            return
        }
        guard let pending = pendingRollbackRestore else { return }

        undoRollbackPhase = .restoring
        lastError = nil
        do {
            guard !pending.diff.filePaths.isEmpty else {
                throw GatewayError.rpc(code: 5021, message: "rollback.diff did not report restorable file paths")
            }
            for filePath in pending.diff.filePaths {
                let restored = RollbackRestoreResult(json: try await undoRollbackRequest(
                    "rollback.restore",
                    params: .object([
                        "session_id": .string(sessionId),
                        "hash": .string(pending.checkpoint.hash),
                        "file_path": .string(filePath),
                    ])
                ))
                guard restored.success else {
                    throw GatewayError.rpc(code: 5021, message: "rollback.restore did not report success for \(filePath)")
                }
            }
            pendingRollbackRestore = nil
            undoRollbackPhase = .restored
            await backfill()
        } catch {
            undoRollbackPhase = .failed
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func undoRollbackRequest(
        _ method: String,
        params: JSONValue,
        timeout: Duration = .seconds(30)
    ) async throws -> JSONValue {
        if let undoRollbackRPC {
            return try await undoRollbackRPC(method, params, timeout)
        }
        guard let client else { throw GatewayError.notConnected }
        return try await client.requestRaw(method, params: params, timeout: timeout)
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
        lastSendReachedServer = false
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasAttachments = includeAttachments && (attachments?.hasPending ?? false)
        guard !trimmed.isEmpty || hasAttachments else { return false }

        // Wave-2 relay transport: when the relay is the active transport, the
        // gateway-direct `prompt.submit` (below and via the outbox) cannot run —
        // the gateway socket is idle in relay-only mode, so it would throw "Not
        // connected to the Hermes gateway" and strand the deep-link
        // resume-to-send. Submit through the relay coordinator instead; the relay
        // client owns its own reliability spine (seq/ack/resync), and the echoed
        // user item + assistant stream reconcile back through the item
        // projection. Attachments ride the relay too (B9 / A5): queued images
        // upload through the relay `attach` RPC (gateway `image.attach_bytes`,
        // inlined base64 — NO gateway-REST `POST /api/upload`, which a
        // relay-only phone cannot reach) BEFORE the submit, mirroring the
        // direct path's upload-then-submit ordering; an image-only send
        // submits the same default caption as the direct path.
        // OPTIMISTIC USER ECHO (QA-1 B5/B13): render the user's message the
        // instant they commit — WhatsApp bar — instead of waiting on the
        // relay. The relay SUBMIT synthesizes a `userMessage` item
        // (downstream.py) which the projection ADOPTS onto this row in place
        // (by `client_message_id`), so the echo reconciles into the settled
        // timeline without duplication — live, after completion, and across
        // reconnect. `client_message_id` additionally makes an ambiguous-flap
        // retry dedupe into a single turn at the relay. The default gateway
        // path below is byte-identical. Only engaged while the relay socket is
        // actually open.
        if let connection, connection.transportPath == .relay,
           let coordinator = connection.relayCoordinator, coordinator.isOpen {
            // Images-with-no-caption: prompt.submit needs text, so supply the
            // same default the direct path uses. The echo shows the same text
            // the relay item will carry, so adoption never pops the bubble.
            let outgoing = trimmed.isEmpty ? "Please look at the attached image." : trimmed
            let clientMessageID = UUID().uuidString
            // R2 / contract I5 — PIN the submit target at send-intent, sync,
            // before any await: the selected stored id, or nil for a true draft.
            // Re-checked after the submit await (amendment S4) so a mid-await
            // navigation splits deterministically: an EXISTING-session pin whose
            // submit fails converts to a durable queue row against THIS pinned
            // id (never the drifted-to session); a DRAFT/nil pin drops its echo
            // and closes the just-created orphan. There is no fallback to a
            // previously-driven session (the deleted `?? activeSessionID`, D2).
            let pinnedTarget = sessions?.activeStoredId
            sessions?.resetComposerHistoryBrowse(for: sessions?.activeComposerDraftKey)
            let userMessage = ChatMessage(
                role: .user, clientMessageID: clientMessageID, text: outgoing
            )
            userOrdinals[userMessage.id] = messages.lazy.filter { $0.role == .user }.count
            messages.append(userMessage)
            // QA-3 S6/A2 — DURABLE ECHO: the optimistic echo existed only in
            // the in-memory transcript, so a session switch (the transcript
            // reseeds for the other session) or any store rebuild dropped it
            // — the sent prompt vanished from view until the relay's next
            // snapshot re-projected its `userMessage` item (IMG_2585/2591:
            // working rows rendering with NO prompt above them). Persist it
            // into the session-keyed warm snapshot the switch-and-back cache
            // paint reads, so the prompt repaints BEFORE any relay frame
            // lands, and stays until the `userMessage` adoption reconciles it
            // (`markEchoReconciled`). A draft send keys the echo once the
            // relay-created session id lands (below).
            sessions?.persistDurableEcho(
                storedId: sessions?.activeStoredId, echo: userMessage
            )
            // QA-2 R4/A2 — INSTANT WORKING AFFORDANCE: append an optimistic
            // EMPTY streaming assistant bubble the instant the user commits —
            // the breathing caret (`MessageBubble.needsStandaloneCursor`)
            // renders ≤100 ms from send, independent of ANY relay frame (the
            // accepted-and-waiting window before the first item is otherwise
            // blank). It is tagged `relayProjected` so the very first
            // `applyRelayItems` pass replaces it in place — with the SAME id
            // (`relay-assistant-of-<echo>` matches the per-turn re-key in
            // `applyRelayItems`), so SwiftUI morphs the caret bubble into the
            // streaming reply instead of popping the view identity. `relayTurnLive`
            // makes `isStreaming` turn-scoped (see its doc): the stop button and
            // the caret persist for the WHOLE turn, not just between deltas.
            messages.append(ChatMessage(
                id: Self.relayOptimisticAssistantID(forEcho: userMessage.id),
                role: .assistant,
                isStreaming: true,
                relayProjected: true
            ))
            relayTurnLive = true
            // R5: a new send starts a fresh turn — any lingering local-STOP
            // mark belongs to the turn the user just stopped; its frames
            // must not gate THIS turn's stream.
            relayTurnSettling = false
            // QA-3 S8/A4: the driven turn's liveness clock starts at send —
            // silence is measured from here until the first CURRENT-turn frame
            // (the stage-1 silent resync and the stage-2 settle key off it).
            resetTurnLivenessState()
            turnLivenessBaseline = ContinuousClock.now
            if hasAttachments, let attachments {
                setStreaming(true, reason: "relay.send.upload")
                lastError = nil
                do {
                    _ = try await attachments.uploadAndAttach(
                        sessionId: sessions?.activeStoredId, connection: connection
                    )
                } catch {
                    removeLocalEcho(clientMessageID: clientMessageID)
                    abandonRelayTurnAffordance()
                    setStreaming(false, reason: "relay.send.uploadFailed")
                    lastError = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                    return false
                }
            }
            setStreaming(true, reason: "relay.send")
            // QA-2 R12/R13 — a new turn starts clean: drop any task list the
            // PREVIOUS turn left in the relay item store so the dock pill never
            // re-shows a stale list before this turn emits its own `taskList`.
            // `dockShowsTaskBox`'s `isStreaming` gate would hide the stale list
            // anyway, but clearing the owner here is what lets the new turn's
            // first `taskList` frame repopulate from a blank slate (and the
            // pill reads the NEW list, not last turn's).
            relayLatestTaskList = nil
            taskListOwnerSessionId = nil
            // QA-1 B8: stamp the turn start at submit so the pre-first-item
            // inline activity row's elapsed label ticks from the user's send
            // (the direct path stamps in `beginStreamingMessage`; the relay's
            // first rendered item stamps the same way via `applyRelayItems`,
            // but the accepted-and-waiting window before ANY item exists would
            // otherwise read a frozen "0s"). Guarded so a queued-drain re-send
            // keeps the original turn's start. Deliberately NOT the
            // `markTurnStartedIfNeeded()` seam: the Live Activity fires on the
            // first relay item, so a failed submit can never strand it armed.
            if turnStartedAt == nil { turnStartedAt = Date() }
            lastError = nil
            lastSendReachedServer = true
            do {
                let result = try await coordinator.submit(
                    prompt: outgoing,
                    sessionID: pinnedTarget,
                    clientMessageID: clientMessageID
                )
                // R2 / contract I5 + amendment S4 — re-check the PINNED target
                // after the submit await; a mid-await navigation splits.
                let drifted = sessions?.activeStoredId != pinnedTarget
                if let runtimeID = result["session_id"]?.stringValue {
                    let storedID = result["stored_session_id"]?.stringValue ?? runtimeID
                    if drifted, pinnedTarget == nil {
                        // Nil-target (DRAFT) pin, user navigated away mid-create:
                        // the minted session is NOT where they went — drop the
                        // optimistic echo, never redirect, and close the orphan
                        // LOCALLY (no wire close RPC; the relay GCs the empty
                        // session). Nothing is attributed to any session
                        // (desktop submit.ts:262-270; I5/I11 nil-pin branch).
                        removeLocalEcho(clientMessageID: clientMessageID)
                        abandonRelayTurnAffordance()
                        setStreaming(false, reason: "relay.send.driftNilPin")
                        turnStartedAt = nil
                        return true
                    }
                    if pinnedTarget == nil {
                        // Draft create, no drift: the relay MINTED the session —
                        // adopt it atomically (store re-bind + write-gate move +
                        // foreground) so the draft surface becomes a real entry
                        // and the immediately-following send targets the new id
                        // (contract A4/I6).
                        coordinator.adoptCreatedSession(
                            runtimeID: runtimeID, storedID: storedID)
                    }
                    // Land the new-chat bookkeeping (QA-1 B13) AND re-home the
                    // draft's echo onto the created session in the SAME atomic
                    // step (R2 / I8-G4: one identity persisted once at adoption,
                    // never re-keyed by a separate call after the fact). No-op
                    // for an existing session — its echo was keyed at append.
                    await sessions?.landRelayCreatedSession(
                        storedID: storedID, runtimeID: runtimeID, echo: userMessage)
                }
                return true
            } catch {
                // QA-2 R11 (queue-send must NEVER disappear): a failed relay
                // submit — the gateway's 4009 busy reject (the destination
                // session is mid-turn) OR a transport/RPC failure — falls back
                // into the durable outbox for a text-only send, exactly as the
                // direct path queues. The outbox drain is relay-aware
                // (`submitOutboxPrompt` routes through the coordinator, §5a
                // `client_message_id` dedup) and HOLDS the row while its
                // destination session is mid-turn (`busySessionID` gate),
                // draining on turn completion — so a queue-mode send surfaces
                // the outbox PILL immediately and delivers after the turn,
                // instead of the build-115 behavior: echo deleted + error
                // banner + nothing queued ("message DISAPPEARED"). The
                // optimistic immediate-path echo is swapped for the outbox
                // row's echo (distinct `clientMessageID`s — keeping both would
                // double the bubble when the drain presents its row).
                // C3: the queue-and-drain is SILENT — no error banner for what
                // is a self-healing transition. Attachments cannot ride the
                // outbox (its upload stage is gateway-REST-only; relay attach
                // lives on the immediate path above), so those keep the
                // pre-existing echo-removal failure.
                removeLocalEcho(clientMessageID: clientMessageID)
                abandonRelayTurnAffordance()
                setStreaming(false, reason: "relay.sendError")
                turnStartedAt = nil
                // R2 / S4 nil-pin drift: the user abandoned a DRAFT whose submit
                // never reached the relay — drop, never redirect (no orphan was
                // minted, no durable row against a session the user left).
                if sessions?.activeStoredId != pinnedTarget, pinnedTarget == nil {
                    return false
                }
                if !hasAttachments, let queueStore {
                    // Thread the ORIGINAL client message id into the outbox row
                    // (its jobID): if this failure was an AMBIGUOUS transport
                    // loss — the relay may already have driven the turn — the
                    // drain resubmits the same id and the relay's §5a dedup
                    // folds it into one turn (never a double-send).
                    //
                    // R2 / S4 existing-pin branch: enqueue against the PINNED id
                    // captured at intent — NEVER the drifted-to session — so a
                    // send whose target moved mid-pipeline drains once against
                    // its original destination (I11; was `sessions?.activeStoredId`,
                    // which redirected the row to wherever the user navigated).
                    if let queued = await queueStore.enqueue(
                        trimmed,
                        storedSessionId: pinnedTarget,
                        wake: false,
                        clientMessageID: clientMessageID
                    ) {
                        presentOutboxEcho(
                            clientMessageID: queued.clientMessageID,
                            text: queued.text,
                            remotePaths: []
                        )
                        lastError = nil
                        queueStore.wake()
                        return true
                    }
                }
                lastError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                return false
            }
        }

        // Production sends enter the protected repository before session
        // creation, upload, local echo, or prompt.submit. Unit-store graphs that
        // do not install an outbox retain the legacy direct path below.
        if let queueStore {
            let assetInputs = hasAttachments ? (attachments?.draftAssetInputs() ?? []) : []
            guard let queued = await queueStore.enqueue(
                trimmed,
                storedSessionId: sessions?.activeStoredId,
                assets: assetInputs,
                newSession: sessions?.isDraft == true,
                wake: false
            ) else {
                lastError = "Couldn’t save this prompt to the outbox."
                return false
            }
            attachments?.removeAll()
            presentOutboxEcho(
                clientMessageID: queued.clientMessageID,
                text: queued.text,
                remotePaths: []
            )
            lastError = nil
            queueStore.wake()
            return true
        }
        guard let connection, let client else {
            lastError = "No active session"
            return false
        }

        // STR-973A silent reconnect: during grace the transport is down but
        // the user must never see a send error — enqueue to the offline
        // outbox instead, same as a fully-offline send. Attachments aren't
        // supported by the outbox (text-only), so let those fall through to
        // the real (failing) send path below. `isDraining` guards against a
        // `QueueStore.drain()` replay's own `chat.send()` call re-enqueuing
        // itself — drain owns its own re-insert-on-failure semantics and must
        // reach the real RPC attempt.
        if connection.isInGrace, !hasAttachments, connection.queueStore?.isDraining != true {
            _ = await connection.queueStore?.enqueue(trimmed, storedSessionId: sessions?.activeStoredId)
            return true
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
        sessions?.resetComposerHistoryBrowse(for: sessions?.activeComposerDraftKey)
        let userMessage = ChatMessage(role: .user, text: localDisplay)
        userOrdinals[userMessage.id] = messages.lazy.filter { $0.role == .user }.count
        messages.append(userMessage)
        setStreaming(true, reason: "send.localTurn")  // ownership=LOCAL (token already held)
        lastError = nil
        lastSendReachedServer = true
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

    func prepareOutboxSubmission(job: WorkJob, remotePaths: [String]) {
        presentOutboxEcho(
            clientMessageID: job.clientMessageID,
            text: job.submissionText,
            remotePaths: remotePaths
        )
    }

    func submitOutboxPrompt(
        job: WorkJob,
        runtimeSessionID: String,
        remotePaths: [String]
    ) async throws -> OutboxSubmitResult {
        // Wave-2 relay transport: when the flag is `.relay` the gateway `client`
        // is idle, so the durable outbox must drain OVER THE RELAY (§5:
        // `prompt.submit` maps to the relay `submit` RPC into the relay-owned
        // session). The relay item projection owns the transcript + streaming
        // state, so this branch deliberately skips the gateway-style local-turn /
        // streaming bookkeeping — it routes the prompt and maps the RPC result to
        // a receipt. A returned result (no throw) means the relay accepted the
        // prompt → an accepted `queued` receipt marks the job completed (no
        // permanent pending). A transport failure throws, and the outbox retains
        // the row for the next wake so it delivers once the relay reconnects; the
        // job's stable identity keeps that retry from creating a second row.
        // Gated on the coordinator existing first: gateway-direct never allocates
        // it, so that path skips the flag read and stays byte-identical.
        if let coordinator = connection?.relayCoordinator,
           connection?.transportPath == .relay {
            prepareOutboxSubmission(job: job, remotePaths: remotePaths)
            lastSendReachedServer = true
            // R2 / D10: an EMPTY runtime id is a relay new-session row — submit
            // with a NIL target so the relay CREATE-on-nil-SUBMIT mints the
            // session (downstream.py:759-763) instead of the dead gateway
            // `session.create`. Deliberately NOT adopted as the active session —
            // this is a background drain and must not move the write-gate to the
            // minted session; the relay runs the turn there and the user sees it
            // on open. The relay's cmid dedup makes a retry of the same row
            // idempotent (one turn on the minted session).
            let target: String? = runtimeSessionID.isEmpty ? nil : runtimeSessionID
            // Thread the durable row's stable id so an ambiguous-flap retry (the
            // submit threw after the relay already ran `prompt_submit`, so the
            // outbox retains the row and the next wake resubmits the SAME job) is
            // deduped by the relay SUBMIT handler into a single turn — parity with
            // the gateway path's `client_message_id` (see below).
            _ = try await coordinator.submit(
                prompt: job.submissionText,
                sessionID: target,
                clientMessageID: job.clientMessageID
            )
            return OutboxSubmitResult(
                status: "queued",
                accepted: true,
                clientMessageID: job.clientMessageID
            )
        }
        guard let client else { throw GatewayError.notConnected }
        prepareOutboxSubmission(job: job, remotePaths: remotePaths)
        pendingReconnectReconcileID = nil
        beginLocalTurn()
        setStreaming(true, reason: "outbox.submit")
        lastError = nil
        lastSendReachedServer = true
        do {
            let result = try await client.requestRaw(
                "prompt.submit",
                params: .object([
                    "session_id": .string(runtimeSessionID),
                    "text": .string(job.submissionText),
                    "client_message_id": .string(job.clientMessageID),
                ])
            )
            let receipt = OutboxSubmitResult(json: result)
            if !(receipt.accepted && OutboxProcessor.acceptedDispositions.contains(receipt.status)) {
                endLocalTurn()
                setStreaming(false, reason: "outbox.pendingReceipt")
            }
            return receipt
        } catch {
            endLocalTurn()
            setStreaming(false, reason: "outbox.transportError")
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            throw error
        }
    }

    /// Remove the optimistic user echo for a durable outbox row that the user
    /// chose to Delete from its transcript error badge (C1). Correlates by the
    /// shared `clientMessageID`; the QueueStore cancels/deletes the row itself.
    /// A no-op when the echo is already gone (e.g. a late server-seeded replace).
    func removeLocalEcho(clientMessageID: String) {
        guard let index = messages.firstIndex(where: {
            $0.role == .user && $0.clientMessageID == clientMessageID
        }) else { return }
        let removed = messages.remove(at: index)
        userOrdinals[removed.id] = nil
        // QA-3 S6/A2: a deliberately-removed echo (the failed-send delete, or
        // the immediate→outbox swap at 2719/2735) must not resurrect from the
        // durable warm snapshot on the next repaint.
        sessions?.markEchoReconciled(
            storedId: sessions?.activeStoredId,
            clientMessageID: clientMessageID,
            text: removed.text
        )
    }

    /// The stable id of a relay turn's assistant row, derived from the turn's
    /// USER row id — stable across echo adoption (adoption preserves the echo's
    /// id) and across every re-projection, so the optimistic caret bubble the
    /// send appends (`relayOptimisticAssistantID(forEcho:)`) and the real
    /// streaming segment `applyRelayItems` rebuilds share ONE identity: the
    /// caret morphs into the reply in place (no SwiftUI view-identity pop at
    /// the first item, none at settle). QA-2 R4/A2.
    static func relayAssistantID(forUserRowID userRowID: UUID) -> UUID {
        ChatMessage.deterministicID(seedKey: "relay-assistant-of-\(userRowID.uuidString)")
    }

    /// The optimistic empty streaming assistant bubble's id at send time —
    /// derived from the optimistic user ECHO's id, which `adoptRelayEcho`
    /// preserves when the relay's synthesized `userMessage` item lands, so this
    /// equals `relayAssistantID(forUserRowID:)` for the same turn. QA-2 R4/A2.
    static func relayOptimisticAssistantID(forEcho echoID: UUID) -> UUID {
        relayAssistantID(forUserRowID: echoID)
    }

    /// Tear down the optimistic relay-turn affordance on a FAILED send: drop the
    /// empty streaming assistant bubble and un-mark the turn live, so a rejected
    /// submit never strands a breathing caret + stop button over a dead turn.
    /// QA-2 R4/A2 (mirror of the direct path's failed-send cleanup).
    private func abandonRelayTurnAffordance() {
        relayTurnLive = false
        messages.removeAll {
            $0.role == .assistant && $0.relayProjected && $0.parts.isEmpty
        }
    }

    /// QA-2 R8 / N3 — append the user's clarify answer as a local user row.
    /// See `respondClarification`. The echo is NOT outbox-tracked (no
    /// `clientMessageID`): the answer is delivered by the gate RPC, not the
    /// durable submit path, so there is nothing to retry/cancel. Untagged +
    /// non-relay-projected so `applyRelayItems` preserves it across live
    /// projections and the direct-path reconcile never evicts a fresh row.
    private func appendClarifyAnswerEcho(_ answer: String) {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let message = ChatMessage(role: .user, text: trimmed)
        userOrdinals[message.id] = messages.lazy.filter { $0.role == .user }.count
        messages.append(message)
    }

    private func presentOutboxEcho(
        clientMessageID: String,
        text: String,
        remotePaths: [String]
    ) {
        let display = Self.localSentImageDisplayText(
            outgoing: text,
            uploadedImagePaths: remotePaths
        )
        if let index = messages.firstIndex(where: { $0.clientMessageID == clientMessageID }) {
            let existing = messages[index]
            guard existing.text != display else { return }
            messages[index] = ChatMessage(
                id: existing.id,
                role: .user,
                clientMessageID: clientMessageID,
                text: display,
                timestamp: existing.timestamp,
                presentation: existing.presentation
            )
            return
        }
        sessions?.resetComposerHistoryBrowse(for: sessions?.activeComposerDraftKey)
        let userMessage = ChatMessage(
            role: .user,
            clientMessageID: clientMessageID,
            text: display
        )
        userOrdinals[userMessage.id] = messages.lazy.filter { $0.role == .user }.count
        messages.append(userMessage)
        // QA-3 S6/A2: the outbox echo is the user's ONLY record of a queued
        // prompt (its turn may not run for a while — the relay HOLDS the row
        // while the destination session is mid-turn) — make it durable across
        // a session switch / store rebuild exactly like the immediate-path
        // echo. The durable outbox ROW survives regardless; this keeps the
        // PROMPT rendered until the relay `userMessage` adoption reconciles.
        sessions?.persistDurableEcho(
            storedId: sessions?.activeStoredId, echo: userMessage
        )
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
        // Wave-2 relay transport (QA-2 R11): the gateway `client` is idle in
        // relay mode, so stop OVER THE RELAY — `coordinator.interrupt` targets
        // the driven session (the relay owns the running turn; `interruptTarget`
        // is threaded for an adopted foreign mirror exactly as the direct path
        // does, defaulting to the coordinator's driven session when nil). This
        // mirrors the QA-1 B10 relay-aware approve/clarify pattern — interrupt
        // was the control RPC B10 missed, so every stop attempt in relay mode
        // threw "Not connected to the Hermes gateway" off the idle direct
        // socket (the build-115 R11 banner + the never-stopping turn that
        // wedged the dock). The default gateway path stays byte-identical.
        if let connection, connection.transportPath == .relay {
            guard let coordinator = connection.relayCoordinator else {
                lastError = "Relay not connected"
                return
            }
            // R5 (contract B1/I9): LOCAL SETTLEMENT FIRST — the UI settles the
            // instant the tap lands; the interrupt RPC goes out second. The
            // settling mark gates this turn's late frames to no-ops and (pre-L3
            // compat) distinguishes the stop on a reason-less `turn.completed`.
            settleLocalStopFirst()
            do {
                _ = try await coordinator.interrupt(interruptTarget)
            } catch {
                lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            return
        }
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

    /// R5 (contract B1/I9): local STOP settlement FIRST — the UI settles the
    /// INSTANT the tap lands, before the interrupt RPC leaves: mark the turn
    /// settling (the coordinator gates this turn's late frames to no-ops),
    /// finalize the partial text (keep a non-empty streaming row, drop the
    /// empty optimistic caret bubble), and clear the busy/stop affordance.
    /// The authoritative `turn.completed{reason:interrupted}` settles the
    /// entry afterwards (Live Activity end, queue HOLD — the L3 wire-truth
    /// split); until then this mark + the settling state carry the stop.
    private func settleLocalStopFirst() {
        guard isStreaming || relayTurnLive else { return }
        relayTurnSettling = true
        relayTurnLive = false
        // Finalize the partial text in place: a non-empty streaming row keeps
        // its content and freezes; the empty optimistic caret bubble drops
        // (nothing to keep — B1 "keep non-empty, drop empty caret").
        var index = messages.count - 1
        while index >= 0 {
            if messages[index].relayProjected,
               messages[index].role == .assistant,
               messages[index].isStreaming {
                if messages[index].parts.isEmpty {
                    messages.remove(at: index)
                } else {
                    messages[index].isStreaming = false
                }
            }
            index -= 1
        }
        streamingMessageID = nil
        setStreaming(false, reason: "interrupt.localSettle")
    }

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
        // Wave-2 relay transport (QA-2 R11): steer OVER THE RELAY — the gateway
        // `client` is idle in relay mode, so the direct `session.steer` RPC
        // threw "Not connected to the Hermes gateway" on every attempt (and the
        // relay protocol had NO steer method at all — added in §5b: upstream
        // `steer` → gateway `session.steer`). The relay passes the gateway's
        // disposition through VERBATIM, so the status mapping below is
        // identical to the direct path. Routing follows `interrupt()` exactly
        // (`interruptTarget`).
        if let connection, connection.transportPath == .relay {
            guard let coordinator = connection.relayCoordinator else {
                return .error("Relay not connected")
            }
            do {
                let result = try await coordinator.steer(
                    sessionID: interruptTarget, text: trimmed
                )
                switch result["status"]?.stringValue {
                case "queued":   return .queued
                case "rejected": return .rejected
                default:
                    // Defensive parity with the direct path: an unknown status
                    // is a soft rejection — the user keeps their text.
                    return .rejected
                }
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                lastError = msg
                return .error(msg)
            }
        }
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
        // Wave-2 relay transport (QA-1 B10): the gateway `client` is idle in
        // relay mode, so answer OVER THE RELAY — `coordinator.approve` builds
        // the ratified §5 wire shape (`session_id` + `decision` [+ `request_id`
        // / `all`]; the relay maps decision→the gateway's `choice`). Same
        // optimistic clear as the direct path below; the relay resolves the
        // gate by session, so a nil/empty `approvalSession` falls back to the
        // coordinator's driven session exactly as `respondApproval` does to
        // `activeSessionId`. The default gateway path stays byte-identical.
        if let connection, connection.transportPath == .relay {
            let requestId = pendingApproval?.id ?? ""
            pendingApproval = nil
            onApprovalChange?(false)
            markRelayGateResolved(requestId)
            guard let coordinator = connection.relayCoordinator else {
                lastError = "Relay not connected"
                return
            }
            do {
                _ = try await coordinator.approve(
                    sessionID: approvalSession?.isEmpty == false ? approvalSession : nil,
                    requestID: requestId,
                    decision: approve ? "approve" : "deny",
                    resolveAll: all
                )
            } catch {
                lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            return
        }
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
        // QA-2 R8 / N3: echo the user's answer as a local user row BEFORE the
        // card clears, so the transcript shows what the user picked. The
        // pre-QA-2 path cleared the card + emitted the RPC but appended nothing
        // — on the relay path no `userMessage` item is synthesized for clarify
        // answers (only prompts), so the card vanished with no answer bubble
        // (IMG_2535/2540, docs/qa2-root-causes.md N3). Mirrored on BOTH
        // transports (relay + direct): an untagged local user row is preserved
        // by `applyRelayItems` (relayProjected=false, no consumed echo id), and
        // the direct path's reconcile never evicts a fresh user row. Guarded on
        // `pending != nil` so a re-entrant call after the card cleared (the
        // view's isResponding guard is best-effort) cannot duplicate the row.
        if pending != nil {
            appendClarifyAnswerEcho(answer)
            // The card is consumed the moment the user answers — clear it here
            // on EVERY path, not only inside the transport branches (qa2 fix
            // round: both branches already cleared before their RPC, so wired
            // behavior is unchanged; the unwired/unit path previously left the
            // card up forever and re-entry re-echoed — ClarifyCardNativeTests
            // testRespondClarificationEchoesAnswerAsUserMessage /
            // EchoIsSingleRowEvenIfCalledTwice).
            pendingClarification = nil
        }
        // Wave-2 relay transport (QA-1 B10): answer OVER THE RELAY —
        // `coordinator.clarify` builds the §5 shape (`session_id` + `text` +
        // `request_id`; the relay maps text→the gateway's `answer`). The
        // `request_id` echo is REQUIRED: the gateway matches the pending
        // waiter by it — without it the reply 4009s and the agent hangs.
        if let connection, connection.transportPath == .relay {
            if let rid = pending?.request.requestId { markRelayGateResolved(rid) }
            guard let coordinator = connection.relayCoordinator else {
                lastError = "Relay not connected"
                return
            }
            do {
                _ = try await coordinator.clarify(
                    sessionID: clarifySession?.isEmpty == false ? clarifySession : nil,
                    requestID: pending?.request.requestId ?? "",
                    response: answer
                )
            } catch {
                lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            return
        }
        guard let client,
              let sessionId = (clarifySession?.isEmpty == false ? clarifySession : activeSessionId)
        else { return }
        // (pendingClarification already cleared at the echo site above.)
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

    /// QA-1 B4: `true` once an authoritative seed landed ZERO rows for the
    /// open session — an HONEST empty transcript (a session with no messages
    /// yet). Distinguishes that legitimate state from a mid-open wipe, which
    /// the placeholder must render as the skeleton — never blank. `reset()`
    /// clears it (a fresh open is unconfirmed until its seed lands); a
    /// non-empty seed or relay projection clears it; an EMPTY authoritative
    /// seed sets it.
    private(set) var transcriptConfirmedEmpty = false

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

    /// DEBUG-ONLY: drive the REAL streaming reasoning path with a synthesized
    /// `reasoning.delta` frame, exactly as a WS reasoning delta would. It carries
    /// no `session_id`, so `ownership(of:)` classifies it `.local` and it flows
    /// through `handle(event:)` → `thinkingBuffer` → `scheduleFlush` →
    /// `flushBuffers` → `appendReasoningDelta` — the same coalesced render path a
    /// live reasoning stream exercises. Used by the `thinking` UITestSeed mode to
    /// render the live thinking block (pulsing label + inline timer + tail-scrolled
    /// faded body) for sim-scoped evidence without a live gateway.
    func debugInjectReasoningDelta(_ text: String) {
        guard let event = GatewayEvent(params: .object([
            "type": .string("reasoning.delta"),
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

    /// Whether a transcript seed REPLACES the merged timeline or UNIONs onto it
    /// (QA-2 R15 — the stuck-episode segment drop).
    ///
    ///  - ``replace``: `incoming` is the SOLE truth — existing rows it does not
    ///    carry are removed. Used by SESSION-OPEN paints (a cache/REST seed for
    ///    a DIFFERENT session must evict the previous session's rows — that is
    ///    the session isolation the cache-first open relies on, since a
    ///    cache-HIT open seeds WITHOUT a preceding `reset()`), and by every
    ///    caller that does not name a policy.
    ///  - ``union``: `incoming` is a KNOWN-PARTIAL snapshot. Every reseed source
    ///    on this tree serves a recent-TAIL window — relay history honors
    ///    `limit` with `messages[-limit:]` (`relay/hermes_relay/downstream.py`),
    ///    plugin REST serves the 50-row tail — and the relay's per-session
    ///    store holds only what it observed since process start. A union reseed
    ///    UPDATES the rows the snapshot carries IN PLACE and APPENDS genuinely
    ///    new ones, but NEVER evicts settled history the snapshot merely does
    ///    not cover: the merged view shows at least the settled history it held
    ///    before the reseed (spec R15/A8 invariant — "the cache still had it").
    ///    Only SAME-SESSION reseeds pass `.union` (`backfill()` and the
    ///    phase-2/hydrate/chain-tip network reconciles in `SessionStore`) —
    ///    every one guarded on the active session identity, so a union can
    ///    never bleed across sessions. A genuinely server-deleted row still
    ///    clears on the next full open (the session-open seed replaces).
    enum ReseedPolicy: Sendable {
        case replace
        case union
    }

    func seed(from stored: [StoredMessage], policy: ReseedPolicy = .replace) {
        // ARCH37 STEP 2 — normalize on the CURRENT actor (main here, for the
        // synchronous/foreign-mirror callers) then apply. The off-main open/backfill
        // path instead pre-normalizes on its fetch Task and calls `seed(normalized:)`
        // directly (one main-actor hop for the assignment only). Both routes funnel
        // through `seed(normalized:)` so the foreign-mirror bail + in-place reconcile
        // semantics are identical regardless of where the normalize ran.
        seed(normalized: Self.toChatMessages(stored), policy: policy)
    }

    /// Apply an ALREADY-NORMALIZED seed (`toChatMessages` output) onto the
    /// transcript. The pure `toChatMessages` transform may have run OFF the main
    /// actor (ARCH37 Step 2 — the off-main open/backfill path), so this method is the
    /// single MAIN-ACTOR hop that mutates `messages`: the foreign-mirror bail, the
    /// in-place reconcile, the ordinal rebuild, and the `transcriptGeneration` bump.
    func seed(normalized: [ChatMessage], policy: ReseedPolicy = .replace) {
        // A slow REST seed must never wipe a LIVE adopted foreign mirror
        // (R1 #61): open() the session another client is driving, the foreign
        // `message.start` adopts mid-fetch, then the stale seed lands here and
        // `cancelStreaming()` would tear the mirror down mid-turn (truncated
        // reply, corrupted re-adoption). Bail instead — the mirror is already
        // rendering live, and its `message.complete` runs the authoritative
        // teardown + backfill reconcile (which clears the flag before seeding).
        guard !streamingIsForeign else { return }
        cancelStreaming()
        // QA-1 B4: an authoritative seed is the confirmation of what the open
        // session actually contains — zero rows IS the (honest) transcript.
        // A UNION reseed is a KNOWN-PARTIAL snapshot (R15): an empty one proves
        // nothing about the session — never let it confirm emptiness over a
        // painted transcript (the placeholder chain must stay honest).
        if policy == .replace {
            transcriptConfirmedEmpty = normalized.isEmpty
        }
        // IN-PLACE RECONCILE (contract Batch E §3.7, fixes D9): merge the new
        // seed onto the existing transcript by identity instead of a wholesale
        // `messages = …` replace. A wholesale replace remounts every row (new
        // SwiftUI identity) and — for a foreign-mirror reconcile — first removes
        // the placeholder (`teardownForeignStream`) then re-adds the finalized
        // reply from REST, so the mirrored reply BLINKS OUT and pops back
        // restacked. The merge keeps identity for rows whose deterministic ids
        // match across reseeds (no restack), and adopts the foreign placeholder's
        // slot for the reconciled trailing reply (no blink, no count churn).
        reconcileMessages(with: normalized, policy: policy)
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
    ///
    /// ABH-401 CONFLICT GUARD: also bails while a `loadTranscriptAround` jump fetch
    /// is in flight (`isLoadingJumpTarget`). Both methods build their prepended
    /// seed from a synchronous snapshot of `messages` taken before their async
    /// fetch resolves; if the two ran concurrently the loser's `seed(normalized:)`
    /// would be built from a now-stale snapshot and silently drop whatever the
    /// winner just prepended (a lost update — not just a redundant fetch). Mutual
    /// exclusion between the two async prepend paths prevents that clobber.
    func loadEarlierTranscript() async {
        guard !isStreaming,
              !isLoadingEarlierTranscript,
              !isLoadingJumpTarget,
              transcriptHasMoreBefore,
              let storedId = sessions?.activeStoredId,
              let before = oldestLoadedTranscriptWireId,
              let fetch = resolvedTranscriptPageFetch else { return }
        isLoadingEarlierTranscript = true
        defer { isLoadingEarlierTranscript = false }
        guard let page = await fetch(storedId, Self.transcriptOpenWindowLimit, before) else { return }
        if !page.messages.isEmpty {
            let older = Self.toChatMessages(page.messages)
            seed(normalized: older + messages)
        }
        noteTranscriptPaging(oldestId: page.oldestId, hasMoreBefore: page.hasMoreBefore)
    }

    /// Whether the jump resolver may try the server's target-centered page. Also
    /// false while a `loadEarlierTranscript` backward-page fetch is in flight
    /// (ABH-401 conflict guard) — `loadTranscriptAround` would bail on that same
    /// condition, so checking it here avoids ChatView burning an attempt-cap slot
    /// on a call already known to fail.
    func canFetchJumpTarget(messageId: Int) -> Bool {
        !isLoadingJumpTarget && !isLoadingEarlierTranscript
            && !jumpWindowFetchAttemptedMessageIds.contains(messageId)
    }

    /// Fetch a radius window around a jump target and prepend it to the loaded tail.
    /// Returns true when the server returned a page containing the target wire id.
    ///
    /// ABH-401 CONFLICT GUARD: also bails while a `loadEarlierTranscript` backward
    /// page fetch is in flight (`isLoadingEarlierTranscript`) — see that method's
    /// doc for why the two async prepend paths must be mutually exclusive.
    func loadTranscriptAround(messageId: Int, radius: Int = ChatStore.transcriptOpenWindowLimit) async -> Bool {
        guard !isStreaming, !isLoadingJumpTarget, !isLoadingEarlierTranscript,
              let storedId = sessions?.activeStoredId,
              let fetch = resolvedTranscriptAroundFetch else { return false }
        jumpWindowFetchAttemptedMessageIds.insert(messageId)
        isLoadingJumpTarget = true
        jumpTargetLoadError = nil
        defer { isLoadingJumpTarget = false }

        guard let page = await fetch(storedId, messageId, radius) else {
            jumpTargetLoadError = "Couldn’t load earlier messages."
            return false
        }
        guard page.containsTarget, !page.messages.isEmpty else {
            jumpTargetLoadError = "That earlier message is no longer available."
            return false
        }

        let around = Self.toChatMessages(page.messages)
        let aroundIds = Set(around.map(\.id))
        seed(normalized: around + messages.filter { !aroundIds.contains($0.id) })
        noteTranscriptPaging(oldestId: page.oldestId, hasMoreBefore: page.hasMoreBefore)
        jumpTargetLoadError = nil
        return true
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
    ///     inserted in wire order.
    ///
    /// POLICY (QA-2 R15 — the stuck-episode segment drop):
    ///  - ``ReseedPolicy/replace`` (default): existing rows absent from
    ///    `incoming` are REMOVED — the final array is byte-identical in content
    ///    to `incoming` (so every existing test that asserts
    ///    `messages.map(\.text)` after a reconcile still holds).
    ///  - ``ReseedPolicy/union``: `incoming` is a KNOWN-PARTIAL snapshot (the
    ///    relay's tail-window history / item store observed since process
    ///    start). Matched rows still update in place and genuinely-new rows
    ///    still insert — but untagged existing rows the snapshot does NOT carry
    ///    are RETAINED in their existing position, never evicted: the merged
    ///    view shows at least the settled history it held before the reseed
    ///    (spec R15/A8 invariant). The one exception is `relayProjected` rows:
    ///    the live relay projection re-renders any still-live item from the
    ///    item store on the next frame (`applyRelayItems`), so a reseed
    ///    supersedes the stale projection exactly as it did pre-union. A user
    ///    row the snapshot carries under a wire id the optimistic echo's
    ///    runtime id never matches ADOPTS the echo's slot (mirror of
    ///    `adoptRelayEcho`) so the two converge into one bubble.
    private func reconcileMessages(with incoming: [ChatMessage], policy: ReseedPolicy = .replace) {
        let placeholderID = pendingForeignReconcileID
        // A replace consumes the marker (unmatched rows are evicted anyway); a
        // union RETAINS it when unconsumed — the retained placeholder row keeps
        // its adoption slot for a later seed, parity with ABH-278 below.
        if policy == .replace { pendingForeignReconcileID = nil }
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

        // PASS 1 — fold `incoming` into content-updated rows keyed by their
        // FINAL id (the existing row's id for matched/adopted rows, the
        // incoming row's own id for genuinely-new rows), in incoming order.
        var updatedByID: [UUID: ChatMessage] = [:]
        var incomingOrder: [UUID] = []
        var consumedIDs: Set<UUID> = []   // existing ids consumed by an adoption

        for newMessage in incoming {
            if var existing = existingByID[newMessage.id] {
                // Same identity across reseeds — keep the slot, update content in
                // place so SwiftUI diffs the parts rather than remounting the row.
                existing.parts = newMessage.parts
                existing.isStreaming = newMessage.isStreaming
                existing.timestamp = newMessage.timestamp
                existing.presentation = newMessage.presentation
                updatedByID[existing.id] = existing
                incomingOrder.append(existing.id)
            } else if !placeholderConsumed,
                      let placeholder = placeholderRow,
                      newMessage.role == .assistant,
                      placeholder.role == .assistant {
                // The reconciled foreign reply adopts the in-flight placeholder's
                // identity + slot (no blink, no restack). Build a new value with
                // the placeholder's id so the row updates in place.
                placeholderConsumed = true
                pendingForeignReconcileID = nil
                consumedIDs.insert(placeholder.id)
                let adopted = ChatMessage(
                    id: placeholder.id,
                    role: newMessage.role,
                    parts: newMessage.parts,
                    isStreaming: newMessage.isStreaming,
                    timestamp: newMessage.timestamp,
                    presentation: newMessage.presentation
                )
                updatedByID[placeholder.id] = adopted
                incomingOrder.append(placeholder.id)
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
                consumedIDs.insert(reconnect.id)
                let adopted = ChatMessage(
                    id: reconnect.id,
                    role: newMessage.role,
                    parts: newMessage.parts,
                    isStreaming: newMessage.isStreaming,
                    timestamp: newMessage.timestamp,
                    presentation: newMessage.presentation
                )
                updatedByID[reconnect.id] = adopted
                incomingOrder.append(reconnect.id)
            } else if policy == .union, newMessage.role == .user,
                      let echo = unionEchoAdoptionTarget(for: newMessage, skipping: consumedIDs) {
                // R15 union: the snapshot carries the user's own prompt under a
                // gateway wire id the optimistic echo's runtime id (or the relay
                // projection's `relay-user-…` id) never matches. Absent adoption
                // the union would RETAIN the echo beside its authoritative twin —
                // a duplicate bubble. Fold the snapshot row onto the echo's slot
                // instead (mirror of `adoptRelayEcho`), keeping the echo's
                // identity + `clientMessageID` + timestamp so the relay
                // `userMessage` adoption chain stays intact.
                consumedIDs.insert(echo.id)
                let adopted = ChatMessage(
                    id: echo.id,
                    role: newMessage.role,
                    clientMessageID: echo.clientMessageID,
                    parts: newMessage.parts,
                    isStreaming: newMessage.isStreaming,
                    timestamp: echo.timestamp,
                    presentation: newMessage.presentation
                )
                updatedByID[echo.id] = adopted
                incomingOrder.append(echo.id)
            } else {
                // Genuinely-new row.
                updatedByID[newMessage.id] = newMessage
                incomingOrder.append(newMessage.id)
            }
        }

        if policy == .replace {
            var rebuilt: [ChatMessage] = []
            rebuilt.reserveCapacity(incomingOrder.count + 1)
            for id in incomingOrder {
                if let row = updatedByID[id] { rebuilt.append(row) }
            }
            if !reconnectConsumed,
               let reconnect = reconnectRow,
               !rebuilt.contains(where: { $0.id == reconnect.id }) {
                // ABH-278: REST can be a moment behind the resumed turn. Preserve
                // the interrupted local row instead of evicting the in-flight
                // reply / warning just because the backfill snapshot does not
                // include it yet. Keep `pendingReconnectReconcileID` armed so a
                // later seed containing the final assistant row can still adopt
                // this identity.
                rebuilt.append(reconnect)
            } else if reconnectID != nil, reconnectRow == nil {
                pendingReconnectReconcileID = nil
            }
            messages = rebuilt
            return
        }

        // UNION (QA-2 R15): the snapshot is known-partial — walk the EXISTING
        // transcript as the spine: matched/adopted ids emit the updated row,
        // untagged rows the snapshot does not cover are RETAINED in place (the
        // settled history the cache still holds), and `relayProjected` rows the
        // snapshot does not cover are superseded (the relay projection re-renders
        // any still-live item on the next frame). Genuinely-new snapshot rows
        // slot in right after the newest matched row (they are the fresh tail —
        // e.g. a turn that settled on the gateway mid-flap) or append when
        // nothing matched.
        var rebuilt: [ChatMessage] = []
        rebuilt.reserveCapacity(messages.count + incomingOrder.count)
        var emittedIncoming: Set<UUID> = []
        for existing in messages {
            if let updated = updatedByID[existing.id] {
                rebuilt.append(updated)
                emittedIncoming.insert(existing.id)
            } else if !existing.relayProjected {
                // Retained: the partial snapshot does not cover this settled row.
                rebuilt.append(existing)
            }
        }
        // Splice genuinely-new snapshot rows at their WIRE position relative to
        // the matched rows: a run BEFORE the first matched row belongs BEFORE
        // the first matched row's slot (it precedes it on the wire — e.g. the
        // user-prompt row a snapshot carries ahead of the adopted interrupted
        // reply); a run after a matched row lands right after that row's slot.
        // A bare append would invert a new prompt behind its own reply.
        var newBeforeFirstMatch: [ChatMessage] = []
        var runsAfterMatch: [UUID: [ChatMessage]] = [:]
        var lastMatchedID: UUID?
        for id in incomingOrder {
            if emittedIncoming.contains(id) {
                lastMatchedID = id
            } else if let row = updatedByID[id] {
                if let anchor = lastMatchedID {
                    runsAfterMatch[anchor, default: []].append(row)
                } else {
                    newBeforeFirstMatch.append(row)
                }
            }
        }
        var assembled: [ChatMessage] = []
        assembled.reserveCapacity(rebuilt.count + newBeforeFirstMatch.count)
        var prependedLeading = false
        for row in rebuilt {
            if !prependedLeading, emittedIncoming.contains(row.id) {
                assembled.append(contentsOf: newBeforeFirstMatch)
                prependedLeading = true
            }
            assembled.append(row)
            if let run = runsAfterMatch[row.id] {
                assembled.append(contentsOf: run)
            }
        }
        if !prependedLeading {
            assembled.append(contentsOf: newBeforeFirstMatch)
        }
        rebuilt = assembled
        if reconnectID != nil, reconnectRow == nil {
            pendingReconnectReconcileID = nil
        }
        // ABH-278 + foreign placeholder: under a union an unconsumed marker row
        // is RETAINED by the spine above; both markers stay ARMED so a later
        // seed carrying the authoritative row can still adopt its identity.
        messages = rebuilt
    }

    /// The existing user row a UNION reseed's user row adopts onto (QA-2 R15) —
    /// the optimistic echo (or the relay-projected prompt row) for the SAME
    /// prompt, whose runtime / relay id the gateway wire id never matches.
    /// Mirrors `adoptRelayEcho`'s precedence: untagged rows first (the echo
    /// with a `clientMessageID`, then any untagged same-text row), then a
    /// tagged relay projection as the fallback. Text match is exact and
    /// non-empty; `skipping` excludes ids an earlier incoming row already
    /// adopted so N identical prompts pair up one-to-one.
    private func unionEchoAdoptionTarget(
        for incoming: ChatMessage, skipping: Set<UUID>
    ) -> ChatMessage? {
        let text = incoming.text
        guard !text.isEmpty else { return nil }
        func matches(_ message: ChatMessage) -> Bool {
            message.role == .user && !skipping.contains(message.id) && message.text == text
        }
        return messages.first(where: { matches($0) && !$0.relayProjected && $0.clientMessageID != nil })
            ?? messages.first(where: { matches($0) && !$0.relayProjected })
            ?? messages.first(where: { matches($0) })
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
            let fullDiff = InlineFileDiff.isFileEditTool(name) ? InlineFileDiff.extract(from: row.content) : nil
            func matches(_ activity: ToolActivity) -> Bool {
                if let callId { return activity.id == callId }
                return activity.name == name
            }
            // Pending buffer first.
            if let i = pendingTools.firstIndex(where: matches) {
                pendingTools[i].resultPreview = preview
                pendingTools[i].state = failed ? .failed : .done
                pendingTools[i].todos = row.content["todos"]?.arrayValue
                pendingTools[i].fullDiff = fullDiff
                return true
            }
            // Emitted assistant messages, newest first.
            for mi in result.indices.reversed() where result[mi].role == .assistant {
                if result[mi].mergeSeedToolResult(
                    matching: callId, name: name, preview: preview, failed: failed,
                    todos: row.content["todos"]?.arrayValue,
                    fullDiff: fullDiff
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
                let unmatchedName = row.toolName ?? "tool"
                var activity = ToolActivity(
                    id: row.toolCallId ?? "stored-tool-\(index)",
                    name: unmatchedName,
                    argsSummary: "",
                    progressText: "",
                    resultPreview: String(row.text.prefix(300)),
                    state: .done,
                    durationMs: nil,
                    todos: row.content["todos"]?.arrayValue
                )
                if InlineFileDiff.isFileEditTool(unmatchedName) {
                    activity.fullDiff = InlineFileDiff.extract(from: row.content)
                }
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
                id: ChatMessage.deterministicID(seedKey: baseID), role: role,
                // R4b (I5 write-local-first / I8): a write-local-first cache row
                // carries the send's cmid — thread it onto the painted row so the
                // relay `userMessage` item (same cmid) adopts it IN PLACE after a
                // force-close→reopen paint, instead of projecting a twin bubble.
                clientMessageID: row.clientMessageID, parts: rowParts,
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
                            state: tool.state, durationMs: tool.durationMs, todos: tool.todos,
                            fullDiff: tool.fullDiff, resultSummary: tool.resultSummary
                        )
                    }
                    // The cluster id is the first tool's id; re-derive after de-dup.
                    let clusterID = uniquePartID(newTools.first?.id ?? id)
                    if toolsChanged || clusterID != id { changed = true }
                    return .tools(id: clusterID, tools: newTools, collapsed: collapsed, turnElapsed: elapsed)
                case .item(let id, let item):
                    // Wave-2 item-backed part: its identity is the stable relay
                    // `item_id`, unique by construction, so the de-dup pass leaves
                    // it verbatim. (The live store does not emit `.item` today;
                    // this arm keeps the exhaustive switch total.)
                    return .item(id: uniquePartID(id), item: item)
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
        // R3 (ROUND-4 W2d): on relay the STREAM is the authority — the
        // foreground/reconnect reconcile is a relay-LOCAL `resync{last_seq}`
        // (seq watermark; the coordinator owns it), never a transcript
        // refetch (contract I14/A11). This turns the backfill() storm triggers
        // (foreground, reconnect, watchdog) into a silent resync on relay and
        // deletes the relay `history` RPC they used to fire. The REST backfill
        // below is direct-mode recovery, unchanged until Wave 4 folds the fork
        // (amendment S1).
        if connection?.transportPath == .relay {
            guard !isStreaming else { return }
            await connection?.relayCoordinator?.requestLivenessResync()
            return
        }
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
            // QA-2 R15: a recovery reseed is a KNOWN-PARTIAL snapshot (relay
            // history tail window / plugin 50-row tail) — union it onto the
            // merged timeline so settled history the snapshot does not cover
            // survives (the stuck-episode segment drop). Same-session guard
            // above keeps the union from ever bleeding across sessions.
            seed(from: stored, policy: .union)
            noteTranscriptSeedWindow(stored)
            // P3 write-through: the foreground/reconnect reconcile re-fetched the
            // authoritative transcript — persist it so the next open paints from
            // disk. Fire-and-forget, OFF the UI path; CacheStore no-ops for cron
            // sessions (never transcript-cached, per the decided scope).
            if let cacheStore {
                if let identity = sessions?.cacheIdentity(storedId) {
                    Task { try? await cacheStore.saveTranscript(identity: identity, messages: stored) }
                }
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

    /// The injected target-centered jump fetch, or the plugin REST route.
    private var resolvedTranscriptAroundFetch: ((String, Int, Int) async -> TranscriptAroundFetch?)? {
        if let transcriptAroundFetch { return transcriptAroundFetch }
        guard let rest = connection?.rest else { return nil }
        return { sessionId, messageId, radius in
            await fetchTranscriptAround(
                rest: rest,
                sessionId: sessionId,
                around: messageId,
                radius: radius
            )
        }
    }

    /// The injected `transcriptPageFetch` test seam, or the default that
    /// resolves the live `connection?.rest` and calls the module-level
    /// ``fetchTranscriptPage``. Mirrors ``resolvedTranscriptAroundFetch``'s
    /// injected-seam-first pattern so tests can control `loadEarlierTranscript`'s
    /// fetch timing without a live REST client.
    private var resolvedTranscriptPageFetch: ((String, Int, Int?) async -> TranscriptPageFetch?)? {
        if let transcriptPageFetch { return transcriptPageFetch }
        guard let rest = connection?.rest else { return nil }
        return { sessionId, limit, before in
            await fetchTranscriptPage(rest: rest, sessionId: sessionId, limit: limit, before: before)
        }
    }

    /// The injected `backfillFetch`, or the default that resolves the live REST
    /// client. Built lazily because `connection` is wired after `init`; tests
    /// override `backfillFetch` directly.
    private var resolvedBackfillFetch: ((String) async throws -> [StoredMessage])? {
        if let backfillFetch { return backfillFetch }
        // R3 (ROUND-4 W2d): the relay `history` backfill branch DELETES — on
        // relay, `backfill()` itself is a relay-local resync now (above); no
        // transcript refetch ever resolves here. (Its QA-2 R15 purpose — a
        // post-flap reconcile over the transport that IS up — is served by the
        // coordinator's resync{last_seq} replay, which is gap-free by
        // construction and costs the gateway zero reads.) The REST fetcher
        // below serves direct mode until Wave 4 folds the fork (amendment S1).
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
            return try await fetchTranscriptDeltaAware(rest: rest, cacheStore: cacheStore, sessionId: sessionId, identity: self.sessions?.cacheIdentity(sessionId))
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
        // R1/I12 (amendment G1): relay gates MOVE with their session — park
        // them before the wholesale clear so a switch-back re-shows the card
        // (the direct-path gate keeps its reset lifetime — this branch only
        // touches relay-owned gates).
        if let approval = pendingApproval, relayOwnedGateIDs.contains(approval.id) {
            parkedRelayApprovals[approval.sessionId] = approval
        }
        if let clarify = pendingClarification,
           let rid = clarify.request.requestId, relayOwnedGateIDs.contains(rid) {
            parkedRelayClarifications[clarify.sessionId] = clarify
        }
        pendingApproval = nil
        pendingClarification = nil
        // The relay gate-suppression set is NOT cleared here (R1/I12): an
        // ANSWERED gate's resync re-delivery must stay suppressed across
        // switches for every session the phone drives — the set belongs to
        // the process lifetime, not one session's teardown (bounded:
        // drop-all past 256 in `markRelayGateResolved`). The DURABLE I23
        // mirror survives a kill regardless (seeded at init).
        // R5/I21: the settled-turn latch belongs to the torn-down session
        // (turn ids carry the session id, but drop them with the session).
        settledRelayTurnIDs.removeAll()
        relayTurnSettleLatched = false
        relayTurnSawErrorItem = false
        relayTurnSettling = false
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
        isLoadingJumpTarget = false
        jumpTargetLoadError = nil
        oldestLoadedTranscriptWireId = nil
        jumpWindowFetchAttemptedMessageIds = []
        // A pending foreign-reconcile adoption belongs to the session being torn
        // down (§3.7); never let it bleed into the next session's first seed.
        pendingForeignReconcileID = nil
        pendingReconnectReconcileID = nil
        // The relay-path task-list mirror belongs to the session being torn down
        // too (N4/A5): without this, a switch to a session projected via the
        // gateway path (which never calls `applyRelayItems`) would keep showing
        // the previous session's dock task box.
        relayLatestTaskList = nil
        // QA-2 R13: drop ownership with the mirror so a stale owner can never
        // leak into the next session's dock visibility check.
        taskListOwnerSessionId = nil
        // QA-2 R12: a session teardown kills any in-flight local turn — cancel
        // its watchdog so it can never fire-settle into the fresh session.
        cancelLocalTurnWatchdog()
        // Relay echo adoptions belong to the session being torn down (QA-1):
        // a stale adoption must never re-id a next session's userMessage item
        // onto a prior session's consumed echo row.
        relayEchoAdoptions = [:]
        clearAllCompactionIndicators()
        transcriptGeneration = 0
        transcriptConfirmedEmpty = false
    }

    // MARK: - Wave-2 relay transport projection (RELAY-PHONE-PROTOCOL §2/§7)

    /// A sticky adoption of an optimistic user echo (an UNTAGGED `.user` row
    /// from the relay send path) by a relay `userMessage` item. Once an item
    /// adopts an echo, it keeps the echo's identity for the rest of the session
    /// — the echo row is CONSUMED out of the preserved history on the pass that
    /// first adopts it, so every later re-projection (the echo row is gone by
    /// then) resolves the identity from this map instead of re-searching, and
    /// the bubble never flickers nor duplicates (QA-1 B5/B13).
    private struct RelayEchoAdoption: Sendable {
        let id: UUID
        let clientMessageID: String?
        let timestamp: Date
    }

    /// `userMessage` item id → adopted echo identity, per projected session.
    /// Cleared on `reset()` (session teardown) so a next session never inherits
    /// a stale adoption.
    private var relayEchoAdoptions: [String: RelayEchoAdoption] = [:]

    /// Resolve the identity a `userMessage` item projects onto: a prior
    /// adoption (sticky), else an UNCONSUMED optimistic echo row in the current
    /// transcript — correlated by `client_message_id` first (deterministic, so
    /// distinct sends of identical text never collapse), then by text for an
    /// item without one (a prompt submitted without a cmid). Returns `nil` when
    /// nothing matches — the item projects onto its own deterministic id (a
    /// prompt this phone never echoed, e.g. sent by another client).
    private func adoptRelayEcho(
        for item: ChatItem, consuming: inout Set<UUID>
    ) -> RelayEchoAdoption? {
        if let adopted = relayEchoAdoptions[item.itemID] {
            // QA-3 S4: the sticky contract assumed the echo row was gone from
            // `messages` after the pass that first adopted it — true until the
            // R15 union backfill FOLDED the gateway wire row onto the echo's
            // slot as an UNTAGGED row, resurrecting an unconsumed twin. Re-mark
            // it consumed on EVERY pass so the twin (and its assistant run, in
            // `applyRelayItems`) never survives beside the rebuilt copy — the
            // second half of the IMG_2579 orphan-answer duplication.
            consuming.insert(adopted.id)
            return adopted
        }
        let itemCMID = item.body["client_message_id"]?.stringValue
        // Adoption matches by CMID (contract I8, amendment G4): an item
        // carrying a `client_message_id` adopts its echo by cmid OR NOT AT
        // ALL — a FOREIGN-cmid item (a desktop-originated turn whose prompt
        // text equals a cache-painted row) never consumes the cmid-less
        // cache twin: the cache row + the foreign user row are TWO rows
        // (wire truth). The deleted text FALLBACK for cmid-bearing items was
        // the I8 violation (base consumed the twin — the fuzzy adoption R1
        // deletes). A cmid-LESS item (a resync snapshot's copy of a turn
        // this phone painted from the GRDB cache, which carries no cmid —
        // `toChatMessages` maps none) still adopts the same-text cmid-less
        // paint row so the reconciled turn renders ONCE, in place (QA-3
        // S4/A2 — the IMG_2579 duplication stays dead; that paint row has no
        // other identity to union on).
        func eligible(_ message: ChatMessage) -> Bool {
            message.role == .user && !message.relayProjected && !consuming.contains(message.id)
        }
        let echo: ChatMessage?
        if let itemCMID {
            echo = messages.first(where: { eligible($0) && $0.clientMessageID == itemCMID })
        } else {
            echo = messages.first(where: {
                eligible($0) && $0.clientMessageID == nil && $0.text == item.textBody
            })
        }
        guard let echo else { return nil }
        let adoption = RelayEchoAdoption(
            id: echo.id,
            clientMessageID: echo.clientMessageID,
            timestamp: echo.timestamp
        )
        relayEchoAdoptions[item.itemID] = adoption
        consuming.insert(echo.id)
        // QA-3 S6/A2: the durable echo (the session-keyed warm snapshot the
        // send write-through persists so a switch-and-back repaints it) is
        // now reconciled — purge it so a later repaint never re-presents a
        // second bubble beside the adopted row. The projection targets the
        // active session (the coordinator parks it on drafts — S11).
        sessions?.markEchoReconciled(
            storedId: sessions?.activeStoredId,
            clientMessageID: adoption.clientMessageID,
            text: echo.text
        )
        return adoption
    }

    /// Rebuild the visible transcript from the relay item store's reconciled
    /// items (the NEW relay transport path — docs/RELAY-PHONE-PROTOCOL.md §2).
    ///
    /// ADDITIVE + flag-gated: ONLY ``RelaySessionCoordinator`` (reached when the
    /// `transportPath` flag is `.relay`, default OFF) calls this. The gateway blob
    /// path never does, so today's streaming rendering is byte-unchanged.
    ///
    /// Projection (§2): each `userMessage` item becomes its own right-aligned
    /// `.user` bubble and flushes the assistant segment before it; every other
    /// item projects via ``ChatItem/renderPart`` into an ordered assistant
    /// message — text/reasoning/usage reuse the legacy renderers, the special
    /// kinds (`toolCall`/`fileChange`/`image`/`browser`/`error`) route through
    /// `.item` for `ChatItemView`. A non-terminal trailing item keeps the
    /// assistant bubble streaming. `items` MUST already be in render order (the
    /// store sorts by `ord`, ties by arrival). Message + part identities are
    /// derived deterministically from the stable relay ids, so re-projecting on
    /// every frame is churn-free (SwiftUI diffs cleanly, no bubble re-creation).
    ///
    /// MERGE, NOT REPLACE (QA-1 B5/B6/B7/B13): the projection is the LIVE relay
    /// content; the UNTAGGED rows already in `messages` (the GRDB cache paint,
    /// optimistic user echoes, direct-path rows) are the settled HISTORY. The
    /// rebuilt projection is tagged `relayProjected` and APPENDED below the
    /// preserved history — cached/settled transcript and the live streaming
    /// turn COEXIST, scrollback intact during and after streaming. Re-projection
    /// replaces only tagged rows (idempotent, no duplication); an empty `items`
    /// (session bound, zero frames yet) therefore leaves the cache paint
    /// untouched — the cold-open/force-close paint stays the initial truth
    /// (B15). A relay `userMessage` item ADOPTS the matching optimistic echo in
    /// place (sticky, by `client_message_id` then text) — one bubble, no dupe.
    /// R16: detect a relay turn that ended in FAILURE — an `item.completed`
    /// whose `type == .error` and `status == .failed`. Used by
    /// ``applyRelayItems(_:)`` to route the Live Activity end seam to
    /// `onTurnDiscarded` (no queue drain) instead of `onTurnComplete`, matching
    /// the direct path's `handleGatewayError`. Pure + testable.
    nonisolated static func hasRelayErrorTerminal(_ items: [ChatItem]) -> Bool {
        items.contains { $0.type == .error && $0.status == .failed }
    }

    func applyRelayItems(
        _ items: [ChatItem],
        turnSettled: Bool = false,
        serverTurnDuration: TimeInterval? = nil
    ) {
        // `turnSettled` (QA-2 R4/A2): the coordinator passes `true` when the frame
        // that drove this projection is `turn.completed` — the authoritative
        // turn-end the turn-scoped `relayTurnLive` flag clears on. Without it the
        // terminal-item window would either strand streaming true forever (if the
        // flag ignored item state entirely) or kill it at the first terminal frame
        // (the build-115 bug). Item terminality still drives the PER-ROW
        // `isStreaming` (the caret leaves a finished bubble); the STORE-level flag
        // is turn-scoped.
        //
        // `serverTurnDuration` (QA-3 S2/A1): the relay's authoritative turn
        // wall-clock (`turn.completed` body `duration_s`, reframer-measured from
        // the turn open). The per-turn timer STARTS LOCALLY at send
        // (`turnStartedAt`) — the affordance renders ≤100 ms from send, never
        // gated on a frame — and RECONCILES to this server value on settle, so
        // the "Worked for Ns" label reads the turn's true duration even when the
        // phone's local start is skewed (queued-drain re-send) or absent (a
        // mid-turn resume this phone did not send — those now stamp the settled
        // duration from the server with NO local start at all).
        if turnSettled {
            relayTurnLive = false
            resetTurnLivenessState()   // QA-3 S8/A4: the turn settled — its liveness state dies with it
        }
        // QA-2 R12 — a live frame batch proves SOMETHING is progressing; stamp
        // the wall clock (observability). QA-3 S8/A4: the liveness watchdog is
        // NO LONGER re-armed here — it is per-TURN now, refreshed only by
        // CURRENT-turn frames via `noteTurnLivenessFrame(isCurrentTurn:)` from
        // the coordinator's ingest (re-arming on ANY batch was the re-arm-by-
        // other-turn bug that kept IMG_2591's dead turn "working" forever).
        lastRelayItemFrameAt = Date()
        // QA-3 S8/A4 — PRIOR-TURN LIVENESS: the last `userMessage` item bounds
        // the CURRENT turn (the relay allocates its ord at SUBMIT, before any
        // of that turn's agent items, so render order is strictly
        // [U1,A1…][U2,A2…]). A still-`.inProgress` item BEFORE that boundary
        // belongs to a turn a NEWER turn already superseded — it can never
        // legitimately complete now, so settle it deterministically (muted
        // "Interrupted" fold) instead of rendering "Working…" forever.
        // Stateless + idempotent: every projection self-heals, and any late
        // authoritative frame (item.completed / snapshot) replaces the item by
        // id and restores the honest state.
        let lastUserMessageIndex = items.lastIndex { $0.type == .userMessage }
        var rebuilt: [ChatMessage] = []
        var segmentParts: [ChatMessagePart] = []
        var segmentAnchor: String?
        var segmentStreaming = false
        var segmentInterrupted = false
        // Echo rows adopted by a `userMessage` item THIS pass — consumed out
        // of the preserved history so the reconcile replaces the echo in place
        // instead of projecting a second bubble beside it.
        var consumedEchoIDs: Set<UUID> = []

        func flushSegment() {
            guard let anchor = segmentAnchor, !segmentParts.isEmpty else {
                segmentParts = []
                segmentAnchor = nil
                segmentStreaming = false
                segmentInterrupted = false
                return
            }
            let segmentID = ChatMessage.deterministicID(seedKey: "relay-assistant-\(anchor)")
            rebuilt.append(ChatMessage(
                id: segmentID,
                role: .assistant,
                parts: segmentParts,
                isStreaming: segmentStreaming,
                interrupted: segmentInterrupted && !segmentStreaming,
                // I21: a re-projection inherits the prior row's timestamp —
                // never a fresh `Date()` — so a resync replay converges to
                // the byte-identical transcript.
                timestamp: messages.first(where: { $0.id == segmentID })?.timestamp ?? Date(),
                relayProjected: true
            ))
            segmentParts = []
            segmentAnchor = nil
            segmentStreaming = false
            segmentInterrupted = false
        }

        for (index, item) in items.enumerated() {
            if item.type == .userMessage {
                flushSegment()
                let adoption = adoptRelayEcho(for: item, consuming: &consumedEchoIDs)
                let userRowID = adoption?.id
                    ?? ChatMessage.deterministicID(seedKey: "relay-user-\(item.itemID)")
                rebuilt.append(ChatMessage(
                    id: userRowID,
                    role: .user,
                    clientMessageID: adoption?.clientMessageID
                        ?? item.body["client_message_id"]?.stringValue,
                    parts: [.text(id: item.itemID, text: item.textBody)],
                    // I21: the adopted echo's timestamp on first adoption, the
                    // prior projection's thereafter — NEVER a fresh `Date()` —
                    // so a resync replay (the echo already consumed) converges
                    // to the byte-identical transcript.
                    timestamp: adoption?.timestamp
                        ?? messages.first(where: { $0.id == userRowID })?.timestamp
                        ?? Date(),
                    relayProjected: true
                ))
            } else if let part = item.renderPart {
                if segmentAnchor == nil { segmentAnchor = item.itemID }
                segmentParts.append(part)
                if !item.isTerminal {
                    if let lastUserMessageIndex, index < lastUserMessageIndex {
                        // A prior turn's stuck item — settled, muted (A4).
                        segmentInterrupted = true
                    } else {
                        segmentStreaming = true
                    }
                } else if item.locallyInterrupted {
                    // The watchdog's stage-2 settle marked this item terminal.
                    segmentInterrupted = true
                }
            }
        }
        flushSegment()

        // QA-2 R4/A2 — STABLE PER-TURN ASSISTANT IDENTITY: re-key every rebuilt
        // assistant row off the turn's USER row id (stable across echo adoption
        // and every re-projection) instead of the first agent item's id. The
        // optimistic caret bubble the send appends carries
        // `relayOptimisticAssistantID(forEcho:)` — the SAME derivation off the
        // echo id adoption preserves — so the first real segment inherits the
        // bubble's identity and SwiftUI morphs caret → streaming reply in place
        // (no view-identity pop at first item, none at settle). Turns with no
        // user row (a mid-turn resume snapshot) keep the anchor-derived id.
        var lastUserRowID: UUID?
        for index in rebuilt.indices {
            if rebuilt[index].role == .user {
                lastUserRowID = rebuilt[index].id
            } else if rebuilt[index].role == .assistant, let userRowID = lastUserRowID {
                let seg = rebuilt[index]
                let assistantID = Self.relayAssistantID(forUserRowID: userRowID)
                rebuilt[index] = ChatMessage(
                    id: assistantID,
                    role: .assistant,
                    parts: seg.parts,
                    isStreaming: seg.isStreaming,
                    interrupted: seg.interrupted,
                    reasoningElapsed: seg.reasoningElapsed,
                    // I21: inherit the prior projection's timestamp under the
                    // FINAL (re-keyed) id — a replay converges byte-identical.
                    timestamp: messages.first(where: { $0.id == assistantID })?.timestamp
                        ?? seg.timestamp,
                    relayProjected: true
                )
            }
        }

        // QA-2 R4/A2 — OPTIMISTIC CARET RETENTION: while the turn is live
        // (`relayTurnLive`) and the CURRENT turn has no agent items yet (the
        // accepted-and-waiting window — the relay's first frame is the terminal
        // `userMessage`), keep an empty streaming assistant bubble at the tail
        // so the breathing caret + stop button persist from send to first
        // delta, independent of item terminality. Reuses the existing
        // optimistic row's id when present (send created it), else derives it
        // from the turn's user row. The first real agent item replaces it in
        // place (same id, above) on the next pass.
        if relayTurnLive {
            var hasAgentItemThisTurn = false
            for item in items.reversed() {
                if item.type == .userMessage { break }
                if item.renderPart != nil { hasAgentItemThisTurn = true; break }
            }
            if !hasAgentItemThisTurn {
                let optimisticID = messages.first(where: {
                    $0.role == .assistant && $0.relayProjected && $0.parts.isEmpty
                })?.id
                    ?? lastUserRowID.map(Self.relayAssistantID(forUserRowID:))
                    ?? ChatMessage.deterministicID(seedKey: "relay-assistant-optimistic")
                rebuilt.append(ChatMessage(
                    id: optimisticID,
                    role: .assistant,
                    isStreaming: true,
                    relayProjected: true
                ))
            }
        }

        // N4/A5: the dock's task box reads `latestTodoList`; on the relay path
        // the ONE living `.taskList` item lives in these reconciled items, NOT
        // in a `todo` ToolActivity the legacy scan would find — refresh the
        // relay mirror from the same batch so the dock works identically on
        // both transports (and clears when the session has no task list).
        // Deliberately BEFORE the empty guard: an empty projection must still
        // clear the stale session's task list so the new dock starts clean.
        refreshRelayTaskListMirror(from: items)

        // QA-1 B4 — BLANK-SCREEN IMPOSSIBLE: an EMPTY relay projection must
        // never blank a painted transcript. R1's write-gate move re-projects
        // the incoming entry only when it HAS items (an empty entry leaves the
        // cache paint intact — the switch never voids, contract I2); this
        // guard is the belt-and-braces fallback for any other empty projection
        // (e.g. a pre-content frame on a fresh open). Assigning `messages = []` there raced the
        // GRDB cache seed (`seedTranscriptCacheFirst`) and, whichever landed
        // last, left the view EMPTY with a bumped `transcriptGeneration` — a
        // fully blank screen (the placeholder's skeleton branch requires
        // generation == 0, so no skeleton either). Fall back to the painted
        // content instead: cache → skeleton → content, NEVER void. The
        // switch's own cache seed (or `reset()` on a cache miss) owns the
        // legitimate content → content transition.
        guard !rebuilt.isEmpty else { return }

        transcriptConfirmedEmpty = false
        // QA-2 R4/A2 — TURN-SCOPED STREAMING: `isStreaming` is true from the
        // relay send (`relayTurnLive`) until the turn settles via
        // `turn.completed`, independent of per-item terminality. The build-115
        // bug derived it SOLELY from item state — the relay's synthesized
        // TERMINAL `userMessage` first frame projected `nowStreaming == false`
        // and killed the cursor + stop button for the entire accepted-and-
        // waiting window (fast turns showed no affordance at all). Item
        // terminality still drives each rebuilt ROW's `isStreaming` (the caret
        // leaves a finished bubble); the STORE flag is turn-scoped.
        let nowStreaming = relayTurnLive || rebuilt.contains { $0.isStreaming }
        // QA-1 B8: relay turn-lifecycle chrome. `turnStartedAt`/`activeToolName`
        // are direct-path event-router internals the relay path never updates
        // per event — left alone, the inline activity row's elapsed label would
        // inherit a stale prior turn's start on the next relay send. Stamp on
        // the first streaming projection (parity with `beginStreamingMessage`
        // → `markTurnStartedIfNeeded`, also firing the Live Activity seam for a
        // turn this phone did NOT send — e.g. a mid-turn resume) and clear when
        // the projection settles (parity with `handleMessageComplete`). The
        // transition read MUST precede `setStreaming` below.
        if nowStreaming {
            markTurnStartedIfNeeded()
        } else if isStreaming {
            // QA-2 R5/A3 — SETTLE EDGE: capture the turn's wall-clock duration
            // BEFORE clearing the timer, and persist it keyed by the settled
            // assistant row's stable per-turn id — the projection rebuilds
            // every tagged row from the (session-accumulating) item store on
            // every pass, so the settled "Worked for Ns" label (re-stamped
            // below) survives later turns' re-projections. Relay items carry no
            // timestamps; build 115 settled relay rows read a bare "Worked"
            // (IMG_2532). Mirrors the direct path's completion-time stamp.
            //
            // QA-3 S2/A1 — SERVER RECONCILIATION: the authoritative duration is
            // the relay's `turn.completed` `duration_s` when it carries one;
            // the local `turnStartedAt` measurement is the fallback (and the
            // LIVE timer's source while the turn runs). Server-wins means a
            // mid-turn resume (no local start) still stamps an honest settled
            // duration.
            let elapsed = serverTurnDuration
                ?? turnStartedAt.map { Date().timeIntervalSince($0) }
            if let elapsed {
                // The settled row is THIS turn's assistant row — the last
                // assistant AFTER the last user row (a turn that settled with
                // zero agent items must not re-stamp the previous turn's row).
                let lastUserIdx = rebuilt.lastIndex(where: { $0.role == .user }) ?? -1
                if let settledIdx = rebuilt.lastIndex(where: { $0.role == .assistant }),
                   settledIdx > lastUserIdx {
                    relaySettledElapsed[rebuilt[settledIdx].id] = elapsed
                }
            }
            turnStartedAt = nil
            activeToolName = nil
            // R16 NOTE: the Live Activity END seam for relay turns is NOT
            // fired here. The projection-settle edge is an unreliable signal
            // — a snapshot fed all-at-once never transitions through
            // streaming, and a relay `.error` item leaves the assistant
            // segment `in_progress` (so the projection keeps streaming). The
            // relay wire carries an EXPLICIT turn boundary (`.turnCompleted`)
            // and explicit failure items (`.error`/status `.failed`); the
            // coordinator fires those via `notifyRelayTurnCompleted()` /
            // `notifyRelayTurnDiscarded()`. See
            // `RelaySessionCoordinator.ingest`.
        }
        // QA-2 R5/A3: re-stamp settled relay turns' captured durations on every
        // pass (the rows are rebuilt fresh from items each time), so a settled
        // turn keeps reading "Worked for Ns" after the store has cleared
        // `turnStartedAt` and after subsequent turns re-project the timeline.
        if !relaySettledElapsed.isEmpty {
            for index in rebuilt.indices
            where rebuilt[index].role == .assistant
                && !rebuilt[index].isStreaming
                && rebuilt[index].reasoningElapsed == nil {
                rebuilt[index].reasoningElapsed = relaySettledElapsed[rebuilt[index].id]
            }
        }
        // QA-1 B5/B6/B7/B13 — MERGED TIMELINE: preserve the settled history
        // (every untagged row) and append the live relay projection below it —
        // minus any echo rows a userMessage item adopted this pass (they
        // re-enter tagged, in place). History + live turn coexist; scrollback
        // stays intact during and after streaming.
        //
        // QA-3 S4/A2 — CONSUME CACHE-PAINTED ASSISTANT TWINS: adoption only
        // consumes USER rows (`adoptRelayEcho`), but a reconnect resync /
        // mid-turn open delivers a snapshot of ALL accumulated items, so the
        // rebuilt tail re-projects EVERY turn the session ever ran — including
        // turns the GRDB cache / network seed already painted UNTAGGED. With
        // only the user twins consumed, the preserved history still held every
        // cache-painted ANSWER `[A1…An]` above a rebuilt `[U1',A1'…Un',An']`
        // tail: each answer rendered TWICE, and the orphan cache copy sat
        // ABOVE the rebuilt user rows — the answer visibly preceding the
        // prompt that asked it (IMG_2579-2582: the same exchange in two
        // orders at two scroll positions of one view; switching away "fixed"
        // it because the cache paint alone is ordered). The rebuilt copy is
        // AUTHORITATIVE (the relay item store is the live truth), so for each
        // user row a `userMessage` item adopted/consumed this pass, consume
        // the untagged assistant run that FOLLOWS it in the current
        // transcript — its settled cache-painted answer for that same turn.
        // Guarded on the rebuilt turn actually CARRYING an assistant segment:
        // a snapshot with the prompt's `userMessage` but no agent items yet
        // (a turn that errored pre-item, or a snapshot raced by its first
        // item) must not evaporate the cache answer before the relay copy
        // exists. Turns the item store does not carry at all (prompt sent by
        // another client) keep every preserved row — untouched.
        var consumedHistoryIDs = consumedEchoIDs
        // Rebuilt user rows whose turn carries an assistant segment. Adopted
        // user rows re-enter under the echo's id (== the consumed id), so the
        // rebuilt row id and the consumed id are the same key.
        var rebuiltHasAssistantAfter: [UUID: Bool] = [:]
        var rebuiltCurrentUser: UUID?
        for row in rebuilt {
            if row.role == .user {
                rebuiltCurrentUser = row.id
                rebuiltHasAssistantAfter[row.id] = false
            } else if row.role == .assistant, let userRowID = rebuiltCurrentUser {
                rebuiltHasAssistantAfter[userRowID] = true
            }
        }
        var inTwinRun = false
        for message in messages {
            if message.role == .user {
                // A consumed user row starts its twin run only when the
                // rebuilt turn carries the authoritative answer copy.
                inTwinRun = !message.relayProjected
                    && consumedEchoIDs.contains(message.id)
                    && rebuiltHasAssistantAfter[message.id] == true
            } else if inTwinRun, !message.relayProjected {
                consumedHistoryIDs.insert(message.id)
            }
        }
        let preserved = messages.filter {
            !$0.relayProjected && !consumedHistoryIDs.contains($0.id)
        }
        messages = preserved + rebuilt
        setStreaming(nowStreaming, reason: "relayProjection")
    }

    // MARK: - R5 relay turn-end semantics (contract I9/I21 — L3 wire-truth reason)

    /// R5/W2e (contract I9/B1): the local-STOP mark. `interrupt()` settles the
    /// UI FIRST (partial text finalized, busy/stop affordance cleared) and
    /// marks the current turn settling; the coordinator gates LATE item frames
    /// of the turn (crossed the interrupt in flight; a resync ring replay) to
    /// no-ops until the authoritative `turn.completed` settles it. Cleared on
    /// that settle, the next turn start, a new send, an authoritative snapshot
    /// re-baseline, and any wholesale teardown. ALSO the pre-L3 COMPAT input
    /// that distinguishes a user stop on a reason-less `turn.completed`
    /// (deleted with the compat branch in W3b — RR5).
    private(set) var relayTurnSettling = false

    /// R5/W2e (contract I9, L3 consume): a failed `.error` item arrived for
    /// the current turn. Wire-truth `reason:error` on `turn.completed` (lane
    /// L3) supersedes it; this flag is the COMPAT input for a pre-L3 relay's
    /// reason-less `turn.completed` (RR5) — the signal the deleted
    /// `relayTurnTerminatedByError` latch carried. Deleted with the compat
    /// branch in W3b.
    private var relayTurnSawErrorItem = false

    /// I21: turn ids whose settle seam already fired. A resync replay /
    /// snapshot re-delivery re-emits the settled turn's `turn.completed` (and
    /// `.error` item); the seam fires ONCE per turn (the double drain / double
    /// LA-end the W0a RED matrix recorded). Bounded: drop-all past 64 — replay
    /// windows are short and a dropped key at worst re-fires one idempotent
    /// LA end.
    private var settledRelayTurnIDs: Set<String> = []

    /// Id-less settle latch (frames without a `turn`): one seam per turn.
    private var relayTurnSettleLatched = false

    /// R5: the ONE relay turn-end seam (contract I9 — `turn.completed{reason}`
    /// is the sole completion edge; stopped ≠ completed). `completed` ⇒ the
    /// queue MAY drain (`onTurnComplete` → drain pipeline); `interrupted`
    /// (user stop) / `error` ⇒ the queue HOLDS (`onTurnDiscarded` → Live
    /// Activity end only). Latched once per turn (I21). The watchdog's
    /// PROVISIONAL stage-2 settle does NOT route through here — a late
    /// authoritative `turn.completed` must still fire its honest seam
    /// (a frame-silent turn resurrects; contract I10).
    private func settleRelayTurn(_ turnID: String?, completed: Bool) {
        if let turnID, !turnID.isEmpty {
            guard settledRelayTurnIDs.insert(turnID).inserted else { return }
            if settledRelayTurnIDs.count > 64 { settledRelayTurnIDs.removeAll() }
        } else {
            guard !relayTurnSettleLatched else { return }
            relayTurnSettleLatched = true
        }
        relayTurnSettling = false
        relayTurnSawErrorItem = false
        if completed { onTurnComplete?() } else { onTurnDiscarded?() }
    }

    /// R5 (contract I9, lane L3): fire the turn-end seam from the relay
    /// coordinator's `.turnCompleted` handler, split on the relay's
    /// wire-truth `reason`: `completed` ⇒ drain; `interrupted` / `error` ⇒
    /// HOLD (stopped ≠ completed). The relay path never flows through
    /// `handleMessageComplete` (direct path), so this seam is the Live
    /// Activity's only end edge on relay reach (R16).
    func notifyRelayTurnCompleted(turnID: String?, reason: String?) {
        let completed: Bool
        if let reason, !reason.isEmpty {
            completed = (reason == "completed")   // wire truth (L3)
        } else {
            // COMPAT — pre-L3 relay (RR5): no `reason` on the wire; fall back
            // to the local signals the deleted `relayTurnTerminatedByError`
            // latch carried (user stop via the settling mark, error via the
            // error-item flag). W3b deletes this branch once every relay
            // stamps reason.
            completed = !relayTurnSettling && !relayTurnSawErrorItem
        }
        settleRelayTurn(turnID, completed: completed)
    }

    /// R5: a failed `.error` item is a turn TERMINAL (parity with the direct
    /// path's `handleGatewayError`): fire the DISCARD seam — the queue does
    /// NOT drain into a session that just errored. The trailing
    /// `.turnCompleted` (the relay emits one even for errored turns) is
    /// suppressed by the once-per-turn latch (I21).
    func notifyRelayTurnDiscarded(turnID: String?) {
        relayTurnSawErrorItem = true
        settleRelayTurn(turnID, completed: false)
    }

    /// R5 (contract I3/I9): a `snapshot` is an authoritative re-baseline — it
    /// supersedes a local-STOP settlement (the server truth wins; the stopped
    /// turn's items re-project exactly as the snapshot carries them).
    func noteAuthoritativeRebaseline() {
        relayTurnSettling = false
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
        // QA-2 R4/A2: a wholesale reset/discard ends the turn-scoped relay
        // live flag too (reset/open-seed/draft/connection-drop all funnel
        // here) — never let it strand `isStreaming` true into the next
        // session. The settled-duration stamps belong to the torn-down
        // session's rows; drop them with it.
        relayTurnLive = false
        relaySettledElapsed = [:]
        // R5: the torn-down turn's settle state dies with it (a new turn's
        // `turn.completed` must fire its seam; a lingering local-stop mark
        // would gate the NEXT turn's frames).
        relayTurnSettling = false
        relayTurnSawErrorItem = false
        relayTurnSettleLatched = false
        resetTurnLivenessState()   // QA-3 S8/A4: the torn-down turn's liveness state dies with it
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

    // MARK: - QA-2 R12 local-turn watchdog (stop-state wedge kill)

    /// QA-3 S8/A4 — a CURRENT-turn frame just landed (the coordinator's ingest
    /// classifies each frame — frames of a SUPERSEDED turn never call this with
    /// `true`, so a dead prior turn's late frames cannot refresh the clock, and
    /// a dead current turn's silence is never masked by another turn's traffic
    /// — the IMG_2591 re-arm-by-other-turn bug). Refresh the silence baseline
    /// and re-arm the two-stage watchdog.
    func noteTurnLivenessFrame(isCurrentTurn: Bool) {
        guard isCurrentTurn else { return }
        turnLivenessBaseline = ContinuousClock.now
        if isStreaming { armLocalTurnWatchdog() }
    }

    /// (Re)arm the per-turn liveness watchdog (QA-3 S8/A4; QA-2 R12's wedge
    /// kill, reworked per-turn). Armed on every `isStreaming` false→true
    /// transition and on every CURRENT-turn frame. Evaluates in
    /// ``turnLivenessTick`` chunks off ``turnLivenessBaseline`` (so a frame
    /// landing mid-sleep defers the stages instead of firing late):
    ///   stage 1 at ``turnLivenessResyncAfter`` of silence — one SILENT
    ///     `resync{last_seq}` (self-heals a dropped terminal frame);
    ///   stage 2 at ``localTurnStaleTimeout`` of silence — the turn is dead:
    ///     settle it locally (muted "Interrupted"), never an error banner.
    private func armLocalTurnWatchdog() {
        cancelLocalTurnWatchdog()
        if turnLivenessBaseline == nil { turnLivenessBaseline = ContinuousClock.now }
        localTurnWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: ChatStore.turnLivenessTick)
                guard let self, !Task.isCancelled else { return }
                guard self.isStreaming else { return }
                let idle = self.turnLivenessBaseline.map { $0.duration(to: ContinuousClock.now) } ?? .zero
                if idle >= ChatStore.localTurnStaleTimeout {
                    self.fireTurnLivenessSettle()
                    return
                }
                if idle >= ChatStore.turnLivenessResyncAfter, !self.turnLivenessResyncFired {
                    self.fireTurnLivenessResync()
                }
            }
        }
    }

    private func cancelLocalTurnWatchdog() {
        localTurnWatchdog?.cancel()
        localTurnWatchdog = nil
    }

    /// QA-3 S8/A4 stage 1 — the current turn went silent past
    /// ``turnLivenessResyncAfter``: ask the relay for a `resync{last_seq}`
    /// replay (a snapshot when the gap exceeds the ring). SILENT and
    /// idempotent — a dropped `item.completed` / `turn.completed` heals here
    /// and the turn settles naturally; the user sees nothing (C3). Latched:
    /// fires at most once per turn (reset on turn start / settle).
    private func fireTurnLivenessResync() {
        guard isStreaming, !turnLivenessResyncFired else { return }
        turnLivenessResyncFired = true
        #if DEBUG
        turnLivenessResyncCount += 1
        #endif
        chatLog.warning("turn-liveness stage 1: current turn silent past the resync window — requesting a SILENT resync{last_seq} to recover dropped frames (self-healing, never surfaced — C3)")
        guard connection?.transportPath == .relay,
              let coordinator = connection?.relayCoordinator else { return }
        Task { await coordinator.requestLivenessResync() }
    }

    /// QA-3 S8/A4 stage 2 — the current turn went silent past
    /// ``localTurnStaleTimeout`` with no completion even after the stage-1
    /// resync: the turn is DEAD (gateway turn died / submit never ran / the
    /// authority has nothing more). Settle it: the coordinator locally
    /// terminals the stuck items (muted "Interrupted" fold — C3, never an
    /// error banner) and the live flag clears, so eternal double-working is
    /// unreachable. The normal `turn.completed` / `message.complete` /
    /// interrupt paths settle via `setStreaming(false)` first; this fires
    /// only when none of those landed in time.
    private func fireTurnLivenessSettle() {
        guard isStreaming else { return }
        chatLog.warning("turn-liveness stage 2: turn silent past the settle window with no completion even after the silent resync — settling as INTERRUPTED so eternal double-working is impossible (C3: no error surface)")
        if connection?.transportPath == .relay, let coordinator = connection?.relayCoordinator {
            // Locally settle the dead turn's stuck items; the re-projection
            // folds them as muted "Interrupted" rows and clears the turn-scoped
            // live flag.
            coordinator.settleStaleTurnLocally()
        }
        // Belt and braces (direct path, or a projection that still reads
        // streaming): force the settle exactly like the QA-2 wedge kill did.
        if isStreaming {
            mutateStreaming { $0.isStreaming = false }
            streamingMessageID = nil
            setStreaming(false, reason: "turnLivenessSettle")
        }
        turnStartedAt = nil
        activeToolName = nil
        activeToolCallId = nil
        resetTurnLivenessState()
        // R5 (contract I10/B4 — Matrix B §4 gap): a PROVISIONAL watchdog
        // settle ends the Live Activity + gates ONLY — it never drains the
        // queue: the turn may still be live on the gateway (a frame-silent
        // tool) and a late frame resurrects it, after which the honest
        // `turn.completed{reason}` fires the real seam. Base fired
        // `onTurnComplete` here — a false-positive settle drained a queued
        // prompt into the still-running turn (4009 churn). The settle does
        // NOT latch the turn (``settleRelayTurn`` is NOT called): the
        // authoritative completion must still fire its seam.
        onTurnDiscarded?()
    }

    /// Reset the per-turn liveness state (turn start / every settle path).
    private func resetTurnLivenessState() {
        turnLivenessResyncFired = false
        turnLivenessBaseline = nil
    }

    /// QA-2 R12/R13 — relay turn start. Called by `RelaySessionCoordinator`
    /// .ingest on a `turn.started` frame. The relay item store accumulates the
    /// PRIOR turn's `taskList` item (stable `<sid>:tasks` id, replaced in place
    /// only when THIS turn emits its own first `taskList` frame), so without
    /// this clear the next `applyRelayItems` would re-mirror the previous turn's
    /// list and the dock pill would briefly render stale data the moment the new
    /// turn flips `isStreaming` true. Clearing here lets the new turn re-seed
    /// the dock from a blank slate the instant its own `taskList` arrives.
    func handleRelayTurnStarted() {
        relayLatestTaskList = nil
        taskListOwnerSessionId = nil
    }

    #if DEBUG
    /// DEBUG test seam: drive the liveness watchdog's stage-2 SETTLE path
    /// synchronously without waiting ``localTurnStaleTimeout``. Production code
    /// never calls this — the watchdog's tick loop is the only legit trigger.
    /// Lets the regression test prove a missed-frame turn releases `isStreaming`
    /// and the dock pill without a force-close (A6/R12, QA-3 A4).
    @discardableResult
    func _debugFireLocalTurnWatchdog() -> Bool {
        guard isStreaming else { return false }
        fireTurnLivenessSettle()
        return true
    }

    /// DEBUG test seam: drive the liveness watchdog's stage-1 SILENT RESYNC
    /// synchronously without waiting ``turnLivenessResyncAfter`` (QA-3 A4).
    @discardableResult
    func _debugFireTurnLivenessResync() -> Bool {
        guard isStreaming else { return false }
        fireTurnLivenessResync()
        return true
    }
    #endif

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
    ///
    /// `stampWarning` defaults to `true` (the visible "Connection lost"
    /// bubble). STR-973A's silent-reconnect grace passes `false` on a quick
    /// heal (attempt-0 succeeds inside the grace window): the stream state
    /// still needs finalizing so `backfill()` can run, but the user never saw
    /// a reconnect banner, so no warning should land in the transcript either.
    func handleConnectionDrop(stampWarning: Bool = true) {
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
            if stampWarning, message.warning == nil { message.setWarningPart("Connection lost") }
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

// MARK: - Latest completed assistant reply (STR-545)

extension ChatStore {
    /// The most recent assistant turn that has finished streaming and carries
    /// non-empty text — ignores streaming/pending rows, non-assistant rows,
    /// and blank assistant turns (a tool-only or thinking-only turn has no
    /// `.text` part). This is the read-only seam the hands-free conversation
    /// loop (STR-532) polls to find what to speak next; it does not mutate
    /// any store state.
    ///
    /// - Parameter lastSeenId: the id of the reply already spoken/consumed.
    ///   Passing the same id again returns `nil` so a poller doesn't re-speak
    ///   an unchanged reply.
    func latestCompletedAssistantReply(excluding lastSeenId: UUID? = nil) -> ChatMessage? {
        guard let candidate = messages.last(where: { message in
            message.role == .assistant
                && !message.isStreaming
                && !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else { return nil }
        return candidate.id == lastSeenId ? nil : candidate
    }
}
