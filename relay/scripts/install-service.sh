#!/usr/bin/env bash
# install-service.sh — install / uninstall / inspect the ai.hermes.relay launchd
# service (spec DAILY-DRIVER N6, acceptance A7): exactly ONE relay on this Mac,
# supervised by launchd, pointed at the LIVE gateway with the dashboard token.
#
# What "install" does (idempotent):
#   1. Pre-flight: macOS launchctl present; the gateway token file exists
#      (default ~/.hermes/dashboard.token — the relay would exit without it and
#      KeepAlive would crash-loop, so we refuse to install into that state).
#   2. Provision a service venv on the external volume (internal disk is tight)
#      and pip-install the relay package NON-editable, so the service does not
#      depend on any worktree staying on disk.
#   3. Render ai.hermes.relay.plist (this dir) -> ~/Library/LaunchAgents/,
#      expanding ~ to $HOME (launchd does no shell expansion), and validate it
#      with `plutil -lint`. An existing plist is backed up first.
#   4. launchctl bootout any loaded instance, then bootstrap the new one.
#
# The service runs:
#   $VENV/bin/python -m hermes_relay \
#       --gateway-host 127.0.0.1 --gateway-port 9119 --allow-live-gateway \
#       --listen 0.0.0.0:8788 --token-file ~/.hermes/dashboard.token
# KeepAlive + RunAtLoad; stdout and stderr both go to
# ~/Library/Logs/Hermes/relay.log. 9119 is accepted ONLY because the service
# passes --allow-live-gateway (hermes_relay/__main__.py refuses it otherwise).
#
# DEPLOY ORDER (Land phase): decommission-old-relays.sh FIRST (frees 0.0.0.0:8788
# and kills the stale 9119-dialing relay), then `install-service.sh install`.
#
# Subcommands:
#   install     provision venv, render + load the plist
#   uninstall   bootout the service and remove the plist (venv + logs kept)
#   status      plist/loaded/PID/read-only-health report (never mutates)
#
# Flags:
#   --dry-run   print every action without executing (no pip, no launchctl)
#
# Overrides (environment):
#   RELAY_SERVICE_VENV  service venv   (default /Volumes/MainData/Developer/
#                                       hermes-tmp/venvs/relay-service)
#   RELAY_LISTEN        downstream bind           (default 0.0.0.0:8788)
#   RELAY_TOKEN_FILE    gateway token file        (default $HOME/.hermes/dashboard.token)
#   RELAY_LOG_FILE      stdout+stderr sink        (default $HOME/Library/Logs/Hermes/relay.log)
#   HERMES_REPO_ROOT    WorkingDirectory for the service (default: this repo root)
#   RELAY_HERMES_HOME   HERMES_HOME used by device-token validation
#                       (default $HOME/.hermes)
#
# SAFETY: this script is safe to run in any tree — it only touches the venv on
# /Volumes/MainData and the current user's ~/Library. It NEVER contacts the
# live gateway itself; only the installed service does (that is its job).
set -euo pipefail

LABEL="ai.hermes.relay"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"        # relay/scripts
RELAY_PKG="$(cd "$HERE/.." && pwd)"                          # relay/
REPO_ROOT="${HERMES_REPO_ROOT:-$(cd "$RELAY_PKG/.." && pwd)}"  # repo root
TEMPLATE="$HERE/$LABEL.plist"

VENV="${RELAY_SERVICE_VENV:-/Volumes/MainData/Developer/hermes-tmp/venvs/relay-service}"
LISTEN="${RELAY_LISTEN:-0.0.0.0:8788}"
TOKEN_FILE="${RELAY_TOKEN_FILE:-$HOME/.hermes/dashboard.token}"
LOG_FILE="${RELAY_LOG_FILE:-$HOME/Library/Logs/Hermes/relay.log}"
HERMES_HOME_DIR="${RELAY_HERMES_HOME:-$HOME/.hermes}"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"
GUI_DOMAIN="gui/$(id -u)"
PYTHON_BIN="/opt/homebrew/bin/python3.13"

DRY_RUN=0
CMD=""

usage() {
  cat <<EOF
usage: $(basename "$0") {install|uninstall|status} [--dry-run]

  install     provision $VENV, render + load ~/Library/LaunchAgents/$LABEL.plist
  uninstall   bootout the service and remove the plist (venv + logs kept)
  status      report plist/load/PID + read-only health (never mutates)
  --dry-run   print actions without executing
EOF
}

say()  { printf 'install-service: %s\n' "$*"; }
run()  {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'install-service: DRY-RUN  %s\n' "$*"
  else
    printf 'install-service: RUN      %s\n' "$*"
    "$@"
  fi
}

for arg in "$@"; do
  case "$arg" in
    install|uninstall|status) CMD="$arg" ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "install-service: unknown argument: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "$CMD" ]; then
  usage >&2
  exit 2
fi

# --- status: pure inspection, never mutates --------------------------------
if [ "$CMD" = "status" ]; then
  rc=0
  if [ -f "$PLIST_DST" ]; then
    say "plist installed: $PLIST_DST"
  else
    say "plist NOT installed ($PLIST_DST absent)"
    rc=1
  fi

  if launchctl print "$GUI_DOMAIN/$LABEL" >/dev/null 2>&1; then
    say "service loaded in $GUI_DOMAIN:"
    launchctl print "$GUI_DOMAIN/$LABEL" 2>/dev/null \
      | grep -E '^[[:space:]]*(state|pid|last exit code|program) =' || true
  else
    say "service not loaded in $GUI_DOMAIN"
    rc=1
  fi

  # Any hermes_relay process? (service + strays; decommission-old-relays.sh
  # owns the distinction.)
  if pgrep -f -- '-m hermes_relay' >/dev/null 2>&1; then
    say "hermes_relay processes running:"
    pgrep -fl -- '-m hermes_relay' || true
  else
    say "no hermes_relay process running"
  fi

  # Read-only health curl (explicitly allowed by the spec). Never fatal.
  if command -v curl >/dev/null 2>&1; then
    health="http://127.0.0.1:${LISTEN##*:}/healthz"
    relay_health_token=""
    [ ! -s "$TOKEN_FILE" ] || IFS= read -r relay_health_token < "$TOKEN_FILE"
    if body="$(curl -fsS --max-time 3 \
        -H "X-Hermes-Session-Token: $relay_health_token" "$health" 2>/dev/null)"; then
      say "health $health -> $body"
    else
      say "health $health -> no/failed response (service down or starting)"
    fi
  fi
  exit "$rc"
fi

# --- pre-flight shared by install/uninstall --------------------------------
if ! command -v launchctl >/dev/null 2>&1; then
  echo "install-service: launchctl not found — this is a macOS-only service." >&2
  exit 1
fi

if [ "$CMD" = "uninstall" ]; then
  say "booting out $GUI_DOMAIN/$LABEL (ignore 'no such service' if not loaded)"
  run launchctl bootout "$GUI_DOMAIN/$LABEL" || true
  if [ -f "$PLIST_DST" ]; then
    run rm -f "$PLIST_DST"
  else
    say "plist already absent: $PLIST_DST"
  fi
  say "uninstalled. Kept: venv $VENV and log $LOG_FILE (remove by hand if wanted)."
  say "NOTE: no supervised relay runs now; the phone relay path is offline."
  exit 0
fi

# --- install ----------------------------------------------------------------
say "installing $LABEL (dry-run=$DRY_RUN)"

# 1) pre-flight: token file must exist (else KeepAlive crash-loop).
if [ ! -s "$TOKEN_FILE" ]; then
  echo "install-service: token file missing or empty: $TOKEN_FILE" >&2
  echo "  The relay exits without a gateway token and KeepAlive would" >&2
  echo "  crash-loop the service. Create/point RELAY_TOKEN_FILE first." >&2
  exit 1
fi
if [ ! -f "$TEMPLATE" ]; then
  echo "install-service: plist template missing: $TEMPLATE" >&2
  exit 1
fi

# 2) service venv on the external volume + non-editable relay install.
if [ ! -x "$VENV/bin/python" ]; then
  run "$PYTHON_BIN" -m venv "$VENV"
else
  say "venv exists: $VENV"
fi
run "$VENV/bin/python" -m pip install --quiet --upgrade pip
run "$VENV/bin/python" -m pip install --quiet "$RELAY_PKG"

# 3) render the plist (expand tokens to absolute paths) and lint it.
run mkdir -p "$HOME/Library/Logs/Hermes" "$HOME/Library/LaunchAgents"
if [ "$DRY_RUN" -eq 1 ]; then
  say "DRY-RUN  render $TEMPLATE -> $PLIST_DST"
  say "         venv=$VENV repo=$REPO_ROOT token=$TOKEN_FILE log=$LOG_FILE listen=$LISTEN"
  say "         hermes_home=$HERMES_HOME_DIR"
else
  if [ -f "$PLIST_DST" ]; then
    backup="$PLIST_DST.bak.$(date -u +%Y%m%dT%H%M%SZ)"
    cp "$PLIST_DST" "$backup"
    say "existing plist backed up: $backup"
  fi
  sed \
    -e "s|__VENV__|$VENV|g" \
    -e "s|__REPO_ROOT__|$REPO_ROOT|g" \
    -e "s|__TOKEN_FILE__|$TOKEN_FILE|g" \
    -e "s|__LOG_FILE__|$LOG_FILE|g" \
    -e "s|__LISTEN__|$LISTEN|g" \
    -e "s|__HERMES_HOME__|$HERMES_HOME_DIR|g" \
    "$TEMPLATE" > "$PLIST_DST"
  say "rendered: $PLIST_DST"
  plutil -lint "$PLIST_DST"
fi

# 4) (re)load: bootout is best-effort, bootstrap is the load.
say "booting out any loaded instance (ignore 'no such service')"
run launchctl bootout "$GUI_DOMAIN/$LABEL" || true
run launchctl bootstrap "$GUI_DOMAIN" "$PLIST_DST"

say "installed. Verify with: $0 status"
say "Logs: $LOG_FILE   (the service dials the LIVE gateway 127.0.0.1:9119 by design)"
say "Before this serves the phone, retire strays: $(dirname "$0")/decommission-old-relays.sh"
exit 0
