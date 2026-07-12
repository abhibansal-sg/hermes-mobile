# STR-1593 release validation

Validated on release landing commit `373a2493c` atop PR #105 branch
`str-1339-ios-live-creds-provision`.

| Check | Result |
|---|---|
| `scripts/run_tests.sh tests/scripts/test_changed_tests.py tests/scripts/test_verify_sh.py -q -j 2 --file-timeout 60` | 32 passed, 0 failed across 2 files in 4.7s |
| `bash -n scripts/verify.sh` | Passed |
| `bash scripts/verify.sh --self-test` | Passed |
| `.venv/bin/ruff check scripts/changed_tests.py tests/scripts/test_changed_tests.py` | All checks passed |
| `git diff --check` before commit | Passed |

Coverage audit: the focused suite exercises changed-test selection, nested
`conftest.py` subtree expansion, helper import mapping, unmapped-source
reporting, broad/core fallback, argument validation, and preservation of the
argument-less full-suite path.
