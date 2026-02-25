#!/usr/bin/env bash
#
# configure-claude.sh - Claude Code mclaude variant configuration
# ================================================================
# This script configures the mclaude variant created by install-base.sh.
# It sets up VoltAgent subagents, MCP servers (GitHub, Jira, Serena),
# helper scripts, global CLAUDE.md, and WSL-specific settings.
#
# PREREQUISITE: Run install-base.sh first to install Node.js, cc-mirror,
# and create the mclaude variant.
#
# Usage:
#   bash configure-claude.sh [--dry-run] [--verbose] [--no-color] [--reconfigure-mcp]
#
# Options:
#   --dry-run          Show what would be done without making changes
#   --verbose          Show detailed progress information
#   --no-color         Disable colored output
#   --reconfigure-mcp  Force re-prompting for MCP credentials even if configured
#   --help             Show this help message
#
# What this script does:
#   Step 1: Deploy VoltAgent subagents configuration (settings.json)
#   Step 2: Configure MCP servers (GitHub, Jira, Serena) with credentials
#   Step 3: Patch mclaude launcher with MCP enablement + update-checker
#   Step 4: Install and patch happy-coder for mobile access
#   Step 5: Deploy helper scripts (update-checker, happy-coder-patch)
#   Step 6: Deploy global CLAUDE.md configuration
#   Step 7: Configure WSL settings (git, credentials, bashrc, /etc/wsl.conf)
#

set -euo pipefail

# Resolve script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the utility library
if [[ ! -f "${SCRIPT_DIR}/lib.sh" ]]; then
    echo "ERROR: lib.sh not found in ${SCRIPT_DIR}" >&2
    exit 1
fi
source "${SCRIPT_DIR}/lib.sh"

# ============================================================================
# CONFIGURATION
# ============================================================================

CC_MIRROR_VARIANT="mclaude"
CONFIG_DIR="${HOME}/.cc-mirror/${CC_MIRROR_VARIANT}/config"
SCRIPTS_DIR="${HOME}/.cc-mirror/${CC_MIRROR_VARIANT}/scripts"
LAUNCHER="${HOME}/.local/bin/${CC_MIRROR_VARIANT}"

RECONFIGURE_MCP=false
TOTAL_STEPS=7

# Step tracking for summary
INSTALLED_STEPS=()
SKIPPED_STEPS=()

# ============================================================================
# HELPERS
# ============================================================================

# Show help
show_help() {
    cat << 'EOF'
configure-claude.sh - Configure Claude Code mclaude variant

PREREQUISITE:
  Run install-base.sh first to install Node.js, cc-mirror, and create
  the mclaude variant.

USAGE:
  bash configure-claude.sh [OPTIONS]

OPTIONS:
  --dry-run          Show what would be done without making changes
  --verbose          Show detailed progress information
  --no-color         Disable colored output
  --reconfigure-mcp  Force re-prompting for MCP credentials even if configured
  --help             Show this help message

WHAT THIS SCRIPT DOES:
  1. Deploy VoltAgent subagents configuration (settings.json)
  2. Configure MCP servers (GitHub, Jira, Serena) with credentials
  3. Patch mclaude launcher with MCP enablement + update-checker
  4. Install and patch happy-coder for mobile access
  5. Deploy helper scripts (update-checker, happy-coder-patch)
  6. Deploy global CLAUDE.md configuration
  7. Configure WSL settings (git, credentials, bashrc, /etc/wsl.conf)

IDEMPOTENCY:
  This script can be run multiple times safely. It will:
  - Skip unchanged files (checksum comparison)
  - Only prompt for missing MCP credentials
  - Backup files before overwriting
  - Detect and skip already-applied patches

EOF
}

# Prompt for user input (secure for secrets, visible for non-secrets)
prompt_credential() {
    local prompt_text="$1"
    local var_name="$2"
    local is_secret="${3:-true}"

    echo -e "\n${COLOR_BLUE}${prompt_text}${COLOR_RESET}"
    if [[ "${is_secret}" == "true" ]]; then
        read -r -s -p "> " input
        echo
    else
        read -r -p "> " input
    fi

    # Direct assignment instead of eval for security
    case "${var_name}" in
        github_token) github_token="${input}" ;;
        jira_url) jira_url="${input}" ;;
        jira_email) jira_email="${input}" ;;
        jira_api_token) jira_api_token="${input}" ;;
        *) log_error "Unknown variable name: ${var_name}"; return 1 ;;
    esac
}


# ============================================================================
# STEP 1: DEPLOY VOLTAGENT CONFIGURATION
# ============================================================================

deploy_voltagent_config() {
    log_step 1 "${TOTAL_STEPS}" "Deploy VoltAgent Subagents Configuration"

    local template="${SCRIPT_DIR}/config/settings.json"
    local target="${CONFIG_DIR}/settings.json"

    require_file "${template}" "VoltAgent settings.json template"

    run_cmd mkdir -p "${CONFIG_DIR}"

    # Check if target exists and is identical to template (after __HOME__ substitution)
    if [[ -f "${target}" ]]; then
        local temp_expanded
        temp_expanded=$(mktemp)
        sed "s|__HOME__|${HOME}|g" "${template}" > "${temp_expanded}"

        if files_identical "${target}" "${temp_expanded}"; then
            rm -f "${temp_expanded}"
            log_info "settings.json already up to date, skipping"
            SKIPPED_STEPS+=("VoltAgent configuration (already up to date)")
            return 0
        fi
        rm -f "${temp_expanded}"
    fi

    # Backup existing file
    backup_file "${target}"

    # Deploy with __HOME__ replacement
    log_info "Deploying settings.json (all VoltAgent categories disabled globally)..."
    if [[ "${DRY_RUN}" == "false" ]]; then
        sed "s|__HOME__|${HOME}|g" "${template}" > "${target}"
    else
        echo -e "${COLOR_YELLOW}[DRY RUN]${COLOR_RESET} Would deploy: ${target}"
    fi

    log_success "VoltAgent configuration deployed"
    log_info "Per-project: Add specific agents to <project>/.claude/agents/"
    INSTALLED_STEPS+=("VoltAgent configuration")
}

# ============================================================================
# STEP 2: CONFIGURE MCP SERVERS
# ============================================================================

configure_mcp_servers() {
    log_step 2 "${TOTAL_STEPS}" "Configure MCP Servers"

    local template="${SCRIPT_DIR}/config/mcp.json.template"
    local target="${CONFIG_DIR}/.mcp.json"
    local settings_local="${CONFIG_DIR}/settings.local.json"

    require_file "${template}" "MCP template"

    # Detect tool paths
    local uvx_cmd npx_cmd safe_path
    uvx_cmd="$(command -v uvx 2>/dev/null || echo "uvx")"
    npx_cmd="$(command -v npx 2>/dev/null || echo "npx")"
    safe_path="${HOME}/.local/bin:${HOME}/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

    # Parse existing config if present (for idempotency)
    local existing_github=false existing_jira=false
    if [[ -f "${target}" ]] && [[ "${RECONFIGURE_MCP}" == "false" ]]; then
        log_info "Checking existing MCP configuration..."

        # Check if GitHub is configured with non-placeholder token
        if command -v jq &>/dev/null; then
            local gh_token jira_url_check
            gh_token=$(jq -r '.mcpServers.github.env.GITHUB_PERSONAL_ACCESS_TOKEN // empty' "${target}" 2>/dev/null || true)
            jira_url_check=$(jq -r '.mcpServers.jira.env.JIRA_URL // empty' "${target}" 2>/dev/null || true)

            [[ -n "${gh_token}" ]] && [[ "${gh_token}" != "__GITHUB_TOKEN__" ]] && existing_github=true
            [[ -n "${jira_url_check}" ]] && [[ "${jira_url_check}" != "__JIRA_URL__" ]] && existing_jira=true
        else
            # Fallback: simple grep check
            if grep -q '"GITHUB_PERSONAL_ACCESS_TOKEN"' "${target}" 2>/dev/null && \
               ! grep -q '"__GITHUB_TOKEN__"' "${target}" 2>/dev/null; then
                existing_github=true
            fi
            if grep -q '"JIRA_URL"' "${target}" 2>/dev/null && \
               ! grep -q '"__JIRA_URL__"' "${target}" 2>/dev/null; then
                existing_jira=true
            fi
        fi

        [[ "${existing_github}" == "true" ]] && log_info "GitHub MCP server already configured"
        [[ "${existing_jira}" == "true" ]] && log_info "Jira MCP server already configured"
    fi

    # --- Serena (always enabled, no credentials needed) ---
    log_info "Serena MCP server will be configured (no credentials needed)"

    # --- GitHub ---
    local setup_github=false github_token=""

    if [[ "${existing_github}" == "true" ]]; then
        log_info "Skipping GitHub credential prompt (already configured, use --reconfigure-mcp to change)"
        setup_github=true
        # Read existing token
        if command -v jq &>/dev/null; then
            github_token=$(jq -r '.mcpServers.github.env.GITHUB_PERSONAL_ACCESS_TOKEN' "${target}")
        else
            github_token=$(grep -o '"GITHUB_PERSONAL_ACCESS_TOKEN"[[:space:]]*:[[:space:]]*"[^"]*"' "${target}" | sed 's/.*"\([^"]*\)"$/\1/')
        fi
    else
        echo ""
        echo -e "${COLOR_BLUE}GitHub MCP Server Setup${COLOR_RESET}"
        echo "  You need a Personal Access Token with repo + read:org scopes."
        echo "  Create one at: https://github.com/settings/tokens"

        if prompt_yes_no "  Set up GitHub MCP server?" "y"; then
            prompt_credential "  Enter your GitHub Personal Access Token:" github_token
            setup_github=true
        fi
    fi

    # --- Jira ---
    local setup_jira=false jira_url="" jira_email="" jira_api_token=""

    if [[ "${existing_jira}" == "true" ]]; then
        log_info "Skipping Jira credential prompt (already configured, use --reconfigure-mcp to change)"
        setup_jira=true
        # Read existing credentials
        if command -v jq &>/dev/null; then
            jira_url=$(jq -r '.mcpServers.jira.env.JIRA_URL' "${target}")
            jira_email=$(jq -r '.mcpServers.jira.env.JIRA_USERNAME' "${target}")
            jira_api_token=$(jq -r '.mcpServers.jira.env.JIRA_API_TOKEN' "${target}")
        else
            jira_url=$(grep -o '"JIRA_URL"[[:space:]]*:[[:space:]]*"[^"]*"' "${target}" | sed 's/.*"\([^"]*\)"$/\1/')
            jira_email=$(grep -o '"JIRA_USERNAME"[[:space:]]*:[[:space:]]*"[^"]*"' "${target}" | sed 's/.*"\([^"]*\)"$/\1/')
            jira_api_token=$(grep -o '"JIRA_API_TOKEN"[[:space:]]*:[[:space:]]*"[^"]*"' "${target}" | sed 's/.*"\([^"]*\)"$/\1/')
        fi
    else
        echo ""
        echo -e "${COLOR_BLUE}Jira/Atlassian MCP Server Setup${COLOR_RESET}"
        echo "  You need your Jira URL, email, and API token."
        echo "  Create a token at: https://id.atlassian.com/manage-profile/security/api-tokens"

        if prompt_yes_no "  Set up Jira MCP server?" "y"; then
            prompt_credential "  Enter your Jira URL (e.g. https://company.atlassian.net):" jira_url false
            prompt_credential "  Enter your Jira email:" jira_email false
            prompt_credential "  Enter your Jira API Token:" jira_api_token
            setup_jira=true
        fi
    fi

    # Build .mcp.json from template
    log_info "Generating .mcp.json..."

    local mcp_json
    mcp_json=$(sed \
        -e "s|__SERENA_CMD__|${uvx_cmd}|g" \
        -e "s|__NPX_CMD__|${npx_cmd}|g" \
        -e "s|__JIRA_CMD__|${uvx_cmd}|g" \
        -e "s|__PATH__|${safe_path}|g" \
        -e "s|__GITHUB_TOKEN__|${github_token}|g" \
        -e "s|__JIRA_URL__|${jira_url}|g" \
        -e "s|__JIRA_USERNAME__|${jira_email}|g" \
        -e "s|__JIRA_API_TOKEN__|${jira_api_token}|g" \
        "${template}")

    # Remove unconfigured servers from JSON (SAFE: stdin, not argv)
    if [[ "${setup_github}" != "true" ]]; then
        if command -v node &>/dev/null; then
            mcp_json=$(printf '%s' "${mcp_json}" | node -e "
                const d = JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
                delete d.mcpServers.github;
                process.stdout.write(JSON.stringify(d, null, 2));
            ")
        else
            log_warn "Node.js not available, cannot remove unconfigured servers from JSON"
        fi
    fi

    if [[ "${setup_jira}" != "true" ]]; then
        if command -v node &>/dev/null; then
            mcp_json=$(printf '%s' "${mcp_json}" | node -e "
                const d = JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
                delete d.mcpServers.jira;
                process.stdout.write(JSON.stringify(d, null, 2));
            ")
        else
            log_warn "Node.js not available, cannot remove unconfigured servers from JSON"
        fi
    fi

    # Deploy .mcp.json (use printf for safe file writing)
    backup_file "${target}"

    if [[ "${DRY_RUN}" == "false" ]]; then
        printf '%s\n' "${mcp_json}" > "${target}"
        log_success ".mcp.json deployed to ${target}"
    else
        echo -e "${COLOR_YELLOW}[DRY RUN]${COLOR_RESET} Would deploy: ${target}"
    fi

    # Deploy settings.local.json (MCP enablement flags)
    log_info "Deploying settings.local.json with MCP enablement flags..."

    # Build the enabledMcpjsonServers list based on what was configured
    local servers='"serena"'
    [[ "${setup_github}" == "true" ]] && servers="${servers}, \"github\""
    [[ "${setup_jira}" == "true" ]] && servers="${servers}, \"jira\""

    backup_file "${settings_local}"

    if [[ "${DRY_RUN}" == "false" ]]; then
        cat > "${settings_local}" << SETTINGSLOCAL
{
  "enableAllProjectMcpServers": true,
  "enabledMcpjsonServers": [
    ${servers}
  ]
}
SETTINGSLOCAL
        log_success "settings.local.json deployed with enablement flags"
    else
        echo -e "${COLOR_YELLOW}[DRY RUN]${COLOR_RESET} Would deploy: ${settings_local}"
    fi

    log_success "MCP servers configured"
    INSTALLED_STEPS+=("MCP servers (GitHub, Jira, Serena)")
}

# ============================================================================
# STEP 3: PATCH MCLAUDE LAUNCHER
# ============================================================================

patch_mclaude_launcher() {
    log_step 3 "${TOTAL_STEPS}" "Patch mclaude Launcher"

    require_file "${LAUNCHER}" "mclaude launcher (run install-base.sh first)"

    # Cleanup trap for temp files
    local tmpfile tmpfile2=""
    tmpfile=$(mktemp)
    trap 'rm -f "${tmpfile}" "${tmpfile2:-}"' RETURN

    # Check if already patched
    if grep -q "__cc_enable_mcp" "${LAUNCHER}"; then
        log_info "Launcher already has MCP enablement patch, skipping"
        SKIPPED_STEPS+=("MCP enablement patch (already applied)")
    else
        log_info "Adding MCP enablement function to launcher..."

        # Backup original
        backup_file "${LAUNCHER}"

        # Build the patch
        cat > "${tmpfile}" << 'LAUNCHER_PATCH'

# Ensure MCP servers are enabled in settings.local.json (NOT .claude.json which gets overwritten)
__cc_enable_mcp() {
  local config_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  local project_dir="${PWD}/.claude"
  for settings_dir in "$config_dir" "$project_dir"; do
    local settings_file="${settings_dir}/settings.local.json"
    mkdir -p "$settings_dir" 2>/dev/null || true
    python3 -c "
import json, os
f_path = '$settings_file'
try:
    if os.path.exists(f_path):
        with open(f_path, 'r') as f:
            d = json.load(f)
    else:
        d = {}
    changed = False
    # Read server names from .mcp.json in config dir
    mcp_file = os.path.join('$config_dir', '.mcp.json')
    needed = []
    if os.path.exists(mcp_file):
        with open(mcp_file) as mf:
            mcp = json.load(mf)
            needed = list(mcp.get('mcpServers', {}).keys())
    if not needed:
        needed = ['serena']
    if sorted(d.get('enabledMcpjsonServers', [])) != sorted(needed):
        d['enabledMcpjsonServers'] = needed
        changed = True
    if not d.get('enableAllProjectMcpServers'):
        d['enableAllProjectMcpServers'] = True
        changed = True
    if changed:
        with open(f_path, 'w') as f:
            json.dump(d, f, indent=2)
            f.write('\n')
except Exception:
    pass
" 2>/dev/null || true
  done
}

# Enable MCP servers before startup
__cc_enable_mcp

LAUNCHER_PATCH

        # Insert the patch before the exec line and write to another temp file
        tmpfile2=$(mktemp)

        if [[ "${DRY_RUN}" == "false" ]]; then
            awk -v patch="$(cat "${tmpfile}")" '
              /^exec node/ { print patch }
              { print }
            ' "${LAUNCHER}" > "${tmpfile2}"

            # Verify the temp file is valid
            if [[ ! -s "${tmpfile2}" ]] || ! grep -q "^exec node" "${tmpfile2}"; then
                log_error "Patch validation failed, launcher may be corrupted"
                return 1
            fi

            # Replace original with patched version
            mv "${tmpfile2}" "${LAUNCHER}"
            chmod +x "${LAUNCHER}"

            log_success "Launcher patched with MCP enablement"
            INSTALLED_STEPS+=("MCP enablement patch")
        else
            echo -e "${COLOR_YELLOW}[DRY RUN]${COLOR_RESET} Would patch: ${LAUNCHER}"
        fi
    fi

    # Add update-checker if not present
    if ! grep -q "update-checker.sh" "${LAUNCHER}"; then
        log_info "Adding update-checker to launcher..."

        backup_file "${LAUNCHER}"

        tmpfile=$(mktemp)
        trap 'rm -f "${tmpfile}"' RETURN

        if [[ "${DRY_RUN}" == "false" ]]; then
            awk '
              /^exec node/ {
                print "# Run update checker (interactive sessions only)"
                print "if [[ -t 1 ]] && [[ \"$*\" != *\"--output-format\"* ]]; then"
                print "  if [[ -x \"$HOME/.cc-mirror/mclaude/scripts/update-checker.sh\" ]]; then"
                print "    \"$HOME/.cc-mirror/mclaude/scripts/update-checker.sh\" || true"
                print "  fi"
                print "fi"
                print ""
              }
              { print }
            ' "${LAUNCHER}" > "${tmpfile}"

            # Verify
            if [[ ! -s "${tmpfile}" ]] || ! grep -q "^exec node" "${tmpfile}"; then
                log_error "Update-checker patch validation failed"
                return 1
            fi

            mv "${tmpfile}" "${LAUNCHER}"
            chmod +x "${LAUNCHER}"

            log_success "Update-checker added to launcher"
            INSTALLED_STEPS+=("Update-checker integration")
        else
            echo -e "${COLOR_YELLOW}[DRY RUN]${COLOR_RESET} Would add update-checker to: ${LAUNCHER}"
        fi
    else
        log_info "Launcher already has update-checker, skipping"
        SKIPPED_STEPS+=("Update-checker (already integrated)")
    fi

    log_success "Launcher configuration complete"
}

# ============================================================================
# STEP 4: INSTALL HAPPY-CODER
# ============================================================================

install_happy_coder() {
    log_step 4 "${TOTAL_STEPS}" "Install happy-coder"

    local was_installed=false
    if command -v happy &>/dev/null; then
        log_info "happy-coder already installed, checking for updates..."
        run_cmd npm update -g happy-coder 2>/dev/null || run_cmd npm install -g happy-coder
        was_installed=true
    else
        log_info "Installing happy-coder from npm..."
        run_cmd npm install -g happy-coder
    fi

    log_info "Applying cc-mirror patch to happy-coder..."
    require_file "${SCRIPT_DIR}/scripts/happy-coder-patch.js" "happy-coder patch script"

    run_cmd node "${SCRIPT_DIR}/scripts/happy-coder-patch.js"

    log_success "happy-coder installed and patched"

    if [[ "${was_installed}" == "true" ]]; then
        INSTALLED_STEPS+=("happy-coder (updated and patched)")
    else
        INSTALLED_STEPS+=("happy-coder")
    fi
}

# ============================================================================
# STEP 5: DEPLOY HELPER SCRIPTS
# ============================================================================

deploy_helper_scripts() {
    log_step 5 "${TOTAL_STEPS}" "Deploy Helper Scripts"

    run_cmd mkdir -p "${SCRIPTS_DIR}"

    local deployed_count=0
    local skipped_count=0

    # happy-coder-patch.js
    local src_patch="${SCRIPT_DIR}/scripts/happy-coder-patch.js"
    local dest_patch="${SCRIPTS_DIR}/happy-coder-patch.js"

    require_file "${src_patch}" "happy-coder-patch.js"

    if files_identical "${src_patch}" "${dest_patch}"; then
        log_info "happy-coder-patch.js already up to date, skipping"
        ((skipped_count++))
    else
        backup_file "${dest_patch}"
        run_cmd cp "${src_patch}" "${dest_patch}"
        log_success "Deployed: happy-coder-patch.js"
        ((deployed_count++))
    fi

    # update-checker.sh
    local src_checker="${SCRIPT_DIR}/scripts/update-checker.sh"
    local dest_checker="${SCRIPTS_DIR}/update-checker.sh"

    require_file "${src_checker}" "update-checker.sh"

    if files_identical "${src_checker}" "${dest_checker}"; then
        log_info "update-checker.sh already up to date, skipping"
        ((skipped_count++))
    else
        backup_file "${dest_checker}"
        run_cmd cp "${src_checker}" "${dest_checker}"
        run_cmd chmod +x "${dest_checker}"
        log_success "Deployed: update-checker.sh"
        ((deployed_count++))
    fi

    # Copy this installer for reference
    local src_installer="${SCRIPT_DIR}/configure-claude.sh"
    local dest_installer="${SCRIPTS_DIR}/configure-claude.sh"

    if files_identical "${src_installer}" "${dest_installer}"; then
        log_info "configure-claude.sh already up to date, skipping"
        ((skipped_count++))
    else
        backup_file "${dest_installer}"
        run_cmd cp "${src_installer}" "${dest_installer}"
        run_cmd chmod +x "${dest_installer}"
        log_success "Deployed: configure-claude.sh (reference copy)"
        ((deployed_count++))
    fi

    if [[ ${deployed_count} -gt 0 ]]; then
        INSTALLED_STEPS+=("Helper scripts (${deployed_count} deployed)")
    fi
    if [[ ${skipped_count} -gt 0 ]]; then
        SKIPPED_STEPS+=("Helper scripts (${skipped_count} already up to date)")
    fi

    log_success "Helper scripts deployed to ${SCRIPTS_DIR}"
}

# ============================================================================
# STEP 6: DEPLOY GLOBAL CLAUDE.md
# ============================================================================

deploy_claude_md() {
    log_step 6 "${TOTAL_STEPS}" "Deploy Global CLAUDE.md"

    local src="${SCRIPT_DIR}/config/CLAUDE.md"
    local dest="${HOME}/.claude/CLAUDE.md"

    run_cmd mkdir -p "${HOME}/.claude"

    if [[ ! -f "${src}" ]]; then
        log_warn "config/CLAUDE.md not found in setup folder, skipping"
        SKIPPED_STEPS+=("Global CLAUDE.md (source not found)")
        return 0
    fi

    if files_identical "${src}" "${dest}"; then
        log_info "CLAUDE.md already up to date, skipping"
        SKIPPED_STEPS+=("Global CLAUDE.md (already up to date)")
    else
        backup_file "${dest}"
        run_cmd cp "${src}" "${dest}"
        log_success "CLAUDE.md deployed to ~/.claude/CLAUDE.md"
        INSTALLED_STEPS+=("Global CLAUDE.md")
    fi
}

# ============================================================================
# STEP 7: CONFIGURE WSL SETTINGS
# ============================================================================

configure_wsl_settings() {
    log_step 7 "${TOTAL_STEPS}" "Configure WSL Settings"

    local changes_made=false

    # Git configuration
    log_info "Configuring git for WSL..."
    run_cmd git config --global core.autocrlf input
    run_cmd git config --global color.ui auto
    run_cmd git config --global color.diff always

    # Git credential helper (reads GitHub PAT from MCP config — single source of truth)
    local cred_helper_src="${SCRIPT_DIR}/scripts/git-credential-mcp"
    local cred_helper_dest="${HOME}/.local/bin/git-credential-mcp"
    if [[ -f "${cred_helper_src}" ]]; then
        run_cmd mkdir -p "${HOME}/.local/bin"
        if ! files_identical "${cred_helper_src}" "${cred_helper_dest}"; then
            backup_file "${cred_helper_dest}"
            run_cmd cp "${cred_helper_src}" "${cred_helper_dest}"
            run_cmd chmod +x "${cred_helper_dest}"
            log_success "Git credential helper deployed to ${cred_helper_dest}"
        else
            log_info "Git credential helper already up to date"
        fi
        run_cmd git config --global credential.helper "${cred_helper_dest}"
    fi

    changes_made=true

    # Bash color prompt
    log_info "Enabling color prompt in bashrc..."
    if grep -q '^#force_color_prompt=yes' "${HOME}/.bashrc" 2>/dev/null; then
        backup_file "${HOME}/.bashrc"
        if [[ "${DRY_RUN}" == "false" ]]; then
            sed -i 's/^#force_color_prompt=yes/force_color_prompt=yes/' "${HOME}/.bashrc"
            log_success "Color prompt enabled"
        else
            echo -e "${COLOR_YELLOW}[DRY RUN]${COLOR_RESET} Would enable color prompt in .bashrc"
        fi
    else
        log_info "Color prompt already enabled or not found in .bashrc"
    fi

    # Check /etc/wsl.conf
    if [[ ! -f /etc/wsl.conf ]] || ! grep -q "metadata" /etc/wsl.conf 2>/dev/null; then
        log_warn "WSL configuration may need updating."
        echo ""
        echo "  Recommended /etc/wsl.conf:"
        echo '    [automount]'
        echo '    enabled = true'
        echo '    options = "metadata,umask=22,fmask=11"'
        echo '    [interop]'
        echo '    enabled = true'
        echo '    appendWindowsPath = true'
        echo ""
        echo "  Then restart WSL: wsl --shutdown"
        echo ""
    else
        log_info "/etc/wsl.conf looks good"
    fi

    log_success "WSL settings configured"

    if [[ "${changes_made}" == "true" ]]; then
        INSTALLED_STEPS+=("WSL settings (git, bashrc)")
    else
        SKIPPED_STEPS+=("WSL settings (already configured)")
    fi
}

# ============================================================================
# SUMMARY
# ============================================================================

print_summary() {
    print_header "Configuration Complete!"

    # Show what was installed
    if [[ ${#INSTALLED_STEPS[@]} -gt 0 ]]; then
        echo -e "${COLOR_GREEN}Installed/Updated:${COLOR_RESET}"
        for step in "${INSTALLED_STEPS[@]}"; do
            echo -e "  ${COLOR_GREEN}✓${COLOR_RESET} ${step}"
        done
        echo ""
    fi

    # Show what was skipped
    if [[ ${#SKIPPED_STEPS[@]} -gt 0 ]]; then
        echo -e "${COLOR_YELLOW}Skipped (already configured):${COLOR_RESET}"
        for step in "${SKIPPED_STEPS[@]}"; do
            echo -e "  ${COLOR_YELLOW}○${COLOR_RESET} ${step}"
        done
        echo ""
    fi

    echo -e "${COLOR_BLUE}To start using Claude Code:${COLOR_RESET}"
    echo "  1. Open a new terminal (or run: source ~/.bashrc)"
    echo "  2. Run: mclaude"
    echo ""
    echo -e "${COLOR_BLUE}For mobile access via happy-coder:${COLOR_RESET}"
    echo "  Run: happy"
    echo ""
    echo -e "${COLOR_BLUE}MCP servers are available in ALL projects automatically.${COLOR_RESET}"
    echo "  Server definitions: ${CONFIG_DIR}/.mcp.json"
    echo "  Enablement flags:   ${CONFIG_DIR}/settings.local.json"
    echo ""
    echo -e "${COLOR_BLUE}VoltAgent per-project control:${COLOR_RESET}"
    echo "  All categories disabled globally. Add specific agents to:"
    echo "    <project>/.claude/agents/"
    echo "  from:"
    echo "    ~/.cc-mirror/mclaude/config/plugins/voltagent-subagents/<category>/"
    echo ""

    if [[ "${DRY_RUN}" == "true" ]]; then
        echo -e "${COLOR_YELLOW}NOTE: This was a DRY RUN. No changes were made.${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}      Run without --dry-run to apply changes.${COLOR_RESET}"
        echo ""
    fi
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    # Initialize logging
    log_init

    # Set up cleanup trap for interruptions
    trap 'log_error "Configuration interrupted. Check log file for details: ${LOG_FILE}"' ERR INT TERM

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --reconfigure-mcp)
                RECONFIGURE_MCP=true
                log_info "MCP reconfiguration mode enabled"
                shift
                ;;
            *)
                # Let parse_common_args handle the rest
                if ! parse_common_args "$1"; then
                    show_help
                    exit 0
                fi
                shift
                ;;
        esac
    done

    print_header "Claude Code Configuration (mclaude variant)"

    # Prerequisites check
    require_cmd cc-mirror "Run install-base.sh first"
    require_cmd node "Run install-base.sh first"
    require_cmd npm "Run install-base.sh first"
    require_file "${LAUNCHER}" "mclaude launcher (run install-base.sh first)"

    # Verify template files
    require_file "${SCRIPT_DIR}/config/settings.json" "settings.json template"
    require_file "${SCRIPT_DIR}/config/mcp.json.template" "MCP template"
    require_file "${SCRIPT_DIR}/scripts/happy-coder-patch.js" "happy-coder patch script"
    require_file "${SCRIPT_DIR}/scripts/update-checker.sh" "update-checker script"

    log_success "Prerequisites verified"
    echo ""

    # Run configuration steps
    deploy_voltagent_config
    configure_mcp_servers
    patch_mclaude_launcher
    install_happy_coder
    deploy_helper_scripts
    deploy_claude_md
    configure_wsl_settings

    # Show summary
    print_summary
}

main "$@"
