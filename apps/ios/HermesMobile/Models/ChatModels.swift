import Foundation

// UI-facing domain models built by ChatStore from gateway events and
// stored transcripts. Views render these; they never touch wire types.

enum ChatRole: String, Sendable {
    case user
    case assistant
    case system
    case tool
}

/// Ordered assistant-turn content, modeled after the desktop chat grammar but
/// rendered with native SwiftUI views.
///
/// `parts` is the SOLE source of truth for a message's content (ABH-87 Batch A
/// / contract §2.1). The former top-level scalar fields (`text/thinking/tools/
/// warning/usage`) are now read-only computed accessors derived from `parts`
/// (see `ChatMessage`), used only for copy/retry/checkpoint/export — never as a
/// render or write source. The desktop renders ONE ordered `parts[]` in strict
/// wire order; iOS now matches that with no parallel array.
enum ChatMessagePart: Identifiable, Sendable, Equatable {
    case reasoning(id: String, text: String)
    case tools(id: String, tools: [ToolActivity], collapsed: Bool, turnElapsed: TimeInterval?)
    case text(id: String, text: String)
    case warning(id: String, text: String)
    case usage(id: String, stats: UsageStats)

    var id: String {
        switch self {
        case .reasoning(let id, _),
             .tools(let id, _, _, _),
             .text(let id, _),
             .warning(let id, _),
             .usage(let id, _):
            return id
        }
    }
}

/// One transcript entry. Assistant messages accumulate streamed text,
/// thinking, and a tool-activity timeline into `parts` while `isStreaming` is
/// true.
struct ChatMessage: Identifiable, Sendable {
    /// How the entry is displayed.
    ///
    /// `.collapsed` renders as a dimmed disclosure row instead of a full
    /// bubble — used for machine scaffolding in stored transcripts (cron
    /// preambles, raw tool dumps, system prompts) that would otherwise
    /// drown the conversation.
    enum Presentation: Sendable, Equatable {
        case normal
        case collapsed(label: String)
    }

    let id: UUID
    let role: ChatRole
    // (deterministic-id factory defined in the extension below)
    /// Ordered assistant-turn parts — the SOLE content source of truth. This
    /// ordering IS visual order (desktop §4a). Empty for a freshly-created
    /// streaming bubble before its first delta lands.
    var parts: [ChatMessagePart]
    var isStreaming: Bool
    /// Settable so the seed producer can advance a coalesced turn's timestamp to
    /// its latest contributing wire row (desktop `active.timestamp = …`). Live
    /// streaming never reassigns it.
    var timestamp: Date
    var presentation: Presentation

    /// Seed convenience init: materializes scalar seed content into deterministic
    /// `parts` (reasoning → tools → text → warning → usage), the same fixed
    /// within-row order the desktop seed normalizer uses. This keeps existing
    /// call sites (user-message sends, the history seed mapper) working while
    /// `parts` remains the only stored representation. Batch B replaces the seed
    /// mapper with the full interleaving `toChatMessages` port; until then a
    /// seeded assistant row collapses to this fixed order, which is exactly the
    /// behavior the prior `legacyAssistantParts` projection produced.
    init(
        id: UUID = UUID(),
        role: ChatRole,
        parts: [ChatMessagePart] = [],
        text: String = "",
        thinking: String = "",
        tools: [ToolActivity] = [],
        isStreaming: Bool = false,
        usage: UsageStats? = nil,
        warning: String? = nil,
        timestamp: Date = Date(),
        presentation: Presentation = .normal
    ) {
        self.id = id
        self.role = role
        self.isStreaming = isStreaming
        self.timestamp = timestamp
        self.presentation = presentation

        if !parts.isEmpty {
            // Caller supplied an already-ordered part list (e.g. the future seed
            // producer). Trust it verbatim.
            self.parts = parts
        } else {
            // Materialize scalar seed content into deterministic parts. Ids are
            // derived from the message id so a re-seed of the same row yields
            // identical ids (no churn) — never `UUID()`.
            var seeded: [ChatMessagePart] = []
            if !thinking.isEmpty {
                seeded.append(.reasoning(id: "\(id.uuidString)-reasoning-0", text: thinking))
            }
            if !tools.isEmpty {
                seeded.append(.tools(
                    id: tools[0].id,
                    tools: tools,
                    collapsed: false,
                    turnElapsed: nil
                ))
            }
            if !text.isEmpty {
                seeded.append(.text(id: "\(id.uuidString)-text-0", text: text))
            }
            if let warning, !warning.isEmpty {
                seeded.append(.warning(id: "\(id.uuidString)-warning", text: warning))
            }
            if let usage {
                seeded.append(.usage(id: "\(id.uuidString)-usage", stats: usage))
            }
            self.parts = seeded
        }
    }
}

// MARK: - Deterministic seeded identity (ABH-87 Batch B, contract §2.2)

extension ChatMessage {
    /// A STABLE `UUID` derived from a deterministic seed key
    /// (`"{ts}-{index}-{role}"`). `ChatMessage.id` is a `UUID` (Batch A,
    /// deeply wired: `streamingMessageID`, `userOrdinals`, checkpoint restore),
    /// so the seed producer cannot use the raw string as the id — but reopening
    /// a session MUST yield the same id (ID-stability test #2). This folds the
    /// key's UTF-8 bytes into the 16 UUID bytes (a cheap deterministic digest;
    /// no crypto dependency), so the same wire row always maps to the same id
    /// while distinct rows effectively never collide. The seed key string itself
    /// is what every PART id is built from, so part identity is stable too.
    static func deterministicID(seedKey: String) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        // FNV-1a-style mix into each of the 16 slots, offset per byte so short
        // keys still spread across the whole UUID.
        var hash: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x100000001b3
        for (i, byte) in Array(seedKey.utf8).enumerated() {
            hash = (hash ^ UInt64(byte)) &* prime
            bytes[i % 16] ^= UInt8((hash >> UInt64((i % 8) * 8)) & 0xff)
        }
        // Stir once more so the trailing bytes reflect the whole key.
        for i in 0..<16 {
            hash = (hash ^ UInt64(bytes[i])) &* prime
            bytes[i] = bytes[i] ^ UInt8((hash >> 24) & 0xff)
        }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

// MARK: - Derived, read-only compatibility accessors (computed from `parts`)

extension ChatMessage {
    /// Ordered concatenation of `.text` part bodies. For Copy/Share/export/retry
    /// and branch seeds — always exactly the displayed prose (kills D10).
    var text: String {
        parts.reduce(into: "") { acc, part in
            if case .text(_, let t) = part { acc += t }
        }
    }

    /// Ordered concatenation of `.reasoning` part bodies.
    var thinking: String {
        parts.reduce(into: "") { acc, part in
            if case .reasoning(_, let t) = part { acc += t }
        }
    }

    /// All tool activities across every `.tools` cluster, in wire order.
    var tools: [ToolActivity] {
        parts.reduce(into: []) { acc, part in
            if case .tools(_, let cluster, _, _) = part { acc += cluster }
        }
    }

    /// First inline warning, if any.
    var warning: String? {
        for part in parts {
            if case .warning(_, let t) = part { return t }
        }
        return nil
    }

    /// First usage footer, if any.
    var usage: UsageStats? {
        for part in parts {
            if case .usage(_, let stats) = part { return stats }
        }
        return nil
    }

    /// True when any tool cluster was collapsed at completion (a ≥2-tool turn).
    var toolsCollapsed: Bool {
        parts.contains { part in
            if case .tools(_, _, let collapsed, _) = part { return collapsed }
            return false
        }
    }

    /// The wall-clock label attached to a collapsed cluster, if present.
    var turnElapsed: TimeInterval? {
        for part in parts {
            if case .tools(_, _, _, let elapsed) = part, let elapsed { return elapsed }
        }
        return nil
    }
}

// MARK: - Streaming / completion mutations (the only writers of `parts`)

extension ChatMessage {
    mutating func appendAssistantTextDelta(_ delta: String) {
        guard !delta.isEmpty else { return }
        if let index = parts.indices.last, parts[index].isText {
            guard case .text(let id, let existing) = parts[index] else { return }
            parts[index] = .text(id: id, text: existing + delta)
        } else {
            parts.append(.text(id: newRunID("text"), text: delta))
        }
    }

    mutating func appendReasoningDelta(_ delta: String) {
        guard !delta.isEmpty else { return }
        if let index = parts.indices.last, parts[index].isReasoning {
            guard case .reasoning(let id, let existing) = parts[index] else { return }
            parts[index] = .reasoning(id: id, text: existing + delta)
        } else {
            parts.append(.reasoning(id: newRunID("reasoning"), text: delta))
        }
    }

    /// Settle the authoritative final text (contract §2.5 / D4). The completion
    /// rule, in order:
    ///  1. No streamed text → append the final as one text part.
    ///  2. Final is a prefix-EXTENSION of concatenated streamed text → append the
    ///     missing tail. If a tool sits after the last text part, the tail is
    ///     post-tool prose and becomes a NEW trailing text part (never merged
    ///     into the earlier part — that would float it above the tool).
    ///  3. A SINGLE text run exists → replace it in place (keep its id/position).
    ///  4. MULTIPLE text runs are interleaved with tools → the streamed
    ///     interleaving is AUTHORITATIVE for order. Completion must NEVER move
    ///     prose across a tool boundary, so we do NOT fuse the runs into one
    ///     slot. We reconcile only the TRAILING text run with whatever the final
    ///     text adds beyond the earlier runs' concatenation; the leading runs and
    ///     their tool boundaries are left exactly as they streamed (kills D4).
    mutating func applyFinalText(_ finalText: String) {
        guard !finalText.isEmpty else { return }
        let existingText = parts.compactMap(\.textValue).joined()
        let textRunCount = parts.reduce(into: 0) { if case .text = $1 { $0 += 1 } }

        if parts.isEmpty || existingText.isEmpty {
            parts.append(.text(id: newRunID("text"), text: finalText))
            return
        }

        if finalText.hasPrefix(existingText), finalText.count > existingText.count,
           let lastTextIndex = parts.lastIndex(where: { $0.isText }) {
            // Case 2: authoritative final EXTENDS what streamed.
            let tail = String(finalText.dropFirst(existingText.count))
            if lastTextIndex == parts.indices.last {
                guard case .text(let id, let existing) = parts[lastTextIndex] else { return }
                parts[lastTextIndex] = .text(id: id, text: existing + tail)
            } else {
                parts.append(.text(id: newRunID("text"), text: tail))
            }
            return
        }

        guard finalText != existingText else { return }

        if textRunCount <= 1 {
            // Case 3: a single (or zero, handled above) text run — safe to replace
            // in place at its existing position.
            replaceTextParts(with: finalText)
            return
        }

        // Case 4: interleaved text↔tool runs and the final CONTRADICTS the
        // concatenation. Do not collapse across tool boundaries. Keep every
        // leading text run verbatim; reconcile only the trailing run so the
        // final's authoritative tail is honored without crossing a boundary.
        reconcileTrailingTextRun(towardFinal: finalText)
    }

    /// Reconcile the LAST text run with the authoritative final text when text is
    /// interleaved with tools. The earlier text runs (and the tool boundaries
    /// between them) are authoritative-by-stream and left untouched; only the
    /// trailing run is adjusted to carry the remainder of the final text that
    /// follows everything before it. If the final does not extend past the
    /// leading runs, the trailing run is replaced in place (still never moving
    /// prose across a boundary).
    private mutating func reconcileTrailingTextRun(towardFinal finalText: String) {
        guard let lastTextIndex = parts.lastIndex(where: { $0.isText }) else {
            parts.append(.text(id: newRunID("text"), text: finalText))
            return
        }
        // Concatenate every text run BEFORE the trailing one — these stay fixed.
        let leading = parts[..<lastTextIndex]
            .compactMap(\.textValue)
            .joined()
        let id = parts[lastTextIndex].id
        if finalText.hasPrefix(leading), finalText.count >= leading.count {
            // The final agrees with the leading runs; the trailing run carries
            // the remainder (which may itself be empty → drop to an empty-safe
            // value, but keep the part so identity/position is preserved).
            let remainder = String(finalText.dropFirst(leading.count))
            parts[lastTextIndex] = .text(id: id, text: remainder)
        } else {
            // The final diverges even from the leading prose; we cannot safely
            // re-segment without crossing a boundary, so overwrite ONLY the
            // trailing run in place and leave the leading runs as streamed. This
            // is the conservative no-cross-boundary settle.
            parts[lastTextIndex] = .text(id: id, text: finalText)
        }
    }

    /// Settle the authoritative final reasoning IN PLACE at the position it
    /// streamed (contract §2.5 / D3). The gateway's `message.complete.reasoning`
    /// is the complete settled text; a throttled/broadcast client may have missed
    /// deltas. The desktop dedupe rule (use-message-stream.ts:453-468): drop a
    /// streamed reasoning run whose normalized text is a prefix of (or is
    /// prefixed by) the final, and keep wire order — never yank reasoning to the
    /// top. Reasoning that streamed AFTER an early text/tool stays exactly where
    /// it streamed.
    mutating func applyFinalReasoning(_ finalReasoning: String) {
        guard !finalReasoning.isEmpty else { return }
        if let index = parts.firstIndex(where: { $0.isReasoning }) {
            // Replace the existing reasoning run in place — same id (ForEach /
            // disclosure identity), same index. We collapse any extra reasoning
            // runs (rare; reasoning is a single leading block on the wire) into
            // this one slot WITHOUT moving it: remove the trailing duplicates
            // first, then overwrite the anchor in position.
            let id = parts[index].id
            var i = parts.count - 1
            while i > index {
                if parts[i].isReasoning { parts.remove(at: i) }
                i -= 1
            }
            parts[index] = .reasoning(id: id, text: finalReasoning)
        } else {
            // No reasoning streamed: open a deterministic reasoning run at the
            // FRONT of the bubble (reasoning leads a turn on the wire — desktop
            // within-row order — and there is no streamed position to honor).
            parts.insert(.reasoning(id: newRunID("reasoning"), text: finalReasoning), at: 0)
        }
    }

    mutating func upsertToolActivity(_ activity: ToolActivity) {
        if updateToolPart(activityID: activity.id, transform: { $0 = activity }) {
            return
        }
        if let last = parts.indices.last,
           case .tools(let id, var cluster, let collapsed, let elapsed) = parts[last] {
            cluster.append(activity)
            parts[last] = .tools(id: id, tools: cluster, collapsed: collapsed, turnElapsed: elapsed)
        } else {
            // New cluster: id is the first tool's `tool_call_id` (wire-stable
            // across live and seed, contract §2.2), NOT `UUID()`.
            parts.append(.tools(
                id: activity.id,
                tools: [activity],
                collapsed: false,
                turnElapsed: nil
            ))
        }
    }

    mutating func updateToolActivity(id activityID: String, _ transform: (inout ToolActivity) -> Void) {
        _ = updateToolPart(activityID: activityID, transform: transform)
    }

    /// Collapse the finished turn's tool clusters into summary capsules.
    ///
    /// PER-CLUSTER decision (ABH-87 Batch D / contract §3.2, fixes D8): each
    /// `.tools` cluster collapses independently iff IT has ≥2 tools — NOT on a
    /// turn-total count. So `text→toolA→text→toolB` (two single-tool clusters)
    /// leaves BOTH expanded (their lone rows render), while consecutive `toolA,
    /// toolB` (one two-tool cluster) collapses into a single "N tool calls"
    /// summary. This replaces the prior turn-total `collapse` boolean that
    /// stamped every cluster identically (which produced multiple "1 tool call"
    /// capsules).
    ///
    /// The whole-turn `turnElapsed` wall-clock is attached ONLY to clusters that
    /// actually collapse (it labels the summary capsule's "· Xs" tail); an
    /// expanded single-tool cluster has no summary to label and keeps the elapsed
    /// it already carried. The derived `toolsCollapsed` accessor stays correct: it
    /// is true iff ANY cluster collapsed.
    mutating func collapseFinishedToolClusters(turnElapsed: TimeInterval?) {
        for index in parts.indices {
            guard case .tools(let id, let cluster, _, let existingElapsed) = parts[index] else { continue }
            let collapse = cluster.count >= 2
            parts[index] = .tools(
                id: id,
                tools: cluster,
                collapsed: collapse,
                turnElapsed: collapse ? turnElapsed : existingElapsed
            )
        }
    }

    /// Write/replace the single inline `.warning` part. (The former dual-write to
    /// a legacy `warning` field is gone — the field is now derived from this part.)
    mutating func setWarningPart(_ warningText: String) {
        guard !warningText.isEmpty else { return }
        if let index = parts.firstIndex(where: { $0.isWarning }) {
            parts[index] = .warning(id: parts[index].id, text: warningText)
        } else {
            parts.append(.warning(id: "\(id.uuidString)-warning", text: warningText))
        }
    }

    /// Write/replace the single trailing `.usage` part. (The former dual-write to
    /// a legacy `usage` field is gone — the field is now derived from this part.)
    mutating func setUsagePart(_ usageStats: UsageStats?) {
        guard let usageStats else { return }
        if let index = parts.firstIndex(where: { $0.isUsage }) {
            parts[index] = .usage(id: parts[index].id, stats: usageStats)
        } else {
            parts.append(.usage(id: "\(id.uuidString)-usage", stats: usageStats))
        }
    }

    /// Deterministic id for a NEW run of `kind` (`text`/`reasoning`):
    /// `"{messageID}-{kind}-{runIndex}"` where `runIndex` is the ordinal of this
    /// run within the message. Because a same-kind run only ever opens when a
    /// different-kind part intervenes (consecutive-run rule, contract §2.2/§2.5),
    /// every existing part of `kind` is its own run, so the next run's ordinal is
    /// simply the current count of `kind` parts. A streamed run and its seeded
    /// counterpart for the same turn therefore compute the SAME id. NO `UUID()`.
    private func newRunID(_ kind: String) -> String {
        let runIndex = parts.reduce(into: 0) { acc, part in
            switch (kind, part) {
            case ("text", .text): acc += 1
            case ("reasoning", .reasoning): acc += 1
            default: break
            }
        }
        return "\(id.uuidString)-\(kind)-\(runIndex)"
    }

    // MARK: - Seed producer support (ABH-87 Batch B)
    //
    // These are the ONLY writers the history seed producer uses. They enforce the
    // SAME consecutive-run invariant the stream reducer does (contract §2.5 /
    // Batch A gate scrutiny note #1): a new `.tools` cluster only opens when a
    // non-tool part intervenes, so non-adjacent same-kind runs never collide on
    // their ordinal-derived ids.

    /// Append a single seed tool activity, extending the trailing cluster when it
    /// is adjacent (no intervening non-tool part), else opening a new cluster
    /// keyed by the activity's own `tool_call_id`.
    mutating func appendSeedToolActivity(_ activity: ToolActivity) {
        if let last = parts.indices.last,
           case .tools(let id, var cluster, let collapsed, let elapsed) = parts[last] {
            cluster.append(activity)
            parts[last] = .tools(id: id, tools: cluster, collapsed: collapsed, turnElapsed: elapsed)
        } else {
            parts.append(.tools(id: activity.id, tools: [activity], collapsed: false, turnElapsed: nil))
        }
    }

    /// Append already-ordered seed parts, coalescing across the boundary so the
    /// consecutive-run invariant holds: a leading `.tools` part of the incoming
    /// run extends an adjacent trailing cluster instead of opening a duplicate
    /// run; everything else appends verbatim (the producer never hands two
    /// adjacent same-kind text/reasoning parts here — they are merged at the row
    /// level — so no ordinal-id collision is possible).
    mutating func appendSeedParts(_ incoming: [ChatMessagePart]) {
        for part in incoming {
            if case .tools(_, let cluster, _, _) = part,
               let last = parts.indices.last,
               case .tools = parts[last] {
                for activity in cluster { appendSeedToolActivity(activity) }
            } else {
                parts.append(part)
            }
        }
    }

    /// Merge a stored tool-result onto a pending tool activity in this message,
    /// matching by `tool_call_id` (then `tool_name`). Returns true if merged.
    mutating func mergeSeedToolResult(
        matching callId: String?,
        name: String,
        preview: String,
        failed: Bool,
        todos: [JSONValue]?
    ) -> Bool {
        for index in parts.indices {
            guard case .tools(let id, var cluster, let collapsed, let elapsed) = parts[index] else { continue }
            let toolIndex: Int?
            if let callId {
                toolIndex = cluster.firstIndex { $0.id == callId }
            } else {
                // Match the first not-yet-resolved activity of this name.
                toolIndex = cluster.firstIndex { $0.name == name && $0.state == .running }
            }
            guard let ti = toolIndex else { continue }
            cluster[ti].resultPreview = preview
            cluster[ti].state = failed ? .failed : .done
            cluster[ti].todos = todos
            parts[index] = .tools(id: id, tools: cluster, collapsed: collapsed, turnElapsed: elapsed)
            return true
        }
        return false
    }

    private mutating func replaceTextParts(with finalText: String) {
        guard let lastTextIndex = parts.lastIndex(where: { $0.isText }) else {
            parts.append(.text(id: newRunID("text"), text: finalText))
            return
        }
        // Coalesce all text into the LAST text part's position (keeping its id for
        // ForEach/scroll identity), not the first — collapsing to the first index
        // would float the merged settled text ABOVE any interleaved tools on a
        // mirrored turn that received text→tool→text, lying about the order
        // (review fix #4). The last text part already sits after those tools.
        let textID = parts[lastTextIndex].id
        // Count text parts before the anchor so the insertion index stays valid
        // once the earlier text parts are removed.
        let removedBefore = parts[..<lastTextIndex].filter { $0.isText }.count
        parts.removeAll(where: { $0.isText })
        let insertIndex = max(0, min(lastTextIndex - removedBefore, parts.count))
        parts.insert(.text(id: textID, text: finalText), at: insertIndex)
    }

    private mutating func updateToolPart(
        activityID: String,
        transform: (inout ToolActivity) -> Void
    ) -> Bool {
        for index in parts.indices {
            guard case .tools(let id, var cluster, let collapsed, let elapsed) = parts[index],
                  let toolIndex = cluster.firstIndex(where: { $0.id == activityID })
            else { continue }
            transform(&cluster[toolIndex])
            parts[index] = .tools(id: id, tools: cluster, collapsed: collapsed, turnElapsed: elapsed)
            return true
        }
        return false
    }
}

private extension ChatMessagePart {
    var isReasoning: Bool {
        if case .reasoning = self { return true }
        return false
    }

    var isText: Bool {
        if case .text = self { return true }
        return false
    }

    var isWarning: Bool {
        if case .warning = self { return true }
        return false
    }

    var isUsage: Bool {
        if case .usage = self { return true }
        return false
    }

    var textValue: String? {
        if case .text(_, let text) = self { return text }
        return nil
    }
}

/// One tool call in an assistant turn (start → progress* → complete).
struct ToolActivity: Identifiable, Sendable, Equatable {
    enum State: Sendable, Equatable {
        case running
        case done
        case failed
    }

    /// `tool_call_id` from the gateway.
    let id: String
    let name: String
    var argsSummary: String
    var progressText: String
    var resultPreview: String
    var state: State
    var durationMs: Double?
    /// Structured todo list, retained verbatim from `tool.complete`'s full
    /// `result.todos` (the gateway also mirrors it to `payload.todos`). The
    /// TodoCardView renders from THIS, never from the 300-char-truncated
    /// `resultPreview` — a real todo list overflows the preview and its JSON
    /// re-parse would fail, leaving the card blank. `nil` for non-todo tools.
    var todos: [JSONValue]?

    /// Human-friendly one-liner for collapsed rows.
    var summaryLine: String {
        switch state {
        case .running: return progressText.isEmpty ? "Running…" : progressText
        case .done:
            if let durationMs {
                return String(format: "Done in %.1fs", durationMs / 1000)
            }
            return "Done"
        case .failed: return "Failed"
        }
    }
}

/// An approval the user must answer, bound to its session.
struct PendingApproval: Identifiable, Sendable, Equatable {
    let id: String
    let sessionId: String
    let request: ApprovalRequestPayload
}

/// A clarification the user must answer, bound to its session.
struct PendingClarification: Sendable, Equatable {
    let sessionId: String
    let request: ClarifyRequestPayload
}
