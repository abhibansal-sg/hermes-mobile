# QA-3 Forensics Ledger — Device screenshots IMG_2577–IMG_2594 (build 116)

**Session under test:** "CLIProxyAPI vs llm-proxy Co..." (project llm-proxy, /Users/abbhinnav/Developer/products/llm-proxy), model qwen3.8-max-preview; secondary session "Upcoming Pending Orders" (project Aheli, /Users/abbhinnav/Documents/02-Businesses/Aheli).
**Capture window:** 2026-07-21 10:42–11:30 local (status-bar clocks). Owner dictation arrived old→new; ledger below is chronologically ordered.
**Relay-log correlation source:** ~/Library/Logs/Hermes/relay.log (push.register 10:36:35 ×2; APNs fan-outs 10:46:25 + 10:49:04 → 3 tokens: 2 stale production …cb1f27/…920549 + sandbox …bd6b4a).

## IMG_2577 — 10:42 — bugRefs S1, S2
Session "CLIProxyAPI vs llm-proxy Co...", keyboard open, turn just submitted (red stop button active).
Sequence top→bottom: [scrolled-off prior assistant text "...hat." / "postcard. The history scrub is still pending from the hardening list."] → [USER: "I want to review how the proxy is transforming the messages for anthropic models when used in hermes. And compare it to how native Claude code sessions handle it"] → [small static blue vertical bar/cursor mark — no spinner, no "Working" text, no timer] → [project/CWD row "llm-proxy · /Users/abbhinnav/Developer/products/llm-proxy"] → [composer, stop red/active].
No working affordance visible at all even though the stop button shows the turn in flight — consistent with S2 late affordance. The lone static blue bar between the user message and the CWD row is the plausible S1 cursor candidate (bare, textless, motionless). CWD→composer gap moderate in this frame.

## IMG_2578 — 10:43 — bugRefs S2, S3, S1
Same session, ~1 min after send, turn still in flight (stop active), keyboard open.
Sequence: [USER bubble (same prompt)] → ["⚙ Working... 35s >" row — spinner icon + inline elapsed timer] → [separate static blue vertical bar, unlabeled, directly below] → [CWD row] → [composer, stop active].
Direct proof of S2: affordance only now visible, already reads **35s elapsed** (matches spec "~35s after send" almost exactly). Direct proof of S3: TWO working affordances stacked simultaneously — labeled "Working... 35s" spinner+timer row AND separate unlabeled blue cursor bar — not one merged breathing-cursor line.

## IMG_2579 — 10:47 — bugRefs S4
Same session, turn completed (no stop button), scrolled to middle position.
Sequence verbatim: [dimmed assistant text: "live *somewhere* the model can see it, and" / "...tem[] is billing-forbidden. The use..." / "is the only remaining channel." / "### What native CC does instead (for context)" / "Claude Code puts its "personality" in:" / numbered list 1-4 / "It never has a "soul block" — it's a coding tool, not a persona agent. Hermes is fundamentally different, which is why the proxy has to relocate content that CC never generates."] → [action-icon row: copy/retry/branch/share/speak] → [USER bubble (same prompt)] → [CWD row] → [composer].
**The assistant's answer renders ABOVE the user message that prompted it** — exactly S4.

## IMG_2580 — 10:47 — bugRefs S4
Same session, scrolled near the very top of the answer, turn completed.
Sequence: [USER bubble (same prompt)] → [collapsed row "Worked >"] → [ASSISTANT markdown: "## Hermes via Proxy vs Native Claude Code — Wire Comparison" / "### What Anthropic's API actually receives" / table system[0]="You are Claude Code, Anthropic's officia[l] CLI for Claude.", system[1]="x-anthropic-billing... header: cc_version=2.1.210...xx; ..."].
Here order IS correct (user before answer). Same clock minute as IMG_2579/2581 showing the SAME content in WRONG order — identical exchange renders in two different orders depending on scroll position within one session view: duplicate/split render, not a one-off glitch.

## IMG_2581 — 10:47 — bugRefs S4
Same session, same scroll position as IMG_2579 — pixel-identical content (owner re-shot to be sure). Reinforces the answer-above-prompt state is stable/reproducible, not a one-frame flicker.

## IMG_2582 — 10:47 — bugRefs S4, S6
Same session, scrolled to bottom of the answer.
Sequence: [ASSISTANT text ending "...But not CC-native behavior — a real CC session's first user message is just the user's prompt" / "This is the tradeoff we're locked into: soul must live somewhere the model can see it, and system[] is billing-forbidden. The user message is the only remaining channel." / "### What native CC does instead (for context)" / list 1-4 / closing paragraph] → [action-icon row] → [CWD row] → [composer].
**No user message bubble between answer and CWD row** — the answer flows directly into CWD/composer chrome as if last item, prompt absent from its expected end-of-thread slot. Flip side of S4/S6: prompt not just misordered but missing where it belongs at the bottom of a completed turn.

## IMG_2583 — 10:49 — bugRefs S5, S13
CLIProxyAPI session in background; in-app notification banner overlaid at top.
Banner text verbatim: "Hermes finished" (label "now") / body: `HTTP 403: {"code":"unauthenticated:bad-credentials","error":"The OAuth2 access token could not be validated."}`.
Raw HTTP 403 JSON surfaced verbatim via push/finish banner while viewing an unrelated session — violates C3 (no error theater); the S5 artifact. Background content unchanged from IMG_2582 → banner belongs to a DIFFERENT session's turn.
Log correlation: relay.log APNs fan-out to 3 tokens (2 stale production + 1 sandbox) at 2026-07-21 10:49:04 (lines 220-222) matches the banner's "now" at 10:49 — this banner is the client-side rendering of that push/finish event. Surrounding lines (10:49:02–10:49:48): interleaved polling of sessions 20260716_010204_477a7a and 20260720_171346_ad9133 — either is the plausible 403 source (neither is the on-screen CLIProxyAPI session nor the Aheli session in IMG_2584).

## IMG_2584 — 10:49 — bugRefs S6
Session "Upcoming Pending Orders" (Aheli).
Sequence: [ASSISTANT table "Upcoming Pending Orders" — Trans Orient ~12,328...; Rich ~2,583; Combined ~14,911/~23,491] → "---" → "One confirm from you: was 3 Jul SGD 8,580.48 to Trans Orient?" bullets → "(Jul 3 1,449.70 was an internal OCBC transfer, not a supplier FAST.)" → [action-icon row] → [USER: "Yes, internal transfer is usually to rich"] → [CWD row "Aheli · ..."] → [composer IDLE — no stop, no working/spinner row].
Reply echoed as sent but no working affordance, no response activity; composer at rest as if nothing in flight. S6 family: message sent in second session shows no working indication, outcome unaccounted for.

## IMG_2585 — 11:25 — bugRefs S6, S8
Back in CLIProxyAPI session, 38 min after IMG_2577–2582, new turn in flight.
Sequence: [same prior assistant text ending "...relocate content that CC never generates."] → ["⚙ Working... · ToolCall 5s >" row] → [CWD row] → [composer, stop red/active].
**No user message bubble anywhere** between prior answer and the new Working row — fresh turn running (5s young, stop active) but the triggering prompt is missing from view: S6 "prompt vanished" pattern now inside the ORIGINAL session.
Log correlation: relay.log websocket connection opens at 10:46:31, 10:47:18, and 11:25:28 (line 237) — the 11:25:28 open is within ~1s of this clock (11:25) and the 5s timer, consistent with a fresh connection/resubmit cycle (reconnect plausibly dropped the optimistic echo of the prompt).

## IMG_2586 — 11:26 — bugRefs (baseline)
Same session, idle/settled, mic active (not generating).
Sequence: [assistant tail "...billing risk. Soul still present. Skills still accessible (via tools, which the model already knows how to call)."] → "## Direct answer" → quoted "Is this the best possible way for us to transform the message?" → bold "The proxy transform is optimal given its inputs." + paragraph → "That's the one remaining high-impact item. Want me to implement the Hermes system shrink?" → [action-icon row] → [USER: "How confident are you about this? Can you run a few live smoke test and tell me what give the best results?"].
Standard chronological order — no defect; baseline. Matches relay.log GET .../20260716_010204_477a7a/messages at 11:26:04.

## IMG_2587 — 11:26 — bugRefs S3, S1
Same session, turn now in flight (red stop).
Sequence: [assistant tail] → [USER bubble (smoke-test prompt)] → ["Working... · Running code from hermes_tool... 1s >" status row (spinner + status text + inline timer "1s" + chevron)] → [SEPARATE static blue vertical bar block directly below] → [footer "llm-proxy · ..."].
Two distinct visual affordances stacked (spinner/status/timer row PLUS separate cursor bar) — S3 dual-affordance again. Cursor shows no pulse in the still. Affordance appeared fast here (~1s) → S2 latency not evidenced in this frame.

## IMG_2588 — 11:27 — bugRefs (no defect)
Same session, turn completed.
Sequence: [assistant tail] → "## Direct answer" → quoted line → bold lead + paragraph → "Want me to implement the Hermes system shrink?" → [action-icon row] → [USER bubble (smoke-test prompt)] → [collapsed "Worked >" row] → [SECOND action-icon row] → [footer]. Composer idle. Working row correctly collapsed to "Worked" — no defect.

## IMG_2589 — 11:27 — bugRefs S7
Same session, scrolled up mid-generation (stop active), jump-to-bottom FAB visible.
~Top 70% of screen (header→just above text) is pure blank/void — no content, no skeleton, no loader. Only near the bottom: "Worked >" row, then "## 1. Primary Request and Intent" heading, then "The conversation spans multiple interconnected workstreams on Abhi's [llm]-proxy multi-account Claude proxy s[ystem] Hermes Agent memory system:" (partly occluded by FAB/composer). Large blank scrollback + partially-rendered message beneath — the scroll-up void.

## IMG_2590 — 11:27 — bugRefs S7
Same session, scrolled further — stop active, FAB visible.
The ENTIRE content region between header and composer is completely blank/void — no text, no skeleton anywhere; only chrome (header, FAB, composer with red stop). More extreme instance of the same void-on-scroll, one screenshot later in the same gesture.

## IMG_2591 — 11:28 — bugRefs S8
Session "Upcoming Pending Orders" (Aheli), keyboard open, red stop = active turn.
Sequence: [assistant tail, faded "...3 1,449.70 was an internal OCBC tra[nsfer]... not a supplier FAST.)"] → [USER: "Yes, internal transfer is usually to rich"] → ["Working... · ToolCall 5s >" row] → [static blue cursor bar] → [rounded chat-bubble containing literally "??", right-aligned user-bubble styling] → [SECOND "Working... · ToolCall 5s >" row] → [footer "Aheli · ..."].
Two "Working...ToolCall 5s" rows sandwich an unresolved "??' placeholder — timeline shows working state for BOTH previous AND current turn with an unrendered item between, no error/recovery. Direct literal match for S8 ("the '??' session showed working for previous AND current turn, nothing ever arrived"). Relay log: this session (20260720_171346_ad9133, inferred) fetched at 11:28:01.

## IMG_2592 — 11:28 — bugRefs S9, S8
Sessions drawer open (Sessions/Projects tabs, profile "default", search, Inbox, Automation, Chats 50) over the same Aheli session, dimmed.
Drawer list: "Ordering Birthday Flowers for..." (16h ago) → "Internal Disk Management Check" (17h) → "Upcoming Pending Orders" (current, 18h) → "New chat — https://openship.io" (22h) → "Serving Other Models via Proxy" (yesterday) → "Project Relay Status Review" (yesterday, under New-chat FAB) → "Reply exactly: QWEN38_CTX_..." (bottom, cut off).
Dimmed background still shows the unresolved IMG_2591 state (Working×2, cursor bar) — drawer opened WHILE the S8 double-working/"??" turn was unresolved. Consistent with S9 acceptance scenario (tap/drawer-open during in-flight load); a single frame alone doesn't prove dismiss failure.

## IMG_2593 — 11:28 — bugRefs S10
Projects tab → "hermes-mobile" project detail (PROJECT header, back chevron, "New Session" row at /Volumes/MainData/Developer/products/hermes-mobile, SESSIONS 0).
Body: "New Session" row → "SESSIONS 0" header → empty-state "No sessions yet — Start a new session above to begin working in this project."
Despite hermes-mobile being the actively-developed project (dozens of real sessions), the screen reports ZERO sessions — direct S10 hit. Dimmed edge shows prior chat still rendering Working×2 + "Hi" bubble + composer "+ / qwe[n...]" through the transition — underlying chat state persists behind project navigation.

## IMG_2594 — 11:30 — bugRefs S11
Fresh/untitled chat (header = model name "qwen3.8-max-preview" only — a New Chat), keyboard open, unsent draft.
Top of the otherwise-empty timeline: ["Working... · ToolCall 7s >" row] → [static blue cursor bar] — with NO user message above/below, and the composer holds an UNSENT draft: "I'm exploring the idea of how can I attach a persistent hermes session to use Claude code. Meaning I can use |" (cursor mid-word, not submitted).
A brand-new chat renders ANOTHER session's Working/ToolCall row before anything was sent. Relay log has no session-messages fetch at this timestamp (last: 20260720_171346_ad9133 @11:29:15, 20260716_010204_477a7a @11:29:18; next activity 11:33:51) — the new chat never made its own backend request; the Working row is stale leaked client-side state from the previous session's in-flight turn, not anything happening in this chat.

## Cross-cuts
- **S13 tokens:** fan-outs at 10:46:25 + 10:49:04 each post to …cb1f27 (prod, stale) + …920549 (prod, stale) + …bd6b4a (sandbox, the phone). Stale entries carry device_id:null → survived QA-2 device_id-keyed dedup.
- **S5 text:** `HTTP 403: {"code":"unauthenticated:bad-credentials","error":"The OAuth2 access token could not be validated."}` — upstream OAuth failure surfaced raw in a "Hermes finished" notification body.
- **Chronology set pieces for render_conformance replay:** IMG_2579/2580/2581/2582 (answer-above-prompt, split render, missing-prompt-at-bottom), IMG_2585 + IMG_2591 (prompt-vanished + double-working), IMG_2589/2590 (void scrollback), IMG_2594 (cross-session leak).
