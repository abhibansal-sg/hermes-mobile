---
name: Agent prompting — concrete imperatives beat collaborative asks
description: Paperclip Hermes/Kai bots execute mutations only when given exact API payloads + time deadlines. Collaborative "please do X" phrasing produces ack-theater.
type: feedback
originSessionId: 247467c5-73b8-4f37-81f3-a0f202fdaeca
---
Paperclip Telegram agents (hermHAL_bot, kaiHAL_bot) have real tool access to the paperclip REST API (they can PATCH issues, advance stages, etc.), but they do NOT execute when prompted with soft/collaborative phrasing. They respond with multi-paragraph acknowledgments confirming they understand the ask, without running the actual mutation.

**What worked (2026-04-20, GIT-1066 reassignment):**
Exact payload + time deadline + call out the ack-theater:
```
Run these 4 PATCH operations. Paste confirmation here when done.
PATCH /api/issues/<uuid> { assigneeAgentId: "<uuid>" }   # GIT-NNNN → Impl
...
Deadline: 20:29 SGT. 6 minutes from now. I'm watching the logs.
```
Kai executed all 4 PATCHes within 60 seconds.

**What failed (same session, same asks):**
- "Please direct CTO to start GIT-1066..." → "Acknowledged, standard confirmed" (no PATCH)
- "Unstick GIT-1063, reassign masters..." → "That is the correct escalation, agreed" (no PATCH)

**Why:** soft phrasing reads as "discuss this" not "do this." Agents default to the conversational path because it matches the framing.

**How to apply:**
- For any paperclip mutation you want an agent to execute, include the literal HTTP method + path + JSON body. Don't describe it, spell it out.
- Add a time-bound deadline and say you'll verify via logs.
- If the first response is analytical rather than operational, explicitly name it ("acknowledgment is not execution, paste the PATCH confirmation").
- Verify by grepping `pm2 logs paperclip` for `PATCH /issues/<uuid>` with 2xx status before believing the agent's claim.

**What NOT to conclude:** don't diagnose "text-only bot, no tool binding" too quickly — that was a false read during this session before the imperative-payload ask landed.
