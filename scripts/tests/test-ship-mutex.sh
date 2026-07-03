#!/bin/bash
# test-ship-mutex.sh — verify ship-testflight.sh's mkdir-mutex guarantees only ONE
# concurrent ship proceeds (ABH-348).
#
# WHY: two concurrent ship invocations (orchestrator cadence + soak/live-beat) each
# bumped the build and fired a separate Xcode Cloud run, stranding builds 61/62/63.
# The fix is a non-blocking mkdir mutex at $HOME/.hermes/ship-testflight.lock. This
# test proves the mutex: exactly ONE process wins the lock and proceeds past the gate,
# the other prints "SHIP SKIPPED: another ship in progress" and exits 0.
#
# HERMETIC (ABH-348 rework): the loser invokes the real ship-testflight.sh with
# SHIP_SELFTEST=1. That inert guard (in ship-testflight.sh) hard-exits AFTER the mutex
# decision but BEFORE GATE 0 / any side effect — so the loser can NEVER reach build
# bump, archive, upload, or cloud-trigger regardless of mutex state or governor
# arming. This is the false-green safety boundary: even if the mutex is removed, the
# test FAILS without ever shipping.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
SHIP="$REPO/scripts/ship-testflight.sh"
LOCK_DIR="$HOME/.hermes/ship-testflight.lock"

pass(){ echo "PASS: $1"; exit 0; }
fail(){ echo "FAIL: $1"; exit 1; }

[ -x "$SHIP" ] || fail "ship-testflight.sh not found/executable at $SHIP"

# --- clean slate -------------------------------------------------------------
rm -rf "$LOCK_DIR" 2>/dev/null

# --- 1. simulate a ship already holding the lock (the "winner") --------------
# Use the exact mkdir+pid+trap pattern from ship-testflight.sh.
mkdir "$LOCK_DIR" 2>/dev/null || fail "could not create lock dir (pre-existing?)"
echo "$$" > "$LOCK_DIR/pid"
echo "$(date '+%Y-%m-%d %H:%M:%S') test-winner" > "$LOCK_DIR/info"
release(){ [ -f "$LOCK_DIR/pid" ] && [ "$(cat "$LOCK_DIR/pid" 2>/dev/null)" = "$$" ] && rm -rf "$LOCK_DIR"; }
trap release EXIT INT TERM

echo "  winner (pid $$) holds lock; launching a racing ship invocation…"

# --- 2. launch the "loser" (real script, SHIP_SELFTEST=1 for hermeticity) ----
# SHIP_SELFTEST=1 makes ship-testflight.sh exit 0 right after the mutex decision,
# before ANY side effect. So the loser is provably safe regardless of mutex state.
OUT=$(SHIP_SELFTEST=1 "$SHIP" 2>&1)
RC=$?

echo "  loser exit_code=$RC"
echo "  loser output: $OUT"

# --- 3. assertions -----------------------------------------------------------
# (a) exit 0 — a skipped concurrent ship is NOT a failure
[ "$RC" -eq 0 ] || fail "expected exit 0 (skip is not a failure), got $RC"
# (b) it must report the skip
echo "$OUT" | grep -q "SHIP SKIPPED: another ship in progress" \
  || fail "expected 'SHIP SKIPPED: another ship in progress' in output, got: $OUT"
# (c) it must NOT have reached the selftest exit (that would mean it got past the mutex)
echo "$OUT" | grep -q "SHIP SELFTEST" \
  && fail "loser reached SELFTEST guard — mutex leak (loser acquired the lock despite the winner)" || true
# (d) it must NOT have bumped the build or triggered any build/cloud work
echo "$OUT" | grep -qiE "bumping build|CLOUD SHIP|archiving|triggering Xcode Cloud" \
  && fail "loser proceeded past the mutex (build/cloud work detected) — mutex leak" || true

# release our lock so the trap doesn't double-clean
release
trap - EXIT INT TERM

echo
pass "concurrent ship was skipped (exit 0, SHIP SKIPPED) while another ship held the mutex"
