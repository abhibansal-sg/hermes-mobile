---
name: GStack Skill Adapter Split
description: GStack skills only work on claude_local adapter. Codex agents produce evidence, Release Engineer (Claude) runs actual skill gates.
type: project
originSessionId: 247467c5-73b8-4f37-81f3-a0f202fdaeca
---
GStack skills (/review, /qa, /qa-only, /ship, /investigate) only work with the claude_local adapter (Claude Code). They cannot run on codex_local or hermes_local.

**Why:** GStack skills are Claude Code slash commands. Codex CLI has no equivalent plugin system. Decided 2026-04-16 after discovering Staff + QA Engineers (codex_local) were told to invoke skills they physically couldn't run — explaining the 0.1a evidence gap.

**How to apply:**
- Staff Engineer (codex_local, gpt-5.3-codex): builds code, produces structured evidence (files changed, test results, lint output). Does NOT run /review.
- QA Engineer (codex_local, gpt-5.3-codex): validates, produces QA report with pass/fail verdict. Does NOT run /qa-only.
- Release Engineer (claude_local, claude-sonnet-4-6): runs all GStack skill gates (/review, /ship, /document-release). This is the GStack compliance surface.
- Strategy B was initially chosen (Codex builds, Claude gates), but then gstack was installed for Codex via `./setup --host codex` (2026-04-16).
- 36 gstack skills now at ~/.codex/skills/gstack-*. Skills are prefixed: /gstack-review, /gstack-qa, /gstack-ship etc.
- Pending: smoke test to verify Codex agents can actually invoke gstack skills before restoring skill requirements in AGENTS.md.
