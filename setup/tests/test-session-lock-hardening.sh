#!/usr/bin/env bash
# CFG-452 red-team hardening (Fable 2026-07-07) — session-lock.sh Findings 2 & 3.
#   F3: idempotent re-acquire must PRESERVE the existing ccSessionId + original PID
#       (it currently blanks cc + resets PID to the transient hook $$, which
#       manufactures unstamped/dead-PID locks and feeds the F1 residual).
#   F2: _write_lock / stamp_cc_session must REJECT unsafe ids instead of splicing
#       them into the JSON encoders — a quote/newline/backslash truncates the lock
#       to 0 bytes (mutual-exclusion loss). Refuse; never truncate the live lock.
source "$(dirname "$0")/test-helpers.sh"

LOCK_LIB="$REPO_ROOT/setup/scripts/session-lock.sh"
suite_header "session-lock hardening (F2 sanitize ids, F3 preserve on re-acquire)"

# ── F3: idempotent re-acquire preserves cc + PID ─────────────────────────────

test_reacquire_preserves_cc() {
    source "$LOCK_LIB"
    local D="$TEST_TMPDIR/f3a"; mkdir -p "$D/.claude"
    _write_lock "$D/.claude/.session-lock" "sess-A" "cc-x" 999999
    acquire_lock "$D" "sess-A"                     # re-acquire, NO cc arg (hook/afleet case)
    _read_lock "$D/.claude/.session-lock"
    assert_eq "cc-x" "$_LOCK_CC_SESSION" "re-acquire preserves existing ccSessionId"
}
run_test "F3: idempotent re-acquire preserves ccSessionId" test_reacquire_preserves_cc

test_reacquire_preserves_pid() {
    source "$LOCK_LIB"
    local D="$TEST_TMPDIR/f3b"; mkdir -p "$D/.claude"
    _write_lock "$D/.claude/.session-lock" "sess-A" "cc-x" 999999
    acquire_lock "$D" "sess-A"
    _read_lock "$D/.claude/.session-lock"
    assert_eq "999999" "$_LOCK_PID" "re-acquire preserves the original owner PID (not reset to hook \$\$)"
}
run_test "F3: idempotent re-acquire preserves original PID" test_reacquire_preserves_pid

test_reacquire_honors_new_cc() {
    source "$LOCK_LIB"
    local D="$TEST_TMPDIR/f3c"; mkdir -p "$D/.claude"
    _write_lock "$D/.claude/.session-lock" "sess-A" "cc-x" 999999
    acquire_lock "$D" "sess-A" "cc-new"           # explicit new cc → honored, PID kept
    _read_lock "$D/.claude/.session-lock"
    assert_eq "cc-new" "$_LOCK_CC_SESSION" "explicit new cc arg on re-acquire is honored"
    assert_eq "999999" "$_LOCK_PID" "explicit-cc re-acquire still preserves PID"
}
run_test "F3: re-acquire with explicit cc updates cc, keeps PID" test_reacquire_honors_new_cc

# ── F2: unsafe ids are refused, lock is never truncated ──────────────────────

test_write_lock_rejects_unsafe_cc() {
    source "$LOCK_LIB"
    local D="$TEST_TMPDIR/f2a"; mkdir -p "$D/.claude"; local L="$D/.claude/.session-lock"
    _write_lock "$L" "sess-A" "cc-good" 999999
    local before; before="$(cat "$L")"
    _write_lock "$L" "sess-A" "bad'; rm -rf x" 999999; local rc=$?
    assert_eq "1" "$rc" "_write_lock refuses an unsafe cc id"
    assert_eq "$before" "$(cat "$L")" "lock is NOT truncated/altered on refusal"
}
run_test "F2: _write_lock rejects unsafe cc id, lock intact" test_write_lock_rejects_unsafe_cc

test_write_lock_rejects_unsafe_session() {
    source "$LOCK_LIB"
    local D="$TEST_TMPDIR/f2b"; mkdir -p "$D/.claude"; local L="$D/.claude/.session-lock"
    _write_lock "$L" "sess-A" "cc-good" 999999
    local before; before="$(cat "$L")"
    _write_lock "$L" $'bad\nid' "cc-good" 999999; local rc=$?
    assert_eq "1" "$rc" "_write_lock refuses an unsafe (newline) session id"
    assert_eq "$before" "$(cat "$L")" "lock preserved on unsafe session id"
}
run_test "F2: _write_lock rejects unsafe session id, lock intact" test_write_lock_rejects_unsafe_session

test_stamp_rejects_unsafe_cc() {
    source "$LOCK_LIB"
    local D="$TEST_TMPDIR/f2c"; mkdir -p "$D/.claude"; local L="$D/.claude/.session-lock"
    acquire_lock "$D" "sess-A" >/dev/null 2>&1     # unstamped valid lock (pid=$$, alive)
    local before; before="$(cat "$L")"
    stamp_cc_session "$D" "bad'id"; local rc=$?
    assert_eq "1" "$rc" "stamp_cc_session refuses an unsafe cc id"
    assert_eq "$before" "$(cat "$L")" "stamp refusal leaves lock unchanged"
}
run_test "F2: stamp_cc_session rejects unsafe cc id" test_stamp_rejects_unsafe_cc

test_safe_ids_still_work() {
    source "$LOCK_LIB"
    local D="$TEST_TMPDIR/f2d"; mkdir -p "$D/.claude"; local L="$D/.claude/.session-lock"
    local uuid="a1b2c3d4-5566-7788-99aa-bbccddeeff00"
    _write_lock "$L" "$uuid" "cc_test.id-1" 12345; local rc=$?
    assert_eq "0" "$rc" "valid UUID/charset ids still write successfully"
    _read_lock "$L"
    assert_eq "$uuid" "$_LOCK_SESSION" "valid session id round-trips"
    assert_eq "cc_test.id-1" "$_LOCK_CC_SESSION" "valid cc id round-trips"
}
run_test "F2: safe ids (UUID, ._-) still write (regression guard)" test_safe_ids_still_work

suite_summary
