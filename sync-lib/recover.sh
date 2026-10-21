#!/usr/bin/env bash
# sync-lib/recover.sh — Emergency recover: copy from live locations back to repo
# Sourced by sync.sh. Do not run directly.
#
# Provides: cmd_recover
#
# Requires: SCRIPT_DIR, GLOBAL_DIR, PROJECTS_DIR, CLAUDE_HOME,
#           log_info, log_warn, log_error (from sync.sh)
# Also requires: find_project_path (from common.sh)
# Also requires: _sed_i (from lib-portable.sh via common.sh)

# ---- RECOVER: Copy from live locations → repo (emergency only) ----
# v1.0: renamed from cmd_collect. Normal workflow is deploy-only.
# Use this ONLY when deployed files have edits not yet in the repo.
cmd_recover() {
    if [[ "${1:-}" != "--emergency" ]]; then
        echo "ERROR: recover requires --emergency flag." >&2
        echo "This command copies deployed files BACK into the repo." >&2
        echo "Normal workflow is deploy-only (repo → live)." >&2
        echo "Only use this for emergency recovery of unsaved local edits." >&2
        echo "" >&2
        echo "Usage: bash sync.sh recover --emergency" >&2
        return 1
    fi
    shift  # consume --emergency
    log_info "EMERGENCY RECOVER: Collecting config from live locations → repo"

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
            # Per-file timestamp guard: skip files where repo version is newer
            # than deployed version. Prevents stale deployed files from overwriting
            # features committed on other machines.
            local dir_collected=0 dir_skipped=0
            for deployed_file in "$CLAUDE_HOME/$dir/"*; do
                [ -f "$deployed_file" ] || continue
                local base
                base=$(basename "$deployed_file")

                local repo_file="$GLOBAL_DIR/$dir/$base"
                [ -f "$repo_file" ] || continue

                # Skip if files are identical
                if diff -q "$deployed_file" "$repo_file" >/dev/null 2>&1; then
                    continue
                fi

                # Timestamp guard: skip if repo version is newer
                local repo_commit_ts deployed_mtime
                repo_commit_ts=$(git -C "$SCRIPT_DIR" log -1 --format='%ct' -- "global/$dir/$base" 2>/dev/null || echo "0")
                deployed_mtime=$(stat -c '%Y' "$deployed_file" 2>/dev/null || stat -f '%m' "$deployed_file" 2>/dev/null || echo "0")
                if [ "$repo_commit_ts" -gt "$deployed_mtime" ]; then
                    log_warn "Skipping $dir/$base — repo version is newer than deployed (run 'sync.sh deploy' to update)"
                    dir_skipped=$((dir_skipped + 1))
                    continue
                fi

                cp "$deployed_file" "$repo_file"
                dir_collected=$((dir_collected + 1))
            done
            [ "$dir_collected" -gt 0 ] && log_info "Collected: $dir/ ($dir_collected file(s))"
            [ "$dir_skipped" -gt 0 ] && log_warn "Skipped $dir_skipped file(s) in $dir/ — repo newer"
        fi
    done

    # Collect hooks (if not symlinked)
    if [ -d "$CLAUDE_HOME/hooks" ] && [ ! -L "$CLAUDE_HOME/hooks" ]; then
        for hook in "$CLAUDE_HOME/hooks/"*.sh; do
            [ -f "$hook" ] || continue
            base=$(basename "$hook")
            if [ -f "$GLOBAL_DIR/hooks/$base" ]; then
                # Safety 1: skip if the source has uncommitted changes (editing hazard)
                if git -C "$SCRIPT_DIR" diff --name-only 2>/dev/null | grep -q "global/hooks/$base"; then
                    log_warn "Skipping hook collect: $base has uncommitted edits in repo"
                    # Persist warning for SessionStart check 18 to surface
                    local _marker="$SCRIPT_DIR/.collect-uncommitted-hooks"
                    if [ ! -f "$_marker" ]; then
                        echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$_marker"
                        echo "files=$base" >> "$_marker"
                    else
                        # Append file if not already listed
                        grep -q "$base" "$_marker" 2>/dev/null || \
                            _sed_i "s/^files=\(.*\)/files=\1 $base/" "$_marker"
                    fi
                    continue
                fi
                # Safety 2: skip if repo version is newer than deployed version
                # This prevents stale deployed hooks from overwriting features
                # committed on other machines (the multi-machine collect bug).
                local repo_commit_ts deployed_mtime
                repo_commit_ts=$(git -C "$SCRIPT_DIR" log -1 --format='%ct' -- "global/hooks/$base" 2>/dev/null || echo "0")
                deployed_mtime=$(stat -c '%Y' "$hook" 2>/dev/null || stat -f '%m' "$hook" 2>/dev/null || echo "0")
                if [ "$repo_commit_ts" -gt "$deployed_mtime" ]; then
                    log_warn "Skipping hook collect: $base — repo version is newer than deployed (run 'sync.sh deploy' to update deployed hooks)"
                    continue
                fi
                if ! diff -q "$hook" "$GLOBAL_DIR/hooks/$base" >/dev/null 2>&1; then
                    # Strip managed header before collecting back to source (CFG-300)
                    sed '/^# MANAGED/d' "$hook" > "$GLOBAL_DIR/hooks/$base"
                    log_info "Collected hook: $base (managed header stripped)"
                fi
            fi
        done
        # Collect hook subdirectories (e.g., checks/)
        for subdir in "$CLAUDE_HOME/hooks"/*/; do
            [ -d "$subdir" ] || continue
            local subdir_name
            subdir_name=$(basename "$subdir")
            [ -d "$GLOBAL_DIR/hooks/$subdir_name" ] || continue
            for f in "$subdir"*.sh; do
                [ -f "$f" ] || continue
                local f_base
                f_base=$(basename "$f")
                if [ -f "$GLOBAL_DIR/hooks/$subdir_name/$f_base" ]; then
                    if ! diff -q "$f" "$GLOBAL_DIR/hooks/$subdir_name/$f_base" >/dev/null 2>&1; then
                        # Strip managed header before collecting back to source (CFG-300)
                        sed '/^# MANAGED/d' "$f" > "$GLOBAL_DIR/hooks/$subdir_name/$f_base"
                        log_info "Collected hook: $subdir_name/$f_base (managed header stripped)"
                    fi
                fi
            done
        done
    fi

    # Clean up collect marker if no uncommitted hooks remain
    if [ -f "$SCRIPT_DIR/.collect-uncommitted-hooks" ]; then
        if ! git -C "$SCRIPT_DIR" diff --name-only 2>/dev/null | grep -q "^global/hooks/"; then
            rm -f "$SCRIPT_DIR/.collect-uncommitted-hooks"
        fi
    fi

    # Collect project-specific rules
    for project_dir in "$PROJECTS_DIR"/*/; do
        [ -d "$project_dir" ] || continue
        project_name=$(basename "$project_dir")
        project_path=$(find_project_path "$project_name")
        [ -n "$project_path" ] && [ -d "$project_path/.claude" ] || continue

        mkdir -p "$project_dir/rules"
        local rules_collected=0 rules_skipped=0
        for rule in "$project_path/.claude/"*.md; do
            [ -f "$rule" ] || continue
            local base
            base=$(basename "$rule")

            # Skip if files are identical
            if [ -f "$project_dir/rules/$base" ] && diff -q "$rule" "$project_dir/rules/$base" >/dev/null 2>&1; then
                continue
            fi

            # Timestamp guard: if repo version is newer than deployed, skip collection
            # to avoid overwriting commits from other machines with stale local files.
            local repo_commit_ts deployed_mtime
            repo_commit_ts=$(git -C "$SCRIPT_DIR" log -1 --format='%ct' -- "setup/projects/$project_name/rules/$base" 2>/dev/null || echo "0")
            deployed_mtime=$(stat -c '%Y' "$rule" 2>/dev/null || stat -f '%m' "$rule" 2>/dev/null || echo "0")
            if [ "$repo_commit_ts" -gt "$deployed_mtime" ]; then
                log_warn "Skipping $project_name/$base — repo version is newer than deployed (run 'sync.sh deploy' to update)"
                rules_skipped=$((rules_skipped + 1))
                continue
            fi

            cp "$rule" "$project_dir/rules/$base"
            rules_collected=$((rules_collected + 1))
            log_info "Collected: $project_name/$base"
        done
        if [ "$rules_skipped" -gt 0 ]; then
            log_info "Project $project_name rules: $rules_collected collected, $rules_skipped skipped"
        fi
    done

    log_info "Collect complete. Review changes with 'git diff'."
}
