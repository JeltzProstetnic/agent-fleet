#!/usr/bin/env bash
# CFG-452 Phase 2 — SessionStart role-marker wiring (checks/07b-platform-env.sh).
#
# Verifies the ACTUAL 07b check writes the correct role marker at startup:
#   - a free project → acquire (check_lock rc 0) → marker "leader";
#   - a project held by another live session (rc 2) → marker "follower".
# Runs the real 07b in a subshell with a controlled env (_FORCE_WSL=0 disables the
# wsl.conf auto-fix; a bare CONFIG_REPO makes 7b.2/7b.3 no-ops), so only the 7b.4
# lock+role path exercises. This closes the SessionStart-wiring gap that the
# library/shutdown unit tests do not cover.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO_ROOT/setup/tests/test-helpers.sh"

HOOK_07B="$REPO_ROOT/global/hooks/checks/07b-platform-env.sh"
LOCK_LIB="$REPO_ROOT/setup/scripts/session-lock.sh"

suite_header "session-role hook wiring (checks/07b writes leader|follower)"

# Minimal CONFIG_REPO the check expects: just the real lock lib under setup/scripts.
_mk_config_repo() {
    local cr="$1"
    mkdir -p "$cr/setup/scripts"
    cp "$LOCK_LIB" "$cr/setup/scripts/session-lock.sh"
}

# Run 07b with a controlled environment against $proj as PWD.
_run_07b() {
    local cr="$1" proj="$2" cc="$3" af="$4"
    (
        export _FORCE_WSL=0            # skip 7b.1 wsl.conf auto-fix (no system writes)
        export CONFIG_REPO="$cr" PROJECT_DIR="$proj"
        export CC_SESSION_ID="$cc" AFLEET_SESSION_ID="$af"
        WARNINGS="" INBOX_MSG=""
        cd "$proj"
        # shellcheck disable=SC1090
        source "$HOOK_07B"
    ) >/dev/null 2>&1
}

test_leader_marker_written_on_acquire() {
    local cr="$TEST_TMPDIR/cr1" proj="$TEST_TMPDIR/proj-leader"
    _mk_config_repo "$cr"
    mkdir -p "$proj/.claude"          # free project — no lock
    _run_07b "$cr" "$proj" "cc-leader" ""
    assert_file_exists "$proj/.claude/.session-role.cc-leader" "07b writes a role marker on acquire"
    assert_file_contains "$proj/.claude/.session-role.cc-leader" "leader" "acquire (rc 0) ⇒ leader"
    assert_file_exists "$proj/.claude/.session-lock" "07b acquired the lock"
}
run_test "07b: acquire ⇒ leader marker" test_leader_marker_written_on_acquire

test_follower_marker_written_on_conflict() {
    local cr="$TEST_TMPDIR/cr2" proj="$TEST_TMPDIR/proj-follower"
    _mk_config_repo "$cr"
    mkdir -p "$proj/.claude"
    # A DIFFERENT live session holds the lock. Use a real background process so the
    # lock's PID is alive and genuinely != the check's PID (bash subshells share $$,
    # so a subshell acquire would look like our own lock, not a foreign one).
    sleep 120 & local _fpid=$!
    ( source "$LOCK_LIB"; _write_lock "$proj/.claude/.session-lock" "af-other-leader" "" "$_fpid" )
    _run_07b "$cr" "$proj" "cc-follower" ""
    kill "$_fpid" 2>/dev/null || true
    assert_file_exists "$proj/.claude/.session-role.cc-follower" "07b writes a role marker on conflict"
    assert_file_contains "$proj/.claude/.session-role.cc-follower" "follower" "foreign live lock (rc 2) ⇒ follower"
    assert_file_exists "$proj/.claude/.session-lock" "07b leaves the foreign leader lock intact"
}
run_test "07b: conflict ⇒ follower marker" test_follower_marker_written_on_conflict

suite_summary
