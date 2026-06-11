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

# 2) plugin payload ---------------------------------------------------------
PLUGIN_DST="$TARGET/.hermes/plugins/hermes-mobile"
say "installing plugin -> $PLUGIN_DST"
run "mkdir -p '$TARGET/.hermes/plugins'"
run "rm -rf '$PLUGIN_DST'"
run "cp -R '$PLUGIN_SRC' '$PLUGIN_DST'"

# 3) enable -----------------------------------------------------------------
say "enabling the plugin…"
if command -v hermes >/dev/null 2>&1; then
  run "hermes plugins enable hermes-mobile || true"
else
  say "(hermes CLI not on PATH — add 'hermes-mobile' to plugins.enabled in your config.yaml)"
fi

cat <<'EOF'

[hermes-mobile] Done. Add these to your gateway environment, then restart it:

    export HERMES_ENABLE_PROJECT_PLUGINS=1   # discover .hermes/plugins/
    export HERMES_GATEWAY_BROADCAST=1        # multi-client live fan-out

Verify after restart:
    hermes plugins list            # hermes-mobile -> enabled
    hermes mobile-pair             # prints a QR / hermesapp://pair link for the iOS app

Roll back any time:
    git apply -R seams.patch && rm -rf .hermes/plugins/hermes-mobile
    hermes plugins disable hermes-mobile
EOF
