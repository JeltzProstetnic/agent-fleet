#!/usr/bin/env bash
# Tests for global/hooks/checks/11-plugin-integrity.sh
# TDD: write tests first, then implement.
#
# The check sources into config-check.sh's shared variable environment.
# We simulate that environment by setting the shared vars directly and
# sourcing the check file in a subshell.

source "$(dirname "$0")/test-helpers.sh"

CHECK_SCRIPT="$REPO_ROOT/global/hooks/checks/11-plugin-integrity.sh"

suite_header "11-plugin-integrity.sh (VoltAgent plugin integrity)"

# -- Helpers -------------------------------------------------------------------

# Run the check in a subshell with controlled shared variables.
# Args:
#   $1 -- CC_MIRROR_DIR (pointing at our mock)
#   $2 -- settings.json path (optional override; defaults to $1/config/settings.json)
# Outputs the WARNINGS and INBOX_MSG produced by the check, separated by "|||"
run_check() {
    local cc_mirror_dir="$1"
    local settings_file="${2:-$cc_mirror_dir/config/settings.json}"

    # Run in a subshell so sourcing the check doesn't pollute our process
    (
        export WARNINGS=""
        export INBOX_MSG=""
        export CONFIG_REPO="$REPO_ROOT"
        export SETTINGS_FILE="$settings_file"
        export CC_MIRROR_DIR="$cc_mirror_dir"
        export PROJECT_DIR="/tmp/test-project"
        export PROJECT_ROOT="$REPO_ROOT"

        # Source the check (it modifies WARNINGS and INBOX_MSG)
        # shellcheck source=/dev/null
        source "$CHECK_SCRIPT" 2>/dev/null

        printf '%s|||%s' "$WARNINGS" "$INBOX_MSG"
    )
}

# Extract just the WARNINGS part from run_check output
get_warnings() {
    echo "${1%%|||*}"
}

# Extract just the INBOX_MSG part from run_check output
get_inbox() {
    echo "${1##*|||}"
}

# Create a complete mock plugin environment with all expected files
create_full_mock_env() {
    local base="$1"

    # Directory structure mirrors real CC_MIRROR_DIR
    local plugins_dir="$base/config/plugins"
    mkdir -p "$plugins_dir/cache"

    # settings.json with enabledPlugins: {} (correct)
    cat > "$base/config/settings.json" <<'EOF'
{
  "enabledPlugins": {},
  "spinnerTipsEnabled": false
}
EOF

    # known_marketplaces.json with voltagent-subagents present
    cat > "$plugins_dir/known_marketplaces.json" <<'EOF'
{
  "claude-plugins-official": {
    "source": { "source": "github", "repo": "anthropics/claude-plugins-official" },
    "installLocation": "/fake/cache/claude-plugins-official",
    "lastUpdated": "2026-01-01T00:00:00.000Z"
  },
  "voltagent-subagents": {
    "source": { "source": "github", "repo": "VoltAgent/awesome-claude-code-subagents" },
    "installLocation": "/fake/cache/voltagent-subagents",
    "lastUpdated": "2026-01-01T00:00:00.000Z"
  }
}
EOF

    # installed_plugins.json with all 10 expected bundles
    cat > "$plugins_dir/installed_plugins.json" <<'EOF'
{
  "version": 2,
  "plugins": {
    "voltagent-lang@voltagent-subagents": [
      { "scope": "user", "installPath": "/fake/cache/voltagent-lang/1.0.0", "version": "1.0.0", "installedAt": "2026-01-01T00:00:00.000Z", "lastUpdated": "2026-01-01T00:00:00.000Z" }
    ],
    "voltagent-infra@voltagent-subagents": [
      { "scope": "user", "installPath": "/fake/cache/voltagent-infra/1.0.0", "version": "1.0.0", "installedAt": "2026-01-01T00:00:00.000Z", "lastUpdated": "2026-01-01T00:00:00.000Z" }
    ],
    "voltagent-core-dev@voltagent-subagents": [
      { "scope": "user", "installPath": "/fake/cache/voltagent-core-dev/1.0.0", "version": "1.0.0", "installedAt": "2026-01-01T00:00:00.000Z", "lastUpdated": "2026-01-01T00:00:00.000Z" }
    ],
    "voltagent-qa-sec@voltagent-subagents": [
      { "scope": "user", "installPath": "/fake/cache/voltagent-qa-sec/1.0.0", "version": "1.0.0", "installedAt": "2026-01-01T00:00:00.000Z", "lastUpdated": "2026-01-01T00:00:00.000Z" }
    ],
    "voltagent-data-ai@voltagent-subagents": [
      { "scope": "user", "installPath": "/fake/cache/voltagent-data-ai/1.0.0", "version": "1.0.0", "installedAt": "2026-01-01T00:00:00.000Z", "lastUpdated": "2026-01-01T00:00:00.000Z" }
    ],
    "voltagent-dev-exp@voltagent-subagents": [
      { "scope": "user", "installPath": "/fake/cache/voltagent-dev-exp/1.0.0", "version": "1.0.0", "installedAt": "2026-01-01T00:00:00.000Z", "lastUpdated": "2026-01-01T00:00:00.000Z" }
    ],
    "voltagent-domains@voltagent-subagents": [
      { "scope": "user", "installPath": "/fake/cache/voltagent-domains/1.0.0", "version": "1.0.0", "installedAt": "2026-01-01T00:00:00.000Z", "lastUpdated": "2026-01-01T00:00:00.000Z" }
    ],
    "voltagent-biz@voltagent-subagents": [
      { "scope": "user", "installPath": "/fake/cache/voltagent-biz/1.0.0", "version": "1.0.0", "installedAt": "2026-01-01T00:00:00.000Z", "lastUpdated": "2026-01-01T00:00:00.000Z" }
    ],
    "voltagent-meta@voltagent-subagents": [
      { "scope": "user", "installPath": "/fake/cache/voltagent-meta/1.0.0", "version": "1.0.0", "installedAt": "2026-01-01T00:00:00.000Z", "lastUpdated": "2026-01-01T00:00:00.000Z" }
    ],
    "voltagent-research@voltagent-subagents": [
      { "scope": "user", "installPath": "/fake/cache/voltagent-research/1.0.0", "version": "1.0.0", "installedAt": "2026-01-01T00:00:00.000Z", "lastUpdated": "2026-01-01T00:00:00.000Z" }
    ]
  }
}
EOF

    # Create cache subdirectories for each bundle
    for bundle in voltagent-lang voltagent-infra voltagent-core-dev voltagent-qa-sec \
                  voltagent-data-ai voltagent-dev-exp voltagent-domains voltagent-biz \
                  voltagent-meta voltagent-research; do
        mkdir -p "$plugins_dir/cache/voltagent-subagents/$bundle/1.0.0"
        touch "$plugins_dir/cache/voltagent-subagents/$bundle/1.0.0/plugin.yaml"
    done
}

# -- Tests ---------------------------------------------------------------------

# Test 1: Happy path -- no warnings when everything is correct
test_all_good_no_warnings() {
    local base="$TEST_TMPDIR/cc-mirror"
    create_full_mock_env "$base"

    local result
    result=$(run_check "$base")
    local warnings
    warnings=$(get_warnings "$result")

    assert_eq "" "$warnings" "should produce no warnings when all plugins present and enabledPlugins empty"
}
run_test "happy path: no warnings when all plugins installed and enabledPlugins empty" test_all_good_no_warnings

# Test 2: Missing known_marketplaces.json -- warn that marketplace is not registered
test_marketplace_file_missing() {
    local base="$TEST_TMPDIR/cc-mirror"
    create_full_mock_env "$base"
    rm "$base/config/plugins/known_marketplaces.json"

    local result
    result=$(run_check "$base")
    local warnings
    warnings=$(get_warnings "$result")

    assert_contains "$warnings" "PLUGIN" "should contain PLUGIN warning"
    assert_contains "$warnings" "voltagent-subagents" "should mention the missing marketplace"
}
run_test "marketplace missing: warns when known_marketplaces.json absent" test_marketplace_file_missing

# Test 3: voltagent-subagents not in known_marketplaces.json
test_marketplace_not_registered() {
    local base="$TEST_TMPDIR/cc-mirror"
    create_full_mock_env "$base"

    # Overwrite to only have the official marketplace, not voltagent
    cat > "$base/config/plugins/known_marketplaces.json" <<'EOF'
{
  "claude-plugins-official": {
    "source": { "source": "github", "repo": "anthropics/claude-plugins-official" },
    "installLocation": "/fake/cache/official",
    "lastUpdated": "2026-01-01T00:00:00.000Z"
  }
}
EOF

    local result
    result=$(run_check "$base")
    local warnings
    warnings=$(get_warnings "$result")

    assert_contains "$warnings" "PLUGIN" "should contain PLUGIN warning"
    assert_contains "$warnings" "voltagent-subagents" "should name the missing marketplace"
    assert_contains "$warnings" "market" "should mention marketplace context"
}
run_test "marketplace not registered: warns when voltagent-subagents absent from known_marketplaces.json" test_marketplace_not_registered

# Test 4: Missing installed_plugins.json -- warn about missing plugins
test_installed_plugins_file_missing() {
    local base="$TEST_TMPDIR/cc-mirror"
    create_full_mock_env "$base"
    rm "$base/config/plugins/installed_plugins.json"

    local result
    result=$(run_check "$base")
    local warnings
    warnings=$(get_warnings "$result")

    assert_contains "$warnings" "PLUGIN" "should contain PLUGIN warning"
    assert_contains "$warnings" "install" "should mention installation issue"
}
run_test "installed_plugins.json missing: warns when file is absent" test_installed_plugins_file_missing

# Test 5: One plugin bundle missing from installed_plugins.json
test_one_plugin_bundle_missing() {
    local base="$TEST_TMPDIR/cc-mirror"
    create_full_mock_env "$base"

    # Remove voltagent-research from installed_plugins.json
    cat > "$base/config/plugins/installed_plugins.json" <<'EOF'
{
  "version": 2,
  "plugins": {
    "voltagent-lang@voltagent-subagents": [
      { "scope": "user", "installPath": "/fake", "version": "1.0.0", "installedAt": "2026-01-01T00:00:00.000Z", "lastUpdated": "2026-01-01T00:00:00.000Z" }
    ],
    "voltagent-infra@voltagent-subagents": [
      { "scope": "user", "installPath": "/fake", "version": "1.0.0", "installedAt": "2026-01-01T00:00:00.000Z", "lastUpdated": "2026-01-01T00:00:00.000Z" }
    ],
    "voltagent-core-dev@voltagent-subagents": [
      { "scope": "user", "installPath": "/fake", "version": "1.0.0", "installedAt": "2026-01-01T00:00:00.000Z", "lastUpdated": "2026-01-01T00:00:00.000Z" }
    ],
    "voltagent-qa-sec@voltagent-subagents": [
      { "scope": "user", "installPath": "/fake", "version": "1.0.0", "installedAt": "2026-01-01T00:00:00.000Z", "lastUpdated": "2026-01-01T00:00:00.000Z" }
    ],
    "voltagent-data-ai@voltagent-subagents": [
      { "scope": "user", "installPath": "/fake", "version": "1.0.0", "installedAt": "2026-01-01T00:00:00.000Z", "lastUpdated": "2026-01-01T00:00:00.000Z" }
    ],
    "voltagent-dev-exp@voltagent-subagents": [
      { "scope": "user", "installPath": "/fake", "version": "1.0.0", "installedAt": "2026-01-01T00:00:00.000Z", "lastUpdated": "2026-01-01T00:00:00.000Z" }
    ],
    "voltagent-domains@voltagent-subagents": [
      { "scope": "user", "installPath": "/fake", "version": "1.0.0", "installedAt": "2026-01-01T00:00:00.000Z", "lastUpdated": "2026-01-01T00:00:00.000Z" }
    ],
    "voltagent-biz@voltagent-subagents": [
      { "scope": "user", "installPath": "/fake", "version": "1.0.0", "installedAt": "2026-01-01T00:00:00.000Z", "lastUpdated": "2026-01-01T00:00:00.000Z" }
    ],
    "voltagent-meta@voltagent-subagents": [
      { "scope": "user", "installPath": "/fake", "version": "1.0.0", "installedAt": "2026-01-01T00:00:00.000Z", "lastUpdated": "2026-01-01T00:00:00.000Z" }
    ]
  }
}
EOF

    local result
    result=$(run_check "$base")
    local warnings
    warnings=$(get_warnings "$result")

    assert_contains "$warnings" "PLUGIN" "should contain PLUGIN warning"
    assert_contains "$warnings" "voltagent-research" "should name the missing bundle"
}
run_test "plugin bundle missing: warns when voltagent-research missing from installed_plugins.json" test_one_plugin_bundle_missing

# Test 6: enabledPlugins is non-empty -- token budget violation
test_enabled_plugins_non_empty() {
    local base="$TEST_TMPDIR/cc-mirror"
    create_full_mock_env "$base"

    # Overwrite settings.json with non-empty enabledPlugins
    cat > "$base/config/settings.json" <<'EOF'
{
  "enabledPlugins": {
    "voltagent-lang@voltagent-subagents": true,
    "voltagent-infra@voltagent-subagents": true
  },
  "spinnerTipsEnabled": false
}
EOF

    local result
    result=$(run_check "$base")
    local warnings
    warnings=$(get_warnings "$result")

    assert_contains "$warnings" "PLUGIN" "should contain PLUGIN warning"
    assert_contains "$warnings" "enabledPlugins" "should mention enabledPlugins"
    assert_contains "$warnings" "token" "should mention token budget"
}
run_test "enabledPlugins non-empty: warns about token budget violation" test_enabled_plugins_non_empty

# Test 7: settings.json missing -- should not crash (SETTINGS_FILE might not exist)
test_settings_file_missing() {
    local base="$TEST_TMPDIR/cc-mirror"
    create_full_mock_env "$base"
    rm "$base/config/settings.json"

    # Should not crash; just skip the enabledPlugins check silently
    local result
    result=$(run_check "$base")

    local warnings
    warnings=$(get_warnings "$result")

    assert_not_contains "$warnings" "enabledPlugins" "should not warn about enabledPlugins when settings.json missing"
}
run_test "settings.json missing: no crash, no enabledPlugins warning" test_settings_file_missing

# Test 8: Plugin cache directory missing for an installed bundle
test_cache_dir_missing() {
    local base="$TEST_TMPDIR/cc-mirror"
    create_full_mock_env "$base"

    # Remove a cache directory for voltagent-research
    rm -rf "$base/config/plugins/cache/voltagent-subagents/voltagent-research"

    local result
    result=$(run_check "$base")
    local warnings
    warnings=$(get_warnings "$result")

    assert_contains "$warnings" "PLUGIN" "should contain PLUGIN warning"
    assert_contains "$warnings" "cache" "should mention cache issue"
    assert_contains "$warnings" "voltagent-research" "should name the bundle with missing cache"
}
run_test "cache dir missing: warns when plugin cache directory absent" test_cache_dir_missing

# Test 9: Plugin cache directory exists but is empty (no files)
test_cache_dir_empty() {
    local base="$TEST_TMPDIR/cc-mirror"
    create_full_mock_env "$base"

    # Remove contents of cache dir for voltagent-biz but keep the directory
    rm -f "$base/config/plugins/cache/voltagent-subagents/voltagent-biz/1.0.0/plugin.yaml"
    # The 1.0.0 dir still exists but is empty

    local result
    result=$(run_check "$base")
    local warnings
    warnings=$(get_warnings "$result")

    assert_contains "$warnings" "PLUGIN" "should contain PLUGIN warning"
    assert_contains "$warnings" "cache" "should mention cache"
    assert_contains "$warnings" "voltagent-biz" "should name the bundle with empty cache"
}
run_test "cache dir empty: warns when plugin cache directory has no files" test_cache_dir_empty

# Test 10: Multiple failures produce a single consolidated warning (not multiple)
test_multiple_failures_consolidated() {
    local base="$TEST_TMPDIR/cc-mirror"
    create_full_mock_env "$base"

    # Both marketplace missing AND enabledPlugins non-empty
    rm "$base/config/plugins/known_marketplaces.json"
    cat > "$base/config/settings.json" <<'EOF'
{
  "enabledPlugins": { "voltagent-lang@voltagent-subagents": true },
  "spinnerTipsEnabled": false
}
EOF

    local result
    result=$(run_check "$base")
    local warnings
    warnings=$(get_warnings "$result")

    # Should have combined issues mentioned
    assert_contains "$warnings" "PLUGIN" "should contain PLUGIN warning"
    assert_contains "$warnings" "voltagent-subagents" "should mention marketplace issue"
    assert_contains "$warnings" "enabledPlugins" "should mention enabledPlugins issue"
}
run_test "multiple failures: consolidated warning message" test_multiple_failures_consolidated

# -- Summary -------------------------------------------------------------------
suite_summary
