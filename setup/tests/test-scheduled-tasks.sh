#!/usr/bin/env bash
# Tests for scheduled task system (sched-lib.sh + check 19)
source "$(dirname "$0")/test-helpers.sh"

SCHED_LIB="$REPO_ROOT/setup/scripts/sched-lib.sh"

suite_header "scheduled-tasks"

# ── Task registration ────────────────────────────────────────────────────────

test_register_valid_task() {
    source "$SCHED_LIB"
    sched_reset
    sched_task "test-task" --interval daily --scope fleet --exec auto --desc "Test task"
    local count
    count=$(sched_count)
    assert_eq "1" "$count" "expected 1 task registered"
}
run_test "register valid task" test_register_valid_task

test_register_multiple_tasks() {
    source "$SCHED_LIB"
    sched_reset
    sched_task "task-a" --interval daily --scope fleet --exec auto --desc "Task A"
    sched_task "task-b" --interval weekly --scope per-machine --exec prompted --desc "Task B"
    sched_task "task-c" --interval monthly --scope fleet --exec manual --desc "Task C"
    assert_eq "3" "$(sched_count)"
}
run_test "register multiple tasks" test_register_multiple_tasks

test_reject_bad_interval() {
    source "$SCHED_LIB"
    sched_reset
    local out
    out=$(sched_task "bad" --interval hourly --scope fleet --exec auto --desc "Bad" 2>&1) || true
    assert_eq "0" "$(sched_count)" "bad interval should not register"
}
run_test "reject invalid interval" test_reject_bad_interval

test_reject_bad_scope() {
    source "$SCHED_LIB"
    sched_reset
    sched_task "bad" --interval daily --scope global --exec auto --desc "Bad" 2>&1 || true
    assert_eq "0" "$(sched_count)" "bad scope should not register"
}
run_test "reject invalid scope" test_reject_bad_scope

test_reject_bad_exec() {
    source "$SCHED_LIB"
    sched_reset
    sched_task "bad" --interval daily --scope fleet --exec silent --desc "Bad" 2>&1 || true
    assert_eq "0" "$(sched_count)" "bad exec should not register"
}
run_test "reject invalid execution type" test_reject_bad_exec

test_reject_missing_id() {
    source "$SCHED_LIB"
    sched_reset
    sched_task "" --interval daily --scope fleet --exec auto --desc "No ID" 2>&1 || true
    assert_eq "0" "$(sched_count)"
}
run_test "reject empty task ID" test_reject_missing_id

test_reject_duplicate_id() {
    source "$SCHED_LIB"
    sched_reset
    sched_task "dupe" --interval daily --scope fleet --exec auto --desc "First"
    sched_task "dupe" --interval weekly --scope fleet --exec auto --desc "Second" 2>&1 || true
    assert_eq "1" "$(sched_count)" "duplicate ID should not register"
}
run_test "reject duplicate task ID" test_reject_duplicate_id

# ── Date gating ──────────────────────────────────────────────────────────────

test_every_session_always_due() {
    source "$SCHED_LIB"
    SCHED_MARKER_DIR="$TEST_TMPDIR"
    sched_is_due "test" "every-session"
    assert_eq "0" "$?" "every-session should always be due"
}
run_test "every-session is always due" test_every_session_always_due

test_daily_due_first_time() {
    source "$SCHED_LIB"
    SCHED_MARKER_DIR="$TEST_TMPDIR"
    sched_is_due "test" "daily"
    assert_eq "0" "$?" "daily should be due on first check"
}
run_test "daily task due on first check" test_daily_due_first_time

test_daily_not_due_after_mark() {
    source "$SCHED_LIB"
    SCHED_MARKER_DIR="$TEST_TMPDIR"
    sched_mark_done "test" "daily"
    if sched_is_due "test" "daily"; then
        fail "daily should NOT be due after mark_done"
    fi
}
run_test "daily task not due after mark_done" test_daily_not_due_after_mark

test_weekly_due_first_time() {
    source "$SCHED_LIB"
    SCHED_MARKER_DIR="$TEST_TMPDIR"
    sched_is_due "test" "weekly"
    assert_eq "0" "$?" "weekly should be due on first check"
}
run_test "weekly task due on first check" test_weekly_due_first_time

test_weekly_not_due_after_mark() {
    source "$SCHED_LIB"
    SCHED_MARKER_DIR="$TEST_TMPDIR"
    sched_mark_done "test" "weekly"
    if sched_is_due "test" "weekly"; then
        fail "weekly should NOT be due after mark_done"
    fi
}
run_test "weekly task not due after mark_done" test_weekly_not_due_after_mark

test_monthly_due_first_time() {
    source "$SCHED_LIB"
    SCHED_MARKER_DIR="$TEST_TMPDIR"
    sched_is_due "test" "monthly"
    assert_eq "0" "$?" "monthly should be due on first check"
}
run_test "monthly task due on first check" test_monthly_due_first_time

test_monthly_not_due_after_mark() {
    source "$SCHED_LIB"
    SCHED_MARKER_DIR="$TEST_TMPDIR"
    sched_mark_done "test" "monthly"
    if sched_is_due "test" "monthly"; then
        fail "monthly should NOT be due after mark_done"
    fi
}
run_test "monthly task not due after mark_done" test_monthly_not_due_after_mark

test_marker_file_created() {
    source "$SCHED_LIB"
    SCHED_MARKER_DIR="$TEST_TMPDIR"
    sched_mark_done "mytest" "daily"
    local marker
    marker=$(find "$TEST_TMPDIR" -name ".sched-mytest-*" | head -1)
    [[ -n "$marker" ]] || fail "marker file should exist"
}
run_test "mark_done creates marker file" test_marker_file_created

# ── Scope matching ───────────────────────────────────────────────────────────

test_fleet_scope_always_matches() {
    source "$SCHED_LIB"
    SCHED_MACHINE="wsl"
    SCHED_PROJECT="cfg-agent-fleet"
    sched_matches_scope "fleet" "" ""
    assert_eq "0" "$?"
}
run_test "fleet scope matches any machine/project" test_fleet_scope_always_matches

test_per_machine_matches_correct() {
    source "$SCHED_LIB"
    SCHED_MACHINE="wsl"
    sched_matches_scope "per-machine" "wsl" ""
    assert_eq "0" "$?"
}
run_test "per-machine matches correct machine" test_per_machine_matches_correct

test_per_machine_rejects_wrong() {
    source "$SCHED_LIB"
    SCHED_MACHINE="wsl"
    if sched_matches_scope "per-machine" "steamdeck" ""; then
        fail "per-machine should not match wrong machine"
    fi
}
run_test "per-machine rejects wrong machine" test_per_machine_rejects_wrong

test_per_project_matches_correct() {
    source "$SCHED_LIB"
    SCHED_PROJECT="cfg-agent-fleet"
    sched_matches_scope "per-project" "" "cfg-agent-fleet"
    assert_eq "0" "$?"
}
run_test "per-project matches correct project" test_per_project_matches_correct

test_per_project_rejects_wrong() {
    source "$SCHED_LIB"
    SCHED_PROJECT="cfg-agent-fleet"
    if sched_matches_scope "per-project" "" "social"; then
        fail "per-project should not match wrong project"
    fi
}
run_test "per-project rejects wrong project" test_per_project_rejects_wrong

test_per_machine_project_matches_both() {
    source "$SCHED_LIB"
    SCHED_MACHINE="wsl"
    SCHED_PROJECT="cfg-agent-fleet"
    sched_matches_scope "per-machine-project" "wsl" "cfg-agent-fleet"
    assert_eq "0" "$?"
}
run_test "per-machine-project matches when both match" test_per_machine_project_matches_both

test_per_machine_project_rejects_wrong_machine() {
    source "$SCHED_LIB"
    SCHED_MACHINE="wsl"
    SCHED_PROJECT="cfg-agent-fleet"
    if sched_matches_scope "per-machine-project" "steamdeck" "cfg-agent-fleet"; then
        fail "should reject when machine doesn't match"
    fi
}
run_test "per-machine-project rejects wrong machine" test_per_machine_project_rejects_wrong_machine

# ── Resolution ───────────────────────────────────────────────────────────────

test_resolve_filters_by_scope_and_date() {
    source "$SCHED_LIB"
    SCHED_MARKER_DIR="$TEST_TMPDIR"
    SCHED_MACHINE="wsl"
    SCHED_PROJECT="cfg-agent-fleet"
    sched_reset

    sched_task "fleet-daily" --interval daily --scope fleet --exec auto --desc "Fleet daily"
    sched_task "wsl-only" --interval daily --scope per-machine --machine wsl --exec auto --desc "WSL only"
    sched_task "deck-only" --interval daily --scope per-machine --machine steamdeck --exec auto --desc "Deck only"

    local due
    due=$(sched_resolve)
    assert_contains "$due" "fleet-daily"
    assert_contains "$due" "wsl-only"
    assert_not_contains "$due" "deck-only"
}
run_test "resolve filters by scope" test_resolve_filters_by_scope_and_date

test_resolve_skips_already_done() {
    source "$SCHED_LIB"
    SCHED_MARKER_DIR="$TEST_TMPDIR"
    SCHED_MACHINE="wsl"
    SCHED_PROJECT="cfg-agent-fleet"
    sched_reset

    sched_task "done-task" --interval daily --scope fleet --exec auto --desc "Already done"
    sched_task "new-task" --interval daily --scope fleet --exec auto --desc "Not done yet"
    sched_mark_done "done-task" "daily"

    local due
    due=$(sched_resolve)
    assert_not_contains "$due" "done-task"
    assert_contains "$due" "new-task"
}
run_test "resolve skips already-done tasks" test_resolve_skips_already_done

test_resolve_groups_by_exec_type() {
    source "$SCHED_LIB"
    SCHED_MARKER_DIR="$TEST_TMPDIR"
    SCHED_MACHINE="wsl"
    SCHED_PROJECT="cfg-agent-fleet"
    sched_reset

    sched_task "auto-task" --interval daily --scope fleet --exec auto --desc "Auto"
    sched_task "prompted-task" --interval daily --scope fleet --exec prompted --desc "Prompted"
    sched_task "manual-task" --interval daily --scope fleet --exec manual --desc "Manual"

    local auto prompted manual
    auto=$(sched_resolve "auto")
    prompted=$(sched_resolve "prompted")
    manual=$(sched_resolve "manual")
    assert_contains "$auto" "auto-task"
    assert_contains "$prompted" "prompted-task"
    assert_contains "$manual" "manual-task"
    assert_not_contains "$auto" "prompted-task"
}
run_test "resolve groups by execution type" test_resolve_groups_by_exec_type

# ── Task execution ───────────────────────────────────────────────────────────

test_auto_exec_runs_command() {
    source "$SCHED_LIB"
    SCHED_MARKER_DIR="$TEST_TMPDIR"
    SCHED_MACHINE="wsl"
    SCHED_PROJECT="cfg-agent-fleet"
    sched_reset

    sched_task "echo-task" --interval daily --scope fleet --exec auto --desc "Echo test" \
        --cmd "echo TASK_RAN"

    local out
    out=$(sched_run_auto)
    assert_contains "$out" "TASK_RAN"
}
run_test "auto exec runs command and captures output" test_auto_exec_runs_command

test_auto_exec_marks_done() {
    source "$SCHED_LIB"
    SCHED_MARKER_DIR="$TEST_TMPDIR"
    SCHED_MACHINE="wsl"
    SCHED_PROJECT="cfg-agent-fleet"
    sched_reset

    sched_task "mark-task" --interval daily --scope fleet --exec auto --desc "Mark test" \
        --cmd "echo done"
    sched_run_auto >/dev/null

    if sched_is_due "mark-task" "daily"; then
        fail "task should be marked done after auto exec"
    fi
}
run_test "auto exec marks task done" test_auto_exec_marks_done

test_prompted_produces_warning() {
    source "$SCHED_LIB"
    SCHED_MARKER_DIR="$TEST_TMPDIR"
    SCHED_MACHINE="wsl"
    SCHED_PROJECT="cfg-agent-fleet"
    sched_reset

    sched_task "prompt-task" --interval daily --scope fleet --exec prompted --desc "Needs attention"

    local warnings
    warnings=$(sched_get_warnings)
    assert_contains "$warnings" "prompt-task"
    assert_contains "$warnings" "Needs attention"
}
run_test "prompted task produces warning text" test_prompted_produces_warning

test_manual_produces_reminder() {
    source "$SCHED_LIB"
    SCHED_MARKER_DIR="$TEST_TMPDIR"
    SCHED_MACHINE="wsl"
    SCHED_PROJECT="cfg-agent-fleet"
    sched_reset

    sched_task "remind-task" --interval weekly --scope fleet --exec manual --desc "Check something"

    local reminders
    reminders=$(sched_get_reminders)
    assert_contains "$reminders" "remind-task"
    assert_contains "$reminders" "Check something"
}
run_test "manual task produces reminder text" test_manual_produces_reminder

suite_summary
