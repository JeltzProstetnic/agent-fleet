#!/usr/bin/env bash
# Tests for setup/scripts/clean-pending-files.sh — deprecated wrapper around manage-pending.sh
# Verifies: argument mapping, delegation to manage-pending.sh, backward compatibility
source "$(dirname "$0")/test-helpers.sh"

SCRIPT="$REPO_ROOT/setup/scripts/clean-pending-files.sh"
MANAGE_SCRIPT="$REPO_ROOT/setup/scripts/manage-pending.sh"

suite_header "clean-pending-files.sh (deprecated wrapper)"

# ── Helpers ─────────────────────────────────────────────────────────────────

create_project() {
    local dir="$TEST_TMPDIR/project"
    mkdir -p "$dir/docs"
    cat > "$dir/backlog.md" << 'EOF'
# Backlog
## Open
- [ ] [P1] `TST-1` **Test task**: See `docs/pending-test-task.md`
- [x] [P1] `TST-2` **Done task**: See `docs/pending-done-task.md`
EOF
    echo "$dir"
}

create_pending_file() {
    local dir="$1" name="$2" action="${3:-triage}"
    cat > "$dir/docs/$name" << EOF
Action: $action

Content of $name for testing.
EOF
}

# ── Prerequisites ───────────────────────────────────────────────────────────

test_script_exists() {
    assert_file_exists "$SCRIPT" "clean-pending-files.sh should exist"
}
run_test "script file exists" test_script_exists

test_manage_pending_exists() {
    assert_file_exists "$MANAGE_SCRIPT" "manage-pending.sh should exist (delegation target)"
}
run_test "manage-pending.sh exists (delegation target)" test_manage_pending_exists

test_script_is_deprecated_wrapper() {
    local first_lines
    first_lines=$(head -5 "$SCRIPT")
    assert_contains "$first_lines" "DEPRECATED" "script should declare itself deprecated"
}
run_test "script declares itself as deprecated" test_script_is_deprecated_wrapper

# ── Default behavior (no args) delegates to report ─────────────────────────

test_default_runs_report() {
    local dir
    dir=$(create_project)
    create_pending_file "$dir" "pending-test-task.md" "triage"

    local output
    output=$(bash "$SCRIPT" --project-dir "$dir" 2>&1)
    assert_contains "$output" "pending-test-task.md" "default should show pending files"
}
run_test "default invocation runs report mode" test_default_runs_report

# ── --list flag mapped correctly ────────────────────────────────────────────

test_list_flag_shows_report() {
    local dir
    dir=$(create_project)
    create_pending_file "$dir" "pending-alpha.md" "reference"
    create_pending_file "$dir" "pending-beta.md" "defer"

    local output
    output=$(bash "$SCRIPT" --list --project-dir "$dir" 2>&1)
    assert_contains "$output" "pending-alpha.md" "should list alpha"
    assert_contains "$output" "pending-beta.md" "should list beta"
}
run_test "--list flag produces report output" test_list_flag_shows_report

# ── --project-dir is forwarded ──────────────────────────────────────────────

test_project_dir_forwarded() {
    local dir
    dir=$(create_project)
    create_pending_file "$dir" "pending-forward.md" "act"

    local output
    output=$(bash "$SCRIPT" --project-dir "$dir" 2>&1)
    assert_contains "$output" "pending-forward.md" "should find file in specified project dir"
}
run_test "--project-dir is forwarded to manage-pending.sh" test_project_dir_forwarded

# ── --stale-only is silently dropped ────────────────────────────────────────

test_stale_only_dropped_gracefully() {
    local dir
    dir=$(create_project)
    create_pending_file "$dir" "pending-stale-test.md" "triage"

    local rc=0
    local output
    output=$(bash "$SCRIPT" --stale-only --project-dir "$dir" 2>&1) || rc=$?
    assert_eq "0" "$rc" "should not fail with deprecated --stale-only flag"
    assert_contains "$output" "pending-stale-test.md" "should still show files"
}
run_test "--stale-only flag is silently dropped" test_stale_only_dropped_gracefully

# ── Combined old flags work ─────────────────────────────────────────────────

test_combined_old_flags() {
    local dir
    dir=$(create_project)
    create_pending_file "$dir" "pending-combo.md" "defer"

    local rc=0
    local output
    output=$(bash "$SCRIPT" --list --stale-only --project-dir "$dir" 2>&1) || rc=$?
    assert_eq "0" "$rc" "combined old flags should not fail"
    assert_contains "$output" "pending-combo.md" "should still list files"
}
run_test "combined old flags do not break" test_combined_old_flags

# ── No pending files: clean output ──────────────────────────────────────────

test_no_pending_files() {
    local dir
    dir=$(create_project)
    # No pending files created

    local output
    output=$(bash "$SCRIPT" --project-dir "$dir" 2>&1)
    assert_contains "$output" "No pending files" "should report no files found"
}
run_test "no pending files gives clean output" test_no_pending_files

# ── Report shows action type ───────────────────────────────────────────────

test_report_shows_action() {
    local dir
    dir=$(create_project)
    create_pending_file "$dir" "pending-typed.md" "reference"

    local output
    output=$(bash "$SCRIPT" --project-dir "$dir" 2>&1)
    assert_contains "$output" "reference" "report should show the action type"
}
run_test "report displays action type from file header" test_report_shows_action

# ── Report shows tracked/untracked status ──────────────────────────────────

test_report_tracked_status() {
    local dir
    dir=$(create_project)
    # This file IS referenced in the backlog (TST-1)
    create_pending_file "$dir" "pending-test-task.md" "act"
    # This file is NOT referenced in the backlog
    create_pending_file "$dir" "pending-orphan.md" "triage"

    local output
    output=$(bash "$SCRIPT" --project-dir "$dir" 2>&1)
    assert_contains "$output" "tracked" "should show tracked for backlog-referenced file"
    assert_contains "$output" "untracked" "should show untracked for orphan file"
}
run_test "report shows tracked/untracked status" test_report_tracked_status

# ── Report shows summary counts ───────────────────────────────────────────

test_report_summary() {
    local dir
    dir=$(create_project)
    create_pending_file "$dir" "pending-one.md" "defer"
    create_pending_file "$dir" "pending-two.md" "act"
    create_pending_file "$dir" "pending-three.md" "triage"

    local output
    output=$(bash "$SCRIPT" --project-dir "$dir" 2>&1)
    assert_contains "$output" "3 pending" "should count 3 pending files in summary"
}
run_test "report summary shows correct total count" test_report_summary

# ── Unknown flags are silently ignored ──────────────────────────────────────

test_unknown_flags_ignored() {
    local dir
    dir=$(create_project)
    create_pending_file "$dir" "pending-unk.md" "triage"

    local rc=0
    # The wrapper shifts unknown args, but manage-pending.sh might reject them
    # clean-pending-files.sh should eat unknown flags before forwarding
    local output
    output=$(bash "$SCRIPT" --some-unknown-flag --project-dir "$dir" 2>&1) || rc=$?
    # The wrapper skips unknown flags via default case in its parser
    assert_eq "0" "$rc" "unknown flags should not cause error"
}
run_test "unknown flags are silently ignored by wrapper" test_unknown_flags_ignored

# ── Exit code matches manage-pending.sh ────────────────────────────────────

test_exit_code_no_files() {
    local dir
    dir=$(create_project)
    local rc=0
    bash "$SCRIPT" --project-dir "$dir" >/dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" "should exit 0 with no pending files"
}
run_test "exit code 0 when no pending files" test_exit_code_no_files

test_exit_code_with_files() {
    local dir
    dir=$(create_project)
    create_pending_file "$dir" "pending-ec.md" "defer"
    local rc=0
    bash "$SCRIPT" --project-dir "$dir" >/dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" "should exit 0 when pending files exist"
}
run_test "exit code 0 when pending files exist" test_exit_code_with_files

# ── File age display ───────────────────────────────────────────────────────

test_age_display() {
    local dir
    dir=$(create_project)
    create_pending_file "$dir" "pending-aged.md" "defer"
    touch -d "7 days ago" "$dir/docs/pending-aged.md"

    local output
    output=$(bash "$SCRIPT" --project-dir "$dir" 2>&1)
    assert_contains "$output" "7d" "should show age in days"
}
run_test "report shows file age in days" test_age_display

suite_summary
