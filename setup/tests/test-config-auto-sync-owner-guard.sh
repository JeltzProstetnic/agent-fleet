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

# The builders (_prep_cfg_repo, _hold_cfg_lock_foreign, _run, the fake CC
# tree, _arm_template_push, …) are shared with test-config-auto-sync-held-phases.sh.
source "$REPO_ROOT/setup/tests/test-config-auto-sync-owner-fixtures.sh"

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
    # Under the shutting-down session's own CC, as in production: a lock check
    # that sees no CC at all answers "unknown" and keeps the repo (CFG-673).
    _run "$cfg" "$proj" leader || true
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
    _run "$cfg" "$proj" leader || true   # own CC visible (CFG-673), as in production
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

test_commit_message_names_every_swept_file() {
    # The backlog's minimum for CFG-665: a sweep must never again be invisible.
    # Whatever the directory staging picks up — tracked edits AND new files, in
    # every staged directory — is named, path by path, in the commit body, so a
    # session whose work was swept can see it in `git log` instead of finding a
    # green tree and wondering. Nobody holds the repo here, so the sweep is
    # legitimate; the assertion is about what the commit SAYS.
    local cfg="$TEST_TMPDIR/cfg" proj="$TEST_TMPDIR/life"
    mkdir -p "$proj" "$TEST_TMPDIR/home"
    _prep_cfg_repo "$cfg"
    echo "left by a finished session" >> "$cfg/global/hooks/x.sh"
    echo "left by a finished session" >> "$cfg/backlog.md"
    echo "left by a finished session" >> "$cfg/docs/pending-work.md"
    echo "left by a finished session" >> "$cfg/cross-project/inbox.md"
    echo "new module, still untracked" > "$cfg/global/hooks/new-check.sh"
    _run "$cfg" "$proj" || true
    local subject body committed f n
    subject=$(git -C "$cfg" log -1 --format=%s)
    assert_contains "$subject" "Auto-sync:" "precondition: the sweep commit was made (subject: '$subject')" || return 1
    body=$(git -C "$cfg" log -1 --format=%b)
    committed=$(git -C "$cfg" diff-tree --no-commit-id --name-only -r HEAD)
    # The five edits above plus whatever the real rotate-session.sh wrote for
    # the (unheld) cfg context — the count is measured, not assumed.
    n=$(printf '%s\n' "$committed" | grep -c . || true)
    for f in global/hooks/x.sh backlog.md docs/pending-work.md cross-project/inbox.md global/hooks/new-check.sh; do
        assert_contains "$committed" "$f" "precondition: the directory staging swept '$f'" || return 1
    done
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        assert_contains "$body" "$f" "the commit body names swept file '$f'" || return 1
    done <<< "$committed"
    assert_contains "$body" "$n file(s)" "the commit body states the measured count ($n file(s))"
}
run_test "CFG-665: the Auto-sync commit names every file it swept, with the measured count" test_commit_message_names_every_swept_file

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

# ── CFG-673 / GH#9: a blind lock check is "unknown", never "stale" ───────────

test_blind_check_treats_cfg_repo_as_held() {
    # The lock check sees /proc but no CC process at all, not even the one
    # shutting down (a CC matcher that recognises nothing here; in Claude
    # Code's Bash sandbox, a PID namespace). Every recorded pid then reads dead
    # and "nobody live" is the scan's blindness, not the machine's state.
    # check_lock answers rc 4 (cannot determine) and keeps the lock; the hook
    # must treat the config repo as held and record that the state is unknown.
    local cfg="$TEST_TMPDIR/cfg" proj="$TEST_TMPDIR/life"
    mkdir -p "$proj" "$TEST_TMPDIR/home"
    _prep_cfg_repo "$cfg"
    sleep 0.01 & local dead=$!; wait "$dead" 2>/dev/null || true
    ( source "$LOCK_LIB"; _write_lock "$cfg/.claude/.session-lock" "af-cfg-owner" "cc-cfg-owner" "$dead" )
    local before after
    before=$(_commits "$cfg")
    _CC_PROC_RE="(^|/)cfg673-no-such-cc-$$([[:space:]]|$)" _run "$cfg" "$proj" || true
    after=$(_commits "$cfg")
    assert_file_exists "$cfg/.claude/.session-lock" "the cfg lock is not deleted on a blind scan" || return 1
    local goal; goal=$(_goal_lines "$cfg")
    assert_eq "1" "$goal" "the cfg context is not rotated while its holder is unknown (measured $goal goal line(s))" || return 1
    assert_file_not_exists "$cfg/session-history.md" "no archive written" || return 1
    assert_eq "$before" "$after" "no Auto-sync commit against a config repo whose holder is unknown (measured $before -> $after)" || return 1
    assert_file_exists "$cfg/.sync-warnings.log" "the unknown state is recorded for the next session" || return 1
    assert_file_contains "$cfg/.sync-warnings.log" "unknown" "the record says the lock state is unknown"
}
run_test "CFG-673: blind lock check ⇒ config repo treated as held, lock kept, state recorded as unknown" test_blind_check_treats_cfg_repo_as_held

# ── CFG-665 (Phase 0.8): a foreign-held config repo is never propagated ──────
# template-push.sh copies the config repo's WORKING TREE — another live session's
# uncommitted, half-built files included — into ~/agent-fleet, the PUBLIC
# template, and pushes it. Phase 0.8 ran before Phase 3 had asked who holds the
# repo, so another project's shutdown pushed a live cfg session's uncommitted
# files twice on 2026-11-11 (agent-fleet c8e613c, 67df308). The verdict must be
# taken BEFORE Phase 0.8 and must be the same one Phase 3 acts on.

# _arm_template_push (mock template-push.sh recording argv, mock ~/agent-fleet)
# comes from the shared fixtures.

# The deferral is an AUDIT line under $HOME/.claude/logs, never a drift-log line:
# checks/04-auto-fix.sh Check 4.5 surfaces every .sync-warnings.log line at the
# next SessionStart of ANY project as drift to fix with `sync.sh deploy`.
_DEFER_AUDIT_LOG=""
_assert_not_propagated() {   # <config_repo> <before_commits> <why>
    local cfg="$1" before="$2" why="$3"
    local calls=0 n=0
    [[ -f "$_TPL_ARGV" ]] && calls=$(grep -c . "$_TPL_ARGV" || true)
    assert_eq "0" "$calls" "template-push.sh never invoked — not even --dry-run — $why (measured $calls call(s))" || return 1
    _DEFER_AUDIT_LOG="$TEST_TMPDIR/home/.claude/logs/template-push-deferred.log"
    assert_file_exists "$_DEFER_AUDIT_LOG" "the deferral is recorded in the audit log" || return 1
    [[ -f "$_DEFER_AUDIT_LOG" ]] && n=$(grep -c "TEMPLATE_PUSH_DEFERRED" "$_DEFER_AUDIT_LOG" || true)
    assert_eq "1" "$n" "exactly one TEMPLATE_PUSH_DEFERRED audit line (measured $n)" || return 1
    if [[ -f "$cfg/.sync-warnings.log" ]]; then
        assert_file_not_contains "$cfg/.sync-warnings.log" "TEMPLATE_PUSH_DEFERRED" "the deferral is NOT in the drift log (SessionStart would surface it as drift to deploy)" || return 1
    fi
    assert_file_not_exists "$cfg/.template-push-failed" "a deferral is not a failure: no marker, no streak" || return 1
    local after; after=$(_commits "$cfg")
    assert_eq "$before" "$after" "Phase 3 verdict unchanged: no Auto-sync commit (measured $before -> $after)" || return 1
    local staged; staged=$(git -C "$cfg" diff --cached --name-only | wc -l | tr -d ' ')
    assert_eq "0" "$staged" "Phase 3 verdict unchanged: nothing staged (measured $staged path(s))"
}

test_phase08_skipped_when_cfg_held_on_this_machine() {
    # check_lock rc 2: another live session on this machine (this test process)
    # holds the config repo; a foreign project's shutdown must not propagate.
    local cfg="$TEST_TMPDIR/cfg" proj="$TEST_TMPDIR/life"
    mkdir -p "$proj" "$TEST_TMPDIR/home"
    _prep_cfg_repo "$cfg"
    _arm_template_push "$cfg"
    echo "half-built, uncommitted" >> "$cfg/global/hooks/x.sh"
    _hold_cfg_lock_foreign "$cfg"
    local before; before=$(_commits "$cfg")
    _run "$cfg" "$proj" || true
    _assert_not_propagated "$cfg" "$before" "while another live session on this machine holds the config repo (check_lock=2)"
}
run_test "CFG-665: Phase 0.8 is skipped when another live session on this machine holds the config repo (rc 2)" test_phase08_skipped_when_cfg_held_on_this_machine

test_phase08_skipped_when_cfg_held_on_other_machine() {
    # check_lock rc 3: the lock names another machine — unverifiable, held.
    local cfg="$TEST_TMPDIR/cfg" proj="$TEST_TMPDIR/life"
    mkdir -p "$proj" "$TEST_TMPDIR/home"
    _prep_cfg_repo "$cfg"
    _arm_template_push "$cfg"
    printf '{"machine":"other-host-%s","pid":1,"sessionId":"af-cfg-owner","timestamp":"2026-11-11T00:00:00Z","user":"test","ccSessionId":"cc-cfg-owner"}\n' "$$" \
        > "$cfg/.claude/.session-lock"
    local before; before=$(_commits "$cfg")
    _run "$cfg" "$proj" || true
    _assert_not_propagated "$cfg" "$before" "while a lock from another machine holds the config repo (check_lock=3)"
}
run_test "CFG-665: Phase 0.8 is skipped when a lock from another machine holds the config repo (rc 3)" test_phase08_skipped_when_cfg_held_on_other_machine

test_phase08_skipped_when_cfg_holder_unknown() {
    # check_lock rc 4: a blind scan (no CC visible at all) — fail closed, as
    # Phase 3 does (CFG-673): no propagation while the holder is unknown.
    local cfg="$TEST_TMPDIR/cfg" proj="$TEST_TMPDIR/life"
    mkdir -p "$proj" "$TEST_TMPDIR/home"
    _prep_cfg_repo "$cfg"
    _arm_template_push "$cfg"
    sleep 0.01 & local dead=$!; wait "$dead" 2>/dev/null || true
    ( source "$LOCK_LIB"; _write_lock "$cfg/.claude/.session-lock" "af-cfg-owner" "cc-cfg-owner" "$dead" )
    local before; before=$(_commits "$cfg")
    _CC_PROC_RE="(^|/)cfg673-no-such-cc-$$([[:space:]]|$)" _run "$cfg" "$proj" || true
    _assert_not_propagated "$cfg" "$before" "while the config repo's holder is unknown (check_lock=4)" || return 1
    assert_file_contains "$cfg/.sync-warnings.log" "unknown" "the unknown state is still recorded"
}
run_test "CFG-665: Phase 0.8 is skipped when the config repo's holder is unknown (rc 4, fail closed)" test_phase08_skipped_when_cfg_holder_unknown

test_phase08_skipped_by_mismarked_nested_cc_in_cfg() {
    # ORIGINAL_DIR == CONFIG_REPO: a nested CC in the config repo mis-marked
    # leader ends while the leader's lock is still there. Phase 1's guard will
    # refuse its rotation; Phase 0.8 must reach the same verdict EARLIER and not
    # push the leader's working tree.
    local cfg="$TEST_TMPDIR/cfg"
    mkdir -p "$TEST_TMPDIR/home"
    _prep_cfg_repo "$cfg"
    _arm_template_push "$cfg"
    echo "leader's half-built edit" >> "$cfg/global/hooks/x.sh"
    sleep 120 & local lpid=$!
    ( source "$LOCK_LIB"; _write_lock "$cfg/.claude/.session-lock" "af-cfg-owner" "cc-cfg-owner" "$lpid" )
    printf 'leader\n' > "$cfg/.claude/.session-role.cc-nested"
    local before; before=$(_commits "$cfg")
    _run "$cfg" "$cfg" nested af-cfg-owner cc-nested || true
    kill "$lpid" 2>/dev/null || true
    _assert_not_propagated "$cfg" "$before" "by a nested CC mis-marked leader in the config repo itself"
}
run_test "CFG-665: Phase 0.8 is skipped by a nested CC mis-marked leader in the config repo (ORIGINAL_DIR == CONFIG_REPO)" test_phase08_skipped_by_mismarked_nested_cc_in_cfg

test_phase08_deferral_leaves_failure_streak_alone() {
    # A deferral is not a run: an existing failure marker keeps its streak
    # byte-for-byte — neither advanced (no failure) nor cleared (no success).
    local cfg="$TEST_TMPDIR/cfg" proj="$TEST_TMPDIR/life"
    mkdir -p "$proj" "$TEST_TMPDIR/home"
    _prep_cfg_repo "$cfg"
    _arm_template_push "$cfg"
    printf 'time=2026-11-10 01:00:00 UTC\nfirst_failed=2026-11-09 01:00:00 UTC\nfirst_failed_epoch=1794099600\nconsecutive=2\nexit_code=3\ndrift_files=1\noutput_tail=held\n' \
        > "$cfg/.template-push-failed"
    local seed; seed=$(cat "$cfg/.template-push-failed")
    _hold_cfg_lock_foreign "$cfg"
    _run "$cfg" "$proj" || true
    local calls=0
    [[ -f "$_TPL_ARGV" ]] && calls=$(grep -c . "$_TPL_ARGV" || true)
    assert_eq "0" "$calls" "template-push.sh not invoked despite the marker (measured $calls call(s))" || return 1
    assert_file_exists "$cfg/.template-push-failed" "the marker survives the deferral" || return 1
    assert_eq "$seed" "$(cat "$cfg/.template-push-failed")" "the marker is byte-identical: streak neither advanced nor cleared"
}
run_test "CFG-665: a Phase 0.8 deferral neither advances nor clears the failure streak" test_phase08_deferral_leaves_failure_streak_alone

_assert_no_deferral() {   # <config_repo> — a run that propagated recorded no deferral anywhere
    assert_file_not_exists "$TEST_TMPDIR/home/.claude/logs/template-push-deferred.log" "no deferral audit line for a run that propagated" || return 1
    if [[ -f "$1/.sync-warnings.log" ]]; then
        assert_file_not_contains "$1/.sync-warnings.log" "TEMPLATE_PUSH_DEFERRED" "no deferral in the drift log" || return 1
    fi
    true
}

test_phase08_runs_when_cfg_unheld() {
    # No over-reach: with nobody holding the config repo (own CC visible, no
    # lock) a foreign project's shutdown still propagates exactly as before —
    # dry-run first, then the real pass on drift.
    local cfg="$TEST_TMPDIR/cfg" proj="$TEST_TMPDIR/life"
    mkdir -p "$proj" "$TEST_TMPDIR/home"
    _prep_cfg_repo "$cfg"
    _arm_template_push "$cfg"
    _run "$cfg" "$proj" leader || true
    assert_file_exists "$_TPL_ARGV" "template-push.sh invoked for an unheld config repo" || return 1
    local calls; calls=$(grep -c . "$_TPL_ARGV" || true)
    assert_eq "2" "$calls" "dry-run then the real pass (measured $calls call(s))" || return 1
    assert_eq "--dry-run" "$(sed -n 1p "$_TPL_ARGV")" "first call is the dry-run" || return 1
    assert_eq "--commit" "$(sed -n 2p "$_TPL_ARGV")" "second call is the real pass (--commit: mock template has no origin)" || return 1
    _assert_no_deferral "$cfg"
}
run_test "CFG-665: Phase 0.8 still propagates when nobody holds the config repo (no over-reach)" test_phase08_runs_when_cfg_unheld

test_phase08_runs_for_cfg_own_shutdown() {
    # The ending session IS the cfg session and owns the lock (its release
    # failed: no cc id on stdin — the test_unreleased_genuine_leader shape).
    # check_lock answers 1 (ours): propagation runs.
    local cfg="$TEST_TMPDIR/cfg"
    mkdir -p "$TEST_TMPDIR/home"
    _prep_cfg_repo "$cfg"
    _arm_template_push "$cfg"
    sleep 120 & local lpid=$!
    ( source "$LOCK_LIB"; _write_lock "$cfg/.claude/.session-lock" "af-mine" "cc-mine" "$lpid" )
    printf 'leader\n' > "$cfg/.claude/.session-role.af-mine"
    _run "$cfg" "$cfg" leader af-mine cc-mine "" || true
    kill "$lpid" 2>/dev/null || true
    assert_file_exists "$_TPL_ARGV" "template-push.sh invoked by the cfg session's own shutdown" || return 1
    local calls; calls=$(grep -c . "$_TPL_ARGV" || true)
    assert_eq "2" "$calls" "dry-run then the real pass (measured $calls call(s))" || return 1
    _assert_no_deferral "$cfg"
}
run_test "CFG-665: Phase 0.8 runs for the cfg session's own shutdown (owner, lock still present)" test_phase08_runs_for_cfg_own_shutdown

test_phase08_runs_for_cfg_own_shutdown_lock_released() {
    # The ordinary cfg shutdown: the leader released its own lock in Phase -1,
    # so no lock is present and nothing is foreign — propagation runs.
    local cfg="$TEST_TMPDIR/cfg"
    mkdir -p "$TEST_TMPDIR/home"
    _prep_cfg_repo "$cfg"
    _arm_template_push "$cfg"
    _run "$cfg" "$cfg" leader || true
    assert_file_exists "$_TPL_ARGV" "template-push.sh invoked by the released-lock cfg shutdown" || return 1
    local calls; calls=$(grep -c . "$_TPL_ARGV" || true)
    assert_eq "2" "$calls" "dry-run then the real pass (measured $calls call(s))" || return 1
    _assert_no_deferral "$cfg"
}
run_test "CFG-665: Phase 0.8 runs for the cfg session's own shutdown (lock already released)" test_phase08_runs_for_cfg_own_shutdown_lock_released

# ── CFG-665 review: the verdict's other two sources, and the lock-less holder ─

# _write_lock_from_template_push (a template-push.sh mock whose --dry-run is the
# moment a cfg session APPEARS) comes from the shared fixtures.

_assert_phase3_held_after_late_arrival() {   # <config_repo> <before_commits> <why>
    local cfg="$1" before="$2" why="$3"
    local calls; calls=$(grep -c . "$_TPL_ARGV" 2>/dev/null || true)
    assert_eq "2" "$calls" "precondition: Phase 0.8 ran — nobody held the repo when the early probe looked (measured $calls call(s))" || return 1
    local after; after=$(_commits "$cfg")
    assert_eq "$before" "$after" "no Auto-sync commit — $why (measured $before -> $after)" || return 1
    local staged; staged=$(git -C "$cfg" diff --cached --name-only | wc -l | tr -d ' ')
    assert_eq "0" "$staged" "nothing staged (measured $staged path(s))" || return 1
    assert_file_contains "$cfg/global/hooks/x.sh" "in-progress edit" "the arriving session's edit is still in the working tree"
}

test_phase3_takes_phase1_verdict_when_holder_gone_by_phase3() {
    # E-ORIN: ORIGINAL_DIR == CONFIG_REPO. No lock when the early probe runs; a
    # foreign session appears during Phase 0.8, so Phase 1's guard refuses the
    # rotation (_ORIG_HELD_BY_OTHER=1); by Phase 3 that session is gone again
    # (the rotate stub kills the holder as it returns), so the re-probe finds a
    # stale lock and no holder. Only the OR-in of Phase 1's verdict keeps Phase
    # 3 from staging and committing. Mutant check: `if false` there → red.
    local cfg="$TEST_TMPDIR/cfg"
    mkdir -p "$TEST_TMPDIR/home"
    _prep_cfg_repo "$cfg"
    sleep 120 & local lpid=$!
    _write_lock_from_template_push "$cfg" "$lpid" also-edit
    cat > "$cfg/setup/scripts/rotate-session.sh" << STUB
#!/usr/bin/env bash
bash "$ROTATE_REAL" "\$@"; rc=\$?
kill "$lpid" 2>/dev/null
exit \$rc
STUB
    local before; before=$(_commits "$cfg")
    _run "$cfg" "$cfg" leader || true
    kill "$lpid" 2>/dev/null || true
    local goal; goal=$(_goal_lines "$cfg")
    assert_eq "1" "$goal" "precondition: Phase 1's guard refused — the context is intact (measured $goal goal line(s))" || return 1
    _assert_phase3_held_after_late_arrival "$cfg" "$before" "Phase 3 takes Phase 1's verdict although the re-probe no longer sees a holder"
}
run_test "CFG-665: Phase 3 keeps Phase 1's refusal when the holder is gone again by Phase 3 (ORIGINAL_DIR == CONFIG_REPO)" test_phase3_takes_phase1_verdict_when_holder_gone_by_phase3

test_phase3_reprobe_catches_holder_arriving_during_phase08() {
    # E-TOCTOU: a foreign project's shutdown. Nobody holds the config repo when
    # the early probe looks; a cfg session appears during Phase 0.8 and is still
    # live at Phase 3. The cfg context is ABSENT, so rotate-session.sh's guard
    # cannot be what refuses: only the re-probe under the flock stops the sweep.
    local cfg="$TEST_TMPDIR/cfg" proj="$TEST_TMPDIR/life"
    mkdir -p "$proj" "$TEST_TMPDIR/home"
    _prep_cfg_repo "$cfg"
    git -C "$cfg" rm -q session-context.md && git -C "$cfg" commit -q -m "no cfg context" && git -C "$cfg" push -q origin main
    sleep 120 & local lpid=$!
    _write_lock_from_template_push "$cfg" "$lpid" also-edit
    local before; before=$(_commits "$cfg")
    _run "$cfg" "$proj" leader || true
    kill "$lpid" 2>/dev/null || true
    _assert_phase3_held_after_late_arrival "$cfg" "$before" "the re-probe under the flock sees the session that arrived during Phase 0.8"
}
run_test "CFG-665: Phase 3 re-probes under the flock and sees a holder that arrived during Phase 0.8" test_phase3_reprobe_catches_holder_arriving_during_phase08

test_phase08_skipped_when_foreign_cc_lives_in_cfg_without_lock() {
    # No lock file at all, but a live foreign CC is cwd'd in the config repo
    # (CFG-468: a session whose lock was lost or never written). check_lock
    # answers 2 from the process scan alone; Phase 0.8 must not propagate.
    local cfg="$TEST_TMPDIR/cfg" proj="$TEST_TMPDIR/life"
    mkdir -p "$proj" "$TEST_TMPDIR/home"
    _prep_cfg_repo "$cfg"
    _arm_template_push "$cfg"
    [[ ! -f "$cfg/.claude/.session-lock" ]] || { echo "precondition: no lock file"; return 1; }
    env -C "$cfg" bash -c 'exec -a fakecc-nested sleep 120' & local fpid=$!
    sleep 0.2
    local before; before=$(_commits "$cfg")
    _run "$cfg" "$proj" leader || true
    kill "$fpid" 2>/dev/null || true
    _assert_not_propagated "$cfg" "$before" "while a lock-less foreign CC is cwd'd in the config repo (check_lock=2 from the process scan)"
}
run_test "CFG-665: Phase 0.8 is skipped when a lock-less foreign CC is cwd'd in the config repo" test_phase08_skipped_when_foreign_cc_lives_in_cfg_without_lock

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
