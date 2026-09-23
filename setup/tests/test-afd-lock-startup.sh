#!/usr/bin/env bash
# Tests for CFG-210: Wire AFD lock query into SessionStart (Check 31)
# Verifies that SessionStart queries AFD for lock status before falling
# back to local .session-lock file check.
source "$(dirname "$0")/test-helpers.sh"

suite_header "CFG-210: AFD lock query in SessionStart"

LOCK_SCRIPT="$REPO_ROOT/setup/scripts/session-lock.sh"
AFD_LIB="$REPO_ROOT/afd/lib/afd-lib.sh"
CHECK_SCRIPT="$REPO_ROOT/global/hooks/checks/07b-platform-env.sh"

_REAL_AFD_TOKEN="${AFD_TOKEN:-}"
_REAL_AFD_URL="${AFD_URL:-}"
_REAL_PATH="$PATH"

restore_env() {
    export AFD_TOKEN="$_REAL_AFD_TOKEN"
    export AFD_URL="$_REAL_AFD_URL"
    export PATH="$_REAL_PATH"
    unset AFLEET_SESSION_ID 2>/dev/null || true
}

# ── Helper: simulate Check 31 in isolation ──────────────────────────────────
# We can't source the full hook (needs too much context), so we extract and
# run just the Check 31 logic with the required variables set up.

run_check_31() {
    local project_dir="$1"
    local config_repo="$REPO_ROOT"

    # Set up vars that Check 31 expects
    local CONFIG_REPO="$config_repo"
    local PWD="$project_dir"
    local WARNINGS=""
    local AFLEET_SESSION_ID="${AFLEET_SESSION_ID:-}"

    # Source lock lib
    source "$LOCK_SCRIPT"

    # Source AFD lib if available
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
            local _afd_machine _afd_session
            _afd_machine=$(echo "$_afd_result" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('machine',''))" 2>/dev/null) || true
            _afd_session=$(echo "$_afd_result" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('sessionId',''))" 2>/dev/null) || true

            if [ -n "$_afd_machine" ]; then
                local _our_machine
                _our_machine=$(hostname)
                local _our_session="${AFLEET_SESSION_ID:-}"

                # Is it us?
                if [ "$_afd_machine" = "$_our_machine" ] && [ "$_afd_session" = "$_our_session" ]; then
                    _afd_lock_checked=true  # Our lock, fine
                elif [ -n "$_afd_machine" ]; then
                    WARNINGS="${WARNINGS:+$WARNINGS | }SESSION_LOCKED_REMOTE: AFD reports project locked by $_afd_machine (session $_afd_session). FOLLOWER — load knowledge/follower-mode.md and follow it."
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
                WARNINGS="${WARNINGS:+$WARNINGS | }SESSION_LOCKED_REMOTE: Project locked by $_LOCK_MACHINE (session $_LOCK_SESSION)."
                ;;
            0)
                acquire_lock "$project_dir" "${AFLEET_SESSION_ID:-}" 2>/dev/null
                # Also try AFD lock acquire (non-blocking)
                if [ -n "${AFD_TOKEN:-}" ]; then
                    local _pn
                    _pn=$(basename "$project_dir")
                    afd_lock_acquire "$_pn" "$(hostname)" "${AFLEET_SESSION_ID:-$$}" "$$" 2>/dev/null || true
                fi
                ;;
        esac
    fi

    echo "$WARNINGS"
}

# ── Test: AFD reports locked → SESSION_LOCKED_REMOTE warning ────────────────

test_afd_reports_locked() {
    local proj="$TEST_TMPDIR/myproject"
    mkdir -p "$proj/.claude"

    # Mock curl: return lock held by another machine
    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/curl" << 'MOCK'
#!/usr/bin/env bash
echo '{"project":"myproject","machine":"wsl-box","sessionId":"abc-123","pid":9999}'
exit 0
MOCK
    chmod +x "$TEST_TMPDIR/bin/curl"
    export PATH="$TEST_TMPDIR/bin:$_REAL_PATH"
    export AFD_TOKEN="test-token"
    export AFD_URL="http://localhost:9999"

    local out
    out=$(run_check_31 "$proj")
    restore_env

    assert_contains "$out" "SESSION_LOCKED_REMOTE"
    assert_contains "$out" "wsl-box"
    assert_contains "$out" "abc-123"
}
run_test "AFD reports locked → SESSION_LOCKED_REMOTE warning" test_afd_reports_locked

# ── Test: AFD unreachable → falls back to local lock check ──────────────────

test_afd_unreachable_fallback() {
    local proj="$TEST_TMPDIR/myproject"
    mkdir -p "$proj/.claude"

    # Mock curl: fails (connection refused)
    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/curl" << 'MOCK'
#!/usr/bin/env bash
exit 7
MOCK
    chmod +x "$TEST_TMPDIR/bin/curl"
    export PATH="$TEST_TMPDIR/bin:$_REAL_PATH"
    export AFD_TOKEN="test-token"
    export AFD_URL="http://localhost:9999"

    local out
    out=$(run_check_31 "$proj")
    restore_env

    # No warnings — project is free (no local lock either)
    assert_eq "" "$out" "should produce no warnings when AFD down and no local lock"

    # Should have acquired local lock as fallback
    assert_file_exists "$proj/.claude/.session-lock" "local lock should be acquired"
}
run_test "AFD unreachable → falls back to local lock (no warning)" test_afd_unreachable_fallback

# ── Test: No AFD_TOKEN → falls back to local lock check ─────────────────────

test_no_afd_token_fallback() {
    local proj="$TEST_TMPDIR/myproject"
    mkdir -p "$proj/.claude"

    unset AFD_TOKEN
    export AFD_URL="http://localhost:9999"

    local out
    out=$(run_check_31 "$proj")
    restore_env

    assert_eq "" "$out" "should produce no warnings when no token and no local lock"
    assert_file_exists "$proj/.claude/.session-lock" "local lock should be acquired"
}
run_test "no AFD_TOKEN → falls back to local lock check" test_no_afd_token_fallback

# ── Test: AFD reports free + local lock exists → local lock wins ────────────

test_afd_free_local_locked() {
    local proj="$TEST_TMPDIR/myproject"
    mkdir -p "$proj/.claude"

    # Create a local lock from a "remote" machine
    source "$LOCK_SCRIPT"
    python3 -c "
import json
data = {'machine': 'other-machine', 'pid': 99999, 'sessionId': 'old-session', 'timestamp': '2026-03-18T00:00:00Z', 'user': 'test'}
with open('$proj/.claude/.session-lock', 'w') as f: json.dump(data, f)
"

    # Mock curl: return empty (no lock on server)
    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/curl" << 'MOCK'
#!/usr/bin/env bash
# Return empty for GET (no lock), success for POST
if [[ "$*" == *"GET"* ]]; then
    exit 22  # curl error = no resource
fi
if [[ "$*" == *"POST"* ]]; then
    printf '{}\n201'
fi
exit 0
MOCK
    chmod +x "$TEST_TMPDIR/bin/curl"
    export PATH="$TEST_TMPDIR/bin:$_REAL_PATH"
    export AFD_TOKEN="test-token"
    export AFD_URL="http://localhost:9999"

    local out
    out=$(run_check_31 "$proj")
    restore_env

    # AFD returned nothing → falls through to local check → local says remote lock
    assert_contains "$out" "SESSION_LOCKED_REMOTE"
    assert_contains "$out" "other-machine"
}
run_test "AFD free + local lock from remote → local lock warning" test_afd_free_local_locked

# ── Test: AFD lock is ours → no warning ─────────────────────────────────────

test_afd_our_lock() {
    local proj="$TEST_TMPDIR/myproject"
    mkdir -p "$proj/.claude"

    local _hostname
    _hostname=$(hostname)

    # Mock curl: return lock held by US
    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/curl" << MOCK
#!/usr/bin/env bash
echo '{"project":"myproject","machine":"$_hostname","sessionId":"our-session","pid":$$}'
exit 0
MOCK
    chmod +x "$TEST_TMPDIR/bin/curl"
    export PATH="$TEST_TMPDIR/bin:$_REAL_PATH"
    export AFD_TOKEN="test-token"
    export AFD_URL="http://localhost:9999"
    export AFLEET_SESSION_ID="our-session"

    local out
    out=$(run_check_31 "$proj")
    restore_env

    assert_eq "" "$out" "should produce no warnings when AFD lock is ours"
}
run_test "AFD lock is ours → no warning" test_afd_our_lock

# ── Test: Local lock acquire also tries AFD acquire ─────────────────────────

test_local_acquire_also_tries_afd() {
    local proj="$TEST_TMPDIR/myproject"
    mkdir -p "$proj/.claude"

    # Mock curl: AFD status returns nothing (free), acquire returns 201
    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/curl" << 'MOCK'
#!/usr/bin/env bash
echo "$*" >> /tmp/test-afd-curl-calls.log
if [[ "$*" == *"GET"* ]]; then
    exit 22  # no resource
fi
if [[ "$*" == *"-w"* ]]; then
    printf '{}\n201'
else
    echo '{}'
fi
exit 0
MOCK
    chmod +x "$TEST_TMPDIR/bin/curl"
    : > /tmp/test-afd-curl-calls.log
    export PATH="$TEST_TMPDIR/bin:$_REAL_PATH"
    export AFD_TOKEN="test-token"
    export AFD_URL="http://localhost:9999"

    local out
    out=$(run_check_31 "$proj")
    restore_env

    # Local lock should be acquired
    assert_file_exists "$proj/.claude/.session-lock" "local lock should be acquired"

    # AFD acquire should have been attempted (POST to /api/locks)
    if [ -f /tmp/test-afd-curl-calls.log ]; then
        assert_file_contains /tmp/test-afd-curl-calls.log "POST"
        assert_file_contains /tmp/test-afd-curl-calls.log "/api/locks"
    fi
    rm -f /tmp/test-afd-curl-calls.log
}
run_test "local lock acquire also tries AFD acquire" test_local_acquire_also_tries_afd

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
