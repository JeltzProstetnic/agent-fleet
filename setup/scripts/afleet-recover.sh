#!/usr/bin/env bash
# afleet-recover.sh — Recovery, diagnostics, rollback, and safe-mode for agent fleet
# Subcommands: doctor, recover, rollback, safe-mode
# Dispatched from afleet.sh or run standalone.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_REPO="${CONFIG_REPO:-}"
if [[ -z "$CONFIG_REPO" ]]; then
    for d in "$HOME/cfg-agent-fleet" "$HOME/agent-fleet"; do
        [[ -f "$d/sync.sh" && ! -f "$d/.template-repo" ]] && CONFIG_REPO="$d" && break
    done
fi

CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# ── Colors ──────────────────────────────────────────────────────────────────
if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
    C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'
    C_BOLD='\033[1m'; C_RESET='\033[0m'
else
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_BOLD=''; C_RESET=''
fi

# ── Output helpers ──────────────────────────────────────────────────────────
_ok()   { printf "  ${C_GREEN}OK${C_RESET}   %s\n" "$1"; }
_fail() { printf "  ${C_RED}FAIL${C_RESET} %s\n" "$1"; }
_warn() { printf "  ${C_YELLOW}WARN${C_RESET} %s\n" "$1"; }
_fix()  { printf "  ${C_GREEN}FIX${C_RESET}  %s\n" "$1"; }
_info() { printf "  ${C_BOLD}INFO${C_RESET} %s\n" "$1"; }

# ── Check functions ─────────────────────────────────────────────────────────
# Each returns 0=ok, 1=fail, 2=warn. Sets CHECK_MSG.
# When fix_mode=1, attempt auto-repair.

check_cc_binary() {
    local fix_mode="${1:-0}"
    if ! command -v claude >/dev/null 2>&1; then
        CHECK_MSG="claude binary not found in PATH"
        return 1
    fi
    local version
    version=$(claude --version 2>/dev/null) || {
        CHECK_MSG="claude --version failed"
        return 1
    }
    CHECK_MSG="claude binary: v${version}"
    return 0
}

check_settings_json() {
    local fix_mode="${1:-0}"
    local settings="$CLAUDE_CONFIG_DIR/settings.json"
    if [[ ! -f "$settings" ]]; then
        CHECK_MSG="Settings file missing: $settings"
        if [[ "$fix_mode" == "1" && -n "$CONFIG_REPO" ]]; then
            local template="$CONFIG_REPO/setup/config/settings.json"
            if [[ -f "$template" ]]; then
                cp "$template" "$settings"
                _fix "Restored settings.json from template"
                CHECK_MSG="Settings restored from template"
                return 0
            fi
        fi
        return 1
    fi
    if ! python3 -c "import json; json.load(open('$settings'))" 2>/dev/null; then
        CHECK_MSG="Settings file is not valid JSON: $settings"
        return 1
    fi
    CHECK_MSG="Settings valid JSON"
    return 0
}

check_mcp_servers() {
    local fix_mode="${1:-0}"
    local mcp_file="$CLAUDE_CONFIG_DIR/.mcp.json"
    if [[ ! -f "$mcp_file" ]]; then
        CHECK_MSG="No .mcp.json found"
        return 2
    fi

    local failed=0 checked=0 details=""
    # Parse servers using python3 for reliability
    local servers
    servers=$(python3 -c "
import json, sys
try:
    with open('$mcp_file') as f:
        d = json.load(f)
    for name, cfg in d.get('mcpServers', {}).items():
        stype = 'url' if 'url' in cfg else 'command'
        val = cfg.get('url', cfg.get('command', ''))
        print(f'{name}|{stype}|{val}')
except Exception as e:
    print(f'ERROR|error|{e}', file=sys.stderr)
" 2>/dev/null) || { CHECK_MSG="Failed to parse .mcp.json"; return 1; }

    while IFS='|' read -r name stype val; do
        [[ -z "$name" ]] && continue
        ((checked++)) || true
        if [[ "$stype" == "url" ]]; then
            # Extract host:port from URL, TCP probe with 2s timeout
            local host port
            host=$(echo "$val" | sed -E 's|https?://||; s|/.*||; s|:.*||')
            port=$(echo "$val" | grep -oE ':[0-9]+' | sed 's/^://' | head -1)
            port="${port:-80}"
            if ! timeout 2 bash -c "echo >/dev/tcp/$host/$port" 2>/dev/null; then
                details+="  $name: unreachable ($host:$port)\n"
                ((failed++)) || true
            fi
        elif [[ "$stype" == "command" ]]; then
            if ! command -v "$val" >/dev/null 2>&1; then
                details+="  $name: binary not found ($val)\n"
                ((failed++)) || true
            fi
        fi
    done <<< "$servers"

    if [[ $failed -gt 0 ]]; then
        CHECK_MSG="MCP servers: $failed of $checked unreachable\n$details"
        return 1
    fi
    CHECK_MSG="MCP servers: $checked checked, all reachable"
    return 0
}

check_hooks() {
    local fix_mode="${1:-0}"
    local hooks_dir="$HOME/.claude/hooks"
    if [[ ! -d "$hooks_dir" ]]; then
        CHECK_MSG="Hooks directory missing: $hooks_dir"
        return 1
    fi

    local failed=0 fixed=0 details=""
    while IFS= read -r -d '' hook; do
        local name
        name=$(basename "$hook")
        # Check executable
        if [[ ! -x "$hook" ]]; then
            if [[ "$fix_mode" == "1" ]]; then
                chmod +x "$hook"
                _fix "chmod +x $name"
                ((fixed++)) || true
            else
                details+="  $name: not executable\n"
                ((failed++)) || true
            fi
        fi
        # Check syntax
        if ! bash -n "$hook" 2>/dev/null; then
            details+="  $name: syntax error\n"
            ((failed++)) || true
        fi
    done < <(find "$hooks_dir" -name "*.sh" -print0 2>/dev/null)

    if [[ $fixed -gt 0 ]]; then
        details+="  Fixed $fixed hooks\n"
    fi
    if [[ $failed -gt 0 ]]; then
        CHECK_MSG="Hooks: $failed issues\n$details"
        return 1
    fi
    CHECK_MSG="Hooks: all OK${fixed:+ ($fixed fixed)}"
    return 0
}

check_session_locks() {
    local fix_mode="${1:-0}"
    local lock_file="$HOME/.claude/.session-lock"
    if [[ ! -f "$lock_file" ]]; then
        CHECK_MSG="No session lock"
        return 0
    fi

    local lock_pid lock_machine lock_ts
    lock_pid=$(python3 -c "import json; d=json.load(open('$lock_file')); print(d.get('pid','?'))" 2>/dev/null || echo "?")
    lock_machine=$(python3 -c "import json; d=json.load(open('$lock_file')); print(d.get('machine','?'))" 2>/dev/null || echo "?")
    lock_ts=$(python3 -c "import json; d=json.load(open('$lock_file')); print(d.get('timestamp','?'))" 2>/dev/null || echo "?")

    # Check if PID is still alive (same machine only)
    local hostname
    hostname=$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo "unknown")
    if [[ "$lock_machine" == "$hostname" ]]; then
        if ! kill -0 "$lock_pid" 2>/dev/null; then
            if [[ "$fix_mode" == "1" ]]; then
                rm -f "$lock_file"
                _fix "Removed stale local session lock (PID $lock_pid dead)"
                CHECK_MSG="Stale lock removed"
                return 0
            fi
            CHECK_MSG="Stale session lock: PID $lock_pid dead (machine: $lock_machine, time: $lock_ts)"
            return 2
        fi
        CHECK_MSG="Active session lock: PID $lock_pid (this machine)"
        return 2
    fi
    CHECK_MSG="Remote session lock: machine=$lock_machine, PID=$lock_pid, time=$lock_ts"
    return 2
}

check_git_state() {
    local fix_mode="${1:-0}"
    if [[ -z "$CONFIG_REPO" || ! -d "$CONFIG_REPO/.git" ]]; then
        CHECK_MSG="Config repo not found or not a git repo"
        return 1
    fi
    local status
    status=$(git -C "$CONFIG_REPO" status --porcelain 2>/dev/null) || {
        CHECK_MSG="git status failed in config repo"
        return 1
    }
    local dirty=""
    [[ -n "$status" ]] && dirty=" (dirty: $(echo "$status" | wc -l | tr -d ' ') files)"
    CHECK_MSG="Config repo: $(git -C "$CONFIG_REPO" log --oneline -1 2>/dev/null)${dirty}"
    return 0
}

# ── Subcommands ─────────────────────────────────────────────────────────────

cmd_doctor() {
    printf "\n${C_BOLD}Agent Fleet Health Check${C_RESET}\n\n"
    local total=0 ok=0 failed=0 warned=0

    local checks=(check_cc_binary check_settings_json check_mcp_servers check_hooks check_session_locks check_git_state)
    local labels=("Claude Code binary" "Settings JSON" "MCP servers" "Hooks" "Session locks" "Git state")

    for i in "${!checks[@]}"; do
        ((total++)) || true
        CHECK_MSG=""
        local rc=0
        ${checks[$i]} 0 || rc=$?
        case $rc in
            0) _ok "${labels[$i]}: $CHECK_MSG"; ((ok++)) || true ;;
            1) _fail "${labels[$i]}: $CHECK_MSG"; ((failed++)) || true ;;
            2) _warn "${labels[$i]}: $CHECK_MSG"; ((warned++)) || true ;;
        esac
    done

    printf "\n${C_BOLD}Summary:${C_RESET} %d checks — %d OK, %d failed, %d warnings\n\n" \
        "$total" "$ok" "$failed" "$warned"
    [[ $failed -eq 0 ]]
}

cmd_recover() {
    printf "\n${C_BOLD}Agent Fleet Recovery${C_RESET}\n\n"
    local total_fixes=0

    # Run all checks in fix mode
    local checks=(check_cc_binary check_settings_json check_hooks check_session_locks check_git_state)
    local labels=("Claude Code binary" "Settings JSON" "Hooks" "Session locks" "Git state")

    for i in "${!checks[@]}"; do
        CHECK_MSG=""
        local rc=0
        ${checks[$i]} 1 || rc=$?
        case $rc in
            0) _ok "${labels[$i]}: $CHECK_MSG" ;;
            1) _fail "${labels[$i]}: $CHECK_MSG (could not auto-fix)" ;;
            2) _warn "${labels[$i]}: $CHECK_MSG" ;;
        esac
    done

    # Run sync.sh deploy if available
    if [[ -n "$CONFIG_REPO" && -f "$CONFIG_REPO/sync.sh" ]]; then
        _info "Running sync.sh deploy..."
        bash "$CONFIG_REPO/sync.sh" deploy 2>&1 | sed 's/^/    /'
    fi

    printf "\n${C_BOLD}Recovery complete.${C_RESET} Run 'afleet doctor' to verify.\n\n"
}

cmd_rollback() {
    local dry_run=0 confirm=0 count=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) dry_run=1; shift ;;
            --yes|-y) confirm=1; shift ;;
            [0-9]*) count="$1"; shift ;;
            *) printf "Unknown option: %s\n" "$1" >&2; return 1 ;;
        esac
    done

    if [[ -z "$count" ]]; then
        printf "Usage: afleet rollback [--dry-run] [--yes] <N>\n"
        printf "  N = number of commits to roll back\n"
        return 1
    fi

    if [[ -z "$CONFIG_REPO" || ! -d "$CONFIG_REPO/.git" ]]; then
        printf "Error: config repo not found\n" >&2
        return 1
    fi

    local total_commits
    total_commits=$(git -C "$CONFIG_REPO" rev-list --count HEAD 2>/dev/null || echo 0)
    if [[ "$count" -ge "$total_commits" ]]; then
        printf "Error: cannot roll back %d commits (only %d exist)\n" "$count" "$total_commits" >&2
        return 1
    fi

    printf "\n${C_BOLD}Rolling back %d commit(s):${C_RESET}\n\n" "$count"
    git -C "$CONFIG_REPO" log --oneline -n "$count" 2>/dev/null | sed 's/^/  /'
    printf "\n"

    local target
    target=$(git -C "$CONFIG_REPO" rev-parse "HEAD~${count}" 2>/dev/null)
    printf "Target: %s\n" "$target"

    if [[ "$dry_run" == "1" ]]; then
        printf "\n${C_YELLOW}Dry run — no changes made.${C_RESET}\n\n"
        return 0
    fi

    if [[ "$confirm" != "1" ]]; then
        printf "\nThis will reset the config repo. Continue? [y/N] "
        read -r answer
        [[ "$answer" =~ ^[Yy] ]] || { printf "Aborted.\n"; return 1; }
    fi

    # Save current HEAD for potential undo
    local saved_head
    saved_head=$(git -C "$CONFIG_REPO" rev-parse HEAD)
    printf "Saved HEAD: %s (use 'git reset --hard %s' to undo)\n" "$saved_head" "$saved_head"

    # Reset
    git -C "$CONFIG_REPO" reset --hard "$target" 2>&1 | sed 's/^/  /'

    # Redeploy
    if [[ -f "$CONFIG_REPO/sync.sh" ]]; then
        printf "\nRedeploying from rolled-back state...\n"
        bash "$CONFIG_REPO/sync.sh" deploy 2>&1 | sed 's/^/    /'
    fi

    printf "\n${C_GREEN}Rollback complete.${C_RESET} Run 'afleet doctor' to verify.\n\n"
}

cmd_safe_mode() {
    local prepare_only="${AFLEET_SAFE_MODE_PREPARE_ONLY:-0}"
    local dry_run="${AFLEET_SAFE_MODE_DRY_RUN:-0}"

    printf "\n${C_BOLD}Agent Fleet Safe Mode${C_RESET}\n"
    printf "  Launching with: no hooks, no MCP servers, no plugins, minimal settings\n\n"

    if [[ "$dry_run" == "1" ]]; then
        printf "  ${C_YELLOW}Dry run — would create temp config and launch bare claude.${C_RESET}\n\n"
        return 0
    fi

    # Create temporary config directory
    local safe_dir
    safe_dir=$(mktemp -d "${TMPDIR:-/tmp}/afleet-safe.XXXXXX")

    # Minimal settings: no hooks, no plugins, basic permissions
    cat > "$safe_dir/settings.json" << 'EOF'
{
  "permissions": {
    "allow": [
      "Bash(git:*)",
      "Bash(ls:*)",
      "Bash(cat:*)",
      "Read",
      "Write",
      "Edit",
      "Glob",
      "Grep"
    ]
  }
}
EOF

    # Empty MCP config
    echo '{}' > "$safe_dir/.mcp.json"
    mkdir -p "$safe_dir/.claude"
    echo '{}' > "$safe_dir/.claude/settings.local.json"

    if [[ "$prepare_only" == "1" ]]; then
        printf "SAFE_CONFIG_DIR=%s\n" "$safe_dir"
        printf "  Safe config prepared at: %s\n" "$safe_dir"
        return 0
    fi

    printf "  Config: %s\n" "$safe_dir"
    printf "  Press Ctrl+C to exit safe mode.\n\n"

    # Find claude binary (bypass mclaude entirely)
    local claude_bin=""
    if [[ -f "$HOME/.cc-mirror/mclaude/npm/node_modules/@anthropic-ai/claude-code/cli.js" ]]; then
        claude_bin="node $HOME/.cc-mirror/mclaude/npm/node_modules/@anthropic-ai/claude-code/cli.js"
    elif command -v claude >/dev/null 2>&1; then
        claude_bin="claude"
    else
        printf "${C_RED}Error: cannot find claude binary${C_RESET}\n" >&2
        rm -rf "$safe_dir"
        return 1
    fi

    # Launch with stripped config
    CLAUDE_CONFIG_DIR="$safe_dir" $claude_bin "$@" || true

    # Cleanup
    rm -rf "$safe_dir"
    printf "\n${C_GREEN}Safe mode exited.${C_RESET} Temp config cleaned up.\n"
}

# ── Usage ───────────────────────────────────────────────────────────────────

usage() {
    cat << 'EOF'
Usage: afleet-recover <command> [options]

Commands:
  doctor              Health check — diagnose issues without fixing
  recover             Auto-diagnose and fix common issues
  rollback [N]        Roll back config repo by N commits + redeploy
  safe-mode           Launch Claude Code with minimal config (no hooks/MCP/plugins)

Rollback options:
  --dry-run           Show what would be rolled back without doing it
  --yes, -y           Skip confirmation prompt

Examples:
  afleet doctor                    # Check everything
  afleet recover                   # Auto-fix what's broken
  afleet rollback --dry-run 3      # Preview rolling back 3 commits
  afleet rollback --yes 1          # Roll back last commit immediately
  afleet safe-mode                 # Launch bare CC for emergency debugging
EOF
}

# ── Main dispatch ───────────────────────────────────────────────────────────

case "${1:-}" in
    doctor)     shift; cmd_doctor "$@" ;;
    recover)    shift; cmd_recover "$@" ;;
    rollback)   shift; cmd_rollback "$@" ;;
    safe-mode|safemode) shift; cmd_safe_mode "$@" ;;
    --help|-h)  usage ;;
    "")         usage ;;
    *)          printf "Unknown command: %s\n\n" "$1" >&2; usage; exit 1 ;;
esac
