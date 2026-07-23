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
//   - LIVE (streaming) — RATIFIED Wave-2.5 single-line rule (QA-2 R5/R6/A3),
//     reworked to the QA-3 S2/S3/A1 MERGED CURSOR LINE: ONE chrome-less line
//     that IS the streaming caret — "▌ (softly breathing) Working… · ‹current
//     tool› ‹per-TURN timer› ›" — tap to expand the bifurcation (thinking +
//     tool timeline, the same step list the settled fold shows). The breathing
//     cursor is the leading glyph of this very line (no spinner — the QA-2
//     `ProgressView` + a SECOND standalone caret stacked beneath it was the
//     S3 double-affordance), and `MessageBubble` renders this line with ZERO
//     parts from SEND — the affordance appears on local send state ≤100 ms
//     (S2), never gated on the first relay item; item arrival only updates the
//     status text. Once the answer text streams, the glyph hands the pulse to
//     the prose-tail `StreamingCursor` (exactly one glyph breathes at any
//     instant) while the line keeps status + timer. Nothing streams inline
//     while live: no per-reasoning-run accordions (their per-item 1 s timers
//     and label+body double-print were R5/N4/N6), no separate current-tool
//     row, no reserved 172 pt thinking window (the R6 bands). The timer is
//     per-TURN (from `ChatStore.turnStartedAt`, stamped locally at send and
//     reconciled to the relay's `turn.completed` duration), never per item.
//
// SINGLE-FOLD CONTRACT (owner QA, 2026-07-19): within ONE agent turn, EVERYTHING
// before the final answer text — reasoning segments, tool calls (BOTH the new
// `.item` work items AND the classic `.tools` clusters), and interim narration
// `.text` segments — folds under ONE working section. The FINAL answer text (the
// trailing `.text` run after the last work part) renders as the body. This applies
// to the `ChatMessagePart` path too, so older stored sessions retain the same
// anatomy — the owner sees old sessions daily and the old anatomy
// (repeating italic "Thinking ›" rows + boxed tool cards alternating with interim
// prose) is exactly what this collapses.

// MARK: - Breathing cursor (approved StreamingCursor spec, QA-3 S1/S2/S3)

/// The soft opacity breathe behind the streaming cursor glyph — the approved
/// StreamingCursor spec: theme-bound, a soft 1.0 → 0.25 opacity breathing at a
/// 1.2 s period (0.6 s ease each direction, the cosine curve's shape matching
/// the former `easeInOut(0.6).repeatForever(autoreverses)`).
///
/// QA-3 S1: the pulse is a PURE FUNCTION OF WALL-CLOCK TIME, not a `@State`
/// kicked by `onAppear` + `withAnimation(.repeatForever)`. That old pattern
/// stranded the cursor STATIC whenever the row remounted mid-turn (an
/// animation-nil transaction or a view-identity change resets `@State`
/// without re-firing `onAppear`) — the motionless blue bar the owner
/// photographed (IMG_2577/2585/2587). A time-driven pulse has no state to
/// strand: any remount renders the correct phase for "now" and keeps
/// breathing. Deterministic + unit-testable (every value pinned by
/// `RenderConformanceTests.testCursorBreathe_*`).
enum CursorBreathe {
    /// Full breathe period (0.6 s dim-down + 0.6 s brighten-up, autoreverse
    /// parity with the ratified spec).
    nonisolated static let period: TimeInterval = 1.2
    /// The dim trough of the breathe (1.0 peak → 0.25 trough).
    nonisolated static let minOpacity: Double = 0.25

    /// Glyph opacity at an instant. Settled (`streaming == false`) or Reduce
    /// Motion reads a steady full-opacity glyph — honest presence, no pulse.
    nonisolated static func opacity(
        at date: Date,
        streaming: Bool = true,
        reduceMotion: Bool = false
    ) -> Double {
        guard streaming, !reduceMotion else { return 1.0 }
        let t = date.timeIntervalSinceReferenceDate
        let phase = t.truncatingRemainder(dividingBy: period) / period   // 0 ..< 1
        // Cosine ease: 0 at phase 0 (peak), 1 at phase 0.5 (trough), back to 0
        // at phase 1 — the smooth easeInOut-ish autoreverse shape.
        let eased = (1 - cos(2 * .pi * phase)) / 2
        return 1.0 - (1.0 - minOpacity) * eased
    }
}

/// The breathing ▌ glyph as a standalone live-working element (the prose-tail
/// `StreamingCursor` in MessageBubble shares `CursorBreathe`). Stateless — the
/// caller supplies the clock `date` (a `TimelineView` context) so one timeline
/// drives the whole working line (glyph + per-turn timer) at once.
struct BreathingCursorGlyph: View {
    /// The frame date from the enclosing `TimelineView` — the pulse phase.
    var date: Date
    /// Whether the owning turn is streaming (settled ⇒ steady glyph).
    var streaming: Bool = true

    @Environment(\.hermesTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text("▌")
            .foregroundColor(theme.midground)
            .opacity(CursorBreathe.opacity(at: date,
                                           streaming: streaming,
                                           reduceMotion: reduceMotion))
            .accessibilityHidden(true)
    }
}

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
    /// `.reasoning` and the `.tools` cluster count. `.text` is NOT
    /// work — a trailing `.text` run is the final answer body; interim `.text`
    /// still folds because it sits BEFORE the last work part, not because it is
    /// eligible itself. `.usage` / `.warning` are footers and never work.
    nonisolated static func isWorkingEligible(_ part: ChatMessagePart) -> Bool {
        switch part {
        case .reasoning, .tools:
            return true
        case .text, .warning, .usage:
            return false
        }
    }

    /// The index of the LAST work part (reasoning / classic tools / item work) in
    /// the turn — the fold boundary. `nil` when the turn is pure text/usage/warning
    /// (no work to fold).
    nonisolated static func lastWorkIndex(in parts: [ChatMessagePart]) -> Int? {
        parts.lastIndex(where: isWorkingEligible)
    }

    /// QA-3 S2/S3/A1 — the SINGLE-AFFORDANCE decision for the caret slot. The
    /// ratified design: ONE working surface — the breathing cursor line (glyph
    /// + inline status + per-turn timer). While the turn is live and the answer
    /// text has not started:
    ///  • NO work part yet (the optimistic send-time bubble has zero parts —
    ///    nothing folds): the caret slot renders the MERGED working line itself
    ///    → `true`. This is the S2 fix — the labeled, timed affordance exists
    ///    from SEND, driven by local state, never gated on the first relay item
    ///    frame (build 116 showed a bare textless cursor there until the model's
    ///    first item, ~35 s later in IMG_2578).
    ///  • work parts present (a fold exists): `false` — the fold's own live
    ///    line IS the cursor line now (its spinner replaced by the breathing
    ///    glyph); a separate standalone cursor beside it was the S3 dual-
    ///    affordance bug (IMG_2578/2587/2591).
    ///  • answer text present: `false` — the caret rides the prose tail.
    /// Settled turns: always `false`. Pure + `nonisolated static` so the render
    /// gate pins the rule directly (the same seam pattern as
    /// `ChatView.shouldShowInlineTurnActivity`).
    nonisolated static func preItemWorkingLineVisible(
        parts: [ChatMessagePart],
        streamingLive: Bool
    ) -> Bool {
        guard streamingLive else { return false }
        guard parts.lastTextPartID == nil else { return false }
        return lastWorkIndex(in: parts) == nil
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

    /// Whether any tool in the run failed — a failed status OR an `error` item, in
    /// EITHER the item-layer parts or the classic `.tools` clusters. Drives the
    /// collapsed section's failure badge so a fold never hides a failure (§2).
    nonisolated static func runHasFailure(_ parts: [ChatMessagePart]) -> Bool {
        toolUnits(in: parts).contains(where: \.isFailure)
    }

    // MARK: - Tool units

    /// A single tool activity used by the live current-tool line and failure badge.
    struct WorkUnit: Equatable, Sendable {
        let summary: String
        let status: ToolActivity.State
        let isFailure: Bool
        /// Whether the unit's identity is still a RAW wire state token (QA-2
        /// N2: `tool.generating` / `review.summary` — the relay's pre-resolution
        /// event name). The live collapsed line reads "Working…" for raw units
        /// instead of surfacing internal state (C1); the humanized `summary`
        /// itself falls back to a neutral label, never the raw token.
        let raw: Bool
    }

    /// Flatten a run's tool work (not reasoning or narration) into ordered units.
    nonisolated static func toolUnits(in parts: [ChatMessagePart]) -> [WorkUnit] {
        var out: [WorkUnit] = []
        for part in parts {
            switch part {
            case .tools(_, let tools, _, _):
                for tool in tools {
                    out.append(WorkUnit(
                        summary: legacyToolSummary(tool),
                        status: tool.state,
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
        return units.last(where: { $0.status == .running }) ?? units.last
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

    /// Wall-clock seconds a settled working section took: the turn's stamped
    /// duration when known, else the sum of the items' own `duration_s`, else nil
    /// (the label then omits the time tail).
    nonisolated static func runDurationSeconds(
        _ parts: [ChatMessagePart],
        settled: TimeInterval?
    ) -> TimeInterval? {
        if let settled, settled > 0 { return settled }
        var summed = 0.0
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
    /// QA-3 S2/S3/A1: whether the live line LEADS with the breathing cursor
    /// glyph — i.e. whether this line currently owns "the" working pulse. True
    /// while no answer text flows (the pre-text window: the line IS the caret);
    /// false once the answer streams, when the prose-tail `StreamingCursor`
    /// owns the pulse and this line keeps the status + timer only. Exactly one
    /// glyph breathes at any instant — never two stacked affordances (S3).
    var showsCursorGlyph: Bool = true

    /// QA-3 S8/A4 — the turn ended via the LIVENESS fallback (dead turn
    /// force-settled), not a real completion: the settled fold reads a muted
    /// "Interrupted" instead of "Worked" (honest, never an error banner — C3).
    var interrupted: Bool = false

    @Environment(\.hermesTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

    // MARK: - Live: ONE merged breathing-cursor working line (QA-3 S2/S3/A1)

    /// The ratified live-turn presentation, reworked for QA-3 S2/S3/A1: a
    /// SINGLE chrome-less line that IS the streaming cursor —
    /// "▌ (breathing) Working… · ‹current tool› ‹per-TURN timer› ›" — tap to
    /// expand the bifurcation (thinking + tool timeline). The QA-2 live line
    /// led with a `ProgressView` spinner and a SECOND affordance — the bare
    /// standalone caret — stacked beneath it (IMG_2578/2587/2591, S3): the
    /// spinner is GONE (no `ProgressView` anywhere in the working line) and the
    /// breathing caret moved INTO this line's leading edge, so the fold and the
    /// caret are one surface. `MessageBubble` renders this same view with ZERO
    /// parts from SEND (the pre-first-frame window — S2: the labeled+timed
    /// affordance no longer waits on the first relay item), so item arrival
    /// only updates the status text; it never mounts a second surface.
    ///
    /// The line drives off a single `TimelineView` — the glyph's breathe and
    /// the per-turn timer tick share ONE clock (stateless; survives
    /// re-projection — see `CursorBreathe`). NOTHING streams inline: the old
    /// per-reasoning-run accordions, the separate current-tool row, and the
    /// fixed 172 pt thinking window remain gone (R5/R6).
    @ViewBuilder
    private var liveSection: some View {
        let hasSteps = !steps.isEmpty
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !streaming)) { context in
            Group {
                if hasSteps {
                    Button {
                        toggle()
                    } label: {
                        liveCollapsedLine(now: context.date, hasSteps: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(liveAccessibilityLabel(now: context.date))
                    .accessibilityValue(isExpanded ? "expanded" : "collapsed")
                    .accessibilityHint("Double-tap to \(isExpanded ? "collapse" : "expand") what the assistant is doing")
                    .accessibilityAddTraits(.isButton)
                } else {
                    // Pre-first-item window: nothing to expand yet — the line is
                    // presence-only (breathing caret + "Working…" + timer). It
                    // becomes tappable the moment the first work part lands.
                    liveCollapsedLine(now: context.date, hasSteps: false)
                        .accessibilityLabel(liveAccessibilityLabel(now: context.date))
                }
            }
            .accessibilityIdentifier("workingSectionLive")
        }

        if isExpanded, hasSteps {
            // Tap-to-expand bifurcation: reasoning steps + the tool timeline
            // in wire order — the SAME step list the settled fold expands.
            stepList(steps)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    /// Chrome-less collapsed live line: the breathing cursor glyph (when this
    /// line owns the pulse) + "Working… · ‹tool›" + the per-TURN elapsed label
    /// + chevron (only when expandable). No spinner, no box/border/capsule —
    /// the settled row's exact visual language, live variant.
    private func liveCollapsedLine(now: Date, hasSteps: Bool) -> some View {
        HStack(spacing: 6) {
            if showsCursorGlyph {
                BreathingCursorGlyph(date: now, streaming: streaming)
                    .font(.callout)
            }
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
            if hasSteps {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(theme.mutedFg)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func liveAccessibilityLabel(now: Date) -> String {
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
