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

# ── Clone-if-missing: lookup registry and clone into empty project dir ─────
# Returns 0 on success (repo cloned), 1 on failure (no match, no URL, clone failed)
_try_clone_from_registry() {
    local registry="${REGISTRY_PATH:-$HOME/cfg-agent-fleet/registry.md}"
    [[ -f "$registry" ]] || return 1

    # Normalize PWD to ~/path for matching against registry Path column
    local cwd_pattern="${PWD/#$HOME/\~}"

    # Parse registry: columns are |Name|P|Parent|Path|Repo|Machines|Type|Status|Notes
    # Leading | creates an empty first field — _lead absorbs it
    local repo_slug=""
    while IFS='|' read -r _lead _name _pri _parent path repo _rest; do
        # Strip backticks, whitespace
        path=$(echo "$path" | tr -d '`' | xargs)
        [[ "$path" == "$cwd_pattern" ]] || continue
        repo_slug=$(echo "$repo" | tr -d '`' | sed 's/ *(private)//; s/ *(public)//' | xargs)
        break
    done < "$registry"

    # No match or no URL
    [[ -n "$repo_slug" && "$repo_slug" != "—" && "$repo_slug" != "-" ]] || return 1

    # Construct clone URLs — support local paths (for testing) and GitHub slugs
    local url_primary url_fallback
    if [[ "$repo_slug" == /* || "$repo_slug" == *"://"* ]]; then
        # Absolute path or full URL — use directly (no fallback)
        url_primary="$repo_slug"
        url_fallback=""
    else
        # GitHub slug (owner/repo)
        url_primary="git@github.com:${repo_slug}.git"
        url_fallback="https://github.com/${repo_slug}.git"
    fi

    echo "Empty project directory — found '$repo_slug' in registry."
    echo "Attempting clone..."

    # Use git init + remote + fetch + checkout (works in non-empty dirs, preserves .claude/)
    git init -b main >/dev/null 2>&1 || return 1
    git config user.email "auto@agent-fleet" 2>/dev/null || true
    git config user.name "agent-fleet" 2>/dev/null || true

    git remote add origin "$url_primary" 2>/dev/null || true

    local fetched=false
    if git fetch origin --quiet 2>/dev/null; then
        fetched=true
    elif [[ -n "$url_fallback" ]]; then
        echo "SSH failed — trying HTTPS..."
        git remote set-url origin "$url_fallback" 2>/dev/null
        if git fetch origin --quiet 2>/dev/null; then
            fetched=true
        fi
    fi

    if [[ "$fetched" != "true" ]]; then
        # Cleanup partial init
        rm -rf .git
        echo "Clone failed (remote unreachable). Check credentials and network."
        return 1
    fi

    # Detect default branch and checkout
    local default_branch
    default_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||') || true
    [[ -n "$default_branch" ]] || default_branch="main"

    if ! git checkout -b "$default_branch" "origin/$default_branch" 2>/dev/null; then
        # Branch might already exist from init
        git checkout "$default_branch" 2>/dev/null || true
        git branch -u "origin/$default_branch" 2>/dev/null || true
    fi

    echo "Cloned from registry ($repo_slug)."
    return 0
}

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

# Verify we're in a git repo — if not, try clone-if-missing from registry
if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  if _try_clone_from_registry; then
    : # Fall through to normal sync logic
  else
    echo "ERROR: Not a git repo."
    exit 2
  fi
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
  # Auto-recover if ahead commits are only auto-sync rotations (safe to rebase)
  LOCAL_SUBJECTS=$(git log "$COMPARE_REF..HEAD" --format='%s')
  ALL_AUTOSYNC=true
  while IFS= read -r subj; do
    case "$subj" in
      "Auto-sync: "*)  ;; # auto-sync rotation — safe to rebase
      *)  ALL_AUTOSYNC=false; break ;;
    esac
  done <<< "$LOCAL_SUBJECTS"

  if [ "$ALL_AUTOSYNC" = true ] && [ "$AUTO_PULL" = true ]; then
    echo "DIVERGED: $AHEAD auto-sync commit(s) ahead, $BEHIND behind — auto-rebasing..."
    if git rebase "$COMPARE_REF" --quiet 2>/dev/null; then
      echo "Rebased successfully."
      # Push the rebased auto-sync commits (force-with-lease: safe force push
      # since rebase rewrites commit hashes; --force-with-lease refuses if remote
      # changed since our fetch, preventing accidental overwrites)
      _PUSH_REMOTE="${SYNC_REMOTE:-origin}"
      _PUSH_BRANCH=$(git rev-parse --abbrev-ref HEAD)
      git push "$_PUSH_REMOTE" "$_PUSH_BRANCH" --force-with-lease --quiet 2>/dev/null \
        || echo "WARNING: Post-rebase push failed (will retry next session)."
      # Rebase already incorporated all remote changes — done
      exit 0
    else
      git rebase --abort 2>/dev/null || true
      echo "WARNING: Auto-rebase failed — falling back to manual resolution."
      echo ""
      echo "Local commits not on remote:"
      git log "$COMPARE_REF..HEAD" --oneline --no-decorate
      echo ""
      echo "Remote commits not local:"
      git log "HEAD..$COMPARE_REF" --oneline --no-decorate
      exit 2
    fi
  else
    echo "DIVERGED: $AHEAD ahead, $BEHIND behind. Manual resolution needed."
    echo ""
    echo "Local commits not on remote:"
    git log "$COMPARE_REF..HEAD" --oneline --no-decorate
    echo ""
    echo "Remote commits not local:"
    git log "HEAD..$COMPARE_REF" --oneline --no-decorate
    exit 2
  fi
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

    # Recover interrupted rotation: if dirty files are only session rotation
    # artifacts, commit them instead of stashing (prevents stash-pop conflicts).
    STASHED=false
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
      _DIRTY_FILES=$(git diff --name-only 2>/dev/null; git diff --cached --name-only 2>/dev/null)
      _ALL_SESSION=true
      while IFS= read -r _df; do
        [ -z "$_df" ] && continue
        case "$_df" in
          session-context.md|session-history.md|next-session-task.md|docs/session-log.md|.post-rotation-commit) ;;
          *) _ALL_SESSION=false; break ;;
        esac
      done <<< "$_DIRTY_FILES"

      if [ "$_ALL_SESSION" = true ]; then
        echo "Recovering interrupted session rotation..."
        # Stage each file separately (git add fails atomically on multi-pathspec)
        git add session-context.md 2>/dev/null || true
        git add session-history.md 2>/dev/null || true
        git add next-session-task.md 2>/dev/null || true
        git add docs/session-log.md 2>/dev/null || true
        git add .post-rotation-commit 2>/dev/null || true
        if git diff --cached --quiet 2>/dev/null; then
          # Nothing was actually staged (content unchanged) — fall back to stash
          echo "No staged changes from rotation — stashing instead."
          git stash push --quiet -m "git-sync-check auto-stash" 2>/dev/null && STASHED=true
        else
          git commit -m "Auto-sync: recovered rotation (interrupted)" --quiet 2>/dev/null || true
          # Re-check: now we may be diverged (ahead+behind) — rebase auto-sync
          _NOW_AHEAD=$(git rev-list "$COMPARE_REF..HEAD" --count 2>/dev/null || echo 0)
          if [ "$_NOW_AHEAD" -gt 0 ]; then
            if git rebase "$COMPARE_REF" --quiet 2>/dev/null; then
              echo "Rebased recovered rotation onto remote."
              _PUSH_REMOTE="${SYNC_REMOTE:-origin}"
              _PUSH_BRANCH=$(git rev-parse --abbrev-ref HEAD)
              git push "$_PUSH_REMOTE" "$_PUSH_BRANCH" --force-with-lease --quiet 2>/dev/null || true
              # Pull already happened via rebase — skip normal pull path
              echo "Pulled successfully (via rebase)."
              # Update PRE_PULL_HEAD to post-rebase state for deploy-sensitive detection
              PRE_PULL_HEAD=$(git rev-parse HEAD~"$BEHIND" 2>/dev/null || echo "$LOCAL")
              PULL_OK=true
            else
              git rebase --abort 2>/dev/null || true
              echo "WARNING: Rotation recovery rebase failed — stashing instead."
              git reset HEAD~1 --quiet 2>/dev/null || true
              git stash push --quiet -m "git-sync-check auto-stash" 2>/dev/null && STASHED=true
            fi
          fi
        fi
      else
        echo "Stashing local changes..."
        git stash push --quiet -m "git-sync-check auto-stash" 2>/dev/null && STASHED=true
      fi
    fi

    # Save pre-pull HEAD for deploy-sensitive path detection (CFG-208)
    PRE_PULL_HEAD="$LOCAL"

    # Skip normal pull if rotation recovery already handled it via rebase
    if [ "${PULL_OK:-}" != true ]; then
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

    fi # end: skip normal pull if rotation recovery handled it

    # Restore stashed changes
    if [ "$STASHED" = true ]; then
      if ! git stash pop --quiet 2>/dev/null; then
        echo "WARNING: Stash pop had conflicts — resolve manually (changes in 'git stash list')."
      fi
    fi

    # CFG-208: Auto-deploy if pulled commits include deploy-sensitive paths.
    # Runs BEFORE SessionStart hook fires — avoids self-referencing hazard.
    if [ "$PULL_OK" = true ]; then
      DEPLOY_SENSITIVE_PREFIXES="global/hooks/ global/knowledge/ global/reference/ global/foundation/ global/domains/ setup/config/ setup/scripts/"
      CHANGED_FILES=$(git diff --name-only "$PRE_PULL_HEAD" HEAD 2>/dev/null || true)
      NEEDS_DEPLOY=false

      for changed in $CHANGED_FILES; do
        for prefix in $DEPLOY_SENSITIVE_PREFIXES; do
          case "$changed" in
            "$prefix"*) NEEDS_DEPLOY=true; break 2 ;;
          esac
        done
      done

      if [ "$NEEDS_DEPLOY" = true ]; then
        SYNC_SCRIPT_PATH="$REPO_ROOT/sync.sh"
        if [ -x "$SYNC_SCRIPT_PATH" ]; then
          echo "Deploy-sensitive files changed — running sync.sh deploy..."
          bash "$SYNC_SCRIPT_PATH" deploy 2>&1 || echo "WARNING: sync.sh deploy failed (non-blocking)."
        fi
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

# ── Version update check ─────────────────────────────────────────────────────
# After sync, compare local .agent-fleet-version with remote (fetched) version.
# This detects when the user is on an older tagged release and a newer one exists.
_check_fleet_version() {
  local version_file="$REPO_ROOT/.agent-fleet-version"
  [[ -f "$version_file" ]] || return 0

  local local_ver
  local_ver=$(cat "$version_file" 2>/dev/null | tr -d '[:space:]')
  [[ -n "$local_ver" ]] || return 0

  # Check remote version file (already fetched)
  local remote_ver
  local remote_ref="${SYNC_REMOTE:-origin}/$BRANCH"
  remote_ver=$(git show "$remote_ref:.agent-fleet-version" 2>/dev/null | tr -d '[:space:]') || return 0
  [[ -n "$remote_ver" ]] || return 0

  if [[ "$local_ver" != "$remote_ver" ]]; then
    # Compare versions (simple string compare works for semver without pre-release)
    if [[ "$(printf '%s\n' "$local_ver" "$remote_ver" | sort -V | head -1)" == "$local_ver" && "$local_ver" != "$remote_ver" ]]; then
      echo ""
      echo -e "\033[1;33m[UPDATE AVAILABLE]\033[0m agent-fleet $local_ver → $remote_ver"
      echo "  Run: bash ~/agent-fleet/setup/scripts/upgrade.sh"
      echo ""
    fi
  fi
}

# Run version check if this is an agent-fleet repo (has .agent-fleet-version)
if [[ -f "$REPO_ROOT/.agent-fleet-version" ]]; then
  _check_fleet_version
fi

if [ "$AHEAD" -gt 0 ]; then
  echo "Ahead of remote by $AHEAD commit(s) (unpushed). No action needed."
  exit 0
fi
