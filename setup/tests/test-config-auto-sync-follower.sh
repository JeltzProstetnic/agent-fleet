#!/usr/bin/env bash
# CFG-452 Phase 2 — follower-aware SessionEnd (config-auto-sync.sh).
#
# The safety property: a FOLLOWER shutdown must NOT rotate/commit/deploy/push and
# must NOT delete the leader's lock. Role is read from the marker persisted at
# SessionStart; when no marker exists it falls back to lock ownership.
#
# Uses the REAL session-lock.sh (so read_role/release_own_lock/clear_role exist)
# copied over the mock, and the shared config-auto-sync test harness.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO_ROOT/setup/tests/test-helpers.sh"
source "$REPO_ROOT/setup/tests/test-config-auto-sync-helpers.sh"

suite_header "config-auto-sync.sh (CFG-452 Phase 2: follower-aware shutdown)"

# Install the REAL lock lib + a logging rotate stub into a mock config repo.
_prep_repo() {
    local config_repo="$1" project_dir="$2"
    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    cp "$REPO_ROOT/setup/scripts/session-lock.sh" "$config_repo/setup/scripts/session-lock.sh"
    cat > "$config_repo/setup/scripts/rotate-session.sh" << 'STUB'
#!/usr/bin/env bash
# log every non-flag arg so the test can see whether (and on what) rotate ran
for a in "$@"; do [ "$a" = "--owner-verified" ] || echo "ROTATE:$a" >> "${ROTATE_LOG:-/dev/null}"; done
exit 0
STUB
    chmod +x "$config_repo/setup/scripts/rotate-session.sh"
    mkdir -p "$project_dir/docs" "$project_dir/.claude"
    cat > "$project_dir/session-context.md" << 'EOF'
# Session Context
**Session Goal**: Phase 2 follower test
- [x] Did a thing
## Key Decisions
- Test
EOF
    (cd "$config_repo" && git add -A && git commit -m "stubs+lib" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
}

# Create a foreign leader lock owned by a different session id (alive PID).
_make_foreign_lock() {
    local project_dir="$1" leader_sid="$2"
    ( source "$REPO_ROOT/setup/scripts/session-lock.sh"
      acquire_lock "$project_dir" "$leader_sid" >/dev/null 2>&1 )
}

# ── FOLLOWER via marker: skips rotate, leaves the leader lock intact ──────────
test_follower_marker_skips_rotate() {
    local config_repo="$TEST_TMPDIR/cfg" project_dir="$TEST_TMPDIR/proj" mock_home="$TEST_TMPDIR/home"
    mkdir -p "$mock_home"
    _prep_repo "$config_repo" "$project_dir"
    _make_foreign_lock "$project_dir" "af-leader"           # leader holds the lock
    printf 'follower\n' > "$project_dir/.claude/.session-role.af-follower"

    export ROTATE_LOG="$TEST_TMPDIR/rotate.log"; : > "$ROTATE_LOG"
    export AFLEET_SESSION_ID="af-follower"                  # this session = follower
    local patched rc=0
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || rc=$?
    unset AFLEET_SESSION_ID

    assert_eq "0" "$rc" "follower hook still exits 0"
    local log; log=$(<"$ROTATE_LOG")
    assert_not_contains "$log" "$project_dir" "FOLLOWER must NOT rotate the project"
    assert_file_exists "$project_dir/.claude/.session-lock" "FOLLOWER must NOT delete the leader's lock"
    assert_file_not_exists "$project_dir/.claude/.session-role.af-follower" "follower clears its own role marker"
    unset ROTATE_LOG
}
run_test "follower (marker): skips rotate, leader lock intact" test_follower_marker_skips_rotate

# ── FOLLOWER via fallback: no marker, but a foreign lock is present ───────────
test_follower_fallback_no_marker() {
    local config_repo="$TEST_TMPDIR/cfg" project_dir="$TEST_TMPDIR/proj" mock_home="$TEST_TMPDIR/home"
    mkdir -p "$mock_home"
    _prep_repo "$config_repo" "$project_dir"
    _make_foreign_lock "$project_dir" "af-someone-else"     # foreign lock, no matching id
    # No role marker at all. Our id does not own the lock → must resolve to follower.

    export ROTATE_LOG="$TEST_TMPDIR/rotate.log"; : > "$ROTATE_LOG"
    export AFLEET_SESSION_ID="af-me"
    local patched rc=0
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || rc=$?
    unset AFLEET_SESSION_ID

    assert_eq "0" "$rc" "fallback-follower hook exits 0"
    local log; log=$(<"$ROTATE_LOG")
    assert_not_contains "$log" "$project_dir" "unprovable foreign lock ⇒ treated as follower ⇒ no rotate"
    assert_file_exists "$project_dir/.claude/.session-lock" "foreign leader lock left intact"
    unset ROTATE_LOG
}
run_test "follower (fallback): foreign lock, no marker ⇒ skips rotate" test_follower_fallback_no_marker

# ── LEADER via marker: performs the rotate ───────────────────────────────────
test_leader_marker_rotates() {
    local config_repo="$TEST_TMPDIR/cfg" project_dir="$TEST_TMPDIR/proj" mock_home="$TEST_TMPDIR/home"
    mkdir -p "$mock_home"
    _prep_repo "$config_repo" "$project_dir"
    # Leader owns the lock with a matching id, and the marker says leader.
    _make_foreign_lock "$project_dir" "af-leader"
    printf 'leader\n' > "$project_dir/.claude/.session-role.af-leader"

    export ROTATE_LOG="$TEST_TMPDIR/rotate.log"; : > "$ROTATE_LOG"
    export AFLEET_SESSION_ID="af-leader"
    local patched rc=0
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || rc=$?
    unset AFLEET_SESSION_ID

    assert_eq "0" "$rc" "leader hook exits 0"
    local log; log=$(<"$ROTATE_LOG")
    assert_contains "$log" "$project_dir" "LEADER rotates the project"
    unset ROTATE_LOG
}
run_test "leader (marker): performs rotate" test_leader_marker_rotates

# ── SOLO (no lock, no marker): treated as leader — never lose a solo's work ───
test_solo_no_lock_is_leader() {
    local config_repo="$TEST_TMPDIR/cfg" project_dir="$TEST_TMPDIR/proj" mock_home="$TEST_TMPDIR/home"
    mkdir -p "$mock_home"
    _prep_repo "$config_repo" "$project_dir"
    # No lock file, no marker, no identity — a solo direct-launch session.

    export ROTATE_LOG="$TEST_TMPDIR/rotate.log"; : > "$ROTATE_LOG"
    local patched rc=0
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || rc=$?

    assert_eq "0" "$rc" "solo hook exits 0"
    local log; log=$(<"$ROTATE_LOG")
    assert_contains "$log" "$project_dir" "SOLO session (no lock) is treated as leader and rotates"
    unset ROTATE_LOG
}
run_test "solo (no lock/no marker): treated as leader" test_solo_no_lock_is_leader

suite_summary
