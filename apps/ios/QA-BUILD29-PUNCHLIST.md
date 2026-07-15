# Build 29 full-app guided QA — live :9119 (de-patched, plugin paths)

Format: one step at a time; ✅ / finding. I watch /tmp/qa29/events.log server-side.
Punch list grows at the bottom; everything fixes in ONE batch → build 30.

## A. Launch & connect
- [x] A1 ✅ (tap confirmed resume + provider enrichment)
- [ ] A2 Face ID lock (if enabled) gates and unlocks

## B. Sessions drawer
- [x] B1 ✅
- [x] B2 pin ✅ rename ✅; search = findings 10-13
- [x] B3 ✅ (+ findings 14-15)
- [x] B4 ✅ (covered during approval tests)
- [x] B5 ✅ works; relocation request = finding 16

## C. Chat core
- [x] C1 ✅ (stick-to-bottom correct)
- [x] C2 ✅ clean; finding 17
- [x] C3 ✅
- [ ] C4 code block + ANSI rendering
- [ ] C5 scroll feel: history load, stick-to-bottom, keyboard

## D. Attachments
- [ ] D1 camera capture → agent sees image (vision Q)
- [x] D2 photo library — KNOWN BUG #1 (picker won't open)
- [ ] D3 document scanner
- [ ] D4 sent-image bubble — KNOWN GAP #2 ("Attached Image", no thumbnail)

## E. Files
- [x] E1 composer → Browse Files → open file (PASSED earlier)
- [x] E2 3-dot → working dir → file open — KNOWN BUG #3
- [x] E3 @-button in viewer — KNOWN UX #4
- [ ] E4 @-mention autocomplete in composer

## F. Approvals (with server-side tap)
- [x] F1 investigated — see #9 update (needs offline test on 9124)
- [ ] F2 deny → agent blocked message
- [ ] F3 approve → command runs
- [ ] F4 inbox collects cross-session approvals
- [ ] F5 audit view shows the resolution w/ device attribution

## G. Push & Live Activity
- [ ] G1 turn >30s + app backgrounded → turn-complete push
- [ ] G2 approval push (manual mode) + approve from notification action
- [x] G3 Live Activity timer — KNOWN BUG #8 (stuck at 0; LA registry empty)
- [ ] G4 push prefs toggles respected

## H. Voice & TTS
- [ ] H1 dictation (mic) → transcribed into composer
- [ ] H2 TTS speak a reply

## I. Panels & settings (S4 surface!)
- [ ] I1 model picker: switch model in a session (pill updates; other sessions unaffected)
- [ ] I2 fast toggle pre-first-turn then send (S4 parked-override path live)
- [ ] I3 reasoning effort change reflects
- [ ] I4 usage / cron / skills panels load
- [ ] I5 theme + appearance

## J. Multi-client
- [ ] J1 phone→Mac mirror (phone sends; Mac shows live)
- [x] J2 Mac→phone: reply mirrors live; OWN prompt doesn't — KNOWN GAP #6
- [ ] J3 cross-session banner / approval inbox from foreign session

## K. Extras (quick pass)
- [ ] K1 widgets show status/usage
- [ ] K2 share sheet → app inbox
- [ ] K3 hermesapp:// deep link
- [ ] K4 Siri shortcut (if configured)

## PUNCH LIST (running)
1. Photo Library picker won't open (PhotosPicker-in-Menu) — BUG
2. Sent image: "Attached Image" placeholder, no thumbnail — GAP
3. 3-dot → working dir → file won't open — BUG
4. @-button in file viewer: no visible feedback — UX
5. Device row looks tappable, does nothing — UX
6. Mac→phone: own prompt not mirrored live (reply is) — GAP (foreign-frame)
7. (resolved: turn-complete push needs >30s — by design; retest properly in G1)
8. Live Activity timer stuck at 0 — BUG (LA token registry empty server-side)
9. Approval card: tap confirms server emits NO approval.request for these commands → smart mode auto-decides (by design, explains 'never seen'). Manual-mode card render is UNVERIFIED end-to-end on mobile — agent caches mode at build, so a live flip didn't take for pre-built sessions. MY HOMEWORK: drive manual-mode approval on isolated 9124 w/ fresh agent + WS client, confirm approval.request emits AND iOS renders the card. Then decide real-bug vs by-design.
10. Search: results feel incomplete + unclear sort order — BUG/UX (investigate scope+ranking)
11. Search: opening a result doesn't jump to the matched message — GAP
12. Search: cluttered by tool/thinking verbose; want scope toggle (user msgs + final replies only) — FEATURE
13. Desktop: session rename only reflects after desktop restart — DESKTOP lane, later
14. Delete context-menu: trash icon should be red like the label — POLISH
15. Archived list: tapping a chat opens it but drawer doesn't dismiss — UX BUG
16. Automation runs buried under Settings → move to a drawer tab next to Archived — UX/FEATURE
17. Interrupt discards partially-streamed text (should persist with marker); stale "waiting for model response" label alongside "turn interrupted" — BUG/UX
18. **P0** UI FREEZE on reconnect→open-drawer (reliable repro, force-kill recovers) + opened sessions render EMPTY though server has full history (verified: 1-to-30 + lighthouse both intact in state.db). Client reconnect/hydration race. Crash report in TestFlight feedback.
19. Interrupted turns don't persist the USER message or partial assistant text to state.db (verified server-side: lighthouse session stored only assistant-empty + tool rows; user prompt absent) — SERVER BUG, shares root with #17; gateway interrupt/persistence path


## BUILD STATUS
- Build 30 (VALID, verified by user): P0 reconnect freeze [#18] + photo picker [#1] FIXED.
- Build 31 (uploaded): LA local timer [#8], archived drawer-dismiss [#15], file-viewer @-mention [#4] FIXED.
- RECLASSIFIED out of quick-fix: sent-image thumbnail [#2] = feature (server stores "Attached Image" text; needs image-fetch endpoint or local cache surviving restart); working-dir picker file-open [#3] = UX decision (it's a directory picker by design).
- REMAINING (need steer / server / design): search overhaul [#10-12], interrupt persistence [#17-UI + #19-server], automation drawer tab [#16], device-row tap [#5], red trash icon [#14], working-dir-picker decision, sent-image thumbnail.
