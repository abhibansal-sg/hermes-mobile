# TRANSCRIPT-DESIGN-SPEC — compact mode + clean chrome

**Origin:** Abhi (Board), 2026-07-08, verbatim intent captured with follow-up
Q&A. Companion to SMOOTHNESS-SPEC (STR-969: pipeline feel) — this one is the
VISUAL layer. Designer + architect refine together; every WU judged against
the design-system rubric (docs/design/, STR-308).

**Theme law for everything below: clean, minimal, consistent.** No emoji
glyphs in chrome, no spinners, in-box type never larger than body text,
one shared box aesthetic (the diff-render look: smaller mono font, tight
padding, muted chrome) across terminal/code/copy/diff blocks.

---

## T-1 COMPACT MODE (default transcript mode)

1. DEFAULT = COMPACT, always: every turn renders compact by default —
   fresh opens, re-opens, navigation returns. Expansion is per-turn,
   ephemeral (tap to expand a turn; when the TURN ENDS it re-collapses;
   navigate away + back = compact again). No persistence of expansion.
2. LIVE compact turn (ChatGPT/Claude-app pattern): while the agent works,
   show ONLY a two-line live status — model-distilled precise thinking
   points (not raw stream). Tap anywhere on it → expands to the full
   current view (thinking block, tool rows, etc.) for THIS turn until it
   ends.
3. DISTILLED STATUS SOURCE: auxiliary model generates the two-line status
   points from the live thinking/tool stream (Claude-style "Considering
   edge cases…"). Server-side summarization pass, throttled (~1 update/
   2-3s max), tiny prompt, cheap model.
4. AUX-MODEL SETTINGS (new Settings section "Auxiliary models"): user-
   configurable model per auxiliary function — status distillation,
   voice/dictation, title generation, any existing aux lanes — default
   sonnet-class. One picker pattern reused; gateway `config.set` backed.
5. Completed compact turn = user bubble + final assistant text only
   (thinking/tools hidden behind the tap-to-expand).

## T-2 THINKING BLOCK (expanded view) — remove the toy chrome

1. NO brain emoji (ThinkingView.swift:79 `Label(..., systemImage:
   "brain")` → plain text label). NO kaomoji/ASCII faces in mobile
   thinking streams: gateway indicator style defaults to kaomoji
   (server.py:1791-1792) — mobile must render thinking text with
   indicator faces stripped (render-layer filter or per-session
   config.set indicator=ascii-off equivalent; follow DESKTOP's clean
   treatment as the reference).
2. NO spinner. Active step row = the step's text with a SLOW PULSING
   GLOW (opacity/brightness breathe, design-system motion tokens) + a
   live seconds timer IN THE SAME ROW, right-aligned ("Reading files
   4s").
3. LIVE THINKING WINDOW: while thinking streams, show a small fixed-
   height block auto-scrolled to the tail (most recent always visible);
   the TOP EDGE FADES TO TRANSPARENT (gradient mask — no hard clip line,
   text "fades into darkness" upward). Clean, no border box.
4. ON SETTLE: the window collapses immediately to one line — "Thought
   for 47s" (m/s formatting) — tappable to re-expand the full text.

## T-3 CONTENT BOXES (terminal / code / diff / copyable) — one aesthetic

1. Adopt the diff-render look as THE canonical box style everywhere:
   mono font strictly smaller than body, red/green diff lines kept,
   minimal chrome, inline copy affordance, consistent corner radius +
   padding from the design tokens.
2. Terminal boxes are the worst offender today (font ≥ body size) —
   bring them to the canonical style.
3. Inline > boxed-in-a-box: kill nested backgrounds/double borders.

## T-4 STATUS INDICATOR — kill the pill, adopt desktop's inline glow

1. Remove the floating spinner pill at the bottom.
2. Desktop-parity treatment: an INLINE glowing status line (desktop's
   blue glow + elapsed time) that appears in-flow at the transcript tail
   when a turn is active and disappears when settled — never a floating
   overlay. In compact mode this IS the two-line distilled status (T-1);
   in expanded mode it rides the bottom of the active turn.
3. Session context line (desktop parity): when the session is attached
   to a gate/worktree/project context, show it the way desktop does at
   the transcript edge — small, muted, inline.

## T-5 TASK LIST — dock to composer

1. Remove the inline-in-chat task box. Task state DOCKS to the top edge
   of the composer.
2. Collapsed (default): one clean line — group/list title + "4/10"
   progress. Live-updates as the agent checks items.
3. Tap → expands upward into the full checklist (scrollable overlay,
   same clean style); tap-away collapses.
4. Keep the existing well-designed checklist internals — relocation +
   collapse are the change, not the list rendering.

## T-6 APPROVAL CARD — compact by default, full desktop option parity

1. Card renders COLLAPSED: 2-3 lines max (tool + one-line summary),
   expandable for the full command/detail. Never a full-screen wall.
2. Desktop option parity — extract desktop's exact approval option set
   and mirror it (Approve / Deny / always-allow variants incl. per-
   session always-allow). The current "always allow for this session"
   small-text row must be a REAL, obviously-tappable control (today's
   is unclear and possibly dead — verify + fix as part of the WU).
3. Same canonical box aesthetic as T-3.

## T-7 BUGS (file as type/bug, dispatch immediately — not design-gated)

1. YOLO bolt toggle (ComposerView.swift:728-751): reported non-working.
   It calls the desktop-parity config.set yolo path, but is silently
   disabled when disconnected/no-activeRuntimeId, gives no failure
   feedback, and pending state may swallow the tap. Root-cause +
   verified fix on a REAL session; add UI feedback when toggle is
   unavailable (why), and an XCUITest that flips it and proves the
   gateway state changed.
2. Profile switch: sessions fail to load properly after switching
   profiles; occasional CRASH on switch. Root-cause the crash
   (suspect: mid-refresh store teardown / cache rows keyed to the other
   profile). Also investigate the reported desktop-app disturbance
   during mobile profile use (session.resume with profile override
   mutates shared gateway state? _hermes_home override leakage —
   server.py _load_cfg override path).
3. All-profiles session list: desktop groups by profile with per-group
   expand; mobile has no grouping and its merged list is unreliable.
   Implement desktop-parity grouped list (collapsed per-profile groups,
   few recent + expand).
4. Project grouping: mobile's project list/counts don't match desktop
   for the same data. Audit: mobile filters client-side from the loaded
   window (SessionStore.swift:3651 — known gap, cwd_prefix unused);
   fix = server-side project session query (ties into SMOOTHNESS WS-4).

---

## Sequencing
- BUGS (T-7) dispatch NOW as fixes — no design dependency.
- T-2 + T-3 + T-4 (clean chrome) = one design WU cluster; designer
  produces the motion/box specs against tokens FIRST, then build.
- T-1 compact mode = the flagship WU: needs the aux-model settings
  plumbing (server + iOS) + distillation endpoint; spec the summarizer
  prompt + throttle in the WU before build.
- T-5, T-6 ride after the chrome cluster (reuse its box/motion tokens).
- Every UI WU: UI-evidence law (recordings iPhone AND iPad) + design-
  rubric review by the designer seat.
