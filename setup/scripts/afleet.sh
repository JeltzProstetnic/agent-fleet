#!/usr/bin/env bash
# afleet — unified agent fleet launcher
# Wraps mclaude with project detection, pre-launch sync, and interactive project picker.
# Usage: afleet [<project>] [--list|-l] [--pick|-p] [--cwd <dir>] [--help|-h]
set -euo pipefail

# ── Config ───────────────────────────────────────────────────────────────────
CONFIG_REPO="${CONFIG_REPO:-}"
if [[ -z "$CONFIG_REPO" ]]; then
    for d in "$HOME/agent-fleet"; do
        [[ -f "$d/sync.sh" ]] && CONFIG_REPO="$d" && break
    done
fi
if [[ -z "$CONFIG_REPO" ]]; then
    echo "Error: config repo not found (tried ~/agent-fleet)" >&2
    exit 1
fi

REGISTRY="$CONFIG_REPO/registry.md"
DASHBOARD_CACHE="$CONFIG_REPO/cross-project/dashboard-cache.md"
SYNC_SCRIPT="$CONFIG_REPO/setup/scripts/git-sync-check.sh"
DRY_RUN="${AFLEET_DRY_RUN:-0}"

# ── ANSI Colors ─────────────────────────────────────────────────────────────
if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
    C_RED='\033[0;31m'
    C_BRED='\033[1;31m'
    C_YEL='\033[0;33m'
    C_BYEL='\033[1;33m'
    C_CYN='\033[0;36m'
    C_BCYN='\033[1;36m'
    C_DIM='\033[2m'
    C_BOLD='\033[1m'
    C_BWHT='\033[1;37m'
    C_INV='\033[7m'
    C_RST='\033[0m'
else
    C_RED='' C_BRED='' C_YEL='' C_BYEL='' C_CYN='' C_BCYN=''
    C_DIM='' C_BOLD='' C_BWHT='' C_INV='' C_RST=''
fi

# ── Spinner utility ─────────────────────────────────────────────────────────
# Usage: start_spinner "message"; ... do work ...; stop_spinner
# Spinner PID stored in _SPINNER_PID. Safe to call stop_spinner if none running.
_SPINNER_PID=""
start_spinner() {
    local msg="${1:-Working…}"
    [[ -t 1 ]] || return 0
    (
        trap 'printf "\r\033[K"; exit 0' TERM HUP INT
        _frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
        _i=0
        while true; do
            printf '\r\033[38;5;220m    %s\033[38;5;243m %s\033[0m' "${_frames[$_i]}" "$msg"
            _i=$(( (_i + 1) % 10 ))
            sleep 0.08
        done
    ) &
    _SPINNER_PID=$!
}
stop_spinner() {
    if [[ -n "${_SPINNER_PID:-}" ]]; then
        kill "$_SPINNER_PID" 2>/dev/null
        wait "$_SPINNER_PID" 2>/dev/null || true
        _SPINNER_PID=""
        printf '\r\033[K'
    fi
}

# ── Registry parsing ─────────────────────────────────────────────────────────
parse_registry() {
    if [[ ! -f "$REGISTRY" ]]; then
        echo "Error: registry.md not found at $REGISTRY" >&2
        return 1
    fi
    awk -F'|' '
        /^\|/ {
            prio = $3
            gsub(/^[ \t]+|[ \t]+$/, "", prio)
            if (prio ~ /^P[1-5]$/) {
                name = $2; path = $5
                gsub(/^[ \t]+|[ \t]+$/, "", name)
                gsub(/^[ \t]+|[ \t]+$/, "", path)
                gsub(/`/, "", path)
                gsub(/~/, ENVIRON["HOME"], path)
                if (name != "" && path != "") print name "|" path
            }
        }
    ' "$REGISTRY"
}

# ── Dashboard cache parsing ──────────────────────────────────────────────────
# Output: name|priority|parent|path|type|tasks|size|p1names|lastdone
parse_dashboard_cache() {
    if [[ ! -f "$DASHBOARD_CACHE" ]]; then
        echo "Error: dashboard-cache.md not found at $DASHBOARD_CACHE" >&2
        return 1
    fi
    awk -F'|' '
        /^\|/ {
            prio = $3
            gsub(/^[ \t]+|[ \t]+$/, "", prio)
            if (prio ~ /^P[1-5]$/) {
                name = $2; parent = $4; path = $5; type = $6
                tasks = $7; size = $8; p1names = $10; lastdone = $11
                gsub(/^[ \t]+|[ \t]+$/, "", name)
                gsub(/^[ \t]+|[ \t]+$/, "", parent)
                gsub(/^[ \t]+|[ \t]+$/, "", path)
                gsub(/^[ \t]+|[ \t]+$/, "", type)
                gsub(/^[ \t]+|[ \t]+$/, "", tasks)
                gsub(/^[ \t]+|[ \t]+$/, "", size)
                gsub(/^[ \t]+|[ \t]+$/, "", p1names)
                gsub(/^[ \t]+|[ \t]+$/, "", lastdone)
                gsub(/`/, "", path)
                gsub(/~/, ENVIRON["HOME"], path)
                if (name != "") print name "|" prio "|" parent "|" path "|" type "|" tasks "|" size "|" p1names "|" lastdone
            }
        }
    ' "$DASHBOARD_CACHE"
}

# ── Build display list ───────────────────────────────────────────────────────
# Input: parse_dashboard_cache output (stdin)
# Output: label|name|type|tasks|size|priority|is_child|parent|path|p1names
# Algorithm:
#   - Parents at their own priority get numbers (1, 2, 3...)
#   - Children whose priority >= parent priority stay nested, get letters (a, b, c...)
#   - Children whose priority < parent priority get promoted with own number + parent suffix
#   - P4-P5 excluded unless PICKER_SHOW_ALL=1
build_display_list() {
    local show_all="${PICKER_SHOW_ALL:-0}"
    local -a names=() prios=() parents=() paths=() types=() tasks_arr=() sizes=() p1names_arr=()
    local i=0

    # Read all projects
    while IFS='|' read -r name prio parent path type tasks size p1names lastdone; do
        [[ -z "$name" ]] && continue
        names+=("$name")
        prios+=("$prio")
        parents+=("$parent")
        paths+=("$path")
        types+=("$type")
        tasks_arr+=("$tasks")
        sizes+=("$size")
        p1names_arr+=("$p1names")
        ((i++)) || true
    done

    local total=$i
    local num=1
    local letter_idx=0
    local letters="abcdefghijklmnopqrstuvwxyz"
    local -a processed=()

    # Process tiers P1-P5
    for tier in P1 P2 P3 P4 P5; do
        [[ "$show_all" != "1" && ("$tier" == "P4" || "$tier" == "P5") ]] && continue

        local tier_has_items=false

        for ((i=0; i<total; i++)); do
            [[ -n "${processed[$i]:-}" ]] && continue
            local name="${names[$i]}"
            local prio="${prios[$i]}"
            local parent="${parents[$i]}"

            # Is this a parent-level project at this tier?
            if [[ "$prio" == "$tier" && ("$parent" == "—" || "$parent" == "-") ]]; then
                tier_has_items=true
                processed[$i]=1
                echo "${num}|${name}|${types[$i]}|${tasks_arr[$i]}|${sizes[$i]}|${prio}|0|—|${paths[$i]}|${p1names_arr[$i]}"
                ((num++)) || true

                # Find children of this parent that stay nested (child prio >= parent prio number)
                local parent_prio_num="${prio#P}"
                for ((j=0; j<total; j++)); do
                    [[ -n "${processed[$j]:-}" ]] && continue
                    [[ "${parents[$j]}" != "$name" ]] && continue
                    local child_prio_num="${prios[$j]#P}"
                    if [[ "$child_prio_num" -ge "$parent_prio_num" ]]; then
                        [[ "$show_all" != "1" && "$child_prio_num" -ge 4 ]] && continue
                        processed[$j]=1
                        local letter="${letters:$letter_idx:1}"
                        ((letter_idx++)) || true
                        # Use parent's priority for display tier grouping
                        echo "${letter}|${names[$j]}|${types[$j]}|${tasks_arr[$j]}|${sizes[$j]}|${prio}|1|${name}|${paths[$j]}|${p1names_arr[$j]}"
                    fi
                done
            fi
        done

        # Promoted children: child priority is at this tier but parent is at a lower-priority tier
        for ((i=0; i<total; i++)); do
            [[ -n "${processed[$i]:-}" ]] && continue
            local name="${names[$i]}"
            local prio="${prios[$i]}"
            local parent="${parents[$i]}"
            [[ "$prio" != "$tier" ]] && continue
            [[ "$parent" == "—" || "$parent" == "-" ]] && continue

            # Find parent's priority
            local parent_prio=""
            for ((k=0; k<total; k++)); do
                [[ "${names[$k]}" == "$parent" ]] && parent_prio="${prios[$k]}" && break
            done
            [[ -z "$parent_prio" ]] && continue

            local parent_prio_num="${parent_prio#P}"
            local child_prio_num="${prio#P}"

            if [[ "$child_prio_num" -lt "$parent_prio_num" ]]; then
                tier_has_items=true
                processed[$i]=1
                # Promoted child — gets a number, type shows "(parent)"
                echo "${num}|${name}|${types[$i]} (${parent})|${tasks_arr[$i]}|${sizes[$i]}|${prio}|0|${parent}|${paths[$i]}|${p1names_arr[$i]}"
                ((num++)) || true
            fi
        done
    done
}

# ── Render picker ────────────────────────────────────────────────────────────
# Input: build_display_list output (stdin)
# Output: formatted box-drawing table to stdout
render_picker() {
    local term_width="${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}"
    local -a labels=() names=() types=() tasks_arr=() sizes=() prios=() is_child=() parents_arr=() p1names_arr=()
    local i=0

    while IFS='|' read -r label name type tasks size prio child parent path p1names; do
        [[ -z "$label" ]] && continue
        labels+=("$label")
        names+=("$name")
        types+=("$type")
        tasks_arr+=("$tasks")
        sizes+=("$size")
        prios+=("$prio")
        is_child+=("$child")
        parents_arr+=("$parent")
        p1names_arr+=("$p1names")
        ((i++)) || true
    done
    local total=$i

    # Column widths — fixed + elastic Tasks column
    # Row format: │  LL  NAME..  TYPE..  TASKS..  SIZE  │
    # Fixed spacing: 2+2+2 (label zone) + 4×2 (inter-column) + 2 (trailing) = 14 chars
    # Plus 2 for the │ border chars = 16 total overhead
    local col_name=18
    local col_type=14
    local col_size=6
    local col_tasks=$((term_width - col_name - col_type - col_size - 16))
    [[ $col_tasks -lt 12 ]] && col_tasks=12
    [[ $col_tasks -gt 50 ]] && col_tasks=50

    local inner_width=$((14 + col_name + col_type + col_tasks + col_size))

    # Tier colors
    _tier_color() {
        case "$1" in
            P1) printf '%b' "$C_BRED" ;;
            P2) printf '%b' "$C_BYEL" ;;
            P3) printf '%b' "$C_BCYN" ;;
            *) printf '%b' "$C_DIM" ;;
        esac
    }
    _tier_label() {
        case "$1" in
            P1) echo "P1 CRITICAL" ;;
            P2) echo "P2 ACTIVE" ;;
            P3) echo "P3 ONGOING" ;;
            P4) echo "P4 PAUSED" ;;
            P5) echo "P5 DORMANT" ;;
        esac
    }

    # Build tasks display string
    _format_tasks() {
        local tasks="$1" p1names="$2" max_w="$3"
        local result=""
        if [[ "$tasks" == "—" || -z "$tasks" ]]; then
            result="—"
        else
            result="$tasks"
            if [[ -n "$p1names" ]]; then
                # Convert pipe-separated to semicolon-separated
                local names_str="${p1names//|/; }"
                result="$result — $names_str"
            fi
        fi
        # Truncate
        if [[ ${#result} -gt $max_w ]]; then
            result="${result:0:$((max_w - 1))}…"
        fi
        echo "$result"
    }

    # Printf width adjusted for multibyte chars (├─, └─, —, …)
    # printf %-*s uses byte width, not display width — this compensates
    _pw() {
        local target=$1 text="$2"
        local bytes chars
        bytes=$(printf '%s' "$text" | wc -c)
        chars=${#text}
        echo $((target + bytes - chars))
    }

    # Draw horizontal line
    _hline() {
        local char="$1" left="$2" right="$3"
        printf '%b' "$C_DIM"
        printf '%s' "$left"
        for ((x=0; x<inner_width; x++)); do printf '%s' "$char"; done
        printf '%s' "$right"
        printf '%b\n' "$C_RST"
    }

    # Render by tier
    local current_tier=""
    local p4p5_count=0
    local prev_item_tier=""

    for ((i=0; i<total; i++)); do
        local tier="${prios[$i]}"
        local child="${is_child[$i]}"

        # Count P4-P5 for footer
        if [[ "$tier" == "P4" || "$tier" == "P5" ]]; then
            ((p4p5_count++)) || true
        fi

        # New tier?
        if [[ "$tier" != "$current_tier" ]]; then
            # Close previous tier
            if [[ -n "$current_tier" ]]; then
                _hline "─" "└" "┘"
                echo
            fi

            current_tier="$tier"
            local tier_color
            tier_color=$(_tier_color "$tier")
            local tier_label
            tier_label=$(_tier_label "$tier")

            # Tier header
            printf '  %b%s%b\n' "$tier_color" "$tier_label" "$C_RST"
            _hline "─" "┌" "┐"
        fi

        # Blank line between groups (except first item in tier)
        if [[ "$child" == "0" && "$tier" == "$prev_item_tier" ]]; then
            printf '%b│%*s│%b\n' "$C_DIM" "$inner_width" "" "$C_RST"
        fi

        # Format fields
        local label="${labels[$i]}"
        local name="${names[$i]}"
        local type="${types[$i]}"
        local size="${sizes[$i]}"
        [[ -z "$size" || "$size" == "—" ]] && size="—"
        local tasks_str
        tasks_str=$(_format_tasks "${tasks_arr[$i]}" "${p1names_arr[$i]}" "$col_tasks")

        # Truncate type
        if [[ ${#type} -gt $((col_type - 1)) ]]; then
            type="${type:0:$((col_type - 2))}…"
        fi
        # Build name display — children get tree prefix in the name column
        local name_display="$name"
        local label_color="$C_BWHT"
        if [[ "$child" == "1" ]]; then
            label_color="$C_DIM"
            local tree_char="└─"
            if [[ $((i + 1)) -lt $total && "${is_child[$((i+1))]}" == "1" && "${parents_arr[$((i+1))]}" == "${parents_arr[$i]}" ]]; then
                tree_char="├─"
            fi
            name_display="$tree_char $name_display"
        fi
        # Truncate name
        if [[ ${#name_display} -gt $((col_name - 1)) ]]; then
            name_display="${name_display:0:$((col_name - 2))}…"
        fi

        # Unified row format — same printf for parent and child
        # _pw compensates for multibyte chars (├─ └─ — …) in printf width
        printf '%b│%b  %b%s%b  %-*s  %-*s  %-*s  %*s  %b│%b\n' \
            "$C_DIM" "$C_RST" \
            "$label_color" "$(printf '%2s' "$label")" "$C_RST" \
            "$(_pw "$col_name" "$name_display")" "$name_display" \
            "$(_pw "$col_type" "$type")" "$type" \
            "$(_pw "$col_tasks" "$tasks_str")" "$tasks_str" \
            "$(_pw "$col_size" "$size")" "$size" \
            "$C_DIM" "$C_RST"
        prev_item_tier="$tier"
    done

    # Close last tier
    if [[ -n "$current_tier" ]]; then
        _hline "─" "└" "┘"
    fi

    # P4-P5 footer (when hidden)
    if [[ "$p4p5_count" -eq 0 ]]; then
        # Count hidden P4-P5 from full cache
        local hidden
        hidden=$(parse_dashboard_cache 2>/dev/null | awk -F'|' '$2 ~ /P[45]/' | wc -l)
        if [[ "$hidden" -gt 0 ]]; then
            printf '\n  %b+ %d paused/dormant (afleet --pick --all)%b\n' "$C_DIM" "$hidden" "$C_RST"
        fi
    fi

    # Action bar
    printf '\n  %b[#/a]%b select  %b[q]%b quit  %b[Enter]%b cwd project  %b[a]%b show all\n' \
        "$C_BOLD" "$C_RST" "$C_BOLD" "$C_RST" "$C_BOLD" "$C_RST" "$C_BOLD" "$C_RST"
}

# ── Resolve selection ────────────────────────────────────────────────────────
# Input: build_display_list output (stdin), selection string as $1
# Output: name|path of selected project, or empty
resolve_selection() {
    local sel="$1"
    while IFS='|' read -r label name type tasks size prio child parent path p1names; do
        [[ -z "$label" ]] && continue
        if [[ "$label" == "$sel" ]]; then
            echo "${name}|${path}"
            return 0
        fi
    done
    return 1
}

# ── Interactive picker ───────────────────────────────────────────────────────
run_picker() {
    local show_all=0

    while true; do
        local cache_data
        cache_data=$(parse_dashboard_cache) || return 1

        local display_list
        display_list=$(echo "$cache_data" | PICKER_SHOW_ALL="$show_all" build_display_list)

        # Clear screen and render
        printf '\033[2J\033[H'
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
            echo "  afleet <project>    Open specific project by name (from registry.md)"
            echo "  afleet --list       Show available projects (non-interactive)"
            echo "  afleet --pick       Show interactive project picker"
            echo "  afleet --dash       Alias for --pick (backwards compat)"
            echo "  afleet --cwd <dir>  Override working directory for project detection"
            echo "  afleet --all        Include P4-P5 projects in picker"
            exit 0 ;;
        --list|-l) MODE="list"; shift ;;
        --pick|-p|--dash|-d) SHOW_PICKER=true; shift ;;
        --all) PICKER_ALL=1; shift ;;
        --cwd) CWD_OVERRIDE="$2"; shift 2 ;;
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
HAS_REGISTRY=false
[[ -f "$REGISTRY" ]] && HAS_REGISTRY=true

if [[ -n "$PROJECT_ARG" ]]; then
    if $HAS_REGISTRY; then
        MATCH=$(parse_registry | grep -i "^${PROJECT_ARG}|" | head -1 || true)
    else
        MATCH=""
    fi
    if [[ -z "$MATCH" ]]; then
        echo "Error: project '$PROJECT_ARG' not found" >&2
        exit 1
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
        if [[ -f "$CHECK_DIR/CLAUDE.md" ]]; then
            TARGET_DIR="$CHECK_DIR"
            TARGET_NAME="$BASENAME"
            break
        fi
        if $HAS_REGISTRY; then
            MATCH=$(parse_registry | grep -i "^${BASENAME}|" | head -1 || true)
            if [[ -n "$MATCH" ]]; then
                TARGET_NAME="${MATCH%%|*}"
                TARGET_DIR="${MATCH#*|}"
                break
            fi
        fi
        CHECK_DIR="$(dirname "$CHECK_DIR")"
    done

    # Fallback — use base project directly (no picker on fresh installs)
    if [[ -z "$TARGET_DIR" ]]; then
        if [[ -d "$HOME/agent-fleet" ]]; then
            TARGET_DIR="$HOME/agent-fleet"
            TARGET_NAME="agent-fleet"
        else
            echo "Error: no project detected and no base project found" >&2
            exit 1
        fi
    fi
fi

# ── Interactive picker (only with registry + dashboard cache) ────────────────
if $SHOW_PICKER && $HAS_REGISTRY && [[ -f "$DASHBOARD_CACHE" ]]; then
    PICKER_SHOW_ALL="$PICKER_ALL" run_picker || true
fi

# ── Pre-launch: SteamOS pre-flight ───────────────────────────────────────────
steamos_preflight

# ── Pre-launch: git sync ────────────────────────────────────────────────────
start_spinner "Syncing repos…"

if [[ -f "$SYNC_SCRIPT" && -d "$TARGET_DIR/.git" ]]; then
    bash "$SYNC_SCRIPT" --pull "$TARGET_DIR" >/dev/null 2>&1 || true
fi

if [[ "$TARGET_DIR" != "$CONFIG_REPO" && -f "$SYNC_SCRIPT" && -d "$CONFIG_REPO/.git" ]]; then
    bash "$SYNC_SCRIPT" --pull "$CONFIG_REPO" >/dev/null 2>&1 || true
fi

# Pre-pull all other local repos (CFG-129) — prevents stale cross-project state.
AFLEET_SKIP_REPOS="$TARGET_DIR|$CONFIG_REPO" pre_pull_all_repos

stop_spinner

# ── Launch ───────────────────────────────────────────────────────────────────

if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY_RUN: would cd to $TARGET_DIR and exec mclaude"
    exit 0
fi

cd "$TARGET_DIR"

MCLAUDE=""
for candidate in "$HOME/.local/bin/mclaude" "$(command -v mclaude 2>/dev/null || true)"; do
    [[ -x "$candidate" ]] && MCLAUDE="$candidate" && break
done

if [[ -z "$MCLAUDE" ]]; then
    echo "Error: mclaude not found. Install via cc-mirror." >&2
    exit 1
fi

# ── Banner: AF fleet banner with CC version ──────────────────────────────────
# Replaces both mclaude splash and CC built-in banner with a single clean banner.
# CC_MIRROR_SPLASH=0 suppresses mclaude's splash; TweakCC hideStartupBanner
# suppresses CC's built-in banner (requires cc-mirror tweak to be applied).
if [[ -t 1 ]]; then
    __cc_ver=""
    __cc_pkg="$HOME/.cc-mirror/mclaude/npm/node_modules/@anthropic-ai/claude-code/package.json"
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

    # ── Startup spinner ──────────────────────────────────────────────────────
    # Node.js + CC init takes several seconds — show a Braille spinner in
    # AF-yellow so the TUI doesn't look hung.
    start_spinner "Starting session…"
fi

AFLEET_LAUNCHED=1 AFLEET_PROJECT="$TARGET_NAME" CC_MIRROR_SPLASH=0 "$MCLAUDE"
MCLAUDE_EXIT=$?

# Kill startup spinner (if still alive — CC's TUI hides it, but the process lingers)
stop_spinner

exit "${MCLAUDE_EXIT:-0}"
