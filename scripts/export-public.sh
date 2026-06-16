#!/usr/bin/env bash
#
# export-public.sh — deterministic public-export pipeline for the `hermes-ios`
# repo. Run from the fork root. Builds a SANITIZED staging tree at
# /tmp/hermes-ios-export/ by ALLOWLIST (only the iOS app, the mobile gateway
# plugin, and the self-host installer go public) plus deterministic SCRUBS
# (internal task IDs, review-round IDs, deploy specifics, team IDs, private
# mirror slug). It NEVER touches the fork's tracked files — every scrub runs on
# the COPIED tree only. It does NOT create or push any GitHub repo.
#
# Idempotent: wipes and rebuilds the staging dir on every run.
#
# Usage:
#   scripts/export-public.sh                 # build + scrub + self-verify
#   OUT=/some/dir scripts/export-public.sh   # override the staging dir
#
set -euo pipefail

# --- locate the fork root (this script lives in <root>/scripts) ----------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT="${OUT:-/tmp/hermes-ios-export}"

cd "$ROOT"
# `.git` is a directory in a normal clone, a file in a worktree — accept both.
if [ ! -e .git ] || ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "ERROR: must run from the fork root (not a git work tree: $ROOT)" >&2
  exit 1
fi

echo "== export-public =="
echo "fork root : $ROOT"
echo "staging   : $OUT"

# --- 1. ALLOWLIST: which tracked files go public -------------------------------
# Only paths matching these prefixes/files are copied. We intersect with
# `git ls-files` so untracked junk, build artifacts, and .DS_Store never leak.
#
# HermesMobileUITests is included because project.yml declares it as a build
# target with `sources: HermesMobileUITests`; omitting it would leave a dangling
# source reference. The xcodeproj + Entitlements + Info.plist + Assets are
# included so the project both regenerates (XcodeGen) and opens as-is.
ALLOW_PREFIXES=(
  "apps/ios/HermesMobile/"
  "apps/ios/HermesMobileTests/"
  "apps/ios/HermesMobileUITests/"
  "apps/ios/HermesWidgets/"
  "apps/ios/HermesShare/"
  "apps/ios/DebugBridge/"
  "apps/ios/Entitlements/"
  "apps/ios/HermesMobile.xcodeproj/"
  "plugins/hermes-mobile/"
)
ALLOW_FILES=(
  "apps/ios/project.yml"
  "apps/ios/KNOWN-ISSUES.md"
  "dist/hermes-mobile/install.sh"
  "dist/hermes-mobile/seams.patch"
  "dist/hermes-mobile/INSTALL.md"
)

# Hard exclude list — defense in depth. Even if one of the prefixes above were
# widened, these never get copied. (Most are already outside the allowlist.)
is_excluded() {
  case "$1" in
    *CONTRACT-*.md|*SHIP-TESTFLIGHT*|*SEAM-LEDGER*|*-VERDICT.md|*PARITY-*|\
    *POLISH-*|*QA-*|*F3-*|*INTERFACES.md|*CLAUDE.md|*CODEX-LANE*|\
    *CONDUCTOR-BOOTSTRAP*|*LINEAR-BACKFILL-SPEC*|*REVIEW-*|\
    *.agent-memory/*|*TESTFLIGHT-BETA-NOTES*|*ExportOptions-TestFlight.plist|\
    *__pycache__*|*.DS_Store|*.pyc)
      return 0 ;;
  esac
  return 1
}

# --- clean staging -------------------------------------------------------------
rm -rf "$OUT"
mkdir -p "$OUT"

copied=0
copy_one() {
  local rel="$1"
  is_excluded "$rel" && return 0
  [ -f "$rel" ] || return 0   # tracked but missing? skip silently
  local dst="$OUT/$rel"
  mkdir -p "$(dirname "$dst")"
  cp "$rel" "$dst"
  copied=$((copied + 1))
}

# enumerate tracked files once, filter by allowlist
while IFS= read -r rel; do
  keep=0
  for p in "${ALLOW_PREFIXES[@]}"; do
    case "$rel" in "$p"*) keep=1; break ;; esac
  done
  if [ "$keep" -eq 0 ]; then
    for f in "${ALLOW_FILES[@]}"; do
      [ "$rel" = "$f" ] && { keep=1; break; }
    done
  fi
  [ "$keep" -eq 1 ] && copy_one "$rel"
done < <(git ls-files)

# PUBLIC-README.md -> README.md at the export root
if [ -f dist/hermes-mobile/PUBLIC-README.md ]; then
  cp dist/hermes-mobile/PUBLIC-README.md "$OUT/README.md"
  copied=$((copied + 1))
fi

# LICENSE (MIT, dual copyright: Nous Research + HermesMobile) -> export root
if [ -f dist/hermes-mobile/LICENSE ]; then
  cp dist/hermes-mobile/LICENSE "$OUT/LICENSE"
  copied=$((copied + 1))
fi

echo "copied $copied files into staging"

# --- 2. SCRUBS -----------------------------------------------------------------
# All scrubs run over the COPIED tree only. Each is a perl one-liner so the
# substitution is deterministic and re-runnable. We log a per-category count of
# matched LINES before scrubbing for the verification report.
#
# We scrub text files only (skip the AppIcon.png + any binary).

# bash 3.2 has no `mapfile`; read into the array portably.
# NOTE: seams.patch is a unified git diff — it is EXCLUDED from the general
# prose scrubs + cosmetic squeeze (which would desync context/removed lines and
# break `git apply`). It gets a dedicated patch-safe pass below that edits ONLY
# `+`-prefixed added lines.
PATCH_FILE="$OUT/dist/hermes-mobile/seams.patch"
TEXT_FILES=()
while IFS= read -r f; do
  [ "$f" = "$PATCH_FILE" ] && continue
  TEXT_FILES+=("$f")
done < <(
  find "$OUT" -type f \
    ! -name '*.png' ! -name '*.jpg' ! -name '*.jpeg' ! -name '*.gif' \
    ! -name '*.pdf' ! -name '*.ico' ! -name '*.car' \
    -print | sort
)

count_hits() {  # count_hits <ERE> — counts across all text files INCL. the patch
  local pat="$1" n=0
  for f in "${TEXT_FILES[@]}" "$PATCH_FILE"; do
    [ -f "$f" ] || continue
    n=$((n + $(grep -cE "$pat" "$f" 2>/dev/null || true)))
  done
  echo "$n"
}

# Run a perl substitution across every text file.
scrub() {  # scrub <perl-expr>
  local expr="$1"
  perl -CSD -i -pe "$expr" "${TEXT_FILES[@]}"
}

echo "== scrub counts (matched lines, pre-scrub) =="

C_SLUG=$(count_hits 'ab0991-oss/hermes-mobile')
C_ABH=$(count_hits 'ABH-[0-9]')
C_R1=$(count_hits 'R1 ?#[0-9]')
C_JARGON=$(count_hits 'judge round|RIDER|SHIP-AFTER-MUSTFIX|[0-9]-lens')
C_CONTRACT=$(count_hits 'CONTRACT-[A-Za-z0-9]|SEAM-LEDGER')
C_CRON=$(count_hits 'cron_[a-f0-9]{12}_[0-9_]+')
C_DEPLOY=$(count_hits '127\.0\.0\.1:9119|:9119|:9123|live 9119|live 9123|9119-EQUIVALENT|this-branch 9123|4523965de')
C_TEAM=$(count_hits '6J4Y9NKRQ2')
C_USER=$(count_hits '/Users/abbhinnav|abhinavbansal@mac\.com')

printf '  %-22s %s\n' "private-mirror-slug" "$C_SLUG"
printf '  %-22s %s\n' "ABH-### task ids"    "$C_ABH"
printf '  %-22s %s\n' "R1 #NN review ids"   "$C_R1"
printf '  %-22s %s\n' "ai-review jargon"    "$C_JARGON"
printf '  %-22s %s\n' "CONTRACT/SEAM cites" "$C_CONTRACT"
printf '  %-22s %s\n' "real session ids"    "$C_CRON"
printf '  %-22s %s\n' "deploy specifics"    "$C_DEPLOY"
printf '  %-22s %s\n' "DEVELOPMENT_TEAM"    "$C_TEAM"
printf '  %-22s %s\n' "user path/email"     "$C_USER"

# ---- (a) private mirror slug --------------------------------------------------
scrub 's{ab0991-oss/hermes-mobile}{ab0991-oss/hermes-ios}g;'

# ---- (b) plugin.yaml author (special-case before generic ABH strip) ----------
scrub 's{^author:[ \t]*Hermes Mobile \(ABH-\d+\)[ \t]*$}{author: HermesMobile}gm;'

# ---- (c) ABH-### Linear task ids ----------------------------------------------
# Handle the common structured forms first so prose stays clean, then strip any
# residual bare token. Order matters (most specific -> generic).
scrub '
  # ID used as a clause SUBJECT: "when ABH-48 made X" -> "when a change made X"
  # (keep the connective + verb; replace the bare ID with a neutral noun so the
  # sentence still parses).
  s/\b(when|where|which|that|after|once|since|as|because)\s+ABH-\d+\s+(made|added|moved|changed|introduced|removed|landed|set|split|renamed)\b/$1 a change $2/g;
  # "(ABH-86 item 4: foo)" / "(ABH-86 item 4 foo)" -> drop the ID, keep the note
  s/\(ABH-\d+(?:\s+§?[\d.]+)?\s+(item\b)/($1/g;
  # "(ABH-87 Batch B, ...)" / "(ABH-88 §3.2)" / "(ABH-75)" -> drop whole paren
  s/\s*\(ABH-\d+(?:\s+(?:Batch\s+\w+|§?[\d.]+|RIDER(?:\s+\d+)?|judge round|follow-up|de-patch|merge semantics)?[^)]*)?\)//g;
  # "// ABH-86 item 1: foo" leading-comment -> "// foo"
  s{(//+|\#)[ \t]*ABH-\d+(?:\s+§?[\d.]+)?\s+item\s+\d+[ \t]*(?:[:.,]|\x{2014}|\x{2013}|-)?[ \t]*}{$1 }g;
  # "// ABH-83: foo" / "// ABH-159 — foo" / "// ABH-88" leading -> "// foo"
  # (explicit em/en-dash codepoints so the delimiter is always consumed).
  s{(//+|\#)[ \t]*ABH-\d+[ \t]*(?:[:.,]|\x{2014}|\x{2013}|-)?[ \t]*}{$1 }g;
  # "Stage 1 (ABH-88): resolve" -> "Stage 1: resolve"
  s/\s*\(ABH-\d+\)\s*:/:/g;
  # "per ABH-87 §3.1" / "see ABH-86" inline phrase -> drop the citation word too
  s/\s*\b(?:per|see|from|via|in)\s+ABH-\d+(?:\s+§?[\d.]+)?\b//g;
  # bare leftover "ABH-86 — " / "ABH-86: " / "ABH-86" -> remove (incl. dashes)
  s/\bABH-\d+[ \t]*(?:[:.,]|\x{2014}|\x{2013}|-)[ \t]*//g;
  s/\s*\bABH-\d+\b//g;
'

# ---- (d) R1 #NN review-round ids ----------------------------------------------
# RNUM matches the id incl. multi-refs like "#12/#21" and "#9/#42".
scrub '
  my $RNUM = qr/R1 ?\#\d+(?:[\/\#\d ]*\d)?/;
  # whole self-contained paren incl. a trailing ", Batch C" or " — note":
  #   "(R1 #30, Batch C)" -> ""   "(R1 #92)" -> ""   "(R1 #29 — note)" -> ""
  s/\s*\($RNUM(?:\s*[,—–-][^()]*)?\)//g;
  # leading-comment id (optionally opening an UNCLOSED paren) + its delimiter:
  #   "// (R1 #29 — previously" -> "// previously"   "// R1 #66: foo" -> "// foo"
  s{(//+|\#)[ \t]*\(?$RNUM[ \t]*(?:[:.,]|\x{2014}|\x{2013}|-)?[ \t]*}{$1 }g;
  # "MARK: - R1 #92 invariant" -> "MARK: - invariant"
  s/$RNUM\s+(invariant|class|generation|catch-side)/$1/g;
  # "the R1 #17 class" -> "the class"
  s/\bthe $RNUM\s+/the /g;
  # any bare survivor
  s/\s*$RNUM//g;
'

# ---- (e) internal AI-review jargon --------------------------------------------
scrub '
  s/\s*\(\s*RIDER(?:\s+\d+)?\s*\)//g;       # "(RIDER)" / "(RIDER 4)" -> drop
  s/\bRIDER\s+\d+\b//g;                       # "RIDER 4" -> drop
  s/\bRIDER\b//g;                              # bare RIDER
  s/\s*\bjudge round\b//g;                     # "judge round" -> drop
  s/\bSHIP-AFTER-MUSTFIX\b//g;
  s/\b[0-9]-lens(?:\s+(?:workflow|review))?\b//g;
'

# ---- (f) dangling CONTRACT-*.md / SEAM-LEDGER citations -----------------------
# Those design docs are excluded from the export, so a "see CONTRACT-X.md"
# pointer would dangle. Replace the citation with a neutral phrase or remove it.
scrub '
  # "(CONTRACT-OFFLINE-CACHE.md P1/P2)" -> "(offline cache)"
  s/\(\s*CONTRACT-OFFLINE-CACHE(?:\.md)?[^)]*\)/(offline cache)/g;
  s/CONTRACT-OFFLINE-CACHE(?:\.md)?/the offline-cache design/g;
  # "; see CONTRACT-DEPATCH.md" / "(see CONTRACT-DEPATCH.md)" -> drop the see-cite
  s/[;,]?\s*\(?\s*(?:see|per|from|in)\s+CONTRACT-[A-Za-z0-9_]+(?:\.md)?\b\.?\)?//g;
  # "per CONTRACT-F4B.md" / "from CONTRACT-WAVE1C.md" general
  s/\s*\b(?:per|see|from|in|via)\s+CONTRACT-[A-Za-z0-9_]+(?:\.md)?\b//g;
  # bare "CONTRACT-UI-I" / "CONTRACT-W3A.md" leftover -> "the design contract"
  s/\bCONTRACT-[A-Za-z0-9_]+(?:\.md)?/the design contract/g;
  s/\bSEAM-LEDGER(?:\.md)?/the seam ledger/g;
'

# ---- (f2) orphaned leading punctuation from removed citations -----------------
# Stripping a leading "(R1 #61):" / "(ABH-86) —" / "(R1 #30, Batch C)." can leave
# a comment whose body starts with a lone ":" "," or "." (e.g. "// : open()" or
# "///. Never derived"). No comment body legitimately begins with one of these;
# collapse "//[ ].[ ]" -> "// ". Em/en-dashes are left alone (genuine prose
# continuations sometimes start a line with one).
scrub 's{^(\s*(?:///+|//|\#))[ \t]*[:,.][ \t]+}{$1 }g;'

# ---- (g) real session ids -----------------------------------------------------
scrub 's/cron_[a-f0-9]{12}_\d+_\d+/cron_example_session/g;'

# ---- (h) deploy specifics -----------------------------------------------------
# 9119 is the dashboard's documented DEFAULT port, so a bare "9119" is not a
# secret; what we scrub is the DEPLOY NARRATIVE (the user's own running instance)
# and any host:port literal that would expose a specific address.
scrub '
  # narrative phrases -> generic. Do the multi-word ones first.
  s{\b(?:our|the|today.?s|this-branch)\s+(?:LIVE|live)\s+9119(?:\s*/\s*this-branch\s+9123)?}{a stock gateway}gi;
  s{\blive 9119\s*/\s*this-branch 9123\b}{a stock gateway}gi;
  s{\bthis-branch 9123\b}{a stock gateway}gi;
  s{\b9119-EQUIVALENT\b}{stock-gateway-equivalent}gi;
  s{\btoday.?s server\b}{the gateway}gi;
  s{\btoday.?s live 9119\b}{the gateway}gi;
  # host:port literals in PROSE/instructions -> placeholder host (keeps :9119 off
  # the verify grep). The ws:// example in KNOWN-ISSUES is user-facing.
  s{ws://127\.0\.0\.1:9119/api/ws}{ws://<your-gateway-host>:<port>/api/ws}g;
  s{https?://127\.0\.0\.1:9119}{http://127.0.0.1:8080}g;
  # bare "live 9119" / "live 9123" survivors
  s{\b(?:LIVE|live) 9119\b}{a stock gateway}gi;
  s{\b(?:LIVE|live) 9123\b}{a stock gateway}gi;
  # bare commit sha called out in a comment -> generic
  s/`4523965de`/an earlier revision/g;
  s/\bat\s+4523965de\b/in an earlier revision/g;
  s/\b4523965de\b/an earlier revision/g;
'

# Test-only example ports: arbitrary "host:9119" literals in *Tests/*UITests
# files are not addresses, just "some port". Normalize to 8080 so the verify
# grep is fully clean without changing test semantics.
TEST_FILES=()
while IFS= read -r f; do [ -n "$f" ] && TEST_FILES+=("$f"); done < <(
  printf '%s\n' "${TEXT_FILES[@]}" | grep -E '/(HermesMobileTests|HermesMobileUITests)/' || true
)
if [ "${#TEST_FILES[@]}" -gt 0 ]; then
  perl -CSD -i -pe '
    s{(://[A-Za-z0-9._-]+):9119\b}{$1:8080}g;     # https://a:9119 -> https://a:8080
    s{(%3A)9119\b}{${1}8080}g;                      # url-encoded :9119 -> :8080
    s{\bhost:9119\b}{host:8080}g;
    s{\b9119\b}{8080}g;                              # any stray test port
  ' "${TEST_FILES[@]}"
fi

# ---- (i) DEVELOPMENT_TEAM -> empty (project.yml + pbxproj) ---------------------
# Xcode auto-fills the team from the builder's signing account.
scrub '
  s/(DEVELOPMENT_TEAM:[ \t]*)6J4Y9NKRQ2[ \t]*$/${1}""/gm;   # project.yml "KEY: ID" -> KEY: ""
  s/(DEVELOPMENT_TEAM\s*=\s*)6J4Y9NKRQ2(\s*;)/${1}""${2}/g;  # pbxproj DEVELOPMENT_TEAM = ID;
  s/(DevelopmentTeam\s*=\s*)6J4Y9NKRQ2(\s*;)/${1}""${2}/g;   # pbxproj DevelopmentTeam = ID;
  s/\b6J4Y9NKRQ2\b//g;                                       # any residual
'

# ---- (j) user path / email ----------------------------------------------------
scrub '
  s{/Users/abbhinnav}{$HOME}g;
  s{abhinavbansal\@mac\.com}{}g;
'

# ---- (j2) private gateway/desktop repo path+line citations --------------------
# iOS comments cross-reference the gateway source by path+line. The stock file
# NAMES are already public (seams.patch is a diff against them; INSTALL.md lists
# them), so keep the name — strip only the volatile LINE NUMBERS, which drift on
# every upstream rebase and are useless to a reader. The desktop app source is NOT
# part of the published patch surface, so generalize those refs away.
scrub '
  s{((?:tui_gateway|hermes_cli)/[A-Za-z0-9_./]+\.py):\d+(?:-\d+)?}{$1}g;
  s{\b((?:server|web_server|ws)\.py):\d+(?:-\d+)?}{$1}g;
  s{\bapps/desktop/[A-Za-z0-9_./-]+}{the desktop app}g;
'

# ---- (j3) deploy narrative + private test-instance port -----------------------
scrub '
  s{\bthe live dashboard until its (?:next )?redeploy\b}{a gateway that has not applied the seam patch yet}gi;
  s{\buntil its next redeploy\b}{until it applies the seam patch}gi;
  s{\bthe live dashboard\b}{the gateway}gi;
  s{\bon 9123\b}{on a test gateway}g;
  s{9123}{8080}g;
'

# ---- (j4) internal review jargon (case-insensitive) + contract anchors --------
scrub '
  s{//\s*MARK:\s*-\s*Judge round[^\n]*}{// MARK: - Regression re-verification}gi;
  s{\bJudge round\b}{regression re-verification}gi;
  s{\bpost-fix adversarial re-verification\b}{post-fix re-verification}gi;
  s{\badversarial re-verification\b}{re-verification}gi;
  s{\bthe contract\b}{the spec}g;
  s{\s*§\s*[\d.]+(?:\.test)?(?:\s+\d+(?:[-\x{2013}]\d+)?)?}{}g;
  s{\bBatch [A-H] gate scrutiny\b}{review}g;
'

# ---- (j5) defensive: residual bare first name / no-hyphen ABH id --------------
scrub '
  s{\bAbhinav\b}{Sam}g;
  s{\s*\bABH[-_ ]?\d+\b}{}g;
'

# Collapse double-spaces / dangling " :" left by token removal inside single-line
# // and # comments (cosmetic, keeps comments readable). LEADING indentation is
# preserved — we split off the indent + comment marker and only tidy the comment
# BODY, so code-adjacent comments stay aligned. We only touch comment lines so
# code and string literals are never reformatted.
perl -CSD -i -pe '
  if (m{^(\s*(?:///+|//|\#)\s?)(.*)$}) {
    my ($lead, $body) = ($1, $2);
    $body =~ s/[ \t]{2,}/ /g;          # squeeze interior runs of spaces
    $body =~ s/\(\s+/(/g; $body =~ s/\s+\)/)/g;  # "( foo )" -> "(foo)"
    $body =~ s/\s+([:.,;])/$1/g;        # " :" -> ":"
    $body =~ s/[ \t]+$//;              # trailing ws
    $_ = $lead . $body . "\n";
  }
' "${TEXT_FILES[@]}"

# ---- (k) seams.patch — patch-SAFE scrub --------------------------------------
# Only the sensitive tokens that appear on ADDED ('+') lines are scrubbed, and
# ONLY on those lines. Context (' '), removed ('-'), hunk ('@@'), and file
# headers ('+++ '/'--- '/'diff ') are left BYTE-IDENTICAL so `git apply` still
# matches the target. No cosmetic squeeze runs here. (In this tree the only
# in-scope token on '+' lines is the CONTRACT-DEPATCH.md citation.)
if [ -f "$PATCH_FILE" ]; then
  perl -CSD -i -pe '
    # added line, but NOT the "+++ b/file" header
    if (/^\+/ && !/^\+\+\+ /) {
      # "; See CONTRACT-DEPATCH.md seam S2." -> "."  (drop the whole dangling
      # citation incl. a trailing "seam SN" that belonged to it). Keep a
      # standalone "(seam S5)" label elsewhere — those describe the patch.
      s{[;,]?\s*\(?\s*(?:see|per)\s+CONTRACT-[A-Za-z0-9_]+(?:\.md)?(?:\s+seam\s+S\d+)?\b\.?\)?}{}gi;
      # any residual bare doc name -> neutral phrase
      s{\bCONTRACT-[A-Za-z0-9_]+(?:\.md)?}{the integration design}g;
      s{\bSEAM-LEDGER(?:\.md)?}{the seam ledger}g;
      s{\s*\bABH-\d+\b}{}g;
      s{\s*\bR1 ?\#\d+\b}{}g;
      # tidy orphan punctuation left mid-sentence by a removed citation:
      # "tokens.; shaped" -> "tokens; shaped"; "foo. , bar" -> "foo, bar".
      s{\.[ \t]*;}{;}g;
      s{\.[ \t]*,}{,}g;
    }
  ' "$PATCH_FILE"
fi

echo "scrubs applied."

# --- 3. VERIFY -----------------------------------------------------------------
echo "== verification grep =="
# seams.patch is a controlled unified diff (its +++ headers MUST name the stock
# gateway files, and it has its own patch-safe scrub); exclude it from the prose
# verify so legitimate diff headers don't read as leaks.
VERIFY_PAT='ab0991-oss/hermes-mobile|ABH[-_ ]?[0-9]|R1 ?#[0-9]|127\.0\.0\.1:9119|:9119|9123|/Users/abbhinnav|[Aa]bhinav|3DHXXG4GHQ|TQQF7DKKX8|6J4Y9NKRQ2|d7deff8e-5489|SHIP-TESTFLIGHT|SEAM-LEDGER|CONTRACT-|(server|web_server|ws)\.py:[0-9]|apps/desktop/|[Jj]udge round|redeploy'
if grep -rnE --exclude='seams.patch' "$VERIFY_PAT" "$OUT" ; then
  echo ""
  echo "!! VERIFY: remaining hits above — review before publishing."
  rc=1
else
  echo "VERIFY: clean (no forbidden tokens)."
  rc=0
fi

# --- tree summary --------------------------------------------------------------
echo "== tree summary =="
echo "top-level:"
( cd "$OUT" && ls -1 )
echo ""
echo "file count: $(find "$OUT" -type f | wc -l | tr -d ' ')"

exit $rc
