#!/usr/bin/env bash
# Tests for clean-permissions.sh — removes stale permissions blocks from settings.local.json
source "$(dirname "$0")/test-helpers.sh"

CLEAN_SCRIPT="$REPO_ROOT/setup/scripts/clean-permissions.sh"

suite_header "Clean Permissions Tests"

# ── Core behavior ────────────────────────────────────────────────────────────

test_removes_permissions_block() {
    local slj="$TEST_TMPDIR/project/.claude/settings.local.json"
    mkdir -p "$(dirname "$slj")"
    cat > "$slj" << 'EOF'
{
  "enableAllProjectMcpServers": true,
  "permissions": {
    "allow": [
      "Bash(echo:*)"
    ]
  },
  "enabledMcpjsonServers": ["serena"]
}
EOF

    bash "$CLEAN_SCRIPT" "$TEST_TMPDIR" 2>/dev/null
    assert_file_not_contains "$slj" '"permissions"'
    assert_file_contains "$slj" '"enableAllProjectMcpServers"'
    assert_file_contains "$slj" '"enabledMcpjsonServers"'
}
run_test "removes permissions block, preserves other keys" test_removes_permissions_block

test_no_permissions_block_noop() {
    local slj="$TEST_TMPDIR/project/.claude/settings.local.json"
    mkdir -p "$(dirname "$slj")"
    cat > "$slj" << 'EOF'
{
  "enableAllProjectMcpServers": true,
  "enabledMcpjsonServers": ["serena"]
}
EOF

    local before
    before=$(cat "$slj")
    bash "$CLEAN_SCRIPT" "$TEST_TMPDIR" 2>/dev/null
    local after
    after=$(cat "$slj")
    assert_eq "$before" "$after"
}
run_test "no-op when no permissions block exists" test_no_permissions_block_noop

test_handles_multiple_projects() {
    for proj in alpha beta gamma; do
        local slj="$TEST_TMPDIR/$proj/.claude/settings.local.json"
        mkdir -p "$(dirname "$slj")"
        cat > "$slj" << 'EOF'
{
  "enableAllProjectMcpServers": true,
  "permissions": {
    "allow": ["Bash(cat:*)"]
  }
}
EOF
    done

    bash "$CLEAN_SCRIPT" "$TEST_TMPDIR" 2>/dev/null

    for proj in alpha beta gamma; do
        local slj="$TEST_TMPDIR/$proj/.claude/settings.local.json"
        assert_file_not_contains "$slj" '"permissions"'
        assert_file_contains "$slj" '"enableAllProjectMcpServers"'
    done
}
run_test "cleans permissions from multiple projects" test_handles_multiple_projects

test_skips_files_without_permissions() {
    # One with permissions, one without
    local slj1="$TEST_TMPDIR/dirty/.claude/settings.local.json"
    local slj2="$TEST_TMPDIR/clean/.claude/settings.local.json"
    mkdir -p "$(dirname "$slj1")" "$(dirname "$slj2")"

    cat > "$slj1" << 'EOF'
{
  "permissions": { "allow": ["Bash(ls:*)"] },
  "enabledMcpjsonServers": ["serena"]
}
EOF
    cat > "$slj2" << 'EOF'
{
  "enabledMcpjsonServers": ["serena"]
}
EOF

    local clean_before
    clean_before=$(cat "$slj2")
    bash "$CLEAN_SCRIPT" "$TEST_TMPDIR" 2>/dev/null
    assert_file_not_contains "$slj1" '"permissions"'
    local clean_after
    clean_after=$(cat "$slj2")
    assert_eq "$clean_before" "$clean_after"
}
run_test "only modifies files that have permissions blocks" test_skips_files_without_permissions

test_reports_cleaned_count() {
    for proj in a b; do
        local slj="$TEST_TMPDIR/$proj/.claude/settings.local.json"
        mkdir -p "$(dirname "$slj")"
        cat > "$slj" << 'EOF'
{
  "permissions": { "allow": [] }
}
EOF
    done

    local output
    output=$(bash "$CLEAN_SCRIPT" "$TEST_TMPDIR" 2>&1)
    assert_contains "$output" "2"
}
run_test "reports number of cleaned files" test_reports_cleaned_count

test_no_output_when_nothing_to_clean() {
    local slj="$TEST_TMPDIR/proj/.claude/settings.local.json"
    mkdir -p "$(dirname "$slj")"
    echo '{"enabledMcpjsonServers": []}' > "$slj"

    local output
    output=$(bash "$CLEAN_SCRIPT" "$TEST_TMPDIR" 2>&1)
    assert_eq "" "$output"
}
run_test "silent when nothing to clean" test_no_output_when_nothing_to_clean

test_exits_zero_always() {
    # Even with no files found
    assert_exit_code 0 bash "$CLEAN_SCRIPT" "$TEST_TMPDIR"
}
run_test "exits 0 even when no settings files found" test_exits_zero_always

test_default_scans_home() {
    # When called without args, should default to $HOME
    # We can't test the actual $HOME behavior in isolation, but verify it runs
    assert_exit_code 0 bash "$CLEAN_SCRIPT"
}
run_test "runs without arguments (defaults to HOME)" test_default_scans_home

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
