#!/usr/bin/env bash
# Tests for session lock detection in SessionStart hook (06-state-injection.sh)
# Tests Check 36 (project lock) and Check 35 fix (sibling lock JSON parsing)
source "$(dirname "$0")/test-helpers.sh"

CHECK_SCRIPT="$REPO_ROOT/global/hooks/checks/06b-lock-knowledge.sh"

suite_header "session-lock-hook (06b-lock-knowledge.sh)"

# Helper: create a JSON lock file
create_lock_file() {
    local path="$1" machine="$2" pid="$3" user="${4:-testuser}" session="${5:-test-session}" ts="${6:-2026-03-25T09:00:00Z}"
    mkdir -p "$(dirname "$path")"
    printf '{"machine":"%s","pid":%s,"sessionId":"%s","timestamp":"%s","user":"%s"}\n' \
        "$machine" "$pid" "$session" "$ts" "$user" > "$path"
}

# Helper: source the check file with mock environment and capture results
run_check() {
    local project_dir="$1"
    (
        export PROJECT_DIR="$project_dir"
        export CONFIG_REPO="$REPO_ROOT"
        export WARNINGS=""
        export INBOX_MSG=""
        # The hook's own CC is visible to the lock library, as in production. Without
        # this the verdict would depend on whether a real CC happens to be visible to
        # the test run (CFG-673: a scan that sees no CC answers 4, keeps the lock).
        export _CC_SELF_PID="$$"
        # Ensure .claude/ and session-context.md exist to avoid noise from other checks
        mkdir -p "$project_dir/.claude" "$project_dir/docs"
        # Source the check file — all checks run, we only care about lock messages
        source "$CHECK_SCRIPT" 2>/dev/null || true
        # Output both for the test to capture
        echo "WARNINGS=$WARNINGS"
        echo "INBOX_MSG=$INBOX_MSG"
    )
}

# ── No lock file — no lock messages ────────────────────────────────────────

test_no_lock() {
    mkdir -p "$TEST_TMPDIR/project/.claude"
    local out
    out=$(run_check "$TEST_TMPDIR/project")
    assert_not_contains "$out" "STALE_LOCK" "should not mention stale lock"
    assert_not_contains "$out" "SESSION_LOCKED" "should not mention session locked"
}
run_test "no lock file: no lock-related messages" test_no_lock

# ── Stale lock (same machine, dead PID) — auto-clear + warn ───────────────

test_stale_lock_same_machine() {
    local hostname
    hostname=$(cat /etc/hostname 2>/dev/null || hostname 2>/dev/null || echo "unknown")
    mkdir -p "$TEST_TMPDIR/project/.claude"
    # Use PID 99999 which is almost certainly dead
    create_lock_file "$TEST_TMPDIR/project/.claude/.session-lock" "$hostname" "99999"

    local out
    out=$(run_check "$TEST_TMPDIR/project")
    assert_contains "$out" "STALE_LOCK_CLEARED" "should report stale lock cleared"
    assert_file_not_exists "$TEST_TMPDIR/project/.claude/.session-lock" "lock file should be deleted"
}
run_test "stale lock (same machine, dead PID): auto-clear + warn" test_stale_lock_same_machine

# ── Remote lock (different machine) — warn with machine name ──────────────

test_remote_lock() {
    mkdir -p "$TEST_TMPDIR/project/.claude"
    create_lock_file "$TEST_TMPDIR/project/.claude/.session-lock" "testhost-remote" "12345" "remoteuser"

    local out
    out=$(run_check "$TEST_TMPDIR/project")
    assert_contains "$out" "SESSION_LOCKED_REMOTE" "should report remote lock"
    assert_contains "$out" "testhost-remote" "should include remote machine name"
    assert_contains "$out" "remoteuser" "should include remote user"
    # Lock file should NOT be deleted (can't verify PID on remote)
    assert_file_exists "$TEST_TMPDIR/project/.claude/.session-lock" "remote lock should not be deleted"
}
run_test "remote lock (different machine): warn with machine name" test_remote_lock

# ── Sibling lock — JSON parsing ───────────────────────────────────────────

test_sibling_lock_json() {
    # Create a project with .config-repo marker (CFG-329: marker-based sibling detection)
    mkdir -p "$TEST_TMPDIR/project/.claude"
    echo "# config repo marker" > "$TEST_TMPDIR/project/.config-repo"
    local sibling_dir="$HOME/agent-fleet"

    # Only test if sibling dir exists with .template-repo marker
    if [ ! -d "$sibling_dir" ] || [ ! -f "$sibling_dir/.template-repo" ]; then
        return 0  # Skip silently
    fi

    # Verify the check doesn't crash and produces sibling status
    local out
    out=$(run_check "$TEST_TMPDIR/project")
    assert_contains "$out" "SIBLING_SESSION" "should produce sibling session status"
}
run_test "sibling lock: JSON parsing doesn't crash" test_sibling_lock_json

# ── Stale lock with age display ────────────────────────────────────────────

test_stale_lock_age() {
    local hostname
    hostname=$(cat /etc/hostname 2>/dev/null || hostname 2>/dev/null || echo "unknown")
    mkdir -p "$TEST_TMPDIR/project/.claude"
    # Create lock with old timestamp (2 hours ago)
    local old_ts
    old_ts=$(date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
    create_lock_file "$TEST_TMPDIR/project/.claude/.session-lock" "$hostname" "99999" "testuser" "old-session" "$old_ts"

    local out
    out=$(run_check "$TEST_TMPDIR/project")
    assert_contains "$out" "STALE_LOCK_CLEARED" "should report stale lock cleared" || return 1
    # Age should be present (format: Xh Ym or Xm)
    assert_contains "$out" "age:" "should include age in message"
}
run_test "stale lock: includes age in warning" test_stale_lock_age

# ── Own session lock — should NOT report SESSION_LOCKED ──────────────────────

test_own_session_lock() {
    local hostname
    hostname=$(cat /etc/hostname 2>/dev/null || hostname 2>/dev/null || echo "unknown")
    mkdir -p "$TEST_TMPDIR/project/.claude"
    # Use current shell PID (alive) with a known session ID
    create_lock_file "$TEST_TMPDIR/project/.claude/.session-lock" "$hostname" "$$" "testuser" "my-session-abc"

    local out
    out=$(
        export PROJECT_DIR="$TEST_TMPDIR/project"
        export CONFIG_REPO="$REPO_ROOT"
        export WARNINGS=""
        export INBOX_MSG=""
        export AFLEET_SESSION_ID="my-session-abc"
        mkdir -p "$PROJECT_DIR/.claude"
        source "$CHECK_SCRIPT" 2>/dev/null || true
        echo "WARNINGS=$WARNINGS"
        echo "INBOX_MSG=$INBOX_MSG"
    )
    assert_not_contains "$out" "SESSION_LOCKED" "own session lock should not trigger SESSION_LOCKED"
}
run_test "own session lock (matching AFLEET_SESSION_ID): no warning" test_own_session_lock

# ── Other session lock (different session ID, live PID) ──────────────────────

test_other_session_lock() {
    local hostname
    hostname=$(cat /etc/hostname 2>/dev/null || hostname 2>/dev/null || echo "unknown")
    mkdir -p "$TEST_TMPDIR/project/.claude"
    # Use current shell PID (alive) but different session ID
    create_lock_file "$TEST_TMPDIR/project/.claude/.session-lock" "$hostname" "$$" "testuser" "other-session-xyz"

    local out
    out=$(
        export PROJECT_DIR="$TEST_TMPDIR/project"
        export CONFIG_REPO="$REPO_ROOT"
        export WARNINGS=""
        export INBOX_MSG=""
        export AFLEET_SESSION_ID="my-session-abc"
        mkdir -p "$PROJECT_DIR/.claude"
        source "$CHECK_SCRIPT" 2>/dev/null || true
        echo "WARNINGS=$WARNINGS"
        echo "INBOX_MSG=$INBOX_MSG"
    )
    assert_contains "$out" "SESSION_LOCKED" "different session should report SESSION_LOCKED"
}
run_test "other session lock (different AFLEET_SESSION_ID): reports locked" test_other_session_lock

# ── GH#10: a dead recorded pid is not proof the session is gone ─────────────
# The lock's recorded pid is frequently the EPHEMERAL SessionStart hook process
# (CFG-468), so 06b's bare `kill -0` + `rm -f` deleted the lock of a session
# that was still live under another pid. Every lock removal must go through the
# library's liveness-proven path (check_lock refuses while a live CC is cwd'd in
# the project). A fake "CC" is a setsid-detached `sleep` cwd'd in the project,
# made visible to the library by _CC_PROC_RE; _CC_SELF_PID is this shell so the
# scan runs (an empty exclude fails open, as it must for a solo session).

_spawn_foreign_cc() {   # <dir> — echoes the pid of a detached sleep cwd'd in <dir>
    local dir="$1" real i p
    real="$(realpath "$dir" 2>/dev/null || echo "$dir")"
    setsid sh -c "cd '$dir' && exec sleep 20" </dev/null >/dev/null 2>&1 &
    for i in $(seq 1 30); do
        for p in $(pgrep -x sleep 2>/dev/null); do
            if [[ "$(readlink "/proc/$p/cwd" 2>/dev/null)" == "$real" ]]; then
                echo "$p"; return 0
            fi
        done
        sleep 0.1
    done
    return 1
}

run_check_with_liveness() {   # <project_dir> — 06b with the library's CC matcher pointed at the fake
    local project_dir="$1"
    (
        export PROJECT_DIR="$project_dir"
        export CONFIG_REPO="$REPO_ROOT"
        export WARNINGS=""
        export INBOX_MSG=""
        export _CC_PROC_RE='sleep' _CC_SELF_PID="$$"
        unset AFLEET_SESSION_ID
        mkdir -p "$project_dir/.claude" "$project_dir/docs"
        source "$CHECK_SCRIPT" 2>/dev/null || true
        echo "WARNINGS=$WARNINGS"
        echo "INBOX_MSG=$INBOX_MSG"
    )
}

test_dead_pid_live_cc_lock_preserved() {
    local hostname proj="$TEST_TMPDIR/project"
    hostname=$(cat /etc/hostname 2>/dev/null || hostname 2>/dev/null || echo "unknown")
    mkdir -p "$proj/.claude"
    create_lock_file "$proj/.claude/.session-lock" "$hostname" "99999" "testuser" "inc-session"
    local fake; fake="$(_spawn_foreign_cc "$proj")" || { echo "could not spawn fake CC" >&2; return 1; }
    local out
    out=$(run_check_with_liveness "$proj")
    kill "$fake" 2>/dev/null || true
    assert_file_exists "$proj/.claude/.session-lock" "dead recorded pid + live CC in the project: lock NOT deleted" || return 1
    assert_not_contains "$out" "STALE_LOCK_CLEARED" "no stale-clear is reported for a live session" || return 1
    assert_contains "$out" "SESSION_LOCKED" "the live session is reported as holding the project"
}
run_test "GH#10: dead recorded pid + live CC in project: lock preserved, SESSION_LOCKED" test_dead_pid_live_cc_lock_preserved

test_dead_pid_no_live_cc_still_cleared() {
    # The same path with NO live CC must still clear the genuinely stale lock —
    # the fix routes the removal through the library, it does not stop clearing.
    local hostname proj="$TEST_TMPDIR/project"
    hostname=$(cat /etc/hostname 2>/dev/null || hostname 2>/dev/null || echo "unknown")
    mkdir -p "$proj/.claude"
    create_lock_file "$proj/.claude/.session-lock" "$hostname" "99999" "testuser" "old-session"
    local out
    out=$(run_check_with_liveness "$proj")
    assert_file_not_exists "$proj/.claude/.session-lock" "genuinely stale lock (dead pid, no live CC) is still cleared" || return 1
    assert_contains "$out" "STALE_LOCK_CLEARED" "stale clear is still reported"
}
run_test "GH#10: dead recorded pid + no live CC: still cleared via the library" test_dead_pid_no_live_cc_still_cleared

test_dead_pid_own_cc_lock_is_ours() {
    # CFG-454: the session's OWN lock (bound to its cc id, which config-check.sh
    # exports as CC_SESSION_ID) whose recorded pid has died — a direct launch's
    # pid is the dead SessionStart hook, so this is every /compact, /clear or
    # resume — while another CC is live in the project. It is neither another
    # session's lock nor stale: keep it and say nothing.
    local hostname proj="$TEST_TMPDIR/project"
    hostname=$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo "unknown")
    mkdir -p "$proj/.claude"
    printf '{"machine":"%s","pid":99999,"sessionId":"own-session","timestamp":"2026-03-25T09:00:00Z","user":"testuser","ccSessionId":"cc-mine"}\n' \
        "$hostname" > "$proj/.claude/.session-lock"
    local fake; fake="$(_spawn_foreign_cc "$proj")" || { echo "could not spawn fake CC" >&2; return 1; }
    local out
    out=$(CC_SESSION_ID=cc-mine CLAUDE_CODE_SESSION_ID=cc-mine run_check_with_liveness "$proj")
    kill "$fake" 2>/dev/null || true
    assert_file_exists "$proj/.claude/.session-lock" "the session's own lock is not deleted" || return 1
    assert_not_contains "$out" "STALE_LOCK_CLEARED" "its own lock is not reported as stale" || return 1
    assert_not_contains "$out" "SESSION_LOCKED" "its own lock is not reported as another session's"
}
run_test "CFG-454: dead recorded pid, lock bound to our cc id, other CC live: ours, silent" test_dead_pid_own_cc_lock_is_ours

test_dead_pid_blind_scan_is_unknown() {
    # CFG-673 / GH#9: the lock check sees /proc but no CC process at all, not
    # even this session's own (a CC matcher that recognises nothing here; in
    # Claude Code's Bash sandbox, a PID namespace). "Dead pid + nobody live" is
    # then the scan describing its own blindness: check_lock keeps the lock
    # (rc 4) and 06b must say the state is unknown, not "cleared" and not
    # "another session seen".
    local hostname proj="$TEST_TMPDIR/project"
    hostname=$(cat /etc/hostname 2>/dev/null || hostname 2>/dev/null || echo "unknown")
    mkdir -p "$proj/.claude" "$proj/docs"
    true & local dpid=$!; wait "$dpid" 2>/dev/null || true
    create_lock_file "$proj/.claude/.session-lock" "$hostname" "$dpid" "testuser" "inc-session"
    local out
    out=$(
        export PROJECT_DIR="$proj" CONFIG_REPO="$REPO_ROOT" WARNINGS="" INBOX_MSG=""
        export _CC_PROC_RE="(^|/)cfg673-no-such-cc-$$([[:space:]]|$)"
        unset _CC_SELF_PID AFLEET_SESSION_ID CC_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID
        source "$CHECK_SCRIPT" 2>/dev/null || true
        echo "WARNINGS=$WARNINGS"
        echo "INBOX_MSG=$INBOX_MSG"
    )
    assert_file_exists "$proj/.claude/.session-lock" "a blind scan does not delete the lock" || return 1
    assert_not_contains "$out" "STALE_LOCK_CLEARED" "nothing is reported as cleared" || return 1
    assert_contains "$out" "SESSION_LOCK_UNKNOWN" "the lock state is reported as unknown" || return 1
    assert_not_contains "$out" "a live session holds the project" "a blind scan does not claim it saw a live session"
}
run_test "CFG-673: dead recorded pid + zero visible CC processes: lock kept, SESSION_LOCK_UNKNOWN" test_dead_pid_blind_scan_is_unknown

test_no_bare_rm_in_06b() {
    # Source-level guard: the only way to remove a lock in 06b is the library.
    local n
    n=$(grep -c 'rm -f "\$_project_lock"' "$CHECK_SCRIPT" 2>/dev/null || true)
    assert_eq "0" "$n" "06b has no bare rm of the project lock (measured $n)"
}
run_test "GH#10: 06b has no bare rm of the lock" test_no_bare_rm_in_06b

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
