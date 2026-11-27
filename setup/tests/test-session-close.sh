#!/usr/bin/env bash
# Tests for setup/scripts/session-close.sh — `afx session-close` (CFG-1093 P-SHUTDOWN).
#
# One verb for the command steps of the shutdown checklist (decided Q-1093-SHUTDOWN, 2026-11-25):
# clean-permissions → dashboard row (--auto) → handover-check (a GATE here: a gap refuses
# before rotation) → rotate-session → sync.sh deploy → anti-lockout-check on the live files.
# Decided 2026-11-26: anti-lockout runs AFTER deploy, in every project whose close ran the deploy
# (Q-SC-ORDER); the verb does not commit or push (Q-SC-COMMIT); a failing non-gate step warns
# and the run continues, exiting non-zero at the end (Q-SC-FAIL).
# Exit: 0 all passed · 1 a gate refused · 2 usage · 4 finished with warnings.
#
# Every external step is a stub that logs its call, so nothing here touches live files;
# handover-check.sh and rotate-session.sh run for real where the gate itself is the subject.
source "$(dirname "$0")/test-helpers.sh"

SCRIPT="$REPO_ROOT/setup/scripts/session-close.sh"

suite_header "session-close.sh (CFG-1093: afx session-close)"

# _stub <name> — a script that logs "<name> <args>" and exits with $STUB_<NAME>_RC (default 0)
_stub() {
    local name="$1" var
    var="STUB_$(tr '[:lower:]-' '[:upper:]_' <<<"$name")_RC"
    mkdir -p "$TEST_TMPDIR/stubs"
    cat > "$TEST_TMPDIR/stubs/$name.sh" <<EOF
#!/usr/bin/env bash
echo "$name \$*" >> "$TEST_TMPDIR/calls.log"
echo "$name output line"
exit \${$var:-0}
EOF
}

_fixture() {  # project "beta" at $TEST_TMPDIR/home/beta, registered in the cache
    mkdir -p "$TEST_TMPDIR/home/beta/docs"
    : > "$TEST_TMPDIR/calls.log"
    cat > "$TEST_TMPDIR/cache.md" <<'EOF'
| Project | Priority | Parent | Path | Type | Tasks | Size | Deadline | P1Names | LastDone |
|---------|----------|--------|------|------|-------|------|----------|---------|----------|
| beta | P2 | — | ~/beta | code | 1P2 | 340M |  |  |  |
EOF
    local s
    for s in clean-permissions dashboard-row handover-check rotate-session sync held-check anti-lockout-check; do _stub "$s"; done
}

# _ctx <recovery-body> — a populated session-context whose handover file carries "Carried item"
_ctx() {
    local d="$TEST_TMPDIR/home/beta"
    cat > "$d/session-context.md" <<EOF
# Session Context

## Session Info
- **Last Updated**: 2026-11-26T22:00Z
- **Machine**: test-box
- **Working Directory**: $d
- **Session Goal**: Ship the thing

## Current State
- **Progress** (use \`- [x]\` checkbox for each completed item):
  - [x] Did the first part

## Key Decisions

## Recovery Instructions
$1

## Next Session Task
task: true
file: docs/pending-x.md
backlog: none
description: resume
EOF
    printf '%s\n' "- Carried item" > "$d/docs/pending-x.md"
}

_blank_ctx() {
    printf '# Session Context\n\n## Session Info\n- **Session Goal**:\n\n## Recovery Instructions\n\n## Next Session Task\n' \
        > "$TEST_TMPDIR/home/beta/session-context.md"
}

# _close [args…] — runs the verb with every step stubbed unless the caller unset an override.
# Sets RC and OUT in the caller.
_close() {
    RC=0
    OUT=$(env HOME="$TEST_TMPDIR/home" DASHBOARD_CACHE="$TEST_TMPDIR/cache.md" \
        SC_CLEAN_PERMISSIONS="${SC_CLEAN_PERMISSIONS-$TEST_TMPDIR/stubs/clean-permissions.sh}" \
        SC_DASHBOARD_ROW="${SC_DASHBOARD_ROW-$TEST_TMPDIR/stubs/dashboard-row.sh}" \
        SC_HANDOVER_CHECK="${SC_HANDOVER_CHECK-$TEST_TMPDIR/stubs/handover-check.sh}" \
        SC_ROTATE="${SC_ROTATE-$TEST_TMPDIR/stubs/rotate-session.sh}" \
        SC_SYNC="${SC_SYNC-$TEST_TMPDIR/stubs/sync.sh}" \
        SC_HELD_CHECK="${SC_HELD_CHECK-$TEST_TMPDIR/stubs/held-check.sh}" \
        SC_ANTI_LOCKOUT="${SC_ANTI_LOCKOUT-$TEST_TMPDIR/stubs/anti-lockout-check.sh}" \
        bash "$SCRIPT" "$@" 2>&1) || RC=$?
}

_calls() { awk '{print $1}' "$TEST_TMPDIR/calls.log" | paste -sd' ' -; }

# ── Happy path and ordering ──────────────────────────────────────────────────

t_all_steps_in_order() {
    _fixture; _ctx "- Carried item"
    _close --deadline "ship 2026-12-01" "$TEST_TMPDIR/home/beta"
    assert_eq "0" "$RC" "exit 0 when every step passes (output: $OUT)" || return 1
    assert_eq "clean-permissions dashboard-row handover-check rotate-session held-check sync anti-lockout-check" "$(_calls)" \
        "steps run in the approved order, anti-lockout after deploy" || return 1
    assert_file_contains "$TEST_TMPDIR/calls.log" "dashboard-row beta --auto --deadline ship 2026-12-01" "row by project name, --auto + deadline" || return 1
    assert_file_contains "$TEST_TMPDIR/calls.log" "sync deploy" "deploy is sync.sh deploy"
}
run_test "every step runs once, in order; anti-lockout after deploy" t_all_steps_in_order

t_no_deadline_only_auto() {
    _fixture; _ctx "- Carried item"
    _close "$TEST_TMPDIR/home/beta"
    assert_file_contains "$TEST_TMPDIR/calls.log" "dashboard-row beta --auto" "auto only" || return 1
    assert_file_not_contains "$TEST_TMPDIR/calls.log" "--deadline" "no deadline flag when none given"
}
run_test "without --deadline the row is written with --auto alone" t_no_deadline_only_auto

t_defaults_to_cwd() {
    _fixture; _ctx "- Carried item"
    RC=0
    OUT=$(cd "$TEST_TMPDIR/home/beta" && env HOME="$TEST_TMPDIR/home" DASHBOARD_CACHE="$TEST_TMPDIR/cache.md" \
        SC_CLEAN_PERMISSIONS="$TEST_TMPDIR/stubs/clean-permissions.sh" SC_DASHBOARD_ROW="$TEST_TMPDIR/stubs/dashboard-row.sh" \
        SC_HANDOVER_CHECK="$TEST_TMPDIR/stubs/handover-check.sh" SC_ROTATE="$TEST_TMPDIR/stubs/rotate-session.sh" \
        SC_SYNC="$TEST_TMPDIR/stubs/sync.sh" SC_HELD_CHECK="$TEST_TMPDIR/stubs/held-check.sh" \
        SC_ANTI_LOCKOUT="$TEST_TMPDIR/stubs/anti-lockout-check.sh" bash "$SCRIPT" 2>&1) || RC=$?
    assert_eq "0" "$RC" "exit 0" || return 1
    assert_file_contains "$TEST_TMPDIR/calls.log" "rotate-session $TEST_TMPDIR/home/beta" "the project dir is the current directory"
}
run_test "the project dir defaults to the current directory" t_defaults_to_cwd

t_usage_error() {
    _fixture
    _close --bogus
    assert_eq "2" "$RC" "unknown option → 2" || return 1
    assert_eq "" "$(_calls)" "nothing ran"
}
run_test "an unknown option is a usage error and runs nothing" t_usage_error

# ── Gates ────────────────────────────────────────────────────────────────────

t_handover_gap_refuses_before_rotation() {
    _fixture; _ctx "- Tell the user the backup is 3 days stale"
    SC_HANDOVER_CHECK="" SC_ROTATE="" _close_real_gate
    assert_eq "1" "$RC" "a handover gap refuses (output: $OUT)" || return 1
    assert_contains "$OUT" "Tell the user the backup is 3 days stale" "the uncarried item is named" || return 1
    assert_file_not_exists "$TEST_TMPDIR/home/beta/session-history.md" "rotation did not run" || return 1
    assert_file_contains "$TEST_TMPDIR/home/beta/session-context.md" "Ship the thing" "context left intact" || return 1
    assert_file_not_contains "$TEST_TMPDIR/calls.log" "sync deploy" "no deploy after a refusal"
}
# Real handover-check.sh and rotate-session.sh, stubs for the rest.
_close_real_gate() {
    RC=0
    OUT=$(env HOME="$TEST_TMPDIR/home" DASHBOARD_CACHE="$TEST_TMPDIR/cache.md" \
        SC_CLEAN_PERMISSIONS="$TEST_TMPDIR/stubs/clean-permissions.sh" SC_DASHBOARD_ROW="$TEST_TMPDIR/stubs/dashboard-row.sh" \
        SC_SYNC="$TEST_TMPDIR/stubs/sync.sh" SC_HELD_CHECK="$TEST_TMPDIR/stubs/held-check.sh" \
        SC_ANTI_LOCKOUT="$TEST_TMPDIR/stubs/anti-lockout-check.sh" bash "$SCRIPT" "$TEST_TMPDIR/home/beta" 2>&1) || RC=$?
}
run_test "a handover gap refuses before rotation (real handover-check.sh)" t_handover_gap_refuses_before_rotation

t_carried_handover_rotates_for_real() {
    _fixture; _ctx "- Carried item"
    _close_real_gate
    assert_eq "0" "$RC" "exit 0 (output: $OUT)" || return 1
    assert_file_contains "$TEST_TMPDIR/home/beta/session-history.md" "Ship the thing" "real rotation archived the session" || return 1
    assert_file_exists "$TEST_TMPDIR/home/beta/next-session-task.md" "handover extracted"
}
run_test "a carried handover rotates (real handover-check.sh + rotate-session.sh)" t_carried_handover_rotates_for_real

t_rotation_refused_stops() {
    _fixture; _ctx "- Carried item"
    STUB_ROTATE_SESSION_RC=3 _close "$TEST_TMPDIR/home/beta"
    assert_eq "1" "$RC" "rotation refusal is a gate" || return 1
    assert_contains "$OUT" "another live session" "exit 3 is named as held by another session" || return 1
    assert_file_not_contains "$TEST_TMPDIR/calls.log" "sync deploy" "no deploy"
}
run_test "rotation refused (held by another session) stops the run" t_rotation_refused_stops

t_rotation_failed_stops() {
    _fixture; _ctx "- Carried item"
    STUB_ROTATE_SESSION_RC=1 _close "$TEST_TMPDIR/home/beta"
    assert_eq "1" "$RC" "a failed rotation is a gate" || return 1
    assert_contains "$OUT" "rotate-session output line" "rotation's own message is shown" || return 1
    assert_file_not_contains "$TEST_TMPDIR/calls.log" "sync deploy" "no deploy"
}
run_test "rotation failed stops the run and shows rotation's message" t_rotation_failed_stops

t_anti_lockout_fail_is_a_gate() {
    _fixture; _ctx "- Carried item"
    STUB_ANTI_LOCKOUT_CHECK_RC=1 _close "$TEST_TMPDIR/home/beta"
    assert_eq "1" "$RC" "anti-lockout failure refuses" || return 1
    assert_contains "$OUT" "before ending the session" "says to fix it while the session is open"
}
run_test "an anti-lockout failure is a gate" t_anti_lockout_fail_is_a_gate

# ── Non-gate failures warn and continue ──────────────────────────────────────

t_clean_permissions_fail_warns() {
    _fixture; _ctx "- Carried item"
    STUB_CLEAN_PERMISSIONS_RC=1 _close "$TEST_TMPDIR/home/beta"
    assert_eq "4" "$RC" "finished with a warning" || return 1
    assert_contains "$(_calls)" "anti-lockout-check" "the remaining steps ran"
}
run_test "clean-permissions failing warns, continues, exits 4" t_clean_permissions_fail_warns

t_dashboard_fail_warns() {
    _fixture; _ctx "- Carried item"
    STUB_DASHBOARD_ROW_RC=1 _close "$TEST_TMPDIR/home/beta"
    assert_eq "4" "$RC" "finished with a warning" || return 1
    assert_contains "$(_calls)" "rotate-session" "rotation still ran"
}
run_test "dashboard-row failing warns, continues, exits 4" t_dashboard_fail_warns

t_deploy_fail_still_checks() {
    _fixture; _ctx "- Carried item"
    STUB_SYNC_RC=1 _close "$TEST_TMPDIR/home/beta"
    assert_eq "4" "$RC" "a failed deploy is a warning" || return 1
    assert_contains "$(_calls)" "anti-lockout-check" "anti-lockout still checks what is live" || return 1
    # Fable review 2026-11-27 #4: sync.sh deploy never writes .sync-failed (only the SessionEnd hook
    # does), so pointing there sent the agent to a missing or stale file. Deploy's output is the evidence.
    assert_contains "$OUT" "sync output line" "deploy's own output is shown" || return 1
    assert_not_contains "$OUT" ".sync-failed" "no pointer to a file deploy does not write"
}
run_test "a failed deploy warns, shows deploy's output, and anti-lockout still runs" t_deploy_fail_still_checks

# Fable review #2: anti-lockout check 10 gates on the CONFIG REPO's uncommitted Tier-2 tree, which
# another project's session may not touch — so outside cfg the verb runs only the live-file checks.
t_live_only_outside_the_config_repo() {
    _fixture; _ctx "- Carried item"
    _close "$TEST_TMPDIR/home/beta"
    assert_file_contains "$TEST_TMPDIR/calls.log" "anti-lockout-check --live-only" "another project: live checks only"
}
run_test "outside the config repo anti-lockout runs with --live-only" t_live_only_outside_the_config_repo

t_full_gate_in_the_config_repo() {
    _fixture; _ctx "- Carried item"
    CONFIG_REPO="$TEST_TMPDIR/home/beta" _close "$TEST_TMPDIR/home/beta"
    assert_eq "0" "$RC" "exit 0 (output: $OUT)" || return 1
    assert_file_contains "$TEST_TMPDIR/calls.log" "^anti-lockout-check $" "the config repo's own close keeps the full gate" || return 1
    assert_file_not_contains "$TEST_TMPDIR/calls.log" "--live-only" "no --live-only there"
}
run_test "in the config repo itself anti-lockout runs the full gate" t_full_gate_in_the_config_repo

# Fable review #3: an empty Session Goal is not "rotated" when the context has content.
t_empty_goal_with_content_refuses() {
    _fixture; _ctx "- Carried item"
    sed -i 's/^- \*\*Session Goal\*\*: .*/- **Session Goal**:/' "$TEST_TMPDIR/home/beta/session-context.md"
    _close "$TEST_TMPDIR/home/beta"
    assert_eq "1" "$RC" "refused (output: $OUT)" || return 1
    assert_contains "$OUT" "no Session Goal" "names the missing goal" || return 1
    assert_file_not_contains "$TEST_TMPDIR/calls.log" "rotate-session" "rotation not run" || return 1
    assert_file_not_contains "$TEST_TMPDIR/calls.log" "sync deploy" "nothing after it ran"
}
run_test "a context with content but an empty Session Goal is refused, not skipped" t_empty_goal_with_content_refuses

# Fable second pass #3: rotate-session.sh also counts a legacy `### Completed` section as content.
t_legacy_completed_section_is_content() {
    _fixture
    printf '# Session Context\n\n## Session Info\n- **Session Goal**:\n\n### Completed\n- Shipped the thing\n\n## Key Decisions\n\n## Recovery Instructions\n\n## Next Session Task\n' \
        > "$TEST_TMPDIR/home/beta/session-context.md"
    _close "$TEST_TMPDIR/home/beta"
    assert_eq "1" "$RC" "refused, not skipped as rotated (output: $OUT)" || return 1
    assert_contains "$OUT" "no Session Goal" "names the missing goal"
}
run_test "a legacy ### Completed section counts as content (goalless → refused)" t_legacy_completed_section_is_content

# Fable second pass #1: a git worktree of the config repo IS the config repo for the E2E gate, and
# the gate must look at the tree being closed, not at the main checkout.
t_config_repo_worktree_keeps_the_full_gate() {
    _fixture; _ctx "- Carried item"
    local main="$TEST_TMPDIR/cfgmain" wt="$TEST_TMPDIR/cfgwt"
    mkdir -p "$main"
    git -C "$main" init -q; git -C "$main" config user.email t@t; git -C "$main" config user.name t
    echo x > "$main/f"; git -C "$main" add f; git -C "$main" commit -qm init
    git -C "$main" worktree add -q "$wt" 2>/dev/null || return 1
    cp "$TEST_TMPDIR/home/beta/session-context.md" "$wt/"; mkdir -p "$wt/docs"; cp "$TEST_TMPDIR/home/beta/docs/pending-x.md" "$wt/docs/"
    cat > "$TEST_TMPDIR/stubs/anti-lockout-check.sh" <<EOF
#!/usr/bin/env bash
echo "anti-lockout-check \$* repo=\${ANTILOCKOUT_REPO_DIR:-unset}" >> "$TEST_TMPDIR/calls.log"
exit 0
EOF
    CONFIG_REPO="$main" _close "$wt"
    assert_eq "0" "$RC" "exit 0 (output: $OUT)" || return 1
    assert_file_not_contains "$TEST_TMPDIR/calls.log" "--live-only" "a worktree of the config repo keeps the full gate" || return 1
    assert_file_contains "$TEST_TMPDIR/calls.log" "repo=$(cd "$wt" && pwd -P)" "check 10 looks at the closing worktree"
}
run_test "a worktree of the config repo keeps the full gate, pointed at the worktree" t_config_repo_worktree_keeps_the_full_gate

# Fable review #7: drive the REAL dashboard-row.sh on a multi-row cache with a child row first.
t_real_dashboard_row_on_multi_row_cache() {
    _fixture; _ctx "- Carried item"
    cat > "$TEST_TMPDIR/cache.md" <<'EOF'
| Project | Priority | Parent | Path | Type | Tasks | Size | Deadline | P1Names | LastDone |
|---------|----------|--------|------|------|-------|------|----------|---------|----------|
| kid | P2 | beta | ~/kid | code | 9P1 | 9G |  |  |  |
| beta | P2 | — | ~/beta | code | 1P2 | 340M |  |  |  |
EOF
    mkdir -p "$TEST_TMPDIR/home/kid"
    printf '# Backlog\n- [ ] [P1] `B-1` **One**: x\n' > "$TEST_TMPDIR/home/beta/backlog.md"
    SC_DASHBOARD_ROW="" _close --deadline "soon" "$TEST_TMPDIR/home/beta"
    assert_eq "0" "$RC" "exit 0 (output: $OUT)" || return 1
    assert_file_contains "$TEST_TMPDIR/cache.md" "^| beta | P2 | — | ~/beta | code | 1P1 | " "beta's row has beta's count" || return 1
    assert_file_contains "$TEST_TMPDIR/cache.md" "| soon |" "deadline written" || return 1
    assert_file_contains "$TEST_TMPDIR/cache.md" "^| kid | P2 | beta | ~/kid | code | 9P1 | 9G |" "kid untouched"
}
run_test "with the real dashboard-row.sh, a child row listed first is left alone" t_real_dashboard_row_on_multi_row_cache

# ── Skips ────────────────────────────────────────────────────────────────────

t_unregistered_dir_skips_row() {
    _fixture; _ctx "- Carried item"
    mkdir -p "$TEST_TMPDIR/home/gamma"; cp "$TEST_TMPDIR/home/beta/session-context.md" "$TEST_TMPDIR/home/gamma/"
    mkdir -p "$TEST_TMPDIR/home/gamma/docs"; cp "$TEST_TMPDIR/home/beta/docs/pending-x.md" "$TEST_TMPDIR/home/gamma/docs/"
    _close "$TEST_TMPDIR/home/gamma"
    assert_eq "0" "$RC" "not an error" || return 1
    assert_file_not_contains "$TEST_TMPDIR/calls.log" "dashboard-row" "no row write" || return 1
    assert_contains "$OUT" "no dashboard row" "the skip is stated"
}
run_test "a dir with no dashboard row skips the row step with a note" t_unregistered_dir_skips_row

t_held_config_repo_skips_deploy_and_check() {
    _fixture; _ctx "- Carried item"
    STUB_HELD_CHECK_RC=2 _close "$TEST_TMPDIR/home/beta"
    assert_eq "0" "$RC" "a held config repo is the expected skip" || return 1
    assert_file_not_contains "$TEST_TMPDIR/calls.log" "sync deploy" "no deploy" || return 1
    assert_file_not_contains "$TEST_TMPDIR/calls.log" "anti-lockout-check" "no check when no deploy ran" || return 1
    assert_contains "$OUT" "held by another live session" "the skip is stated"
}
run_test "config repo held by another session: deploy and anti-lockout skipped" t_held_config_repo_skips_deploy_and_check

t_held_unknown_fails_closed() {
    _fixture; _ctx "- Carried item"
    STUB_HELD_CHECK_RC=4 _close "$TEST_TMPDIR/home/beta"
    assert_eq "4" "$RC" "unknown holder → skipped with a warning" || return 1
    assert_file_not_contains "$TEST_TMPDIR/calls.log" "sync deploy" "fail closed: no deploy"
}
run_test "config repo holder unknown: deploy skipped (fail closed), warning" t_held_unknown_fails_closed

t_already_rotated() {
    _fixture; _blank_ctx
    _close "$TEST_TMPDIR/home/beta"
    assert_eq "0" "$RC" "re-run after rotation is fine" || return 1
    assert_file_not_contains "$TEST_TMPDIR/calls.log" "rotate-session" "rotation not re-run" || return 1
    assert_contains "$OUT" "already rotated" "stated"
}
run_test "an already-rotated context is a no-op for rotation (safe re-run)" t_already_rotated

suite_summary
