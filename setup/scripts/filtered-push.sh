#!/usr/bin/env bash
# filtered-push.sh — Centralized dual-remote push: private (full) + public (filtered)
#
# Reads .push-filter.conf from the project root to determine which paths to exclude
# from the public remote. Pushes full content to the private remote, then synthesizes
# a filtered commit for the public remote.
#
# Usage:
#   bash ~/cfg-agent-fleet/setup/scripts/filtered-push.sh [--dry-run]
#
# Run from any project directory that has a .push-filter.conf file.
#
# SAFETY: This script NEVER fetches or pulls from the public remote. The public remote
# is write-only. This prevents the catastrophic bug where a filtered public state gets
# merged into the working tree (Session 120 incident: ~17K lines lost).

set -euo pipefail

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

# Find project root (walk up to find .git)
find_project_root() {
    local dir="$PWD"
    while [[ "$dir" != "/" ]]; do
        [[ -d "$dir/.git" ]] && { echo "$dir"; return; }
        dir="$(dirname "$dir")"
    done
    echo ""
}

REPO_ROOT="$(find_project_root)"
if [[ -z "$REPO_ROOT" ]]; then
    echo "ERROR: Not inside a git repository." >&2
    exit 1
fi
cd "$REPO_ROOT"

CONFIG="$REPO_ROOT/.push-filter.conf"
if [[ ! -f "$CONFIG" ]]; then
    echo "ERROR: No .push-filter.conf found in $REPO_ROOT" >&2
    echo "Create one with:" >&2
    echo "  private_remote=<name>    # remote for full content (e.g., 'private')" >&2
    echo "  public_remote=<name>     # remote for filtered content (e.g., 'origin')" >&2
    echo "  branch=<name>            # branch to push (default: main)" >&2
    echo "  exclude=<path>           # one per line, paths to exclude from public" >&2
    echo "  exclude_glob=<pattern>   # one per line, glob patterns to exclude" >&2
    exit 1
fi

# Parse config
PRIVATE_REMOTE=""
PUBLIC_REMOTE=""
BRANCH="main"
EXCLUDE_PATHS=()
EXCLUDE_GLOBS=()

while IFS='=' read -r key value; do
    # Skip comments and blank lines
    [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
    key="$(echo "$key" | xargs)"
    value="$(echo "$value" | xargs)"
    case "$key" in
        private_remote) PRIVATE_REMOTE="$value" ;;
        public_remote)  PUBLIC_REMOTE="$value" ;;
        branch)         BRANCH="$value" ;;
        exclude)        EXCLUDE_PATHS+=("$value") ;;
        exclude_glob)   EXCLUDE_GLOBS+=("$value") ;;
        *) echo "WARNING: Unknown config key '$key'" >&2 ;;
    esac
done < "$CONFIG"

# Validate
if [[ -z "$PRIVATE_REMOTE" ]]; then
    echo "ERROR: private_remote not set in .push-filter.conf" >&2
    exit 1
fi
if [[ -z "$PUBLIC_REMOTE" ]]; then
    echo "ERROR: public_remote not set in .push-filter.conf" >&2
    exit 1
fi

# Verify remotes exist
if ! git remote get-url "$PRIVATE_REMOTE" &>/dev/null; then
    echo "ERROR: Remote '$PRIVATE_REMOTE' not configured. Run: git remote add $PRIVATE_REMOTE <url>" >&2
    exit 1
fi
if ! git remote get-url "$PUBLIC_REMOTE" &>/dev/null; then
    echo "ERROR: Remote '$PUBLIC_REMOTE' not configured. Run: git remote add $PUBLIC_REMOTE <url>" >&2
    exit 1
fi

# Verify we're on the right branch
CURRENT_BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || echo "")"
if [[ "$CURRENT_BRANCH" != "$BRANCH" ]]; then
    echo "ERROR: Expected to be on branch '$BRANCH', but on '$CURRENT_BRANCH'" >&2
    exit 1
fi

# Check for uncommitted changes
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "ERROR: Uncommitted changes. Commit or stash first." >&2
    exit 1
fi

echo "=== Dual-remote push: $(basename "$REPO_ROOT") ==="
echo "  Private: $PRIVATE_REMOTE ($BRANCH, full content)"
echo "  Public:  $PUBLIC_REMOTE ($BRANCH, filtered)"
echo "  Excluding: ${EXCLUDE_PATHS[*]:-none} ${EXCLUDE_GLOBS[*]:-}"
echo ""

# --- Step 1: Sync with private remote ---
echo "=== Syncing with $PRIVATE_REMOTE ==="
git fetch "$PRIVATE_REMOTE"

LOCAL=$(git rev-parse "$BRANCH")
REMOTE=$(git rev-parse "$PRIVATE_REMOTE/$BRANCH" 2>/dev/null || echo "none")

if [[ "$REMOTE" != "none" && "$LOCAL" != "$REMOTE" ]]; then
    BASE=$(git merge-base "$BRANCH" "$PRIVATE_REMOTE/$BRANCH" 2>/dev/null || echo "none")
    if [[ "$BASE" == "$LOCAL" ]]; then
        echo "Fast-forwarding to $PRIVATE_REMOTE/$BRANCH..."
        if $DRY_RUN; then
            echo "[dry-run] Would fast-forward"
        else
            git merge --ff-only "$PRIVATE_REMOTE/$BRANCH"
        fi
    elif [[ "$BASE" == "$REMOTE" ]]; then
        echo "Local is ahead of $PRIVATE_REMOTE/$BRANCH — will push."
    else
        echo "ERROR: Local and $PRIVATE_REMOTE/$BRANCH have diverged!" >&2
        echo "  Local:  $LOCAL" >&2
        echo "  Remote: $REMOTE" >&2
        echo "  Base:   $BASE" >&2
        echo "Run 'git pull --rebase $PRIVATE_REMOTE $BRANCH' to resolve, then retry." >&2
        exit 1
    fi
fi

# --- Step 2: Push full content to private ---
echo ""
echo "=== Pushing to $PRIVATE_REMOTE (full content) ==="
if $DRY_RUN; then
    echo "[dry-run] Would push $BRANCH to $PRIVATE_REMOTE"
else
    git push "$PRIVATE_REMOTE" "$BRANCH"
fi

# --- Step 3: Build filtered tree for public ---
echo ""
echo "=== Preparing filtered push to $PUBLIC_REMOTE ==="

if [[ ${#EXCLUDE_PATHS[@]} -eq 0 && ${#EXCLUDE_GLOBS[@]} -eq 0 ]]; then
    echo "No exclusions configured — pushing full content to public too."
    if $DRY_RUN; then
        echo "[dry-run] Would push $BRANCH to $PUBLIC_REMOTE"
    else
        git push "$PUBLIC_REMOTE" "$BRANCH"
    fi
    echo "Done."
    exit 0
fi

# Create a temporary index to build a filtered tree
TEMP_INDEX=$(mktemp)
trap "rm -f '$TEMP_INDEX'" EXIT
export GIT_INDEX_FILE="$TEMP_INDEX"

# Read current branch's tree into the temp index
git read-tree "$BRANCH"

# Remove excluded paths
for path in "${EXCLUDE_PATHS[@]}"; do
    git rm -r --cached --quiet "$path" 2>/dev/null || true
done

# Remove excluded glob patterns
for glob in "${EXCLUDE_GLOBS[@]}"; do
    # shellcheck disable=SC2086
    git rm -r --cached --quiet -- $glob 2>/dev/null || true
done

# Write the filtered tree
TREE=$(git write-tree)

# Restore normal index
unset GIT_INDEX_FILE

# Determine parent for the public commit (fetch only the ref, no merge)
# SAFETY: We only read the remote ref — we never merge it into our working tree.
# NOTE: We intentionally do NOT fetch from the public remote here. The comparison
# is against the last-known state. If the public remote was updated externally,
# this may create a force-push situation. This is acceptable because the public
# remote is write-only from this workflow.
PARENT_ARGS=()
if git rev-parse --verify "refs/remotes/$PUBLIC_REMOTE/$BRANCH" &>/dev/null; then
    PARENT_ARGS=(-p "$(git rev-parse "refs/remotes/$PUBLIC_REMOTE/$BRANCH")")
fi

# Check if tree differs from current public HEAD
if git rev-parse --verify "refs/remotes/$PUBLIC_REMOTE/$BRANCH" &>/dev/null; then
    CURRENT_PUBLIC_TREE=$(git rev-parse "refs/remotes/$PUBLIC_REMOTE/${BRANCH}^{tree}" 2>/dev/null || echo "none")
    if [[ "$TREE" == "$CURRENT_PUBLIC_TREE" ]]; then
        echo "Public repo already up to date."
        exit 0
    fi
fi

# Use the branch's latest commit message
MAIN_MSG=$(git log -1 --format=%B "$BRANCH")
COMMIT=$(echo "$MAIN_MSG" | git commit-tree "$TREE" "${PARENT_ARGS[@]}")

echo "=== Pushing to $PUBLIC_REMOTE (filtered) ==="
if $DRY_RUN; then
    echo "[dry-run] Would push filtered commit $COMMIT to $PUBLIC_REMOTE/$BRANCH"
    echo "[dry-run] Filtered tree excludes: ${EXCLUDE_PATHS[*]} ${EXCLUDE_GLOBS[*]}"
else
    git push "$PUBLIC_REMOTE" "$COMMIT:refs/heads/$BRANCH"
fi

echo ""
echo "Done. $PRIVATE_REMOTE: full push. $PUBLIC_REMOTE: filtered."
