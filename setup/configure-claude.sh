#!/usr/bin/env bash
#
# configure-claude.sh - Claude Code mclaude variant configuration
# ================================================================
# This script configures the mclaude variant created by install-base.sh.
# It sets up VoltAgent subagents, MCP servers (GitHub, Google Workspace,
# Twitter, Jira, Serena, Playwright, Memory, Diagram Bridge, Postgres),
# helper scripts, global CLAUDE.md, and WSL settings.
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
#   Step 2: Configure MCP servers (GitHub, Jira, Serena, Playwright, Memory,
#           Diagram Bridge, Postgres) with credentials
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
  2. Configure MCP servers (GitHub, Google Workspace, Twitter, Jira, Serena,
     Playwright, Memory, Diagram Bridge, Postgres)
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
        google_client_id) google_client_id="${input}" ;;
        google_client_secret) google_client_secret="${input}" ;;
        google_email) google_email="${input}" ;;
        twitter_api_key) twitter_api_key="${input}" ;;
        twitter_api_secret) twitter_api_secret="${input}" ;;
        twitter_access_token) twitter_access_token="${input}" ;;
        twitter_access_secret) twitter_access_secret="${input}" ;;
        jira_url) jira_url="${input}" ;;
        jira_email) jira_email="${input}" ;;
        jira_api_token) jira_api_token="${input}" ;;
        postgres_url) postgres_url="${input}" ;;
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

    # Helper: check if a server is already configured (non-placeholder)
    check_existing_server() {
        local server_name="$1" env_key="$2" placeholder="$3"
        if command -v jq &>/dev/null; then
            local val
            val=$(jq -r ".mcpServers.\"${server_name}\".env.\"${env_key}\" // empty" "${target}" 2>/dev/null || true)
            [[ -n "${val}" ]] && [[ "${val}" != "${placeholder}" ]]
        else
            grep -q "\"${env_key}\"" "${target}" 2>/dev/null && \
            ! grep -q "\"${placeholder}\"" "${target}" 2>/dev/null
        fi
    }

    # Parse existing config if present (for idempotency)
    local existing_github=false existing_google=false existing_twitter=false existing_jira=false existing_postgres=false
    if [[ -f "${target}" ]] && [[ "${RECONFIGURE_MCP}" == "false" ]]; then
        log_info "Checking existing MCP configuration..."

        check_existing_server github GITHUB_PERSONAL_ACCESS_TOKEN __GITHUB_TOKEN__ && existing_github=true
        check_existing_server google-workspace GOOGLE_OAUTH_CLIENT_ID __GOOGLE_CLIENT_ID__ && existing_google=true
        check_existing_server twitter API_KEY __TWITTER_API_KEY__ && existing_twitter=true
        check_existing_server jira JIRA_URL __JIRA_URL__ && existing_jira=true

        # Postgres stores its URL as a CLI arg, not env var — check if the placeholder is gone
        if command -v jq &>/dev/null; then
            local pg_arg
            pg_arg=$(jq -r '.mcpServers.postgres.args[2] // empty' "${target}" 2>/dev/null || true)
            [[ -n "${pg_arg}" ]] && [[ "${pg_arg}" != "__POSTGRES_URL__" ]] && existing_postgres=true
        elif grep -q '"@modelcontextprotocol/server-postgres"' "${target}" 2>/dev/null && \
             ! grep -q '__POSTGRES_URL__' "${target}" 2>/dev/null; then
            existing_postgres=true
        fi

        [[ "${existing_github}" == "true" ]] && log_info "GitHub MCP server already configured"
        [[ "${existing_google}" == "true" ]] && log_info "Google Workspace MCP server already configured"
        [[ "${existing_twitter}" == "true" ]] && log_info "Twitter MCP server already configured"
        [[ "${existing_jira}" == "true" ]] && log_info "Jira MCP server already configured"
        [[ "${existing_postgres}" == "true" ]] && log_info "PostgreSQL MCP server already configured"
    fi

    # --- No-credential servers (always enabled) ---
    log_info "Always-on MCP servers: Serena, Playwright, Memory, Diagram Bridge (no credentials needed)"

    # --- GitHub ---
    local setup_github=false github_token=""

    if [[ "${existing_github}" == "true" ]]; then
        log_info "Skipping GitHub credential prompt (already configured, use --reconfigure-mcp to change)"
        setup_github=true
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

    # --- Google Workspace ---
    local setup_google=false google_client_id="" google_client_secret="" google_email=""

    if [[ "${existing_google}" == "true" ]]; then
        log_info "Skipping Google Workspace credential prompt (already configured, use --reconfigure-mcp to change)"
        setup_google=true
        if command -v jq &>/dev/null; then
            google_client_id=$(jq -r '.mcpServers."google-workspace".env.GOOGLE_OAUTH_CLIENT_ID' "${target}")
            google_client_secret=$(jq -r '.mcpServers."google-workspace".env.GOOGLE_OAUTH_CLIENT_SECRET' "${target}")
            google_email=$(jq -r '.mcpServers."google-workspace".env.USER_GOOGLE_EMAIL' "${target}")
        fi
    else
        echo ""
        echo -e "${COLOR_BLUE}Google Workspace MCP Server Setup${COLOR_RESET}"
        echo "  Provides access to Gmail, Google Docs, Sheets, Calendar, Drive."
        echo "  You need a Google Cloud OAuth 2.0 Client ID."
        echo "  Create one at: https://console.cloud.google.com/apis/credentials"
        echo "  Required APIs: Gmail, Drive, Calendar, Docs, Sheets"

        if prompt_yes_no "  Set up Google Workspace MCP server?" "n"; then
            prompt_credential "  Enter your Google OAuth Client ID:" google_client_id false
            prompt_credential "  Enter your Google OAuth Client Secret:" google_client_secret
            prompt_credential "  Enter your Google account email:" google_email false
            setup_google=true
        fi
    fi

    # --- Twitter ---
    local setup_twitter=false twitter_api_key="" twitter_api_secret="" twitter_access_token="" twitter_access_secret=""

    if [[ "${existing_twitter}" == "true" ]]; then
        log_info "Skipping Twitter credential prompt (already configured, use --reconfigure-mcp to change)"
        setup_twitter=true
        if command -v jq &>/dev/null; then
            twitter_api_key=$(jq -r '.mcpServers.twitter.env.API_KEY' "${target}")
            twitter_api_secret=$(jq -r '.mcpServers.twitter.env.API_SECRET_KEY' "${target}")
            twitter_access_token=$(jq -r '.mcpServers.twitter.env.ACCESS_TOKEN' "${target}")
            twitter_access_secret=$(jq -r '.mcpServers.twitter.env.ACCESS_TOKEN_SECRET' "${target}")
        fi
    else
        echo ""
        echo -e "${COLOR_BLUE}Twitter/X MCP Server Setup${COLOR_RESET}"
        echo "  Post tweets and search. Requires Twitter API v2 credentials."
        echo "  Create an app at: https://developer.x.com"

        if prompt_yes_no "  Set up Twitter MCP server?" "n"; then
            prompt_credential "  Enter your API Key:" twitter_api_key
            prompt_credential "  Enter your API Secret:" twitter_api_secret
            prompt_credential "  Enter your Access Token:" twitter_access_token
            prompt_credential "  Enter your Access Token Secret:" twitter_access_secret
            setup_twitter=true
        fi
    fi

    # --- Jira ---
    local setup_jira=false jira_url="" jira_email="" jira_api_token=""

    if [[ "${existing_jira}" == "true" ]]; then
        log_info "Skipping Jira credential prompt (already configured, use --reconfigure-mcp to change)"
        setup_jira=true
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

        if prompt_yes_no "  Set up Jira MCP server?" "n"; then
            prompt_credential "  Enter your Jira URL (e.g. https://company.atlassian.net):" jira_url false
            prompt_credential "  Enter your Jira email:" jira_email false
            prompt_credential "  Enter your Jira API Token:" jira_api_token
            setup_jira=true
        fi
    fi

    # --- Postgres ---
    local setup_postgres=false postgres_url=""

    if [[ "${existing_postgres}" == "true" ]]; then
        log_info "Skipping PostgreSQL credential prompt (already configured, use --reconfigure-mcp to change)"
        setup_postgres=true
        if command -v jq &>/dev/null; then
            postgres_url=$(jq -r '.mcpServers.postgres.args[2]' "${target}")
        else
            postgres_url=$(grep -o '"__POSTGRES_URL__\|postgresql://[^"]*"' "${target}" | tr -d '"' | head -1)
        fi
    else
        echo ""
        echo -e "${COLOR_BLUE}PostgreSQL MCP Server Setup${COLOR_RESET}"
        echo "  Direct SQL access to a PostgreSQL database."
        echo "  Requires a connection URL: postgresql://user:pass@host:port/dbname"

        if prompt_yes_no "  Set up PostgreSQL MCP server?" "n"; then
            prompt_credential "  Enter your PostgreSQL connection URL:" postgres_url false
            setup_postgres=true
        fi
    fi

    # Build .mcp.json from template
    log_info "Generating .mcp.json..."

    local mcp_json
    mcp_json=$(sed \
        -e "s|__SERENA_CMD__|${uvx_cmd}|g" \
        -e "s|__UVX_CMD__|${uvx_cmd}|g" \
        -e "s|__NPX_CMD__|${npx_cmd}|g" \
        -e "s|__JIRA_CMD__|${uvx_cmd}|g" \
        -e "s|__PATH__|${safe_path}|g" \
        -e "s|__GITHUB_TOKEN__|${github_token}|g" \
        -e "s|__GOOGLE_CLIENT_ID__|${google_client_id}|g" \
        -e "s|__GOOGLE_CLIENT_SECRET__|${google_client_secret}|g" \
        -e "s|__GOOGLE_EMAIL__|${google_email}|g" \
        -e "s|__TWITTER_API_KEY__|${twitter_api_key}|g" \
        -e "s|__TWITTER_API_SECRET__|${twitter_api_secret}|g" \
        -e "s|__TWITTER_ACCESS_TOKEN__|${twitter_access_token}|g" \
        -e "s|__TWITTER_ACCESS_SECRET__|${twitter_access_secret}|g" \
        -e "s|__JIRA_URL__|${jira_url}|g" \
        -e "s|__JIRA_USERNAME__|${jira_email}|g" \
        -e "s|__JIRA_API_TOKEN__|${jira_api_token}|g" \
        -e "s|__POSTGRES_URL__|${postgres_url}|g" \
        "${template}")

    # Remove unconfigured servers from JSON
    for server_flag in "github:${setup_github}" "google-workspace:${setup_google}" "twitter:${setup_twitter}" "jira:${setup_jira}" "postgres:${setup_postgres}"; do
        local server_name="${server_flag%%:*}"
        local server_enabled="${server_flag##*:}"
        if [[ "${server_enabled}" != "true" ]]; then
            if command -v node &>/dev/null; then
                mcp_json=$(printf '%s' "${mcp_json}" | node -e "
                    const d = JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
                    delete d.mcpServers['${server_name}'];
                    process.stdout.write(JSON.stringify(d, null, 2));
                ")
            else
                log_warn "Node.js not available, cannot remove unconfigured server: ${server_name}"
            fi
        fi
    done

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
    local servers='"serena", "playwright", "memory", "diagram"'
    [[ "${setup_github}" == "true" ]] && servers="${servers}, \"github\""
    [[ "${setup_google}" == "true" ]] && servers="${servers}, \"google-workspace\""
    [[ "${setup_twitter}" == "true" ]] && servers="${servers}, \"twitter\""
    [[ "${setup_jira}" == "true" ]] && servers="${servers}, \"jira\""
    [[ "${setup_postgres}" == "true" ]] && servers="${servers}, \"postgres\""

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

    # Build summary of what was configured
    local configured_list="Serena, Playwright, Memory, Diagram Bridge"
    [[ "${setup_github}" == "true" ]] && configured_list="${configured_list}, GitHub"
    [[ "${setup_google}" == "true" ]] && configured_list="${configured_list}, Google Workspace"
    [[ "${setup_twitter}" == "true" ]] && configured_list="${configured_list}, Twitter"
    [[ "${setup_jira}" == "true" ]] && configured_list="${configured_list}, Jira"
    [[ "${setup_postgres}" == "true" ]] && configured_list="${configured_list}, PostgreSQL"

    log_success "MCP servers configured (${configured_list})"
    INSTALLED_STEPS+=("MCP servers (${configured_list})")
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
