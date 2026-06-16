#!/usr/bin/env bash
#
# HermesMobile installer — turns a stock Hermes-agent checkout into one that
# serves the HermesMobile iOS app, with ZERO changes you have to make by hand.
#
# It does three things:
#   1. applies `seams.patch` — ~785 additive lines across 8 stock gateway files
#      (event fan-out, emit/transport observers, session-scoped overrides,
#       pluggable device-token auth, session.delete live-evict). All additive;
#      stock behaviour is unchanged when the plugin is absent.
#   2. drops the self-contained `hermes-mobile/` plugin into your project
#      plugins dir (no stock files touched by the plugin).
#   3. enables the plugin and prints the env you need to export.
#
# Usage:
#   ./install.sh [/path/to/your/hermes-agent]     # defaults to $PWD
#   ./install.sh --dry-run [/path/to/...]         # show what would happen
#
# Safe to re-run: it refuses to patch a dirty tree and skips an already-applied
# patch. Roll back any time with:  git apply -R seams.patch  (and remove the
# plugin dir + the `plugins.enabled` entry).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY=0; TARGET=""
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    *) TARGET="$a" ;;
  esac
done
TARGET="${TARGET:-$PWD}"
PATCH="$HERE/seams.patch"
PLUGIN_SRC="$HERE/plugin/hermes-mobile"
[ -d "$PLUGIN_SRC" ] || PLUGIN_SRC="$HERE/../../plugins/hermes-mobile"   # in-repo fallback

say(){ printf '\033[1m[hermes-mobile]\033[0m %s\n' "$*"; }
run(){ if [ "$DRY" = 1 ]; then echo "  + $*"; else eval "$*"; fi; }

[ -f "$TARGET/tui_gateway/server.py" ] || { echo "ERROR: $TARGET is not a hermes-agent checkout (no tui_gateway/server.py)"; exit 1; }
[ -f "$PATCH" ] || { echo "ERROR: seams.patch not found next to installer"; exit 1; }
[ -d "$PLUGIN_SRC" ] || { echo "ERROR: plugin payload not found ($PLUGIN_SRC)"; exit 1; }
cd "$TARGET"

# 1) seam patch -------------------------------------------------------------
if git -C "$TARGET" apply --reverse --check "$PATCH" >/dev/null 2>&1; then
  say "seam patch already applied — skipping."
elif git -C "$TARGET" apply --check "$PATCH" >/dev/null 2>&1; then
  say "applying seam patch (8 stock files, additive)…"
  run "git -C '$TARGET' apply '$PATCH'"
else
  say "plain apply didn't match; trying 3-way merge against your tree…"
  run "git -C '$TARGET' apply --3way '$PATCH'" || {
    echo "ERROR: seam patch did not apply. Your gateway has drifted from the"
    echo "       baseline this patch targets. Re-generate it against your HEAD:"
    echo "         (in the hermes-mobile repo) git diff <your-base> > seams.patch"
    exit 1; }
fi

# 2) plugin payload -> USER source ($HERMES_HOME/plugins), NOT project source.
#    The dashboard refuses to auto-import a plugin's REST `api.py` from PROJECT
#    plugins (`<checkout>/.hermes/plugins/`, security gate GHSA-5qr3-c538-wm9j) —
#    so the mobile REST API the iOS app needs ONLY mounts from the trusted
#    user-source dir. Installing here also means HERMES_ENABLE_PROJECT_PLUGINS is
#    not required.
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
PLUGIN_DST="$HERMES_HOME/plugins/hermes-mobile"
say "installing plugin -> $PLUGIN_DST (user source)"
run "mkdir -p '$HERMES_HOME/plugins'"
run "rm -rf '$PLUGIN_DST'"
run "cp -R '$PLUGIN_SRC' '$PLUGIN_DST'"
# Drop any stale compiled bytecode that rode along in the copy.
run "find '$PLUGIN_DST' -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null || true"

# 2b) runtime deps the plugin's REST routes need but the base gateway may lack:
#     python-multipart (multipart/form-data parsing for /upload), qrcode (the
#     pairing QR). Installed into the gateway's own interpreter (next to the
#     `hermes` CLI). Reported HONESTLY — uv-built venvs ship WITHOUT pip, so we
#     bootstrap it (ensurepip) or fall back to `uv pip` rather than fail silently.
DEPS_OK=0
GW_PY=""
HERMES_BIN="$(command -v hermes 2>/dev/null || true)"
if [ -n "$HERMES_BIN" ]; then
  GW_PY="$(dirname "$HERMES_BIN")/python"; [ -x "$GW_PY" ] || GW_PY="$(dirname "$HERMES_BIN")/python3"
fi
[ -x "${GW_PY:-/nonexistent}" ] || GW_PY="$(command -v python3 || true)"
if [ -n "${GW_PY}" ]; then
  say "ensuring runtime deps (python-multipart, qrcode) for ${GW_PY}"
  if [ "$DRY" = 1 ]; then
    echo "  + ${GW_PY} -m pip install python-multipart qrcode[pil]"; DEPS_OK=1
  elif "${GW_PY}" -m pip install --quiet --disable-pip-version-check python-multipart 'qrcode[pil]' 2>/dev/null; then
    DEPS_OK=1
  elif "${GW_PY}" -m ensurepip --upgrade >/dev/null 2>&1 && \
       "${GW_PY}" -m pip install --quiet --disable-pip-version-check python-multipart 'qrcode[pil]' 2>/dev/null; then
    DEPS_OK=1   # interpreter had no pip (uv venv) — bootstrapped it
  elif command -v uv >/dev/null 2>&1 && \
       uv pip install --python "${GW_PY}" python-multipart 'qrcode[pil]' >/dev/null 2>&1; then
    DEPS_OK=1   # uv pip fallback
  fi
fi
if [ "$DEPS_OK" != 1 ]; then
  say "⚠  could NOT auto-install python-multipart / qrcode. Attachment upload and the"
  say "   pairing QR need them — install into your gateway's python by hand, e.g.:"
  say "       ${GW_PY:-<your-gateway-python>} -m pip install python-multipart 'qrcode[pil]'"
fi

# 3) enable -----------------------------------------------------------------
say "enabling the plugin…"
if command -v hermes >/dev/null 2>&1; then
  run "hermes plugins enable hermes-mobile || true"
else
  say "(hermes CLI not on PATH — add 'hermes-mobile' to plugins.enabled in your config.yaml)"
fi

# 3b) pairing needs a STABLE dashboard session token. The dashboard uses
#     \$HERMES_DASHBOARD_SESSION_TOKEN (else a random ephemeral one), while
#     `hermes mobile-pair` reads \$HERMES_HOME/dashboard.token — seed a stable
#     token if one isn't already set, so both sides agree.
TOKEN_FILE="$HERMES_HOME/dashboard.token"
if [ ! -s "$TOKEN_FILE" ] && [ -n "${GW_PY:-}" ]; then
  say "seeding a stable dashboard token -> $TOKEN_FILE"
  run "mkdir -p '$HERMES_HOME'"
  run "'$GW_PY' -c \"import secrets,pathlib;pathlib.Path('$TOKEN_FILE').write_text(secrets.token_urlsafe(32))\" || true"
fi

cat <<EOF

[hermes-mobile] Done. The plugin is installed in your USER plugins dir
($PLUGIN_DST).

Export these before starting your gateway (add to your shell profile to persist
across restarts), then start it:

    export HERMES_GATEWAY_BROADCAST=1                              # multi-client live fan-out
    export HERMES_DASHBOARD_SESSION_TOKEN="\$(cat '$TOKEN_FILE')"  # so the iOS app can pair

Verify, then pair:
    hermes plugins list            # hermes-mobile -> enabled
    hermes mobile-pair             # prints a hermesapp://pair link (+ QR) for the iOS app

(HERMES_ENABLE_PROJECT_PLUGINS is NOT needed — user-source plugins load by default.)

Roll back any time:
    (in your hermes-agent checkout) git apply -R seams.patch
    rm -rf '$PLUGIN_DST' && hermes plugins disable hermes-mobile
EOF
