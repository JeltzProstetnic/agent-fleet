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

suite_summary
