#!/usr/bin/env bash
# setup.sh — Bootstrap agent-fleet on Linux, macOS, or WSL
# Usage: bash setup.sh [--non-interactive] [--help]

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
DATE="$(date '+%Y-%m-%d')"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'

NON_INTERACTIVE=false

for arg in "$@"; do
  case "$arg" in
    --non-interactive) NON_INTERACTIVE=true ;;
    --help)
      cat <<'EOF'
Usage: bash setup.sh [--non-interactive] [--help]

Bootstraps the agent-fleet system on Linux, macOS, or WSL.

Flags:
  --non-interactive   Skip all prompts; use env vars or defaults
  --help              Show this message

Environment variables (non-interactive mode):
  CLAUDE_USER_NAME        Your full name
  CLAUDE_USER_ROLE        Your role or title
  CLAUDE_USER_BACKGROUND  Brief background description
  CLAUDE_USER_STYLE       Preferred communication style
  CLAUDE_MACHINE_ID       Machine identifier (default: hostname)
  CLAUDE_GITHUB_PAT       GitHub PAT (optional)
  CLAUDE_GOOGLE_CLIENT_ID     Google OAuth client ID (optional)
  CLAUDE_GOOGLE_CLIENT_SECRET Google OAuth client secret (optional)
  CLAUDE_GOOGLE_EMAIL         Google account email (optional)
  CLAUDE_TWITTER_API_KEY      Twitter API key (optional)
  CLAUDE_TWITTER_API_SECRET   Twitter API secret (optional)
  CLAUDE_TWITTER_ACCESS_TOKEN Twitter access token (optional)
  CLAUDE_TWITTER_ACCESS_SECRET Twitter access token secret (optional)
  CLAUDE_JIRA_URL             Jira instance URL (optional)
  CLAUDE_JIRA_EMAIL           Jira account email (optional)
  CLAUDE_JIRA_API_TOKEN       Jira API token (optional)
EOF
      exit 0 ;;
    *) echo -e "${RED}Unknown flag: $arg${RESET}" >&2; exit 1 ;;
  esac
done

step() { echo -e "\n${BOLD}${BLUE}Step $1${RESET} — $2"; }
ok()   { echo -e "  ${GREEN}+${RESET} $1"; }
warn() { echo -e "  ${YELLOW}!${RESET} $1"; }
die()  { echo -e "\n${RED}Error:${RESET} $1" >&2; exit 1; }

prompt() {
  # prompt <var_name> <label> <default>
  local var="$1" label="$2" default="$3"
  if [[ "$NON_INTERACTIVE" == true ]]; then
    printf -v "$var" '%s' "${!var:-$default}"
  else
    local answer
    read -r -p "  $label [${default}]: " answer
    printf -v "$var" '%s' "${answer:-$default}"
  fi
}

backup_if_exists() {
  local target="$1"
  if [[ -e "$target" || -L "$target" ]]; then
    mv "$target" "${target}.bak.${DATE}"
    warn "Backed up $(basename "$target") -> $(basename "$target").bak.${DATE}"
  fi
}

cmd_info() {
  # Returns "path | version" or "not found"
  local path; path="$(command -v "$1" 2>/dev/null)" || { echo "not found"; return; }
  local ver; ver="$("$1" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+[.0-9]*' | head -1 || true)"
  echo "${path} | ${ver:-unknown}"
}

# ---------------------------------------------------------------------------
# Step 1 — Detect platform
# ---------------------------------------------------------------------------
step "1/7" "Detecting platform"

PLATFORM="linux"
[[ "$OSTYPE" == "darwin"* ]] && PLATFORM="macos"
grep -qi microsoft /proc/version 2>/dev/null && PLATFORM="wsl"
ok "Platform: ${PLATFORM}"

# ---------------------------------------------------------------------------
# Step 2 — Check prerequisites
# ---------------------------------------------------------------------------
step "2/7" "Checking prerequisites"

command -v git &>/dev/null || die "git is not installed. Please install git first."
ok "git: $(command -v git)"

# Ensure git user.name and email are configured (needed for auto-sync hooks)
if [[ -z "$(git config --global user.name 2>/dev/null)" ]]; then
  if [[ "$NON_INTERACTIVE" == true ]]; then
    warn "git user.name not set — auto-sync commits may fail"
  else
    read -r -p "  git user.name not set. Your name for commits: " _gitname
    [[ -n "$_gitname" ]] && git config --global user.name "$_gitname" && ok "Set git user.name"
  fi
fi
if [[ -z "$(git config --global user.email 2>/dev/null)" ]]; then
  if [[ "$NON_INTERACTIVE" == true ]]; then
    warn "git user.email not set — auto-sync commits may fail"
  else
    read -r -p "  git user.email not set. Your email for commits: " _gitemail
    [[ -n "$_gitemail" ]] && git config --global user.email "$_gitemail" && ok "Set git user.email"
  fi
fi

mkdir -p "$CLAUDE_DIR"/{foundation,domains,reference,knowledge,machines,hooks}
ok "Config dir: ${CLAUDE_DIR}"

# ---------------------------------------------------------------------------
# Step 3 — User profile
# ---------------------------------------------------------------------------
step "3/7" "User profile setup"

PROFILE_FILE="$REPO_DIR/global/foundation/user-profile.md"

if [[ "$NON_INTERACTIVE" == true && -f "$PROFILE_FILE" ]]; then
  warn "Keeping existing user-profile.md (non-interactive)"
else
  CLAUDE_USER_NAME="${CLAUDE_USER_NAME:-}"
  CLAUDE_USER_ROLE="${CLAUDE_USER_ROLE:-}"
  CLAUDE_USER_BACKGROUND="${CLAUDE_USER_BACKGROUND:-}"
  CLAUDE_USER_STYLE="${CLAUDE_USER_STYLE:-}"

  prompt CLAUDE_USER_NAME       "Your full name"               "User"
  prompt CLAUDE_USER_ROLE       "Your role or title"           "Developer"
  prompt CLAUDE_USER_BACKGROUND "Brief background (1 line)"    "Software developer"
  prompt CLAUDE_USER_STYLE      "Preferred communication style" "Direct and technical"

  mkdir -p "$(dirname "$PROFILE_FILE")"
  cat > "$PROFILE_FILE" <<EOF
# User Profile

## Identity
- **Name:** ${CLAUDE_USER_NAME}
- **Role:** ${CLAUDE_USER_ROLE}

## Background
${CLAUDE_USER_BACKGROUND}

## Communication Style
${CLAUDE_USER_STYLE}

## Notes
_Auto-generated by setup.sh on ${DATE}. Edit freely._
EOF
  ok "Wrote global/foundation/user-profile.md"
fi

# ---------------------------------------------------------------------------
# Step 4 — Machine catalog
# ---------------------------------------------------------------------------
step "4/7" "Machine catalog"

CLAUDE_MACHINE_ID="${CLAUDE_MACHINE_ID:-}"
prompt CLAUDE_MACHINE_ID "Machine ID (hostname or custom label)" "$(hostname)"

CATALOG_FILE="$REPO_DIR/machine-catalog.md"
TOOL_ROWS=""
for tool in git node npm python3 docker gh pandoc curl wget jq make; do
  info="$(cmd_info "$tool")"
  if [[ "$info" == "not found" ]]; then
    TOOL_ROWS+="| \`${tool}\` | — | not found |\n"
  else
    p="${info%% |*}"; v="${info##*| }"
    TOOL_ROWS+="| \`${tool}\` | ${p} | ${v} |\n"
  fi
done

CC_VARIANT="vanilla"
if command -v claude &>/dev/null; then
  [[ "$(command -v claude)" == *mirror* ]] && CC_VARIANT="cc-mirror"
fi

cat > "$CATALOG_FILE" <<EOF
# Machine Catalog: ${CLAUDE_MACHINE_ID}

Platform: ${PLATFORM}
Last updated: ${DATE}

## Installed Tools

| Tool | Path | Version |
|------|------|---------|
$(printf "%b" "$TOOL_ROWS")

## Claude Code

- Variant: ${CC_VARIANT}
- Config path: ${CLAUDE_DIR}/

## MCP Servers

(none configured yet)
EOF

ok "Wrote machine-catalog.md (machine: ${CLAUDE_MACHINE_ID})"

# ---------------------------------------------------------------------------
# Step 5 — Infrastructure discovery
# ---------------------------------------------------------------------------
step "5/7" "Infrastructure discovery"

INFRA_DIR="$HOME/infrastructure"
INFRA_SCRIPT="$REPO_DIR/setup/scripts/infra-discover.sh"

if [[ -d "$INFRA_DIR" ]]; then
  warn "~/infrastructure/ already exists — skipping creation"
  if [[ "$NON_INTERACTIVE" != true ]]; then
    read -r -p "  Re-run infrastructure discovery? [y/N]: " _rediscover
    if [[ "${_rediscover,,}" == "y" && -x "$INFRA_SCRIPT" ]]; then
      bash "$INFRA_SCRIPT" > "$INFRA_DIR/infrastructure-map.md"
      ok "Re-discovered infrastructure → infrastructure-map.md"
    fi
  fi
else
  mkdir -p "$INFRA_DIR/.claude"
  if [[ -x "$INFRA_SCRIPT" ]]; then
    bash "$INFRA_SCRIPT" > "$INFRA_DIR/infrastructure-map.md"
    ok "Discovered infrastructure → infrastructure-map.md"
  else
    warn "infra-discover.sh not found or not executable — skipping discovery"
  fi

  # Copy project template if available
  INFRA_TEMPLATE="$REPO_DIR/projects/infrastructure/rules/CLAUDE.md"
  if [[ -f "$INFRA_TEMPLATE" ]]; then
    cp "$INFRA_TEMPLATE" "$INFRA_DIR/.claude/CLAUDE.md"
    ok "Installed infrastructure project CLAUDE.md"
  fi

  # Create starter files
  cat > "$INFRA_DIR/session-context.md" <<SEOF
# Session Context

## Session Info
- **Last Updated**: ${DATE}
- **Machine**: ${CLAUDE_MACHINE_ID}
- **Working Directory**: ~/infrastructure
- **Session Goal**: Initial setup

## Current State
- **Active Task**: Review infrastructure-map.md
- **Progress**:
  - [x] Infrastructure discovery completed
- **Pending**: Review discovered topology, annotate roles

## Key Decisions

## Recovery Instructions
1. Review infrastructure-map.md for discovered network topology
2. Update CLAUDE.md with project-specific access details
SEOF

  cat > "$INFRA_DIR/backlog.md" <<BEOF
# Backlog — infrastructure

## Open

- [ ] [P3] **Review infrastructure map**: Review auto-discovered network topology, annotate device roles
- [ ] [P3] **Set up secrets vault**: Create encrypted vault for credentials (age or openssl)

## Done

### ${DATE}
- [x] Project created by setup.sh with infrastructure discovery
BEOF

  # Initialize git repo
  cd "$INFRA_DIR"
  git init --quiet
  git add -A
  git commit -m "Initial infrastructure project from setup.sh" --quiet 2>/dev/null || true
  cd "$REPO_DIR"

  ok "Created ~/infrastructure/ with discovery results, backlog, and git repo"
fi

# ---------------------------------------------------------------------------
# Step 6 — Symlinks
# ---------------------------------------------------------------------------
step "6/7" "Creating symlinks in ${CLAUDE_DIR}"

if [[ -f "$REPO_DIR/global/CLAUDE.md" ]]; then
  backup_if_exists "$CLAUDE_DIR/CLAUDE.md"
  ln -s "$REPO_DIR/global/CLAUDE.md" "$CLAUDE_DIR/CLAUDE.md"
  ok "Linked CLAUDE.md"
else
  warn "global/CLAUDE.md not found — skipping"
fi

for dir in foundation domains reference knowledge machines; do
  src="$REPO_DIR/global/$dir"
  dst="$CLAUDE_DIR/$dir"
  if [[ -d "$src" ]]; then
    backup_if_exists "$dst"
    ln -s "$src" "$dst"
    ok "Linked $dir/"
  else
    warn "global/$dir/ not found — skipping"
  fi
done

# Create CLAUDE.local.md pointing to machine file
MACHINE_FILE="$REPO_DIR/global/machines/${CLAUDE_MACHINE_ID}.md"
LOCAL_MD="$HOME/CLAUDE.local.md"
if [[ ! -f "$LOCAL_MD" ]]; then
  # Create machine file from template if it doesn't exist yet
  MACHINE_TEMPLATE="$REPO_DIR/global/machines/_template.md"
  if [[ -f "$MACHINE_TEMPLATE" && ! -f "$MACHINE_FILE" ]]; then
    sed "s/<hostname-pattern>/${CLAUDE_MACHINE_ID}/g" "$MACHINE_TEMPLATE" \
      | sed "s/- \*\*Platform\*\*:/- **Platform**: ${PLATFORM}/" \
      | sed "s/- \*\*Hostname pattern\*\*:/- **Hostname pattern**: $(hostname)/" \
      | sed "s/- \*\*User\*\*:/- **User**: $(whoami)/" \
      > "$MACHINE_FILE"
    ok "Created machine file: machines/${CLAUDE_MACHINE_ID}.md"
  fi
  echo "@~/.claude/machines/${CLAUDE_MACHINE_ID}.md" > "$LOCAL_MD"
  ok "Created ~/CLAUDE.local.md -> machines/${CLAUDE_MACHINE_ID}.md"
else
  warn "~/CLAUDE.local.md already exists — keeping existing"
fi

# ---------------------------------------------------------------------------
# Step 7 — Hooks
# ---------------------------------------------------------------------------
step "7/7" "Installing hooks"

HOOKS_SRC="$REPO_DIR/global/hooks"
if [[ -d "$HOOKS_SRC" ]]; then
  shopt -s nullglob
  hooks=("$HOOKS_SRC"/*.sh)
  shopt -u nullglob
  if [[ ${#hooks[@]} -gt 0 ]]; then
    for hook in "${hooks[@]}"; do
      fname="$(basename "$hook")"
      cp "$hook" "$CLAUDE_DIR/hooks/$fname"
      chmod +x "$CLAUDE_DIR/hooks/$fname"
      ok "Installed hook: $fname"
    done
  else
    warn "No .sh hooks found in global/hooks/"
  fi
else
  warn "global/hooks/ not found — skipping"
fi

# ---------------------------------------------------------------------------
# Optional — MCP Server Setup
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}${BLUE}MCP Server Setup${RESET}"
echo "  MCP servers let Claude access external tools (GitHub, Gmail, Twitter, Jira)."
echo "  Serena (code navigation) is always included — no credentials needed."
echo "  You can skip all of these now and set them up later via Claude's interactive setup."
echo ""

MCP_FILE="$HOME/.mcp.json"
MCP_SERVERS='{}' # Will be built up as JSON
CONFIGURED_SERVERS="serena"

# Helper to detect tool paths
NPX_CMD="$(command -v npx 2>/dev/null || echo "npx")"
UVX_CMD="$(command -v uvx 2>/dev/null || echo "uvx")"
SAFE_PATH="${HOME}/.local/bin:${HOME}/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# --- Serena (always included) ---
SERENA_CMD="$(command -v uvx 2>/dev/null || echo "uvx")"

# --- GitHub ---
setup_github=false
CLAUDE_GITHUB_PAT="${CLAUDE_GITHUB_PAT:-}"
if [[ "$NON_INTERACTIVE" == true ]]; then
  [[ -n "$CLAUDE_GITHUB_PAT" ]] && setup_github=true
else
  read -r -p "  Set up GitHub MCP? (repos, issues, PRs) [y/N]: " _gh
  if [[ "${_gh,,}" == "y" ]]; then
    echo "    Create a PAT at: https://github.com/settings/tokens (scope: repo)"
    read -r -s -p "    GitHub PAT (hidden): " CLAUDE_GITHUB_PAT
    echo ""
    [[ -n "$CLAUDE_GITHUB_PAT" ]] && setup_github=true
  fi
fi
[[ "$setup_github" == true ]] && ok "GitHub: configured" && CONFIGURED_SERVERS="$CONFIGURED_SERVERS, github"

# --- Google Workspace ---
setup_google=false
CLAUDE_GOOGLE_CLIENT_ID="${CLAUDE_GOOGLE_CLIENT_ID:-}"
CLAUDE_GOOGLE_CLIENT_SECRET="${CLAUDE_GOOGLE_CLIENT_SECRET:-}"
CLAUDE_GOOGLE_EMAIL="${CLAUDE_GOOGLE_EMAIL:-}"
if [[ "$NON_INTERACTIVE" == true ]]; then
  [[ -n "$CLAUDE_GOOGLE_CLIENT_ID" ]] && setup_google=true
else
  read -r -p "  Set up Google Workspace MCP? (Gmail, Docs, Calendar, Drive) [y/N]: " _gw
  if [[ "${_gw,,}" == "y" ]]; then
    echo "    You need a Google Cloud OAuth 2.0 Client ID."
    echo "    Create one at: https://console.cloud.google.com/apis/credentials"
    echo "    Required APIs: Gmail, Drive, Calendar, Docs, Sheets"
    read -r -p "    Google OAuth Client ID: " CLAUDE_GOOGLE_CLIENT_ID
    read -r -s -p "    Google OAuth Client Secret (hidden): " CLAUDE_GOOGLE_CLIENT_SECRET
    echo ""
    read -r -p "    Google account email: " CLAUDE_GOOGLE_EMAIL
    [[ -n "$CLAUDE_GOOGLE_CLIENT_ID" && -n "$CLAUDE_GOOGLE_CLIENT_SECRET" ]] && setup_google=true
  fi
fi
[[ "$setup_google" == true ]] && ok "Google Workspace: configured" && CONFIGURED_SERVERS="$CONFIGURED_SERVERS, google-workspace"

# --- Twitter ---
setup_twitter=false
CLAUDE_TWITTER_API_KEY="${CLAUDE_TWITTER_API_KEY:-}"
CLAUDE_TWITTER_API_SECRET="${CLAUDE_TWITTER_API_SECRET:-}"
CLAUDE_TWITTER_ACCESS_TOKEN="${CLAUDE_TWITTER_ACCESS_TOKEN:-}"
CLAUDE_TWITTER_ACCESS_SECRET="${CLAUDE_TWITTER_ACCESS_SECRET:-}"
if [[ "$NON_INTERACTIVE" == true ]]; then
  [[ -n "$CLAUDE_TWITTER_API_KEY" ]] && setup_twitter=true
else
  read -r -p "  Set up Twitter/X MCP? (post tweets, search) [y/N]: " _tw
  if [[ "${_tw,,}" == "y" ]]; then
    echo "    You need Twitter API v2 credentials (developer.x.com)."
    read -r -s -p "    API Key (hidden): " CLAUDE_TWITTER_API_KEY
    echo ""
    read -r -s -p "    API Secret (hidden): " CLAUDE_TWITTER_API_SECRET
    echo ""
    read -r -s -p "    Access Token (hidden): " CLAUDE_TWITTER_ACCESS_TOKEN
    echo ""
    read -r -s -p "    Access Token Secret (hidden): " CLAUDE_TWITTER_ACCESS_SECRET
    echo ""
    [[ -n "$CLAUDE_TWITTER_API_KEY" && -n "$CLAUDE_TWITTER_ACCESS_TOKEN" ]] && setup_twitter=true
  fi
fi
[[ "$setup_twitter" == true ]] && ok "Twitter: configured" && CONFIGURED_SERVERS="$CONFIGURED_SERVERS, twitter"

# --- Jira ---
setup_jira=false
CLAUDE_JIRA_URL="${CLAUDE_JIRA_URL:-}"
CLAUDE_JIRA_EMAIL="${CLAUDE_JIRA_EMAIL:-}"
CLAUDE_JIRA_API_TOKEN="${CLAUDE_JIRA_API_TOKEN:-}"
if [[ "$NON_INTERACTIVE" == true ]]; then
  [[ -n "$CLAUDE_JIRA_URL" ]] && setup_jira=true
else
  read -r -p "  Set up Jira/Atlassian MCP? (issues, boards, sprints) [y/N]: " _jira
  if [[ "${_jira,,}" == "y" ]]; then
    echo "    Create an API token at: https://id.atlassian.com/manage-profile/security/api-tokens"
    read -r -p "    Jira URL (e.g. https://company.atlassian.net): " CLAUDE_JIRA_URL
    read -r -p "    Jira email: " CLAUDE_JIRA_EMAIL
    read -r -s -p "    Jira API token (hidden): " CLAUDE_JIRA_API_TOKEN
    echo ""
    [[ -n "$CLAUDE_JIRA_URL" && -n "$CLAUDE_JIRA_API_TOKEN" ]] && setup_jira=true
  fi
fi
[[ "$setup_jira" == true ]] && ok "Jira: configured" && CONFIGURED_SERVERS="$CONFIGURED_SERVERS, jira"

# --- Postgres ---
setup_postgres=false
CLAUDE_POSTGRES_URL="${CLAUDE_POSTGRES_URL:-}"
if [[ "$NON_INTERACTIVE" == true ]]; then
  [[ -n "$CLAUDE_POSTGRES_URL" ]] && setup_postgres=true
else
  read -r -p "  Set up Postgres MCP? (direct database queries) [y/N]: " _pg
  if [[ "${_pg,,}" == "y" ]]; then
    read -r -p "    Connection URL (e.g. postgresql://user:pass@localhost/mydb): " CLAUDE_POSTGRES_URL
    [[ -n "$CLAUDE_POSTGRES_URL" ]] && setup_postgres=true
  fi
fi
[[ "$setup_postgres" == true ]] && ok "Postgres: configured" && CONFIGURED_SERVERS="$CONFIGURED_SERVERS, postgres"

# --- Auto-included servers (no credentials needed) ---
ok "Playwright (browser automation): auto-included"
ok "Memory (knowledge graph): auto-included"
ok "Diagram (Mermaid diagram generation): auto-included"
CONFIGURED_SERVERS="$CONFIGURED_SERVERS, playwright, memory, diagram"

# --- Build .mcp.json ---
# Start with Serena (always present)
backup_if_exists "$MCP_FILE"

# Use node if available, otherwise python3, otherwise raw cat
if command -v node &>/dev/null; then
  node -e "
    const mcp = { mcpServers: {} };

    // Serena — always included
    mcp.mcpServers.serena = {
      command: '$SERENA_CMD',
      args: ['--from', 'git+https://github.com/oraios/serena', 'serena-mcp-server', '--context', 'claude-code'],
      env: { PATH: '$SAFE_PATH' }
    };

    if ('$setup_github' === 'true') {
      mcp.mcpServers.github = {
        command: '$NPX_CMD',
        args: ['-y', '@modelcontextprotocol/server-github'],
        env: { GITHUB_PERSONAL_ACCESS_TOKEN: $(printf '%s' "$CLAUDE_GITHUB_PAT" | node -e "process.stdout.write(JSON.stringify(require('fs').readFileSync('/dev/stdin','utf8')))"), PATH: '$SAFE_PATH' }
      };
    }

    if ('$setup_google' === 'true') {
      mcp.mcpServers['google-workspace'] = {
        command: '$UVX_CMD',
        args: ['workspace-mcp'],
        env: {
          GOOGLE_OAUTH_CLIENT_ID: $(printf '%s' "$CLAUDE_GOOGLE_CLIENT_ID" | node -e "process.stdout.write(JSON.stringify(require('fs').readFileSync('/dev/stdin','utf8')))"),
          GOOGLE_OAUTH_CLIENT_SECRET: $(printf '%s' "$CLAUDE_GOOGLE_CLIENT_SECRET" | node -e "process.stdout.write(JSON.stringify(require('fs').readFileSync('/dev/stdin','utf8')))"),
          USER_GOOGLE_EMAIL: $(printf '%s' "$CLAUDE_GOOGLE_EMAIL" | node -e "process.stdout.write(JSON.stringify(require('fs').readFileSync('/dev/stdin','utf8')))"),
          PATH: '$SAFE_PATH'
        }
      };
    }

    if ('$setup_twitter' === 'true') {
      mcp.mcpServers.twitter = {
        command: '$NPX_CMD',
        args: ['-y', '@enescinar/twitter-mcp'],
        env: {
          API_KEY: $(printf '%s' "$CLAUDE_TWITTER_API_KEY" | node -e "process.stdout.write(JSON.stringify(require('fs').readFileSync('/dev/stdin','utf8')))"),
          API_SECRET_KEY: $(printf '%s' "$CLAUDE_TWITTER_API_SECRET" | node -e "process.stdout.write(JSON.stringify(require('fs').readFileSync('/dev/stdin','utf8')))"),
          ACCESS_TOKEN: $(printf '%s' "$CLAUDE_TWITTER_ACCESS_TOKEN" | node -e "process.stdout.write(JSON.stringify(require('fs').readFileSync('/dev/stdin','utf8')))"),
          ACCESS_TOKEN_SECRET: $(printf '%s' "$CLAUDE_TWITTER_ACCESS_SECRET" | node -e "process.stdout.write(JSON.stringify(require('fs').readFileSync('/dev/stdin','utf8')))"),
          PATH: '$SAFE_PATH'
        }
      };
    }

    if ('$setup_jira' === 'true') {
      mcp.mcpServers.jira = {
        command: '$UVX_CMD',
        args: ['mcp-atlassian'],
        env: {
          JIRA_URL: $(printf '%s' "$CLAUDE_JIRA_URL" | node -e "process.stdout.write(JSON.stringify(require('fs').readFileSync('/dev/stdin','utf8')))"),
          JIRA_USERNAME: $(printf '%s' "$CLAUDE_JIRA_EMAIL" | node -e "process.stdout.write(JSON.stringify(require('fs').readFileSync('/dev/stdin','utf8')))"),
          JIRA_API_TOKEN: $(printf '%s' "$CLAUDE_JIRA_API_TOKEN" | node -e "process.stdout.write(JSON.stringify(require('fs').readFileSync('/dev/stdin','utf8')))"),
          PATH: '$SAFE_PATH'
        }
      };
    }

    if ('$setup_postgres' === 'true') {
      mcp.mcpServers.postgres = {
        command: '$NPX_CMD',
        args: ['-y', '@modelcontextprotocol/server-postgres', $(printf '%s' "$CLAUDE_POSTGRES_URL" | node -e "process.stdout.write(JSON.stringify(require('fs').readFileSync('/dev/stdin','utf8')))")],
        env: { PATH: '$SAFE_PATH' }
      };
    }

    // Auto-included servers (no credentials)
    mcp.mcpServers.playwright = {
      command: '$NPX_CMD',
      args: ['-y', '@playwright/mcp'],
      env: { PATH: '$SAFE_PATH' }
    };

    mcp.mcpServers.memory = {
      command: '$NPX_CMD',
      args: ['-y', '@modelcontextprotocol/server-memory'],
      env: { PATH: '$SAFE_PATH' }
    };

    mcp.mcpServers['diagram'] = {
      command: '$UVX_CMD',
      args: ['--from', 'mcp-mermaid-image-gen', 'mcp_mermaid_image_gen'],
      env: { PATH: '$SAFE_PATH' }
    };

    process.stdout.write(JSON.stringify(mcp, null, 2) + '\n');
  " > "$MCP_FILE"
elif command -v python3 &>/dev/null; then
  python3 -c "
import json, sys

mcp = {'mcpServers': {}}

mcp['mcpServers']['serena'] = {
    'command': '$SERENA_CMD',
    'args': ['--from', 'git+https://github.com/oraios/serena', 'serena-mcp-server', '--context', 'claude-code'],
    'env': {'PATH': '$SAFE_PATH'}
}

if '$setup_github' == 'true':
    mcp['mcpServers']['github'] = {
        'command': '$NPX_CMD',
        'args': ['-y', '@modelcontextprotocol/server-github'],
        'env': {'GITHUB_PERSONAL_ACCESS_TOKEN': sys.stdin.readline().strip(), 'PATH': '$SAFE_PATH'}
    }

json.dump(mcp, open('$MCP_FILE', 'w'), indent=2)
print()
" <<< "$CLAUDE_GITHUB_PAT"
  warn "Python fallback: only GitHub supported. Add other servers via Claude's interactive setup."
else
  warn "Neither node nor python3 found — skipping .mcp.json generation."
  warn "Claude's interactive setup will help you configure MCP servers."
fi

# Update machine catalog with configured servers
MCP_LIST=""
[[ "$setup_github" == true ]] && MCP_LIST="${MCP_LIST}github, "
[[ "$setup_google" == true ]] && MCP_LIST="${MCP_LIST}google-workspace, "
[[ "$setup_twitter" == true ]] && MCP_LIST="${MCP_LIST}twitter, "
[[ "$setup_jira" == true ]] && MCP_LIST="${MCP_LIST}jira, "
[[ "$setup_postgres" == true ]] && MCP_LIST="${MCP_LIST}postgres, "
MCP_LIST="${MCP_LIST}playwright, memory, diagram, serena"

sed -i'' -e "s/(none configured yet)/${MCP_LIST}/" "$CATALOG_FILE"
ok "Wrote ~/.mcp.json ($CONFIGURED_SERVERS)"

# ---------------------------------------------------------------------------
# Create first-run marker
# ---------------------------------------------------------------------------
touch "$REPO_DIR/.setup-pending"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}${GREEN}Setup complete.${RESET}"
echo ""
printf "${BOLD}%-20s${RESET} %s\n" "Platform:"    "$PLATFORM"
printf "${BOLD}%-20s${RESET} %s\n" "Machine ID:"  "$CLAUDE_MACHINE_ID"
printf "${BOLD}%-20s${RESET} %s\n" "Config dir:"  "$CLAUDE_DIR"
printf "${BOLD}%-20s${RESET} %s\n" "Repo root:"   "$REPO_DIR"
printf "${BOLD}%-20s${RESET} %s\n" "MCP servers:"  "$CONFIGURED_SERVERS"
echo ""
echo -e "${BOLD}Symlinks in ${CLAUDE_DIR}:${RESET}"
echo "  CLAUDE.md   ->  global/CLAUDE.md"
echo "  foundation/ ->  global/foundation/"
echo "  domains/    ->  global/domains/"
echo "  reference/  ->  global/reference/"
echo "  knowledge/  ->  global/knowledge/"
echo "  machines/   ->  global/machines/"

# ---------------------------------------------------------------------------
# Offer interactive refinement
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}${BLUE}Interactive setup${RESET}"
echo "  Claude can now help you personalize your configuration:"
echo "  - Refine your user profile with real preferences"
echo "  - Set up additional MCP servers you skipped above"
echo "  - Choose which knowledge domains to enable"
echo "  - Review your infrastructure map and annotate device roles"
echo "  - Set up your first project"
echo "  - Add global rules (e.g. 'always use bun', 'never auto-commit')"
echo ""

# Detect available Claude command
CLAUDE_CMD=""
if command -v mclaude &>/dev/null; then
  CLAUDE_CMD="mclaude"
elif command -v claude &>/dev/null; then
  CLAUDE_CMD="claude"
fi

if [[ -n "$CLAUDE_CMD" ]]; then
  do_refine=false
  if [[ "$NON_INTERACTIVE" == true ]]; then
    echo "  Run '$CLAUDE_CMD' in $REPO_DIR to start interactive setup."
  else
    read -r -p "  Launch Claude now for interactive setup? [Y/n]: " _refine
    [[ "${_refine,,}" != "n" ]] && do_refine=true
  fi

  if [[ "$do_refine" == true ]]; then
    echo ""
    echo -e "${BOLD}Launching $CLAUDE_CMD in ${REPO_DIR}...${RESET}"
    echo ""
    cd "$REPO_DIR"
    exec "$CLAUDE_CMD"
  fi
else
  echo -e "  ${YELLOW}Claude Code not found in PATH.${RESET}"
  echo "  After installing Claude Code, run it in ${REPO_DIR} to start interactive setup."
fi

echo ""
echo -e "${BOLD}Manual setup:${RESET}"
echo "  1. cd $REPO_DIR"
echo "  2. Run: claude  (or mclaude)"
echo "  Claude will detect the pending setup and guide you through it."
