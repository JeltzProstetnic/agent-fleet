#!/usr/bin/env bash
# Tests for GPI (Grind Progress Indicator) — setup/scripts/gpi.sh + statusline rendering
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

suite_header "GPI CLI Tests"

# ── CLI Tests ────────────────────────────────────────────────────────────────

test_start_creates_state_file() {
    gpi start test-op "testing"
    assert_file_exists "$TEST_TMPDIR/gpi-state.json"
    local label
    label=$(gpi_field '.ops["test-op"].label')
    assert_eq "testing" "$label"
}
run_test "start creates state file" test_start_creates_state_file

test_start_sets_timestamp() {
    gpi start foo "label"
    local started
    started=$(gpi_field '.ops["foo"].started')
    assert_neq "null" "$started" "started should be set"
    local updated
    updated=$(gpi_field '.updated')
    assert_neq "null" "$updated" "updated should be set"
}
run_test "start sets timestamps" test_start_sets_timestamp

test_start_with_seq() {
    gpi start backup "rsync" --seq 3/7
    local idx total
    idx=$(gpi_field '.ops["backup"].seq_index')
    total=$(gpi_field '.ops["backup"].seq_total')
    assert_eq "3" "$idx"
    assert_eq "7" "$total"
}
run_test "start with --seq parses n/m" test_start_with_seq

test_start_with_group() {
    gpi start op1 "copy" --group storage
    local grp
    grp=$(gpi_field '.ops["op1"].group')
    assert_eq "storage" "$grp"
}
run_test "start with --group sets group" test_start_with_group

test_start_with_eta() {
    gpi start op1 "copy" --eta 300
    local eta
    eta=$(gpi_field '.ops["op1"].eta_secs')
    assert_eq "300" "$eta"
}
run_test "start with --eta sets eta_secs" test_start_with_eta

test_start_overwrites_existing() {
    gpi start op1 "old-label"
    gpi start op1 "new-label"
    local label
    label=$(gpi_field '.ops["op1"].label')
    assert_eq "new-label" "$label"
    local count
    count=$(gpi_field '.ops | length')
    assert_eq "1" "$count"
}
run_test "start overwrites existing op" test_start_overwrites_existing

test_update_merges_fields() {
    gpi start op1 "copy"
    gpi update op1 --pct 50 --detail "2.1G 95MB/s"
    local pct detail label
    pct=$(gpi_field '.ops["op1"].pct')
    detail=$(gpi_field '.ops["op1"].detail')
    label=$(gpi_field '.ops["op1"].label')
    assert_eq "50" "$pct"
    assert_eq "2.1G 95MB/s" "$detail"
    assert_eq "copy" "$label" "label should be preserved"
}
run_test "update merges fields" test_update_merges_fields

test_update_nonexistent_fails() {
    assert_failure gpi update nonexistent --pct 50
}
run_test "update nonexistent op fails" test_update_nonexistent_fails

test_update_eta() {
    gpi start op1 "copy"
    gpi update op1 --eta 120
    local eta
    eta=$(gpi_field '.ops["op1"].eta_secs')
    assert_eq "120" "$eta"
}
run_test "update eta" test_update_eta

test_done_sets_completed_at() {
    gpi start op1 "copy"
    gpi start op2 "sync"
    gpi done op1
    local completed_at
    completed_at=$(gpi_field '.ops["op1"].completed_at')
    assert_neq "null" "$completed_at" "op1 should have completed_at set" || return 1
    assert_neq "null" "$(gpi_field '.ops["op2"]')" "op2 should remain" || return 1
    assert_eq "null" "$(gpi_field '.ops["op2"].completed_at // "null"')" "op2 should not be completed"
}
run_test "done sets completed_at" test_done_sets_completed_at

test_done_preserves_label() {
    gpi start op1 "copy"
    gpi done op1
    local label
    label=$(gpi_field '.ops["op1"].label')
    assert_eq "copy" "$label" "label should be preserved after done"
}
run_test "done preserves label" test_done_preserves_label

test_done_writes_notification_sidecar() {
    gpi start op1 "copy"
    gpi done op1
    assert_file_exists "$TEST_TMPDIR/gpi-completed.json" "notification sidecar should exist"
    local notif_label
    notif_label=$(jq -r '.[0].label' "$TEST_TMPDIR/gpi-completed.json")
    assert_eq "copy" "$notif_label" "sidecar should contain label"
}
run_test "done writes notification sidecar" test_done_writes_notification_sidecar

test_cleanup_removes_old_completed() {
    gpi start op1 "copy"
    gpi done op1
    # Backdate completed_at to 120 seconds ago
    local old_ts=$(($(date +%s) - 120))
    local tmp
    tmp=$(jq --argjson ts "$old_ts" '.ops["op1"].completed_at = $ts' "$TEST_TMPDIR/gpi-state.json")
    echo "$tmp" > "$TEST_TMPDIR/gpi-state.json"
    # Any gpi command should trigger cleanup
    gpi status >/dev/null
    assert_eq "null" "$(gpi_field '.ops["op1"] // "null"')" "old completed op should be cleaned up"
}
run_test "cleanup removes old completed ops" test_cleanup_removes_old_completed

test_cleanup_keeps_recent_completed() {
    gpi start op1 "copy"
    gpi done op1
    # completed_at is just now, should survive cleanup
    gpi status >/dev/null
    assert_neq "null" "$(gpi_field '.ops["op1"]')" "recently completed op should survive cleanup"
}
run_test "cleanup keeps recent completed ops" test_cleanup_keeps_recent_completed

test_clear_removes_all() {
    gpi start op1 "copy"
    gpi start op2 "sync"
    gpi clear --all
    local count
    count=$(gpi_field '.ops | length')
    assert_eq "0" "$count"
}
run_test "clear --all removes all" test_clear_removes_all

test_clear_group_selective() {
    gpi start op1 "copy" --group backup
    gpi start op2 "sync" --group backup
    gpi start op3 "compile" --group build
    gpi clear --group backup
    assert_eq "null" "$(gpi_field '.ops["op1"]')"
    assert_eq "null" "$(gpi_field '.ops["op2"]')"
    assert_neq "null" "$(gpi_field '.ops["op3"]')" "op3 in different group should remain"
}
run_test "clear --group removes only that group" test_clear_group_selective

test_status_readable() {
    gpi start op1 "copying" --pct 45 --group backup --seq 2/5
    # pct via start isn't supported, use update
    gpi update op1 --pct 45
    local output
    output=$(gpi status)
    assert_contains "$output" "op1"
    assert_contains "$output" "copying"
    assert_contains "$output" "45"
}
run_test "status prints readable summary" test_status_readable

test_concurrent_updates() {
    gpi start op1 "copy"
    gpi start op2 "sync"
    # Run 10 concurrent updates
    for i in $(seq 1 10); do
        gpi update op1 --pct $((i * 10)) &
        gpi update op2 --pct $((i * 5)) &
    done
    wait
    # File should still be valid JSON
    assert_success jq '.' "$TEST_TMPDIR/gpi-state.json"
    # Both ops should still exist
    assert_neq "null" "$(gpi_field '.ops["op1"]')"
    assert_neq "null" "$(gpi_field '.ops["op2"]')"
}
run_test "concurrent updates don't corrupt" test_concurrent_updates

# ── Statusline Rendering Tests ───────────────────────────────────────────────

suite_header "GPI Statusline Rendering Tests"

test_render_no_state_file() {
    rm -f "$TEST_TMPDIR/gpi-state.json"
    local output
    output=$(render_statusline)
    # Should have basic statusline but no GPI bracket
    assert_contains "$output" "project"
    assert_not_contains "$output" "[rsync" "should not have old rsync indicator"
}
run_test "no state file = no GPI indicator" test_render_no_state_file

test_render_single_op() {
    gpi start rsync-fms "rsync"
    gpi update rsync-fms --pct 45 --detail "25.5G"
    local output
    output=$(render_statusline)
    assert_contains "$output" "rsync"
    assert_contains "$output" "45%"
}
run_test "single op renders label + pct" test_render_single_op

test_render_sequential() {
    gpi start backup "rsync" --seq 3/7
    gpi update backup --pct 45
    local output
    output=$(render_statusline)
    assert_contains "$output" "3/7"
    assert_contains "$output" "rsync"
    assert_contains "$output" "45%"
}
run_test "sequential op renders n/m" test_render_sequential

test_render_indeterminate() {
    gpi start scan "scanning"
    # No pct set — should be null/indeterminate
    local output
    output=$(render_statusline)
    assert_contains "$output" "scanning"
    assert_contains "$output" "..."
}
run_test "indeterminate op shows dots" test_render_indeterminate

test_render_parallel() {
    gpi start op1 "rsync" --eta 300
    gpi update op1 --pct 45
    gpi start op2 "compile" --eta 60
    gpi update op2 --pct 80
    local output
    output=$(render_statusline)
    # Should show only the highest-pct op (compile 80%) with +1 suffix
    assert_contains "$output" "compile" || return 1
    assert_contains "$output" "80%" || return 1
    assert_contains "$output" "+1" || return 1
}
run_test "parallel ops show highest pct + count" test_render_parallel

test_render_completed_op_briefly() {
    gpi start op1 "copy"
    gpi done op1
    local output
    output=$(render_statusline)
    # Recently completed op should show with DONE indicator
    assert_contains "$output" "copy" "recently completed op should still render"
    assert_contains "$output" "DONE" "completed op should show DONE"
}
run_test "completed op renders briefly with DONE" test_render_completed_op_briefly

test_render_completed_op_hidden_after_60s() {
    gpi start op1 "copy"
    gpi done op1
    # Backdate completed_at to 90 seconds ago
    local old_ts=$(($(date +%s) - 90))
    local tmp
    tmp=$(jq --argjson ts "$old_ts" '.ops["op1"].completed_at = $ts' "$TEST_TMPDIR/gpi-state.json")
    echo "$tmp" > "$TEST_TMPDIR/gpi-state.json"
    local output
    output=$(render_statusline)
    assert_not_contains "$output" "copy" "completed op >60s should be hidden"
}
run_test "completed op hidden after 60s" test_render_completed_op_hidden_after_60s

test_render_stale_state() {
    gpi start op1 "copy"
    gpi update op1 --pct 50
    # Manually set updated to 400 seconds ago
    local old_ts=$(($(date +%s) - 400))
    local tmp
    tmp=$(jq --argjson ts "$old_ts" '.updated = $ts' "$TEST_TMPDIR/gpi-state.json")
    echo "$tmp" > "$TEST_TMPDIR/gpi-state.json"
    local output
    output=$(render_statusline)
    # Should render dimmed (contains \033[2m)
    assert_contains "$output" "copy" "stale but <600s should still render"
}
run_test "stale state (>300s) still renders" test_render_stale_state

test_render_very_stale_state() {
    gpi start op1 "copy"
    gpi update op1 --pct 50
    # Manually set updated to 700 seconds ago
    local old_ts=$(($(date +%s) - 700))
    local tmp
    tmp=$(jq --argjson ts "$old_ts" '.updated = $ts' "$TEST_TMPDIR/gpi-state.json")
    echo "$tmp" > "$TEST_TMPDIR/gpi-state.json"
    local output
    output=$(render_statusline)
    # Should NOT render GPI at all
    assert_not_contains "$output" "copy" "very stale (>600s) should be hidden"
}
run_test "very stale state (>600s) renders nothing" test_render_very_stale_state

test_render_malformed_json() {
    echo "not json{{{" > "$TEST_TMPDIR/gpi-state.json"
    local output
    output=$(render_statusline)
    # Should not crash — still renders basic statusline
    assert_contains "$output" "project"
    assert_not_contains "$output" "[?] ..." "should not show error indicator"
}
run_test "malformed JSON handled gracefully" test_render_malformed_json

# ── Log Enrichment Tests (ir-chk, raw bytes, dedup, staleness) ──────────────

suite_header "GPI Log Enrichment Tests"

test_log_irchk_progress() {
    local logfile="$TEST_TMPDIR/rsync.log"
    # Real rsync output — completed file with ir-chk
    printf '         32,768   0%%  167.54kB/s    0:00:42        7,087,616 100%%   19.71MB/s    0:00:00 (xfr#1352, ir-chk=1009/2448)\n' > "$logfile"
    gpi start rsync-test "backup" --log "$logfile"
    local output
    output=$(render_statusline)
    # ir-chk=1009/2448 → (2448-1009)/2448*100 = 58%
    assert_contains "$output" "58%" "should show overall progress from ir-chk"
}
run_test "ir-chk parsed for overall progress" test_log_irchk_progress

test_log_no_raw_bytes() {
    local logfile="$TEST_TMPDIR/rsync.log"
    printf '         32,768   0%%  167.54kB/s    0:00:42        7,087,616 100%%   19.71MB/s    0:00:00 (xfr#1352, ir-chk=1009/2448)\n' > "$logfile"
    gpi start rsync-test "backup" --log "$logfile"
    local output
    output=$(render_statusline)
    assert_not_contains "$output" "32,768" "raw bytes should NOT be in display" || return 1
    assert_not_contains "$output" "7,087,616" "final bytes should NOT be in display" || return 1
}
run_test "raw bytes stripped from display" test_log_no_raw_bytes

test_log_no_pct_duplication() {
    local logfile="$TEST_TMPDIR/rsync.log"
    printf '         32,768   0%%  167.54kB/s    0:00:42        7,087,616 100%%   19.71MB/s    0:00:00 (xfr#1352, ir-chk=1009/2448)\n' > "$logfile"
    gpi start rsync-test "backup" --log "$logfile"
    local output
    output=$(render_statusline)
    # Strip ANSI codes for counting
    local clean
    clean=$(echo "$output" | sed 's/\x1b\[[0-9;]*m//g')
    # Count % occurrences — should be exactly 2: context bar (50%) + GPI (58%)
    local pct_count
    pct_count=$(echo "$clean" | grep -oP '\d+%' | wc -l)
    if [[ "$pct_count" -gt 2 ]]; then
        printf "    percentage appears %d times — duplication detected\n    clean output: %s\n" "$pct_count" "$clean" >&2
        return 1
    fi
}
run_test "percentage not duplicated in display" test_log_no_pct_duplication

test_log_active_prevents_staleness() {
    local logfile="$TEST_TMPDIR/rsync.log"
    printf '         32,768   0%%   60.72kB/s    0:10:44\n' > "$logfile"
    gpi start rsync-test "backup" --log "$logfile"
    # Set updated to 700 seconds ago (normally "very stale" = hidden)
    local old_ts=$(($(date +%s) - 700))
    local tmp
    tmp=$(jq --argjson ts "$old_ts" '.updated = $ts' "$TEST_TMPDIR/gpi-state.json")
    echo "$tmp" > "$TEST_TMPDIR/gpi-state.json"
    # Touch the log file to make it recent
    touch "$logfile"
    local output
    output=$(render_statusline)
    assert_contains "$output" "backup" "active log file should prevent staleness dismissal"
}
run_test "active log file prevents staleness" test_log_active_prevents_staleness

test_log_speed_shown() {
    local logfile="$TEST_TMPDIR/rsync.log"
    printf '         32,768   0%%  167.54kB/s    0:00:42        7,087,616 100%%   19.71MB/s    0:00:00 (xfr#1352, ir-chk=1009/2448)\n' > "$logfile"
    gpi start rsync-test "backup" --log "$logfile"
    local output
    output=$(render_statusline)
    assert_contains "$output" "MB/s" "should show speed in display"
}
run_test "speed shown in display" test_log_speed_shown

test_log_inprogress_no_bytes() {
    # In-progress file: no ir-chk, just initial transfer stats
    local logfile="$TEST_TMPDIR/rsync.log"
    printf '         32,768   0%%   60.72kB/s    0:10:44\n' > "$logfile"
    gpi start rsync-test "backup" --log "$logfile"
    local output
    output=$(render_statusline)
    assert_contains "$output" "kB/s" "should show speed" || return 1
    assert_not_contains "$output" "32,768" "raw bytes should NOT be in display" || return 1
}
run_test "in-progress line shows speed only" test_log_inprogress_no_bytes

test_log_done_marker() {
    local logfile="$TEST_TMPDIR/rsync.log"
    printf 'some data\nRSYNC COMPLETE\n' > "$logfile"
    gpi start rsync-test "backup" --log "$logfile"
    local output
    output=$(render_statusline)
    assert_contains "$output" "DONE" "RSYNC COMPLETE should show DONE"
}
run_test "RSYNC COMPLETE shows DONE" test_log_done_marker

test_log_done_sets_completed_at_in_state() {
    local logfile="$TEST_TMPDIR/rsync.log"
    printf 'some data\nRSYNC COMPLETE\n' > "$logfile"
    gpi start rsync-test "backup" --log "$logfile"
    render_statusline >/dev/null
    # Renderer should have written completed_at to state
    local completed_at
    completed_at=$(gpi_field '.ops["rsync-test"].completed_at // "null"')
    assert_neq "null" "$completed_at" "renderer should set completed_at when log shows completion"
}
run_test "log completion sets completed_at in state" test_log_done_sets_completed_at_in_state

test_log_done_writes_notification() {
    local logfile="$TEST_TMPDIR/rsync.log"
    printf 'some data\nRSYNC COMPLETE\n' > "$logfile"
    gpi start rsync-test "backup" --log "$logfile"
    render_statusline >/dev/null
    # Renderer should have written notification sidecar
    local notif_file="$TEST_TMPDIR/gpi-completed.json"
    # Need to patch sidecar path too — will add to render_statusline helper
    assert_file_exists "$TEST_TMPDIR/gpi-completed.json" "notification sidecar should exist after log completion"
}
run_test "log completion writes notification sidecar" test_log_done_writes_notification

# ── Stale Entry Cleanup Tests (CFG-363) ─────────────────────────────────────

suite_header "GPI Stale Entry Cleanup Tests (CFG-363)"

test_cleanup_stale_removes_old_orphans() {
    gpi start orphan1 "stale-op"
    # Backdate started to 25 hours ago, no completed_at
    local old_ts=$(($(date +%s) - 90000))
    local tmp
    tmp=$(jq --argjson ts "$old_ts" '.ops["orphan1"].started = $ts' "$TEST_TMPDIR/gpi-state.json")
    echo "$tmp" > "$TEST_TMPDIR/gpi-state.json"
    # Any gpi command triggers cleanup
    gpi status >/dev/null
    assert_eq "null" "$(gpi_field '.ops["orphan1"] // "null"')" "orphan >24h should be removed"
}
run_test "cleanup_stale removes entries >24h with no completed_at" test_cleanup_stale_removes_old_orphans

test_cleanup_stale_keeps_young_entries() {
    gpi start fresh1 "recent-op"
    # started is just now — should survive
    gpi status >/dev/null
    assert_neq "null" "$(gpi_field '.ops["fresh1"]')" "recent entry should survive cleanup"
}
run_test "cleanup_stale keeps entries <24h" test_cleanup_stale_keeps_young_entries

test_cleanup_stale_keeps_completed() {
    gpi start completed1 "done-op"
    gpi done completed1
    # Backdate started to 25 hours ago but has completed_at
    local old_ts=$(($(date +%s) - 90000))
    local tmp
    tmp=$(jq --argjson ts "$old_ts" '.ops["completed1"].started = $ts' "$TEST_TMPDIR/gpi-state.json")
    echo "$tmp" > "$TEST_TMPDIR/gpi-state.json"
    gpi status >/dev/null
    # cleanup_completed handles these (by completed_at age), not cleanup_stale
    # Since completed_at is recent, it should survive
    assert_neq "null" "$(gpi_field '.ops["completed1"]')" "completed entry should be handled by cleanup_completed, not stale"
}
run_test "cleanup_stale ignores entries with completed_at" test_cleanup_stale_keeps_completed

test_cleanup_stale_mixed_entries() {
    gpi start stale1 "old-orphan"
    gpi start fresh1 "new-op"
    # Backdate only stale1
    local old_ts=$(($(date +%s) - 90000))
    local tmp
    tmp=$(jq --argjson ts "$old_ts" '.ops["stale1"].started = $ts' "$TEST_TMPDIR/gpi-state.json")
    echo "$tmp" > "$TEST_TMPDIR/gpi-state.json"
    gpi status >/dev/null
    assert_eq "null" "$(gpi_field '.ops["stale1"] // "null"')" "stale entry should be removed" || return 1
    assert_neq "null" "$(gpi_field '.ops["fresh1"]')" "fresh entry should survive"
}
run_test "cleanup_stale removes stale entries while keeping fresh" test_cleanup_stale_mixed_entries

# ── SessionEnd GPI Cleanup Integration Test (CFG-363) ───────────────────────

suite_header "GPI SessionEnd Integration Tests (CFG-363)"

test_sessionend_has_gpi_cleanup() {
    local hook_file="$REPO_ROOT/global/hooks/config-auto-sync.sh"
    assert_file_exists "$hook_file"
    assert_contains "$(cat "$hook_file")" "gpi" "SessionEnd hook must reference gpi cleanup"
    assert_contains "$(cat "$hook_file")" "clear" "SessionEnd hook must call gpi clear"
}
run_test "SessionEnd hook contains GPI cleanup" test_sessionend_has_gpi_cleanup

suite_summary
