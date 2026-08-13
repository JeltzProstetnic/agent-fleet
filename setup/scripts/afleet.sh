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
    for c in "$HOME/.local/bin/mclaude" "$HOME/.cc-mirror/bin/mclaude.cmd" "$(command -v mclaude 2>/dev/null || true)" "$(command -v claude 2>/dev/null || true)"; do
        [[ -n "$c" && -x "$c" ]] && launcher="$c" && break
    done
    if [[ -z "$launcher" ]]; then
        echo "  FATAL: Neither mclaude nor claude found." >&2; exit 1
    fi
    cd "$HOME" 2>/dev/null || true
    exec "$launcher"
}

# ── Config ───────────────────────────────────────────────────────────────────
# Detect config repo using shared library (skipped if CONFIG_REPO already set)
if [[ -z "${CONFIG_REPO:-}" ]]; then
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

# ── Pre-picker: pull config repo so registry.md is current ──────────────────
# Must happen BEFORE parse_registry / picker — otherwise new projects added on
# other machines won't appear. Timeout prevents network hangs from blocking launch.
_PRE_PICKER_TIMEOUT="${AFLEET_PRE_PICKER_TIMEOUT:-10}"
if [[ -f "$SYNC_SCRIPT" && -d "$CONFIG_REPO/.git" ]]; then
    timeout "$_PRE_PICKER_TIMEOUT" bash "$SYNC_SCRIPT" --pull "$CONFIG_REPO" >/dev/null 2>&1 || true
fi

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

# ── Binary preflight (CFG-370) ──────────────────────────────────────────────
# Checks external binaries afleet depends on. Critical = abort. Optional = degrade.
# Testable via: AFLEET_PREFLIGHT_RESULT (receives "ok" or "missing:<list>")
afleet_check_binaries() {
    local missing_critical=() missing_optional=()
    for bin in git bash; do
        command -v "$bin" &>/dev/null || missing_critical+=("$bin")
    done
    for bin in script timeout node fzf; do
        command -v "$bin" &>/dev/null || missing_optional+=("$bin")
    done
    if (( ${#missing_critical[@]} )); then
        echo "  FATAL: required binaries missing: ${missing_critical[*]}" >&2
        echo "  Install them and retry." >&2
        AFLEET_PREFLIGHT_RESULT="missing:${missing_critical[*]}"
        return 1
    fi
    if (( ${#missing_optional[@]} )); then
        echo "  ⚠ Optional binaries missing: ${missing_optional[*]} (degraded mode)" >&2
        AFLEET_PREFLIGHT_RESULT="missing:${missing_optional[*]}"
        return 0
    fi
    AFLEET_PREFLIGHT_RESULT="ok"
    return 0
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

# ── Worktree helper: create an isolated git worktree for follower mode ─────
# Updates global TARGET_DIR to the new worktree path so launch_mclaude cd's there.
# Also sets AFLEET_WORKTREE_MODE=1 + AFLEET_WORKTREE_MAIN + AFLEET_WORKTREE_BRANCH
# so post_session_cleanup can prompt to merge/clean up on exit.
_create_worktree_and_retarget() {
    local main_dir="$1"
    local ts branch wt_root wt_path
    ts=$(date +%Y%m%d-%H%M%S)
    branch="afleet-wt-$ts"
    wt_root="$HOME/.afleet-worktrees"
    wt_path="$wt_root/${TARGET_NAME}-${ts}"

    if [[ ! -d "$main_dir/.git" && ! -f "$main_dir/.git" ]]; then
        echo "  ✖ Project is not a git repo — cannot create worktree." >&2
        return 1
    fi

    mkdir -p "$wt_root" 2>/dev/null || {
        echo "  ✖ Cannot create worktree root $wt_root" >&2
        return 1
    }

    local _err
    if ! _err=$(git -C "$main_dir" worktree add -b "$branch" "$wt_path" HEAD 2>&1); then
        echo "  ✖ git worktree add failed:" >&2
        echo "    $_err" >&2
        return 1
    fi

    TARGET_DIR="$wt_path"
    AFLEET_WORKTREE_MAIN="$main_dir"
    AFLEET_WORKTREE_BRANCH="$branch"
    export AFLEET_WORKTREE_MODE=1 AFLEET_WORKTREE_MAIN AFLEET_WORKTREE_BRANCH
    echo "  → Worktree created: $wt_path" >&2
    echo "    Branch: $branch" >&2
    echo "    Main session's lock is untouched." >&2
}

# ── Session lock acquisition (CFG-101) ──────────────────────────────────────
# Local lock (same-machine protection) + optional server lock (cross-machine).
# Server lock is best-effort — fails silently if AFD unreachable or no token.
#
# On conflict, offers two choices only:
#   w = create a git worktree and work there in follower mode
#   q = quit without launching (default)
# No steal/force-release option — that's only possible via direct mclaude/cc
# invocation (documented escape hatch). See follower-mode.md.
afleet_acquire_session_lock() {
    local project_dir="$1"
    local project_name="$2"
    local lock_lib="$CONFIG_REPO/setup/scripts/session-lock.sh"
    local afd_lib="$CONFIG_REPO/afd/lib/afd-lib.sh"

    [[ -f "$lock_lib" ]] || return 0  # No lock library — skip

    source "$lock_lib" 2>/dev/null || { echo "  Warning: session-lock.sh failed to load" >&2; return 0; }
    local session_id
    session_id=$(_generate_session_id)

    # Acquire local lock. Pass afleet's own (non-CC) PID as the exclude so the
    # CFG-468 live-CC scan RUNS at pre-launch (non-empty exclude) and catches an
    # incumbent session whose lock decayed to a dead ephemeral pid — afleet is not
    # a CC process, so excluding it is harmless.
    if ! acquire_lock "$project_dir" "$session_id" "" "$$"; then
        echo "" >&2
        echo "  ⚠ Project locked by another session on this machine." >&2
        lock_info "$project_dir" >&2
        echo "" >&2
        echo "  [w] Open in isolated git worktree (follower mode)" >&2
        echo "  [q] Quit (default)" >&2
        printf '  Choice: '
        local _ans=""
        read -r _ans || _ans=""
        case "$_ans" in
            w|W)
                _create_worktree_and_retarget "$project_dir" || return 1
                return 0   # worktree is its own workspace — skip lock acquisition
                ;;
            *)
                echo "  → Session not started." >&2
                return 1
                ;;
        esac
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

# ── resolve_project — Arg parsing + project resolution ──────────────────────
# Sets globals: CWD_OVERRIDE, SHOW_PICKER, PROJECT_ARG, MODE, PICKER_ALL,
#               TARGET_DIR, TARGET_NAME
# May exit for --help, --list, recovery subcommands, or errors.
resolve_project() {
    CWD_OVERRIDE=""
    SHOW_PICKER=false
    PROJECT_ARG=""
    MODE="launch"
    PICKER_ALL=0
    MODEL_ARG=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                echo "Usage: afleet [<project>] [--list|-l] [--pick|-p] [--cwd <dir>]"
                echo ""
                echo "  afleet              Auto-detect project from CWD, or show project picker"
                echo "  afleet <project>    Open specific project by name or prefix (from registry.md)"
                echo "  afleet <proj> <model>  Run against a LOCAL model via LM Studio (e.g. af cfg gemma4)"
                echo "  afleet --model <alias> Same, explicit form. Aliases: setup/config/local-models.conf"
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
            --model) [[ $# -ge 2 ]] || { echo "Error: --model requires an argument" >&2; exit 1; }; MODEL_ARG="$2"; shift 2 ;;
            -*) echo "Unknown option: $1" >&2; exit 1 ;;
            # First bare positional = project, second = local-model alias (CFG-506).
            # `af cfg-agent-fleet gemma4`. A lone token that is not a project but IS a known
            # alias is treated as the model, with the project resolved from cwd/picker.
            *)  if [[ -z "$PROJECT_ARG" ]]; then PROJECT_ARG="$1"; else MODEL_ARG="$1"; fi; shift ;;
        esac
    done

    # Lone-token disambiguation: `af gemma4` with no project.
    if [[ -n "$PROJECT_ARG" && -z "$MODEL_ARG" ]] && ! parse_registry 2>/dev/null | cut -d'|' -f1 | grep -qx "$PROJECT_ARG"; then
        if [[ -f "$CONFIG_REPO/setup/config/local-models.conf" ]] \
           && grep -vE '^\s*(#|$)' "$CONFIG_REPO/setup/config/local-models.conf" \
              | awk -F'|' '{gsub(/ /,"",$1); print $1}' | grep -qx "$PROJECT_ARG"; then
            MODEL_ARG="$PROJECT_ARG"; PROJECT_ARG=""
        fi
    fi

    # ── List mode ────────────────────────────────────────────────────────────
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

    # ── Binary preflight ─────────────────────────────────────────────────────
    afleet_check_binaries || _fallback_launch "missing critical binaries"

    # ── Project resolution ───────────────────────────────────────────────────
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

    # ── Interactive picker ───────────────────────────────────────────────────
    if $SHOW_PICKER; then
        PICKER_SHOW_ALL="$PICKER_ALL" run_picker || true
    fi
}

# ── pre_launch_sync — SteamOS preflight, git sync, Telegram, session lock ───
# Reads globals: TARGET_DIR, TARGET_NAME, CONFIG_REPO, SYNC_SCRIPT
pre_launch_sync() {
    # ── SteamOS pre-flight ───────────────────────────────────────────────────
    steamos_preflight || echo "  Warning: SteamOS preflight had issues — continuing" >&2

    # ── Git sync ─────────────────────────────────────────────────────────────
    start_spinner "Syncing repos…"

    # Config repo already pulled pre-picker — only pull target if it's a different repo.
    if [[ "$TARGET_DIR" != "$CONFIG_REPO" && -f "$SYNC_SCRIPT" && -d "$TARGET_DIR/.git" ]]; then
        bash "$SYNC_SCRIPT" --pull "$TARGET_DIR" >/dev/null 2>&1 || true
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

    # ── Telegram-to-inbox (CFG-238) ──────────────────────────────────────────
    # Check AFD for unprocessed Telegram messages from between sessions.
    # Creates inbox entries routed by @project-name tags. 0 LLM tokens.
    type telegram_inbox_check &>/dev/null && { telegram_inbox_check || true; }

    # ── Acquire session lock (CFG-101) ───────────────────────────────────────
    # Non-zero return = user chose quit OR worktree creation failed.
    # Either way we do NOT launch CC. This is deliberate — the old
    # "launching anyway" fallthrough was a bug that ignored the user's choice.
    afleet_acquire_session_lock "$TARGET_DIR" "$TARGET_NAME" || exit 0
}

# ── launch_mclaude — mclaude detection, TweakCC, banner, exec ───────────────
# Reads globals: DRY_RUN, TARGET_DIR, TARGET_NAME
# Sets globals: MCLAUDE_EXIT
launch_mclaude() {
    if [[ "$DRY_RUN" == "1" ]]; then
        echo "DRY_RUN: would cd to $TARGET_DIR and exec mclaude"
        exit 0
    fi

    cd "$TARGET_DIR" 2>/dev/null || { echo "  Warning: cannot cd to $TARGET_DIR — using HOME" >&2; cd "$HOME"; }

    MCLAUDE=""
    for candidate in "$HOME/.local/bin/mclaude" "$HOME/.cc-mirror/bin/mclaude.cmd" "$(command -v mclaude 2>/dev/null || true)"; do
        [[ -x "$candidate" ]] && MCLAUDE="$candidate" && break
    done

    if [[ -z "$MCLAUDE" ]]; then
        echo "Error: mclaude not found. Install via cc-mirror." >&2
        exit 1
    fi

    # ── Local model launcher (CFG-506) ───────────────────────────────────────
    # `mclaude` HARDCODES `export CLAUDE_CONFIG_DIR=…/config` on line 3 and is regenerated
    # by `cc-mirror update`, so patching it is not an option. Local mode therefore execs the
    # CC entrypoint directly via a generated shim, which also keeps every downstream
    # invocation below ($MCLAUDE under script(1)) unchanged.
    if [[ -n "${AFLEET_LOCAL_MODEL:-}" ]]; then
        local _cc_entry="" _c
        for _c in "${CC_MIRROR_DIR:-$HOME/.cc-mirror/mclaude}/npm/node_modules/@anthropic-ai/claude-code/bin/claude" \
                  "${CC_MIRROR_DIR:-$HOME/.cc-mirror/mclaude}/npm/node_modules/@anthropic-ai/claude-code/bin/claude.exe" \
                  "$(command -v claude 2>/dev/null || true)"; do
            [[ -n "$_c" && -x "$_c" ]] && _cc_entry="$_c" && break
        done
        if [[ -z "$_cc_entry" ]]; then
            echo "  Error: Claude Code entrypoint not found for local mode." >&2; exit 1
        fi
        # Refresh the lean profile from the repo at launch — idempotent, always current, and
        # avoids pointing CLAUDE_CONFIG_DIR at the git repo itself (CC writes session state
        # into that dir and would pollute the working tree).
        local _lean="${CC_MIRROR_DIR:-$HOME/.cc-mirror/mclaude}/config-local"
        local _leansrc="$CONFIG_REPO/setup/config-local"
        [[ -d "$_leansrc" ]] || { echo "  Error: lean profile source missing: $_leansrc" >&2; exit 1; }
        mkdir -p "$_lean" || { echo "  Error: cannot create $_lean" >&2; exit 1; }
        cp -f "$_leansrc/CLAUDE.md" "$_leansrc/settings.json" "$_leansrc/.mcp.json" "$_lean/" 2>/dev/null \
            || { echo "  Error: could not refresh lean profile into $_lean" >&2; exit 1; }
        local _shim; _shim=$(mktemp "${TMPDIR:-/tmp}/afleet-local-XXXXXX.sh")
        cat > "$_shim" <<SHIM
#!/usr/bin/env bash
export CLAUDE_CONFIG_DIR="$_lean"
export ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL:-}"
export ANTHROPIC_AUTH_TOKEN="${ANTHROPIC_AUTH_TOKEN:-}"
export CLAUDE_CODE_ATTRIBUTION_HEADER=0
export AFLEET_LOCAL_MODEL="${AFLEET_LOCAL_MODEL:-}"
exec "$_cc_entry" --model "${AFLEET_LOCAL_MODEL:-}" "\$@"
SHIM
        chmod +x "$_shim"
        MCLAUDE="$_shim"
        AFLEET_LOCAL_SHIM="$_shim"
    fi

    # ── TweakCC config repair ────────────────────────────────────────────────
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

    # ── Banner: AF fleet banner with CC version ──────────────────────────────
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
        # A local session must be unmistakable — never let it be confused with a cloud one.
        if [[ -n "${AFLEET_LOCAL_MODEL:-}" ]]; then
            printf '              \033[38;5;208mLOCAL %s\033[0m \033[38;5;240m· %s · lean profile\033[0m\n' \
                   "$AFLEET_LOCAL_MODEL" "${AFLEET_LOCAL_MODEL_KEY:-?}"
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

    # ── Session terminal log ─────────────────────────────────────────────────
    # WT historySize caps at 32767 (SHORT_MAX). script(1) captures full terminal
    # output to a file. Last 3 logs per project, stored next to session-context.md.
    __afleet_logdir="$TARGET_DIR/docs/terminal-logs"
    mkdir -p "$__afleet_logdir" 2>/dev/null || true
    # Rotate: keep last 3
    ls -t "$__afleet_logdir"/session-*.log 2>/dev/null | tail -n +4 | xargs rm -f 2>/dev/null || true
    __afleet_logfile="$__afleet_logdir/session-$(date +%Y%m%d-%H%M%S).log"
    export MCLAUDE_SESSION_LOG="$__afleet_logfile"
    export AFLEET_LAUNCHED=1 AFLEET_PROJECT="$TARGET_NAME" CC_MIRROR_SPLASH=0

    # Terminal logging via script(1). GNU (util-linux) and BSD (macOS) have
    # incompatible flag sets: GNU uses -f -e -c CMD FILE, BSD uses FILE CMD ARGS.
    # Detect flavor, branch, or fall back to no-logging if script(1) is absent
    # (Fedora 42 splits it into util-linux-script).
    if command -v script &>/dev/null; then
        if script --version 2>/dev/null | grep -q util-linux; then
            # GNU util-linux: -q quiet, -f flush, -e exit-code, -c CMD FILE
            if [[ -n "$INITIAL_PROMPT" ]]; then
                script -q -f -e -c "$MCLAUDE '${INITIAL_PROMPT//\'/\'\\\'\'}'" "$__afleet_logfile"
            else
                script -q -f -e -c "$MCLAUDE" "$__afleet_logfile"
            fi
            MCLAUDE_EXIT=$?
        else
            # BSD (macOS): script [-q] FILE COMMAND [ARGS...]
            # Does not propagate child exit code — capture via sidecar.
            local _exit_sidecar="$__afleet_logdir/.exit-code"
            if [[ -n "$INITIAL_PROMPT" ]]; then
                script -q "$__afleet_logfile" bash -c "$MCLAUDE '$INITIAL_PROMPT'; echo \$? > '$_exit_sidecar'"
            else
                script -q "$__afleet_logfile" bash -c "$MCLAUDE; echo \$? > '$_exit_sidecar'"
            fi
            MCLAUDE_EXIT=$(cat "$_exit_sidecar" 2>/dev/null || echo 1)
            rm -f "$_exit_sidecar"
        fi
    else
        echo "  ⚠ script(1) not found — terminal logging disabled (install util-linux-script)" >&2
        if [[ -n "$INITIAL_PROMPT" ]]; then
            "$MCLAUDE" "$INITIAL_PROMPT"
        else
            "$MCLAUDE"
        fi
        MCLAUDE_EXIT=$?
    fi

    # Remove the generated local-model shim (contains no secrets, but leave no litter).
    [[ -n "${AFLEET_LOCAL_SHIM:-}" ]] && rm -f "$AFLEET_LOCAL_SHIM"

    # Clear pre-launch banner from primary buffer so it doesn't linger after CC exits.
    # ONLY on clean exit — non-zero exit leaves error messages visible (CFG-370 lesson).
    [[ -t 1 && ${MCLAUDE_EXIT:-1} -eq 0 ]] && printf '\033[2J\033[H'
}

# ── post_session_cleanup — Worktree merge, drive reminder, exit ────────────
# Reads globals: MCLAUDE_EXIT, TARGET_DIR, AFLEET_WORKTREE_MODE,
#                AFLEET_WORKTREE_MAIN, AFLEET_WORKTREE_BRANCH
post_session_cleanup() {
    # ── Worktree cleanup ─────────────────────────────────────────────────────
    # If this session ran in an afleet-managed worktree, either auto-remove
    # (empty) or prompt to merge (has commits/changes).
    if [[ "${AFLEET_WORKTREE_MODE:-0}" == "1" && -n "${AFLEET_WORKTREE_MAIN:-}" \
          && -n "${AFLEET_WORKTREE_BRANCH:-}" && -d "$TARGET_DIR" ]]; then
        local main="$AFLEET_WORKTREE_MAIN"
        local branch="$AFLEET_WORKTREE_BRANCH"
        local main_head wt_head dirty ahead
        main_head=$(git -C "$main" rev-parse HEAD 2>/dev/null || echo "")
        wt_head=$(git -C "$TARGET_DIR" rev-parse HEAD 2>/dev/null || echo "")
        dirty=$(git -C "$TARGET_DIR" status --porcelain 2>/dev/null || echo "")
        ahead=0
        if [[ -n "$main_head" && -n "$wt_head" && "$main_head" != "$wt_head" ]]; then
            ahead=$(git -C "$TARGET_DIR" rev-list --count "$main_head..$wt_head" 2>/dev/null || echo 0)
        fi

        if [[ "$ahead" -eq 0 && -z "$dirty" ]]; then
            # Empty worktree — auto-remove silently
            git -C "$main" worktree remove --force "$TARGET_DIR" >/dev/null 2>&1 || true
            git -C "$main" branch -D "$branch" >/dev/null 2>&1 || true
            echo "  → Worktree cleaned up (no changes)." >&2
        else
            echo "" >&2
            echo "  Worktree has changes:" >&2
            [[ "$ahead" -gt 0 ]] && echo "    $ahead commit(s) ahead of main session's HEAD" >&2
            [[ -n "$dirty" ]]   && echo "    uncommitted file changes present" >&2
            echo "    Path:   $TARGET_DIR" >&2
            echo "    Branch: $branch" >&2
            printf '  Fast-forward merge into main session and delete worktree? [y/N] ' >&2
            local _ans=""
            # afleet runs under `script -c`, which consumes stdin, so the real
            # prompt must read the terminal directly. AFLEET_PROMPT_INPUT is the
            # test seam (CFG-474): without it the tests could only ever exercise
            # the no-controlling-terminal fallback, so the suite passed in CI and
            # hung forever for the human it was meant to gate.
            read -r _ans <"${AFLEET_PROMPT_INPUT:-/dev/tty}" 2>/dev/null || read -r _ans || _ans=""
            if [[ "$_ans" =~ ^[yY] ]]; then
                if [[ -n "$dirty" ]]; then
                    echo "  ✖ Uncommitted changes in worktree — commit or discard before merging." >&2
                    echo "  → Worktree preserved at $TARGET_DIR" >&2
                elif git -C "$main" merge --ff-only "$branch" >/dev/null 2>&1; then
                    git -C "$main" worktree remove --force "$TARGET_DIR" >/dev/null 2>&1 || true
                    git -C "$main" branch -D "$branch" >/dev/null 2>&1 || true
                    echo "  → Merged fast-forward and cleaned up." >&2
                else
                    echo "  ✖ Fast-forward merge failed (main branch diverged)." >&2
                    echo "  → Worktree preserved. Resolve manually:" >&2
                    echo "    git -C $main merge $branch" >&2
                fi
            else
                echo "  → Worktree preserved at $TARGET_DIR" >&2
                echo "    Clean up later: git -C $main worktree remove $TARGET_DIR" >&2
            fi
        fi
    fi

    # ── Drive unmount reminder (WSL only) ────────────────────────────────────
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
}

# ── Source guard ─────────────────────────────────────────────────────────────
# When sourced for testing, only define functions — don't execute main logic
if [[ "${AFLEET_SOURCE_ONLY:-0}" == "1" ]]; then
    return 0 2>/dev/null || exit 0
fi

# ── Main execution ──────────────────────────────────────────────────────────
resolve_project "$@"
pre_launch_sync

# ── Local model mode (CFG-506) ──────────────────────────────────────────────
# A failure here ABORTS. Never fall back to the cloud model: silently spending Opus
# tokens when the user explicitly asked for a local model is the exact surprise this
# feature exists to prevent.
if [[ -n "${MODEL_ARG:-}" ]]; then
    if [[ -f "$_AFLEET_DIR/afleet-local-model.sh" ]] && bash -n "$_AFLEET_DIR/afleet-local-model.sh" 2>/dev/null; then
        # shellcheck disable=SC1090
        source "$_AFLEET_DIR/afleet-local-model.sh"
        alm_prepare "$MODEL_ARG" || { echo "  Local model setup failed — aborting (no cloud fallback)." >&2; exit 1; }
    else
        echo "  afleet-local-model.sh missing or broken — cannot run local model mode." >&2; exit 1
    fi
fi

launch_mclaude
post_session_cleanup
