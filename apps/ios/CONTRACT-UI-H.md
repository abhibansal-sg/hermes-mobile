# UI Batch H Contract — Context Meter + Workspace Grouping

Rules: INTERFACES.md recap; theme engine; Batches A-F + consolidation LANDED —
read POST-consolidation state (RestClient may have absorbed the satellite
clients; SessionsAPI/RestControlClient types may have moved). Small batch,
two S-effort modules. Keep all tests green + accessibility ids.

## H1 context-window meter — owns Models/ProtocolTypes.swift (additive),
Stores/ChatStore.swift (minimal), Views/Chat/ComposerView.swift (chip area),
Views/Panels/ModelPickerView.swift (stats header), MessageBubble usage footer
Server already emits, app currently DROPS: usage dict on every
message.complete carries context_used, context_max, context_percent,
compressions (tui_gateway/server.py:1587 _get_usage). Wire it through:
1. UsageStats: add optional contextUsed: Int?, contextMax: Int?,
   contextPercent: Int?, compressions: Int? (snake_case decode is automatic).
2. ChatStore: expose private(set) var contextUsage: (used: Int, max: Int,
   percent: Int, compressions: Int)? — updated in handleMessageComplete from
   the payload usage; reset on session open/draft; ALSO seed from
   session.status after resume (call it once post-open so a resumed session
   shows occupancy before its first new turn — session.status result usage
   carries the same fields).
3. Composer model chip → combined model+context affordance:
   - 2pt progress fill along the chip capsule's bottom edge, width =
     contextPercent, theme.midground; >= 75 → theme.statusWarn (compression
     threshold).
   - >= 50: chip text gains " · N%" suffix.
   - nil contextUsage → plain chip, zero layout shift.
   - accessibilityValue on the chip: "context N percent".
4. ModelPickerView (the chip's tap target): compact stats header when
   contextUsage present: "142K / 1M tokens · 14% · 2 compressions" (formatK
   helper: 142_000 → "142K", 1_000_000 → "1M"). Pass contextUsage in via
   init from the chip call site.
5. Turn usage footer (MessageBubble): append " · ctx 142K" when the turn's
   usage has contextUsed.
Semantics note (document in code): updates per completed turn (occupancy of
the last API prompt), not per streamed token.

## H2 workspace grouping — owns Models/ProtocolTypes.swift (cwd decode,
coordinate with H1's additive edit — integrator dedupes), Stores/SessionStore.swift
(grouping accessor), Views/Drawer/* (sections + toggle)
Desktop semantics (apps/desktop/src/app/chat/sidebar/index.tsx:160
workspaceGroupsFor — replicate exactly):
1. SessionSummary: decode cwd: String? (REST rows carry it; WS RPC rows nil).
2. SessionStore: var groupByWorkspace: Bool (DefaultsKeys, default false) +
   func workspaceGroups() -> [(id: String, label: String, sessions:
   [SessionSummary])]: group key = trimmed cwd or "__no_workspace__"; label =
   basename(cwd) or "No workspace"; groups keep recency order (first-seen in
   the recency-sorted input); WITHIN a group sort by startedAt DESC (stable —
   desktop's muscle-memory rule). Pinned sessions stay in the Pinned section
   regardless of grouping.
3. DrawerView: toggle lives in the existing Recents "…"/filter menu ("Group
   by workspace" checkmark item). When on: section headers (label,
   .footnote.semibold mutedFg, folder SF symbol) replacing the flat Recents
   list; cron-hide filter still applies inside groups. No drag-reorder of
   groups in v1 (desktop has it; skip — note as future).
4. Live-pulse, source glyphs, humanized titles, selection — all preserved
   per row (reuse DrawerSessionRow unchanged).

## H3 glass chrome — owns the floating-chrome call sites only
(ChatView pills + scroll-to-bottom pill, DrawerView New-chat capsule)
Principle: GLASS FOR CHROME, THEMES FOR CONTENT. On iOS 26+ the floating
layer gets the system Liquid Glass treatment exactly where the reference
Claude app has it; everywhere else (and on iOS 17-25) today's solid theme
fills stay. Content surfaces (transcript, composer card, drawer body,
sheets) are NEVER glassed — that re-breaks the six-theme identity (Batch A
G2 rationale).
1. Verify the exact SwiftUI API against the installed iOS 26.5 SDK before
   coding (expected family: .glassEffect(...in shape), GlassEffectContainer,
   .buttonStyle(.glass) — confirm signatures; do not guess).
2. Implement a single shared modifier in the Theme layer, e.g.
   `func chromePillBackground(_ theme: HermesTheme) -> some View` /
   `.chromePill(theme)`: if #available(iOS 26): glass effect in a Capsule/
   Circle; else: the current theme.card fill + border. Apply at the four
   call sites: hamburger pill, trailing actions pill, scroll-to-bottom pill,
   drawer "+ New chat" capsule. No other surface.
3. Legibility: glyphs on glass use theme.fg; verify against light AND dark
   wallpaper-ish content behind (scroll a busy transcript under the pills)
   on iOS 26 sim. Dark-only themes (midnight etc.) force dark scheme — the
   glass adapts; verify it doesn't fight the forced colorScheme.
4. Visual deliverables: /tmp/hermes-uiH-glass-light.png + glass-dark.png
   (pills over scrolled content, iOS 26 sim).

## H4 micro-polish — TurnActivityBar (ChatView.swift, owned by whichever
module the integrator assigns — likely H1 since it's in the chat area)
Remove the Stop button from the streaming TurnActivityBar — the composer's
morph button already shows stop while streaming (single affordance
principle, user request). Keep spinner + elapsed + current tool name.
Verify the "Stop turn" accessibility label moves to/remains on the
composer's stop state (ChatFlowUITests references it — update the test if
it targeted the bar's button).

## Integration
Standard ritual: reconcile (ProtocolTypes dedupe), xcodegen, build (Swift 6
strict), full live test suite (known-flaky cross-client policy applies), new
unit tests: UsageStats context fields decode + formatK + workspaceGroups
ordering rules (recency groups / creation-time rows / no-workspace bucket).
Visual: composer chip with meter at low% and (simulate by injecting a high
contextPercent via a debug seed if a real 75% session is impractical —
acceptable to screenshot the <75 state + unit-test the threshold color
logic), grouped drawer /tmp/hermes-uiH-grouped.png, stats header in model
sheet /tmp/hermes-uiH-stats.png. Device build sanity. Return standard JSON.
