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
    assert_file_contains "$logfile" "Command:" "log header should contain command" || return 1
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

# ── Summary ─────────────────────────────────────────────────────────────────

suite_summary
