#!/usr/bin/env bash
#
# install-voltagent.sh — Install VoltAgent marketplace and plugin bundles (CFG-137a)
# ====================================================================================
# Automates the VoltAgent marketplace installation previously done manually.
# Clones the awesome-claude-code-subagents repo, installs all 10 plugin bundles
# into the cache, and registers everything in known_marketplaces.json and
# installed_plugins.json.
#
# Usage:
#   bash install-voltagent.sh [--dry-run] [--verbose]
#
# Environment:
#   INSTALL_VA_CONFIG_DIR   Override config dir (for testing)
#   INSTALL_VA_SKIP_CLONE   Path to pre-cloned repo (for testing — skips git clone)
#
# Idempotent: safe to re-run. Skips already-installed plugins, merges JSON entries.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source lib.sh if available
if [[ -f "${SCRIPT_DIR}/../lib.sh" ]]; then
    source "${SCRIPT_DIR}/../lib.sh"
else
    DRY_RUN="${DRY_RUN:-false}"
    VERBOSE="${VERBOSE:-false}"
    log_info()    { echo "[INFO]  $*"; }
    log_success() { echo "[OK]    $*"; }
    log_warn()    { echo "[WARN]  $*"; }
    log_error()   { echo "[ERROR] $*" >&2; }
    print_header() { echo ""; echo "=== $* ==="; echo ""; }
fi

# ============================================================================
# CONFIGURATION
# ============================================================================

# Auto-detect config directory (override with INSTALL_VA_CONFIG_DIR for testing)
if [[ -n "${INSTALL_VA_CONFIG_DIR:-}" ]]; then
    CONFIG_DIR="$INSTALL_VA_CONFIG_DIR"
elif [[ -d "${HOME}/.cc-mirror/mclaude/config" ]]; then
    CONFIG_DIR="${HOME}/.cc-mirror/mclaude/config"
else
    CONFIG_DIR="${HOME}/.claude"
fi

MARKETPLACE_NAME="voltagent-subagents"
GITHUB_REPO="VoltAgent/awesome-claude-code-subagents"
GITHUB_URL="https://github.com/${GITHUB_REPO}"

MARKETPLACE_DIR="${CONFIG_DIR}/plugins/marketplaces/${MARKETPLACE_NAME}"
CACHE_DIR="${CONFIG_DIR}/plugins/cache/${MARKETPLACE_NAME}"
KNOWN_MARKETPLACES="${CONFIG_DIR}/plugins/known_marketplaces.json"
INSTALLED_PLUGINS="${CONFIG_DIR}/plugins/installed_plugins.json"

# ============================================================================
# ARGUMENT PARSING
# ============================================================================

DRY_RUN="${DRY_RUN:-false}"
VERBOSE="${VERBOSE:-false}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)  DRY_RUN=true; shift ;;
        --verbose)  VERBOSE=true; shift ;;
        --help|-h)
            echo "Usage: bash install-voltagent.sh [--dry-run] [--verbose]"
            echo ""
            echo "Installs VoltAgent marketplace (awesome-claude-code-subagents) into"
            echo "the Claude Code plugins directory."
            echo ""
            echo "Options:"
            echo "  --dry-run   Show what would be done without doing it"
            echo "  --verbose   Show detailed progress"
            echo ""
            echo "Environment:"
            echo "  INSTALL_VA_CONFIG_DIR   Override config dir (for testing)"
            echo "  INSTALL_VA_SKIP_CLONE   Path to pre-cloned repo (skip git clone)"
            exit 0
            ;;
        *) log_warn "Unknown argument: $1"; shift ;;
    esac
done

verbose_log() {
    if [[ "${VERBOSE}" == "true" ]]; then
        log_info "$*"
    fi
}

# ============================================================================
# STEP 1: CLONE / UPDATE MARKETPLACE REPO
# ============================================================================

print_header "Step 1: Clone VoltAgent Marketplace"

# INSTALL_VA_SKIP_CLONE is set by tests to inject a pre-built fake repo
# instead of running a real git clone.
SKIP_CLONE_SRC="${INSTALL_VA_SKIP_CLONE:-}"

if [[ "${DRY_RUN}" == "true" ]]; then
    echo "  [DRY RUN] Would clone ${GITHUB_URL} → ${MARKETPLACE_DIR}"
else
    if [[ -n "$SKIP_CLONE_SRC" ]]; then
        # Test mode: copy the fake repo to the marketplace dir
        if [[ ! -d "${MARKETPLACE_DIR}" ]]; then
            mkdir -p "$(dirname "${MARKETPLACE_DIR}")"
            cp -r "${SKIP_CLONE_SRC}" "${MARKETPLACE_DIR}"
            verbose_log "Copied test repo from ${SKIP_CLONE_SRC} → ${MARKETPLACE_DIR}"
        else
            verbose_log "Marketplace dir already exists, skipping copy"
        fi
    elif [[ -d "${MARKETPLACE_DIR}/.git" ]]; then
        log_info "${MARKETPLACE_NAME}: already cloned, pulling latest..."
        git -C "${MARKETPLACE_DIR}" pull --quiet 2>/dev/null \
            || log_warn "${MARKETPLACE_NAME}: git pull failed (network?) — continuing with existing"
    elif [[ -d "${MARKETPLACE_DIR}" ]]; then
        log_warn "${MARKETPLACE_NAME}: directory exists but is not a git repo — skipping clone"
    else
        log_info "Cloning ${GITHUB_URL}..."
        mkdir -p "$(dirname "${MARKETPLACE_DIR}")"
        if git clone --quiet --depth 1 "${GITHUB_URL}" "${MARKETPLACE_DIR}" 2>/dev/null; then
            log_success "Cloned ${MARKETPLACE_NAME}"
        else
            log_error "Clone failed — check network or repo access"
            exit 1
        fi
    fi
fi

# ============================================================================
# STEP 2: DISCOVER PLUGINS FROM MARKETPLACE MANIFEST
# ============================================================================

print_header "Step 2: Discover Plugins"

MARKETPLACE_JSON="${MARKETPLACE_DIR}/.claude-plugin/marketplace.json"

# Convert paths for native Python on Windows/MSYS (CFG-336)
_PY_MARKETPLACE_JSON=$(_to_native_path "${MARKETPLACE_JSON}" 2>/dev/null || echo "${MARKETPLACE_JSON}")
_PY_KNOWN_MARKETPLACES=$(_to_native_path "${KNOWN_MARKETPLACES}" 2>/dev/null || echo "${KNOWN_MARKETPLACES}")
_PY_INSTALLED_PLUGINS=$(_to_native_path "${INSTALLED_PLUGINS}" 2>/dev/null || echo "${INSTALLED_PLUGINS}")
_PY_MARKETPLACE_DIR=$(_to_native_path "${MARKETPLACE_DIR}" 2>/dev/null || echo "${MARKETPLACE_DIR}")
_PY_CACHE_DIR=$(_to_native_path "${CACHE_DIR}" 2>/dev/null || echo "${CACHE_DIR}")

if [[ "${DRY_RUN}" == "true" ]]; then
    echo "  [DRY RUN] Would read plugin list from ${MARKETPLACE_JSON}"
    echo "  [DRY RUN] Would install all plugins to ${CACHE_DIR}/<plugin-name>/1.0.0"
    print_header "Summary"
    echo "  [DRY RUN] No changes made."
    exit 0
fi

if [[ ! -f "${MARKETPLACE_JSON}" ]]; then
    log_error "Marketplace manifest not found: ${MARKETPLACE_JSON}"
    log_error "Is the marketplace cloned correctly?"
    exit 1
fi

# Parse plugin list from marketplace.json
# Returns lines of: name|source_path|version
PLUGIN_LIST=$(python3 -c "
import json, sys
try:
    data = json.load(open('${_PY_MARKETPLACE_JSON}'))
    for p in data.get('plugins', []):
        name = p.get('name', '')
        source = p.get('source', '')
        version = p.get('version', '1.0.0')
        if name and source:
            print(f'{name}|{source}|{version}')
except Exception as e:
    print(f'ERROR: {e}', file=sys.stderr)
    sys.exit(1)
")

if [[ -z "${PLUGIN_LIST}" ]]; then
    log_error "No plugins found in ${MARKETPLACE_JSON}"
    exit 1
fi

plugin_count=$(echo "${PLUGIN_LIST}" | wc -l | tr -d ' ')
log_info "Found ${plugin_count} plugin bundles in marketplace manifest"

# ============================================================================
# STEP 3: INSTALL PLUGINS TO CACHE
# ============================================================================

print_header "Step 3: Install Plugin Bundles to Cache"

mkdir -p "${CACHE_DIR}"

installed_count=0
skipped_count=0

while IFS='|' read -r plugin_name plugin_source plugin_version; do
    [[ -z "$plugin_name" ]] && continue

    # Resolve source path relative to marketplace dir
    # Source is like "./categories/01-core-development"
    source_dir="${MARKETPLACE_DIR}/${plugin_source#./}"
    cache_dest="${CACHE_DIR}/${plugin_name}/${plugin_version}"

    if [[ -d "${cache_dest}" ]]; then
        verbose_log "${plugin_name}: already in cache (${cache_dest}) — skipping"
        ((skipped_count++)) || true
        continue
    fi

    if [[ ! -d "${source_dir}" ]]; then
        log_warn "${plugin_name}: source dir not found (${source_dir}) — skipping"
        continue
    fi

    verbose_log "${plugin_name}: copying ${source_dir} → ${cache_dest}"
    mkdir -p "$(dirname "${cache_dest}")"
    cp -r "${source_dir}" "${cache_dest}"
    log_info "Installed: ${plugin_name}@${plugin_version}"
    ((installed_count++)) || true

done <<< "${PLUGIN_LIST}"

log_success "Plugins: ${installed_count} installed, ${skipped_count} already present"

# ============================================================================
# STEP 4: REGISTER IN known_marketplaces.json
# ============================================================================

print_header "Step 4: Register in known_marketplaces.json"

mkdir -p "$(dirname "${KNOWN_MARKETPLACES}")"

NOW=$(python3 -c "from datetime import datetime, timezone; print(datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.000Z'))")

python3 - <<PYEOF
import json, os

path = '${_PY_KNOWN_MARKETPLACES}'
marketplace_dir = '${_PY_MARKETPLACE_DIR}'
now = '${NOW}'

# Load existing or start fresh
if os.path.exists(path):
    with open(path, 'r') as f:
        data = json.load(f)
else:
    data = {}

# Add/update voltagent entry
data['${MARKETPLACE_NAME}'] = {
    'source': {
        'source': 'github',
        'repo': '${GITHUB_REPO}'
    },
    'installLocation': marketplace_dir,
    'lastUpdated': now
}

with open(path, 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')

print(f'  Registered voltagent-subagents in {path}')
PYEOF

log_success "Marketplace registered in known_marketplaces.json"

# ============================================================================
# STEP 5: REGISTER PLUGINS IN installed_plugins.json
# ============================================================================

print_header "Step 5: Register Plugins in installed_plugins.json"

mkdir -p "$(dirname "${INSTALLED_PLUGINS}")"

python3 - <<PYEOF
import json, os

path = '${_PY_INSTALLED_PLUGINS}'
cache_base = '${_PY_CACHE_DIR}'
plugin_list_raw = """${PLUGIN_LIST}"""
now = '${NOW}'

# Load existing or start fresh with version 2 format
if os.path.exists(path):
    with open(path, 'r') as f:
        data = json.load(f)
    # Ensure version 2 format
    if data.get('version') != 2:
        data = {'version': 2, 'plugins': data}
    if 'plugins' not in data:
        data['plugins'] = {}
else:
    data = {'version': 2, 'plugins': {}}

plugins = data['plugins']

added = 0
skipped = 0
for line in plugin_list_raw.strip().splitlines():
    line = line.strip()
    if not line:
        continue
    parts = line.split('|')
    if len(parts) < 3:
        continue
    name, source, version = parts[0], parts[1], parts[2]
    key = f'{name}@voltagent-subagents'
    install_path = os.path.join(cache_base, name, version)

    if key in plugins:
        skipped += 1
        continue

    plugins[key] = [{
        'scope': 'user',
        'installPath': install_path,
        'version': version,
        'installedAt': now,
        'lastUpdated': now
    }]
    added += 1

with open(path, 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')

print(f'  Added {added} plugin entries, {skipped} already present')
PYEOF

log_success "Plugins registered in installed_plugins.json"

# ============================================================================
# SUMMARY
# ============================================================================

print_header "VoltAgent Installation Complete"

echo "Marketplace:   ${MARKETPLACE_DIR}"
echo "Cache:         ${CACHE_DIR}"
echo "Registries:    ${KNOWN_MARKETPLACES}"
echo "               ${INSTALLED_PLUGINS}"
echo ""
echo "Installed ${plugin_count} plugin bundles from VoltAgent/awesome-claude-code-subagents."
echo ""
if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[DRY RUN] No changes were made."
fi
