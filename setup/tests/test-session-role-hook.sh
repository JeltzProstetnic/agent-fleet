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

HOOK_07B="$REPO_ROOT/global/hooks/checks/07c-session-lock.sh"   # CFG-721: the lock section moved out of 07b
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
    # This session's own CC is visible to the lock check, as in production
    # (CFG-673: a check that sees no CC at all answers "unknown", not "free").
    _CC_SELF_PID="$$" _run_07b "$cr" "$proj" "cc-leader" ""
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

# ── CFG-740: a daemon-hosted background session of the leader, end to end ────
# Measured life WSL 2026-10-06: `/background` inside a fresh `af` leader spawned
# a transient `claude daemon run`, which spawned `claude --bg-pty-host`, which
# spawned a full REPL in the same cwd. Its SessionStart read the leader's live
# lock (pid = the afleet launcher, an ANCESTOR of the REPL) and became a
# follower. That verdict is correct — the leader was alive, still owned the
# lock and later ran its own SessionEnd — but the warning gave the next agent
# nothing to recognise the shape by, so it was reported as a false follower.
# These tests build the REAL process chain (no stubs: real pids, real /proc
# ancestry, the real 07c) and check the verdict AND the wording.
#   bg:     launcher(lock pid) → leader-CC → daemon-CC → pty-host-CC → bg-REPL-CC → hook
#   leader: launcher(lock pid) → leader-CC → hook                 (the af shape)
# Only argv0 `cfg740cc-*` processes are Claude Code to the library here, so the
# suite's own ancestry (a real CC when run from a session) plays no part.
_cfg740_write_chain() {   # <path> — the fixture script, written once per run
    cat > "$1" <<'CHAIN'
#!/usr/bin/env bash
# argv: <mode> <lockpid|-> <ccstamp> <lockfile> <proj> <config-repo> <hook> <outfile> [level]
set -u
mode=$1 lockpid=$2 ccstamp=$3 lockfile=$4 proj=$5 cr=$6 hook=$7 out=$8 lvl=${9:-0}
case "$mode" in
    bg)     names=(cfg740-launcher cfg740cc-leader cfg740cc-daemon cfg740cc-ptyhost cfg740cc-bgrepl) ;;
    leader) names=(cfg740-launcher cfg740cc-leader) ;;
    *)      echo "bad mode $mode" >&2; exit 2 ;;
esac
last=$(( ${#names[@]} - 1 ))
# Take this level's process name once; exec keeps the pid.
if [[ "${CFG740_NAMED:-}" != "$lvl" ]]; then
    CFG740_NAMED=$lvl exec -a "${names[$lvl]}" bash "$0" "$@"
fi
if (( lvl == 0 )); then
    # The launcher writes the lock — with its own pid, as afleet does, unless told otherwise.
    [[ "$lockpid" == "-" ]] && lockpid=$$
    ( source "$cr/setup/scripts/session-lock.sh"; _write_lock "$lockfile" "sess-leader" "$ccstamp" "$lockpid" )
fi
if (( lvl < last )); then
    bash "$0" "$mode" "$lockpid" "$ccstamp" "$lockfile" "$proj" "$cr" "$hook" "$out" $((lvl + 1))
    exit $?
fi
# Innermost CC (the REPL): run the SessionStart check as a child, as the hook runs.
bash -c '
    export _FORCE_WSL=0 CONFIG_REPO="$1" PROJECT_DIR="$2"
    export _CC_PROC_RE="(^|/)cfg740cc-[a-z]+([[:space:]]|$)"
    WARNINGS="" INBOX_MSG=""
    cd "$2" || exit 1
    source "$3" >/dev/null 2>&1 || true
    printf "WARNINGS=%s\n" "$WARNINGS" > "$4"
' _ "$cr" "$proj" "$hook" "$out"
CHAIN
}

_cfg740_run_chain() {   # <mode> <lockpid|-> <ccstamp> <proj> <cc-id> <afleet-id> → echoes "WARNINGS=…"
    local mode="$1" lockpid="$2" ccstamp="$3" proj="$4" cc="$5" af="$6"
    local fixture="$TEST_TMPDIR/cfg740-chain.sh" out="$TEST_TMPDIR/cfg740-$mode-$RANDOM.out"
    [[ -f "$fixture" ]] || _cfg740_write_chain "$fixture"
    mkdir -p "$proj/.claude"
    ( unset _CC_SELF_PID
      export CC_SESSION_ID="$cc" CLAUDE_CODE_SESSION_ID="$cc" AFLEET_SESSION_ID="$af"
      timeout 60 bash "$fixture" "$mode" "$lockpid" "$ccstamp" "$proj/.claude/.session-lock" \
          "$proj" "$REPO_ROOT" "$HOOK_07B" "$out" ) >/dev/null 2>&1 || true
    cat "$out" 2>/dev/null || echo "WARNINGS=<chain produced no output>"
}

test_cfg740_bg_session_is_follower_and_named_nested() {
    local proj="$TEST_TMPDIR/p740-hook-bg" out
    # The leader's lock is already stamped with the leader's cc id, as it is by
    # the time a background session starts; the REPL inherits AFLEET_SESSION_ID.
    out="$(_cfg740_run_chain bg - cc-leader "$proj" cc-bg sess-leader)"
    assert_contains "$out" "SESSION_LOCKED:" "a background session under a live leader is locked out (got: ${out:0:160})" || return 1
    assert_contains "$out" "NESTED" "the warning names the shape — the holder is an ancestor of this session's own CC (got: ${out:0:240})" || return 1
    assert_file_contains "$proj/.claude/.session-role.cc-bg" "follower" "role marker: follower" || return 1
    assert_file_contains "$proj/.claude/.session-lock" '"cc-leader"' "the leader's lock is intact and still bound to the leader"
}
run_test "CFG-740: 07c — daemon-hosted background session ⇒ follower, warning says NESTED (real process chain)" test_cfg740_bg_session_is_follower_and_named_nested

test_cfg740_af_leader_shape_is_leader() {
    # Positive control for the chain itself: the same launcher-written lock,
    # read by the CC directly beneath the launcher, is the leader's own.
    local proj="$TEST_TMPDIR/p740-hook-leader" out
    out="$(_cfg740_run_chain leader - "" "$proj" cc-leader sess-leader)"
    assert_not_contains "$out" "SESSION_LOCKED" "the af shape (launcher → leader CC → hook) is the owner (got: ${out:0:160})" || return 1
    assert_file_contains "$proj/.claude/.session-role.cc-leader" "leader" "role marker: leader" || return 1
    assert_file_contains "$proj/.claude/.session-lock" '"cc-leader"' "the leader stamped its own lock"
}
run_test "CFG-740: 07c — the af launcher shape is still the leader (real process chain)" test_cfg740_af_leader_shape_is_leader

test_cfg740_foreign_holder_is_not_named_nested() {
    # A live holder that is NOT an ancestor: locked, and the wording must not
    # claim nesting — the qualifier is evidence, not decoration.
    local proj="$TEST_TMPDIR/p740-hook-foreign" out fpid
    sleep 120 & fpid=$!
    out="$(_cfg740_run_chain leader "$fpid" cc-other "$proj" cc-mine sess-mine)"
    kill "$fpid" 2>/dev/null || true
    assert_contains "$out" "SESSION_LOCKED:" "an unrelated live holder is foreign (got: ${out:0:160})" || return 1
    assert_not_contains "$out" "NESTED" "a holder that is not an ancestor is not called nested (got: ${out:0:240})" || return 1
    assert_file_contains "$proj/.claude/.session-role.cc-mine" "follower" "role marker: follower"
}
run_test "CFG-740: 07c — unrelated live holder ⇒ follower, NOT named nested" test_cfg740_foreign_holder_is_not_named_nested

test_cfg740_orphaned_bg_session_locks_newcomer_with_no_lock_file() {
    # Second symptom's consequence: the leader has exited (lock released) but
    # the background REPL kept running, cwd'd in the project. A newcomer is a
    # follower (CFG-468) and must be told WHY — there is no lock to point at.
    local proj="$TEST_TMPDIR/p740-hook-orphan" real out found=""
    mkdir -p "$proj/.claude"; real="$(realpath "$proj")"
    # Spawn from a command-substitution subshell (as the 06b suite's
    # _spawn_foreign_cc does): the subshell exits, the sleep is reparented away
    # from this script, and so is NOT a descendant of $$ — a child of $$ would be
    # excluded by the CFG-468 self-tree rule and the test would prove nothing.
    found="$( setsid bash -c "cd '$proj' && exec -a cfg740cc-orphan sleep 20" </dev/null >/dev/null 2>&1 &
        for i in $(seq 1 30); do
            for p in $(pgrep -x sleep 2>/dev/null || true); do
                [[ "$(readlink "/proc/$p/cwd" 2>/dev/null)" == "$real" ]] && { echo "$p"; exit 0; }
            done
            sleep 0.1
        done )"
    [[ -n "$found" ]] || { echo "could not spawn the orphan fixture" >&2; return 1; }
    out="$( unset _CC_SELF_PID
        export _FORCE_WSL=0 CONFIG_REPO="$REPO_ROOT" PROJECT_DIR="$proj"
        export CC_SESSION_ID=cc-new CLAUDE_CODE_SESSION_ID=cc-new AFLEET_SESSION_ID=sess-new
        export _CC_PROC_RE='(^|/)cfg740cc-[a-z]+([[:space:]]|$)' _CC_SELF_PID="$$"
        WARNINGS="" INBOX_MSG=""
        cd "$proj" || exit 1
        source "$HOOK_07B" >/dev/null 2>&1 || true
        printf 'WARNINGS=%s\n' "$WARNINGS" )"
    kill "$found" 2>/dev/null || true
    assert_contains "$out" "SESSION_LOCKED:" "a live CC cwd'd in the project with no lock file ⇒ locked (got: ${out:0:160})" || return 1
    assert_contains "$out" "no readable lock file" "the newcomer is told there is no lock, only a live session (got: ${out:0:240})" || return 1
    assert_file_contains "$proj/.claude/.session-role.cc-new" "follower" "role marker: follower"
}
run_test "CFG-740: 07c — orphaned background session, no lock file ⇒ follower with a legible reason" test_cfg740_orphaned_bg_session_locks_newcomer_with_no_lock_file

suite_summary
