#!/usr/bin/env bash
# sync-lib/status.sh — Status command: compare repo vs live locations
# Sourced by sync.sh. Do not run directly.
#
# Provides: cmd_status
#
# Requires: SCRIPT_DIR, GLOBAL_DIR, PROJECTS_DIR, CLAUDE_HOME, PLATFORM,
#           RED, YELLOW, NC,
#           log_info, log_warn (from sync.sh)
# Also requires: find_project_path (from common.sh)

# ---- STATUS: Compare repo vs live ----
cmd_status() {
    log_info "Comparing repo vs live locations"
    log_info "Platform: $PLATFORM"

    # CFG-296: Report active machine overlay
    local _machine_dir
    _machine_dir=$(detect_machine_dir)
    if [[ -n "$_machine_dir" ]]; then
        local _overlay_dir="$SCRIPT_DIR/setup/config/machines/$_machine_dir"
        local _overlay_count=0
        if [[ -d "$_overlay_dir" ]]; then
            _overlay_count=$(find "$_overlay_dir" -maxdepth 1 -type f -not -name '.gitkeep' 2>/dev/null | wc -l)
        fi
        log_info "Machine overlay: $_machine_dir ($_overlay_count override files)"
    else
        log_info "Machine overlay: none"
    fi
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
        # Inbox pending count — only count task lines AFTER the divider marker,
        # so format documentation (code blocks above the marker) is not counted.
        local inbox="$cross_dir/inbox.md"
        if [ -f "$inbox" ]; then
            local pending
            pending=$(awk '/<!-- Pending tasks appear below this line -->/{found=1; next} found && /^\- \[ \]/{count++} END{print count+0}' "$inbox" 2>/dev/null || true)
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
