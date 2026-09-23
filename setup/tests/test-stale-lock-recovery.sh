#!/usr/bin/env bash
# Tests for CFG-218: Stale cross-machine lock recovery
# Covers: staleness detection, lock age computation, force_release,
#         server mode (AFD stale field), serverless mode (timestamp-based info).
source "$(dirname "$0")/test-helpers.sh"

suite_header "CFG-218: Stale Cross-Machine Lock Recovery"

LOCK_SCRIPT="$REPO_ROOT/setup/scripts/session-lock.sh"
AFD_LIB="$REPO_ROOT/afd/lib/afd-lib.sh"

_REAL_AFD_TOKEN="${AFD_TOKEN:-}"
_REAL_AFD_URL="${AFD_URL:-}"
_REAL_PATH="$PATH"

restore_env() {
    export AFD_TOKEN="$_REAL_AFD_TOKEN"
    export AFD_URL="$_REAL_AFD_URL"
    export PATH="$_REAL_PATH"
    unset AFLEET_SESSION_ID 2>/dev/null || true
}

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

# Helper: Simulate Check 31 with staleness-aware logic
# Returns WARNINGS string via stdout
run_check_31() {
    local project_dir="$1"
    local config_repo="$REPO_ROOT"

    local CONFIG_REPO="$config_repo"
    local PWD="$project_dir"
    local WARNINGS=""
    local AFLEET_SESSION_ID="${AFLEET_SESSION_ID:-}"

    source "$LOCK_SCRIPT"

    if [ -f "$AFD_LIB" ]; then
        source "$AFD_LIB"
    fi

    # ── AFD lock check (CFG-210) ──
    local _afd_lock_checked=false
    if [ -n "${AFD_TOKEN:-}" ] && [ -f "$AFD_LIB" ]; then
        local _project_name
        _project_name=$(basename "$project_dir")
        local _afd_result
        _afd_result=$(afd_lock_status "$_project_name" 2>/dev/null) || true

        if [ -n "$_afd_result" ]; then
            local _afd_machine _afd_session _afd_stale _afd_heartbeat
            _afd_machine=$(echo "$_afd_result" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('machine',''))" 2>/dev/null) || true
            _afd_session=$(echo "$_afd_result" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('sessionId',d.get('session_id','')))" 2>/dev/null) || true
            _afd_stale=$(echo "$_afd_result" | python3 -c "import json,sys; d=json.load(sys.stdin); print(str(d.get('stale',False)).lower())" 2>/dev/null) || true
            _afd_heartbeat=$(echo "$_afd_result" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('last_heartbeat',''))" 2>/dev/null) || true

            if [ -n "$_afd_machine" ]; then
                local _our_machine
                _our_machine=$(hostname)
                local _our_session="${AFLEET_SESSION_ID:-}"

                if [ "$_afd_machine" = "$_our_machine" ] && [ "$_afd_session" = "$_our_session" ]; then
                    _afd_lock_checked=true  # Our lock, fine
                elif [ -n "$_afd_machine" ]; then
                    if [ "$_afd_stale" = "true" ]; then
                        WARNINGS="${WARNINGS:+$WARNINGS | }SESSION_LOCKED_REMOTE: AFD reports project locked by $_afd_machine (session $_afd_session) — STALE (no heartbeat since $_afd_heartbeat). Use force_release to override."
                    else
                        WARNINGS="${WARNINGS:+$WARNINGS | }SESSION_LOCKED_REMOTE: AFD reports project locked by $_afd_machine (session $_afd_session) — ACTIVE (heartbeat $_afd_heartbeat). FOLLOWER — load knowledge/follower-mode.md and follow it."
                    fi
                    _afd_lock_checked=true
                fi
            fi
        fi
    fi

    # ── Local lock check (existing, fallback when AFD unavailable) ──
    if [ "$_afd_lock_checked" = false ]; then
        check_lock "$project_dir" 2>/dev/null
        local _lock_rc=$?

        if [[ $_lock_rc -eq 2 ]] && [[ -n "${AFLEET_SESSION_ID:-}" ]]; then
            _read_lock "$project_dir/.claude/.session-lock" 2>/dev/null
            if [[ "$_LOCK_SESSION" == "$AFLEET_SESSION_ID" ]]; then
                _lock_rc=1
            fi
        fi

        case $_lock_rc in
            2)
                _read_lock "$project_dir/.claude/.session-lock" 2>/dev/null
                WARNINGS="${WARNINGS:+$WARNINGS | }SESSION_LOCKED: Project locked by PID $_LOCK_PID (session $_LOCK_SESSION) on this machine."
                ;;
            3)
                _read_lock "$project_dir/.claude/.session-lock" 2>/dev/null
                local _lock_age
                _lock_age=$(lock_age "$project_dir" 2>/dev/null) || _lock_age="unknown"
                WARNINGS="${WARNINGS:+$WARNINGS | }SESSION_LOCKED_REMOTE: Project locked by $_LOCK_MACHINE (session $_LOCK_SESSION, user $_LOCK_USER, since $_LOCK_TIMESTAMP, age ${_lock_age}). Use force_release to override, or investigate on $_LOCK_MACHINE."
                ;;
            0)
                acquire_lock "$project_dir" "${AFLEET_SESSION_ID:-}" 2>/dev/null
                ;;
            1)
                ;;
        esac
    fi

    echo "$WARNINGS"
}

# ══════════════════════════════════════════════════════════════════════════════
# lock_age tests — computes human-readable age from lock timestamp
# ══════════════════════════════════════════════════════════════════════════════

test_lock_age_returns_age_string() {
    local proj="$TEST_TMPDIR/project"
    make_project_dir "$proj"

    # Write lock with timestamp 2 hours ago
    local ts_2h_ago
    ts_2h_ago=$(date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%SZ)
    cat > "$proj/.claude/.session-lock" << LOCKEOF
{"machine":"other-host","pid":1,"sessionId":"remote-session","timestamp":"$ts_2h_ago","user":"someone"}
LOCKEOF

    source "$LOCK_SCRIPT"
    local age
    age=$(lock_age "$proj")
    local rc=$?

    assert_eq "0" "$rc" "lock_age should succeed"
    # Should contain "h" or "hour" in the output
    assert_contains "$age" "h" "age should contain hours indicator"
}
run_test "lock_age returns human-readable age string" test_lock_age_returns_age_string

test_lock_age_recent_lock_shows_minutes() {
    local proj="$TEST_TMPDIR/project"
    make_project_dir "$proj"

    # Write lock with timestamp 5 minutes ago
    local ts_5m_ago
    ts_5m_ago=$(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
    cat > "$proj/.claude/.session-lock" << LOCKEOF
{"machine":"other-host","pid":1,"sessionId":"remote-session","timestamp":"$ts_5m_ago","user":"someone"}
LOCKEOF

    source "$LOCK_SCRIPT"
    local age
    age=$(lock_age "$proj")

    assert_contains "$age" "m" "recent lock age should contain minutes indicator"
}
run_test "lock_age shows minutes for recent lock" test_lock_age_recent_lock_shows_minutes

test_lock_age_no_lock_returns_error() {
    local proj="$TEST_TMPDIR/project"
    make_project_dir "$proj"

    source "$LOCK_SCRIPT"
    local rc=0
    lock_age "$proj" 2>/dev/null || rc=$?

    assert_eq "1" "$rc" "lock_age should return 1 when no lock exists"
}
run_test "lock_age returns error when no lock" test_lock_age_no_lock_returns_error

# ══════════════════════════════════════════════════════════════════════════════
# lock_info — enhanced with age display
# ══════════════════════════════════════════════════════════════════════════════

test_lock_info_includes_age_for_remote_lock() {
    local proj="$TEST_TMPDIR/project"
    make_project_dir "$proj"

    local ts_1h_ago
    ts_1h_ago=$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)
    cat > "$proj/.claude/.session-lock" << LOCKEOF
{"machine":"other-host","pid":1,"sessionId":"remote-session","timestamp":"$ts_1h_ago","user":"someone"}
LOCKEOF

    source "$LOCK_SCRIPT"
    local output
    output=$(lock_info "$proj")

    assert_contains "$output" "Age:" "lock_info should include Age field"
    assert_contains "$output" "REMOTE" "lock_info should show REMOTE status"
}
run_test "lock_info includes age for remote lock" test_lock_info_includes_age_for_remote_lock

# ══════════════════════════════════════════════════════════════════════════════
# Serverless mode: remote lock presents info (machine, timestamp, age, user)
# ══════════════════════════════════════════════════════════════════════════════

test_serverless_remote_lock_shows_full_info() {
    local proj="$TEST_TMPDIR/project"
    make_project_dir "$proj"

    local ts_3h_ago
    ts_3h_ago=$(date -u -d '3 hours ago' +%Y-%m-%dT%H:%M:%SZ)
    cat > "$proj/.claude/.session-lock" << LOCKEOF
{"machine":"other-host-xyz","pid":12345,"sessionId":"remote-session","timestamp":"$ts_3h_ago","user":"testuser"}
LOCKEOF

    # No AFD_TOKEN — serverless mode
    unset AFD_TOKEN
    export AFD_URL=""

    local out
    out=$(run_check_31 "$proj")
    restore_env

    assert_contains "$out" "SESSION_LOCKED_REMOTE" "should report remote lock"
    assert_contains "$out" "other-host-xyz" "should include machine name"
    assert_contains "$out" "remote-session" "should include session ID"
    assert_contains "$out" "testuser" "should include user"
    assert_contains "$out" "$ts_3h_ago" "should include timestamp"
    assert_contains "$out" "force_release" "should suggest force_release"
}
run_test "serverless mode: remote lock shows full info (machine, session, user, timestamp, age)" test_serverless_remote_lock_shows_full_info

test_serverless_active_local_lock_not_auto_cleaned() {
    local proj="$TEST_TMPDIR/project"
    make_project_dir "$proj"

    # Create lock from another machine — even old, should NOT be auto-cleaned
    local ts_old
    ts_old=$(date -u -d '6 hours ago' +%Y-%m-%dT%H:%M:%SZ)
    cat > "$proj/.claude/.session-lock" << LOCKEOF
{"machine":"other-host-xyz","pid":12345,"sessionId":"remote-session","timestamp":"$ts_old","user":"testuser"}
LOCKEOF

    unset AFD_TOKEN
    export AFD_URL=""

    local out
    out=$(run_check_31 "$proj")
    restore_env

    # Lock should still exist (not auto-cleaned)
    assert_file_exists "$proj/.claude/.session-lock" "remote lock should NOT be auto-cleaned regardless of age"
    assert_contains "$out" "SESSION_LOCKED_REMOTE" "should still report remote lock"
}
run_test "serverless: old remote lock is NOT auto-cleaned (no timestamp-based auto-cleanup)" test_serverless_active_local_lock_not_auto_cleaned

# ══════════════════════════════════════════════════════════════════════════════
# Server mode: AFD stale field detection
# ══════════════════════════════════════════════════════════════════════════════

test_server_stale_lock_detected() {
    local proj="$TEST_TMPDIR/myproject"
    mkdir -p "$proj/.claude"

    # Mock curl: return lock with stale=true
    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/curl" << 'MOCK'
#!/usr/bin/env bash
echo '{"project":"myproject","machine":"crashed-host","sessionId":"dead-session","pid":9999,"stale":true,"last_heartbeat":"2026-03-18T10:00:00"}'
exit 0
MOCK
    chmod +x "$TEST_TMPDIR/bin/curl"
    export PATH="$TEST_TMPDIR/bin:$_REAL_PATH"
    export AFD_TOKEN="test-token"
    export AFD_URL="http://localhost:9999"

    local out
    out=$(run_check_31 "$proj")
    restore_env

    assert_contains "$out" "SESSION_LOCKED_REMOTE" "should report remote lock"
    assert_contains "$out" "STALE" "should indicate lock is STALE"
    assert_contains "$out" "crashed-host" "should include machine name"
    assert_contains "$out" "force_release" "should suggest force_release for stale lock"
}
run_test "server mode: stale lock detected from AFD stale field" test_server_stale_lock_detected

test_server_active_lock_shows_active() {
    local proj="$TEST_TMPDIR/myproject"
    mkdir -p "$proj/.claude"

    # Mock curl: return lock with stale=false (active)
    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/curl" << 'MOCK'
#!/usr/bin/env bash
echo '{"project":"myproject","machine":"active-host","sessionId":"live-session","pid":9999,"stale":false,"last_heartbeat":"2026-03-18T15:30:00"}'
exit 0
MOCK
    chmod +x "$TEST_TMPDIR/bin/curl"
    export PATH="$TEST_TMPDIR/bin:$_REAL_PATH"
    export AFD_TOKEN="test-token"
    export AFD_URL="http://localhost:9999"

    local out
    out=$(run_check_31 "$proj")
    restore_env

    assert_contains "$out" "SESSION_LOCKED_REMOTE" "should report remote lock"
    assert_contains "$out" "ACTIVE" "should indicate lock is ACTIVE"
    assert_contains "$out" "active-host" "should include machine name"
    assert_not_contains "$out" "STALE" "should NOT say stale for active lock"
}
run_test "server mode: active lock (with heartbeat) shows ACTIVE, not STALE" test_server_active_lock_shows_active

test_server_stale_lock_not_auto_cleaned() {
    local proj="$TEST_TMPDIR/myproject"
    mkdir -p "$proj/.claude"

    # Write a local lock file too (simulating the stale remote lock)
    cat > "$proj/.claude/.session-lock" << LOCKEOF
{"machine":"crashed-host","pid":9999,"sessionId":"dead-session","timestamp":"2026-03-18T10:00:00Z","user":"someone"}
LOCKEOF

    # Mock curl: return stale lock from AFD
    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/curl" << 'MOCK'
#!/usr/bin/env bash
echo '{"project":"myproject","machine":"crashed-host","sessionId":"dead-session","pid":9999,"stale":true,"last_heartbeat":"2026-03-18T10:00:00"}'
exit 0
MOCK
    chmod +x "$TEST_TMPDIR/bin/curl"
    export PATH="$TEST_TMPDIR/bin:$_REAL_PATH"
    export AFD_TOKEN="test-token"
    export AFD_URL="http://localhost:9999"

    local out
    out=$(run_check_31 "$proj")
    restore_env

    # Lock should still exist — user decides to override
    assert_file_exists "$proj/.claude/.session-lock" "stale lock should NOT be auto-cleaned — user decides"
    assert_contains "$out" "STALE" "should report stale"
}
run_test "server mode: stale lock is NOT auto-cleaned (user decides)" test_server_stale_lock_not_auto_cleaned

# ══════════════════════════════════════════════════════════════════════════════
# force_release clears remote lock (both local and server)
# ══════════════════════════════════════════════════════════════════════════════

test_force_release_clears_remote_lock() {
    local proj="$TEST_TMPDIR/project"
    make_project_dir "$proj"

    # Write a lock from another machine
    cat > "$proj/.claude/.session-lock" << LOCKEOF
{"machine":"crashed-host","pid":99999,"sessionId":"dead-session","timestamp":"2026-01-01T00:00:00Z","user":"someone"}
LOCKEOF

    source "$LOCK_SCRIPT"
    local rc=0
    force_release "$proj" || rc=$?

    assert_eq "0" "$rc" "force_release should succeed for remote lock"
    assert_file_not_exists "$proj/.claude/.session-lock" "lock file should be removed"
}
run_test "force_release clears remote lock" test_force_release_clears_remote_lock

test_force_release_clears_6h_old_remote_lock() {
    local proj="$TEST_TMPDIR/project"
    make_project_dir "$proj"

    local ts_6h_ago
    ts_6h_ago=$(date -u -d '6 hours ago' +%Y-%m-%dT%H:%M:%SZ)
    cat > "$proj/.claude/.session-lock" << LOCKEOF
{"machine":"other-machine","pid":11111,"sessionId":"old-session","timestamp":"$ts_6h_ago","user":"otheruser"}
LOCKEOF

    source "$LOCK_SCRIPT"
    local rc=0
    force_release "$proj" || rc=$?

    assert_eq "0" "$rc" "force_release should succeed for old remote lock"
    assert_file_not_exists "$proj/.claude/.session-lock" "old lock file should be removed"
}
run_test "force_release clears 6-hour-old remote lock" test_force_release_clears_6h_old_remote_lock

# ══════════════════════════════════════════════════════════════════════════════
# lock_age edge cases
# ══════════════════════════════════════════════════════════════════════════════

test_lock_age_old_lock_shows_days() {
    local proj="$TEST_TMPDIR/project"
    make_project_dir "$proj"

    local ts_2d_ago
    ts_2d_ago=$(date -u -d '2 days ago' +%Y-%m-%dT%H:%M:%SZ)
    cat > "$proj/.claude/.session-lock" << LOCKEOF
{"machine":"other-host","pid":1,"sessionId":"old-session","timestamp":"$ts_2d_ago","user":"someone"}
LOCKEOF

    source "$LOCK_SCRIPT"
    local age
    age=$(lock_age "$proj")

    assert_contains "$age" "d" "old lock age should contain days indicator"
}
run_test "lock_age shows days for old lock" test_lock_age_old_lock_shows_days

test_lock_age_corrupt_file() {
    local proj="$TEST_TMPDIR/project"
    make_project_dir "$proj"

    echo "not json" > "$proj/.claude/.session-lock"

    source "$LOCK_SCRIPT"
    local rc=0
    lock_age "$proj" 2>/dev/null || rc=$?

    assert_eq "1" "$rc" "lock_age should fail for corrupt lock file"
}
run_test "lock_age returns error for corrupt lock file" test_lock_age_corrupt_file

# ══════════════════════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════════════════════

suite_summary
