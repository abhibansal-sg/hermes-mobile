import Foundation

// The Wave-2 item model (docs/RELAY-PHONE-PROTOCOL.md §2) — the unit the phone
// renders. A turn is an ordered list of `ChatItem`s, each with a stable
// `item_id` and a `started → delta* → completed` lifecycle where `completed`
// is AUTHORITATIVE (replaces whatever deltas accumulated). This is the shared
// foundation both the render lane and the client lane build against.

// MARK: - Item type (§2)

/// The item backbone: a generic tool card + a handful of special renders. The
/// relay assigns `type` from the raw event / tool `name`. Forward-compatibility
/// rule (§2): ANY unrecognized `type` decodes to `.toolCall`, so a new Hermes
/// tool never breaks the phone.
enum ChatItemType: String, Sendable, Equatable, CaseIterable, Codable {
    case userMessage    // the submitted prompt — right-aligned bubble
    case agentMessage   // message.delta/complete — markdown text, streams
    case reasoning      // reasoning.delta/available — collapsible "thinking"
    case toolCall       // GENERIC: ANY tool.start/complete keyed by `name`
    case taskList       // the `todo` tool — ONE living checklist on a stable id
    case fileChange     // tool.complete.inline_diff present — diff render
    case image          // image_generate / attachment / md image — inline image
    case browser        // browser_* name family — screenshot/snapshot render
    case error          // error event / failed tool — never hidden in a collapse
    case usage          // message.complete.usage — turn footer

    /// Decode a wire `type`, mapping anything unrecognized to the generic tool
    /// card (§2 forward-compat rule). `.taskList` is the ONE tool the relay
    /// does NOT collapse into `.toolCall` (§2 taskList semantics) — it has a
    /// dedicated render + drives the Turn Dock's task box via the ChatStore
    /// latest-todo accessor (N4/A5).
    init(wire: String) {
        self = ChatItemType(rawValue: wire) ?? .toolCall
    }
}

/// Item lifecycle status (§2). Unknown / missing decodes to `.inProgress`.
enum ChatItemStatus: String, Sendable, Equatable, Codable {
    case inProgress = "in_progress"
    case completed
    case failed

    init(wire: String) {
        self = ChatItemStatus(rawValue: wire) ?? .inProgress
    }
}

/// One rendered item (§2):
/// `{ item_id, type, status, ord, summary, body }`.
///
/// `rawType` preserves the original wire `type` string even when `type` folded
/// an unknown value to `.toolCall`, so the generic tool card can still key off
/// the true tool name and nothing is lost on round-trip.
struct ChatItem: Sendable, Equatable, Identifiable, Codable {
    let itemID: String
    let type: ChatItemType
    /// The wire `type` verbatim (may differ from `type.rawValue` for an unknown
    /// tool folded to `.toolCall`).
    let rawType: String
    var status: ChatItemStatus
    /// Position of the item within its turn (the render order key).
    var ord: Int
    /// One-line summary for collapsed rows / accessibility.
    var summary: String?
    /// Type-specific payload (args/result/text/diff/usage/…), kept untyped and
    /// projected by the accessors below.
    var body: JSONValue
    /// QA-3 S8/A4 — LOCAL liveness settle marker (NEVER a wire field, hence not
    /// in ``CodingKeys``). Set by ``RelayItemStore/settleInProgressLocally()``
    /// when the per-turn liveness watchdog force-settles a dead turn's stuck
    /// `.inProgress` items: they become terminal for the render lane and the
    /// projection folds them as a MUTED "Interrupted" section (never an error
    /// banner — C3). Provisional by design: any later authoritative frame for
    /// the item (`item.completed` / a `snapshot` reconcile) REPLACES the whole
    /// item by id and clears this, so the truth always heals the local settle.
    var locallyInterrupted: Bool

    var id: String { itemID }

    init(
        itemID: String,
        type: ChatItemType,
        rawType: String? = nil,
        status: ChatItemStatus,
        ord: Int,
        summary: String? = nil,
        body: JSONValue = .null,
        locallyInterrupted: Bool = false
    ) {
        self.itemID = itemID
        self.type = type
        self.rawType = rawType ?? type.rawValue
        self.status = status
        self.ord = ord
        self.summary = summary
        self.body = body
        self.locallyInterrupted = locallyInterrupted
    }

    private enum CodingKeys: String, CodingKey {
        case itemID = "item_id"
        case type, status, ord, summary, body
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.itemID = try c.decode(String.self, forKey: .itemID)
        let rawType = try c.decode(String.self, forKey: .type)
        self.rawType = rawType
        self.type = ChatItemType(wire: rawType)
        let rawStatus = try c.decodeIfPresent(String.self, forKey: .status)
        self.status = rawStatus.map(ChatItemStatus.init(wire:)) ?? .inProgress
        self.ord = try c.decodeIfPresent(Int.self, forKey: .ord) ?? 0
        self.summary = try c.decodeIfPresent(String.self, forKey: .summary)
        self.body = try c.decodeIfPresent(JSONValue.self, forKey: .body) ?? .null
        // Local-only liveness marker — never decoded from the wire.
        self.locallyInterrupted = false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(itemID, forKey: .itemID)
        // Encode `rawType` so an unknown-tool item round-trips its true wire type
        // rather than the folded `.toolCall`.
        try c.encode(rawType, forKey: .type)
        try c.encode(status.rawValue, forKey: .status)
        try c.encode(ord, forKey: .ord)
        try c.encodeIfPresent(summary, forKey: .summary)
        try c.encode(body, forKey: .body)
    }

    /// Convenience decode from an already-parsed `JSONValue` (snapshot items /
    /// item.started|completed bodies). Returns `nil` only when `item_id` is
    /// absent — every other field has a documented default.
    init?(json: JSONValue) {
        guard let itemID = json["item_id"]?.stringValue else { return nil }
        let rawType = json["type"]?.stringValue ?? ChatItemType.toolCall.rawValue
        self.init(
            itemID: itemID,
            type: ChatItemType(wire: rawType),
            rawType: rawType,
            status: json["status"]?.stringValue.map(ChatItemStatus.init(wire:)) ?? .inProgress,
            ord: json["ord"]?.intValue ?? 0,
            summary: json["summary"]?.stringValue,
            body: json["body"] ?? .null
        )
    }
}

// MARK: - Body projections

extension ChatItem {
    /// The tool `name` for a `toolCall`/`fileChange`/`browser`/`image` item —
    /// the discriminator the generic tool card keys off (§2). Falls back to the
    /// raw wire type when the body carries no explicit name.
    var toolName: String {
        body["name"]?.stringValue ?? rawType
    }

    /// The prose body for a text-bearing item (`agentMessage`/`reasoning`/
    /// `error`): `body.text` → `body.markdown` → `summary` → "".
    var textBody: String {
        body["text"]?.stringValue
            ?? body["markdown"]?.stringValue
            ?? summary
            ?? ""
    }

    /// Unified diff for a `fileChange` item (`body.inline_diff` → `body.diff`).
    var inlineDiff: String? {
        body["inline_diff"]?.stringValue ?? body["diff"]?.stringValue
    }

    /// Usage stats for a `usage` item (`body.usage` → `body`).
    var usageStats: UsageStats? {
        (body["usage"] ?? body).decoded(as: UsageStats.self)
    }

    /// The parsed task list for a `.taskList` item (RELAY-PHONE-PROTOCOL §2 —
    /// the relay-side `todo` tool, ONE living checklist per session driven
    /// through the normal item lifecycle on a stable `<sid>:tasks` id). Body
    /// shape: `{ tasks:[{id,text,status}], counts, all_complete }`. Returns
    /// `nil` for any non-`.taskList` item or a body that yields no parseable
    /// list (empty / malformed) — so callers fall through to the prior list
    /// instead of clobbering the dock with nothing, mirroring the legacy
    /// `latestTodo` scan's skip-empty semantics.
    var taskListBody: TodoList? {
        guard type == .taskList, let tasks = body["tasks"]?.arrayValue else { return nil }
        return TodoList(todosArray: tasks)
    }

    var isTerminal: Bool { status == .completed || status == .failed }
}

// MARK: - Item → render part mapping (§2, ChatMessagePart compat layer)

extension ChatItem {
    /// Project this item onto a `ChatMessagePart` for the assistant transcript.
    ///
    /// KNOWN text-shaped kinds reuse the EXISTING legacy renderers so nothing
    /// about today's rendering changes: `agentMessage → .text`,
    /// `reasoning → .reasoning`, `usage → .usage`. The NEW special-render kinds
    /// (`toolCall`/`taskList`/`fileChange`/`image`/`browser`/`error`) route
    /// through the new item-backed `.item` case, which the render lane draws.
    ///
    /// `userMessage` returns `nil`: it is the right-aligned user bubble (a
    /// separate `ChatMessage`, role `.user`), not an assistant-turn part.
    var renderPart: ChatMessagePart? {
        switch type {
        case .userMessage:
            return nil
        case .agentMessage:
            return .text(id: itemID, text: textBody)
        case .reasoning:
            return .reasoning(id: itemID, text: textBody)
        case .usage:
            guard let stats = usageStats else { return .item(id: itemID, item: self) }
            return .usage(id: itemID, stats: stats)
        case .toolCall, .taskList, .fileChange, .image, .browser, .error:
            return .item(id: itemID, item: self)
        }
    }
}

// MARK: - Client-lane delivery seam (§4 / §7)

/// The sink a relay client delivers each decoded, `seq`-ordered frame to. The
/// CLIENT lane produces frames (live transport or mock) and invokes this on the
/// main actor as they arrive; the RENDER/STORE lane implements it (feeding the
/// item reducer). This callback is the exact seam between the two lanes.
typealias RelayFrameHandler = @MainActor @Sendable (RelayFrame) -> Void

/// A source of relay frames (§3). Both the live WS client and the mock harness
/// conform; downstream code targets this protocol, never a concrete transport,
/// so the render lane can build/preview/test against the mock with zero
/// relay-internals dependency (§7).
protocol RelayItemSource: Sendable {
    /// Stream frames to `onFrame` in `seq` order until the source completes or
    /// the surrounding task is cancelled.
    func run(onFrame: @escaping RelayFrameHandler) async
}
