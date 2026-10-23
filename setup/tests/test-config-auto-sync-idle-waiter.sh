#!/usr/bin/env bash
# Tests for config-auto-sync.sh — CFG-806: silence this session's idle waiter first.
#
# afd-idle-wake.sh (Stop hook, asyncRewake, CFG-777/797) polls for up to 12 h and exits 2
# to wake the model on a Telegram message or a new inbox item. Claude Code is still alive
# while its SessionEnd hooks run (/exit, /clear — up to CLAUDE_CODE_SESSIONEND_HOOKS_TIMEOUT_MS),
# so a wake in that window opens a new turn in a session the user has already left. The
# SessionEnd hook therefore, before anything else: writes $AFD_MSG_DIR/.idle/<sid>.ending
# (the waiter checks it before every wake) and sends the waiter named by <sid>.pid SIGTERM —
# only when that pid really is an afd-idle-wake.sh (pidfile pids can be reused).
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO_ROOT/setup/tests/test-helpers.sh"
source "$REPO_ROOT/setup/tests/test-config-auto-sync-helpers.sh"

suite_header "config-auto-sync.sh (CFG-806: idle waiter silenced at SessionEnd)"

# The hook reads the session id from its stdin JSON via lib-hook-stdin.sh, sourced from the
# hook's own directory — the patched copy lives in TEST_TMPDIR, so the library goes there too.
setup_hook_env() {
    CONFIG_REPO_T="$TEST_TMPDIR/config-repo"; PROJECT_T="$TEST_TMPDIR/project"; MOCK_HOME="$TEST_TMPDIR/home"
    mkdir -p "$PROJECT_T/.claude" "$MOCK_HOME"
    create_mock_config_repo "$CONFIG_REPO_T"
    create_tracked_repo_main "$CONFIG_REPO_T" "$TEST_TMPDIR/remote.git"
    git -C "$CONFIG_REPO_T" add -A >/dev/null 2>&1
    git -C "$CONFIG_REPO_T" commit -q -m "stubs" >/dev/null 2>&1 || true
    git -C "$CONFIG_REPO_T" push -q origin main >/dev/null 2>&1 || true
    cp "$REPO_ROOT/global/hooks/lib-hook-stdin.sh" "$TEST_TMPDIR/lib-hook-stdin.sh"
    IDLE_DIR="$MOCK_HOME/.afd-msgs/.idle"; mkdir -p "$IDLE_DIR"
    PATCHED=$(create_patched_hook "$CONFIG_REPO_T" "$PROJECT_T" "$MOCK_HOME")
    export AFLEET_SESSION_ID=""
}

# A stand-in for a live waiter: its command line carries the script name (that is what the
# hook's kill guard checks), it records SIGTERM, and it outlives the hook unless signalled.
start_fake_waiter() { # start_fake_waiter <sid> → FAKE_PID, FAKE_LOG; writes <sid>.pid like the real one
    FAKE_LOG="$TEST_TMPDIR/fake-$1.log"; rm -f "$FAKE_LOG"
    cat > "$TEST_TMPDIR/afd-idle-wake.sh" << 'EOF'
#!/usr/bin/env bash
trap 'echo TERM > "$FAKE_LOG"; exit 0' TERM
echo $$ > "$PIDFILE"
i=0; while (( i < 600 )); do sleep 0.1; i=$((i+1)); done
EOF
    FAKE_LOG="$FAKE_LOG" PIDFILE="$IDLE_DIR/$1.pid" bash "$TEST_TMPDIR/afd-idle-wake.sh" &
    FAKE_PID=$!
    local n=0; while [[ ! -s "$IDLE_DIR/$1.pid" ]] && (( n < 30 )); do sleep 0.1; n=$((n+1)); done
}
stop_fake_waiter() { kill "$FAKE_PID" 2>/dev/null; wait "$FAKE_PID" 2>/dev/null || true; }

session_end_json() { printf '{"session_id":"%s","hook_event_name":"SessionEnd","reason":"prompt_input_exit","cwd":"%s"}' "$1" "$PROJECT_T"; }

test_marks_session_ending_and_signals_waiter() {
    setup_hook_env
    start_fake_waiter s1
    local t0=$SECONDS
    session_end_json s1 | run_hook "$PATCHED" || true
    local n=0; while [[ ! -s "$FAKE_LOG" ]] && (( n < 30 )); do sleep 0.1; n=$((n+1)); done
    assert_file_exists "$IDLE_DIR/s1.ending" "the session is marked as ending for its waiter"
    assert_eq "TERM" "$(cat "$FAKE_LOG" 2>/dev/null)" "the waiter named by the pidfile receives SIGTERM"
    kill -0 "$FAKE_PID" 2>/dev/null && ok=1 || ok=0
    assert_eq "0" "$ok" "and is gone $(( SECONDS - t0 ))s after the hook started"
    stop_fake_waiter
}
run_test "SessionEnd marks the session ending and signals its idle waiter" test_marks_session_ending_and_signals_waiter

test_pid_reuse_guard_spares_a_stranger() {
    setup_hook_env
    sleep 30 & local stranger=$!
    echo "$stranger" > "$IDLE_DIR/s1.pid"      # a dead waiter's pid, reused by an unrelated process
    session_end_json s1 | run_hook "$PATCHED" || true
    kill -0 "$stranger" 2>/dev/null && ok=0 || ok=1
    assert_eq "0" "$ok" "a pidfile pid that is not an afd-idle-wake.sh is left alone"
    assert_file_exists "$IDLE_DIR/s1.ending" "the marker is still written (the waiter honours it on its own)"
    kill "$stranger" 2>/dev/null; wait "$stranger" 2>/dev/null || true
}
run_test "a reused pid that is not a waiter is never signalled" test_pid_reuse_guard_spares_a_stranger

test_other_sessions_waiters_untouched() {
    setup_hook_env
    start_fake_waiter s2                      # another live session on this machine
    session_end_json s1 | run_hook "$PATCHED" || true
    sleep 0.3
    kill -0 "$FAKE_PID" 2>/dev/null && ok=0 || ok=1
    assert_eq "0" "$ok" "only this session's waiter is signalled (s2 keeps waiting)"
    assert_file_not_exists "$IDLE_DIR/s2.ending" "and only this session is marked ending"
    stop_fake_waiter
}
run_test "another session's waiter and marker are untouched" test_other_sessions_waiters_untouched

test_no_session_id_is_a_quiet_noop() {
    setup_hook_env
    start_fake_waiter s1
    run_hook "$PATCHED" < /dev/null || true   # no stdin JSON: no session id, nothing to silence
    sleep 0.3
    kill -0 "$FAKE_PID" 2>/dev/null && ok=0 || ok=1
    assert_eq "0" "$ok" "without a session id no waiter is signalled"
    [[ -z "$(ls "$IDLE_DIR"/*.ending 2>/dev/null)" ]] && ok=0 || ok=1
    assert_eq "0" "$ok" "and no marker is written"
    stop_fake_waiter
}
run_test "no session id on stdin: nothing is marked or signalled" test_no_session_id_is_a_quiet_noop

test_old_markers_are_pruned() {
    setup_hook_env
    : > "$IDLE_DIR/old.ending"; touch -d '3 hours ago' "$IDLE_DIR/old.ending"
    : > "$IDLE_DIR/recent.ending"
    session_end_json s1 | run_hook "$PATCHED" || true
    assert_file_not_exists "$IDLE_DIR/old.ending" "a marker older than two hours is pruned"
    assert_file_exists "$IDLE_DIR/recent.ending" "a recent marker (a session still shutting down) is kept"
}
run_test "stale ending markers are pruned, recent ones kept" test_old_markers_are_pruned

suite_summary
