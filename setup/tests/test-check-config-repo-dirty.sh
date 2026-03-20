#!/usr/bin/env bash
# Tests for check 18: config-repo-dirty (uncommitted changes + ghost session detection)
# TDD: these tests are written BEFORE the implementation

source "$(dirname "$0")/test-helpers.sh"
source "$(dirname "$0")/test-check-helpers.sh"

suite_header "config-check.sh: config repo dirty state (check 18)"

# ── Test 1: Clean repo produces no warning ──

test_clean_repo_no_warning() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    create_mock_plugin_files "$mock_home"
    mkdir -p "$config_repo/global/hooks"
    echo "# hook" > "$config_repo/global/hooks/test-hook.sh"
    (cd "$config_repo" && git add -A && git commit -m "add hook" >/dev/null 2>&1)

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    if [[ "$output" == *"CONFIG_REPO_DIRTY"* ]]; then
        echo "FAIL: clean repo should NOT produce CONFIG_REPO_DIRTY warning" >&2
        echo "Output: $output" >&2
        return 1
    fi
    if [[ "$output" == *"GHOST_SESSION"* ]]; then
        echo "FAIL: clean repo should NOT produce GHOST_SESSION warning" >&2
        return 1
    fi
}
run_test "clean repo: no CONFIG_REPO_DIRTY or GHOST_SESSION warning" test_clean_repo_no_warning

# ── Test 2: Uncommitted changes in global/hooks/ produce warning ──

test_uncommitted_hooks_warning() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    create_mock_plugin_files "$mock_home"
    mkdir -p "$config_repo/global/hooks"
    echo "# original" > "$config_repo/global/hooks/afd-relay.sh"
    (cd "$config_repo" && git add -A && git commit -m "add hook" >/dev/null 2>&1)

    # Make uncommitted edit
    echo "# modified" > "$config_repo/global/hooks/afd-relay.sh"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "CONFIG_REPO_DIRTY" "should warn about dirty config repo"
    assert_contains "$output" "afd-relay.sh" "should list the dirty file"
}
run_test "uncommitted hook edits: produces CONFIG_REPO_DIRTY warning" test_uncommitted_hooks_warning

# ── Test 3: Uncommitted changes in global/ (non-hooks) produce warning ──

test_uncommitted_global_warning() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    create_mock_plugin_files "$mock_home"
    mkdir -p "$config_repo/global/foundation"
    echo "# original" > "$config_repo/global/foundation/test.md"
    (cd "$config_repo" && git add -A && git commit -m "add foundation" >/dev/null 2>&1)

    echo "# modified" > "$config_repo/global/foundation/test.md"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "CONFIG_REPO_DIRTY" "should warn about dirty global/ files"
}
run_test "uncommitted global/ edits: produces CONFIG_REPO_DIRTY warning" test_uncommitted_global_warning

# ── Test 4: Staged but uncommitted changes produce warning ──

test_staged_changes_warning() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    create_mock_plugin_files "$mock_home"
    mkdir -p "$config_repo/global/hooks"
    echo "# original" > "$config_repo/global/hooks/test-hook.sh"
    (cd "$config_repo" && git add -A && git commit -m "add hook" >/dev/null 2>&1)

    echo "# staged change" > "$config_repo/global/hooks/test-hook.sh"
    (cd "$config_repo" && git add global/hooks/test-hook.sh)

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "CONFIG_REPO_DIRTY" "should warn about staged changes"
}
run_test "staged but uncommitted changes: produces CONFIG_REPO_DIRTY warning" test_staged_changes_warning

# ── Test 5: Changes outside global/ (e.g. backlog.md) also produce warning ──

test_non_global_changes_warning() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    create_mock_plugin_files "$mock_home"
    echo "# backlog" > "$config_repo/backlog.md"
    (cd "$config_repo" && git add -A && git commit -m "add backlog" >/dev/null 2>&1)

    echo "# modified backlog" > "$config_repo/backlog.md"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "CONFIG_REPO_DIRTY" "should warn about any uncommitted changes"
}
run_test "non-global uncommitted changes: also produces CONFIG_REPO_DIRTY" test_non_global_changes_warning

# ── Test 6: Ghost session detection — blank session + dirty repo ──

test_ghost_session_detection() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$config_repo"  # project IS the config repo
    mkdir -p "$mock_home/.claude"

    create_mock_config_repo "$config_repo"
    create_mock_plugin_files "$mock_home"

    # Create blank session-context.md (freshly rotated = no session goal)
    cat > "$config_repo/session-context.md" << 'EOF'
# Session Context

## Session Info
- **Last Updated**: 2026-03-19T16:28:10+01:00 (rotated)
- **Machine**:
- **Working Directory**:
- **Session Goal**:

## Current State
- **Active Task**:
- **Progress** (use `- [x]` checkbox for each completed item):
- **Pending**:

## Key Decisions

## Recovery Instructions
EOF
    (cd "$config_repo" && git add -A && git commit -m "rotated session" >/dev/null 2>&1)

    # Now make uncommitted changes (ghost session left these)
    mkdir -p "$config_repo/global/hooks"
    echo "# ghost edit" > "$config_repo/global/hooks/some-hook.sh"
    (cd "$config_repo" && git add global/hooks/some-hook.sh && git commit -m "add hook" >/dev/null 2>&1)
    echo "# ghost modified" > "$config_repo/global/hooks/some-hook.sh"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "GHOST_SESSION" "should detect ghost session (blank session + dirty repo)"
}
run_test "ghost session: blank session-context + dirty repo triggers GHOST_SESSION" test_ghost_session_detection

# ── Test 7: Dirty repo with active session does NOT trigger ghost ──

test_active_session_no_ghost() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$config_repo"
    mkdir -p "$mock_home/.claude"

    create_mock_config_repo "$config_repo"
    create_mock_plugin_files "$mock_home"

    # Create session-context.md WITH a goal (active session)
    cat > "$config_repo/session-context.md" << 'EOF'
# Session Context

## Session Info
- **Last Updated**: 2026-03-19T16:28:10+01:00
- **Machine**: Steam Deck
- **Working Directory**: /home/deck/cfg-agent-fleet
- **Session Goal**: Working on hook improvements

## Current State
- **Active Task**: editing hooks
EOF
    mkdir -p "$config_repo/global/hooks"
    echo "# hook" > "$config_repo/global/hooks/test.sh"
    (cd "$config_repo" && git add -A && git commit -m "session state" >/dev/null 2>&1)

    # Make uncommitted changes
    echo "# modified" > "$config_repo/global/hooks/test.sh"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    # Should still warn about dirty, but NOT ghost
    assert_contains "$output" "CONFIG_REPO_DIRTY" "should still warn about dirty repo"
    if [[ "$output" == *"GHOST_SESSION"* ]]; then
        echo "FAIL: active session should NOT trigger GHOST_SESSION" >&2
        return 1
    fi
}
run_test "active session + dirty repo: CONFIG_REPO_DIRTY but no GHOST_SESSION" test_active_session_no_ghost

# ── Test 8: Untracked files do NOT trigger warning ──

test_untracked_files_no_warning() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    create_mock_plugin_files "$mock_home"

    # Add an untracked file (not modified tracked file)
    echo "temp" > "$config_repo/tmp-scratch.txt"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    if [[ "$output" == *"CONFIG_REPO_DIRTY"* ]]; then
        echo "FAIL: untracked files should NOT trigger CONFIG_REPO_DIRTY" >&2
        return 1
    fi
}
run_test "untracked files only: no CONFIG_REPO_DIRTY warning" test_untracked_files_no_warning

# ── Test 9: Warning includes file count ──

test_warning_includes_count() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    create_mock_plugin_files "$mock_home"
    mkdir -p "$config_repo/global/hooks"
    echo "# a" > "$config_repo/global/hooks/hook-a.sh"
    echo "# b" > "$config_repo/global/hooks/hook-b.sh"
    echo "# c" > "$config_repo/global/hooks/hook-c.sh"
    (cd "$config_repo" && git add -A && git commit -m "add hooks" >/dev/null 2>&1)

    echo "# modified a" > "$config_repo/global/hooks/hook-a.sh"
    echo "# modified b" > "$config_repo/global/hooks/hook-b.sh"
    echo "# modified c" > "$config_repo/global/hooks/hook-c.sh"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "3 uncommitted file(s)" "should include count of dirty files"
}
run_test "dirty file count: warning shows number of uncommitted files" test_warning_includes_count

# ── Test 10: Collect-uncommitted marker detection ──

test_collect_marker_detection() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    create_mock_plugin_files "$mock_home"

    # Create the marker file that sync.sh collect would write
    cat > "$config_repo/.collect-uncommitted-hooks" << 'EOF'
timestamp=2026-03-19T15:30:00Z
files=afd-relay.sh afk-deactivate.sh config-auto-sync.sh
EOF

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "COLLECT_BLOCKED" "should surface collect marker warning"
    assert_contains "$output" "afd-relay.sh" "should list blocked files from marker"
}
run_test "collect-uncommitted marker: surfaces COLLECT_BLOCKED warning" test_collect_marker_detection

suite_summary
