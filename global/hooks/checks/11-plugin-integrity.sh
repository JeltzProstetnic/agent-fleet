#!/usr/bin/env bash
# Check group 11: VoltAgent plugin integrity
# Checks: 11.1, 11.2, 11.3
# Shared vars used: SETTINGS_FILE, WARNINGS
#
# Verifies that:
#   11.1. voltagent-subagents marketplace is registered in known_marketplaces.json
#   11.2. All 10 expected VoltAgent plugin bundles are in installed_plugins.json
#   11.3. Plugin cache directories exist and are non-empty for installed bundles
#
# Note: Global enabledPlugins check removed — Check 7.1 (07-environment.sh) auto-empties
# enabledPlugins before this file runs, making a warning-only check dead code.
#
# Expected state (from upstream-dependencies.md):
#   Marketplace: voltagent-subagents
#   Bundles: voltagent-lang, voltagent-infra, voltagent-core-dev, voltagent-qa-sec,
#            voltagent-data-ai, voltagent-dev-exp, voltagent-domains, voltagent-biz,
#            voltagent-meta, voltagent-research
#   All at version 1.0.0. Global enabledPlugins must be {}.

_PLUGIN_ISSUES=""
_PLUGINS_DIR="$(dirname "$SETTINGS_FILE")/plugins"
_MARKETPLACES_FILE="$_PLUGINS_DIR/known_marketplaces.json"
_INSTALLED_FILE="$_PLUGINS_DIR/installed_plugins.json"
_CACHE_DIR="$_PLUGINS_DIR/cache/voltagent-subagents"

_EXPECTED_BUNDLES="voltagent-lang voltagent-infra voltagent-core-dev voltagent-qa-sec \
voltagent-data-ai voltagent-dev-exp voltagent-domains voltagent-biz \
voltagent-meta voltagent-research"

# Check 11.1: voltagent-subagents marketplace registered
if [ -f "$_MARKETPLACES_FILE" ]; then
    if ! grep -q '"voltagent-subagents"' "$_MARKETPLACES_FILE" 2>/dev/null; then
        _PLUGIN_ISSUES="${_PLUGIN_ISSUES:+$_PLUGIN_ISSUES; }voltagent-subagents marketplace not registered in known_marketplaces.json (run 'mclaude marketplace add VoltAgent/awesome-claude-code-subagents' to fix)"
    fi
else
    _PLUGIN_ISSUES="${_PLUGIN_ISSUES:+$_PLUGIN_ISSUES; }voltagent-subagents marketplace not registered (known_marketplaces.json missing — reinstall required)"
fi

# Check 11.2: All expected plugin bundles installed
if [ -f "$_INSTALLED_FILE" ]; then
    _MISSING_BUNDLES=""
    for _bundle in $_EXPECTED_BUNDLES; do
        if ! grep -q "\"${_bundle}@voltagent-subagents\"" "$_INSTALLED_FILE" 2>/dev/null; then
            _MISSING_BUNDLES="${_MISSING_BUNDLES:+$_MISSING_BUNDLES, }$_bundle"
        fi
    done
    if [ -n "$_MISSING_BUNDLES" ]; then
        _PLUGIN_ISSUES="${_PLUGIN_ISSUES:+$_PLUGIN_ISSUES; }missing installed plugin bundles: $_MISSING_BUNDLES (run 'mclaude plugins install <bundle>' to fix)"
    fi
else
    _PLUGIN_ISSUES="${_PLUGIN_ISSUES:+$_PLUGIN_ISSUES; }installed_plugins.json missing — VoltAgent plugin bundles may not be installed"
fi

# Check 11.3: Plugin cache directories exist and are non-empty (at least one file anywhere inside)
if [ -f "$_INSTALLED_FILE" ]; then
    _EMPTY_CACHE=""
    for _bundle in $_EXPECTED_BUNDLES; do
        _bundle_cache="$_CACHE_DIR/$_bundle"
        if ! [ -d "$_bundle_cache" ]; then
            _EMPTY_CACHE="${_EMPTY_CACHE:+$_EMPTY_CACHE, }$_bundle (missing cache dir)"
        else
            # Use find to check for any regular file anywhere under the bundle dir
            _has_files=$(find "$_bundle_cache" -type f 2>/dev/null | head -1)
            if [ -z "$_has_files" ]; then
                _EMPTY_CACHE="${_EMPTY_CACHE:+$_EMPTY_CACHE, }$_bundle (empty cache dir)"
            fi
        fi
    done
    if [ -n "$_EMPTY_CACHE" ]; then
        _PLUGIN_ISSUES="${_PLUGIN_ISSUES:+$_PLUGIN_ISSUES; }plugin cache missing or empty for: $_EMPTY_CACHE — plugin data may be corrupt, reinstall affected bundles"
    fi
fi

# Surface all plugin issues as a single WARNING
if [ -n "$_PLUGIN_ISSUES" ]; then
    WARNINGS="${WARNINGS:+$WARNINGS;}PLUGIN_INTEGRITY: $_PLUGIN_ISSUES"
fi
