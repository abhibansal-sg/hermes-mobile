---
name: project_astrology_brain_ingest
description: Astrology-brain book-ingestion project — building the generalized ingest-book tool and clearing the ~29-book queue into gbrain
metadata: 
  node_type: memory
  type: project
  originSessionId: 33c00415-4eb4-42f7-920a-45e69cde0cf4
---

Building a generalized **`ingest-book`** tool (standalone gstack skill at `~/.claude/skills/ingest-book/`, OUTSIDE the read-only `~/gbrain` repo) that ingests a book in any format/language into the gbrain knowledge brain via a verified 6-phase pipeline with a hard `PROOF_PASS` reconciliation gate before federation.

**Authoritative docs (both at `$HOME`, NOT in the repo):** `~/ASTROLOGY_BRAIN_HANDOFF.md` (context + 8 snags) and `~/INGEST_BOOK_SPEC.md` (v0.2 design spec, grounded in verified on-disk contract).

**Locked decisions (2026-05-31):** standalone gstack skill · full tool first · local OCR (Surya for Devanagari, ~3-5GB model) · Tesseract-eng enabled now (proven) · first e2e test = BPHS Vol 1 (482p, native).

**Key facts:** gbrain CLI `~/.bun/bin/gbrain` v0.40.8.0 · PyMuPDF 1.26.5 ONLY via `/usr/bin/python3` · Voyage+OpenAI keys in `~/.gbrain/env` (0600), inject via `set -a; source ~/.gbrain/env; set +a` (snag #3) · doc layer `~/Library/Mobile Documents/com~apple~CloudDocs/Downloads/astro_downloads/_gbrain_document_layer` (iCloud, gets evicted) · 3 books already federated (carmen 149, brihat-samhita 333, vettius-valens 708) · `default` source (493p email/newsletter) causes query-scope snag #7 (deferred).

**Verified contract:** Valens `reconciliation.json` = 18 fields w/ top-level `PROOF_PASS`; `table_assets.json` = index → per-table grid files; one `figure_assets.json` for embedded figs + full-page 2x renders; classify thresholds from carmen `phase1_qa.py`.

**Bucket A native, not yet ingested (clear first, no OCR):** BPHS Vol 1 482p, Mantreswara Phaladeepika 265p, Clavis/Key 600p, Laghu Parashari OPVerma 187p, Great Introduction/Abu Maʿshar 1435p, Brihat Jataka 115p. **Bucket B (Devanagari scans, OCR-blocked):** ~15 incl. BPHS Devanagari 800p, Saravali, Tajika Nilakanthi, Jataka Parijata I/II.

Relates to [[project_openclaw_stack]], [[feedback_api_key_scoping]].
