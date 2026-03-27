#!/usr/bin/env bash
# afleet — unified agent fleet launcher
# Wraps mclaude with project detection, pre-launch sync, and interactive project picker.
# Usage: afleet [<project>] [--list|-l] [--pick|-p] [--cwd <dir>] [--help|-h]
set -uo pipefail  # NO set -e — launcher must NEVER crash. Every section handles its own errors.

# ── Fallback launch ──────────────────────────────────────────────────────────
# If anything critical fails, launch Claude Code directly (degraded but alive).
_fallback_launch() {
    echo "" >&2
    echo "  !! AFLEET DEGRADED LAUNCH — $1" >&2
    echo "  Launching Claude Code directly (no sync, no project detection)." >&2
    echo "" >&2
    local launcher=""
    for c in "$HOME/.local/bin/mclaude" "$(command -v mclaude 2>/dev/null || true)" "$(command -v claude 2>/dev/null || true)"; do
        [[ -n "$c" && -x "$c" ]] && launcher="$c" && break
    done
    if [[ -z "$launcher" ]]; then
        echo "  FATAL: Neither mclaude nor claude found." >&2; exit 1
    fi
    cd "$HOME" 2>/dev/null || true
    exec "$launcher"
}

# ── Config ───────────────────────────────────────────────────────────────────
# Detect config repo using shared library
_LIB_DETECT=""
for _p in "$HOME/.claude/hooks/lib-detect-repo.sh" "$(dirname "${BASH_SOURCE[0]}")/../../global/hooks/lib-detect-repo.sh"; do
    [[ -f "$_p" ]] && _LIB_DETECT="$_p" && break
done
if [[ -n "$_LIB_DETECT" ]]; then
    source "$_LIB_DETECT"
    # PERSONAL_CONFIG_REPO: the user's personal config repo (cfg-agent-fleet), not the template
    CONFIG_REPO="$(_detect_config_repo)"
else
    # Fallback: inline detection if shared lib not found
    CONFIG_REPO=""
    for d in "$HOME/cfg-agent-fleet" "$HOME/agent-fleet"; do
        [[ -f "$d/sync.sh" ]] && CONFIG_REPO="$d" && break
    done
fi
if [[ -z "$CONFIG_REPO" ]]; then
    echo "ERROR: Cannot find config repo (cfg-agent-fleet or agent-fleet)" >&2
    exit 1
fi

REGISTRY="$CONFIG_REPO/registry.md"
DASHBOARD_CACHE="$CONFIG_REPO/cross-project/dashboard-cache.md"
INBOX_FILE="$CONFIG_REPO/cross-project/inbox.md"
SYNC_SCRIPT="$CONFIG_REPO/setup/scripts/git-sync-check.sh"
DRY_RUN="${AFLEET_DRY_RUN:-0}"

# ── Portable readlink -f (needed before any library is sourced) ───────────────
_readlink_f() { readlink -f "$1" 2>/dev/null && return; local t="$1"; [ "${t#/}" = "$t" ] && t="$PWD/$t"; while [ -L "$t" ]; do local l; l=$(readlink "$t") || break; [ "${l#/}" = "$l" ] && l="$(dirname "$t")/$l"; t="$l"; done; local d; d=$(cd "$(dirname "$t")" 2>/dev/null && pwd -P) || return 1; echo "$d/$(basename "$t")"; }

# ── Source library (symlink-safe, with fallback) ─────────────────────────────
_AFLEET_DIR="$(dirname "$(_readlink_f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")"
if [[ -f "$_AFLEET_DIR/afleet-lib.sh" ]] && bash -n "$_AFLEET_DIR/afleet-lib.sh" 2>/dev/null; then
    source "$_AFLEET_DIR/afleet-lib.sh" || _fallback_launch "afleet-lib.sh sourcing failed"
else
    _fallback_launch "afleet-lib.sh missing or has syntax errors"
fi

# ── Interactive picker ───────────────────────────────────────────────────────
run_picker() {
    local show_all=0

    while true; do
        local cache_data
        cache_data=$(parse_dashboard_cache) || return 1

        local display_list
        display_list=$(echo "$cache_data" | PICKER_SHOW_ALL="$show_all" build_display_list)

        # Clear visible screen for picker redraw (preserve scrollback)
        printf '\033[2J\033[H'
        if [[ -t 1 ]]; then
            printf '\033[38;5;220m    ▄▀█ █▀▀\033[0m   \033[38;5;245mAgent Fleet\033[0m\n'
            printf '\033[38;5;220m    █▀█ █▀\033[0m    \033[38;5;240m━━━━━━━━━━━━\033[0m\n'
            printf '\n'
        fi
        echo "$display_list" | render_picker
        printf '\n  ▸ '

        local sel
        read -r sel

        # Handle special inputs
        [[ "$sel" == "q" || "$sel" == "Q" ]] && exit 0
        [[ "$sel" == "a" || "$sel" == "A" ]] && { show_all=1; continue; }

        # Empty input — use CWD project
        if [[ -z "$sel" ]]; then
            return 0
        fi

        # Resolve selection
        local result
        result=$(echo "$display_list" | resolve_selection "$sel") || {
            printf '  %bInvalid selection: %s%b\n' "$C_RED" "$sel" "$C_RST"
            sleep 1
            continue
        }

        TARGET_NAME="${result%%|*}"
        TARGET_DIR="${result#*|}"
        return 0
    done
}

# ── SteamOS pre-flight ───────────────────────────────────────────────────────
# Detects SteamOS version change (after OS update) and auto-runs reprovision
# if system packages were wiped. Called before git sync and launch.
# Testable via overrides: STEAMOS_OS_RELEASE, STEAMOS_MARKER_FILE,
#   STEAMOS_CHECK_CMD (tool to verify; default: jq), STEAMOS_REPROVISION_SCRIPT
steamos_preflight() {
    local os_release="${STEAMOS_OS_RELEASE:-/etc/os-release}"
    [[ -f "$os_release" ]] && grep -qi steam "$os_release" 2>/dev/null || return 0

    local current_ver
    current_ver=$(grep "^VERSION_ID=" "$os_release" 2>/dev/null | cut -d= -f2)
    [[ -z "$current_ver" ]] && return 0

    local marker_file="${STEAMOS_MARKER_FILE:-$HOME/.steamos-provisioned-version}"
    local last_ver=""
    [[ -f "$marker_file" ]] && last_ver=$(cat "$marker_file" 2>/dev/null)

    # Already provisioned for this version
    [[ "$current_ver" == "$last_ver" ]] && return 0

    echo -e "${C_YEL}SteamOS version changed: ${last_ver:-<none>} -> ${current_ver}${C_RST}"

    local check_cmd="${STEAMOS_CHECK_CMD:-jq}"
    if ! command -v "$check_cmd" &>/dev/null; then
        echo -e "${C_BRED}System packages wiped ($check_cmd missing). Running reprovision...${C_RST}"
        local reprov="${STEAMOS_REPROVISION_SCRIPT:-$CONFIG_REPO/setup/reprovision-steamos.sh}"
        if [[ -f "$reprov" ]]; then
            bash "$reprov"
            if [[ $? -eq 0 ]]; then
                echo "$current_ver" > "$marker_file"
                echo -e "${C_CYN}Reprovision complete. Version marker updated.${C_RST}"
            else
                echo -e "${C_RED}Reprovision had errors. Will retry next launch.${C_RST}" >&2
                return 1
            fi
        else
            echo -e "${C_RED}Reprovision script not found: $reprov${C_RST}" >&2
            return 1
        fi
    else
        echo -e "${C_CYN}Packages intact. Updating version marker.${C_RST}"
        echo "$current_ver" > "$marker_file"
    fi
}

# ── Pre-pull all local repos (CFG-129) ───────────────────────────────────────
# Pulls all project repos listed in registry.md that exist locally.
# Prevents stale cross-project state (e.g., tmp/ false alarms from already-moved files).
# Non-fatal: failures are logged but don't block launch.
# Testable via: AFLEET_SYNC_LOG, AFLEET_SKIP_REPOS (pipe-separated paths), AFLEET_PULL_TIMEOUT
pre_pull_all_repos() {
    local timeout="${AFLEET_PULL_TIMEOUT:-10}"
    local skip_repos="${AFLEET_SKIP_REPOS:-}"
    local sync_log="${AFLEET_SYNC_LOG:-}"

    [[ -f "$SYNC_SCRIPT" ]] || return 0

    while IFS='|' read -r name path; do
        [[ -z "$path" ]] && continue
        [[ ! -d "$path/.git" ]] && continue

        # Skip repos already pulled by main launch
        if [[ -n "$skip_repos" ]]; then
            local skip=false
            IFS='|' read -ra skip_arr <<< "$skip_repos"
            for sp in "${skip_arr[@]}"; do
                [[ "$path" == "$sp" ]] && skip=true && break
            done
            $skip && continue
        fi

        if [[ -n "$sync_log" ]]; then
            echo "SYNC_CALLED path=$path" >> "$sync_log"
        fi

        timeout "$timeout" bash "$SYNC_SCRIPT" --pull "$path" >/dev/null 2>&1 || true
    done < <(parse_registry)
}

# ── Source guard ─────────────────────────────────────────────────────────────
# When sourced for testing, only define functions — don't execute main logic
if [[ "${AFLEET_SOURCE_ONLY:-0}" == "1" ]]; then
    return 0 2>/dev/null || exit 0
fi

# ── Main logic ───────────────────────────────────────────────────────────────
CWD_OVERRIDE=""
SHOW_PICKER=false
PROJECT_ARG=""
MODE="launch"
PICKER_ALL=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            echo "Usage: afleet [<project>] [--list|-l] [--pick|-p] [--cwd <dir>]"
            echo ""
            echo "  afleet              Auto-detect project from CWD, or show project picker"
            echo "  afleet <project>    Open specific project by name or prefix (from registry.md)"
            echo "  afleet --list       Show available projects (non-interactive)"
            echo "  afleet --pick       Show interactive project picker"
            echo "  afleet --dash       Alias for --pick (backwards compat)"
            echo "  afleet --cwd <dir>  Override working directory for project detection"
            echo "  afleet --all        Include P4-P5 projects in picker"
            echo ""
            echo "Recovery:"
            echo "  afleet doctor       Health check — diagnose issues"
            echo "  afleet recover      Auto-diagnose and fix common issues"
            echo "  afleet rollback N   Roll back config repo by N commits + redeploy"
            echo "  afleet safe-mode    Launch Claude Code with minimal config"
            exit 0 ;;
        --list|-l) MODE="list"; shift ;;
        --pick|-p|--dash|-d) SHOW_PICKER=true; shift ;;
        --all) PICKER_ALL=1; shift ;;
        --cwd) [[ $# -ge 2 ]] || { echo "Error: --cwd requires an argument" >&2; exit 1; }; CWD_OVERRIDE="$2"; shift 2 ;;
        # Recovery subcommands — delegate to afleet-recover.sh
        doctor|recover|rollback|safe-mode|safemode)
            if [[ -f "$_AFLEET_DIR/afleet-recover.sh" ]]; then
                exec bash "$_AFLEET_DIR/afleet-recover.sh" "$@"
            else
                echo "Recovery module not yet installed." >&2; exit 1
            fi ;;
        -*) echo "Unknown option: $1" >&2; exit 1 ;;
        *)  PROJECT_ARG="$1"; shift ;;
    esac
done

# ── List mode ────────────────────────────────────────────────────────────────
if [[ "$MODE" == "list" ]]; then
    printf "%-25s %s\n" "Project" "Path"
    printf "%-25s %s\n" "-------" "----"
    parse_registry | while IFS='|' read -r name path; do
        local_exists=""
        [[ -d "$path" ]] && local_exists="*" || local_exists=" "
        printf "%-25s %s %s\n" "$name" "$path" "$local_exists"
    done
    exit 0
fi

# ── Project resolution ───────────────────────────────────────────────────────
TARGET_DIR=""
TARGET_NAME=""

if [[ -n "$PROJECT_ARG" ]]; then
    # Try exact match first (case-insensitive)
    MATCH=$(parse_registry | grep -i "^${PROJECT_ARG}|" | head -1 || true)
    if [[ -z "$MATCH" ]]; then
        # Fall back to prefix match
        PREFIX_MATCHES=$(parse_registry | grep -i "^${PROJECT_ARG}" || true)
        MATCH_COUNT=$(echo "$PREFIX_MATCHES" | grep -c '.' || true)
        if [[ "$MATCH_COUNT" -eq 1 ]]; then
            MATCH="$PREFIX_MATCHES"
        elif [[ "$MATCH_COUNT" -gt 1 ]]; then
            echo "Error: prefix '$PROJECT_ARG' matches multiple projects:" >&2
            echo "$PREFIX_MATCHES" | while IFS='|' read -r name _path; do
                echo "  - $name" >&2
            done
            exit 1
        else
            echo "Error: project '$PROJECT_ARG' not found in registry.md" >&2
            echo "Run 'afleet --list' to see available projects." >&2
            exit 1
        fi
    fi
    TARGET_NAME="${MATCH%%|*}"
    TARGET_DIR="${MATCH#*|}"
    if [[ ! -d "$TARGET_DIR" ]]; then
        echo "Error: project '$TARGET_NAME' directory does not exist: $TARGET_DIR" >&2
        exit 1
    fi
else
    DETECT_DIR="${CWD_OVERRIDE:-$(pwd)}"
    [[ "$DETECT_DIR" == /mnt/* ]] && DETECT_DIR=""

    CHECK_DIR="${DETECT_DIR:-/}"
    while [[ "$CHECK_DIR" != "/" ]]; do
        BASENAME="$(basename "$CHECK_DIR")"
        if [[ -d "$CHECK_DIR/.claude" && -f "$CHECK_DIR/CLAUDE.md" ]]; then
            TARGET_DIR="$CHECK_DIR"
            TARGET_NAME="$BASENAME"
            break
        fi
        MATCH=$(parse_registry | grep -i "^${BASENAME}|" | head -1 || true)
        if [[ -n "$MATCH" ]]; then
            TARGET_NAME="${MATCH%%|*}"
            TARGET_DIR="${MATCH#*|}"
            break
        fi
        CHECK_DIR="$(dirname "$CHECK_DIR")"
    done

    # Fallback — show picker or auto-launch on first-run
    if [[ -z "$TARGET_DIR" ]]; then
        if [[ -d "$HOME/cfg-agent-fleet" ]]; then
            TARGET_DIR="$HOME/cfg-agent-fleet"
            TARGET_NAME="cfg-agent-fleet"
        elif [[ -d "$HOME/agent-fleet" ]]; then
            TARGET_DIR="$HOME/agent-fleet"
            TARGET_NAME="agent-fleet"
        else
            echo "Error: no project detected and no base project found" >&2
            exit 1
        fi
        # First-run: skip picker, go straight to config project
        if [[ -f "$TARGET_DIR/.setup-pending" ]]; then
            SHOW_PICKER=false
        else
            SHOW_PICKER=true
        fi
    fi
fi

# ── Interactive picker ───────────────────────────────────────────────────────
if $SHOW_PICKER; then
    PICKER_SHOW_ALL="$PICKER_ALL" run_picker || true
fi

# ── Pre-launch: SteamOS pre-flight ───────────────────────────────────────────
steamos_preflight || echo "  Warning: SteamOS preflight had issues — continuing" >&2

# ── Pre-launch: git sync ────────────────────────────────────────────────────
start_spinner "Syncing repos…"

if [[ -f "$SYNC_SCRIPT" && -d "$TARGET_DIR/.git" ]]; then
    bash "$SYNC_SCRIPT" --pull "$TARGET_DIR" >/dev/null 2>&1 || true
fi

if [[ "$TARGET_DIR" != "$CONFIG_REPO" && -f "$SYNC_SCRIPT" && -d "$CONFIG_REPO/.git" ]]; then
    bash "$SYNC_SCRIPT" --pull "$CONFIG_REPO" >/dev/null 2>&1 || true
fi

# Pre-pull all other local repos (CFG-129) — prevents stale cross-project state.
AFLEET_SKIP_REPOS="$TARGET_DIR|$CONFIG_REPO" pre_pull_all_repos || true

# Full deploy: hooks, settings, project rules, rosters, statusline, etc.
# Replaces the old hook-only repair — sync.sh deploy is idempotent and
# ensures settings.json env vars (CONFIG_REPO), hooks, and all config
# are current after git pull. Suppressed output — errors still surface.
if [[ -f "$CONFIG_REPO/sync.sh" ]]; then
    bash "$CONFIG_REPO/sync.sh" deploy >/dev/null 2>&1 || true
fi

stop_spinner

# ── Pre-launch: Telegram-to-inbox (CFG-238) ─────────────────────────────────
# Check AFD for unprocessed Telegram messages from between sessions.
# Creates inbox entries routed by @project-name tags. 0 LLM tokens.
type telegram_inbox_check &>/dev/null && { telegram_inbox_check || true; }

# ── Pre-launch: acquire session lock (CFG-101) ──────────────────────────────
# Local lock (same-machine protection) + optional server lock (cross-machine).
# Server lock is best-effort — fails silently if AFD unreachable or no token.
afleet_acquire_session_lock() {
    local project_dir="$1"
    local project_name="$2"
    local lock_lib="$CONFIG_REPO/setup/scripts/session-lock.sh"
    local afd_lib="$CONFIG_REPO/afd/lib/afd-lib.sh"

    [[ -f "$lock_lib" ]] || return 0  # No lock library — skip

    source "$lock_lib" 2>/dev/null || { echo "  Warning: session-lock.sh failed to load" >&2; return 0; }
    local session_id
    session_id=$(_generate_session_id)

    # Acquire local lock
    if ! acquire_lock "$project_dir" "$session_id"; then
        echo "  ⚠ Project locked by another session on this machine." >&2
        lock_info "$project_dir" >&2
        printf '  Continue anyway? (y/N) '
        read -r _ans
        [[ "$_ans" =~ ^[yY] ]] || return 1
        force_release "$project_dir"
        acquire_lock "$project_dir" "$session_id" || return 1
    fi

    # Export session ID for hooks (statusline heartbeat, SessionEnd release)
    export AFLEET_SESSION_ID="$session_id"

    # Try server lock — 409 = both-stop (CFG-101b)
    if [[ -f "$afd_lib" && -n "${AFD_TOKEN:-}" ]]; then
        source "$afd_lib" 2>/dev/null || { echo "  Warning: afd-lib.sh failed to load" >&2; return 0; }
        local _lock_rc=0
        afd_lock_acquire "$project_name" "$(hostname)" "$session_id" "$$" 2>/tmp/.afleet-lock-msg || _lock_rc=$?
        if [[ "$_lock_rc" -eq 2 ]]; then
            echo "" >&2
            echo "  ✖ $(cat /tmp/.afleet-lock-msg 2>/dev/null)" >&2
            echo "  Both sessions should stop to avoid conflicts." >&2
            echo "  Use 'afd lock release $project_name' to force-clear if the other session is dead." >&2
            rm -f /tmp/.afleet-lock-msg
            return 1
        elif [[ "$_lock_rc" -ne 0 ]]; then
            echo "  ⚠ Server lock unavailable ($(cat /tmp/.afleet-lock-msg 2>/dev/null))" >&2
        fi
        rm -f /tmp/.afleet-lock-msg
    fi

    return 0
}

afleet_acquire_session_lock "$TARGET_DIR" "$TARGET_NAME" || {
    echo "  Warning: session lock failed — launching anyway" >&2
}

# ── Launch ───────────────────────────────────────────────────────────────────

if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY_RUN: would cd to $TARGET_DIR and exec mclaude"
    exit 0
fi

cd "$TARGET_DIR" 2>/dev/null || { echo "  Warning: cannot cd to $TARGET_DIR — using HOME" >&2; cd "$HOME"; }

MCLAUDE=""
for candidate in "$HOME/.local/bin/mclaude" "$(command -v mclaude 2>/dev/null || true)"; do
    [[ -x "$candidate" ]] && MCLAUDE="$candidate" && break
done

if [[ -z "$MCLAUDE" ]]; then
    echo "Error: mclaude not found. Install via cc-mirror." >&2
    exit 1
fi

# ── TweakCC config repair ────────────────────────────────────────────────────
# CC updates reset tweakcc config.json to defaults. Re-apply our settings
# so the CC built-in logo stays hidden and the AF banner is the only splash.
# Runs every launch — idempotent, costs nothing if already correct.
__tweakcc_cfg="${CC_MIRROR_DIR:-$HOME/.cc-mirror/mclaude}/tweakcc/config.json"
if [[ -f "$__tweakcc_cfg" ]] && command -v node >/dev/null 2>&1; then
    node -e "
const fs = require('fs');
const f = '$__tweakcc_cfg';
const c = JSON.parse(fs.readFileSync(f, 'utf8'));
let changed = false;
if (c.settings?.misc?.hideStartupBanner !== true) { c.settings.misc.hideStartupBanner = true; changed = true; }
if (c.settings?.misc?.hideStartupClawd !== true) { c.settings.misc.hideStartupClawd = true; changed = true; }
if (changed) { fs.writeFileSync(f, JSON.stringify(c, null, 2) + '\n'); }
" 2>/dev/null || true
fi

# ── Banner: AF fleet banner with CC version ──────────────────────────────────
# Replaces both mclaude splash and CC built-in banner with a single clean banner.
# CC_MIRROR_SPLASH=0 suppresses mclaude's splash; TweakCC hideStartupBanner
# suppresses CC's built-in banner (requires cc-mirror tweak to be applied).
# Clear screen first for clean transition from picker.
if [[ -t 1 ]]; then
    printf '\033[2J\033[H'
    __cc_ver=""
    __cc_pkg="${CC_MIRROR_DIR:-$HOME/.cc-mirror/mclaude}/npm/node_modules/@anthropic-ai/claude-code/package.json"
    if [[ -f "$__cc_pkg" ]]; then
        __cc_ver=$(node -e "process.stdout.write(require('$__cc_pkg').version)" 2>/dev/null || true)
    fi
    printf '\n'
    printf '\033[38;5;220m    ▄▀█ █▀▀\033[0m   \033[38;5;245m%s\033[0m\n' "$TARGET_NAME"
    printf '\033[38;5;220m    █▀█ █▀\033[0m    \033[38;5;240m━━━━━━━━━━━━\033[0m\n'
    if [[ -n "$__cc_ver" ]]; then
        printf '              \033[38;5;243mClaude Code v%s\033[0m\n' "$__cc_ver"
    fi
    printf '\n'

fi

# First-run: write DON'T PANIC ASCII art to temp file, pass via --prompt-file or quoted arg
INITIAL_PROMPT=""
if [[ -f "$TARGET_DIR/.setup-pending" ]]; then
    INITIAL_PROMPT=$(cat << 'DONTPANIC'

 ██████╗   ██████╗  ███╗   ██╗ ████████╗
 ██╔══██╗ ██╔═══██╗ ████╗  ██║ ╚══██╔══╝
 ██║  ██║ ██║   ██║ ██╔██╗ ██║    ██║
 ██║  ██║ ██║   ██║ ██║╚██╗██║    ██║
 ██████╔╝ ╚██████╔╝ ██║ ╚████║    ██║
 ╚═════╝   ╚═════╝  ╚═╝  ╚═══╝    ╚═╝

 ██████╗  █████╗  ███╗   ██╗ ██╗  ██████╗
 ██╔══██╗██╔══██╗ ████╗  ██║ ██║ ██╔════╝
 ██████╔╝███████║ ██╔██╗ ██║ ██║ ██║
 ██╔═══╝ ██╔══██║ ██║╚██╗██║ ██║ ██║
 ██║     ██║  ██║ ██║ ╚████║ ██║ ╚██████╗
 ╚═╝     ╚═╝  ╚═╝ ╚═╝  ╚═══╝ ╚═╝  ╚═════╝

 Starting Agent Fleet.
DONTPANIC
)
fi

if [[ -n "$INITIAL_PROMPT" ]]; then
    AFLEET_LAUNCHED=1 AFLEET_PROJECT="$TARGET_NAME" CC_MIRROR_SPLASH=0 "$MCLAUDE" "$INITIAL_PROMPT"
else
    AFLEET_LAUNCHED=1 AFLEET_PROJECT="$TARGET_NAME" CC_MIRROR_SPLASH=0 "$MCLAUDE"
fi
MCLAUDE_EXIT=$?

# Clear pre-launch banner from primary buffer so it doesn't linger after CC exits
[[ -t 1 ]] && printf '\033[2J\033[H'


# ── Post-session: drive unmount reminder (WSL only) ─────────────────────────
# Claude Code can't unmount (no sudo), so remind the user to do it manually.
_mounted_drives=""
for mp in /mnt/d /mnt/wsl/data8tb; do
    mountpoint -q "$mp" 2>/dev/null && _mounted_drives="${_mounted_drives:+$_mounted_drives, }$mp"
done
if [[ -n "$_mounted_drives" ]]; then
    printf '\n%b  ⚠ External drives still mounted: %s%b\n' "$C_BYEL" "$_mounted_drives" "$C_RST"
    printf '%b  Eject from Windows: T7 Shield via tray icon, 8TB via "Safely Remove Hardware"%b\n\n' "$C_DIM" "$C_RST"
fi

exit $MCLAUDE_EXIT
