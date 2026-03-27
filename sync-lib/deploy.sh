#!/usr/bin/env bash
# sync-lib/deploy.sh — Deploy command: push config from repo to live locations
# Sourced by sync.sh. Do not run directly.
#
# Provides: cmd_deploy, deploy_settings, deploy_hooks, deploy_afd,
#           deploy_afleet, deploy_aliases, deploy_project_rules,
#           deploy_rosters, check_settings_health, apply_project_icons
#
# Requires: SCRIPT_DIR, GLOBAL_DIR, PROJECTS_DIR, CLAUDE_HOME, PLATFORM,
#           log_info, log_warn, log_error (from sync.sh)
# Also requires: find_project_path (from common.sh)
# Also requires: pre_deploy_checks (from pre-deploy.sh)
# Also requires: check_template_drift, check_personal_data_leaks (from check.sh)
# Also requires: clean_marketplace_plugins (from setup.sh)

# ---- DEPLOY: Copy from repo → live (for non-symlink setups or project rules) ----
cmd_deploy() {
    if ! pre_deploy_checks; then
        log_error "Pre-deploy checks failed — aborting deploy"
        return 1
    fi
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

    # Shared shell aliases
    deploy_aliases

    # DMS inbox drop folder
    if [ ! -d "$HOME/dms-inbox" ]; then
        mkdir -p "$HOME/dms-inbox"
        log_info "Created: ~/dms-inbox/ (DMS drop folder)"
    fi

    # Statusline script (canonical: setup/config/statusline-command.sh → ~/.claude/statusline-command.sh)
    if [ -f "$SCRIPT_DIR/setup/config/statusline-command.sh" ]; then
        cp "$SCRIPT_DIR/setup/config/statusline-command.sh" "$CLAUDE_HOME/statusline-command.sh"
        chmod +x "$CLAUDE_HOME/statusline-command.sh"
        log_info "Deployed: statusline-command.sh → $CLAUDE_HOME/"
        # Clean up legacy statusline.sh if it exists
        [ -f "$CLAUDE_HOME/statusline.sh" ] && rm -f "$CLAUDE_HOME/statusline.sh" && log_info "Removed legacy statusline.sh"
    fi

    # Deploy custom skills to cc-mirror config (where CC actually reads them)
    deploy_skills

    # Apply project folder icons (platform-appropriate)
    apply_project_icons

    # Clean unwanted marketplace plugins (auto-installed by Claude Code)
    clean_marketplace_plugins

    # Deploy settings.json to cc-mirror config (merges base template + live secrets)
    deploy_settings

    # Check live settings.json for missing critical blocks
    check_settings_health

    # Template drift check
    check_template_drift

    # Personal-data leak check on template
    check_personal_data_leaks

    # Per-project agent rosters from registry (CFG-220)
    deploy_rosters

    # AFD client and library
    deploy_afd

    # afleet launcher
    deploy_afleet

    log_info "Deploy complete."
}

deploy_settings() {
    local settings_base="$SCRIPT_DIR/setup/config/settings.json"
    local override="$SCRIPT_DIR/setup/config/settings.override.json"
    local live="${CC_MIRROR_DIR:-$HOME/.cc-mirror/mclaude}/config/settings.json"

    if [[ ! -f "$settings_base" ]]; then
        log_warn "No settings.json found — skipping settings deploy"
        return
    fi

    # CFG-296: Machine overlay — merge machine-specific settings onto base
    local effective_base="$settings_base"
    local machine_dir
    machine_dir=$(detect_machine_dir)
    if [[ -n "$machine_dir" ]]; then
        local machine_overlay="$SCRIPT_DIR/setup/config/machines/$machine_dir/settings.json"
        if [[ -f "$machine_overlay" ]]; then
            local overlay_tmp="${settings_base}.machine-overlay.tmp"
            if python3 "$SCRIPT_DIR/setup/scripts/json-overlay.py" "$settings_base" "$machine_overlay" > "$overlay_tmp" 2>/dev/null; then
                effective_base="$overlay_tmp"
                log_info "Applied machine overlay: $machine_dir/settings.json"
            else
                rm -f "$overlay_tmp"
                log_warn "Machine overlay merge failed — using base settings"
            fi
        fi
    fi

    local render_script="$SCRIPT_DIR/setup/scripts/render-template.sh"

    if [[ ! -f "$live" ]]; then
        # First deploy — render template and write
        log_info "First-time settings deploy → $live"
        if [[ -f "$render_script" ]]; then
            bash "$render_script" "$effective_base" > "$live"
        else
            sed "s|__HOME__|$HOME|g" "$effective_base" > "$live"
        fi
        # Clean up temp overlay file if created
        [[ "$effective_base" != "$settings_base" ]] && rm -f "$effective_base"
        return
    fi

    # Merge base template into live config (external script for maintainability):
    # - hooks, statusLine, spinnerTipsEnabled, enabledPlugins: base wins (authoritative)
    # - env: live preserved, base merged on top (so secrets survive, new vars added)
    # - permissions.allow: union of both (deduped)
    # - live-only keys (effortLevel, etc.): preserved
    python3 "$SCRIPT_DIR/setup/scripts/json-merge.py" "$effective_base" "$live" "$override" > "${live}.tmp"

    # Clean up temp overlay file if created
    [[ "$effective_base" != "$settings_base" ]] && rm -f "$effective_base"

    # Validate the output is valid JSON before replacing
    if python3 -c "import json; json.load(open('${live}.tmp'))" 2>/dev/null; then
        mv "${live}.tmp" "$live"
        log_info "Deployed settings.json → $live (merged: base hooks/structure + live secrets)"
    else
        rm -f "${live}.tmp"
        log_warn "Settings merge produced invalid JSON — live settings unchanged"
    fi
}

deploy_skills() {
    local skills_src="$SCRIPT_DIR/global/skills"
    local skills_dst="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills"
    [ -d "$skills_src" ] || return 0
    local deployed=0
    for skill_dir in "$skills_src"/*/; do
        [ -d "$skill_dir" ] || continue
        [ -f "$skill_dir/SKILL.md" ] || continue
        local skill_name
        skill_name=$(basename "$skill_dir")
        local target="$skills_dst/$skill_name"
        mkdir -p "$target"
        cp -r "$skill_dir"* "$target/"
        deployed=$((deployed + 1))
    done
    [ "$deployed" -gt 0 ] && log_info "Deployed $deployed custom skill(s) to $skills_dst"
}

deploy_hooks() {
    local managed_header="# MANAGED — DO NOT EDIT. Source: ~/cfg-agent-fleet/global/hooks/"
    mkdir -p "$CLAUDE_HOME/hooks"
    for hook in "$GLOBAL_DIR/hooks/"*.sh; do
        [ -f "$hook" ] || continue
        base=$(basename "$hook")
        # Remove existing read-only file before writing (v1.0: deployed hooks are 555)
        rm -f "$CLAUDE_HOME/hooks/$base"
        # Inject managed-file header after shebang (v1.0: deployed hooks are repo-managed)
        {
            head -1 "$hook"
            echo "${managed_header}${base}"
            tail -n +2 "$hook"
        } > "$CLAUDE_HOME/hooks/$base"
        chmod 555 "$CLAUDE_HOME/hooks/$base"
        log_info "Deployed hook: $base"
    done
    # Deploy hook subdirectories (e.g., checks/)
    for subdir in "$GLOBAL_DIR/hooks"/*/; do
        [ -d "$subdir" ] || continue
        local subdir_name
        subdir_name=$(basename "$subdir")
        mkdir -p "$CLAUDE_HOME/hooks/$subdir_name"
        for f in "$subdir"*.sh; do
            [ -f "$f" ] || continue
            local f_base
            f_base=$(basename "$f")
            rm -f "$CLAUDE_HOME/hooks/$subdir_name/$f_base"
            {
                head -1 "$f"
                echo "${managed_header}${subdir_name}/${f_base}"
                tail -n +2 "$f"
            } > "$CLAUDE_HOME/hooks/$subdir_name/$f_base"
            chmod 555 "$CLAUDE_HOME/hooks/$subdir_name/$f_base"
            log_info "Deployed hook: $subdir_name/$f_base"
        done
    done
}

deploy_afd() {
    local afd_dir="$SCRIPT_DIR/afd"
    if [ ! -d "$afd_dir" ]; then
        return 0
    fi

    mkdir -p "$HOME/.local/bin" "$HOME/.local/lib"

    if [ -f "$afd_dir/client/afd" ]; then
        cp "$afd_dir/client/afd" "$HOME/.local/bin/afd"
        chmod +x "$HOME/.local/bin/afd"
        log_info "Deployed: afd client → ~/.local/bin/"
    fi

    if [ -f "$afd_dir/lib/afd-lib.sh" ]; then
        cp "$afd_dir/lib/afd-lib.sh" "$HOME/.local/lib/afd-lib.sh"
        log_info "Deployed: afd-lib.sh → ~/.local/lib/"
    fi
}

deploy_afleet() {
    local wrapper_src="$SCRIPT_DIR/setup/scripts/afleet-wrapper.sh"
    local afleet_src="$SCRIPT_DIR/setup/scripts/afleet.sh"
    local nav_src="$SCRIPT_DIR/setup/scripts/afleet-nav.sh"
    local desktop_src="$SCRIPT_DIR/setup/config/afleet.desktop"

    mkdir -p "$HOME/.local/bin"

    # Prefer wrapper (CFG-256: copied, survives repo corruption)
    if [ -f "$wrapper_src" ]; then
        # Remove symlink if present (cp writes through symlinks)
        [ -L "$HOME/.local/bin/afleet" ] && rm "$HOME/.local/bin/afleet"
        cp "$wrapper_src" "$HOME/.local/bin/afleet"
        chmod +x "$HOME/.local/bin/afleet"
        log_info "Deployed: afleet-wrapper → ~/.local/bin/afleet (copied)"
    elif [ -f "$afleet_src" ]; then
        ln -sf "$afleet_src" "$HOME/.local/bin/afleet"
        log_info "Deployed: afleet → ~/.local/bin/ (symlink fallback)"
    fi

    if [ -f "$nav_src" ]; then
        ln -sf "$nav_src" "$HOME/.local/bin/afleet-nav"
        log_info "Deployed: afleet-nav → ~/.local/bin/ (symlink)"
    fi

    # Deploy .desktop file on KDE/GNOME (not WSL, not VPS)
    if [ -f "$desktop_src" ] && [ -d "$HOME/.local/share/applications" ] && [ -z "${WSL_DISTRO_NAME:-}" ]; then
        cp "$desktop_src" "$HOME/.local/share/applications/afleet.desktop"
        log_info "Deployed: afleet.desktop → ~/.local/share/applications/"
    fi

    # Deploy Windows .bat bridge (WSL only)
    local bat_src="$SCRIPT_DIR/setup/scripts/afleet.bat"
    if [ -f "$bat_src" ] && [ -n "${WSL_DISTRO_NAME:-}" ]; then
        local win_apps="/mnt/c/Users/$(powershell.exe -NoProfile -Command '[Environment]::UserName' 2>/dev/null | tr -d '\r')/AppData/Local/Microsoft/WindowsApps"
        if [ -d "$win_apps" ]; then
            cp "$bat_src" "$win_apps/afleet.bat"
            log_info "Deployed: afleet.bat → WindowsApps/ (Windows PATH)"
            local af_bat_src="$SCRIPT_DIR/setup/scripts/af.bat"
            if [ -f "$af_bat_src" ]; then
                cp "$af_bat_src" "$win_apps/af.bat"
                log_info "Deployed: af.bat → WindowsApps/ (Windows PATH)"
            fi
        fi
    fi
}

deploy_aliases() {
    local aliases_src="$SCRIPT_DIR/setup/config/aliases.sh"
    local aliases_dst="$HOME/.cfg-aliases.sh"
    local bashrc="$HOME/.bashrc"
    local marker="# agent-fleet: shared aliases"

    if [ ! -f "$aliases_src" ]; then
        return 0
    fi

    cp "$aliases_src" "$aliases_dst"
    log_info "Deployed: aliases.sh → ~/.cfg-aliases.sh"

    if ! grep -qF "$marker" "$bashrc" 2>/dev/null; then
        printf '\n%s\n[ -f ~/.cfg-aliases.sh ] && source ~/.cfg-aliases.sh\n' "$marker" >> "$bashrc"
        log_info "Added shared aliases source line to .bashrc"
    else
        log_info "Shared aliases already sourced in .bashrc"
    fi
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

deploy_rosters() {
    local roster_script="$SCRIPT_DIR/setup/scripts/setup-project-roster.sh"
    if [ -f "$roster_script" ]; then
        log_info "Deploying per-project agent rosters from registry..."
        bash "$roster_script" --all-local 2>&1 | while IFS= read -r line; do
            echo "  $line"
        done
    else
        log_warn "Roster script not found: $roster_script"
    fi
}

# ---- SETTINGS HEALTH CHECK ----
# Warns if live settings.json is missing critical blocks (permissions, hooks).
# A partial settings.json causes permission prompt storms and missing hooks.
check_settings_health() {
    local live_settings="${CC_MIRROR_DIR:-$HOME/.cc-mirror/mclaude}/config/settings.json"
    [ -f "$live_settings" ] || return 0

    local issues=0

    if ! grep -q '"permissions"' "$live_settings" 2>/dev/null; then
        log_warn "settings.json is missing 'permissions' block — all tool calls will require manual approval"
        log_warn "  Fix: redeploy from template: sed 's|__HOME__|$HOME|g' setup/config/settings.json > $live_settings"
        issues=$((issues + 1))
    fi

    if ! grep -q '"hooks"' "$live_settings" 2>/dev/null; then
        log_warn "settings.json is missing 'hooks' block — SessionStart/End hooks won't fire"
        issues=$((issues + 1))
    fi

    if ! grep -q '"enabledPlugins"' "$live_settings" 2>/dev/null; then
        log_warn "settings.json is missing 'enabledPlugins' block — skill plugins won't load"
        issues=$((issues + 1))
    fi

    if [ "$issues" -gt 0 ]; then
        log_warn "$issues critical block(s) missing from settings.json. Redeploy from template."
    fi
}

# ---- PROJECT FOLDER ICONS ----
# Applies priority-colored badge icons to project folders.
# Platform-detected: Windows (shortcut hub on NTFS) and/or KDE (.directory files).
apply_project_icons() {
    local icon_script="$SCRIPT_DIR/setup/scripts/project-icons.sh"
    [ -f "$icon_script" ] || return 0

    # Generate icons if they don't exist yet
    if [ ! -f "$SCRIPT_DIR/setup/icons/p1.ico" ]; then
        if python3 -c "from PIL import Image" 2>/dev/null; then
            log_info "Generating project badge icons..."
            bash "$icon_script" generate 2>/dev/null || log_warn "Icon generation failed (Pillow missing?)"
        else
            log_warn "Pillow not installed — skipping icon generation (pip install Pillow, or pipx run pip install Pillow on SteamOS)"
            return 0
        fi
    fi

    # Apply based on platform
    if [ -d /mnt/c/ ]; then
        # WSL — apply Windows shortcut hub
        log_info "Applying project folder icons (Windows shortcut hub)..."
        bash "$icon_script" apply-windows 2>/dev/null || log_warn "Windows icon application failed"
    fi

    if command -v kwriteconfig6 >/dev/null 2>&1 || command -v kwriteconfig5 >/dev/null 2>&1; then
        # KDE — apply .directory files
        log_info "Applying project folder icons (KDE Dolphin)..."
        bash "$icon_script" apply-kde 2>/dev/null || log_warn "KDE icon application failed"
    fi
}
