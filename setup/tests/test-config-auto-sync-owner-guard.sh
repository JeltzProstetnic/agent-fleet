#!/usr/bin/env bash
# CFG-666 / CFG-665 — the SessionEnd hook must not act on a config repo that a
# DIFFERENT live session holds.
#
# CFG-666 (P0): config-auto-sync.sh rotated — archived and then BLANKED —
# the config repo's session-context.md from ANY other project's shutdown, and
# passed --owner-verified to disarm rotate-session.sh's foreign-lock guard
# (CFG-452) at the one call site where the caller is by definition foreign.
# Measured 2026-09-21: another project's session shutdown (its own Phase 2
# commit 0b1a31a at 12:52:28) blanked a live config-repo session's context
# mid-work (config-repo commit a410acdc at 12:52:32).
#
# CFG-665: the same shutdown staged the config repo by directory and swept a
# live cfg session's in-progress work into an "Auto-sync:" commit (1ced099a,
# 630cb8e3, 030190f5 on the same day). git-sweep-guard.sh cannot see this — it
# is a PreToolUse hook on Bash, and a hook's own `git add` is not a Bash tool
# call — so the owner check has to live in the staging logic itself.
#
# Product under test: the REAL hook, the REAL rotate-session.sh (with its real
# lib.sh and session-lock.sh beside it) and the REAL session-lock.sh in the
# mock config repo. The "other live session" is this test process: its pid is
# alive for the whole test and its ids never match the ids the hook runs with.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO_ROOT/setup/tests/test-helpers.sh"
source "$REPO_ROOT/setup/tests/test-config-auto-sync-helpers.sh"

suite_header "config-auto-sync.sh (CFG-666/CFG-665: config repo held by another live session)"

# CFG666_HOOK_SCRIPT=<path> runs this suite against a candidate hook instead of
# the repo's (e.g. `git show <rev>:global/hooks/config-auto-sync.sh` extracted
# to tmp/), which is how red-before / green-after is shown without a checkout.
HOOK_SCRIPT="${CFG666_HOOK_SCRIPT:-$HOOK_SCRIPT}"

LOCK_LIB="$REPO_ROOT/setup/scripts/session-lock.sh"
ROTATE_REAL="$REPO_ROOT/setup/scripts/rotate-session.sh"
APPEND_REAL="$REPO_ROOT/setup/scripts/append-post-rotation.sh"

# The ids the SHUTTING-DOWN session runs with. They must never match the lock.
_HOOK_ENV=(AFLEET_SESSION_ID=af-other-project CC_SESSION_ID=cc-other-project)

_CFG_GOAL="Mid-work cfg session that must survive a foreign shutdown"

# A populated cfg session-context.md — exactly the state that holds while a
# cfg session is mid-work (goal + a completed item, so rotate has real work).
_populate_cfg_context() {
    cat > "$1/session-context.md" << EOF
# Session Context

## Session Info
- **Last Updated**: 2026-09-21T12:25:00Z
- **Machine**: WSL
- **Working Directory**: $1
- **Session Goal**: $_CFG_GOAL

## Current State
- **Progress**:
- [x] Drained the inbox

## Key Decisions
- keep going
EOF
}

# Mock config repo carrying the real lock library (or the harness mock when
# asked), the real rotate-session.sh and append-post-rotation.sh, a tracked
# work area and a populated cfg context. Everything is committed and pushed, so
# any later commit or index change is the hook's doing. Deliberately NO
# projects/ dir — the live repo has none either.
_prep_cfg_repo() {   # <config_repo> [real-lib|mock-lib]
    local cfg="$1" lib="${2:-real-lib}"
    create_mock_config_repo "$cfg"
    create_tracked_repo_main "$cfg" "$TEST_TMPDIR/remote.git"
    if [[ "$lib" == "real-lib" ]]; then
        cp "$LOCK_LIB" "$cfg/setup/scripts/session-lock.sh"
    fi
    cp "$APPEND_REAL" "$cfg/setup/scripts/append-post-rotation.sh"
    # Delegate to the REAL rotate-session.sh so it sources the real lib.sh and
    # session-lock.sh next to it — the guard under test is the real guard.
    cat > "$cfg/setup/scripts/rotate-session.sh" << STUB
#!/usr/bin/env bash
exec bash "$ROTATE_REAL" "\$@"
STUB
    chmod +x "$cfg/setup/scripts/rotate-session.sh"
    mkdir -p "$cfg/global/hooks" "$cfg/docs" "$cfg/cross-project" "$cfg/.claude"
    echo "hook v1" > "$cfg/global/hooks/x.sh"
    echo "backlog v1" > "$cfg/backlog.md"
    echo "registry v1" > "$cfg/registry.md"
    echo "manifest v1" > "$cfg/template-sync-manifest.md"
    echo "pending v1" > "$cfg/docs/pending-work.md"
    echo "inbox v1" > "$cfg/cross-project/inbox.md"
    _populate_cfg_context "$cfg"
    (cd "$cfg" && git add -A && git commit -q -m "cfg baseline" && git push -q origin main)
}

# A live foreign lock on the config repo: this test process's pid (alive for the
# whole test), bound to ids the hook does not run with.
_hold_cfg_lock_foreign() {
    ( source "$LOCK_LIB"; _write_lock "$1/.claude/.session-lock" "af-cfg-owner" "cc-cfg-owner" "$$" )
}

# Fake CC process tree for the nested-CC cases. session-lock.sh identifies CC
# processes by cmdline (_CC_PROC_RE, env-overridable); pointing it at these
# names makes any real CC running this suite invisible, so the verdict depends
# only on the tree built here. `leader` = one fake CC; `nested` = one under it.
_FAKE_CC_RE='(^|/)fakecc-(leader|nested)([[:space:]]|$)'
_mk_fake_cc_tree() {
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
_under_tree() {   # leader|nested <script> [args]
    local tree="$1"; shift
    case "$tree" in
        leader) _CC_PROC_RE="$_FAKE_CC_RE" bash "$TEST_TMPDIR/fakecc-leader.sh" "$@" ;;
        nested) _CC_PROC_RE="$_FAKE_CC_RE" bash "$TEST_TMPDIR/fakecc-leader.sh" "$TEST_TMPDIR/fakecc-nested.sh" "$@" ;;
    esac
}

# Run the hook as a shutdown of <project_dir>.
#   tree      none (default) | leader | nested   — process tree to run under
#   af / cc   the ids the shutting-down session runs with
#   stdin_id  the session_id CC pipes to the hook on stdin (default: cc)
_run() {   # <config_repo> <project_dir> [tree] [af] [cc] [stdin_id]
    local cfg="$1" proj="$2" tree="${3:-none}" af="${4:-af-other-project}" cc="${5:-cc-other-project}"
    local stdin_id="${6-$cc}"
    local patched
    patched=$(create_patched_hook "$cfg" "$proj" "$TEST_TMPDIR/home")
    # The hook reads its CC session id from stdin JSON via lib-hook-stdin.sh,
    # sourced from its own directory — give the patched copy that library.
    cp "$REPO_ROOT/global/hooks/lib-hook-stdin.sh" "$TEST_TMPDIR/"
    (
        export AFLEET_SESSION_ID="$af" CC_SESSION_ID="$cc"
        if [[ "$tree" == none ]]; then
            printf '{"session_id":"%s"}' "$stdin_id" | bash "$patched"
        else
            _mk_fake_cc_tree
            printf '{"session_id":"%s"}' "$stdin_id" | _under_tree "$tree" "$patched"
        fi
    ) 2>/dev/null
}

_commits() { git -C "$1" rev-list --count HEAD; }
_goal_lines() { grep -c "$_CFG_GOAL" "$1/session-context.md" 2>/dev/null || true; }

# ── CFG-666: a foreign shutdown must not rotate a live cfg session's context ─

test_held_context_not_rotated() {
    local cfg="$TEST_TMPDIR/cfg" proj="$TEST_TMPDIR/life"
    mkdir -p "$proj" "$TEST_TMPDIR/home"
    _prep_cfg_repo "$cfg"
    _hold_cfg_lock_foreign "$cfg"
    local before rc=0
    before=$(_commits "$cfg")
    _run "$cfg" "$proj" || rc=$?
    assert_eq "0" "$rc" "hook exits 0 (measured rc=$rc)" || return 1
    local goal; goal=$(_goal_lines "$cfg")
    assert_eq "1" "$goal" "live cfg context keeps its goal line (measured $goal occurrence(s)) — a foreign shutdown must not blank it" || return 1
    assert_file_not_exists "$cfg/session-history.md" "no archive written by the foreign shutdown — rotation is the owner's job" || return 1
    if [[ -f "$cfg/.sync-warnings.log" ]]; then
        assert_file_not_contains "$cfg/.sync-warnings.log" "rotate-session failed" "a guard refusal is not a rotation failure" || return 1
    fi
    local after; after=$(_commits "$cfg")
    assert_eq "$before" "$after" "no Auto-sync commit against a held config repo (measured $before -> $after)"
}
run_test "CFG-666: foreign shutdown leaves a live cfg session-context.md intact (no rotate, no blank)" test_held_context_not_rotated

test_unheld_context_still_rotated() {
    # The fix must not over-reach: with nobody holding the config repo, its
    # stale context is rotated exactly as before, through the bare command.
    local cfg="$TEST_TMPDIR/cfg" proj="$TEST_TMPDIR/life"
    mkdir -p "$proj" "$TEST_TMPDIR/home"
    _prep_cfg_repo "$cfg"
    _run "$cfg" "$proj" || true
    local goal; goal=$(_goal_lines "$cfg")
    assert_eq "0" "$goal" "unheld cfg context is rotated to the blank template (measured $goal goal line(s) left)" || return 1
    assert_file_exists "$cfg/session-history.md" "archive written for the unheld repo" || return 1
    assert_file_contains "$cfg/session-history.md" "$_CFG_GOAL" "archive carries the rotated goal"
}
run_test "CFG-666: unheld cfg context is still rotated (no over-reach)" test_unheld_context_still_rotated

test_stale_lock_does_not_block_rotation() {
    # A lock whose recorded pid is dead and with no live CC in the repo is
    # stale, not foreign — the guard must not turn it into a permanent skip.
    local cfg="$TEST_TMPDIR/cfg" proj="$TEST_TMPDIR/life"
    mkdir -p "$proj" "$TEST_TMPDIR/home"
    _prep_cfg_repo "$cfg"
    sleep 0.01 & local dead=$!; wait "$dead" 2>/dev/null || true
    ( source "$LOCK_LIB"; _write_lock "$cfg/.claude/.session-lock" "af-gone" "cc-gone" "$dead" )
    _run "$cfg" "$proj" || true
    local goal; goal=$(_goal_lines "$cfg")
    assert_eq "0" "$goal" "stale lock (dead pid $dead) does not block rotation (measured $goal goal line(s) left)" || return 1
    assert_file_exists "$cfg/session-history.md" "archive written despite the stale lock"
}
run_test "CFG-666: a stale lock (dead pid) does not block rotation" test_stale_lock_does_not_block_rotation

# ── CFG-665: a foreign shutdown must not sweep a live cfg session's work ─────

test_held_work_not_swept() {
    local cfg="$TEST_TMPDIR/cfg" proj="$TEST_TMPDIR/life"
    mkdir -p "$proj" "$TEST_TMPDIR/home"
    _prep_cfg_repo "$cfg"
    # The live cfg session's in-progress edits: tracked files across every
    # directory the hook stages, plus an untracked new file.
    echo "in-progress hook edit" >> "$cfg/global/hooks/x.sh"
    echo "in-progress backlog edit" >> "$cfg/backlog.md"
    echo "in-progress pending edit" >> "$cfg/docs/pending-work.md"
    echo "in-progress inbox edit" >> "$cfg/cross-project/inbox.md"
    echo "in-progress new knowledge" > "$cfg/global/knowledge-new.md"
    _hold_cfg_lock_foreign "$cfg"
    local before after staged
    before=$(_commits "$cfg")
    _run "$cfg" "$proj" || true
    after=$(_commits "$cfg")
    assert_eq "$before" "$after" "no Auto-sync commit while another session holds the config repo (measured $before -> $after)" || return 1
    staged=$(git -C "$cfg" diff --cached --name-only | wc -l | tr -d ' ')
    assert_eq "0" "$staged" "nothing left staged by the foreign shutdown (measured $staged path(s))" || return 1
    local dirty; dirty=$(grep -l "in-progress" "$cfg/global/hooks/x.sh" "$cfg/backlog.md" "$cfg/docs/pending-work.md" "$cfg/cross-project/inbox.md" "$cfg/global/knowledge-new.md" 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "5" "$dirty" "all 5 in-progress edits still in the working tree (measured $dirty)"
}
run_test "CFG-665: foreign shutdown does not stage or commit a live cfg session's in-progress work" test_held_work_not_swept

test_held_already_staged_work_not_committed() {
    # The 030190f5 shape: the live cfg session has ALREADY staged its commit
    # and is about to run `git commit`. A foreign shutdown must not commit it.
    local cfg="$TEST_TMPDIR/cfg" proj="$TEST_TMPDIR/life"
    mkdir -p "$proj" "$TEST_TMPDIR/home"
    _prep_cfg_repo "$cfg"
    echo "staged by the owner" >> "$cfg/backlog.md"
    git -C "$cfg" add backlog.md
    _hold_cfg_lock_foreign "$cfg"
    local before after
    before=$(_commits "$cfg")
    _run "$cfg" "$proj" || true
    after=$(_commits "$cfg")
    assert_eq "$before" "$after" "the owner's staged-but-uncommitted work is not committed from a foreign shutdown (measured $before -> $after)" || return 1
    local staged; staged=$(git -C "$cfg" diff --cached --name-only)
    assert_contains "$staged" "backlog.md" "the owner's staged file is still staged, untouched"
}
run_test "CFG-665: foreign shutdown does not commit what the live cfg session has already staged" test_held_already_staged_work_not_committed

test_held_post_rotation_marker_not_consumed() {
    # Phase 3.5 (append-post-rotation.sh) CONSUMES .post-rotation-commit. Run
    # from a foreign shutdown it steals the live cfg session's marker, so that
    # session's own Phase 3.5 later finds nothing.
    local cfg="$TEST_TMPDIR/cfg" proj="$TEST_TMPDIR/life"
    mkdir -p "$proj" "$TEST_TMPDIR/home"
    _prep_cfg_repo "$cfg"
    echo "$(git -C "$cfg" rev-parse HEAD) $(date +%s)" > "$cfg/.post-rotation-commit"
    _hold_cfg_lock_foreign "$cfg"
    _run "$cfg" "$proj" || true
    assert_file_exists "$cfg/.post-rotation-commit" "the live cfg session's .post-rotation-commit marker survives a foreign shutdown"
}
run_test "CFG-665: foreign shutdown does not consume a live cfg session's post-rotation marker" test_held_post_rotation_marker_not_consumed

test_unheld_directory_staging_unchanged() {
    # The backlog's explicit constraint: do NOT narrow the directory staging —
    # with nobody holding the repo, global/ backlog.md registry.md still sweep.
    local cfg="$TEST_TMPDIR/cfg" proj="$TEST_TMPDIR/life"
    mkdir -p "$proj" "$TEST_TMPDIR/home"
    _prep_cfg_repo "$cfg"
    echo "left by a finished session" >> "$cfg/global/hooks/x.sh"
    echo "left by a finished session" >> "$cfg/backlog.md"
    echo "left by a finished session" >> "$cfg/registry.md"
    _run "$cfg" "$proj" || true
    local committed; committed=$(git -C "$cfg" diff-tree --no-commit-id --name-only -r HEAD)
    assert_contains "$committed" "global/hooks/x.sh" "global/ still staged for an unheld repo" || return 1
    assert_contains "$committed" "backlog.md" "backlog.md still staged for an unheld repo" || return 1
    assert_contains "$committed" "registry.md" "registry.md still staged for an unheld repo"
}
run_test "CFG-665: unheld config repo is still staged by directory (breadth not narrowed)" test_unheld_directory_staging_unchanged

test_unheld_docs_and_cross_project_staged_without_projects_dir() {
    # `git add docs/ projects/ cross-project/` fails ATOMICALLY when any one
    # pathspec matches nothing, and the live repo has no projects/ dir —
    # measured 2026-09-23: "fatal: pathspec 'projects/' did not match any
    # files". So docs/ and cross-project/ were never staged on a real machine
    # (docs/session-log.md is absent from a410acdc although rotation wrote it).
    local cfg="$TEST_TMPDIR/cfg" proj="$TEST_TMPDIR/life"
    mkdir -p "$proj" "$TEST_TMPDIR/home"
    _prep_cfg_repo "$cfg"
    [[ ! -d "$cfg/projects" ]] || { echo "precondition: projects/ must be absent"; return 1; }
    echo "left by a finished session" >> "$cfg/docs/pending-work.md"
    echo "left by a finished session" >> "$cfg/cross-project/inbox.md"
    _run "$cfg" "$proj" || true
    local committed; committed=$(git -C "$cfg" diff-tree --no-commit-id --name-only -r HEAD)
    assert_contains "$committed" "docs/pending-work.md" "docs/ staged although projects/ is absent" || return 1
    assert_contains "$committed" "cross-project/inbox.md" "cross-project/ staged although projects/ is absent"
}
run_test "CFG-665: docs/ and cross-project/ are staged even with no projects/ dir (production layout)" test_unheld_docs_and_cross_project_staged_without_projects_dir

# ── Phase 1: a mis-marked nested CC must not rotate or sweep ITS OWN project ─

test_mismarked_nested_leader_cannot_rotate_or_sweep() {
    # The trigger side of CFG-666: a nested CC in the config repo whose role
    # marker says `leader` (what the ungated 07b override wrote) reaches the
    # leader path with the leader's lock still present — its release fails on
    # the cc-id mismatch. Phase 1 then ran `rotate-session.sh $ORIGINAL_DIR
    # --owner-verified` and blanked the LEADER's live context; Phase 3.5 ate
    # the leader's marker; Phase 3 swept the leader's work.
    local cfg="$TEST_TMPDIR/cfg"
    mkdir -p "$TEST_TMPDIR/home"
    _prep_cfg_repo "$cfg"
    echo "leader's in-progress hook edit" >> "$cfg/global/hooks/x.sh"
    echo "$(git -C "$cfg" rev-parse HEAD) $(date +%s)" > "$cfg/.post-rotation-commit"
    sleep 120 & local lpid=$!
    ( source "$LOCK_LIB"; _write_lock "$cfg/.claude/.session-lock" "af-cfg-owner" "cc-cfg-owner" "$lpid" )
    printf 'leader\n' > "$cfg/.claude/.session-role.cc-nested"
    local before after
    before=$(_commits "$cfg")
    _run "$cfg" "$cfg" nested af-cfg-owner cc-nested || true
    kill "$lpid" 2>/dev/null || true
    after=$(_commits "$cfg")
    local goal; goal=$(_goal_lines "$cfg")
    assert_eq "1" "$goal" "the leader's live context keeps its goal line (measured $goal occurrence(s))" || return 1
    assert_file_not_exists "$cfg/session-history.md" "no archive written by the mis-marked nested CC" || return 1
    assert_eq "$before" "$after" "no Auto-sync commit by the mis-marked nested CC (measured $before -> $after)" || return 1
    assert_file_exists "$cfg/.post-rotation-commit" "the leader's post-rotation marker survives" || return 1
    local staged; staged=$(git -C "$cfg" diff --cached --name-only | wc -l | tr -d ' ')
    assert_eq "0" "$staged" "nothing staged by the mis-marked nested CC (measured $staged path(s))" || return 1
    assert_file_exists "$cfg/.sync-warnings.log" "the refusal is surfaced to the next session" || return 1
    assert_file_contains "$cfg/.sync-warnings.log" "refused" "the warning names a guard refusal, not a rotation failure"
}
run_test "CFG-666: a nested CC mis-marked leader cannot rotate or sweep its own project (no --owner-verified at Phase 1)" test_mismarked_nested_leader_cannot_rotate_or_sweep

test_unreleased_genuine_leader_still_rotates() {
    # Dropping the flag must not cost the genuine leader its rotation. With the
    # lock still present at Phase 1 (its release failed: no cc id on stdin),
    # rotate-session.sh's guard recognises the owner through the lock's cc id
    # binding and rotates on the bare command.
    local cfg="$TEST_TMPDIR/cfg"
    mkdir -p "$TEST_TMPDIR/home"
    _prep_cfg_repo "$cfg"
    sleep 120 & local lpid=$!
    ( source "$LOCK_LIB"; _write_lock "$cfg/.claude/.session-lock" "af-mine" "cc-mine" "$lpid" )
    printf 'leader\n' > "$cfg/.claude/.session-role.af-mine"
    local before after
    before=$(_commits "$cfg")
    _run "$cfg" "$cfg" leader af-mine cc-mine "" || true
    kill "$lpid" 2>/dev/null || true
    after=$(_commits "$cfg")
    local goal; goal=$(_goal_lines "$cfg")
    assert_eq "0" "$goal" "the genuine leader's context is rotated (measured $goal goal line(s) left)" || return 1
    assert_file_exists "$cfg/session-history.md" "archive written for the genuine leader" || return 1
    assert_eq "$((before + 1))" "$after" "the genuine leader still commits its rotation (measured $before -> $after)"
}
run_test "CFG-666: the genuine leader with an unreleased lock still rotates on the bare command" test_unreleased_genuine_leader_still_rotates

# ── Second line of defence: rotate-session.sh's own guard ────────────────────

test_rotate_guard_holds_when_hook_cannot_check() {
    # With the harness's mock lock lib (no check_lock) the hook cannot see the
    # foreign session itself. Dropping --owner-verified at the CONFIG_REPO call
    # site lets rotate-session.sh's real guard refuse (exit 3), and the hook
    # must read that as "held by another session", not as a rotation failure.
    local cfg="$TEST_TMPDIR/cfg" proj="$TEST_TMPDIR/life"
    mkdir -p "$proj" "$TEST_TMPDIR/home"
    _prep_cfg_repo "$cfg" mock-lib
    echo "in-progress hook edit" >> "$cfg/global/hooks/x.sh"
    _hold_cfg_lock_foreign "$cfg"
    local before after
    before=$(_commits "$cfg")
    _run "$cfg" "$proj" || true
    after=$(_commits "$cfg")
    local goal; goal=$(_goal_lines "$cfg")
    assert_eq "1" "$goal" "rotate-session's guard kept the live context (measured $goal goal line(s))" || return 1
    assert_file_not_exists "$cfg/session-history.md" "no archive written through the bypass" || return 1
    if [[ -f "$cfg/.sync-warnings.log" ]]; then
        assert_file_not_contains "$cfg/.sync-warnings.log" "rotate-session failed" "exit 3 (guard refusal) is not logged as a failure" || return 1
    fi
    assert_eq "$before" "$after" "the guard's refusal also stops the sweep (measured $before -> $after)"
}
run_test "CFG-666: rotate-session.sh's own guard is honoured when the hook cannot check the lock" test_rotate_guard_holds_when_hook_cannot_check

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
