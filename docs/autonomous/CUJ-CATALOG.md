# Critical User Journeys (CUJ) — the app's "must always work" catalog

**This file is the contract for staging smoke coverage.** Layer 3 of the test
pyramid: unit tests catch logic (layer 1), per-fix regression tests catch
recurrence (layer 2), THIS catalog catches "a user can no longer do a core
thing" (layer 3), the soak catches systemic decay under abuse (layer 4),
TestFlight + Abhi catch taste (layer 5).

## Rules (build practice, locked 2026-07-03)

1. **Every shipped feature that adds a user-facing capability MUST add or amend
   a CUJ entry in the same PR.** The reviewer's craft checklist includes this.
   No entry → the feature is invisible to the smoke gate → review FAIL.
2. Each CUJ has a **machine-checkable smoke** (REST/WS against the staging
   gateway) — cheap (<30s each), deterministic, evidence-producing. UI-only
   journeys (pure SwiftUI behavior) are marked `smoke: ios-sim` and covered by
   the iOS test suite instead — the smoke runner skips them but counts them.
3. The soak beat runs the FULL catalog first (breadth), THEN its abuse suites
   (depth). A CUJ failure = DO-NOT-SHIP, same as an abuse failure.
4. Keep it honest-sized: a CUJ is a JOURNEY (user intent), not an endpoint.
   Target ≤20 entries; consolidate rather than sprawl.

## Catalog (v1 — derived from shipped surface as of build 58)

| id | journey | smoke | added by |
|----|---------|-------|----------|
| CUJ-01 | Pair a device and get an authed session | `POST /api/devices/issue` + authed `/api/status` | core |
| CUJ-02 | Send a prompt, receive a completed reply | REST session create → prompt → completion | core |
| CUJ-03 | Gateway dies mid-turn → iOS survives, shows reconnecting, auto-recovers, re-attaches to the open session, and refreshes the transcript | WS flap + reconcile; `smoke: ios-sim` ConnectionStoreReconnectTests mid-turn drop path (ABH-276/278/288/289/355) | Malacca/ABH-355 |
| CUJ-04 | Approve/deny a pending approval from the phone; reply to a clarification from lock screen | `/api/approvals/respond` contract (ABH-258 ownership) + `/api/approvals/reply` clarify-only contract (ABH-296) | core |
| CUJ-05 | Sessions list, source-grouped drawer, search, resume | Recents default excludes cron/subagent + empty sessions AND machinery never enters the backing array via any ingress path (fetch, WS-triggered refresh, background refresh, load-more append, cache restore); the ingress filter is cursor-neutral (grow-limit pagination counts each server row exactly once via an all-seen-id set, so filtered machinery never inflates the cursor or halts loadMore before later human sessions; row-inclusion dedupes against the rendered `sessions` set so a working-set survivor reappearing in a grown-limit append is never appended twice); `smoke: ios-sim` drawer opens with reachable Chats + Telegram source groups only, honest counts/empty/error states, no cron/subagent drawer bucket, and `UX1DrawerFeedTests.testMachineryRejectedAtIngressOnLiveRefreshPath` + `testLoadMoreReachesHumanSessionsPastMachineryWall` + `testSurvivorReappearingInLoadMoreNotDuplicated` prove machinery sessions arriving on the live path never appear in the human drawer list, pagination reaches human sessions past a machinery wall, and a survivor reappearing in loadMore is present exactly once; `/api/sessions/search` + resume + messages readback | core/ABH-345/ABH-373 |
| CUJ-06 | Enable relay push + pair + truthful test-push | `/relay/config` → `/relay/pair` → `/relay/test-push` → `/relay/status` truthfulness, including direct-APNs vs relay vs no-push-configured outcomes (ABH-282/283/284/285, ABH-213, ABH-314) | wave-68 |
| CUJ-07 | Device tokens: pair → APNs token registers, honest Settings state, list, revoke (scope-gated) | iOS pair/foreground registers `/push/register`; with relay configured, POST `/push/register` exercises relay `register_device` enrollment without delaying the REST 200; Settings shows not-authorized / not-registered / registered truthfully; `/api/devices`, DELETE + approve-scope 403 (ABH-329, ABH-315, ABH-275, ABH-270) | push lineage |
| CUJ-08 | Provider list + key entry + rotate/replace an authenticated provider's API key from the phone (no key leak in response) | `/api/providers` + `/providers/{slug}/key` write→readback redacted; smoke asserts list_providers serves `auth_type=="api_key"` for an authenticated registered provider so tap-to-rotate remains provisionable | provider mgmt/ABH-268 |
| CUJ-09 | Cron jobs: list, delivery-failure surfaced, and live "Deliver to" target selection | `/api/cron/jobs` + `/api/cron/delivery-targets`; `smoke: ios-sim` opens cron editor, sees only connected targets, shows the home-channel hint for unconfigured-home targets, saves the chosen `deliver`, and keeps a CLI-created exotic `deliver` value selected instead of blank | cron/ABH-265 |
| CUJ-10 | File attach/upload → agent sees it | `/api/upload` + fs/read contract | share/capture |
| CUJ-11 | Kanban/agents visibility (active agents view) | `/api/agents` shape sanity | ops surface |
| CUJ-12 | Slash-command launcher lists real commands | slash-commands route (#104, ABH-228) | build 58 |
| CUJ-13 | Learning Journey read surface loads | learning.frames/detail (ABH-246) | build 56 |
| CUJ-14 | Credits/billing view loads (view-only) | credits surface (ABH-237) | build 56 |
| CUJ-15 | Manual context compress action and auto-compaction truth marker | compress route (ABH-222); `smoke: ios-sim` status.update kind=compacting shows an inline "Compressing older context…" marker only for the active session, not for a background session, and message.complete/kind-change clears it (ABH-363) | build 55 / ABH-363 |
| CUJ-16 | YOLO/flow-state approval-bypass toggle honored | toggle write + approval behavior contract (ABH-227) | build 55 |
| CUJ-17 | Device-limit 409 surfaced without composer lock | `/api/devices/issue` at limit → 409 contract (ABH-254) | fix lineage |
| CUJ-18 | Debug share bundle from settings | `/api/debug-share` produces a bundle (#90) | support |
| CUJ-19 | Recover the gateway from the phone (restart + update) with honest reconnecting state | POST /api/gateway/restart → poll /api/actions/gateway-restart/status until running:false; badge reads reconnecting while in-flight | Malacca |
| CUJ-20 | iPad keyboard user sends a message and navigates with Cmd shortcuts | `smoke: ios-sim` RootKeyboardShortcutActionsTests verifies shortcut action symbols fire / are wired | ABH-308 |
| CUJ-21 | iOS artifact-gallery image opens full-screen, zooms, and closes | `smoke: ios-sim` ZoomableImageViewTests verifies fit math, zoom/pan clamp invariants, double-tap min→zoom/reset toggle, and swipe-down dismiss gate; UI smoke must open an image artifact into `artifactZoomableImageViewer`, exercise pinch/double-tap zoom behavior, then close via `zoomableImageCloseButton`/swipe dismiss | ABH-242 |
| CUJ-22 | Projects tab loads real projects with session counts | `GET /api/plugins/hermes-mobile/projects` returns a JSON array of `{id,label,root,session_count}`; 401 without token; junk-filtered (no ~/.hermes, no bare home); empty → `[]` | ABH-350 |
| CUJ-23 | Turn ends by any path → Live Activity shows ended, never a zombie timer | `smoke: ios-sim` verifies staleDate expiry is visual END; plugin pytest proves non-happy teardown/startup sweep emit ActivityKit end frames | ABH-361 |
| CUJ-24 | Set working dir → visible confirmation + agent runs there | `smoke: ios-sim` WorkingDirectoryTests verifies displayPath + confirmationMessage AND the E2E cwd-plumbing round-trip (picker relative path → `WorkingDirectory.resolveCwdPlumbing` wire cwd == absolute join → gateway adoption contract: `adoptedCwd == wireCwd` or the plumbing fails nil, catching drift); UI smoke must open the overflow menu, see the current cwd label (or "Working Directory" when unset), open the picker, see the explainer banner, pick a folder, observe the E2E adoption probe (re-read via `fsList`) confirm the session adopted the sent cwd, and see a system confirmation row in the transcript; `session.cwd.set` plumbing verified server-side (`_set_session_cwd` sets `session["cwd"]` + persists `explicit_cwd`) | ABH-362 |
| CUJ-25 | Drawer Projects tab: browse projects, drill into sessions, start new session in project | `smoke: ios-sim` segmented Sessions/Projects toggle switches the drawer body; Projects list renders real projects with counts; tapping a project pushes ProjectDetailView with its sessions (cwd-matched); "New Session" action starts a draft with `cwd = project.root` (verified via the session.create `cwd` param round-trip) | ABH-351 |
| CUJ-26 | Assistant markdown renders desktop-grade GFM in message bubbles | `smoke: ios-sim` assistant bubble with a GFM table shows a bordered horizontally-scrollable native table (not raw dashes/pipes), task-list checkboxes, strikethrough, blockquote chrome, nested lists, links, and a LaTeX sample still renders through the existing pipeline | ABH-360 |
| CUJ-27 | Send a prompt → inline working indicator occupies transcript layout, then clears on complete | `smoke: ios-sim` UI smoke must send a prompt, observe `inlineWorkingIndicator` as the last transcript row above the composer (not a floating overlay strip), verify the row reads Working before first assistant output / Still thinking after visible output when no tool is active / tool name while a tool runs, and verify transcript prose never scrolls underneath it and the row disappears after completion | ABH-359 |
| CUJ-28 | Expand a tool row → Arguments + Result visible immediately, no toggle | `smoke: ios-sim` UI smoke must tap a `toolDetailDisclosure` row in the transcript, see the "Arguments" block (args JSON) and "Result" block render directly in the expanded panel with NO "Show technical detail" Toggle; long results scroll within a bounded maxHeight region (not a hard clip); a failed tool tints its "Result" label + body in `theme.statusError` (honest red, not a fake "ok"); a still-running tool with no result yet shows "Running…" | ABH-358 |
| CUJ-29 | Open Settings from the drawer header gear on cold launch and reopen it warm | `smoke: ios-sim` `tests/flows/regressions/settings-open.yaml` cold-launches, opens the drawer, taps `settingsAvatar`, asserts the Settings sheet marker (`settingsClose` + Gateway Status), closes it, then reopens it from the same warm drawer | ABH-375 |
| CUJ-30 | Switch away from a running turn and return → live state restored, not end-of-turn row | `smoke: ios-sim` LiveTurnReentryTests: with a turn RUNNING, switch to another session and back, then assert the composer shows Stop (not mic) and the transcript shows the working indicator — NOT the end-of-turn action row (copy/share/announce/repeat); the correct session's live server turn status wins on rapid switches; Stop clears and the action row appears only on real completion | ABH-371 |
| CUJ-31 | Warm session switch paints cached transcript instantly then reconciles to truth | `smoke: ios-sim` ChatStoreBatchBTests verifies a warm re-open paints the in-memory cached transcript before a slow fetch returns AND still reconciles when the fetch lands; memory-snapshot paint must never permanently serve stale rows by borrowing a fresh-disk skip proof | ABH-372 |
| CUJ-32 | iOS system log viewer: pick a file, filter by level, substring-search, view the tail | Settings → System Logs; `GET /api/logs?file=<>&level=<>&search=<>` returns `{file, lines:[...]}`; file picker (agent/errors/gateway/desktop), level filter (All/DEBUG/INFO/WARNING/ERROR), substring search; refresh on filter change; honest empty ("This log file is empty." / "No lines match the current filters.") / loading / error (unknown-file 400 surfaced as "Unknown log file") states; color-per-level semantics | ABH-368 |
| CUJ-33 | Sent image thumbnail renders across all ingress paths (app-native, cross-surface resume, mid-turn attach) | `smoke: ios-sim` `tests/flows/regressions/sent-image-thumbnail.yaml` attaches a photo, sends it, and asserts `sentImageThumbnail`; unit coverage pins the app-native immediate echo marker while existing persisted-marker parsing covers cross-surface/backfill rows | ABH-385 |
| CUJ-34 | Select composer text in both directions without opening the drawer; edge-swipe the drawer without the transcript scrolling | `smoke: ios-sim` DrawerGestureArbitrationTests verifies focused composer/text-selection drags do not latch the drawer, and a latched horizontal drawer pan disables transcript vertical scroll until touch end | ABH-380/381 |
| CUJ-36 | Composer @ context picker exposes full mobile context triggers | `smoke: ios-sim` MentionContextTriggerTests verifies bare `@` surfaces `@diff`, `@staged`, `@file:`, `@folder:`, `@url:`, `@git:` from `complete.path` and selection inserts the correct bare token or kind prefix without regressing legacy `@file:<path>` insertion | ABH-382 |
| CUJ-37 | Per-model presets: pick model A → set high effort, pick model B → switch back to A → effort is restored (not reset to default); changing effort/fast persists for that model | `smoke: ios-sim` ModelPresetTests verifies the UserDefaults-backed store round-trips effort+fast per `provider::model`, applies-on-select reads the stored preset for the newly-selected model, default fallback returns `.empty` for a model with no stored preset; UI smoke must open the session model popover, set high effort on model A, select model B, return to model A, and observe the effort picker reflects the remembered high value (not the gateway default medium) | ABH-383 |
| CUJ-38 | Share into Hermes from iOS → queued item is visible, drains on foreground or gateway reconnect, and successful delivery shows confirmation | `smoke: ios-sim` SharedInboxDrainerTests verifies onDrained count, pending-count derivation from SharedStore, `.connected` retry trigger, and overlapping scene/connect triggers do not double-deliver; UI smoke should share a URL while offline, see the drawer settings badge, reconnect the gateway, and observe the "Queued N shared item(s)" toast | ABH-267 |

`smoke: ios-sim` (covered by iOS test suite, skipped by gateway smoke): stale
'Connection lost' warning clears on clean resume (ABH-289 tests), per-event
push toggles gate local notifications (ABH-269), share-extension inbox drain
toast (ABH-277), cron delivery target picker truthfulness/legacy-selection
(ABH-265).

## Maintenance

- Refiner: when promoting a feature, note which CUJ it lands in (or that it
  adds one). Orchestrator: the engineer card for a user-facing feature includes
  "add/amend CUJ entry + smoke" in SCOPE.
- The soak beat reads this file every run; entries it cannot smoke (route gone,
  contract changed) are DO-NOT-SHIP evidence — the catalog IS the contract.
