#!/usr/bin/env bash
# upgrade.sh — One-command upgrade for agent-fleet
#
# Usage: bash upgrade.sh [--dry-run]
#
# Prerequisites: upstream remote must be configured
#   git remote add upstream https://github.com/JeltzProstetnic/agent-fleet.git

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source shared utilities (fall back to minimal stubs)
if [[ -f "$REPO_DIR/setup/lib.sh" ]]; then
    source "$REPO_DIR/setup/lib.sh"
else
    log_info()  { echo -e "\033[0;32m[INFO]\033[0m $*"; }
    log_warn()  { echo -e "\033[1;33m[WARN]\033[0m $*"; }
    log_error() { echo -e "\033[0;31m[ERROR]\033[0m $*"; }
fi

DRY_RUN=false
CHANNEL_FILE="$REPO_DIR/.agent-fleet-channel"
CHANNEL=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run|--check) DRY_RUN=true; shift ;;
        --channel)
            if [[ -n "${2:-}" ]] && [[ "$2" == "major" || "$2" == "rolling" ]]; then
                CHANNEL="$2"
                echo "$CHANNEL" > "$CHANNEL_FILE"
                log_info "Update channel set to: $CHANNEL"
            else
                log_error "Invalid channel. Use: --channel major  OR  --channel rolling"
                exit 1
            fi
            shift 2
            ;;
        *) shift ;;
    esac
done

# Read persisted channel (default: major)
if [[ -z "$CHANNEL" ]]; then
    CHANNEL=$(cat "$CHANNEL_FILE" 2>/dev/null || echo "major")
fi
log_info "Update channel: $CHANNEL"

# ── 1. Read current version ──────────────────────────────────────────────────

CURRENT_VERSION="0.0"
if [[ -f "$REPO_DIR/.agent-fleet-version" ]]; then
    CURRENT_VERSION=$(cat "$REPO_DIR/.agent-fleet-version")
fi
log_info "Current version: $CURRENT_VERSION"

# ── 2. Check upstream remote ─────────────────────────────────────────────────

if ! git -C "$REPO_DIR" remote get-url upstream &>/dev/null; then
    log_error "No 'upstream' remote configured."
    log_error "Add it with: git remote add upstream https://github.com/JeltzProstetnic/agent-fleet.git"
    exit 1
fi

# ── 3. Check working tree ────────────────────────────────────────────────────

STASHED=false
if [[ -n "$(git -C "$REPO_DIR" status --porcelain)" ]]; then
    log_warn "Working tree has uncommitted changes. Stashing..."
    git -C "$REPO_DIR" stash push -m "upgrade.sh auto-stash $(date +%Y%m%d_%H%M%S)" >/dev/null 2>&1
    STASHED=true
fi

# ── 3b. EXIT trap for stash restoration ──────────────────────────────────────

cleanup_stash() {
    if [[ "$STASHED" == "true" ]]; then
        log_warn "Restoring stashed changes due to unexpected exit..."
        git -C "$REPO_DIR" stash pop >/dev/null 2>&1 || log_warn "Stash pop had conflicts — resolve manually"
        STASHED=false
    fi
}
trap cleanup_stash EXIT

# ── 4. Fetch upstream ────────────────────────────────────────────────────────

log_info "Fetching upstream..."
if ! git -C "$REPO_DIR" fetch upstream >/dev/null 2>&1; then
    log_error "Failed to fetch from upstream remote. Check your network connection and upstream URL."
    exit 1
fi

# Detect upstream default branch (main or master)
if git -C "$REPO_DIR" rev-parse --verify "upstream/main" &>/dev/null; then
    UPSTREAM_BRANCH="main"
elif git -C "$REPO_DIR" rev-parse --verify "upstream/master" &>/dev/null; then
    UPSTREAM_BRANCH="master"
else
    log_error "Cannot determine upstream default branch (tried main, master)"
    exit 1
fi

# ── 5. Read upstream version (channel-aware) ────────────────────────────────

# Get latest upstream version from tags, filtered by channel
_get_latest_tag() {
    local tags
    tags=$(git -C "$REPO_DIR" tag -l 'v*' --sort=-version:refname 2>/dev/null)
    if [[ "$CHANNEL" == "major" ]]; then
        # Major only: match vN.0 or vN.0.0 patterns (no minor bumps)
        echo "$tags" | grep -E '^v[0-9]+\.0(\.0)?$' | head -1 | sed 's/^v//'
    else
        # Rolling: latest tag regardless
        echo "$tags" | head -1 | sed 's/^v//'
    fi
}

# First try tags (preferred — explicit release points)
UPSTREAM_VERSION=$(_get_latest_tag)

# Fallback: read version file from upstream branch
if [[ -z "$UPSTREAM_VERSION" ]]; then
    UPSTREAM_VERSION=$(git -C "$REPO_DIR" show "upstream/$UPSTREAM_BRANCH:.agent-fleet-version" 2>/dev/null || echo "")
fi
if [[ -z "$UPSTREAM_VERSION" ]]; then
    log_warn "No version found upstream — defaulting to 0.0"
    UPSTREAM_VERSION="0.0"
fi
log_info "Upstream version: $UPSTREAM_VERSION (channel: $CHANNEL)"

if [[ "$CURRENT_VERSION" == "$UPSTREAM_VERSION" ]]; then
    log_info "Already up to date."
    if [[ "$STASHED" == "true" ]]; then
        git -C "$REPO_DIR" stash pop >/dev/null 2>&1
        STASHED=false
    fi
    exit 0
fi

# ── 6. Dry run check ─────────────────────────────────────────────────────────

if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would upgrade $CURRENT_VERSION → $UPSTREAM_VERSION"
    log_info "[DRY RUN] Would merge upstream/$UPSTREAM_BRANCH and run pending migrations"
    if [[ "$STASHED" == "true" ]]; then
        git -C "$REPO_DIR" stash pop >/dev/null 2>&1
        STASHED=false
    fi
    exit 0
fi

# ── 7. Merge upstream ────────────────────────────────────────────────────────

log_info "Merging upstream/$UPSTREAM_BRANCH..."
if ! git -C "$REPO_DIR" merge "upstream/$UPSTREAM_BRANCH" --no-edit 2>&1; then
    log_error "Merge conflict! Resolve manually, then re-run: bash upgrade.sh"
    log_error "Your stash (if any) is preserved. Run 'git stash pop' after resolving."
    # Disable EXIT trap — user must manually pop stash after resolving conflict
    trap - EXIT
    exit 1
fi

# ── 8. Run pending migrations ────────────────────────────────────────────────

if [[ -d "$REPO_DIR/setup/migrations" ]]; then
    for migration in "$REPO_DIR/setup/migrations"/v*.sh; do
        [[ -f "$migration" ]] || continue
        # Extract version from filename (v0.3.sh → 0.3)
        m_version=$(basename "$migration" .sh | sed 's/^v//')

        # Run if migration version > current version (portable semver comparison)
        if [[ "$(printf '%s\n%s' "$CURRENT_VERSION" "$m_version" | _sort_versions | head -1)" != "$m_version" ]] && [[ "$m_version" != "$CURRENT_VERSION" ]]; then
            log_info "Running migration v${m_version}..."
            bash "$migration" "$REPO_DIR"
        else
            log_info "Skipping migration v${m_version} (already applied)"
        fi
    done
fi

# ── 9. Restore stash ─────────────────────────────────────────────────────────

if [[ "$STASHED" == "true" ]]; then
    log_info "Restoring stashed changes..."
    git -C "$REPO_DIR" stash pop >/dev/null 2>&1 || log_warn "Stash pop had conflicts — resolve manually"
    STASHED=false
fi

# ── 10. Deploy ────────────────────────────────────────────────────────────────

log_info "Deploying to live locations..."
bash "$REPO_DIR/sync.sh" deploy 2>&1 || log_warn "Deploy returned non-zero — check output"

# ── 11. Summary ──────────────────────────────────────────────────────────────

FINAL_VERSION=$(cat "$REPO_DIR/.agent-fleet-version" 2>/dev/null || echo "unknown")
log_info "Upgrade complete: $CURRENT_VERSION → $FINAL_VERSION"
