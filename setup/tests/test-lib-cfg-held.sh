#!/usr/bin/env bash
# Tests for global/hooks/lib-cfg-held.sh (CFG-965): the SessionEnd hook's owner
# verdict for the config repo — "is it held by a DIFFERENT live session?" — and
# the two things that verdict must never do: fail open on an unusable check_lock
# (SF-1), or read an unexpected check_lock result as "free".
#
# check_lock (setup/scripts/session-lock.sh): 0 free, 1 ours, 2 another live
# session here, 3 another machine, 4 cannot determine. The library maps 0/1 to
# "not held", 2/3 to "held", and EVERYTHING ELSE to "held, recorded as unknown".
set -euo pipefail
source "$(dirname "$0")/test-helpers.sh"

LIB="$REPO_ROOT/global/hooks/lib-cfg-held.sh"

suite_header "lib-cfg-held.sh (CFG-965: owner verdict for the config repo, fail closed)"

# Run _cfg_held_probe in a subshell with the library loaded against a scratch
# config repo. <rc> = what the stubbed check_lock returns, or `none` for no
# check_lock at all (and no git repo, so HEAD's copy is unavailable too).
# Prints "held=<0|1> unknown=<drift-log lines saying unknown> calls=<check_lock calls>".
_probe() {   # <rc|none> [same|other] [lock|nolock]
    local rc="$1" mode="${2:-other}" lock="${3:-nolock}"
    local cfg="$TEST_TMPDIR/cfg" orig="$TEST_TMPDIR/other"
    mkdir -p "$cfg/.claude" "$orig" "$TEST_TMPDIR/home"
    rm -f "$cfg/.sync-warnings.log" "$cfg/.claude/.session-lock" "$TEST_TMPDIR/calls"
    [[ "$lock" == lock ]] && echo '{"machine":"x","pid":1,"sessionId":"s","timestamp":"t","user":"u"}' > "$cfg/.claude/.session-lock"
    [[ "$mode" == same ]] && orig="$cfg"
    (
        CONFIG_REPO="$cfg" ORIGINAL_DIR="$orig" HOME="$TEST_TMPDIR/home"
        _shutdown_progress() { :; }
        if [[ "$rc" != none ]]; then
            eval "check_lock() { echo called >> '$TEST_TMPDIR/calls'; return $rc; }"
        fi
        source "$LIB"
        _cfg_held_probe
        # grep -c prints nothing for a missing file (and "0", rc 1, for a file
        # with no match): normalise both to a number.
        u=$(grep -c unknown "$cfg/.sync-warnings.log" 2>/dev/null); c=$(grep -c called "$TEST_TMPDIR/calls" 2>/dev/null)
        printf 'held=%s unknown=%s calls=%s\n' "$_CFG_HELD_BY_OTHER" "${u:-0}" "${c:-0}"
    )
}

test_rc0_and_rc1_are_not_held() {
    local r0 r1
    r0=$(_probe 0); r1=$(_probe 1)
    echo "    measured: rc0 -> $r0; rc1 -> $r1"
    assert_contains "$r0" "held=0" "check_lock 0 (free) ⇒ not held" || return 1
    assert_contains "$r1" "held=0" "check_lock 1 (ours) ⇒ not held" || return 1
    assert_contains "$r1" "unknown=0" "nothing recorded for a clean verdict"
}
run_test "probe: check_lock 0 and 1 ⇒ not held, nothing recorded" test_rc0_and_rc1_are_not_held

test_rc2_and_rc3_are_held_silently() {
    local r2 r3
    r2=$(_probe 2); r3=$(_probe 3)
    echo "    measured: rc2 -> $r2; rc3 -> $r3"
    assert_contains "$r2" "held=1" "check_lock 2 (another live session here) ⇒ held" || return 1
    assert_contains "$r3" "held=1" "check_lock 3 (another machine) ⇒ held" || return 1
    assert_contains "$r2" "unknown=0" "a known holder is not an unknown state" || return 1
    assert_contains "$r3" "unknown=0" "a known holder is not an unknown state"
}
run_test "probe: check_lock 2 and 3 ⇒ held, no unknown record" test_rc2_and_rc3_are_held_silently

test_rc4_is_held_and_recorded() {
    local r; r=$(_probe 4)
    echo "    measured: $r"
    assert_contains "$r" "held=1" "check_lock 4 (cannot determine) ⇒ held (fail closed)" || return 1
    assert_contains "$r" "unknown=1" "and recorded as unknown for the next SessionStart"
}
run_test "probe: check_lock 4 ⇒ held, recorded as unknown" test_rc4_is_held_and_recorded

test_unexpected_rc_is_held_and_recorded() {
    # 127 is what a missing check_lock returns from a subshell; 7 is nothing
    # the library defines. Neither may read as "free".
    local r127 r7
    r127=$(_probe 127); r7=$(_probe 7)
    echo "    measured: rc127 -> $r127; rc7 -> $r7"
    assert_contains "$r127" "held=1" "an unexpected result (127) ⇒ held" || return 1
    assert_contains "$r127" "unknown=1" "and recorded" || return 1
    assert_contains "$r7" "held=1" "an unexpected result (7) ⇒ held" || return 1
    assert_file_contains "$TEST_TMPDIR/cfg/.sync-warnings.log" "check_lock=7" "the record carries the result it could not classify"
}
run_test "probe: any other check_lock result ⇒ held, recorded with the result" test_unexpected_rc_is_held_and_recorded

test_rc6_is_held_with_the_format_reason() {
    # 6 = a lock is present that HEAD's library cannot read (a newer library
    # wrote it): held, recorded with that reason — never "corrupt, cleaned".
    local r; r=$(_probe 6)
    echo "    measured: $r"
    assert_contains "$r" "held=1" "check_lock 6 ⇒ held" || return 1
    assert_contains "$r" "unknown=1" "and recorded" || return 1
    assert_file_contains "$TEST_TMPDIR/cfg/.sync-warnings.log" "cannot read (empty, corrupt, or a newer format)" "the record names the three possibilities without guessing" || return 1
    assert_file_contains "$TEST_TMPDIR/cfg/.sync-warnings.log" "force_release" "and says how to clear it once no cfg session is live"
}
run_test "probe: check_lock 6 (lock HEAD's library cannot read) ⇒ held, format reason recorded" test_rc6_is_held_with_the_format_reason

test_no_check_lock_anywhere() {
    # No live check_lock and no git repo to take HEAD's copy from (rc 5 inside
    # the library). With a lock present: fail closed and say so. Without one:
    # nothing to be closed about and no scan possible — not held.
    local with without
    # The lock-less probe first: each probe starts from a fresh drift log, and
    # the record asserted below is the lock-present probe's.
    without=$(_probe none other nolock); with=$(_probe none other lock)
    echo "    measured: lock -> $with; no lock -> $without"
    assert_contains "$with" "held=1" "no usable check_lock + a lock present ⇒ held" || return 1
    assert_contains "$with" "unknown=1" "recorded as unknown" || return 1
    assert_file_contains "$TEST_TMPDIR/cfg/.sync-warnings.log" "check_lock unavailable" "the record says the library was unusable" || return 1
    assert_contains "$without" "held=0" "no usable check_lock + no lock ⇒ not held"
}
run_test "probe: no usable check_lock ⇒ held only when a lock file exists" test_no_check_lock_anywhere

test_same_dir_asks_only_with_a_lock_present() {
    # ORIGINAL_DIR == CONFIG_REPO: a genuine leader released its own lock in
    # Phase -1, so with no lock the project is its own and check_lock is not
    # even asked; with a lock still there, it is.
    local without with
    without=$(_probe 2 same nolock); with=$(_probe 2 same lock)
    echo "    measured: no lock -> $without; lock -> $with"
    assert_contains "$without" "calls=0" "no lock ⇒ check_lock not called" || return 1
    assert_contains "$without" "held=0" "no lock ⇒ not held" || return 1
    assert_contains "$with" "calls=1" "lock present ⇒ check_lock asked" || return 1
    assert_contains "$with" "held=1" "and its foreign verdict taken"
}
run_test "probe: the project IS the config repo ⇒ check_lock only when a lock is still present" test_same_dir_asks_only_with_a_lock_present

test_unknown_is_recorded_once_across_probes() {
    local cfg="$TEST_TMPDIR/cfg" n
    mkdir -p "$cfg" "$TEST_TMPDIR/other" "$TEST_TMPDIR/home"
    n=$(
        CONFIG_REPO="$cfg" ORIGINAL_DIR="$TEST_TMPDIR/other" HOME="$TEST_TMPDIR/home"
        _shutdown_progress() { :; }
        check_lock() { return 4; }
        source "$LIB"
        _cfg_held_probe; _cfg_held_probe
        grep -c unknown "$cfg/.sync-warnings.log" 2>/dev/null || true
    )
    assert_eq "1" "$n" "two probes of the same unknown state leave one record (measured $n)"
}
run_test "probe: the unknown record is written once, however often the probe runs" test_unknown_is_recorded_once_across_probes

test_unknown_record_is_stashed_while_a_drift_log_reset_is_pending() {
    # config-auto-sync.sh takes the verdict BEFORE its Phase 0.7 rewrites the
    # drift log from scratch. With the reset announced, the record waits in
    # the stash and lands only on the flush — so the rewrite cannot erase it.
    local cfg="$TEST_TMPDIR/cfg" out
    mkdir -p "$cfg" "$TEST_TMPDIR/other" "$TEST_TMPDIR/home"
    out=$(
        CONFIG_REPO="$cfg" ORIGINAL_DIR="$TEST_TMPDIR/other" HOME="$TEST_TMPDIR/home"
        _shutdown_progress() { :; }
        check_lock() { return 4; }
        source "$LIB"
        _CFG_DRIFT_LOG_RESET_PENDING=1
        _cfg_held_probe
        b=$(grep -c unknown "$cfg/.sync-warnings.log" 2>/dev/null); b=${b:-0}
        rm -f "$cfg/.sync-warnings.log"      # what Phase 0.7 does with no drift
        _cfg_held_flush_record
        a=$(grep -c unknown "$cfg/.sync-warnings.log" 2>/dev/null); a=${a:-0}
        _cfg_held_flush_record
        c=$(grep -c unknown "$cfg/.sync-warnings.log" 2>/dev/null); c=${c:-0}
        printf 'held=%s before=%s after=%s again=%s\n' "$_CFG_HELD_BY_OTHER" "$b" "$a" "$c"
    )
    echo "    measured: $out"
    assert_contains "$out" "held=1" "the verdict is taken at once" || return 1
    assert_contains "$out" "before=0" "nothing is written while the reset is pending" || return 1
    assert_contains "$out" "after=1" "the flush writes the stashed record" || return 1
    assert_contains "$out" "again=1" "a second flush writes nothing more"
}
run_test "probe: with a drift-log reset pending, the unknown record waits for the flush" test_unknown_record_is_stashed_while_a_drift_log_reset_is_pending

# ── _cfg_held_check_lock: live library first, HEAD's copy second, 5 otherwise ─

_mk_repo_with_head_lib() {   # <repo> <library body>
    mkdir -p "$1/setup/scripts"
    printf '%s\n' "$2" > "$1/setup/scripts/session-lock.sh"
    git -C "$1" init -q -b main
    git -C "$1" config user.email t@t.t
    git -C "$1" config user.name t
    git -C "$1" add -A
    git -C "$1" commit -q -m "lib at HEAD"
}

# SF-1 residual (reviewer, 2026-11-11): the live check_lock can parse and run while
# a helper it calls is mid-rename, and then its dead-pid branch deletes the lock
# and answers "free". So HEAD's copy is asked FIRST whenever it is obtainable;
# the live copy is only for a repo with no HEAD copy at all.
test_check_lock_prefers_head_copy_over_live() {
    local repo="$TEST_TMPDIR/repo" rc=0
    _mk_repo_with_head_lib "$repo" 'check_lock() { return 2; }'
    (
        _shutdown_progress() { :; }
        check_lock() { return 3; }
        source "$LIB"
        _cfg_held_check_lock "$repo"
    ) || rc=$?
    assert_eq "2" "$rc" "HEAD's copy answers although a live check_lock is defined (measured rc=$rc)"
}
run_test "_cfg_held_check_lock: HEAD's copy wins over a live check_lock (SF-1 residual)" test_check_lock_prefers_head_copy_over_live

test_check_lock_uses_live_only_when_head_unobtainable() {
    local dir="$TEST_TMPDIR/plain" rc=0
    mkdir -p "$dir"
    (
        _shutdown_progress() { :; }
        check_lock() { return 3; }
        source "$LIB"
        _cfg_held_check_lock "$dir"
    ) || rc=$?
    assert_eq "3" "$rc" "with no HEAD copy to take, the live check_lock is all there is (measured rc=$rc)"
}
run_test "_cfg_held_check_lock: the live check_lock is used only when HEAD's copy is unobtainable" test_check_lock_uses_live_only_when_head_unobtainable

test_check_lock_broken_head_copy_does_not_fall_back_to_live() {
    local repo="$TEST_TMPDIR/repo" rc=0
    _mk_repo_with_head_lib "$repo" $'x() { :; }\nif then\ncheck_lock() { return 2; }'
    (
        _shutdown_progress() { :; }
        check_lock() { return 0; }
        source "$LIB"
        _cfg_held_check_lock "$repo"
    ) || rc=$?
    assert_eq "5" "$rc" "an obtainable but broken HEAD copy is 5 — the live copy is not consulted (measured rc=$rc)"
}
run_test "_cfg_held_check_lock: an obtainable but broken HEAD copy is 5, never the live verdict" test_check_lock_broken_head_copy_does_not_fall_back_to_live

test_check_lock_unreadable_lock_is_6_and_kept() {
    # The REAL library at HEAD, a lock it cannot parse on disk: before the
    # check_lock call its _read_lock is asked, and a failure is 6 — the lock
    # is left alone, never cleaned as corrupt.
    local repo="$TEST_TMPDIR/repo" rc=0
    _mk_repo_with_head_lib "$repo" "$(cat "$REPO_ROOT/setup/scripts/session-lock.sh")"
    mkdir -p "$repo/.claude"
    printf 'lockfmt=2\nmachine=x\npid=1\nsessionId=s\n' > "$repo/.claude/.session-lock"
    (
        _shutdown_progress() { :; }
        source "$LIB"
        _cfg_held_check_lock "$repo"
    ) || rc=$?
    assert_eq "6" "$rc" "a lock HEAD's _read_lock cannot read is 6 (measured rc=$rc)" || return 1
    assert_file_exists "$repo/.claude/.session-lock" "and the lock is not deleted"
}
run_test "_cfg_held_check_lock: a lock HEAD's library cannot read is 6 and is left in place" test_check_lock_unreadable_lock_is_6_and_kept

test_check_lock_renamed_pid_field_is_6_and_kept() {
    # Round 4: HEAD's _read_lock accepts ANY JSON (python/jq branches) and
    # leaves _LOCK_PID empty for an unknown pid field; "readable" must also
    # mean machine set and pid numeric, or check_lock reads "" as a dead pid.
    local repo="$TEST_TMPDIR/repo" rc=0
    _mk_repo_with_head_lib "$repo" "$(cat "$REPO_ROOT/setup/scripts/session-lock.sh")"
    mkdir -p "$repo/.claude"
    printf '{"machine":"%s","lockPid":%s,"sessionId":"s","timestamp":"t","user":"u","ccSessionId":"c"}\n' "$(hostname)" "$$" > "$repo/.claude/.session-lock"
    (
        _shutdown_progress() { :; }
        source "$LIB"
        _cfg_held_check_lock "$repo"
    ) || rc=$?
    assert_eq "6" "$rc" "valid JSON with the pid under an unknown name is 6, not a dead-pid verdict (measured rc=$rc)" || return 1
    assert_file_exists "$repo/.claude/.session-lock" "and the lock is not deleted"
}
run_test "_cfg_held_check_lock: a JSON lock without a numeric pid HEAD knows is 6 and is left in place" test_check_lock_renamed_pid_field_is_6_and_kept

test_check_lock_ignores_inherited_git_env() {
    # A GIT_DIR / GIT_WORK_TREE inherited from the environment points git at
    # another repo; `git -C <repo> show HEAD:…` must still read THIS repo.
    local repo="$TEST_TMPDIR/repo" rc=0
    _mk_repo_with_head_lib "$repo" 'check_lock() { return 2; }'
    (
        export GIT_DIR="$TEST_TMPDIR/not-a-repo" GIT_WORK_TREE="$TEST_TMPDIR/not-a-tree" GIT_INDEX_FILE="$TEST_TMPDIR/not-an-index"
        _shutdown_progress() { :; }
        source "$LIB"
        _cfg_held_check_lock "$repo"
    ) || rc=$?
    assert_eq "2" "$rc" "HEAD's copy is read although GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE point elsewhere (measured rc=$rc)"
}
run_test "_cfg_held_check_lock: inherited GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE do not hide HEAD's copy" test_check_lock_ignores_inherited_git_env

test_check_lock_falls_back_to_head_copy() {
    local repo="$TEST_TMPDIR/repo" rc=0
    _mk_repo_with_head_lib "$repo" 'check_lock() { return 2; }'
    # The working tree's copy is mid-edit: check_lock renamed.
    printf 'check_lock_wip() { return 0; }\n' > "$repo/setup/scripts/session-lock.sh"
    (
        _shutdown_progress() { :; }
        source "$LIB"
        _cfg_held_check_lock "$repo"
    ) || rc=$?
    assert_eq "2" "$rc" "with no live check_lock, HEAD's copy of session-lock.sh answers (measured rc=$rc)"
}
run_test "_cfg_held_check_lock: falls back to HEAD's session-lock.sh (SF-1)" test_check_lock_falls_back_to_head_copy

test_check_lock_head_copy_broken_is_5() {
    local repo="$TEST_TMPDIR/repo" rc=0
    _mk_repo_with_head_lib "$repo" $'x() { :; }\nif then\ncheck_lock() { return 2; }'
    (
        _shutdown_progress() { :; }
        source "$LIB"
        _cfg_held_check_lock "$repo"
    ) || rc=$?
    assert_eq "5" "$rc" "a HEAD copy with a syntax error before check_lock yields 5, never a verdict (measured rc=$rc)"
}
run_test "_cfg_held_check_lock: a broken HEAD copy is 5 (unavailable), not a verdict" test_check_lock_head_copy_broken_is_5

test_check_lock_no_git_is_5() {
    local dir="$TEST_TMPDIR/plain" rc=0
    mkdir -p "$dir"
    (
        _shutdown_progress() { :; }
        source "$LIB"
        _cfg_held_check_lock "$dir"
    ) || rc=$?
    assert_eq "5" "$rc" "no live check_lock and no git history ⇒ 5 (measured rc=$rc)"
}
run_test "_cfg_held_check_lock: no library anywhere is 5" test_check_lock_no_git_is_5

# ── _cfg_defer_audit: the audit log for expected skips ───────────────────────

test_defer_audit_line_shape() {
    local log="$TEST_TMPDIR/home/.claude/logs/template-push-deferred.log"
    mkdir -p "$TEST_TMPDIR/home" "$TEST_TMPDIR/life"
    (
        CONFIG_REPO="$TEST_TMPDIR/cfg" ORIGINAL_DIR="$TEST_TMPDIR/life" HOME="$TEST_TMPDIR/home"
        _shutdown_progress() { :; }
        source "$LIB"
        _cfg_defer_audit DEPLOY_DEFERRED "config repo held by another live session"
    )
    assert_file_exists "$log" "the audit log is created under \$HOME/.claude/logs" || return 1
    assert_file_contains "$log" "DEPLOY_DEFERRED: config repo held by another live session (shutdown of life)" "tag, text and the shutting-down project"
}
run_test "_cfg_defer_audit: one line, tagged, naming the project that shut down" test_defer_audit_line_shape

suite_summary
