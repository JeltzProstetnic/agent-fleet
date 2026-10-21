#!/usr/bin/env bash
# sync-lib/deploy.sh — Deploy command: push config from repo to live locations
# Sourced by sync.sh. Do not run directly.
#
# Provides: cmd_deploy, deploy_settings, deploy_hooks, deploy_skills,
#           deploy_agents, deploy_afd, deploy_afleet, deploy_repro, deploy_aliases,
#           deploy_project_rules, deploy_rosters, check_settings_health,
#           apply_project_icons
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

    # Deploy custom agent definitions to cc-mirror config (CFG-438)
    deploy_agents

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

    # `repro` shortcut (SteamOS only)
    deploy_repro

    # Clear stale sync-failed marker on successful deploy
    rm -f "$SCRIPT_DIR/.sync-failed"

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

    # No cc-mirror config dir (fresh box, non-mirror install): writing would fail and,
    # under `set -e`, truncate cmd_deploy. Warn and leave settings alone.
    if [[ ! -d "$(dirname "$live")" ]]; then
        log_warn "No Claude Code config dir at $(dirname "$live") — skipping settings deploy"
        [[ "$effective_base" != "$settings_base" ]] && rm -f "$effective_base"
        return 0
    fi

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

    # Validate: valid JSON + no test-path contamination in env vars
    local _py_live_tmp
    _py_live_tmp=$(_to_native_path "${live}.tmp")
    if python3 -c "import json; json.load(open('$_py_live_tmp'))" 2>/dev/null; then
        if grep -qE '/tmp/cfgtest|/tmp/pytest|/tmp/bats' "${live}.tmp" 2>/dev/null; then
            rm -f "${live}.tmp"
            log_warn "Settings merge contains test paths — aborting deploy to prevent env contamination"
            return
        fi
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
        # A machine may already have the skill symlinked straight back into the repo.
        # Source and destination are then the SAME directory, `cp` fails with "are the
        # same file", and under sync.sh's `set -euo pipefail` that aborts the ENTIRE
        # deploy here — everything after deploy_skills (deploy_settings included) silently
        # never runs, leaving new hooks on disk but wired into nothing. Some bash builds
        # carry on past the failure, so it can reproduce on the target and not on the box
        # you fix it from: assert the absence of the error, not the exit code.
        if [ -e "$target" ] && [ "$(readlink -f "$target")" = "$(readlink -f "${skill_dir%/}")" ]; then
            deployed=$((deployed + 1))
            continue
        fi
        mkdir -p "$target"
        cp -r "$skill_dir"* "$target/"
        deployed=$((deployed + 1))
    done
    [ "$deployed" -gt 0 ] && log_info "Deployed $deployed custom skill(s) to $skills_dst"
    # Never end on a failing test: with no skills at all, `[ 0 -gt 0 ]` is this function's
    # last command, so it would return 1 and set -e would abort the deploy on a machine
    # that simply has none.
    return 0
}

# Deploy custom agent definitions (markdown with frontmatter) from global/agents/
# to the dir Claude Code actually reads user-level agents from ($CLAUDE_CONFIG_DIR/agents/,
# which is ~/.cc-mirror/mclaude/config/agents/ under mclaude). Flat *.md files, one per agent.
# No orphan cleanup: the agents dir may hold user-placed agents we must not delete.
deploy_agents() {
    local agents_src="$SCRIPT_DIR/global/agents"
    local agents_dst="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/agents"
    [ -d "$agents_src" ] || return 0
    local deployed=0
    for agent_file in "$agents_src"/*.md; do
        [ -f "$agent_file" ] || continue
        mkdir -p "$agents_dst"
        cp "$agent_file" "$agents_dst/$(basename "$agent_file")"
        deployed=$((deployed + 1))
    done
    [ "$deployed" -gt 0 ] && log_info "Deployed $deployed custom agent(s) to $agents_dst"
}

deploy_hooks() {
    local managed_header="# MANAGED — DO NOT EDIT. Source: $SCRIPT_DIR/global/hooks/"
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
        # Clean orphaned hooks: remove deployed files that no longer exist in repo
        for deployed in "$CLAUDE_HOME/hooks/$subdir_name/"*.sh; do
            [ -f "$deployed" ] || continue
            local d_base
            d_base=$(basename "$deployed")
            if [ ! -f "$subdir$d_base" ]; then
                rm -f "$deployed"
                log_info "Removed orphaned hook: $subdir_name/$d_base"
            fi
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
        # rm + cp, not the GNU-only cp flag that unlinks the target (BSD/macOS lack it; a running
        # afd binary is replaced by unlinking first, never written in place)
        rm -f "$HOME/.local/bin/afd" && cp "$afd_dir/client/afd" "$HOME/.local/bin/afd"
        chmod +x "$HOME/.local/bin/afd"
        log_info "Deployed: afd client → ~/.local/bin/"
    fi

    if [ -f "$afd_dir/lib/afd-lib.sh" ]; then
        cp "$afd_dir/lib/afd-lib.sh" "$HOME/.local/lib/afd-lib.sh"
        log_info "Deployed: afd-lib.sh → ~/.local/lib/"
    fi
}

# deploy_repro — SteamOS only: ~/.local/bin/repro → setup/reprovision-steamos.sh, so an OS
# update is repaired by typing `repro` from any folder. Never replaces an
# unrelated `repro`; OS_RELEASE_FILE overrides /etc/os-release for tests.
deploy_repro() {
    local src="$SCRIPT_DIR/setup/reprovision-steamos.sh" dst="$HOME/.local/bin/repro"
    local os_release="${OS_RELEASE_FILE:-/etc/os-release}"
    grep -qiE '^ID(_LIKE)?=.*(steamos|holo)' "$os_release" 2>/dev/null || return 0
    [ -f "$src" ] || return 0
    mkdir -p "$HOME/.local/bin"
    if [ -e "$dst" ] || [ -L "$dst" ]; then
        if [ "$(readlink -f "$dst" 2>/dev/null)" != "$(readlink -f "$src")" ]; then
            log_warn "Skipped 'repro' shortcut: an unrelated repro exists at $dst"
            return 0
        fi
    fi
    _link_file "$src" "$dst"
    log_info "Deployed: repro → reprovision-steamos.sh (~/.local/bin/)"
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
        _check_linked "$HOME/.local/bin/afleet" && rm "$HOME/.local/bin/afleet"
        cp "$wrapper_src" "$HOME/.local/bin/afleet"
        chmod +x "$HOME/.local/bin/afleet"
        log_info "Deployed: afleet-wrapper → ~/.local/bin/afleet (copied)"
    elif [ -f "$afleet_src" ]; then
        _link_file "$afleet_src" "$HOME/.local/bin/afleet"
        log_info "Deployed: afleet → ~/.local/bin/ (linked)"
    fi

    if [ -f "$nav_src" ]; then
        _link_file "$nav_src" "$HOME/.local/bin/afleet-nav"
        log_info "Deployed: afleet-nav → ~/.local/bin/ (linked)"
    fi

    # Deploy .desktop file on KDE/GNOME (not WSL, not VPS)
    if [ -f "$desktop_src" ] && [ -d "$HOME/.local/share/applications" ] && [ -z "${WSL_DISTRO_NAME:-}" ]; then
        cp "$desktop_src" "$HOME/.local/share/applications/afleet.desktop"
        log_info "Deployed: afleet.desktop → ~/.local/share/applications/"
    fi

    # Deploy 'af' shortcut (CFG-507). Through install_af_shortcut (setup/lib.sh) — the same
    # guard install.sh uses — so it never clobbers or shadows an unrelated `af`. This runs in
    # `sync.sh setup` BEFORE install.sh's own af block and on every SessionEnd deploy; an
    # unguarded link here made the installer's guard dead. lib.sh is sourced in a subshell
    # so its set -e and log_* stay out of sync.sh.
    if [ -x "$HOME/.local/bin/afleet" ]; then
        local af_copy_src="$wrapper_src" af_conflict=""
        [ -f "$af_copy_src" ] || af_copy_src="$afleet_src"
        if af_conflict=$( source "$SCRIPT_DIR/setup/lib.sh" >/dev/null 2>&1 \
                && install_af_shortcut "$af_copy_src" "$HOME/.local/bin/af" ); then
            log_info "Deployed: af → afleet (standard fleet shortcut)"
        elif [ -n "$af_conflict" ]; then
            log_warn "Skipped 'af' shortcut: an unrelated 'af' exists at $af_conflict — use 'afleet'"
        else
            log_warn "Skipped 'af' shortcut: could not load setup/lib.sh"
        fi
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
