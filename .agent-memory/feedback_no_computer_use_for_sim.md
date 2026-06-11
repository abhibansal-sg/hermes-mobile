---
name: no-computer-use-for-sim
description: "Hermes Mobile work: agents must NEVER use the computer-use MCP for the simulator/app — use xcrun simctl + the DebugBridge instead. computer-use triggers approval prompts the user does not want."
metadata: 
  node_type: memory
  type: feedback
  originSessionId: c6271256-6b41-4b30-a2e2-057a9325db34
---

User (2026-06-08): keeps getting computer-use approve/deny prompts despite the "dangerously bypass" setting being on, and wants them to stop.

**Why bypass doesn't cover it:** "dangerously bypass" skips tool/Bash permission prompts; computer-use (screen control: mouse/keyboard/screenshots of the REAL desktop) is a SEPARATE, stronger consent gate (macOS + harness) that is intentionally NOT bypassed. I cannot/should not flip it.

**The fix — eliminate the need, don't bypass the gate:** all Hermes Mobile simulator/app verification MUST use:
- Screenshots: `xcrun simctl io <sim-udid> screenshot <path.png>` (then Read the PNG).
- Interaction (tap/swipe/type/keyboard): the in-app DebugBridge on loopback port 9999 (boot token at `<sim data container>/tmp/gstack-ios-qa.token` → POST /auth/rotate → /session/acquire → /tap,/swipe,/type). The bridge is DEBUG-only and already wired.
- App lifecycle: `xcrun simctl install/launch/terminate`, deep links via `xcrun simctl openurl`.
NEVER use `mcp__computer-use__*` for the sim — it is never required and it pops the consent prompt.

**How to apply:** put an explicit prohibition in EVERY spawned agent/workflow house-rules block: "Do NOT use the computer-use MCP; screenshot via `xcrun simctl io ... screenshot`, interact via the DebugBridge (port 9999). If those cannot do it, report the limitation — do NOT fall back to computer-use." (A subagent once fell back to computer-use for a panels spot-check when the bridge path was inconvenient — that is the behavior to forbid.) If the user ever DOES see a computer-use prompt mid-run, they can safely DENY it; the agent should then use the simctl/bridge path.
