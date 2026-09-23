#!/usr/bin/env bash
# Tests for 13-scaling-thresholds.sh — file LOC scaling threshold monitor
source "$(dirname "$0")/test-helpers.sh"

suite_header "Scaling Thresholds Check (13-scaling-thresholds.sh)"

CHECK="$REPO_ROOT/global/hooks/checks/13-scaling-thresholds.sh"

# Helper: generate a file with N lines
make_file() {
    local path="$1"
    local lines="$2"
    mkdir -p "$(dirname "$path")"
    # Generate exactly N lines
    seq 1 "$lines" > "$path"
}

# Helper: set up a mock config repo with files, then run the check
run_check() {
    # Uses TEST_TMPDIR as CONFIG_REPO
    export CONFIG_REPO="$TEST_TMPDIR/config-repo"
    mkdir -p "$CONFIG_REPO"
    WARNINGS=""
    # Ensure daily gate does not block — remove marker
    rm -f "/tmp/.scaling-check-$(date +%Y-%m-%d)" 2>/dev/null || true
    source "$CHECK"
    echo "$WARNINGS"
}

# ── Tests ────────────────────────────────────────────────────────────────────

# Test 1: Bash script under soft limit — no warning
test_bash_under_soft() {
    make_file "$TEST_TMPDIR/config-repo/setup/scripts/foo.sh" 300
    local output
    output=$(run_check)
    assert_not_contains "$output" "foo.sh" "bash script under soft limit should not warn"
}
run_test "bash script under soft limit — silent" test_bash_under_soft

# Test 2: Bash script over soft limit — warns
test_bash_over_soft() {
    make_file "$TEST_TMPDIR/config-repo/setup/scripts/big.sh" 450
    local output
    output=$(run_check)
    assert_contains "$output" "big.sh" "bash script over soft limit should mention filename"
    assert_contains "$output" "soft limit" "bash script over soft limit should say 'soft limit'"
}
run_test "bash script over soft limit — warns" test_bash_over_soft

# Test 3: Bash script over hard limit — hard warning
test_bash_over_hard() {
    make_file "$TEST_TMPDIR/config-repo/setup/scripts/huge.sh" 650
    local output
    output=$(run_check)
    assert_contains "$output" "huge.sh" "bash script over hard limit should mention filename"
    # Should mention HARD LIMIT or split
    if [[ "$output" != *"HARD LIMIT"* ]] && [[ "$output" != *"split"* ]]; then
        echo "    ASSERT failed: expected 'HARD LIMIT' or 'split' in output" >&2
        echo "    Got: $output" >&2
        return 1
    fi
}
run_test "bash script over hard limit — hard warning" test_bash_over_hard

# Test 4: Test file under soft limit — no warning
test_testfile_under_soft() {
    make_file "$TEST_TMPDIR/config-repo/setup/tests/test-something.sh" 700
    local output
    output=$(run_check)
    assert_not_contains "$output" "test-something.sh" "test file under soft limit should not warn"
}
run_test "test file under soft limit — silent" test_testfile_under_soft

# Test 5: Test file over soft limit — warns
test_testfile_over_soft() {
    make_file "$TEST_TMPDIR/config-repo/setup/tests/test-big.sh" 900
    local output
    output=$(run_check)
    assert_contains "$output" "test-big.sh" "test file over soft limit should mention filename"
    assert_contains "$output" "soft limit" "test file over soft limit should say 'soft limit'"
}
run_test "test file over soft limit — warns" test_testfile_over_soft

# Test 6: Test file over hard limit — hard warning
test_testfile_over_hard() {
    make_file "$TEST_TMPDIR/config-repo/setup/tests/test-huge.sh" 1600
    local output
    output=$(run_check)
    assert_contains "$output" "test-huge.sh" "test file over hard limit should mention filename"
    if [[ "$output" != *"HARD LIMIT"* ]] && [[ "$output" != *"split"* ]]; then
        echo "    ASSERT failed: expected 'HARD LIMIT' or 'split' in output" >&2
        echo "    Got: $output" >&2
        return 1
    fi
}
run_test "test file over hard limit — hard warning" test_testfile_over_hard

# Test 7: Knowledge .md under soft limit — no warning
test_knowledge_under_soft() {
    make_file "$TEST_TMPDIR/config-repo/global/knowledge/vault-ops.md" 150
    local output
    output=$(run_check)
    assert_not_contains "$output" "vault-ops.md" "knowledge file under soft limit should not warn"
}
run_test "knowledge .md under soft limit — silent" test_knowledge_under_soft

# Test 8: Knowledge .md over soft limit — warns
test_knowledge_over_soft() {
    make_file "$TEST_TMPDIR/config-repo/global/knowledge/big-doc.md" 250
    local output
    output=$(run_check)
    assert_contains "$output" "big-doc.md" "knowledge file over soft limit should mention filename"
    assert_contains "$output" "soft limit" "knowledge file over soft limit should say 'soft limit'"
}
run_test "knowledge .md over soft limit — warns" test_knowledge_over_soft

# Test 9: Reference .md over hard limit — hard warning
test_reference_over_hard() {
    make_file "$TEST_TMPDIR/config-repo/global/reference/huge-ref.md" 400
    local output
    output=$(run_check)
    assert_contains "$output" "huge-ref.md" "reference file over hard limit should mention filename"
    if [[ "$output" != *"HARD LIMIT"* ]] && [[ "$output" != *"split"* ]]; then
        echo "    ASSERT failed: expected 'HARD LIMIT' or 'split' in output" >&2
        echo "    Got: $output" >&2
        return 1
    fi
}
run_test "reference .md over hard limit — hard warning" test_reference_over_hard

# Test 10: Hook check module under soft limit — no warning
test_hook_check_under_soft() {
    make_file "$TEST_TMPDIR/config-repo/global/hooks/checks/99-test.sh" 80
    local output
    output=$(run_check)
    assert_not_contains "$output" "99-test.sh" "hook check under soft limit should not warn"
}
run_test "hook check module under soft limit — silent" test_hook_check_under_soft

# Test 11: Hook check module over soft limit — warns
test_hook_check_over_soft() {
    make_file "$TEST_TMPDIR/config-repo/global/hooks/checks/99-big.sh" 120
    local output
    output=$(run_check)
    assert_contains "$output" "99-big.sh" "hook check over soft limit should mention filename"
    assert_contains "$output" "soft limit" "hook check over soft limit should say 'soft limit'"
}
run_test "hook check module over soft limit — warns" test_hook_check_over_soft

# Test 12: Hook check module over hard limit — hard warning
test_hook_check_over_hard() {
    make_file "$TEST_TMPDIR/config-repo/global/hooks/checks/99-huge.sh" 160
    local output
    output=$(run_check)
    assert_contains "$output" "99-huge.sh" "hook check over hard limit should mention filename"
    if [[ "$output" != *"HARD LIMIT"* ]] && [[ "$output" != *"split"* ]]; then
        echo "    ASSERT failed: expected 'HARD LIMIT' or 'split' in output" >&2
        echo "    Got: $output" >&2
        return 1
    fi
}
run_test "hook check module over hard limit — hard warning" test_hook_check_over_hard

# Test 13: Hook script (non-checks/) over soft limit — warns
test_hook_script_over_soft() {
    make_file "$TEST_TMPDIR/config-repo/global/hooks/big-hook.sh" 250
    local output
    output=$(run_check)
    assert_contains "$output" "big-hook.sh" "hook script over soft limit should mention filename"
    assert_contains "$output" "soft limit" "hook script over soft limit should say 'soft limit'"
}
run_test "hook script (non-checks) over soft limit — warns" test_hook_script_over_soft

# Test 14: Hook script over hard limit — hard warning
test_hook_script_over_hard() {
    make_file "$TEST_TMPDIR/config-repo/global/hooks/huge-hook.sh" 350
    local output
    output=$(run_check)
    assert_contains "$output" "huge-hook.sh" "hook script over hard limit should mention filename"
    if [[ "$output" != *"HARD LIMIT"* ]] && [[ "$output" != *"split"* ]]; then
        echo "    ASSERT failed: expected 'HARD LIMIT' or 'split' in output" >&2
        echo "    Got: $output" >&2
        return 1
    fi
}
run_test "hook script (non-checks) over hard limit — hard warning" test_hook_script_over_hard

# Test 15: afd/ bash scripts are also checked
test_afd_script_over_soft() {
    make_file "$TEST_TMPDIR/config-repo/afd/lib/helpers.sh" 450
    local output
    output=$(run_check)
    assert_contains "$output" "helpers.sh" "afd script over soft limit should mention filename"
    assert_contains "$output" "soft limit"
}
run_test "afd/ bash script over soft limit — warns" test_afd_script_over_soft

# Test 16: sync.sh at root is also checked
test_sync_over_soft() {
    make_file "$TEST_TMPDIR/config-repo/sync.sh" 450
    local output
    output=$(run_check)
    assert_contains "$output" "sync.sh" "sync.sh over soft limit should mention filename"
}
run_test "sync.sh over soft limit — warns" test_sync_over_soft

# Test 17: Non-matching file types are ignored
test_non_matching_ignored() {
    # A .py file in setup/scripts/ should not be checked
    make_file "$TEST_TMPDIR/config-repo/setup/scripts/something.py" 9000
    # A .md in a non-knowledge/reference dir should not be checked
    make_file "$TEST_TMPDIR/config-repo/docs/big-doc.md" 9000
    # A .txt file anywhere
    make_file "$TEST_TMPDIR/config-repo/global/knowledge/notes.txt" 9000
    local output
    output=$(run_check)
    assert_not_contains "$output" "something.py" ".py files should be ignored"
    assert_not_contains "$output" "big-doc.md" "docs/ .md files should be ignored"
    assert_not_contains "$output" "notes.txt" ".txt files should be ignored"
}
run_test "non-matching file types are ignored" test_non_matching_ignored

# Test 18: Summary line appears when there are violations
test_summary_line() {
    make_file "$TEST_TMPDIR/config-repo/setup/scripts/a.sh" 450
    make_file "$TEST_TMPDIR/config-repo/setup/scripts/b.sh" 650
    local output
    output=$(run_check)
    # Should have a summary mentioning count of files
    assert_contains "$output" "2" "summary should mention count of files with violations"
}
run_test "summary includes count of violating files" test_summary_line

# Test 19: Daily gate marker prevents re-running
test_daily_gate() {
    # Create a file that would trigger a warning
    make_file "$TEST_TMPDIR/config-repo/setup/scripts/big.sh" 450

    # Create the daily marker BEFORE running check
    touch "/tmp/.scaling-check-$(date +%Y-%m-%d)"

    export CONFIG_REPO="$TEST_TMPDIR/config-repo"
    WARNINGS=""
    source "$CHECK"
    local output="$WARNINGS"

    # Clean up marker
    rm -f "/tmp/.scaling-check-$(date +%Y-%m-%d)" 2>/dev/null || true

    assert_not_contains "$output" "big.sh" "daily gate should prevent warnings"
}
run_test "daily gate marker prevents re-running" test_daily_gate

# Test 20: All files under thresholds — completely silent
test_all_under_threshold() {
    make_file "$TEST_TMPDIR/config-repo/setup/scripts/small.sh" 100
    make_file "$TEST_TMPDIR/config-repo/setup/tests/test-small.sh" 200
    make_file "$TEST_TMPDIR/config-repo/global/knowledge/small.md" 50
    make_file "$TEST_TMPDIR/config-repo/global/reference/small.md" 50
    make_file "$TEST_TMPDIR/config-repo/global/hooks/checks/01-small.sh" 30
    make_file "$TEST_TMPDIR/config-repo/global/hooks/small-hook.sh" 80
    local output
    output=$(run_check)
    assert_eq "" "$output" "all files under thresholds should produce no output"
}
run_test "all files under thresholds — completely silent" test_all_under_threshold

suite_summary
