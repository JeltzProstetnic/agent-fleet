#!/usr/bin/env bash
#
# setup-project-roster.sh — Configure per-project VoltAgent agent rosters (CFG-137b, CFG-220)
# =====================================================================================
# Registry-authoritative roster deployment. Reads the Roster Snapshots table in
# registry.md as the single source of truth for per-project agent bundles.
# Falls back to TYPE_BUNDLE_MAP for projects not in the roster table.
#
# VoltAgent plugins are installed globally in the marketplace cache but MUST NOT be
# enabled globally (token budget rule). Instead, each project enables only the relevant
# bundles via per-project .claude/settings.local.json.
#
# Usage:
#   bash setup-project-roster.sh [<project-path>] [--dry-run] [--list] [--all-local]
#
#   <project-path>   Project directory (defaults to CWD)
#   --dry-run        Preview without writing
#   --list           Show the type→bundle mapping table and exit
#   --all-local      Apply rosters to all locally-present projects from registry
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
ALL_LOCAL=false
PROJECT_PATH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)     DRY_RUN=true; shift ;;
        --list)        LIST_MODE=true; shift ;;
        --all-local)   ALL_LOCAL=true; shift ;;
        --help|-h)
            echo "Usage: bash setup-project-roster.sh [<project-path>] [--dry-run] [--list] [--all-local]"
            echo ""
            echo "Configures per-project VoltAgent agent roster via .claude/settings.local.json."
            echo ""
            echo "Options:"
            echo "  <project-path>   Project directory (default: CWD)"
            echo "  --dry-run        Preview changes without writing"
            echo "  --list           Show project-type → bundle mapping and exit"
            echo "  --all-local      Apply rosters to all locally-present projects from registry"
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

# ============================================================================
# TYPE → BUNDLE MAPPING (fallback when project not in Roster Snapshots)
# ============================================================================
# Each entry: "type_pattern|bundle1 bundle2 bundle3"
# Type pattern is matched as a substring (case-insensitive) against the Type
# column extracted from registry.md.

# Canonical types from global/reference/project-types.md (CFG-217)
declare -a TYPE_BUNDLE_MAP=(
    "code|voltagent-core-dev voltagent-lang voltagent-qa-sec"
    "writing|voltagent-research"
    "research|voltagent-research voltagent-data-ai"
    "config|voltagent-infra voltagent-dev-exp"
    "infra|voltagent-infra voltagent-dev-exp"
    "marketing|voltagent-research voltagent-biz"
    "business|voltagent-biz voltagent-research"
    "data|voltagent-data-ai voltagent-research"
    "media|voltagent-data-ai voltagent-core-dev"
    "tooling|voltagent-core-dev voltagent-infra voltagent-biz"
    "research + writing|voltagent-research voltagent-data-ai"
    "research + writing + code|voltagent-research voltagent-data-ai voltagent-core-dev voltagent-lang"
    "research + code|voltagent-research voltagent-data-ai voltagent-core-dev voltagent-lang"
    "code + infra|voltagent-core-dev voltagent-lang voltagent-infra"
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
# REGISTRY ROSTER PARSING (CFG-220)
# ============================================================================

# Parse the Roster Snapshots table from registry.md.
# Returns space-separated voltagent bundle names for the given project,
# or empty string if project not found in the roster table.
lookup_registry_roster() {
    local project_name="$1"

    if [[ ! -f "$REGISTRY" ]]; then
        echo ""
        return
    fi

    python3 - "$REGISTRY" "$project_name" << 'PYEOF'
import sys

registry_path = sys.argv[1]
project_name = sys.argv[2]

with open(registry_path, 'r') as f:
    content = f.read()

# Find the Roster Snapshots section
in_roster = False
for line in content.splitlines():
    stripped = line.strip()
    # Detect section start
    if stripped.startswith('## Roster Snapshots'):
        in_roster = True
        continue
    # Stop at next section
    if in_roster and stripped.startswith('## '):
        break
    if not in_roster:
        continue
    # Parse table rows
    if not stripped.startswith('|'):
        continue
    cols = [c.strip() for c in stripped.split('|')]
    if len(cols) < 4:
        continue
    proj_col = cols[1]
    bundles_col = cols[2]
    # Skip header/separator
    if proj_col in ('Project', '') or '---' in proj_col:
        continue
    if bundles_col in ('Bundles (enabledPlugins)', '') or '---' in bundles_col:
        continue
    # Match project name
    if proj_col.strip() == project_name:
        # Parse comma-separated short names → voltagent-prefixed space-separated
        short_names = [b.strip() for b in bundles_col.split(',') if b.strip()]
        full_names = [f"voltagent-{name}" for name in short_names]
        print(' '.join(full_names))
        sys.exit(0)

# Not found
print('')
PYEOF
}

# Parse registry to get all projects with their paths and roster data.
# Used by --all-local mode. Outputs lines of "project_name|path|bundles".
# If a project has a roster entry, bundles come from there.
# Otherwise bundles are empty (caller should fall back to type-based).
list_registry_projects() {
    if [[ ! -f "$REGISTRY" ]]; then
        return
    fi

    python3 - "$REGISTRY" << 'PYEOF'
import sys, os

registry_path = sys.argv[1]

with open(registry_path, 'r') as f:
    content = f.read()

# First pass: collect roster entries
roster = {}
in_roster = False
for line in content.splitlines():
    stripped = line.strip()
    if stripped.startswith('## Roster Snapshots'):
        in_roster = True
        continue
    if in_roster and stripped.startswith('## '):
        break
    if not in_roster or not stripped.startswith('|'):
        continue
    cols = [c.strip() for c in stripped.split('|')]
    if len(cols) < 4:
        continue
    proj = cols[1].strip()
    bundles_col = cols[2].strip()
    if proj in ('Project', '') or '---' in proj:
        continue
    if bundles_col in ('Bundles (enabledPlugins)', '') or '---' in bundles_col:
        continue
    short_names = [b.strip() for b in bundles_col.split(',') if b.strip()]
    roster[proj] = ' '.join(f"voltagent-{name}" for name in short_names)

# Second pass: collect projects with paths
in_projects = False
for line in content.splitlines():
    stripped = line.strip()
    if stripped.startswith('## Projects'):
        in_projects = True
        continue
    if in_projects and stripped.startswith('## ') and 'Roster' not in stripped:
        break
    if not in_projects or not stripped.startswith('|'):
        continue
    cols = [c.strip() for c in stripped.split('|')]
    if len(cols) < 9:
        continue
    proj = cols[1].strip()
    path_col = cols[4].strip().strip('`').strip()
    type_col = cols[7].strip()
    if proj in ('Project', '') or '---' in proj:
        continue
    if not path_col:
        continue
    # Expand ~ to HOME
    expanded = path_col.replace('~', os.environ.get('HOME', '~'))
    bundles = roster.get(proj, '')
    print(f"{proj}|{expanded}|{bundles}|{type_col}")
PYEOF
}

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
    # Check if the leaf directory matches the last component of the path
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
# BUNDLE RESOLUTION (type-based fallback)
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
# SETTINGS WRITE (replaces enabledPlugins, preserves other keys)
# ============================================================================

write_settings() {
    local settings_file="$1"
    local bundles="$2"
    local dry_run="$3"

    if [[ "$dry_run" == "true" ]]; then
        echo "[DRY RUN] Would write to: $settings_file"
        echo "[DRY RUN] enabledPlugins:"
        python3 - "$bundles" << 'PYEOF'
import sys
bundles = sys.argv[1].split()
for b in bundles:
    if b:
        print(f"  {b}@voltagent-subagents: true")
PYEOF
        return
    fi

    # Write enabledPlugins — REPLACE (not merge) for registry-authoritative behavior.
    # Other settings keys are preserved.
    if [[ -f "$settings_file" ]]; then
        python3 - "$settings_file" "$bundles" << 'PYEOF'
import sys, json

settings_path = sys.argv[1]
bundles = sys.argv[2].split()

with open(settings_path, 'r') as f:
    settings = json.load(f)

# Replace enabledPlugins entirely (registry is authoritative)
ep = {}
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
# APPLY ROSTER TO A SINGLE PROJECT
# ============================================================================

apply_roster_to_project() {
    local project_path="$1"
    local project_name
    project_name="$(basename "$project_path")"
    local dry_run="${2:-$DRY_RUN}"

    # Step 1: Check registry roster (authoritative)
    local bundles
    bundles=$(lookup_registry_roster "$project_name")

    if [[ -n "$bundles" ]]; then
        log_info "$project_name: using registry roster"
    else
        # Step 2: Fall back to type-based resolution
        local project_type
        project_type=$(detect_project_type "$project_path")
        if [[ -z "$project_type" ]]; then
            log_warn "$project_name: no roster entry and type unknown — skipping"
            return 0
        fi
        bundles=$(resolve_bundles "$project_type")
        if [[ -z "$bundles" ]]; then
            log_warn "$project_name: no bundle mapping for type '$project_type' — skipping"
            return 0
        fi
        log_info "$project_name: using type-derived roster (type: $project_type)"
    fi

    log_info "$project_name bundles: $bundles"

    local settings_file="$project_path/.claude/settings.local.json"

    if [[ "$dry_run" != "true" ]]; then
        mkdir -p "$project_path/.claude"
    fi

    write_settings "$settings_file" "$bundles" "$dry_run"

    if [[ "$dry_run" != "true" ]]; then
        log_success "$project_name: roster written → $settings_file"
    fi
}

# ============================================================================
# ALL-LOCAL MODE (CFG-220)
# ============================================================================

run_all_local() {
    log_info "Applying rosters to all locally-present projects..."

    local count=0
    local skipped=0

    while IFS='|' read -r proj_name proj_path proj_bundles proj_type; do
        [[ -z "$proj_name" ]] && continue

        if [[ ! -d "$proj_path" ]]; then
            log_info "$proj_name: path not found locally ($proj_path) — skipping"
            ((skipped++)) || true
            continue
        fi

        apply_roster_to_project "$proj_path"
        ((count++)) || true
    done < <(list_registry_projects)

    log_info "Rosters applied: $count projects ($skipped skipped — not local)"
}

# ============================================================================
# MAIN
# ============================================================================

if [[ "$ALL_LOCAL" == "true" ]]; then
    run_all_local
    exit 0
fi

# Single-project mode
if [[ -z "$PROJECT_PATH" ]]; then
    PROJECT_PATH="$(pwd)"
fi

PROJECT_PATH="$(cd "$PROJECT_PATH" && pwd)"

log_info "Project path: $PROJECT_PATH"

apply_roster_to_project "$PROJECT_PATH"
