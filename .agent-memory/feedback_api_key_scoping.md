---
name: API Key Scoping Discipline
description: NEVER put API keys in LaunchAgent plist — they leak to entire gateway. Scope keys to specific subprocesses only.
type: feedback
originSessionId: 247467c5-73b8-4f37-81f3-a0f202fdaeca
---
NEVER put OPENAI_API_KEY or ANTHROPIC_API_KEY in the OpenClaw LaunchAgent plist (~/Library/LaunchAgents/ai.openclaw.gateway.plist).

**Why:** On 2026-04-12, API keys placed in the plist leaked to the entire OpenClaw gateway. Every component (heartbeats, Mia, LCM summarization, active memory) consumed the key instead of using OAuth. This burned $16+ in one day and exhausted the quota, silently breaking GBrain vector search.

**How to apply:** When a tool needs an API key (like GBrain needing OPENAI_API_KEY for embeddings):
1. For CLI usage: export in ~/.zshrc (shell env doesn't leak to launchd services)
2. For MCP subprocess under gateway: use the `env` block in openclaw.json MCP server config to scope the key to that specific subprocess only
3. For the gateway itself: NEVER. Gateway agents use OAuth via openai-codex provider.
4. Also check: does the tool actually read from config files, or only from process.env? GBrain has a bug where config values are stored but never applied.
