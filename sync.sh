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
PROJECTS_DIR="$SCRIPT_DIR/setup/projects"

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

# Verification markers
SETUP_VERIFIED_MARKER="$CLAUDE_HOME/.setup-verified"
SETUP_FAILED_MARKER="$CLAUDE_HOME/.setup-failed"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Source user-local overrides (hostname map, post-setup hook) if present
if [[ -f "$SCRIPT_DIR/sync.local.sh" ]]; then
    source "$SCRIPT_DIR/sync.local.sh"
fi

# Source modular libraries
source "$SCRIPT_DIR/sync-lib/common.sh"
source "$SCRIPT_DIR/sync-lib/check.sh"
source "$SCRIPT_DIR/sync-lib/pre-deploy.sh"

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
    ln -sf "$GLOBAL_DIR/CLAUDE.md" "$CLAUDE_HOME/CLAUDE.md"
    log_info "Linked: $CLAUDE_HOME/CLAUDE.md → $GLOBAL_DIR/CLAUDE.md"

    # Knowledge architecture directories (directory symlinks)
    for dir in foundation reference domains knowledge machines skills; do
        if [ -d "$GLOBAL_DIR/$dir" ]; then
            # Remove whatever exists at the target — symlink, directory, or file
            if [ -L "$CLAUDE_HOME/$dir" ]; then
                rm -f "$CLAUDE_HOME/$dir"
            elif [ -d "$CLAUDE_HOME/$dir" ]; then
                log_warn "$CLAUDE_HOME/$dir exists as directory — backing up"
                mv "$CLAUDE_HOME/$dir" "$CLAUDE_HOME/${dir}.bak.$(date +%s)"
            fi
            # Use ln -sfn: -n prevents following existing symlink-to-dir
            ln -sfn "$GLOBAL_DIR/$dir" "$CLAUDE_HOME/$dir"
            log_info "Linked: $CLAUDE_HOME/$dir → $GLOBAL_DIR/$dir"
        fi
    done

    # Hooks
    deploy_hooks

    # Project-specific rules
    deploy_project_rules

    # Shared shell aliases
    deploy_aliases

    # afleet launcher
    deploy_afleet

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
                # steamdeck*)     machine_file="steamdeck.md" ;;
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

    # Run provisioning checks (VoltAgent, skill collections, CC version)
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

# ---- PROVISIONING: Verify and install additional components ----
# Non-blocking — failures warn but don't prevent setup completion.
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
        cc_version=$(python3 -c "import json; print(json.load(open('$cc_pkg'))['version'])" 2>/dev/null || echo "unknown")
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

    # V1: CLAUDE.md symlink exists (hard)
    if [ ! -L "$CLAUDE_HOME/CLAUDE.md" ]; then
        hard_failures+=("V1:CLAUDE.md not symlinked")
    fi

    # V2: CLAUDE.md symlink target valid (hard)
    if [ -L "$CLAUDE_HOME/CLAUDE.md" ] && [ ! -f "$(readlink -f "$CLAUDE_HOME/CLAUDE.md")" ]; then
        hard_failures+=("V2:CLAUDE.md symlink target missing")
    fi

    # V3-V7: Knowledge architecture directories (hard)
    local idx=3
    for dir in foundation reference domains knowledge machines; do
        if [ ! -L "$CLAUDE_HOME/$dir" ]; then
            hard_failures+=("V${idx}:$dir not symlinked")
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

    # Apply project folder icons (platform-appropriate)
    apply_project_icons

    # Clean unwanted marketplace plugins (auto-installed by Claude Code)
    clean_marketplace_plugins

    # Validate settings merge (actual deploy is manual / check_settings_health validates live)
    validate_settings_merge

    # Check live settings.json for missing critical blocks
    check_settings_health

    # Template drift check
    check_template_drift

    # Personal-data leak check on template
    check_personal_data_leaks

    # AFD client and library
    deploy_afd

    # afleet launcher
    deploy_afleet

    log_info "Deploy complete."
}

clean_marketplace_plugins() {
    local script="$SCRIPT_DIR/setup/scripts/clean-marketplace-plugins.sh"
    if [ -f "$script" ]; then
        bash "$script" 2>/dev/null || log_warn "Marketplace plugin cleanup returned non-zero"
    fi
}

validate_settings_merge() {
    local base="$SCRIPT_DIR/setup/config/settings.json"
    local override="$SCRIPT_DIR/setup/config/settings.override.json"

    if [[ ! -f "$base" ]]; then
        log_warn "No settings.json found — skipping settings deploy"
        return
    fi

    if [[ -f "$override" ]]; then
        log_info "Merging settings.json + settings.override.json"
        # Deep merge: override wins for scalars, arrays are concatenated (deduped)
        python3 -c "
import json, sys
base = json.load(open(sys.argv[1]))
over = json.load(open(sys.argv[2]))
def merge(b, o):
    for k, v in o.items():
        if k in b and isinstance(b[k], dict) and isinstance(v, dict):
            merge(b[k], v)
        elif k in b and isinstance(b[k], list) and isinstance(v, list):
            combined = b[k] + [x for x in v if x not in b[k]]
            b[k] = combined
        else:
            b[k] = v
merge(base, over)
print(json.dumps(base, indent=2))
" "$base" "$override"
    else
        # No override — use base as-is (substitute __HOME__)
        sed "s|__HOME__|$HOME|g" "$base"
    fi > /dev/null  # Validation only — checks that merge succeeds without writing anywhere
    # Actual settings live at $CC_MIRROR_DIR/config/settings.json (deployed by initial setup).
    # check_settings_health validates the live file has critical blocks.
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
    # Deploy hook subdirectories (e.g., checks/)
    for subdir in "$GLOBAL_DIR/hooks"/*/; do
        [ -d "$subdir" ] || continue
        local subdir_name
        subdir_name=$(basename "$subdir")
        mkdir -p "$CLAUDE_HOME/hooks/$subdir_name"
        for f in "$subdir"*.sh; do
            [ -f "$f" ] || continue
            cp "$f" "$CLAUDE_HOME/hooks/$subdir_name/$(basename "$f")"
            log_info "Deployed hook: $subdir_name/$(basename "$f")"
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

    # Prefer wrapper (copied, survives repo corruption)
    if [ -f "$wrapper_src" ]; then
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

# ---- PERSONAL DATA LEAK CHECK ----
# Scans the template repo for patterns that suggest personal data leaked into public files.
# Warns but does not block — manual review required.
#
# Customize: set PERSONAL_DATA_PATTERNS in sync.local.sh as a grep -E regex.
# Example: PERSONAL_DATA_PATTERNS='(your-email@example\.com|your-username|your-ip-address)'
# check_personal_data_leaks — moved to sync-lib/check.sh
# check_template_drift — moved to sync-lib/check.sh

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
                            sed -i "s/^files=\(.*\)/files=\1 $base/" "$_marker"
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
                    cp "$hook" "$GLOBAL_DIR/hooks/$base"
                    log_info "Collected hook: $base"
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
                        cp "$f" "$GLOBAL_DIR/hooks/$subdir_name/$f_base"
                        log_info "Collected hook: $subdir_name/$f_base"
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

# _extract_manifest_section — moved to sync-lib/common.sh
# cmd_check — moved to sync-lib/check.sh
# cmd_check_template — moved to sync-lib/check.sh
# find_project_path — moved to sync-lib/common.sh

# ---- Stamp: refresh all manifest hashes to current values ----
cmd_stamp() {
    local manifest="$SCRIPT_DIR/template-sync-manifest.md"
    if [ ! -f "$manifest" ]; then
        log_warn "template-sync-manifest.md not found — nothing to stamp"
        return 0
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        log_warn "python3 not found — cannot compute hashes"
        return 1
    fi

    local refreshed=0 skipped=0
    local tracked_files
    tracked_files=$(grep -oP '^\| `[^`]+` \| `[0-9a-f]{8}`' "$manifest" | sed 's/^| `//;s/` | `/|/;s/`$//' || true)

    local line file_path old_hash
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        file_path="${line%%|*}"
        old_hash="${line##*|}"
        [ -n "$file_path" ] && [ -n "$old_hash" ] || continue

        local full_path="$SCRIPT_DIR/$file_path"
        if [ ! -f "$full_path" ]; then
            log_warn "Skipping $file_path — file not found"
            skipped=$((skipped + 1))
            continue
        fi

        local new_hash
        new_hash=$(python3 -c "import binascii,sys;print(format(binascii.crc32(open(sys.argv[1],'rb').read())&0xFFFFFFFF,'08x'))" "$full_path")

        if [ "$new_hash" != "$old_hash" ]; then
            # Replace the old hash with new hash in the manifest (exact match on backtick-wrapped hash)
            sed -i "s/\`$old_hash\`/\`$new_hash\`/" "$manifest"
            log_info "Refreshed $file_path: $old_hash → $new_hash"
            refreshed=$((refreshed + 1))
        fi
    done <<< "$tracked_files"

    if [ "$refreshed" -gt 0 ]; then
        log_info "Refreshed $refreshed hash(es) in template-sync-manifest.md"
    else
        log_info "All manifest hashes are current — nothing to refresh"
    fi
    [ "$skipped" -eq 0 ] || log_warn "Skipped $skipped missing file(s)"
}

# ---- Main ----
case "${1:-help}" in
    setup)          cmd_setup ;;
    deploy)         cmd_deploy ;;
    collect)        cmd_collect ;;
    check)          shift; cmd_check "$@" ;;
    check-template) shift; cmd_check_template "$@" ;;
    stamp)          cmd_stamp ;;
    status)         cmd_status ;;
    mobile-deploy)  bash "$SCRIPT_DIR/setup/scripts/mobile-deploy.sh" ;;
    mobile-collect) bash "$SCRIPT_DIR/setup/scripts/mobile-deploy.sh" --collect ;;
    *)
        echo "Usage: bash sync.sh {setup|deploy|collect|check|check-template|stamp|status|mobile-deploy|mobile-collect}"
        echo ""
        echo "  setup          — Replace live files with symlinks to repo (recommended, one-time)"
        echo "  deploy         — Copy from repo → live locations (for non-symlink setups)"
        echo "  collect        — Copy from live locations → repo (capture session edits)"
        echo "  check          — Check all propagation chains for drift/staleness"
        echo "  check-template — Pre-publish check: exclusions, personal data, config"
        echo "  stamp          — Refresh all manifest hashes to current values (after template sync)"
        echo "  status         — Show differences between repo and live"
        echo "  mobile-deploy  — Generate/refresh the mobile agent-fleet repo"
        echo "  mobile-collect — Merge mobile outbox tasks into cross-project inbox"
        ;;
esac
