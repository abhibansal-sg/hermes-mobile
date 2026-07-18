import Foundation

// Wave-2 relay client — the item store (docs/RELAY-PHONE-PROTOCOL.md §2/§4).
// ADDITIVE: this is the NEW relay path's reducer, parallel to the legacy
// GatewayEvent/ChatStore blob path. The app is not wired to it yet (a later
// convergence wave flips the transport). Nothing here touches the legacy path.

/// The client-side item store (RELAY-PHONE-PROTOCOL §2/§4): a pure, value-type
/// reducer that folds the relay's `started → delta* → completed` item lifecycle
/// into the current item set, keyed by `item_id`, where **`completed` is
/// authoritative** — it replaces whatever deltas accumulated.
///
/// Determinism + idempotency are the whole point. Re-applying an already-seen
/// frame (a `resync` that re-sends frames the phone already folded in) converges
/// to the exact same state, so reconnection reconciliation is gap-free: the
/// phone paints optimistically off deltas and self-heals on `item.completed` /
/// `snapshot` (§4).
struct RelayItemStore: Sendable, Equatable {
    /// Items keyed by `item_id`.
    private(set) var itemsByID: [String: ChatItem] = [:]
    /// First-seen order of item ids. Items that share (or lack) an `ord` still
    /// render deterministically in arrival order.
    private(set) var arrivalOrder: [String] = []
    /// Highest downstream `seq` folded in — the ack / replay watermark (§4).
    private(set) var lastSeq: Int = 0

    init() {}

    /// The current items in render order: by `ord` ascending, ties broken by
    /// first-seen arrival order (a stable sort key, so streaming never reshuffles
    /// equal-`ord` rows).
    var items: [ChatItem] {
        arrivalOrder
            .compactMap { itemsByID[$0] }
            .enumerated()
            .sorted { lhs, rhs in
                lhs.element.ord != rhs.element.ord
                    ? lhs.element.ord < rhs.element.ord
                    : lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    // MARK: - Seq admission (§4)

    /// How an incoming `seq` relates to what the store has already folded in.
    /// The client uses this to decide whether a live gap warrants a `resync`.
    enum SeqAdmission: Sendable, Equatable {
        /// `seq == lastSeq + 1` — the dense, expected case.
        case inOrder
        /// `seq <= lastSeq` — already applied; a harmless idempotent re-apply
        /// (e.g. a replayed frame after `resync`).
        case duplicate
        /// `seq > lastSeq + 1` — one or more frames were missed. The payload is
        /// still applied optimistically; the caller should `resync` to backfill.
        case gap(missing: Range<Int>)
    }

    /// Classify a `seq` against the current watermark without mutating.
    func classify(seq: Int) -> SeqAdmission {
        if seq <= lastSeq { return .duplicate }
        if seq == lastSeq + 1 { return .inOrder }
        return .gap(missing: (lastSeq + 1)..<seq)
    }

    // MARK: - Reduction (§3)

    /// Fold one downstream frame into the store. Returns the `seq` classification
    /// so the client can trigger a `resync` on a gap. The payload is applied
    /// regardless of ordering: reduction is idempotent, so a duplicate re-applies
    /// harmlessly and a gap still paints optimistically until the backfill lands.
    @discardableResult
    mutating func apply(_ frame: RelayFrame) -> SeqAdmission {
        let admission = classify(seq: frame.seq)
        switch frame.kind {
        case .itemStarted:
            if let item = frame.item { applyStarted(item) }
        case .itemDelta:
            if let delta = frame.itemDelta { applyDelta(delta) }
        case .itemCompleted:
            if let item = frame.item { applyCompleted(item) }
        case .snapshot:
            if let snapshot = frame.snapshot { reconcile(snapshot: snapshot) }
        case .turnStarted, .turnCompleted, .approvalRequest, .clarifyRequest,
             .status, .title, .unknown:
            break   // non-item frame kinds carry no store mutation
        }
        if frame.seq > lastSeq { lastSeq = frame.seq }
        return admission
    }

    /// Fold a batch of frames in order (a `resync` replay or a fixture stream).
    mutating func apply<S: Sequence>(_ frames: S) where S.Element == RelayFrame {
        for frame in frames { apply(frame) }
    }

    // MARK: - Snapshot reconciliation (§4)

    /// Reconcile a `snapshot` (the resume-as-items payload replayed on
    /// `resync`/`open`) by `item_id` (§4). Every snapshot item is authoritative
    /// and replaces any local copy; items already present but absent from the
    /// snapshot are RETAINED — the snapshot is the resumed baseline, not a delete
    /// list. Idempotent: applying the same snapshot twice is a no-op.
    mutating func reconcile(snapshot: RelaySnapshot) {
        for item in snapshot.items {
            track(item.itemID)
            itemsByID[item.itemID] = item
        }
        // The snapshot cursor is the seq its items reflect; advance the watermark
        // so subsequent acks/gap-detection resume from there.
        if let cursor = snapshot.cursor, cursor > lastSeq { lastSeq = cursor }
    }

    // MARK: - Lifecycle folds

    private mutating func track(_ id: String) {
        if itemsByID[id] == nil { arrivalOrder.append(id) }
    }

    /// `item.started`: insert the skeleton only when the item is not already
    /// present. A late/duplicate `started` must never clobber an item that has
    /// accumulated deltas or already `completed` (completed is authoritative).
    private mutating func applyStarted(_ item: ChatItem) {
        guard itemsByID[item.itemID] == nil else { return }
        track(item.itemID)
        itemsByID[item.itemID] = item
    }

    /// `item.delta`: merge the patch into the item body (append streaming `text`,
    /// overwrite other fields). A delta after `completed` is ignored (authoritative).
    /// A delta for an unseen item materializes an in-progress placeholder so a
    /// dropped `started` still streams; a later `completed`/`snapshot` heals it.
    private mutating func applyDelta(_ delta: RelayItemDelta) {
        if let existing = itemsByID[delta.itemID] {
            guard !existing.isTerminal else { return }
            var updated = existing
            updated.body = Self.mergePatch(delta.patch, into: existing.body)
            itemsByID[delta.itemID] = updated
        } else {
            track(delta.itemID)
            itemsByID[delta.itemID] = ChatItem(
                itemID: delta.itemID,
                type: .toolCall,   // unknown until started/completed lands; generic fallback (§2)
                status: .inProgress,
                ord: 0,
                body: Self.mergePatch(delta.patch, into: .null)
            )
        }
    }

    /// `item.completed`: the FULL authoritative item replaces any local copy (§4).
    private mutating func applyCompleted(_ item: ChatItem) {
        track(item.itemID)
        itemsByID[item.itemID] = item
    }

    /// Merge a delta `patch` into an item body: APPEND the streaming `text` field
    /// (deltas accumulate prose token-by-token), OVERWRITE every other key.
    static func mergePatch(_ patch: JSONValue, into body: JSONValue) -> JSONValue {
        guard let patchObject = patch.objectValue else { return body }
        var merged = body.objectValue ?? [:]
        for (key, value) in patchObject {
            if key == "text", case .string(let addition) = value {
                let existing = merged["text"]?.stringValue ?? ""
                merged["text"] = .string(existing + addition)
            } else {
                merged[key] = value
            }
        }
        return .object(merged)
    }
}
