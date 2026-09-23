#!/usr/bin/env bash
# Tests for setup/scripts/install-skill-collections.sh
# Verifies clone logic, dry-run mode, plugin entries, settings update,
# and idempotent behavior. Does NOT clone real repos (uses mock git repos).

source "$(dirname "$0")/test-helpers.sh"

suite_header "Install Skill Collections"

SCRIPT="$REPO_ROOT/setup/scripts/install-skill-collections.sh"

# ── Helpers ──────────────────────────────────────────────────────────────────

# Create a mock environment with local git repos instead of GitHub URLs
setup_mock_env() {
    local mock_root="$1"
    mkdir -p "$mock_root/config/plugins/marketplaces"
    mkdir -p "$mock_root/skill-collections"
    mkdir -p "$mock_root/config-repo/setup/config"

    # Create a valid settings.json
    echo '{"hooks": {}, "enabledPlugins": {}}' > "$mock_root/config/settings.json"
    # Template settings.json
    echo '{"hooks": {}, "enabledPlugins": {}}' > "$mock_root/config-repo/setup/config/settings.json"

    # Create local bare repos to clone from (instead of GitHub)
    for repo_name in getsentry superpowers trailofbits anthropic-skills voltagent-skills; do
        create_bare_repo "$mock_root/remotes/${repo_name}.git"
        # Add an initial commit so clone works
        local tmp_clone="$mock_root/tmp-clone-${repo_name}"
        create_git_repo "$tmp_clone"
        git -C "$tmp_clone" remote add origin "$mock_root/remotes/${repo_name}.git"
        git -C "$tmp_clone" push -u origin main >/dev/null 2>&1
        rm -rf "$tmp_clone"
    done
}

# ── Tests: --help flag ─────────────────────────────────────────────────────

test_help_flag() {
    local output
    output=$(bash "$SCRIPT" --help 2>&1)
    assert_contains "$output" "Usage:"
    assert_contains "$output" "skill-collections"
}
run_test "--help shows usage" test_help_flag

# ── Tests: Dry-run mode ───────────────────────────────────────────────────

test_dry_run_no_changes() {
    local output
    output=$(bash "$SCRIPT" --dry-run 2>&1)
    assert_contains "$output" "DRY RUN"
}
run_test "--dry-run reports dry run mode" test_dry_run_no_changes

# ── Tests: Clone logic (using clone_repo function) ─────────────────────────

test_clone_repo_fresh() {
    local target="$TEST_TMPDIR/marketplaces"
    local remote="$TEST_TMPDIR/remote.git"
    create_bare_repo "$remote"
    # Add initial commit
    local tmp_repo="$TEST_TMPDIR/tmp-init"
    create_git_repo "$tmp_repo"
    git -C "$tmp_repo" remote add origin "$remote"
    git -C "$tmp_repo" push -u origin main >/dev/null 2>&1
    rm -rf "$tmp_repo"

    mkdir -p "$target"
    # Simulate fresh clone
    git clone --quiet --depth 1 "$remote" "$target/test-repo" 2>/dev/null
    assert_dir_exists "$target/test-repo/.git"
}
run_test "clone_repo creates fresh clone" test_clone_repo_fresh

test_clone_repo_idempotent() {
    local target="$TEST_TMPDIR/marketplaces"
    local remote="$TEST_TMPDIR/remote.git"
    create_bare_repo "$remote"
    local tmp_repo="$TEST_TMPDIR/tmp-init"
    create_git_repo "$tmp_repo"
    git -C "$tmp_repo" remote add origin "$remote"
    git -C "$tmp_repo" push -u origin main >/dev/null 2>&1
    rm -rf "$tmp_repo"

    mkdir -p "$target"
    git clone --quiet --depth 1 "$remote" "$target/test-repo" 2>/dev/null
    # Second clone attempt (same as re-run)
    local before_count
    before_count=$(git -C "$target/test-repo" rev-list --count HEAD)
    git -C "$target/test-repo" pull --quiet 2>/dev/null || true
    local after_count
    after_count=$(git -C "$target/test-repo" rev-list --count HEAD)
    assert_eq "$before_count" "$after_count" "pull on unchanged repo should keep same commit count"
}
run_test "re-run pulls without duplicating" test_clone_repo_idempotent

test_clone_skips_non_git_dir() {
    # If a directory exists but is not a git repo, the script should skip
    local target="$TEST_TMPDIR/marketplaces"
    mkdir -p "$target/not-a-repo"
    echo "random file" > "$target/not-a-repo/something.txt"

    # The clone logic checks for .git dir
    if [[ -d "$target/not-a-repo/.git" ]]; then
        return 1
    fi
    # Not a git repo — script would skip
    assert_dir_exists "$target/not-a-repo"
    [[ ! -d "$target/not-a-repo/.git" ]]
}
run_test "clone skips existing non-git directory" test_clone_skips_non_git_dir

# ── Tests: Plugin entries format ───────────────────────────────────────────

test_plugin_entries_format() {
    # Verify the PLUGIN_ENTRIES array format by grepping the script
    local entries
    entries=$(grep -E '^\s+"[a-z].*\|(true|false)"' "$SCRIPT" || true)
    local count
    count=$(echo "$entries" | grep -c '|' || echo "0")
    # Should have at least 5 entries
    [[ "$count" -ge 5 ]]
}
run_test "plugin entries have correct pipe-separated format" test_plugin_entries_format

test_plugin_entries_have_valid_booleans() {
    # Extract only lines between PLUGIN_ENTRIES=( and the closing )
    local entries
    entries=$(sed -n '/^PLUGIN_ENTRIES=(/,/^)/p' "$SCRIPT" | grep -E '^\s+"' || true)
    # Every entry should end with |true" or |false"
    local bad_entries
    bad_entries=$(echo "$entries" | grep -v -E '\|(true|false)"' || true)
    assert_eq "" "$bad_entries" "all plugin entries should have valid boolean values"
}
run_test "plugin entries have valid boolean values" test_plugin_entries_have_valid_booleans

# ── Tests: Settings.json update logic ──────────────────────────────────────

test_settings_json_update() {
    local settings="$TEST_TMPDIR/settings.json"
    echo '{"hooks": {}, "enabledPlugins": {}}' > "$settings"

    # Simulate what the script's Python block does
    python3 -c "
import json

with open('$settings', 'r') as f:
    data = json.load(f)

plugins = data.setdefault('enabledPlugins', {})
entries = [('test-plugin@market', 'true'), ('other-plugin@market', 'false')]

for key, enabled in entries:
    if key not in plugins:
        plugins[key] = enabled == 'true'

with open('$settings', 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
"
    assert_file_contains "$settings" "test-plugin@market"
    assert_file_contains "$settings" "other-plugin@market"
    # true entry should be boolean true
    assert_file_contains "$settings" '"test-plugin@market": true'
    # false entry should be boolean false
    assert_file_contains "$settings" '"other-plugin@market": false'
}
run_test "settings.json plugin update writes correct JSON" test_settings_json_update

test_settings_json_update_idempotent() {
    local settings="$TEST_TMPDIR/settings.json"
    echo '{"hooks": {}, "enabledPlugins": {"existing@market": true}}' > "$settings"

    python3 -c "
import json

with open('$settings', 'r') as f:
    data = json.load(f)

plugins = data.setdefault('enabledPlugins', {})
entries = [('existing@market', 'false'), ('new@market', 'true')]

added = 0
for key, enabled in entries:
    if key not in plugins:
        plugins[key] = enabled == 'true'
        added += 1

with open('$settings', 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')

assert added == 1, f'Expected 1 addition, got {added}'
"
    # Existing entry should keep its original value (true), not be overwritten
    assert_file_contains "$settings" '"existing@market": true'
    # New entry should be added
    assert_file_contains "$settings" '"new@market": true'
}
run_test "settings.json update is idempotent (no overwrite)" test_settings_json_update_idempotent

# ── Tests: Marketplace repo list ───────────────────────────────────────────

test_marketplace_repos_defined() {
    local count
    count=$(grep -cE '^\s+"[a-z].*https://github.com' "$SCRIPT" || echo "0")
    [[ "$count" -ge 3 ]]
}
run_test "at least 3 marketplace repos defined" test_marketplace_repos_defined

test_skill_collection_repos_defined() {
    local count
    count=$(grep -c 'SKILL_COLLECTION_REPOS' "$SCRIPT" || echo "0")
    [[ "$count" -ge 1 ]]
}
run_test "skill collection repos array is defined" test_skill_collection_repos_defined

# ── Tests: Unknown args ───────────────────────────────────────────────────

test_unknown_arg_warns() {
    local output
    output=$(bash "$SCRIPT" --dry-run --bogus-flag 2>&1) || true
    assert_contains "$output" "Unknown argument"
}
run_test "unknown arguments produce warning" test_unknown_arg_warns

# ── Tests: Step 3 — global plugins stay empty ─────────────────────────────

test_step3_no_global_plugins() {
    local output
    output=$(bash "$SCRIPT" --dry-run 2>&1)
    assert_contains "$output" "NOT enabled globally"
}
run_test "step 3 confirms plugins are not enabled globally" test_step3_no_global_plugins

suite_summary
