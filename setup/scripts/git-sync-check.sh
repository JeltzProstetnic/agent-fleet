#!/usr/bin/env bash
# Check if the current git repo has remote changes that need pulling.
# Usage: bash git-sync-check.sh [--pull] [path]
#   --pull:   fetch + pull if behind (default: fetch + report only)
#   path:     git repo path (default: current directory)
#
# Exit codes:
#   0 = up to date (or pulled successfully)
#   1 = behind remote (when not using --pull)
#   2 = error (not a git repo, no remote, fetch failed)

set -euo pipefail

# Never use a pager — this script is non-interactive
export GIT_PAGER=cat

AUTO_PULL=false
REPO_PATH=""
for arg in "$@"; do
  case "$arg" in
    --pull) AUTO_PULL=true ;;
    *) REPO_PATH="$arg" ;;
  esac
done

# Change to repo path if provided
if [ -n "$REPO_PATH" ]; then
  if [ ! -d "$REPO_PATH" ]; then
    echo "ERROR: Not a directory: $REPO_PATH"
    exit 2
  fi
  cd "$REPO_PATH"
fi

# Verify we're in a git repo
if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  echo "ERROR: Not a git repo."
  exit 2
fi

BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
if [ -z "$BRANCH" ]; then
  echo "ERROR: Detached HEAD — cannot check remote."
  exit 2
fi

# Dual-remote safety: if .push-filter.conf exists, only sync with the private remote.
# The public remote is write-only — fetching/merging from it would contaminate the tree.
REPO_ROOT=$(git rev-parse --show-toplevel)
PUSH_FILTER="$REPO_ROOT/.push-filter.conf"
SYNC_REMOTE=""
if [ -f "$PUSH_FILTER" ]; then
  SYNC_REMOTE=$(grep '^private_remote=' "$PUSH_FILTER" 2>/dev/null | head -1 | cut -d= -f2 | xargs)
  if [ -n "$SYNC_REMOTE" ]; then
    # Verify the remote actually exists (fresh installs may not have it yet)
    if git remote get-url "$SYNC_REMOTE" &>/dev/null; then
      echo "Dual-remote project detected — syncing with '$SYNC_REMOTE' only."
    else
      echo "Remote '$SYNC_REMOTE' not configured yet — skipping sync."
      exit 0
    fi
  fi
fi

# Check if tracking remote exists
UPSTREAM=$(git rev-parse --abbrev-ref "@{u}" 2>/dev/null || echo "")
if [ -z "$UPSTREAM" ] && [ -z "$SYNC_REMOTE" ]; then
  echo "No upstream set for '$BRANCH' — skipping."
  exit 0
fi

# Fetch only the relevant remote
if [ -n "$SYNC_REMOTE" ]; then
  if ! git fetch "$SYNC_REMOTE" --quiet 2>/dev/null; then
    echo "WARNING: git fetch $SYNC_REMOTE failed (network issue?)."
    exit 2
  fi
  # Use the private remote's branch as the comparison target
  COMPARE_REF="$SYNC_REMOTE/$BRANCH"
else
  if ! git fetch --quiet 2>/dev/null; then
    echo "WARNING: git fetch failed (network issue?)."
    exit 2
  fi
  COMPARE_REF="@{u}"
fi

LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse "$COMPARE_REF" 2>/dev/null || echo "")
if [ -z "$REMOTE" ]; then
  echo "Remote ref '$COMPARE_REF' not found — skipping."
  exit 0
fi

if [ "$LOCAL" = "$REMOTE" ]; then
  echo "Up to date."
  exit 0
fi

# Check direction
BEHIND=$(git rev-list "HEAD..$COMPARE_REF" --count)
AHEAD=$(git rev-list "$COMPARE_REF..HEAD" --count)

# Check diverged FIRST (both ahead and behind)
if [ "$BEHIND" -gt 0 ] && [ "$AHEAD" -gt 0 ]; then
  echo "DIVERGED: $AHEAD ahead, $BEHIND behind. Manual resolution needed."
  echo ""
  echo "Local commits not on remote:"
  git log "$COMPARE_REF..HEAD" --oneline --no-decorate
  echo ""
  echo "Remote commits not local:"
  git log "HEAD..$COMPARE_REF" --oneline --no-decorate
  exit 2
fi

if [ "$BEHIND" -gt 0 ]; then
  echo "BEHIND remote by $BEHIND commit(s)."
  echo ""
  echo "Incoming changes:"
  git log "HEAD..$COMPARE_REF" --oneline --no-decorate
  echo ""
  echo "Files changed:"
  git diff --stat "HEAD..$COMPARE_REF"

  if [ "$AUTO_PULL" = true ]; then
    echo ""
    echo "Pulling..."

    # Auto-stash dirty worktree to prevent pull failures (multi-device pattern)
    STASHED=false
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
      echo "Stashing local changes..."
      git stash push --quiet -m "git-sync-check auto-stash" 2>/dev/null && STASHED=true
    fi

    PULL_OK=false
    if [ -n "$SYNC_REMOTE" ]; then
      # Dual-remote: explicit merge from private remote only
      if git merge --ff-only "$COMPARE_REF" 2>/dev/null; then
        echo "Pulled successfully (from $SYNC_REMOTE)."
        PULL_OK=true
      else
        echo "WARNING: Fast-forward merge from $SYNC_REMOTE failed. Manual merge may be needed."
      fi
    else
      if git pull --ff-only --quiet 2>/dev/null; then
        echo "Pulled successfully."
        PULL_OK=true
      else
        echo "WARNING: Fast-forward pull failed. Manual merge may be needed."
      fi
    fi

    # Restore stashed changes
    if [ "$STASHED" = true ]; then
      if ! git stash pop --quiet 2>/dev/null; then
        echo "WARNING: Stash pop had conflicts — resolve manually (changes in 'git stash list')."
      fi
    fi

    if [ "$PULL_OK" = true ]; then
      exit 0
    else
      exit 2
    fi
  else
    exit 1
  fi
fi

if [ "$AHEAD" -gt 0 ]; then
  echo "Ahead of remote by $AHEAD commit(s) (unpushed). No action needed."
  exit 0
fi
