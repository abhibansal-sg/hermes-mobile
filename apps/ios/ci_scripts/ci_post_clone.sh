#!/usr/bin/env bash
# ci_post_clone.sh — Xcode Cloud post-clone script for HermesMobile
#
# Xcode Cloud calls this automatically after the repo is checked out,
# before any build action. It must live at apps/ios/ci_scripts/ (same
# directory as the .xcodeproj) and be executable.
#
# Responsibilities:
#   1. Install xcodegen (via Homebrew — available on all Xcode Cloud VMs)
#   2. Regenerate HermesMobile.xcodeproj from project.yml (source of truth)
#   3. Resolve Swift Package Manager dependencies
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
# 1. Install xcodegen via Homebrew
#    Xcode Cloud VMs ship with Homebrew pre-installed; the install is a
#    no-op if the formula is already cached.
# --------------------------------------------------------------------------
log "Checking for xcodegen..."
if command -v xcodegen &>/dev/null; then
    log "xcodegen already present: $(xcodegen --version 2>&1 | head -1)"
else
    log "Installing xcodegen via Homebrew..."
    brew install xcodegen
    log "Installed: $(xcodegen --version 2>&1 | head -1)"
fi

# --------------------------------------------------------------------------
# 2. Regenerate the Xcode project from project.yml
#    project.yml lives at apps/ios/project.yml.
#    xcodegen must be run from the directory containing project.yml.
# --------------------------------------------------------------------------
log "Regenerating HermesMobile.xcodeproj from project.yml..."
cd "$IOS_DIR"

if [ ! -f "project.yml" ]; then
    log "ERROR: project.yml not found at $IOS_DIR/project.yml"
    exit 1
fi

xcodegen generate --spec project.yml
log "xcodegen generate succeeded."

# --------------------------------------------------------------------------
# 3. Resolve SPM dependencies
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
