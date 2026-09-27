#!/usr/bin/env bash
# Self-test for the test harness — verifies assertions, lifecycle, and fixtures work
source "$(dirname "$0")/test-helpers.sh"

suite_header "Test Harness Self-Test"

# Run an assertion that is EXPECTED to fail, in a child shell so its failure is not
# recorded against the calling test (CFG-532). Succeeds only when the assertion returned 1,
# so a misspelled or missing assert (127) does not pass as a rejection.
assert_rejects() {
    assert_exit_code 1 bash -c 'source "$0"; "$@"' "$SCRIPT_DIR/test-helpers.sh" "$@"
}

# Write a one-off suite to $TEST_TMPDIR and run it in a child bash. Sets RUN_OUTPUT and
# RUN_RC for the caller — the harness under test must not share counters with this suite.
run_child_suite() {
    local body="$1"
    local suite="$TEST_TMPDIR/child-suite.sh"
    printf 'source "%s"\n%s\nsuite_summary\n' "$SCRIPT_DIR/test-helpers.sh" "$body" > "$suite"
    RUN_RC=0
    RUN_OUTPUT=$(NO_COLOR=1 bash "$suite" 2>&1) || RUN_RC=$?
}

# ── Assertion tests ──────────────────────────────────────────────────────────

test_assert_eq_pass() {
    assert_eq "hello" "hello"
    assert_eq "" ""
    assert_eq "123" "123"
}
run_test "assert_eq passes on equal strings" test_assert_eq_pass

test_assert_eq_fail() {
    assert_rejects assert_eq "hello" "world"
}
run_test "assert_eq fails on unequal strings" test_assert_eq_fail

test_assert_contains_pass() {
    assert_contains "hello world" "world"
    assert_contains "foobar" "oob"
}
run_test "assert_contains passes on substring match" test_assert_contains_pass

test_assert_contains_fail() {
    assert_rejects assert_contains "hello world" "xyz"
}
run_test "assert_contains fails on no match" test_assert_contains_fail

test_assert_not_contains() {
    assert_not_contains "hello world" "xyz"
    assert_rejects assert_not_contains "hello world" "world"
}
run_test "assert_not_contains works correctly" test_assert_not_contains

# ── File assertions ──────────────────────────────────────────────────────────

test_file_assertions() {
    local testfile="$TEST_TMPDIR/testfile.txt"
    echo "line one" > "$testfile"
    echo "line two" >> "$testfile"

    assert_file_exists "$testfile"
    assert_file_not_exists "$TEST_TMPDIR/nonexistent.txt"
    assert_dir_exists "$TEST_TMPDIR"
    assert_file_contains "$testfile" "line one"
    assert_file_not_contains "$testfile" "line three"
    assert_line_count "$testfile" 2
    assert_grep_count "$testfile" "line" 2
}
run_test "file assertions work correctly" test_file_assertions

# ── Exit code assertions ────────────────────────────────────────────────────

test_exit_code() {
    assert_exit_code 0 true
    assert_exit_code 1 false
    assert_success true
    assert_failure false
}
run_test "exit code assertions work correctly" test_exit_code

# ── Lifecycle ────────────────────────────────────────────────────────────────

test_tmpdir_isolation() {
    # Each test gets a unique tmpdir
    assert_dir_exists "$TEST_TMPDIR"
    local marker="$TEST_TMPDIR/marker.txt"
    echo "test" > "$marker"
    assert_file_exists "$marker"
}
run_test "test tmpdir is isolated and writable" test_tmpdir_isolation

test_tmpdir_cleanup() {
    # Verify previous test's tmpdir was cleaned up
    # We can't directly check, but we can verify our own is fresh
    local files
    files=$(ls -A "$TEST_TMPDIR" 2>/dev/null | wc -l)
    assert_eq "0" "$files" "tmpdir should be empty at test start"
}
run_test "test tmpdir is cleaned up between tests" test_tmpdir_cleanup

# ── run_test verdict (CFG-532) ──────────────────────────────────────────────
# run_test used to take only the test function's exit status — the status of its LAST
# command — so a failing assert followed by a passing one was reported PASS. Every
# assert_* now records its failure for the running test, and run_test checks that record.

test_nonfinal_assert_fails_test() {
    run_child_suite '
t_nonfinal() {
    assert_eq "a" "b" "not the last statement"
    assert_eq "x" "x"
}
run_test "nonfinal" t_nonfinal'
    assert_neq "0" "$RUN_RC" "suite must exit non-zero"
    assert_contains "$RUN_OUTPUT" "FAIL nonfinal"
    assert_not_contains "$RUN_OUTPUT" "PASS nonfinal"
}
run_test "run_test fails a test whose non-final assertion failed" test_nonfinal_assert_fails_test

test_subshell_assert_fails_test() {
    # Asserts inside `( ... )` are common (cd + source in isolation); they must count too.
    run_child_suite '
t_sub() {
    (
        assert_eq "a" "b" "inside a subshell"
        assert_eq "x" "x"
    )
}
run_test "subshell" t_sub'
    assert_neq "0" "$RUN_RC" "suite must exit non-zero"
    assert_contains "$RUN_OUTPUT" "FAIL subshell"
}
run_test "run_test fails a test whose assertion failed inside a subshell" test_subshell_assert_fails_test

test_assert_failure_does_not_leak() {
    # The failure record is per test: a red test must not drag the next one down.
    run_child_suite '
t_first() { assert_eq "a" "b" "first fails"; assert_eq "x" "x"; }
t_second() { assert_eq "x" "x"; }
run_test "first" t_first
run_test "second" t_second'
    assert_contains "$RUN_OUTPUT" "FAIL first"
    assert_contains "$RUN_OUTPUT" "PASS second"
    assert_contains "$RUN_OUTPUT" "Failed:  1"
}
run_test "assertion failures do not leak into the next test" test_assert_failure_does_not_leak

test_explicit_return_still_fails() {
    # The function's own exit status still counts — `|| return 1` guards keep working.
    run_child_suite '
t_ret() { return 1; }
run_test "ret" t_ret'
    assert_neq "0" "$RUN_RC" "suite must exit non-zero"
    assert_contains "$RUN_OUTPUT" "FAIL ret"
}
run_test "a non-zero return still fails the test" test_explicit_return_still_fails

# Every assert_* must record its failure, or a non-final call to it is dead again. Each case
# below runs as a NON-final statement followed by a passing assert, so only the record can
# fail its test. The list must name every assert_* the harness defines.
_WIRING_CASES=(
    'assert_eq a b'
    'assert_neq a a'
    'assert_contains abc x'
    'assert_contains_any abc x y'
    'assert_not_contains abc b'
    'assert_file_exists "$TEST_TMPDIR/missing"'
    'assert_file_not_exists "$TEST_TMPDIR/f"'
    'assert_dir_exists "$TEST_TMPDIR/missing"'
    'assert_file_contains "$TEST_TMPDIR/f" three'
    'assert_file_not_contains "$TEST_TMPDIR/f" one'
    'assert_exit_code 0 false'
    'assert_success false'
    'assert_failure true'
    'assert_line_count "$TEST_TMPDIR/f" 5'
    'assert_grep_count "$TEST_TMPDIR/f" one 3'
)

test_every_assert_is_wired() {
    local body="" i
    for i in "${!_WIRING_CASES[@]}"; do
        body+="t_$i() { printf 'one\\ntwo\\n' > \"\$TEST_TMPDIR/f\"; ${_WIRING_CASES[$i]}; assert_eq x x; }"$'\n'
        body+="run_test \"case-$i\" t_$i"$'\n'
    done
    run_child_suite "$body"
    # Collect every problem and assert ONCE, as the final statement: the check must not
    # depend on the wiring of any assert it is checking.
    local problems=""
    for i in "${!_WIRING_CASES[@]}"; do
        [[ "$RUN_OUTPUT" == *"FAIL case-$i"$'\n'* ]] || problems+="not failed: ${_WIRING_CASES[$i]}"$'\n'
    done
    [[ "$RUN_OUTPUT" == *"Failed:  ${#_WIRING_CASES[@]}"$'\n'* ]] || problems+="child suite did not fail all ${#_WIRING_CASES[@]} cases"$'\n'

    # Completeness: every assert_* defined by the harness has a case above.
    local defined covered
    defined=$(bash -c 'source "$0" >/dev/null 2>&1; declare -F' "$SCRIPT_DIR/test-helpers.sh" \
        | awk '$3 ~ /^assert_/ {print $3}' | sort)
    covered=$(printf '%s\n' "${_WIRING_CASES[@]}" | awk '{print $1}' | sort -u)
    [[ -n "$defined" ]] || problems+="found no assert_* in test-helpers.sh"$'\n'
    [[ "$defined" == "$covered" ]] || problems+="wiring cases cover [$covered] but the harness defines [$defined]"$'\n'
    assert_eq "" "$problems" "every harness assert_* must record its failure"
}
run_test "every assert_* records its failure as a non-final statement" test_every_assert_is_wired

test_missing_record_fails_test() {
    # Fail closed: without the record run_test cannot prove that no assertion failed.
    run_child_suite '
t_lost() { rm -f "$_ASSERT_FAIL_FILE"; }
run_test "lost" t_lost'
    assert_neq "0" "$RUN_RC" "suite must exit non-zero"
    assert_contains "$RUN_OUTPUT" "FAIL lost"
}
run_test "a test whose assertion record vanished fails" test_missing_record_fails_test

test_record_created_private() {
    # setup_test creates the record itself (mktemp: exclusive create, owner-only) so that a
    # missing record is detectable and nobody else can pre-create or redirect it.
    assert_file_exists "$_ASSERT_FAIL_FILE"
    assert_eq "$_ASSERT_FAIL_FILE" "$(find "$_ASSERT_FAIL_FILE" -perm 600 2>/dev/null)" "record must be mode 600"
}
run_test "the assertion record exists at test start and is owner-only" test_record_created_private

# ── Either-or assertions (CFG-532) ──────────────────────────────────────────
# `assert_a || assert_b` does NOT mean "either" any more: assert_a records its failure before
# assert_b runs, so the test fails even when assert_b matches. Use assert_contains_any.

test_or_chain_is_not_either() {
    run_child_suite '
t_chain() {
    local content="ROOT CAUSE analysis"
    assert_contains "$content" "root cause" || assert_contains "$content" "ROOT CAUSE"
}
run_test "chain" t_chain'
    assert_contains "$RUN_OUTPUT" "FAIL chain" "an || chain keeps the first alternative's failure"
}
run_test "assert_a || assert_b fails when only assert_b matches" test_or_chain_is_not_either

test_contains_any_later_needle_passes() {
    run_child_suite '
t_any() {
    local content="ROOT CAUSE analysis"
    assert_contains_any "$content" "root cause" "ROOT CAUSE"
    assert_contains_any "$content" "analysis"
}
run_test "any" t_any'
    assert_eq "0" "$RUN_RC" "suite must pass: $RUN_OUTPUT"
    assert_contains "$RUN_OUTPUT" "PASS any"
}
run_test "assert_contains_any passes when a later needle matches" test_contains_any_later_needle_passes

test_contains_any_rejects() {
    assert_rejects assert_contains_any "abc" "x" "y"
    # Needles are literal substrings, like assert_contains, not glob patterns.
    assert_rejects assert_contains_any "abc" "[b]"
    assert_contains_any "a[b]c" "[b]"
    # No needle at all is a broken call, not a vacuous pass.
    assert_rejects assert_contains_any "abc"
}
run_test "assert_contains_any fails when no needle matches" test_contains_any_rejects

test_no_or_chained_asserts() {
    # Guard against the idiom coming back in any suite that sources this harness.
    local files=() f hits
    for f in "$SCRIPT_DIR"/*.sh "$REPO_ROOT"/afd/tests/*.sh "$REPO_ROOT"/vps/*/tests/*.sh; do
        [[ -f "$f" ]] || continue
        [[ "$f" == "$SCRIPT_DIR/test-harness.sh" ]] && continue
        files+=("$f")
    done
    hits=$(grep -nE 'assert_[a-z_]+.*\|\|[[:space:]]*assert_|^[[:space:]]*\|\|[[:space:]]*assert_' "${files[@]}" \
        | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)
    assert_eq "" "$hits" "use assert_contains_any instead of an assert_* || assert_* chain"
}
run_test "no suite chains assert_* || assert_* as an either-or" test_no_or_chained_asserts

# ── Git fixtures ─────────────────────────────────────────────────────────────

test_create_git_repo() {
    local repo="$TEST_TMPDIR/repo"
    create_git_repo "$repo"

    assert_dir_exists "$repo/.git"
    assert_file_exists "$repo/README.md"

    local branch
    branch=$(cd "$repo" && git branch --show-current)
    # Accept either main or master
    [[ "$branch" == "main" ]] || [[ "$branch" == "master" ]]
}
run_test "create_git_repo creates a valid repo with initial commit" test_create_git_repo

test_create_tracked_repo() {
    local repo="$TEST_TMPDIR/repo"
    local remote="$TEST_TMPDIR/remote.git"
    create_tracked_repo "$repo" "$remote"

    assert_dir_exists "$repo/.git"
    assert_dir_exists "$remote"

    local remote_url
    remote_url=$(cd "$repo" && git remote get-url origin)
    assert_eq "$remote" "$remote_url"
}
run_test "create_tracked_repo sets up repo with remote tracking" test_create_tracked_repo

test_add_commit() {
    local repo="$TEST_TMPDIR/repo"
    create_git_repo "$repo"
    add_commit "$repo" "second commit"

    local count
    count=$(cd "$repo" && git rev-list --count HEAD)
    assert_eq "2" "$count" "should have 2 commits"
}
run_test "add_commit adds a commit to existing repo" test_add_commit

# ── Session context fixture ─────────────────────────────────────────────────

test_create_session_context() {
    local dir="$TEST_TMPDIR/project"
    create_session_context "$dir" "Test my goal" "test-box"

    assert_file_exists "$dir/session-context.md"
    assert_file_contains "$dir/session-context.md" "Test my goal"
    assert_file_contains "$dir/session-context.md" "test-box"
    assert_file_contains "$dir/session-context.md" '\- \[x\] Did something useful'
    assert_dir_exists "$dir/docs"
}
run_test "create_session_context generates valid session file" test_create_session_context

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
