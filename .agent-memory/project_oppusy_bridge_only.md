---
name: Oppusy Bridge-Only Config
description: @Oppusy_bot runs via isolated OpenClaw profile (port 18790) as a true bridge-only channel into Claude Code. Reached via --dangerously-load-development-channels server:openclaw-oppusy + session.sendPolicy deny.
type: project
originSessionId: 247467c5-73b8-4f37-81f3-a0f202fdaeca
---
@Oppusy_bot (Telegram) is bridged into Claude Code via an isolated OpenClaw gateway profile `oppusy` on port 18790, separate from main gateway (18789 — Kai/mia). Decided 2026-04-19.

**Why:** Previous attempts (April 13-15) added oppusy to the main gateway and caused cross-connection drift between bots. Full isolation via `--profile oppusy` solved that.

**How to apply:**

Config at `~/.openclaw-oppusy/openclaw.json` — key fields for bridge-only behavior:
- `agents.defaults.model: "openai-codex/gpt-5.4"` (uses user's ChatGPT Pro OAuth, no metered cost — required so embedded agent resolves; without this it fell back to unauth'd `openai/gpt-5.4`)
- `session.sendPolicy.rules: [{ action: "deny", match: { channel: "telegram" } }]` — blocks embedded agent Telegram outbound only. MCP bridge `messages_send` still works (different code path).
- `channels.telegram.accounts.oppusy.errorPolicy: "silent"` — suppresses error-text leaks.
- **`bindings[]` entry REQUIRED for non-"default" accounts to receive GROUP messages.** Schema: `{type:"route", agentId:"main", match:{channel:"telegram", accountId:"oppusy"}}`. Without this, OpenClaw 2026.4.14 silently drops group inbound at bot-BwMz6R6-.js:3763 with `requiresExplicitAccountBinding` — DMs still work (check only fires when `isGroup=true`). Discovered 2026-04-19 via source instrumentation after hours of chasing requireMention red herrings.

MCP bridge registered in `~/.claude.json` (NOT `~/.claude/settings.json`) at both root `mcpServers` and project `/Users/abbhinnav` level:
```
openclaw-oppusy: openclaw --profile oppusy mcp serve --claude-channel-mode on --token-file ~/.openclaw-oppusy/gateway.token --url ws://localhost:18790/
```

Claude Code launch flag REQUIRED (no persistent user-level setting for dev channels):
```
claude --dangerously-load-development-channels server:openclaw-oppusy
```
Format is `server:<mcp-name>` for bare MCP servers (or `plugin:<name>@<marketplace>` for plugins). Bare name fails with "entries must be tagged" error. Docs: https://code.claude.com/docs/en/channels-reference#test-during-the-research-preview

LaunchAgent: `~/Library/LaunchAgents/ai.openclaw.gateway.oppusy.plist` with `OPENCLAW_GATEWAY_TOKEN` env var.

Gateway restarts drop the bridge push subscription. If inbound stops after a config change, relaunch Claude Code with the flag.

There is NO documented `autoReply: false` or `mode: "bridge"` for Telegram in OpenClaw 2026.4.14. The sendPolicy + errorPolicy combo is the official workaround per OpenClaw docs bot.
