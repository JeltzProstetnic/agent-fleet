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

# Helper: strip ANSI codes from output
strip_ansi() {
    sed 's/\x1b\[[0-9;]*m//g'
}

# Helper: render in the background (race tests). Output lands in $1; echoes the pid to wait for.
render_statusline_bg() {
    local out="$1" statusline_tmp="$TEST_TMPDIR/statusline-test-bg.sh"
    sed -e "s|os.path.expanduser('~/.claude/.gpi-state.json')|'$TEST_TMPDIR/gpi-state.json'|g" \
        -e "s|os.path.expanduser('~/.claude/.gpi-completed.json')|'$TEST_TMPDIR/gpi-completed.json'|g" \
        "$STATUSLINE_SCRIPT" > "$statusline_tmp"
    echo '{"model":{"display_name":"Opus"},"context_window":{"used_percentage":50,"context_window_size":200000,"current_usage":{"input_tokens":100000}},"cost":{"total_cost_usd":1.5},"workspace":{"project_dir":"/home/test/project"}}' \
        | timeout 30 bash "$statusline_tmp" > "$out" 2>/dev/null &
    echo $!
}

# CFG-863: every tmux call made by gpi.sh or the renderer under test goes to a PRIVATE
# socket dir, never to the user's live server. The dir must EXIST for the whole file: with
# a missing TMUX_TMPDIR tmux silently falls back to /tmp — the live server (measured
# 2026-10-28). Not under TEST_TMPDIR, which teardown removes after every test.
unset TMUX
TMUX_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/cfgtest-tmux.XXXXXX")"; export TMUX_TMPDIR
# `|| true`: the helpers run with set -e, and a failing kill-server (no server) would end
# the handler before the rm — the dir then outlives the run (seen 2026-10-28).
trap 'tmux kill-server 2>/dev/null || true; rm -rf "$TMUX_TMPDIR"' EXIT

# Helper: start a throwaway session on the private socket; echoes its name.
tmux_sandbox_session() {
    local name="cfgtest-live-$$-$RANDOM"
    tmux new-session -d -s "$name" sleep 120
    echo "$name"
}

# Helper: move an op's `started` back by N seconds (past the 10 s dead-tmux grace).
backdate_started() {
    local tmp
    tmp=$(jq --arg id "$1" --argjson by "$2" '.ops[$id].started -= $by' "$TEST_TMPDIR/gpi-state.json")
    echo "$tmp" > "$TEST_TMPDIR/gpi-state.json"
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

# 2026-10-22 (infrastructure lrn): `gpi clear <id>` silently fell through to "clear all" and wiped
# other sessions' operations. An id is not a clear selector: refuse it and touch nothing.
test_clear_refuses_positional_id() {
    gpi start op1 "mine"
    gpi start op2 "someone else's"
    local rc=0
    gpi clear op1 >/dev/null 2>&1 || rc=$?
    assert_neq "0" "$rc" "clear <id> must fail" || return 1
    assert_neq "null" "$(gpi_field '.ops["op1"]')" "op1 must survive a refused clear" || return 1
    assert_neq "null" "$(gpi_field '.ops["op2"]')" "op2 must survive a refused clear"
}
run_test "clear <id> is refused and clears nothing" test_clear_refuses_positional_id

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
    # CFG-863 (display): before, every op vanished after 600 s of quiet while still registered,
    # so a long quiet job read as "nothing running". An unfinished op stays visible, dimmed.
    assert_contains "$output" "copy" "a quiet (>600s) unfinished op still renders" || return 1
    assert_contains "$output" $'\033[2m' "and renders dimmed"
}
run_test "very stale state (>600s) still renders an unfinished op, dimmed" test_render_very_stale_state

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
    # CFG-863: the state file is machine-global while "leader" is per project, so `--all`
    # wiped other projects' RUNNING jobs. Behavioural proof: test-config-auto-sync-gpi.sh.
    # Judged on code lines only — the hook's own comment names the retired call.
    assert_not_contains "$(grep -v '^[[:space:]]*#' "$hook_file")" "clear --all" "SessionEnd must never clear running ops"
}
run_test "SessionEnd hook contains GPI cleanup" test_sessionend_has_gpi_cleanup

test_done_on_unknown_op_creates_no_stub() {  # 2026-10-28: statusline showed "[? DONE]"
    rm -f "$TEST_TMPDIR/gpi-state.json"
    gpi start other "Other job" >/dev/null 2>&1
    gpi done gone-already >/dev/null 2>&1
    assert_eq "null" "$(gpi_field '.ops["gone-already"]')" "done on an expired/cleared op adds no label-less stub"
}
run_test "done on an unknown op creates no stub" test_done_on_unknown_op_creates_no_stub

# ── State file hygiene (CFG-863 C/D) ────────────────────────────────────────

suite_header "GPI State Hygiene (CFG-863 C/D)"

test_empty_state_file_is_repaired() {
    : > "$TEST_TMPDIR/gpi-state.json"
    gpi start op1 "after-empty" 2>/dev/null || true
    assert_eq "after-empty" "$(gpi_field '.ops["op1"].label // "null"')" "start on an EMPTY state file must register the op"
}
run_test "empty state file is repaired on the next command" test_empty_state_file_is_repaired

test_invalid_state_file_is_repaired() {
    echo 'not json{{{' > "$TEST_TMPDIR/gpi-state.json"
    gpi start op1 "after-garbage" 2>/dev/null || true
    local rc=0
    jq -e '.ops | type == "object"' "$TEST_TMPDIR/gpi-state.json" >/dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" "state file is valid JSON again (jq rc=$rc)" || return 1
    assert_eq "after-garbage" "$(gpi_field '.ops["op1"].label // "null"')" "start on an INVALID state file must register the op"
}
run_test "invalid state file is repaired on the next command" test_invalid_state_file_is_repaired

test_cleanup_survives_op_without_started() {
    gpi start op1 "no-started"
    gpi start op2 "normal"
    local tmp
    tmp=$(jq 'del(.ops["op1"].started)' "$TEST_TMPDIR/gpi-state.json")
    echo "$tmp" > "$TEST_TMPDIR/gpi-state.json"
    gpi status >/dev/null 2>&1 || true
    local rc=0
    jq -e '.ops | type == "object"' "$TEST_TMPDIR/gpi-state.json" >/dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" "state file still valid JSON (jq rc=$rc)" || return 1
    assert_eq "no-started" "$(gpi_field '.ops["op1"].label // "null"')" "an op without 'started' must not blank the state" || return 1
    assert_eq "normal" "$(gpi_field '.ops["op2"].label // "null"')" "its siblings survive too"
}
run_test "an op without 'started' does not blank the state file" test_cleanup_survives_op_without_started

test_state_writes_replace_atomically() {
    gpi start op1 "copy"
    # A reader that opened the file BEFORE a write keeps a complete, unchanged snapshot:
    # tmp+rename leaves it the old inode; an in-place `echo >` truncates under its feet (D).
    exec 7< "$TEST_TMPDIR/gpi-state.json"
    gpi update op1 --pct 99
    local snapshot
    snapshot=$(cat <&7)
    exec 7<&-
    local rc=0
    jq -e . <<< "$snapshot" >/dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" "snapshot held across a write is complete JSON (jq rc=$rc)" || return 1
    assert_eq "null" "$(jq -r '.ops["op1"].pct' <<< "$snapshot")" "snapshot held across a write is the OLD content, not the file rewritten in place"
}
run_test "state writes replace the file atomically" test_state_writes_replace_atomically

# ── tmux liveness (CFG-863) ─────────────────────────────────────────────────

suite_header "GPI tmux Liveness (CFG-863)"

test_start_records_tmux_session() {
    gpi start op1 "job" --tmux my-sess
    gpi start op2 "manual"
    assert_eq "my-sess" "$(gpi_field '.ops["op1"].tmux_session // "null"')" "--tmux is recorded" || return 1
    assert_eq "null" "$(gpi_field '.ops["op2"].tmux_session // "null"')" "no --tmux: nothing recorded"
}
run_test "start --tmux records the session name" test_start_records_tmux_session

test_clear_dead_reaps_only_completed_and_dead_tmux() {
    local live
    live=$(tmux_sandbox_session)
    gpi start live-op "live" --tmux "$live"
    gpi start dead-op "dead" --tmux "cfgtest-gone-$$"
    gpi start plain-op "plain"
    gpi start done-op "done"
    gpi done done-op
    backdate_started live-op 60
    backdate_started dead-op 60
    gpi clear --dead
    tmux kill-server 2>/dev/null || true
    assert_eq "live" "$(gpi_field '.ops["live-op"].label // "null"')" "op whose tmux session is alive survives" || return 1
    assert_eq "plain" "$(gpi_field '.ops["plain-op"].label // "null"')" "op without tmux survives (cannot be judged)" || return 1
    assert_eq "null" "$(gpi_field '.ops["dead-op"] // "null"')" "op whose tmux session is gone is reaped" || return 1
    assert_eq "null" "$(gpi_field '.ops["done-op"] // "null"')" "completed op is reaped"
}
run_test "clear --dead: reaps completed + dead-tmux, keeps live-tmux + plain" test_clear_dead_reaps_only_completed_and_dead_tmux

test_clear_dead_with_no_tmux_server() {
    tmux kill-server 2>/dev/null || true
    gpi start dead-op "dead" --tmux "cfgtest-gone-$$"
    gpi start plain-op "plain"
    backdate_started dead-op 60
    gpi clear --dead
    assert_eq "null" "$(gpi_field '.ops["dead-op"] // "null"')" "no server at all: the tmux op is reaped" || return 1
    assert_eq "plain" "$(gpi_field '.ops["plain-op"].label // "null"')" "plain op kept"
}
run_test "clear --dead: no tmux server = every tmux op is dead, plain ops kept" test_clear_dead_with_no_tmux_server

test_young_tmux_op_is_never_judged_dead() {
    # tmux-launch.sh runs `gpi start` BEFORE `tmux new-session`: for a moment the op exists
    # and its session does not. A SessionEnd or a render in that window must not reap/hide it.
    tmux kill-server 2>/dev/null || true
    gpi start fresh "just-launched" --tmux "cfgtest-not-yet-$$"
    gpi clear --dead
    assert_eq "just-launched" "$(gpi_field '.ops["fresh"].label // "null"')" "an op started <10 s ago survives clear --dead without its session" || return 1
    local output
    output=$(render_statusline | strip_ansi)
    assert_contains "$output" "just-launched" "and the renderer still shows it"
}
run_test "a tmux op younger than the grace period is neither reaped nor hidden" test_young_tmux_op_is_never_judged_dead

test_clear_dead_when_tmux_unreachable_keeps_everything() {
    # tmux cannot reach its socket dir at all (not "no server"): nothing can be judged.
    local locked="$TEST_TMPDIR/locked-sock"
    mkdir -m 000 "$locked"
    gpi start dead-op "unjudgeable" --tmux "cfgtest-gone-$$"
    TMUX_TMPDIR="$locked" gpi clear --dead
    chmod 700 "$locked"
    assert_eq "unjudgeable" "$(gpi_field '.ops["dead-op"].label // "null"')" "unreachable tmux: op kept, not reaped"
}
run_test "clear --dead: unreachable tmux reaps nothing" test_clear_dead_when_tmux_unreachable_keeps_everything

test_render_hides_op_whose_tmux_session_is_gone() {
    tmux kill-server 2>/dev/null || true
    gpi start killed "killed-job" --tmux "cfgtest-gone-$$"
    gpi start plain "plain-job"
    backdate_started killed 60
    local output
    output=$(render_statusline | strip_ansi)
    assert_not_contains "$output" "killed-job" "op whose tmux session is gone is not shown" || return 1
    assert_contains "$output" "plain-job" "op without tmux is shown" || return 1
    assert_not_contains "$output" "+1" "the hidden op is not counted either"
}
run_test "renderer hides an op whose tmux session is gone" test_render_hides_op_whose_tmux_session_is_gone

test_render_shows_quiet_op_whose_tmux_session_is_live() {
    local live
    live=$(tmux_sandbox_session)
    gpi start alive "alive-job" --tmux "$live"
    local old_ts=$(($(date +%s) - 700))
    local tmp
    tmp=$(jq --argjson ts "$old_ts" '.updated = $ts' "$TEST_TMPDIR/gpi-state.json")
    echo "$tmp" > "$TEST_TMPDIR/gpi-state.json"
    local output
    output=$(render_statusline)
    tmux kill-server 2>/dev/null || true
    assert_contains "$output" "alive-job" "a quiet (>600s) op whose tmux session is alive renders"
}
run_test "renderer shows a quiet op whose tmux session is live" test_render_shows_quiet_op_whose_tmux_session_is_live

test_render_completed_op_shows_done_after_its_session_ended() {
    tmux kill-server 2>/dev/null || true
    gpi start fin "finished-job" --tmux "cfgtest-gone-$$"
    gpi done fin
    local output
    output=$(render_statusline)
    assert_contains "$output" "finished-job" "a just-completed op still flashes" || return 1
    assert_contains "$output" "DONE" "as DONE, although its tmux session has ended"
}
run_test "renderer still flashes DONE after the op's tmux session ended" test_render_completed_op_shows_done_after_its_session_ended

# ── Renderer write-back vs concurrent gpi.sh (CFG-863 B) ────────────────────

suite_header "GPI Renderer Write-Back (CFG-863 B)"

test_render_writeback_keeps_concurrent_start() {
    # The renderer read the state UNLOCKED and, when it had something to write back, rewrote
    # the WHOLE dict — an op gpi.sh added or updated in between was lost. Deterministic
    # replay: two running ops log to FIFOs, so the renderer blocks inside its read->write
    # window; an op is started while it is blocked; an expired completed op makes it write.
    local f1="$TEST_TMPDIR/log1.fifo" f2="$TEST_TMPDIR/log2.fifo"
    mkfifo "$f1" "$f2"
    gpi start a1 "job-1" --log "$f1"
    gpi start a2 "job-2" --log "$f2"
    gpi start old "old-job"
    local tmp old_ts=$(($(date +%s) - 120))
    tmp=$(jq --argjson ts "$old_ts" '.ops["old"].completed_at = $ts' "$TEST_TMPDIR/gpi-state.json")
    echo "$tmp" > "$TEST_TMPDIR/gpi-state.json"
    local pid
    pid=$(render_statusline_bg "$TEST_TMPDIR/render.out")
    timeout 10 sh -c ': > "$0"' "$f1" || true   # returns once the renderer holds log1 open (state already read)
    gpi start late "late-job"                    # it is blocked opening log2: this lands in its window
    timeout 10 sh -c ': > "$0"' "$f2" || true
    wait "$pid" 2>/dev/null || true
    assert_eq "late-job" "$(gpi_field '.ops["late"].label // "null"')" "an op started inside the renderer's read->write window survives its write-back" || return 1
    assert_eq "null" "$(gpi_field '.ops["old"] // "null"')" "the expired completed op was still cleaned"
}
run_test "renderer write-back does not clobber a concurrent gpi start" test_render_writeback_keeps_concurrent_start

suite_summary
