#!/usr/bin/env bash
# Tests for risk-gate.sh PreToolUse hook
# Verifies T1 edits are blocked without clearance, allowed with fresh clearance,
# and that T2/T3/non-infrastructure files pass through.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

HOOK="$SCRIPT_DIR/../../global/hooks/risk-gate.sh"

suite_header "Risk Gate Hook Tests"

# Helper: simulate a PreToolUse hook call
run_gate() {
    local tool_name="$1"
    local file_path="$2"
    local mock_home="${3:-$TEST_TMPDIR/home}"

    local input
    if [ "$tool_name" = "Write" ]; then
        input="{\"tool_name\":\"$tool_name\",\"tool_input\":{\"file_path\":\"$file_path\",\"content\":\"test\"}}"
    elif [ "$tool_name" = "Edit" ]; then
        input="{\"tool_name\":\"$tool_name\",\"tool_input\":{\"file_path\":\"$file_path\",\"old_string\":\"a\",\"new_string\":\"b\"}}"
    else
        input="{\"tool_name\":\"$tool_name\",\"tool_input\":{\"command\":\"echo hi\"}}"
    fi

    echo "$input" | HOME="$mock_home" bash "$HOOK" 2>&1
}

# ── T1 Blocking Tests ──

test_blocks_mclaude_without_clearance() {
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$mock_home/.local/bin"

    local output rc=0
    output=$(run_gate "Write" "$mock_home/.local/bin/mclaude" "$mock_home") || rc=$?

    assert_eq "2" "$rc" "Should block mclaude edit without clearance"
    assert_contains "$output" "RISK_GATE TIER 1" "Should include RISK_GATE TIER 1 in message"
}

test_blocks_afleet_without_clearance() {
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$mock_home/.local/bin"

    local output rc=0
    output=$(run_gate "Edit" "$mock_home/.local/bin/afleet" "$mock_home") || rc=$?

    assert_eq "2" "$rc" "Should block afleet edit without clearance"
    assert_contains "$output" "RISK_GATE TIER 1" "Should include tier label"
}

test_blocks_settings_json_without_clearance() {
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$mock_home/.cc-mirror/mclaude/config"

    local output rc=0
    output=$(run_gate "Write" "$mock_home/.cc-mirror/mclaude/config/settings.json" "$mock_home") || rc=$?

    assert_eq "2" "$rc" "Should block settings.json edit without clearance"
    assert_contains "$output" "RISK_GATE TIER 1" "Should include tier label"
}

test_blocks_mcp_json_without_clearance() {
    local mock_home="$TEST_TMPDIR/home"

    local output rc=0
    output=$(run_gate "Edit" "$mock_home/.mcp.json" "$mock_home") || rc=$?

    assert_eq "2" "$rc" "Should block .mcp.json edit without clearance"
}

test_blocks_sync_sh_without_clearance() {
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$mock_home/cfg-agent-fleet"

    local output rc=0
    output=$(run_gate "Write" "$mock_home/cfg-agent-fleet/sync.sh" "$mock_home") || rc=$?

    assert_eq "2" "$rc" "Should block cfg-agent-fleet/sync.sh edit without clearance"
}

test_blocks_agent_fleet_sync_sh() {
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$mock_home/agent-fleet"

    local output rc=0
    output=$(run_gate "Write" "$mock_home/agent-fleet/sync.sh" "$mock_home") || rc=$?

    assert_eq "2" "$rc" "Should block agent-fleet/sync.sh edit without clearance"
}

# ── Clearance Tests ──

test_allows_with_fresh_clearance() {
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$mock_home/.local/bin"

    local file_path="$mock_home/.local/bin/mclaude"
    local hash
    hash=$(echo "$file_path" | md5sum | cut -c1-16)
    touch "/tmp/.risk-gate-clearance-${hash}"

    local output rc=0
    output=$(run_gate "Write" "$file_path" "$mock_home") || rc=$?

    rm -f "/tmp/.risk-gate-clearance-${hash}"
    assert_eq "0" "$rc" "Should allow T1 edit with fresh clearance"
}

test_blocks_with_stale_clearance() {
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$mock_home/.local/bin"

    local file_path="$mock_home/.local/bin/mclaude"
    local hash
    hash=$(echo "$file_path" | md5sum | cut -c1-16)
    local clearance_file="/tmp/.risk-gate-clearance-${hash}"
    touch -d "15 minutes ago" "$clearance_file"

    local output rc=0
    output=$(run_gate "Write" "$file_path" "$mock_home") || rc=$?

    rm -f "$clearance_file"
    assert_eq "2" "$rc" "Should block T1 edit with stale (>10 min) clearance"
}

test_clearance_is_per_file() {
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$mock_home/.local/bin" "$mock_home/.cc-mirror/mclaude/config"

    # Create clearance for mclaude only
    local mclaude_path="$mock_home/.local/bin/mclaude"
    local mclaude_hash
    mclaude_hash=$(echo "$mclaude_path" | md5sum | cut -c1-16)
    touch "/tmp/.risk-gate-clearance-${mclaude_hash}"

    # mclaude should pass
    local rc1=0
    run_gate "Write" "$mclaude_path" "$mock_home" >/dev/null 2>&1 || rc1=$?

    # settings.json should still block
    local settings_path="$mock_home/.cc-mirror/mclaude/config/settings.json"
    local rc2=0
    run_gate "Write" "$settings_path" "$mock_home" >/dev/null 2>&1 || rc2=$?

    rm -f "/tmp/.risk-gate-clearance-${mclaude_hash}"

    assert_eq "0" "$rc1" "mclaude should pass with its own clearance"
    assert_eq "2" "$rc2" "settings.json should still block without its own clearance"
}

# ── Pass-Through Tests ──

test_t2_files_pass_through() {
    local mock_home="$TEST_TMPDIR/home"

    local output rc=0
    output=$(run_gate "Write" "$mock_home/.claude/hooks/some-hook.sh" "$mock_home") || rc=$?

    assert_eq "0" "$rc" "T2 files (hooks) should pass through"
}

test_t3_files_pass_through() {
    local mock_home="$TEST_TMPDIR/home"

    local output rc=0
    output=$(run_gate "Edit" "$mock_home/.claude/reference/some-ref.md" "$mock_home") || rc=$?

    assert_eq "0" "$rc" "T3 files (reference) should pass through"
}

test_non_write_tools_ignored() {
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$mock_home/.local/bin"

    local output rc=0
    output=$(run_gate "Bash" "$mock_home/.local/bin/mclaude" "$mock_home") || rc=$?

    assert_eq "0" "$rc" "Non-Write/Edit tools should be ignored"
}

test_regular_project_files_pass() {
    local mock_home="$TEST_TMPDIR/home"

    local output rc=0
    output=$(run_gate "Write" "$mock_home/my-project/src/main.py" "$mock_home") || rc=$?

    assert_eq "0" "$rc" "Regular project files should pass through"
}

# ── Stderr Message Content Tests ──

test_stderr_includes_instructions() {
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$mock_home/.local/bin"

    local output rc=0
    output=$(run_gate "Write" "$mock_home/.local/bin/mclaude" "$mock_home") || rc=$?

    assert_contains "$output" "risk-analysis-protocol.md" "Should reference protocol file"
    assert_contains "$output" "clearance" "Should mention clearance"
}

# ── Run ──

run_test "blocks mclaude Write without clearance" test_blocks_mclaude_without_clearance
run_test "blocks afleet Edit without clearance" test_blocks_afleet_without_clearance
run_test "blocks settings.json Write without clearance" test_blocks_settings_json_without_clearance
run_test "blocks .mcp.json Edit without clearance" test_blocks_mcp_json_without_clearance
run_test "blocks cfg-agent-fleet/sync.sh Write without clearance" test_blocks_sync_sh_without_clearance
run_test "blocks agent-fleet/sync.sh Write without clearance" test_blocks_agent_fleet_sync_sh
run_test "allows T1 edit with fresh clearance file" test_allows_with_fresh_clearance
run_test "blocks T1 edit with stale clearance (>10 min)" test_blocks_with_stale_clearance
run_test "clearance is per-file (mclaude clearance doesn't clear settings.json)" test_clearance_is_per_file
run_test "T2 files (hooks) pass through" test_t2_files_pass_through
run_test "T3 files (reference) pass through" test_t3_files_pass_through
run_test "non-Write/Edit tools ignored" test_non_write_tools_ignored
run_test "regular project files pass through" test_regular_project_files_pass
run_test "stderr includes protocol reference and clearance instructions" test_stderr_includes_instructions

suite_summary
