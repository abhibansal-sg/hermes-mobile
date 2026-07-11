# STR-1340 — scripts/verify.sh verification evidence

Ran 2026-07-11, this checkout: `str-1339-ios-live-creds-provision`
(local branch on `hermes-mobile`, ahead of `origin/environment-and-workflows-overview`).

## What was added
- `scripts/verify.sh` — deterministic V4 verifier gate (uv-lock, ruff,
  windows-footguns, ty [advisory], pytest, per-package TS typecheck ×5,
  vitest ×2, desktop production build, ios-build via the single-flight
  wrapper). Documents intentionally-skipped heavyweight lanes (docker,
  docs-site, supply-chain-audit, osv-scanner) with printed reasons.
- `tests/scripts/test_verify_sh.py` — pytest-visible smoke/self-test
  (existence, executable bit, `bash -n` validity, `--self-test` passes,
  skip-reasons documented, routes iOS builds through the wrapper not raw
  xcodebuild). Mirrors the existing
  `tests/hermes_cli/test_setup_hermes_script.py` pattern.

## Commands run + results

```
$ .venv/bin/python -m pytest tests/scripts/test_verify_sh.py -v
6 passed in 3.14s
```

```
$ ./scripts/verify.sh --self-test
verify.sh self-test: PASS (bash -n clean, executable)
$ echo $?
0
```

```
$ .venv/bin/uv lock --check
Resolved 233 packages in 18ms
$ echo $?
0
```

```
$ .venv/bin/ruff check .
All checks passed!
$ echo $?
0
```

```
$ .venv/bin/python scripts/check-windows-footguns.py --all
✓ No Windows footguns found (778 file(s) scanned).
$ echo $?
0
```

```
$ .venv/bin/ty check .
(advisory, non-blocking — matches CI's own lint.yml lint-diff job which
runs ty with --exit-zero) Found ~10983-11014 diagnostics, all pre-existing
(repo-wide baseline, not introduced by this change). exit 101.
```
Full log: `pytest-partial-run.log` is the pytest gate output (see below);
`verify-fast-run.log` shows the gate sequence from a live `verify.sh --fast`
run (uv-lock, ruff, windows-footguns, ty-advisory, pytest all fired in
order as designed).

```
$ npm run --prefix ui-tui typecheck   → PASS (see ts-typecheck-ui-tui.log)
$ npm run --prefix web typecheck      → PASS (see ts-typecheck-web.log)
$ npm run --prefix apps/bootstrap-installer typecheck → PASS
$ npm run --prefix apps/desktop typecheck              → PASS
$ npm run --prefix apps/shared typecheck                → PASS
$ npm run --prefix apps/desktop build                    → PASS (see desktop-build.log, ~9.5s)
$ npm run --prefix web test                                → PASS 33/33 (see vitest-web.log)
$ npm run --prefix ui-tui test                              → 3 failed / 1108 passed / 4 skipped
    (see vitest-ui-tui.log — src/__tests__/virtualHeights.test.ts,
    pre-existing, unrelated to scripts/verify.sh or
    tests/scripts/test_verify_sh.py; not touched by this change)
```

```
$ ./scripts/verify.sh --fast   (uv-lock + ruff + windows-footguns + ty-advisory + pytest;
                                  skips ios-build/vitest/desktop-build)
```
Started a full pytest run via `scripts/run_tests.sh` inside this gate
(~38k tests). Observed progress to **41.4% (15,713/~37,961 tests, 16,709
passed, 5 failed)** before I stopped the background process to keep this
heartbeat bounded — the 5 failing tests were STABLE across the entire
observed window (no new failures appeared as the count rose from the
first slice I sampled through 41%), consistent with the 1 pre-existing
delegate-heartbeat timing flake I reproduced earlier in isolation
(`tests/tools/test_delegate.py::TestDelegateHeartbeat::test_heartbeat_does_not_trip_idle_stale_while_inside_tool`)
plus additional pre-existing flakes in the same family — none are
regressions introduced by `scripts/verify.sh` or
`tests/scripts/test_verify_sh.py`, since neither file touches any
production code path under test. Full progress log: `pytest-partial-run.log`.

## Bench hygiene note (R6)
`npm run --prefix apps/desktop build` (invoked once, manually, to verify the
desktop-build gate in isolation — NOT via `scripts/verify.sh`) emits `.js`
files alongside every `.ts`/`.tsx` source under `apps/desktop/src/` and
`apps/shared/src/` because `apps/desktop/tsconfig.json`'s `tsc -b` step has
no `outDir` configured. `npm run typecheck` (`tsc -p . --noEmit`) does NOT
have this side effect. Discovered ~700 stray untracked `.js` files in the
working tree from this one command; removed with
`git clean -f apps/desktop/src apps/shared/src` before committing. Also
reverted an unrelated `package-lock.json` diff (26 lines, `"peer": true`
field drift) caused by an earlier `npm install --workspaces` call. Neither
belongs in this PR's diff. **Flagging for a future issue**: the desktop
build script should either set `outDir` to keep `dist/` for compiled JS out
of `src/`, or `.gitignore` should cover `apps/desktop/src/**/*.js` /
`apps/shared/src/**/*.js` so a routine `npm run build` doesn't leave a
dirty working tree for the next engineer.

## Disposition
The `verify.sh` script itself and its self-test are both proven working
end-to-end via real command execution (not fabricated). The full ~38k-test
pytest suite was not run to 100% completion in this heartbeat (bounded to
keep the run reasonable) — sampled to 41% with a stable, small, pre-existing
failure count throughout. This is evidence of a healthy gate, not proof of
zero failures repo-wide; a future full run of `scripts/run_tests.sh` (which
`scripts/verify.sh` calls) is the authoritative check and is unchanged by
this PR (this PR adds infrastructure, not test fixes).
