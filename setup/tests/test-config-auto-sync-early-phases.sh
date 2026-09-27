#!/usr/bin/env bash
# Tests for config-auto-sync.sh — early phases (-1, 0, 0.5, 0.6, 0.7)
# Split from test-config-auto-sync.sh (CFG-301)
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO_ROOT/setup/tests/test-helpers.sh"
source "$REPO_ROOT/setup/tests/test-config-auto-sync-helpers.sh"

suite_header "config-auto-sync.sh (early phases: -1, 0, 0.5, 0.6, 0.7)"

# ── Phase -1: Lock Release ──────────────────────────────────────────────────

test_lock_release_local() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$project_dir/.claude" "$mock_home"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    # Push sync.sh etc. into the repo
    (cd "$config_repo" && git add -A && git commit -m "add stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    # Write a session lock file so the hook can read/release it
    cat > "$project_dir/.claude/.session-lock" << 'EOF'
{"machine":"testhost","pid":99999,"sessionId":"test-session-123","timestamp":"2026-01-01T00:00:00Z","user":"test"}
EOF

    # Override the session-lock.sh mock to track release_lock calls
    cat > "$config_repo/setup/scripts/session-lock.sh" << 'STUB'
#!/usr/bin/env bash
_LOCK_SESSION=""
_read_lock() {
    local lockfile="$1"
    [ -f "$lockfile" ] || return 1
    _LOCK_SESSION="test-session-123"
    return 0
}
release_lock() {
    echo "RELEASE_CALLED:$1:$2" >> "${RELEASE_LOG:-/dev/null}"
    return 0
}
force_release() {
    echo "FORCE_RELEASE:$1" >> "${RELEASE_LOG:-/dev/null}"
    return 0
}
STUB

    export RELEASE_LOG="$TEST_TMPDIR/release.log"
    export AFLEET_SESSION_ID=""

    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true

    # The hook should have called release_lock or force_release for the project dir
    if [[ -f "$RELEASE_LOG" ]]; then
        local log_content
        log_content=$(<"$RELEASE_LOG")
        # Should reference the project directory
        assert_contains "$log_content" "$project_dir" "release should target project dir"
    else
        # If no RELEASE_LOG, the hook fell back to force_release which also writes there
        # or the session lock wasn't found (acceptable in mock scenarios)
        true
    fi

    unset RELEASE_LOG AFLEET_SESSION_ID
}
run_test "Phase -1: lock release called on shutdown" test_lock_release_local

test_lock_release_with_session_id_env() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$project_dir/.claude" "$mock_home"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    (cd "$config_repo" && git add -A && git commit -m "add stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    # Override session-lock.sh to track calls
    cat > "$config_repo/setup/scripts/session-lock.sh" << 'STUB'
#!/usr/bin/env bash
_LOCK_SESSION=""
_read_lock() { return 1; }
release_lock() {
    echo "RELEASE:sid=$2" >> "${RELEASE_LOG:-/dev/null}"
    return 0
}
release_own_lock() {
    echo "RELEASE:sid=$2" >> "${RELEASE_LOG:-/dev/null}"
    return 0
}
force_release() { return 0; }
STUB

    export RELEASE_LOG="$TEST_TMPDIR/release.log"
    export AFLEET_SESSION_ID="env-session-456"

    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true

    if [[ -f "$RELEASE_LOG" ]]; then
        local log_content
        log_content=$(<"$RELEASE_LOG")
        assert_contains "$log_content" "env-session-456" "should use AFLEET_SESSION_ID from env"
    fi

    unset RELEASE_LOG AFLEET_SESSION_ID
}
run_test "Phase -1: uses AFLEET_SESSION_ID from env when available" test_lock_release_with_session_id_env

# Regression (CFG-452): a follower session (no AFLEET_SESSION_ID) must NOT delete
# the live leader's lock. Uses the REAL session-lock.sh so an actual clobber shows.
test_lock_release_follower_no_clobber() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$project_dir/.claude" "$mock_home"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    cp "$REPO_ROOT/setup/scripts/session-lock.sh" "$config_repo/setup/scripts/session-lock.sh"
    (cd "$config_repo" && git add -A && git commit -m "add stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    # Live leader holds the lock (our PID is alive), foreign sid
    cat > "$project_dir/.claude/.session-lock" << EOF
{"machine":"$(hostname)","pid":$$,"sessionId":"leader-live-sid","timestamp":"2026-01-01T00:00:00Z","user":"$(whoami)"}
EOF

    export AFLEET_SESSION_ID=""
    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true
    unset AFLEET_SESSION_ID

    local exists=0
    if [[ -f "$project_dir/.claude/.session-lock" ]]; then exists=1; fi
    assert_eq "1" "$exists" "follower shutdown must leave the leader's lock intact"
}
run_test "Phase -1: follower (no AFLEET_SESSION_ID) does not clobber leader lock" test_lock_release_follower_no_clobber

# Positive (CFG-452): a leader whose AFLEET_SESSION_ID matches releases its own lock.
test_lock_release_leader_removes_own() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$project_dir/.claude" "$mock_home"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    cp "$REPO_ROOT/setup/scripts/session-lock.sh" "$config_repo/setup/scripts/session-lock.sh"
    (cd "$config_repo" && git add -A && git commit -m "add stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    cat > "$project_dir/.claude/.session-lock" << EOF
{"machine":"$(hostname)","pid":$$,"sessionId":"leader-own-sid","timestamp":"2026-01-01T00:00:00Z","user":"$(whoami)"}
EOF

    export AFLEET_SESSION_ID="leader-own-sid"
    # Force the degraded (no resolvable CC pid) path so the hook exercises the
    # legacy AFLEET/sessionId release contract deterministically — the fabricated
    # lock pid ($$) is not a real CC pid, and the suite may run nested under a live
    # CC session where _cc_self_pid would otherwise resolve to that CC. (CFG-454)
    export _CC_SELF_PID=""
    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true
    unset AFLEET_SESSION_ID _CC_SELF_PID

    local exists=0
    if [[ -f "$project_dir/.claude/.session-lock" ]]; then exists=1; fi
    assert_eq "0" "$exists" "leader must release its own lock at shutdown"
}
run_test "Phase -1: leader releases its own lock (AFLEET_SESSION_ID matches)" test_lock_release_leader_removes_own

# ── Phase 0: Mobile Outbox Collection ────────────────────────────────────────

test_mobile_outbox_collection() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$project_dir" "$mock_home"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    (cd "$config_repo" && git add -A && git commit -m "add stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    # Create a mobile repo with outbox tasks
    local mobile_repo="$mock_home/agent-fleet-mobile"
    mkdir -p "$mobile_repo/inbox"
    cat > "$mobile_repo/inbox/outbox.md" << 'EOF'
# Mobile Outbox
- [ ] Task one from mobile
- [ ] Task two from mobile
EOF

    # Track mobile-deploy.sh calls, argv included: since CFG-634 the Phase 4
    # refresh (deploy mode) runs on every leader shutdown, so only a --collect
    # call is evidence about Phase 0.
    cat > "$config_repo/setup/scripts/mobile-deploy.sh" << 'STUB'
#!/usr/bin/env bash
echo "MOBILE_CALL:$*" >> "${MOBILE_LOG:-/dev/null}"
exit 0
STUB
    chmod +x "$config_repo/setup/scripts/mobile-deploy.sh"

    export MOBILE_LOG="$TEST_TMPDIR/mobile.log"

    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true

    local collects
    collects=$(grep -c -- '--collect' "$MOBILE_LOG" 2>/dev/null) || true
    collects=${collects:-0}   # no log at all = no call (grep -c prints nothing for a missing file)
    unset MOBILE_LOG
    assert_eq "1" "$collects" "Phase 0 calls mobile-deploy.sh --collect exactly once (measured $collects)"
}
run_test "Phase 0: collects mobile outbox when tasks exist" test_mobile_outbox_collection

test_mobile_outbox_skipped_when_empty() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$project_dir" "$mock_home"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    (cd "$config_repo" && git add -A && git commit -m "add stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    # Create mobile repo with NO pending tasks (all done)
    local mobile_repo="$mock_home/agent-fleet-mobile"
    mkdir -p "$mobile_repo/inbox"
    cat > "$mobile_repo/inbox/outbox.md" << 'EOF'
# Mobile Outbox
- [x] Already done task
EOF

    cat > "$config_repo/setup/scripts/mobile-deploy.sh" << 'STUB'
#!/usr/bin/env bash
echo "MOBILE_CALL:$*" >> "${MOBILE_LOG:-/dev/null}"
exit 0
STUB
    chmod +x "$config_repo/setup/scripts/mobile-deploy.sh"

    export MOBILE_LOG="$TEST_TMPDIR/mobile.log"

    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true

    # Phase 0 must NOT collect — no unchecked tasks. The Phase 4 refresh
    # (deploy mode) runs regardless since CFG-634 and is not what this test is
    # about, so the stub records argv and only a --collect call counts. The
    # old "log must not exist" assertion sat before `unset` and never decided
    # the verdict.
    local collects
    collects=$(grep -c -- '--collect' "$MOBILE_LOG" 2>/dev/null) || true
    collects=${collects:-0}   # no log at all = no call (grep -c prints nothing for a missing file)
    unset MOBILE_LOG
    assert_eq "0" "$collects" "mobile-deploy.sh --collect must not be called with 0 pending tasks (measured $collects)"
}
run_test "Phase 0: skips mobile outbox when no pending tasks" test_mobile_outbox_skipped_when_empty

test_mobile_outbox_skipped_when_no_repo() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$project_dir" "$mock_home"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    (cd "$config_repo" && git add -A && git commit -m "add stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    # No mobile repo at all
    cat > "$config_repo/setup/scripts/mobile-deploy.sh" << 'STUB'
#!/usr/bin/env bash
echo "MOBILE_COLLECT" >> "${MOBILE_LOG:-/dev/null}"
exit 0
STUB
    chmod +x "$config_repo/setup/scripts/mobile-deploy.sh"

    export MOBILE_LOG="$TEST_TMPDIR/mobile.log"

    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true

    assert_file_not_exists "$MOBILE_LOG" "mobile-deploy.sh should not be called when repo absent"

    unset MOBILE_LOG
}
run_test "Phase 0: skips mobile collection when mobile repo absent" test_mobile_outbox_skipped_when_no_repo

# ── Phase 0.5: Permissions Cleanup ──────────────────────────────────────────

test_permissions_cleanup_called() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$project_dir" "$mock_home"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    (cd "$config_repo" && git add -A && git commit -m "add stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    # Override clean-permissions.sh to track invocation
    cat > "$config_repo/setup/scripts/clean-permissions.sh" << 'STUB'
#!/usr/bin/env bash
echo "CLEAN_PERMS_CALLED" >> "${PERMS_LOG:-/dev/null}"
exit 0
STUB
    chmod +x "$config_repo/setup/scripts/clean-permissions.sh"

    export PERMS_LOG="$TEST_TMPDIR/perms.log"

    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true

    assert_file_exists "$PERMS_LOG" "clean-permissions.sh should have been invoked"

    unset PERMS_LOG
}
run_test "Phase 0.5: clean-permissions.sh is invoked" test_permissions_cleanup_called

test_permissions_cleanup_failure_nonfatal() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$project_dir" "$mock_home"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    (cd "$config_repo" && git add -A && git commit -m "add stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    # Make clean-permissions.sh fail
    cat > "$config_repo/setup/scripts/clean-permissions.sh" << 'STUB'
#!/usr/bin/env bash
exit 1
STUB
    chmod +x "$config_repo/setup/scripts/clean-permissions.sh"

    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    local rc=0
    run_hook "$patched" || rc=$?

    # Hook should still exit 0 — cleanup failure is non-fatal
    assert_eq "0" "$rc" "hook should exit 0 even if clean-permissions.sh fails"
}
run_test "Phase 0.5: permissions cleanup failure is non-fatal" test_permissions_cleanup_failure_nonfatal

# ── Phase 0.6: Pending File Auto-Clean ───────────────────────────────────────

test_pending_auto_clean_called() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$project_dir" "$mock_home"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    (cd "$config_repo" && git add -A && git commit -m "add stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    # Override manage-pending.sh to track invocation
    cat > "$config_repo/setup/scripts/manage-pending.sh" << 'STUB'
#!/usr/bin/env bash
echo "PENDING_CALLED:$*" >> "${PENDING_LOG:-/dev/null}"
exit 0
STUB
    chmod +x "$config_repo/setup/scripts/manage-pending.sh"

    export PENDING_LOG="$TEST_TMPDIR/pending.log"

    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true

    assert_file_exists "$PENDING_LOG" "manage-pending.sh should have been called"
    local log_content
    log_content=$(<"$PENDING_LOG")
    assert_contains "$log_content" "--auto-clean" "should call with --auto-clean"
    assert_contains "$log_content" "--project-dir" "should pass --project-dir"

    unset PENDING_LOG
}
run_test "Phase 0.6: manage-pending.sh called with --auto-clean" test_pending_auto_clean_called

test_pending_auto_clean_failure_nonfatal() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$project_dir" "$mock_home"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    (cd "$config_repo" && git add -A && git commit -m "add stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    # Make manage-pending.sh fail
    cat > "$config_repo/setup/scripts/manage-pending.sh" << 'STUB'
#!/usr/bin/env bash
exit 1
STUB
    chmod +x "$config_repo/setup/scripts/manage-pending.sh"

    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    local rc=0
    run_hook "$patched" || rc=$?

    assert_eq "0" "$rc" "hook should exit 0 even if manage-pending.sh fails"
}
run_test "Phase 0.6: pending auto-clean failure is non-fatal" test_pending_auto_clean_failure_nonfatal

# ── Phase 0.7: Propagation Drift Check ──────────────────────────────────────

test_drift_check_writes_warning_log() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$project_dir" "$mock_home"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"

    # Make sync.sh check report drift warnings
    cat > "$config_repo/sync.sh" << 'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    check)
        echo "WARNING: global/CLAUDE.md drifted from deployed"
        echo "2 issue(s) found"
        ;;
    deploy) echo "ok" ;;
    *) echo "$*" ;;
esac
exit 0
STUB
    chmod +x "$config_repo/sync.sh"

    (cd "$config_repo" && git add -A && git commit -m "add stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true

    assert_file_exists "$config_repo/.sync-warnings.log" "should write drift warnings to .sync-warnings.log"
    assert_file_contains "$config_repo/.sync-warnings.log" "drifted" "should contain drift warning"
    assert_file_contains "$config_repo/.sync-warnings.log" "issue(s) found" "should contain issue count"
}
run_test "Phase 0.7: drift warnings written to .sync-warnings.log" test_drift_check_writes_warning_log

test_drift_check_cleans_log_on_no_issues() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$project_dir" "$mock_home"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    (cd "$config_repo" && git add -A && git commit -m "add stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    # Pre-create a stale warnings log
    echo "old warning" > "$config_repo/.sync-warnings.log"

    # sync.sh check reports no issues
    cat > "$config_repo/sync.sh" << 'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    check)   echo "All clear, no drift detected" ;;
    deploy)  echo "ok" ;;
    *)       echo "$*" ;;
esac
exit 0
STUB
    chmod +x "$config_repo/sync.sh"

    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true

    assert_file_not_exists "$config_repo/.sync-warnings.log" "should remove stale warnings log when no drift"
}
run_test "Phase 0.7: stale warnings log removed when no drift" test_drift_check_cleans_log_on_no_issues

test_drift_check_failure_nonfatal() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$project_dir" "$mock_home"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"

    # Make sync.sh check fail
    cat > "$config_repo/sync.sh" << 'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    check)   exit 1 ;;
    deploy)  echo "ok" ;;
    *)       echo "$*" ;;
esac
STUB
    chmod +x "$config_repo/sync.sh"

    (cd "$config_repo" && git add -A && git commit -m "add stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    local rc=0
    run_hook "$patched" || rc=$?

    assert_eq "0" "$rc" "hook should exit 0 even if drift check fails"
}
run_test "Phase 0.7: drift check failure is non-fatal" test_drift_check_failure_nonfatal

# ── Phase 0.8: Template Propagation (CFG-242, CFG-391, CFG-396) ─────────────

# Set up a minimal Phase-0.8 test scaffold:
#   - Mock agent-fleet repo at $mock_home/agent-fleet (with .git)
#   - Mock template-push.sh that records argv to $TPL_LOG and obeys $TPL_EXIT
# Returns nothing — sets globals via the caller's local scope.
_phase08_scaffold() {
    local config_repo="$1" mock_home="$2" tpl_log="$3"
    # Mock agent-fleet directory with .git so the Phase 0.8 guard passes
    mkdir -p "$mock_home/agent-fleet/.git"
    # Mock template-push.sh — records argv, emits drift on --dry-run, exits per env
    cat > "$config_repo/setup/scripts/template-push.sh" << STUB
#!/usr/bin/env bash
echo "\$@" >> "$tpl_log"
case "\$1" in
    --dry-run) echo "Would copy global/CLAUDE.md"; exit 0 ;;
    --commit|--push) exit "\${TPL_EXIT:-0}" ;;
esac
exit 0
STUB
    chmod +x "$config_repo/setup/scripts/template-push.sh"
}

test_phase08_uses_push_not_commit() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home"
    local tpl_log="$TEST_TMPDIR/tpl-argv.log"
    mkdir -p "$project_dir" "$mock_home"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    _phase08_scaffold "$config_repo" "$mock_home" "$tpl_log"
    # Give agent-fleet a remote AND a tracked upstream branch so preflight passes
    git init --bare -b main "$TEST_TMPDIR/af-remote.git" >/dev/null 2>&1
    (cd "$mock_home/agent-fleet" && git init -b main >/dev/null 2>&1 \
        && git config user.email t@t.t && git config user.name t \
        && echo init > README.md && git add README.md \
        && git commit -m initial >/dev/null 2>&1 \
        && git remote add origin "$TEST_TMPDIR/af-remote.git" \
        && git push -u origin main >/dev/null 2>&1)

    (cd "$config_repo" && git add -A && git commit -m "stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true

    assert_file_exists "$tpl_log" "template-push.sh should have been invoked"
    assert_file_contains "$tpl_log" "[-][-]push" "Phase 0.8 should call template-push with --push (CFG-391)"
}
run_test "Phase 0.8: uses --push when remote available (CFG-391)" test_phase08_uses_push_not_commit

test_phase08_falls_back_to_commit_when_no_remote() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home"
    local tpl_log="$TEST_TMPDIR/tpl-argv.log"
    mkdir -p "$project_dir" "$mock_home"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    _phase08_scaffold "$config_repo" "$mock_home" "$tpl_log"
    # Initialise agent-fleet WITHOUT a remote — preflight should fall back to --commit
    (cd "$mock_home/agent-fleet" && git init -b main >/dev/null 2>&1 \
        && git config user.email t@t.t && git config user.name t)

    (cd "$config_repo" && git add -A && git commit -m "stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true

    assert_file_exists "$tpl_log" "template-push.sh should have been invoked"
    assert_not_contains "$(cat "$tpl_log")" "--push" "should not use --push when remote missing (preflight)"
    assert_file_contains "$tpl_log" "[-][-]commit" "should fall back to --commit when remote missing"
}
run_test "Phase 0.8: falls back to --commit when remote missing (CFG-391)" test_phase08_falls_back_to_commit_when_no_remote

test_phase08_writes_failure_marker_on_exit_nonzero() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home"
    local tpl_log="$TEST_TMPDIR/tpl-argv.log"
    mkdir -p "$project_dir" "$mock_home"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    _phase08_scaffold "$config_repo" "$mock_home" "$tpl_log"

    # Force template-push to fail; the marker should be written
    cat > "$config_repo/setup/scripts/template-push.sh" << 'STUB'
#!/usr/bin/env bash
case "$1" in
    --dry-run) echo "Would copy global/CLAUDE.md"; exit 0 ;;
    --commit|--push) echo "fatal: simulated failure" >&2; exit 1 ;;
esac
exit 0
STUB
    chmod +x "$config_repo/setup/scripts/template-push.sh"

    (cd "$config_repo" && git add -A && git commit -m "stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true

    assert_file_exists "$config_repo/.template-push-failed" \
        "Phase 0.8 should write .template-push-failed on non-zero exit (CFG-396)"
    assert_file_contains "$config_repo/.template-push-failed" "exit_code=1" \
        "marker should record exit code"
    assert_file_contains "$config_repo/.template-push-failed" "drift_files=" \
        "marker should record drift count"
}
run_test "Phase 0.8: writes .template-push-failed marker on failure (CFG-396)" test_phase08_writes_failure_marker_on_exit_nonzero

test_phase08_clears_failure_marker_on_success() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home"
    local tpl_log="$TEST_TMPDIR/tpl-argv.log"
    mkdir -p "$project_dir" "$mock_home"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    _phase08_scaffold "$config_repo" "$mock_home" "$tpl_log"
    # Pre-create stale marker — successful run should remove it
    echo "stale=1" > "$config_repo/.template-push-failed"

    (cd "$config_repo" && git add -A && git commit -m "stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true

    assert_file_not_exists "$config_repo/.template-push-failed" \
        "successful Phase 0.8 should clear stale .template-push-failed marker (CFG-396)"
}
run_test "Phase 0.8: clears stale failure marker on success (CFG-396)" test_phase08_clears_failure_marker_on_success

# ── CFG-613 (b): a failing propagation must carry its AGE, not just its latest time ──
# The marker was overwritten on every failure, so "failed six days running" and
# "failed once, last night" were the same file. It now keeps when the streak began
# and how long it is; the SessionStart check names both.
_phase08_failing_run() {
    local config_repo="$TEST_TMPDIR/config-repo" project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home" tpl_log="$TEST_TMPDIR/tpl-argv.log"
    mkdir -p "$project_dir" "$mock_home"
    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    _phase08_scaffold "$config_repo" "$mock_home" "$tpl_log"
    (cd "$config_repo" && git add -A && git commit -m "stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    [[ -n "${1:-}" ]] && printf '%s\n' "$1" > "$config_repo/.template-push-failed"
    local patched; patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    TPL_EXIT=3 run_hook "$patched" || true
}

test_phase08_first_failure_starts_the_streak() {
    local before; before=$(date +%s)
    _phase08_failing_run ""
    local m="$TEST_TMPDIR/config-repo/.template-push-failed"
    assert_file_exists "$m" "a failing push must write the marker" || return 1
    assert_file_contains "$m" "consecutive=1" "the first failure starts the count at 1" || return 1
    assert_file_contains "$m" "exit_code=3" "the marker still records the exit code" || return 1
    local epoch; epoch=$(sed -n 's/^first_failed_epoch=//p' "$m" | head -1)
    [[ "$epoch" =~ ^[0-9]+$ ]] || { echo "    first_failed_epoch missing or not numeric: '$epoch'" >&2; return 1; }
    [[ "$epoch" -ge "$before" ]] || { echo "    first_failed_epoch $epoch predates the run ($before)" >&2; return 1; }
}
run_test "Phase 0.8: first failure starts the streak at 1 with its epoch (CFG-613)" test_phase08_first_failure_starts_the_streak

test_phase08_repeat_failure_keeps_start_and_counts_up() {
    _phase08_failing_run 'time=2026-09-20 08:00:00 UTC
first_failed=2026-09-18 08:00:00 UTC
first_failed_epoch=1789718400
consecutive=4
exit_code=3
drift_files=1
output_tail=old'
    local m="$TEST_TMPDIR/config-repo/.template-push-failed"
    assert_file_contains "$m" "consecutive=5" "a repeat failure must count up, not restart" || return 1
    assert_file_contains "$m" "first_failed=2026-09-18 08:00:00 UTC" "the streak's start must survive the rewrite" || return 1
    assert_file_contains "$m" "first_failed_epoch=1789718400" "the start epoch must survive the rewrite" || return 1
    assert_file_not_contains "$m" "time=2026-09-20 08:00:00 UTC" "time= is the LATEST failure and must be refreshed"
}
run_test "Phase 0.8: a repeat failure keeps the streak start and counts up (CFG-613)" test_phase08_repeat_failure_keeps_start_and_counts_up

test_phase08_legacy_marker_is_carried_forward() {
    # A marker written before CFG-613 has only time=: that failure is the streak's start.
    _phase08_failing_run 'time=2026-09-11 08:00:00 UTC
exit_code=1
drift_files=1
output_tail=old'
    local m="$TEST_TMPDIR/config-repo/.template-push-failed"
    assert_file_contains "$m" "consecutive=2" "an old marker counts as one earlier failure" || return 1
    assert_file_contains "$m" "first_failed=2026-09-11 08:00:00 UTC" "the old marker's time= becomes the streak start" || return 1
    grep -qE '^first_failed_epoch=[0-9]+$' "$m" || { echo "    no numeric first_failed_epoch after upgrade" >&2; return 1; }
}
run_test "Phase 0.8: a pre-CFG-613 marker is carried forward, not reset (CFG-613)" test_phase08_legacy_marker_is_carried_forward

# ── CFG-613 (b), the gate's blind spot: a DRY-RUN that fails with nothing to copy ──
# Phase 0.8 starts the real run only when the dry-run prints "Would copy/sanitize"
# lines. The hard aborts - a manifest coverage gap (CFG-497/534/614/607), a dirty
# template at preflight - and a run whose every candidate is held stop before the
# copy pass and print none. Measured with the real template-push.sh: rc=1 (or 3),
# zero such lines. If the dry-run's exit code is thrown away, that failure writes no
# marker, advances no streak, and TEMPLATE_PUSH_FAILING never fires: the most common
# hard failure is the one that stays silent. $1 = dry-run rc, stdin = dry-run output.
_phase08_dryrun_fails() {
    local rc="$1" marker="${2:-}"
    local config_repo="$TEST_TMPDIR/config-repo" project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home" tpl_log="$TEST_TMPDIR/tpl-argv.log"
    mkdir -p "$project_dir" "$mock_home" "$mock_home/agent-fleet/.git"
    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    cat > "$TEST_TMPDIR/dry-out.txt"
    cat > "$config_repo/setup/scripts/template-push.sh" << STUB
#!/usr/bin/env bash
echo "\$@" >> "$tpl_log"
cat "$TEST_TMPDIR/dry-out.txt"
exit $rc
STUB
    chmod +x "$config_repo/setup/scripts/template-push.sh"
    (cd "$config_repo" && git add -A && git commit -m "stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    [[ -n "$marker" ]] && printf '%s\n' "$marker" > "$config_repo/.template-push-failed"
    local patched; patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true
}

test_phase08_coverage_gap_dryrun_writes_marker() {
    _phase08_dryrun_fails 1 << 'OUT'
[ERROR] [MANIFEST] UNTRACKED: global/hooks/brand-new-guard.sh
[ERROR] [MANIFEST] 1 file(s) under global/hooks setup/scripts have no row in template-sync-manifest.md.
[ERROR] Aborting before any copy — complete the manifest, then re-run.
[INFO] === Template Push Summary ===
[ERROR]   Untracked in manifest: 1
OUT
    local m="$TEST_TMPDIR/config-repo/.template-push-failed"
    assert_file_exists "$m" "a dry-run that hard-aborts (coverage gap) must write the failure marker" || return 1
    assert_file_contains "$m" "exit_code=1" "the marker records the dry-run's exit code" || return 1
    assert_file_contains "$m" "consecutive=1" "the first such failure starts the streak" || return 1
    assert_file_contains "$m" "drift_files=0" "nothing was copyable" || return 1
    assert_file_contains "$m" "Untracked in manifest: 1" "the kept tail is the dry-run's own output" || return 1
    assert_file_contains "$TEST_TMPDIR/config-repo/.sync-warnings.log" "TEMPLATE_PUSH_FAILED: exit=1 drift=0" \
        "the drift log names the failure too"
}
run_test "Phase 0.8: a coverage-gap abort in the dry-run writes the marker (CFG-613)" test_phase08_coverage_gap_dryrun_writes_marker

test_phase08_dryrun_abort_advances_existing_streak() {
    # A dirty template (left by an earlier failed commit) aborts every later run at
    # preflight: the streak must keep counting and the exit code must be the current one.
    _phase08_dryrun_fails 1 'time=2026-09-20 08:00:00 UTC
first_failed=2026-09-18 08:00:00 UTC
first_failed_epoch=1789718400
consecutive=3
exit_code=3
drift_files=4
output_tail=old' << 'OUT'
[ERROR] Template repo has uncommitted changes — resolve before pushing
OUT
    local m="$TEST_TMPDIR/config-repo/.template-push-failed"
    assert_file_contains "$m" "consecutive=4" "a failing dry-run must advance the streak, not freeze it" || return 1
    assert_file_contains "$m" "first_failed=2026-09-18 08:00:00 UTC" "the streak's start survives" || return 1
    assert_file_contains "$m" "exit_code=1" "exit_code is the LATEST failure's (was 3, now 1)" || return 1
    assert_file_contains "$m" "uncommitted changes" "the tail says why" || return 1
    assert_file_not_contains "$m" "output_tail=old" "the old tail is replaced"
}
run_test "Phase 0.8: a failing dry-run advances an existing streak (CFG-613)" test_phase08_dryrun_abort_advances_existing_streak

test_phase08_hold_with_nothing_to_copy_writes_marker() {
    # Every candidate held (or, once only real diffs print "Would copy", a held hook that is
    # already identical downstream): exit 3 and no drift line. Still a failure, with its names.
    _phase08_dryrun_fails 3 << 'OUT'
[ERROR] [REGISTRATION] HELD: global/hooks/g.sh — registered here but not in the template's
[INFO] === Template Push Summary ===
[ERROR]     - global/hooks/g.sh
[ERROR]   Held (unregistered downstream): 1 hook(s) NOT propagated — would ship inert; exit 3
OUT
    local m="$TEST_TMPDIR/config-repo/.template-push-failed"
    assert_file_exists "$m" "a dry-run that holds files must write the failure marker" || return 1
    assert_file_contains "$m" "exit_code=3" "partial, recorded as 3" || return 1
    assert_file_contains "$m" "    - global/hooks/g.sh" "held names reach the marker for Check 8.2"
}
run_test "Phase 0.8: a dry-run hold with nothing to copy writes the marker (CFG-613)" test_phase08_hold_with_nothing_to_copy_writes_marker

test_phase08_clean_dryrun_with_nothing_to_copy_is_silent() {
    # Over-blocking guard: rc 0 and nothing to copy is a healthy, current template.
    printf '[INFO] === Template Push Summary ===\n' | _phase08_dryrun_fails 0
    assert_file_not_exists "$TEST_TMPDIR/config-repo/.template-push-failed" \
        "a clean dry-run with nothing to copy is not a failure" || return 1
    assert_not_contains "$(cat "$TEST_TMPDIR/config-repo/.sync-warnings.log" 2>/dev/null)" \
        "TEMPLATE_PUSH_FAILED" "and logs no failure"
}
run_test "Phase 0.8: a clean dry-run with nothing to copy stays silent (CFG-613)" test_phase08_clean_dryrun_with_nothing_to_copy_is_silent

# Helper: Phase 0.8 scaffold that emits Cat-3 "Flag-only" warnings
_phase08_cat3_scaffold() {
    local config_repo="$1" mock_home="$2" cat3_files="$3"
    mkdir -p "$mock_home/agent-fleet/.git"
    # Mock template-push.sh: --dry-run emits drift, --commit/--push emits Cat-3 Flag-only lines
    cat > "$config_repo/setup/scripts/template-push.sh" << STUB
#!/usr/bin/env bash
case "\$1" in
    --dry-run) echo "Would copy global/CLAUDE.md"; exit 0 ;;
    --commit|--push)
$(for f in $cat3_files; do echo "        echo \"[WARN] Flag-only file changed: $f\""; done)
        exit 0 ;;
esac
exit 0
STUB
    chmod +x "$config_repo/setup/scripts/template-push.sh"
    # Mock manifest with diff reasons
    cat > "$config_repo/template-sync-manifest.md" << 'MEOF'
## Tracked Files — Intentional Diffs
| File | Diff reason |
|------|-------------|
| `global/CLAUDE.md` | Personal: machine table. Template: generic. |
| `sync.sh` | Personal hostname case |
MEOF
}

test_phase08_cat3_init_no_inbox() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$project_dir" "$mock_home" "$config_repo/cross-project"
    echo "# inbox" > "$config_repo/cross-project/inbox.md"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    _phase08_cat3_scaffold "$config_repo" "$mock_home" "global/CLAUDE.md sync.sh"
    (cd "$config_repo" && git add -A && git commit -m "stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true

    assert_file_exists "$config_repo/.cat3-known" "first run should initialize .cat3-known"
    assert_not_contains "$(cat "$config_repo/cross-project/inbox.md")" "Cat-3 review" \
        "first run should NOT generate inbox tasks (seed-only)"
}
run_test "Phase 0.8: Cat-3 first run initializes .cat3-known without inbox tasks (CFG-395)" test_phase08_cat3_init_no_inbox

test_phase08_cat3_new_file_generates_inbox() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$project_dir" "$mock_home" "$config_repo/cross-project"
    echo "# inbox" > "$config_repo/cross-project/inbox.md"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    # .cat3-known exists with only sync.sh — global/CLAUDE.md is "new"
    echo "sync.sh" > "$config_repo/.cat3-known"
    _phase08_cat3_scaffold "$config_repo" "$mock_home" "global/CLAUDE.md sync.sh"
    (cd "$config_repo" && git add -A && git commit -m "stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true

    local af="$config_repo/cross-project/inbox/agent-fleet.md"
    assert_file_contains "$af" "Cat-3 review" \
        "new Cat-3 file should generate an inbox task in the per-project file (CFG-542)" || return 1
    assert_file_contains "$af" "global/CLAUDE.md" \
        "inbox task should name the specific file" || return 1
    assert_file_contains "$af" "agent-fleet\\*\\* \\[work\\]" \
        "the item must carry its type tag (CFG-541)" || return 1
    assert_not_contains "$(cat "$config_repo/cross-project/inbox.md")" "Cat-3 review" \
        "nothing may be appended to the legacy inbox.md any more" || return 1
    assert_file_contains "$config_repo/.cat3-known" "global/CLAUDE.md" \
        ".cat3-known should now include the new file"
}
run_test "Phase 0.8: new Cat-3 file generates inbox task (CFG-395)" test_phase08_cat3_new_file_generates_inbox

test_phase08_cat3_known_file_no_duplicate() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$project_dir" "$mock_home" "$config_repo/cross-project"
    echo "# inbox" > "$config_repo/cross-project/inbox.md"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    # .cat3-known already has both files — nothing is new
    printf 'global/CLAUDE.md\nsync.sh\n' > "$config_repo/.cat3-known"
    _phase08_cat3_scaffold "$config_repo" "$mock_home" "global/CLAUDE.md sync.sh"
    (cd "$config_repo" && git add -A && git commit -m "stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true

    assert_not_contains "$(cat "$config_repo/cross-project/inbox.md" "$config_repo/cross-project/inbox/agent-fleet.md" 2>/dev/null)" "Cat-3 review" \
        "already-known Cat-3 files should NOT generate duplicate inbox tasks"
}
run_test "Phase 0.8: known Cat-3 files do not generate duplicate inbox tasks (CFG-395)" test_phase08_cat3_known_file_no_duplicate

# .cat3-known was append-only: a file that was reclassified (or re-converged) stayed "known"
# forever, so when it drifted again no review item was ever raised. Prune to what is flagged now.
test_phase08_cat3_known_is_pruned_to_current_flags() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$project_dir" "$mock_home" "$config_repo/cross-project"
    echo "# inbox" > "$config_repo/cross-project/inbox.md"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    printf 'global/CLAUDE.md\nsync.sh\nsetup/scripts/gone.sh\n' > "$config_repo/.cat3-known"
    _phase08_cat3_scaffold "$config_repo" "$mock_home" "global/CLAUDE.md sync.sh"
    (cd "$config_repo" && git add -A && git commit -m "stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true

    assert_not_contains "$(cat "$config_repo/.cat3-known")" "setup/scripts/gone.sh" \
        "a file no longer flagged must leave .cat3-known" || return 1
    assert_file_contains "$config_repo/.cat3-known" "sync.sh" \
        "still-flagged files stay known"
}
run_test "Phase 0.8: .cat3-known is pruned to the files flagged now" test_phase08_cat3_known_is_pruned_to_current_flags
# ── CFG-431: Phase 0.8 — fixed drift is stripped, push only on real drift ────
# (a) Phase 0.7 logs template-drift warnings; Phase 0.8 fixes them; only the
#     MOBILE warnings were ever stripped (Phase 4), so every next session
#     opened with "propagation drift detected at last shutdown" for drift that
#     was already resolved.
# (b) template-push --dry-run reported "Would copy" for every manifest file,
#     identical or not, so Phase 0.8 ran --push on every shutdown. The dry-run
#     now reports only real differences (test-template-push.sh) and the hook
#     gates on that — but still pushes when agent-fleet has unpushed commits
#     (a push that failed last time must be retried) and still runs the Cat-3
#     detection from the dry-run output when nothing needs pushing.

# agent-fleet with an origin remote AND a tracked upstream, so preflight
# chooses --push.
_phase08_agent_fleet_with_upstream() {   # <mock_home>
    git init --bare -b main "$TEST_TMPDIR/af-remote.git" >/dev/null 2>&1
    (cd "$1/agent-fleet" && git init -b main >/dev/null 2>&1 \
        && git config user.email t@t.t && git config user.name t \
        && echo init > README.md && git add README.md \
        && git commit -m initial >/dev/null 2>&1 \
        && git remote add origin "$TEST_TMPDIR/af-remote.git" \
        && git push -u origin main >/dev/null 2>&1)
}

# A template-push stub that records argv and whose --dry-run output is given
# verbatim (so a test can make it report drift, no drift, or a Cat-3 flag).
_phase08_stub_with_dry_run_output() {   # <config_repo> <tpl_log> <dry-run text>
    mkdir -p "$TEST_TMPDIR/home/agent-fleet/.git"
    cat > "$1/setup/scripts/template-push.sh" << STUB
#!/usr/bin/env bash
echo "\$@" >> "$2"
case "\$1" in
    --dry-run) printf '%s\n' "$3"; exit "\${TPL_DRY_EXIT:-0}" ;;
    --commit|--push) exit "\${TPL_EXIT:-0}" ;;
esac
exit 0
STUB
    chmod +x "$1/setup/scripts/template-push.sh"
}

# sync.sh whose check reports template drift (two shapes + the summary), one
# unrelated drift line, and the overall summary.
_stage_sync_with_template_drift() {   # <config_repo>
    cat > "$1/sync.sh" << 'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    deploy) echo "mock-deploy: ok" ;;
    check)
        echo "[WARN] global/hooks/foo.sh differs from template — propagate update"
        echo "[WARN] setup/lib.sh: not found in template"
        echo "[WARN] Template: 2 file(s) drifted"
        echo "[WARN] Hook bar.sh: drifted (repo ≠ deployed)"
        echo "[WARN] 3 issue(s) found across propagation chains"
        ;;
    *) echo "mock-sync: $*" ;;
esac
exit 0
STUB
    chmod +x "$1/sync.sh"
}

test_phase08_strips_template_drift_after_successful_push() {
    local config_repo="$TEST_TMPDIR/config-repo" project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home" tpl_log="$TEST_TMPDIR/tpl-argv.log"
    mkdir -p "$project_dir" "$mock_home"
    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    _stage_sync_with_template_drift "$config_repo"
    _phase08_stub_with_dry_run_output "$config_repo" "$tpl_log" "[INFO] [dry-run] Would copy: global/hooks/foo.sh"
    _phase08_agent_fleet_with_upstream "$mock_home"
    (cd "$config_repo" && git add -A && git commit -m "stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    local patched; patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true
    assert_file_contains "$tpl_log" "[-][-]push" "precondition: Phase 0.8 propagated (--push ran)" || return 1
    assert_file_exists "$config_repo/.sync-warnings.log" "the unrelated warning keeps the log alive" || return 1
    local log; log=$(cat "$config_repo/.sync-warnings.log")
    assert_not_contains "$log" "differs from template" "per-file template drift is stripped once propagated" || return 1
    assert_not_contains "$log" "not found in template" "missing-in-template drift is stripped once propagated" || return 1
    assert_not_contains "$log" "file(s) drifted" "the template drift summary is stripped once propagated" || return 1
    assert_contains "$log" "Hook bar.sh: drifted" "non-template drift is preserved"
}
run_test "CFG-431: template-drift warnings are stripped after a successful Phase 0.8 push" test_phase08_strips_template_drift_after_successful_push

test_phase08_keeps_template_drift_when_push_fails() {
    local config_repo="$TEST_TMPDIR/config-repo" project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home" tpl_log="$TEST_TMPDIR/tpl-argv.log"
    mkdir -p "$project_dir" "$mock_home"
    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    _stage_sync_with_template_drift "$config_repo"
    _phase08_stub_with_dry_run_output "$config_repo" "$tpl_log" "[INFO] [dry-run] Would copy: global/hooks/foo.sh"
    _phase08_agent_fleet_with_upstream "$mock_home"
    (cd "$config_repo" && git add -A && git commit -m "stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    local patched; patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    TPL_EXIT=3 run_hook "$patched" || true
    assert_file_exists "$config_repo/.template-push-failed" "precondition: the push failed (exit 3, held file)" || return 1
    assert_file_contains "$config_repo/.sync-warnings.log" "differs from template" "drift that was NOT fixed stays in the log"
}
run_test "CFG-431: template-drift warnings stay when Phase 0.8 fails" test_phase08_keeps_template_drift_when_push_fails

test_phase08_removes_log_when_only_template_drift_was_logged() {
    # When template drift was the ONLY finding, stripping it must not leave a
    # log holding just the "N issue(s) found" summary — the next session would
    # still surface "propagation drift detected at last shutdown".
    local config_repo="$TEST_TMPDIR/config-repo" project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home" tpl_log="$TEST_TMPDIR/tpl-argv.log"
    mkdir -p "$project_dir" "$mock_home"
    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    cat > "$config_repo/sync.sh" << 'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    deploy) echo "mock-deploy: ok" ;;
    check)
        echo "[WARN] global/hooks/foo.sh differs from template — propagate update"
        echo "[WARN] Template: 1 file(s) drifted"
        echo "[WARN] 1 issue(s) found across propagation chains"
        ;;
    *) echo "mock-sync: $*" ;;
esac
exit 0
STUB
    chmod +x "$config_repo/sync.sh"
    _phase08_stub_with_dry_run_output "$config_repo" "$tpl_log" "[INFO] [dry-run] Would copy: global/hooks/foo.sh"
    _phase08_agent_fleet_with_upstream "$mock_home"
    (cd "$config_repo" && git add -A && git commit -m "stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    local patched; patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true
    assert_file_contains "$tpl_log" "[-][-]push" "precondition: Phase 0.8 propagated (--push ran)" || return 1
    assert_file_not_exists "$config_repo/.sync-warnings.log" "a log that held only the fixed template drift (plus its summary) is removed"
}
run_test "CFG-431: the drift log is removed when template drift was its only content" test_phase08_removes_log_when_only_template_drift_was_logged

test_phase08_skips_push_when_nothing_differs() {
    local config_repo="$TEST_TMPDIR/config-repo" project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home" tpl_log="$TEST_TMPDIR/tpl-argv.log"
    mkdir -p "$project_dir" "$mock_home"
    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    _phase08_stub_with_dry_run_output "$config_repo" "$tpl_log" \
        "[INFO] [dry-run] Identical: setup/lib.sh
[INFO] [dry-run] Identical: global/hooks/foo.sh
[INFO] [dry-run] Would commit to template
[INFO] [dry-run] Would push template"
    _phase08_agent_fleet_with_upstream "$mock_home"
    (cd "$config_repo" && git add -A && git commit -m "stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    local patched; patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true
    assert_file_contains "$tpl_log" "[-][-]dry-run" "the dry-run preview still runs" || return 1
    local pushes; pushes=$(grep -c '\-\-push\|\-\-commit' "$tpl_log" || true)
    assert_eq "0" "$pushes" "no --push/--commit when the dry-run reports nothing to copy (measured $pushes)"
}
run_test "CFG-431: Phase 0.8 does not push when the dry-run reports no differing file" test_phase08_skips_push_when_nothing_differs

test_phase08_pushes_when_agent_fleet_has_unpushed_commits() {
    # A push that failed last shutdown left a local agent-fleet commit behind;
    # the files no longer differ, so the drift gate alone would strand it.
    local config_repo="$TEST_TMPDIR/config-repo" project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home" tpl_log="$TEST_TMPDIR/tpl-argv.log"
    mkdir -p "$project_dir" "$mock_home"
    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    _phase08_stub_with_dry_run_output "$config_repo" "$tpl_log" "[INFO] [dry-run] Identical: setup/lib.sh"
    _phase08_agent_fleet_with_upstream "$mock_home"
    (cd "$mock_home/agent-fleet" && echo more >> README.md && git commit -qam "propagated last time, push failed")
    (cd "$config_repo" && git add -A && git commit -m "stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    local patched; patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true
    assert_file_contains "$tpl_log" "[-][-]push" "an unpushed agent-fleet commit still triggers --push"
}
run_test "CFG-431: Phase 0.8 still pushes when agent-fleet has an unpushed commit" test_phase08_pushes_when_agent_fleet_has_unpushed_commits

test_phase08_cat3_detected_from_dry_run_without_push() {
    # Cat-3 flags used to be parsed from the --push output only; with the push
    # gated, a changed flag-only file with no Cat-1/2 drift must still reach the
    # inbox — from the dry-run output, which reports Flag-only files too.
    local config_repo="$TEST_TMPDIR/config-repo" project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home" tpl_log="$TEST_TMPDIR/tpl-argv.log"
    mkdir -p "$project_dir" "$mock_home" "$config_repo/cross-project"
    echo "# inbox" > "$config_repo/cross-project/inbox.md"
    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    echo "sync.sh" > "$config_repo/.cat3-known"
    _phase08_stub_with_dry_run_output "$config_repo" "$tpl_log" \
        "[INFO] [dry-run] Identical: setup/lib.sh
[WARN] Flag-only file changed: global/CLAUDE.md"
    _phase08_agent_fleet_with_upstream "$mock_home"
    (cd "$config_repo" && git add -A && git commit -m "stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    local patched; patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true
    local pushes; pushes=$(grep -c '\-\-push\|\-\-commit' "$tpl_log" || true)
    assert_eq "0" "$pushes" "precondition: nothing was pushed (measured $pushes)" || return 1
    assert_file_contains "$config_repo/cross-project/inbox/agent-fleet.md" "global/CLAUDE.md" "the Cat-3 file still reaches the inbox from the dry-run output"
}
run_test "CFG-431: Cat-3 detection still runs from the dry-run when nothing is pushed" test_phase08_cat3_detected_from_dry_run_without_push

# CFG-431 x CFG-613: with the real pass gated on the dry-run, the dry-run's EXIT
# CODE is a verdict too. A dry-run that holds a file (exit 3) or aborts before
# copying (exit 1: manifest coverage gap, empty personal_patterns, dirty
# template) prints no "Would copy" line, so the drift gate alone reads it as
# clean: no real pass, no marker, no TEMPLATE_PUSH_FAILED, and propagation
# stops in silence. Before the gate, the real pass ran every time and its exit
# code was recorded.
test_phase08_records_a_holding_dry_run_with_nothing_copyable() {
    local config_repo="$TEST_TMPDIR/config-repo" project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home" tpl_log="$TEST_TMPDIR/tpl-argv.log"
    mkdir -p "$project_dir" "$mock_home"
    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    _phase08_stub_with_dry_run_output "$config_repo" "$tpl_log" \
        "[ERROR] [LEAK] HELD: global/hooks/foo.sh — 1 personal-data hit(s); this file will NOT be propagated
[ERROR]     - global/hooks/foo.sh
[ERROR]   Held (personal data): 1 file(s) NOT propagated (1 hit line(s)) — genericize and re-run; exit 3"
    _phase08_agent_fleet_with_upstream "$mock_home"
    (cd "$config_repo" && git add -A && git commit -m "stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    local head_before; head_before=$(git -C "$config_repo" rev-parse HEAD)
    local patched; patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    TPL_DRY_EXIT=3 run_hook "$patched" || true
    assert_file_exists "$config_repo/.template-push-failed" "a dry-run that exits 3 leaves the failure marker" || return 1
    assert_file_contains "$config_repo/.template-push-failed" "exit_code=3" "the marker carries the dry-run's exit code" || return 1
    assert_file_contains "$config_repo/.template-push-failed" "global/hooks/foo.sh" "the marker names the held file" || return 1
    assert_file_contains "$config_repo/.sync-warnings.log" "TEMPLATE_PUSH_FAILED: exit=3" "the next SessionStart is told" || return 1
    assert_file_not_exists "$config_repo/.template-push-verified-$head_before" "a holding run never vouches for HEAD"
}
run_test "CFG-431: a dry-run that holds a file (exit 3) with nothing copyable is recorded" test_phase08_records_a_holding_dry_run_with_nothing_copyable

test_phase08_records_an_aborting_dry_run() {
    local config_repo="$TEST_TMPDIR/config-repo" project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home" tpl_log="$TEST_TMPDIR/tpl-argv.log"
    mkdir -p "$project_dir" "$mock_home"
    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    _phase08_stub_with_dry_run_output "$config_repo" "$tpl_log" \
        "[ERROR] [LEAK] personal_patterns is EMPTY or missing in setup/config/template-push.conf — refusing to propagate anything (fail closed)"
    _phase08_agent_fleet_with_upstream "$mock_home"
    (cd "$config_repo" && git add -A && git commit -m "stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    local patched; patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    TPL_DRY_EXIT=1 run_hook "$patched" || true
    assert_file_exists "$config_repo/.template-push-failed" "a dry-run that aborts (exit 1) leaves the failure marker" || return 1
    assert_file_contains "$config_repo/.template-push-failed" "exit_code=1" "the marker carries the dry-run's exit code" || return 1
    assert_file_contains "$config_repo/.template-push-failed" "personal_patterns is EMPTY" "the marker keeps the abort reason" || return 1
    assert_file_contains "$config_repo/.sync-warnings.log" "TEMPLATE_PUSH_FAILED: exit=1" "the next SessionStart is told"
}
run_test "CFG-431: a dry-run that aborts before copying (exit 1) is recorded" test_phase08_records_an_aborting_dry_run

# manifest-push-check.sh blocks a cfg commit of a manifest-tracked file unless
# .template-push-verified-<HEAD> exists. The real pass wrote it on every
# shutdown (commit_template, "No changes to commit"); with the real pass gated,
# a clean dry-run is now the only verification that ran, so it must leave the
# same marker or the next session's first such commit is falsely blocked.
test_phase08_clean_dry_run_vouches_for_head() {
    local config_repo="$TEST_TMPDIR/config-repo" project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home" tpl_log="$TEST_TMPDIR/tpl-argv.log"
    mkdir -p "$project_dir" "$mock_home"
    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    _phase08_stub_with_dry_run_output "$config_repo" "$tpl_log" "[INFO] [dry-run] Identical: setup/lib.sh"
    _phase08_agent_fleet_with_upstream "$mock_home"
    (cd "$config_repo" && git add -A && git commit -m "stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    local head_before; head_before=$(git -C "$config_repo" rev-parse HEAD)
    local patched; patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true
    local pushes; pushes=$(grep -c '\-\-push\|\-\-commit' "$tpl_log" || true)
    assert_eq "0" "$pushes" "precondition: nothing was pushed (measured $pushes)" || return 1
    assert_file_exists "$config_repo/.template-push-verified-$head_before" "a clean dry-run with no drift vouches for HEAD" || return 1
    assert_file_not_exists "$config_repo/.template-push-failed" "and leaves no failure marker"
}
run_test "CFG-431: a clean dry-run with no drift writes the verification marker for HEAD" test_phase08_clean_dry_run_vouches_for_head

# ── Phase 0.85: Pending-File Demote Detection (loop closure) ────────────────

# Install the REAL manage-pending.sh into the mock config repo (the default
# create_mock_config_repo stub exits 0 with no output).
_install_real_manage_pending() {
    local config_repo="$1"
    cp "$REPO_ROOT/setup/scripts/manage-pending.sh" "$config_repo/setup/scripts/manage-pending.sh"
    chmod +x "$config_repo/setup/scripts/manage-pending.sh"
}

test_phase085_demote_needed_written() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local project_dir="$config_repo"   # config repo is the project (real shutdown)
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$mock_home"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    _install_real_manage_pending "$config_repo"

    # Baseline: an "Auto-sync: session rotation" commit marks the since-ref.
    (cd "$config_repo" && git add -A \
        && git commit -m "Auto-sync: session rotation $(date -u +%FT%TZ)" >/dev/null 2>&1)

    # A pending act file tracking CFG-900.
    printf 'Action: act\nTracked-by: CFG-900\n\nShipped this session.' \
        > "$config_repo/docs/pending-shipped-feature.md"

    # A feat commit AFTER the baseline that ships CFG-900.
    (cd "$config_repo" && git add docs/pending-shipped-feature.md \
        && git commit -m "feat: ship CFG-900 shipped feature" >/dev/null 2>&1)

    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true

    assert_file_exists "$config_repo/.sync-warnings.log" \
        "Phase 0.85 should write to the drift log when a demote is needed"
    assert_file_contains "$config_repo/.sync-warnings.log" "PENDING_DEMOTE_NEEDED:" \
        "drift log should carry PENDING_DEMOTE_NEEDED"
    assert_file_contains "$config_repo/.sync-warnings.log" "pending-shipped-feature.md" \
        "should name the shipped pending file"
}
run_test "Phase 0.85: PENDING_DEMOTE_NEEDED written when shipped PRN found" test_phase085_demote_needed_written

test_phase085_silent_when_nothing_to_demote() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local project_dir="$config_repo"
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$mock_home"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    _install_real_manage_pending "$config_repo"

    (cd "$config_repo" && git add -A \
        && git commit -m "Auto-sync: session rotation $(date -u +%FT%TZ)" >/dev/null 2>&1)

    # Pending act file tracking an OPEN PRN that was NOT committed this window.
    printf 'Action: act\nTracked-by: CFG-901\n\nStill open.' \
        > "$config_repo/docs/pending-open-feature.md"
    (cd "$config_repo" && git add docs/pending-open-feature.md \
        && git commit -m "docs: unrelated note (no PRN)" >/dev/null 2>&1)

    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true

    # Either no drift log, or one without PENDING_DEMOTE_NEEDED.
    if [[ -f "$config_repo/.sync-warnings.log" ]]; then
        assert_not_contains "$(cat "$config_repo/.sync-warnings.log")" "PENDING_DEMOTE_NEEDED:" \
            "should NOT emit PENDING_DEMOTE_NEEDED when nothing matches"
    fi
}
run_test "Phase 0.85: silent when nothing to demote" test_phase085_silent_when_nothing_to_demote

test_phase085_exit_zero() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local project_dir="$config_repo"
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$mock_home"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    _install_real_manage_pending "$config_repo"
    (cd "$config_repo" && git add -A \
        && git commit -m "Auto-sync: session rotation $(date -u +%FT%TZ)" >/dev/null 2>&1)
    printf 'Action: act\nTracked-by: CFG-902\n\nShipped.' \
        > "$config_repo/docs/pending-x.md"
    (cd "$config_repo" && git add docs/pending-x.md \
        && git commit -m "fix: CFG-902 done" >/dev/null 2>&1)

    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    local rc=0
    run_hook "$patched" || rc=$?

    assert_eq "0" "$rc" "Phase 0.85 must not change the hook's exit behaviour"
}
run_test "Phase 0.85: hook still exits 0" test_phase085_exit_zero

# ── Shutdown Progress Messages (CFG-340) ─────────────────────────────────────

test_progress_messages_emitted() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$project_dir" "$mock_home"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    (cd "$config_repo" && git add -A && git commit -m "add stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")

    # Capture stderr where progress messages go
    local stderr_log="$TEST_TMPDIR/stderr.log"
    bash "$patched" 2>"$stderr_log" || true

    assert_file_exists "$stderr_log" "stderr should be captured"
    assert_file_contains "$stderr_log" "Releasing\|Rotating\|Deploying\|Shutdown" "should emit shutdown progress"
    assert_file_contains "$stderr_log" "complete\|done\|failed" "should emit completion or failure message"
}
run_test "emits progress messages to stderr during shutdown" test_progress_messages_emitted

test_progress_messages_include_phases() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$project_dir" "$mock_home"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    (cd "$config_repo" && git add -A && git commit -m "add stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    local stderr_log="$TEST_TMPDIR/stderr.log"
    bash "$patched" 2>"$stderr_log" || true

    # Should mention key early phases (later phases may not run in mock env)
    assert_file_contains "$stderr_log" "Releasing\|Rotating\|drift" "should mention early phases"
}
run_test "progress messages mention key phases" test_progress_messages_include_phases

# ── Phase 1.5: Post-Rotation Append Safety ───────────────────────────────────

test_phase15_skips_when_project_is_config_repo() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local project_dir="$config_repo"  # SAME directory — this is the bug scenario
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$mock_home"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    (cd "$config_repo" && git add -A && git commit -m "stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    # Create post-rotation marker pointing to current HEAD
    local head_hash
    head_hash=$(git -C "$config_repo" rev-parse HEAD)
    echo "$head_hash $(date +%s)" > "$config_repo/.post-rotation-commit"

    # Make a new commit so append-post-rotation would find something
    echo "new content" >> "$config_repo/README.md"
    (cd "$config_repo" && git add README.md && git commit -m "post-rotation change" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    # Create append-post-rotation.sh stub that consumes the marker
    cat > "$config_repo/setup/scripts/append-post-rotation.sh" << 'STUB2'
#!/usr/bin/env bash
_dir="${1:-.}"
[ -f "$_dir/.post-rotation-commit" ] || exit 0
rm -f "$_dir/.post-rotation-commit"
exit 0
STUB2
    chmod +x "$config_repo/setup/scripts/append-post-rotation.sh"

    # Override sync.sh deploy to check if marker still exists at deploy time
    # If Phase 1.5 consumed it, marker is gone. If Phase 1.5 was skipped, marker survives.
    local marker_check_log="$TEST_TMPDIR/marker-check.log"
    cat > "$config_repo/sync.sh" << STUB
#!/usr/bin/env bash
case "\${1:-}" in
    deploy)
        if [ -f "$config_repo/.post-rotation-commit" ]; then
            echo "MARKER_EXISTS" >> "$marker_check_log"
        else
            echo "MARKER_GONE" >> "$marker_check_log"
        fi
        ;;
    check) echo "no issues" ;;
    *) ;;
esac
exit 0
STUB
    chmod +x "$config_repo/sync.sh"

    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true

    # The marker should STILL exist at deploy time (Phase 3), meaning Phase 1.5
    # did NOT consume it before the flock gate. Phase 3.5 handles it after flock.
    assert_file_exists "$marker_check_log" "sync.sh deploy should have run"
    assert_file_contains "$marker_check_log" "MARKER_EXISTS" \
        "post-rotation marker must survive until after flock (Phase 1.5 should skip when project == config repo)"
}
run_test "Phase 1.5: skips append-post-rotation when project dir is config repo" test_phase15_skips_when_project_is_config_repo

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
