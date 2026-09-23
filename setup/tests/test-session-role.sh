#!/usr/bin/env bash
# CFG-452 Phase 2 — session role marker (leader|follower) persistence.
#
# The role is determined at SessionStart (when the acquire result is
# unambiguous) and read at SessionEnd to gate shared-state mutation. One marker
# file per session identity so parallel sessions coexist:
#   $PROJECT_DIR/.claude/.session-role.<id>   (single word: leader|follower)
#
# These unit-test the library functions the hooks call:
#   write_role <dir> <role> [cc_sid] [afleet_sid]
#   read_role  <dir>        [cc_sid] [afleet_sid]   -> echoes role, rc 0/1
#   clear_role <dir>        [cc_sid] [afleet_sid]
source "$(dirname "$0")/test-helpers.sh"

LOCK_LIB="$REPO_ROOT/setup/scripts/session-lock.sh"

suite_header "session-role (write_role / read_role / clear_role)"

# ── round-trip ───────────────────────────────────────────────────────────────

test_leader_roundtrip() {
    local dir="$TEST_TMPDIR/role-leader"
    ( source "$LOCK_LIB"; write_role "$dir" leader "cc-1" "" )
    local out
    out=$( source "$LOCK_LIB"; read_role "$dir" "cc-1" "" )
    assert_eq "leader" "$out" "write_role leader → read_role returns leader"
}
run_test "roundtrip: leader" test_leader_roundtrip

test_follower_roundtrip() {
    local dir="$TEST_TMPDIR/role-follower"
    ( source "$LOCK_LIB"; write_role "$dir" follower "cc-2" "" )
    local out
    out=$( source "$LOCK_LIB"; read_role "$dir" "cc-2" "" )
    assert_eq "follower" "$out" "write_role follower → read_role returns follower"
}
run_test "roundtrip: follower" test_follower_roundtrip

test_creates_claude_dir() {
    local dir="$TEST_TMPDIR/role-mkdir"   # note: .claude does NOT exist yet
    ( source "$LOCK_LIB"; write_role "$dir" leader "cc-mk" "" )
    assert_file_exists "$dir/.claude/.session-role.cc-mk" "write_role creates .claude/ if missing"
}
run_test "write_role creates .claude/" test_creates_claude_dir

# ── identity key fallback ────────────────────────────────────────────────────

test_afleet_fallback() {
    # cc id empty → falls back to the afleet id as the marker key.
    local dir="$TEST_TMPDIR/role-afleet"
    ( source "$LOCK_LIB"; write_role "$dir" leader "" "af-9" )
    local out
    out=$( source "$LOCK_LIB"; read_role "$dir" "" "af-9" )
    assert_eq "leader" "$out" "empty cc id falls back to afleet id for the marker key"
}
run_test "identity: afleet fallback when cc empty" test_afleet_fallback

test_both_empty_no_marker() {
    # No stable id → degraded mode: write NOTHING (avoids a shared-slot collision
    # between a leader and a follower that both have empty ids). Shutdown then
    # falls back to lock ownership instead of a (possibly wrong) shared marker.
    local dir="$TEST_TMPDIR/role-noid"
    mkdir -p "$dir/.claude"
    local rc=0
    ( source "$LOCK_LIB"; write_role "$dir" leader "" "" ) || rc=$?
    assert_neq "0" "$rc" "write_role refuses (rc 1) when no stable id is available"
    local n
    n=$(find "$dir/.claude" -name '.session-role.*' 2>/dev/null | wc -l)
    assert_eq "0" "$n" "no marker file written when both ids are empty"
}
run_test "identity: both ids empty → no marker" test_both_empty_no_marker

# ── validation ───────────────────────────────────────────────────────────────

test_rejects_bad_role() {
    local dir="$TEST_TMPDIR/role-bad"
    mkdir -p "$dir/.claude"
    local rc=0
    ( source "$LOCK_LIB"; write_role "$dir" boss "cc-x" "" ) || rc=$?
    assert_neq "0" "$rc" "write_role rejects a role that is not leader|follower"
    local n
    n=$(find "$dir/.claude" -name '.session-role.*' 2>/dev/null | wc -l)
    assert_eq "0" "$n" "invalid role writes no marker"
}
run_test "validation: rejects non leader|follower role" test_rejects_bad_role

test_read_corrupt_returns_nonzero() {
    local dir="$TEST_TMPDIR/role-corrupt"
    mkdir -p "$dir/.claude"
    printf 'garbage\n' > "$dir/.claude/.session-role.cc-c"
    local rc=0
    ( source "$LOCK_LIB"; read_role "$dir" "cc-c" "" ) >/dev/null 2>&1 || rc=$?
    assert_neq "0" "$rc" "read_role rejects a marker whose body is not leader|follower"
}
run_test "validation: corrupt marker body → rc 1" test_read_corrupt_returns_nonzero

test_read_missing_returns_nonzero() {
    local dir="$TEST_TMPDIR/role-missing"
    mkdir -p "$dir/.claude"
    local rc=0
    ( source "$LOCK_LIB"; read_role "$dir" "cc-none" "" ) >/dev/null 2>&1 || rc=$?
    assert_neq "0" "$rc" "read_role returns non-zero when no marker exists"
}
run_test "validation: missing marker → rc 1" test_read_missing_returns_nonzero

# ── parallel sessions coexist ────────────────────────────────────────────────

test_parallel_markers_coexist() {
    local dir="$TEST_TMPDIR/role-parallel"
    ( source "$LOCK_LIB"; write_role "$dir" leader   "cc-A" "" )
    ( source "$LOCK_LIB"; write_role "$dir" follower "cc-B" "" )
    local a b
    a=$( source "$LOCK_LIB"; read_role "$dir" "cc-A" "" )
    b=$( source "$LOCK_LIB"; read_role "$dir" "cc-B" "" )
    assert_eq "leader:follower" "$a:$b" "two sessions keep independent role markers"
}
run_test "parallel: distinct markers per session id" test_parallel_markers_coexist

# ── clear ────────────────────────────────────────────────────────────────────

test_clear_removes_marker() {
    local dir="$TEST_TMPDIR/role-clear"
    ( source "$LOCK_LIB"; write_role "$dir" leader "cc-cl" "" )
    ( source "$LOCK_LIB"; clear_role "$dir" "cc-cl" "" )
    assert_file_not_exists "$dir/.claude/.session-role.cc-cl" "clear_role removes this session's marker"
}
run_test "clear: removes marker" test_clear_removes_marker

test_clear_missing_is_noop() {
    local dir="$TEST_TMPDIR/role-clear-noop"
    mkdir -p "$dir/.claude"
    local rc=0
    ( source "$LOCK_LIB"; clear_role "$dir" "cc-gone" "" ) || rc=$?
    assert_eq "0" "$rc" "clear_role is a safe no-op when there is no marker"
}
run_test "clear: no marker is a safe no-op" test_clear_missing_is_noop

# ── path safety (no traversal via a hostile id) ──────────────────────────────

test_id_sanitized_no_traversal() {
    local dir="$TEST_TMPDIR/role-safe"
    # A hostile id with slashes/dots must not escape .claude/ — it is sanitized to
    # a flat filename, and the same sanitized key must round-trip.
    ( source "$LOCK_LIB"; write_role "$dir" leader 'cc/../../evil' "" )
    # Nothing created outside the project's .claude/
    assert_file_not_exists "$TEST_TMPDIR/evil" "hostile id does not write outside .claude/"
    local out
    out=$( source "$LOCK_LIB"; read_role "$dir" 'cc/../../evil' "" )
    assert_eq "leader" "$out" "sanitized hostile id still round-trips consistently"
}
run_test "path safety: hostile id sanitized, no traversal" test_id_sanitized_no_traversal

# ── CFG-468 Defect E: role-marker garbage collection ─────────────────────────
# Nothing ever removed these markers. Measured in the live repo on 2026-08-23:
# 12 markers, oldest dated Jul 7, five of them test artefacts written into the
# live project by suites that used non-UUID ids. A marker whose session is long
# gone is not just clutter — it is a stale claim about who holds this project,
# in the same family as the lock_info/check_lock disagreement (CFG-533).
#
#   gc_roles <project_dir> [max_age_days] [keep_cc_sid] [keep_afleet_sid]
# Removes ONLY .claude/.session-role.* older than max_age_days (default 7), and
# never the caller's own marker whatever its age.

# Guard the premise: without this, a missing gc_roles makes the "keeps"/"never
# removes"/"touches nothing" tests pass vacuously — a check that cannot see the
# thing it checks.
_require_gc() {
    ( source "$LOCK_LIB"; declare -F gc_roles >/dev/null ) \
        || { printf "    PREMISE FAILED: gc_roles is not defined\n"; return 1; }
}

_mk_role() {   # <dir> <id> <days-old>
    local dir="$1" id="$2" days="$3"
    mkdir -p "$dir/.claude"
    printf 'leader\n' > "$dir/.claude/.session-role.$id"
    touch -d "$days days ago" "$dir/.claude/.session-role.$id"
}

test_gc_removes_expired() {
    _require_gc || return 1
    local dir="$TEST_TMPDIR/gc1"
    _mk_role "$dir" "old-uuid" 30
    ( source "$LOCK_LIB"; gc_roles "$dir" 7 "keep-me" "" )
    assert_file_not_exists "$dir/.claude/.session-role.old-uuid" "a 30-day-old marker is collected"
}
run_test "gc_roles: removes markers past the age threshold" test_gc_removes_expired

test_gc_keeps_fresh() {
    _require_gc || return 1
    local dir="$TEST_TMPDIR/gc2"
    _mk_role "$dir" "recent-uuid" 1
    ( source "$LOCK_LIB"; gc_roles "$dir" 7 "keep-me" "" )
    assert_file_exists "$dir/.claude/.session-role.recent-uuid" "a 1-day-old marker is kept"
}
run_test "gc_roles: keeps markers inside the threshold" test_gc_keeps_fresh

test_gc_never_removes_own_marker() {
    _require_gc || return 1
    local dir="$TEST_TMPDIR/gc3"
    _mk_role "$dir" "mine" 90            # our own id, but ancient (long-running session)
    ( source "$LOCK_LIB"; gc_roles "$dir" 7 "mine" "" )
    assert_file_exists "$dir/.claude/.session-role.mine" "the caller's OWN marker survives regardless of age"
}
run_test "gc_roles: never collects the caller's own marker" test_gc_never_removes_own_marker

test_gc_touches_nothing_else() {
    _require_gc || return 1
    local dir="$TEST_TMPDIR/gc4"
    mkdir -p "$dir/.claude"
    printf '{}\n'      > "$dir/.claude/.session-lock"
    printf '{}\n'      > "$dir/.claude/settings.local.json"
    printf 'x\n'       > "$dir/.claude/.session-rolexyz"     # near-miss name, not a marker
    touch -d "90 days ago" "$dir/.claude/.session-lock" "$dir/.claude/settings.local.json" "$dir/.claude/.session-rolexyz"
    ( source "$LOCK_LIB"; gc_roles "$dir" 7 "mine" "" )
    assert_file_exists "$dir/.claude/.session-lock"          ".session-lock is never touched" \
      && assert_file_exists "$dir/.claude/settings.local.json"  "settings.local.json is never touched" \
      && assert_file_exists "$dir/.claude/.session-rolexyz"     "a near-miss filename is never touched"
}
run_test "gc_roles: only ever removes .session-role.* markers" test_gc_touches_nothing_else

test_gc_missing_dir_is_noop() {
    _require_gc || return 1
    local rc=0
    ( source "$LOCK_LIB"; gc_roles "$TEST_TMPDIR/does-not-exist" 7 "mine" "" ) || rc=$?
    assert_eq "0" "$rc" "a missing project dir is a silent no-op, never an error"
}
run_test "gc_roles: missing directory is a safe no-op" test_gc_missing_dir_is_noop

test_write_role_collects_on_the_way_in() {
    # GC must be automatic — a cleanup nobody calls is the state we are already in.
    local dir="$TEST_TMPDIR/gc6"
    _mk_role "$dir" "ancient" 60
    ( source "$LOCK_LIB"; write_role "$dir" leader "fresh-sid" "" )
    assert_file_not_exists "$dir/.claude/.session-role.ancient" "write_role collects expired markers" \
      && assert_file_exists "$dir/.claude/.session-role.fresh-sid" "write_role still writes its own marker"
}
run_test "write_role: garbage-collects expired markers automatically" test_write_role_collects_on_the_way_in

suite_summary
