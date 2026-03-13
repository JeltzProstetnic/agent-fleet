#!/usr/bin/env bash
# Tests for CFG-101: Session Locking — afleet + hook integration
# Tests server-side lock acquire/release/heartbeat integration with afd-lib.sh
# and the afleet.sh/config-auto-sync.sh hook wiring.
source "$(dirname "$0")/test-helpers.sh"

suite_header "CFG-101: Server Lock Integration"

LOCK_SCRIPT="$REPO_ROOT/setup/scripts/session-lock.sh"
AFD_LIB="$REPO_ROOT/afd/lib/afd-lib.sh"
AFLEET_SCRIPT="$REPO_ROOT/setup/scripts/afleet.sh"
HOOK_SCRIPT="$REPO_ROOT/global/hooks/config-auto-sync.sh"

# Save real env to restore between tests
_REAL_AFD_TOKEN="${AFD_TOKEN:-}"
_REAL_AFD_URL="${AFD_URL:-}"
_REAL_PATH="$PATH"

# Helper: restore env after each test
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

# Helper: set up mock curl + isolated AFD env
# Usage: setup_test_afd <tmpdir> [http_code] [response_body]
setup_test_afd() {
    local tmpdir="$1"
    local http_code="${2:-201}"
    local body="${3:-{}}"
    mkdir -p "$tmpdir/bin"
    cat > "$tmpdir/bin/curl" << MOCK
#!/usr/bin/env bash
echo "\$*" >> "$tmpdir/curl_calls.log"
if [[ "\$*" == *"-w"* ]]; then
    printf '%s\n%s' '$body' '$http_code'
else
    printf '%s' '$body'
fi
exit 0
MOCK
    chmod +x "$tmpdir/bin/curl"
    : > "$tmpdir/curl_calls.log"
    # Properly export isolated env vars
    export PATH="$tmpdir/bin:$_REAL_PATH"
    export AFD_TOKEN="test-token"
    export AFD_URL="http://localhost:9999"
    source "$AFD_LIB"
}

# Helper: set up mock curl that fails (AFD unreachable)
setup_test_afd_fail() {
    local tmpdir="$1"
    mkdir -p "$tmpdir/bin"
    cat > "$tmpdir/bin/curl" << 'MOCK'
#!/usr/bin/env bash
exit 7
MOCK
    chmod +x "$tmpdir/bin/curl"
    : > "$tmpdir/curl_calls.log"
    export PATH="$tmpdir/bin:$_REAL_PATH"
    export AFD_TOKEN="test-token"
    export AFD_URL="http://localhost:9999"
    source "$AFD_LIB"
}

# Helper: set up mock curl returning 409 conflict
setup_test_afd_conflict() {
    local tmpdir="$1"
    local holder="${2:-other-machine}"
    mkdir -p "$tmpdir/bin"
    cat > "$tmpdir/bin/curl" << MOCK
#!/usr/bin/env bash
echo "\$*" >> "$tmpdir/curl_calls.log"
if [[ "\$*" == *"-w"* ]]; then
    printf '{"status":"locked","holder":"$holder"}\n409'
else
    printf '{"status":"locked","holder":"$holder"}'
fi
exit 0
MOCK
    chmod +x "$tmpdir/bin/curl"
    : > "$tmpdir/curl_calls.log"
    export PATH="$tmpdir/bin:$_REAL_PATH"
    export AFD_TOKEN="test-token"
    export AFD_URL="http://localhost:9999"
    source "$AFD_LIB"
}

# Helper: read mock curl call log
curl_calls() {
    local tmpdir="$1"
    cat "$tmpdir/curl_calls.log" 2>/dev/null || echo ""
}

# ── afd-lib.sh lock function tests (with mock curl) ──────────────────────────

test_afd_lock_acquire_calls_correct_endpoint() {
    setup_test_afd "$TEST_TMPDIR" "201" '{"status":"acquired"}'

    afd_lock_acquire "my-project" "wsl" "sess-123" "42"
    local rc=$?

    local calls
    calls=$(curl_calls "$TEST_TMPDIR")
    assert_eq "0" "$rc" "afd_lock_acquire should succeed with 201" &&
    assert_contains "$calls" "/api/locks" "should call /api/locks endpoint" &&
    assert_contains "$calls" "my-project" "should include project name" &&
    assert_contains "$calls" "sess-123" "should include session ID"
    local ret=$?
    restore_env
    return $ret
}
run_test "afd_lock_acquire calls correct endpoint" test_afd_lock_acquire_calls_correct_endpoint

test_afd_lock_acquire_fails_on_409() {
    setup_test_afd_conflict "$TEST_TMPDIR"

    afd_lock_acquire "my-project" 2>/dev/null
    local rc=$?

    restore_env
    assert_eq "1" "$rc" "afd_lock_acquire should fail with 409"
}
run_test "afd_lock_acquire fails on 409 conflict" test_afd_lock_acquire_fails_on_409

test_afd_lock_acquire_requires_token() {
    export AFD_TOKEN=""
    export AFD_URL="http://localhost:9999"
    source "$AFD_LIB"
    unset AFD_TOKEN

    afd_lock_acquire "my-project" 2>/dev/null
    local rc=$?

    restore_env
    assert_eq "1" "$rc" "afd_lock_acquire should fail without AFD_TOKEN"
}
run_test "afd_lock_acquire requires AFD_TOKEN" test_afd_lock_acquire_requires_token

test_afd_lock_release_calls_delete() {
    setup_test_afd "$TEST_TMPDIR" "200" '{}'

    afd_lock_release "my-project"
    local rc=$?

    local calls
    calls=$(curl_calls "$TEST_TMPDIR")
    assert_eq "0" "$rc" "afd_lock_release should succeed" &&
    assert_contains "$calls" "DELETE" "should use DELETE method" &&
    assert_contains "$calls" "/api/locks/my-project" "should target project lock"
    local ret=$?
    restore_env
    return $ret
}
run_test "afd_lock_release calls DELETE endpoint" test_afd_lock_release_calls_delete

test_afd_lock_heartbeat_calls_patch() {
    setup_test_afd "$TEST_TMPDIR" "200" '{}'

    afd_lock_heartbeat "my-project"
    local rc=$?

    local calls
    calls=$(curl_calls "$TEST_TMPDIR")
    assert_eq "0" "$rc" "afd_lock_heartbeat should succeed" &&
    assert_contains "$calls" "PATCH" "should use PATCH method" &&
    assert_contains "$calls" "/api/locks/my-project" "should target project lock" &&
    assert_contains "$calls" "heartbeat" "should include heartbeat payload"
    local ret=$?
    restore_env
    return $ret
}
run_test "afd_lock_heartbeat calls PATCH endpoint" test_afd_lock_heartbeat_calls_patch

# ── afleet.sh lock integration tests ──────────────────────────────────────────

test_afleet_acquires_local_lock() {
    local proj="$TEST_TMPDIR/project"
    make_project_dir "$proj"

    source "$LOCK_SCRIPT"

    acquire_lock "$proj" "test-session"
    local rc=$?

    assert_eq "0" "$rc" "should acquire local lock" &&
    assert_file_exists "$proj/.claude/.session-lock" "lock file should exist"
}
run_test "afleet acquires local lock" test_afleet_acquires_local_lock

test_afleet_local_lock_blocks_second_session() {
    local proj="$TEST_TMPDIR/project"
    make_project_dir "$proj"

    source "$LOCK_SCRIPT"

    # First session acquires
    acquire_lock "$proj" "session-1"
    local rc1=$?
    assert_eq "0" "$rc1" "first acquire should succeed"

    # To test blocking, we need a live PID that's not us.
    # Spawn a background sleep and use its PID.
    sleep 60 &
    local bg_pid=$!

    python3 -c "
import json
lock = {'machine': '$(hostname)', 'pid': $bg_pid, 'sessionId': 'other-session',
        'timestamp': '2026-03-13T00:00:00Z', 'user': '$(whoami)'}
with open('$proj/.claude/.session-lock', 'w') as f:
    json.dump(lock, f)
"
    # Now our acquire should fail (bg_pid is alive)
    acquire_lock "$proj" "session-2" 2>/dev/null
    local rc2=$?
    kill $bg_pid 2>/dev/null || true
    wait $bg_pid 2>/dev/null || true
    assert_eq "1" "$rc2" "second acquire should fail when locked by live PID"
}
run_test "local lock blocks second session" test_afleet_local_lock_blocks_second_session

test_afleet_server_lock_fallback_on_no_token() {
    local proj="$TEST_TMPDIR/project"
    make_project_dir "$proj"

    source "$LOCK_SCRIPT"
    export AFD_TOKEN=""
    unset AFD_TOKEN

    acquire_lock "$proj" "test-session"
    local rc=$?

    assert_eq "0" "$rc" "local lock should succeed even without AFD_TOKEN" &&
    assert_file_exists "$proj/.claude/.session-lock"
    local ret=$?
    restore_env
    return $ret
}
run_test "server lock gracefully skipped without AFD_TOKEN" test_afleet_server_lock_fallback_on_no_token

test_afleet_server_lock_fallback_on_unreachable() {
    local proj="$TEST_TMPDIR/project"
    make_project_dir "$proj"

    setup_test_afd_fail "$TEST_TMPDIR"
    source "$LOCK_SCRIPT"

    # Local lock should succeed
    acquire_lock "$proj" "test-session"
    local rc=$?
    assert_eq "0" "$rc" "local lock should succeed when AFD unreachable"

    # Server lock should fail silently
    afd_lock_acquire "my-project" 2>/dev/null
    local server_rc=$?
    assert_eq "1" "$server_rc" "server lock should fail when AFD unreachable"
    local ret=$?
    restore_env
    return $ret
}
run_test "server lock fallback when AFD unreachable" test_afleet_server_lock_fallback_on_unreachable

# ── Session ID propagation tests ──────────────────────────────────────────────

test_session_id_generated() {
    source "$LOCK_SCRIPT"

    local sid
    sid=$(_generate_session_id)

    assert_neq "" "$sid" "session ID should not be empty"
}
run_test "session ID is generated" test_session_id_generated

test_session_id_stored_in_lock_file() {
    local proj="$TEST_TMPDIR/project"
    make_project_dir "$proj"

    source "$LOCK_SCRIPT"

    local sid
    sid=$(_generate_session_id)
    acquire_lock "$proj" "$sid"

    local lockfile="$proj/.claude/.session-lock"
    local stored_sid
    stored_sid=$(python3 -c "import json; print(json.load(open('$lockfile'))['sessionId'])")

    assert_eq "$sid" "$stored_sid" "session ID in lock file should match generated ID"
}
run_test "session ID stored in lock file" test_session_id_stored_in_lock_file

test_session_id_via_env_var() {
    local proj="$TEST_TMPDIR/project"
    make_project_dir "$proj"

    source "$LOCK_SCRIPT"

    local sid="test-env-session-42"
    acquire_lock "$proj" "$sid"

    # Simulate what config-auto-sync.sh would do
    export AFLEET_SESSION_ID="$sid"
    release_lock "$proj" "$AFLEET_SESSION_ID"
    local rc=$?

    assert_eq "0" "$rc" "release with env var session ID should succeed" &&
    assert_file_not_exists "$proj/.claude/.session-lock" "lock file should be removed"
    local ret=$?
    restore_env
    return $ret
}
run_test "AFLEET_SESSION_ID env var used for release" test_session_id_via_env_var

# ── config-auto-sync.sh release integration tests ─────────────────────────────

test_hook_releases_local_lock() {
    local proj="$TEST_TMPDIR/project"
    make_project_dir "$proj"

    source "$LOCK_SCRIPT"
    acquire_lock "$proj" "hook-test-session"

    assert_file_exists "$proj/.claude/.session-lock" "lock should exist before release"

    release_lock "$proj" 2>/dev/null || true

    assert_file_not_exists "$proj/.claude/.session-lock" "lock should be removed after release"
}
run_test "hook releases local lock" test_hook_releases_local_lock

test_hook_releases_server_lock() {
    setup_test_afd "$TEST_TMPDIR" "200" '{}'

    export AFLEET_SESSION_ID="hook-session-42"
    afd_lock_release "my-project"
    local rc=$?

    local calls
    calls=$(curl_calls "$TEST_TMPDIR")
    assert_eq "0" "$rc" "server lock release should succeed" &&
    assert_contains "$calls" "DELETE" "should call DELETE" &&
    assert_contains "$calls" "/api/locks/my-project" "should target correct project"
    local ret=$?
    restore_env
    return $ret
}
run_test "hook releases server lock" test_hook_releases_server_lock

test_hook_server_release_silent_on_failure() {
    setup_test_afd_fail "$TEST_TMPDIR"

    afd_lock_release "my-project" 2>/dev/null
    local rc=$?

    restore_env
    # rc will be non-zero (7=connection refused) — the hook uses || true
    assert_neq "0" "$rc" "server release returns error but doesn't crash"
}
run_test "hook server release silent on failure" test_hook_server_release_silent_on_failure

# ── Heartbeat tests ───────────────────────────────────────────────────────────

test_heartbeat_sends_patch() {
    setup_test_afd "$TEST_TMPDIR" "200" '{}'

    afd_lock_heartbeat "my-project"
    local rc=$?

    local calls
    calls=$(curl_calls "$TEST_TMPDIR")
    assert_eq "0" "$rc" "heartbeat should succeed" &&
    assert_contains "$calls" "PATCH" "should use PATCH" &&
    assert_contains "$calls" "heartbeat" "should include heartbeat in payload"
    local ret=$?
    restore_env
    return $ret
}
run_test "heartbeat sends PATCH with heartbeat payload" test_heartbeat_sends_patch

test_heartbeat_silent_on_no_token() {
    export AFD_TOKEN=""
    export AFD_URL="http://localhost:9999"
    source "$AFD_LIB"
    unset AFD_TOKEN

    afd_lock_heartbeat "my-project" 2>/dev/null
    local rc=$?

    restore_env
    assert_eq "1" "$rc" "heartbeat should fail without token"
}
run_test "heartbeat silent on no AFD_TOKEN" test_heartbeat_silent_on_no_token

test_heartbeat_silent_on_unreachable() {
    setup_test_afd_fail "$TEST_TMPDIR"

    afd_lock_heartbeat "my-project" 2>/dev/null
    local rc=$?

    restore_env
    assert_neq "0" "$rc" "heartbeat should fail silently when AFD unreachable"
}
run_test "heartbeat silent on AFD unreachable" test_heartbeat_silent_on_unreachable

# ── afleet.sh / hook existence tests ──────────────────────────────────────────

test_afleet_function_exists() {
    grep -q 'afleet_acquire_session_lock()' "$AFLEET_SCRIPT" 2>/dev/null
    local rc=$?
    assert_eq "0" "$rc" "afleet_acquire_session_lock() should exist in afleet.sh"
}
run_test "afleet_acquire_session_lock function exists in afleet.sh" test_afleet_function_exists

test_afleet_release_function_exists() {
    grep -q 'afd_lock_release\|AFLEET_SESSION_ID' "$HOOK_SCRIPT" 2>/dev/null
    local rc=$?
    assert_eq "0" "$rc" "server lock release should exist in config-auto-sync.sh"
}
run_test "server lock release exists in config-auto-sync.sh" test_afleet_release_function_exists

test_statusline_heartbeat_exists() {
    local statusline="$REPO_ROOT/setup/config/statusline-command.sh"
    grep -q 'heartbeat\|afd_lock_heartbeat\|AFLEET_SESSION_ID' "$statusline" 2>/dev/null
    local rc=$?
    assert_eq "0" "$rc" "heartbeat code should exist in statusline-command.sh"
}
run_test "heartbeat code exists in statusline-command.sh" test_statusline_heartbeat_exists

# ── End-to-end flow test ─────────────────────────────────────────────────────

test_full_lock_lifecycle() {
    local proj="$TEST_TMPDIR/project"
    make_project_dir "$proj"

    setup_test_afd "$TEST_TMPDIR" "201" '{"status":"acquired"}'
    source "$LOCK_SCRIPT"

    # 1. Generate session ID
    local sid
    sid=$(_generate_session_id)
    assert_neq "" "$sid" "session ID generated" || return 1

    # 2. Acquire local lock
    acquire_lock "$proj" "$sid"
    assert_eq "0" "$?" "local lock acquired" || return 1
    assert_file_exists "$proj/.claude/.session-lock" || return 1

    # 3. Acquire server lock
    afd_lock_acquire "test-project" "$(hostname)" "$sid" "$$"
    assert_eq "0" "$?" "server lock acquired" || return 1

    # 4. Send heartbeat (update mock response without resetting log)
    # Re-create mock curl with 200 but keep existing log
    cat > "$TEST_TMPDIR/bin/curl" << 'HBMOCK'
#!/usr/bin/env bash
echo "$*" >> "TMPDIR_PLACEHOLDER/curl_calls.log"
if [[ "$*" == *"-w"* ]]; then
    printf '{}\n200'
else
    printf '{}'
fi
exit 0
HBMOCK
    sed -i "s|TMPDIR_PLACEHOLDER|$TEST_TMPDIR|g" "$TEST_TMPDIR/bin/curl"
    chmod +x "$TEST_TMPDIR/bin/curl"
    afd_lock_heartbeat "test-project"
    assert_eq "0" "$?" "heartbeat sent" || return 1

    # 5. Release local lock
    release_lock "$proj" "$sid"
    assert_eq "0" "$?" "local lock released" || return 1
    assert_file_not_exists "$proj/.claude/.session-lock" "local lock file removed" || return 1

    # 6. Release server lock
    afd_lock_release "test-project"
    assert_eq "0" "$?" "server lock released" || return 1

    # Verify curl was called for all operations
    local calls
    calls=$(curl_calls "$TEST_TMPDIR")
    assert_contains "$calls" "POST" "acquire used POST" &&
    assert_contains "$calls" "PATCH" "heartbeat used PATCH" &&
    assert_contains "$calls" "DELETE" "release used DELETE"
    local ret=$?
    restore_env
    return $ret
}
run_test "full lock lifecycle: acquire -> heartbeat -> release" test_full_lock_lifecycle

suite_summary
