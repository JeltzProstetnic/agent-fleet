#!/usr/bin/env bash
#
# upgrade.sh — Upgrade agent-fleet with pre-upgrade rollback checkpoint
#
# Creates a git tag before pulling latest changes, then runs sync.sh deploy.
# Use --rollback to revert to the most recent pre-upgrade checkpoint.
#
# Usage:
#   bash upgrade.sh [options]
#
# Options:
#   --dry-run        Show what would be done without making changes
#   --rollback       Revert to the most recent pre-upgrade tag
#   --list-tags      Show available rollback points
#   --skip-deploy    Pull only, skip sync.sh deploy (for testing)
#   --repo <path>    Override repo path (for testing)
#   --help, -h       Show this help message
#

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/../.."

# Defaults
DRY_RUN=false
ROLLBACK=false
LIST_TAGS=false
SKIP_DEPLOY=false
REPO_PATH=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

log_info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_success() { echo -e "${GREEN}${BOLD}[SUCCESS]${NC} $*"; }

# ============================================================================
# HELP
# ============================================================================

show_help() {
    cat << 'EOF'
upgrade.sh — Upgrade agent-fleet with rollback support

Usage:
  bash upgrade.sh [options]

Options:
  --dry-run        Show what would be done without making changes
  --rollback       Revert to the most recent pre-upgrade tag
  --list-tags      Show available rollback points (pre-upgrade-* tags)
  --skip-deploy    Pull only, skip sync.sh deploy
  --repo <path>    Override repo path (default: auto-detect from script location)
  --help, -h       Show this help message

How it works:
  1. Creates a git tag (pre-upgrade-TIMESTAMP) at current HEAD
  2. Pulls latest changes from origin (fast-forward only)
  3. Runs sync.sh deploy to update live configuration

Rollback:
  If something breaks after an upgrade, run:
    bash upgrade.sh --rollback

  This resets HEAD to the most recent pre-upgrade tag and re-deploys.
  Tags are preserved so you can roll back multiple times if needed.

  View available rollback points:
    bash upgrade.sh --list-tags

EOF
}

# ============================================================================
# ARGUMENT PARSING
# ============================================================================

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)    DRY_RUN=true; shift ;;
        --rollback)   ROLLBACK=true; shift ;;
        --list-tags)  LIST_TAGS=true; shift ;;
        --skip-deploy) SKIP_DEPLOY=true; shift ;;
        --repo)       REPO_PATH="$2"; shift 2 ;;
        --help|-h)    show_help; exit 0 ;;
        *)            log_warn "Unknown argument: $1"; shift ;;
    esac
done

# Resolve repo path
if [[ -z "$REPO_PATH" ]]; then
    REPO_PATH="$(cd "$REPO_ROOT" && pwd)"
fi

# Validate repo
if [[ ! -d "$REPO_PATH/.git" ]]; then
    log_error "Not a git repository: $REPO_PATH"
    exit 1
fi

# ============================================================================
# LIST TAGS
# ============================================================================

if [[ "$LIST_TAGS" == "true" ]]; then
    echo -e "${BOLD}Available rollback points:${NC}"
    local_tags=$(git -C "$REPO_PATH" tag -l 'pre-upgrade-*' --sort=-creatordate 2>/dev/null || true)
    if [[ -z "$local_tags" ]]; then
        echo "  (no pre-upgrade tags found)"
    else
        while IFS= read -r tag; do
            local_hash=$(git -C "$REPO_PATH" rev-parse --short "$tag" 2>/dev/null || echo "???")
            echo "  $tag  ($local_hash)"
        done <<< "$local_tags"
    fi
    exit 0
fi

# ============================================================================
# ROLLBACK
# ============================================================================

if [[ "$ROLLBACK" == "true" ]]; then
    latest_tag=$(git -C "$REPO_PATH" tag -l 'pre-upgrade-*' --sort=-creatordate 2>/dev/null | head -n1)

    if [[ -z "$latest_tag" ]]; then
        log_error "No pre-upgrade tag found. Nothing to roll back to."
        exit 1
    fi

    log_info "Rolling back to: $latest_tag"
    tag_hash=$(git -C "$REPO_PATH" rev-parse "$latest_tag")
    current_hash=$(git -C "$REPO_PATH" rev-parse HEAD)

    if [[ "$tag_hash" == "$current_hash" ]]; then
        log_info "Already at $latest_tag — nothing to do"
        exit 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would reset to $latest_tag ($tag_hash)"
        exit 0
    fi

    git -C "$REPO_PATH" reset --hard "$latest_tag" >/dev/null 2>&1
    log_success "Rolled back to $latest_tag"

    # Re-deploy after rollback
    if [[ "$SKIP_DEPLOY" != "true" ]]; then
        sync_script="$REPO_PATH/sync.sh"
        if [[ -x "$sync_script" ]]; then
            log_info "Re-deploying configuration..."
            bash "$sync_script" deploy
        fi
    fi

    exit 0
fi

# ============================================================================
# UPGRADE
# ============================================================================

log_info "Upgrading agent-fleet in $REPO_PATH"

# Check for uncommitted changes
if ! git -C "$REPO_PATH" diff --quiet 2>/dev/null || ! git -C "$REPO_PATH" diff --cached --quiet 2>/dev/null; then
    log_error "Uncommitted changes detected. Commit or stash before upgrading."
    exit 1
fi

# Fetch latest
log_info "Fetching from origin..."
if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would fetch from origin"
else
    git -C "$REPO_PATH" fetch origin 2>/dev/null || {
        log_error "Failed to fetch from origin"
        exit 1
    }
fi

# Check if there are updates
current_branch=$(git -C "$REPO_PATH" branch --show-current)
local_hash=$(git -C "$REPO_PATH" rev-parse HEAD)
remote_hash=$(git -C "$REPO_PATH" rev-parse "origin/$current_branch" 2>/dev/null || echo "")

if [[ -z "$remote_hash" ]]; then
    log_error "Cannot find remote branch: origin/$current_branch"
    exit 1
fi

if [[ "$local_hash" == "$remote_hash" ]]; then
    log_info "Already up to date ($current_branch at $(echo "$local_hash" | cut -c1-7))"
    exit 0
fi

# Count incoming commits
incoming=$(git -C "$REPO_PATH" rev-list HEAD..origin/"$current_branch" --count 2>/dev/null || echo "?")
log_info "$incoming new commit(s) available"

if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would create tag and pull $incoming commit(s)"
    git -C "$REPO_PATH" log --oneline HEAD..origin/"$current_branch" 2>/dev/null | head -10
    exit 0
fi

# Create pre-upgrade tag
timestamp=$(date +%Y-%m-%d-%H%M%S)
tag_name="pre-upgrade-${timestamp}"
git -C "$REPO_PATH" tag "$tag_name"
log_info "Created rollback point: $tag_name ($(echo "$local_hash" | cut -c1-7))"

# Pull (fast-forward only)
if ! git -C "$REPO_PATH" pull --ff-only origin "$current_branch" >/dev/null 2>&1; then
    log_error "Fast-forward pull failed (diverged history?)"
    log_error "Rollback with: bash $0 --rollback --repo $REPO_PATH"
    exit 1
fi

new_hash=$(git -C "$REPO_PATH" rev-parse HEAD)
log_success "Upgraded: $(echo "$local_hash" | cut -c1-7) → $(echo "$new_hash" | cut -c1-7) ($incoming commit(s))"

# Deploy
if [[ "$SKIP_DEPLOY" != "true" ]]; then
    sync_script="$REPO_PATH/sync.sh"
    if [[ -x "$sync_script" ]]; then
        log_info "Deploying configuration..."
        bash "$sync_script" deploy
        log_success "Deploy complete"
    else
        log_warn "sync.sh not found or not executable — skipping deploy"
    fi
fi

log_success "Upgrade complete. Rollback available: bash $0 --rollback"
