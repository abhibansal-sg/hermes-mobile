# ABH-519 device reliability pre-fix evidence

Source device: physical iPhone Air, build 127, USB-connected.

## Long assistant prose

- Session: `20260723_203806_d5b079`
- Gateway transcript: 2 rows.
- Phone GRDB cache: 2 rows; assistant `rowJSON` is 5,175 bytes.
- Assistant content: 4,034 characters.
- Gateway content and cached phone content produce the same SHA-256 when emitted with a trailing newline: `bcf26919c217e8db5b323c69b6354ebb0f54c8f3eccf52697b1b24eeb9be57e3`.
- Physical UI initially rendered items 1 through 9 and only the marker `10`, then blank space.
- The message toolbar's Copy action copied the complete text through item 12 and the final paragraph.
- Force-close/reopen preserved the cutoff. Switching away and back caused the same bytes to lay out fully.

Conclusion: transport and persistence are byte-complete. The defect is in the mounted long-prose layout path, not transcript delivery.

The historical contracts mention a DEBUG `StateServer`, but this checkout contains no implementation of `/state/snapshot`, `/state/restore`, or `/screenshot`. The exact device-shaped transcript is therefore preserved in `apps/ios/HermesMobileTests/Fixtures/ios_fix_long_prose.json`; no synthetic UI-state snapshot is claimed.

## Project detail

- `/api/plugins/hermes-mobile/projects` reported the `hermes-mobile` project with 72 sessions.
- The device-visible detail remained empty.
- The legacy `/api/sessions?cwd_prefix=<project root>` returned zero because worktree CWDs do not share the parent repository's path prefix.
- The plugin project detail route returned one row on the captured production install, proving overview/detail membership divergence.

## Earlier history

- The Venture session had 238 server rows; the phone initially held the latest 50.
- The plugin history endpoint returned a 50-row older page with `has_more_before=true` in under 30 ms locally and through the tailnet.
- The phone displayed `Loading earlier`, entered reconnecting, and inserted no rows.
- Device networking logs contain repeated 15-second `NSURLErrorDomain -1001` failures during this window.

## Retry/edit

The existing `ChatStoreOrdinalWindowingTests` fixture proves that the same user row receives ordinal 35 with full history and ordinal 5 in a 20-row tail. Sending that window-relative ordinal to stock `prompt.submit` can truncate the wrong server turn or yield the observed stale-message error.

## Notifications

- The phone did not show a normal turn-complete notification.
- The device had a production APNs token and enabled turn events in the captured registration.
- The relay's direct APNs test endpoint reported successful submission.
- This proves configuration and provider submission, but not delivery or turn-event observation. End-to-end notification acceptance remains required after the code fixes.

The stock v0.19 runtime currently serving the phone has none of the generic
ABH-88 event seams required by the plugin's retained architecture:
`post_emit_event`, `_EMIT_OBSERVERS`, and
`register_prompt_receipt_provider` are all absent. Therefore the plugin cannot
observe ordinary `message.complete` events or install S11 receipts without
patching stock core. Direct APNs submission can pass while normal completion
notifications remain impossible. This is an architecture/version gate, not an
iOS retry defect; no core monkey-patch was added.

## Focused post-fix proof

- Physical iPhone Air:
  - `ChatStoreOrdinalWindowingTests`: 4 passed.
  - `ProjectsStoreTests`: 17 passed.
  - `ProseSelectionTests`: 10 passed, 1 opt-in screenshot test skipped.
  - `TranscriptWindowRevealTests`: 8 passed.
  - Combined result: 40 executed, 1 skipped, 0 failures.
  - Build log: `/tmp/hermes-ios-build-32423.log`.
- Relay/plugin:
  - `test_projects_route.py` and `test_transcript_paging.py`: 28 passed.
- Signed app build:
  - `scripts/ios-build.sh build` succeeded.
  - Build log: `/tmp/hermes-ios-build-57888.log`.
  - Installed and cold-launched on the iPhone Air at 21:33–21:34 local time.
- Live read-only timing:
  - Stock 50-row transcript page over the same Tailscale relay: 0.05–0.21 s,
    353,429 bytes.
  - Current project detail route: 0.35 s.
  - The earlier device trace's two 15-second failures were transient request
    stalls, not a consistently slow relay path. The relay subsequently logged
    the phone closing timed-out requests before their upstream responses could
    be written. No blind retry was added.
