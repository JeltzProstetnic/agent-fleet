#!/usr/bin/env bash
# CFG-666 (trigger side) — checks/07b-platform-env.sh must not hand a NESTED CC
# the leader role.
#
# A nested CC (a headless `mclaude -p` from a Bash tool call, a tmux-launched CC
# in the same project) inherits the leader's AFLEET_SESSION_ID. check_lock
# (session-lock.sh, CFG-536) compares that id only when the caller is NOT a
# nested CC — the library's own comment says an ungated comparison "would hand
# it ownership and reopen the CFG-454 F1 spoof". 07b then repeated the same
# comparison with no gate and overwrote the library's verdict (rc 2 → 1), so the
# nested CC's role marker read `leader`; at its SessionEnd the leader path ran
# `rotate-session.sh <project> --owner-verified` against the LEADER's live
# session-context.md.
#
# Runs the REAL 07b under a REAL process tree: fake CC processes made with
# `exec -a`, and _CC_PROC_RE (env-overridable in session-lock.sh) pointed at
# them, so any real CC running this suite is invisible and the verdict depends
# only on the tree built here. `leader` = one fake CC; `nested` = one under it.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO_ROOT/setup/tests/test-helpers.sh"

# CFG666_HOOK_07B=<path> runs this suite against a candidate check instead of the
# repo's (e.g. an extracted `git show <rev>:...07b-platform-env.sh`).
HOOK_07B="${CFG666_HOOK_07B:-$REPO_ROOT/global/hooks/checks/07b-platform-env.sh}"
LOCK_LIB="$REPO_ROOT/setup/scripts/session-lock.sh"

suite_header "checks/07b — a nested CC is a follower (CFG-666 trigger)"

_FAKE_CC_RE='(^|/)fakecc-(leader|nested)([[:space:]]|$)'

_mk_fake_cc_tree() {
    # fakecc-leader stays alive as the PARENT (bash -c spawns the child);
    # fakecc-nested replaces itself with the command (same pid, renamed).
    # `bash "$@"` must NOT be the last command of the -c string: bash 5.2
    # exec-optimises a single trailing command (measured 2026-09-23), which
    # would replace the leader with the child and flatten the tree.
    cat > "$TEST_TMPDIR/fakecc-leader.sh" << 'EOF'
#!/usr/bin/env bash
exec -a fakecc-leader bash -c 'bash "$@"; rc=$?; exit $rc' _ "$@"
EOF
    cat > "$TEST_TMPDIR/fakecc-nested.sh" << 'EOF'
#!/usr/bin/env bash
exec -a fakecc-nested bash "$@"
EOF
}

_under_tree() {   # leader|nested <script> [args] — run <script> as the innermost fake CC
    local tree="$1"; shift
    case "$tree" in
        leader) _CC_PROC_RE="$_FAKE_CC_RE" bash "$TEST_TMPDIR/fakecc-leader.sh" "$@" ;;
        nested) _CC_PROC_RE="$_FAKE_CC_RE" bash "$TEST_TMPDIR/fakecc-leader.sh" "$TEST_TMPDIR/fakecc-nested.sh" "$@" ;;
    esac
}

# Minimal CONFIG_REPO the check expects: just the real lock lib under setup/scripts.
_mk_config_repo() {
    mkdir -p "$1/setup/scripts"
    cp "$LOCK_LIB" "$1/setup/scripts/session-lock.sh"
}

# The runner that sources the real 07b with a controlled env against $proj.
_mk_07b_runner() {   # <config_repo> <proj>
    cat > "$TEST_TMPDIR/run07b.sh" << EOF
#!/usr/bin/env bash
export _FORCE_WSL=0            # skip 7b.1 wsl.conf auto-fix (no system writes)
export CONFIG_REPO="$1" PROJECT_DIR="$2"
WARNINGS="" INBOX_MSG=""
cd "$2"
source "$HOOK_07B"
EOF
}

_role_of() { tr -d '[:space:]' < "$1" 2>/dev/null || true; }

test_nested_cc_is_follower() {
    local cr="$TEST_TMPDIR/cr" proj="$TEST_TMPDIR/proj"
    _mk_config_repo "$cr"; _mk_fake_cc_tree; _mk_07b_runner "$cr" "$proj"
    mkdir -p "$proj/.claude"
    # The leader's live lock: afleet id af-leader, already stamped with the
    # leader's own cc id, pid alive and neither ours nor the fake CC's.
    sleep 120 & local lpid=$!
    ( source "$LOCK_LIB"; _write_lock "$proj/.claude/.session-lock" "af-leader" "cc-leader" "$lpid" )
    # The nested CC: inherited AFLEET_SESSION_ID, its own cc id, a CC above it.
    AFLEET_SESSION_ID=af-leader CC_SESSION_ID=cc-nested \
        _under_tree nested "$TEST_TMPDIR/run07b.sh" >/dev/null 2>&1 || true
    kill "$lpid" 2>/dev/null || true
    local marker="$proj/.claude/.session-role.cc-nested" role
    assert_file_exists "$marker" "07b wrote a role marker for the nested CC" || return 1
    role=$(_role_of "$marker")
    assert_eq "follower" "$role" "a nested CC with an inherited AFLEET_SESSION_ID is a follower (measured role: '$role')" || return 1
    assert_file_exists "$proj/.claude/.session-lock" "the leader's lock is left intact" || return 1
    assert_file_contains "$proj/.claude/.session-lock" '"cc-leader"' "the lock stays bound to the leader's cc id"
}
run_test "07b: nested CC (inherited AFLEET_SESSION_ID) gets role follower, not leader" test_nested_cc_is_follower

test_afleet_leader_stays_leader() {
    # Removing the override must not demote the genuine `af` leader: its lock
    # (written by afleet before CC starts: afleet id, no cc id yet, launcher pid)
    # is recognised by check_lock itself through the AFLEET_SESSION_ID match,
    # gated on "not nested" — which a single fake CC satisfies.
    local cr="$TEST_TMPDIR/cr" proj="$TEST_TMPDIR/proj"
    _mk_config_repo "$cr"; _mk_fake_cc_tree; _mk_07b_runner "$cr" "$proj"
    mkdir -p "$proj/.claude"
    sleep 120 & local lpid=$!
    ( source "$LOCK_LIB"; _write_lock "$proj/.claude/.session-lock" "af-leader" "" "$lpid" )
    AFLEET_SESSION_ID=af-leader CC_SESSION_ID=cc-leader \
        _under_tree leader "$TEST_TMPDIR/run07b.sh" >/dev/null 2>&1 || true
    kill "$lpid" 2>/dev/null || true
    local marker="$proj/.claude/.session-role.cc-leader" role
    assert_file_exists "$marker" "07b wrote a role marker for the leader" || return 1
    role=$(_role_of "$marker")
    assert_eq "leader" "$role" "the genuine af leader keeps role leader without the override (measured role: '$role')" || return 1
    assert_file_contains "$proj/.claude/.session-lock" '"cc-leader"' "07b stamped the leader's lock with its cc id"
}
run_test "07b: the genuine af leader (AFLEET_SESSION_ID matches, not nested) stays leader" test_afleet_leader_stays_leader

suite_summary
