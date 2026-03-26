#!/usr/bin/env bash
# afleet-nav — cross-project navigation helper
# Opens projects in new terminal tabs, sends cross-project notifications,
# and shows project info from the registry.
#
# Usage: afleet-nav.sh <action> <project-name> [--config-repo <path>]
#
# Actions:
#   switch <project>           Open project in new tab, close current session
#   tab <project>              Open project in new tab (keep current session)
#   notify <project> <msg>     Append task to cross-project inbox
#   info <project>             Show project info from registry
set -euo pipefail

# ── Config ───────────────────────────────────────────────────────────────────
CONFIG_REPO=""
ACTION=""
PROJECT=""
MESSAGE=""
DRY_RUN="${AFLEET_NAV_DRY_RUN:-0}"
PROC_VERSION="${AFLEET_NAV_PROC_VERSION:-/proc/version}"
HAS_QDBUS="${AFLEET_NAV_HAS_QDBUS:-}"

# ── Parse args ───────────────────────────────────────────────────────────────
show_usage() {
    cat << 'EOF'
Usage: afleet-nav.sh <action> <project-name> [options]

Actions:
  switch <project>             Open project in a new terminal tab, close current session
  tab <project>                Open project in a new terminal tab (keep current)
  notify <project> <message>   Append a task to the cross-project inbox
  info <project>               Show project info from registry

Options:
  --config-repo <path>   Path to config repo (default: auto-detect)
  --help, -h             Show this help

Platform dispatch for tab/switch (detected automatically):
  WSL       → Windows Terminal (wt.exe)
  KDE       → Konsole (qdbus)
  tmux      → tmux new-window
  fallback  → print manual instructions
EOF
}

# Need at least one argument
if [[ $# -eq 0 ]]; then
    echo "Error: missing action argument." >&2
    echo "" >&2
    show_usage >&2
    exit 1
fi

# Parse positional and option arguments
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            show_usage
            exit 0 ;;
        --config-repo)
            CONFIG_REPO="$2"; shift 2 ;;
        -*)
            echo "Unknown option: $1" >&2; exit 1 ;;
        *)
            POSITIONAL+=("$1"); shift ;;
    esac
done

# Extract action and project from positional args
ACTION="${POSITIONAL[0]:-}"
PROJECT="${POSITIONAL[1]:-}"

# Validate action
case "$ACTION" in
    switch|tab|notify|info) ;;
    *)
        echo "Error: Unknown action '$ACTION'" >&2
        echo "" >&2
        show_usage >&2
        exit 1 ;;
esac

# Project is required for all actions
if [[ -z "$PROJECT" ]]; then
    echo "Error: missing project argument." >&2
    echo "" >&2
    show_usage >&2
    exit 1
fi

# Notify needs a message (positional args 3+)
if [[ "$ACTION" == "notify" ]]; then
    if [[ ${#POSITIONAL[@]} -lt 3 ]]; then
        echo "Error: notify requires a message argument." >&2
        echo "Usage: afleet-nav.sh notify <project> <message>" >&2
        exit 1
    fi
    # Join all remaining positional args as the message
    MESSAGE="${POSITIONAL[*]:2}"
fi

# ── Config repo detection ─────────────────────────────────────────────────────
if [[ -z "$CONFIG_REPO" ]]; then
    for d in "$HOME/cfg-agent-fleet" "$HOME/agent-fleet"; do
        [[ -f "$d/registry.md" ]] && CONFIG_REPO="$d" && break
    done
fi
if [[ -z "$CONFIG_REPO" ]]; then
    echo "Error: config repo not found (tried ~/cfg-agent-fleet, ~/agent-fleet)" >&2
    exit 1
fi

REGISTRY="$CONFIG_REPO/registry.md"

# ── Registry parsing ─────────────────────────────────────────────────────────
# Parse the Projects table from registry.md
# Output: name|priority|parent|path|machines  (one per line)
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
                name = $2; parent = $4; path = $5; machines = $7
                gsub(/^[ \t]+|[ \t]+$/, "", name)
                gsub(/^[ \t]+|[ \t]+$/, "", parent)
                gsub(/^[ \t]+|[ \t]+$/, "", path)
                gsub(/^[ \t]+|[ \t]+$/, "", machines)
                gsub(/`/, "", path)
                gsub(/~/, ENVIRON["HOME"], path)
                if (name != "" && path != "") print name "|" prio "|" parent "|" path "|" machines
            }
        }
    ' "$REGISTRY"
}

# Lookup a single project by name (case-insensitive)
lookup_project() {
    local name="$1"
    parse_registry | grep -i "^${name}|" | head -1 || true
}

# ── Platform detection ────────────────────────────────────────────────────────
# Returns: wsl, kde, tmux, or fallback
detect_platform() {
    # 1. WSL check
    if [[ -f "$PROC_VERSION" ]] && grep -qi microsoft "$PROC_VERSION" 2>/dev/null; then
        echo "wsl"
        return
    fi

    # 2. KDE Konsole check
    local check_qdbus="$HAS_QDBUS"
    if [[ -z "$check_qdbus" ]]; then
        command -v qdbus >/dev/null 2>&1 && check_qdbus=1 || check_qdbus=0
    fi
    if [[ "$check_qdbus" == "1" ]]; then
        echo "kde"
        return
    fi

    # 3. tmux check
    if [[ -n "${TMUX:-}" ]]; then
        echo "tmux"
        return
    fi

    # 4. Fallback
    echo "fallback"
}

# ── Open tab/switch ───────────────────────────────────────────────────────────
open_project_tab() {
    local project_name="$1"
    local project_path="$2"
    local platform
    platform=$(detect_platform)

    case "$platform" in
        wsl)
            local cmd="wt.exe -w 0 nt wsl.exe --cd $project_path -- bash -l -c \"afleet $project_name\""
            if [[ "$DRY_RUN" == "1" ]]; then
                echo "DRY_RUN: $cmd"
            else
                eval "$cmd"
            fi
            ;;
        kde)
            local cmd="qdbus \$(qdbus | grep konsole | head -1) /Windows org.kde.konsole.Window.newSession"
            if [[ "$DRY_RUN" == "1" ]]; then
                echo "DRY_RUN: $cmd (then cd $project_path && afleet $project_name)"
            else
                eval "$cmd"
            fi
            ;;
        tmux)
            local cmd="tmux new-window -c \"$project_path\" \"afleet $project_name\""
            if [[ "$DRY_RUN" == "1" ]]; then
                echo "DRY_RUN: $cmd"
            else
                eval "$cmd"
            fi
            ;;
        fallback)
            echo "No supported terminal multiplexer detected."
            echo "Open a new terminal manually and run:"
            echo "  cd $project_path && afleet $project_name"
            ;;
    esac
}

# ── Actions ───────────────────────────────────────────────────────────────────

action_info() {
    local match
    match=$(lookup_project "$PROJECT")
    if [[ -z "$match" ]]; then
        echo "Error: project '$PROJECT' not found in registry." >&2
        exit 1
    fi

    local name prio parent path machines
    IFS='|' read -r name prio parent path machines <<< "$match"

    echo "Project:   $name"
    echo "Priority:  $prio"
    echo "Path:      $path"
    if [[ "$parent" != "—" && "$parent" != "-" && -n "$parent" ]]; then
        echo "Parent:    $parent"
    fi
    echo "Machines:  $machines"

    # Show directory existence
    if [[ -d "$path" ]]; then
        echo "Status:    directory exists"
    else
        echo "Status:    directory NOT found"
    fi
}

action_notify() {
    local inbox="$CONFIG_REPO/cross-project/inbox.md"

    # Create inbox file with header if it doesn't exist
    if [[ ! -f "$inbox" ]]; then
        mkdir -p "$(dirname "$inbox")"
        cat > "$inbox" << 'HEADER'
# Cross-Project Inbox

Tasks are per-project. Each project picks up its own entry and deletes it after integrating.

## Pending

HEADER
    fi

    # Append the task
    echo "- [ ] **${PROJECT}**: ${MESSAGE}" >> "$inbox"
    echo "Task added to inbox for $PROJECT"
}

action_tab() {
    local match
    match=$(lookup_project "$PROJECT")
    if [[ -z "$match" ]]; then
        echo "Error: project '$PROJECT' not found in registry." >&2
        exit 1
    fi

    local name prio parent path machines
    IFS='|' read -r name prio parent path machines <<< "$match"

    echo "Opening $name in new tab..."
    open_project_tab "$name" "$path"
}

action_switch() {
    local match
    match=$(lookup_project "$PROJECT")
    if [[ -z "$match" ]]; then
        echo "Error: project '$PROJECT' not found in registry." >&2
        exit 1
    fi

    local name prio parent path machines
    IFS='|' read -r name prio parent path machines <<< "$match"

    echo "Opening $name in new tab..."
    open_project_tab "$name" "$path"
    echo ""
    echo "You can now close this session. Run 'cls' or '/clear' to shut down."
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

case "$ACTION" in
    info)   action_info ;;
    notify) action_notify ;;
    tab)    action_tab ;;
    switch) action_switch ;;
esac
