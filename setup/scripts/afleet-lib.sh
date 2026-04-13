#!/usr/bin/env bash
# afleet-lib.sh — library functions for the agent fleet launcher
# Pure functions: registry/cache parsing, display list building, rendering.
# Sourced by afleet.sh — not meant to be executed directly.

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
# Returns name|path lines from registry.md. If registry.md is missing:
#   - First run (.setup-pending exists): returns empty (no projects yet)
#   - Otherwise: auto-creates a minimal registry.md with the config project
parse_registry() {
    if [[ ! -f "$REGISTRY" ]]; then
        # First run — no registry expected yet, return empty
        if [[ -f "$CONFIG_REPO/.setup-pending" ]]; then
            return 0
        fi
        # Not first run — auto-create minimal registry with config project
        local config_name
        config_name="$(basename "$CONFIG_REPO")"
        mkdir -p "$(dirname "$REGISTRY")"
        cat > "$REGISTRY" << EOF
# Project Registry

## Projects

| Project | Priority | Parent | Path | GitHub Remote | Machines | Type | Phase | Notes |
|---------|----------|--------|------|--------------|----------|------|-------|-------|
| ${config_name} | P1 | — | \`~/${config_name}\` | | $(hostname 2>/dev/null || echo "unknown") | meta | active | Auto-created by afleet |
EOF
        echo "Note: Created minimal registry.md at $REGISTRY" >&2
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

# ── Render picker (helpers) ──────────────────────────────────────────────────
# Shared state: _RP_labels[], _RP_names[], _RP_types[], _RP_tasks[],
#   _RP_sizes[], _RP_prios[], _RP_is_child[], _RP_parents[], _RP_p1names[],
#   _RP_total, _RP_col_name, _RP_col_type, _RP_col_tasks, _RP_col_size,
#   _RP_inner_width
# These arrays are populated by render_picker() before calling helpers.

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
            local names_str="${p1names//|/; }"
            result="$result — $names_str"
        fi
    fi
    if [[ ${#result} -gt $max_w ]]; then
        result="${result:0:$((max_w - 1))}…"
    fi
    echo "$result"
}

# Printf width adjusted for multibyte chars (├─, └─, —, …)
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
    for ((x=0; x<_RP_inner_width; x++)); do printf '%s' "$char"; done
    printf '%s' "$right"
    printf '%b\n' "$C_RST"
}

# Print tier header: label line + opening hline
# Args: $1=tier, $2=previous_tier (empty if first)
_render_tier_header() {
    local tier="$1" prev_tier="$2"
    if [[ -n "$prev_tier" ]]; then
        _hline "─" "└" "┘"
        echo
    fi
    local tier_color tier_lbl
    tier_color=$(_tier_color "$tier")
    tier_lbl=$(_tier_label "$tier")
    printf '  %b%s%b\n' "$tier_color" "$tier_lbl" "$C_RST"
    _hline "─" "┌" "┐"
}

# Format and print a single row
# Args: $1=index into _RP arrays
_render_row() {
    local idx="$1"
    local label="${_RP_labels[$idx]}"
    local name="${_RP_names[$idx]}"
    local type="${_RP_types[$idx]}"
    local size="${_RP_sizes[$idx]}"
    local child="${_RP_is_child[$idx]}"
    [[ -z "$size" || "$size" == "—" ]] && size="—"
    local tasks_str
    tasks_str=$(_format_tasks "${_RP_tasks[$idx]}" "${_RP_p1names[$idx]}" "$_RP_col_tasks")

    # Truncate type
    if [[ ${#type} -gt $((_RP_col_type - 1)) ]]; then
        type="${type:0:$((_RP_col_type - 2))}…"
    fi

    # Build name display — children get tree prefix
    local name_display="$name"
    local label_color="$C_BWHT"
    if [[ "$child" == "1" ]]; then
        label_color="$C_DIM"
        local tree_char="└─"
        if [[ $((idx + 1)) -lt $_RP_total && "${_RP_is_child[$((idx+1))]}" == "1" && "${_RP_parents[$((idx+1))]}" == "${_RP_parents[$idx]}" ]]; then
            tree_char="├─"
        fi
        name_display="$tree_char $name_display"
    fi
    if [[ ${#name_display} -gt $((_RP_col_name - 1)) ]]; then
        name_display="${name_display:0:$((_RP_col_name - 2))}…"
    fi

    printf '%b│%b  %b%s%b  %-*s  %-*s  %-*s  %*s  %b│%b\n' \
        "$C_DIM" "$C_RST" \
        "$label_color" "$(printf '%2s' "$label")" "$C_RST" \
        "$(_pw "$_RP_col_name" "$name_display")" "$name_display" \
        "$(_pw "$_RP_col_type" "$type")" "$type" \
        "$(_pw "$_RP_col_tasks" "$tasks_str")" "$tasks_str" \
        "$(_pw "$_RP_col_size" "$size")" "$size" \
        "$C_DIM" "$C_RST"
}

# Render footer: close last tier box, P4-P5 hidden count, action bar
# Args: $1=current_tier, $2=p4p5_count
_render_footer() {
    local current_tier="$1" p4p5_count="$2"
    if [[ -n "$current_tier" ]]; then
        _hline "─" "└" "┘"
    fi
    if [[ "$p4p5_count" -eq 0 ]]; then
        local hidden
        hidden=$(parse_dashboard_cache 2>/dev/null | awk -F'|' '$2 ~ /P[45]/' | wc -l)
        if [[ "$hidden" -gt 0 ]]; then
            printf '\n  %b+ %d paused/dormant (afleet --pick --all)%b\n' "$C_DIM" "$hidden" "$C_RST"
        fi
    fi
    printf '\n  %b[#/a]%b select  %b[q]%b quit  %b[Enter]%b cwd project  %b[a]%b show all\n' \
        "$C_BOLD" "$C_RST" "$C_BOLD" "$C_RST" "$C_BOLD" "$C_RST" "$C_BOLD" "$C_RST"
}

# ── Render picker (coordinator) ─────────────────────────────────────────────
# Input: build_display_list output (stdin)
# Output: formatted box-drawing table to stdout
render_picker() {
    local term_width="${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}"
    _RP_labels=(); _RP_names=(); _RP_types=(); _RP_tasks=(); _RP_sizes=()
    _RP_prios=(); _RP_is_child=(); _RP_parents=(); _RP_p1names=()
    local i=0

    while IFS='|' read -r label name type tasks size prio child parent path p1names; do
        [[ -z "$label" ]] && continue
        _RP_labels+=("$label"); _RP_names+=("$name"); _RP_types+=("$type")
        _RP_tasks+=("$tasks"); _RP_sizes+=("$size"); _RP_prios+=("$prio")
        _RP_is_child+=("$child"); _RP_parents+=("$parent"); _RP_p1names+=("$p1names")
        ((i++)) || true
    done
    _RP_total=$i

    # Column widths — fixed + elastic Tasks column
    _RP_col_name=18; _RP_col_type=14; _RP_col_size=6
    _RP_col_tasks=$((term_width - _RP_col_name - _RP_col_type - _RP_col_size - 16))
    [[ $_RP_col_tasks -lt 12 ]] && _RP_col_tasks=12
    [[ $_RP_col_tasks -gt 50 ]] && _RP_col_tasks=50
    _RP_inner_width=$((14 + _RP_col_name + _RP_col_type + _RP_col_tasks + _RP_col_size))

    # Main render loop
    local current_tier="" p4p5_count=0 prev_item_tier=""
    for ((i=0; i<_RP_total; i++)); do
        local tier="${_RP_prios[$i]}" child="${_RP_is_child[$i]}"

        if [[ "$tier" == "P4" || "$tier" == "P5" ]]; then
            ((p4p5_count++)) || true
        fi
        if [[ "$tier" != "$current_tier" ]]; then
            _render_tier_header "$tier" "$current_tier"
            current_tier="$tier"
        fi
        if [[ "$child" == "0" && "$tier" == "$prev_item_tier" ]]; then
            printf '%b│%*s│%b\n' "$C_DIM" "$_RP_inner_width" "" "$C_RST"
        fi

        _render_row "$i"
        prev_item_tier="$tier"
    done

    _render_footer "$current_tier" "$p4p5_count"
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

# ── Telegram-to-inbox (CFG-238) ─────────────────────────────────────────────
# Check AFD for unprocessed Telegram messages and create inbox entries.
# Called pre-launch (0 LLM tokens). Messages with @project-name tags are
# routed to the named project; untagged or unknown tags go to cfg-agent-fleet.
# Testable: uses PATH for afd discovery, CONFIG_REPO for registry/inbox.
telegram_inbox_check() {
    command -v afd >/dev/null 2>&1 || return 0

    local raw_messages
    raw_messages=$(afd messages 2>/dev/null) || return 0
    [[ -z "$raw_messages" ]] && return 0

    # Build project name list from registry (lowercase for matching)
    local -A project_names=()
    while IFS='|' read -r name _path; do
        [[ -z "$name" ]] && continue
        local lower
        lower=$(echo "$name" | tr '[:upper:]' '[:lower:]')
        project_names["$lower"]="$name"
    done < <(parse_registry)

    local inbox_file="$INBOX_FILE"
    local count=0
    local -A routed_projects=()
    local today
    today=$(date +%Y-%m-%d)

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        # Parse JSON — extract message field (lightweight, no jq dependency)
        local msg
        msg=$(echo "$line" | sed -n 's/.*"message":"\([^"]*\)".*/\1/p')
        [[ -z "$msg" ]] && continue

        # Extract @tag (first occurrence)
        local tag="" target="" clean_msg="$msg"
        if [[ "$msg" =~ @([a-zA-Z0-9_-]+) ]]; then
            tag="${BASH_REMATCH[1]}"
            local tag_lower
            tag_lower=$(echo "$tag" | tr '[:upper:]' '[:lower:]')
            if [[ -n "${project_names[$tag_lower]:-}" ]]; then
                target="${project_names[$tag_lower]}"
                # Remove @tag from message for cleaner inbox entry
                clean_msg=$(echo "$msg" | sed "s/@${tag}[[:space:]]*//" | sed 's/^[[:space:]]*//')
            fi
        fi

        # Fallback: no tag or unknown tag → cfg-agent-fleet
        if [[ -z "$target" ]]; then
            target="cfg-agent-fleet"
            clean_msg="$msg"
        fi

        # Append inbox entry
        echo "- [ ] **${target}**: ${clean_msg}. Source: Telegram ${today}." >> "$inbox_file"
        ((count++)) || true
        routed_projects["$target"]=1
    done <<< "$raw_messages"

    if [[ $count -gt 0 ]]; then
        local project_list
        project_list=$(printf '%s\n' "${!routed_projects[@]}" | sort | paste -sd', ')
        printf '  📨 %d Telegram message(s) → inbox (%s)\n' "$count" "$project_list"
    fi
}
