# STR-1476 deterministic verifier report

Date: 2026-07-11
PR head before this report commit: `34ec40fcc6bc6984d7ec3b38389b192cba1ee7d9`
Base tested independently: `12665efff` (`origin/environment-and-workflows-overview`)

## `scripts/verify.sh` result

The full deterministic verifier ran on the PR head.

Passing blocking gates:

- `uv-lock`
- `node-install`
- `hermes-ink-build`
- `windows-footguns`
- all five TypeScript typecheck workspaces
- `vitest-web`
- `desktop-build`
- `ios-build`

One blocking gate failed:

```text
vitest-ui-tui: FAIL
Test Files 2 failed | 105 passed (107)
Tests 3 failed | 1110 passed | 1 skipped (1114)
```

Failing tests:

- `src/__tests__/statusRule.test.ts`: 2 failures
- `src/__tests__/virtualHeights.test.ts`: 1 failure

## Base reproduction

The two failing files were rerun in a clean detached worktree at base SHA `12665efff`, using the repository's installed workspace dependencies. The same three assertions failed on the base branch:

```text
Test Files 2 failed (2)
Tests 3 failed | 19 passed (22)
```

The PR diff does not touch `ui-tui/`; these are pre-existing base failures rather than regressions introduced by STR-1450. The temporary base worktree was removed immediately after the reproduction.

## Focused iOS regression suite

`HermesMobileTests/CacheFirstLaunchTests` passed 11/11 with zero failures. See `cache-first-launch-tests-final.md` in this directory.
