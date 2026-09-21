#!/usr/bin/env bash
# Tests for tmux-launch.sh — session launch, death detection, exit code logging
source "$(dirname "$0")/test-helpers.sh"

TMUX_LAUNCH="$REPO_ROOT/setup/scripts/tmux-launch.sh"

# Mock gpi globally to prevent test pollution of ~/.claude/.gpi-state.json
MOCK_BIN="$(mktemp -d)"
cat > "$MOCK_BIN/gpi" << 'MOCKEOF'
#!/usr/bin/env bash
exit 0
MOCKEOF
chmod +x "$MOCK_BIN/gpi"
export PATH="$MOCK_BIN:$PATH"

# Helper: kill tmux session if it exists (cleanup)
kill_session() {
    tmux kill-session -t "$1" 2>/dev/null || true
}

suite_header "tmux-launch.sh Tests"

# ── Argument Validation ─────────────────────────────────────────────────────

test_missing_args() {
    local output
    output=$(bash "$TMUX_LAUNCH" 2>&1) || true
    assert_contains "$output" "Usage"
}
run_test "missing args prints usage" test_missing_args

test_two_args_fails() {
    local output
    output=$(bash "$TMUX_LAUNCH" sess label 2>&1) || true
    assert_contains "$output" "Usage"
}
run_test "two args prints usage" test_two_args_fails

# ── Log Pre-Creation ────────────────────────────────────────────────────────

test_log_precreated() {
    local session="tl-precreate-$$"
    local logfile="$TEST_TMPDIR/pre.log"
    bash "$TMUX_LAUNCH" "$session" "test" --log "$logfile" "sleep 5" 2>/dev/null
    # Log should exist immediately (created before tmux, not by tmux)
    assert_file_exists "$logfile" "log should be pre-created before tmux starts" || return 1
    assert_file_contains "$logfile" "Session:" "log header should contain session name" || return 1
    # The command itself lives in the .meta sidecar (CFG-659), not here — the
    # header must only POINT at it, so no command text can collide with a
    # sentinel the job later writes into this same log.
    assert_file_contains "$logfile" "Command logged to:" "log header should point at the meta sidecar" || return 1
    kill_session "$session"
}
run_test "log file pre-created with header" test_log_precreated

test_log_dir_created() {
    local session="tl-logdir-$$"
    local logfile="$TEST_TMPDIR/deep/nested/dir/test.log"
    bash "$TMUX_LAUNCH" "$session" "test" --log "$logfile" "sleep 5" 2>/dev/null
    assert_file_exists "$logfile" "log dir should be created automatically" || return 1
    kill_session "$session"
}
run_test "missing log directory created automatically" test_log_dir_created

# CFG-659: the header used to echo the command verbatim into the same log the
# command writes its completion sentinel to, so `grep -c 'RSYNC DONE'` matched
# the line ANNOUNCING the sentinel and returned 1 from the first second — a
# completion check that reports success while the job is still running.
# Measured on a life-session Audio mirror: grep said done at 516 of 1162 files.
test_sentinel_not_in_header() {
    local session="tl-sentinel-$$"
    local logfile="$TEST_TMPDIR/sentinel.log"
    bash "$TMUX_LAUNCH" "$session" "test" --log "$logfile" \
        "sleep 5; echo 'RSYNC DONE' >> $logfile" 2>/dev/null
    # At launch the job has not finished, so the sentinel must not be present.
    local n
    # `grep -c` already prints 0 on no-match and THEN exits 1 — a `|| echo 0`
    # here appends a second zero and the assert compares against "0\n0".
    n=$(grep -c 'RSYNC DONE' "$logfile" 2>/dev/null || true)
    kill_session "$session"
    assert_eq "0" "$n" "log must not contain the sentinel before the job emits it"
}
run_test "completion sentinel in the command does not appear in the log header" test_sentinel_not_in_header

test_command_recorded_in_meta() {
    local session="tl-meta-$$"
    local logfile="$TEST_TMPDIR/meta.log"
    bash "$TMUX_LAUNCH" "$session" "test" --log "$logfile" "sleep 5" 2>/dev/null
    assert_file_exists "$logfile.meta" "command should be recorded in a .meta sidecar" || return 1
    assert_file_contains "$logfile.meta" "sleep 5" "meta should carry the command" || return 1
    kill_session "$session"
}
run_test "launch command is recorded in a .meta sidecar, not the log" test_command_recorded_in_meta

# ── Session Verification ────────────────────────────────────────────────────

test_session_exists_after_launch() {
    local session="tl-verify-$$"
    local logfile="$TEST_TMPDIR/verify.log"
    bash "$TMUX_LAUNCH" "$session" "test" --log "$logfile" "sleep 30" 2>/dev/null
    # Session should be alive
    tmux has-session -t "$session" 2>/dev/null
    local rc=$?
    assert_eq "0" "$rc" "tmux session should exist after launch" || return 1
    kill_session "$session"
}
run_test "session exists after successful launch" test_session_exists_after_launch

# ── Immediate Death Detection ───────────────────────────────────────────────

test_immediate_death_detected() {
    local session="tl-die-$$"
    local logfile="$TEST_TMPDIR/die.log"
    # Command that exits immediately with error
    local output
    output=$(bash "$TMUX_LAUNCH" "$session" "test" --log "$logfile" "exit 1" 2>&1) || true
    # Should report error on stderr
    assert_contains "$output" "ERROR" "should report session death" || return 1
    assert_contains "$output" "died immediately" "should say session died" || return 1
}
run_test "immediate session death is detected and reported" test_immediate_death_detected

test_immediate_death_exit_code() {
    local session="tl-die-rc-$$"
    local logfile="$TEST_TMPDIR/die-rc.log"
    # Command that exits immediately
    bash "$TMUX_LAUNCH" "$session" "test" --log "$logfile" "exit 1" 2>/dev/null
    local rc=$?
    assert_neq "0" "$rc" "should exit non-zero when session dies immediately" || return 1
}
run_test "immediate death returns non-zero exit code" test_immediate_death_exit_code

test_immediate_death_logged() {
    local session="tl-die-log-$$"
    local logfile="$TEST_TMPDIR/die-log.log"
    bash "$TMUX_LAUNCH" "$session" "test" --log "$logfile" "exit 1" 2>/dev/null || true
    assert_file_contains "$logfile" "ERROR" "log should record the session death" || return 1
}
run_test "immediate death recorded in log file" test_immediate_death_logged

# ── Exit Code Capture ───────────────────────────────────────────────────────

test_exit_code_logged_success() {
    local session="tl-rc0-$$"
    local logfile="$TEST_TMPDIR/rc0.log"
    bash "$TMUX_LAUNCH" "$session" "test" --log "$logfile" "echo done" 2>/dev/null
    # Wait for command to finish (it's fast)
    sleep 2
    assert_file_contains "$logfile" "EXIT_CODE: 0" "successful command should log exit code 0" || return 1
}
run_test "exit code 0 logged for successful command" test_exit_code_logged_success

test_exit_code_logged_failure() {
    local session="tl-rc42-$$"
    local logfile="$TEST_TMPDIR/rc42.log"
    # Use a command that takes a moment so the session doesn't die instantly
    bash "$TMUX_LAUNCH" "$session" "test" --log "$logfile" "sleep 0.5; exit 42" 2>/dev/null || true
    # Wait for command to finish
    sleep 3
    assert_file_contains "$logfile" "EXIT_CODE: 42" "failed command should log exit code 42" || return 1
}
run_test "non-zero exit code logged for failed command" test_exit_code_logged_failure

# ── Duplicate Session Handling ──────────────────────────────────────────────

test_duplicate_session_replaced() {
    local session="tl-dup-$$"
    local logfile1="$TEST_TMPDIR/dup1.log"
    local logfile2="$TEST_TMPDIR/dup2.log"
    # Start first session
    bash "$TMUX_LAUNCH" "$session" "first" --log "$logfile1" "sleep 30" 2>/dev/null
    tmux has-session -t "$session" 2>/dev/null
    assert_eq "0" "$?" "first session should exist" || return 1
    # Start second session with same name
    bash "$TMUX_LAUNCH" "$session" "second" --log "$logfile2" "sleep 30" 2>/dev/null
    tmux has-session -t "$session" 2>/dev/null
    assert_eq "0" "$?" "replacement session should exist" || return 1
    # Second log should exist and have header
    assert_file_exists "$logfile2" || return 1
    assert_file_contains "$logfile2" "Session:" "replacement log should have header" || return 1
    kill_session "$session"
}
run_test "duplicate session name replaces old session" test_duplicate_session_replaced

# ── No --log Mode ───────────────────────────────────────────────────────────

test_no_log_still_verifies() {
    local session="tl-nolog-$$"
    # Launch without --log
    local output
    output=$(bash "$TMUX_LAUNCH" "$session" "test" "sleep 30" 2>&1)
    assert_contains "$output" "launched" "should report successful launch" || return 1
    tmux has-session -t "$session" 2>/dev/null
    assert_eq "0" "$?" "session should exist without --log" || return 1
    kill_session "$session"
}
run_test "launch without --log still verifies session" test_no_log_still_verifies

test_no_log_death_detected() {
    local session="tl-nolog-die-$$"
    local output
    output=$(bash "$TMUX_LAUNCH" "$session" "test" "exit 1" 2>&1) || true
    assert_contains "$output" "ERROR" "should detect death even without --log" || return 1
}
run_test "immediate death detected without --log" test_no_log_death_detected

# ── GPI Registration ────────────────────────────────────────────────────────

test_gpi_called() {
    local session="tl-gpi-$$"
    local logfile="$TEST_TMPDIR/gpi.log"
    # Create a mock gpi that logs calls
    local mock_dir="$TEST_TMPDIR/mockbin"
    mkdir -p "$mock_dir"
    cat > "$mock_dir/gpi" << 'MOCKEOF'
#!/usr/bin/env bash
echo "gpi $*" >> "${GPI_CALL_LOG:-/tmp/gpi-calls.log}"
MOCKEOF
    chmod +x "$mock_dir/gpi"
    local call_log="$TEST_TMPDIR/gpi-calls.log"
    GPI_CALL_LOG="$call_log" PATH="$mock_dir:$PATH" \
        bash "$TMUX_LAUNCH" "$session" "testing gpi" --log "$logfile" "sleep 5" 2>/dev/null
    assert_file_exists "$call_log" "gpi should have been called" || return 1
    assert_file_contains "$call_log" "start" "gpi start should be called" || return 1
    assert_file_contains "$call_log" "$session" "gpi called with session name" || return 1
    kill_session "$session"
}
run_test "GPI registration called on launch" test_gpi_called

# ── Session-name prefix matching (CFG-616 family) ───────────────────────────
# tmux resolves `-t name` by exact match, then PREFIX match. Measured on WSL
# 2026-09-17: with a live session `zztest2`, `tmux kill-session -t zztest`
# returns 0 and kills `zztest2`, while `-t=zztest` correctly fails. So a launch
# whose session name is a PREFIX of a running job's name silently killed that
# running job, and the death check could pass on a stranger's session.

test_prefix_sibling_survives_and_death_still_detected() {
    local sib="zzpfxsib2" own="zzpfxsib"
    tmux kill-session -t="$sib" 2>/dev/null || true
    tmux kill-session -t="$own" 2>/dev/null || true
    tmux new-session -d -s "$sib" "sleep 30"
    sleep 0.5

    local out rc=0
    out=$(bash "$TMUX_LAUNCH" "$own" "prefix probe" "exit 1" 2>&1) || rc=$?

    local sib_alive=1
    tmux has-session -t="$sib" 2>/dev/null || sib_alive=0

    tmux kill-session -t="$own" 2>/dev/null || true
    tmux kill-session -t="$sib" 2>/dev/null || true

    # The launcher must not touch a session that merely shares its prefix.
    assert_eq "1" "$sib_alive" "prefix-sharing sibling session must survive the launch" || return 1
    # And with the sibling still alive, an immediately dead session must still be caught.
    assert_neq "0" "$rc" "immediate death must be detected even with a prefix-sharing sibling alive" || return 1
    assert_contains "$out" "died immediately" "death message must still be reported" || return 1
}
run_test "prefix-named sibling is neither killed nor mistaken for our session" test_prefix_sibling_survives_and_death_still_detected

# ── Summary ─────────────────────────────────────────────────────────────────

suite_summary
