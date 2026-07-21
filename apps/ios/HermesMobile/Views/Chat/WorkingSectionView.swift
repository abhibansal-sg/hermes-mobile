import SwiftUI

// Wave-2 collapsed working-sections (owner spec, built on the relay item model —
// docs/RELAY-PHONE-PROTOCOL.md §2), reworked to the APPROVED ChatGPT-style
// transcript language (mockups/transcript-full.html):
//
//   - SETTLED: the whole run collapses to a chrome-less one-line muted
//     "Worked for N" + a small chevron — NO box, border, gradient, or capsule.
//     Tapping expands a chrome-less vertical STEP LIST: a small monochrome
//     SF-symbol glyph (terminal-style for tool steps, thought-bubble for
//     reasoning) + a muted natural-language summary per step. Tapping any step
//     opens the "Thinking" SHEET (timeline rail + bold titles + reasoning text +
//     embedded command/output code cards). If any tool failed the row carries a
//     red failure badge so the failure is never hidden behind the fold (§2).
//   - LIVE (streaming) — RATIFIED Wave-2.5 single-line rule (QA-2 R5/R6/A3):
//     ONE collapsed line — "Working… ‹per-TURN timer›" with the current tool
//     inline once it resolves a friendly name — tap to expand the bifurcation
//     (thinking + tool timeline, the same step list the settled fold shows).
//     Nothing streams inline while live: no per-reasoning-run accordions (their
//     per-item 1 s timers and label+body double-print were R5/N4/N6), no
//     separate current-tool row, no reserved 172 pt thinking window (the R6
//     bands). The streaming caret in the answer bubble is THE progress signal;
//     the timer is per-TURN (from `ChatStore.turnStartedAt`), never per item.
//
// SINGLE-FOLD CONTRACT (owner QA, 2026-07-19): within ONE agent turn, EVERYTHING
// before the final answer text — reasoning segments, tool calls (BOTH the new
// `.item` work items AND the classic `.tools` clusters), and interim narration
// `.text` segments — folds under ONE working section. The FINAL answer text (the
// trailing `.text` run after the last work part) renders as the body. This applies
// to the CLASSIC `ChatMessagePart` path too (old / non-relay sessions), not only
// the item-layer path — the owner sees old sessions daily and the old anatomy
// (repeating italic "Thinking ›" rows + boxed tool cards alternating with interim
// prose) is exactly what this collapses.

// MARK: - Grouping + summary model (pure, deterministically testable)

/// One node in the assistant transcript after working-section grouping: either a
/// standalone part (rendered exactly as before) or a folded working run.
enum AssistantRenderNode: Identifiable, Equatable {
    case part(ChatMessagePart)
    case working(id: String, parts: [ChatMessagePart])

    var id: String {
        switch self {
        case .part(let part): return part.id
        case .working(let id, _): return "working-\(id)"
        }
    }
}

/// A single collapsed/sheet step derived from a working run's parts. Pure value
/// type (Sendable/Equatable) so the humanizer is unit-testable without a View.
struct WorkingStep: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable { case reasoning, tool, narration }

    let id: String
    let kind: Kind
    /// SF-symbol glyph name (monochrome) shown at the leading edge of the step.
    let glyph: String
    /// Muted natural-language one-liner for the collapsed step list.
    let summary: String
    /// Bold title for the Thinking sheet's timeline entry.
    let title: String
    /// Reasoning body / prose detail for the sheet (nil for pure tool steps).
    let body: String?
    /// Command / arguments code card for the sheet (nil when absent).
    let command: String?
    /// Language hint for the command code card.
    let commandLanguage: String?
    /// Result / output code card for the sheet (nil when absent).
    let output: String?
    /// Whether this step failed — drives the red glyph + badge.
    let isFailure: Bool
}

/// Grouping + summary logic for the collapsed working-sections. `nonisolated
/// static` throughout so every rule is unit-testable without a SwiftUI view or an
/// actor hop.
enum WorkingSectionModel {

    /// Whether a part represents WORK — the parts whose LAST occurrence marks the
    /// fold boundary (everything up to and including it collapses). Streamed
    /// `.reasoning`, the classic `.tools` cluster, and an item-backed work render
    /// (tool / file change / browser / image / error) all count. `.text` is NOT
    /// work — a trailing `.text` run is the final answer body; interim `.text`
    /// still folds because it sits BEFORE the last work part, not because it is
    /// eligible itself. `.usage` / `.warning` are footers and never work.
    nonisolated static func isWorkingEligible(_ part: ChatMessagePart) -> Bool {
        switch part {
        case .reasoning, .tools:
            return true
        case .item(_, let item):
            return isWorkingItem(item)
        case .text, .warning, .usage:
            return false
        }
    }

    /// Item types that render inside a working section. `agentMessage` / `usage` /
    /// `userMessage` project onto legacy parts and never arrive as `.item`, but
    /// are excluded defensively so only real work folds.
    nonisolated static func isWorkingItem(_ item: ChatItem) -> Bool {
        switch item.type {
        case .toolCall, .taskList, .fileChange, .browser, .image, .error, .reasoning:
            return true
        case .agentMessage, .usage, .userMessage:
            return false
        }
    }

    /// The index of the LAST work part (reasoning / classic tools / item work) in
    /// the turn — the fold boundary. `nil` when the turn is pure text/usage/warning
    /// (no work to fold).
    nonisolated static func lastWorkIndex(in parts: [ChatMessagePart]) -> Int? {
        parts.lastIndex(where: isWorkingEligible)
    }

    /// Coalesce the assistant's ordered `parts` into render nodes under the
    /// SINGLE-FOLD contract: everything up to and including the LAST work part
    /// folds into ONE `.working` node (reasoning + classic `.tools` + item work +
    /// any interim narration `.text` caught between them). Everything AFTER the last
    /// work part — the final answer `.text`, plus `.usage` / `.warning` footers —
    /// renders as standalone `.part` nodes. A turn with NO work part (pure prose)
    /// decomposes entirely to `.part` nodes, so a plain answer never grows a fold.
    ///
    /// O(n): one `lastIndex` scan + one pass. Streaming stays O(delta)-friendly —
    /// the fold node's id is pinned to the first part, so its `WorkingSectionView`
    /// (and its `@State`) keeps identity as later deltas append.
    nonisolated static func renderNodes(from parts: [ChatMessagePart]) -> [AssistantRenderNode] {
        guard let boundary = lastWorkIndex(in: parts) else {
            return parts.map(AssistantRenderNode.part)
        }
        var nodes: [AssistantRenderNode] = []
        let folded = Array(parts[...boundary])
        nodes.append(.working(id: folded[0].id, parts: folded))
        if boundary + 1 < parts.count {
            for part in parts[(boundary + 1)...] {
                nodes.append(.part(part))
            }
        }
        return nodes
    }

    /// The item parts of a run, in order.
    nonisolated static func items(in parts: [ChatMessagePart]) -> [ChatItem] {
        parts.compactMap { part in
            if case .item(_, let item) = part { return item }
            return nil
        }
    }

    /// Whether any tool in the run failed — a failed status OR an `error` item, in
    /// EITHER the item-layer parts or the classic `.tools` clusters. Drives the
    /// collapsed section's failure badge so a fold never hides a failure (§2).
    nonisolated static func runHasFailure(_ parts: [ChatMessagePart]) -> Bool {
        toolUnits(in: parts).contains(where: \.isFailure)
    }

    /// A single item is a failure iff its status is `.failed` or its type is
    /// `.error` (a failed tool surfaces as either on the wire).
    nonisolated static func isFailure(_ item: ChatItem) -> Bool {
        item.status == .failed || item.type == .error
    }

    // MARK: - Unified tool units (item-layer + classic `.tools`)

    /// A single tool-ish work unit flattened from either an item-layer work `.item`
    /// or one activity of a classic `.tools` cluster, so the live current-tool line
    /// and the failure badge treat both paths identically.
    struct WorkUnit: Equatable, Sendable {
        let summary: String
        let status: ChatItemStatus
        let isFailure: Bool
        /// Whether the unit's identity is still a RAW wire state token (QA-2
        /// N2: `tool.generating` / `review.summary` — the relay's pre-resolution
        /// event name). The live collapsed line reads "Working…" for raw units
        /// instead of surfacing internal state (C1); the humanized `summary`
        /// itself falls back to a neutral label, never the raw token.
        let raw: Bool
    }

    /// Flatten a run's tool work (NOT reasoning, NOT narration) into ordered units,
    /// spanning both the item-layer and the classic `.tools` clusters.
    nonisolated static func toolUnits(in parts: [ChatMessagePart]) -> [WorkUnit] {
        var out: [WorkUnit] = []
        for part in parts {
            switch part {
            case .item(_, let item) where isWorkingItem(item):
                out.append(WorkUnit(
                    summary: stepSummary(for: item),
                    status: item.status,
                    isFailure: isFailure(item),
                    raw: isRawStateName(item.toolName)
                        && (item.summary.map(isRawStateName) ?? true)
                ))
            case .tools(_, let tools, _, _):
                for tool in tools {
                    out.append(WorkUnit(
                        summary: legacyToolSummary(tool),
                        status: legacyStatus(tool.state),
                        isFailure: tool.state == .failed,
                        raw: isRawStateName(tool.name)
                    ))
                }
            default:
                continue
            }
        }
        return out
    }

    /// The current (most recent) tool unit shown while the turn is live: the last
    /// still-in-progress unit, else simply the last unit. `nil` when the run has no
    /// tool work at all (a pure-reasoning fold).
    nonisolated static func currentWork(in parts: [ChatMessagePart]) -> WorkUnit? {
        let units = toolUnits(in: parts)
        return units.last(where: { $0.status == .inProgress }) ?? units.last
    }

    /// Map a classic `ToolActivity.State` onto the item-layer status vocabulary so
    /// the live status glyph is shared across both paths.
    nonisolated static func legacyStatus(_ state: ToolActivity.State) -> ChatItemStatus {
        switch state {
        case .running: return .inProgress
        case .done: return .completed
        case .failed: return .failed
        }
    }

    /// Humanized one-liner for a classic `.tools` activity — prefers the tool's own
    /// derived `resultSummary`, else humanizes its name against its args preview.
    nonisolated static func legacyToolSummary(_ tool: ToolActivity) -> String {
        if let s = tool.resultSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            return shortTarget(s)
        }
        let target = tool.argsSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        return humanize(name: tool.name, target: target.isEmpty ? nil : target)
    }

    /// The tool `body.duration_s` for an item, if present.
    nonisolated static func duration(of item: ChatItem) -> TimeInterval? {
        item.body["duration_s"]?.doubleValue
    }

    /// Wall-clock seconds a settled working section took: the turn's stamped
    /// duration when known, else the sum of the items' own `duration_s`, else nil
    /// (the label then omits the time tail).
    nonisolated static func runDurationSeconds(
        _ parts: [ChatMessagePart],
        settled: TimeInterval?
    ) -> TimeInterval? {
        if let settled, settled > 0 { return settled }
        var summed = items(in: parts).reduce(into: 0.0) { acc, item in
            if let d = duration(of: item), d > 0 { acc += d }
        }
        // Classic `.tools` clusters carry their own per-activity `durationMs`.
        for part in parts {
            if case .tools(_, let tools, _, let turnElapsed) = part {
                if let turnElapsed, turnElapsed > 0 {
                    summed += turnElapsed
                } else {
                    for tool in tools where (tool.durationMs ?? 0) > 0 {
                        summed += (tool.durationMs ?? 0) / 1000
                    }
                }
            }
        }
        return summed > 0 ? summed : nil
    }

    /// The current (most recent) tool line shown while the turn is live: the last
    /// still-in-progress item, else simply the last item in the run.
    nonisolated static func currentWorkingItem(in parts: [ChatMessagePart]) -> ChatItem? {
        let its = items(in: parts)
        return its.last(where: { $0.status == .inProgress }) ?? its.last
    }

    /// "Worked for 12s" / "Worked for 2m 3s" / "Worked" (no known duration).
    /// A KNOWN sub-second duration still reads "Worked for 1s" — a turned-on
    /// duration never rounds down to a bare "Worked" (QA-2 R5: a stamped relay
    /// turn must show its time).
    nonisolated static func workedLabel(seconds: TimeInterval?) -> String {
        guard let seconds, seconds > 0 else { return "Worked" }
        let total = max(1, Int(seconds.rounded()))
        if total < 60 { return "Worked for \(total)s" }
        return "Worked for \(total / 60)m \(total % 60)s"
    }

    /// QA-3 S8/A4 — the settled fold label for a turn the LIVENESS fallback
    /// ended instead of a real completion: a dead turn (no frames + no
    /// completion past the liveness window) whose stuck items were
    /// force-settled — a prior turn a newer turn superseded (IMG_2591's
    /// eternal double-working), or the watchdog's silent resync recovered
    /// nothing. Muted "Interrupted" — HONEST, and never an error banner (C3).
    /// No duration: a dead turn has no honest end-to-end time.
    nonisolated static func settledLabel(seconds: TimeInterval?, interrupted: Bool) -> String {
        interrupted ? "Interrupted" : workedLabel(seconds: seconds)
    }

    /// VoiceOver label for the collapsed capsule: the worked label plus an
    /// explicit failure clause when the section hid a failed step.
    nonisolated static func summaryAccessibilityLabel(
        seconds: TimeInterval?,
        hasFailure: Bool,
        interrupted: Bool = false
    ) -> String {
        let base = settledLabel(seconds: seconds, interrupted: interrupted)
        return hasFailure ? "\(base), contains a failed step" : base
    }

    // MARK: - Step humanizer (deterministic, no LLM)

    /// The monochrome SF-symbol glyph for a step of the given item type.
    nonisolated static func glyph(for type: ChatItemType) -> String {
        switch type {
        case .fileChange: return "pencil"
        case .image: return "photo"
        case .browser: return "safari"
        case .error: return "exclamationmark.triangle"
        case .reasoning: return "bubble.left"
        case .taskList: return "checklist"
        case .toolCall, .agentMessage, .usage, .userMessage: return "terminal"
        }
    }

    /// The single most descriptive argument value for a tool item — the target a
    /// natural-language summary reads against (path / pattern / command / url).
    nonisolated static func primaryTarget(of item: ChatItem) -> String? {
        let args = item.body["args"]
        // NB: the tool's own `name` is its identity, not a target — never read it
        // here, or a nameless-arg tool would echo its name twice ("Foo foo").
        let keys = ["path", "file", "filename", "file_path", "pattern",
                    "query", "q", "command", "cmd", "url", "target"]
        for key in keys {
            if let value = args?[key]?.stringValue ?? item.body[key]?.stringValue {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    /// Whether a wire tool name / relay-supplied summary is a RAW internal state
    /// token rather than a human label — the dotted lowercase event names the
    /// relay emits before a tool resolves its friendly name (QA-2 N2:
    /// `tool.generating`, `review.summary` flashed in live rows for ≈1 s with a
    /// contradictory green ✓). These are never surfaced: the live line reads
    /// "Working…" and the humanizer falls back to a neutral label. A real tool
    /// name is snake/kebab-case (no dots); a friendly summary has spaces/case.
    nonisolated static func isRawStateName(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return true }
        guard t.contains(".") else { return false }
        return t.allSatisfy { $0.isLowercase || $0 == "." || $0 == "_" || $0.isNumber }
    }

    /// The collapsed LIVE line's label (QA-2 R5/A3, ratified Wave-2.5): plain
    /// "Working…" until the current tool resolves a friendly humanized summary,
    /// then the tool inline ("Working… · Read auth.py"). NEVER a raw state name
    /// (N2) — a raw unit reads as plain "Working…" until it resolves.
    nonisolated static func liveCollapsedLabel(parts: [ChatMessagePart]) -> String {
        guard let unit = currentWork(in: parts), !unit.raw else { return "Working…" }
        return "Working… · \(unit.summary)"
    }

    /// Collapse whitespace/newlines and cap length so a summary stays one line.
    nonisolated static func shortTarget(_ raw: String, limit: Int = 72) -> String {
        let flat = raw
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\t" })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        if flat.count <= limit { return flat }
        return String(flat.prefix(limit - 1)) + "…"
    }

    /// Title-case a snake/kebab tool name for the default humanized summary.
    nonisolated static func prettifyToolName(_ name: String) -> String {
        let spaced = name
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard let first = spaced.first else { return name }
        return first.uppercased() + spaced.dropFirst()
    }

    /// A muted natural-language one-liner for a tool item ("Ran alembic upgrade
    /// head", "Read auth.py", "Grepped for node_loop"). Prefers the relay-supplied
    /// `summary`; otherwise derives a verb from the tool name + primary target.
    /// Deterministic — no model calls.
    nonisolated static func stepSummary(for item: ChatItem) -> String {
        // A relay `summary` that is still a raw state token (`tool.generating`)
        // is NOT a label — fall through to the humanizer (QA-2 N2).
        if let s = item.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !s.isEmpty, !isRawStateName(s) {
            return shortTarget(s)
        }
        let target = primaryTarget(of: item)

        func verb(_ v: String, _ fallback: String) -> String {
            if let target { return "\(v) \(shortTarget(target))" }
            return fallback
        }

        switch item.type {
        case .fileChange: return verb("Edited", "Edited a file")
        case .browser: return verb("Opened", "Browsed a page")
        case .image: return "Generated an image"
        case .error: return target.map { "Error: \(shortTarget($0))" } ?? "Hit an error"
        default: break
        }

        return humanize(name: item.toolName, target: target)
    }

    /// Verb-from-name humanizer shared by the item-layer (`stepSummary`) and the
    /// classic-tool (`legacyToolSummary`) paths, so both derive the same natural
    /// language. `name` is passed in its ORIGINAL case (the pretty-name fallback
    /// preserves it); keyword matching lowercases internally.
    nonisolated static func humanize(name: String, target: String?) -> String {
        let lower = name.lowercased()
        // A still-raw dotted event name (QA-2 N2) must never reach the UI —
        // neutral fallback BEFORE the loose keyword matching (a raw name like
        // `review.summary` would otherwise false-match "view" → "Read …").
        if isRawStateName(name) {
            if let target { return "Working on \(shortTarget(target))" }
            return "Tool step"
        }
        func verb(_ v: String, _ fallback: String) -> String {
            if let target { return "\(v) \(shortTarget(target))" }
            return fallback
        }
        if lower.contains("read") || lower.contains("cat") || lower.contains("open") || lower.contains("view") {
            return verb("Read", "Read a file")
        }
        if lower.contains("grep") || lower.contains("search") || lower.contains("find")
            || lower.contains("ripgrep") || lower == "rg" {
            if let target { return "Grepped for \(shortTarget(target))" }
            return "Searched the codebase"
        }
        if lower.contains("write") || lower.contains("create") {
            return verb("Wrote", "Wrote a file")
        }
        if lower.contains("edit") || lower.contains("patch") || lower.contains("apply")
            || lower.contains("replace") || lower.contains("update") {
            return verb("Edited", "Edited a file")
        }
        if lower.contains("list") || lower == "ls" {
            return verb("Listed", "Listed files")
        }
        if lower.contains("run") || lower.contains("bash") || lower.contains("shell")
            || lower.contains("exec") || lower.contains("command") || lower.contains("terminal") {
            if let target { return "Ran \(shortTarget(target))" }
            return "Ran a command"
        }
        let pretty = prettifyToolName(name)
        if let target { return "\(pretty) \(shortTarget(target))" }
        return pretty
    }

    /// The command/arguments code-card body for a tool item's Thinking-sheet
    /// entry: an explicit `command`/`cmd` arg, else the compact args preview.
    nonisolated static func commandText(of item: ChatItem) -> String? {
        let args = item.body["args"]
        if let cmd = (args?["command"]?.stringValue ?? args?["cmd"]?.stringValue
                      ?? item.body["command"]?.stringValue),
           !cmd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return cmd
        }
        let summary = item.argsSummary
        return summary.isEmpty ? nil : summary
    }

    /// The language hint for a command code card — "bash" for a real shell
    /// command, nil for a `key: value` args preview.
    nonisolated static func commandLanguage(of item: ChatItem) -> String? {
        let args = item.body["args"]
        if args?["command"] != nil || args?["cmd"] != nil || item.body["command"] != nil {
            return "bash"
        }
        return nil
    }

    /// The bold Thinking-sheet title for a reasoning first line — capped short.
    nonisolated static func reasoningTitle(_ firstLine: String) -> String {
        shortTarget(firstLine, limit: 60)
    }

    /// Build the ordered step list for a working run under the single-fold
    /// contract: one step per non-empty reasoning part (thought-bubble glyph, first
    /// line as summary, full text in the sheet), one step per work item OR classic
    /// `.tools` activity (humanized summary + code cards), and one step per interim
    /// narration `.text` segment (text glyph, first line as summary, full text in
    /// the sheet). The FINAL answer `.text` never reaches here — it lives in the
    /// tail nodes that `renderNodes` keeps outside the fold.
    nonisolated static func steps(from parts: [ChatMessagePart]) -> [WorkingStep] {
        var out: [WorkingStep] = []
        for part in parts {
            switch part {
            case .reasoning(let id, let text):
                let cleaned = ThinkingDisplay.cleanedText(text)
                guard !cleaned.isEmpty else { continue }
                let firstLine = firstNonEmptyLine(cleaned)
                out.append(WorkingStep(
                    id: id,
                    kind: .reasoning,
                    glyph: "bubble.left",
                    summary: shortTarget(firstLine),
                    title: reasoningTitle(firstLine),
                    body: cleaned,
                    command: nil,
                    commandLanguage: nil,
                    output: nil,
                    isFailure: false
                ))
            case .item(let id, let item):
                let summary = stepSummary(for: item)
                let output = item.resultPreview.isEmpty ? nil : item.resultPreview
                out.append(WorkingStep(
                    id: id,
                    kind: .tool,
                    glyph: glyph(for: item.type),
                    summary: summary,
                    title: summary,
                    body: nil,
                    command: commandText(of: item),
                    commandLanguage: commandLanguage(of: item),
                    output: output,
                    isFailure: isFailure(item)
                ))
            case .tools(_, let tools, _, _):
                for tool in tools {
                    let summary = legacyToolSummary(tool)
                    out.append(WorkingStep(
                        id: tool.id,
                        kind: .tool,
                        glyph: tool.state == .failed ? "exclamationmark.triangle" : "terminal",
                        summary: summary,
                        title: summary,
                        body: nil,
                        command: tool.argsSummary.isEmpty ? nil : tool.argsSummary,
                        commandLanguage: nil,
                        output: tool.resultPreview.isEmpty ? nil : tool.resultPreview,
                        isFailure: tool.state == .failed
                    ))
                }
            case .text(let id, let text):
                // Interim narration — a `.text` part caught before the last work
                // part. (The final answer `.text` is in the tail, never here.)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let firstLine = firstNonEmptyLine(trimmed)
                out.append(WorkingStep(
                    id: id,
                    kind: .narration,
                    glyph: "text.alignleft",
                    summary: shortTarget(firstLine),
                    title: reasoningTitle(firstLine),
                    body: trimmed,
                    command: nil,
                    commandLanguage: nil,
                    output: nil,
                    isFailure: false
                ))
            default:
                continue
            }
        }
        return out
    }

    /// The first non-blank line of a block, used for a step's one-line summary.
    nonisolated static func firstNonEmptyLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            .map(String.init) ?? text
    }
}

// MARK: - View

/// Renders one folded working run (see `WorkingSectionModel`) in the approved
/// ChatGPT-style chrome-less language: a muted "Worked for N" line that expands
/// to a step list, with a "Thinking" sheet behind each step.
struct WorkingSectionView: View {
    /// The run's parts (reasoning + working items), in wire order.
    let parts: [ChatMessagePart]
    /// Whether the owning turn is still streaming — selects the live vs. settled
    /// presentation.
    var streaming: Bool = false
    /// Turn start for the live reasoning elapsed label (from `ChatStore`).
    var liveTurnStartedAt: Date?
    /// Settled turn duration stamped on the message, for the "Worked for N" label.
    var settledDuration: TimeInterval?
    /// QA-3 S8/A4 — the turn ended via the LIVENESS fallback (dead turn
    /// force-settled), not a real completion: the settled fold reads a muted
    /// "Interrupted" instead of "Worked" (honest, never an error banner — C3).
    var interrupted: Bool = false

    @Environment(\.hermesTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Per-TURN timer tick for the live collapsed line (QA-2 R5: the timer is
    /// per-turn, never per-item). Same 1 s cadence the settled label derives
    /// from; `monospacedDigit` keeps the row from jittering as it counts.
    private static let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var now = Date()

    /// Manual expansion of the folded step list. Settled AND live sections
    /// start collapsed (QA-2 R5/A3: a live turn is ONE line until the user
    /// taps — no auto-open churn, no inline streaming reasoning).
    @State private var isExpanded = false
    /// Presentation of the "Thinking" sheet, opened by tapping a step.
    @State private var showThinkingSheet = false
    /// The step the sheet should scroll to on open.
    @State private var focusedStepID: String?

    private var hasFailure: Bool { WorkingSectionModel.runHasFailure(parts) }
    private var durationSeconds: TimeInterval? {
        WorkingSectionModel.runDurationSeconds(parts, settled: settledDuration)
    }
    private var steps: [WorkingStep] { WorkingSectionModel.steps(from: parts) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if streaming {
                liveSection
            } else {
                settledSection
            }
        }
        .padding(.leading, 2)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: isExpanded)
        .accessibilityIdentifier("workingSection")
        .sheet(isPresented: $showThinkingSheet) {
            ThinkingSheet(steps: steps, focusedStepID: focusedStepID)
        }
    }

    private func toggle() {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { isExpanded.toggle() }
    }

    private func openSheet(_ stepID: String) {
        focusedStepID = stepID
        showThinkingSheet = true
    }

    // MARK: - Settled: chrome-less "Worked for N" fold

    @ViewBuilder
    private var settledSection: some View {
        Button {
            toggle()
        } label: {
            workedLabelRow
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            WorkingSectionModel.summaryAccessibilityLabel(
                seconds: durationSeconds, hasFailure: hasFailure, interrupted: interrupted
            )
        )
        .accessibilityValue(isExpanded ? "expanded" : "collapsed")
        .accessibilityHint("Double-tap to \(isExpanded ? "collapse" : "expand") what the assistant did")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("workingSectionSummary")

        if isExpanded {
            stepList(steps)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    /// Chrome-less collapsed line: muted "Worked for N" + a small rotating
    /// chevron. No box, border, gradient, or capsule (approved design §1).
    private var workedLabelRow: some View {
        HStack(spacing: 6) {
            Text(WorkingSectionModel.settledLabel(seconds: durationSeconds, interrupted: interrupted))
                .font(.callout)
                .foregroundStyle(theme.mutedFg)
                .monospacedDigit()
            if hasFailure { failureBadge }
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(theme.mutedFg)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    // MARK: - Chrome-less step list (glyph + muted summary)

    @ViewBuilder
    private func stepList(_ list: [WorkingStep]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(list) { step in
                Button {
                    openSheet(step.id)
                } label: {
                    stepRow(step)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(step.summary)
                .accessibilityHint("Double-tap to open the thinking detail")
            }
        }
        .accessibilityIdentifier("workingSectionSteps")
    }

    private func stepRow(_ step: WorkingStep) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: step.isFailure ? "exclamationmark.triangle" : step.glyph)
                .font(.footnote)
                .foregroundStyle(step.isFailure ? theme.statusError : theme.mutedFg)
                .frame(width: 20, alignment: .center)
                .padding(.top, 2)
            Text(step.summary)
                .font(.callout)
                .foregroundStyle(theme.mutedFg)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    // MARK: - Live: ONE collapsed working line (ratified Wave-2.5, QA-2 R5/R6)

    /// The ratified live-turn presentation: a SINGLE chrome-less line —
    /// "Working… · ‹current tool› ‹per-TURN timer› ›" — tap to expand the
    /// bifurcation (thinking + tool timeline). NOTHING streams inline: the old
    /// per-reasoning-run `ThinkingView` accordions (per-item 1 s timers, label
    /// + body double-print — R5/N4/N6), the separate current-tool row, and the
    /// fixed 172 pt thinking window (the R6 whitespace bands) are gone. The
    /// streaming caret in the answer bubble remains THE progress signal
    /// (Wave-2.5 "no fat working pill; the caret is the working signal").
    @ViewBuilder
    private var liveSection: some View {
        Button {
            toggle()
        } label: {
            liveCollapsedLine
        }
        .buttonStyle(.plain)
        .accessibilityLabel(liveAccessibilityLabel)
        .accessibilityValue(isExpanded ? "expanded" : "collapsed")
        .accessibilityHint("Double-tap to \(isExpanded ? "collapse" : "expand") what the assistant is doing")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("workingSectionLive")
        .onReceive(Self.tick) { now = $0 }

        if isExpanded {
            // Tap-to-expand bifurcation: reasoning steps + the tool timeline
            // in wire order — the SAME step list the settled fold expands.
            stepList(steps)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    /// Chrome-less collapsed live line: spinner + "Working… · ‹tool›" + the
    /// per-TURN elapsed label + chevron. No box/border/capsule (the settled
    /// row's exact visual language, live variant).
    private var liveCollapsedLine: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.mini)
                .accessibilityHidden(true)
            Text(WorkingSectionModel.liveCollapsedLabel(parts: parts))
                .font(.callout)
                .foregroundStyle(theme.mutedFg)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(ThinkingDisplay.elapsedText(startedAt: liveTurnStartedAt, now: now))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(theme.mutedFg.opacity(0.75))
                .accessibilityHidden(true)
            if hasFailure { failureBadge }
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(theme.mutedFg)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private var liveAccessibilityLabel: String {
        let elapsed = ThinkingDisplay.elapsedText(startedAt: liveTurnStartedAt, now: now)
        let base = "\(WorkingSectionModel.liveCollapsedLabel(parts: parts)), elapsed \(elapsed)"
        return hasFailure ? "\(base), contains a failed step" : base
    }

    // MARK: - Shared chrome

    private var failureBadge: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.caption2)
            .foregroundStyle(theme.statusError)
            .accessibilityLabel("contains a failed step")
    }
}

// MARK: - Thinking sheet

/// The "Thinking" sheet (approved design §3): a timeline rail down the left, each
/// step a bold title + reasoning text + embedded command/output code cards. Reuses
/// `CodeBlockView` for the lifted code cards (language label + copy).
private struct ThinkingSheet: View {
    let steps: [WorkingStep]
    var focusedStepID: String?

    @Environment(\.hermesTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        // Continuous timeline rail behind the glyph column.
                        Rectangle()
                            .fill(theme.border)
                            .frame(width: 1.5)
                            .padding(.leading, 9)
                            .padding(.top, 12)
                            .padding(.bottom, 12)
                        VStack(alignment: .leading, spacing: 22) {
                            ForEach(steps) { step in
                                trailStep(step).id(step.id)
                            }
                        }
                    }
                    .padding(20)
                }
                .onAppear {
                    guard let focusedStepID else { return }
                    proxy.scrollTo(focusedStepID, anchor: .top)
                }
            }
            .background(theme.bg)
            .navigationTitle("Thinking")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func trailStep(_ step: WorkingStep) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: step.isFailure ? "exclamationmark.triangle" : step.glyph)
                .font(.footnote)
                .foregroundStyle(step.isFailure ? theme.statusError : theme.mutedFg)
                .frame(width: 20, height: 20)
                .background(Circle().fill(theme.bg).frame(width: 24, height: 24))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(step.title)
                    .font(.headline)
                    .foregroundStyle(theme.fg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let body = step.body, !body.isEmpty {
                    Text(body)
                        .font(.subheadline)
                        .foregroundStyle(theme.mutedFg)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let command = step.command, !command.isEmpty {
                    CodeBlockView(language: step.commandLanguage, code: command)
                }
                if let output = step.output, !output.isEmpty {
                    CodeBlockView(language: nil, code: output)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
