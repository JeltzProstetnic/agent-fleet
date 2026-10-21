#!/usr/bin/env bash
# sync-lib/setup.sh — Setup command: symlink live locations to repo
# Sourced by sync.sh. Do not run directly.
#
# Provides: cmd_setup, run_provisioning_checks, verify_setup, clean_marketplace_plugins,
#           _replace_dir_with_link, setup_arm_githooks
#
# Requires: SCRIPT_DIR, GLOBAL_DIR, PROJECTS_DIR, CLAUDE_HOME, PLATFORM,
#           SETUP_VERIFIED_MARKER, SETUP_FAILED_MARKER,
#           log_info, log_warn, log_error, _readlink_f (from sync.sh)
# Also requires: get_hostname (from common.sh)
# Also requires: deploy_hooks, deploy_project_rules, deploy_aliases,
#                deploy_afleet (from deploy.sh)

# ---- _replace_dir_with_link <src> <dst> (CFG-700) ----
# Replace dst with a link (or, in copy mode, a copy) of src. A real directory at dst is
# moved to <dst>.bak.<epoch> first — in copy mode too, unless it is an unchanged
# previous copy — because _link_dir's copy mode would otherwise rm -rf unbacked content.
_replace_dir_with_link() {
    local src="$1" dst="$2"
    if [ -L "$dst" ]; then
        rm -f "$dst"
    elif [ -d "$dst" ]; then
        if _can_symlink || ! diff -rq "$src" "$dst" >/dev/null 2>&1; then
            log_warn "$dst exists as directory — backing up"
            mv "$dst" "${dst}.bak.$(date +%s)"
        fi
    fi
    _link_dir "$src" "$dst"
}

# ---- setup_arm_githooks (CFG-700, replaces the template-only hooksPath block) ----
setup_arm_githooks() {
    local script="$SCRIPT_DIR/setup/scripts/ensure-githooks.sh"
    [ -f "$script" ] || return 0
    bash "$script" "$SCRIPT_DIR" || log_warn "Could not arm .githooks in $SCRIPT_DIR"
    return 0
}

# ---- SETUP: Replace live files with symlinks to repo ----
cmd_setup() {
    log_info "Setting up symlinks from live locations → repo"
    log_info "Platform: $PLATFORM"

    # Ensure ~/.claude exists as a real directory (not a symlink)
    if [ -L "$CLAUDE_HOME" ]; then
        log_warn "$CLAUDE_HOME is a symlink — removing and creating directory"
        rm "$CLAUDE_HOME"
    fi
    mkdir -p "$CLAUDE_HOME"

    # Backup existing files
    if [ -f "$CLAUDE_HOME/CLAUDE.md" ] && [ ! -L "$CLAUDE_HOME/CLAUDE.md" ]; then
        log_info "Backing up existing $CLAUDE_HOME/CLAUDE.md"
        cp "$CLAUDE_HOME/CLAUDE.md" "$CLAUDE_HOME/CLAUDE.md.bak"
    fi

    # Global CLAUDE.md
    _link_file "$GLOBAL_DIR/CLAUDE.md" "$CLAUDE_HOME/CLAUDE.md"
    log_info "Linked: $CLAUDE_HOME/CLAUDE.md → $GLOBAL_DIR/CLAUDE.md"

    # Knowledge architecture directories (directory symlinks)
    for dir in foundation reference domains knowledge machines skills; do
        if [ -d "$GLOBAL_DIR/$dir" ]; then
            _replace_dir_with_link "$GLOBAL_DIR/$dir" "$CLAUDE_HOME/$dir"
            log_info "Linked: $CLAUDE_HOME/$dir → $GLOBAL_DIR/$dir"
        fi
    done

    # Arm the repo's tracked .githooks/ guard (pre-push leak gate)
    setup_arm_githooks

    # Hooks
    deploy_hooks

    # Project-specific rules
    deploy_project_rules

    # Shared shell aliases
    deploy_aliases

    # afleet launcher
    deploy_afleet

    # `repro` shortcut (SteamOS only)
    deploy_repro

    # Create CLAUDE.local.md if missing (machine-specific @import)
    if [[ ! -f "$HOME/CLAUDE.local.md" ]]; then
        # Auto-detect machine file from hostname
        local machine_file=""
        local hn
        hn=$(get_hostname)

        # Try user-defined hostname map first (from sync.local.sh)
        if type local_hostname_map &>/dev/null; then
            machine_file=$(local_hostname_map "$hn")
        fi

        # Fall back to framework defaults (commented examples for new users)
        if [[ -z "$machine_file" ]]; then
            case "$hn" in
                # Example: map your hostnames to machine definition files
                # my-vps-*)       machine_file="vps.md" ;;
                # DESKTOP-*)      machine_file="wsl.md" ;;
                # my-handheld*)   machine_file="handheld.md" ;;
                # my-workstation*)
                #     if [[ "$(whoami)" == "work-user" ]]; then
                #         machine_file="office.md"
                #     else
                #         machine_file="home.md"
                #     fi
                #     ;;
                *) ;;  # No match
            esac
        fi

        if [[ -n "$machine_file" && -f "$CLAUDE_HOME/machines/$machine_file" ]]; then
            echo "@~/.claude/machines/$machine_file" > "$HOME/CLAUDE.local.md"
            log_info "Created CLAUDE.local.md → machines/$machine_file"
        else
            log_warn "Could not auto-detect machine — create ~/CLAUDE.local.md manually"
            log_warn "  echo '@~/.claude/machines/<machine>.md' > ~/CLAUDE.local.md"
        fi
    else
        log_info "CLAUDE.local.md already exists"
    fi

    # Run user-defined post-setup hook (from sync.local.sh)
    if type local_post_setup &>/dev/null; then
        local_post_setup
    fi

    # Clean unwanted marketplace plugins
    clean_marketplace_plugins

    # Provisioning checks: VoltAgent, skill collections, CC version
    run_provisioning_checks

    # Verify setup was successful
    if verify_setup; then
        log_info "Setup complete. Live locations now symlinked to repo."
        log_warn "Restart Claude Code for changes to take effect."
    else
        log_error "Setup completed but verification FAILED."
        log_error "Some checks did not pass. Review the errors above."
        log_error "DO NOT start a Claude Code session until this is fixed."
        exit 1
    fi
}

# ---- PROVISIONING CHECKS: VoltAgent, skill collections, CC version (CFG-219) ----
# Runs after core setup. Checks if optional provisioning steps have been completed
# and executes them if not. Non-blocking: failures warn but don't fail setup.
run_provisioning_checks() {
    log_info "Running provisioning checks..."

    local config_dir="${CC_MIRROR_DIR:-$HOME/.cc-mirror/mclaude}/config"
    local voltagent_script="${VOLTAGENT_INSTALL_SCRIPT:-$SCRIPT_DIR/setup/scripts/install-voltagent.sh}"
    local skill_script="${SKILL_COLLECTIONS_INSTALL_SCRIPT:-$SCRIPT_DIR/setup/scripts/install-skill-collections.sh}"

    # 1. VoltAgent marketplace
    local voltagent_marker="$config_dir/plugins/marketplace.json"
    if [[ -f "$voltagent_marker" ]]; then
        log_info "VoltAgent marketplace: installed"
    else
        log_warn "VoltAgent marketplace not found — attempting install..."
        if [[ -f "$voltagent_script" ]]; then
            if bash "$voltagent_script" 2>&1; then
                log_info "VoltAgent marketplace: installed successfully"
            else
                log_warn "VoltAgent install failed — run manually: bash $voltagent_script"
            fi
        else
            log_warn "VoltAgent install script not found: $voltagent_script"
        fi
    fi

    # 2. Skill collections
    local skill_dir="$HOME/.local/share/skill-collections"
    local skill_count=0
    if [[ -d "$skill_dir" ]]; then
        skill_count=$(find "$skill_dir" -maxdepth 2 -name ".git" -type d 2>/dev/null | wc -l)
    fi
    if [[ "$skill_count" -gt 0 ]]; then
        log_info "Skill collections: installed ($skill_count repo(s))"
    else
        log_warn "Skill collections not found — attempting install..."
        if [[ -f "$skill_script" ]]; then
            if bash "$skill_script" 2>&1; then
                log_info "Skill collections: installed successfully"
            else
                log_warn "Skill collections install failed — run manually: bash $skill_script"
            fi
        else
            log_warn "Skill collections install script not found: $skill_script"
        fi
    fi

    # 3. Claude Code version (informational only — don't auto-update)
    local cc_pkg="${CC_MIRROR_DIR:-$HOME/.cc-mirror/mclaude}/npm/node_modules/@anthropic-ai/claude-code/package.json"
    if [[ -f "$cc_pkg" ]]; then
        local cc_version
        local _py_cc_pkg
        _py_cc_pkg=$(_to_native_path "$cc_pkg")
        cc_version=$(python3 -c "import json; print(json.load(open('$_py_cc_pkg'))['version'])" 2>/dev/null || echo "unknown")
        log_info "Claude Code version: $cc_version"
    else
        log_warn "Claude Code: not found at $cc_pkg"
    fi
}

# ---- VERIFY: Check that setup completed correctly ----
# Hard errors = symlinks broken, setup genuinely failed. Block launch.
# Soft warnings = first-run items not yet configured. Warn but pass.
verify_setup() {
    local hard_failures=()
    local soft_warnings=()

    # V1: CLAUDE.md linked (symlink or copy on Windows) (hard)
    if ! _check_linked "$CLAUDE_HOME/CLAUDE.md"; then
        hard_failures+=("V1:CLAUDE.md not linked")
    fi

    # V2: CLAUDE.md link target valid (hard)
    if _check_linked "$CLAUDE_HOME/CLAUDE.md" && ! _check_linked_valid "$CLAUDE_HOME/CLAUDE.md"; then
        hard_failures+=("V2:CLAUDE.md link target missing")
    fi

    # V3-V7: Knowledge architecture directories (hard)
    local idx=3
    for dir in foundation reference domains knowledge machines; do
        if ! _check_linked "$CLAUDE_HOME/$dir"; then
            hard_failures+=("V${idx}:$dir not linked")
        fi
        ((idx++))
    done

    # V8: CLAUDE.local.md exists (soft — created during first session)
    if [ ! -f "$HOME/CLAUDE.local.md" ]; then
        soft_warnings+=("V8:~/CLAUDE.local.md missing — will be created during first session")
    fi

    # V9: CLAUDE.local.md target valid (soft — depends on V8)
    if [ -f "$HOME/CLAUDE.local.md" ]; then
        local import_target
        import_target=$(grep '^@' "$HOME/CLAUDE.local.md" | head -1 | sed 's/^@//' | sed "s|~|$HOME|g")
        if [ -n "$import_target" ] && [ ! -f "$import_target" ]; then
            soft_warnings+=("V9:CLAUDE.local.md @import target missing: $import_target")
        fi
    fi

    # V10: Hooks deployed (hard)
    if [ ! -f "$CLAUDE_HOME/hooks/config-check.sh" ]; then
        hard_failures+=("V10:SessionStart hook not deployed")
    fi

    # V11: Hooks executable (hard)
    if [ -f "$CLAUDE_HOME/hooks/config-check.sh" ] && [ ! -x "$CLAUDE_HOME/hooks/config-check.sh" ]; then
        hard_failures+=("V11:SessionStart hook not executable")
    fi

    # Report soft warnings (don't block)
    if [ ${#soft_warnings[@]} -gt 0 ]; then
        for w in "${soft_warnings[@]}"; do
            log_warn "  $w"
        done
    fi

    if [ ${#hard_failures[@]} -eq 0 ]; then
        local total_checks=11
        local warn_count=${#soft_warnings[@]}
        cat > "$SETUP_VERIFIED_MARKER" << EOF
verified=$(date -u +%Y-%m-%dT%H:%M:%SZ)
machine=$(get_hostname)
config_repo=$SCRIPT_DIR
checks_passed=$((total_checks - warn_count))
warnings=$warn_count
EOF
        rm -f "$SETUP_FAILED_MARKER"
        if [ "$warn_count" -gt 0 ]; then
            log_info "Setup verification PASSED ($warn_count non-blocking warning(s) above)"
        else
            log_info "Setup verification PASSED (all $total_checks checks)"
        fi
        return 0
    else
        {
            echo "failed=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            echo "machine=$(get_hostname)"
            echo "config_repo=$SCRIPT_DIR"
            printf 'failed_checks=%s\n' "${hard_failures[*]}"
        } > "$SETUP_FAILED_MARKER"
        rm -f "$SETUP_VERIFIED_MARKER"
        log_error "Setup verification FAILED:"
        for check in "${hard_failures[@]}"; do
            log_error "  - $check"
        done
        return 1
    fi
}

# ---- Clean unwanted marketplace plugins (used by both setup and deploy) ----
clean_marketplace_plugins() {
    local script="$SCRIPT_DIR/setup/scripts/clean-marketplace-plugins.sh"
    if [ -f "$script" ]; then
        bash "$script" 2>/dev/null || log_warn "Marketplace plugin cleanup returned non-zero"
    fi
}
