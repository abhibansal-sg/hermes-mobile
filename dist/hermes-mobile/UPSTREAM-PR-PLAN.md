# Upstream seam PRs → NousResearch/hermes-agent (plan, internal)

Fork: **ab0991-oss/hermes-agent** (created). Base: rebase each branch onto fresh
`upstream/main` (currently `36ae95847`) — the seams.patch targets an older index,
so hunks must be RE-PLACED per PR (small, localized; 3-way usually resolves).

## Hard constraints (from researching their CONTRIBUTING / AGENTS.md / merged PRs)
- **Conventional Commits**, imperative, lowercase, no trailing period. Commits land
  verbatim (rebase/cherry-pick, not squash) — keep each clean.
- **One logical change per PR.** Never mix fix + feature + refactor. S5 must get
  isolated security review — never bundle it.
- **No DCO/CLA**, no `Signed-off-by`. BUT `contributor-check.yml` is a CI gate:
  the commit-author email must be in `scripts/release.py` AUTHOR_MAP. → PR1 adds
  `"ab0991-oss@users.noreply.github.com": "ab0991-oss"` (author commits with that
  email).
- Run **`scripts/run_tests.sh`** (CI parity, not bare pytest) + add tests +
  **`scripts/check-windows-footguns.py`**. New deps need `<next_major` bound + `uv lock`.
- **Out-of-tree consumer is the #1 decline risk.** AGENTS.md: "no speculative
  hooks/extension points without a concrete consumer." Frame each hook PR as the
  CAPABILITY (not "add hook"), name the consumer (github.com/ab0991-oss/hermes-ios),
  cite the merged `feat(hooks): session:compress event_callback for MemPalace sync`
  precedent, and make "empty registry == byte-identical stock" a first-class TEST.
- **Issue-first** for the hook/auth PRs (PR1, PR5, PR6) — a one-paragraph "would you
  accept an empty-by-default observer seam in write_json/_emit for an out-of-tree
  broadcast plugin?" de-risks the series. Bug-fix PRs go straight to PR.

## The series (merge order; lead with stand-alone bug fixes)
1. **PR-A `fix(gateway): scope /fast and /reasoning to the session`** (S4). Stand-alone
   config-correctness fix (extends upstream's own model_override). Direct PR. Safest.
2. **PR-B `fix(gateway): session.delete evicts a live session instead of 4023`** (S6).
   Stand-alone behavior fix. Direct PR.
3. **PR-C `feat(gateway): role-scoped session search`** (search-scope toggle). Trivial
   additive, default identical. Direct PR.
4. **PR-D (bonus) `fix(gateway): persist the user prompt on an interrupted turn`** —
   the prompt.submit DB-resync fix embedded in the patch (replace_messages +
   `_last_flushed_db_idx` resync). Stand-alone bug fix; NOT a numbered seam. Direct PR.
5. **PR-E `feat(gateway): event/transport/lifecycle observer seams for multi-client
   mirroring`** (S1+S2+S3). Issue-first, then PR. Carries the AUTHOR_MAP entry.
6. **PR-F `feat(dashboard): pluggable accept-only machine-token auth seam`** (S5 part 1:
   token_auth.py + middleware/routes/ws_tickets + the `_has_*` OR-branches). Issue-first.
   Security surface — every branch runs AFTER the shared-token compare; empty registry
   = byte-identical; `match_token` never raises.
7. **PR-G `feat(dashboard): cut revoked device sockets live + audit approval
   resolutions`** (S5 part 2: WS revoke-cut + `tools/approval.py` audit). Depends on PR-F.

## Must EXCLUDE from every upstream PR
- The `_git_branch_fast` non-blocking branch read in session.create — it imports from
  the mobile plugin (hard plugin path). Mobile-perf only; keep in the installer patch.

## PR body template (their PR template — fill every section)
`## What does this PR do?` (root cause / why) · `## Related Issue` · `## Type of Change`
· `## Changes Made` (per-file) · `## How to Test` (numbered, copy-pasteable) ·
`## Checklist`. Lead with root cause; paste exact test counts + a live roundtrip.

Full per-PR draft bodies: workflow output `seam-pr-design` (run wf_cb6642e5-25a).
