#!/usr/bin/env bash
# Tests for setup/scripts/plugin-inventory.sh
source "$(dirname "$0")/test-helpers.sh"

suite_header "Plugin Inventory"

SCRIPT="$REPO_ROOT/setup/scripts/plugin-inventory.sh"

# ── Tests ────────────────────────────────────────────────────────────────────

test_script_runs_without_error() {
    local output
    output=$(bash "$SCRIPT" 2>&1)
    local rc=$?
    assert_eq "0" "$rc" "script should exit 0"
    # Should produce some output
    [[ -n "$output" ]] || { echo "    No output produced" >&2; return 1; }
}
run_test "script runs without error on current machine" test_script_runs_without_error

test_json_flag_produces_valid_json() {
    local output
    output=$(bash "$SCRIPT" --json 2>&1)
    local rc=$?
    assert_eq "0" "$rc" "script should exit 0 with --json"
    # Validate JSON
    echo "$output" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null
    local jrc=$?
    assert_eq "0" "$jrc" "--json output should be valid JSON"
}
run_test "--json flag produces valid JSON" test_json_flag_produces_valid_json

test_reports_marketplace_count() {
    local output
    output=$(bash "$SCRIPT" 2>&1)
    # Should mention marketplace(s) — either "0 marketplaces" or "N marketplace(s)"
    assert_contains "$output" "marketplace" "output should mention marketplaces"
}
run_test "reports marketplace count" test_reports_marketplace_count

test_reports_zero_enabled_when_empty() {
    # Create a fake config with empty enabledPlugins
    local config_dir="$TEST_TMPDIR/config"
    mkdir -p "$config_dir"
    cat > "$config_dir/settings.json" << 'EOF'
{
  "enabledPlugins": {}
}
EOF

    local output
    output=$(PLUGIN_INV_CONFIG_DIR="$config_dir" bash "$SCRIPT" 2>&1)
    assert_contains "$output" "0 enabled" "should report 0 enabled plugins"
}
run_test "reports 0 enabled plugins when enabledPlugins is empty" test_reports_zero_enabled_when_empty

test_reports_enabled_plugins_count() {
    local config_dir="$TEST_TMPDIR/config"
    mkdir -p "$config_dir"
    cat > "$config_dir/settings.json" << 'EOF'
{
  "enabledPlugins": {
    "plugin-a@marketplace-1": true,
    "plugin-b@marketplace-1": false
  }
}
EOF

    local output
    output=$(PLUGIN_INV_CONFIG_DIR="$config_dir" bash "$SCRIPT" 2>&1)
    assert_contains "$output" "2 enabled" "should report 2 enabled plugins"
}
run_test "reports correct enabled plugins count" test_reports_enabled_plugins_count

test_json_has_required_fields() {
    local config_dir="$TEST_TMPDIR/config"
    mkdir -p "$config_dir/plugins/marketplaces/test-marketplace/external_plugins/test-plugin"
    echo '{}' > "$config_dir/plugins/marketplaces/test-marketplace/external_plugins/test-plugin/plugin.json"
    cat > "$config_dir/settings.json" << 'EOF'
{
  "enabledPlugins": {}
}
EOF

    local output
    output=$(PLUGIN_INV_CONFIG_DIR="$config_dir" bash "$SCRIPT" --json 2>&1)

    # Check required JSON fields
    local has_marketplaces has_enabled has_global_status
    has_marketplaces=$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print('marketplaces' in d)")
    has_enabled=$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print('enabled_plugins' in d)")
    has_global_status=$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print('global_enablement' in d)")

    assert_eq "True" "$has_marketplaces" "JSON should have 'marketplaces' field"
    assert_eq "True" "$has_enabled" "JSON should have 'enabled_plugins' field"
    assert_eq "True" "$has_global_status" "JSON should have 'global_enablement' field"
}
run_test "JSON output has required fields" test_json_has_required_fields

test_detects_marketplace_directories() {
    local config_dir="$TEST_TMPDIR/config"
    mkdir -p "$config_dir/plugins/marketplaces/marketplace-alpha/external_plugins/plug-a"
    mkdir -p "$config_dir/plugins/marketplaces/marketplace-beta/external_plugins/plug-b"
    mkdir -p "$config_dir/plugins/marketplaces/marketplace-beta/external_plugins/plug-c"
    cat > "$config_dir/settings.json" << 'EOF'
{ "enabledPlugins": {} }
EOF

    local output
    output=$(PLUGIN_INV_CONFIG_DIR="$config_dir" bash "$SCRIPT" 2>&1)
    assert_contains "$output" "2 marketplace" "should find 2 marketplaces"
}
run_test "detects multiple marketplace directories" test_detects_marketplace_directories

test_reports_global_clean_status() {
    local config_dir="$TEST_TMPDIR/config"
    mkdir -p "$config_dir"
    cat > "$config_dir/settings.json" << 'EOF'
{ "enabledPlugins": {} }
EOF

    local output
    output=$(PLUGIN_INV_CONFIG_DIR="$config_dir" bash "$SCRIPT" 2>&1)
    assert_contains "$output" "CLEAN" "empty enabledPlugins should report CLEAN"
}
run_test "reports global CLEAN status when enabledPlugins is empty" test_reports_global_clean_status

test_reports_global_warning_status() {
    local config_dir="$TEST_TMPDIR/config"
    mkdir -p "$config_dir"
    cat > "$config_dir/settings.json" << 'EOF'
{
  "enabledPlugins": {
    "some-plugin@some-marketplace": true
  }
}
EOF

    local output
    output=$(PLUGIN_INV_CONFIG_DIR="$config_dir" bash "$SCRIPT" 2>&1)
    assert_contains "$output" "WARNING" "non-empty enabledPlugins should report WARNING"
}
run_test "reports global WARNING status when enabledPlugins is non-empty" test_reports_global_warning_status

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
