#!/usr/bin/env bash
# sync.sh — Synchronize Claude Code configuration between this repo and live locations
#
# Usage:
#   bash sync.sh deploy    — Push config from repo → live locations
#   bash sync.sh collect   — Pull config from live locations → repo
#   bash sync.sh status    — Show what's different between repo and live
#   bash sync.sh setup     — Initial setup: replace live files with symlinks to repo
#
# Cross-platform: detects WSL vs native Linux vs Git Bash on Windows

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GLOBAL_DIR="$SCRIPT_DIR/global"
PROJECTS_DIR="$SCRIPT_DIR/projects"

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

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# ---- SETUP: Replace live files with symlinks to repo ----
cmd_setup() {
    log_info "Setting up symlinks from live locations → repo"
    log_info "Platform: $PLATFORM"

    # Backup existing files
    if [ -f "$CLAUDE_HOME/CLAUDE.md" ] && [ ! -L "$CLAUDE_HOME/CLAUDE.md" ]; then
        log_info "Backing up existing $CLAUDE_HOME/CLAUDE.md"
        cp "$CLAUDE_HOME/CLAUDE.md" "$CLAUDE_HOME/CLAUDE.md.bak"
    fi

    # Global CLAUDE.md
    ln -sf "$GLOBAL_DIR/CLAUDE.md" "$CLAUDE_HOME/CLAUDE.md"
    log_info "Linked: $CLAUDE_HOME/CLAUDE.md → $GLOBAL_DIR/CLAUDE.md"

    # Knowledge architecture directories (directory symlinks)
    for dir in foundation reference domains knowledge machines; do
        if [ -d "$GLOBAL_DIR/$dir" ]; then
            if [ -L "$CLAUDE_HOME/$dir" ]; then
                rm "$CLAUDE_HOME/$dir"
            elif [ -d "$CLAUDE_HOME/$dir" ]; then
                log_warn "$CLAUDE_HOME/$dir exists as directory — backing up"
                mv "$CLAUDE_HOME/$dir" "$CLAUDE_HOME/${dir}.bak"
            fi
            ln -sf "$GLOBAL_DIR/$dir" "$CLAUDE_HOME/$dir"
            log_info "Linked: $CLAUDE_HOME/$dir → $GLOBAL_DIR/$dir"
        fi
    done

    # Hooks
    deploy_hooks

    # Project-specific rules
    deploy_project_rules

    # Check for CLAUDE.local.md (machine-specific @import)
    if [[ ! -f "$HOME/CLAUDE.local.md" ]]; then
        log_warn "No ~/CLAUDE.local.md found. Create one for machine-specific loading:"
        log_warn "  echo '@~/.claude/machines/<machine>.md' > ~/CLAUDE.local.md"
    else
        log_info "CLAUDE.local.md already exists"
    fi

    log_info "Setup complete. Live locations now symlinked to repo."
    log_warn "Restart Claude Code for changes to take effect."
}

# ---- DEPLOY: Copy from repo → live (for non-symlink setups or project rules) ----
cmd_deploy() {
    log_info "Deploying config from repo → live locations"

    # Global CLAUDE.md
    if [ -L "$CLAUDE_HOME/CLAUDE.md" ]; then
        log_info "CLAUDE.md is symlinked — no copy needed"
    else
        cp "$GLOBAL_DIR/CLAUDE.md" "$CLAUDE_HOME/CLAUDE.md"
        log_info "Copied: CLAUDE.md → $CLAUDE_HOME/"
    fi

    # Knowledge architecture directories
    for dir in foundation reference domains knowledge machines; do
        if [ -d "$GLOBAL_DIR/$dir" ]; then
            if [ -L "$CLAUDE_HOME/$dir" ]; then
                log_info "$dir/ is symlinked — no copy needed"
            else
                mkdir -p "$CLAUDE_HOME/$dir"
                cp -r "$GLOBAL_DIR/$dir/." "$CLAUDE_HOME/$dir/"
                log_info "Copied: $dir/ → $CLAUDE_HOME/$dir/"
            fi
        fi
    done

    # Hooks
    deploy_hooks

    # Project-specific rules
    deploy_project_rules

    # Template drift check
    check_template_drift

    log_info "Deploy complete."
}

deploy_hooks() {
    mkdir -p "$CLAUDE_HOME/hooks"
    for hook in "$GLOBAL_DIR/hooks/"*.sh; do
        [ -f "$hook" ] || continue
        base=$(basename "$hook")
        cp "$hook" "$CLAUDE_HOME/hooks/$base"
        chmod +x "$CLAUDE_HOME/hooks/$base"
        log_info "Deployed hook: $base"
    done
}

deploy_project_rules() {
    # Deploy project-specific rules to projects that exist on this machine
    for project_dir in "$PROJECTS_DIR"/*/; do
        [ -d "$project_dir" ] || continue
        project_name=$(basename "$project_dir")

        # Find the project path from registry
        project_path=$(find_project_path "$project_name")
        if [ -z "$project_path" ]; then
            log_warn "Project '$project_name' not found on this machine — skipping"
            continue
        fi

        if [ ! -d "$project_path" ]; then
            log_warn "Project path '$project_path' doesn't exist — skipping"
            continue
        fi

        # Deploy rules
        if [ -d "$project_dir/rules" ]; then
            mkdir -p "$project_path/.claude"
            for rule in "$project_dir/rules/"*.md; do
                [ -f "$rule" ] || continue
                base=$(basename "$rule")
                cp "$rule" "$project_path/.claude/$base"
                log_info "Deployed: $project_name/rules/$base → $project_path/.claude/"
            done
        fi
    done
}

# ---- TEMPLATE DRIFT CHECK ----
# Checks tracked files for changes since last template sync.
# The manifest stores file hashes — if changed, template may need updating.
check_template_drift() {
    local manifest="$SCRIPT_DIR/template-sync-manifest.md"
    [ -f "$manifest" ] || return 0  # No manifest — nothing to check

    # CRC32 computation requires python3
    if ! command -v python3 >/dev/null 2>&1; then
        log_warn "python3 not found — skipping template drift check"
        return 0
    fi

    local drift_count=0

    # Extract tracked file rows from manifest: lines matching "| `path` | `hash` |"
    # Use process substitution to avoid consuming stdin
    local tracked_files
    tracked_files=$(sed -n 's/^| `\([^`]*\)` | `\([0-9a-f]\{8\}\)`.*/\1|\2/p' "$manifest" || true)

    local line file_path hash
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        file_path="${line%%|*}"
        hash="${line##*|}"
        [ -n "$file_path" ] && [ -n "$hash" ] || continue

        local full_path="$SCRIPT_DIR/$file_path"
        [ -f "$full_path" ] || continue

        local current_hash
        current_hash=$(python3 -c "import binascii,sys;print(format(binascii.crc32(open(sys.argv[1],'rb').read())&0xFFFFFFFF,'08x'))" "$full_path")

        if [ "$current_hash" != "$hash" ]; then
            log_warn "$file_path changed since last template sync (was: $hash, now: $current_hash)"
            drift_count=$((drift_count + 1))
        fi
    done <<< "$tracked_files"

    if [ "$drift_count" -gt 0 ]; then
        log_warn "$drift_count file(s) drifted. Review template-sync-manifest.md and propagate changes."
    fi
}

# ---- COLLECT: Copy from live locations → repo ----
cmd_collect() {
    log_info "Collecting config from live locations → repo"

    # Global CLAUDE.md (only if not symlinked — symlinks are already in sync)
    if [ -L "$CLAUDE_HOME/CLAUDE.md" ]; then
        log_info "CLAUDE.md is symlinked — already in sync"
    elif [ -f "$CLAUDE_HOME/CLAUDE.md" ]; then
        cp "$CLAUDE_HOME/CLAUDE.md" "$GLOBAL_DIR/CLAUDE.md"
        log_info "Collected: CLAUDE.md"
    fi

    # Knowledge architecture directories
    for dir in foundation reference domains knowledge machines; do
        if [ -L "$CLAUDE_HOME/$dir" ]; then
            log_info "$dir/ is symlinked — already in sync"
        elif [ -d "$CLAUDE_HOME/$dir" ] && [ -d "$GLOBAL_DIR/$dir" ]; then
            cp -r "$CLAUDE_HOME/$dir/." "$GLOBAL_DIR/$dir/"
            log_info "Collected: $dir/"
        fi
    done

    # Collect hooks (if not symlinked)
    if [ -d "$CLAUDE_HOME/hooks" ] && [ ! -L "$CLAUDE_HOME/hooks" ]; then
        for hook in "$CLAUDE_HOME/hooks/"*.sh; do
            [ -f "$hook" ] || continue
            base=$(basename "$hook")
            if [ -f "$GLOBAL_DIR/hooks/$base" ]; then
                if ! diff -q "$hook" "$GLOBAL_DIR/hooks/$base" >/dev/null 2>&1; then
                    cp "$hook" "$GLOBAL_DIR/hooks/$base"
                    log_info "Collected hook: $base"
                fi
            fi
        done
    fi

    # Collect project-specific rules
    for project_dir in "$PROJECTS_DIR"/*/; do
        [ -d "$project_dir" ] || continue
        project_name=$(basename "$project_dir")
        project_path=$(find_project_path "$project_name")
        [ -n "$project_path" ] && [ -d "$project_path/.claude" ] || continue

        mkdir -p "$project_dir/rules"
        for rule in "$project_path/.claude/"*.md; do
            [ -f "$rule" ] || continue
            base=$(basename "$rule")
            cp "$rule" "$project_dir/rules/$base"
            log_info "Collected: $project_name/$base"
        done
    done

    log_info "Collect complete. Review changes with 'git diff'."
}

# ---- STATUS: Compare repo vs live ----
cmd_status() {
    log_info "Comparing repo vs live locations"
    log_info "Platform: $PLATFORM"
    echo ""

    local diffs=0

    # Global CLAUDE.md
    if [ -L "$CLAUDE_HOME/CLAUDE.md" ]; then
        echo "  CLAUDE.md: symlinked ✓"
    elif diff -q "$GLOBAL_DIR/CLAUDE.md" "$CLAUDE_HOME/CLAUDE.md" >/dev/null 2>&1; then
        echo "  CLAUDE.md: in sync ✓"
    else
        echo -e "  CLAUDE.md: ${RED}DIFFERS${NC}"
        diffs=$((diffs + 1))
    fi

    # Knowledge architecture directories
    for dir in foundation reference domains knowledge machines; do
        if [ -L "$CLAUDE_HOME/$dir" ]; then
            echo "  $dir/: symlinked ✓"
        elif [ -d "$CLAUDE_HOME/$dir" ]; then
            echo -e "  $dir/: ${YELLOW}EXISTS BUT NOT SYMLINKED${NC}"
            diffs=$((diffs + 1))
        elif [ -d "$GLOBAL_DIR/$dir" ]; then
            echo -e "  $dir/: ${YELLOW}NOT DEPLOYED${NC}"
            diffs=$((diffs + 1))
        fi
    done

    # Project-specific
    echo ""
    log_info "Project-specific rules:"
    for project_dir in "$PROJECTS_DIR"/*/; do
        [ -d "$project_dir" ] || continue
        project_name=$(basename "$project_dir")
        project_path=$(find_project_path "$project_name")

        if [ -z "$project_path" ] || [ ! -d "$project_path" ]; then
            echo "  $project_name: not on this machine"
            continue
        fi

        for rule in "$project_dir/rules/"*.md; do
            [ -f "$rule" ] || continue
            base=$(basename "$rule")
            target="$project_path/.claude/$base"
            if [ ! -f "$target" ]; then
                echo -e "  $project_name/$base: ${YELLOW}NOT DEPLOYED${NC}"
                diffs=$((diffs + 1))
            elif diff -q "$rule" "$target" >/dev/null 2>&1; then
                echo "  $project_name/$base: in sync ✓"
            else
                echo -e "  $project_name/$base: ${RED}DIFFERS${NC}"
                diffs=$((diffs + 1))
            fi
        done
    done

    # Agent roster summary
    echo ""
    log_info "Agent rosters:"
    for d in "$HOME"/*/; do
        [ -d "$d/.claude/agents" ] || continue
        count=$(find "$d/.claude/agents/" -maxdepth 1 -name "*.md" 2>/dev/null | wc -l)
        [ "$count" -gt 0 ] && echo "  $(basename "$d"): $count agents"
    done

    # Cross-project status
    local cross_dir="$SCRIPT_DIR/cross-project"
    if [ -d "$cross_dir" ]; then
        echo ""
        log_info "Cross-project state:"
        # Inbox pending count
        local inbox="$cross_dir/inbox.md"
        if [ -f "$inbox" ]; then
            local pending
            pending=$(grep -c '^\- \[ \]' "$inbox" 2>/dev/null || true)
            if [ "$pending" -gt 0 ] 2>/dev/null; then
                echo -e "  inbox.md: ${YELLOW}$pending pending task(s)${NC}"
            else
                echo "  inbox.md: empty ✓"
            fi
        fi
        # Strategy file freshness
        for f in "$cross_dir"/*-strategy.md "$cross_dir"/contacts.md "$cross_dir"/engagement-log.md; do
            [ -f "$f" ] || continue
            local base last_mod days_ago
            base=$(basename "$f")
            last_mod=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null)
            if [ -n "$last_mod" ]; then
                days_ago=$(( ($(date +%s) - last_mod) / 86400 ))
                if [ "$days_ago" -gt 14 ]; then
                    echo -e "  $base: ${YELLOW}last modified ${days_ago}d ago${NC}"
                else
                    echo "  $base: updated ${days_ago}d ago ✓"
                fi
            fi
        done
    fi

    echo ""
    if [ $diffs -eq 0 ]; then
        log_info "Everything in sync ✓"
    else
        log_warn "$diffs difference(s) found. Run 'deploy' or 'collect' to sync."
    fi
}

# ---- Helper: find project path by name ----
find_project_path() {
    local name="$1"
    # Check common locations
    for candidate in "$HOME/$name" "$HOME/projects/$name"; do
        if [ -d "$candidate" ]; then
            echo "$candidate"
            return
        fi
    done
    # Check registry for custom paths
    if [ -f "$SCRIPT_DIR/registry.md" ]; then
        # Extract path from registry table (format: | name | priority | path | desc | active |)
        local path
        path=$(grep -F "| $name |" "$SCRIPT_DIR/registry.md" 2>/dev/null | head -1 | awk -F'|' '{print $4}' | xargs | tr -d '`')
        if [ -n "$path" ]; then
            # Expand ~
            path="${path/#\~/$HOME}"
            if [ -d "$path" ]; then
                echo "$path"
            fi
        fi
    fi
}

# ---- Main ----
case "${1:-help}" in
    setup)   cmd_setup ;;
    deploy)  cmd_deploy ;;
    collect) cmd_collect ;;
    status)  cmd_status ;;
    *)
        echo "Usage: bash sync.sh {setup|deploy|collect|status}"
        echo ""
        echo "  setup   — Replace live files with symlinks to repo (recommended, one-time)"
        echo "  deploy  — Copy from repo → live locations (for non-symlink setups)"
        echo "  collect — Copy from live locations → repo (capture session edits)"
        echo "  status  — Show differences between repo and live"
        ;;
esac
