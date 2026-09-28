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

# ── release_own_lock tests (CFG-452 — clobber prevention) ────────────────────

test_release_own_lock_removes_matching_sid() {
    local proj="$TEST_TMPDIR/project"
    make_project_dir "$proj"
    source "$LOCK_SCRIPT"
    # Force the degraded (no resolvable CC pid) path so this test deterministically
    # exercises the legacy sessionId release contract regardless of whether the
    # suite is run standalone or nested under a live CC session. (CFG-454)
    local _CC_SELF_PID=""
    acquire_lock "$proj" "own-sid-1"

    local rc=0
    release_own_lock "$proj" "own-sid-1" || rc=$?
    assert_eq "0" "$rc" "release_own_lock succeeds for matching sid (degraded/sessionId path)"

    local exists=0
    if [[ -f "$proj/.claude/.session-lock" ]]; then exists=1; fi
    assert_eq "0" "$exists" "lock removed when sid matches"
}
run_test "release_own_lock removes lock when sid matches" test_release_own_lock_removes_matching_sid

test_release_own_lock_keeps_foreign_lock() {
    local proj="$TEST_TMPDIR/project"
    make_project_dir "$proj"
    source "$LOCK_SCRIPT"
    # A live leader holds the lock (our PID, foreign sid)
    acquire_lock "$proj" "leader-sid"

    local rc=0
    release_own_lock "$proj" "follower-sid" || rc=$?
    assert_eq "1" "$rc" "release_own_lock refuses a foreign lock"

    local exists=0
    if [[ -f "$proj/.claude/.session-lock" ]]; then exists=1; fi
    assert_eq "1" "$exists" "foreign lock left intact (no clobber)"
}
run_test "release_own_lock leaves foreign lock intact" test_release_own_lock_keeps_foreign_lock

test_release_own_lock_keeps_lock_when_no_sid() {
    local proj="$TEST_TMPDIR/project"
    make_project_dir "$proj"
    source "$LOCK_SCRIPT"
    acquire_lock "$proj" "leader-sid"

    local rc=0
    release_own_lock "$proj" "" || rc=$?
    assert_eq "1" "$rc" "release_own_lock refuses when no sid supplied"

    local exists=0
    if [[ -f "$proj/.claude/.session-lock" ]]; then exists=1; fi
    assert_eq "1" "$exists" "lock left intact when ownership unprovable"
}
run_test "release_own_lock leaves lock when no sid supplied" test_release_own_lock_keeps_lock_when_no_sid

test_release_own_lock_noop_when_no_lock() {
    local proj="$TEST_TMPDIR/project"
    make_project_dir "$proj"
    source "$LOCK_SCRIPT"

    local rc=0
    release_own_lock "$proj" "any-sid" || rc=$?
    assert_eq "0" "$rc" "release_own_lock is a safe no-op when no lock exists"
}
run_test "release_own_lock is noop when no lock exists" test_release_own_lock_noop_when_no_lock

test_release_own_lock_keeps_corrupt_lock() {
    local proj="$TEST_TMPDIR/project"
    make_project_dir "$proj"
    printf '{ not valid json ' > "$proj/.claude/.session-lock"

    source "$LOCK_SCRIPT"
    local rc=0
    release_own_lock "$proj" "some-sid" || rc=$?
    assert_eq "1" "$rc" "release_own_lock refuses an unreadable lock"

    local exists=0
    if [[ -f "$proj/.claude/.session-lock" ]]; then exists=1; fi
    assert_eq "1" "$exists" "corrupt lock left intact"
}
run_test "release_own_lock leaves corrupt lock intact" test_release_own_lock_keeps_corrupt_lock

# ── ccSessionId ownership (CFG-452 Phase 1 — env-inheritance spoof fix, F1) ───

test_acquire_records_cc_session() {
    local proj="$TEST_TMPDIR/project"
    make_project_dir "$proj"
    source "$LOCK_SCRIPT"
    acquire_lock "$proj" "afleet-1" "cc-abc"
    local cc
    cc=$(lock_field "$proj/.claude/.session-lock" "ccSessionId")
    assert_eq "cc-abc" "$cc" "acquire_lock records ccSessionId when provided"
}
run_test "acquire_lock records ccSessionId" test_acquire_records_cc_session

test_stamp_cc_session_adds_cc() {
    local proj="$TEST_TMPDIR/project"
    make_project_dir "$proj"
    source "$LOCK_SCRIPT"
    acquire_lock "$proj" "afleet-1"          # afleet acquire, no cc yet
    stamp_cc_session "$proj" "cc-leader"
    local cc sid
    cc=$(lock_field "$proj/.claude/.session-lock" "ccSessionId")
    sid=$(lock_field "$proj/.claude/.session-lock" "sessionId")
    assert_eq "afleet-1" "$sid" "stamp preserves sessionId"
    assert_eq "cc-leader" "$cc" "stamp_cc_session sets ccSessionId"
}
run_test "stamp_cc_session stamps an owned lock" test_stamp_cc_session_adds_cc

test_release_rejects_env_spoof() {
    # F1: a nested CC process inherits AFLEET_SESSION_ID but has a DIFFERENT cc session id
    local proj="$TEST_TMPDIR/project"
    make_project_dir "$proj"
    source "$LOCK_SCRIPT"
    acquire_lock "$proj" "afleet-1"
    stamp_cc_session "$proj" "cc-LEADER"

    local rc=0
    release_own_lock "$proj" "afleet-1" "cc-NESTED" || rc=$?
    assert_eq "1" "$rc" "nested (foreign cc, same afleet sid) must not release"
    local exists=0
    if [[ -f "$proj/.claude/.session-lock" ]]; then exists=1; fi
    assert_eq "1" "$exists" "leader lock survives the env-inheritance spoof"
}
run_test "release_own_lock rejects env-inheritance spoof" test_release_rejects_env_spoof

test_release_by_cc_session_matches() {
    local proj="$TEST_TMPDIR/project"
    make_project_dir "$proj"
    source "$LOCK_SCRIPT"
    acquire_lock "$proj" "afleet-1"
    stamp_cc_session "$proj" "cc-LEADER"

    local rc=0
    release_own_lock "$proj" "afleet-1" "cc-LEADER" || rc=$?
    assert_eq "0" "$rc" "leader (matching cc) releases its own lock"
    local exists=0
    if [[ -f "$proj/.claude/.session-lock" ]]; then exists=1; fi
    assert_eq "0" "$exists" "lock removed on matching ccSessionId"
}
run_test "release_own_lock releases on matching ccSessionId" test_release_by_cc_session_matches

test_release_cc_stamped_ignores_sessionid() {
    # Once cc-stamped, sessionId-only proof must NOT release the lock
    local proj="$TEST_TMPDIR/project"
    make_project_dir "$proj"
    source "$LOCK_SCRIPT"
    acquire_lock "$proj" "afleet-1"
    stamp_cc_session "$proj" "cc-LEADER"

    local rc=0
    release_own_lock "$proj" "afleet-1" "" || rc=$?
    assert_eq "1" "$rc" "sessionId-only proof cannot release a cc-stamped lock"
    local exists=0
    if [[ -f "$proj/.claude/.session-lock" ]]; then exists=1; fi
    assert_eq "1" "$exists" "cc-stamped lock survives a sessionId-only release"
}
run_test "release_own_lock ignores sessionId once cc-stamped" test_release_cc_stamped_ignores_sessionid

# ── CFG-454: unstamped-lock ownership by CC-process ancestry (F1 full close) ──
# An UNSTAMPED lock must NOT be released/claimed by an inherited AFLEET_SESSION_ID
# (the spoofable env var). Ownership is proven by process ancestry: the lock's
# recorded pid is a live ANCESTOR of the owning session's CC (afleet runs mclaude
# as a child via `script`, so the afleet shell stays CC's ancestor). Walking up
# from the caller's own CC, the leader reaches the lock pid before any other CC; a
# nested CC hits the leader's CC first. These tests model the real topology with a
# stubbed process tree (override _ppid_of/_pid_is_cc after sourcing) + _CC_SELF_PID:
#   100 afleet-shell → 200 script → 300 leader-CC → 400 nested-bash → 500 nested-CC
_cfg454_stub_tree() {
    _ppid_of() { case "$1" in 300) echo 200;; 200) echo 100;; 100) echo 1;; 500) echo 400;; 400) echo 300;; *) echo "";; esac; }
    _pid_is_cc() { case "$1" in 300|500) return 0;; *) return 1;; esac; }
}

test_cfg454_owns_leader() {
    source "$LOCK_SCRIPT"; _cfg454_stub_tree
    local _CC_SELF_PID=300      # leader (outermost) CC
    local rc=0; _cc_owns_lock_pid 100 || rc=$?
    assert_eq "0" "$rc" "outermost leader CC owns a lock whose pid is its afleet-shell ancestor (100)"
}
run_test "CFG-454: _cc_owns_lock_pid — leader owns ancestor-pid lock" test_cfg454_owns_leader

test_cfg454_owns_nested_refused() {
    source "$LOCK_SCRIPT"; _cfg454_stub_tree
    local _CC_SELF_PID=500      # nested CC (leader CC 300 above it)
    local rc=0; _cc_owns_lock_pid 100 || rc=$?
    assert_eq "1" "$rc" "nested CC hits the leader CC first → does NOT own the leader's lock"
}
run_test "CFG-454: _cc_owns_lock_pid — nested refused" test_cfg454_owns_nested_refused

test_cfg454_owns_foreign_refused() {
    source "$LOCK_SCRIPT"; _cfg454_stub_tree
    local _CC_SELF_PID=300      # a leader whose ancestry does NOT contain pid 999
    local rc=0; _cc_owns_lock_pid 999 || rc=$?
    assert_eq "1" "$rc" "a different session's lock pid (not in our ancestry) is not owned"
}
run_test "CFG-454: _cc_owns_lock_pid — foreign session refused" test_cfg454_owns_foreign_refused

test_cfg454_owns_unresolvable_refused() {
    source "$LOCK_SCRIPT"; _cfg454_stub_tree
    local _CC_SELF_PID=""       # native-binary detection gap (unresolvable own CC pid)
    local rc=0; _cc_owns_lock_pid 100 || rc=$?
    assert_eq "1" "$rc" "unresolvable own CC pid → not proven owner (caller falls back to sessionId)"
}
run_test "CFG-454: _cc_owns_lock_pid — unresolvable → not owner" test_cfg454_owns_unresolvable_refused

test_cfg454_is_nested_leader_no() {
    source "$LOCK_SCRIPT"; _cfg454_stub_tree
    local _CC_SELF_PID=300
    local rc=0; _cc_is_nested || rc=$?
    assert_eq "1" "$rc" "outermost leader CC is NOT nested"
}
run_test "CFG-454: _cc_is_nested — leader is not nested" test_cfg454_is_nested_leader_no

test_cfg454_is_nested_nested_yes() {
    source "$LOCK_SCRIPT"; _cfg454_stub_tree
    local _CC_SELF_PID=500
    local rc=0; _cc_is_nested || rc=$?
    assert_eq "0" "$rc" "nested CC (leader CC above it) IS nested"
}
run_test "CFG-454: _cc_is_nested — nested detected" test_cfg454_is_nested_nested_yes

test_cfg454_release_leader_ok_nested_blocked() {
    local proj="$TEST_TMPDIR/project-454rel"
    make_project_dir "$proj"
    source "$LOCK_SCRIPT"; _cfg454_stub_tree
    # Unstamped leader lock recorded with the afleet-shell pid (100), sessionId set.
    _write_lock "$proj/.claude/.session-lock" "afleet-leader" "" 100

    # Nested CC (500) with inherited AFLEET_SESSION_ID=afleet-leader must NOT release.
    # `|| return 1` stops the test at the first failed assert, since later steps depend
    # on it. (Since CFG-532 a bare failing assert fails the test too.)
    local _CC_SELF_PID=500
    local rc=0; release_own_lock "$proj" "afleet-leader" "cc-nested" || rc=$?
    assert_eq "1" "$rc" "nested CC cannot release the leader's unstamped lock (ancestry proof)" || return 1
    local exists=0; [[ -f "$proj/.claude/.session-lock" ]] && exists=1
    assert_eq "1" "$exists" "leader lock survives the nested release attempt" || return 1

    # Leader CC (300) releases its own lock.
    _CC_SELF_PID=300
    rc=0; release_own_lock "$proj" "afleet-leader" "" || rc=$?
    assert_eq "0" "$rc" "leader CC releases its own unstamped lock via ancestry proof" || return 1
    exists=0; [[ -f "$proj/.claude/.session-lock" ]] && exists=1
    assert_eq "0" "$exists" "leader's own lock is removed"
}
run_test "CFG-454: release — leader releases, nested blocked (real afleet topology)" test_cfg454_release_leader_ok_nested_blocked

test_cfg454_release_degraded_sessionid() {
    local proj="$TEST_TMPDIR/project-454deg"
    make_project_dir "$proj"
    source "$LOCK_SCRIPT"; _cfg454_stub_tree
    _write_lock "$proj/.claude/.session-lock" "afleet-leader" "" 100
    local _CC_SELF_PID=""       # native-binary gap → degraded sessionId proof
    local rc=0; release_own_lock "$proj" "afleet-leader" "" || rc=$?
    assert_eq "0" "$rc" "degraded platform falls back to sessionId release for the genuine leader" || return 1
    local exists=0; [[ -f "$proj/.claude/.session-lock" ]] && exists=1
    assert_eq "0" "$exists" "degraded-env sessionId release removes the lock"
}
run_test "CFG-454: release — degraded env keeps sessionId path" test_cfg454_release_degraded_sessionid

test_cfg454_stamp_nested_blocked_leader_ok() {
    local proj="$TEST_TMPDIR/project-454stamp"
    make_project_dir "$proj"
    source "$LOCK_SCRIPT"; _cfg454_stub_tree
    _is_pid_alive() { [[ "$1" == "100" ]] && return 0; return 1; }   # afleet shell alive
    _write_lock "$proj/.claude/.session-lock" "afleet-leader" "" 100

    # Nested CC (500) must NOT claim (stamp) the leader's live unstamped lock.
    # `|| return 1` stops the test at the first failed assert (CFG-532 fails it either way).
    local _CC_SELF_PID=500
    local rc=0; stamp_cc_session "$proj" "cc-nested" || rc=$?
    assert_eq "1" "$rc" "nested CC cannot stamp (claim) the leader's live unstamped lock" || return 1
    _read_lock "$proj/.claude/.session-lock"
    assert_eq "" "$_LOCK_CC_SESSION" "lock not bound to the nested cc id (clobber precursor blocked)" || return 1

    # Leader CC (300) stamps its own lock.
    _CC_SELF_PID=300
    rc=0; stamp_cc_session "$proj" "cc-leader" || rc=$?
    assert_eq "0" "$rc" "leader CC stamps its own lock" || return 1
    _read_lock "$proj/.claude/.session-lock"
    assert_eq "cc-leader" "$_LOCK_CC_SESSION" "leader's lock is bound to its cc id"
}
run_test "CFG-454: stamp — nested blocked, leader stamps (real afleet topology)" test_cfg454_stamp_nested_blocked_leader_ok

# ── check_lock tests ────────────────────────────────────────────────────────

test_check_returns_0_when_free() {
    local proj="$TEST_TMPDIR/project"
    local _CC_SELF_PID=$$   # the caller's own CC is visible, as for every hook (CFG-673: a blind scan answers 4)
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
    local _CC_SELF_PID=$$   # the caller's own CC is visible, as for every hook (CFG-673: a blind scan answers 4)
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
    local _CC_SELF_PID=$$   # the caller's own CC is visible, as for every hook (CFG-673: a blind scan answers 4)
    make_project_dir "$proj"

    echo "{{garbage}}" > "$proj/.claude/.session-lock"

    source "$LOCK_SCRIPT"
    local rc=0
    check_lock "$proj" || rc=$?

    assert_eq "0" "$rc" "check should return 0 (free) for corrupt lock"
    assert_file_not_exists "$proj/.claude/.session-lock" "corrupt lock should be cleaned up"
}
run_test "check cleans up corrupt lock file" test_check_corrupt_lockfile

# ── AFLEET_SESSION_ID recognition (CFG-146 fix) ─────────────────────────────
# Bug: afleet acquires lock (its PID), launches claude (different PID).
# Hook's check_lock returns 2 (foreign lock) because $$ differs from afleet PID.
# Fix: config-check.sh compares AFLEET_SESSION_ID against lock's sessionId.
# These tests validate the recognition pattern used in Check 31.

test_afleet_session_id_recognizes_parent_lock() {
    local proj="$TEST_TMPDIR/project"
    make_project_dir "$proj"

    # Simulate afleet: spawn background process, acquire lock with its PID
    sleep 300 &
    local afleet_pid=$!
    local session_id="test-afleet-session-$(date +%s)"

    # Write lock as if afleet (different PID) acquired it
    cat > "$proj/.claude/.session-lock" << LOCKEOF
{"machine":"$(hostname)","pid":$afleet_pid,"sessionId":"$session_id","timestamp":"2026-01-01T00:00:00Z","user":"$(whoami)"}
LOCKEOF

    source "$LOCK_SCRIPT"

    # check_lock sees foreign PID (alive) → returns 2
    local rc=0
    check_lock "$proj" || rc=$?
    assert_eq "2" "$rc" "check_lock should return 2 (different live PID)"

    # But AFLEET_SESSION_ID matches → hook should recognize it as our lock
    _read_lock "$proj/.claude/.session-lock" 2>/dev/null
    local match="false"
    if [[ "$_LOCK_SESSION" == "$session_id" ]]; then
        match="true"
    fi
    assert_eq "true" "$match" "session ID comparison should match (AFLEET_SESSION_ID pattern)"

    kill "$afleet_pid" 2>/dev/null
    wait "$afleet_pid" 2>/dev/null || true
}
run_test "AFLEET_SESSION_ID recognizes parent process lock (CFG-146 fix)" test_afleet_session_id_recognizes_parent_lock

test_afleet_session_id_does_not_match_foreign() {
    local proj="$TEST_TMPDIR/project"
    make_project_dir "$proj"

    sleep 300 &
    local other_pid=$!

    cat > "$proj/.claude/.session-lock" << LOCKEOF
{"machine":"$(hostname)","pid":$other_pid,"sessionId":"foreign-session-xyz","timestamp":"2026-01-01T00:00:00Z","user":"$(whoami)"}
LOCKEOF

    source "$LOCK_SCRIPT"

    # check_lock returns 2
    local rc=0
    check_lock "$proj" || rc=$?
    assert_eq "2" "$rc" "check_lock should return 2 for foreign lock"

    # Session ID does NOT match our AFLEET_SESSION_ID → stays foreign
    _read_lock "$proj/.claude/.session-lock" 2>/dev/null
    local our_sid="our-session-abc"
    local match="false"
    if [[ "$_LOCK_SESSION" == "$our_sid" ]]; then
        match="true"
    fi
    assert_eq "false" "$match" "session ID should NOT match when truly foreign"

    kill "$other_pid" 2>/dev/null
    wait "$other_pid" 2>/dev/null || true
}
run_test "AFLEET_SESSION_ID does not false-match foreign lock" test_afleet_session_id_does_not_match_foreign

# ── hostname fallback tests ───────────────────────────────────────────────

test_hostname_fallback_etc_hostname() {
    if [[ ! -f /etc/hostname ]] || [[ ! -r /etc/hostname ]]; then
        skip_test "/etc/hostname not present" "/etc/hostname does not exist or is not readable (e.g. Fedora uses hostnamectl)"
        return
    fi
    local result
    result="$(cat /etc/hostname 2>/dev/null | tr -d '[:space:]')"
    if [[ -z "$result" ]]; then
        skip_test "/etc/hostname empty" "/etc/hostname exists but is empty (e.g. Fedora uses hostnamectl)"
        return
    fi
    local has_content="true"
    assert_eq "true" "$has_content" "/etc/hostname should be readable and non-empty"
}
run_test "hostname fallback: /etc/hostname readable" test_hostname_fallback_etc_hostname

test_hostname_fallback_uname() {
    local result
    result="$(uname -n 2>/dev/null || echo "")"
    local has_content="false"
    [[ -n "$result" && "$result" != "unknown" ]] && has_content="true"
    assert_eq "true" "$has_content" "uname -n should return a real hostname"
}
run_test "hostname fallback: uname -n works" test_hostname_fallback_uname

test_hostname_fallback_chain_under_set_e() {
    local result
    result="$(set -euo pipefail; hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || uname -n 2>/dev/null || echo unknown)"
    local valid="false"
    [[ -n "$result" && "$result" != "unknown" ]] && valid="true"
    assert_eq "true" "$valid" "fallback chain should resolve a real hostname under set -euo pipefail"
}
run_test "hostname fallback: full chain under set -euo pipefail" test_hostname_fallback_chain_under_set_e

test_hostname_unknown_warning_in_source() {
    local found="false"
    grep -q 'WARNING.*hostname.*unknown' "$LOCK_SCRIPT" && found="true"
    assert_eq "true" "$found" "session-lock.sh should contain unknown hostname warning"
}
run_test "hostname fallback: 'unknown' warning exists in source" test_hostname_unknown_warning_in_source

test_lock_machine_field_populated() {
    local proj="$TEST_TMPDIR/project"
    make_project_dir "$proj"

    source "$LOCK_SCRIPT"
    acquire_lock "$proj" "test-hostname-field" 2>/dev/null
    local machine_val
    machine_val="$(lock_field "$proj/.claude/.session-lock" "machine")"
    local valid="false"
    [[ -n "$machine_val" && "$machine_val" != "unknown" ]] && valid="true"
    assert_eq "true" "$valid" "lock machine field should be a real hostname (got: $machine_val)"
}
run_test "lock file machine field is populated correctly" test_lock_machine_field_populated

# ── CFG-536 / CFG-454(2): check_lock must be able to recognise its OWN owner ──
# check_lock proved ownership by `$_LOCK_PID == $$ || == $self_pid` only. On the
# primary `af`/afleet launch path the lock records the LAUNCHER shell while
# _cc_self_pid resolves the claude.exe pid, so that comparison can never match
# and every leader read its own live lock as foreign (rc 2). Measured live in
# this repo on 2026-08-23: lock pid 1831764 (afleet shell, alive), own CC 1836804
# — no match, rc 2, while AFLEET_SESSION_ID matched the lock's sessionId exactly
# and the lock pid was a clean ancestor of our CC. Two independent proofs of
# ownership were sitting in the library unused.
#
# Consequence, and why it is not cosmetic: the documented shutdown command
# (`rotate-session.sh`, bare) refuses for the real leader, and the obvious
# workaround is --owner-verified — the bypass a security review flagged as able
# to blank a live session's context from another project. A guard that refuses
# its owner every time trains the habit of disarming it.
#
# Stub tree (as _cfg454_stub_tree):
#   100 afleet-shell → 200 script → 300 leader-CC → 400 nested-bash → 500 nested-CC

_cfg536_lock() {   # <proj> <sessionId> <ccSessionId> <pid>
    make_project_dir "$1"
    _write_lock "$1/.claude/.session-lock" "$2" "$3" "$4"
}

test_cfg536_owner_by_ancestry() {
    local proj="$TEST_TMPDIR/p536-anc"
    source "$LOCK_SCRIPT"; _cfg454_stub_tree
    _is_pid_alive() { [[ "$1" == "100" ]] && return 0; return 1; }
    _cfg536_lock "$proj" "sess-other" "cc-other" 100     # ids deliberately do NOT match
    local _CC_SELF_PID=300 CC_SESSION_ID="" AFLEET_SESSION_ID=""
    local rc=0; check_lock "$proj" 300 || rc=$?
    assert_eq "1" "$rc" "leader owns a live lock whose pid is its launcher ancestor (the af launch shape)"
}
run_test "CFG-536: check_lock — ownership by launcher ancestry" test_cfg536_owner_by_ancestry

test_cfg536_owner_by_cc_session_id() {
    local proj="$TEST_TMPDIR/p536-cc"
    source "$LOCK_SCRIPT"; _cfg454_stub_tree
    _is_pid_alive() { [[ "$1" == "777" ]] && return 0; return 1; }
    _cfg536_lock "$proj" "sess-x" "cc-mine" 777          # pid 777 is unrelated to our tree
    local _CC_SELF_PID=300 CC_SESSION_ID="cc-mine" AFLEET_SESSION_ID=""
    local rc=0; check_lock "$proj" 300 || rc=$?
    assert_eq "1" "$rc" "a matching ccSessionId proves ownership when the pid cannot"
}
run_test "CFG-536: check_lock — ownership by ccSessionId" test_cfg536_owner_by_cc_session_id

test_cfg536_owner_by_afleet_session_id() {
    # CFG-672 narrowed this contract: the afleet id is an INHERITED env var, so
    # it proves ownership only when our own CC pid is unresolvable (degraded
    # matcher) — whenever the matcher works, ancestry is the proof for the af
    # path (test_cfg536_owner_by_ancestry) and the id match is not consulted.
    local proj="$TEST_TMPDIR/p536-af"
    source "$LOCK_SCRIPT"; _cfg454_stub_tree
    _is_pid_alive() { [[ "$1" == "777" ]] && return 0; return 1; }
    _cfg536_lock "$proj" "sess-mine" "" 777
    local _CC_SELF_PID="" CC_SESSION_ID="" AFLEET_SESSION_ID="sess-mine"
    local rc=0; check_lock "$proj" "" || rc=$?
    assert_eq "1" "$rc" "a matching afleet sessionId proves ownership when our own CC pid is unresolvable"
}
run_test "CFG-536: check_lock — ownership by afleet sessionId (degraded matcher)" test_cfg536_owner_by_afleet_session_id

# ── CFG-672: a tmux-launched CC carries the leader's AFLEET_SESSION_ID ──────
# tmux-launch.sh passes no `-e`, so `tmux new-session -d` hands the server's
# global environment — inherited from whichever session started the server —
# to every pane. A CC started in a pane is parented to the TMUX SERVER, not to
# the leader's CC, so _cc_is_nested (ancestry-only) cannot see it, and the
# ungated afleet-id comparison in check_lock returned 1 ("ours") for it.
# Stub tree = _cfg454_stub_tree plus the tmux branch:
#   1 → 550 tmux-server → 600 tmux-CC        (no CC above 600; 100 not above it)
_cfg672_stub_tree() {
    _cfg454_stub_tree
    _ppid_of() { case "$1" in 300) echo 200;; 200) echo 100;; 100) echo 1;; 500) echo 400;; 400) echo 300;; 600) echo 550;; 550) echo 1;; *) echo "";; esac; }
    _pid_is_cc() { case "$1" in 300|500|600) return 0;; *) return 1;; esac; }
    _is_pid_alive() { case "$1" in 100|550|600) return 0;; *) return 1;; esac; }
}

test_cfg672_tmux_cc_with_inherited_afleet_id_is_not_owner() {
    local proj="$TEST_TMPDIR/p672-tmux"
    source "$LOCK_SCRIPT"; _cfg672_stub_tree
    # The af leader's live, still-unstamped lock (afleet shell pid 100).
    _cfg536_lock "$proj" "sess-leader" "" 100
    # The tmux CC: its own CC pid resolves, its cc id is its own, and the
    # inherited AFLEET_SESSION_ID matches the lock exactly.
    local _CC_SELF_PID=600 CC_SESSION_ID="cc-tmux" AFLEET_SESSION_ID="sess-leader"
    local rc=0; check_lock "$proj" 600 || rc=$?
    assert_eq "2" "$rc" "a tmux-launched CC (not nested by ancestry, inherited afleet id) is NOT the owner (measured rc=$rc)"
}
run_test "CFG-672: check_lock — tmux CC with inherited AFLEET_SESSION_ID stays follower" test_cfg672_tmux_cc_with_inherited_afleet_id_is_not_owner

test_cfg672_af_leader_still_owner_with_matching_afleet_id() {
    # Regression: the genuine af leader (lock pid = its launcher ancestor) with
    # the SAME ids set is still the owner — via ancestry, not the env var.
    local proj="$TEST_TMPDIR/p672-leader"
    source "$LOCK_SCRIPT"; _cfg672_stub_tree
    _cfg536_lock "$proj" "sess-leader" "" 100
    local _CC_SELF_PID=300 CC_SESSION_ID="cc-leader" AFLEET_SESSION_ID="sess-leader"
    local rc=0; check_lock "$proj" 300 || rc=$?
    assert_eq "1" "$rc" "the af leader owns its launcher-ancestor lock with a matching afleet id (measured rc=$rc)"
}
run_test "CFG-672: check_lock — the af leader is still the owner" test_cfg672_af_leader_still_owner_with_matching_afleet_id

# ── CFG-454 3b(4): binding an UNSTAMPED lock needs POSITIVE ownership proof ──
# stamp_cc_session refused only a PROVEN nested CC. A CC launched via
# tmux-launch.sh / setsid is not a descendant of the leader, so that gate could
# not see it, and it inherits the leader's AFLEET_SESSION_ID: with the leader's
# lock still unstamped (deploy-transition window, or CC_SESSION_ID empty at the
# leader's SessionStart) it stamped the lock with ITS cc id and released it at
# its own SessionEnd. The claim now requires proof: the lock pid is our own
# shell (07b acquired it a moment ago) or a live launcher ancestor of our CC.
_cfg454_unstamped_lock() {   # <proj> <pid>
    make_project_dir "$1"
    _write_lock "$1/.claude/.session-lock" "sess-leader" "" "$2"
}

test_cfg454_stamp_tmux_cc_refused() {
    local proj="$TEST_TMPDIR/p454-tmux"
    source "$LOCK_SCRIPT"; _cfg672_stub_tree
    _cfg454_unstamped_lock "$proj" 100          # leader's launcher, alive
    local _CC_SELF_PID=600                      # tmux CC: not nested, not owner
    local rc=0; stamp_cc_session "$proj" "cc-tmux" || rc=$?
    assert_eq "1" "$rc" "a tmux-launched CC cannot claim the leader's live unstamped lock (measured rc=$rc)" || return 1
    _read_lock "$proj/.claude/.session-lock"
    assert_eq "" "$_LOCK_CC_SESSION" "the lock stays unstamped (not bound to the tmux CC's id)"
}
run_test "CFG-454: stamp — tmux-launched CC refused on a live unstamped lock" test_cfg454_stamp_tmux_cc_refused

test_cfg454_stamp_dead_pid_live_leader_refused() {
    # A direct-launch leader's hook pid has died but its CC is live in the
    # project: a foreign CC that somehow reaches stamp must still be refused.
    local proj="$TEST_TMPDIR/p454-deadpid"
    source "$LOCK_SCRIPT"; _cfg672_stub_tree
    _cfg454_unstamped_lock "$proj" 999          # dead recorded pid
    # The only live CC in the project is the leader (300): visible to everyone
    # but the leader itself (the scan excludes the caller's own tree).
    _project_has_live_cc() { [[ "$2" == "300" ]] && return 1; return 0; }
    local _CC_SELF_PID=600
    local rc=0; stamp_cc_session "$proj" "cc-tmux" || rc=$?
    assert_eq "1" "$rc" "dead recorded pid + a live leader CC in the project ⇒ claim refused (measured rc=$rc)" || return 1
    _read_lock "$proj/.claude/.session-lock"
    assert_eq "" "$_LOCK_CC_SESSION" "the leader's decayed lock is not bound to the rival's id"
}
run_test "CFG-454: stamp — dead lock pid but live leader in project ⇒ refused" test_cfg454_stamp_dead_pid_live_leader_refused

test_cfg454_stamp_leader_own_decayed_lock_ok() {
    # The same decayed lock, claimed by the leader itself: nobody else is live
    # in the project, so the stamp goes through (never self-block a solo leader).
    local proj="$TEST_TMPDIR/p454-deadpid-own"
    source "$LOCK_SCRIPT"; _cfg672_stub_tree
    _cfg454_unstamped_lock "$proj" 999
    _project_has_live_cc() { [[ "$2" == "300" ]] && return 1; return 0; }
    local _CC_SELF_PID=300
    local rc=0; stamp_cc_session "$proj" "cc-leader" || rc=$?
    assert_eq "0" "$rc" "the leader stamps its own decayed lock (measured rc=$rc)" || return 1
    _read_lock "$proj/.claude/.session-lock"
    assert_eq "cc-leader" "$_LOCK_CC_SESSION" "bound to the leader's cc id"
}
run_test "CFG-454: stamp — leader stamps its own decayed lock" test_cfg454_stamp_leader_own_decayed_lock_ok

test_cfg454_stamp_direct_launch_same_hook_pid_ok() {
    # Direct launch: 07b acquires (pid = the hook's \$\$) and stamps in the SAME
    # hook process. \$\$ is a DESCENDANT of our CC, never an ancestor, so ancestry
    # cannot prove it — the hook's own pid must be accepted as proof.
    local proj="$TEST_TMPDIR/p454-direct"
    source "$LOCK_SCRIPT"; _cfg454_stub_tree     # real _is_pid_alive: \$\$ is alive
    _cfg454_unstamped_lock "$proj" "$$"
    local _CC_SELF_PID=300
    local rc=0; stamp_cc_session "$proj" "cc-direct" || rc=$?
    assert_eq "0" "$rc" "the acquiring hook process stamps the lock it just wrote (measured rc=$rc)" || return 1
    _read_lock "$proj/.claude/.session-lock"
    assert_eq "cc-direct" "$_LOCK_CC_SESSION" "bound to the direct-launch cc id"
}
run_test "CFG-454: stamp — the acquiring hook process stamps its own lock" test_cfg454_stamp_direct_launch_same_hook_pid_ok

test_cfg454_stamp_degraded_fails_open() {
    # Unresolvable own CC pid (detection gap): no proof is possible either way,
    # so the claim goes through — the spoof needs a resolvable rival, which a
    # degraded platform equally lacks. Documented contract, not a regression.
    local proj="$TEST_TMPDIR/p454-degraded"
    source "$LOCK_SCRIPT"; _cfg672_stub_tree
    _cfg454_unstamped_lock "$proj" 100
    local _CC_SELF_PID=""
    local rc=0; stamp_cc_session "$proj" "cc-any" || rc=$?
    assert_eq "0" "$rc" "degraded matcher fails open on stamp (measured rc=$rc)"
}
run_test "CFG-454: stamp — degraded matcher fails open" test_cfg454_stamp_degraded_fails_open

test_cfg536_nested_cc_is_not_the_owner() {
    # A nested CC INHERITS the leader's environment, so the id comparisons above
    # would hand it ownership. It must stay a follower — this is the F1 spoof the
    # CFG-454 work exists to close, and the new ownership signals must not reopen it.
    local proj="$TEST_TMPDIR/p536-nested"
    source "$LOCK_SCRIPT"; _cfg454_stub_tree
    _is_pid_alive() { [[ "$1" == "100" ]] && return 0; return 1; }
    _cfg536_lock "$proj" "sess-mine" "cc-mine" 100
    local _CC_SELF_PID=500 CC_SESSION_ID="cc-mine" AFLEET_SESSION_ID="sess-mine"
    local rc=0; check_lock "$proj" 500 || rc=$?
    assert_eq "2" "$rc" "a nested CC with the leader's inherited env is still NOT the owner"
}
run_test "CFG-536: check_lock — nested CC never claims ownership" test_cfg536_nested_cc_is_not_the_owner

test_cfg536_foreign_live_lock_still_locked() {
    # Regression: a genuinely foreign live session must still read as locked.
    local proj="$TEST_TMPDIR/p536-foreign"
    source "$LOCK_SCRIPT"; _cfg454_stub_tree
    _is_pid_alive() { [[ "$1" == "777" ]] && return 0; return 1; }
    _cfg536_lock "$proj" "sess-other" "cc-other" 777
    local _CC_SELF_PID=300 CC_SESSION_ID="cc-mine" AFLEET_SESSION_ID="sess-mine"
    local rc=0; check_lock "$proj" 300 || rc=$?
    assert_eq "2" "$rc" "a live lock with no ownership proof is still foreign (rc 2)"
}
run_test "CFG-536: check_lock — foreign live lock still locked" test_cfg536_foreign_live_lock_still_locked

# ── CFG-454 ivbook: the ccSessionId proof must be reachable in production ────
# The ccSessionId match above only ever saw CC_SESSION_ID (exported by
# config-check.sh, so it exists ONLY inside the SessionStart hook) or
# CLAUDE_SESSION_ID (set by nothing). The ivbook refusal came from the agent's
# bare `rotate-session.sh` at shutdown — a Bash-tool subprocess, whose env
# carries the id as CLAUDE_CODE_SESSION_ID (Claude Code sets it per spawn, for
# hooks and tools alike, to the spawning CC's OWN id). So the proof never fired
# where it was needed. And the dead-recorded-pid branch never looked at the
# ccSessionId at all: a direct-launch lock's pid is ALWAYS the dead hook pid
# (CFG-468), so the leader read its own lock as foreign whenever any other CC
# (a follower, a tmux job) was cwd'd in the project.

test_cfg454_ivbook_cc_id_from_claude_code_env() {
    local proj="$TEST_TMPDIR/p454-ivbook-env"
    source "$LOCK_SCRIPT"; _cfg454_stub_tree
    _is_pid_alive() { [[ "$1" == "777" ]] && return 0; return 1; }
    _cfg536_lock "$proj" "sess-x" "cc-mine" 777          # alive, unrelated pid
    local _CC_SELF_PID=300 CC_SESSION_ID="" CLAUDE_SESSION_ID="" AFLEET_SESSION_ID=""
    local CLAUDE_CODE_SESSION_ID="cc-mine"
    local rc=0; check_lock "$proj" 300 || rc=$?
    assert_eq "1" "$rc" "the CC-provided CLAUDE_CODE_SESSION_ID proves ownership of a lock bound to it (measured rc=$rc)"
}
run_test "CFG-454: check_lock — ccSessionId proof via CLAUDE_CODE_SESSION_ID (Bash-tool env)" test_cfg454_ivbook_cc_id_from_claude_code_env

test_cfg454_dead_pid_own_cc_id_with_follower_live() {
    local proj="$TEST_TMPDIR/p454-deadpid-follower"
    source "$LOCK_SCRIPT"; _cfg454_stub_tree
    _is_pid_alive() { return 1; }                         # recorded pid 999 is dead
    _project_has_live_cc() { return 0; }                  # a follower CC is live in the project
    _cfg536_lock "$proj" "sess-x" "cc-mine" 999
    local _CC_SELF_PID=300 CC_SESSION_ID="" CLAUDE_SESSION_ID="" AFLEET_SESSION_ID=""
    local CLAUDE_CODE_SESSION_ID="cc-mine"
    local rc=0; check_lock "$proj" 300 || rc=$?
    assert_eq "1" "$rc" "dead recorded pid + a live follower: the lock bound to OUR cc id is still ours (measured rc=$rc)" || return 1
    assert_file_exists "$proj/.claude/.session-lock" "the leader's own lock is left in place"
}
run_test "CFG-454: check_lock — dead recorded pid, own ccSessionId, follower live ⇒ ours" test_cfg454_dead_pid_own_cc_id_with_follower_live

test_cfg454_dead_pid_own_cc_id_is_not_deleted() {
    # Solo leader, decayed pid: reading its own lock must not delete it (before,
    # check_lock rm'd it and reported "free", so every compaction of a direct
    # launch dropped and re-acquired the lock and 06b reported STALE_LOCK_CLEARED).
    local proj="$TEST_TMPDIR/p454-deadpid-solo"
    source "$LOCK_SCRIPT"; _cfg454_stub_tree
    _is_pid_alive() { return 1; }
    _project_has_live_cc() { return 1; }
    _cfg536_lock "$proj" "sess-x" "cc-mine" 999
    local _CC_SELF_PID=300 CC_SESSION_ID="cc-mine" CLAUDE_SESSION_ID="" AFLEET_SESSION_ID=""
    local CLAUDE_CODE_SESSION_ID=""
    local rc=0; check_lock "$proj" 300 || rc=$?
    assert_eq "1" "$rc" "dead recorded pid, own ccSessionId (hook's CC_SESSION_ID) ⇒ ours (measured rc=$rc)" || return 1
    assert_file_exists "$proj/.claude/.session-lock" "the owner's lock is not deleted as stale"
}
run_test "CFG-454: check_lock — dead recorded pid, own ccSessionId ⇒ ours, lock kept" test_cfg454_dead_pid_own_cc_id_is_not_deleted

test_cfg454_dead_pid_nested_cc_id_still_foreign() {
    # Regression guard for the gate: a NESTED CC that somehow carries the
    # leader's cc id in its env gets no ownership from it on a dead-pid lock.
    local proj="$TEST_TMPDIR/p454-deadpid-nested"
    source "$LOCK_SCRIPT"; _cfg454_stub_tree
    _is_pid_alive() { return 1; }
    _project_has_live_cc() { return 0; }                  # the leader (300) is live in the project
    _cfg536_lock "$proj" "sess-x" "cc-mine" 999
    local _CC_SELF_PID=500 CC_SESSION_ID="" CLAUDE_SESSION_ID="" AFLEET_SESSION_ID=""
    local CLAUDE_CODE_SESSION_ID="cc-mine"
    local rc=0; check_lock "$proj" 500 || rc=$?
    assert_eq "2" "$rc" "a nested CC with the leader's cc id is NOT the owner of the dead-pid lock (measured rc=$rc)" || return 1
    assert_file_exists "$proj/.claude/.session-lock" "the leader's lock is left in place"
}
run_test "CFG-454: check_lock — dead recorded pid, nested CC with leader's cc id ⇒ foreign" test_cfg454_dead_pid_nested_cc_id_still_foreign

test_cfg454_dead_pid_other_cc_id_still_foreign() {
    # Regression guard: a follower whose own cc id differs stays a follower.
    local proj="$TEST_TMPDIR/p454-deadpid-other"
    source "$LOCK_SCRIPT"; _cfg454_stub_tree
    _is_pid_alive() { return 1; }
    _project_has_live_cc() { return 0; }
    _cfg536_lock "$proj" "sess-x" "cc-leader" 999
    local _CC_SELF_PID=300 CC_SESSION_ID="" CLAUDE_SESSION_ID="" AFLEET_SESSION_ID=""
    local CLAUDE_CODE_SESSION_ID="cc-follower"
    local rc=0; check_lock "$proj" 300 || rc=$?
    assert_eq "2" "$rc" "dead recorded pid, someone else's cc id, a live CC in the project ⇒ foreign (measured rc=$rc)"
}
run_test "CFG-454: check_lock — dead recorded pid, other ccSessionId, live CC ⇒ foreign" test_cfg454_dead_pid_other_cc_id_still_foreign

test_cfg454_claude_code_id_needs_a_cc_above() {
    # CLAUDE_CODE_SESSION_ID is vouched for by the CC that spawned us, which
    # sets it per spawn. With NO CC above the caller nothing vouches for it: a
    # job in a tmux pane gets the tmux server's global env, i.e. the id of
    # whichever CC started the server (measured: a pane opened by a second
    # session saw the first session's id) — the CFG-672 class of inherited id.
    local proj="$TEST_TMPDIR/p454-no-cc-above"
    source "$LOCK_SCRIPT"; _cfg454_stub_tree
    _is_pid_alive() { [[ "$1" == "777" ]] && return 0; return 1; }
    _cfg536_lock "$proj" "sess-x" "cc-leader" 777
    local _CC_SELF_PID="" CC_SESSION_ID="" CLAUDE_SESSION_ID="" AFLEET_SESSION_ID=""
    local CLAUDE_CODE_SESSION_ID="cc-leader"
    local rc=0; check_lock "$proj" "" || rc=$?
    assert_eq "2" "$rc" "an inherited CLAUDE_CODE_SESSION_ID with no CC above the caller proves nothing (measured rc=$rc)"
}
run_test "CFG-454: check_lock — CLAUDE_CODE_SESSION_ID counts only with a CC above the caller" test_cfg454_claude_code_id_needs_a_cc_above

# ── _ppid_of: a process name with a space or ')' ────────────────────────────
# /proc/<pid>/stat is "pid (comm) state ppid …" and comm may itself contain
# spaces and ')'. Taking whitespace field 4 read "tmux: server" as state 'S',
# so the ancestry walk stopped at any such process. The ppid is the second
# field after the LAST ')'.
test_ppid_of_comm_with_space_and_paren() {
    [[ -r "/proc/$$/stat" ]] || { echo "  (no /proc — _ppid_of uses ps there)"; return 0; }
    source "$LOCK_SCRIPT"
    local d="$TEST_TMPDIR/odd-comm" bin
    mkdir -p "$d"; bin="$d/fake cc) x"
    cp "$(command -v sleep)" "$bin" && chmod +x "$bin"
    "$bin" 30 & local pid=$!
    local i comm=""
    for i in $(seq 1 20); do
        comm="$(cat "/proc/$pid/comm" 2>/dev/null)"; [[ "$comm" == "fake cc) x" ]] && break; sleep 0.05
    done
    local got; got="$(_ppid_of "$pid")"
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    assert_eq "fake cc) x" "$comm" "fixture: the process name carries a space and a ')'" || return 1
    assert_eq "$BASHPID" "$got" "_ppid_of reads the ppid past a comm with a space and ')' (measured '$got')"
}
run_test "_ppid_of: process name with a space and ')' still yields the ppid" test_ppid_of_comm_with_space_and_paren

# ── CFG-673 / GH#9: a scan that sees NO Claude Code process is blind ────────
# Inside Claude Code's Bash sandbox a command runs in its own PID namespace:
# /proc exists but lists only the sandbox's few processes, none of them a CC
# and none of them the host's lock holder, so every recorded pid reads dead.
# check_lock took that for "no live session" and rm'd the lock (rc 0). Owner
# decision (owner, 2026-09-25, "Fail closed: 'unknown'"): zero visible CC processes
# is a DISTINCT result, rc 4 "cannot determine", and the lock is never deleted
# on that evidence.
_cfg673_sandbox_world() {
    # The measured sandbox shape (GH#9): 5 pids, $$ = 2, no CC among them, the
    # host's pids absent.
    _enumerate_pids() { printf '%s\n' 1 2 3 4 5; }
    _pid_is_cc()      { return 1; }
    _ppid_of()        { case "$1" in 2|3|4|5) echo 1;; *) echo "";; esac; }
    _is_pid_alive()   { case "$1" in 1|2|3|4|5) return 0;; *) return 1;; esac; }
}

# Run check_lock as a production caller does (no self-pid argument, own CC
# resolved by the library) inside the sandbox world. Prints nothing; rc = check_lock's.
_cfg673_check_in_sandbox() {   # <proj>
    ( unset _CC_SELF_PID
      _cfg673_sandbox_world
      CC_SESSION_ID="" CLAUDE_SESSION_ID="" AFLEET_SESSION_ID="" CLAUDE_CODE_SESSION_ID="cc-follower"
      check_lock "$1" )
}

test_cfg673_sandbox_dead_pid_lock_is_unknown() {
    local proj="$TEST_TMPDIR/p673-sandbox"
    source "$LOCK_SCRIPT"
    _cfg536_lock "$proj" "sess-leader" "cc-leader" 424242   # the host leader: invisible here
    local rc=0; _cfg673_check_in_sandbox "$proj" || rc=$?
    assert_eq "4" "$rc" "zero visible CC processes ⇒ cannot determine, not 'free' (measured rc=$rc)" || return 1
    assert_file_exists "$proj/.claude/.session-lock" "the lock is not deleted on a blind scan" || return 1
    assert_file_contains "$proj/.claude/.session-lock" '"cc-leader"' "the lock still names the leader"
}
run_test "CFG-673: check_lock — sandbox (visible /proc, zero CC), dead-looking pid ⇒ rc 4, lock kept" test_cfg673_sandbox_dead_pid_lock_is_unknown

test_cfg673_sandbox_corrupt_lock_is_kept() {
    local proj="$TEST_TMPDIR/p673-corrupt"
    source "$LOCK_SCRIPT"
    make_project_dir "$proj"
    echo "not json {{{" > "$proj/.claude/.session-lock"
    local rc=0; _cfg673_check_in_sandbox "$proj" || rc=$?
    assert_eq "4" "$rc" "a corrupt lock seen through a blind scan ⇒ cannot determine (measured rc=$rc)" || return 1
    assert_file_exists "$proj/.claude/.session-lock" "the corrupt lock is not deleted on a blind scan"
}
run_test "CFG-673: check_lock — sandbox, corrupt lock ⇒ rc 4, lock kept" test_cfg673_sandbox_corrupt_lock_is_kept

test_cfg673_sandbox_no_lock_is_unknown() {
    # No lock file is not proof of a free project either (CFG-468: a live CC
    # in the project without a lock is LOCKED), and a blind scan cannot look.
    local proj="$TEST_TMPDIR/p673-nolock"
    source "$LOCK_SCRIPT"
    make_project_dir "$proj"
    local rc=0; _cfg673_check_in_sandbox "$proj" || rc=$?
    assert_eq "4" "$rc" "no lock file + blind scan ⇒ cannot determine (measured rc=$rc)"
}
run_test "CFG-673: check_lock — sandbox, no lock file ⇒ rc 4" test_cfg673_sandbox_no_lock_is_unknown

test_cfg673_real_proc_no_cc_matches_is_unknown() {
    # The same world on the REAL /proc: the matcher recognises no running
    # process (as in the sandbox, where the host's CCs are not in /proc).
    local proj="$TEST_TMPDIR/p673-realproc"
    source "$LOCK_SCRIPT"
    true & local dpid=$!; wait "$dpid" 2>/dev/null || true
    _cfg536_lock "$proj" "sess-leader" "cc-leader" "$dpid"
    local rc=0
    ( unset _CC_SELF_PID
      _CC_PROC_RE="(^|/)cfg673-no-such-cc-$$([[:space:]]|$)"
      CC_SESSION_ID="" CLAUDE_SESSION_ID="" AFLEET_SESSION_ID="" CLAUDE_CODE_SESSION_ID=""
      check_lock "$proj" ) || rc=$?
    assert_eq "4" "$rc" "real /proc, no process matches the CC matcher ⇒ rc 4 (measured rc=$rc)" || return 1
    assert_file_exists "$proj/.claude/.session-lock" "the lock is not deleted"
}
run_test "CFG-673: check_lock — real /proc with zero CC processes ⇒ rc 4, lock kept" test_cfg673_real_proc_no_cc_matches_is_unknown

test_cfg673_own_cc_visible_stale_lock_still_cleaned() {
    # Guard: the decision is about a BLIND scan, not about stale locks. A solo
    # session whose own CC is visible still cleans another session's stale lock.
    local proj="$TEST_TMPDIR/p673-solo"
    source "$LOCK_SCRIPT"
    _cfg536_lock "$proj" "sess-gone" "cc-gone" 424242
    local rc=0
    ( _cfg673_sandbox_world
      _pid_is_cc() { [[ "$1" == "300" ]]; }       # our own CC, visible
      _pid_cwd()   { echo "/elsewhere"; }
      _enumerate_pids() { printf '%s\n' 1 2 300; }
      _CC_SELF_PID=300
      CC_SESSION_ID="cc-mine" CLAUDE_SESSION_ID="" AFLEET_SESSION_ID="" CLAUDE_CODE_SESSION_ID=""
      check_lock "$proj" ) || rc=$?
    assert_eq "0" "$rc" "own CC visible, dead pid, nobody else live ⇒ genuinely stale, free (measured rc=$rc)" || return 1
    assert_file_not_exists "$proj/.claude/.session-lock" "the stale lock is still cleaned"
}
run_test "CFG-673: check_lock — own CC visible, stale lock ⇒ still rc 0, cleaned" test_cfg673_own_cc_visible_stale_lock_still_cleaned

test_cfg673_other_cc_visible_is_not_blind() {
    # Guard: "blind" means NO CC visible at all. An unresolvable own CC with
    # other CCs visible elsewhere keeps the existing unresolvable-self contract.
    local proj="$TEST_TMPDIR/p673-other"
    source "$LOCK_SCRIPT"
    _cfg536_lock "$proj" "sess-gone" "cc-gone" 424242
    local rc=0
    ( unset _CC_SELF_PID
      _cfg673_sandbox_world
      _pid_is_cc() { [[ "$1" == "700" ]]; }       # a CC in another project
      _pid_cwd()   { echo "/some/other/project"; }
      _enumerate_pids() { printf '%s\n' 1 2 700; }
      CC_SESSION_ID="" CLAUDE_SESSION_ID="" AFLEET_SESSION_ID="" CLAUDE_CODE_SESSION_ID=""
      check_lock "$proj" ) || rc=$?
    assert_eq "0" "$rc" "a CC is visible (the scan can see) and none is in the project ⇒ rc 0 as before (measured rc=$rc)"
}
run_test "CFG-673: check_lock — another CC visible elsewhere ⇒ not blind, unchanged" test_cfg673_other_cc_visible_is_not_blind

test_cfg673_sandbox_remote_lock_still_remote() {
    local proj="$TEST_TMPDIR/p673-remote"
    source "$LOCK_SCRIPT"
    make_project_dir "$proj"
    printf '{"machine":"other-host-673","pid":4242,"sessionId":"s","timestamp":"2026-09-25T00:00:00Z","user":"u","ccSessionId":"c"}\n' \
        > "$proj/.claude/.session-lock"
    local rc=0; _cfg673_check_in_sandbox "$proj" || rc=$?
    assert_eq "3" "$rc" "a lock from another machine is still rc 3 in a blind world (measured rc=$rc)"
}
run_test "CFG-673: check_lock — sandbox, remote lock ⇒ still rc 3" test_cfg673_sandbox_remote_lock_still_remote

# ── CFG-592: an unresolvable own CC with other CCs visible is loud, not silent ─
# The one shape check_lock still grants silently: the caller's own CC pid is
# unresolvable, so _project_has_live_cc fails OPEN on its empty exclude without
# looking (deliberate — a solo session must never self-block), while a CC IS
# visible, so CFG-673's rc 4 does not fire. Owner decision 2026-09-28, option 3:
# keep the grant, surface it. lock_self_unknown is the predicate the SessionStart
# hook uses to say so; the verdicts themselves do not move.

test_cfg592_self_unknown_rival_in_project_flagged_grant_unchanged() {
    local proj="$TEST_TMPDIR/p592-flag" real
    source "$LOCK_SCRIPT"
    _cfg536_lock "$proj" "sess-gone" "cc-gone" 424242
    real="$(realpath "$proj")"
    local out
    out="$( unset _CC_SELF_PID
      _cfg673_sandbox_world
      _pid_is_cc() { [[ "$1" == "700" ]]; }       # a CC cwd'd IN the project: a rival
      _pid_cwd()   { echo "$real"; }
      _enumerate_pids() { printf '%s\n' 1 2 700; }
      CC_SESSION_ID="" CLAUDE_SESSION_ID="" AFLEET_SESSION_ID="" CLAUDE_CODE_SESSION_ID=""
      rc=0; check_lock "$proj" || rc=$?
      flag=0; lock_self_unknown || flag=$?
      echo "rc=$rc flag=$flag" )"
    assert_eq "rc=0 flag=0" "$out" "own CC unresolvable + a CC visible (a rival in the project, unseen) ⇒ rc 0 as before, and lock_self_unknown says so (measured '$out')" || return 1
    assert_file_not_exists "$proj/.claude/.session-lock" "the grant is unchanged: the dead-pid lock is still cleaned"
}
run_test "CFG-592: check_lock — own CC unresolvable, rival CC visible in project ⇒ rc 0 kept, lock_self_unknown rc 0" test_cfg592_self_unknown_rival_in_project_flagged_grant_unchanged

test_cfg592_self_resolved_not_flagged_rival_detected() {
    local proj="$TEST_TMPDIR/p592-self" real
    source "$LOCK_SCRIPT"
    _cfg536_lock "$proj" "sess-gone" "cc-gone" 424242
    real="$(realpath "$proj")"
    local out
    out="$( _cfg673_sandbox_world
      _pid_is_cc() { [[ "$1" == "300" || "$1" == "700" ]]; }   # 300 = our own CC, 700 = the same rival
      _pid_cwd()   { if [[ "$1" == "700" ]]; then echo "$real"; else echo "/elsewhere"; fi; }
      _enumerate_pids() { printf '%s\n' 1 2 300 700; }
      _CC_SELF_PID=300
      CC_SESSION_ID="cc-mine" CLAUDE_SESSION_ID="" AFLEET_SESSION_ID="" CLAUDE_CODE_SESSION_ID=""
      rc=0; check_lock "$proj" || rc=$?
      flag=0; lock_self_unknown || flag=$?
      arg=0; lock_self_unknown 300 || arg=$?
      echo "rc=$rc flag=$flag arg=$arg" )"
    assert_eq "rc=2 flag=1 arg=1" "$out" "own CC resolved ⇒ the same rival IS detected (rc 2) and nothing is flagged, resolved by ancestry or passed explicitly (measured '$out')"
}
run_test "CFG-592: check_lock — own CC resolved ⇒ rival detected (rc 2), lock_self_unknown rc 1" test_cfg592_self_resolved_not_flagged_rival_detected

test_cfg592_blind_scan_not_flagged_rc4_kept() {
    local proj="$TEST_TMPDIR/p592-blind"
    source "$LOCK_SCRIPT"
    _cfg536_lock "$proj" "sess-leader" "cc-leader" 424242
    local out
    out="$( unset _CC_SELF_PID
      _cfg673_sandbox_world
      CC_SESSION_ID="" CLAUDE_SESSION_ID="" AFLEET_SESSION_ID="" CLAUDE_CODE_SESSION_ID=""
      rc=0; check_lock "$proj" || rc=$?
      flag=0; lock_self_unknown || flag=$?
      echo "rc=$rc flag=$flag" )"
    assert_eq "rc=4 flag=1" "$out" "no CC visible at all ⇒ rc 4 as before, and that is CFG-673's signal, not this one (measured '$out')" || return 1
    assert_file_exists "$proj/.claude/.session-lock" "the lock is still kept on a blind scan"
}
run_test "CFG-592: check_lock — blind scan ⇒ rc 4 unchanged, lock_self_unknown rc 1" test_cfg592_blind_scan_not_flagged_rc4_kept

test_cfg592_explicit_empty_self_no_lock_flagged() {
    # No lock file, and the self pid passed EXPLICITLY empty (respected as
    # "unresolvable", exactly as check_lock's ${2-...} does) although ancestry
    # would have resolved it.
    local proj="$TEST_TMPDIR/p592-nolock"
    source "$LOCK_SCRIPT"
    make_project_dir "$proj"
    local out
    out="$( _cfg673_sandbox_world
      _pid_is_cc() { [[ "$1" == "300" || "$1" == "700" ]]; }
      _pid_cwd()   { echo "/some/other/project"; }
      _enumerate_pids() { printf '%s\n' 1 2 300 700; }
      _CC_SELF_PID=300
      CC_SESSION_ID="" CLAUDE_SESSION_ID="" AFLEET_SESSION_ID="" CLAUDE_CODE_SESSION_ID=""
      rc=0; check_lock "$proj" "" || rc=$?
      flag=0; lock_self_unknown "" || flag=$?
      echo "rc=$rc flag=$flag" )"
    assert_eq "rc=0 flag=0" "$out" "no lock + explicitly empty self + a CC visible ⇒ rc 0 as before, flagged (measured '$out')"
}
run_test "CFG-592: check_lock — no lock, explicit empty self, CC visible ⇒ rc 0 kept, lock_self_unknown rc 0" test_cfg592_explicit_empty_self_no_lock_flagged

# ── Summary ─────────────────────────────────────────────────────────────────

suite_summary
