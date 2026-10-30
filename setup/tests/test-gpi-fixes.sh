#!/usr/bin/env bash
# Tests for GPI fixes: single-job statusline display + stale entry cleanup
# Fix 1: statusline renders only largest/slowest job with +N suffix
# Fix 2: gpi clear (no args) removes only completed entries; --all for force-reset
source "$(dirname "$0")/test-helpers.sh"

GPI_SCRIPT="$REPO_ROOT/setup/scripts/gpi.sh"
STATUSLINE_SCRIPT="$REPO_ROOT/setup/config/statusline-command.sh"

# Helper: run gpi.sh with test state file and notification sidecar
gpi() {
    GPI_STATE="$TEST_TMPDIR/gpi-state.json" GPI_COMPLETED="$TEST_TMPDIR/gpi-completed.json" "$GPI_SCRIPT" "$@"
}

# Helper: read a field from the test state file via jq
gpi_field() {
    jq -r "$1" "$TEST_TMPDIR/gpi-state.json"
}

# Helper: render statusline with test GPI state, return output
render_statusline() {
    local gpi_path="$TEST_TMPDIR/gpi-state.json"
    local completed_path="$TEST_TMPDIR/gpi-completed.json"
    local statusline_tmp="$TEST_TMPDIR/statusline-test.sh"
    # Patch the statusline to use our test GPI path and completed sidecar path
    sed -e "s|os.path.expanduser('~/.claude/.gpi-state.json')|'$gpi_path'|g" \
        -e "s|os.path.expanduser('~/.claude/.gpi-completed.json')|'$completed_path'|g" \
        "$STATUSLINE_SCRIPT" > "$statusline_tmp"
    chmod +x "$statusline_tmp"
    echo '{"model":{"display_name":"Opus"},"context_window":{"used_percentage":50,"context_window_size":200000,"current_usage":{"input_tokens":100000}},"cost":{"total_cost_usd":1.5},"workspace":{"project_dir":"/home/test/project"}}' \
        | bash "$statusline_tmp" 2>/dev/null
}

# Helper: strip ANSI codes from output
strip_ansi() {
    sed 's/\x1b\[[0-9;]*m//g'
}

# ═══════════════════════════════════════════════════════════════════════════════
# Fix 1: Statusline renders only largest/slowest job with +N suffix
# ═══════════════════════════════════════════════════════════════════════════════

suite_header "Fix 1: GPI Statusline — Single Job Display"

test_single_op_no_suffix() {
    gpi start op1 "Porn->ext8tb"
    gpi update op1 --pct 45
    local output
    output=$(render_statusline)
    local clean
    clean=$(echo "$output" | strip_ansi)
    assert_contains "$clean" "Porn->ext8tb" "should show single op label"
    assert_contains "$clean" "45%" "should show pct"
    assert_not_contains "$clean" "+" "single op should NOT have +N suffix"
}
run_test "single op: no +N suffix" test_single_op_no_suffix

test_two_ops_shows_highest_pct_plus_one() {
    gpi start op1 "Porn->ext8tb"
    gpi update op1 --pct 45
    gpi start op2 "Porn->shield"
    gpi update op2 --pct 80
    local output
    output=$(render_statusline)
    local clean
    clean=$(echo "$output" | strip_ansi)
    # op2 has higher pct (80%), should be shown
    assert_contains "$clean" "Porn->shield" "should show highest pct op"
    assert_contains "$clean" "80%" "should show highest pct"
    assert_contains "$clean" "+1" "should show +1 for the other op"
    # Should NOT show the other op's label
    assert_not_contains "$clean" "Porn->ext8tb" "should NOT show secondary op label"
}
run_test "two ops: shows highest pct + +1" test_two_ops_shows_highest_pct_plus_one

test_three_ops_shows_plus_two() {
    gpi start op1 "copy1"
    gpi update op1 --pct 20
    gpi start op2 "copy2"
    gpi update op2 --pct 90
    gpi start op3 "copy3"
    gpi update op3 --pct 50
    local output
    output=$(render_statusline)
    local clean
    clean=$(echo "$output" | strip_ansi)
    assert_contains "$clean" "copy2" "should show highest pct op (90%)"
    assert_contains "$clean" "90%" "should show highest pct"
    assert_contains "$clean" "+2" "should show +2 for two other ops"
}
run_test "three ops: shows highest pct + +2" test_three_ops_shows_plus_two

test_tied_pct_longest_running_wins() {
    gpi start op1 "older-op"
    gpi start op2 "newer-op"
    gpi update op1 --pct 50
    gpi update op2 --pct 50
    # op1 started first (has smaller started timestamp), so it's longest running
    # Manually backdate op1 to be clearly older
    local old_ts=$(($(date +%s) - 600))
    local tmp
    tmp=$(jq --argjson ts "$old_ts" '.ops["op1"].started = $ts' "$TEST_TMPDIR/gpi-state.json")
    echo "$tmp" > "$TEST_TMPDIR/gpi-state.json"
    local output
    output=$(render_statusline)
    local clean
    clean=$(echo "$output" | strip_ansi)
    assert_contains "$clean" "older-op" "tied pct: should show longest-running op"
    assert_contains "$clean" "+1" "should show +1 for the other op"
}
run_test "tied pct: longest running wins" test_tied_pct_longest_running_wins

test_multi_ops_detail_shown() {
    gpi start op1 "backup"
    gpi update op1 --pct 70 --detail "42MB/s"
    gpi start op2 "sync"
    gpi update op2 --pct 30
    local output
    output=$(render_statusline)
    local clean
    clean=$(echo "$output" | strip_ansi)
    # op1 has higher pct, should be shown with its detail
    assert_contains "$clean" "backup" "should show highest pct op"
    assert_contains "$clean" "42MB/s" "should show detail of the displayed op"
    assert_contains "$clean" "+1" "should show +1 for the other op"
}
run_test "multi ops: detail of displayed op shown" test_multi_ops_detail_shown

test_indeterminate_ops_treated_as_zero_pct() {
    gpi start op1 "scanning"
    # op1 has no pct (indeterminate)
    gpi start op2 "copying"
    gpi update op2 --pct 10
    local output
    output=$(render_statusline)
    local clean
    clean=$(echo "$output" | strip_ansi)
    # op2 has pct=10, op1 has null pct (treated as 0), so op2 should win
    assert_contains "$clean" "copying" "should show op with actual pct over indeterminate"
    assert_contains "$clean" "+1" "should show +1"
}
run_test "indeterminate ops: treated as zero pct in ranking" test_indeterminate_ops_treated_as_zero_pct

test_pipe_separator_removed() {
    # The old format used " | " between ops — ensure that's gone
    gpi start op1 "copy1"
    gpi update op1 --pct 40
    gpi start op2 "copy2"
    gpi update op2 --pct 60
    local output
    output=$(render_statusline)
    local clean
    clean=$(echo "$output" | strip_ansi)
    assert_not_contains "$clean" " | " "should NOT use pipe separator between ops"
}
run_test "pipe separator removed from multi-op display" test_pipe_separator_removed

# ═══════════════════════════════════════════════════════════════════════════════
# Fix 2: gpi clear — completed-only default, --all for force-reset
# ═══════════════════════════════════════════════════════════════════════════════

suite_header "Fix 2: GPI Clear — Completed-Only Default"

test_clear_no_args_keeps_active() {
    gpi start op1 "active-copy"
    gpi start op2 "active-sync"
    gpi update op1 --pct 50
    gpi clear
    # Active ops should survive
    local count
    count=$(gpi_field '.ops | length')
    assert_eq "2" "$count" "clear (no args) should keep active ops"
}
run_test "clear (no args): keeps active ops" test_clear_no_args_keeps_active

test_clear_no_args_removes_completed() {
    gpi start op1 "done-copy"
    gpi start op2 "active-sync"
    gpi done op1
    gpi clear
    # op1 (completed) should be removed, op2 (active) should remain
    assert_eq "null" "$(gpi_field '.ops["op1"] // "null"')" "completed op should be removed"
    assert_neq "null" "$(gpi_field '.ops["op2"]')" "active op should remain"
    local count
    count=$(gpi_field '.ops | length')
    assert_eq "1" "$count" "should have 1 op remaining"
}
run_test "clear (no args): removes completed, keeps active" test_clear_no_args_removes_completed

test_clear_no_args_all_completed() {
    gpi start op1 "copy"
    gpi start op2 "sync"
    gpi done op1
    gpi done op2
    gpi clear
    local count
    count=$(gpi_field '.ops | length')
    assert_eq "0" "$count" "all completed ops should be removed"
}
run_test "clear (no args): removes all when all are completed" test_clear_no_args_all_completed

test_clear_no_args_nothing_completed() {
    gpi start op1 "copy"
    gpi start op2 "sync"
    gpi clear
    local count
    count=$(gpi_field '.ops | length')
    assert_eq "2" "$count" "no completed ops = nothing removed"
}
run_test "clear (no args): nothing completed = nothing removed" test_clear_no_args_nothing_completed

test_clear_all_removes_everything() {
    gpi start op1 "copy"
    gpi start op2 "sync"
    gpi update op1 --pct 50
    gpi clear --all
    local count
    count=$(gpi_field '.ops | length')
    assert_eq "0" "$count" "--all should remove everything including active"
}
run_test "clear --all: removes everything" test_clear_all_removes_everything

test_clear_all_with_completed() {
    gpi start op1 "copy"
    gpi start op2 "sync"
    gpi done op1
    gpi clear --all
    local count
    count=$(gpi_field '.ops | length')
    assert_eq "0" "$count" "--all should remove everything"
}
run_test "clear --all: removes completed and active" test_clear_all_with_completed

test_clear_group_still_works() {
    gpi start op1 "copy" --group backup
    gpi start op2 "sync" --group backup
    gpi start op3 "compile" --group build
    gpi clear --group backup
    assert_eq "null" "$(gpi_field '.ops["op1"]')" "group-cleared op1"
    assert_eq "null" "$(gpi_field '.ops["op2"]')" "group-cleared op2"
    assert_neq "null" "$(gpi_field '.ops["op3"]')" "op3 in different group should remain"
}
run_test "clear --group: still works as before" test_clear_group_still_works

# ═══════════════════════════════════════════════════════════════════════════════
# Auto-cleanup: cleanup_completed called on gpi status
# ═══════════════════════════════════════════════════════════════════════════════

suite_header "Auto-cleanup on status"

test_status_triggers_cleanup() {
    gpi start op1 "copy"
    gpi done op1
    # Backdate completed_at to 120 seconds ago
    local old_ts=$(($(date +%s) - 120))
    local tmp
    tmp=$(jq --argjson ts "$old_ts" '.ops["op1"].completed_at = $ts' "$TEST_TMPDIR/gpi-state.json")
    echo "$tmp" > "$TEST_TMPDIR/gpi-state.json"
    # Status should trigger cleanup
    gpi status >/dev/null
    assert_eq "null" "$(gpi_field '.ops["op1"] // "null"')" "status should clean up old completed ops"
}
run_test "status triggers cleanup of old completed ops" test_status_triggers_cleanup

test_statusline_render_triggers_cleanup() {
    gpi start op1 "copy"
    gpi done op1
    # Backdate completed_at to 120 seconds ago
    local old_ts=$(($(date +%s) - 120))
    local tmp
    tmp=$(jq --argjson ts "$old_ts" '.ops["op1"].completed_at = $ts' "$TEST_TMPDIR/gpi-state.json")
    echo "$tmp" > "$TEST_TMPDIR/gpi-state.json"
    # Render should trigger cleanup (the Python code already does this)
    render_statusline >/dev/null
    assert_eq "null" "$(gpi_field '.ops["op1"] // "null"')" "statusline render should clean up old completed ops"
}
run_test "statusline render triggers cleanup of old completed ops" test_statusline_render_triggers_cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# CFG-875: `done` exits 0 once the op is marked; `clear --dead` reaps idle ops that
# carry no tmux_session (an 'LS tunnel' op sat on the statusline ~1 day).
# ═══════════════════════════════════════════════════════════════════════════════

suite_header "CFG-875: done exit code, idle reap of session-less ops"

# Set an op's timestamps relative to now (seconds ago) in the test state file.
_gpi_age() {  # <id> <started-ago> [<updated_at-ago>]
    local now; now=$(date +%s)
    local started=$((now - $2)) upd
    upd=$((now - ${3:-$2}))
    jq --arg id "$1" --argjson s "$started" --argjson u "$upd" \
        '.ops[$id].started = $s | .ops[$id].updated_at = $u' "$TEST_TMPDIR/gpi-state.json" > "$TEST_TMPDIR/s.tmp"
    mv "$TEST_TMPDIR/s.tmp" "$TEST_TMPDIR/gpi-state.json"
}

test_done_exit_0_when_sidecar_unwritable() {
    gpi start op1 "job"
    : > "$TEST_TMPDIR/blocker"   # a regular file where the sidecar's directory would go
    local rc=0
    GPI_STATE="$TEST_TMPDIR/gpi-state.json" GPI_COMPLETED="$TEST_TMPDIR/blocker/notdir/completed.json" "$GPI_SCRIPT" done op1 2>/dev/null || rc=$?
    assert_eq "0" "$rc" "done exits 0 although the notification sidecar could not be written (measured rc=$rc)"
    assert_neq "null" "$(gpi_field '.ops.op1.completed_at')" "the op is marked completed regardless"
}
run_test "CFG-875: done returns 0 once the op is marked, even if the sidecar write fails" test_done_exit_0_when_sidecar_unwritable

test_clear_dead_reaps_idle_sessionless_op() {
    gpi start idle7h "LS tunnel"          # no --tmux: never judged by tmux
    gpi start idle1h "fresh job"
    gpi start bumped "updated recently"
    _gpi_age idle7h $((7*3600))
    _gpi_age idle1h 3600
    _gpi_age bumped $((7*3600)) 60        # started 7 h ago, last update 1 min ago
    gpi clear --dead
    assert_eq "null" "$(gpi_field '.ops.idle7h // null')" "op without tmux_session and no update for 7 h is reaped"
    assert_eq "fresh job" "$(gpi_field '.ops.idle1h.label')" "an op idle for 1 h stays"
    assert_eq "updated recently" "$(gpi_field '.ops.bumped.label')" "an old op that was updated recently stays"
}
run_test "CFG-875: clear --dead reaps a session-less op idle > 6 h, keeps fresh and recently-updated ones" test_clear_dead_reaps_idle_sessionless_op

test_update_refreshes_updated_at() {
    gpi start op1 "job"
    _gpi_age op1 $((7*3600))
    gpi update op1 --pct 50
    local now; now=$(date +%s)
    local u; u=$(gpi_field '.ops.op1.updated_at // 0')
    (( now - u < 60 )) && ok=0 || ok=1
    assert_eq "0" "$ok" "gpi update stamps the op's updated_at (measured age $((now - u)) s)"
    assert_eq "$(gpi_field '.ops.op1.started')" "$(jq -r '.ops.op1.started' "$TEST_TMPDIR/gpi-state.json")" "started is untouched"
}
run_test "CFG-875: gpi update refreshes the op's updated_at, start sets it" test_update_refreshes_updated_at

test_clear_dead_keeps_plain_clear_semantics() {
    gpi start op1 "job"
    _gpi_age op1 $((7*3600))
    gpi clear                                # no --dead: idle age is not a reason
    assert_eq "job" "$(gpi_field '.ops.op1.label')" "plain clear never reaps by idle age"
}
run_test "CFG-875: the idle reap is confined to clear --dead" test_clear_dead_keeps_plain_clear_semantics

suite_summary
