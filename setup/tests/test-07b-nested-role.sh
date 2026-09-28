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
    # The af launcher shape (CFG-672): afleet.sh writes the lock with ITS OWN pid
    # and runs CC as a CHILD (via `script`), so the launcher stays a live ANCESTOR
    # of the CC for the whole session — the topology check_lock's ancestry proof
    # expects. Args: <proj> <afleet-id> <cc-script> [args]. The child must not be
    # the last command (bash exec-optimises a trailing command, see above).
    cat > "$TEST_TMPDIR/afleet-shell.sh" << EOF
#!/usr/bin/env bash
source "$LOCK_LIB"
_write_lock "\$1/.claude/.session-lock" "\$2" "" "\$\$"
shift 2
bash "\$@"; rc=\$?; exit \$rc
EOF
}

_under_tree() {   # leader|nested|af <script> [args] — run <script> as the innermost fake CC
    local tree="$1"; shift
    case "$tree" in
        leader) _CC_PROC_RE="$_FAKE_CC_RE" bash "$TEST_TMPDIR/fakecc-leader.sh" "$@" ;;
        nested) _CC_PROC_RE="$_FAKE_CC_RE" bash "$TEST_TMPDIR/fakecc-leader.sh" "$TEST_TMPDIR/fakecc-nested.sh" "$@" ;;
        # af <proj> <afleet-id> <script>: launcher writes the lock, CC is its child
        af)     _CC_PROC_RE="$_FAKE_CC_RE" bash "$TEST_TMPDIR/afleet-shell.sh" "$1" "$2" "$TEST_TMPDIR/fakecc-leader.sh" "${@:3}" ;;
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
printf 'WARNINGS=%s\n' "\$WARNINGS"
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
    # is recognised by check_lock itself. Since CFG-672 that recognition is by
    # ANCESTRY — the launcher shell that wrote the lock is a live ancestor of the
    # CC — so the fixture runs the real launcher shape (afleet-shell → fake CC),
    # not merely "some alive pid" (which is the tmux shape tested below).
    local cr="$TEST_TMPDIR/cr" proj="$TEST_TMPDIR/proj"
    _mk_config_repo "$cr"; _mk_fake_cc_tree; _mk_07b_runner "$cr" "$proj"
    mkdir -p "$proj/.claude"
    AFLEET_SESSION_ID=af-leader CC_SESSION_ID=cc-leader \
        _under_tree af "$proj" af-leader "$TEST_TMPDIR/run07b.sh" >/dev/null 2>&1 || true
    local marker="$proj/.claude/.session-role.cc-leader" role
    assert_file_exists "$marker" "07b wrote a role marker for the leader" || return 1
    role=$(_role_of "$marker")
    assert_eq "leader" "$role" "the genuine af leader keeps role leader without the override (measured role: '$role')" || return 1
    assert_file_contains "$proj/.claude/.session-lock" '"cc-leader"' "07b stamped the leader's lock with its cc id"
}
run_test "07b: the genuine af leader (launcher is CC's ancestor, AFLEET_SESSION_ID matches) stays leader" test_afleet_leader_stays_leader

test_tmux_cc_with_inherited_afleet_id_is_follower() {
    # CFG-672: a CC started through tmux-launch.sh is parented to the tmux
    # server, not to the leader's CC, so _cc_is_nested cannot see it — yet it
    # carries the server's inherited AFLEET_SESSION_ID. The leader's lock pid is
    # alive but NOT an ancestor of this CC, and the lock is still unstamped
    # (the exposed window). check_lock accepted the bare id match (rc 1) and 07b
    # then stamped the leader's lock with the tmux CC's id and marked it leader.
    local cr="$TEST_TMPDIR/cr" proj="$TEST_TMPDIR/proj"
    _mk_config_repo "$cr"; _mk_fake_cc_tree; _mk_07b_runner "$cr" "$proj"
    mkdir -p "$proj/.claude"
    sleep 120 & local lpid=$!      # the leader's launcher: alive, unrelated to our tree
    ( source "$LOCK_LIB"; _write_lock "$proj/.claude/.session-lock" "af-leader" "" "$lpid" )
    AFLEET_SESSION_ID=af-leader CC_SESSION_ID=cc-tmux \
        _under_tree leader "$TEST_TMPDIR/run07b.sh" >/dev/null 2>&1 || true
    kill "$lpid" 2>/dev/null || true
    local marker="$proj/.claude/.session-role.cc-tmux" role
    assert_file_exists "$marker" "07b wrote a role marker for the tmux CC" || return 1
    role=$(_role_of "$marker")
    assert_eq "follower" "$role" "a tmux-launched CC with an inherited AFLEET_SESSION_ID is a follower (measured role: '$role')" || return 1
    assert_file_exists "$proj/.claude/.session-lock" "the leader's lock is left intact" || return 1
    assert_file_not_contains "$proj/.claude/.session-lock" '"cc-tmux"' "the leader's lock is NOT stamped with the tmux CC's id"
}
run_test "07b: tmux-launched CC (inherited AFLEET_SESSION_ID, lock pid alive elsewhere) gets role follower" test_tmux_cc_with_inherited_afleet_id_is_follower

test_tmux_cc_on_stamped_leader_lock_is_follower() {
    # The same tmux CC against the NORMAL production state: the leader's lock is
    # already stamped with the leader's cc id. The tmux CC's own ids (hook stdin
    # and the CLAUDE_CODE_SESSION_ID its CC sets for the hook) are its own.
    local cr="$TEST_TMPDIR/cr" proj="$TEST_TMPDIR/proj"
    _mk_config_repo "$cr"; _mk_fake_cc_tree; _mk_07b_runner "$cr" "$proj"
    mkdir -p "$proj/.claude"
    sleep 120 & local lpid=$!
    ( source "$LOCK_LIB"; _write_lock "$proj/.claude/.session-lock" "af-leader" "cc-leader" "$lpid" )
    AFLEET_SESSION_ID=af-leader CC_SESSION_ID=cc-tmux CLAUDE_CODE_SESSION_ID=cc-tmux \
        _under_tree leader "$TEST_TMPDIR/run07b.sh" >/dev/null 2>&1 || true
    kill "$lpid" 2>/dev/null || true
    local marker="$proj/.claude/.session-role.cc-tmux" role
    assert_file_exists "$marker" "07b wrote a role marker for the tmux CC" || return 1
    role=$(_role_of "$marker")
    assert_eq "follower" "$role" "a tmux CC on the leader's STAMPED lock is a follower (measured role: '$role')" || return 1
    assert_file_contains "$proj/.claude/.session-lock" '"cc-leader"' "the lock stays bound to the leader's cc id"
}
run_test "07b: tmux-launched CC on the leader's already-stamped lock gets role follower" test_tmux_cc_on_stamped_leader_lock_is_follower

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

test_direct_leader_compacting_with_follower_live_stays_leader() {
    # CFG-454: a direct launch records the SessionStart hook's pid, dead seconds
    # later. When that leader compacts (SessionStart again, same cc id) while a
    # follower CC is live in the project, check_lock read the leader's OWN
    # stamped lock as foreign (the dead-pid branch never looked at the cc id):
    # the leader became a follower — two followers, no leader.
    local cr="$TEST_TMPDIR/cr" proj="$TEST_TMPDIR/proj"
    _mk_config_repo "$cr"; _mk_fake_cc_tree; _mk_07b_runner "$cr" "$proj"
    mkdir -p "$proj/.claude"
    true & local dpid=$!; wait "$dpid" 2>/dev/null || true
    ( source "$LOCK_LIB"; _write_lock "$proj/.claude/.session-lock" "" "cc-leader" "$dpid" )
    local fol; fol="$(_spawn_other_cc "$proj")" || { echo "could not spawn the follower CC" >&2; return 1; }
    env -u AFLEET_SESSION_ID CC_SESSION_ID=cc-leader CLAUDE_CODE_SESSION_ID=cc-leader \
        _CC_PROC_RE="$_FAKE_CC_RE" bash "$TEST_TMPDIR/fakecc-leader.sh" "$TEST_TMPDIR/run07b.sh" >/dev/null 2>&1 || true
    kill "$fol" 2>/dev/null || true
    local marker="$proj/.claude/.session-role.cc-leader" role
    assert_file_exists "$marker" "07b wrote a role marker for the leader" || return 1
    role=$(_role_of "$marker")
    assert_eq "leader" "$role" "the leader keeps its role on its own decayed lock with a follower live (measured role: '$role')" || return 1
    assert_file_contains "$proj/.claude/.session-lock" '"cc-leader"' "the lock stays bound to the leader's cc id"
}
run_test "07b: direct-launch leader compacting while a follower is live stays leader" test_direct_leader_compacting_with_follower_live_stays_leader

# ── CFG-673 / GH#9: a blind lock check is "unknown", never "free" ────────────
# When the lock check can see /proc but no CC process at all, not even this
# session's own, its liveness scan is blind (a CC matcher that recognises
# nothing here; inside Claude Code's Bash sandbox, a PID namespace). check_lock
# read that as "no holder": it deleted the lock and 07b took the lead. The
# owner decision is fail closed: rc 4, lock kept, this session a follower, and
# the user told the state is unknown. _CC_PROC_RE names no running process.
_run07b_blind() {   # <cc-id>: the real 07b with nothing CC-shaped visible; echoes its WARNINGS
    env -u AFLEET_SESSION_ID -u _CC_SELF_PID CC_SESSION_ID="$1" CLAUDE_CODE_SESSION_ID="$1" \
        _CC_PROC_RE="(^|/)cfg673-no-such-cc-$$([[:space:]]|$)" bash "$TEST_TMPDIR/run07b.sh" 2>/dev/null || true
}

test_blind_check_on_dead_pid_lock_is_follower_unknown() {
    local cr="$TEST_TMPDIR/cr" proj="$TEST_TMPDIR/proj"
    _mk_config_repo "$cr"; _mk_07b_runner "$cr" "$proj"
    mkdir -p "$proj/.claude"
    true & local dpid=$!; wait "$dpid" 2>/dev/null || true
    ( source "$LOCK_LIB"; _write_lock "$proj/.claude/.session-lock" "af-leader" "cc-leader" "$dpid" )
    local out; out="$(_run07b_blind cc-blind)"
    assert_file_exists "$proj/.claude/.session-lock" "the lock is not deleted on a blind scan" || return 1
    assert_file_contains "$proj/.claude/.session-lock" '"cc-leader"' "the lock still names the other session" || return 1
    local marker="$proj/.claude/.session-role.cc-blind" role
    assert_file_exists "$marker" "07b wrote a role marker" || return 1
    role=$(_role_of "$marker")
    assert_eq "follower" "$role" "a session that cannot see who holds the project is a follower (measured role: '$role')" || return 1
    assert_contains "$out" "SESSION_LOCK_UNKNOWN" "the user is told the lock state is unknown"
}
run_test "07b: blind lock check on a dead-pid lock ⇒ lock kept, follower, SESSION_LOCK_UNKNOWN" test_blind_check_on_dead_pid_lock_is_follower_unknown

test_blind_check_without_lock_does_not_take_the_lead() {
    local cr="$TEST_TMPDIR/cr" proj="$TEST_TMPDIR/proj"
    _mk_config_repo "$cr"; _mk_07b_runner "$cr" "$proj"
    mkdir -p "$proj/.claude"
    local out; out="$(_run07b_blind cc-blind)"
    assert_file_not_exists "$proj/.claude/.session-lock" "no lock is acquired on a blind scan" || return 1
    local marker="$proj/.claude/.session-role.cc-blind" role
    assert_file_exists "$marker" "07b wrote a role marker" || return 1
    role=$(_role_of "$marker")
    assert_eq "follower" "$role" "no lock + blind scan ⇒ follower, not leader (measured role: '$role')" || return 1
    assert_contains "$out" "SESSION_LOCK_UNKNOWN" "the user is told the lock state is unknown"
}
run_test "07b: blind lock check with no lock file ⇒ no acquire, follower, SESSION_LOCK_UNKNOWN" test_blind_check_without_lock_does_not_take_the_lead

# ── CFG-592: own CC unresolvable, other CCs visible ⇒ lead granted, but LOUD ──
# The last silent grant. The hook's own CC is not among its ancestors as far as
# the CC matcher can tell (_CC_PROC_RE not matching this install's own CC while
# matching another — CFG-590 / GH#7 — or an ancestry walk cut short), yet a CC
# IS visible, so CFG-673's rc 4 does not fire. _project_has_live_cc then fails
# OPEN without looking (deliberate: a solo session must never self-block), and
# a rival already cwd'd in the project is simply not seen. Owner decision
# 2026-09-28, option 3: keep granting, warn SESSION_LOCK_SELF_UNKNOWN. Fixture:
# the real 07b run OUTSIDE any fake CC tree (own CC unresolvable) while a
# detached fake CC — visible to the matcher — is cwd'd IN the project.
_run07b_self_unknown() {   # <cc-id>: the real 07b, own CC unresolvable, fake CCs visible; echoes WARNINGS
    env -u AFLEET_SESSION_ID -u _CC_SELF_PID CC_SESSION_ID="$1" CLAUDE_CODE_SESSION_ID="$1" \
        _CC_PROC_RE="$_FAKE_CC_RE" bash "$TEST_TMPDIR/run07b.sh" 2>/dev/null || true
}

test_self_unknown_rival_in_project_leads_but_warns() {
    local cr="$TEST_TMPDIR/cr" proj="$TEST_TMPDIR/proj"
    _mk_config_repo "$cr"; _mk_07b_runner "$cr" "$proj"
    mkdir -p "$proj/.claude"
    local rival; rival="$(_spawn_other_cc "$proj")" || { echo "could not spawn the rival CC" >&2; return 1; }
    local out; out="$(_run07b_self_unknown cc-selfunk)"
    kill "$rival" 2>/dev/null || true
    local marker="$proj/.claude/.session-role.cc-selfunk" role
    assert_file_exists "$marker" "07b wrote a role marker" || return 1
    role=$(_role_of "$marker")
    assert_eq "leader" "$role" "the grant is unchanged: own CC unresolvable ⇒ fail open, leader even with a rival in the project (measured role: '$role')" || return 1
    assert_file_exists "$proj/.claude/.session-lock" "the lock was acquired as before" || return 1
    assert_contains "$out" "SESSION_LOCK_SELF_UNKNOWN" "the user is told the mutex could not identify this session's own CC" || return 1
    assert_contains "$out" "_CC_PROC_RE" "the warning names the matcher to check" || return 1
    assert_contains "$out" "check_lock=0" "the warning carries the verdict it qualifies" || return 1
    assert_not_contains "$out" "SESSION_LOCK_UNKNOWN" "this is not the blind-scan case" || return 1
    assert_not_contains "$out" "SESSION_LOCKED" "the rival was not detected — the warning exists because of exactly that"
}
run_test "07b: own CC unresolvable + rival CC visible in project ⇒ still leader, SESSION_LOCK_SELF_UNKNOWN" test_self_unknown_rival_in_project_leads_but_warns

test_self_unknown_own_stamped_lock_dead_pid_leads_and_warns() {
    # The rc 1 shape: a direct-launch leader compacting on its own lock (bound
    # to its cc id, hook pid dead). Still the leader, still warned: the session
    # goes on with a scan that cannot tell it from a rival.
    local cr="$TEST_TMPDIR/cr" proj="$TEST_TMPDIR/proj"
    _mk_config_repo "$cr"; _mk_07b_runner "$cr" "$proj"
    mkdir -p "$proj/.claude"
    true & local dpid=$!; wait "$dpid" 2>/dev/null || true
    ( source "$LOCK_LIB"; _write_lock "$proj/.claude/.session-lock" "" "cc-mine" "$dpid" )
    local other; other="$(_spawn_other_cc "$TEST_TMPDIR")" || { echo "could not spawn the visible CC" >&2; return 1; }
    local out; out="$(_run07b_self_unknown cc-mine)"
    kill "$other" 2>/dev/null || true
    local marker="$proj/.claude/.session-role.cc-mine" role
    assert_file_exists "$marker" "07b wrote a role marker" || return 1
    role=$(_role_of "$marker")
    assert_eq "leader" "$role" "own stamped lock ⇒ leader as before (measured role: '$role')" || return 1
    assert_file_contains "$proj/.claude/.session-lock" '"cc-mine"' "the lock stays bound to this session" || return 1
    assert_contains "$out" "SESSION_LOCK_SELF_UNKNOWN" "a leader whose own CC is unresolvable is warned on rc 1 too" || return 1
    assert_contains "$out" "check_lock=1" "the warning carries the verdict it qualifies"
}
run_test "07b: own CC unresolvable, own stamped lock (dead pid), other CC visible ⇒ leader, SESSION_LOCK_SELF_UNKNOWN" test_self_unknown_own_stamped_lock_dead_pid_leads_and_warns

test_self_resolved_solo_leads_without_self_unknown() {
    local cr="$TEST_TMPDIR/cr" proj="$TEST_TMPDIR/proj"
    _mk_config_repo "$cr"; _mk_fake_cc_tree; _mk_07b_runner "$cr" "$proj"
    mkdir -p "$proj/.claude"
    local out
    out="$(env -u AFLEET_SESSION_ID -u _CC_SELF_PID CC_SESSION_ID=cc-solo CLAUDE_CODE_SESSION_ID=cc-solo \
        _CC_PROC_RE="$_FAKE_CC_RE" bash "$TEST_TMPDIR/fakecc-leader.sh" "$TEST_TMPDIR/run07b.sh" 2>/dev/null || true)"
    local marker="$proj/.claude/.session-role.cc-solo" role
    assert_file_exists "$marker" "07b wrote a role marker" || return 1
    role=$(_role_of "$marker")
    assert_eq "leader" "$role" "a solo session whose own CC resolves is the leader (measured role: '$role')" || return 1
    assert_not_contains "$out" "SESSION_LOCK_SELF_UNKNOWN" "own CC resolved ⇒ no self-unknown warning" || return 1
    assert_not_contains "$out" "SESSION_LOCK_UNKNOWN" "own CC resolved ⇒ not blind either"
}
run_test "07b: own CC resolves, solo ⇒ leader, no SESSION_LOCK_SELF_UNKNOWN" test_self_resolved_solo_leads_without_self_unknown

test_self_resolved_rival_in_project_is_follower_without_self_unknown() {
    # The same rival as the first CFG-592 test, but with the hook's own CC
    # resolvable: now the rival IS seen — follower, SESSION_LOCKED, and nothing
    # about self. The warning tracks self-resolution, not the rival's presence.
    local cr="$TEST_TMPDIR/cr" proj="$TEST_TMPDIR/proj"
    _mk_config_repo "$cr"; _mk_fake_cc_tree; _mk_07b_runner "$cr" "$proj"
    mkdir -p "$proj/.claude"
    local rival; rival="$(_spawn_other_cc "$proj")" || { echo "could not spawn the rival CC" >&2; return 1; }
    local out
    out="$(env -u AFLEET_SESSION_ID -u _CC_SELF_PID CC_SESSION_ID=cc-second CLAUDE_CODE_SESSION_ID=cc-second \
        _CC_PROC_RE="$_FAKE_CC_RE" bash "$TEST_TMPDIR/fakecc-leader.sh" "$TEST_TMPDIR/run07b.sh" 2>/dev/null || true)"
    kill "$rival" 2>/dev/null || true
    local marker="$proj/.claude/.session-role.cc-second" role
    assert_file_exists "$marker" "07b wrote a role marker" || return 1
    role=$(_role_of "$marker")
    assert_eq "follower" "$role" "own CC resolved ⇒ the rival is detected, follower (measured role: '$role')" || return 1
    assert_contains "$out" "SESSION_LOCKED" "the rival is reported" || return 1
    assert_not_contains "$out" "SESSION_LOCK_SELF_UNKNOWN" "a detected rival is not a self-unknown case"
}
run_test "07b: own CC resolves, rival in project ⇒ follower, SESSION_LOCKED, no SESSION_LOCK_SELF_UNKNOWN" test_self_resolved_rival_in_project_is_follower_without_self_unknown

test_blind_scan_is_unknown_not_self_unknown() {
    local cr="$TEST_TMPDIR/cr" proj="$TEST_TMPDIR/proj"
    _mk_config_repo "$cr"; _mk_07b_runner "$cr" "$proj"
    mkdir -p "$proj/.claude"
    local out; out="$(_run07b_blind cc-blind)"
    assert_contains "$out" "SESSION_LOCK_UNKNOWN" "a blind scan is still reported as unknown" || return 1
    assert_not_contains "$out" "SESSION_LOCK_SELF_UNKNOWN" "a blind scan is not double-reported as self-unknown" || return 1
    local role; role="$(_role_of "$proj/.claude/.session-role.cc-blind")"
    assert_eq "follower" "$role" "a blind scan still yields a follower (measured role: '$role')"
}
run_test "07b: blind scan ⇒ SESSION_LOCK_UNKNOWN only, never SESSION_LOCK_SELF_UNKNOWN, follower" test_blind_scan_is_unknown_not_self_unknown

suite_summary
