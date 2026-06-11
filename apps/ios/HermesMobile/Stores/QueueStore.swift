import Foundation

/// Persistent FIFO outbox for user prompts.
///
/// `QueueStore` serves a double duty:
///
/// 1. **Queue** — when the agent is mid-turn (`ChatStore.isStreaming`), the user
///    can still line up follow-up prompts; they are held here and sent one at a
///    time as soon as the agent goes idle.
/// 2. **Offline outbox** — prompts composed while the device is disconnected are
///    enqueued here and survive app restarts (persisted as JSON in
///    `UserDefaults` under `"hermes.queue"`). On reconnect the integrator calls
///    ``drain(chat:)`` and the backlog flushes in order.
///
/// Every mutation (`enqueue`, `update`, `remove`, and the dequeue inside
/// ``drain(chat:)``) is written through to `UserDefaults` immediately, so the
/// outbox is crash-safe: a prompt that was accepted is never silently lost, and
/// a prompt that was sent is never sent twice across a relaunch.
///
/// This store deliberately knows nothing about *when* to drain. It does not
/// observe connection state or streaming and installs no triggers — the
/// integrator wires ``drain(chat:)`` to the appropriate moments (reconnect,
/// turn completion, manual flush). It only guarantees that a drain it is asked
/// to perform respects FIFO order and stops the instant the agent starts
/// streaming again.
@MainActor
@Observable
final class QueueStore {
    /// A single queued prompt awaiting send. `Codable` so the whole queue can be
    /// round-tripped through `UserDefaults`.
    struct QueuedPrompt: Identifiable, Codable, Equatable, Sendable {
        let id: UUID
        var text: String
        let createdAt: Date
        /// The STORED session this prompt was composed for. ``drain(chat:)``
        /// sends it only while that session is active — a prompt queued for A
        /// must never be delivered into B after a mid-stream session switch
        /// (R1 #17: misrouted destructive prompts). `nil` (including every
        /// item persisted before this field existed — `Codable` decodes the
        /// missing key as nil) means "no session affinity": deliver wherever
        /// active, the legacy behavior.
        let storedSessionId: String?

        init(
            id: UUID = UUID(),
            text: String,
            createdAt: Date = Date(),
            storedSessionId: String? = nil
        ) {
            self.id = id
            self.text = text
            self.createdAt = createdAt
            self.storedSessionId = storedSessionId
        }
    }

    /// The pending prompts, oldest first (FIFO send order).
    private(set) var items: [QueuedPrompt] = []

    /// True while a ``drain(chat:)`` is in progress, so callers (and the
    /// integrator) can avoid kicking off overlapping drains.
    private(set) var isDraining = false

    private let defaults: UserDefaults

    /// - Parameter defaults: the backing store for persistence. Defaults to
    ///   `.standard`; injectable so tests can use an isolated suite.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: - Mutation (each persists immediately)

    /// Append a prompt to the back of the queue. Empty/whitespace-only text is
    /// ignored. Returns the queued prompt, or `nil` if nothing was queued.
    /// `storedSessionId` stamps the prompt with the session it was composed
    /// for (R1 #17); pass nil only when no session is active (draft/offline
    /// bootstrap), which keeps the deliver-anywhere legacy behavior.
    @discardableResult
    func enqueue(_ text: String, storedSessionId: String? = nil) -> QueuedPrompt? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let prompt = QueuedPrompt(text: trimmed, storedSessionId: storedSessionId)
        items.append(prompt)
        persist()
        return prompt
    }

    /// Edit the text of a queued prompt in place. No-op if `id` isn't queued or
    /// the new text is empty/whitespace-only (use ``remove(id:)`` to delete).
    func update(id: UUID, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].text = trimmed
        persist()
    }

    /// Remove a queued prompt by id. No-op if it isn't present.
    func remove(id: UUID) {
        guard items.contains(where: { $0.id == id }) else { return }
        items.removeAll { $0.id == id }
        persist()
    }

    /// Drop the entire queue.
    func removeAll() {
        guard !items.isEmpty else { return }
        items.removeAll()
        persist()
    }

    // MARK: - Draining

    /// Send queued prompts through `chat` in FIFO order, one at a time.
    ///
    /// Session affinity (R1 #17): a prompt stamped with a `storedSessionId` is
    /// sent only while that session is the active one — mismatched prompts are
    /// skipped (left queued, order preserved) until their session is reopened.
    /// Unstamped (legacy) prompts deliver into whatever session is active.
    ///
    /// Each eligible prompt is removed from the queue *before* it is handed to
    /// `chat.send` and persisted at that point, so a crash mid-send cannot
    /// resurrect an already-dispatched prompt. Acceptance is `send`'s RETURN
    /// VALUE — the server's own `prompt.submit` ack. It is deliberately NOT
    /// inferred from `chat.isStreaming`: that flag is flipped by the separate
    /// event-router task (the accepted turn's `message.start` may not have
    /// been routed yet when `send` returns) and is cleared by a concurrent
    /// `open()/reset()` mid-RPC — both inferences re-enqueued a prompt the
    /// server had already delivered, i.e. a double-send (ABH-48 judge round).
    /// - accepted → pause with the backlog intact, resumed by the next
    ///   turn-completion trigger.
    /// - not accepted ("Agent is busy" 4009, the post-switch "No active
    ///   session" window, transport error) → the prompt is RE-ENQUEUED at its
    ///   original position and the drain stops — burning through the backlog
    ///   against the same failure was guaranteed data loss (R1 #10/#50); the
    ///   next trigger (turn completion, reconnect, manual flush) retries from
    ///   intact state.
    ///
    /// Drained sends are text-only (`includeAttachments: false`): a prompt
    /// composed earlier must never grab whatever attachments happen to be
    /// pending at drain time — attachments ride only the user's live sends.
    ///
    /// Re-entrancy is guarded by ``isDraining``; a second call while one is in
    /// flight returns immediately.
    func drain(chat: ChatStore) async {
        guard !isDraining else { return }
        // Already streaming: nothing to do now; resume on the next trigger.
        guard !chat.isStreaming else { return }
        isDraining = true
        defer { isDraining = false }

        var index = 0
        while index < items.count, !chat.isStreaming {
            let next = items[index]
            // Session affinity: skip (don't send, don't drop) a prompt queued
            // for a session that isn't the active one (R1 #17).
            if let stamped = next.storedSessionId,
               stamped != chat.activeStoredSessionId {
                index += 1
                continue
            }
            // Dequeue-before-send: a crash mid-send must not double-send.
            items.remove(at: index)
            persist()
            let accepted = await chat.send(text: next.text, includeAttachments: false)
            if accepted {
                // Delivered — the turn-completion trigger resumes the backlog.
                break
            }
            // Not accepted: restore the prompt where it was and stop (R1 #10/#50).
            items.insert(next, at: index)
            persist()
            break
        }
    }

    // MARK: - Persistence

    /// Load the persisted queue. Corrupt/decodable-mismatch data is discarded.
    private func load() {
        guard let data = defaults.data(forKey: DefaultsKeys.queue) else { return }
        guard let decoded = try? JSONDecoder().decode([QueuedPrompt].self, from: data) else {
            // Drop unreadable state rather than crash; an outbox that can't be
            // decoded is treated as empty.
            defaults.removeObject(forKey: DefaultsKeys.queue)
            return
        }
        items = decoded
    }

    /// Write the current queue back to `UserDefaults`. An empty queue clears the
    /// key entirely so a stale blob never lingers.
    private func persist() {
        guard !items.isEmpty else {
            defaults.removeObject(forKey: DefaultsKeys.queue)
            return
        }
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: DefaultsKeys.queue)
    }
}
