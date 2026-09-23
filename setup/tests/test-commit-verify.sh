#!/usr/bin/env bash
# Tests for commit-verify.sh (CFG-226)
source "$(dirname "$0")/test-helpers.sh"

suite_header "Post-Commit Narrative Verification (CFG-226)"

HOOK="$REPO_ROOT/global/hooks/commit-verify.sh"

# Helper: run the hook with mock PostToolUse JSON for Bash
run_hook() {
    local command="$1"
    local stdout="${2:-}"
    python3 -c "
import json, sys
print(json.dumps({'tool_name':'Bash','tool_input':{'command':sys.argv[1]},'tool_output':{'stdout':sys.argv[2]}}))" \
        "$command" "$stdout" | bash "$HOOK" 2>/dev/null
}

# ── Tests ────────────────────────────────────────────────────────────────────

# Test 1: git commit triggers verification reminder
test_git_commit_triggers() {
    local output
    output=$(run_hook "git -C /home/user/proj commit -m 'Fix bug'" "[main abc1234] Fix bug")
    assert_contains "$output" "additionalContext"
    assert_contains "$output" "VERIFY"
}
run_test "git commit triggers verification reminder" test_git_commit_triggers

# Test 2: git commit with multiple -m flags triggers
test_git_commit_multi_m() {
    local output
    output=$(run_hook 'git -C /path commit -m "Subject" -m "Body"' "[main def5678] Subject")
    assert_contains "$output" "VERIFY"
}
run_test "git commit with multiple -m flags triggers" test_git_commit_multi_m

# Test 3: Non-commit git commands do NOT trigger
test_non_commit_silent() {
    local output
    output=$(run_hook "git status" "On branch main")
    assert_eq "" "$output" "git status should not trigger"
}
run_test "non-commit git commands are silent" test_non_commit_silent

# Test 4: Non-git Bash commands are silent
test_non_git_silent() {
    local output
    output=$(run_hook "ls -la" "total 42")
    assert_eq "" "$output" "ls should not trigger"
}
run_test "non-git Bash commands are silent" test_non_git_silent

# Test 5: Output includes continue: true
test_output_has_continue() {
    local output
    output=$(run_hook "git commit -m 'test'" "[main 1234567] test")
    assert_contains "$output" '"continue"'
    assert_contains "$output" "true"
}
run_test "output includes continue: true" test_output_has_continue

# Test 6: Non-Bash tools are silent
test_non_bash_silent() {
    local output
    output=$(echo '{"tool_name":"Edit","tool_input":{"file_path":"/tmp/x"}}' | bash "$HOOK" 2>/dev/null)
    assert_eq "" "$output" "non-Bash tools should be silent"
}
run_test "non-Bash tools are silent" test_non_bash_silent

# Test 7: Failed git commit (no [branch hash] in output) does NOT trigger
test_failed_commit_silent() {
    local output
    output=$(run_hook "git commit -m 'test'" "nothing to commit, working tree clean")
    assert_eq "" "$output" "failed commit should not trigger verification"
}
run_test "failed git commit does not trigger verification" test_failed_commit_silent

# ── Propagation reminder tests (CFG-162 interim) ────────────────────────────

# Test 8: Commit touching global/ triggers propagation reminder
test_global_propagation() {
    local output
    output=$(run_hook "git -C /home/deck/cfg-agent-fleet add global/CLAUDE.md && git -C /home/deck/cfg-agent-fleet commit -m 'Update rules'" "[main aaa1111] Update rules
 1 file changed, 1 insertion(+)
 global/CLAUDE.md | 1 +")
    assert_contains "$output" "PROPAGATION"
}
run_test "commit touching global/ triggers propagation reminder" test_global_propagation

# Test 9: Commit with global/ in --stat output triggers propagation
test_global_in_stat() {
    local output
    output=$(run_hook "git commit -m 'test'" "[main bbb2222] test
 2 files changed
 global/hooks/checks/12-init-guard.sh | 20 +
 setup/tests/test-init-guard.sh | 80 +")
    assert_contains "$output" "PROPAGATION"
}
run_test "global/ in stat output triggers propagation" test_global_in_stat

# Test 10: Commit NOT touching global/ does NOT trigger propagation
test_no_global_no_propagation() {
    local output
    output=$(run_hook "git commit -m 'Fix session'" "[main ccc3333] Fix session
 1 file changed
 session-context.md | 5 +-")
    assert_contains "$output" "VERIFY"
    # Should NOT contain PROPAGATION
    if echo "$output" | grep -q "PROPAGATION"; then
        fail "should not trigger propagation for non-global files"
    fi
}
run_test "commit not touching global/ skips propagation" test_no_global_no_propagation

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
