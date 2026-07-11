#!/usr/bin/env bash
# scripts/verify.sh — THE deterministic V4 verifier gate for hermes-mobile
# (STR-1340: "V4 LAW 3: tests decide, agents advise" — this script is the
# machine-readable ground truth every verifier run must call FIRST).
#
# Runs the canonical install/lint/typecheck/test/build gates for the repo's
# three surfaces (Python core, TypeScript workspaces, iOS app) and prints a
# single PASS/FAIL verdict. Exit 0 = PASS, exit 1 = FAIL. Every gate's full
# log is kept at /tmp/verify-<gate>.log; only the last 12 lines print inline
# on failure so the summary stays scannable.
#
# USAGE:
#   scripts/verify.sh                              # everything (slow: ~pytest + TS + iOS build)
#   scripts/verify.sh --fast                        # skip iOS build + desktop build + vitest
#   scripts/verify.sh --skip-ios                     # skip the iOS build gate only
#   scripts/verify.sh --skip-ts                       # skip all TypeScript gates (typecheck/vitest/desktop-build)
#   scripts/verify.sh --skip-pytest                    # skip the Python test gate
#   scripts/verify.sh --scheme <scheme> --destination <dest>   # override iOS build target
#   scripts/verify.sh --self-test                       # only check this script itself is well-formed
#
# GATE MAP (mirrors .github/workflows/{ci,lint,typecheck,tests}.yml so a
# local PASS here predicts the CI required-check gate):
#   uv-lock          uv lock --check                          (blocking)
#   node-install      ensure workspace node_modules present     (blocking)
#   ruff              ruff check .                              (blocking — matches lint.yml ruff-blocking)
#   windows-footguns  scripts/check-windows-footguns.py --all    (blocking — matches lint.yml windows-footguns)
#   ty-typecheck      ty check .                                  (ADVISORY — CI's own lint-diff job is exit-zero;
#                                                                   repo currently carries pre-existing ty debt,
#                                                                   see reason printed at gate time)
#   pytest            scripts/run_tests.sh                          (blocking — matches tests.yml)
#   ts-typecheck      npm run typecheck per workspace package         (blocking — matches typecheck.yml matrix)
#   vitest            npm run test for ui-tui + web                    (blocking)
#   desktop-build      npm run build --prefix apps/desktop               (blocking — matches typecheck.yml desktop-build)
#   ios-build           scripts/ios-build.sh build ... (single-flight wrapper) (blocking — ALWAYS via the wrapper,
#                                                                                  never raw xcodebuild; loop-common law)
#
# INTENTIONALLY SKIPPED (printed at the end with the reason, per STR-1340's
# acceptance criteria — these mirror decisions already made in CI, not gaps):
#   docker             CI's own all-checks-pass gate excludes it ("so slow lol")
#   docs-site           heavyweight (docusaurus build + ascii-guard install); opt-in only
#   supply-chain/osv     require a GitHub API PR diff / SCA network fetch — not a
#                        deterministic local check; already covered by CI
#
# Output: machine-readable PASS/FAIL per gate + final verdict line.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SCHEME="${SCHEME:-HermesMobile}"
DESTINATION="${DESTINATION:-generic/platform=iOS Simulator}"
SKIP_IOS=0
SKIP_TS=0
SKIP_PYTEST=0
SELF_TEST=0
# TS workspace packages that ship a `typecheck` script (matches
# .github/workflows/typecheck.yml's matrix exactly).
TS_TYPECHECK_PACKAGES=(ui-tui web apps/bootstrap-installer apps/desktop apps/shared)
# Packages that additionally ship a `test` (vitest) script.
TS_TEST_PACKAGES=(ui-tui web)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fast) SKIP_IOS=1; SKIP_TS=2; shift;;  # SKIP_TS=2 means "typecheck only, skip vitest+desktop-build"
    --skip-ios) SKIP_IOS=1; shift;;
    --skip-ts) SKIP_TS=1; shift;;
    --skip-pytest) SKIP_PYTEST=1; shift;;
    --scheme) SCHEME="$2"; shift 2;;
    --destination) DESTINATION="$2"; shift 2;;
    --self-test) SELF_TEST=1; shift;;
    -h|--help) sed -n '2,45p' "${BASH_SOURCE[0]}" >&2; exit 0;;
    *) echo "verify.sh: unknown arg '$1' (see --help)" >&2; exit 2;;
  esac
done

declare -a RESULTS=()
declare -a SKIPPED=()
FAIL=0

log(){ printf '[verify] %s\n' "$*" >&2; }

# gate <name> <command...> — runs the command, logs full output to
# /tmp/verify-<name>.log, records PASS/FAIL, and tails the log on failure.
# Never exits early: every gate runs so a single report captures every issue.
gate() {
  local name="$1"; shift
  echo "── GATE: $name"
  if "$@" >"/tmp/verify-$name.log" 2>&1; then
    RESULTS+=("$name: PASS")
  else
    RESULTS+=("$name: FAIL (log: /tmp/verify-$name.log, tail below)")
    tail -12 "/tmp/verify-$name.log" | sed 's/^/    /'
    FAIL=1
  fi
}

# advisory <name> <command...> — same shape as gate() but never fails the
# verdict; used for lanes CI itself treats as informational (e.g. ty's
# lint-diff job runs with --exit-zero).
advisory() {
  local name="$1"; shift
  echo "── ADVISORY: $name"
  if "$@" >"/tmp/verify-$name.log" 2>&1; then
    RESULTS+=("$name: PASS (advisory)")
  else
    local count
    count="$(grep -c '^error\[' "/tmp/verify-$name.log" 2>/dev/null || echo '?')"
    RESULTS+=("$name: NOT CLEAN (advisory, non-blocking — $count diagnostic(s), log: /tmp/verify-$name.log)")
  fi
}

skip(){  # skip <name> <reason...>
  local name="$1"; shift
  SKIPPED+=("$name: SKIPPED — $*")
}

# ---- --self-test: verify this script is well-formed, then exit -------------
if [ "$SELF_TEST" = "1" ]; then
  if bash -n "${BASH_SOURCE[0]}"; then
    echo "verify.sh self-test: PASS (bash -n clean, $(test -x "${BASH_SOURCE[0]}" && echo executable || echo NOT-EXECUTABLE))"
    exit 0
  else
    echo "verify.sh self-test: FAIL (bash -n reported a syntax error)"
    exit 1
  fi
fi

# ---- uv-lock: pyproject.toml <-> uv.lock consistency (matches uv-lockfile-check.yml) ----
if [ -f pyproject.toml ]; then
  if command -v uv >/dev/null 2>&1; then
    gate uv-lock uv lock --check
  else
    skip uv-lock "uv not on PATH — install uv (https://astral.sh/uv) to run this gate"
  fi
else
  skip uv-lock "no pyproject.toml at repo root"
fi

# ---- node-install: ensure npm workspace symlinks exist before any TS gate ----
NODE_INSTALL_OK=1
if [ "$SKIP_TS" != "1" ] && [ -f package.json ]; then
  if command -v npm >/dev/null 2>&1; then
    if [ -d node_modules ] && [ -e node_modules/@hermes/ink ]; then
      RESULTS+=("node-install: PASS (workspace links already present)")
    else
      gate node-install npm install --workspaces --include-workspace-root=false
      [ "$FAIL" = "1" ] && NODE_INSTALL_OK=0
    fi
    # ui-tui's typecheck/vitest resolve @hermes/ink via its built dist/ output
    # (index.js re-exports ./dist/entry-exports.js) — build it if missing so a
    # fresh checkout doesn't spuriously fail ts-typecheck with TS2307.
    if [ "$NODE_INSTALL_OK" = "1" ] && [ ! -d ui-tui/packages/hermes-ink/dist ]; then
      gate hermes-ink-build npm run build --prefix ui-tui/packages/hermes-ink
    fi
  else
    skip node-install "npm not on PATH"
    NODE_INSTALL_OK=0
  fi
elif [ "$SKIP_TS" = "1" ]; then
  skip node-install "--skip-ts"
  NODE_INSTALL_OK=0
fi

# ---- ruff: blocking Python lint (matches lint.yml's ruff-blocking job) ----
RUFF_BIN=""
for candidate in "$REPO_ROOT/.venv/bin/ruff" "$REPO_ROOT/venv/bin/ruff" "$(command -v ruff 2>/dev/null || true)"; do
  [ -n "$candidate" ] && [ -x "$candidate" ] && { RUFF_BIN="$candidate"; break; }
done
if [ -n "$RUFF_BIN" ]; then
  gate ruff "$RUFF_BIN" check .
else
  skip ruff "no ruff binary found (.venv/bin/ruff, venv/bin/ruff, or PATH) — 'uv sync --extra dev' installs it"
fi

# ---- windows-footguns: blocking static guardrails (matches lint.yml) ----
PY_BIN=""
for candidate in "$REPO_ROOT/.venv/bin/python" "$REPO_ROOT/venv/bin/python" "$(command -v python3 2>/dev/null || true)"; do
  [ -n "$candidate" ] && [ -x "$candidate" ] && { PY_BIN="$candidate"; break; }
done
if [ -n "$PY_BIN" ] && [ -f scripts/check-windows-footguns.py ]; then
  gate windows-footguns "$PY_BIN" scripts/check-windows-footguns.py --all
else
  skip windows-footguns "no python interpreter found, or scripts/check-windows-footguns.py missing"
fi

# ---- ty-typecheck: ADVISORY ONLY — CI's own lint.yml runs ty as an
# exit-zero diagnostic diff (lint-diff), never a blocking gate. The repo
# currently carries ~11k pre-existing ty diagnostics; a local blocking gate
# here would fail on every unrelated diff and train reviewers to ignore it
# (exactly the failure mode lint.yml's own comments warn against). Surface
# the count so a PR that measurably worsens it is still visible.
if [ -n "$PY_BIN" ] && [ -x "$(dirname "$PY_BIN")/ty" ]; then
  advisory ty-typecheck "$(dirname "$PY_BIN")/ty" check .
elif command -v ty >/dev/null 2>&1; then
  advisory ty-typecheck ty check .
else
  skip ty-typecheck "no ty binary found — 'uv sync --extra dev' installs it"
fi

# ---- pytest: blocking Python test gate (matches tests.yml) ----
if [ "$SKIP_PYTEST" = "1" ]; then
  skip pytest "--skip-pytest"
elif { [ -f pyproject.toml ] || [ -d tests ]; } && { [ -d .venv ] || [ -d venv ]; }; then
  gate pytest ./scripts/run_tests.sh
elif [ -f pyproject.toml ] || [ -d tests ]; then
  skip pytest "no local .venv/venv — create one and run scripts/run_tests.sh for Python changes"
else
  skip pytest "no pyproject.toml or tests/ directory"
fi

# ---- ts-typecheck: blocking, one gate per workspace package (matches typecheck.yml matrix) ----
if [ "$SKIP_TS" = "1" ]; then
  skip ts-typecheck "--skip-ts"
elif [ "$NODE_INSTALL_OK" != "1" ]; then
  skip ts-typecheck "node-install did not succeed — see node-install result above"
else
  for pkg in "${TS_TYPECHECK_PACKAGES[@]}"; do
    if [ -f "$pkg/package.json" ]; then
      gate "ts-typecheck-$(basename "$pkg")" npm run --prefix "$pkg" typecheck
    else
      skip "ts-typecheck-$(basename "$pkg")" "$pkg/package.json not found"
    fi
  done
fi

# ---- vitest: blocking (--fast skips this; SKIP_TS=2 means "--fast") ----
if [ "$SKIP_TS" = "1" ] || [ "$SKIP_TS" = "2" ]; then
  skip vitest "$([ "$SKIP_TS" = "1" ] && echo '--skip-ts' || echo '--fast')"
elif [ "$NODE_INSTALL_OK" != "1" ]; then
  skip vitest "node-install did not succeed — see node-install result above"
else
  for pkg in "${TS_TEST_PACKAGES[@]}"; do
    if [ -f "$pkg/package.json" ] && grep -q '"test"' "$pkg/package.json"; then
      gate "vitest-$(basename "$pkg")" npm run --prefix "$pkg" test
    else
      skip "vitest-$(basename "$pkg")" "$pkg/package.json missing or has no 'test' script"
    fi
  done
fi

# ---- desktop-build: blocking production build (matches typecheck.yml desktop-build) ----
if [ "$SKIP_TS" = "1" ] || [ "$SKIP_TS" = "2" ]; then
  skip desktop-build "$([ "$SKIP_TS" = "1" ] && echo '--skip-ts' || echo '--fast')"
elif [ "$NODE_INSTALL_OK" != "1" ]; then
  skip desktop-build "node-install did not succeed — see node-install result above"
elif [ -f apps/desktop/package.json ]; then
  gate desktop-build npm run --prefix apps/desktop build
else
  skip desktop-build "apps/desktop/package.json not found"
fi

# ---- ios-build: blocking, ALWAYS via the single-flight wrapper (loop-common
# iOS build law — NEVER raw xcodebuild; the wrapper serializes machine-wide
# to avoid the SWBBuildService wedge). ----
if [ "$SKIP_IOS" = "1" ]; then
  skip ios-build "--skip-ios / --fast"
elif ls apps/*/*.xcodeproj >/dev/null 2>&1 || [ -d ios ]; then
  if [ -x scripts/ios-build.sh ]; then
    gate ios-build ./scripts/ios-build.sh build -scheme "$SCHEME" -destination "$DESTINATION"
  else
    skip ios-build "scripts/ios-build.sh missing or not executable"
  fi
else
  skip ios-build "no *.xcodeproj under apps/*/ and no ios/ directory"
fi

# ---- explicitly out of scope for this script (decisions already made elsewhere) ----
skip docker "CI's own all-checks-pass gate excludes it (ci.yml: \"so slow lol\"); use CI's docker.yml or hermes-loop tooling for image validation"
skip docs-site "heavyweight (docusaurus build + ascii-guard install); run 'npm run build --prefix website' directly when docs/ or website/ changes"
skip supply-chain-audit "requires a GitHub API PR diff (base...head compare) — not a deterministic local check; CI runs it per-PR"
skip osv-scanner "requires network access to the OSV vulnerability DB; CI runs it per-PR and on a weekly schedule"

echo "════ VERIFY RESULT ════"
for r in "${RESULTS[@]}"; do echo "  $r"; done
echo "──── skipped lanes ────"
for s in "${SKIPPED[@]}"; do echo "  $s"; done
if [ "$FAIL" = "0" ]; then echo "VERDICT: PASS"; exit 0; else echo "VERDICT: FAIL"; exit 1; fi
