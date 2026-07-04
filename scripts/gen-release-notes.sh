#!/bin/bash
# gen-release-notes.sh — generate human-readable release notes for a build from the
# merges since the last ship. Groups PRs into Fixed / New / Improved, keeps ABH-refs,
# and filters to USER-VISIBLE changes (server-only infra noted in one summary line).
#
# Usage: gen-release-notes.sh <build-number> [output-file]
# Writes markdown section to stdout (and file if given). Also prepends to RELEASE_NOTES.md.
set -uo pipefail
BUILD="${1:?build number required}"
OUT="${2:-/tmp/notes-$BUILD.txt}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

LAST_SHIP_SHA=$(git log -1 --grep="ship: TestFlight build" --format="%H" 2>/dev/null)
RANGE="${LAST_SHIP_SHA:+$LAST_SHIP_SHA..}HEAD"

python3 - "$BUILD" "$RANGE" <<'PY' > "$OUT"
import subprocess, sys, re, datetime
build, rng = sys.argv[1], sys.argv[2]
log = subprocess.check_output(['git','log','--format=%s',rng or 'HEAD~20..HEAD'], text=True).splitlines()
fixed, new, improved, infra = [], [], [], 0
for s in log:
    if s.startswith('ship:') or s.startswith('chore') or s.startswith('loops:'):
        continue
    ref = (re.search(r'ABH-\d+', s) or [None]) and (re.search(r'ABH-\d+', s).group(0) if re.search(r'ABH-\d+', s) else '')
    # strip conventional prefix + PR number for readability
    clean = re.sub(r'^\w+\([^)]*\):\s*|^\w+:\s*', '', s)
    clean = re.sub(r'\s*\(#\d+\)$', '', clean)
    clean = re.sub(r'^ABH-\d+:?\s*', '', clean)
    line = f"- {clean[0].upper()+clean[1:]}" + (f" ({ref})" if ref else "")
    low = s.lower()
    user_visible = ('ios' in low or 'mobile' in low or 'widget' in low or 'app' in low) and 'infra' not in low
    if not user_visible:
        infra += 1; continue
    if low.startswith('fix'): fixed.append(line)
    elif low.startswith('feat'): new.append(line)
    else: improved.append(line)
today = datetime.date.today().isoformat()
# theme header (Straits naming, Abhi 2026-07-02): read current-theme.txt if present
theme_name, theme_focus = '', ''
try:
    for ln in open('docs/autonomous/current-theme.txt'):
        if ln.startswith('name='): theme_name = ln.split('=',1)[1].strip()
        if ln.startswith('focus='): theme_focus = ln.split('=',1)[1].strip()
except FileNotFoundError:
    pass
if theme_name:
    print(f"Build {build} — \"{theme_name}\" — {today}")
    print(theme_focus.split(' — ')[0] if ' — ' in theme_focus else theme_focus)
else:
    print(f"Build {build} — {today}")
if new:
    print("\nWHAT'S NEW"); [print(x) for x in new]
if fixed:
    print("\nFIXED"); [print(x) for x in fixed]
if improved:
    print("\nIMPROVED"); [print(x) for x in improved]
if new or fixed:
    print("\nWORTH TRYING")
    # heuristics: surface the most user-facing item as a try-this
    top = (new + fixed)[:3]
    for t in top: print(t.replace('- ', '- Try: ', 1))
if infra:
    print(f"\n(+{infra} server-side/infra changes active on the gateway, no app UI change)")
PY

# prepend to the rolling changelog
if [ -f RELEASE_NOTES.md ]; then
  { cat "$OUT"; echo; echo "---"; echo; cat RELEASE_NOTES.md; } > /tmp/rn_merged.md && mv /tmp/rn_merged.md RELEASE_NOTES.md
else
  { echo "# Hermes Mobile — Release Notes"; echo; cat "$OUT"; } > RELEASE_NOTES.md
fi
cat "$OUT"
