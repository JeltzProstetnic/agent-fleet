#!/usr/bin/env bash
# CFG-965 — every SessionEnd step that acts on the config repo honours the
# owner verdict, and the verdict itself cannot fail open.
#
# CFG-665/666 gated the template propagation, rotation, staging and commit on
# "is the config repo held by a DIFFERENT live session?". Found by that fix
# (2026-11-11): Phase 3 still DEPLOYED the held WORKING TREE — a live session's
# half-edited hooks, settings and knowledge — over the live ~/.claude from any
# project's shutdown; Phase 0.6 deleted cfg docs/pending-*.md; Phase 0 wrote
# into the cfg tree; Phase 0.75 reported the holder's unfinished edits as T2
# work for the next session; Phase 5's shim had no way to know; Phase 0.8 ran
# outside any lock. And (SF-1) the verdict was taken through check_lock
# sourced from the working tree it protects: a holder half-way through editing
# session-lock.sh left check_lock undefined and the probe answered "not held".
#
# MG's decision Q-965-DEPLOY (2026-11-11): a held repo is NOT deployed at all —
# no HEAD-only or temporary-checkout deploy; the holder deploys at its own
# shutdown and every SessionStart deploys anyway.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO_ROOT/setup/tests/test-helpers.sh"
source "$REPO_ROOT/setup/tests/test-config-auto-sync-helpers.sh"
source "$REPO_ROOT/setup/tests/test-config-auto-sync-owner-fixtures.sh"

suite_header "config-auto-sync.sh (CFG-965: held config repo — deploy, auto-clean, collect, T2, shim, Phase 0.8 lock, fail-closed probe)"

# Audit lines for EXPECTED skips go to $HOME/.claude/logs/template-push-deferred.log
# (mock home), never to .sync-warnings.log, which SessionStart surfaces as drift.
# grep -c prints nothing for a missing file (and "0", rc 1, for one with no
# match): a missing log is a count of 0, never an empty string.
_count() { local n; n=$(grep -c -e "$1" "$2" 2>/dev/null); echo "${n:-0}"; }
_audit_lines() { _count "$1" "$TEST_TMPDIR/home/.claude/logs/template-push-deferred.log"; }
_sync_calls() { _count "^$1\$" "$TEST_TMPDIR/sync-calls.log"; }
_tpl_calls() { _count . "$_TPL_ARGV"; }

# ── Phase 3: a held working tree is never deployed (Q-965-DEPLOY) ───────────

test_held_skips_deploy() {
    local cfg="$TEST_TMPDIR/cfg" proj="$TEST_TMPDIR/life"
    mkdir -p "$proj" "$TEST_TMPDIR/home"
    _prep_cfg_repo "$cfg"
    _arm_recording_sync "$cfg" "$TEST_TMPDIR/sync-calls.log"
    echo "half-edited hook — must never reach the live ~/.claude" >> "$cfg/global/hooks/x.sh"
    _hold_cfg_lock_foreign "$cfg"
    _run "$cfg" "$proj" || true
    local checks deploys n
    checks=$(_sync_calls check); deploys=$(_sync_calls deploy)
    assert_eq "1" "$checks" "precondition: sync.sh is reachable — Phase 0.7 ran its check (measured $checks)" || return 1
    assert_eq "0" "$deploys" "sync.sh deploy is NOT run while another live session holds the config repo (measured $deploys call(s))" || return 1
    n=$(_audit_lines DEPLOY_DEFERRED)
    assert_eq "1" "$n" "exactly one DEPLOY_DEFERRED audit line (measured $n)" || return 1
    # Counted, not guarded by `-f`: the drift log usually does not exist here,
    # and a missing file must read as 0 lines, not as an assertion skipped.
    local in_drift failed
    in_drift=$(_count DEPLOY_DEFERRED "$cfg/.sync-warnings.log"); failed=$(_count 'deploy failed' "$cfg/.sync-warnings.log")
    assert_eq "0" "$in_drift" "an expected skip is not drift (measured $in_drift DEPLOY_DEFERRED line(s) in .sync-warnings.log)" || return 1
    assert_eq "0" "$failed" "a skip is not a deploy failure (measured $failed 'deploy failed' line(s))" || return 1
    assert_file_not_exists "$cfg/.sync-failed" "a skipped deploy is not a failed shutdown"
}
run_test "CFG-965: Phase 3 skips sync.sh deploy entirely while another live session holds the config repo" test_held_skips_deploy

test_deploy_skipped_when_holder_arrives_during_phase08() {
    # Nobody holds the repo when the early probe looks; a cfg session appears
    # during Phase 0.8's dry-run and is still live at Phase 3. The re-probe
    # under the flock must gate the deploy too — the last step before the
    # holder's tree would have been copied over ~/.claude.
    local cfg="$TEST_TMPDIR/cfg" proj="$TEST_TMPDIR/life"
    mkdir -p "$proj" "$TEST_TMPDIR/home"
    _prep_cfg_repo "$cfg"
    _arm_recording_sync "$cfg" "$TEST_TMPDIR/sync-calls.log"
    sleep 120 & local lpid=$!
    _write_lock_from_template_push "$cfg" "$lpid" also-edit
    _run "$cfg" "$proj" leader || true
    kill "$lpid" 2>/dev/null || true
    local calls deploys
    calls=$(_tpl_calls)
    assert_eq "2" "$calls" "precondition: Phase 0.8 ran — nobody held the repo when the early probe looked (measured $calls call(s))" || return 1
    deploys=$(_sync_calls deploy)
    assert_eq "0" "$deploys" "the re-probe under the flock also stops the deploy (measured $deploys call(s))"
}
run_test "CFG-965: a holder arriving during Phase 0.8 is caught before the deploy" test_deploy_skipped_when_holder_arrives_during_phase08

test_unheld_still_deploys() {
    local cfg="$TEST_TMPDIR/cfg" proj="$TEST_TMPDIR/life"
    mkdir -p "$proj" "$TEST_TMPDIR/home"
    _prep_cfg_repo "$cfg"
    _arm_recording_sync "$cfg" "$TEST_TMPDIR/sync-calls.log"
    _run "$cfg" "$proj" leader || true
    local deploys; deploys=$(_sync_calls deploy)
    assert_eq "1" "$deploys" "an unheld config repo is deployed exactly once (measured $deploys)" || return 1
    assert_file_not_exists "$TEST_TMPDIR/home/.claude/logs/template-push-deferred.log" "no deferral audit line for an unheld shutdown"
}
run_test "CFG-965: no over-reach — an unheld config repo is still deployed" test_unheld_still_deploys

# ── Phase 0.6: a held repo's docs/pending-*.md are the holder's ──────────────

_install_real_manage_pending() {
    cp "$REPO_ROOT/setup/scripts/manage-pending.sh" "$1/setup/scripts/manage-pending.sh"
    chmod +x "$1/setup/scripts/manage-pending.sh"
}
# A pending file whose only backlog item is [x] — exactly what --auto-clean deletes.
_stage_cleanable_pending() {   # <config_repo>
    printf '<!-- Action: reference -->\n<!-- Tracked-by: CFG-1 -->\n\nShipped.\n' > "$1/docs/pending-shipped.md"
    printf -- '- [x] `CFG-1` shipped — see docs/pending-shipped.md\n' > "$1/backlog.md"
}

test_unheld_auto_clean_deletes_shipped_pending() {
    local cfg="$TEST_TMPDIR/cfg" proj="$TEST_TMPDIR/life"
    mkdir -p "$proj" "$TEST_TMPDIR/home"
    _prep_cfg_repo "$cfg"
    _install_real_manage_pending "$cfg"
    _stage_cleanable_pending "$cfg"
    _run "$cfg" "$proj" leader || true
    assert_file_not_exists "$cfg/docs/pending-shipped.md" "precondition of the mechanism: an unheld shutdown's auto-clean deletes a pending file whose items are all [x]"
}
run_test "CFG-965: Phase 0.6 still auto-cleans a shipped pending file when nobody holds the config repo" test_unheld_auto_clean_deletes_shipped_pending

test_held_auto_clean_leaves_pending_files() {
    local cfg="$TEST_TMPDIR/cfg" proj="$TEST_TMPDIR/life"
    mkdir -p "$proj" "$TEST_TMPDIR/home"
    _prep_cfg_repo "$cfg"
    _install_real_manage_pending "$cfg"
    _stage_cleanable_pending "$cfg"
    _hold_cfg_lock_foreign "$cfg"
    _run "$cfg" "$proj" || true
    assert_file_exists "$cfg/docs/pending-shipped.md" "a held config repo's docs/pending-*.md are the holder's to demote or delete — a foreign shutdown leaves them" || return 1
    local n; n=$(_audit_lines PENDING_AUTO_CLEAN_DEFERRED)
    assert_eq "1" "$n" "the skip is recorded once in the audit log (measured $n)"
}
run_test "CFG-965: Phase 0.6 does not delete a held config repo's pending files" test_held_auto_clean_leaves_pending_files

# ── Phase 0: the mobile collect writes into the cfg tree ─────────────────────

_arm_mobile_outbox() {   # <config_repo> <log> — a phone outbox with one task; mobile-deploy.sh records argv
    local mobile="$TEST_TMPDIR/home/agent-fleet-mobile"
    mkdir -p "$mobile/inbox"
    printf '# Mobile Outbox\n- [ ] Task from the phone\n' > "$mobile/inbox/outbox.md"
    cat > "$1/setup/scripts/mobile-deploy.sh" << STUB
#!/usr/bin/env bash
echo "\$*" >> "$2"
exit 0
STUB
    chmod +x "$1/setup/scripts/mobile-deploy.sh"
}

test_held_skips_mobile_collect_but_phase4_runs() {
    local cfg="$TEST_TMPDIR/cfg" proj="$TEST_TMPDIR/life" log="$TEST_TMPDIR/mobile.log"
    mkdir -p "$proj" "$TEST_TMPDIR/home"
    _prep_cfg_repo "$cfg"
    _arm_mobile_outbox "$cfg" "$log"
    _hold_cfg_lock_foreign "$cfg"
    _run "$cfg" "$proj" || true
    local collects refreshes n
    collects=$(grep -c -- '--collect' "$log" 2>/dev/null || true)
    assert_eq "0" "$collects" "--collect (appends to the cfg tree's inbox and session log) is not run while the repo is held (measured $collects)" || return 1
    assert_file_contains "$TEST_TMPDIR/home/agent-fleet-mobile/inbox/outbox.md" "Task from the phone" "the phone task is still in the outbox for the holder or the next unheld shutdown" || return 1
    refreshes=$(grep -vc -- '--collect' "$log" 2>/dev/null || true)
    assert_eq "1" "$refreshes" "Phase 4 (read-only snapshot refresh) still runs for a held repo (measured $refreshes deploy-mode call(s))" || return 1
    n=$(_audit_lines MOBILE_COLLECT_DEFERRED)
    assert_eq "1" "$n" "the skip is recorded once in the audit log (measured $n)"
}
run_test "CFG-965: Phase 0 does not collect the phone outbox into a held config repo; Phase 4 still refreshes" test_held_skips_mobile_collect_but_phase4_runs

test_unheld_mobile_collect_runs() {
    local cfg="$TEST_TMPDIR/cfg" proj="$TEST_TMPDIR/life" log="$TEST_TMPDIR/mobile.log"
    mkdir -p "$proj" "$TEST_TMPDIR/home"
    _prep_cfg_repo "$cfg"
    _arm_mobile_outbox "$cfg" "$log"
    _run "$cfg" "$proj" leader || true
    local collects; collects=$(grep -c -- '--collect' "$log" 2>/dev/null || true)
    assert_eq "1" "$collects" "an unheld shutdown still collects the outbox exactly once (measured $collects)"
}
run_test "CFG-965: Phase 0 still collects the phone outbox when nobody holds the config repo" test_unheld_mobile_collect_runs

# ── Phase 0.65: the inbox archive is a cfg-tree write too ───────────────────

_arm_inbox_archive() {   # <config_repo> <log>
    cat > "$1/setup/scripts/inbox-archive.sh" << STUB
#!/usr/bin/env bash
echo "\$*" >> "$2"
exit 0
STUB
    chmod +x "$1/setup/scripts/inbox-archive.sh"
}

test_held_skips_inbox_archive_for_mismarked_nested_cc() {
    # ORIGINAL_DIR == CONFIG_REPO: a nested CC mis-marked leader ends while the
    # leader's lock is still there. Phase 0.65 only ever runs from the config
    # repo's own shutdown, and this is the one shape in which that shutdown is
    # not the holder's.
    local cfg="$TEST_TMPDIR/cfg" log="$TEST_TMPDIR/archive.log"
    mkdir -p "$TEST_TMPDIR/home"
    _prep_cfg_repo "$cfg"
    _arm_inbox_archive "$cfg" "$log"
    sleep 120 & local lpid=$!
    ( source "$LOCK_LIB"; _write_lock "$cfg/.claude/.session-lock" "af-cfg-owner" "cc-cfg-owner" "$lpid" )
    printf 'leader\n' > "$cfg/.claude/.session-role.cc-nested"
    _run "$cfg" "$cfg" nested af-cfg-owner cc-nested || true
    kill "$lpid" 2>/dev/null || true
    assert_file_not_exists "$log" "inbox-archive.sh is not run against the leader's cross-project/inbox.md"
}
run_test "CFG-965: Phase 0.65 does not archive the inbox from a nested CC mis-marked leader" test_held_skips_inbox_archive_for_mismarked_nested_cc

test_unheld_cfg_shutdown_archives_inbox() {
    local cfg="$TEST_TMPDIR/cfg" log="$TEST_TMPDIR/archive.log"
    mkdir -p "$TEST_TMPDIR/home"
    _prep_cfg_repo "$cfg"
    _arm_inbox_archive "$cfg" "$log"
    _run "$cfg" "$cfg" leader || true
    assert_file_exists "$log" "the config repo's own (unheld) shutdown still archives" || return 1
    assert_file_contains "$log" "cross-project/inbox.md" "with the inbox as its argument"
}
run_test "CFG-965: Phase 0.65 still archives from the config repo's own unheld shutdown" test_unheld_cfg_shutdown_archives_inbox

# ── Phase 0.75: the T2 marker describes the holder's unfinished edits ────────

test_held_leaves_existing_t2_marker_alone() {
    local cfg="$TEST_TMPDIR/cfg" proj="$TEST_TMPDIR/life"
    mkdir -p "$proj" "$TEST_TMPDIR/home"
    _prep_cfg_repo "$cfg"
    echo "holder's unfinished hook edit" >> "$cfg/global/hooks/x.sh"
    printf 'T2_EDITS: left by the holder\n' > "$cfg/.t2-edits-pending"
    _hold_cfg_lock_foreign "$cfg"
    _run "$cfg" "$proj" || true
    assert_file_exists "$cfg/.t2-edits-pending" "the holder's own marker is neither removed" || return 1
    assert_eq "T2_EDITS: left by the holder" "$(cat "$cfg/.t2-edits-pending")" "nor rewritten from the holder's working tree" || return 1
    local n; n=$(_audit_lines T2_CHECK_DEFERRED)
    assert_eq "1" "$n" "the skip is recorded once in the audit log (measured $n)"
}
run_test "CFG-965: Phase 0.75 leaves a held config repo's T2 marker exactly as it was" test_held_leaves_existing_t2_marker_alone

test_held_writes_no_t2_marker() {
    local cfg="$TEST_TMPDIR/cfg" proj="$TEST_TMPDIR/life"
    mkdir -p "$proj" "$TEST_TMPDIR/home"
    _prep_cfg_repo "$cfg"
    echo "holder's unfinished hook edit" >> "$cfg/global/hooks/x.sh"
    _hold_cfg_lock_foreign "$cfg"
    _run "$cfg" "$proj" || true
    assert_file_not_exists "$cfg/.t2-edits-pending" "a foreign shutdown does not report the holder's unfinished hook edits as T2 work for the next session"
}
run_test "CFG-965: Phase 0.75 does not write a T2 marker from a held config repo's working tree" test_held_writes_no_t2_marker

test_unheld_t2_marker_names_the_hook_edit() {
    local cfg="$TEST_TMPDIR/cfg" proj="$TEST_TMPDIR/life"
    mkdir -p "$proj" "$TEST_TMPDIR/home"
    _prep_cfg_repo "$cfg"
    echo "left by a finished session" >> "$cfg/global/hooks/x.sh"
    _run "$cfg" "$proj" leader || true
    assert_file_exists "$cfg/.t2-edits-pending" "an unheld shutdown still writes the T2 marker" || return 1
    assert_file_contains "$cfg/.t2-edits-pending" "global/hooks/x.sh" "naming the edited hook"
}
run_test "CFG-965: Phase 0.75 still writes the T2 marker for an unheld config repo" test_unheld_t2_marker_names_the_hook_edit

# ── Phase 5: the deployment-local shim is told the verdict ───────────────────

_arm_recording_shim() {   # <config_repo> <log>
    cat > "$1/setup/scripts/config-auto-sync-local.sh" << EOF
#!/usr/bin/env bash
printf 'CFG_HELD_BY_OTHER=%s\n' "\${CFG_HELD_BY_OTHER-unset}" >> "$2"
EOF
}

test_shim_told_when_held() {
    local cfg="$TEST_TMPDIR/cfg" proj="$TEST_TMPDIR/life" log="$TEST_TMPDIR/shim.log"
    mkdir -p "$proj" "$TEST_TMPDIR/home"
    _prep_cfg_repo "$cfg"
    _arm_recording_shim "$cfg" "$log"
    _hold_cfg_lock_foreign "$cfg"
    _run "$cfg" "$proj" || true
    assert_file_exists "$log" "the shim still runs for a held repo (it touches no cfg working file)" || return 1
    assert_file_contains "$log" "^CFG_HELD_BY_OTHER=1$" "and is told the config repo is held, so a downstream shim can honour it"
}
run_test "CFG-965: Phase 5 passes CFG_HELD_BY_OTHER=1 to the deployment-local shim when the repo is held" test_shim_told_when_held

test_shim_told_when_unheld() {
    local cfg="$TEST_TMPDIR/cfg" proj="$TEST_TMPDIR/life" log="$TEST_TMPDIR/shim.log"
    mkdir -p "$proj" "$TEST_TMPDIR/home"
    _prep_cfg_repo "$cfg"
    _arm_recording_shim "$cfg" "$log"
    _run "$cfg" "$proj" leader || true
    assert_file_exists "$log" "the shim ran" || return 1
    assert_file_contains "$log" "^CFG_HELD_BY_OTHER=0$" "an unheld repo is passed as 0, never unset"
}
run_test "CFG-965: Phase 5 passes CFG_HELD_BY_OTHER=0 to the shim when nobody holds the repo" test_shim_told_when_unheld

# ── Phase 0.8 runs under the config repo lock ────────────────────────────────
# It ran outside any lock, so two shutdowns ending together propagated in
# parallel — two template-push runs into one ~/agent-fleet index, racing the
# push. The same .sync-lock Phase 3 takes now covers it; a busy lock DEFERS the
# push (the drift stays and the next shutdown pushes it), it never fails the
# shutdown and never advances the failure streak.

_SYNC_LOCK_HOLDER=""
_hold_sync_lock() {   # <config_repo> <seconds> <release_stamp_file>
    (
        exec 8>"$1/.sync-lock"
        flock 8
        sleep "$2"
        date +%s%N > "$3"
        flock -u 8
    ) &
    _SYNC_LOCK_HOLDER=$!
    sleep 0.3
}
_release_sync_lock_holder() {
    [[ -z "$_SYNC_LOCK_HOLDER" ]] || { kill "$_SYNC_LOCK_HOLDER" 2>/dev/null || true; wait "$_SYNC_LOCK_HOLDER" 2>/dev/null || true; }
    _SYNC_LOCK_HOLDER=""
}
# template-push.sh mock that stamps when its dry-run STARTED (ns since epoch).
_arm_stamping_template_push() {   # <config_repo> <stamp_file>
    _arm_template_push "$1"
    cat > "$1/setup/scripts/template-push.sh" << STUB
#!/usr/bin/env bash
echo "\$@" >> "$_TPL_ARGV"
case "\$1" in --dry-run) date +%s%N > "$2"; echo "Would copy global/hooks/x.sh" ;; esac
exit 0
STUB
    chmod +x "$1/setup/scripts/template-push.sh"
}

test_phase08_waits_for_the_sync_lock() {
    local cfg="$TEST_TMPDIR/cfg" proj="$TEST_TMPDIR/life"
    mkdir -p "$proj" "$TEST_TMPDIR/home"
    _prep_cfg_repo "$cfg"
    _arm_stamping_template_push "$cfg" "$TEST_TMPDIR/tpl-start.ns"
    # Held well past the hook's pre-0.8 phases (measured >2 s on WSL): with a
    # shorter hold a lock-less Phase 0.8 still started after the release and
    # the mutant survived.
    _hold_sync_lock "$cfg" 8 "$TEST_TMPDIR/released.ns"
    _run "$cfg" "$proj" leader || true
    wait "$_SYNC_LOCK_HOLDER" 2>/dev/null || true; _SYNC_LOCK_HOLDER=""
    local calls; calls=$(_tpl_calls)
    assert_eq "2" "$calls" "the push still happens once the lock is free (measured $calls call(s))" || return 1
    local started released after=0
    started=$(cat "$TEST_TMPDIR/tpl-start.ns" 2>/dev/null || echo 0)
    released=$(cat "$TEST_TMPDIR/released.ns" 2>/dev/null || echo 0)
    [[ "$started" -gt "$released" ]] && after=1
    assert_eq "1" "$after" "template-push started only AFTER the other shutdown released .sync-lock (started $started ns, released $released ns)"
}
run_test "CFG-965: Phase 0.8 waits for .sync-lock — no parallel template push from two shutdowns" test_phase08_waits_for_the_sync_lock

test_phase08_deferred_when_the_sync_lock_stays_busy() {
    local cfg="$TEST_TMPDIR/cfg" proj="$TEST_TMPDIR/life"
    mkdir -p "$proj" "$TEST_TMPDIR/home"
    _prep_cfg_repo "$cfg"
    _arm_template_push "$cfg"
    _hold_sync_lock "$cfg" 4 "$TEST_TMPDIR/released.ns"
    CFG_AUTO_SYNC_LOCK_WAIT=1 _run "$cfg" "$proj" leader || true
    _release_sync_lock_holder
    local calls n
    calls=$(_tpl_calls)
    assert_eq "0" "$calls" "template-push.sh not run — not even the dry-run — while the lock stays busy (measured $calls call(s))" || return 1
    n=$(_audit_lines TEMPLATE_PUSH_DEFERRED)
    assert_eq "1" "$n" "the deferral is one audit line (measured $n)" || return 1
    assert_file_contains "$TEST_TMPDIR/home/.claude/logs/template-push-deferred.log" "busy" "which names the busy lock as the reason" || return 1
    assert_file_not_exists "$cfg/.template-push-failed" "a deferral is not a failure: no marker, no streak"
}
run_test "CFG-965: Phase 0.8 is deferred, not failed, when .sync-lock stays busy" test_phase08_deferred_when_the_sync_lock_stays_busy

# ── SF-1: the verdict must not fail open when check_lock is unavailable ──────
# session-lock.sh is sourced from the config repo's WORKING TREE — the tree the
# holder is editing. A holder half-way through that file (check_lock renamed,
# or a syntax error before it) left check_lock undefined, and the probe used
# to answer "not held" for exactly that session.

# The working tree's session-lock.sh mid-edit: every function intact except
# check_lock, renamed. HEAD still carries the real library.
_rename_live_check_lock() {   # <config_repo>
    sed 's/^check_lock() {/check_lock_wip() {/' "$LOCK_LIB" > "$1/setup/scripts/session-lock.sh"
    grep -q '^check_lock_wip() {' "$1/setup/scripts/session-lock.sh"
}

test_sf1_renamed_live_lib_foreign_holder_still_detected() {
    local cfg="$TEST_TMPDIR/cfg" proj="$TEST_TMPDIR/life"
    mkdir -p "$proj" "$TEST_TMPDIR/home"
    _prep_cfg_repo "$cfg"
    _arm_template_push "$cfg"
    _arm_recording_sync "$cfg" "$TEST_TMPDIR/sync-calls.log"
    _rename_live_check_lock "$cfg" || { echo "fixture: rename failed"; return 1; }
    echo "holder's in-progress edit" >> "$cfg/global/hooks/x.sh"
    _hold_cfg_lock_foreign "$cfg"
    local before after; before=$(_commits "$cfg")
    _run "$cfg" "$proj" || true
    after=$(_commits "$cfg")
    local calls deploys goal
    calls=$(_tpl_calls); deploys=$(_sync_calls deploy); goal=$(_goal_lines "$cfg")
    assert_eq "0" "$calls" "no template push: HEAD's session-lock.sh still sees the foreign holder (measured $calls call(s))" || return 1
    assert_eq "0" "$deploys" "no deploy (measured $deploys)" || return 1
    assert_eq "$before" "$after" "no Auto-sync commit (measured $before -> $after)" || return 1
    assert_eq "1" "$goal" "the holder's context is intact (measured $goal goal line(s))" || return 1
    assert_file_not_exists "$cfg/session-history.md" "no archive written"
}
run_test "CFG-965 SF-1: check_lock renamed in the working tree — HEAD's copy still finds the foreign holder" test_sf1_renamed_live_lib_foreign_holder_still_detected

test_sf1_renamed_live_lib_owner_still_proceeds() {
    # The fallback must resolve OWNERSHIP, not just fail closed: the cfg
    # session's own shutdown (lock still present, bound to its ids) with its
    # check_lock mid-rename still propagates and rotates through HEAD's copy.
    local cfg="$TEST_TMPDIR/cfg"
    mkdir -p "$TEST_TMPDIR/home"
    _prep_cfg_repo "$cfg"
    _arm_template_push "$cfg"
    _rename_live_check_lock "$cfg" || { echo "fixture: rename failed"; return 1; }
    sleep 120 & local lpid=$!
    ( source "$LOCK_LIB"; _write_lock "$cfg/.claude/.session-lock" "af-mine" "cc-mine" "$lpid" )
    printf 'leader\n' > "$cfg/.claude/.session-role.af-mine"
    _run "$cfg" "$cfg" leader af-mine cc-mine "" || true
    kill "$lpid" 2>/dev/null || true
    local calls goal
    calls=$(_tpl_calls); goal=$(_goal_lines "$cfg")
    assert_eq "2" "$calls" "the owner still propagates (dry-run + real pass; measured $calls call(s))" || return 1
    assert_eq "0" "$goal" "the owner's context is rotated (measured $goal goal line(s) left)" || return 1
    assert_file_not_exists "$TEST_TMPDIR/home/.claude/logs/template-push-deferred.log" "nothing was deferred for the owner"
}
run_test "CFG-965 SF-1: check_lock renamed in the working tree — the owner is still recognised through HEAD's copy" test_sf1_renamed_live_lib_owner_still_proceeds

test_sf1_no_usable_library_with_lock_fails_closed() {
    # Neither the working tree nor HEAD yields a check_lock (the harness mock
    # library, committed), and a lock is present: unknown, treated as held,
    # recorded — never "not held".
    local cfg="$TEST_TMPDIR/cfg" proj="$TEST_TMPDIR/life"
    mkdir -p "$proj" "$TEST_TMPDIR/home"
    _prep_cfg_repo "$cfg" mock-lib
    _arm_template_push "$cfg"
    _arm_recording_sync "$cfg" "$TEST_TMPDIR/sync-calls.log"
    echo "holder's in-progress edit" >> "$cfg/global/hooks/x.sh"
    _hold_cfg_lock_foreign "$cfg"
    local before after; before=$(_commits "$cfg")
    _run "$cfg" "$proj" || true
    after=$(_commits "$cfg")
    local calls deploys
    calls=$(_tpl_calls); deploys=$(_sync_calls deploy)
    assert_eq "0" "$calls" "no template push without a usable check_lock while a lock is present (measured $calls call(s))" || return 1
    assert_eq "0" "$deploys" "no deploy (measured $deploys)" || return 1
    assert_eq "$before" "$after" "no Auto-sync commit (measured $before -> $after)" || return 1
    assert_file_exists "$cfg/.sync-warnings.log" "the unknown state is recorded for the next session" || return 1
    assert_file_contains "$cfg/.sync-warnings.log" "unknown" "and called unknown, not held-by-a-known-session"
}
run_test "CFG-965 SF-1: no usable session-lock.sh anywhere + a lock present ⇒ treated as held, recorded as unknown" test_sf1_no_usable_library_with_lock_fails_closed

test_held_lib_missing_fails_closed() {
    # The hook shipped without lib-cfg-held.sh (a deployment defect). The
    # owner check cannot run at all: fail closed, say so where the next
    # SessionStart reads, touch nothing in the config repo.
    local cfg="$TEST_TMPDIR/cfg" proj="$TEST_TMPDIR/life"
    mkdir -p "$proj" "$TEST_TMPDIR/home"
    _prep_cfg_repo "$cfg"
    _arm_template_push "$cfg"
    _arm_recording_sync "$cfg" "$TEST_TMPDIR/sync-calls.log"
    echo "left by a finished session" >> "$cfg/global/hooks/x.sh"
    local before after; before=$(_commits "$cfg")
    CFG965_NO_HELD_LIB=1 _run "$cfg" "$proj" leader || true
    after=$(_commits "$cfg")
    local calls deploys
    calls=$(_tpl_calls); deploys=$(_sync_calls deploy)
    assert_eq "0" "$calls" "no template push without the owner-check library (measured $calls call(s))" || return 1
    assert_eq "0" "$deploys" "no deploy (measured $deploys)" || return 1
    assert_eq "$before" "$after" "no Auto-sync commit (measured $before -> $after)" || return 1
    assert_file_contains "$cfg/.sync-warnings.log" "lib-cfg-held.sh" "the missing library is named for the next session"
}
run_test "CFG-965: the hook without lib-cfg-held.sh beside it fails closed and names the library" test_held_lib_missing_fails_closed

# ── SF-1 residual: check_lock still defined, but a helper it calls is mid-rename ─
# The working tree's check_lock parses and runs; _project_has_live_cc is renamed,
# so its call returns 127 (false), and the dead-pid branch of check_lock deletes
# the lock and answers "free" (session-lock.sh ~779-789). Direct-launch shape:
# the lock's recorded pid is dead (the SessionStart hook's), the holder is a
# live CC cwd'd in the config repo. Reviewer measured with the live copy asked
# first: deploy 1, the holder's lock deleted, its context rotated. HEAD's copy
# must be asked FIRST whenever it is obtainable; the control case (real live
# library) pins that the fix does not change the ordinary verdict.
_rename_live_helper() {   # <config_repo> — check_lock intact, _project_has_live_cc renamed
    sed 's/^_project_has_live_cc() {/_project_has_live_cc_wip() {/' "$LOCK_LIB" > "$1/setup/scripts/session-lock.sh"
    grep -q '^_project_has_live_cc_wip() {' "$1/setup/scripts/session-lock.sh"
}
_HOLDER_CC=""
_start_holder_cc() {   # <dir> — a live fake CC (matched by _FAKE_CC_RE) cwd'd in <dir>, not our descendant
    env -C "$1" bash -c 'exec -a fakecc-nested sleep 300' & _HOLDER_CC=$!
    sleep 0.2
}
_stop_holder_cc() { [[ -z "$_HOLDER_CC" ]] || kill "$_HOLDER_CC" 2>/dev/null || true; _HOLDER_CC=""; }

_sf1_residual_case() {   # <renamed:yes|no> — prints "deploys=<n> lock=<0|1> goal=<n> history=<0|1>"
    local cfg="$TEST_TMPDIR/cfg" proj="$TEST_TMPDIR/life"
    mkdir -p "$proj" "$TEST_TMPDIR/home"
    _prep_cfg_repo "$cfg"
    _arm_recording_sync "$cfg" "$TEST_TMPDIR/sync-calls.log"
    echo "holder's half-edited hook" >> "$cfg/global/hooks/x.sh"
    if [[ "$1" == yes ]]; then _rename_live_helper "$cfg" || { echo "fixture: rename failed"; return 1; }; fi
    _start_holder_cc "$cfg"
    sleep 0.01 & local dead=$!; wait "$dead" 2>/dev/null || true
    ( source "$LOCK_LIB"; _write_lock "$cfg/.claude/.session-lock" "af-cfg-owner" "cc-cfg-owner" "$dead" )
    _run "$cfg" "$proj" leader || true
    _stop_holder_cc
    local lock=0 hist=0
    [[ -f "$cfg/.claude/.session-lock" ]] && lock=1
    [[ -f "$cfg/session-history.md" ]] && hist=1
    printf 'deploys=%s lock=%s goal=%s history=%s\n' "$(_sync_calls deploy)" "$lock" "$(_goal_lines "$cfg")" "$hist"
}
_assert_sf1_residual_held() {   # <result> <label>
    assert_contains "$1" "deploys=0" "$2: no deploy" || return 1
    assert_contains "$1" "lock=1" "$2: the holder's lock is kept" || return 1
    assert_contains "$1" "goal=1" "$2: the holder's context is intact" || return 1
    assert_contains "$1" "history=0" "$2: no archive written"
}

test_sf1_residual_control() {
    local r; r=$(_sf1_residual_case no)
    echo "    measured: $r"
    _assert_sf1_residual_held "$r" "control (real live library, dead-pid lock, live holder CC)"
}
run_test "CFG-965 SF-1 residual control: dead-pid lock + live holder CC in the config repo ⇒ held" test_sf1_residual_control

test_sf1_residual_helper_renamed() {
    local r; r=$(_sf1_residual_case yes)
    echo "    measured: $r"
    _assert_sf1_residual_held "$r" "_project_has_live_cc renamed in the working tree, check_lock intact"
}
run_test "CFG-965 SF-1 residual: a helper renamed in the working tree ⇒ still held, lock kept, no deploy, no rotation" test_sf1_residual_helper_renamed

# ── Phase 0.7 while held: the holder's uncommitted tree is not "drift to deploy" ─
# sync.sh check reports "<file>: drifted (repo ≠ deployed)" for every file the
# holder has edited but not deployed; checks/04-auto-fix.sh surfaces that log at
# the next SessionStart as "fix with sync.sh deploy" — exactly the deploy Phase 3
# now refuses. Those lines are dropped while held (genuine warnings stay, a log
# left with only the summary is not written) and the drop is one audit line.

_arm_sync_check_output() {   # <config_repo> <check output> — sync.sh whose `check` prints <output>, verbs recorded
    cat > "$1/sync.sh" << STUB
#!/usr/bin/env bash
echo "\${1:-}" >> "$TEST_TMPDIR/sync-calls.log"
case "\${1:-}" in check) printf '%s\n' "$2" ;; *) echo "mock-sync: \$*" ;; esac
exit 0
STUB
    chmod +x "$1/sync.sh"
}
# The holder's tree shows up two ways: an edited file is "drifted (repo ≠
# deployed)", a NEW file (e.g. a library it just added) is ": not deployed".
# Both are its uncommitted work, both are dropped while held, and the
# "N issue(s) found" summary — whose N counted them — goes with them.
_DRIFT_MIXED='[WARN] Hook x.sh: drifted (repo ≠ deployed)
[WARN] Rule life/rules.md: drifted (repo ≠ deployed)
[WARN] Hook lib-new.sh: not deployed
[WARN] Hook bar.sh registered twice in settings
[WARN] 4 issue(s) found across propagation chains'
_DRIFT_ONLY='[WARN] Hook x.sh: drifted (repo ≠ deployed)
[WARN] Rule life/rules.md: drifted (repo ≠ deployed)
[WARN] Hook lib-new.sh: not deployed
[WARN] 3 issue(s) found across propagation chains'

test_held_drift_check_drops_repo_vs_deployed_lines() {
    local cfg="$TEST_TMPDIR/cfg" proj="$TEST_TMPDIR/life"
    mkdir -p "$proj" "$TEST_TMPDIR/home"
    _prep_cfg_repo "$cfg"
    _arm_sync_check_output "$cfg" "$_DRIFT_MIXED"
    _hold_cfg_lock_foreign "$cfg"
    _run "$cfg" "$proj" || true
    local dropped notdep kept summary n
    dropped=$(_count 'repo ≠ deployed' "$cfg/.sync-warnings.log"); notdep=$(_count ': not deployed' "$cfg/.sync-warnings.log")
    kept=$(_count 'registered twice' "$cfg/.sync-warnings.log"); summary=$(_count 'issue(s) found' "$cfg/.sync-warnings.log")
    assert_eq "0" "$dropped" "no 'repo ≠ deployed' line reaches the drift log while the repo is held (measured $dropped)" || return 1
    assert_eq "0" "$notdep" "no ': not deployed' line either — the holder's new, undeployed file (measured $notdep)" || return 1
    assert_eq "1" "$kept" "a genuine warning that is not about the holder's tree stays (measured $kept)" || return 1
    assert_eq "0" "$summary" "the 'N issue(s) found' summary, whose N counted the dropped lines, is dropped too (measured $summary)" || return 1
    n=$(_audit_lines DRIFT_CHECK_DEFERRED)
    assert_eq "1" "$n" "one DRIFT_CHECK_DEFERRED audit line (measured $n)" || return 1
    assert_file_contains "$TEST_TMPDIR/home/.claude/logs/template-push-deferred.log" "3 repo" "the audit line counts all three dropped lines"
}
run_test "CFG-965: Phase 0.7 drops the holder's repo≠deployed and not-deployed lines while held, keeps other warnings, audits once" test_held_drift_check_drops_repo_vs_deployed_lines

test_held_drift_check_writes_no_log_when_only_summary_would_remain() {
    local cfg="$TEST_TMPDIR/cfg" proj="$TEST_TMPDIR/life"
    mkdir -p "$proj" "$TEST_TMPDIR/home"
    _prep_cfg_repo "$cfg"
    _arm_sync_check_output "$cfg" "$_DRIFT_ONLY"
    _hold_cfg_lock_foreign "$cfg"
    _run "$cfg" "$proj" || true
    local lines; lines=$(_count . "$cfg/.sync-warnings.log")
    assert_eq "0" "$lines" "a drift log that would hold only the issue summary is not written (measured $lines line(s))" || return 1
    local n; n=$(_audit_lines DRIFT_CHECK_DEFERRED)
    assert_eq "1" "$n" "still one DRIFT_CHECK_DEFERRED audit line (measured $n)"
}
run_test "CFG-965: Phase 0.7 writes no drift log while held when only the summary would remain" test_held_drift_check_writes_no_log_when_only_summary_would_remain

test_unheld_drift_check_keeps_repo_vs_deployed_lines() {
    local cfg="$TEST_TMPDIR/cfg" proj="$TEST_TMPDIR/life"
    mkdir -p "$proj" "$TEST_TMPDIR/home"
    _prep_cfg_repo "$cfg"
    _arm_sync_check_output "$cfg" "$_DRIFT_MIXED"
    _run "$cfg" "$proj" leader || true
    local kept notdep summary n
    kept=$(_count 'repo ≠ deployed' "$cfg/.sync-warnings.log"); notdep=$(_count ': not deployed' "$cfg/.sync-warnings.log")
    summary=$(_count '4 issue(s) found' "$cfg/.sync-warnings.log")
    assert_eq "2" "$kept" "an unheld shutdown still reports repo≠deployed drift (measured $kept)" || return 1
    assert_eq "1" "$notdep" "and not-deployed files (measured $notdep)" || return 1
    assert_eq "1" "$summary" "with the summary intact (measured $summary)" || return 1
    n=$(_audit_lines DRIFT_CHECK_DEFERRED)
    assert_eq "0" "$n" "and defers nothing (measured $n)"
}
run_test "CFG-965: Phase 0.7 still reports repo≠deployed drift when nobody holds the config repo" test_unheld_drift_check_keeps_repo_vs_deployed_lines

# ── Fix 1 (round 3): one deadline for both lock waits ────────────────────────
# The SessionEnd cap (settings.json CLAUDE_CODE_SESSIONEND_HOOKS_TIMEOUT_MS,
# 60 s) kills the hook SILENTLY. Two independent budgets (20 s + 45 s) added
# up to 65 s inside flock alone when another shutdown held .sync-lock through
# both (reviewer R2: wall 66 s, .sync-failed only then — i.e. under the real cap
# never). With one shared deadline each wait is min(budget, cap − elapsed), so
# sync_fail "lock" is always reached, visibly, before the cap. Scaled here:
# both budgets 10 s, cap 4 s, lock held 30 s.

test_both_lock_waits_busy_hook_fails_visibly_under_the_cap() {
    local cfg="$TEST_TMPDIR/cfg" proj="$TEST_TMPDIR/life"
    mkdir -p "$proj" "$TEST_TMPDIR/home"
    _prep_cfg_repo "$cfg"
    _arm_template_push "$cfg"
    _hold_sync_lock "$cfg" 30 "$TEST_TMPDIR/released.ns"
    local t0 wall under=0; t0=$SECONDS
    CFG_AUTO_SYNC_LOCK_WAIT=10 CFG_AUTO_SYNC_HOOK_CAP=4 _run "$cfg" "$proj" leader || true
    wall=$(( SECONDS - t0 ))
    _release_sync_lock_holder
    echo "    measured: wall=${wall}s (budgets 10 s + 10 s, cap 4 s)"
    assert_file_contains "$cfg/.sync-failed" "stage=lock" "the lock timeout is recorded visibly — the hook reached sync_fail" || return 1
    (( wall < 10 )) && under=1
    assert_eq "1" "$under" "the hook gave up inside the cap, not after the summed budgets (wall ${wall}s, must be < 10 s)" || return 1
    local n; n=$(_audit_lines TEMPLATE_PUSH_DEFERRED)
    assert_eq "1" "$n" "Phase 0.8 was deferred on the busy lock (measured $n)" || return 1
    assert_file_contains "$cfg/.sync-failed" "cap 4s" "the record names the cap that cut the wait"
}
run_test "CFG-965: both lock waits busy ⇒ the hook fails visibly (.sync-failed stage=lock) inside the cap" test_both_lock_waits_busy_hook_fails_visibly_under_the_cap

# ── Fix 2 (round 3): a lock HEAD's older library cannot read ─────────────────
# HEAD's session-lock.sh is asked first (SF-1). If the lock on disk is in a
# format that older library cannot parse — a newer library wrote it — its
# check_lock takes the "corrupt" branch: no live CC visible in the repo ⇒
# `rm -f lockfile; return 0` (session-lock.sh ~712-717). Reviewer R1: deploy 1,
# the holder's lock DELETED, its context rotated. An older library must never
# delete a lock a newer one wrote: unreadable lock present ⇒ held, recorded.
_write_newer_format_lock() {   # <dir> — not JSON: what a future session-lock.sh might write
    printf 'lockfmt=2\nmachine=%s\npid=%s\nsessionId=af-cfg-owner\nccSessionId=cc-cfg-owner\n' \
        "$(hostname)" "$$" > "$1/.claude/.session-lock"
}

test_lock_head_library_cannot_read_is_held() {
    local cfg="$TEST_TMPDIR/cfg" proj="$TEST_TMPDIR/life"
    mkdir -p "$proj" "$TEST_TMPDIR/home"
    _prep_cfg_repo "$cfg"
    _arm_template_push "$cfg"
    _arm_recording_sync "$cfg" "$TEST_TMPDIR/sync-calls.log"
    echo "holder's half-edited hook" >> "$cfg/global/hooks/x.sh"
    _write_newer_format_lock "$cfg"
    local before; before=$(cat "$cfg/.claude/.session-lock")
    _run "$cfg" "$proj" leader || true
    local deploys calls goal
    deploys=$(_sync_calls deploy); calls=$(_tpl_calls); goal=$(_goal_lines "$cfg")
    assert_file_exists "$cfg/.claude/.session-lock" "a lock HEAD's library cannot read is NOT deleted" || return 1
    assert_eq "$before" "$(cat "$cfg/.claude/.session-lock")" "and is left byte-identical" || return 1
    assert_eq "0" "$deploys" "no deploy (measured $deploys)" || return 1
    assert_eq "0" "$calls" "no template push (measured $calls call(s))" || return 1
    assert_eq "1" "$goal" "the holder's context is intact (measured $goal goal line(s))" || return 1
    assert_file_contains "$cfg/.sync-warnings.log" "cannot read (empty, corrupt, or a newer format)" "the reason is recorded without guessing which of the three it is" || return 1
    assert_file_contains "$cfg/.sync-warnings.log" "force_release" "and the record says how to clear it once no cfg session is live"
}
run_test "CFG-965: a lock in a format HEAD's library cannot read ⇒ held, lock kept, reason recorded" test_lock_head_library_cannot_read_is_held

# ── Round 4: "readable" must mean the fields check_lock relies on are there ──
# HEAD's _read_lock (python/jq branches) returns 0 for ANY JSON object and
# leaves _LOCK_PID empty when `pid` is missing or renamed; only its bash
# fallback validates machine+pid. A newer lock `{"machine":…,"lockPid":<live>,
# …}` therefore passed the round-3 check, check_lock saw an empty pid as dead,
# scanned, deleted the lock and answered free (reviewer: deploy 1, lock gone,
# context rotated). Readable = _read_lock succeeds AND machine is set AND pid
# is numeric; anything else is 6.
_write_renamed_pid_lock() {   # <dir> — valid JSON, live pid under a field name HEAD's library does not know
    printf '{"machine":"%s","lockPid":%s,"sessionId":"af-cfg-owner","timestamp":"2026-11-11T00:00:00Z","user":"test","ccSessionId":"cc-cfg-owner"}\n' \
        "$(hostname)" "$$" > "$1/.claude/.session-lock"
}

test_lock_with_renamed_pid_field_is_held() {
    local cfg="$TEST_TMPDIR/cfg" proj="$TEST_TMPDIR/life"
    mkdir -p "$proj" "$TEST_TMPDIR/home"
    _prep_cfg_repo "$cfg"
    _arm_template_push "$cfg"
    _arm_recording_sync "$cfg" "$TEST_TMPDIR/sync-calls.log"
    echo "holder's half-edited hook" >> "$cfg/global/hooks/x.sh"
    _write_renamed_pid_lock "$cfg"
    local before; before=$(cat "$cfg/.claude/.session-lock")
    _run "$cfg" "$proj" leader || true
    local deploys calls goal
    deploys=$(_sync_calls deploy); calls=$(_tpl_calls); goal=$(_goal_lines "$cfg")
    assert_file_exists "$cfg/.claude/.session-lock" "a JSON lock whose pid field HEAD's library does not know is NOT deleted" || return 1
    assert_eq "$before" "$(cat "$cfg/.claude/.session-lock")" "and is left byte-identical" || return 1
    assert_eq "0" "$deploys" "no deploy (measured $deploys)" || return 1
    assert_eq "0" "$calls" "no template push (measured $calls call(s))" || return 1
    assert_eq "1" "$goal" "the holder's context is intact (measured $goal goal line(s))" || return 1
    assert_file_contains "$cfg/.sync-warnings.log" "cannot read (empty, corrupt, or a newer format)" "recorded as unreadable, not cleaned as corrupt"
}
run_test "CFG-965: a JSON lock with the pid under a name HEAD's library does not know ⇒ held, lock kept" test_lock_with_renamed_pid_field_is_held

# ── Round 4: Phase 3 keeps a work reserve after its wait ─────────────────────
# _lock_budget bounded the WAIT by the cap but left nothing for the work after
# it: with the lock busy 50 s, Phase 3 started at +50 s with 10 s of cap for
# deploy, commit, push, mobile and the shim. Phase 3 now reserves 15 s —
# wait = min(45, cap − elapsed − 15), floored at 0 — and a failed 0-second try
# is sync_fail "lock" as before. Phase 0.8 keeps its reserve-less budget (a
# deferral is free). Scaled: budgets 10 s, cap 20 s, lock held 30 s — Phase 0.8
# uses its full 10 s, Phase 3 is left min(10, 20 − ~10.5 − 15) = 0.
test_phase3_reserves_work_time_after_its_wait() {
    local cfg="$TEST_TMPDIR/cfg" proj="$TEST_TMPDIR/life"
    mkdir -p "$proj" "$TEST_TMPDIR/home"
    _prep_cfg_repo "$cfg"
    _arm_template_push "$cfg"
    _hold_sync_lock "$cfg" 30 "$TEST_TMPDIR/released.ns"
    local t0 wall under=0; t0=$SECONDS
    CFG_AUTO_SYNC_LOCK_WAIT=10 CFG_AUTO_SYNC_HOOK_CAP=20 _run "$cfg" "$proj" leader || true
    wall=$(( SECONDS - t0 ))
    _release_sync_lock_holder
    echo "    measured: wall=${wall}s (budgets 10 s + 10 s, cap 20 s, Phase 3 reserve 15 s)"
    assert_file_contains "$cfg/.sync-failed" "stage=lock" "Phase 3 gave up on the lock visibly" || return 1
    (( wall < 15 )) && under=1
    assert_eq "1" "$under" "Phase 3 did not spend the reserve waiting (wall ${wall}s, must be < 15 s; without the reserve it would be ~20 s)" || return 1
    assert_file_contains "$cfg/.sync-failed" "reserve 15s" "the record names the reserve that cut the wait" || return 1
    local n; n=$(_audit_lines TEMPLATE_PUSH_DEFERRED)
    assert_eq "1" "$n" "Phase 0.8 still used its own, reserve-less budget and deferred (measured $n)"
}
run_test "CFG-965: Phase 3 waits only cap − elapsed − 15 s so deploy/commit/push/mobile/shim keep their time" test_phase3_reserves_work_time_after_its_wait

# ── Fix 4 (round 3): without the library, the owner's lock-less shutdown still rotates ─
# The fail-closed stub (lib-cfg-held.sh missing) plus the Phase 1 skip meant
# the config repo's OWN shutdown — lock released in Phase -1, nobody else there
# — never rotated its context and never deployed (reviewer R4). That shape is
# the one the library itself calls "not held" without asking; the stub mirrors it.

test_lib_missing_owner_lockless_cfg_shutdown_still_rotates() {
    local cfg="$TEST_TMPDIR/cfg"
    mkdir -p "$TEST_TMPDIR/home"
    _prep_cfg_repo "$cfg"
    _arm_recording_sync "$cfg" "$TEST_TMPDIR/sync-calls.log"
    CFG965_NO_HELD_LIB=1 _run "$cfg" "$cfg" leader || true
    local goal deploys n
    goal=$(_goal_lines "$cfg"); deploys=$(_sync_calls deploy)
    assert_eq "0" "$goal" "the owner's lock-less shutdown rotates its context without the library (measured $goal goal line(s) left)" || return 1
    assert_file_exists "$cfg/session-history.md" "archive written" || return 1
    assert_eq "1" "$deploys" "and deploys (measured $deploys)" || return 1
    n=$(_count 'lib-cfg-held.sh' "$cfg/.sync-warnings.log")
    assert_eq "0" "$n" "nothing is recorded as held or missing (measured $n record(s))"
}
run_test "CFG-965: lib-cfg-held.sh missing — the config repo's own lock-less shutdown still rotates and deploys" test_lib_missing_owner_lockless_cfg_shutdown_still_rotates

# ── Phase 1: when the project IS the held config repo, rotate is not even asked ─

test_held_cfg_shutdown_does_not_call_rotate() {
    # ORIGINAL_DIR == CONFIG_REPO, nested CC mis-marked leader, the real leader's
    # live lock: the early probe says held, and the hook's verdict is
    # authoritative — rotate-session.sh's own guard is a second line of
    # defence, not the decision.
    local cfg="$TEST_TMPDIR/cfg" log="$TEST_TMPDIR/rotate-calls.log"
    mkdir -p "$TEST_TMPDIR/home"
    _prep_cfg_repo "$cfg"
    cat > "$cfg/setup/scripts/rotate-session.sh" << STUB
#!/usr/bin/env bash
echo "\$*" >> "$log"
exit 3
STUB
    chmod +x "$cfg/setup/scripts/rotate-session.sh"
    sleep 120 & local lpid=$!
    ( source "$LOCK_LIB"; _write_lock "$cfg/.claude/.session-lock" "af-cfg-owner" "cc-cfg-owner" "$lpid" )
    printf 'leader\n' > "$cfg/.claude/.session-role.cc-nested"
    _run "$cfg" "$cfg" nested af-cfg-owner cc-nested || true
    kill "$lpid" 2>/dev/null || true
    local calls goal
    calls=$(_count . "$log"); goal=$(_goal_lines "$cfg")
    assert_eq "0" "$calls" "rotate-session.sh is not invoked for a config repo the hook already knows is held (measured $calls call(s))" || return 1
    assert_eq "1" "$goal" "the leader's context is intact (measured $goal goal line(s))" || return 1
    assert_file_contains "$cfg/.sync-warnings.log" "refused" "the refusal is still recorded once for the next session"
}
run_test "CFG-965: Phase 1 skips the rotate call itself when the project is the held config repo" test_held_cfg_shutdown_does_not_call_rotate

# ── Phase 3: the lock-timeout record names the wait that was actually used ───

test_phase3_lock_timeout_record_names_the_actual_wait() {
    local cfg="$TEST_TMPDIR/cfg" proj="$TEST_TMPDIR/life"
    mkdir -p "$proj" "$TEST_TMPDIR/home"
    _prep_cfg_repo "$cfg"
    _hold_sync_lock "$cfg" 6 "$TEST_TMPDIR/released.ns"
    CFG_AUTO_SYNC_LOCK_WAIT=1 _run "$cfg" "$proj" leader || true
    _release_sync_lock_holder
    assert_file_contains "$cfg/.sync-failed" "stage=lock" "precondition: Phase 3 gave up on the lock" || return 1
    assert_file_contains "$cfg/.sync-failed" ">1s" "the record names the wait that was used (1 s), not a hardcoded 30s" || return 1
    assert_file_not_contains "$cfg/.sync-failed" ">30s" "no hardcoded 30s in the record"
}
run_test "CFG-965: the Phase 3 lock-timeout record prints the configured wait" test_phase3_lock_timeout_record_names_the_actual_wait

# ── NIT 6: one record per event, and "unknown" is not "another live session" ─

test_blind_check_in_cfg_is_recorded_once() {
    # ORIGINAL_DIR == CONFIG_REPO, blind lock check (rc 4): the early probe
    # records the unknown state; Phase 1's guard refuses the same rotation for
    # the same reason. One event, one drift-log line.
    local cfg="$TEST_TMPDIR/cfg"
    mkdir -p "$TEST_TMPDIR/home"
    _prep_cfg_repo "$cfg"
    sleep 0.01 & local dead=$!; wait "$dead" 2>/dev/null || true
    ( source "$LOCK_LIB"; _write_lock "$cfg/.claude/.session-lock" "af-cfg-owner" "cc-cfg-owner" "$dead" )
    printf 'leader\n' > "$cfg/.claude/.session-role.cc-nested"
    _CC_PROC_RE="(^|/)cfg965-no-such-cc-$$([[:space:]]|$)" _run "$cfg" "$cfg" none af-cfg-owner cc-nested || true
    local unknown held goal
    unknown=$(_count 'unknown' "$cfg/.sync-warnings.log")
    held=$(_count 'held by another live session' "$cfg/.sync-warnings.log")
    goal=$(_goal_lines "$cfg")
    assert_eq "1" "$goal" "precondition: the context was not rotated (measured $goal goal line(s))" || return 1
    assert_eq "1" "$unknown" "exactly one 'unknown' record for one blind check (measured $unknown)" || return 1
    assert_eq "0" "$held" "no line claims another live session was SEEN — nothing was (measured $held)"
}
run_test "CFG-965 NIT 6: a blind check of the config repo as the project is recorded once, as unknown" test_blind_check_in_cfg_is_recorded_once

test_foreign_project_unknown_holder_is_named_unknown() {
    # ORIGINAL_DIR is another project whose own lock the blind check cannot
    # resolve: Phase 1's refusal line must say "unknown", not "held by another
    # live session" — the guard saw nobody.
    local cfg="$TEST_TMPDIR/cfg" proj="$TEST_TMPDIR/life"
    mkdir -p "$proj/.claude" "$proj/docs" "$TEST_TMPDIR/home"
    _prep_cfg_repo "$cfg"
    _populate_cfg_context "$proj"
    sleep 0.01 & local dead=$!; wait "$dead" 2>/dev/null || true
    ( source "$LOCK_LIB"; _write_lock "$proj/.claude/.session-lock" "af-leader" "cc-leader" "$dead" )
    printf 'leader\n' > "$proj/.claude/.session-role.cc-other-project"
    _CC_PROC_RE="(^|/)cfg965-no-such-cc-$$([[:space:]]|$)" _run "$cfg" "$proj" || true
    local line
    line=$(grep "rotate-session refused for $proj" "$cfg/.sync-warnings.log" 2>/dev/null || true)
    assert_contains "$line" "refused for $proj" "precondition: Phase 1's guard refused the project's rotation" || return 1
    assert_contains "$line" "unknown" "the line says the holder is unknown" || return 1
    assert_not_contains "$line" "held by another live session" "and does not claim a session was seen"
}
run_test "CFG-965 NIT 6: a blind check of the shutting-down project is reported as unknown, not as a seen holder" test_foreign_project_unknown_holder_is_named_unknown

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
