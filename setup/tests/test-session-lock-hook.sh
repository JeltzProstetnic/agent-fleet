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
    create_lock_file "$TEST_TMPDIR/project/.claude/.session-lock" "steamdeck-remote" "12345" "deck"

    local out
    out=$(run_check "$TEST_TMPDIR/project")
    assert_contains "$out" "SESSION_LOCKED_REMOTE" "should report remote lock"
    assert_contains "$out" "steamdeck-remote" "should include remote machine name"
    assert_contains "$out" "deck" "should include remote user"
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
    assert_contains "$out" "STALE_LOCK_CLEARED" "should report stale lock cleared"
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

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
