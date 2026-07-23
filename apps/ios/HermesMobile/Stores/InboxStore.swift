import Foundation
#if DEBUG
#endif

/// Cache-first, server-reconciled owner of the global approval / clarification inbox.
///
/// Where `ChatStore` only surfaces the approval / clarification belonging to the
/// transcript currently on screen, `InboxStore` accumulates **every**
/// `approval.request` / `clarify.request` the gateway emits — across all
/// sessions — because the gateway broadcasts these prompts to every connected
/// client (`HERMES_GATEWAY_BROADCAST=1`) and each carries its own `session_id`
/// (+ `stored_session_id`). This gives the user one place to clear pending
/// agent prompts no matter which session raised them, including turns driven by
/// another client (e.g. the desktop) or by a background cron session.
///
/// Each item is answered against **its own** `sessionId`, not the active
/// session: a broadcast approval from a foreign runtime must be resolved on
/// that runtime or it will hang forever. Answering moves the durable row through
/// responding to a server-confirmed terminal state; a
/// `message.complete` for an item's session marks any still-pending items for
/// that session as `expired` (the turn moved on without an answer, so the
/// prompt window is gone).
///
/// The store is fed by `ConnectionStore`'s event router via a single
/// ``handle(event:)`` call (see integration notes) and holds a back-reference
/// to the shared `HermesGatewayClient` for responses. That reference is set
/// once in ``attach(connection:)`` and lives for the app's lifetime.
@MainActor
@Observable
final class InboxStore {
    /// Whether an item is an approval or a free-form clarification.
    enum Kind: Sendable, Equatable {
        case approval
        case clarify
    }

    /// Lifecycle of an inbox item.
    enum ItemState: Sendable, Equatable {
        /// Awaiting a user response.
        case pending
        /// A response RPC is in flight; still visible until server truth lands.
        case responding
        /// The owning turn completed before it was answered — no longer actionable.
        case expired
        /// The server confirmed the item is no longer pending.
        case resolvedElsewhere
        /// The response could not be delivered and can be retried.
        case failedRetryable

        var isVisible: Bool {
            switch self {
            case .pending, .responding, .failedRetryable: true
            case .resolvedElsewhere, .expired: false
            }
        }
    }

    /// The typed payload behind an item. Mirrors the two prompt shapes the
    /// gateway emits, reusing the frozen wire payload types.
    enum Payload: Sendable, Equatable {
        case approval(ApprovalRequestPayload)
        case clarify(ClarifyRequestPayload)
    }

    /// One accumulated prompt awaiting (or having received) a response.
    struct Item: Identifiable, Sendable, Equatable {
        /// Stable identity for the row. For approvals this is the gateway's
        /// approval id; for clarifications (which carry no id on the wire) a
        /// synthesized UUID string, so SwiftUI keeps list identity stable.
        let id: String
        /// Runtime `session_id` the prompt belongs to — the target of the
        /// response RPC.
        let sessionId: String
        /// Persistent `stored_session_id`, when the gateway broadcast included
        /// it. Used for session-title lookup against `SessionStore`.
        let storedSessionId: String?
        let kind: Kind
        let payload: Payload
        let receivedAt: Date
        var state: ItemState

        /// Title shown in the row, derived from the payload.
        var title: String {
            switch payload {
            case .approval(let request): return request.title
            case .clarify(let request): return request.question
            }
        }

        /// One-line supporting text shown under the title, when available.
        var subtitle: String? {
            switch payload {
            case .approval(let request):
                if let description = request.descriptionText, !description.isEmpty { return description }
                return request.target
            case .clarify(let request):
                return request.choices.isEmpty ? nil : request.choices.joined(separator: " · ")
            }
        }
    }

    /// All accumulated items, newest first.
    private(set) var items: [Item] = []

    /// Number of items still awaiting a response — drives toolbar badges.
    #if DEBUG
    #endif
    var pendingCount: Int {
        items.lazy.filter(\.state.isVisible).count
    }

    /// Items still awaiting a response, newest first. The view's primary list.
    var pendingItems: [Item] {
        items.filter { $0.state.isVisible }
    }

    // MARK: - Presentation request (B5 push tap routing)

    /// Monotonic token bumped whenever something (a push tap whose session can't
    /// be located) asks the UI to surface the inbox. The shell (B1 — RootView /
    /// drawer) observes this and presents `InboxView` on change. A token (rather
    /// than a `Bool`) means repeated requests always re-trigger, and there is no
    /// flag for the view to have to clear.
    private(set) var presentationRequestToken: Int = 0

    /// Ask the shell to surface the inbox. Used by `HermesURLRouter.routePushTap`
    /// when an approval/clarify push arrives for a session that isn't in the
    /// loaded list, so the user can still reach the pending prompt.
    func requestPresentation() {
        presentationRequestToken &+= 1
    }

    /// The stored-session id for a given runtime `session_id`, if any accumulated
    /// item carries that mapping. Push payloads carry the **runtime** session id;
    /// `SessionStore.open(_:)` needs the **stored** id, so this bridges the two
    /// using the broadcast prompts the inbox already holds.
    func storedSessionId(forRuntime sessionId: String) -> String? {
        items.first { $0.sessionId == sessionId }?.storedSessionId
    }

    private var connection: ConnectionStore?
    private var cache: CacheStore?
    private var activeScope: CacheScope?
    private var metadata: AttentionReconciliationMetadata?
    private var persistenceTail: Task<Void, Never>?
    private var reconciliationTask: Task<Void, Never>?

    /// Called only after a database transaction commits, allowing the widget to
    /// publish the exact same pending count as the rows just exposed here.
    var onCommittedSnapshot: ((AttentionSnapshot) -> Void)?

    init() {}

    /// Wire up the gateway client back-reference. Called exactly once by
    /// `AppEnvironment`.
    func attach(connection: ConnectionStore) {
        self.connection = connection
    }

    func attachCache(_ cache: CacheStore) {
        self.cache = cache
    }

    private var currentScope: CacheScope? {
        let connected = connection?.serverURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = UserDefaults.standard.string(forKey: DefaultsKeys.serverURL)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let server = (connected?.isEmpty == false ? connected : saved), !server.isEmpty else { return nil }
        let profile = UserDefaults.standard.string(forKey: DefaultsKeys.activeProfile)
            ?? DefaultsKeys.allProfilesScope
        return CacheScope(serverId: server, profileId: profile)
    }

    // MARK: - Cache-first hydration / reconciliation

    /// Paint the saved gateway's committed rows before bootstrap performs any
    /// probe or opens the WebSocket.
    func hydrateCachedGateway() async {
        guard let scope = currentScope else { return }
        await hydrate(scope: scope)
    }

    func hydrate(scope: CacheScope) async {
        guard let cache else { activeScope = scope; return }
        await persistenceTail?.value
        if activeScope?.serverId != scope.serverId {
            try? await cache.clearAttentionForOtherGateways(keepingServerId: scope.serverId)
        }
        guard let snapshot = try? await cache.loadAttentionSnapshot(scope: scope) else { return }
        activeScope = scope
        publish(snapshot)
    }

    /// Explicit/launch/foreground reconciliation entry point. A missing legacy
    /// endpoint is a soft fallback to live events; the committed cache remains.
    func refresh() async {
        guard let scope = currentScope else { return }
        if activeScope != scope { await hydrate(scope: scope) }
        guard let rest = connection?.rest else { return }
        await refresh(scope: scope, rest: rest)
    }

    func refresh(scope: CacheScope, rest: RestClient) async {
        if let reconciliationTask {
            await reconciliationTask.value
            if activeScope != scope { await refresh(scope: scope, rest: rest) }
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh(scope: scope, rest: rest)
        }
        reconciliationTask = task
        await task.value
        reconciliationTask = nil
    }

    private func performRefresh(scope: CacheScope, rest: RestClient) async {
        guard let cache else { return }
        await persistenceTail?.value
        let disk = try? await cache.loadAttentionSnapshot(scope: scope)
        let cursor = (activeScope == scope ? metadata?.cursor : nil) ?? disk?.metadata?.cursor
        do {
            let envelope = try await rest.pendingAttention(cursor: cursor)
            let snapshot = try await cache.applyPendingAttention(envelope, scope: scope)
            guard activeScope == nil || activeScope == scope else { return }
            activeScope = scope
            publish(snapshot)
        } catch RestError.badStatus(let code, _) where code == 404 || code == 405 {
            // Old gateway: live broadcasts remain the best available authority.
        } catch {
            // Offline/decoding failures retain the last indivisible disk snapshot.
        }
    }

    /// Drain queued WebSocket persistence before lifecycle teardown and in
    /// deterministic relaunch tests.
    func flushPersistence() async {
        await persistenceTail?.value
    }

    private func publish(_ snapshot: AttentionSnapshot) {
        metadata = snapshot.metadata
        items = snapshot.items.map(Self.item(from:))
        onCommittedSnapshot?(snapshot)
    }

    // MARK: - Event handling

    /// Route a gateway event into the inbox.
    ///
    /// `approval.request` / `clarify.request` are accumulated (deduped by id).
    /// `message.complete` expires any still-pending items for that event's
    /// session — the turn finished without the prompt being answered here, so
    /// it can no longer be acted on. All other event types are ignored.
    ///
    /// Unlike `ChatStore`, this is session-agnostic: it accepts prompts from
    /// every session the gateway broadcasts, which is the whole point of the
    /// inbox.
    func handle(event: GatewayEvent) {
        switch event.type {
        case .approvalRequest:
            ingestApproval(event)
            Task { await refresh() }
        case .clarifyRequest:
            ingestClarify(event)
            Task { await refresh() }
        case .messageComplete:
            if let sessionId = event.sessionId { expirePending(forSession: sessionId) }
            Task { await refresh() }
        default:
            break
        }
    }

    private func ingestApproval(_ event: GatewayEvent) {
        guard let sessionId = event.sessionId, !sessionId.isEmpty else { return }
        let request = ApprovalRequestPayload(payload: event.payload)
        let item = Item(
            id: request.id,
            sessionId: sessionId,
            storedSessionId: event.storedSessionId,
            kind: .approval,
            payload: .approval(request),
            receivedAt: Date(),
            state: .pending
        )
        insertLive(item)
    }

    private func ingestClarify(_ event: GatewayEvent) {
        guard let sessionId = event.sessionId, !sessionId.isEmpty else { return }
        let request = ClarifyRequestPayload(payload: event.payload)
        // Clarifications carry no wire id; key them by session so a repeat
        // clarify on the same runtime replaces the previous one rather than
        // stacking stale prompts.
        let item = Item(
            id: "clarify:\(sessionId)",
            sessionId: sessionId,
            storedSessionId: event.storedSessionId,
            kind: .clarify,
            payload: .clarify(request),
            receivedAt: Date(),
            state: .pending
        )
        insertLive(item)
    }

    /// Insert (or replace) an item, keeping the list newest-first. A repeat of
    /// the same id refreshes the payload and re-arms it as pending.
    private func insert(_ item: Item) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.insert(item, at: 0)
        }
    }

    private func insertLive(_ item: Item) {
        guard let persisted = Self.persisted(from: item) else { return }
        if let existing = items.first(where: { $0.id == item.id || $0.id == persisted.id }),
           existing.state == .responding || existing.state == .failedRetryable
            || existing.state == .resolvedElsewhere || existing.state == .expired {
            return
        }
        if cache != nil, activeScope ?? currentScope != nil {
            enqueuePersistence { cache, scope in
                try await cache.upsertLiveAttention(persisted, scope: scope)
            }
        } else {
            insert(item)
        }
    }

    /// Mark every still-pending item belonging to `sessionId` as expired.
    private func expirePending(forSession sessionId: String) {
        if cache != nil, activeScope ?? currentScope != nil {
            enqueuePersistence { cache, scope in
                try await cache.expireAttention(sessionId: sessionId, scope: scope)
            }
        } else {
            for index in items.indices where items[index].sessionId == sessionId && items[index].state.isVisible {
                items[index].state = .expired
            }
        }
    }

    // MARK: - Responses

    /// Answer an approval item against its **own** session, retaining durable
    /// retry/terminal state until server truth confirms the outcome.
    ///
    /// - Parameters:
    ///   - item: the inbox item to answer (must be `.approval`).
    ///   - approve: `true` to approve, `false` to deny.
    ///   - all: approve/deny all remaining requests in that turn.
    func respondApproval(_ item: Item, approve: Bool, all: Bool) async {
        guard case .approval = item.payload else { return }
        await commitState(id: item.id, state: .responding)
        guard let rest = connection?.rest else {
            await commitState(id: item.id, state: .failedRetryable)
            return
        }
        switch await rest.respondToApproval(
            sessionId: item.sessionId, approve: approve, all: all
        ) {
        case .resolved, .alreadyHandled:
            // The RPC response is authoritative server confirmation. Keep a
            // terminal row on disk so an older broadcast/snapshot cannot re-arm
            // it; the next delta tombstone advances the durable revision.
            await commitState(id: item.id, state: .resolvedElsewhere)
            await refresh()
        case .failed:
            await commitState(id: item.id, state: .failedRetryable)
        }
    }

    /// Answer a clarification item against its **own** session, retaining
    /// retry/terminal state until server truth confirms the outcome.
    ///
    /// The reply MUST echo the request's `request_id` — the gateway routes
    /// clarify answers via `_pending[request_id]` (`tui_gateway/server.py`
    /// `_respond`), and a reply without it 4009s ("no pending clarify
    /// request"), leaving the agent blocked on the prompt (ABH-46 item 2).
    func respondClarification(_ item: Item, answer: String) async {
        guard case .clarify(let request) = item.payload else { return }
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await commitState(id: item.id, state: .responding)
        guard let rest = connection?.rest, let requestId = request.requestId else {
            await commitState(id: item.id, state: .failedRetryable)
            return
        }
        switch await rest.respondToClarification(
            sessionId: item.sessionId,
            requestId: requestId,
            answer: trimmed
        ) {
        case .resolved, .alreadyHandled:
            await commitState(id: item.id, state: .resolvedElsewhere)
            await refresh()
        case .failed:
            await commitState(id: item.id, state: .failedRetryable)
        }
    }

    /// Drop an item without answering (user dismissed it).
    func dismiss(_ item: Item) {
        if cache != nil, activeScope ?? currentScope != nil {
            enqueuePersistence { cache, scope in
                try await cache.removeAttention(scope: scope, id: item.id)
            }
        } else {
            items.removeAll { $0.id == item.id }
        }
    }

    /// Drop all expired items — a tidy-up the view can offer.
    func clearExpired() {
        if cache != nil, activeScope ?? currentScope != nil {
            enqueuePersistence { cache, scope in
                try await cache.removeTerminalAttention(scope: scope)
            }
        } else {
            items.removeAll { $0.state == .expired || $0.state == .resolvedElsewhere }
        }
    }

    /// Privacy reset used by Forget Gateway. Repeated calls are harmless.
    func removeAll() {
        items.removeAll()
    }

    // MARK: - Response bookkeeping

    private func commitState(id: String, state: ItemState) async {
        guard let cache, let scope = activeScope ?? currentScope,
              let lifecycle = Self.lifecycle(from: state) else {
            if let index = items.firstIndex(where: { $0.id == id }) {
                items[index].state = state
            }
            return
        }
        await persistenceTail?.value
        if let snapshot = try? await cache.markAttentionState(id: id, state: lifecycle, scope: scope) {
            publish(snapshot)
        }
    }

    private func enqueuePersistence(
        _ operation: @escaping @Sendable (CacheStore, CacheScope) async throws -> AttentionSnapshot
    ) {
        guard let cache, let scope = activeScope ?? currentScope else { return }
        let previous = persistenceTail
        persistenceTail = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            if let snapshot = try? await operation(cache, scope),
               self.activeScope == nil || self.activeScope == scope {
                self.activeScope = scope
                self.publish(snapshot)
            }
        }
    }

    private static func item(from persisted: PersistedAttentionItem) -> Item {
        let payload: Payload
        if persisted.kind == "clarify" {
            var object: [String: JSONValue] = [
                "question": .string(persisted.detail.question ?? persisted.safeTitle),
                "choices": .array(persisted.detail.choices.map(JSONValue.string)),
                "request_id": .string(persisted.requestId),
            ]
            if persisted.requestId.isEmpty { object.removeValue(forKey: "request_id") }
            payload = .clarify(ClarifyRequestPayload(payload: .object(object)))
        } else {
            var object: [String: JSONValue] = [
                "id": .string(persisted.requestId),
                "title": .string(persisted.safeTitle),
            ]
            if let description = persisted.detail.description {
                object["description"] = .string(description)
            }
            payload = .approval(ApprovalRequestPayload(payload: .object(object)))
        }
        return Item(
            id: persisted.id,
            sessionId: persisted.sessionId,
            storedSessionId: persisted.storedSessionId,
            kind: persisted.kind == "clarify" ? .clarify : .approval,
            payload: payload,
            receivedAt: Date(timeIntervalSince1970: persisted.createdAt),
            state: state(from: persisted.state)
        )
    }

    private static func persisted(from item: Item) -> PersistedAttentionItem? {
        switch item.payload {
        case .approval(let request):
            return PersistedAttentionItem(
                id: request.id.hasPrefix("approval:") ? request.id : "approval:\(request.id)",
                requestId: request.id, sessionId: item.sessionId,
                storedSessionId: item.storedSessionId, kind: "approval",
                safeTitle: "Approval required",
                detail: .init(),
                createdAt: item.receivedAt.timeIntervalSince1970
            )
        case .clarify(let request):
            let requestId = request.requestId ?? item.sessionId
            return PersistedAttentionItem(
                id: requestId.hasPrefix("clarify:") ? requestId : "clarify:\(requestId)",
                requestId: requestId,
                sessionId: item.sessionId, storedSessionId: item.storedSessionId,
                kind: "clarify", safeTitle: "Clarification required",
                detail: .init(question: request.question, choices: request.choices),
                createdAt: item.receivedAt.timeIntervalSince1970
            )
        }
    }

    private static func state(from lifecycle: AttentionLifecycle) -> ItemState {
        switch lifecycle {
        case .pending: .pending
        case .responding: .responding
        case .resolvedElsewhere: .resolvedElsewhere
        case .expired: .expired
        case .failedRetryable: .failedRetryable
        }
    }

    private static func lifecycle(from state: ItemState) -> AttentionLifecycle? {
        switch state {
        case .pending: .pending
        case .responding: .responding
        case .resolvedElsewhere: .resolvedElsewhere
        case .expired: .expired
        case .failedRetryable: .failedRetryable
        }
    }

    /// Whether a respond error means the prompt was already resolved elsewhere
    /// (STR-291). The gateway's shared `_respond` helper returns RPC 4009
    /// "no pending <key> request" when the request id is already consumed —
    /// for `clarify.respond` that means the answer landed via another path
    /// (push-notification text-reply, another client, or a duplicate). Code
    /// 4009 is also used for "session busy", so the message must match too.
    func isAlreadyResolvedError(_ error: Error) -> Bool {
        guard case .rpc(let code, let message) = error as? GatewayError,
              code == 4009,
              message.contains("no pending") else { return false }
        return true
    }
}
