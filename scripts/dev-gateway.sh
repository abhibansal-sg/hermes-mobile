#!/usr/bin/env bash
#
# dev-gateway.sh — provision + manage an ISOLATED developer gateway for the
# Hermes Mobile app, fully separate from the user's live :9119 dashboard.
#
#   * HERMES_HOME = ~/Developer/.hermes-dev  (own data/sessions/token/config —
#     ZERO overlap with ~/.hermes; the live gateway is never touched).
#   * Port        = 9200  (clean, separate from live :9119 + the old :9123 rig).
#   * Code        = THIS valencia checkout's source (trunk + the HermesMobile
#     plugin + seams), run via this checkout's .venv. So `git pull` here updates
#     the dev gateway's behaviour; the plugin is SYMLINKED (not copied) so plugin
#     edits in the repo are live immediately.
#   * Service     = launchd (RunAtLoad + KeepAlive) so it auto-starts on login
#     and survives reboot — managed like the live one, but isolated.
#
# Usage:
#   scripts/dev-gateway.sh install     # one-time: provision HOME + plugin + token + launchd
#   scripts/dev-gateway.sh start|stop|restart|status
#   scripts/dev-gateway.sh token       # print the dev pairing token
#   scripts/dev-gateway.sh pair        # print a hermesapp://pair link for the iOS app
#   scripts/dev-gateway.sh uninstall   # remove the launchd job (keeps the data dir)
#   scripts/dev-gateway.sh logs        # tail the dev gateway log
#
# SAFETY: this script only ever touches ~/Developer/.hermes-dev and its own
# launchd label (ai.hermes.dev-gateway). It NEVER touches ~/.hermes or the
# ai.hermes.dashboard service.
set -euo pipefail

# --- config (the canonical dev-gateway facts; update here if relocating) ------
DEV_HOME="${HERMES_DEV_HOME:-$HOME/Developer/.hermes-dev}"
DEV_PORT="${HERMES_DEV_PORT:-9200}"
DEV_HOST="127.0.0.1"
LABEL="ai.hermes.dev-gateway"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

# This checkout (the dev gateway runs THIS source via THIS venv).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV_HERMES="$REPO_ROOT/.venv/bin/hermes"
VENV_PY="$REPO_ROOT/.venv/bin/python"
PLUGIN_SRC="$REPO_ROOT/plugins/hermes-mobile"
SERVICE_WRAPPER="$DEV_HOME/bin/dev-gateway-service"
TOKEN_FILE="$DEV_HOME/dashboard.token"
LOG="$DEV_HOME/logs/dev-gateway.log"
ERRLOG="$DEV_HOME/logs/dev-gateway.error.log"

say(){ printf '\033[1m[dev-gateway]\033[0m %s\n' "$*"; }
die(){ printf '\033[1m[dev-gateway] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# Guard: never let DEV_HOME resolve to the live ~/.hermes.
[ "$DEV_HOME" = "$HOME/.hermes" ] && die "DEV_HOME must NOT be ~/.hermes (that's the LIVE gateway)."

cmd_install() {
  [ -x "$VENV_HERMES" ] || die "no hermes at $VENV_HERMES — run 'uv sync' / install the repo venv first."
  [ -d "$PLUGIN_SRC" ]  || die "plugin source missing at $PLUGIN_SRC"

  say "provisioning isolated dev HOME at $DEV_HOME"
  mkdir -p "$DEV_HOME"/{bin,logs,plugins,sessions}

  # Plugin -> SYMLINK into the dev HOME's user-source plugin dir (live edits).
  # (The dashboard only auto-mounts a plugin's REST api.py from the user-source
  #  HERMES_HOME/plugins dir — GHSA-5qr3-c538-wm9j — so this is the correct home.)
  local plugin_dst="$DEV_HOME/plugins/hermes-mobile"
  if [ -L "$plugin_dst" ] || [ -e "$plugin_dst" ]; then rm -rf "$plugin_dst"; fi
  ln -s "$PLUGIN_SRC" "$plugin_dst"
  say "plugin symlinked: $plugin_dst -> $PLUGIN_SRC"

  # Runtime deps the plugin REST routes need (qrcode for pairing, multipart for upload).
  # The repo venv is uv-built (no pip), so prefer `uv pip`, fall back to ensurepip.
  say "ensuring plugin runtime deps in the repo venv"
  if command -v uv >/dev/null 2>&1 && uv pip install --python "$VENV_PY" python-multipart 'qrcode[pil]' >/dev/null 2>&1; then
    :
  elif "$VENV_PY" -m pip install --quiet --disable-pip-version-check python-multipart 'qrcode[pil]' 2>/dev/null; then
    :
  else
    say "⚠ could not auto-install python-multipart/qrcode — install them into $VENV_PY by hand"
  fi

  # The dashboard process needs a built web UI dist (the iOS app uses only the
  # REST/WS API, but the dashboard refuses to boot with --skip-build and no dist).
  if [ ! -d "$REPO_ROOT/hermes_cli/web_dist" ]; then
    say "building the web UI dist (one-time; gitignored) …"
    ( cd "$REPO_ROOT" && npm install --workspace web --silent >/dev/null 2>&1 && npm run build -w web >/dev/null 2>&1 ) \
      && say "web dist built" \
      || say "⚠ web dist build failed — build it: (cd $REPO_ROOT && npm run build -w web), then restart"
  fi

  # Stable dev pairing token (own, never the live one).
  if [ ! -s "$TOKEN_FILE" ]; then
    "$VENV_PY" -c "import secrets,pathlib; pathlib.Path('$TOKEN_FILE').write_text(secrets.token_urlsafe(32))"
    chmod 600 "$TOKEN_FILE"
    say "seeded dev pairing token -> $TOKEN_FILE"
  else
    say "dev token already present -> $TOKEN_FILE"
  fi

  # Enable the plugin in the dev HOME's config (idempotent).
  HERMES_HOME="$DEV_HOME" "$VENV_HERMES" plugins enable hermes-mobile >/dev/null 2>&1 \
    && say "plugin enabled in dev config" \
    || say "(could not auto-enable via CLI — it loads from the user-source dir regardless)"

  # The launchd service wrapper (token + env live here, never in the plist).
  cat > "$SERVICE_WRAPPER" <<WRAP
#!/bin/zsh
# ISOLATED Hermes DEV gateway — separate from the live :9119 dashboard.
# Generated by scripts/dev-gateway.sh; edit the source script, then re-install.
set -euo pipefail
export HERMES_HOME="$DEV_HOME"
export HERMES_DASHBOARD_SESSION_TOKEN="\$(head -n1 "$TOKEN_FILE" | tr -d '[:space:]')"
export HERMES_GATEWAY_BROADCAST=1          # multi-client live mirroring (desktop<->phone)
export PATH="$REPO_ROOT/.venv/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
ulimit -n 4096 2>/dev/null || true
# No APNs here by default: push needs the app publisher's key; dev relies on
# in-app delivery. (Add HERMES_PUSH_ENABLED + HERMES_APNS_* if you want to test
# real push against a development-signed local build.)
exec "$VENV_HERMES" dashboard --no-open --skip-build --host $DEV_HOST --port $DEV_PORT
WRAP
  chmod +x "$SERVICE_WRAPPER"
  say "service wrapper -> $SERVICE_WRAPPER"

  # The launchd plist (token NOT in the plist — API-key-scoping discipline).
  cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>              <string>$LABEL</string>
    <key>ProgramArguments</key>   <array><string>$SERVICE_WRAPPER</string></array>
    <key>RunAtLoad</key>          <true/>
    <key>KeepAlive</key>          <true/>
    <key>WorkingDirectory</key>   <string>$DEV_HOME</string>
    <key>StandardOutPath</key>    <string>$LOG</string>
    <key>StandardErrorPath</key>  <string>$ERRLOG</string>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
PLISTEOF
  say "launchd plist -> $PLIST"
  cmd_start
  say "done. Dev gateway on http://$DEV_HOST:$DEV_PORT (HERMES_HOME=$DEV_HOME)"
}

cmd_start()  { launchctl unload "$PLIST" 2>/dev/null || true; launchctl load "$PLIST"; sleep 1; cmd_status; }
cmd_stop()   { launchctl unload "$PLIST" 2>/dev/null && say "stopped" || say "(not loaded)"; }
cmd_restart(){ cmd_stop; cmd_start; }
cmd_uninstall(){ launchctl unload "$PLIST" 2>/dev/null || true; rm -f "$PLIST"; say "launchd job removed (data dir $DEV_HOME kept)"; }
cmd_token()  { [ -s "$TOKEN_FILE" ] && head -n1 "$TOKEN_FILE" || die "no token; run install"; }
cmd_logs()   { tail -n 40 -f "$LOG" "$ERRLOG"; }

cmd_status() {
  if curl -fsS --max-time 3 "http://$DEV_HOST:$DEV_PORT/health" >/dev/null 2>&1; then
    say "UP   — http://$DEV_HOST:$DEV_PORT (HERMES_HOME=$DEV_HOME)"
  else
    say "DOWN — http://$DEV_HOST:$DEV_PORT (check: scripts/dev-gateway.sh logs)"
  fi
  launchctl list 2>/dev/null | grep -q "$LABEL" && say "launchd: loaded" || say "launchd: NOT loaded"
}

cmd_pair() {
  local tok url; tok="$(cmd_token)"; url="http://$DEV_HOST:$DEV_PORT"
  # --url pins the dev gateway (default auto-detect resolves to the live Tailscale
  # Serve setup). --device-token mints a revocable per-device token via the plugin.
  HERMES_HOME="$DEV_HOME" HERMES_DASHBOARD_SESSION_TOKEN="$tok" \
    "$VENV_HERMES" mobile-pair --url "$url" --device-token \
    || { say "CLI mobile-pair failed; manual pairing —"; echo "  URL:   $url"; echo "  Token: $tok"; }
}

case "${1:-}" in
  install)   cmd_install ;;
  start)     cmd_start ;;
  stop)      cmd_stop ;;
  restart)   cmd_restart ;;
  status)    cmd_status ;;
  uninstall) cmd_uninstall ;;
  token)     cmd_token ;;
  pair)      cmd_pair ;;
  logs)      cmd_logs ;;
  *) echo "usage: $0 {install|start|stop|restart|status|uninstall|token|pair|logs}" >&2; exit 2 ;;
esac
