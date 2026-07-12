#!/bin/zsh
set -euo pipefail

# STR-713 / STR-1021 same-process provider-key survival harness.
# Builds the iOS app through scripts/ios-build.sh, launches an iPad simulator
# with DEBUG-only seeded Settings > Model Provider data, types an unsaved
# provider key, then flips regular -> compact -> regular in the SAME PROCESS
# via simctl openurl. No host input devices are used.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HERMES_LOOP_DIR="${HERMES_LOOP_DIR:-/Users/abbhinnav/Developer/products/hermes-loop}"
SIM_UI="${SIM_UI:-/Users/abbhinnav/Developer/products/hermes-loop/scripts/sim-ui.sh}"
UDID="${UDID:-}"
OUT_DIR="${OUT_DIR:-}"
BUNDLE_ID="${BUNDLE_ID:-ai.hermes.app}"
EXPECTED_KEY="${EXPECTED_KEY:-sk-test-691}"
SIM_RUNTIME="${SIM_RUNTIME:-iOS 26.5}"
select_udid() {
  local runtime="$1"
  xcrun simctl list devices available | awk -v runtime="$runtime" '
    $0 ~ "^-- " runtime " --" { in_runtime = 1; next }
    /^-- / { in_runtime = 0; next }
    in_runtime && /iPad Pro 13-inch \(M5\)/ && /Shutdown/ {
      split($0, parts, /[()]/);
      if (length(parts[4]) == 36) { print parts[4]; exit }
    }
  '
}

if [[ -z "$UDID" ]]; then
  UDID="$(select_udid "$SIM_RUNTIME")"
fi
if [[ -z "$UDID" ]]; then
  # Fallback for environments that differ from the expected 26.5 OS pairing.
  UDID="$(xcrun simctl list devices available | awk '
    /iPad Pro 13-inch \(M5\)/ && /Shutdown/ {
      split($0, parts, /[()]/);
      if (length(parts[4]) == 36) { print parts[4]; exit }
    }
  ')"
fi
if [[ -z "$UDID" ]]; then
  # Last resort for retrying after a failed run left all matching sims booted.
  UDID="$(xcrun simctl list devices available | awk '
    /iPad Pro 13-inch \(M5\)/ {
      split($0, parts, /[()]/);
      if (length(parts[4]) == 36) { print parts[4]; exit }
    }
  ')"
fi
if [[ -z "$UDID" ]]; then
  echo "ERROR: no available iPad Pro 13-inch (M5) simulator found; set UDID=..." >&2
  exit 2
fi

if [[ ! -x "$SIM_UI" ]]; then
  echo "ERROR: sim-ui helper not executable at $SIM_UI (set SIM_UI=...)" >&2
  exit 2
fi

if [[ -z "$OUT_DIR" ]]; then
  stamp="$(date +%Y%m%d-%H%M%S)"
  OUT_DIR="$HERMES_LOOP_DIR/work-products/STR-713-provider-survival/$stamp"
fi
mkdir -p "$OUT_DIR"
LOG="$OUT_DIR/run.log"

exec > >(tee "$LOG") 2>&1

echo "== STR-713 provider-key survival evidence =="
echo "root=$ROOT_DIR"
echo "udid=$UDID"
echo "out=$OUT_DIR"
echo

cd "$ROOT_DIR"
scripts/ios-build.sh build \
  -scheme HermesMobile \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=26.5'

APP="$ROOT_DIR/apps/ios/.derivedData/Build/Products/Debug-iphonesimulator/HermesMobile.app"
if [[ ! -d "$APP" ]]; then
  echo "ERROR: built app not found at $APP" >&2
  exit 3
fi

echo "== boot/install/launch =="
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl uninstall "$UDID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install "$UDID" "$APP"
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true

recording="$OUT_DIR/provider-key-survival.mp4"
"$SIM_UI" "$UDID" record "$recording" &
record_pid=$!
cleanup() {
  if kill -0 "$record_pid" 2>/dev/null; then
    kill -INT "$record_pid" 2>/dev/null || true
    wait "$record_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

SIMCTL_CHILD_HERMES_UITEST_SEED=demo \
SIMCTL_CHILD_HERMES_UITEST_SIZE_CLASS=regular \
SIMCTL_CHILD_HERMES_UITEST_PROVIDER_KEY_SURVIVAL=1 \
  xcrun simctl launch "$UDID" "$BUNDLE_ID" --hermes-uitest-provider-key-survival
sleep 3

# First custom-scheme open after install can show iOS's "Open in Hermes Agent?"
# confirmation. Clear that prompt before entering unsaved form state so the
# later size-class flips are delivered directly to the same running process.
xcrun simctl openurl "$UDID" hermesapp://debug/size-class/regular
SIM_UI_RETRIES=1 "$SIM_UI" "$UDID" passthrough tap --label Open --wait-timeout 5 || true
sleep 1

"$SIM_UI" "$UDID" shot "$OUT_DIR/01-regular-shell.png"

echo "== open Settings > Model Provider > OpenAI key field =="
"$SIM_UI" "$UDID" passthrough tap --id settingsAvatar --wait-timeout 15
sleep 1
"$SIM_UI" "$UDID" shot "$OUT_DIR/02-settings-open.png"
"$SIM_UI" "$UDID" describe > "$OUT_DIR/02-settings-open.ax.txt"
grep -F "Model Provider" "$OUT_DIR/02-settings-open.ax.txt"
"$SIM_UI" "$UDID" passthrough tap --id settingsModelProvider --wait-timeout 15
"$SIM_UI" "$UDID" passthrough tap --id providerRow-openai --wait-timeout 15
"$SIM_UI" "$UDID" passthrough tap --id providerKeyField --wait-timeout 15
"$SIM_UI" "$UDID" type "$EXPECTED_KEY"
sleep 1
"$SIM_UI" "$UDID" shot "$OUT_DIR/03-key-before-compact.png"
"$SIM_UI" "$UDID" describe > "$OUT_DIR/03-key-before-compact.ax.txt"
grep -F "$EXPECTED_KEY" "$OUT_DIR/03-key-before-compact.ax.txt"

echo "== flip regular -> compact in process =="
xcrun simctl openurl "$UDID" hermesapp://debug/size-class/compact
sleep 2
"$SIM_UI" "$UDID" shot "$OUT_DIR/04-key-after-compact.png"
"$SIM_UI" "$UDID" describe > "$OUT_DIR/04-key-after-compact.ax.txt"
grep -F "$EXPECTED_KEY" "$OUT_DIR/04-key-after-compact.ax.txt"

echo "== flip compact -> regular in process =="
xcrun simctl openurl "$UDID" hermesapp://debug/size-class/regular
sleep 2
"$SIM_UI" "$UDID" shot "$OUT_DIR/05-key-after-regular.png"
"$SIM_UI" "$UDID" describe > "$OUT_DIR/05-key-after-regular.ax.txt"
grep -F "$EXPECTED_KEY" "$OUT_DIR/05-key-after-regular.ax.txt"

cleanup
trap - EXIT

cat > "$OUT_DIR/README.md" <<EOF
# STR-713 Provider-Key Survival Evidence

- Harness: \`scripts/ios-provider-key-survival-evidence.sh\`
- Simulator: \`$UDID\`
- Dummy unsaved key: \`$EXPECTED_KEY\`
- Sequence: regular launch -> Settings > Model Provider -> OpenAI key field -> type key without Save -> compact deep link -> regular deep link
- Assertion: each \`*.ax.txt\` file contains \`$EXPECTED_KEY\` after the branch flip.
- Recording: \`provider-key-survival.mp4\`
- Log: \`run.log\`
EOF

echo
echo "PASS: same-process provider key survived regular -> compact -> regular"
echo "artifacts=$OUT_DIR"
