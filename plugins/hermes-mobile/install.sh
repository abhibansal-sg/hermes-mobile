#!/bin/sh
# install.sh — install the hermes-mobile plugin into a stock Hermes.
#
# Usage (two-line install):
#   curl -fsSL https://raw.githubusercontent.com/abhibansal-sg/hermes-mobile/environment-and-workflows-overview/plugins/hermes-mobile/install.sh | sh
#   hermes mobile-pair
#
# What it does:
#   1. Copies plugins/hermes-mobile/ into ~/.hermes/plugins/hermes-mobile/
#      (the stock plugin discovery path — no core patch, no forked binary).
#   2. Prints next steps (restart gateway, pair the phone).
#
# Idempotent: re-running updates the plugin in place.
set -eu

REPO="${HERMES_MOBILE_REPO:-abhibansal-sg/hermes-mobile}"
BRANCH="${HERMES_MOBILE_BRANCH:-environment-and-workflows-overview}"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
DEST="$HERMES_HOME/plugins/hermes-mobile"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "hermes-mobile plugin installer"
echo "  repo:   $REPO@$BRANCH"
echo "  target: $DEST"

# Fetch just the plugin directory via the GitHub tarball (no git required).
curl -fsSL "https://codeload.github.com/$REPO/tar.gz/refs/heads/$BRANCH" \
  | tar -xz -C "$TMP" --strip-components=1 "*/plugins/hermes-mobile" 2>/dev/null \
  || { echo "ERROR: could not fetch plugins/hermes-mobile from $REPO@$BRANCH" >&2; exit 1; }

SRC="$TMP/plugins/hermes-mobile"
[ -d "$SRC" ] || { echo "ERROR: plugin dir missing from archive" >&2; exit 1; }

mkdir -p "$HERMES_HOME/plugins"
rm -rf "$DEST"
cp -R "$SRC" "$DEST"
# Never ship test/dev artifacts into the live plugin dir.
rm -rf "$DEST/tests" "$DEST/__pycache__" 2>/dev/null || true

echo ""
echo "Installed. Next steps:"
echo "  1. Restart your gateway:  hermes serve   (or hermes dashboard)"
echo "  2. Pair your phone:       hermes mobile-pair"
