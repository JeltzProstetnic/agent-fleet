#!/usr/bin/env bash
#
# configure-claude.sh - Claude Code mclaude variant configuration
# ================================================================
# This script configures the mclaude variant created by install-base.sh.
# It sets up VoltAgent subagents, base MCP servers (no credentials needed),
# helper scripts, and platform settings (git, credentials, WSL/SteamOS).
#
# MCP servers that need credentials (GitHub, Twitter, Google Workspace, Jira,
# Postgres) are NOT configured here. They are set up conversationally during
# your first mclaude session via the first-run refinement protocol.
#
# PREREQUISITE: Run install-base.sh first to install Node.js, cc-mirror,
# and create the mclaude variant.
#
# Usage:
#   bash configure-claude.sh [--dry-run] [--verbose] [--no-color] [--path-prefix PATH]
#
# Options:
#   --dry-run          Show what would be done without making changes
#   --verbose          Show detailed progress information
#   --no-color         Disable colored output
#   --path-prefix PATH Prepend PATH to $PATH (for non-interactive SSH where NVM isn't loaded)
#   --help             Show this help message
#
# What this script does:
#   Step 1: Deploy VoltAgent subagents configuration (settings.json)
#   Step 2: Deploy base MCP servers (Serena, Playwright, Memory, Diagram Bridge)
#   Step 3: Patch mclaude launcher with MCP enablement + update-checker
#   Step 4: Deploy helper scripts (update-checker)
#   Step 5: Configure platform settings (git, credentials, shell RC, WSL/SteamOS specifics)
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

TOTAL_STEPS=5

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
  --path-prefix PATH Prepend PATH to $PATH (for non-interactive SSH sessions
                     where NVM/node aren't in PATH). Example:
                       bash configure-claude.sh --path-prefix ~/.nvm/versions/node/v22.22.0/bin
  --help             Show this help message

WHAT THIS SCRIPT DOES:
  1. Deploy VoltAgent subagents configuration (settings.json)
  2. Deploy base MCP servers (no credentials needed)
  3. Patch mclaude launcher with MCP enablement + update-checker
  4. Deploy helper scripts (update-checker)
  5. Configure platform settings (git, credentials, shell RC, WSL/SteamOS specifics)

  MCP servers that need credentials (GitHub, Twitter, Google Workspace,
  Jira, Postgres) are configured conversationally during your first
  mclaude session.

IDEMPOTENCY:
  This script can be run multiple times safely. It will:
  - Skip unchanged files (checksum comparison)
  - Backup files before overwriting
  - Detect and skip already-applied patches

EOF
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
    log_step 2 "${TOTAL_STEPS}" "Deploy Base MCP Servers"

    local target="${CONFIG_DIR}/.mcp.json"
    local settings_local="${CONFIG_DIR}/settings.local.json"

    # Detect tool paths
    local uvx_cmd npx_cmd safe_path node_bin_dir
    uvx_cmd="$(command -v uvx 2>/dev/null || echo "uvx")"
    npx_cmd="$(command -v npx 2>/dev/null || echo "npx")"
    # Include NVM node bin dir in PATH so spawned processes can find `node`
    # (npx calls node internally, which fails on SteamOS/non-standard distros without this)
    node_bin_dir="$(dirname "$(command -v node 2>/dev/null || echo "")" 2>/dev/null || true)"
    safe_path="${HOME}/.local/bin:${HOME}/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    if [[ -n "${node_bin_dir}" && "${safe_path}" != *"${node_bin_dir}"* ]]; then
        safe_path="${node_bin_dir}:${safe_path}"
    fi

    # If .mcp.json already exists with configured credential servers, preserve it
    if [[ -f "${target}" ]]; then
        local has_credentials=false
        if command -v jq &>/dev/null; then
            # Check if any credential-based server has real (non-placeholder) values
            for server in github twitter jira; do
                local val
                val=$(jq -r ".mcpServers.\"${server}\" // empty" "${target}" 2>/dev/null || true)
                if [[ -n "${val}" ]] && [[ "${val}" != "null" ]]; then
                    has_credentials=true
                    break
                fi
            done
        fi

        if [[ "${has_credentials}" == "true" ]] && [[ "${RECONFIGURE_MCP:-false}" != "true" ]]; then
            log_info ".mcp.json already has configured servers — preserving existing config"
            log_info "  (use --reconfigure-mcp to force reconfiguration)"
            SKIPPED_STEPS+=("MCP servers (.mcp.json already configured)")
            return 0
        fi
        if [[ "${has_credentials}" == "true" ]] && [[ "${RECONFIGURE_MCP:-false}" == "true" ]]; then
            log_info "--reconfigure-mcp: overwriting existing MCP configuration"
        fi
    fi

    # Deploy .mcp.json with only base servers (no credentials needed)
    log_info "Deploying base MCP servers: Serena, Playwright, Memory, Diagram Bridge"
    log_info "Credential-based servers (GitHub, Twitter, etc.) will be set up in your first mclaude session"

    backup_file "${target}"

    if [[ "${DRY_RUN}" == "false" ]]; then
        cat > "${target}" << MCPJSON
{
  "mcpServers": {
    "serena": {
      "command": "${uvx_cmd}",
      "args": [
        "--from",
        "git+https://github.com/oraios/serena",
        "serena-mcp-server",
        "--context",
        "claude-code"
      ],
      "env": {
        "PATH": "${safe_path}"
      }
    },
    "playwright": {
      "command": "${npx_cmd}",
      "args": [
        "-y",
        "@playwright/mcp"
      ],
      "env": {
        "PATH": "${safe_path}"
      }
    },
    "memory": {
      "command": "${npx_cmd}",
      "args": [
        "-y",
        "@modelcontextprotocol/server-memory"
      ],
      "env": {
        "PATH": "${safe_path}"
      }
    },
    "diagram": {
      "command": "${uvx_cmd}",
      "args": [
        "--from",
        "mcp-mermaid-image-gen",
        "mcp_mermaid_image_gen"
      ],
      "env": {
        "PATH": "${safe_path}"
      }
    }
  }
}
MCPJSON
        log_success ".mcp.json deployed to ${target}"
    else
        echo -e "${COLOR_YELLOW}[DRY RUN]${COLOR_RESET} Would deploy: ${target}"
    fi

    # Deploy settings.local.json (MCP enablement flags)
    log_info "Deploying settings.local.json with MCP enablement flags..."

    backup_file "${settings_local}"

    if [[ "${DRY_RUN}" == "false" ]]; then
        cat > "${settings_local}" << SETTINGSLOCAL
{
  "enableAllProjectMcpServers": true,
  "enabledMcpjsonServers": [
    "serena", "playwright", "memory", "diagram"
  ]
}
SETTINGSLOCAL
        log_success "settings.local.json deployed with enablement flags"
    else
        echo -e "${COLOR_YELLOW}[DRY RUN]${COLOR_RESET} Would deploy: ${settings_local}"
    fi

    # Deploy Serena global config (suppress browser open on launch)
    local serena_config_dir="${HOME}/.serena"
    local serena_config="${serena_config_dir}/serena_config.yml"
    if [[ ! -f "${serena_config}" ]]; then
        log_info "Creating Serena config (suppress browser open on launch)..."
        if [[ "${DRY_RUN}" == "false" ]]; then
            mkdir -p "${serena_config_dir}"
            cat > "${serena_config}" << 'SERENAYML'
language_backend: LSP
gui_log_window: false
web_dashboard: true
web_dashboard_open_on_launch: false
web_dashboard_listen_address: 127.0.0.1
log_level: 20
trace_lsp_communication: false
ls_specific_settings: {}
ignored_paths: []
tool_timeout: 240
excluded_tools: []
included_optional_tools: []
fixed_tools: []
base_modes:
default_modes:
- interactive
- editing
default_max_tool_answer_chars: 150000
token_count_estimator: CHAR_COUNT
symbol_info_budget: 10
projects: []
SERENAYML
            log_success "Serena config deployed to ${serena_config}"
        else
            echo -e "${COLOR_YELLOW}[DRY RUN]${COLOR_RESET} Would deploy: ${serena_config}"
        fi
    else
        # Serena may regenerate config with defaults on update — always enforce our settings
        if grep -q 'web_dashboard_open_on_launch: true' "${serena_config}"; then
            if [[ "${DRY_RUN}" == "false" ]]; then
                _sed_i 's/web_dashboard_open_on_launch: true/web_dashboard_open_on_launch: false/' "${serena_config}"
                log_info "Serena config: re-enforced web_dashboard_open_on_launch=false"
            else
                echo -e "${COLOR_YELLOW}[DRY RUN]${COLOR_RESET} Would fix: web_dashboard_open_on_launch in ${serena_config}"
            fi
        fi
        if grep -q 'gui_log_window: true' "${serena_config}"; then
            if [[ "${DRY_RUN}" == "false" ]]; then
                _sed_i 's/gui_log_window: true/gui_log_window: false/' "${serena_config}"
                log_info "Serena config: re-enforced gui_log_window=false"
            fi
        fi
    fi

    log_success "Base MCP servers configured (Serena, Playwright, Memory, Diagram Bridge)"
    log_info "Additional servers will be offered during your first mclaude session"
    INSTALLED_STEPS+=("Base MCP servers (Serena, Playwright, Memory, Diagram Bridge)")
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
    trap 'rm -f "${tmpfile:-}" "${tmpfile2:-}"' RETURN

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
            # Insert patch before the exec line. Use sed with a file read (r)
            # instead of awk -v, which corrupts content via C escape processing.
            # Match any exec line (exec node, exec "/path/...", etc.)
            local exec_line
            exec_line=$(grep -n '^exec ' "${LAUNCHER}" | tail -1 | cut -d: -f1)
            if [[ -z "${exec_line}" ]]; then
                log_error "No 'exec' line found in launcher — unexpected format"
                return 1
            fi
            # Insert patch file contents before the exec line
            {
                head -n $((exec_line - 1)) "${LAUNCHER}"
                cat "${tmpfile}"
                tail -n +"${exec_line}" "${LAUNCHER}"
            } > "${tmpfile2}"

            # Verify the temp file is valid
            if [[ ! -s "${tmpfile2}" ]] || ! grep -q '^exec ' "${tmpfile2}"; then
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
        trap 'rm -f "${tmpfile:-}"' RETURN

        if [[ "${DRY_RUN}" == "false" ]]; then
            # Insert update-checker before the exec line (match any exec, not just exec node)
            local exec_line2
            exec_line2=$(grep -n '^exec ' "${LAUNCHER}" | tail -1 | cut -d: -f1)
            if [[ -z "${exec_line2}" ]]; then
                log_error "No 'exec' line found in launcher — unexpected format"
                return 1
            fi
            {
                head -n $((exec_line2 - 1)) "${LAUNCHER}"
                echo '# Run update checker (interactive sessions only)'
                echo 'if [[ -t 1 ]] && [[ "$*" != *"--output-format"* ]]; then'
                echo '  if [[ -x "$HOME/.cc-mirror/mclaude/scripts/update-checker.sh" ]]; then'
                echo '    "$HOME/.cc-mirror/mclaude/scripts/update-checker.sh" || true'
                echo '  fi'
                echo 'fi'
                echo ''
                tail -n +"${exec_line2}" "${LAUNCHER}"
            } > "${tmpfile}"

            # Verify
            if [[ ! -s "${tmpfile}" ]] || ! grep -q '^exec ' "${tmpfile}"; then
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
# STEP 4: DEPLOY HELPER SCRIPTS
# ============================================================================

deploy_helper_scripts() {
    log_step 4 "${TOTAL_STEPS}" "Deploy Helper Scripts"

    run_cmd mkdir -p "${SCRIPTS_DIR}"

    local deployed_count=0
    local skipped_count=0

    # update-checker.sh
    local src_checker="${SCRIPT_DIR}/scripts/update-checker.sh"
    local dest_checker="${SCRIPTS_DIR}/update-checker.sh"

    require_file "${src_checker}" "update-checker.sh"

    if files_identical "${src_checker}" "${dest_checker}"; then
        log_info "update-checker.sh already up to date, skipping"
        ((skipped_count++)) || true
    else
        backup_file "${dest_checker}"
        run_cmd cp "${src_checker}" "${dest_checker}"
        run_cmd chmod +x "${dest_checker}"
        log_success "Deployed: update-checker.sh"
        ((deployed_count++)) || true
    fi

    # statusline-command.sh — context usage bar for Claude Code
    local src_statusline="${SCRIPT_DIR}/config/statusline-command.sh"
    local dest_statusline="${HOME}/.claude/statusline-command.sh"

    require_file "${src_statusline}" "statusline-command.sh"

    run_cmd mkdir -p "${HOME}/.claude"

    if files_identical "${src_statusline}" "${dest_statusline}"; then
        log_info "statusline-command.sh already up to date, skipping"
        ((skipped_count++)) || true
    else
        backup_file "${dest_statusline}"
        run_cmd cp "${src_statusline}" "${dest_statusline}"
        run_cmd chmod +x "${dest_statusline}"
        log_success "Deployed: statusline-command.sh -> ~/.claude/statusline-command.sh"
        ((deployed_count++)) || true
    fi
    # Clean up legacy statusline.sh if it exists
    [ -f "${HOME}/.claude/statusline.sh" ] && rm -f "${HOME}/.claude/statusline.sh" && log_info "Removed legacy statusline.sh"

    # Copy this installer for reference
    local src_installer="${SCRIPT_DIR}/configure-claude.sh"
    local dest_installer="${SCRIPTS_DIR}/configure-claude.sh"

    if files_identical "${src_installer}" "${dest_installer}"; then
        log_info "configure-claude.sh already up to date, skipping"
        ((skipped_count++)) || true
    else
        backup_file "${dest_installer}"
        run_cmd cp "${src_installer}" "${dest_installer}"
        run_cmd chmod +x "${dest_installer}"
        log_success "Deployed: configure-claude.sh (reference copy)"
        ((deployed_count++)) || true
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
# STEP 5: CONFIGURE PLATFORM SETTINGS
# ============================================================================

configure_platform_settings() {
    log_step 5 "${TOTAL_STEPS}" "Configure Platform Settings"

    local changes_made=false

    # --- Git identity (all platforms) ---
    local current_name current_email
    current_name=$(git config --global user.name 2>/dev/null || echo "")
    current_email=$(git config --global user.email 2>/dev/null || echo "")

    if [[ -z "${current_name}" ]] || [[ -z "${current_email}" ]]; then
        if [[ "${NON_INTERACTIVE:-false}" == "true" ]]; then
            # Non-interactive: try to derive from user-profile.md if available
            local profile_file="${HOME}/.claude/foundation/user-profile.md"
            local derived_name="" derived_email=""
            if [[ -f "${profile_file}" ]]; then
                # Extract name from "**Name** —" pattern
                derived_name=$(sed -n 's/.*\*\*\([^*]*\)\*\* —.*/\1/p' "${profile_file}" 2>/dev/null | head -1)
                # Extract first email address
                derived_email=$(grep -oE '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' "${profile_file}" 2>/dev/null | head -1)
            fi

            if [[ -z "${current_name}" ]]; then
                if [[ -n "${derived_name}" ]]; then
                    run_cmd git config --global user.name "${derived_name}"
                    log_info "Git user.name set to '${derived_name}' (from user-profile.md)"
                else
                    log_warn "Git user.name is not configured. Set it with: git config --global user.name 'Your Name'"
                fi
            fi
            if [[ -z "${current_email}" ]]; then
                if [[ -n "${derived_email}" ]]; then
                    run_cmd git config --global user.email "${derived_email}"
                    log_info "Git user.email set to '${derived_email}' (from user-profile.md)"
                else
                    log_warn "Git user.email is not configured. Set it with: git config --global user.email 'you@example.com'"
                fi
            fi
        else
            # Interactive: prompt the user
            if [[ -z "${current_name}" ]]; then
                local input_name=""
                read -r -p "Git user.name (your full name): " input_name
                if [[ -n "${input_name}" ]]; then
                    run_cmd git config --global user.name "${input_name}"
                    log_success "Git user.name set to '${input_name}'"
                else
                    log_warn "Git user.name skipped — set it later: git config --global user.name 'Your Name'"
                fi
            fi
            if [[ -z "${current_email}" ]]; then
                local input_email=""
                read -r -p "Git user.email (your email): " input_email
                if [[ -n "${input_email}" ]]; then
                    run_cmd git config --global user.email "${input_email}"
                    log_success "Git user.email set to '${input_email}'"
                else
                    log_warn "Git user.email skipped — set it later: git config --global user.email 'you@example.com'"
                fi
            fi
        fi
    else
        log_info "Git identity already configured: ${current_name} <${current_email}>"
    fi

    # --- Git configuration (all platforms) ---
    log_info "Configuring git..."
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

    # --- Shell color prompt (all platforms) ---
    local shellrc
    shellrc=$(detect_shell_rc)
    local shellrc_name
    shellrc_name=$(detect_shell_rc_name)

    log_info "Enabling color prompt in ${shellrc_name}..."
    if grep -q '^#force_color_prompt=yes' "${shellrc}" 2>/dev/null; then
        backup_file "${shellrc}"
        if [[ "${DRY_RUN}" == "false" ]]; then
            # Portable in-place sed (GNU sed -i'' vs BSD sed -i '' differ)
            sed 's/^#force_color_prompt=yes/force_color_prompt=yes/' "${shellrc}" > "${shellrc}.tmp" && mv "${shellrc}.tmp" "${shellrc}"
            log_success "Color prompt enabled"
        else
            echo -e "${COLOR_YELLOW}[DRY RUN]${COLOR_RESET} Would enable color prompt in ${shellrc_name}"
        fi
    else
        log_info "Color prompt already enabled or not found in ${shellrc_name}"
    fi

    # --- WSL-specific: /etc/wsl.conf check ---
    if is_wsl; then
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
    fi

    # --- SteamOS-specific notes ---
    if is_steamos; then
        echo ""
        log_info "SteamOS post-install notes:"
        log_info "  - Set a sudo password if you haven't: run 'passwd' (deck user has none by default)"
        log_info "  - Root filesystem is read-only; system writes need: sudo steamos-readonly disable"
        log_info "    Writes outside ~ are WIPED on OS updates — keep everything in your home directory"
        log_info "  - NVM and npm-global persist in ~ (survives OS updates)"
        log_info "  - System packages (socat, bubblewrap, etc.) do NOT survive OS updates"
        log_info "  - After a SteamOS update, run: bash setup/scripts/reprovision-steamos.sh"
        log_info "    (from your agent-fleet directory)"
        log_info "  - Shell config lives in ~/${shellrc_name} (not ~/.bash_profile)"
        echo ""
    fi

    log_success "Platform settings configured"

    if [[ "${changes_made}" == "true" ]]; then
        INSTALLED_STEPS+=("Platform settings (git, ${shellrc_name})")
    else
        SKIPPED_STEPS+=("Platform settings (already configured)")
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
    local _rc_name
    _rc_name=$(detect_shell_rc_name)
    echo "  1. Open a new terminal (or run: source ~/${_rc_name})"
    echo "  2. Run: mclaude"
    echo ""
    echo -e "${COLOR_BLUE}Your first session will guide you through:${COLOR_RESET}"
    echo "  - Setting up your profile (who you are, how you work)"
    echo "  - Connecting services (GitHub, Gmail, Twitter, etc.)"
    echo "  - Configuring your first project"
    echo ""
    echo -e "${COLOR_BLUE}Base MCP servers (no credentials needed):${COLOR_RESET}"
    echo "  Server definitions: ${CONFIG_DIR}/.mcp.json"
    echo "  Enablement flags:   ${CONFIG_DIR}/settings.local.json"
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

_handle_config_error() {
    local exit_code="${1:-1}"
    local line_num="${2:-unknown}"
    if [[ "$exit_code" -eq 130 ]]; then
        log_error "Configuration cancelled by user (line ${line_num})"
    else
        log_error "Configuration failed at line ${line_num} (exit code: ${exit_code})"
        [[ -n "${LOG_FILE:-}" ]] && log_error "Check log file: ${LOG_FILE}"
    fi
}

main() {
    # Initialize logging
    log_init

    # Set up cleanup trap with line info for debugging
    trap '_handle_config_error $? $LINENO' ERR INT TERM

    # Parse arguments (pass all at once so --path-prefix can consume its value)
    if ! parse_common_args "$@"; then
        show_help
        exit 0
    fi

    print_header "Claude Code Configuration (mclaude variant)"

    # Resolve tool paths for non-interactive shells (NVM, --path-prefix)
    ensure_tool_paths

    # Prerequisites check
    require_cmd cc-mirror "Run install-base.sh first"
    require_cmd node "Run install-base.sh first"
    require_cmd npm "Run install-base.sh first"
    require_file "${LAUNCHER}" "mclaude launcher (run install-base.sh first)"

    # Verify template files
    require_file "${SCRIPT_DIR}/config/settings.json" "settings.json template"
    require_file "${SCRIPT_DIR}/scripts/update-checker.sh" "update-checker script"

    log_success "Prerequisites verified"
    echo ""

    # Run configuration steps
    deploy_voltagent_config
    configure_mcp_servers
    patch_mclaude_launcher
    deploy_helper_scripts
    configure_platform_settings

    # Show summary
    print_summary
}

main "$@"
