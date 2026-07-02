Build 57 — "Malacca" — 2026-07-03
RELIABILITY

WHAT'S NEW
- Relay recovery status (ABH-285)
- Relay test push confirmation (ABH-284)
- Relay PAIR — on-device pairing flow + kind=relay parse (ABH-283)
- Relay push mode ENABLE — config route + iOS settings toggle (ABH-282)

FIXED
- Clear stale reconnect 'Connection lost' warning on clean resume (wave build-69) (ABH-289)
- Reconnect on request timeout
- Enforce approval session ownership

WORTH TRYING
- Try: Relay recovery status (ABH-285)
- Try: Relay test push confirmation (ABH-284)
- Try: Relay PAIR — on-device pairing flow + kind=relay parse (ABH-283)

---

Build 56 — "Malacca" — 2026-07-02
RELIABILITY

WHAT'S NEW
- Learning Journey iOS surface (read-first v1, learning.frames/detail) (ABH-246)
- View-only Nous credits/billing surface on iOS (ABH-237)
- Tag owner-typed inbound text with [owner reply] prefix
- Opt-in forwarding of owner-typed messages in bot mode
- Native WhatsApp media delivery via Baileys bridge
- Apply per-reasoning-model stale-timeout floor in stream + non-stream detectors
- In-app spot editor for the file preview pane
- MCP elicitation handler with gateway-aware approval routing
- Apply managed .env last with override
- Add risk-tiered application, Chesterton's Fence, slop + silent failure detection
- Replace shop-app with CLI-based shop skill (v1.0.1)
- Expand the full command inline from the approval bar
- Window translucency slider in Appearance settings
- Persist resolved approval/clarify prompts in scrollback
- Add WhatsApp Business Cloud API adapter

FIXED
- +278 reconnect reconcile-race — no dup bubble, no vanishing reply (ABH-276)
- Wire SharedInboxDrainer onDrained -> app toast (ABH-277)
- Re-running /codex-runtime codex_app_server when already enabled now triggers migration
- Honor approvals.mode/yolo for gateway-context approval routing
- Apply persist override to the DB row only, never the live list
- Close abbreviated-flag bypasses in git/sudo approval patterns
- Close bare powershell Remove-Item bypass + add ri alias (review)
- Detect Windows destructive shell commands
- Persist app-server turns to session DB (fixes starved recall)
- CREATE the flat session for in_channel (mirror only appends)
- Block subshell/brace-group wrappers at the hardline floor
- Collapse $IFS whitespace obfuscation before approval checks
- Stop _strategy_exact emitting overlapping matches
- Await async post-delivery callbacks in chained wrapper
- Append reference block at end of aggregator prompt for KV-cache reuse
- Detect encoding-based dangerous command bypass
- Flag remote content via command substitution
- Detect shell-expanded command names
- Treat # as comment boundary only when whitespace-preceded
- Accept both list and mapping shapes for group_topics config
- Scope run approvals by run id
- Honour tirith_fail_open in cron-deny tirith path + tests
- Run tirith check in cron-deny mode to catch content-level threats
- Catch GNU long-flag abbreviations for chown --recursive and git push --force
- Redact secrets in user-facing approval prompts
- Apply FTS5 sanitizer to search_facts sibling
- Resolve WhatsApp media-path cache roots per-call
- Deliver confirmation + reuse handlers for plain-text approvals
- Route plain-text approval responses instead of steering
- Clarify FIFO outbound-id tracker semantics
- Gate owner-typed forwards on customer chatId allowlist
- Thread-safe interactive approval via contextvars
- Harden heredoc approval, NFKC homograph fold, env-var filter
- Catch hermes gateway stop/restart behind a profile flag
- Keep composer preview links visible when a bg task appears
- Fail-closed feishu webhook rate limiter + whatsapp bridge path guard
- Include apps/shared in dashboard image build
- Warn and default to manual on unknown approvals.mode
- Require approval for host-bound Docker commands
- Force app exit after update/uninstall handoff on macOS
- Resolve LID aliases on modern platforms/ session layout
- Serialize sendMessage to prevent cross-chat contamination
- Apply bot auth policy to Telegram sources
- Honour tirith_fail_open=false on Tirith ImportError
- Resolve phone↔LID aliases in adapter DM/group allowlist
- WhatsApp/Signal hints affirm markdown instead of forbidding it
- Remove process-global HERMES_SESSION_KEY write that misroutes approval prompts across concurrent sessions
- Extend gateway-lifecycle guard to launchctl and pidof-based kills
- Resolve reply-to text so the agent sees reply context
- Fold Windows absolute home paths in dangerous-command detection
- Validate context/memory tool schemas before wrapping
- Skip drift guard for add (append-only) action
- Transcribe in-app voice messages (audio/mp4) instead of failing
- Redact credentials from TUI approval prompts
- Apply /memory approve against a fresh store when no live agent
- Move composer out of contain wrapper instead of portaling
- Set AppUserModelID on Windows so notifications fire
- Redact credentials from approval prompts before sending to clients (#48456)
- Add missing re import + fix test import path after adapter relocation
- Only kill LISTENers when freeing the bridge port, never clients
- Validate bridge PID identity before killing stale pidfile entry
- Relaunch on Linux after in-app update instead of hanging
- Show desktop approval fallback
- Harden smart approval guard against prompt injection
- Seed app-server sessions with configured cwd
- Honor interrupt in blocking gateway approval wait
- Respawn unmapped Windows gateways after update (#50090)
- Normalize bare phone targets to JIDs before bridge send
- Stop in-app update from cascading into a backend restart loop
- Bridge app-server item/started events to Telegram tool-progress
- Audit WhatsApp bridge at its resolved (HERMES_HOME) dir
- Resolve bridge dir with HERMES_HOME mirror in Docker
- Prefer managed node for whatsapp and desktop
- Apply managed layer in cli.py's standalone config loader
- Serve /api/cron/fire on the dashboard app (hosted-agent surface)
- Honor glob command allowlist entries
- Retry the self-update rebuild once so the app relaunches
- Accept `metadata` kwarg in WhatsApp/email send_image
- Harden WhatsApp target alias salvage
- Route WhatsApp group JIDs to the target, not the home DM
- Apply global|platform disabled union to all resolution sites
- Surface off-screen approvals via the jump-to-bottom control
- Gate in-place edits to sensitive user files
- Detect absolute home shell rc writes
- Always append END OF CONTEXT SUMMARY marker to standalone summaries regardless of role
- Natively compile and correctly stage node-pty for desktop app
- Wrap long approval commands in the Ink overlay
- Keep plugin action wrapper signature to (ack, body, action)
- Carry allow_permanent to TUI + desktop approval prompts
- Utf-8 decode for whatsapp-bridge npm install capture (sibling of #43790)
- Review follow-ups for #43921
- Restart stale bridge processes instead of silently reusing them

IMPROVED
- Strip VERTEX_CREDENTIALS_PATH/GOOGLE_APPLICATION_CREDENTIALS from subprocess env
- Tidy reapply-migration control flow
- Extract is_approval_bypass_active(); use frozen-env bypass in codex routing
- Cover Slack App-Level (xapp-) token redaction
- Redact Slack App-Level (xapp-) tokens
- Apply run_job patches via ExitStack, not a positional list
- Repoint owner test import after adapter relocation
- Fix list_profiles O(N*M) wrapper rescan (6.4s -> 0.4s)
- Apply workspace formatter to websocket helpers
- Add PR infographic for approval mode validation
- Add infographic for #36664 WhatsApp LID session-path fix
- Cover LID allowlist match on modern session layout
- Whatsapp send-queue serialization
- Drop structural send-queue integration test
- Fix port-spares-client test race (listen before announce + retry connect)
- Regression for interrupt-unblocks-approval; AUTHOR_MAP
- Align contributor test checklist with wrapper
- Make profile-wrapper alias test OS-aware
- Cover read-only bridge dir mirror; add author map
- Migrate slack/dingtalk/whatsapp/matrix/feishu/telegram/wecom/email/sms adapters to bundled plugins
- Correct STT-fallback comment, type the markdown wrapper, make AAC test portable
- Cover two overlapping user-defined custom providers
- Regenerate shop skill page after shop-app rename
- Cover gateway identity mapping for Honcho
- Align web profile wrapper expectation
- Cover the inline command expander on the approval bar
- 🐛 fix(cli): wrap approval preview hints
- 🐛 fix(cli): wrap long approval commands in prompt
- Merge pull request #44534 from NousResearch/bb/approval-allow-permanent
- Cover gateway identity mapping in Honcho feature page
- Merge commit '6110aed9b' into feat/whatsapp-cloud-api
- Canonicalize identity-mapping on pinUserPeer, migrate legacy key

WORTH TRYING
- Try: Learning Journey iOS surface (read-first v1, learning.frames/detail) (ABH-246)
- Try: View-only Nous credits/billing surface on iOS (ABH-237)
- Try: Tag owner-typed inbound text with [owner reply] prefix

(+2567 server-side/infra changes active on the gateway, no app UI change)

---

# Hermes Mobile — Release Notes

Build 55 — 2026-07-02

WHAT'S NEW
- Manual Compress context action (iOS) (ABH-222)
- Mobile approval-bypass (YOLO/flow-state) toggle (iOS) (ABH-227)
- Server — plugin toolset-config routes (GET/PUT /toolsets/{name}/config) (ABH-224)

FIXED
- Require approve scope on /devices/issue and DELETE /devices/{id} (ABH-275)
- Gate local notifications on per-event push toggles (ABH-269)
- Server-side unregister device token when notifications disabled (ABH-270)
- Surface cron delivery failures
- Route widget approvals to inbox
- Pass api_mode so anthropic key validation sends x-api-key (ABH-259)
- Require approve scope on GET /toolsets/{name}/config (ABH-261)
- Require approve scope on GET /devices (ABH-263)
- Surface rejected provider-key validation_detail on iOS entry sheet (ABH-234)
- Render delete icons in theme.destructive red across cron/chat/drawer (ABH-235)
- Bound session→device correlation index (no per-session leak) (ABH-252)
- Audit websocket approval responses
- Run provider-key validation off the event loop (asyncio.to_thread) (ABH-245)
- Hide unprovisionable openrouter/custom provider skeletons (ABH-233)
- Fix mobile provider key disconnect validation

IMPROVED
- Fire iOS output-context hook via plugin-owned session->device correlation (ABH-221)

WORTH TRYING
- Try: Manual Compress context action (iOS) (ABH-222)
- Try: Mobile approval-bypass (YOLO/flow-state) toggle (iOS) (ABH-227)
- Try: Server — plugin toolset-config routes (GET/PUT /toolsets/{name}/config) (ABH-224)

(+4 server-side/infra changes active on the gateway, no app UI change)

