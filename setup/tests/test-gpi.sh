#!/usr/bin/env bash
# Tests for GPI (Grind Progress Indicator) — setup/scripts/gpi.sh + statusline rendering
source "$(dirname "$0")/test-helpers.sh"

GPI_SCRIPT="$REPO_ROOT/setup/scripts/gpi.sh"
STATUSLINE_SCRIPT="$REPO_ROOT/setup/config/statusline-command.sh"

# Helper: run gpi.sh with test state file
gpi() {
    GPI_STATE="$TEST_TMPDIR/gpi-state.json" "$GPI_SCRIPT" "$@"
}

# Helper: read a field from the test state file via jq
gpi_field() {
    jq -r "$1" "$TEST_TMPDIR/gpi-state.json"
}

# Helper: render statusline with test GPI state, return output
render_statusline() {
    local gpi_path="$TEST_TMPDIR/gpi-state.json"
    local statusline_tmp="$TEST_TMPDIR/statusline-test.sh"
    # Patch the statusline to use our test GPI path
    sed "s|os.path.expanduser('~/.claude/.gpi-state.json')|'$gpi_path'|g" \
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

test_done_removes_entry() {
    gpi start op1 "copy"
    gpi start op2 "sync"
    gpi done op1
    assert_eq "null" "$(gpi_field '.ops["op1"]')" "op1 should be removed"
    assert_neq "null" "$(gpi_field '.ops["op2"]')" "op2 should remain"
}
run_test "done removes entry" test_done_removes_entry

test_done_last_entry_leaves_empty() {
    gpi start op1 "copy"
    gpi done op1
    assert_file_exists "$TEST_TMPDIR/gpi-state.json"
    local count
    count=$(gpi_field '.ops | length')
    assert_eq "0" "$count"
}
run_test "done last entry leaves empty ops" test_done_last_entry_leaves_empty

test_clear_removes_all() {
    gpi start op1 "copy"
    gpi start op2 "sync"
    gpi clear
    local count
    count=$(gpi_field '.ops | length')
    assert_eq "0" "$count"
}
run_test "clear removes all" test_clear_removes_all

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
    # Should show count and the longest-expected (op1, eta 300)
    assert_contains "$output" "rsync"
    assert_contains "$output" "45%"
    # The parallel count indicator
    assert_contains "$output" "2"
}
run_test "parallel ops show count + longest" test_render_parallel

test_render_empty_ops() {
    gpi start op1 "copy"
    gpi done op1
    local output
    output=$(render_statusline)
    # Empty ops dict — no GPI indicator
    # Just verify there's no "copy" in output
    assert_not_contains "$output" "copy"
}
run_test "empty ops = no GPI indicator" test_render_empty_ops

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

suite_summary
