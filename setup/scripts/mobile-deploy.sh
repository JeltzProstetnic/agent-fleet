#!/usr/bin/env bash
# mobile-deploy.sh — Generate or refresh the mobile agent-fleet repo
#
# Usage:
#   bash mobile-deploy.sh [--config-repo PATH] [--target PATH] [--home PATH]
#   bash mobile-deploy.sh --collect [--config-repo PATH] [--target PATH]
#
# Modes:
#   (default)   Generate/refresh the mobile repo with read-only context snapshots
#   --collect   Merge outbox tasks from mobile repo into the main cross-project inbox
#
# Options:
#   --config-repo PATH   Config repo root (default: auto-detect or ~/cfg-agent-fleet)
#   --target PATH        Mobile repo location (default: ~/agent-fleet-mobile)
#   --home PATH          Home directory for finding projects (default: $HOME)

set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────

MODE="deploy"
CONFIG_REPO=""
TARGET=""
USER_HOME=""

# ── Parse arguments ──────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --collect)          MODE="collect"; shift ;;
        --check-staleness)  MODE="check-staleness"; shift ;;
        --config-repo) CONFIG_REPO="$2"; shift 2 ;;
        --target)     TARGET="$2"; shift 2 ;;
        --home)       USER_HOME="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ── Auto-detect config repo ─────────────────────────────────────────────────

if [[ -z "$CONFIG_REPO" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -f "$SCRIPT_DIR/../../sync.sh" ]]; then
        CONFIG_REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
    else
        CONFIG_REPO="$HOME/cfg-agent-fleet"
    fi
fi

[[ -z "$TARGET" ]] && TARGET="${USER_HOME:-$HOME}/agent-fleet-mobile"

# Defensive check: verify config repo exists
if [[ ! -f "$CONFIG_REPO/sync.sh" ]]; then
    echo "ERROR: Config repo not found at $CONFIG_REPO (sync.sh missing)." >&2
    echo "Set --config-repo or clone cfg-agent-fleet to ~/cfg-agent-fleet" >&2
    exit 2
fi
[[ -z "$USER_HOME" ]] && USER_HOME="$HOME"

# ── Colors ───────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# ── Freshness stamp ─────────────────────────────────────────────────────────

stamp_file() {
    local file="$1"
    local timestamp
    timestamp="$(date -u +'%Y-%m-%d %H:%M UTC')"
    local tmp="${file}.tmp.$$"
    echo "<!-- Snapshot: $timestamp -->" > "$tmp"
    cat "$file" >> "$tmp"
    mv "$tmp" "$file"
}

# ── COLLECT MODE ─────────────────────────────────────────────────────────────

# Merge any unmerged claude/* branches into main
merge_claude_branches() {
    # Skip if not a git repo
    if ! git -C "$TARGET" rev-parse --git-dir >/dev/null 2>&1; then
        return 0
    fi

    # Fetch from remote to discover remote-only claude/* branches (Bug 2 fix)
    if git -C "$TARGET" remote get-url origin >/dev/null 2>&1; then
        git -C "$TARGET" fetch origin --prune >/dev/null 2>&1 || true

        # Create local tracking branches for any remote-only claude/* branches
        local remote_branches
        remote_branches=$(git -C "$TARGET" branch -r --list "origin/claude/*" 2>/dev/null | sed 's/^[* ]*//')
        if [[ -n "$remote_branches" ]]; then
            while IFS= read -r rbranch; do
                [[ -z "$rbranch" ]] && continue
                local local_name="${rbranch#origin/}"
                # Only create tracking branch if it doesn't exist locally
                if ! git -C "$TARGET" rev-parse --verify "$local_name" >/dev/null 2>&1; then
                    git -C "$TARGET" branch --track "$local_name" "$rbranch" >/dev/null 2>&1 || true
                fi
            done <<< "$remote_branches"
        fi
    fi

    # Find claude/* branches (now includes any newly tracked remote branches)
    local branches
    branches=$(git -C "$TARGET" branch --list "claude/*" 2>/dev/null | sed 's/^[* ]*//')

    if [[ -z "$branches" ]]; then
        return 0
    fi

    # Ensure we're on main
    local current_branch
    current_branch=$(git -C "$TARGET" branch --show-current 2>/dev/null)
    if [[ "$current_branch" != "main" ]]; then
        git -C "$TARGET" checkout main >/dev/null 2>&1
    fi

    local has_remote=false
    if git -C "$TARGET" remote get-url origin >/dev/null 2>&1; then
        has_remote=true
    fi

    local merged_count=0
    while IFS= read -r branch; do
        [[ -z "$branch" ]] && continue
        log_info "Merging branch: $branch"
        if git -C "$TARGET" merge "$branch" --no-edit >/dev/null 2>&1; then
            git -C "$TARGET" branch -d "$branch" >/dev/null 2>&1
            # Delete remote branch after successful merge (Bug 3 fix)
            if [[ "$has_remote" == true ]]; then
                git -C "$TARGET" push origin --delete "$branch" >/dev/null 2>&1 || true
            fi
            merged_count=$((merged_count + 1))
        else
            log_warn "Failed to merge $branch — may have conflicts. Skipping."
            git -C "$TARGET" merge --abort >/dev/null 2>&1 || true
        fi
    done <<< "$branches"

    if [[ "$merged_count" -gt 0 ]]; then
        log_info "Merged $merged_count claude/* branch(es) into main"
    fi
}

# Collect session-log entries from mobile repo
collect_session_log() {
    local mobile_log="$TARGET/inbox/session-log.md"
    local config_log="$CONFIG_REPO/docs/mobile-session-log.md"

    if [[ ! -f "$mobile_log" ]]; then
        return 0
    fi

    # Check if there are any session entries (### headers mark individual sessions)
    if ! grep -q '^### ' "$mobile_log" 2>/dev/null; then
        log_info "Session log has no entries — nothing to collect"
        return 0
    fi

    # Extract session entries: everything after the header block
    # Skip lines until we find the first ### entry (preserves all entries)
    local entries
    entries=$(sed -n '/^### /,$ p' "$mobile_log")

    # Append to config repo's mobile session log
    mkdir -p "$(dirname "$config_log")"
    if [[ ! -f "$config_log" ]]; then
        echo "# Mobile Session Log" > "$config_log"
        echo "" >> "$config_log"
        echo "Collected from mobile Claude app sessions via \`sync.sh mobile-collect\`." >> "$config_log"
    fi
    echo "" >> "$config_log"
    echo "$entries" >> "$config_log"
    local count
    count=$(echo "$entries" | grep -c '^### ') || count=0
    log_info "Collected $count session log entry/entries → docs/mobile-session-log.md"

    # Reset mobile session log (keep header + comment marker)
    cat > "$mobile_log" <<'SLOG'
# Mobile Session Log

Append-only log of mobile Claude app sessions. Collected by `sync.sh mobile-collect`.

<!-- Entries below, newest first -->
SLOG
    log_info "Mobile session log cleared"
}

cmd_collect() {
    local outbox="$TARGET/inbox/outbox.md"
    local inbox="$CONFIG_REPO/cross-project/inbox.md"

    # Step 1: Merge any claude/* branches before collecting
    merge_claude_branches

    # Step 2: Collect outbox tasks
    if [[ ! -f "$outbox" ]]; then
        log_warn "No outbox found at $outbox"
    else
        local tasks
        tasks=$(grep '^\- \[ \]' "$outbox" 2>/dev/null || true)

        if [[ -z "$tasks" ]]; then
            log_info "Outbox is empty — nothing to collect"
        else
            echo "" >> "$inbox"
            echo "$tasks" >> "$inbox"
            local count
            count=$(echo "$tasks" | wc -l)
            log_info "Merged $count task(s) from outbox into inbox"

            # Reset outbox (keep header)
            cat > "$outbox" <<'OUTBOX'
# Mobile Outbox

Tasks posted here will be merged into the main cross-project inbox
when `sync.sh mobile-collect` runs on any full machine.

## Pending

OUTBOX
            log_info "Outbox cleared"
        fi
    fi

    # Step 3: Collect session-log entries
    collect_session_log
}

# ── DEPLOY MODE ──────────────────────────────────────────────────────────────

cmd_deploy() {
    log_info "Deploying mobile repo to $TARGET"

    # Create directory structure
    mkdir -p "$TARGET/context/project-summaries"
    mkdir -p "$TARGET/inbox"

    # Marker file
    echo "mobile-repo" > "$TARGET/.mobile-repo"

    # ── Copy context files ───────────────────────────────────────────────

    # Foundation files
    for f in user-profile.md personas.md; do
        local src="$CONFIG_REPO/global/foundation/$f"
        if [[ -f "$src" ]]; then
            cp "$src" "$TARGET/context/$f"
            stamp_file "$TARGET/context/$f"
            log_info "Copied: $f"
        fi
    done

    # Registry
    if [[ -f "$CONFIG_REPO/registry.md" ]]; then
        cp "$CONFIG_REPO/registry.md" "$TARGET/context/registry.md"
        stamp_file "$TARGET/context/registry.md"
        log_info "Copied: registry.md"
    fi

    # Dashboard cache
    if [[ -f "$CONFIG_REPO/cross-project/dashboard-cache.md" ]]; then
        cp "$CONFIG_REPO/cross-project/dashboard-cache.md" "$TARGET/context/dashboard-cache.md"
        stamp_file "$TARGET/context/dashboard-cache.md"
        log_info "Copied: dashboard-cache.md"
    fi

    # Cross-project inbox
    if [[ -f "$CONFIG_REPO/cross-project/inbox.md" ]]; then
        cp "$CONFIG_REPO/cross-project/inbox.md" "$TARGET/context/inbox.md"
        stamp_file "$TARGET/context/inbox.md"
        log_info "Copied: inbox.md"
    fi

    # Infrastructure strategy
    if [[ -f "$CONFIG_REPO/cross-project/infrastructure-strategy.md" ]]; then
        cp "$CONFIG_REPO/cross-project/infrastructure-strategy.md" "$TARGET/context/infrastructure-strategy.md"
        stamp_file "$TARGET/context/infrastructure-strategy.md"
        log_info "Copied: infrastructure-strategy.md"
    fi

    # ── Generate machine index ───────────────────────────────────────────

    local machine_index="$TARGET/context/machine-index.md"
    echo "# Machine Index" > "$machine_index"
    echo "" >> "$machine_index"
    local machines_dir="$CONFIG_REPO/global/machines"
    if [[ -d "$machines_dir" ]]; then
        for mf in "$machines_dir"/*.md; do
            [[ -f "$mf" ]] || continue
            local base
            base=$(basename "$mf")
            [[ "$base" == _template.md ]] && continue
            local title
            title=$(head -3 "$mf" | grep -oP '(?<=# Machine: ).*' || echo "$base")
            echo "- **$title**: \`$base\`" >> "$machine_index"
        done
    fi
    stamp_file "$machine_index"
    log_info "Generated: machine-index.md"

    # ── Generate project summaries ───────────────────────────────────────

    # Parse registry for project paths
    if [[ -f "$CONFIG_REPO/registry.md" ]]; then
        while IFS='|' read -r _ name _ _ path _; do
            name=$(echo "$name" | xargs)
            path=$(echo "$path" | xargs | tr -d '`')
            [[ -z "$name" || "$name" == "Project" || "$name" == "---"* ]] && continue
            [[ -z "$path" ]] && continue

            # Expand ~ to user home
            path="${path/#\~/$USER_HOME}"
            [[ -d "$path" ]] || continue

            local summary="$TARGET/context/project-summaries/$name.md"
            echo "# $name" > "$summary"
            echo "" >> "$summary"

            # Session context (head 30 lines)
            if [[ -f "$path/session-context.md" ]]; then
                echo "## Session Context" >> "$summary"
                head -30 "$path/session-context.md" >> "$summary"
                echo "" >> "$summary"
            fi

            # Backlog (head 40 lines)
            if [[ -f "$path/backlog.md" ]]; then
                echo "## Backlog (top)" >> "$summary"
                head -40 "$path/backlog.md" >> "$summary"
                echo "" >> "$summary"
            fi

            log_info "Summary: $name"
        done < <(grep -E '^\|[^-]' "$CONFIG_REPO/registry.md" | grep -v 'Project.*Priority')
    fi

    # ── Outbox (create only if missing) ──────────────────────────────────

    if [[ ! -f "$TARGET/inbox/outbox.md" ]]; then
        cat > "$TARGET/inbox/outbox.md" <<'OUTBOX'
# Mobile Outbox

Tasks posted here will be merged into the main cross-project inbox
when `sync.sh mobile-collect` runs on any full machine.

## Pending

OUTBOX
        log_info "Created: outbox.md"
    else
        log_info "Preserved existing outbox.md"
    fi

    # ── CLAUDE.md ────────────────────────────────────────────────────────

    local claude_template="$CONFIG_REPO/setup/config/mobile-CLAUDE.md"
    if [[ -f "$claude_template" ]]; then
        cp "$claude_template" "$TARGET/CLAUDE.md"
        log_info "Deployed: CLAUDE.md"
    else
        log_warn "No mobile-CLAUDE.md template found — creating minimal"
        echo "# MOBILE MODE" > "$TARGET/CLAUDE.md"
        echo "You are in MOBILE MODE. Read context/ for project info. Write to inbox/outbox.md only." >> "$TARGET/CLAUDE.md"
    fi

    # ── Session context (minimal template) ───────────────────────────────

    cat > "$TARGET/session-context.md" <<'SC'
# Session Context

## Session Info
- **Last Updated**:
- **Machine**: mobile
- **Working Directory**: ~/agent-fleet-mobile
- **Session Goal**:

## Current State
- **Active Task**:
- **Progress** (use `- [x]` checkbox for each completed item):
- **Pending**:

## Key Decisions

## Recovery Instructions
SC

    log_info "Mobile repo deployed to $TARGET"
}

# ── CHECK-STALENESS MODE ─────────────────────────────────────────────────────

cmd_check_staleness() {
    if [[ ! -d "$TARGET" ]]; then
        log_warn "Mobile repo not found at $TARGET — cannot check staleness"
        return 0
    fi

    local stale_count=0

    # Check key source files against their mobile snapshots
    local -a source_target_pairs=(
        "$CONFIG_REPO/global/foundation/user-profile.md|$TARGET/context/user-profile.md"
        "$CONFIG_REPO/global/foundation/personas.md|$TARGET/context/personas.md"
        "$CONFIG_REPO/registry.md|$TARGET/context/registry.md"
        "$CONFIG_REPO/cross-project/dashboard-cache.md|$TARGET/context/dashboard-cache.md"
        "$CONFIG_REPO/cross-project/inbox.md|$TARGET/context/inbox.md"
        "$CONFIG_REPO/cross-project/infrastructure-strategy.md|$TARGET/context/infrastructure-strategy.md"
    )

    for pair in "${source_target_pairs[@]}"; do
        local src="${pair%%|*}"
        local tgt="${pair##*|}"
        [[ -f "$src" ]] || continue
        [[ -f "$tgt" ]] || { stale_count=$((stale_count + 1)); continue; }

        # Compare modification times: if source is newer than target, it's stale
        if [[ "$src" -nt "$tgt" ]]; then
            local base
            base=$(basename "$src")
            log_warn "$base: mobile repo is stale (source newer than snapshot)"
            stale_count=$((stale_count + 1))
        fi
    done

    if [[ "$stale_count" -eq 0 ]]; then
        log_info "Mobile repo is up to date"
    else
        log_warn "$stale_count file(s) stale. Run 'sync.sh mobile-deploy' to refresh."
    fi
}

# ── Main ─────────────────────────────────────────────────────────────────────

case "$MODE" in
    deploy)          cmd_deploy ;;
    collect)         cmd_collect ;;
    check-staleness) cmd_check_staleness ;;
esac
