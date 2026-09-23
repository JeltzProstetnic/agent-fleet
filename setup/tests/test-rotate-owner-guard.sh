#!/usr/bin/env bash
# CFG-452 Phase 2 — rotate-session.sh ownership guard.
#
# rotate-session.sh must refuse to rotate a project held by a DIFFERENT live
# session unless the caller passes --owner-verified (the leader's SessionEnd,
# which has already proven ownership). Ordinary use with no foreign lock is
# unaffected. Proof-by-PID is impossible here (rotate runs as a subprocess), so
# the flag is the ownership assertion.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO_ROOT/setup/tests/test-helpers.sh"

ROTATE="$REPO_ROOT/setup/scripts/rotate-session.sh"
LOCK_LIB="$REPO_ROOT/setup/scripts/session-lock.sh"

suite_header "rotate-session.sh (CFG-452 Phase 2: --owner-verified guard)"

# A project dir with a populated session-context.md (so rotate has real work).
_make_project() {
    local dir="$1"
    mkdir -p "$dir/docs" "$dir/.claude"
    cat > "$dir/session-context.md" << 'EOF'
# Session Context
**Session Goal**: guard test
- [x] work item
## Key Decisions
- decision
EOF
}

_make_foreign_lock() {
    ( source "$LOCK_LIB"; acquire_lock "$1" "af-leader" >/dev/null 2>&1 )
}

test_refuses_on_foreign_lock() {
    local dir="$TEST_TMPDIR/proj-refuse"
    _make_project "$dir"
    _make_foreign_lock "$dir"           # a live foreign session holds it
    local rc=0
    bash "$ROTATE" "$dir" >/dev/null 2>&1 || rc=$?
    assert_eq "3" "$rc" "refuses (exit 3) to rotate a foreign-locked project without --owner-verified"
    assert_file_not_exists "$dir/session-history.md" "no rotation happened (history not written)"
}
run_test "guard: refuses on foreign live lock" test_refuses_on_foreign_lock

test_owner_verified_bypasses() {
    local dir="$TEST_TMPDIR/proj-verified"
    _make_project "$dir"
    _make_foreign_lock "$dir"
    local rc=0
    bash "$ROTATE" "$dir" --owner-verified >/dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" "--owner-verified rotates even with a lock present (leader path)"
    assert_file_exists "$dir/session-history.md" "rotation happened (history written)"
}
run_test "guard: --owner-verified bypasses the check" test_owner_verified_bypasses

test_no_lock_unaffected() {
    local dir="$TEST_TMPDIR/proj-nolock"
    _make_project "$dir"                # no lock at all
    local rc=0
    bash "$ROTATE" "$dir" >/dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" "no lock ⇒ ordinary use is unaffected (rotates normally)"
    assert_file_exists "$dir/session-history.md" "rotation happened (history written)"
}
run_test "guard: no lock ⇒ unaffected" test_no_lock_unaffected

test_flag_order_independent() {
    # The flag must be recognized before OR after the positional dir arg.
    local dir="$TEST_TMPDIR/proj-order"
    _make_project "$dir"
    _make_foreign_lock "$dir"
    local rc=0
    bash "$ROTATE" --owner-verified "$dir" >/dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" "--owner-verified is honored when it precedes the dir"
    assert_file_exists "$dir/session-history.md" "rotation happened with flag-first ordering"
}
run_test "guard: flag position independent" test_flag_order_independent

# ── CFG-536: the leader must rotate on the BARE documented command ────────────
# session-shutdown.md tells the session to run `rotate-session.sh` with no flags.
# Before the check_lock ownership fix, the leader's own live lock read as foreign
# (the lock records the afleet launcher shell, not the claude.exe pid), so the
# guard refused every leader shutdown and the obvious workaround was to add
# --owner-verified to the checklist — the very bypass a security review flagged
# as able to blank a live session's context from another project.
#
# This asserts the outcome that matters: a session that can PROVE ownership is
# not refused, and still needs no flag.
test_leader_rotates_on_bare_command() {
    local dir="$TEST_TMPDIR/proj-leader-bare"
    _make_project "$dir"
    # A lock this session owns: live pid + sessionId matching our AFLEET_SESSION_ID.
    ( source "$LOCK_LIB"; _write_lock "$dir/.claude/.session-lock" "af-mine" "" "$$" )
    local rc=0
    AFLEET_SESSION_ID="af-mine" bash "$ROTATE" "$dir" >/dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" "the proven leader rotates on the BARE command — no --owner-verified needed" || return 1
    assert_file_exists "$dir/session-history.md" "rotation happened for the proven owner"
}
run_test "CFG-536: leader rotates without --owner-verified" test_leader_rotates_on_bare_command

test_unproven_session_still_refused() {
    # The guard must not have been widened into a no-op: a session that cannot
    # prove ownership of a live lock is still refused.
    local dir="$TEST_TMPDIR/proj-unproven"
    _make_project "$dir"
    ( source "$LOCK_LIB"; _write_lock "$dir/.claude/.session-lock" "af-someone-else" "cc-someone-else" "$$" )
    local rc=0
    AFLEET_SESSION_ID="af-mine" CC_SESSION_ID="cc-mine" bash "$ROTATE" "$dir" >/dev/null 2>&1 || rc=$?
    assert_eq "3" "$rc" "a session with no ownership proof is still refused (guard not widened away)" || return 1
    assert_file_not_exists "$dir/session-history.md" "no rotation happened for the unproven caller"
}
run_test "CFG-536: unproven caller is still refused" test_unproven_session_still_refused

suite_summary
