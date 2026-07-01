#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT_UNDER_TEST="$ROOT/scripts/ship-testflight.sh"
FAILURES=0
PASSES=0

fail() {
  echo "FAIL: $*"
  FAILURES=$((FAILURES + 1))
}

pass() {
  echo "PASS: $*"
  PASSES=$((PASSES + 1))
}

extract_gate_2() {
  awk '
    /^# --- GATE 2:/ { in_gate = 1; next }
    /^# --- STEP 1:/ { in_gate = 0 }
    in_gate { print }
  ' "$SCRIPT_UNDER_TEST"
}

make_repo() {
  local mode="$1"
  local repo="$2"

  git init -q "$repo"
  (
    cd "$repo"
    git config user.email test@example.invalid
    git config user.name "Ship Gate Test"
    mkdir -p apps/ios
    cat > apps/ios/project.yml <<'YAML'
settings:
  CURRENT_PROJECT_VERSION: 60
YAML
    git add apps/ios/project.yml

    if [ "$mode" = "no-ship" ]; then
      git commit -q -m "feat: first code before any ship"
    else
      git commit -q -m "ship: TestFlight build 60 (wave test, internal, autonomous)"
    fi

    if [ "$mode" = "one-after" ]; then
      echo "merged change" > merged.txt
      git add merged.txt
      git commit -q -m "feat: merged code after ship"
    fi
  )
}

run_gate_2() {
  local repo="$1"
  (
    cd "$repo"
    bash -c "$(extract_gate_2)"
  ) 2>&1 || true
}

assert_proceeds_with_one_commit_after_last_ship() {
  local tmp repo output
  tmp=$(mktemp -d)
  repo="$tmp/repo"
  make_repo one-after "$repo"
  output=$(run_gate_2 "$repo")
  rm -rf "$tmp"

  if [[ "$output" == *"SHIP SKIPPED"* ]]; then
    fail "one commit after last ship should proceed, not skip"
    printf '  output: %s\n' "$output"
  else
    pass "one commit after last ship proceeds"
  fi
}

assert_skips_with_zero_commits_after_last_ship() {
  local tmp repo output
  tmp=$(mktemp -d)
  repo="$tmp/repo"
  make_repo zero-after "$repo"
  output=$(run_gate_2 "$repo")
  rm -rf "$tmp"

  if [[ "$output" == *"SHIP SKIPPED"* ]]; then
    pass "zero commits after last ship skips"
  else
    fail "zero commits after last ship should skip"
    printf '  output: %s\n' "${output:-<empty>}"
  fi
}

assert_proceeds_without_prior_ship_commit() {
  local tmp repo output
  tmp=$(mktemp -d)
  repo="$tmp/repo"
  make_repo no-ship "$repo"
  output=$(run_gate_2 "$repo")
  rm -rf "$tmp"

  if [[ "$output" == *"SHIP SKIPPED"* ]]; then
    fail "fresh repo without a prior ship commit should proceed"
    printf '  output: %s\n' "$output"
  else
    pass "fresh repo without a prior ship commit proceeds"
  fi
}

assert_proceeds_with_one_commit_after_last_ship
assert_skips_with_zero_commits_after_last_ship
assert_proceeds_without_prior_ship_commit

echo "Gate-2 ship test summary: $PASSES passed, $FAILURES failed"
[ "$FAILURES" -eq 0 ]
