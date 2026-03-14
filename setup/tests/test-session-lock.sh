#!/usr/bin/env bash
# Tests for session-lock.sh — PID-based session lock for same-machine protection (CFG-146)
source "$(dirname "$0")/test-helpers.sh"

suite_header "Session Lock (CFG-146)"

LOCK_SCRIPT="$REPO_ROOT/setup/scripts/session-lock.sh"

# Helper: create a minimal project dir with .claude/
make_project_dir() {
    local dir="$1"
    mkdir -p "$dir/.claude"
}

# Helper: read a JSON field from the lock file using python3
lock_field() {
    local lockfile="$1"
    local field="$2"
    python3 -c "import json; print(json.load(open('$lockfile'))['$field'])"
}

# ── acquire_lock tests ──────────────────────────────────────────────────────

test_acquire_creates_lockfile() {
    local proj="$TEST_TMPDIR/project"
    make_project_dir "$proj"

    source "$LOCK_SCRIPT"
    acquire_lock "$proj" "test-session-1"
    local rc=$?

    assert_eq "0" "$rc" "acquire_lock should succeed"
    assert_file_exists "$proj/.claude/.session-lock"
}
run_test "acquire_lock creates lock file" test_acquire_creates_lockfile

test_acquire_lockfile_valid_json() {
    local proj="$TEST_TMPDIR/project"
    make_project_dir "$proj"

    source "$LOCK_SCRIPT"
    acquire_lock "$proj" "test-session-1"

    # Validate JSON by parsing it
    python3 -c "import json; json.load(open('$proj/.claude/.session-lock'))"
    local rc=$?
    assert_eq "0" "$rc" "lock file should be valid JSON"
}
run_test "lock file is valid JSON" test_acquire_lockfile_valid_json

test_acquire_lockfile_fields() {
    local proj="$TEST_TMPDIR/project"
    make_project_dir "$proj"

    source "$LOCK_SCRIPT"
    acquire_lock "$proj" "test-session-42"

    local lockfile="$proj/.claude/.session-lock"
    local machine pid sessionId user timestamp

    machine=$(lock_field "$lockfile" "machine")
    pid=$(lock_field "$lockfile" "pid")
    sessionId=$(lock_field "$lockfile" "sessionId")
    user=$(lock_field "$lockfile" "user")
    timestamp=$(lock_field "$lockfile" "timestamp")

    assert_eq "$(hostname)" "$machine" "machine should be hostname"
    assert_eq "$$" "$pid" "pid should be current process"
    assert_eq "test-session-42" "$sessionId" "sessionId should match"
    assert_eq "$(whoami)" "$user" "user should be current user"
    # Timestamp should be ISO 8601 format (basic check: contains T and Z or +/-)
    assert_contains "$timestamp" "T" "timestamp should be ISO 8601"
}
run_test "lock file contains correct JSON fields" test_acquire_lockfile_fields

test_acquire_fails_when_locked_by_live_pid() {
    local proj="$TEST_TMPDIR/project"
    make_project_dir "$proj"

    source "$LOCK_SCRIPT"
    # Acquire with our own PID but a different session ID
    acquire_lock "$proj" "session-first"

    # Try to acquire again with a different session — should fail (PID is alive)
    local output rc=0
    output=$(acquire_lock "$proj" "session-second" 2>&1) || rc=$?

    assert_eq "1" "$rc" "acquire should fail when lock held by live PID"
}
run_test "acquire fails when lock held by live PID" test_acquire_fails_when_locked_by_live_pid

test_acquire_succeeds_when_lock_stale() {
    local proj="$TEST_TMPDIR/project"
    make_project_dir "$proj"

    # Manually write a lock with a dead PID
    local dead_pid=99999
    # Make sure PID is dead (pick a high unlikely one)
    while kill -0 "$dead_pid" 2>/dev/null; do
        dead_pid=$((dead_pid + 1))
    done

    cat > "$proj/.claude/.session-lock" << LOCKEOF
{"machine":"$(hostname)","pid":$dead_pid,"sessionId":"old-session","timestamp":"2026-01-01T00:00:00Z","user":"$(whoami)"}
LOCKEOF

    source "$LOCK_SCRIPT"
    local rc=0
    acquire_lock "$proj" "new-session" || rc=$?

    assert_eq "0" "$rc" "acquire should succeed when PID is dead (stale lock)"
    # New lock should have our PID
    local new_pid
    new_pid=$(lock_field "$proj/.claude/.session-lock" "pid")
    assert_eq "$$" "$new_pid" "lock should now have our PID"
}
run_test "acquire succeeds when lock held by dead PID (stale cleanup)" test_acquire_succeeds_when_lock_stale

test_acquire_reacquire_own_session() {
    local proj="$TEST_TMPDIR/project"
    make_project_dir "$proj"

    source "$LOCK_SCRIPT"
    acquire_lock "$proj" "my-session"

    # Re-acquire with same session ID should succeed (idempotent)
    local rc=0
    acquire_lock "$proj" "my-session" || rc=$?

    assert_eq "0" "$rc" "re-acquire with same sessionId should succeed"
}
run_test "acquire re-acquires own session (idempotent)" test_acquire_reacquire_own_session

test_acquire_generates_session_id() {
    local proj="$TEST_TMPDIR/project"
    make_project_dir "$proj"

    source "$LOCK_SCRIPT"
    acquire_lock "$proj"

    local sid
    sid=$(lock_field "$proj/.claude/.session-lock" "sessionId")
    # Should have generated something non-empty
    assert_neq "" "$sid" "sessionId should be auto-generated when not provided"
}
run_test "acquire generates sessionId when not provided" test_acquire_generates_session_id

# ── release_lock tests ──────────────────────────────────────────────────────

test_release_removes_lockfile() {
    local proj="$TEST_TMPDIR/project"
    make_project_dir "$proj"

    source "$LOCK_SCRIPT"
    acquire_lock "$proj" "my-session"
    assert_file_exists "$proj/.claude/.session-lock"

    release_lock "$proj" "my-session"
    assert_file_not_exists "$proj/.claude/.session-lock"
}
run_test "release removes lock file" test_release_removes_lockfile

test_release_only_own_session() {
    local proj="$TEST_TMPDIR/project"
    make_project_dir "$proj"

    source "$LOCK_SCRIPT"
    acquire_lock "$proj" "session-A"

    # Try to release with different session ID — should fail
    local rc=0
    release_lock "$proj" "session-B" || rc=$?

    assert_eq "1" "$rc" "release should fail for different sessionId"
    assert_file_exists "$proj/.claude/.session-lock" "lock should still exist"
}
run_test "release only removes own lock (sessionId check)" test_release_only_own_session

test_release_by_pid_when_no_session_id() {
    local proj="$TEST_TMPDIR/project"
    make_project_dir "$proj"

    source "$LOCK_SCRIPT"
    acquire_lock "$proj" "my-session"

    # Release without session ID — should use PID check
    local rc=0
    release_lock "$proj" || rc=$?

    assert_eq "0" "$rc" "release without sessionId should succeed if PID matches"
    assert_file_not_exists "$proj/.claude/.session-lock"
}
run_test "release by PID when no sessionId provided" test_release_by_pid_when_no_session_id

test_release_noop_when_no_lock() {
    local proj="$TEST_TMPDIR/project"
    make_project_dir "$proj"

    source "$LOCK_SCRIPT"
    # Release when no lock exists — should succeed (noop)
    local rc=0
    release_lock "$proj" "any" || rc=$?

    assert_eq "0" "$rc" "release should be noop when no lock exists"
}
run_test "release is noop when no lock exists" test_release_noop_when_no_lock

# ── check_lock tests ────────────────────────────────────────────────────────

test_check_returns_0_when_free() {
    local proj="$TEST_TMPDIR/project"
    make_project_dir "$proj"

    source "$LOCK_SCRIPT"
    local rc=0
    check_lock "$proj" || rc=$?

    assert_eq "0" "$rc" "check should return 0 when no lock exists"
}
run_test "check returns 0 (free) when no lock" test_check_returns_0_when_free

test_check_returns_1_when_locked_by_us() {
    local proj="$TEST_TMPDIR/project"
    make_project_dir "$proj"

    source "$LOCK_SCRIPT"
    acquire_lock "$proj" "our-session"

    local rc=0
    check_lock "$proj" || rc=$?

    assert_eq "1" "$rc" "check should return 1 when locked by us"
}
run_test "check returns 1 (locked by us)" test_check_returns_1_when_locked_by_us

test_check_returns_2_when_locked_by_another_session() {
    local proj="$TEST_TMPDIR/project"
    make_project_dir "$proj"

    # Spawn a background sleep process (owned by us, so kill -0 works)
    sleep 300 &
    local other_pid=$!

    # Write a lock with our machine but the background process PID
    cat > "$proj/.claude/.session-lock" << LOCKEOF
{"machine":"$(hostname)","pid":$other_pid,"sessionId":"other-session","timestamp":"2026-01-01T00:00:00Z","user":"$(whoami)"}
LOCKEOF

    source "$LOCK_SCRIPT"
    local rc=0
    check_lock "$proj" || rc=$?

    # Clean up background process
    kill "$other_pid" 2>/dev/null
    wait "$other_pid" 2>/dev/null

    assert_eq "2" "$rc" "check should return 2 when locked by another session on this machine"
}
run_test "check returns 2 (locked by another session, same machine)" test_check_returns_2_when_locked_by_another_session

test_check_returns_3_when_locked_by_another_machine() {
    local proj="$TEST_TMPDIR/project"
    make_project_dir "$proj"

    # Write a lock with a different machine name
    cat > "$proj/.claude/.session-lock" << LOCKEOF
{"machine":"other-host-xyz","pid":12345,"sessionId":"remote-session","timestamp":"2026-01-01T00:00:00Z","user":"someone"}
LOCKEOF

    source "$LOCK_SCRIPT"
    local rc=0
    check_lock "$proj" || rc=$?

    assert_eq "3" "$rc" "check should return 3 when locked by another machine"
}
run_test "check returns 3 (locked by another machine)" test_check_returns_3_when_locked_by_another_machine

test_check_returns_0_when_stale() {
    local proj="$TEST_TMPDIR/project"
    make_project_dir "$proj"

    # Write a lock with a dead PID on this machine
    local dead_pid=99999
    while kill -0 "$dead_pid" 2>/dev/null; do
        dead_pid=$((dead_pid + 1))
    done

    cat > "$proj/.claude/.session-lock" << LOCKEOF
{"machine":"$(hostname)","pid":$dead_pid,"sessionId":"dead-session","timestamp":"2026-01-01T00:00:00Z","user":"$(whoami)"}
LOCKEOF

    source "$LOCK_SCRIPT"
    local rc=0
    check_lock "$proj" || rc=$?

    assert_eq "0" "$rc" "check should return 0 for stale lock (dead PID, auto-cleaned)"
    assert_file_not_exists "$proj/.claude/.session-lock" "stale lock should be auto-cleaned"
}
run_test "check auto-cleans stale lock and returns 0 (free)" test_check_returns_0_when_stale

# ── lock_info tests ─────────────────────────────────────────────────────────

test_lock_info_prints_readable() {
    local proj="$TEST_TMPDIR/project"
    make_project_dir "$proj"

    source "$LOCK_SCRIPT"
    acquire_lock "$proj" "info-session"

    local output
    output=$(lock_info "$proj")

    assert_contains "$output" "$(hostname)" "output should contain machine name"
    assert_contains "$output" "$$" "output should contain PID"
    assert_contains "$output" "info-session" "output should contain session ID"
}
run_test "lock_info prints readable output" test_lock_info_prints_readable

test_lock_info_no_lock() {
    local proj="$TEST_TMPDIR/project"
    make_project_dir "$proj"

    source "$LOCK_SCRIPT"
    local output
    output=$(lock_info "$proj")

    assert_contains "$output" "No lock" "should report no lock when none exists"
}
run_test "lock_info reports no lock when none exists" test_lock_info_no_lock

# ── force_release tests ─────────────────────────────────────────────────────

test_force_release_always_works() {
    local proj="$TEST_TMPDIR/project"
    make_project_dir "$proj"

    # Write a lock from "another machine"
    cat > "$proj/.claude/.session-lock" << LOCKEOF
{"machine":"other-host","pid":1,"sessionId":"foreign-session","timestamp":"2026-01-01T00:00:00Z","user":"someone"}
LOCKEOF

    source "$LOCK_SCRIPT"
    local rc=0
    force_release "$proj" || rc=$?

    assert_eq "0" "$rc" "force_release should always succeed"
    assert_file_not_exists "$proj/.claude/.session-lock" "lock file should be removed"
}
run_test "force_release always removes lock" test_force_release_always_works

test_force_release_noop_when_no_lock() {
    local proj="$TEST_TMPDIR/project"
    make_project_dir "$proj"

    source "$LOCK_SCRIPT"
    local rc=0
    force_release "$proj" || rc=$?

    assert_eq "0" "$rc" "force_release should succeed even when no lock exists"
}
run_test "force_release noop when no lock" test_force_release_noop_when_no_lock

# ── _is_pid_alive tests ────────────────────────────────────────────────────

test_is_pid_alive_self() {
    source "$LOCK_SCRIPT"
    local rc=0
    _is_pid_alive $$ || rc=$?

    assert_eq "0" "$rc" "our own PID should be alive"
}
run_test "_is_pid_alive detects living process" test_is_pid_alive_self

test_is_pid_alive_dead() {
    source "$LOCK_SCRIPT"
    local dead_pid=99999
    while kill -0 "$dead_pid" 2>/dev/null; do
        dead_pid=$((dead_pid + 1))
    done

    local rc=0
    _is_pid_alive "$dead_pid" || rc=$?

    assert_eq "1" "$rc" "dead PID should not be alive"
}
run_test "_is_pid_alive detects dead process" test_is_pid_alive_dead

# ── Edge cases ──────────────────────────────────────────────────────────────

test_acquire_creates_claude_dir_if_missing() {
    local proj="$TEST_TMPDIR/project-no-claude"
    mkdir -p "$proj"
    # No .claude/ dir exists

    source "$LOCK_SCRIPT"
    acquire_lock "$proj" "edge-session"

    assert_file_exists "$proj/.claude/.session-lock"
}
run_test "acquire creates .claude/ dir if missing" test_acquire_creates_claude_dir_if_missing

test_corrupt_lockfile_treated_as_stale() {
    local proj="$TEST_TMPDIR/project"
    make_project_dir "$proj"

    echo "not json at all" > "$proj/.claude/.session-lock"

    source "$LOCK_SCRIPT"
    local rc=0
    acquire_lock "$proj" "rescue-session" || rc=$?

    assert_eq "0" "$rc" "acquire should succeed when lock file is corrupt"
    # Should now have our valid lock
    local sid
    sid=$(lock_field "$proj/.claude/.session-lock" "sessionId")
    assert_eq "rescue-session" "$sid" "should have our session after cleaning corrupt lock"
}
run_test "corrupt lock file treated as stale (overwritten)" test_corrupt_lockfile_treated_as_stale

test_check_corrupt_lockfile() {
    local proj="$TEST_TMPDIR/project"
    make_project_dir "$proj"

    echo "{{garbage}}" > "$proj/.claude/.session-lock"

    source "$LOCK_SCRIPT"
    local rc=0
    check_lock "$proj" || rc=$?

    assert_eq "0" "$rc" "check should return 0 (free) for corrupt lock"
    assert_file_not_exists "$proj/.claude/.session-lock" "corrupt lock should be cleaned up"
}
run_test "check cleans up corrupt lock file" test_check_corrupt_lockfile

# ── Summary ─────────────────────────────────────────────────────────────────

suite_summary
