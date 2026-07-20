#!/usr/bin/env bash
# decommission-old-relays.sh — SIGTERM every hermes_relay process that is NOT
# owned by the ai.hermes.relay launchd service (spec DAILY-DRIVER A7: exactly
# ONE relay on this Mac, the supervised one).
#
# Ownership rule: the service execs exactly "$VENV/bin/python" (ProgramArguments
# [0] in the plist), so a hermes_relay process is service-owned iff its argv[0]
# is the service venv's python. Everything else — terminal-launched relays,
# nohup'd relays (even with PPID 1), stale pre-refusal binaries dialing the live
# gateway — is a stray and gets SIGTERMed.
#
# Hard rules honored: SIGTERM only — NEVER kill -9 (a mid-turn SIGTERM is the
# chaos scenario the relay is built to survive; the phone reconnects/resyncs).
#
# Usage:
#   decommission-old-relays.sh [--dry-run]
#
# Overrides (environment — must match install-service.sh or the service itself
# looks like a stray):
#   RELAY_SERVICE_VENV  service venv (default /Volumes/MainData/Developer/
#                       hermes-tmp/venvs/relay-service)
#
# Exit codes: 0 = no strays left (or none found); 1 = strays survived SIGTERM
# past the grace period (reported; never escalated).
set -euo pipefail

VENV="${RELAY_SERVICE_VENV:-/Volumes/MainData/Developer/hermes-tmp/venvs/relay-service}"
SERVICE_PY="$VENV/bin/python"
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

# argv[0] of a pid, i.e. the interpreter launchd/the shell actually execed.
argv0_of() {
  ps -p "$1" -o command= 2>/dev/null | awk '{print $1; exit}'
}

strays=()
service_pids=()
while IFS= read -r pid; do
  [ -n "$pid" ] || continue
  [ "$pid" = "$$" ] && continue      # never ourselves
  [ "$pid" = "$PPID" ] && continue   # never our own parent shell
  exe="$(argv0_of "$pid" || true)"
  if [ -z "$exe" ]; then
    continue                          # vanished between pgrep and ps
  fi
  if [ "$exe" = "$SERVICE_PY" ]; then
    service_pids+=("$pid")
  else
    strays+=("$pid")
  fi
done < <(pgrep -f -- '-m hermes_relay' 2>/dev/null || true)

if [ "${#service_pids[@]}" -gt 0 ]; then
  echo "decommission: keeping service-owned pid(s): ${service_pids[*]} (exe $SERVICE_PY)"
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
