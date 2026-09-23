#!/usr/bin/env bash
# Tests for 20-user-needs.sh — surfaces a project's User Needs document at session start.
# Reinforces the "Read the User Needs before building" rule (CFG-488/CFG-492): the rule
# alone is a "before X, first read Y" pre-step, the shape that fails when attention is
# on the work. This check converts it into an in-context reminder at 0 LLM tokens for
# projects that have no UN at all.
source "$(dirname "$0")/test-helpers.sh"

suite_header "User Needs Check (20-user-needs.sh)"

CHECK="$REPO_ROOT/global/hooks/checks/20-user-needs.sh"

# Run the check against a project dir containing the given relative file paths.
run_check() {
    local project_dir="$1"; shift
    export PROJECT_DIR="$project_dir"
    INBOX_MSG=""
    WARNINGS=""
    mkdir -p "$project_dir"
    local f
    for f in "$@"; do
        mkdir -p "$project_dir/$(dirname "$f")"
        printf '# doc\n' > "$project_dir/$f"
    done
    source "$CHECK"
    echo "$INBOX_MSG"
}

# ── Tests ────────────────────────────────────────────────────────────────────

test_no_un_is_silent() {
    local out
    out=$(run_check "$TEST_TMPDIR/p1" "README.md" "docs/design.md")
    assert_eq "" "$out" "a project with no User Needs document must emit nothing"
}
run_test "no UN document is silent" test_no_un_is_silent

test_detects_canonical_name() {
    local out
    out=$(run_check "$TEST_TMPDIR/p2" "docs/User-Needs_Thing_v1.5.md")
    assert_contains "$out" "UN_PRESENT:" "must emit UN_PRESENT"
    assert_contains "$out" "docs/User-Needs_Thing_v1.5.md" "must name the file it found"
}
run_test "detects User-Needs_*.md" test_detects_canonical_name

test_detects_spaced_and_lowercase() {
    local out
    out=$(run_check "$TEST_TMPDIR/p3" "docs/user needs v2.md")
    assert_contains "$out" "UN_PRESENT:" "detection must be case- and separator-insensitive"
}
run_test "detects 'user needs' lowercase with a space" test_detects_spaced_and_lowercase

test_prefers_deliverables_over_drafts() {
    local out
    out=$(run_check "$TEST_TMPDIR/p4" \
        "docs/User-Needs_old_v0.1.md" \
        "docs/deliverables/2026-08-06/01_User-Needs_v1.5.md")
    assert_contains "$out" "01_User-Needs_v1.5.md" "the deliverables copy is the authoritative one"
}
run_test "prefers a deliverables/ copy" test_prefers_deliverables_over_drafts

test_reports_count_when_several() {
    local out
    out=$(run_check "$TEST_TMPDIR/p5" \
        "docs/User-Needs_a_v1.0.md" "docs/User-Needs_b_v1.0.md" "docs/User-Needs_c_v1.0.md")
    assert_contains "$out" "3 found" "must say how many candidates exist, so the agent knows to check"
}
run_test "reports the candidate count" test_reports_count_when_several

test_ignores_tmp_and_vcs() {
    local out
    out=$(run_check "$TEST_TMPDIR/p6" "tmp/User-Needs_scratch.md" ".git/User-Needs_x.md")
    assert_eq "" "$out" "throwaway and VCS paths must not trigger the reminder"
}
run_test "ignores tmp/ and .git/" test_ignores_tmp_and_vcs

test_ignores_the_fleet_template() {
    local out
    out=$(run_check "$TEST_TMPDIR/p7" "setup/templates/deliverable-set/01_User-Needs.md")
    assert_eq "" "$out" "the blank fleet template is not a project's User Needs"
}
run_test "ignores the deliverable-set template" test_ignores_the_fleet_template

test_appends_to_existing_inbox_msg() {
    export PROJECT_DIR="$TEST_TMPDIR/p8"
    mkdir -p "$PROJECT_DIR/docs"
    printf '# doc\n' > "$PROJECT_DIR/docs/User-Needs_x_v1.0.md"
    INBOX_MSG="PERSONA: TestPersona"
    WARNINGS=""
    source "$CHECK"
    assert_contains "$INBOX_MSG" "PERSONA: TestPersona" "must not clobber earlier fields"
    assert_contains "$INBOX_MSG" " | UN_PRESENT:" "must append with the pipe separator"
}
run_test "appends to an existing INBOX_MSG" test_appends_to_existing_inbox_msg

test_never_warns() {
    export PROJECT_DIR="$TEST_TMPDIR/p9"
    mkdir -p "$PROJECT_DIR/docs"
    printf '# doc\n' > "$PROJECT_DIR/docs/User-Needs_x_v1.0.md"
    INBOX_MSG=""
    WARNINGS=""
    source "$CHECK"
    assert_eq "" "$WARNINGS" "this is informational — it must never raise a WARNING"
}
run_test "never populates WARNINGS" test_never_warns

test_missing_project_dir_is_safe() {
    export PROJECT_DIR="$TEST_TMPDIR/does-not-exist"
    INBOX_MSG=""
    WARNINGS=""
    source "$CHECK"
    assert_eq "" "$INBOX_MSG" "a nonexistent project dir must not error or emit"
}
run_test "nonexistent project dir is safe" test_missing_project_dir_is_safe

# Summary
echo ""
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed out of $TESTS_RUN"
[ "$TESTS_FAILED" -eq 0 ] && exit 0 || exit 1
