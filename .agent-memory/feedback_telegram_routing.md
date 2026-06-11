---
name: Telegram routing discipline
description: NEVER use Kai's Telegram sessions. Only use oppusy account sessions for sending messages.
type: feedback
originSessionId: 247467c5-73b8-4f37-81f3-a0f202fdaeca
---
@Oppusy_bot is dedicated to Claude Code channel only. NEVER send messages through Kai's sessions.

**Why:** Abhi explicitly instructed that oppusy is for Claude Code only, not linked to Kai or main agent. Sending through wrong session causes messages to appear from the wrong bot.

**How to apply:**
- ONLY send on session keys containing `oppusy` (e.g., `agent:main:telegram:oppusy:direct:8593114994`)
- NEVER send on `agent:main:telegram:direct:*` or `agent:main:telegram:group:*` — those are Kai's
- If a message arrives on a non-oppusy session, do NOT respond to it — it's for Kai
- Group replies currently can't go through oppusy (OpenClaw limitation — one session per group). Reply via oppusy DM instead.
