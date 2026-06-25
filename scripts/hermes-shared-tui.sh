#!/usr/bin/env bash
# hermes-shared-tui.sh — launch the desktop TUI ATTACHED to the shared :9119 dashboard
# gateway, so desktop + iOS share the same live sessions (ABH-185, Option A: config-only,
# ZERO stock-core edits).
#
# WHY: by default `hermes --tui` spawns its OWN local gateway (gatewayClient.ts:521), so
# the phone never sees desktop sessions. The stock client already supports attaching when
# HERMES_TUI_GATEWAY_URL is set (gatewayClient.ts:34 → startAttachedGateway). This wrapper
# just sets that var from the dashboard's own connection.json, then execs the real TUI.
#
# REVERSIBLE / OPT-IN: this changes nothing in your shell rc or the stock code. Run this
# instead of `hermes --tui` when you WANT shared mode; run plain `hermes --tui` for the old
# isolated-local behavior. No daemon, no persistence.
#
#   scripts/hermes-shared-tui.sh            # attach + launch the TUI (passes extra args through)
#   scripts/hermes-shared-tui.sh --print    # just print the attach URL it would use (redacted), don't launch
#
# Source of truth for URL+token: ~/Library/Application Support/Hermes/connection.json
# (what the dashboard itself wrote). Falls back to ~/.hermes/dashboard.token + :9119.
set -uo pipefail

CONN="$HOME/Library/Application Support/Hermes/connection.json"
TOKEN_FILE="$HOME/.hermes/dashboard.token"
DEFAULT_BASE="http://127.0.0.1:9119"

die(){ printf 'hermes-shared-tui: %s\n' "$*" >&2; exit 1; }

# Resolve base URL + token from connection.json (preferred) or the token file.
base="$DEFAULT_BASE"; token=""
if [ -f "$CONN" ] && command -v python3 >/dev/null 2>&1; then
  read -r base token < <(python3 - "$CONN" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    r = d.get("remote", {}) or {}
    url = r.get("url") or "http://127.0.0.1:9119"
    tok = ((r.get("token") or {}).get("value")) or ""
    print(url, tok)
except Exception:
    print("http://127.0.0.1:9119", "")
PY
  )
fi
[ -z "$token" ] && [ -f "$TOKEN_FILE" ] && token="$(head -n1 "$TOKEN_FILE" | tr -d '[:space:]')"
[ -z "$token" ] && die "no dashboard token found (connection.json / $TOKEN_FILE). Pair the desktop to the dashboard first."

# http(s)://host:port → ws(s)://host:port/api/ws?token=…
ws_base="$(printf '%s' "$base" | sed -E 's#^http://#ws://#; s#^https://#wss://#')"
attach_url="${ws_base%/}/api/ws?token=${token}"
redacted="${ws_base%/}/api/ws?token=${token:0:6}…"

if [ "${1:-}" = "--print" ]; then
  echo "HERMES_TUI_GATEWAY_URL=$redacted"
  echo "(desktop would ATTACH to the shared dashboard at $base; sessions shared live with iOS)"
  exit 0
fi

# Locate the real hermes CLI (don't recurse into a shell alias).
HERMES_BIN="$(command -v hermes || echo "$HOME/.hermes/hermes-agent/venv/bin/hermes")"
[ -x "$HERMES_BIN" ] || die "hermes CLI not found (tried PATH + ~/.hermes/hermes-agent/venv/bin/hermes)"

echo "hermes-shared-tui: attaching desktop TUI to the shared dashboard ($base) — sessions shared live with iOS." >&2
echo "  (run plain 'hermes --tui' instead for the old isolated-local gateway.)" >&2
exec env HERMES_TUI_GATEWAY_URL="$attach_url" "$HERMES_BIN" --tui "$@"
