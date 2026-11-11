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

# A lock held by a DIFFERENT live session. Since CFG-723 acquire_lock records the
# acquirer's resolved CC pid; called from this test process inside a real Claude
# Code session that is THIS session's own CC, so the "foreign" lock read as ours
# (check_lock rc 1) and the guard let the rotation through. Record a live pid
# outside our ancestry instead — the foreign leader's launcher shell, which is
# what the af flow records (afleet passes its own non-CC pid as self_pid). The
# sleepers are killed by the EXIT trap.
_FOREIGN_LOCK_PIDS=()
_kill_foreign_locks() { local p; for p in "${_FOREIGN_LOCK_PIDS[@]}"; do kill "$p" 2>/dev/null || true; done; }
trap '_kill_foreign_locks' EXIT
_make_foreign_lock() {
    local fpid
    sleep 120 & fpid=$!
    _FOREIGN_LOCK_PIDS+=("$fpid")
    ( source "$LOCK_LIB"; acquire_lock "$1" "af-leader" "" "$fpid" >/dev/null 2>&1 )
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
    # The lock pid here (this test shell) is not an ancestor of any CC, so this
    # pins the DEGRADED contract (CFG-672): with no resolvable own CC pid the
    # afleet id is the proof. The ancestry proof of the real af launch shape is
    # test_af_leader_rotates_by_ancestry below.
    ( source "$LOCK_LIB"; _write_lock "$dir/.claude/.session-lock" "af-mine" "" "$$" )
    local rc=0
    _CC_SELF_PID="" AFLEET_SESSION_ID="af-mine" bash "$ROTATE" "$dir" >/dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" "the proven leader rotates on the BARE command — no --owner-verified needed (measured rc=$rc)" || return 1
    assert_file_exists "$dir/session-history.md" "rotation happened for the proven owner"
}
run_test "CFG-536: leader rotates without --owner-verified (degraded matcher: afleet id)" test_leader_rotates_on_bare_command

# ── CFG-672: the real process shapes, through the real rotate-session.sh ──────
# Fake CC processes made with `exec -a` and _CC_PROC_RE pointed at them, so any
# real CC running this suite is invisible (same technique as test-07b-nested-role).
#   af:   afleet-shell (writes the lock with ITS pid) → fakecc-leader → rotate
#   tmux: lock pid alive elsewhere, inherited afleet id  → fakecc-leader → rotate
_FAKE_CC_RE='(^|/)fakecc-leader([[:space:]]|$)'
_mk_fake_cc() {
    cat > "$TEST_TMPDIR/fakecc-leader.sh" << 'EOF'
#!/usr/bin/env bash
exec -a fakecc-leader bash -c 'bash "$@"; rc=$?; exit $rc' _ "$@"
EOF
    cat > "$TEST_TMPDIR/afleet-shell.sh" << EOF
#!/usr/bin/env bash
source "$LOCK_LIB"
_write_lock "\$1/.claude/.session-lock" "\$2" "" "\$\$"
shift 2
bash "\$@"; rc=\$?; exit \$rc
EOF
}

test_af_leader_rotates_by_ancestry() {
    local dir="$TEST_TMPDIR/proj-af-anc"
    _make_project "$dir"; _mk_fake_cc
    local rc=0
    _CC_PROC_RE="$_FAKE_CC_RE" AFLEET_SESSION_ID="af-mine" \
        bash "$TEST_TMPDIR/afleet-shell.sh" "$dir" "af-mine" "$TEST_TMPDIR/fakecc-leader.sh" "$ROTATE" "$dir" >/dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" "the af leader (launcher is CC's ancestor) rotates on the bare command (measured rc=$rc)" || return 1
    assert_file_exists "$dir/session-history.md" "rotation happened for the ancestry-proven owner"
}
run_test "CFG-672: af leader rotates via launcher ancestry" test_af_leader_rotates_by_ancestry

test_tmux_cc_with_inherited_afleet_id_refused() {
    local dir="$TEST_TMPDIR/proj-tmux"
    _make_project "$dir"; _mk_fake_cc
    sleep 120 & local lpid=$!      # the leader's launcher: alive, not our ancestor
    ( source "$LOCK_LIB"; _write_lock "$dir/.claude/.session-lock" "af-leader" "" "$lpid" )
    local rc=0
    _CC_PROC_RE="$_FAKE_CC_RE" AFLEET_SESSION_ID="af-leader" CC_SESSION_ID="cc-tmux" \
        bash "$TEST_TMPDIR/fakecc-leader.sh" "$ROTATE" "$dir" >/dev/null 2>&1 || rc=$?
    kill "$lpid" 2>/dev/null || true
    assert_eq "3" "$rc" "a tmux-launched CC with the inherited afleet id is refused (measured rc=$rc)" || return 1
    assert_file_not_exists "$dir/session-history.md" "no rotation happened for the tmux CC"
}
run_test "CFG-672: tmux-launched CC (inherited AFLEET_SESSION_ID) is refused" test_tmux_cc_with_inherited_afleet_id_refused

test_ivbook_same_cc_id_different_pid_is_owner() {
    # CFG-454 field case (ivbook 2026-08-11): the lock carried the live
    # session's ccSessionId and its role marker said leader, but ONLY the pid
    # differed (the recorded pid had changed since the lock was written) —
    # check_lock discriminated on pid and refused the leader as a follower.
    # The ccSessionId must prove ownership before any pid fallback.
    local dir="$TEST_TMPDIR/proj-ivbook"
    _make_project "$dir"; _mk_fake_cc
    sleep 120 & local lpid=$!      # alive, unrelated to our tree: the "changed" pid
    ( source "$LOCK_LIB"; _write_lock "$dir/.claude/.session-lock" "af-mine" "cc-mine" "$lpid" )
    local rc=0
    _CC_PROC_RE="$_FAKE_CC_RE" CC_SESSION_ID="cc-mine" \
        bash "$TEST_TMPDIR/fakecc-leader.sh" "$ROTATE" "$dir" >/dev/null 2>&1 || rc=$?
    kill "$lpid" 2>/dev/null || true
    assert_eq "0" "$rc" "same ccSessionId, different pid ⇒ owner, rotates on the bare command (measured rc=$rc)" || return 1
    assert_file_exists "$dir/session-history.md" "rotation happened for the cc-id-proven owner"
}
run_test "CFG-454: same ccSessionId, different pid ⇒ owner, not follower (ivbook)" test_ivbook_same_cc_id_different_pid_is_owner

# ── CFG-454 ivbook, under the env production actually has ─────────────────────
# The test above injects CC_SESSION_ID, which only exists inside the SessionStart
# hook (config-check.sh exports it there). The ivbook refusal came from the
# agent running the bare `rotate-session.sh` through the Bash tool: Claude Code
# gives that subprocess its session id as CLAUDE_CODE_SESSION_ID and nothing
# else. These run the real rotate-session.sh with exactly that env.
_real_env() {   # <cc-id> <cmd...> — the Bash-tool env: CLAUDE_CODE_SESSION_ID only
    local ccid="$1"; shift
    env -u CC_SESSION_ID -u CLAUDE_SESSION_ID -u AFLEET_SESSION_ID \
        CLAUDE_CODE_SESSION_ID="$ccid" _CC_PROC_RE="$_FAKE_CC_RE" "$@"
}
_spawn_other_cc() {   # <dir> — a detached fake CC cwd'd in <dir>; echoes its pid
    local dir="$1" pf="$TEST_TMPDIR/other-cc.pid" i
    rm -f "$pf"
    ( cd "$dir" && setsid bash -c 'echo $$ > "$0"; exec -a fakecc-leader sleep 60' "$pf" ) \
        </dev/null >/dev/null 2>&1 &
    for i in $(seq 1 50); do
        if [[ -s "$pf" ]] && tr '\0' ' ' < "/proc/$(cat "$pf")/cmdline" 2>/dev/null | grep -q '^fakecc-leader'; then
            cat "$pf"; return 0
        fi
        sleep 0.1
    done
    return 1
}

test_ivbook_real_env_alive_unrelated_pid() {
    local dir="$TEST_TMPDIR/proj-ivbook-env"
    _make_project "$dir"; _mk_fake_cc
    sleep 120 & local lpid=$!      # alive, unrelated to our tree: the "changed" pid
    ( source "$LOCK_LIB"; _write_lock "$dir/.claude/.session-lock" "af-mine" "cc-mine" "$lpid" )
    local rc=0
    _real_env cc-mine bash "$TEST_TMPDIR/fakecc-leader.sh" "$ROTATE" "$dir" >/dev/null 2>&1 || rc=$?
    kill "$lpid" 2>/dev/null || true
    assert_eq "0" "$rc" "the leader (CLAUDE_CODE_SESSION_ID = lock ccSessionId) rotates on the bare command (measured rc=$rc)" || return 1
    assert_file_exists "$dir/session-history.md" "rotation happened for the cc-id-proven owner"
}
run_test "CFG-454: ivbook under the Bash-tool env (CLAUDE_CODE_SESSION_ID), live unrelated pid ⇒ owner" test_ivbook_real_env_alive_unrelated_pid

test_ivbook_real_env_dead_pid_follower_live() {
    # A direct launch records the SessionStart hook's pid, which is dead by the
    # time the session shuts down; a follower CC is live in the same project.
    local dir="$TEST_TMPDIR/proj-ivbook-dead"
    _make_project "$dir"; _mk_fake_cc
    true & local dpid=$!; wait "$dpid" 2>/dev/null || true
    ( source "$LOCK_LIB"; _write_lock "$dir/.claude/.session-lock" "af-mine" "cc-mine" "$dpid" )
    local fol; fol="$(_spawn_other_cc "$dir")" || { echo "could not spawn the follower CC" >&2; return 1; }
    local rc=0
    _real_env cc-mine bash "$TEST_TMPDIR/fakecc-leader.sh" "$ROTATE" "$dir" >/dev/null 2>&1 || rc=$?
    kill "$fol" 2>/dev/null || true
    assert_eq "0" "$rc" "dead recorded pid + live follower: the leader still rotates its own project (measured rc=$rc)" || return 1
    assert_file_exists "$dir/session-history.md" "rotation happened for the cc-id-proven owner" || return 1
    assert_file_exists "$dir/.claude/.session-lock" "the leader's lock was not removed by the ownership check"
}
run_test "CFG-454: ivbook under the Bash-tool env, dead recorded pid + live follower ⇒ owner" test_ivbook_real_env_dead_pid_follower_live

test_follower_real_env_dead_pid_leader_live_refused() {
    # Regression guard: the follower's own CLAUDE_CODE_SESSION_ID differs from
    # the lock's, the leader CC is live in the project ⇒ still refused.
    local dir="$TEST_TMPDIR/proj-follower-dead"
    _make_project "$dir"; _mk_fake_cc
    true & local dpid=$!; wait "$dpid" 2>/dev/null || true
    ( source "$LOCK_LIB"; _write_lock "$dir/.claude/.session-lock" "af-leader" "cc-leader" "$dpid" )
    local ldr; ldr="$(_spawn_other_cc "$dir")" || { echo "could not spawn the leader CC" >&2; return 1; }
    local rc=0
    _real_env cc-follower bash "$TEST_TMPDIR/fakecc-leader.sh" "$ROTATE" "$dir" >/dev/null 2>&1 || rc=$?
    kill "$ldr" 2>/dev/null || true
    assert_eq "3" "$rc" "a follower (own cc id differs) is refused while the leader CC is live (measured rc=$rc)" || return 1
    assert_file_not_exists "$dir/session-history.md" "no rotation happened for the follower"
}
run_test "CFG-454: follower under the Bash-tool env, dead recorded pid + live leader ⇒ refused" test_follower_real_env_dead_pid_leader_live_refused

test_tmux_job_with_inherited_claude_code_id_refused() {
    # A non-CC job in a tmux pane carries the tmux server's global env — the
    # CLAUDE_CODE_SESSION_ID of whichever CC started the server, e.g. the
    # leader's, even when a follower launched the job. No CC above it vouches
    # for that id, so it must not prove ownership.
    local dir="$TEST_TMPDIR/proj-tmux-job"
    _make_project "$dir"; _mk_fake_cc
    sleep 120 & local lpid=$!
    ( source "$LOCK_LIB"; _write_lock "$dir/.claude/.session-lock" "af-leader" "cc-leader" "$lpid" )
    local rc=0
    _real_env cc-leader bash "$ROTATE" "$dir" >/dev/null 2>&1 || rc=$?   # no fake CC above
    kill "$lpid" 2>/dev/null || true
    assert_eq "3" "$rc" "a job with no CC above it and an inherited CLAUDE_CODE_SESSION_ID is refused (measured rc=$rc)" || return 1
    assert_file_not_exists "$dir/session-history.md" "no rotation happened for the tmux job"
}
run_test "CFG-454: non-CC job with an inherited CLAUDE_CODE_SESSION_ID (tmux pane) ⇒ refused" test_tmux_job_with_inherited_claude_code_id_refused

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

# ── CFG-673 / GH#9: the bare command inside Claude Code's Bash sandbox ───────
# The sandbox's PID namespace hides every host process while /proc still
# exists, so the lock check sees no CC at all and every recorded pid reads
# dead. check_lock called that "stale": it deleted the live leader's lock and
# rotate-session.sh went on to rotate the leader's project. A blind scan must
# refuse instead (fail closed), keep the lock and say the state is unknown.
# _CC_PROC_RE is pointed at a name no process has: the sandbox's view.
_blind_env() {   # <cc-id> <cmd...> — Bash-tool env, nothing CC-shaped visible
    local ccid="$1"; shift
    env -u CC_SESSION_ID -u CLAUDE_SESSION_ID -u AFLEET_SESSION_ID -u _CC_SELF_PID \
        CLAUDE_CODE_SESSION_ID="$ccid" _CC_PROC_RE="(^|/)cfg673-no-such-cc-$$([[:space:]]|$)" "$@"
}

test_blind_scan_refuses_and_keeps_lock() {
    local dir="$TEST_TMPDIR/proj-blind"
    _make_project "$dir"
    true & local dpid=$!; wait "$dpid" 2>/dev/null || true   # the leader's pid, as the sandbox sees it
    ( source "$LOCK_LIB"; _write_lock "$dir/.claude/.session-lock" "af-leader" "cc-leader" "$dpid" )
    local rc=0 err
    err=$(_blind_env cc-follower bash "$ROTATE" "$dir" 2>&1 >/dev/null) || rc=$?
    assert_eq "3" "$rc" "a blind lock check refuses the rotation (measured rc=$rc)" || return 1
    assert_file_exists "$dir/.claude/.session-lock" "the lock is NOT deleted by a blind check" || return 1
    assert_file_contains "$dir/.claude/.session-lock" '"cc-leader"' "the lock still names the leader" || return 1
    assert_file_not_exists "$dir/session-history.md" "no rotation happened" || return 1
    assert_contains "$err" "unknown" "the refusal says the holder is unknown, not that another session was seen"
}
run_test "CFG-673: bare rotate with zero visible CC processes ⇒ refused as unknown, lock kept" test_blind_scan_refuses_and_keeps_lock

# ── CFG-965 SF-1: the guard must not fail open when check_lock is unavailable ─
# The guard sources session-lock.sh from the WORKING TREE beside it — the tree a
# cfg session is editing. A holder half-way through that file (check_lock
# renamed, a syntax error before it) left check_lock undefined; the subshell
# returned 127, which was neither 2/3 nor 4, and the guard rotated. Now: the
# live library when it carries check_lock, else HEAD's copy, and any result
# other than 0/1 refuses.

# A scratch config repo: rotate-session.sh, lib.sh and the REAL session-lock.sh
# committed at HEAD, so the guard runs from a directory with a git history.
_mk_guard_repo() {   # <repo>
    mkdir -p "$1/setup/scripts"
    cp "$REPO_ROOT/setup/lib.sh" "$1/setup/lib.sh"
    cp "$ROTATE" "$1/setup/scripts/rotate-session.sh"
    cp "$LOCK_LIB" "$1/setup/scripts/session-lock.sh"
    git -C "$1" init -q -b main
    git -C "$1" config user.email t@t.t
    git -C "$1" config user.name t
    git -C "$1" add -A
    git -C "$1" commit -q -m "baseline"
}
_rename_live_check_lock() {   # <repo> — the working tree's copy mid-edit
    sed 's/^check_lock() {/check_lock_wip() {/' "$LOCK_LIB" > "$1/setup/scripts/session-lock.sh"
    grep -q '^check_lock_wip() {' "$1/setup/scripts/session-lock.sh"
}

test_sf1_renamed_live_lib_refuses_foreign_lock() {
    local repo="$TEST_TMPDIR/repo" dir="$TEST_TMPDIR/proj-sf1-foreign" rc=0 err
    _mk_guard_repo "$repo"; _make_project "$dir"
    _rename_live_check_lock "$repo" || { echo "fixture: rename failed" >&2; return 1; }
    sleep 120 & local lpid=$!; _FOREIGN_LOCK_PIDS+=("$lpid")
    ( source "$LOCK_LIB"; _write_lock "$dir/.claude/.session-lock" "af-leader" "cc-leader" "$lpid" )
    err=$(AFLEET_SESSION_ID=af-mine CC_SESSION_ID=cc-mine bash "$repo/setup/scripts/rotate-session.sh" "$dir" 2>&1 >/dev/null) || rc=$?
    assert_eq "3" "$rc" "check_lock renamed in the working tree: HEAD's copy still refuses the foreign lock (measured rc=$rc)" || return 1
    assert_file_not_exists "$dir/session-history.md" "no rotation happened" || return 1
    assert_contains "$err" "held by another live session" "the refusal names a seen holder (check_lock 2), not an unusable library"
}
run_test "CFG-965 SF-1: check_lock renamed in the working tree ⇒ HEAD's copy refuses a foreign lock" test_sf1_renamed_live_lib_refuses_foreign_lock

test_sf1_renamed_live_lib_owner_rotates_via_head_copy() {
    # The fallback must resolve OWNERSHIP, not merely refuse: the proven leader
    # (degraded matcher, afleet id) rotates on the bare command although the
    # working tree's check_lock is mid-rename.
    local repo="$TEST_TMPDIR/repo" dir="$TEST_TMPDIR/proj-sf1-owner" rc=0
    _mk_guard_repo "$repo"; _make_project "$dir"
    _rename_live_check_lock "$repo" || { echo "fixture: rename failed" >&2; return 1; }
    ( source "$LOCK_LIB"; _write_lock "$dir/.claude/.session-lock" "af-mine" "" "$$" )
    _CC_SELF_PID="" AFLEET_SESSION_ID="af-mine" bash "$repo/setup/scripts/rotate-session.sh" "$dir" >/dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" "the owner is recognised through HEAD's copy and rotates (measured rc=$rc)" || return 1
    assert_file_exists "$dir/session-history.md" "rotation happened for the owner"
}
run_test "CFG-965 SF-1: check_lock renamed in the working tree ⇒ the owner still rotates through HEAD's copy" test_sf1_renamed_live_lib_owner_rotates_via_head_copy

test_sf1_no_usable_library_refuses_and_says_why() {
    # Neither the working tree nor HEAD yields a check_lock, and a lock is
    # present: refuse (exit 3) and name the library, never rotate.
    local repo="$TEST_TMPDIR/repo" dir="$TEST_TMPDIR/proj-sf1-none" rc=0 err
    mkdir -p "$repo/setup/scripts"
    cp "$REPO_ROOT/setup/lib.sh" "$repo/setup/lib.sh"
    cp "$ROTATE" "$repo/setup/scripts/rotate-session.sh"
    printf '_LOCK_SESSION=""\n_read_lock() { return 1; }\n' > "$repo/setup/scripts/session-lock.sh"
    git -C "$repo" init -q -b main
    git -C "$repo" config user.email t@t.t
    git -C "$repo" config user.name t
    git -C "$repo" add -A
    git -C "$repo" commit -q -m "no check_lock anywhere"
    _make_project "$dir"
    printf '{"machine":"x","pid":1,"sessionId":"s","timestamp":"t","user":"u"}\n' > "$dir/.claude/.session-lock"
    err=$(bash "$repo/setup/scripts/rotate-session.sh" "$dir" 2>&1 >/dev/null) || rc=$?
    assert_eq "3" "$rc" "no usable check_lock + a lock present ⇒ refused (measured rc=$rc)" || return 1
    assert_file_not_exists "$dir/session-history.md" "no rotation happened" || return 1
    assert_contains "$err" "check_lock" "the refusal names the lock check it could not run" || return 1
    assert_file_exists "$dir/.claude/.session-lock" "the lock is left in place"
}
run_test "CFG-965 SF-1: no usable session-lock.sh anywhere + a lock ⇒ refused, library named, lock kept" test_sf1_no_usable_library_refuses_and_says_why

# ── SF-1 residual: check_lock still defined, a helper it calls mid-rename ────
# With the live copy asked first, its check_lock ran, `_project_has_live_cc`
# returned 127 (false), and the dead-pid branch deleted the leader's lock and
# rotated the leader's project. HEAD's copy is asked first whenever it is
# obtainable. Shape of test_follower_real_env_dead_pid_leader_live_refused.
_rename_live_helper() {   # <repo> — check_lock intact, _project_has_live_cc renamed in the working tree
    sed 's/^_project_has_live_cc() {/_project_has_live_cc_wip() {/' "$LOCK_LIB" > "$1/setup/scripts/session-lock.sh"
    grep -q '^_project_has_live_cc_wip() {' "$1/setup/scripts/session-lock.sh"
}
_sf1_residual_rotate_case() {   # <renamed:yes|no> — prints "rc=<n> lock=<0|1> history=<0|1>"
    local repo="$TEST_TMPDIR/repo" dir="$TEST_TMPDIR/proj-sf1-residual" rc=0 lock=0 hist=0
    _mk_guard_repo "$repo"; _make_project "$dir"; _mk_fake_cc
    if [[ "$1" == yes ]]; then _rename_live_helper "$repo" || { echo "fixture: rename failed" >&2; return 1; }; fi
    true & local dpid=$!; wait "$dpid" 2>/dev/null || true
    ( source "$LOCK_LIB"; _write_lock "$dir/.claude/.session-lock" "af-leader" "cc-leader" "$dpid" )
    local ldr; ldr="$(_spawn_other_cc "$dir")" || { echo "could not spawn the leader CC" >&2; return 1; }
    _real_env cc-follower bash "$TEST_TMPDIR/fakecc-leader.sh" "$repo/setup/scripts/rotate-session.sh" "$dir" >/dev/null 2>&1 || rc=$?
    kill "$ldr" 2>/dev/null || true
    [[ -f "$dir/.claude/.session-lock" ]] && lock=1
    [[ -f "$dir/session-history.md" ]] && hist=1
    printf 'rc=%s lock=%s history=%s\n' "$rc" "$lock" "$hist"
}
_assert_sf1_residual_refused() {   # <result> <label>
    assert_contains "$1" "rc=3" "$2: refused (measured: $1)" || return 1
    assert_contains "$1" "lock=1" "$2: the leader's lock is kept" || return 1
    assert_contains "$1" "history=0" "$2: no rotation happened"
}
test_sf1_residual_rotate_control() {
    local r; r=$(_sf1_residual_rotate_case no)
    echo "    measured: $r"
    _assert_sf1_residual_refused "$r" "control (real live library)"
}
run_test "CFG-965 SF-1 residual control: dead-pid lock + live leader CC ⇒ refused through HEAD's copy" test_sf1_residual_rotate_control

test_sf1_residual_rotate_helper_renamed() {
    local r; r=$(_sf1_residual_rotate_case yes)
    echo "    measured: $r"
    _assert_sf1_residual_refused "$r" "_project_has_live_cc renamed in the working tree, check_lock intact"
}
run_test "CFG-965 SF-1 residual: a helper renamed in the working tree ⇒ still refused, lock kept" test_sf1_residual_rotate_helper_renamed

# ── Round 3: a lock HEAD's older library cannot read; inherited git env ──────
test_lock_head_library_cannot_read_refuses_and_keeps_it() {
    # HEAD's copy is asked first; a lock in a format it cannot parse (a newer
    # library wrote it) must be a refusal, never "corrupt — cleaned and rotated".
    local repo="$TEST_TMPDIR/repo" dir="$TEST_TMPDIR/proj-newer-lock" rc=0 err before
    _mk_guard_repo "$repo"; _make_project "$dir"
    printf 'lockfmt=2\nmachine=%s\npid=%s\nsessionId=af-leader\n' "$(hostname)" "$$" > "$dir/.claude/.session-lock"
    before=$(cat "$dir/.claude/.session-lock")
    err=$(bash "$repo/setup/scripts/rotate-session.sh" "$dir" 2>&1 >/dev/null) || rc=$?
    assert_eq "3" "$rc" "a lock HEAD's library cannot read ⇒ refused (measured rc=$rc)" || return 1
    assert_file_exists "$dir/.claude/.session-lock" "the lock is NOT deleted" || return 1
    assert_eq "$before" "$(cat "$dir/.claude/.session-lock")" "and is byte-identical" || return 1
    assert_file_not_exists "$dir/session-history.md" "no rotation happened" || return 1
    assert_contains "$err" "cannot read (empty, corrupt, or a newer format)" "the refusal names the three possibilities without guessing" || return 1
    assert_contains "$err" "force_release" "and says how to clear it once no session is live"
}
run_test "CFG-965: a lock in a format HEAD's library cannot read ⇒ refused, lock kept, reason named" test_lock_head_library_cannot_read_refuses_and_keeps_it

test_lock_with_renamed_pid_field_refuses_and_keeps_it() {
    # Round 4: valid JSON, live pid under a field name HEAD's library does not
    # know. _read_lock returns 0 with an empty pid; check_lock would read that
    # as dead, scan, delete the lock and rotate. Readable = machine + numeric pid.
    local repo="$TEST_TMPDIR/repo" dir="$TEST_TMPDIR/proj-renamed-pid" rc=0 err before
    _mk_guard_repo "$repo"; _make_project "$dir"
    printf '{"machine":"%s","lockPid":%s,"sessionId":"af-leader","timestamp":"2026-11-11T00:00:00Z","user":"test","ccSessionId":"cc-leader"}\n' \
        "$(hostname)" "$$" > "$dir/.claude/.session-lock"
    before=$(cat "$dir/.claude/.session-lock")
    err=$(bash "$repo/setup/scripts/rotate-session.sh" "$dir" 2>&1 >/dev/null) || rc=$?
    assert_eq "3" "$rc" "a JSON lock without a numeric pid HEAD knows ⇒ refused (measured rc=$rc)" || return 1
    assert_file_exists "$dir/.claude/.session-lock" "the lock is NOT deleted" || return 1
    assert_eq "$before" "$(cat "$dir/.claude/.session-lock")" "and is byte-identical" || return 1
    assert_file_not_exists "$dir/session-history.md" "no rotation happened" || return 1
    assert_contains "$err" "cannot read (empty, corrupt, or a newer format)" "the refusal names the unreadable lock"
}
run_test "CFG-965: a JSON lock with the pid under a name HEAD's library does not know ⇒ refused, lock kept" test_lock_with_renamed_pid_field_refuses_and_keeps_it

test_git_env_does_not_hide_head_copy() {
    # An inherited GIT_DIR points git elsewhere; the guard must still read
    # HEAD's session-lock.sh from the repo the script lives in (owner shape of
    # test_sf1_renamed_live_lib_owner_rotates_via_head_copy).
    local repo="$TEST_TMPDIR/repo" dir="$TEST_TMPDIR/proj-git-env" rc=0
    _mk_guard_repo "$repo"; _make_project "$dir"
    _rename_live_check_lock "$repo" || { echo "fixture: rename failed" >&2; return 1; }
    ( source "$LOCK_LIB"; _write_lock "$dir/.claude/.session-lock" "af-mine" "" "$$" )
    GIT_DIR="$TEST_TMPDIR/not-a-repo" GIT_WORK_TREE="$TEST_TMPDIR/not-a-tree" _CC_SELF_PID="" AFLEET_SESSION_ID="af-mine" \
        bash "$repo/setup/scripts/rotate-session.sh" "$dir" >/dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" "the owner still rotates through HEAD's copy with GIT_DIR/GIT_WORK_TREE pointing elsewhere (measured rc=$rc)" || return 1
    assert_file_exists "$dir/session-history.md" "rotation happened for the owner"
}
run_test "CFG-965: inherited GIT_DIR/GIT_WORK_TREE do not hide HEAD's session-lock.sh from the guard" test_git_env_does_not_hide_head_copy

suite_summary
