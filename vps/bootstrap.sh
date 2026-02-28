#!/usr/bin/env bash
# bootstrap.sh — Full Claude Code (mclaude) setup on a fresh VPS
#
# Self-contained: clones repos, installs everything, deploys config.
# Expects secrets.env in the same directory.
#
# Usage:
#   1. scp bootstrap.sh + secrets.env to VPS
#   2. ssh into VPS
#   3. bash bootstrap.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_REPO="$HOME/agent-fleet"
CC_MIRROR_DIR="$HOME/.cc-mirror/mclaude"
BIN_DIR="$HOME/.local/bin"
SKILL_COLLECTIONS_DIR="$HOME/.local/share/skill-collections"
SECRETS_FILE="$SCRIPT_DIR/secrets.env"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "\n${GREEN}═══ $* ═══${NC}"; }

# ──────────────────────────────────────────────
# Pre-flight checks
# ──────────────────────────────────────────────

if [[ ! -f "$SECRETS_FILE" ]]; then
    log_error "Secrets file not found: $SECRETS_FILE"
    log_error "Place secrets.env next to this script before running."
    exit 1
fi

# shellcheck source=/dev/null
source "$SECRETS_FILE"

if [[ -z "${ANTHROPIC_API_KEY:-}" ]] && [[ -z "${CLAUDE_OAUTH_CREDENTIALS:-}" ]]; then
    log_error "Need either ANTHROPIC_API_KEY or CLAUDE_OAUTH_CREDENTIALS in secrets.env"
    exit 1
fi

if [[ -z "${GITHUB_PERSONAL_ACCESS_TOKEN:-}" ]]; then
    log_error "GITHUB_PERSONAL_ACCESS_TOKEN is empty in secrets.env (needed for authenticated git push by auto-sync hook)"
    exit 1
fi

# ──────────────────────────────────────────────
# Step 1: System dependencies
# ──────────────────────────────────────────────
log_step "Step 1/11: System dependencies"

sudo apt-get update -qq
sudo apt-get install -y -qq \
    curl git tmux build-essential python3 python3-pip python3-venv \
    jq unzip 2>/dev/null

# Node.js 22 (LTS) via NodeSource
if ! command -v node &>/dev/null || [[ "$(node -v | cut -d. -f1 | tr -d v)" -lt 18 ]]; then
    log_info "Installing Node.js 22 LTS..."
    NODESOURCE_SCRIPT=$(mktemp)
    curl -fsSL https://deb.nodesource.com/setup_22.x -o "$NODESOURCE_SCRIPT"
    if [[ $(wc -c < "$NODESOURCE_SCRIPT") -lt 10000 ]]; then
        log_error "NodeSource script too small — possible download failure"
        rm -f "$NODESOURCE_SCRIPT"
        exit 1
    fi
    sudo -E bash "$NODESOURCE_SCRIPT" 2>/dev/null
    rm -f "$NODESOURCE_SCRIPT"
    sudo apt-get install -y -qq nodejs 2>/dev/null
fi
log_info "Node.js: $(node -v)"

# uv/uvx (Python tool runner, needed for Serena + Google Workspace MCP)
if ! command -v uvx &>/dev/null; then
    log_info "Installing uv..."
    UV_SCRIPT=$(mktemp)
    curl -LsSf https://astral.sh/uv/install.sh -o "$UV_SCRIPT"
    if [[ $(wc -c < "$UV_SCRIPT") -lt 10000 ]]; then
        log_error "uv install script too small — possible download failure"
        rm -f "$UV_SCRIPT"
        exit 1
    fi
    sh "$UV_SCRIPT"
    rm -f "$UV_SCRIPT"
    export PATH="$HOME/.local/bin:$PATH"
fi
log_info "uv: $(uv --version 2>/dev/null || echo 'installed')"

# gh CLI (GitHub)
if ! command -v gh &>/dev/null; then
    log_info "Installing GitHub CLI..."
    (type -p wget >/dev/null || sudo apt-get install wget -y -qq) \
    && sudo mkdir -p -m 755 /etc/apt/keyrings \
    && out=$(mktemp) && wget -qO "$out" https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    && cat "$out" | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
    && sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli-stable.list > /dev/null \
    && sudo apt-get update -qq && sudo apt-get install gh -y -qq 2>/dev/null
fi
log_info "gh: $(gh --version | head -1)"

# ──────────────────────────────────────────────
# Step 2: Clone agent-fleet (private repo)
# ──────────────────────────────────────────────
log_step "Step 2/11: Clone agent-fleet"

if [[ -d "$CONFIG_REPO/.git" ]]; then
    log_info "agent-fleet already exists — pulling..."
    git -C "$CONFIG_REPO" pull --quiet
else
    log_info "Cloning agent-fleet (private)..."
    # Store PAT via git credential-store so it's not embedded in the remote URL
    CRED_FILE="$HOME/.git-credentials"
    GITHUB_USER="${GITHUB_USER:-__GITHUB_USERNAME__}"
    if [[ "$GITHUB_USER" == __*__ ]]; then
        log_error "GITHUB_USER is not set — add it to secrets.env"
        exit 1
    fi
    printf 'https://%s:%s@github.com\n' "${GITHUB_USER}" "${GITHUB_PERSONAL_ACCESS_TOKEN}" > "$CRED_FILE"
    chmod 600 "$CRED_FILE"
    git config --global credential.helper "store --file=$CRED_FILE"
    CONFIG_REPO_URL="${CONFIG_REPO_URL:-https://github.com/${GITHUB_USER}/agent-fleet.git}"
    git clone --quiet "$CONFIG_REPO_URL" "$CONFIG_REPO"
fi
log_info "agent-fleet → $CONFIG_REPO"

# Copy secrets.env into the repo's vps/ dir (gitignored)
cp "$SECRETS_FILE" "$CONFIG_REPO/vps/secrets.env" 2>/dev/null || true

# ──────────────────────────────────────────────
# Step 3: cc-mirror directory structure
# ──────────────────────────────────────────────
log_step "Step 3/11: cc-mirror directory structure"

mkdir -p "$CC_MIRROR_DIR"/{npm,config/.claude,config/plugins/marketplaces,config/skills,config/backups,docs,scripts,tweakcc}
mkdir -p "$BIN_DIR"

log_info "Created: $CC_MIRROR_DIR/"

# ──────────────────────────────────────────────
# Step 4: Install Claude Code
# ──────────────────────────────────────────────
log_step "Step 4/11: Claude Code (npm package)"

cd "$CC_MIRROR_DIR/npm"
if [[ ! -f package.json ]]; then
    npm init -y --silent 2>/dev/null
fi
npm install @anthropic-ai/claude-code@latest --silent 2>/dev/null

CC_VERSION=$(node -e "console.log(require('./node_modules/@anthropic-ai/claude-code/package.json').version)")
log_info "Claude Code v$CC_VERSION installed"

# ──────────────────────────────────────────────
# Step 5: variant.json
# ──────────────────────────────────────────────
log_step "Step 5/11: variant.json"

cat > "$CC_MIRROR_DIR/variant.json" <<VJSON
{
  "name": "mclaude",
  "provider": "mirror",
  "baseUrl": "",
  "createdAt": "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)",
  "claudeOrig": "npm:@anthropic-ai/claude-code@$CC_VERSION",
  "binaryPath": "$CC_MIRROR_DIR/npm/node_modules/@anthropic-ai/claude-code/cli.js",
  "configDir": "$CC_MIRROR_DIR/config",
  "tweakDir": "$CC_MIRROR_DIR/tweakcc",
  "brand": "mirror",
  "promptPack": false,
  "skillInstall": true,
  "shellEnv": false,
  "binDir": "$BIN_DIR",
  "installType": "npm",
  "npmDir": "$CC_MIRROR_DIR/npm",
  "npmPackage": "@anthropic-ai/claude-code",
  "npmVersion": "$CC_VERSION",
  "teamModeEnabled": true,
  "updatedAt": "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
}
VJSON

log_info "variant.json created"

# ──────────────────────────────────────────────
# Step 6: mclaude launcher
# ──────────────────────────────────────────────
log_step "Step 6/11: mclaude launcher"

cat > "$BIN_DIR/mclaude" <<LAUNCHER
#!/usr/bin/env bash
set -euo pipefail
export CLAUDE_CONFIG_DIR="$CC_MIRROR_DIR/config"
export TWEAKCC_CONFIG_DIR="$CC_MIRROR_DIR/tweakcc"
if command -v node >/dev/null 2>&1; then
  __cc_mirror_env_file="\$(mktemp)"
  node - <<'NODE' > "\$__cc_mirror_env_file" || true
const fs = require('fs');
const path = require('path');
const dir = process.env.CLAUDE_CONFIG_DIR;
if (!dir) process.exit(0);
const file = path.join(dir, 'settings.json');
const escape = (value) => "'" + String(value).replace(/'/g, "'\"'\"'") + "'";
try {
  if (fs.existsSync(file)) {
    const data = JSON.parse(fs.readFileSync(file, 'utf8'));
    const env = data && typeof data === 'object' ? data.env : null;
    if (env && typeof env === 'object') {
      for (const [key, value] of Object.entries(env)) {
        if (!key) continue;
        process.stdout.write('export ' + key + '=' + escape(value) + '\\n');
      }
    }
  }
} catch {
  // ignore malformed settings
}
NODE
  if [[ -s "\$__cc_mirror_env_file" ]]; then
    # shellcheck disable=SC1090
    source "\$__cc_mirror_env_file"
  fi
  rm -f "\$__cc_mirror_env_file" || true
fi
if [[ "\${CC_MIRROR_UNSET_AUTH_TOKEN:-0}" != "0" ]]; then
  unset ANTHROPIC_AUTH_TOKEN
fi
# Dynamic team name: directory-based
if [[ -n "\${CLAUDE_CODE_TEAM_MODE:-}" ]]; then
  __cc_git_root=\$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  __cc_folder_name=\$(basename "\$__cc_git_root")
  if [[ -n "\${TEAM:-}" ]]; then
    export CLAUDE_CODE_TEAM_NAME="\${__cc_folder_name}-\${TEAM}"
  else
    export CLAUDE_CODE_TEAM_NAME="\${__cc_folder_name}"
  fi
elif [[ -n "\${TEAM:-}" ]]; then
  __cc_git_root=\$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  __cc_folder_name=\$(basename "\$__cc_git_root")
  export CLAUDE_CODE_TEAM_NAME="\${__cc_folder_name}-\${TEAM}"
fi
# Ensure MCP servers are enabled
__cc_enable_mcp() {
  local config_mcp="\${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/.mcp.json"
  local home_mcp_file="\$HOME/.mcp.json"
  local project_mcp="\${PWD}/.mcp.json"
  local needed_json
  needed_json=\$(python3 -c "
import json, os
servers = set()
for path in ['\$config_mcp', '\$home_mcp_file', '\$project_mcp']:
    try:
        if os.path.exists(path):
            with open(path, 'r') as f:
                d = json.load(f)
            servers.update(d.get('mcpServers', {}).keys())
    except Exception:
        pass
print(json.dumps(sorted(servers)))
" 2>/dev/null) || needed_json='[]'
  local config_dir="\${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/.claude"
  local project_dir="\${PWD}/.claude"
  for settings_dir in "\$config_dir" "\$project_dir"; do
    local settings_file="\${settings_dir}/settings.local.json"
    mkdir -p "\$settings_dir" 2>/dev/null || true
    python3 -c "
import json, os
f_path = '\$settings_file'
needed = json.loads('\$needed_json')
try:
    if os.path.exists(f_path):
        with open(f_path, 'r') as f:
            d = json.load(f)
    else:
        d = {}
    changed = False
    if sorted(d.get('enabledMcpjsonServers', [])) != sorted(needed):
        d['enabledMcpjsonServers'] = needed
        changed = True
    if not d.get('enableAllProjectMcpServers'):
        d['enableAllProjectMcpServers'] = True
        changed = True
    if changed:
        with open(f_path, 'w') as f:
            json.dump(d, f, indent=2)
            f.write('\\n')
except Exception:
    pass
" 2>/dev/null || true
  done
  local src_mcp="\${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/.mcp.json"
  local home_mcp="\$HOME/.mcp.json"
  if [[ -f "\$src_mcp" ]] && [[ ! -f "\$home_mcp" || "\$src_mcp" -nt "\$home_mcp" ]]; then
    cp "\$src_mcp" "\$home_mcp" 2>/dev/null || true
  fi
}
__cc_enable_mcp
exec node "$CC_MIRROR_DIR/npm/node_modules/@anthropic-ai/claude-code/cli.js" "\$@"
LAUNCHER

chmod +x "$BIN_DIR/mclaude"

# Ensure ~/.local/bin is in PATH
if ! grep -q 'local/bin' "$HOME/.bashrc" 2>/dev/null; then
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
fi

log_info "mclaude launcher → $BIN_DIR/mclaude"

# ──────────────────────────────────────────────
# Step 7: settings.json + .mcp.json
# ──────────────────────────────────────────────
log_step "Step 7/11: Config (settings.json + .mcp.json)"

# settings.json — adapted for VPS (no WSL/Windows permissions)
cat > "$CC_MIRROR_DIR/config/settings.json" <<SETTINGS
{
  "env": {
    "CC_MIRROR_SPLASH": "1",
    "CC_MIRROR_PROVIDER_LABEL": "Mirror Claude (VPS)",
    "CC_MIRROR_SPLASH_STYLE": "mirror",
    "TWEAKCC_CONFIG_DIR": "$CC_MIRROR_DIR/tweakcc",
    "CLAUDE_CODE_TEAM_MODE": "1",
    "CLAUDE_CODE_AGENT_TYPE": "team-lead",
    "DISABLE_AUTOUPDATER": "1",
    "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION": "1",
    "FORCE_COLOR": "1",
    "COLORTERM": "truecolor"
  },
  "permissions": {
    "allow": [
      "Skill(orchestration)",
      "WebSearch",
      "WebFetch(*)",
      "Read(*)",
      "Glob(*)",
      "Grep(*)",
      "Write(*)",
      "Edit(*)",
      "Bash(ls:*)",
      "Bash(cat:*)",
      "Bash(echo:*)",
      "Bash(which:*)",
      "Bash(env:*)",
      "Bash(wc:*)",
      "Bash(tr:*)",
      "Bash(tput:*)",
      "Bash(command:*)",
      "Bash(head:*)",
      "Bash(tail:*)",
      "Bash(sort:*)",
      "Bash(grep:*)",
      "Bash(find:*)",
      "Bash(md5sum:*)",
      "Bash(crc32:*)",
      "Bash(sha256sum:*)",
      "Bash(awk:*)",
      "Bash(sed:*)",
      "Bash(diff:*)",
      "Bash(xargs:*)",
      "Bash(basename:*)",
      "Bash(dirname:*)",
      "Bash(realpath:*)",
      "Bash(stat:*)",
      "Bash(file:*)",
      "Bash(date:*)",
      "Bash(tee:*)",
      "Bash(touch:*)",
      "Bash(test:*)",
      "Bash([:*)",
      "Bash(pwd:*)",
      "Bash(git:*)",
      "Bash(npm:*)",
      "Bash(npx:*)",
      "Bash(node:*)",
      "Bash(python3:*)",
      "Bash(python:*)",
      "Bash(pip:*)",
      "Bash(uvx:*)",
      "Bash(curl:*)",
      "Bash(gh:*)",
      "Bash(mkdir:*)",
      "Bash(cp:*)",
      "Bash(mv:*)",
      "Bash(chmod:*)",
      "Bash(kill:*)",
      "Bash(docker:*)",
      "Bash(timeout:*)",
      "Bash(tmux:*)",
      "Bash(cc-mirror:*)",
      "Bash(mclaude:*)",
      "mcp__serena__*",
      "mcp__github__*"
    ]
  },
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/hooks/config-check.sh",
            "timeout": 5
          }
        ]
      }
    ],
    "SessionEnd": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/hooks/config-auto-sync.sh",
            "timeout": 30
          }
        ]
      }
    ]
  },
  "enabledPlugins": {
    "voltagent-lang@voltagent-subagents": false,
    "voltagent-infra@voltagent-subagents": false,
    "voltagent-core-dev@voltagent-subagents": false,
    "voltagent-qa-sec@voltagent-subagents": false,
    "voltagent-data-ai@voltagent-subagents": false,
    "voltagent-dev-exp@voltagent-subagents": false,
    "voltagent-domains@voltagent-subagents": false,
    "voltagent-biz@voltagent-subagents": true,
    "voltagent-meta@voltagent-subagents": false,
    "voltagent-research@voltagent-subagents": true
  }
}
SETTINGS

# .mcp.json — VPS-adapted (no pst-search, secrets injected)
UVX_PATH="$(which uvx 2>/dev/null || echo "$HOME/.local/bin/uvx")"
NPX_PATH="$(which npx 2>/dev/null || echo "/usr/bin/npx")"
SYSTEM_PATH="$HOME/.local/bin:$HOME/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Generate .mcp.json via python3 so token values are JSON-encoded safely.
# Tokens containing double quotes, backslashes, or newlines are handled correctly.
MCP_UVX_PATH="$UVX_PATH" \
MCP_NPX_PATH="$NPX_PATH" \
MCP_SYSTEM_PATH="$SYSTEM_PATH" \
MCP_GITHUB_PAT="${GITHUB_PERSONAL_ACCESS_TOKEN}" \
MCP_TWITTER_API_KEY="${TWITTER_API_KEY:-}" \
MCP_TWITTER_API_SECRET_KEY="${TWITTER_API_SECRET_KEY:-}" \
MCP_TWITTER_ACCESS_TOKEN="${TWITTER_ACCESS_TOKEN:-}" \
MCP_TWITTER_ACCESS_TOKEN_SECRET="${TWITTER_ACCESS_TOKEN_SECRET:-}" \
MCP_GOOGLE_OAUTH_CLIENT_ID="${GOOGLE_OAUTH_CLIENT_ID:-}" \
MCP_GOOGLE_OAUTH_CLIENT_SECRET="${GOOGLE_OAUTH_CLIENT_SECRET:-}" \
MCP_GOOGLE_USER_EMAIL="${GOOGLE_USER_EMAIL:-}" \
python3 - > "$CC_MIRROR_DIR/config/.mcp.json" <<'PYEOF'
import json, os
e = os.environ
mcp = {
    "mcpServers": {
        "serena": {
            "command": e["MCP_UVX_PATH"],
            "args": [
                "--from",
                "git+https://github.com/oraios/serena",
                "serena-mcp-server",
                "--context",
                "claude-code",
                "--open-web-dashboard",
                "False"
            ],
            "env": {
                "PATH": e["MCP_SYSTEM_PATH"]
            }
        },
        "github": {
            "command": e["MCP_NPX_PATH"],
            "args": ["-y", "@modelcontextprotocol/server-github"],
            "env": {
                "GITHUB_PERSONAL_ACCESS_TOKEN": e["MCP_GITHUB_PAT"],
                "PATH": e["MCP_SYSTEM_PATH"]
            }
        },
        "twitter": {
            "command": e["MCP_NPX_PATH"],
            "args": ["-y", "@enescinar/twitter-mcp"],
            "env": {
                "API_KEY": e["MCP_TWITTER_API_KEY"],
                "API_SECRET_KEY": e["MCP_TWITTER_API_SECRET_KEY"],
                "ACCESS_TOKEN": e["MCP_TWITTER_ACCESS_TOKEN"],
                "ACCESS_TOKEN_SECRET": e["MCP_TWITTER_ACCESS_TOKEN_SECRET"],
                "PATH": e["MCP_SYSTEM_PATH"]
            }
        },
        "google-workspace": {
            "command": e["MCP_UVX_PATH"],
            "args": ["workspace-mcp"],
            "env": {
                "GOOGLE_OAUTH_CLIENT_ID": e["MCP_GOOGLE_OAUTH_CLIENT_ID"],
                "GOOGLE_OAUTH_CLIENT_SECRET": e["MCP_GOOGLE_OAUTH_CLIENT_SECRET"],
                "OAUTHLIB_INSECURE_TRANSPORT": "1",
                "USER_GOOGLE_EMAIL": e["MCP_GOOGLE_USER_EMAIL"],
                "PATH": e["MCP_SYSTEM_PATH"]
            }
        }
    }
}
print(json.dumps(mcp, indent=2))
PYEOF

log_info "settings.json created"
log_info ".mcp.json created with secrets injected"

# ──────────────────────────────────────────────
# Step 8: ANTHROPIC_API_KEY in .bashrc
# ──────────────────────────────────────────────
log_step "Step 8/11: Auth credentials"

# API key in a separate sourced file (not exposed in .bashrc directly)
if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    CREDS_FILE="$HOME/.claude-credentials"
    printf 'export ANTHROPIC_API_KEY=%q\n' "$ANTHROPIC_API_KEY" > "$CREDS_FILE"
    chmod 600 "$CREDS_FILE"
    # Source from .bashrc if not already set up
    if ! grep -q 'claude-credentials' "$HOME/.bashrc" 2>/dev/null; then
        echo '[ -f "$HOME/.claude-credentials" ] && source "$HOME/.claude-credentials"' >> "$HOME/.bashrc"
    fi
    # Remove any old direct export from .bashrc
    sed -i '/^export ANTHROPIC_API_KEY=/d' "$HOME/.bashrc" 2>/dev/null || true
    log_info "ANTHROPIC_API_KEY set in ~/.claude-credentials (chmod 600)"
fi

# OAuth credentials (Claude Max subscription)
if [[ -n "${CLAUDE_OAUTH_CREDENTIALS:-}" ]]; then
    echo "$CLAUDE_OAUTH_CREDENTIALS" > "$CC_MIRROR_DIR/config/.credentials.json"
    chmod 600 "$CC_MIRROR_DIR/config/.credentials.json"
    log_info "OAuth credentials deployed to .credentials.json"
    log_warn "OAuth tokens expire. If auth fails, run: mclaude login"
else
    log_warn "No OAuth credentials — you'll need to run 'mclaude login' on first use"
fi

# ──────────────────────────────────────────────
# Step 9: VoltAgent subagents + skill collections
# ──────────────────────────────────────────────
log_step "Step 9/11: Plugins & skill collections"

# VoltAgent subagents
VOLTAGENT_DIR="$CC_MIRROR_DIR/config/plugins/marketplaces/voltagent-subagents"
if [[ -d "$VOLTAGENT_DIR/.git" ]]; then
    log_info "VoltAgent subagents already cloned — pulling..."
    git -C "$VOLTAGENT_DIR" pull --quiet
else
    rm -rf "$VOLTAGENT_DIR"
    git clone --quiet https://github.com/VoltAgent/awesome-claude-code-subagents "$VOLTAGENT_DIR"
fi
log_info "VoltAgent subagents: $(ls "$VOLTAGENT_DIR/categories/" 2>/dev/null | wc -l) categories"

# Skill collections
mkdir -p "$SKILL_COLLECTIONS_DIR"
declare -A SKILL_REPOS=(
    ["anthropic-skills"]="https://github.com/anthropics/skills"
    ["voltagent-skills"]="https://github.com/VoltAgent/awesome-agent-skills"
    ["getsentry-skills"]="https://github.com/getsentry/skills"
    ["obra-superpowers"]="https://github.com/obra/superpowers"
    ["trailofbits-skills"]="https://github.com/trailofbits/skills"
)
for name in "${!SKILL_REPOS[@]}"; do
    dir="$SKILL_COLLECTIONS_DIR/$name"
    if [[ -d "$dir/.git" ]]; then
        log_info "$name — pulling..."
        git -C "$dir" pull --quiet 2>/dev/null || true
    else
        log_info "$name — cloning..."
        git clone --quiet "${SKILL_REPOS[$name]}" "$dir" 2>/dev/null || log_warn "Failed to clone $name"
    fi
done

# ──────────────────────────────────────────────
# Step 10: Skills (cc-mirror + global)
# ──────────────────────────────────────────────
log_step "Step 10/11: Skills"

# cc-mirror config skills — embedded from primary machine
# orchestration skill
mkdir -p "$CC_MIRROR_DIR/config/skills/orchestration/references/domains"
if [[ -d "$CONFIG_REPO/vps/skills/orchestration" ]]; then
    cp -r "$CONFIG_REPO/vps/skills/orchestration/"* "$CC_MIRROR_DIR/config/skills/orchestration/"
    log_info "Installed cc-mirror skill: orchestration (from repo)"
else
    log_warn "orchestration skill not in repo — will need manual copy"
fi

# task-manager skill
mkdir -p "$CC_MIRROR_DIR/config/skills/task-manager"
if [[ -d "$CONFIG_REPO/vps/skills/task-manager" ]]; then
    cp -r "$CONFIG_REPO/vps/skills/task-manager/"* "$CC_MIRROR_DIR/config/skills/task-manager/"
    log_info "Installed cc-mirror skill: task-manager (from repo)"
else
    log_warn "task-manager skill not in repo — will need manual copy"
fi

# Global skills directory
mkdir -p "$HOME/.claude/skills"

# Copy global skills from skill collections
declare -A GLOBAL_SKILLS=(
    ["modern-python"]="voltagent-skills"
    ["skill-creator"]="voltagent-skills"
    ["systematic-debugging"]="voltagent-skills"
    ["test-driven-development"]="voltagent-skills"
    ["verification-before-completion"]="voltagent-skills"
    ["writing-plans"]="voltagent-skills"
    ["unrestricted-research"]="voltagent-skills"
)
for skill in "${!GLOBAL_SKILLS[@]}"; do
    collection="${GLOBAL_SKILLS[$skill]}"
    src=$(find "$SKILL_COLLECTIONS_DIR/$collection" -type d -name "$skill" 2>/dev/null | head -1)
    if [[ -n "$src" ]] && [[ -f "$src/SKILL.md" ]]; then
        cp -r "$src" "$HOME/.claude/skills/$skill"
        log_info "Installed global skill: $skill"
    else
        mkdir -p "$HOME/.claude/skills/$skill"
        log_warn "Skill '$skill' not found in $collection — placeholder created"
    fi
done

# ──────────────────────────────────────────────
# Step 11: Deploy config repo (sync.sh setup)
# ──────────────────────────────────────────────
log_step "Step 11/11: Deploy config repo (sync.sh setup)"

mkdir -p "$HOME/.claude"

cd "$CONFIG_REPO"
bash sync.sh setup

# Configure git for auto-sync hook
# Override via GIT_USER_NAME / GIT_USER_EMAIL env vars or in secrets.env
if [[ -z "${GIT_USER_NAME:-}" || -z "${GIT_USER_EMAIL:-}" ]]; then
    log_warn "GIT_USER_NAME and/or GIT_USER_EMAIL not set in secrets.env"
    log_warn "Set them now or configure later with: git config --global user.name/email"
fi
GIT_USER_NAME="${GIT_USER_NAME:-}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-}"
[[ -n "$GIT_USER_EMAIL" ]] && git config --global user.email "$GIT_USER_EMAIL"
[[ -n "$GIT_USER_NAME" ]] && git config --global user.name "$GIT_USER_NAME"
git config --global core.autocrlf input

# Store GitHub credentials for push (used by auto-sync hook)
# PAT is stored via git credential-store (set up in Step 2), not embedded in the remote URL.
# Ensure credential-store is configured and the remote URL is clean.
CRED_FILE="$HOME/.git-credentials"
GITHUB_USER="${GITHUB_USER:-__GITHUB_USERNAME__}"
if [[ "$GITHUB_USER" == __*__ ]]; then
    log_warn "GITHUB_USER placeholder — skipping credential store update"
elif [[ ! -f "$CRED_FILE" ]] || ! grep -q 'github.com' "$CRED_FILE" 2>/dev/null; then
    printf 'https://%s:%s@github.com\n' "${GITHUB_USER}" "${GITHUB_PERSONAL_ACCESS_TOKEN}" > "$CRED_FILE"
    chmod 600 "$CRED_FILE"
fi
git config --global credential.helper "store --file=$CRED_FILE"
CONFIG_REPO_URL="${CONFIG_REPO_URL:-https://github.com/${GITHUB_USER}/agent-fleet.git}"
git -C "$CONFIG_REPO" remote set-url origin "$CONFIG_REPO_URL"

# ──────────────────────────────────────────────
# Bonus: tmux config for persistent sessions
# ──────────────────────────────────────────────
log_step "Bonus: tmux config"

if [[ ! -f "$HOME/.tmux.conf" ]]; then
    cat > "$HOME/.tmux.conf" <<'TMUX'
# Increase scrollback
set -g history-limit 50000

# Enable mouse (for scrolling from mobile terminal)
set -g mouse on

# True color support
set -g default-terminal "tmux-256color"
set -ga terminal-overrides ",*256col*:Tc"

# Status bar
set -g status-right '#H | %H:%M'

# Don't auto-rename windows
set -g allow-rename off
TMUX
    log_info "tmux.conf created"
fi

# ──────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════"
echo -e "${GREEN} Setup complete!${NC}"
echo "═══════════════════════════════════════════════"
echo ""
echo "  Claude Code:    v$CC_VERSION"
echo "  Launcher:       $BIN_DIR/mclaude"
echo "  Config:         $CC_MIRROR_DIR/config/"
echo "  Config repo:    $CONFIG_REPO"
echo ""
echo "  To start:"
echo "    source ~/.bashrc"
echo "    tmux new -s claude"
echo "    cd ~/agent-fleet && mclaude"
echo ""
echo "  Note: Google Workspace OAuth will need browser auth on first use."
echo "  Since this is a headless VPS, you may need to handle the OAuth"
echo "  flow via a forwarded port or copy tokens from the primary machine."
echo ""
