#!/usr/bin/env bash
# Tests for cfg-boundary-guard.sh PreToolUse hook
# Verifies that non-cfg projects cannot write to ~/.claude/ or ~/cfg-agent-fleet/global/

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-harness.sh"
source "$SCRIPT_DIR/test-helpers.sh"

HOOK="$SCRIPT_DIR/../../global/hooks/cfg-boundary-guard.sh"

# Helper: simulate a PreToolUse hook call
# Captures both stdout and stderr; returns exit code
run_guard() {
    local tool_name="$1"
    local file_path="$2"
    local project_dir="$3"
    local mock_home="$4"

    local input
    if [ "$tool_name" = "Write" ]; then
        input="{\"tool_name\":\"$tool_name\",\"tool_input\":{\"file_path\":\"$file_path\",\"content\":\"test\"}}"
    elif [ "$tool_name" = "Edit" ]; then
        input="{\"tool_name\":\"$tool_name\",\"tool_input\":{\"file_path\":\"$file_path\",\"old_string\":\"a\",\"new_string\":\"b\"}}"
    else
        input="{\"tool_name\":\"$tool_name\",\"tool_input\":{\"command\":\"echo hi\"}}"
    fi

    # CONFIG_REPO tells the hook where the config repo is (skips dynamic detection)
    echo "$input" | HOME="$mock_home" PROJECT_DIR="$project_dir" CONFIG_REPO="$mock_home/cfg-agent-fleet" bash "$HOOK" 2>&1
}

# ── Tests ──

test_blocks_write_to_claude_dir_from_other_project() {
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$mock_home/.claude" "$mock_home/cfg-agent-fleet" "$TEST_TMPDIR/other-project"
    touch "$mock_home/cfg-agent-fleet/sync.sh"

    local output rc=0
    output=$(run_guard "Write" "$mock_home/.claude/CLAUDE.md" "$TEST_TMPDIR/other-project" "$mock_home") || rc=$?

    assert_neq "0" "$rc" "Should block write to ~/.claude/ from non-cfg project"
    assert_contains "$output" "owned by cfg-agent-fleet" "Should explain why blocked"
}

test_blocks_edit_to_claude_dir_from_other_project() {
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$mock_home/.claude/knowledge" "$mock_home/cfg-agent-fleet" "$TEST_TMPDIR/sample-project"
    touch "$mock_home/cfg-agent-fleet/sync.sh"

    local output rc=0
    output=$(run_guard "Edit" "$mock_home/.claude/knowledge/learn-protocol.md" "$TEST_TMPDIR/sample-project" "$mock_home") || rc=$?

    assert_neq "0" "$rc" "Should block edit to ~/.claude/knowledge/ from non-cfg project"
}

test_allows_write_from_cfg_project() {
    local mock_home="$TEST_TMPDIR/home"
    local cfg_dir="$mock_home/cfg-agent-fleet"
    mkdir -p "$mock_home/.claude" "$cfg_dir/global"
    touch "$cfg_dir/sync.sh"

    local output rc=0
    output=$(run_guard "Write" "$mock_home/.claude/CLAUDE.md" "$cfg_dir" "$mock_home") || rc=$?

    assert_eq "0" "$rc" "Should allow write to ~/.claude/ from cfg-agent-fleet"
}

test_allows_write_to_own_project() {
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$mock_home/cfg-agent-fleet" "$TEST_TMPDIR/my-project/src"
    touch "$mock_home/cfg-agent-fleet/sync.sh"

    local output rc=0
    output=$(run_guard "Write" "$TEST_TMPDIR/my-project/src/main.py" "$TEST_TMPDIR/my-project" "$mock_home") || rc=$?

    assert_eq "0" "$rc" "Should allow write to own project files"
}

test_ignores_non_write_tools() {
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$mock_home/.claude" "$mock_home/cfg-agent-fleet" "$TEST_TMPDIR/other-project"
    touch "$mock_home/cfg-agent-fleet/sync.sh"

    local output rc=0
    output=$(run_guard "Bash" "$mock_home/.claude/CLAUDE.md" "$TEST_TMPDIR/other-project" "$mock_home") || rc=$?

    assert_eq "0" "$rc" "Should ignore non-Write/Edit tools"
}

test_blocks_write_to_cfg_global() {
    local mock_home="$TEST_TMPDIR/home"
    local cfg_global="$mock_home/cfg-agent-fleet/global/CLAUDE.md"
    mkdir -p "$mock_home/cfg-agent-fleet/global" "$TEST_TMPDIR/social"
    touch "$mock_home/cfg-agent-fleet/sync.sh"

    local output rc=0
    output=$(run_guard "Write" "$cfg_global" "$TEST_TMPDIR/social" "$mock_home") || rc=$?

    assert_neq "0" "$rc" "Should block write to ~/cfg-agent-fleet/global/ from other project"
}

test_allows_cfg_project_write_to_own_global() {
    local mock_home="$TEST_TMPDIR/home"
    local cfg_dir="$mock_home/cfg-agent-fleet"
    local cfg_global="$cfg_dir/global/CLAUDE.md"
    mkdir -p "$cfg_dir/global"
    touch "$cfg_dir/sync.sh"

    local output rc=0
    output=$(run_guard "Write" "$cfg_global" "$cfg_dir" "$mock_home") || rc=$?

    assert_eq "0" "$rc" "Should allow cfg-agent-fleet to write its own global/"
}

test_allows_active_persona_write_from_other_project() {
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$mock_home/.claude" "$mock_home/cfg-agent-fleet" "$TEST_TMPDIR/sample-project"
    touch "$mock_home/cfg-agent-fleet/sync.sh"

    local output rc=0
    output=$(run_guard "Write" "$mock_home/.claude/.active-persona" "$TEST_TMPDIR/sample-project" "$mock_home") || rc=$?

    assert_eq "0" "$rc" "Should allow .active-persona write from any project"
}

test_still_blocks_other_dotfiles_from_other_project() {
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$mock_home/.claude" "$mock_home/cfg-agent-fleet" "$TEST_TMPDIR/social"
    touch "$mock_home/cfg-agent-fleet/sync.sh"

    local output rc=0
    output=$(run_guard "Write" "$mock_home/.claude/.some-other-file" "$TEST_TMPDIR/social" "$mock_home") || rc=$?

    assert_neq "0" "$rc" "Should still block non-allowlisted dotfiles from other projects"
}

# ── Run ──

run_test "blocks Write to ~/.claude/ from non-cfg project" test_blocks_write_to_claude_dir_from_other_project
run_test "blocks Edit to ~/.claude/knowledge/ from non-cfg project" test_blocks_edit_to_claude_dir_from_other_project
run_test "allows Write to ~/.claude/ from cfg-agent-fleet" test_allows_write_from_cfg_project
run_test "allows Write to own project files" test_allows_write_to_own_project
run_test "ignores non-Write/Edit tools" test_ignores_non_write_tools
run_test "blocks Write to ~/cfg-agent-fleet/global/ from other project" test_blocks_write_to_cfg_global
run_test "allows cfg-agent-fleet Write to own global/" test_allows_cfg_project_write_to_own_global
run_test "allows .active-persona write from non-cfg project" test_allows_active_persona_write_from_other_project
run_test "still blocks other dotfiles from non-cfg project" test_still_blocks_other_dotfiles_from_other_project
