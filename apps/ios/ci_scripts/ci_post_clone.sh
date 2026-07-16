#!/usr/bin/env bash
# ci_post_clone.sh — Xcode Cloud post-clone script for HermesMobile
#
# Xcode Cloud calls this automatically after the repo is checked out,
# before any build action. It must live at apps/ios/ci_scripts/ (same
# directory as the .xcodeproj) and be executable.
#
# Responsibilities:
#   1. Regenerate HermesMobile.xcodeproj when xcodegen is preinstalled, or
#      validate the checked-in project as the deterministic fallback
#   2. Resolve Swift Package Manager dependencies
#
# Design principles:
#   - set -euo pipefail: any unexpected failure aborts the build fast
#   - Idempotent: safe to re-run (xcodegen overwrite is fine; brew install
#     is a no-op when already present)
#   - No secrets: never reads or writes tokens/keys
#   - ONLY touches apps/ios/ — nothing else in the repo

set -euo pipefail

log() { printf '[ci_post_clone] %s\n' "$*"; }

# --------------------------------------------------------------------------
# 0. Locate the repo root and apps/ios (this script lives in apps/ios/ci_scripts/)
# --------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$IOS_DIR/../.." && pwd)"

log "SCRIPT_DIR : $SCRIPT_DIR"
log "IOS_DIR    : $IOS_DIR"
log "REPO_ROOT  : $REPO_ROOT"
log "Xcode Cloud build number: ${CI_BUILD_NUMBER:-<not set>}"
log "Workflow   : ${CI_WORKFLOW:-<not set>}"

# --------------------------------------------------------------------------
# 1. Select the project source
#    Release builds must not depend on a Homebrew install succeeding. Xcode
#    Cloud images sometimes contain a broken Cellar, so use xcodegen only when
#    it is already available; otherwise archive the checked-in project that CI
#    and the release controller validated before triggering this workflow.
# --------------------------------------------------------------------------
log "Checking for xcodegen..."
if command -v xcodegen &>/dev/null; then
    log "xcodegen already present: $(xcodegen --version 2>&1 | head -1)"
    USE_XCODEGEN=1
else
    log "xcodegen not preinstalled; using checked-in HermesMobile.xcodeproj"
    USE_XCODEGEN=0
fi

# --------------------------------------------------------------------------
# 2. Regenerate the Xcode project from project.yml
#    project.yml lives at apps/ios/project.yml.
#    xcodegen must be run from the directory containing project.yml.
# --------------------------------------------------------------------------
cd "$IOS_DIR"

if [ "$USE_XCODEGEN" = "1" ]; then
    log "Regenerating HermesMobile.xcodeproj from project.yml..."
    if [ ! -f "project.yml" ]; then
        log "ERROR: project.yml not found at $IOS_DIR/project.yml"
        exit 1
    fi
    xcodegen generate --spec project.yml
    log "xcodegen generate succeeded."
elif [ ! -f "HermesMobile.xcodeproj/project.pbxproj" ]; then
    log "ERROR: checked-in HermesMobile.xcodeproj is missing"
    exit 1
else
    log "Checked-in HermesMobile.xcodeproj is present."
fi

# --------------------------------------------------------------------------
# 2. Resolve SPM dependencies
#    xcodebuild -resolvePackageDependencies pre-fetches all remote SPM
#    packages (GRDB.swift etc.) so the build action starts with a warm cache.
#    The DebugBridge is a local path package — no network needed for it.
# --------------------------------------------------------------------------
XCODEPROJ="$IOS_DIR/HermesMobile.xcodeproj"
log "Resolving Swift Package Manager dependencies..."
xcodebuild -project "$XCODEPROJ" \
           -resolvePackageDependencies \
           -clonedSourcePackagesDirPath "$IOS_DIR/.spm-packages" \
           | grep -E "^(note:|error:|warning:|Resolved|Fetching|Downloading|Cloning|Checkout)" || true

log "SPM resolution complete."

# --------------------------------------------------------------------------
# Done
# --------------------------------------------------------------------------
log "ci_post_clone.sh finished successfully."
