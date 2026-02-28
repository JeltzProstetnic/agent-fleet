#!/usr/bin/env bash
#
# install-skill-collections.sh — Clone and register skill collection marketplaces
# ==================================================================================
# Clones skill collection repos as Claude Code plugin marketplaces and registers
# them in settings.json. Also clones raw skill repos for discovery/browsing.
#
# Usage:
#   bash install-skill-collections.sh [--dry-run] [--verbose] [--no-color]
#
# What this script does:
#   1. Clones marketplace repos into plugins/marketplaces/ (Claude Code plugin format)
#   2. Clones raw skill repos into ~/.local/share/skill-collections/ (for browsing)
#   3. Adds enabledPlugins entries to settings.json
#
# Idempotent: safe to re-run. Skips already-cloned repos, merges plugin entries.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source lib.sh if available (for logging helpers), otherwise define minimal stubs
if [[ -f "${SCRIPT_DIR}/../lib.sh" ]]; then
    source "${SCRIPT_DIR}/../lib.sh"
elif [[ -f "${SCRIPT_DIR}/../../setup/lib.sh" ]]; then
    source "${SCRIPT_DIR}/../../setup/lib.sh"
else
    # Minimal stubs
    DRY_RUN="${DRY_RUN:-false}"
    log_info()    { echo "[INFO]  $*"; }
    log_success() { echo "[OK]    $*"; }
    log_warn()    { echo "[WARN]  $*"; }
    log_error()   { echo "[ERROR] $*" >&2; }
    print_header() { echo ""; echo "=== $* ==="; echo ""; }
fi

# ============================================================================
# CONFIGURATION
# ============================================================================

# Auto-detect Claude Code config directory (cc-mirror variant or stock)
CC_MIRROR_VARIANT="mclaude"
if [[ -d "${HOME}/.cc-mirror/${CC_MIRROR_VARIANT}/config" ]]; then
    CONFIG_DIR="${HOME}/.cc-mirror/${CC_MIRROR_VARIANT}/config"
else
    CONFIG_DIR="${HOME}/.claude"
fi
MARKETPLACE_DIR="${CONFIG_DIR}/plugins/marketplaces"
SKILL_COLLECTIONS_DIR="${HOME}/.local/share/skill-collections"
SETTINGS_FILE="${CONFIG_DIR}/settings.json"

# Marketplace repos — cloned into plugins/marketplaces/<dir-name>/
# Format: "dir-name|git-url"
MARKETPLACE_REPOS=(
    "getsentry|https://github.com/getsentry/skills"
    "superpowers-marketplace|https://github.com/obra/superpowers"
    "trailofbits|https://github.com/trailofbits/skills"
)

# Skill collection repos — cloned into ~/.local/share/skill-collections/<dir-name>/
# These are for browsing/discovery, not directly registered as marketplaces.
# Format: "dir-name|git-url"
SKILL_COLLECTION_REPOS=(
    "anthropic-skills|https://github.com/anthropics/skills"
    "voltagent-skills|https://github.com/VoltAgent/awesome-agent-skills"
)

# Plugin enablement entries for settings.json
# Format: "key|enabled(true/false)"
# These map to plugins discovered inside the marketplace repos.
PLUGIN_ENTRIES=(
    "sentry-skills@getsentry|true"
    "superpowers@superpowers-marketplace|true"
    "ask-questions-if-underspecified@trailofbits|true"
    "modern-python@trailofbits|true"
    "property-based-testing@trailofbits|true"
    "second-opinion@trailofbits|false"
    "git-cleanup@trailofbits|true"
    "static-analysis@trailofbits|true"
    "differential-review@trailofbits|true"
)

# ============================================================================
# ARGUMENT PARSING
# ============================================================================

# Initialize logging if lib.sh was sourced
if type -t log_init &>/dev/null; then
    log_init
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)  DRY_RUN=true; shift ;;
        --verbose)  VERBOSE=true; shift ;;
        --no-color) NO_COLOR=true; shift ;;
        --help|-h)
            echo "Usage: bash install-skill-collections.sh [--dry-run] [--verbose] [--no-color]"
            echo ""
            echo "Clones skill collection repos and registers them as Claude Code plugins."
            echo "Idempotent — safe to re-run."
            exit 0
            ;;
        *) log_warn "Unknown argument: $1"; shift ;;
    esac
done

# ============================================================================
# CLONE HELPERS
# ============================================================================

clone_repo() {
    local target_dir="$1"
    local dir_name="$2"
    local git_url="$3"
    local dest="${target_dir}/${dir_name}"

    if [[ -d "${dest}/.git" ]]; then
        log_info "${dir_name}: already cloned, pulling latest..."
        if [[ "${DRY_RUN}" == "false" ]]; then
            git -C "${dest}" pull --quiet 2>/dev/null || log_warn "${dir_name}: git pull failed (network?)"
        else
            echo "  [DRY RUN] Would git pull in ${dest}"
        fi
        return 0
    fi

    if [[ -d "${dest}" ]]; then
        log_warn "${dir_name}: directory exists but is not a git repo — skipping"
        return 0
    fi

    log_info "${dir_name}: cloning from ${git_url}..."
    if [[ "${DRY_RUN}" == "false" ]]; then
        mkdir -p "${target_dir}"
        if git clone --quiet --depth 1 "${git_url}" "${dest}" 2>/dev/null; then
            log_success "${dir_name}: cloned successfully"
        else
            log_warn "${dir_name}: clone failed (private repo or network issue) — skipping"
        fi
    else
        echo "  [DRY RUN] Would clone ${git_url} → ${dest}"
    fi
}

# ============================================================================
# STEP 1: CLONE MARKETPLACE REPOS
# ============================================================================

print_header "Step 1: Clone Marketplace Repos"

log_info "Target: ${MARKETPLACE_DIR}"
mkdir -p "${MARKETPLACE_DIR}"

cloned_count=0
skipped_count=0

for entry in "${MARKETPLACE_REPOS[@]}"; do
    dir_name="${entry%%|*}"
    git_url="${entry#*|}"
    if [[ -d "${MARKETPLACE_DIR}/${dir_name}/.git" ]]; then
        skipped_count=$((skipped_count + 1))
    else
        cloned_count=$((cloned_count + 1))
    fi
    clone_repo "${MARKETPLACE_DIR}" "${dir_name}" "${git_url}"
done

log_success "Marketplaces: ${cloned_count} new, ${skipped_count} already present"

# ============================================================================
# STEP 2: CLONE SKILL COLLECTION REPOS
# ============================================================================

print_header "Step 2: Clone Skill Collection Repos (for discovery)"

log_info "Target: ${SKILL_COLLECTIONS_DIR}"
mkdir -p "${SKILL_COLLECTIONS_DIR}"

cloned_count=0
skipped_count=0

for entry in "${SKILL_COLLECTION_REPOS[@]}"; do
    dir_name="${entry%%|*}"
    git_url="${entry#*|}"
    if [[ -d "${SKILL_COLLECTIONS_DIR}/${dir_name}/.git" ]]; then
        skipped_count=$((skipped_count + 1))
    else
        cloned_count=$((cloned_count + 1))
    fi
    clone_repo "${SKILL_COLLECTIONS_DIR}" "${dir_name}" "${git_url}"
done

log_success "Skill collections: ${cloned_count} new, ${skipped_count} already present"

# ============================================================================
# STEP 3: REGISTER PLUGINS IN SETTINGS.JSON
# ============================================================================

print_header "Step 3: Register Plugins in settings.json"

if [[ ! -f "${SETTINGS_FILE}" ]]; then
    log_error "settings.json not found at ${SETTINGS_FILE}"
    log_error "Run configure-claude.sh first to deploy the base settings."
    exit 1
fi

log_info "Merging enabledPlugins entries into ${SETTINGS_FILE}..."

if [[ "${DRY_RUN}" == "false" ]]; then
    # Build JSON patch from PLUGIN_ENTRIES
    python3 -c "
import json, sys

settings_path = '${SETTINGS_FILE}'
with open(settings_path, 'r') as f:
    settings = json.load(f)

plugins = settings.setdefault('enabledPlugins', {})
entries = [line.split('|') for line in '''$(printf '%s\n' "${PLUGIN_ENTRIES[@]}")'''.strip().splitlines()]

added = 0
for key, enabled in entries:
    if key not in plugins:
        plugins[key] = enabled == 'true'
        added += 1

with open(settings_path, 'w') as f:
    json.dump(settings, f, indent=2)
    f.write('\n')

print(f'  Added {added} new plugin entries, {len(entries) - added} already present')
"
else
    echo "  [DRY RUN] Would add plugin entries to settings.json:"
    for entry in "${PLUGIN_ENTRIES[@]}"; do
        key="${entry%%|*}"
        enabled="${entry#*|}"
        echo "    ${key} = ${enabled}"
    done
fi

log_success "Plugin registration complete"

# ============================================================================
# STEP 4: UPDATE SETTINGS TEMPLATE (if in agent-fleet repo)
# ============================================================================

# If we're running from within the agent-fleet repo, also update the template
TEMPLATE_SETTINGS="${SCRIPT_DIR}/../config/settings.json"
if [[ -f "${TEMPLATE_SETTINGS}" ]]; then
    print_header "Step 4: Update settings.json template"

    if [[ "${DRY_RUN}" == "false" ]]; then
        python3 -c "
import json

template_path = '${TEMPLATE_SETTINGS}'
with open(template_path, 'r') as f:
    template = json.load(f)

plugins = template.setdefault('enabledPlugins', {})
entries = [line.split('|') for line in '''$(printf '%s\n' "${PLUGIN_ENTRIES[@]}")'''.strip().splitlines()]

added = 0
for key, enabled in entries:
    if key not in plugins:
        plugins[key] = enabled == 'true'
        added += 1

with open(template_path, 'w') as f:
    json.dump(template, f, indent=2)
    f.write('\n')

print(f'  Added {added} new entries to template, {len(entries) - added} already present')
"
    else
        echo "  [DRY RUN] Would update template at ${TEMPLATE_SETTINGS}"
    fi

    log_success "Template updated"
else
    log_info "Not in agent-fleet repo — skipping template update"
fi

# ============================================================================
# SUMMARY
# ============================================================================

print_header "Skill Collections Installed"

echo "Marketplaces (Claude Code plugins):"
for entry in "${MARKETPLACE_REPOS[@]}"; do
    dir_name="${entry%%|*}"
    if [[ -d "${MARKETPLACE_DIR}/${dir_name}/.git" ]]; then
        echo "  + ${dir_name}"
    else
        echo "  - ${dir_name} (failed)"
    fi
done

echo ""
echo "Skill collections (for discovery):"
for entry in "${SKILL_COLLECTION_REPOS[@]}"; do
    dir_name="${entry%%|*}"
    if [[ -d "${SKILL_COLLECTIONS_DIR}/${dir_name}/.git" ]]; then
        echo "  + ${dir_name}"
    else
        echo "  - ${dir_name} (failed)"
    fi
done

echo ""
echo "Plugin entries registered in settings.json."
echo ""
echo "To enable/disable specific plugins, edit:"
echo "  ${SETTINGS_FILE}"
echo "  (under 'enabledPlugins')"
echo ""

if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[DRY RUN] No changes were made."
fi
