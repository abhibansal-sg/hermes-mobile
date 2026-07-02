#!/usr/bin/env bash
#
# staging-gateway.sh — provision + manage an ISOLATED developer gateway for the
# Hermes Mobile app, fully separate from the user's live :9119 dashboard.
#
#   * HERMES_HOME = ~/Developer/.hermes-staging  (own data/sessions/token/config —
#     ZERO overlap with ~/.hermes; the live gateway is never touched).
#   * Port        = 9300  (clean, separate from live :9119 + the old :9123 rig).
#   * Code        = THIS valencia checkout's source (trunk + the HermesMobile
#     plugin + seams), run via this checkout's .venv. So `git pull` here updates
#     the staging gateway's behaviour; the plugin is SYMLINKED (not copied) so plugin
#     edits in the repo are live immediately.
#   * Service     = launchd (RunAtLoad + KeepAlive) so it auto-starts on login
#     and survives reboot — managed like the live one, but isolated.
#
# Usage:
#   scripts/staging-gateway.sh install     # one-time: provision HOME + plugin + token + launchd
#   scripts/staging-gateway.sh start|stop|restart|status
#   scripts/staging-gateway.sh token       # print the staging pairing token
#   scripts/staging-gateway.sh pair        # print a hermesapp://pair link for the iOS app
#   scripts/staging-gateway.sh uninstall   # remove the launchd job (keeps the data dir)
#   scripts/staging-gateway.sh logs        # tail the staging gateway log
#
# SAFETY: this script only ever touches ~/Developer/.hermes-staging and its own
# launchd label (ai.hermes.staging-gateway). It NEVER touches ~/.hermes or the
# ai.hermes.dashboard service.
set -euo pipefail

# --- config (the canonical staging-gateway facts; update here if relocating) ------
# This checkout (the staging gateway runs THIS source via THIS venv).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# STAGING_HOME defaults to an IN-TREE .hermes-staging so the whole dev environment — code,
# gateway data, sessions, token — lives under ONE root (this worktree) and travels
# with any future move. Override with HERMES_STAGING_HOME if you ever want it elsewhere.
STAGING_HOME="${HERMES_STAGING_HOME:-$REPO_ROOT/.hermes-staging}"
STAGING_PORT="${HERMES_STAGING_PORT:-9300}"
STAGING_HOST="127.0.0.1"
LABEL="ai.hermes.staging-gateway"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
VENV_HERMES="$REPO_ROOT/.venv/bin/hermes"
VENV_PY="$REPO_ROOT/.venv/bin/python"
PLUGIN_SRC="$REPO_ROOT/plugins/hermes-mobile"
SERVICE_WRAPPER="$STAGING_HOME/bin/staging-gateway-service"
TOKEN_FILE="$STAGING_HOME/dashboard.token"
LOG="$STAGING_HOME/logs/staging-gateway.log"
ERRLOG="$STAGING_HOME/logs/staging-gateway.error.log"

say(){ printf '\033[1m[staging-gateway]\033[0m %s\n' "$*"; }
die(){ printf '\033[1m[staging-gateway] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# Guard: never let STAGING_HOME resolve to the live ~/.hermes.
[ "$STAGING_HOME" = "$HOME/.hermes" ] && die "STAGING_HOME must NOT be ~/.hermes (that's the LIVE gateway)."

cmd_install() {
  [ -x "$VENV_HERMES" ] || die "no hermes at $VENV_HERMES — run 'uv sync' / install the repo venv first."
  [ -d "$PLUGIN_SRC" ]  || die "plugin source missing at $PLUGIN_SRC"

  # Apply the hermes-mobile broadcast SEAMS to the working tree (idempotent).
  # The branch must STAY stock-clean, so the S1a (_EVENT_FANOUT_SUBSCRIBERS)
  # and S2 (_EMIT_OBSERVERS) hooks ride as scripts/seams.patch instead of a
  # commit. --check first: if it passes the seams aren't applied yet → apply;
  # if it fails (already applied OR would conflict) → skip. Never commits.
  # The seams are pure no-ops on stock (empty list + guarded loop) so a stock
  # gateway behaves identically when the plugin isn't loaded.
  local seams="$REPO_ROOT/scripts/seams.patch"
  if [ -f "$seams" ]; then
    if git -C "$REPO_ROOT" apply --check "$seams" >/dev/null 2>&1; then
      git -C "$REPO_ROOT" apply "$seams" && say "seams applied to working tree (uncommitted): $seams"
    else
      say "seams already applied (or patch context drifted) — left as-is: $seams"
    fi
  else
    say "⚠ $seams missing — broadcast seams NOT applied (multi-client mirror will be dead)"
  fi

  say "provisioning isolated staging HOME at $STAGING_HOME"
  mkdir -p "$STAGING_HOME"/{bin,logs,plugins,sessions}

  # Plugin -> SYMLINK into the staging HOME's user-source plugin dir (live edits).
  # (The dashboard only auto-mounts a plugin's REST api.py from the user-source
  #  HERMES_HOME/plugins dir — GHSA-5qr3-c538-wm9j — so this is the correct home.)
  local plugin_dst="$STAGING_HOME/plugins/hermes-mobile"
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

  # Stable staging pairing token (own, never the live one).
  if [ ! -s "$TOKEN_FILE" ]; then
    "$VENV_PY" -c "import secrets,pathlib; pathlib.Path('$TOKEN_FILE').write_text(secrets.token_urlsafe(32))"
    chmod 600 "$TOKEN_FILE"
    say "seeded staging pairing token -> $TOKEN_FILE"
  else
    say "staging token already present -> $TOKEN_FILE"
  fi

  # Enable the plugin in the staging HOME's config (idempotent).
  HERMES_HOME="$STAGING_HOME" "$VENV_HERMES" plugins enable hermes-mobile >/dev/null 2>&1 \
    && say "plugin enabled in staging config" \
    || say "(could not auto-enable via CLI — it loads from the user-source dir regardless)"

  # The launchd service wrapper (token + env live here, never in the plist).
  cat > "$SERVICE_WRAPPER" <<WRAP
#!/bin/zsh
# ISOLATED Hermes STAGING gateway — separate from the live :9119 dashboard.
# Generated by scripts/staging-gateway.sh; edit the source script, then re-install.
set -euo pipefail
export HERMES_HOME="$STAGING_HOME"
export HERMES_DASHBOARD_SESSION_TOKEN="\$(head -n1 "$TOKEN_FILE" | tr -d '[:space:]')"
export HERMES_GATEWAY_BROADCAST=1          # multi-client live mirroring (desktop<->phone)
export PATH="$REPO_ROOT/.venv/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
ulimit -n 4096 2>/dev/null || true
# No APNs here by default: push needs the app publisher's key; dev relies on
# in-app delivery. (Add HERMES_PUSH_ENABLED + HERMES_APNS_* if you want to test
# real push against a development-signed local build.)
exec "$VENV_HERMES" dashboard --no-open --skip-build --host $STAGING_HOST --port $STAGING_PORT
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
    <key>WorkingDirectory</key>   <string>$STAGING_HOME</string>
    <key>StandardOutPath</key>    <string>$LOG</string>
    <key>StandardErrorPath</key>  <string>$ERRLOG</string>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
PLISTEOF
  say "launchd plist -> $PLIST"
  cmd_start
  say "done. Dev gateway on http://$STAGING_HOST:$STAGING_PORT (HERMES_HOME=$STAGING_HOME)"
}

cmd_start()  { launchctl unload "$PLIST" 2>/dev/null || true; launchctl load "$PLIST"; sleep 1; cmd_status; }
cmd_stop()   { launchctl unload "$PLIST" 2>/dev/null && say "stopped" || say "(not loaded)"; }
cmd_restart(){ cmd_stop; cmd_start; }
cmd_uninstall(){ launchctl unload "$PLIST" 2>/dev/null || true; rm -f "$PLIST"; say "launchd job removed (data dir $STAGING_HOME kept)"; }
cmd_token()  { [ -s "$TOKEN_FILE" ] && head -n1 "$TOKEN_FILE" || die "no token; run install"; }
cmd_logs()   { tail -n 40 -f "$LOG" "$ERRLOG"; }

cmd_status() {
  if curl -fsS --max-time 3 "http://$STAGING_HOST:$STAGING_PORT/health" >/dev/null 2>&1; then
    say "UP   — http://$STAGING_HOST:$STAGING_PORT (HERMES_HOME=$STAGING_HOME)"
  else
    say "DOWN — http://$STAGING_HOST:$STAGING_PORT (check: scripts/staging-gateway.sh logs)"
  fi
  launchctl list 2>/dev/null | grep -q "$LABEL" && say "launchd: loaded" || say "launchd: NOT loaded"
}

cmd_pair() {
  local tok url; tok="$(cmd_token)"; url="http://$STAGING_HOST:$STAGING_PORT"
  # --url pins the staging gateway (default auto-detect resolves to the live Tailscale
  # Serve setup). --device-token mints a revocable per-device token via the plugin.
  HERMES_HOME="$STAGING_HOME" HERMES_DASHBOARD_SESSION_TOKEN="$tok" \
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
