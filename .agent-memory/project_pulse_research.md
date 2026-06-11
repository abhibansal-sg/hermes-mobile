---
name: Pulse Research Notes
description: Complete research for Pulse (codename for Mission Control redesign). 11 rounds of Kai discussion, schemas, scoring, pipeline, failure analysis, MVP definition. 2026-04-13.
type: project
originSessionId: 247467c5-73b8-4f37-81f3-a0f202fdaeca
---
## Codename: Pulse
Abhi's personal action substrate. GBrain = knowledge, Pulse = actions.

## Design Principle #1
"The machine has not earned the right to summarize reality yet." — Kai

## Current Mission Control State

### Data volumes (prod DB):
- actions: 505, people: 13, source_links: 629, timeline_events: 1158
- action_dependencies: 0 (unused), action_comments: 1 (unused), projects: 6

### Scoring (9 components):
priority(35) + overdue(40) + due_soon(20) + delegation(18) + relationship(12) + monetary(12) + staleness(12) + source_heat(11) - blocking(-20)

### WhatsApp Pulse pipeline:
wacli.db → bash normalize → Gemma 26B classify → state-add.sh → POST /api/actions

### Tech: Next.js + SQLite + PM2

## Why MC Failed (from Kai, brutally honest)
1. Dashboard showed wrong data — not just stale, factually inaccurate
2. Pulse detected actionable items but failed to write them (Byron case)
3. No mandatory write discipline — detection without commit is system failure
4. No deterministic doctor/lint — failures discovered by Abhi, not the machine
5. Schema drift between docs and live DB
6. Redesign stalled because substrate trust was shaky — "decorating a machine that dropped bolts"

## 5 Disciplines (GBrain vs MC gap)
1. Detect→decide→write must be ATOMIC (MC allowed detect without write)
2. Lookup-before-create mandatory (MC created duplicates/flat items)
3. Freshness must be visible (MC: 60s recompute but not inspectable)
4. Doctor must be code-driven, hard-failing (MC has fragments, not contract)
5. Nightly reconciliation must repair integrity (MC Night Build = improvements, not semantic repair)

## Abhi's Operating Patterns (ADHD-relevant)
- Continuous capture, batched presentation (don't interrupt, accumulate quietly)
- High bar for interruption (only hard deadlines, important people, risk)
- "What should I do now?" = short, specific, singular, with WHY and source
- Delegation: delegate→move on→machine brings back what matters
- Push > pull (Telegram for alerts, WhatsApp for ops, dashboards secondary)
- Overnight gap: morning queue must be pre-reconciled, not raw

## GBrain-Pulse Boundary
- Pulse decides what Abhi should DO
- GBrain explains who/what that thing is ABOUT
- Pulse owns: actions, scoring, queuing, provenance, operational person refs
- GBrain owns: dossiers, compiled truth, timelines, entity resolution
- Shared: source event IDs. Separate: domain-specific linkage tables
- Scoring caches relationship_importance from GBrain (not deep reads per query)
- Query path: Pulse ranks → selects top items → fetches GBrain context for explanation

## MVP Definition
- pulse init / pulse ingest whatsapp / pulse now
- SQLite, TypeScript/Bun, CLI + MCP
- ONE source: WhatsApp
- ONE query: "What should I do now?" (top 1-3 items + reason + source)
- Import 505 existing actions as legacy seed (marked as legacy provenance)
- Day-1 promise: every actionable WA message either creates an action or is explicitly ignored with reason

## Anti-Patterns / Kill List
- Silent ingestion failure = instant death
- Split-brain architecture (multiple truth stores) = mess
- Premature productization (UI before substrate trust) = MC repeat
- Don't build: dashboard, multi-channel, rich UI, GBrain writeback, agent chat, plan generation, Paperclip integration — all v2+
- Show to Abhi only when "boringly correct" for several consecutive days

## Paperclip: build Pulse standalone first, Paperclip becomes optional client later
## Mia: OpenClaw agent querying Pulse (MCP) + GBrain, not trapped inside Paperclip

## Hardest engineering problem:
Deterministic action extraction from messy real communication — new vs update vs delegation vs noise vs same-thread-new-commitment. The lookup-and-write decision is the knife edge.

## Reference architecture:
- GBrain (garrytan/gbrain) — knowledge substrate
- Pith (SiluPanda/pith) — task substrate (MCP-first, Postgres, TypeScript)
