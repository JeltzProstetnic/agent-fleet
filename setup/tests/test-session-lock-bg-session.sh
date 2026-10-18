#!/usr/bin/env bash
# Tests for session-lock.sh — a daemon-hosted BACKGROUND session of the leader
# is a follower (CFG-740). Kept apart from test-session-lock.sh, which sits at
# the 1500-line split threshold (CFG-171).
#
# Measured life WSL 2026-10-06 (the CC config dir's daemon/roster.json,
# daemon.log and jobs/<id>/state.json): two minutes after `af life` launched,
# a slash command inside the fresh leader dispatched a background session
# through Claude Code's transient daemon. Ancestry of the background REPL:
#   afleet.sh (lock pid) → script → claude.exe (leader) → `claude daemon run`
#   → `claude --bg-pty-host` → `claude --session-id <bg>` → SessionStart hook
# The reporter read its own launcher as a foreign holder and proposed "lock pid
# is an ancestor ⇒ ours". That is the nested-CC spoof shape with two more hops:
# the leader was alive the whole time (it ran its own SessionEnd and released
# the lock when it exited), so the background session is a SECOND live session
# in the project and the follower verdict is correct. These tests pin that, so
# the proposed change is refused by a red test rather than by memory.
source "$(dirname "$0")/test-helpers.sh"

suite_header "Session Lock — daemon-hosted background session (CFG-740)"

LOCK_SCRIPT="$REPO_ROOT/setup/scripts/session-lock.sh"

make_project_dir() { mkdir -p "$1/.claude"; }
_cfg740_lock() {   # <proj> <sessionId> <ccSessionId> <pid>
    make_project_dir "$1"
    _write_lock "$1/.claude/.session-lock" "$2" "$3" "$4"
}

# Stub tree = test-session-lock.sh's _cfg454_stub_tree plus the daemon branch
# under the leader (override _ppid_of/_pid_is_cc/_is_pid_alive after sourcing):
#   100 afleet → 200 script → 300 leader-CC → 400 nested-bash → 500 nested-CC
#                                └→ 700 daemon(CC) → 710 pty-host(CC) → 720 bg-REPL(CC)
_cfg740_stub_tree() {
    _ppid_of() { case "$1" in 300) echo 200;; 200) echo 100;; 100) echo 1;; 500) echo 400;; 400) echo 300;; 700) echo 300;; 710) echo 700;; 720) echo 710;; *) echo "";; esac; }
    _pid_is_cc() { case "$1" in 300|500|700|710|720) return 0;; *) return 1;; esac; }
    _is_pid_alive() { case "$1" in 100|300|700|710|720) return 0;; *) return 1;; esac; }
}

test_cfg740_bg_session_holder_is_ancestor_but_nested() {
    local proj="$TEST_TMPDIR/p740-bg"
    source "$LOCK_SCRIPT"; _cfg740_stub_tree
    _cfg740_lock "$proj" "sess-leader" "cc-leader" 100     # the leader's live, stamped lock
    # The background REPL: its own cc id from the hook stdin, the leader's
    # AFLEET_SESSION_ID inherited through the daemon's environment.
    local _CC_SELF_PID=720 CC_SESSION_ID="cc-bg" CLAUDE_CODE_SESSION_ID="cc-bg" AFLEET_SESSION_ID="sess-leader"
    local rc=0 anc=0 owns=0 nested=0
    check_lock "$proj" 720 || rc=$?
    _pid_is_descendant_of 720 100 || anc=$?
    _cc_owns_lock_pid 100 || owns=$?
    _cc_is_nested || nested=$?
    assert_eq "rc=2 anc=0 owns=1 nested=0" "rc=$rc anc=$anc owns=$owns nested=$nested" \
        "the holder IS an ancestor (anc=0), yet CCs sit between (nested=0, owns=1) ⇒ a second live session, follower (measured rc=$rc)" || return 1
    assert_file_exists "$proj/.claude/.session-lock" "the leader's lock is left intact"
}
run_test "CFG-740: check_lock — daemon-hosted background session of the leader is a follower (holder is an ancestor)" test_cfg740_bg_session_holder_is_ancestor_but_nested

test_cfg740_bg_session_with_leaders_ids_still_follower() {
    # The pure inherited-env spoof on this topology: the background session
    # somehow carries the leader's cc id as well. Ancestry gates every id match.
    local proj="$TEST_TMPDIR/p740-spoof"
    source "$LOCK_SCRIPT"; _cfg740_stub_tree
    _cfg740_lock "$proj" "sess-leader" "cc-leader" 100
    local _CC_SELF_PID=720 CC_SESSION_ID="cc-leader" CLAUDE_CODE_SESSION_ID="cc-leader" AFLEET_SESSION_ID="sess-leader"
    local rc=0; check_lock "$proj" 720 || rc=$?
    assert_eq "2" "$rc" "the leader's full id set, inherited by a nested background session, proves nothing (measured rc=$rc)"
}
run_test "CFG-740: check_lock — background session carrying the leader's ids is still a follower" test_cfg740_bg_session_with_leaders_ids_still_follower

test_cfg740_leader_unaffected_by_its_daemon_branch() {
    # Positive control: with the daemon, pty host and background REPL all live
    # below it, the af leader still owns its launcher-ancestor lock.
    local proj="$TEST_TMPDIR/p740-leader"
    source "$LOCK_SCRIPT"; _cfg740_stub_tree
    _cfg740_lock "$proj" "sess-leader" "cc-leader" 100
    local _CC_SELF_PID=300 CC_SESSION_ID="cc-leader" CLAUDE_CODE_SESSION_ID="cc-leader" AFLEET_SESSION_ID="sess-leader"
    local rc=0; check_lock "$proj" 300 || rc=$?
    assert_eq "1" "$rc" "the af leader is the owner with a live background branch beneath it (measured rc=$rc)"
}
run_test "CFG-740: check_lock — the af leader still owns its lock with a live daemon branch below" test_cfg740_leader_unaffected_by_its_daemon_branch

test_cfg740_orphaned_bg_session_holds_project_for_newcomers() {
    # Second symptom's consequence: the leader exited (lock released, daemon
    # reparented to init) but the background REPL kept running, cwd'd in the
    # project. A NEW session there must be a follower (CFG-468: a live CC in
    # the project without a lock file is LOCKED), until the job is stopped.
    local proj="$TEST_TMPDIR/p740-orphan" real
    source "$LOCK_SCRIPT"
    make_project_dir "$proj"; real="$(realpath "$proj")"
    _ppid_of() { case "$1" in 700) echo 1;; 710) echo 700;; 720) echo 710;; 800) echo 1;; *) echo "";; esac; }
    _pid_is_cc() { case "$1" in 700|710|720|800) return 0;; *) return 1;; esac; }
    _is_pid_alive() { case "$1" in 700|710|720|800) return 0;; *) return 1;; esac; }
    _enumerate_pids() { printf '%s\n' 1 700 710 720 800; }
    _pid_cwd() { case "$1" in 700|710|720) echo "$real";; *) echo "/elsewhere";; esac; }
    local _CC_SELF_PID=800 CC_SESSION_ID="cc-new" CLAUDE_CODE_SESSION_ID="cc-new" AFLEET_SESSION_ID="sess-new"
    local rc=0; check_lock "$proj" 800 || rc=$?
    assert_eq "2" "$rc" "no lock file, an orphaned background session cwd'd in the project ⇒ the newcomer is a follower (measured rc=$rc)"
}
run_test "CFG-740: check_lock — an orphaned background session (leader gone) still holds the project" test_cfg740_orphaned_bg_session_holds_project_for_newcomers

# ── Summary ─────────────────────────────────────────────────────────────────

suite_summary
