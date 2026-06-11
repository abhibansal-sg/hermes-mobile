---
name: OpenClaw Stack State
description: Full memory/GBrain/proxy stack state after QA audit April 14 2026. Config changes, module health, known issues.
type: project
originSessionId: 247467c5-73b8-4f37-81f3-a0f202fdaeca
---
## Current Stack (as of 2026-04-14)

**OpenClaw:** v2026.4.12

### Memory Layers
- **LCM / lossless-claw 0.8.0** — Configured: contextThreshold 0.75, incrementalMaxDepth 1, condensedMinFanout 3, summaryModel gpt-5.4-mini via openai-codex, pruneHeartbeatOk true, freshTailCount 64
- **memory-core** — Plugin active, builtin SQLite, Gemini embedding-2-preview at 3072 dims, 89 files, 787 chunks
- **Active memory** — Model: openai-codex/gpt-5.4-mini (explicit), queryMode recent, promptStyle contextual, persistTranscripts true
- **Dreaming** — Enabled but BROKEN: 521 recall entries, 0 promoted. Gateway not exposing cron service dependency. uniqueQueries never populated.
- **memory-wiki** — REMOVED (replaced by GBrain)
- **Honcho** — REMOVED completely

### GBrain
- v0.9.0, PGLite backend
- 48 pages, 100% embedded (fixed 2026-04-14)
- MCP server added to OpenClaw (`gbrain serve`, stdio, with scoped env keys)
- Kai has full tool access (query, search, get/put, tags, timeline, backlinks)
- Graph unwired: 47 orphan pages, 0 links, 0 tags, 0 timeline entries
- Behavioral integration (skillpack patterns) still pending
- GBrain integrations NOT set up: credential gateway, email, calendar, meeting-sync, voice
- **Embedding model**: text-embedding-3-large at 1536 dims (hardcoded)
- **Expansion model**: claude-haiku-4-5-20251001 (hardcoded, not configurable)
- Vector search + expansion WORKING as of 2026-04-14 (keys funded)

### API Key Scoping (CRITICAL — fixed 2026-04-14)
- **LaunchAgent plist**: NO API keys (OPENAI/ANTHROPIC removed). Gateway is clean.
- **~/.zshrc**: OPENAI_API_KEY + ANTHROPIC_API_KEY exported (for CLI gbrain usage)
- **openclaw.json MCP env**: Both keys scoped to `gbrain serve` subprocess only
- **~/.gbrain/config.json**: Both keys stored (dead — GBrain bug, config not injected to process.env)
- **Why**: Previously keys leaked to entire gateway; heartbeats/Mia/LCM burned $16+ in one day on OpenAI API
- **Rule**: NEVER put OPENAI_API_KEY or ANTHROPIC_API_KEY in the LaunchAgent plist

### Config State
- embeddedHarness: runtime "auto", fallback "none"
- embeddedPi: executionContract "strict-agentic"
- Context window: 256k (openai-codex provider)
- Billing proxy: v2.2.3

### Known Issues
- **Codex harness**: Plugin loads but harness never registers with gateway. Fallback must stay "pi".
- **Active memory latency**: 7-13s via ChatGPT OAuth. Variable by time of day. Not configurable.
- **Active memory debug line**: Generated but /status doesn't render second pluginDebugEntries line.
- **Promotion gap**: Important in-session synthesis stays in LCM raw history, not promoted to durable memory fast enough. Active memory can only search durable memory, not LCM.
- **Mia**: Workspace exists on disk, heartbeat disabled, agent ABSENT at runtime. Intentionally inactive, not broken.
- **Crontab leak**: gbrain check-update cron entry has OPENAI_API_KEY hardcoded inline. Needs cleanup.
- **Telegram DM session**: 4923k/1000k — needs /new reset.
- **GBrain keyword AND logic**: PATCHED LOCALLY — OR fallback when strict returns 0. Needs PR to garrytan/gbrain.
- **GBrain config dead fields**: PATCHED LOCALLY — config keys injected to process.env in loadConfig(). Needs PR to garrytan/gbrain.
- **GBrain silent vector failure**: PATCHED LOCALLY — console.warn on fallback. Needs PR to garrytan/gbrain.
- **Dreaming promotion broken**: 521 recall entries, 0 promoted, 0 uniqueQueries tracked. Promotion pipeline not functioning.
- **LCM summaryModel override**: Runtime still shows gpt-5.4 despite config set to gpt-5.4-mini. Plugin bug.

### Triage (agreed with Kai + Hermes, 2026-04-14)
**Fix now:** Clean crontab API key leak, keep active-memory direct-only, Mia stays inactive
**File bug (OpenClaw):** Dreaming cron service unavailable, dreaming promotion dead, LCM summaryModel override ignored
**Accept as constraint:** Active memory 7-13s latency (OAuth path)

### GBrain PR Status
- 3 local patches (A: keyword OR fallback, B: config-to-env, C: silent failure warnings)
- All 3 approved by Hermes. Test skeletons drafted. Stop words trimmed, comments tightened.
- Blocked on: GitHub re-auth (gh auth login -h github.com), then fork + rebase onto master + add tests
- All code ready, zero-thinking package prepared for Abhi

### Operational Artifacts Created (2026-04-14)
- ~/.openclaw/workspace/AGENT-FINDINGS.md — cross-agent discovery surface
- ~/.openclaw/workspace/GBRAIN-RECONCILE.md — structured GBrain update queue
- ~/.openclaw/workspace/CEO-EXECUTION-MEMO.md — week 1 priorities
- AGENTS.md operating discipline block (10 rules) — ready to paste
- COO weekly checklist — Mon-Fri concrete actions
- High-stakes answer mode protocol for Kai
- 12-page GBrain link map + link-builder script spec
- Reconciliation agent architecture + cron prompt

### Mission Control (URGENT)
- Dev backup age: 322 hours (13+ days) — CRITICAL
- Prod backups: MISSING
- entity_links: 0
- State store is real but under-consumed by Kai for "what should I do now"

### Architecture Decisions
- GBrain = world knowledge (people, companies, concepts)
- memory-core = operational memory (preferences, decisions)
- LCM = conversation recall (raw history + summaries)
- Dreaming = consolidation (recall → promotion to durable memory)
- Active memory = pre-reply injection from durable memory only
