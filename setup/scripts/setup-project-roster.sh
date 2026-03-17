#!/usr/bin/env bash
#
# setup-project-roster.sh — Configure per-project VoltAgent agent rosters
# =====================================================================================
# MAINTENANCE UTILITY — not the primary roster setup mechanism.
# For new projects, the agent selects agents interactively as part of the
# project-setup.md flow, using judgment based on project domain and goals.
# This script is for retroactive/batch roster setup on existing projects.
#
# VoltAgent plugins are installed globally in the marketplace cache but MUST NOT be
# enabled globally (token budget rule). Instead, each project enables only the relevant
# bundles via per-project .claude/settings.local.json.
#
# This script detects the project type from registry.md and writes the appropriate
# enabledPlugins into <project>/.claude/settings.local.json. It merges into any
# existing settings — other keys are preserved.
#
# Usage:
#   bash setup-project-roster.sh [<project-path>] [--dry-run] [--list]
#
#   <project-path>   Project directory (defaults to CWD)
#   --dry-run        Preview without writing
#   --list           Show the type->bundle mapping table and exit
#
# Idempotent: safe to re-run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source lib.sh if available
if [[ -f "${SCRIPT_DIR}/../lib.sh" ]]; then
    source "${SCRIPT_DIR}/../lib.sh"
else
    DRY_RUN="${DRY_RUN:-false}"
    log_info()    { echo "[INFO]  $*"; }
    log_success() { echo "[OK]    $*"; }
    log_warn()    { echo "[WARN]  $*"; }
    log_error()   { echo "[ERROR] $*" >&2; }
fi

# ============================================================================
# CONFIGURATION
# ============================================================================

# Registry path (override via env var for testing)
REGISTRY="${SETUP_ROSTER_REGISTRY:-${SCRIPT_DIR}/../../registry.md}"

# ============================================================================
# ARGUMENT PARSING
# ============================================================================

DRY_RUN="${DRY_RUN:-false}"
LIST_MODE=false
PROJECT_PATH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)   DRY_RUN=true; shift ;;
        --list)      LIST_MODE=true; shift ;;
        --help|-h)
            echo "Usage: bash setup-project-roster.sh [<project-path>] [--dry-run] [--list]"
            echo ""
            echo "Configures per-project VoltAgent agent roster via .claude/settings.local.json."
            echo ""
            echo "Options:"
            echo "  <project-path>   Project directory (default: CWD)"
            echo "  --dry-run        Preview changes without writing"
            echo "  --list           Show project-type -> bundle mapping and exit"
            exit 0
            ;;
        -*)
            log_warn "Unknown flag: $1"
            shift
            ;;
        *)
            if [[ -z "$PROJECT_PATH" ]]; then
                PROJECT_PATH="$1"
            fi
            shift
            ;;
    esac
done

# Default to CWD
if [[ -z "$PROJECT_PATH" ]]; then
    PROJECT_PATH="$(pwd)"
fi

PROJECT_PATH="$(cd "$PROJECT_PATH" && pwd)"

# ============================================================================
# TYPE -> BUNDLE MAPPING
# ============================================================================
# Each entry: "type_pattern|bundle1 bundle2 bundle3"
# Type pattern is matched as a substring (case-insensitive) against the Type
# column extracted from registry.md.

declare -a TYPE_BUNDLE_MAP=(
    "code|voltagent-core-dev voltagent-lang voltagent-qa-sec"
    "meta/config|voltagent-dev-exp voltagent-infra"
    "research + authoring|voltagent-research voltagent-data-ai"
    "research+authoring|voltagent-research voltagent-data-ai"
    "marketing/engagement|voltagent-research voltagent-biz"
    "business/process|voltagent-biz voltagent-research"
    "business/research|voltagent-biz voltagent-research"
    "tooling/integration|voltagent-core-dev voltagent-infra voltagent-biz"
    "infra/config|voltagent-infra voltagent-dev-exp"
    "data/authoring|voltagent-data-ai voltagent-research"
    "writing|voltagent-research"
)

# ============================================================================
# LIST MODE
# ============================================================================

if [[ "$LIST_MODE" == "true" ]]; then
    printf "\n%-35s  %s\n" "Project Type" "Bundles"
    printf "%-35s  %s\n" "$(printf '%0.s-' {1..35})" "$(printf '%0.s-' {1..50})"
    for entry in "${TYPE_BUNDLE_MAP[@]}"; do
        local_type="${entry%%|*}"
        local_bundles="${entry##*|}"
        printf "%-35s  %s\n" "$local_type" "$local_bundles"
    done
    printf "\nMarketplace: voltagent-subagents\n"
    exit 0
fi

# ============================================================================
# PROJECT TYPE DETECTION
# ============================================================================

detect_project_type() {
    local project_path="$1"
    local project_name
    project_name="$(basename "$project_path")"

    if [[ ! -f "$REGISTRY" ]]; then
        log_warn "Registry not found: $REGISTRY"
        echo ""
        return
    fi

    # Extract the Type column from registry.md for this project.
    local project_type=""

    project_type=$(python3 - "$REGISTRY" "$project_name" "$project_path" << 'PYEOF'
import sys, re

registry_path = sys.argv[1]
project_name = sys.argv[2]
project_full_path = sys.argv[3]

# Get rightmost path component of full path for sub-projects
path_parts = [p for p in project_full_path.rstrip('/').split('/') if p]
leaf = path_parts[-1] if path_parts else project_name

with open(registry_path, 'r') as f:
    content = f.read()

# Parse table rows: split on | and strip whitespace
best_type = ""
best_score = 0

for line in content.splitlines():
    line = line.strip()
    if not line.startswith('|'):
        continue
    cols = [c.strip() for c in line.split('|')]
    # cols[0] is empty (before first |), cols[1..N] are the cells
    if len(cols) < 9:
        continue
    proj_col = cols[1]  # Project name column
    path_col = cols[4]  # Path column (backtick-quoted path)
    type_col = cols[7]  # Type column

    # Skip header/separator rows
    if proj_col in ('Project', '-------', '---') or '---' in proj_col:
        continue
    if not type_col or type_col in ('Type', '----', '---'):
        continue

    # Clean up project name
    proj_name_clean = proj_col.strip('` ')
    # Clean up path (remove backticks and ~/)
    path_clean = path_col.strip('` ').replace('~/', '').replace('`', '')

    # Score match quality
    score = 0
    if path_clean.endswith('/' + leaf) or path_clean == leaf:
        score = 3
    elif proj_name_clean.lower() == leaf.lower():
        score = 2
    elif proj_name_clean.lower() == project_name.lower():
        score = 2

    if score > best_score:
        best_score = score
        best_type = type_col.strip()

print(best_type)
PYEOF
    2>/dev/null || true)

    echo "$project_type"
}

# ============================================================================
# BUNDLE RESOLUTION
# ============================================================================

resolve_bundles() {
    local project_type="$1"
    local type_lower
    type_lower="$(echo "$project_type" | tr '[:upper:]' '[:lower:]')"

    local bundles=""

    for entry in "${TYPE_BUNDLE_MAP[@]}"; do
        local pattern="${entry%%|*}"
        local candidate_bundles="${entry##*|}"
        local pattern_lower
        pattern_lower="$(echo "$pattern" | tr '[:upper:]' '[:lower:]')"

        if [[ "$type_lower" == *"$pattern_lower"* ]]; then
            bundles="$candidate_bundles"
            break
        fi
    done

    echo "$bundles"
}

# ============================================================================
# SETTINGS MERGE
# ============================================================================

merge_settings() {
    local settings_file="$1"
    local bundles="$2"
    local dry_run="$3"

    # Build enabledPlugins JSON object
    local plugins_json
    plugins_json=$(python3 - "$bundles" << 'PYEOF'
import sys, json
bundles = sys.argv[1].split()
ep = {}
for b in bundles:
    if b:
        key = f"{b}@voltagent-subagents"
        ep[key] = True
print(json.dumps(ep, indent=2))
PYEOF
    )

    if [[ "$dry_run" == "true" ]]; then
        echo "[DRY RUN] Would write to: $settings_file"
        echo "[DRY RUN] enabledPlugins:"
        python3 - "$bundles" << 'PYEOF'
import sys, json
bundles = sys.argv[1].split()
for b in bundles:
    if b:
        print(f"  {b}@voltagent-subagents: true")
PYEOF
        return
    fi

    # Merge into existing settings.local.json or create fresh
    if [[ -f "$settings_file" ]]; then
        python3 - "$settings_file" "$bundles" << 'PYEOF'
import sys, json

settings_path = sys.argv[1]
bundles = sys.argv[2].split()

with open(settings_path, 'r') as f:
    settings = json.load(f)

ep = settings.get('enabledPlugins', {})
for b in bundles:
    if b:
        key = f"{b}@voltagent-subagents"
        ep[key] = True

settings['enabledPlugins'] = ep

with open(settings_path, 'w') as f:
    json.dump(settings, f, indent=2)
    f.write('\n')
PYEOF
    else
        python3 - "$settings_file" "$bundles" << 'PYEOF'
import sys, json

settings_path = sys.argv[1]
bundles = sys.argv[2].split()

ep = {}
for b in bundles:
    if b:
        key = f"{b}@voltagent-subagents"
        ep[key] = True

settings = {'enabledPlugins': ep}

with open(settings_path, 'w') as f:
    json.dump(settings, f, indent=2)
    f.write('\n')
PYEOF
    fi
}

# ============================================================================
# MAIN
# ============================================================================

log_info "Project path: $PROJECT_PATH"

# Detect type
project_type=$(detect_project_type "$PROJECT_PATH")

if [[ -z "$project_type" ]]; then
    log_warn "Project type unknown for: $(basename "$PROJECT_PATH")"
    log_warn "Not found in registry or type column is empty — no roster written"
    log_info "Run with --list to see supported type -> bundle mapping"
    exit 0
fi

log_info "Detected type: $project_type"

# Resolve bundles
bundles=$(resolve_bundles "$project_type")

if [[ -z "$bundles" ]]; then
    log_warn "No bundle mapping for project type: $project_type"
    log_warn "Supported types shown with --list"
    exit 0
fi

log_info "Bundles: $bundles"

# Target file
SETTINGS_FILE="$PROJECT_PATH/.claude/settings.local.json"

# Ensure .claude directory exists (even in dry-run, skip the mkdir)
if [[ "$DRY_RUN" != "true" ]]; then
    mkdir -p "$PROJECT_PATH/.claude"
fi

# Merge settings
merge_settings "$SETTINGS_FILE" "$bundles" "$DRY_RUN"

if [[ "$DRY_RUN" != "true" ]]; then
    log_success "Roster written: $SETTINGS_FILE"
fi
