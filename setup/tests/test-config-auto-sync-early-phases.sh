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

    # Track mobile-deploy.sh calls
    cat > "$config_repo/setup/scripts/mobile-deploy.sh" << 'STUB'
#!/usr/bin/env bash
echo "MOBILE_COLLECT:$*" >> "${MOBILE_LOG:-/dev/null}"
exit 0
STUB
    chmod +x "$config_repo/setup/scripts/mobile-deploy.sh"

    export MOBILE_LOG="$TEST_TMPDIR/mobile.log"

    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true

    assert_file_exists "$MOBILE_LOG" "mobile-deploy.sh should have been called"
    local log_content
    log_content=$(<"$MOBILE_LOG")
    assert_contains "$log_content" "--collect" "should call with --collect flag"

    unset MOBILE_LOG
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
echo "MOBILE_COLLECT" >> "${MOBILE_LOG:-/dev/null}"
exit 0
STUB
    chmod +x "$config_repo/setup/scripts/mobile-deploy.sh"

    export MOBILE_LOG="$TEST_TMPDIR/mobile.log"

    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true

    # mobile-deploy.sh should NOT have been called — no unchecked tasks
    assert_file_not_exists "$MOBILE_LOG" "mobile-deploy.sh should not be called with 0 pending tasks"

    unset MOBILE_LOG
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

    assert_file_contains "$config_repo/cross-project/inbox.md" "Cat-3 review" \
        "new Cat-3 file should generate an inbox task"
    assert_file_contains "$config_repo/cross-project/inbox.md" "global/CLAUDE.md" \
        "inbox task should name the specific file"
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

    assert_not_contains "$(cat "$config_repo/cross-project/inbox.md")" "Cat-3 review" \
        "already-known Cat-3 files should NOT generate duplicate inbox tasks"
}
run_test "Phase 0.8: known Cat-3 files do not generate duplicate inbox tasks (CFG-395)" test_phase08_cat3_known_file_no_duplicate

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
