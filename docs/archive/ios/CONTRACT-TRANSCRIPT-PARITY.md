# CONTRACT — iOS Transcript Structural Parity (ABH-87)

Status: rebuild contract, ready for builder+gate pipeline.
Scope: `apps/ios/HermesMobile/` chat transcript only. Native SwiftUI; NOT a desktop UI clone.
Reference: desktop `apps/desktop/src` (assistant-ui two-layer split). Live REST payload re-verified against `http://127.0.0.1:9119/api/sessions/{id}/messages` (Bearer auth; session `cron_ebc83e783d98_20260607_155217`, 15 rows: 1 user / 6 assistant / 8 tool; union keys include `tool_calls[].{call_id,function}`, `tool_call_id`, `tool_name`, `reasoning`, `finish_reason`).

**The bar (acceptance invariant):** a session must render **identically-structured whether seeded from history or accumulated live**, and match the desktop's structural rules part-for-part. Formally: `structure(seed(history)) == structure(stream(frames))` for any conversation, where `history` and `frames` describe the same turns.

All line cites verified in this audit pass.

---

## 1. VERDICT — REPLACE the dual-model, KEEP the part *enum* and the native renderers

**Verdict: REPLACE the architecture (single canonical model), SALVAGE the `ChatMessagePart` enum cases and the SwiftUI part renderers.**

The adopted parts work (commit 3f1d1a522, doc `CHAT-THREAD-PARTS-2026-06-07.md`) is **structurally unsound and cannot be incrementally patched to parity**, because its core decision — keep legacy fields (`text/thinking/tools/warning/usage`) as a parallel source of truth alongside `parts[]`, and reconcile them with hand-maintained salvage clauses — is exactly the dual-write seam the desktop does not have. Desktop has **ONE** model (`ChatMessage.parts: ChatMessagePart[]`) rendered in **strict wire order** (`MessagePrimitive.Parts`), with grouping done at render time, never in the data. iOS today has two models that diverge by construction:

- The **seed path never builds `parts[]`** — `ChatStore.chatMessage(from:)` (ChatStore.swift:1737-1749) sets only `role/text/timestamp/presentation`, so reopened turns fall to the fixed-order lossy `legacyAssistantParts` projection (ChatModels.swift:276-299: `reasoning → tools(fused) → text → warning → usage`).
- Worse, the **wire data needed to rebuild parts is discarded at parse time**: `StoredMessage` (ProtocolTypes.swift:224-247) keeps only `role`, `content`, `timestamp` and throws away `tool_calls`, `tool_call_id`, `tool_name`, `reasoning`, `finish_reason`. The live REST payload (re-verified above) **carries all of them** — so parity is achievable, but only after `StoredMessage` is widened. This is the single biggest reason the seed mapper cannot be fixed in isolation.
- The **streaming completion helpers reorder away from wire order**: `applyFinalReasoning` yanks reasoning to index 0 (ChatModels.swift:191-201); `replaceTextParts` collapses all prose into the last text slot (ChatModels.swift:305-322).
- **Part ids are random per part** (`newPartID` → `UUID()`, ChatModels.swift:301-303), so identity churns on every rebuild and across the live→seed transition.

Justified against the desktop's three load-bearing properties:
1. **One canonical model** — desktop: flat `ChatMessage[]`, one agentic turn = ONE assistant message with ordered mixed `parts[]` (`chat-messages.ts` `toChatMessages`). iOS must collapse to one model; the legacy fields must stop being a render source of truth.
2. **No dual-write seams** — desktop never reconciles two arrays; the salvage clauses (`assistantRenderParts` :117-139, "review fix #1/#2/#3/#4") are a permanent maintenance hazard and must be deleted, not extended.
3. **Stable identity** — desktop reuses `streamId` start→settle and caches the runtime mapping by object identity (`use-message-stream.ts:215`, `app/chat/index.tsx:265-270`); iOS must mint deterministic part ids so unchanged parts keep identity across deltas and across seed/stream.

**What survives:** the `ChatMessagePart` *enum shape* (reasoning/tools/text/warning/usage) and the native part renderers (`ThinkingView`, `ToolClusterView`, `MessageSegmenter` prose/code, warning Label, usage footer — MessageBubble.swift:254-348). Those are good native equivalents of the desktop part renderers and are not the defect. The defect is the model and the two producers, which are replaced wholesale.

---

## 2. TARGET iOS MODEL — one structure, two producers

### 2.1 Canonical model

`ChatMessage.parts: [ChatMessagePart]` becomes the **sole** assistant-content source of truth. Legacy scalar fields are demoted to **derived, non-rendering** compatibility accessors (for copy/retry/checkpoint/export only), computed from `parts`, never written independently.

```
enum ChatMessagePart: Identifiable, Sendable, Equatable {
    case reasoning(id: String, text: String)
    case tools(id: String, tools: [ToolActivity], collapsed: Bool, turnElapsed: TimeInterval?)
    case text(id: String, text: String)
    case warning(id: String, text: String)   // inline error/warning (desktop MessagePrimitive.Error)
    case usage(id: String, stats: UsageStats) // NOTE: usage is desktop-session-global, NOT a transcript row (see §2.6)
}

struct ChatMessage {
    let id: MessageID            // see ID rules §2.2
    let role: ChatRole
    var parts: [ChatMessagePart] // ORDERED; this ordering IS visual order (desktop §4a)
    var isStreaming: Bool        // == desktop `pending`
    let timestamp: Date
    var presentation: Presentation
    // DERIVED, read-only (computed from parts) — replaces stored text/thinking/tools/warning/usage:
    var text: String { parts ordered-concat of .text }      // for Copy/Share/export
    var thinking: String { parts ordered-concat of .reasoning }
    var tools: [ToolActivity] { parts flat-map .tools }
}
```

Delete: `var text/thinking/tools/warning/usage` stored fields, `toolsCollapsed`, `turnElapsed` (the latter two move *into* `.tools` payload where they already are), `legacyAssistantParts`, `assistantRenderParts` salvage clauses, `setWarningPart`/`setUsagePart` legacy-field writes (keep the part-mutation half only).

**Grouping is NOT stored.** Match the desktop's two distinct render-time grouping layers (§3): consecutive-run clustering of tool/reasoning parts, and turn grouping (user + following non-user). The model stores parts in wire order, one part per arrival. (iOS already keeps tools in `.tools` clusters; per the consecutive-run rule a new `.tools` part is only opened when a non-tool part intervenes — see §2.5 — which is the desktop `groupMessageParts` semantics expressed in the data. Acceptable as long as the rule is enforced identically by both producers.)

### 2.2 ID / key stability (the anti-re-stack contract)

- **Message id:**
  - **Streaming:** mint ONE id when the assistant bubble is first created (`ensureStreamingMessage`/`beginStreamingMessage`, ChatStore.swift:713-733) and reuse it through completion. `handleMessageComplete` must mutate **the same** message in place (it already targets `streamingMessageID`, :817/:856) — keep that, never re-key. (Desktop `streamId`, use-message-stream.ts:215.)
  - **Seeded:** deterministic from wire: `"{timestamp}-{index}-{role}"`; tool-only synthetic assistant rows get `"{ts}-{index}-tools"`. (Desktop chat-messages.ts:797/:698.)
- **Part id (CRITICAL — replaces `UUID()`):** deterministic and stable across rebuild.
  - `tools`: the part id is derived from the **first tool's `tool_call_id`** (wire-stable both live and seeded). Tool *within* the cluster keyed by its own `tool_call_id`.
  - `reasoning`/`text`: `"{messageID}-{kind}-{runIndex}"` where `runIndex` is the ordinal of that consecutive run within the message. A streamed run and its seeded counterpart for the same turn MUST compute the same id. NO `UUID()`.
  - Guarantee global uniqueness only by mutating colliding ids (desktop `withUniqueToolCallIds`, chat-messages.ts:625-659) — never re-key non-colliding parts.
- **Renderer keying:** `ForEach(parts)` on `part.id` (MessageBubble.swift:240) stays, but now keys are stable, so SwiftUI updates in place instead of tearing down (kills D5/D12 flicker).

### 2.3 Wire ingestion prerequisite — widen `StoredMessage`

`StoredMessage` (ProtocolTypes.swift:224-247) MUST be extended to retain the fields the seed mapper needs (all present in live REST):
```
struct StoredMessage {
    let role, content, timestamp           // existing
    let toolCalls: [WireToolCall]?         // tool_calls[]: {call_id|id, function:{name, arguments(JSON string)}}
    let toolCallId: String?                // tool_call_id (on role:tool rows)
    let toolName: String?                  // tool_name (on role:tool rows)
    let reasoning: String?                 // reasoning | reasoning_content | reasoning_details (first non-empty)
    let finishReason: String?              // finish_reason
}
```
This is a hard precondition for Batch B; without it the seed mapper has nothing to reconstruct from.

### 2.4 SEED producer — `toChatMessages(history) -> [ChatMessage]`

Port the desktop normalizer `toChatMessages` (chat-messages.ts:661-810) — the single most important algorithm. Behavior, in order:

1. **`role:'tool'` rows** (desktop :710-727): attach `result` onto the matching pending `.tools` activity by `tool_call_id`, else by `tool_name`; search the in-progress cluster first, then scan emitted assistant messages backward. If no match, emit a synthetic tool activity. **Tool rows are NEVER their own message.** (Replaces today's drop/collapse in `classify`, ChatStore.swift:1755-1778.)
2. **Per assistant row** (desktop :729-748): build parts in fixed within-row order — reasoning (if any of `reasoning`/`reasoning_content`/`reasoning_details`) → text → tool-call activities from `tool_calls[]`. User rows: strip `--- Attached Context ---`/`--- Context Warnings ---`, hoist `@ref` chips (desktop `displayContentForMessage` :153-171).
3. **Turn coalescing** (desktop :759-794): a tool-only assistant row is buffered, then flushed onto the **active** assistant message. An assistant row with text merges into the active assistant message when either side has a tool call. Net: a long agentic turn `[reason→tool→tool-result→…→final text]` becomes **ONE** assistant `ChatMessage` with ordered mixed `parts[]` — interleaved exactly as the wire delivered. A non-assistant row flushes pending and ends the active assistant.
4. **Empty filter** (desktop :808): drop messages with no text and no non-text part.
5. **Final pass:** unique-but-stable ids (desktop :807).

Machine scaffolding (cron preambles, system prompts) still collapse to a dimmed disclosure row (preserve `classify`'s `.collapsed` presentation, ChatStore.swift:1766-1772) — this is an iOS-native affordance with no desktop conflict, kept.

### 2.5 STREAM producer — frames → SAME structure

Reduce gateway frames into the **same `parts[]` shape** the seed producer yields. Required changes to the current reducer:

- **Flush-before-tool ordering** (desktop "flush contract", use-message-stream.ts tool.start path): text/reasoning buffers MUST flush before any `tool.start` upsert so `text → tool → text` yields `parts:[text, tools, text]`. (`scheduleFlush`/`flushBuffers` exist at ChatStore.swift:1299-1321; the doc claims this ordering at lines 27-28 — verify and lock it in a test.)
- **Delta coalescing:** keep the ~40ms flush floor (ChatStore.swift:1302 `flushInterval`; desktop 33ms STREAM_DELTA_FLUSH_MS). Append into the trailing same-kind part; open a new run only when a different kind intervenes (desktop chat-messages.ts:188-219). Use the deterministic run-index id (§2.2), NOT `UUID()`.
- **`applyFinalReasoning` (ChatModels.swift:191-201) — FIX:** must NOT insert at index 0. On `message.complete`, replace the reasoning run **in place at its existing position** (desktop dedupe: drop streamed reasoning whose normalized text is a prefix of final, keep wire order; use-message-stream.ts:453-468). Reasoning that streamed after an early text/tool stays where it streamed.
- **`applyFinalText` / `replaceTextParts` (ChatModels.swift:165-189, 305-322) — FIX:** the desktop completion rule is: drop streamed text parts, then append the canonical final text part (use-message-stream.ts:453-468) — but this only collapses to one slot because desktop turns rarely interleave final text around tools. For iOS parity the safe rule is: **if final text is a prefix-extension of concatenated streamed text, extend the trailing text run; otherwise, if a single text run exists replace it in place; if multiple text runs are interleaved with tools, the streamed interleaving is authoritative for ORDER — do not fuse runs across a tool boundary.** Net requirement: completion must never move prose across a tool boundary (kills D4). The `else` random-id branches (:150, :184, :221) must use deterministic ids.
- **`completeAssistantMessage` mutates same id, flips `isStreaming:false`** — already correct (ChatStore.swift:844/:856); keep, never re-key.
- **Interrupted/errored:** an interrupted turn must early-return on late deltas (desktop `state.interrupted`, use-message-stream.ts:211-213); errored completion attaches an inline `.warning` part and keeps it across reseed.

### 2.6 Where usage/warnings/approvals live

Match desktop placement (do not invent transcript rows):
- **Usage:** desktop is **session-global** (`setCurrentUsage`), never a transcript row. iOS currently models `.usage` as a per-message part. **Decision: keep `.usage` as a trailing part for native footer convenience, BUT it must be derived deterministically from the turn's completion payload and must render identically seed vs stream (today seeded turns drop it entirely — D2).** It does not affect structural parity of the message body, only the footer.
- **Warning/error:** inline `.warning` part rendered AFTER all body parts, inside the assistant block (desktop `MessagePrimitive.Error`, thread.tsx:254-261). Single source: completion/error frame writes the part; no legacy-field salvage.
- **Approvals/clarify/sudo/secret:** per-session prompt stores + inline bars, NOT transcript parts (desktop use-message-stream.ts:812-887). iOS already routes these via `PendingApproval`/`PendingClarification` (ChatModels.swift:409-420) — keep out of `parts`.

---

## 3. RENDERING CONTRACT

### 3.1 Part rendering (MessageBubble)
- Render `message.parts` directly in array order via `ForEach(parts) { part.id }` (MessageBubble.swift:240). Remove the `assistantRenderParts` indirection and all salvage (ChatModels.swift:115-141).
- Part → view map unchanged (MessageBubble.swift:254-281): reasoning→`ThinkingView`, tools→`ToolClusterView`, text→segmented prose/code, warning→Label, usage→footer.
- **Cursor:** rides the last `.text` part (`lastTextPartID`, MessageBubble.swift:237/241). With stable ids it no longer jumps (kills D12). Standalone cursor when tail is code stays (MessageBubble.swift:319-324).

### 3.2 Tool-cluster grouping (desktop `groupMessageParts` + `ToolGroupSlot`)
- Consecutive `.tools` activities = one cluster; a non-tool part closes the run (already the data shape via §2.5).
- **Collapse rule — FIX D8:** desktop collapses to a "Tool actions · N steps" header when the *group* has 2+ tools, and the wrapper element is identical regardless of size so 1→2 never remounts (tool-fallback.tsx:411-428). iOS today triggers collapse on **turn-total** `tools.count >= 2` (ChatStore.swift:851) then collapses **every** cluster (ChatModels.swift:242-254) — producing multiple "1 tool call" capsules. **Change: collapse decision is per-cluster (cluster has ≥2 tools), not turn-total.** A single-tool cluster renders its lone row (desktop transparent passthrough). `turnElapsed` may still be attached for the header label.
- A turn whose only content is a tool cluster renders one bubble with no text/footer (desktop tool-only turn).

### 3.3 Thinking (desktop `ReasoningAccordionGroup`)
- Renders **in wire position** (before the text it precedes), NOT pinned to top. With the §2.5 fix this holds.
- Auto-open while streaming, auto-collapse when settled; first explicit user toggle wins (desktop thread.tsx:344-351). `ThinkingView` should adopt this default.

### 3.4 Turn grouping + spacing (desktop virtualizer + role layout) — FIX D11
- **Turn group** = a `user` message + every following non-user message until the next user (desktop `buildGroups`, thread-virtualizer.tsx:36-68). Replace the flat `LazyVStack(spacing: 14)` (ChatView.swift:366) with role-aware grouping: tight intra-turn gap (desktop `--conversation-turn-gap = 0.375rem`), larger inter-turn gap.
- **Role layout** (desktop thread.tsx): user = trailing bubble; assistant = leading, full-width, no bubble; system/collapsed = centered/dimmed and visually separated from turn rhythm (so cron/system rows stop reading as evenly-spaced clutter).
- Intra-bubble spacing (parts 8 / segments 12 / tool rows 6) stays.

### 3.5 Action row + Copy — FIX D10
- Action row visibility must key on **rendered text presence** (`!message.parts.contains(where: .text non-empty)` is false), not the legacy `message.text` (MessageBubble.swift:247). Since `message.text` is now derived from parts (§2.1), Copy/Share (MessageBubble.swift:359-362) yield exactly the displayed prose — divergence (D10) is structurally impossible.

### 3.6 Scroll on reseed — FIX D13
- `onChange(of: transcriptGeneration)` force-scroll to bottom (ChatView.swift:410-414) must NOT fire when the user is scrolled up reading. Gate it the same as live scroll: only auto-scroll when already near bottom (the `scrollToBottomIfNeeded` policy already exists, ChatView.swift ~:420). Reseed should also preserve identity (stable ids, §2.2) so turns don't visibly restack under the reader.

### 3.7 Foreign-mirror reconcile — FIX D9
- `teardownForeignStream` (ChatStore.swift:1930-1956) removes the in-flight foreign row then awaits async `backfill()` (:635-637), creating a blink-out window. **Change: do not remove the placeholder before the reseed lands; reconcile in place** (desktop incremental repository sync `addOrUpdateMessage` then delete-missing then `resetHead` — incremental-external-store-runtime.ts:36-58 — never tear down + rebuild). The seed producer now yields the same structure, so a reconciled foreign turn keeps identity and does not restack.

---

## 4. MIGRATION PLAN — ordered batches (builder + gate pipeline)

Each batch is one builder unit with a gate. "Must-not-regress" lists are gate checklists.

### Batch A — Canonical model + derived accessors (foundation)
- **Files:** `Models/ChatModels.swift`.
- **Do:** make `parts` the sole source; convert `text/thinking/tools` to derived computed accessors; delete `legacyAssistantParts`, the `assistantRenderParts` salvage clauses (:117-139), the dual-write halves of `setWarningPart`/`setUsagePart`; switch `newPartID` from `UUID()` to deterministic run-index/`tool_call_id` ids (:301-303).
- **Must not regress:** copy/retry/edit ordinals (`userOrdinals`, ChatStore.swift:1730-1734), checkpoint/branch payloads, export — all now read derived accessors; verify identical strings.
- **Gate:** existing `HermesMobileTests` (357 pass / 4 skip baseline per doc) green; `ProtocolParityABH46Tests.testAssistantPartsPreserveTextToolTextOrder` green.

### Batch B — Widen `StoredMessage` + seed producer
- **Files:** `Models/ProtocolTypes.swift` (StoredMessage :224-247), `Stores/ChatStore.swift` (`chatMessage(from:)` :1737-1749, `classify` :1755-1778, seeding :1700-1850).
- **Do:** retain `tool_calls/tool_call_id/tool_name/reasoning/finish_reason` (§2.3); implement `toChatMessages` (§2.4) building ordered interleaved parts + tool-result merge + turn coalescing; keep cron/system `.collapsed` presentation.
- **Must not regress:** machine-scaffolding collapse, automation-preamble detection (:1771), empty-row filtering.
- **Gate:** seed of the live 15-row session yields ONE assistant bubble per agentic turn with interleaved parts and merged tool results; no standalone tool rows; no lost reasoning.

### Batch C — Stream reducer parity fixes
- **Files:** `Stores/ChatStore.swift` (`handleMessageComplete` :814-862, flush :1299-1321), `Models/ChatModels.swift` (`applyFinalText`/`replaceTextParts` :165-189/:305-322, `applyFinalReasoning` :191-201, `upsertToolActivity` :203-224).
- **Do:** fix reasoning in-place (no index-0 insert); fix final-text to never cross a tool boundary; lock flush-before-tool ordering; deterministic ids on all `else` branches.
- **Must not regress:** interrupted-turn early-return, errored-turn inline warning persistence, R1 ownership machinery (`endLocalTurn`/`localTurnToken`/`streamingIsForeign` asserts, ChatStore.swift:705-733/:856-861/:1936-1948 — these invariants are correct and must stay byte-for-byte), tool grouping into clusters.
- **Gate:** stream-equivalence property test (§4.test) passes for the live session's frame sequence.

### Batch D — Render contract (grouping, spacing, collapse, cursor, footer)
- **Files:** `Views/Chat/MessageBubble.swift`, `Views/Chat/ChatView.swift`, `Views/Chat/ToolActivityRow.swift`, `Views/Chat/ThinkingView.swift`.
- **Do:** per-cluster collapse (§3.2), wire-position thinking + auto-open/collapse (§3.3), turn-aware spacing (§3.4), action-row keys on derived text (§3.5).
- **Must not regress:** Read-more behavior on collapsed rows, ToolCard/TodoCardView rendering from `todos` (ChatModels.swift:393), code-block segmentation, serif prose face (MessageBubble.swift:336).
- **Gate:** seed and live render of the same turn are structurally identical on-device (ios-qa visual pass).

### Batch E — Reconcile/scroll (foreign mirror, reseed scroll)
- **Files:** `Stores/ChatStore.swift` (`teardownForeignStream` :1930-1956, `backfill` :1802+, `transcriptGeneration` :1706-1720), `Views/Chat/ChatView.swift` (:410-414).
- **Do:** in-place reconcile without placeholder removal (§3.7); gate reseed scroll to near-bottom (§3.6).
- **Must not regress:** R1 foreign/local ownership asserts, backfill telemetry counters, reconnect/foreground refresh.
- **Gate:** mirrored desktop-driven turn does not blink out or restack; scrolled-up reader is not yanked on reconnect.

### 4.test — Test plan
1. **Seed/stream structural-equivalence property test (NEW, the headline gate):** a fixture set of conversations (incl. the live 15-row session, a `text→tool→text→tool→text` turn, a tool-only turn, an interrupted turn, an errored turn, a multi-tool-cluster turn). For each: run frames through the stream producer; serialize `[ChatMessage]` to a structural signature `(role, [part-kind+id-shape+text-or-toolids])`. Independently run the same conversation's history through the seed producer; assert **identical signatures**. This is the `structure(seed) == structure(stream)` acceptance invariant encoded.
2. **ID-stability test:** stream a turn, then reseed it from history; assert message id and every part id are equal (no churn).
3. **Ordering tests:** extend `ProtocolParityABH46Tests.testAssistantPartsPreserveTextToolTextOrder` to cover seed path too; add reasoning-stays-in-position and prose-never-crosses-tool-boundary cases.
4. **Per-cluster collapse test:** `text→toolA→text→toolB` yields two single-tool clusters, neither collapsed; `toolA,toolB` consecutive yields one collapsed cluster.
5. **Existing suite:** full `HermesMobileTests` stays green (baseline 357/4).

---

## 5. GLITCH-HYPOTHESIS → FIX MAP (acceptance checklist)

| # | User-observed symptom | Defect (audit) | Root anchor | Fix (batch) | Verified-by |
|---|---|---|---|---|---|
| 1 | Turns restack on reopen; tools jump above prose; prose merges; thinking/tools/usage vanish | D1+D2+D5 | ChatStore.swift:1737-1749 (`parts:[]`) + ChatModels.swift:276-299 (legacy fixed order) + StoredMessage drops fields (ProtocolTypes.swift:224-247) | Batch B (widen StoredMessage + `toChatMessages` ordered seed) + Batch A (deterministic ids) | Test 1, 2 |
| 2 | Mirrored/desktop-driven reply blinks out then pops back restructured | D9 (+D1) | ChatStore.swift:1930-1956 (remove-then-async-backfill) | Batch E (in-place reconcile) | Batch E gate |
| 3 | Thinking disclosure jumps to top at completion | D3 | ChatModels.swift:191-201 (`insert at:0`) | Batch C (reasoning in-place) | Test 3 |
| 4 | Upper paragraph disappears/merges below a tool at completion | D4 | ChatModels.swift:305-322 (`replaceTextParts` last-slot) | Batch C (no prose across tool boundary) | Test 3 |
| 5 | Prose/tool blocks flicker / re-insert mid-stream instead of growing | D5+D6+D12 | ChatModels.swift:301-303 (`UUID()` per part) | Batch A (deterministic part ids) | Test 2 |
| 6 | Multiple tiny "1 tool call" capsules instead of one tool group | D8 | ChatStore.swift:851 (turn-total) + ChatModels.swift:242-254 (collapse-all) | Batch D (per-cluster collapse) | Test 4 |
| 7 | Scroll yanked to bottom + restack on reconnect/foreground while reading | D13 | ChatView.swift:410-414 (unconditional scroll) | Batch E (gate reseed scroll) + Batch B (stable structure) | Batch E gate |
| 8 | Copy yields different text than displayed; action row missing on parts-only turns | D10 | MessageBubble.swift:247/:359-362 (keys on legacy `text`) | Batch A (derived `text`) + Batch D (action-row keys on parts) | Batch A gate |
| 9 | Even, ungrouped spacing; system/cron rows clutter turn rhythm | D11 | ChatView.swift:366 (flat `spacing:14`) | Batch D (turn-aware spacing) | Batch D gate |
| 10 | Latent duplicate warning/usage if any path writes legacy fields | D7 | ChatModels.swift:117-139 (salvage clauses / dual-write) | Batch A (delete dual-write; single source) | Batch A gate |

**Acceptance:** all ten rows checked, Test 1 (seed/stream structural equivalence) green, full `HermesMobileTests` green, and an on-device ios-qa pass confirming a reopened session is visually indistinguishable from the same session watched live.

---

### Appendix — load-bearing files
iOS: `apps/ios/HermesMobile/Models/ChatModels.swift`, `apps/ios/HermesMobile/Models/ProtocolTypes.swift`, `apps/ios/HermesMobile/Stores/ChatStore.swift`, `apps/ios/HermesMobile/Views/Chat/MessageBubble.swift`, `apps/ios/HermesMobile/Views/Chat/ChatView.swift`, `apps/ios/HermesMobile/Views/Chat/ToolActivityRow.swift`, `apps/ios/HermesMobile/Views/Chat/ThinkingView.swift`, `apps/ios/HermesMobileTests/ProtocolParityABH46Tests.swift`.
Desktop ref: `apps/desktop/src/lib/chat-messages.ts`, `chat-runtime.ts`, `app/session/hooks/use-message-stream.ts`, `use-session-actions.ts`, `app/chat/index.tsx`, `lib/incremental-external-store-runtime.ts`, `components/assistant-ui/thread.tsx`, `thread-virtualizer.tsx`, `tool-fallback.tsx`, `types/hermes.ts`, `hermes.ts`, `styles.css`.
