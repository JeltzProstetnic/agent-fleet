#!/usr/bin/env bash
# Tests for critical-edit-notify.sh (CFG-225)
source "$(dirname "$0")/test-helpers.sh"

suite_header "Critical-Edit Notification (CFG-225)"

HOOK="$REPO_ROOT/global/hooks/critical-edit-notify.sh"

# Helper: run the hook with mock PostToolUse JSON
run_hook() {
    local tool_name="$1"
    local file_path="$2"
    echo "{\"tool_name\":\"$tool_name\",\"tool_input\":{\"file_path\":\"$file_path\"}}" \
        | bash "$HOOK" 2>/dev/null
}

# ── Tests ────────────────────────────────────────────────────────────────────

# Test 1: Edit to global/ triggers notification
test_global_edit_triggers() {
    local output
    output=$(run_hook "Edit" "/home/user/.claude/foundation/session-protocol.md")
    assert_contains "$output" "additionalContext"
    assert_contains "$output" "TIER"
    assert_contains "$output" "commit"
}
run_test "edit to global/ (deployed as foundation/) triggers notification" test_global_edit_triggers

# Test 2: Edit to hooks/ triggers notification
test_hooks_edit_triggers() {
    local output
    output=$(run_hook "Edit" "/home/user/cfg-agent-fleet/global/hooks/auto-lint.sh")
    assert_contains "$output" "TIER"
}
run_test "edit to hooks/ triggers notification" test_hooks_edit_triggers

# Test 3: Edit to setup/config/ triggers notification
test_setup_config_triggers() {
    local output
    output=$(run_hook "Write" "/home/user/cfg-agent-fleet/setup/config/settings.json")
    assert_contains "$output" "TIER"
}
run_test "edit to setup/config/ triggers notification" test_setup_config_triggers

# Test 4: Edit to setup/scripts/ triggers notification
test_setup_scripts_triggers() {
    local output
    output=$(run_hook "Edit" "/home/user/cfg-agent-fleet/setup/scripts/rotate-session.sh")
    assert_contains "$output" "TIER"
}
run_test "edit to setup/scripts/ triggers notification" test_setup_scripts_triggers

# Test 5: Edit to statusline triggers notification
test_statusline_triggers() {
    local output
    output=$(run_hook "Edit" "/home/user/.claude/statusline-command.sh")
    assert_contains "$output" "TIER"
}
run_test "edit to statusline triggers notification" test_statusline_triggers

# Test 6: Regular project file does NOT trigger
test_regular_file_silent() {
    local output
    output=$(run_hook "Edit" "/home/user/muse/src/main.py")
    assert_eq "" "$output" "regular file should produce no output"
}
run_test "regular project file produces no notification" test_regular_file_silent

# Test 7: Output includes continue: true
test_output_has_continue() {
    local output
    output=$(run_hook "Edit" "/home/user/cfg-agent-fleet/global/CLAUDE.md")
    assert_contains "$output" '"continue"'
    assert_contains "$output" "true"
}
run_test "output includes continue: true" test_output_has_continue

# Test 8: Non-Edit/Write tools produce no output
test_non_edit_tools_silent() {
    local output
    output=$(echo '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | bash "$HOOK" 2>/dev/null)
    assert_eq "" "$output" "non-Edit/Write tools should be silent"
}
run_test "non-Edit/Write tools produce no output" test_non_edit_tools_silent

# Test 9: Edit to global/CLAUDE.md triggers (the most common case)
test_global_claude_md_triggers() {
    local output
    output=$(run_hook "Edit" "/home/user/cfg-agent-fleet/global/CLAUDE.md")
    assert_contains "$output" "TIER"
}
run_test "edit to global/CLAUDE.md triggers notification" test_global_claude_md_triggers

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
