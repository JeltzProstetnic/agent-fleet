#!/usr/bin/env bash
# CFG-452 Phase 1 Increment 2 — CC hook-stdin session_id ownership wiring.
#
# Part A: unit-tests the stdin parser (global/hooks/lib-hook-stdin.sh :: read_cc_session_id).
# Part B: integration-tests the stamp->release wiring that closes the F1
#         env-inheritance spoof (a nested CC process inherits AFLEET_SESSION_ID
#         but has a DIFFERENT cc session id, so it must NOT release the leader's lock).
#
# Uses the REAL session-lock.sh functions (stamp_cc_session / release_own_lock)
# exactly as the hooks call them — the full-hook path is covered by VM E2E.
source "$(dirname "$0")/test-helpers.sh"

STDIN_LIB="$REPO_ROOT/global/hooks/lib-hook-stdin.sh"
LOCK_LIB="$REPO_ROOT/setup/scripts/session-lock.sh"

suite_header "cc-session-ownership (lib-hook-stdin.sh + wiring)"

# ── Part A: read_cc_session_id parser ────────────────────────────────────────

test_parse_valid() {
    source "$STDIN_LIB"
    local out
    out=$(printf '%s' '{"session_id":"cc-abc-123","cwd":"/x","source":"startup"}' | read_cc_session_id)
    assert_eq "cc-abc-123" "$out" "extracts session_id from a well-formed hook JSON"
}
run_test "parser: valid JSON returns session_id" test_parse_valid

test_parse_empty() {
    source "$STDIN_LIB"
    local out
    out=$(printf '' | read_cc_session_id)
    assert_eq "" "$out" "empty stdin returns empty (safe fallback)"
}
run_test "parser: empty stdin returns empty" test_parse_empty

test_parse_no_key() {
    source "$STDIN_LIB"
    local out
    out=$(printf '%s' '{"cwd":"/x","source":"startup"}' | read_cc_session_id)
    assert_eq "" "$out" "JSON without session_id returns empty"
}
run_test "parser: JSON without session_id returns empty" test_parse_no_key

test_parse_malformed() {
    source "$STDIN_LIB"
    local out
    out=$(printf '%s' 'not json at all {' | read_cc_session_id)
    assert_eq "" "$out" "malformed JSON returns empty"
}
run_test "parser: malformed JSON returns empty" test_parse_malformed

# ── Part B: stamp -> release wiring (F1 spoof closed at hook level) ──────────
# SessionStart acquires + stamps the lock with the CC session id; SessionEnd
# releases ONLY when the CC session id matches. An inherited AFLEET does NOT.

# Acquire as an afleet leader then stamp with a unique cc id (mirrors 07b 7b.4).
_setup_afleet_lock() {
    local dir="$1" afleet="$2" cc="$3"
    mkdir -p "$dir/.claude"
    ( source "$LOCK_LIB"
      acquire_lock "$dir" "$afleet" >/dev/null 2>&1
      stamp_cc_session "$dir" "$cc" >/dev/null 2>&1 )
}

test_leader_releases_own() {
    local dir="$TEST_TMPDIR/proj-leader"
    _setup_afleet_lock "$dir" "af-1" "cc-real"
    source "$STDIN_LIB"; source "$LOCK_LIB"
    local cc
    cc=$(printf '%s' '{"session_id":"cc-real"}' | read_cc_session_id)
    release_own_lock "$dir" "af-1" "$cc"
    assert_file_not_exists "$dir/.claude/.session-lock" "leader with matching cc releases its own lock"
}
run_test "wiring: leader with matching cc releases own lock" test_leader_releases_own

test_nested_spoof_blocked() {
    local dir="$TEST_TMPDIR/proj-spoof"
    _setup_afleet_lock "$dir" "af-1" "cc-real"
    source "$STDIN_LIB"; source "$LOCK_LIB"
    # Nested CC process: inherited AFLEET_SESSION_ID=af-1 but a DIFFERENT cc id.
    local cc
    cc=$(printf '%s' '{"session_id":"cc-nested"}' | read_cc_session_id)
    release_own_lock "$dir" "af-1" "$cc"
    assert_file_exists "$dir/.claude/.session-lock" "nested spoof (same AFLEET, different cc) cannot release the leader lock"
}
run_test "wiring: nested spoof (inherited AFLEET, different cc) blocked" test_nested_spoof_blocked

test_direct_launch_releases() {
    # Direct (non-afleet) launch: no AFLEET, but the lock is cc-stamped at start.
    local dir="$TEST_TMPDIR/proj-direct"
    mkdir -p "$dir/.claude"
    ( source "$LOCK_LIB"
      acquire_lock "$dir" "" >/dev/null 2>&1
      stamp_cc_session "$dir" "cc-direct" >/dev/null 2>&1 )
    source "$STDIN_LIB"; source "$LOCK_LIB"
    local cc
    cc=$(printf '%s' '{"session_id":"cc-direct"}' | read_cc_session_id)
    release_own_lock "$dir" "" "$cc"
    assert_file_not_exists "$dir/.claude/.session-lock" "direct-launch leader releases its own lock via cc id"
}
run_test "wiring: direct-launch leader releases via cc id" test_direct_launch_releases

suite_summary
