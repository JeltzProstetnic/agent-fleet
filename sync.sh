#!/usr/bin/env bash
# sync.sh — Synchronize Claude Code configuration between this repo and live locations
#
# Usage:
#   bash sync.sh deploy    — Push config from repo → live locations
#   bash sync.sh recover --emergency  — Pull config from live → repo (emergency only)
#   bash sync.sh status    — Show what's different between repo and live
#   bash sync.sh setup     — Initial setup: replace live files with symlinks to repo
#
# Cross-platform: detects WSL vs native Linux vs Git Bash on Windows

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GLOBAL_DIR="$SCRIPT_DIR/global"
PROJECTS_DIR="$SCRIPT_DIR/setup/projects"

# Detect platform
if [[ "$OSTYPE" == "darwin"* ]]; then
    PLATFORM="macos"
elif grep -qi microsoft /proc/version 2>/dev/null; then
    PLATFORM="wsl"
elif [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]]; then
    PLATFORM="windows"
else
    PLATFORM="linux"
fi

# Target locations (adjust per platform if needed)
CLAUDE_HOME="$HOME/.claude"

# Verification markers
SETUP_VERIFIED_MARKER="$CLAUDE_HOME/.setup-verified"
SETUP_FAILED_MARKER="$CLAUDE_HOME/.setup-failed"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Portable readlink -f (macOS compat — no GNU coreutils required)
_readlink_f() { readlink -f "$1" 2>/dev/null && return; local t="$1"; [ "${t#/}" = "$t" ] && t="$PWD/$t"; while [ -L "$t" ]; do local l; l=$(readlink "$t") || break; [ "${l#/}" = "$l" ] && l="$(dirname "$t")/$l"; t="$l"; done; local d; d=$(cd "$(dirname "$t")" 2>/dev/null && pwd -P) || return 1; echo "$d/$(basename "$t")"; }

# Source user-local overrides (hostname map, post-setup hook) if present
if [[ -f "$SCRIPT_DIR/sync.local.sh" ]]; then
    source "$SCRIPT_DIR/sync.local.sh"
fi

# Source modular libraries
# Order matters: common.sh first (shared utilities), then check.sh and pre-deploy.sh
# (used by deploy), then deploy.sh (used by setup), then the rest.
source "$SCRIPT_DIR/sync-lib/common.sh"
source "$SCRIPT_DIR/sync-lib/check.sh"
source "$SCRIPT_DIR/sync-lib/pre-deploy.sh"
source "$SCRIPT_DIR/sync-lib/deploy.sh"
source "$SCRIPT_DIR/sync-lib/setup.sh"
source "$SCRIPT_DIR/sync-lib/recover.sh"
source "$SCRIPT_DIR/sync-lib/status.sh"
# stamp.sh removed in v1.0 — drift detection uses direct file comparison

# ---- Main ----
case "${1:-help}" in
    setup)          cmd_setup ;;
    deploy)         cmd_deploy ;;
    recover)        shift; cmd_recover "$@" ;;
    collect)        echo "WARNING: 'collect' is deprecated. Use 'recover --emergency'." >&2; cmd_recover --emergency ;;
    check)          shift; cmd_check "$@" ;;
    check-template) shift; cmd_check_template "$@" ;;
    edit)
        shift
        hook_name="${1:-}"
        if [[ -z "$hook_name" ]]; then
            echo "Usage: bash sync.sh edit <hook-name>" >&2
            echo "Opens the repo source of a deployed hook for editing." >&2
            echo "Example: bash sync.sh edit config-check.sh" >&2
            exit 1
        fi
        # Find the hook source in global/hooks/ (including subdirectories)
        hook_source=""
        if [[ -f "$SCRIPT_DIR/global/hooks/$hook_name" ]]; then
            hook_source="$SCRIPT_DIR/global/hooks/$hook_name"
        else
            for subdir in "$SCRIPT_DIR/global/hooks"/*/; do
                [ -d "$subdir" ] || continue
                if [[ -f "$subdir$hook_name" ]]; then
                    hook_source="$subdir$hook_name"
                    break
                fi
            done
        fi
        if [[ -z "$hook_source" ]]; then
            echo "Hook not found: $hook_name" >&2
            echo "Available hooks:" >&2
            ls "$SCRIPT_DIR/global/hooks/"*.sh 2>/dev/null | xargs -n1 basename >&2
            exit 1
        fi
        echo "Source: $hook_source"
        if [[ -n "${EDITOR:-}" ]]; then
            "$EDITOR" "$hook_source"
        elif command -v code >/dev/null 2>&1; then
            code "$hook_source"
        else
            echo "Set \$EDITOR or install VS Code to open automatically." >&2
        fi
        ;;
    stamp)          echo "The stamp command has been removed in v1.0. Drift detection now uses direct file comparison." >&2; exit 1 ;;
    status)         cmd_status ;;
    mobile-deploy)  bash "$SCRIPT_DIR/setup/scripts/mobile-deploy.sh" ;;
    mobile-collect) bash "$SCRIPT_DIR/setup/scripts/mobile-deploy.sh" --collect ;;
    template-push)  shift; bash "$SCRIPT_DIR/setup/scripts/template-push.sh" --cfg-repo "$SCRIPT_DIR" "$@" ;;
    *)
        echo "Usage: bash sync.sh {setup|deploy|edit|recover|check|check-template|status|template-push|mobile-deploy|mobile-collect}"
        echo ""
        echo "  setup              — Replace live files with symlinks to repo (recommended, one-time)"
        echo "  deploy             — Copy from repo → live locations (hooks deployed read-only)"
        echo "  edit <hook>        — Open repo source of a deployed hook for editing"
        echo "  recover --emergency — Copy from live → repo (emergency only, when deployed files have unsaved edits)"
        echo "  check              — Check all propagation chains for drift/staleness"
        echo "  check-template     — Pre-publish check: exclusions, personal data, config"
        echo "  status             — Show differences between repo and live"
        echo "  template-push      — Push cfg changes to template repo (agent-fleet)"
        echo "  mobile-deploy      — Generate/refresh the mobile agent-fleet repo"
        echo "  mobile-collect     — Merge mobile outbox tasks into cross-project inbox"
        ;;
esac
