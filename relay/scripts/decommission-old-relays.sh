#!/usr/bin/env bash
# decommission-old-relays.sh — SIGTERM every hermes_relay process that is NOT
# owned by the ai.hermes.relay launchd service (spec DAILY-DRIVER A7: exactly
# ONE relay on this Mac, the supervised one).
#
# Ownership rule: launchd is authoritative. The service's PID is read from
# `launchctl print gui/<uid>/ai.hermes.relay` ("pid = N") — that PID is kept,
# every OTHER hermes_relay process is a stray and gets SIGTERMed. (argv[0] is
# NOT a reliable discriminator: on macOS `ps` reports the resolved interpreter
# — the Homebrew Cellar framework binary — identically for a venv python, a
# terminal python, and the service python. Only launchd knows which PID it
# actually spawned.) Everything else — terminal-launched relays, nohup'd
# relays (even with PPID 1), stale pre-refusal binaries dialing the live
# gateway — is a stray.
#
# Hard rules honored: SIGTERM only — NEVER kill -9 (a mid-turn SIGTERM is the
# chaos scenario the relay is built to survive; the phone reconnects/resyncs).
#
# Usage:
#   decommission-old-relays.sh [--dry-run]
#
# Exit codes: 0 = no strays left (or none found); 1 = strays survived SIGTERM
# past the grace period (reported; never escalated).
set -euo pipefail

LABEL="ai.hermes.relay"
GUI_DOMAIN="gui/$(id -u)"
GRACE_SECONDS=5
DRY_RUN=0

case "${1:-}" in
  --dry-run|-n) DRY_RUN=1 ;;
  -h|--help)
    echo "usage: $(basename "$0") [--dry-run]   # SIGTERM hermes_relay strays, spare the ai.hermes.relay service"
    exit 0 ;;
  "") : ;;
  *) echo "decommission: unknown argument: $1" >&2; exit 2 ;;
esac

# The supervised service's PID, per launchd itself (authoritative). Empty when
# the service is not loaded or not currently running (-> nothing to spare).
service_pid=""
if command -v launchctl >/dev/null 2>&1; then
  service_pid="$(launchctl print "$GUI_DOMAIN/$LABEL" 2>/dev/null \
    | awk -F'= ' '/^[[:space:]]*pid =/{gsub(/;.*/, "", $2); print $2; exit}' || true)"
else
  echo "decommission: WARNING — launchctl unavailable; cannot identify the service PID; every hermes_relay process is treated as a stray." >&2
fi

strays=()
service_pids=()
while IFS= read -r pid; do
  [ -n "$pid" ] || continue
  [ "$pid" = "$$" ] && continue      # never ourselves
  [ "$pid" = "$PPID" ] && continue   # never our own parent shell
  if [ -n "$service_pid" ] && [ "$pid" = "$service_pid" ]; then
    service_pids+=("$pid")
  else
    strays+=("$pid")
  fi
done < <(pgrep -f -- '-m hermes_relay' 2>/dev/null || true)

if [ "${#service_pids[@]}" -gt 0 ]; then
  echo "decommission: keeping launchd-service pid(s): ${service_pids[*]} ($LABEL)"
fi

if [ "${#strays[@]}" -eq 0 ]; then
  echo "decommission: no stray hermes_relay processes found — nothing to do."
  exit 0
fi

echo "decommission: stray hermes_relay pid(s): ${strays[*]}"
for pid in "${strays[@]}"; do
  echo "decommission:   $(ps -p "$pid" -o command= 2>/dev/null || echo "pid $pid (gone)")"
done

if [ "$DRY_RUN" -eq 1 ]; then
  echo "decommission: DRY-RUN — would send SIGTERM to: ${strays[*]} (nothing sent)"
  exit 0
fi

# SIGTERM only. Never -9: the relay treats SIGTERM as graceful shutdown and the
# phone is expected to reconnect and resync (spec A6 chaos scenario).
for pid in "${strays[@]}"; do
  if kill -TERM "$pid" 2>/dev/null; then
    echo "decommission: SIGTERM -> $pid"
  else
    echo "decommission: pid $pid already gone"
  fi
done

# Grace period, then report survivors — never escalate past SIGTERM.
deadline=$((SECONDS + GRACE_SECONDS))
while [ "$SECONDS" -lt "$deadline" ]; do
  alive=0
  for pid in "${strays[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      alive=1
      break
    fi
  done
  [ "$alive" -eq 0 ] && break
  sleep 1
done

survivors=()
for pid in "${strays[@]}"; do
  if kill -0 "$pid" 2>/dev/null; then
    survivors+=("$pid")
  fi
done

if [ "${#survivors[@]}" -gt 0 ]; then
  echo "decommission: WARNING — still alive after SIGTERM + ${GRACE_SECONDS}s: ${survivors[*]}" >&2
  echo "decommission: NOT escalating to SIGKILL (spec rule). Investigate by hand." >&2
  exit 1
fi

echo "decommission: all strays terminated. The supervised service (if installed) is the only relay now."
exit 0
