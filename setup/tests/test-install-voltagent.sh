#!/usr/bin/env bash
# Tests for install-voltagent.sh (CFG-137a)
# TDD: written before implementation
source "$(dirname "$0")/test-helpers.sh"

suite_header "Install VoltAgent Marketplace"

SCRIPT="$REPO_ROOT/setup/scripts/install-voltagent.sh"

# ── Helpers ──────────────────────────────────────────────────────────────────

# Build a minimal mock marketplace structure in TEST_TMPDIR/marketplace
# Mirrors the structure of VoltAgent/awesome-claude-code-subagents
create_mock_marketplace() {
    local dest="$1"  # e.g. $TEST_TMPDIR/fake-repo
    mkdir -p "$dest/.claude-plugin"

    # marketplace.json lists two plugins for simplicity
    cat > "$dest/.claude-plugin/marketplace.json" << 'EOF'
{
  "name": "voltagent-subagents",
  "owner": {"name": "VoltAgent Community", "url": "https://github.com/VoltAgent"},
  "metadata": {"version": "1.0.0", "description": "Test marketplace"},
  "plugins": [
    {
      "name": "voltagent-core-dev",
      "source": "./categories/01-core-development",
      "description": "Core dev plugin",
      "version": "1.0.0"
    },
    {
      "name": "voltagent-lang",
      "source": "./categories/02-language-specialists",
      "description": "Language plugin",
      "version": "1.0.0"
    }
  ]
}
EOF

    # Create plugin source directories
    mkdir -p "$dest/categories/01-core-development/.claude-plugin"
    cat > "$dest/categories/01-core-development/.claude-plugin/plugin.json" << 'EOF'
{"name": "voltagent-core-dev", "version": "1.0.0"}
EOF
    echo "# Core Dev" > "$dest/categories/01-core-development/backend-developer.md"

    mkdir -p "$dest/categories/02-language-specialists/.claude-plugin"
    cat > "$dest/categories/02-language-specialists/.claude-plugin/plugin.json" << 'EOF'
{"name": "voltagent-lang", "version": "1.0.0"}
EOF
    echo "# Lang" > "$dest/categories/02-language-specialists/python-pro.md"
}

# Run the script with test config dir and a pre-cloned marketplace (no real git)
run_install() {
    local config_dir="$1"
    local fake_repo="$2"
    shift 2
    INSTALL_VA_CONFIG_DIR="$config_dir" \
    INSTALL_VA_SKIP_CLONE="$fake_repo" \
        bash "$SCRIPT" "$@" 2>&1
}

# ── Tests ────────────────────────────────────────────────────────────────────

# Test 1: Script exits 0 in dry-run mode with no side effects
test_dry_run_exits_zero() {
    local config_dir="$TEST_TMPDIR/config"
    local fake_repo="$TEST_TMPDIR/fake-repo"
    create_mock_marketplace "$fake_repo"
    mkdir -p "$config_dir/plugins"

    local output
    output=$(run_install "$config_dir" "$fake_repo" --dry-run)
    local rc=$?

    assert_eq "0" "$rc" "dry-run should exit 0"
    assert_contains "$output" "DRY RUN" "dry-run output should say DRY RUN"
}
run_test "dry-run exits 0" test_dry_run_exits_zero

# Test 2: Dry-run does NOT clone or create marketplace dir
test_dry_run_no_marketplace_dir() {
    local config_dir="$TEST_TMPDIR/config"
    local fake_repo="$TEST_TMPDIR/fake-repo"
    create_mock_marketplace "$fake_repo"
    mkdir -p "$config_dir/plugins"

    run_install "$config_dir" "$fake_repo" --dry-run >/dev/null 2>&1

    local marketplace_dir="$config_dir/plugins/marketplaces/voltagent-subagents"
    if [[ -d "$marketplace_dir" ]]; then
        printf "${RED}    FAIL: marketplace dir should not exist in dry-run${RESET}\n" >&2
        return 1
    fi
}
run_test "dry-run does not create marketplace directory" test_dry_run_no_marketplace_dir

# Test 3: Normal run creates the marketplace directory
test_creates_marketplace_dir() {
    local config_dir="$TEST_TMPDIR/config"
    local fake_repo="$TEST_TMPDIR/fake-repo"
    create_mock_marketplace "$fake_repo"
    mkdir -p "$config_dir/plugins"

    run_install "$config_dir" "$fake_repo" >/dev/null 2>&1

    assert_dir_exists "$config_dir/plugins/marketplaces/voltagent-subagents" \
        "marketplace dir should exist after install"
}
run_test "creates marketplace directory" test_creates_marketplace_dir

# Test 4: Creates cache directories for each plugin
test_creates_cache_dirs() {
    local config_dir="$TEST_TMPDIR/config"
    local fake_repo="$TEST_TMPDIR/fake-repo"
    create_mock_marketplace "$fake_repo"
    mkdir -p "$config_dir/plugins"

    run_install "$config_dir" "$fake_repo" >/dev/null 2>&1

    assert_dir_exists "$config_dir/plugins/cache/voltagent-subagents/voltagent-core-dev/1.0.0"
    assert_dir_exists "$config_dir/plugins/cache/voltagent-subagents/voltagent-lang/1.0.0"
}
run_test "creates cache directories for all plugins" test_creates_cache_dirs

# Test 5: Cache dir contains plugin files copied from source
test_cache_contains_plugin_files() {
    local config_dir="$TEST_TMPDIR/config"
    local fake_repo="$TEST_TMPDIR/fake-repo"
    create_mock_marketplace "$fake_repo"
    mkdir -p "$config_dir/plugins"

    run_install "$config_dir" "$fake_repo" >/dev/null 2>&1

    assert_file_exists \
        "$config_dir/plugins/cache/voltagent-subagents/voltagent-core-dev/1.0.0/.claude-plugin/plugin.json" \
        "plugin.json should be in cache"
    assert_file_exists \
        "$config_dir/plugins/cache/voltagent-subagents/voltagent-core-dev/1.0.0/backend-developer.md" \
        "plugin content files should be in cache"
}
run_test "cache dirs contain plugin files" test_cache_contains_plugin_files

# Test 6: Registers marketplace in known_marketplaces.json
test_registers_known_marketplace() {
    local config_dir="$TEST_TMPDIR/config"
    local fake_repo="$TEST_TMPDIR/fake-repo"
    create_mock_marketplace "$fake_repo"
    mkdir -p "$config_dir/plugins"

    run_install "$config_dir" "$fake_repo" >/dev/null 2>&1

    local km="$config_dir/plugins/known_marketplaces.json"
    assert_file_exists "$km" "known_marketplaces.json should exist"
    assert_file_contains "$km" "voltagent-subagents"
    assert_file_contains "$km" "VoltAgent/awesome-claude-code-subagents"
}
run_test "registers marketplace in known_marketplaces.json" test_registers_known_marketplace

# Test 7: known_marketplaces.json is valid JSON with correct structure
test_known_marketplaces_valid_json() {
    local config_dir="$TEST_TMPDIR/config"
    local fake_repo="$TEST_TMPDIR/fake-repo"
    create_mock_marketplace "$fake_repo"
    mkdir -p "$config_dir/plugins"

    run_install "$config_dir" "$fake_repo" >/dev/null 2>&1

    local km="$config_dir/plugins/known_marketplaces.json"
    local has_source install_loc
    has_source=$(python3 -c "
import json
d = json.load(open('$km'))
va = d.get('voltagent-subagents', {})
src = va.get('source', {})
print(src.get('source', '') == 'github' and src.get('repo', '') == 'VoltAgent/awesome-claude-code-subagents')
" 2>/dev/null)
    assert_eq "True" "$has_source" "known_marketplaces.json should have correct source"

    install_loc=$(python3 -c "
import json
d = json.load(open('$km'))
print(d.get('voltagent-subagents', {}).get('installLocation', ''))
" 2>/dev/null)
    assert_contains "$install_loc" "voltagent-subagents" "installLocation should contain marketplace name"
}
run_test "known_marketplaces.json has correct structure" test_known_marketplaces_valid_json

# Test 8: Registers plugins in installed_plugins.json
test_registers_installed_plugins() {
    local config_dir="$TEST_TMPDIR/config"
    local fake_repo="$TEST_TMPDIR/fake-repo"
    create_mock_marketplace "$fake_repo"
    mkdir -p "$config_dir/plugins"

    run_install "$config_dir" "$fake_repo" >/dev/null 2>&1

    local ip="$config_dir/plugins/installed_plugins.json"
    assert_file_exists "$ip" "installed_plugins.json should exist"
    assert_file_contains "$ip" "voltagent-core-dev@voltagent-subagents"
    assert_file_contains "$ip" "voltagent-lang@voltagent-subagents"
}
run_test "registers plugins in installed_plugins.json" test_registers_installed_plugins

# Test 9: installed_plugins.json is valid JSON with version 2 format
test_installed_plugins_valid_json() {
    local config_dir="$TEST_TMPDIR/config"
    local fake_repo="$TEST_TMPDIR/fake-repo"
    create_mock_marketplace "$fake_repo"
    mkdir -p "$config_dir/plugins"

    run_install "$config_dir" "$fake_repo" >/dev/null 2>&1

    local ip="$config_dir/plugins/installed_plugins.json"
    local version scope install_path
    version=$(python3 -c "import json; d=json.load(open('$ip')); print(d.get('version',''))")
    assert_eq "2" "$version" "installed_plugins.json should be version 2"

    scope=$(python3 -c "
import json
d = json.load(open('$ip'))
plugin = d.get('plugins', {}).get('voltagent-core-dev@voltagent-subagents', [{}])[0]
print(plugin.get('scope', ''))
")
    assert_eq "user" "$scope" "plugin scope should be 'user'"

    install_path=$(python3 -c "
import json
d = json.load(open('$ip'))
plugin = d.get('plugins', {}).get('voltagent-core-dev@voltagent-subagents', [{}])[0]
print(plugin.get('installPath', ''))
")
    assert_contains "$install_path" "voltagent-core-dev/1.0.0" "installPath should contain plugin name and version"
}
run_test "installed_plugins.json has correct version-2 structure" test_installed_plugins_valid_json

# Test 10: Idempotent — running twice does not duplicate entries
test_idempotent_no_duplicates() {
    local config_dir="$TEST_TMPDIR/config"
    local fake_repo="$TEST_TMPDIR/fake-repo"
    create_mock_marketplace "$fake_repo"
    mkdir -p "$config_dir/plugins"

    run_install "$config_dir" "$fake_repo" >/dev/null 2>&1
    run_install "$config_dir" "$fake_repo" >/dev/null 2>&1

    local ip="$config_dir/plugins/installed_plugins.json"
    # Each plugin key should appear exactly once in plugins map
    local count_core
    count_core=$(python3 -c "
import json
d = json.load(open('$ip'))
plugins = d.get('plugins', {})
print(len(plugins.get('voltagent-core-dev@voltagent-subagents', [])))
")
    assert_eq "1" "$count_core" "idempotent: voltagent-core-dev should have exactly 1 entry"

    local km="$config_dir/plugins/known_marketplaces.json"
    local km_count
    km_count=$(python3 -c "
import json
d = json.load(open('$km'))
print(len([k for k in d if k == 'voltagent-subagents']))
")
    assert_eq "1" "$km_count" "idempotent: known_marketplaces should have exactly 1 voltagent entry"
}
run_test "idempotent — no duplicate entries on second run" test_idempotent_no_duplicates

# Test 11: Idempotent — skips existing cache dirs, does not error
test_idempotent_existing_cache() {
    local config_dir="$TEST_TMPDIR/config"
    local fake_repo="$TEST_TMPDIR/fake-repo"
    create_mock_marketplace "$fake_repo"
    mkdir -p "$config_dir/plugins"

    run_install "$config_dir" "$fake_repo" >/dev/null 2>&1

    # Modify a file in cache to verify it's preserved (idempotent = don't overwrite)
    local sentinel="$config_dir/plugins/cache/voltagent-subagents/voltagent-core-dev/1.0.0/SENTINEL"
    echo "sentinel" > "$sentinel"

    run_install "$config_dir" "$fake_repo" >/dev/null 2>&1

    assert_file_exists "$sentinel" "existing cache dir should not be wiped on second run"
}
run_test "idempotent — preserves existing cache on second run" test_idempotent_existing_cache

# Test 12: Dry-run does NOT write known_marketplaces.json
test_dry_run_no_json_writes() {
    local config_dir="$TEST_TMPDIR/config"
    local fake_repo="$TEST_TMPDIR/fake-repo"
    create_mock_marketplace "$fake_repo"
    mkdir -p "$config_dir/plugins"

    run_install "$config_dir" "$fake_repo" --dry-run >/dev/null 2>&1

    assert_file_not_exists "$config_dir/plugins/known_marketplaces.json" \
        "dry-run should not create known_marketplaces.json"
    assert_file_not_exists "$config_dir/plugins/installed_plugins.json" \
        "dry-run should not create installed_plugins.json"
}
run_test "dry-run does not write JSON files" test_dry_run_no_json_writes

# Test 13: Merges into existing known_marketplaces.json (preserves other entries)
test_merges_known_marketplaces() {
    local config_dir="$TEST_TMPDIR/config"
    local fake_repo="$TEST_TMPDIR/fake-repo"
    create_mock_marketplace "$fake_repo"
    mkdir -p "$config_dir/plugins"

    # Pre-create known_marketplaces.json with existing entry
    cat > "$config_dir/plugins/known_marketplaces.json" << 'EOF'
{
  "claude-plugins-official": {
    "source": {"source": "github", "repo": "anthropics/claude-plugins-official"},
    "installLocation": "/some/path",
    "lastUpdated": "2026-01-01T00:00:00.000Z"
  }
}
EOF

    run_install "$config_dir" "$fake_repo" >/dev/null 2>&1

    local km="$config_dir/plugins/known_marketplaces.json"
    # Both entries should exist
    local count
    count=$(python3 -c "import json; d=json.load(open('$km')); print(len(d))")
    assert_eq "2" "$count" "should have 2 marketplace entries (existing + voltagent)"
    assert_file_contains "$km" "claude-plugins-official"
    assert_file_contains "$km" "voltagent-subagents"
}
run_test "merges voltagent into existing known_marketplaces.json" test_merges_known_marketplaces

# Test 14: Merges into existing installed_plugins.json (preserves other entries)
test_merges_installed_plugins() {
    local config_dir="$TEST_TMPDIR/config"
    local fake_repo="$TEST_TMPDIR/fake-repo"
    create_mock_marketplace "$fake_repo"
    mkdir -p "$config_dir/plugins"

    # Pre-create installed_plugins.json with existing plugin
    cat > "$config_dir/plugins/installed_plugins.json" << 'EOF'
{
  "version": 2,
  "plugins": {
    "some-plugin@claude-plugins-official": [
      {
        "scope": "user",
        "installPath": "/existing/path/1.0.0",
        "version": "1.0.0",
        "installedAt": "2026-01-01T00:00:00.000Z",
        "lastUpdated": "2026-01-01T00:00:00.000Z"
      }
    ]
  }
}
EOF

    run_install "$config_dir" "$fake_repo" >/dev/null 2>&1

    local ip="$config_dir/plugins/installed_plugins.json"
    assert_file_contains "$ip" "some-plugin@claude-plugins-official"
    assert_file_contains "$ip" "voltagent-core-dev@voltagent-subagents"
}
run_test "merges voltagent plugins into existing installed_plugins.json" test_merges_installed_plugins

# Test 15: Verbose flag produces extra output
test_verbose_flag() {
    local config_dir="$TEST_TMPDIR/config"
    local fake_repo="$TEST_TMPDIR/fake-repo"
    create_mock_marketplace "$fake_repo"
    mkdir -p "$config_dir/plugins"

    local verbose_out normal_out
    verbose_out=$(run_install "$config_dir" "$fake_repo" --verbose 2>&1)
    local rc=$?

    assert_eq "0" "$rc" "--verbose should exit 0"
    assert_contains "$verbose_out" "voltagent" "verbose output should mention voltagent"
}
run_test "verbose flag produces output without error" test_verbose_flag

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
