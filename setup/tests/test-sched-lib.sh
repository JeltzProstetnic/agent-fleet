#!/usr/bin/env bash
# Tests for setup/scripts/sched-lib.sh — direct library function tests
# Focuses on edge cases and internal mechanics not covered by test-scheduled-tasks.sh.
source "$(dirname "$0")/test-helpers.sh"

SCHED_LIB="$REPO_ROOT/setup/scripts/sched-lib.sh"

suite_header "sched-lib.sh (scheduler library — direct function tests)"

# ── Helper ──────────────────────────────────────────────────────────────────

load_sched() {
    _SCHED_LIB_LOADED=""
    source "$SCHED_LIB"
    SCHED_MARKER_DIR="$TEST_TMPDIR"
    sched_reset
}

# ── _sched_valid internal validation ────────────────────────────────────────

test_valid_intervals_accepted() {
    load_sched
    for interval in every-session daily weekly monthly; do
        _sched_valid "$interval" "$_SCHED_VALID_INTERVALS" || {
            echo "interval '$interval' should be valid" >&2
            return 1
        }
    done
}
run_test "all defined intervals are accepted" test_valid_intervals_accepted

test_valid_scopes_accepted() {
    load_sched
    for scope in fleet per-machine per-project per-machine-project; do
        _sched_valid "$scope" "$_SCHED_VALID_SCOPES" || {
            echo "scope '$scope' should be valid" >&2
            return 1
        }
    done
}
run_test "all defined scopes are accepted" test_valid_scopes_accepted

test_valid_execs_accepted() {
    load_sched
    for exec_type in auto prompted manual; do
        _sched_valid "$exec_type" "$_SCHED_VALID_EXECS" || {
            echo "exec '$exec_type' should be valid" >&2
            return 1
        }
    done
}
run_test "all defined exec types are accepted" test_valid_execs_accepted

test_empty_value_rejected() {
    load_sched
    if _sched_valid "" "$_SCHED_VALID_INTERVALS"; then
        echo "empty value should be invalid" >&2
        return 1
    fi
}
run_test "empty string rejected as invalid value" test_empty_value_rejected

# ── _sched_date_key ─────────────────────────────────────────────────────────

test_date_key_every_session() {
    load_sched
    local key
    key=$(_sched_date_key "every-session")
    assert_eq "session" "$key" "every-session should return literal 'session'"
}
run_test "date key for every-session is literal 'session'" test_date_key_every_session

test_date_key_daily_format() {
    load_sched
    local key
    key=$(_sched_date_key "daily")
    # Should match YYYY-MM-DD format
    if [[ ! "$key" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        echo "daily key '$key' does not match YYYY-MM-DD" >&2
        return 1
    fi
}
run_test "date key for daily is YYYY-MM-DD format" test_date_key_daily_format

test_date_key_weekly_format() {
    load_sched
    local key
    key=$(_sched_date_key "weekly")
    # Should match YYYY-WNN format
    if [[ ! "$key" =~ ^[0-9]{4}-W[0-9]{2}$ ]]; then
        echo "weekly key '$key' does not match YYYY-WNN" >&2
        return 1
    fi
}
run_test "date key for weekly is YYYY-WNN format" test_date_key_weekly_format

test_date_key_monthly_format() {
    load_sched
    local key
    key=$(_sched_date_key "monthly")
    # Should match YYYY-MM format
    if [[ ! "$key" =~ ^[0-9]{4}-[0-9]{2}$ ]]; then
        echo "monthly key '$key' does not match YYYY-MM" >&2
        return 1
    fi
}
run_test "date key for monthly is YYYY-MM format" test_date_key_monthly_format

# ── sched_reset clears all arrays ───────────────────────────────────────────

test_reset_clears_all() {
    load_sched
    sched_task "t1" --interval daily --scope fleet --exec auto --desc "task"
    sched_task "t2" --interval weekly --scope fleet --exec manual --desc "task2"
    assert_eq "2" "$(sched_count)"
    sched_reset
    assert_eq "0" "$(sched_count)" "reset should clear all tasks"
}
run_test "sched_reset clears all registered tasks" test_reset_clears_all

# ── sched_mark_done overwrites stale marker ─────────────────────────────────

test_mark_done_overwrites_stale_marker() {
    load_sched
    # Write a stale marker manually
    mkdir -p "$SCHED_MARKER_DIR"
    echo "test-task=2020-01-01" > "$SCHED_MARKER_DIR/.sched-markers"
    # Task should be due because the marker is stale
    sched_is_due "test-task" "daily"
    assert_eq "0" "$?" "task with stale marker should be due"
    # Mark done — should overwrite with current date
    sched_mark_done "test-task" "daily"
    if sched_is_due "test-task" "daily"; then
        echo "task should NOT be due after mark_done" >&2
        return 1
    fi
}
run_test "mark_done overwrites stale date marker" test_mark_done_overwrites_stale_marker

# ── Multiple tasks in same marker file ──────────────────────────────────────

test_multiple_tasks_independent_markers() {
    load_sched
    sched_mark_done "alpha" "daily"
    sched_mark_done "beta" "daily"
    # Alpha should be done, gamma should be due
    local rc_alpha=0 rc_beta=0 rc_gamma=0
    sched_is_due "alpha" "daily" || rc_alpha=$?
    sched_is_due "beta" "daily" || rc_beta=$?
    sched_is_due "gamma" "daily" || rc_gamma=$?
    assert_eq "1" "$rc_alpha" "alpha should not be due"
    assert_eq "1" "$rc_beta" "beta should not be due"
    assert_eq "0" "$rc_gamma" "gamma (never marked) should be due"
}
run_test "multiple tasks have independent markers" test_multiple_tasks_independent_markers

# ── sched_matches_scope edge cases ──────────────────────────────────────────

test_unknown_scope_rejected() {
    load_sched
    SCHED_MACHINE="wsl"
    SCHED_PROJECT="test"
    if sched_matches_scope "global" "" ""; then
        echo "unknown scope should return 1" >&2
        return 1
    fi
}
run_test "unknown scope string rejected" test_unknown_scope_rejected

test_per_machine_empty_task_machine() {
    load_sched
    SCHED_MACHINE="wsl"
    if sched_matches_scope "per-machine" "" ""; then
        echo "per-machine with empty task_machine should fail" >&2
        return 1
    fi
}
run_test "per-machine rejects empty task machine" test_per_machine_empty_task_machine

test_per_project_empty_sched_project() {
    load_sched
    SCHED_PROJECT=""
    if sched_matches_scope "per-project" "" "cfg-agent-fleet"; then
        echo "per-project should fail when SCHED_PROJECT is empty" >&2
        return 1
    fi
}
run_test "per-project rejects when SCHED_PROJECT is empty" test_per_project_empty_sched_project

# ── sched_resolve with mixed types ──────────────────────────────────────────

test_resolve_every_session_always_included() {
    load_sched
    SCHED_MACHINE="wsl"
    SCHED_PROJECT="test"
    sched_task "always" --interval every-session --scope fleet --exec auto --desc "Always runs"
    # Mark done should have no effect for every-session
    sched_mark_done "always" "every-session"
    local due
    due=$(sched_resolve "auto")
    assert_contains "$due" "always" "every-session task should always resolve as due"
}
run_test "resolve always includes every-session tasks" test_resolve_every_session_always_included

test_resolve_empty_when_no_tasks() {
    load_sched
    SCHED_MACHINE="wsl"
    SCHED_PROJECT="test"
    local due
    due=$(sched_resolve)
    assert_eq "" "$due" "resolve with no tasks should return empty"
}
run_test "resolve returns empty when no tasks registered" test_resolve_empty_when_no_tasks

# ── sched_run_auto with no cmd ──────────────────────────────────────────────

test_auto_no_cmd_does_not_fail() {
    load_sched
    SCHED_MACHINE="wsl"
    SCHED_PROJECT="test"
    sched_task "no-cmd" --interval daily --scope fleet --exec auto --desc "No command"
    # Should not error even though --cmd was not provided
    local rc=0
    sched_run_auto 2>/dev/null || rc=$?
    assert_eq "0" "$rc" "auto task without cmd should not fail"
}
run_test "auto exec with no --cmd does not fail" test_auto_no_cmd_does_not_fail

# ── sched_get_warnings output format ───────────────────────────────────────

test_warnings_output_format() {
    load_sched
    SCHED_MACHINE="wsl"
    SCHED_PROJECT="test"
    sched_task "fmt-test" --interval daily --scope fleet --exec prompted --desc "Format check"
    local warnings
    warnings=$(sched_get_warnings)
    assert_contains "$warnings" "[PROMPTED]" "warnings should have [PROMPTED] prefix"
    assert_contains "$warnings" "fmt-test" "warnings should contain task ID"
    assert_contains "$warnings" "Format check" "warnings should contain description"
}
run_test "get_warnings output has correct format" test_warnings_output_format

# ── sched_get_reminders output format ──────────────────────────────────────

test_reminders_output_format() {
    load_sched
    SCHED_MACHINE="wsl"
    SCHED_PROJECT="test"
    sched_task "rem-test" --interval weekly --scope fleet --exec manual --desc "Reminder check"
    local reminders
    reminders=$(sched_get_reminders)
    assert_contains "$reminders" "[REMINDER]" "reminders should have [REMINDER] prefix"
    assert_contains "$reminders" "rem-test" "reminders should contain task ID"
    assert_contains "$reminders" "Reminder check" "reminders should contain description"
}
run_test "get_reminders output has correct format" test_reminders_output_format

# ── Marker file path correctness ───────────────────────────────────────────

test_marker_file_path() {
    load_sched
    local expected="$TEST_TMPDIR/.sched-markers"
    local actual
    actual=$(_sched_marker_file)
    assert_eq "$expected" "$actual" "marker file path should use SCHED_MARKER_DIR"
}
run_test "marker file path uses SCHED_MARKER_DIR" test_marker_file_path

test_custom_marker_dir() {
    load_sched
    SCHED_MARKER_DIR="$TEST_TMPDIR/custom/path"
    sched_mark_done "custom" "daily"
    assert_file_exists "$TEST_TMPDIR/custom/path/.sched-markers" "should create marker in custom dir"
}
run_test "custom SCHED_MARKER_DIR is respected" test_custom_marker_dir

# ── sched_task stores all fields ────────────────────────────────────────────

test_task_stores_machine_and_project() {
    load_sched
    SCHED_MACHINE="office"
    SCHED_PROJECT="cfg-agent-fleet"
    sched_task "stored" --interval daily --scope per-machine-project \
        --exec auto --desc "Stored fields" --machine office --project cfg-agent-fleet \
        --cmd "echo hi"
    # Verify via scope matching that the stored values work
    sched_matches_scope "per-machine-project" "office" "cfg-agent-fleet"
    assert_eq "0" "$?" "stored machine and project should match"
}
run_test "sched_task stores machine and project fields" test_task_stores_machine_and_project

suite_summary
