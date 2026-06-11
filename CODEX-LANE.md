# CODEX-LANE — dual-executor architecture [RETIRED 2026-06-07]

> **RETIRED by user ruling 2026-06-07 (full takeover):** Claude owns both
> lanes — backend and frontend. Codex is not dispatched work in this repo.
> Kept for history and the brief template only.

Division of labor for this repo. Two implementation lanes, one owner.

## Lane split (unconditional)

- **Codex lane — ALL backend:** everything in `tui_gateway/`, `hermes_cli/`,
  `tools/`, `tests/`, and any other Python. Backend work is always dispatched
  to Codex; Claude does not write backend code.
- **Claude lane — ALL frontend:** `apps/ios/` (Swift/SwiftUI, XcodeGen,
  widgets, share extension), plus contracts, briefs, and docs.
- **Claude owns everything:** every Codex result is reviewed, tested, and
  committed by Claude. One quality bar, one committer.

## Dispatch — two modes, one brief location

The brief ALWAYS lives in the task's Linear issue description (team ABH,
label lane:codex), using the template below. No side-channel contracts.

**Mode A — interactive (Codex desktop app):** for substantial backend tasks.
Claude writes the brief into the Linear issue and moves it to Todo; the user
picks it up in the Codex app; Codex implements and comments evidence on the
issue; Claude reviews, tests, commits, and owns the status transition.
Codex comments on issues but NEVER changes issue status — Claude owns status.

**Mode B — automated (CLI):** for quick fixes and test-failure iterations.

1. Copy the issue's brief to `/tmp/codex-briefs/<task>.md`.
2. Launch (background it via the Bash tool, run_in_background):

```bash
~/bin/codexw exec -s workspace-write -C ~/.hermes/hermes-agent \
  "$(cat /tmp/codex-briefs/<task>.md)"
```

- ALWAYS `~/bin/codexw`, never bare `codex` (wrapper routes via the ChatGPT
  subscription — verified working).
- `-s workspace-write`: edits files + runs tests in-repo, network denied
  (our suites run offline). Do NOT escalate sandbox level without the user's
  explicit say-so.
- Optional structured report: `--output-schema /tmp/codex-briefs/<task>.schema.json`
  forces the final message into a JSON shape you define.

3. Capture the session id from the output header (or use `resume --last`).

## Iterate (session resume)

After review, send findings back into the SAME Codex context:

```bash
~/bin/codexw exec resume --last "Tests 3 and 7 fail with <output>. Fix without touching the throttle logic."
```

Multiple concurrent lanes → use explicit ids: `codexw exec resume <SESSION_ID> "..."`.

## Review & commit (never delegated)

- Codex WRITES; Claude GATES. After each Codex pass: run the relevant suite
  (full server suite for backend changes), review `git diff`, only then commit.
- Claude commits with explicit pathspecs (`git add <files>`), message style
  `hermes-mobile <batch>: ...`. Codex is told NOT to commit.
- Cross-model review available both ways: /codex skill (review/challenge
  modes) for Claude-authored Swift diffs.

## Brief template (paste into /tmp/codex-briefs/<task>.md)

```
TASK: <one line>
REPO: ~/.hermes/hermes-agent, branch hermes-mobile. Do NOT commit, do NOT push,
do NOT touch apps/ios/.
CONTEXT: <pointers: contract file, relevant source files w/ line refs, prior
findings>
CONSTRAINTS:
- The user's LIVE dashboard runs on 127.0.0.1:9119 — never restart/stop it or
  point test traffic at it. Own test instances go on port 9123+ and must be
  killed afterward.
- No credentials in code or plists. No new dependencies.
- Match surrounding code style; tests for every behavior change.
SPEC: <the actual work, interface-pinned like our CONTRACT-*.md files>
DONE WHEN: <observable gate: which tests pass, what output exists>
REPORT: end with a summary of files touched, tests run + results, and any
concerns. Do not commit.
```

## Stall recovery

If a codex exec hangs: `kill <PID>`, then
`~/bin/codexw exec resume --last "continue"` — session state survives the kill.
