---
name: codex_local adapter stall + recovery
description: Paperclip codex_local adapter hangs after process fork / first tool call. Recovery = reset-session + kill PID. Platform's stranded-issue reconciliation is the safety net.
type: feedback
originSessionId: 247467c5-73b8-4f37-81f3-a0f202fdaeca
---
Paperclip's `codex_local` adapter (used by the Impl agent `79137c46-81ca-4126-b2c7-3ac0bf0127d0`) has a recurring stall pattern: the scheduler launches a real Codex process, Codex starts inspecting the repo (issue 1 lifecycle event + 1 adapter.invoke event in heartbeat-runs log), then hangs mid-session without emitting further events. Issue remains `in_progress` with a live `executionRunId` but no artifacts are produced.

**Recovery sequence (proven 2026-04-20, GIT-1066):**
```
1. POST /api/agents/<agent-id>/runtime-state/reset-session  → 200
2. kill <stuck PID>   (the processPid from GET /api/heartbeat-runs/<run-id>)
3. wait for next heartbeat tick (~2.5min)
```
The killed run finalizes as `succeeded` shortly after kill, paperclip's `periodic stranded-issue reconciliation` fires `continuationRequeued:1` on the next tick, and a fresh executionRunId starts on the same issue.

**Detection signals:**
- Issue stuck `in_progress` for >5min with no commits / no branches / no comments
- `GET /api/heartbeat-runs/<run-id>/events` returns only 2 events (`lifecycle run started` + `adapter.invoke`)
- `runtime-state.lastRunStatus=succeeded` is stale (from a previous run), not the current one

**Platform safety net:**
Paperclip has `periodic stranded-issue reconciliation` that auto-requeues stranded runs — but on its own cadence (not observed precisely; hermes triggered it faster via manual reset). Watch log line: `periodic stranded-issue reconciliation changed assigned issue state {"continuationRequeued":N,"issueIds":[...]}`.

**Why:** adapter's persistent session doesn't survive idle gaps well, or Codex's embedded session isn't emitting lifecycle events back to the harness after a tool call that takes too long.

**How to apply:**
- When Impl checkout shows no artifacts after 7+ min, don't wait — ask Hermes/Kai to run the reset-session + kill sequence.
- File this as infra debt against GIT-1068 (OSS release prep); shipping paperclip publicly with this stall mode unfixed is a known-issue.
- Don't confuse this with claude_local adapter (which had its own prior issues like the CEO timeout fix 2026-04-17).
