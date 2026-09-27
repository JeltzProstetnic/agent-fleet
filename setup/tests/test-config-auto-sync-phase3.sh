#!/usr/bin/env bash
# Tests for config-auto-sync.sh — phase 3 core (sync, push, flock, staging, deploy)
# Split from test-config-auto-sync.sh (CFG-301)
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO_ROOT/setup/tests/test-helpers.sh"
source "$REPO_ROOT/setup/tests/test-config-auto-sync-helpers.sh"

suite_header "config-auto-sync.sh (phase 3: config repo sync)"

# ── Phase 3: Config Repo Sync ───────────────────────────────────────────────

test_config_repo_collect_and_commit() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$project_dir" "$mock_home"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    (cd "$config_repo" && git add -A && git commit -m "add stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    # Create files that Phase 3 would stage.
    # IMPORTANT: git add session-context.md session-history.md fails atomically
    # if session-history.md doesn't exist — both files must be present.
    create_session_files "$config_repo" "session data"

    local before_count
    before_count=$(cd "$config_repo" && git rev-list --count HEAD)

    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true

    local after_count
    after_count=$(cd "$config_repo" && git rev-list --count HEAD)

    # Should have committed
    local diff=$((after_count - before_count))
    assert_eq "1" "$diff" "should create exactly one Phase 3 commit"

    # Check commit message
    local msg
    msg=$(cd "$config_repo" && git log -1 --format='%s')
    assert_contains "$msg" "Auto-sync:" "commit message should start with Auto-sync:"
}
run_test "Phase 3: collects, commits, and pushes config repo" test_config_repo_collect_and_commit

test_config_repo_push_success_clears_marker() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$project_dir" "$mock_home"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    (cd "$config_repo" && git add -A && git commit -m "add stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    # Pre-create a .sync-failed marker from a previous run
    echo "stage=push" > "$config_repo/.sync-failed"

    # Create files to trigger a commit (both must exist for git add to succeed)
    create_session_files "$config_repo" "data"

    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true

    assert_file_not_exists "$config_repo/.sync-failed" "successful push should clear .sync-failed marker"
}
run_test "Phase 3: successful push clears .sync-failed marker" test_config_repo_push_success_clears_marker

test_config_repo_no_changes_exits_clean() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$project_dir" "$mock_home"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    (cd "$config_repo" && git add -A && git commit -m "add stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    # No changes to stage — everything is already committed

    local before_count
    before_count=$(cd "$config_repo" && git rev-list --count HEAD)

    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    local rc=0
    run_hook "$patched" || rc=$?

    assert_eq "0" "$rc" "should exit 0 when nothing to sync"

    local after_count
    after_count=$(cd "$config_repo" && git rev-list --count HEAD)
    assert_eq "$before_count" "$after_count" "should not create commit when nothing changed"
    assert_file_not_exists "$config_repo/.sync-failed" "should not create failure marker"
}
run_test "Phase 3: exits cleanly when nothing to sync" test_config_repo_no_changes_exits_clean

test_deploy_failure_writes_sync_failed() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$project_dir" "$mock_home"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"

    # Make sync.sh deploy fail
    cat > "$config_repo/sync.sh" << 'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    deploy) echo "fatal error in deploy"; exit 1 ;;
    check)   echo "ok" ;;
    *)       echo "$*" ;;
esac
STUB
    chmod +x "$config_repo/sync.sh"

    (cd "$config_repo" && git add -A && git commit -m "add stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    local rc=0
    run_hook "$patched" || rc=$?

    # Deploy failure is non-fatal — logs warning but continues to commit+push
    assert_eq "0" "$rc"
    assert_file_exists "$config_repo/.sync-warnings.log" "should log deploy failure to warnings"
    assert_file_contains "$config_repo/.sync-warnings.log" "deploy failed" "should mention deploy failure"
}
run_test "Phase 3: deploy failure logs warning but continues" test_deploy_failure_writes_sync_failed

test_push_failure_writes_sync_failed() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$project_dir" "$mock_home"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    (cd "$config_repo" && git add -A && git commit -m "add stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    # Create files to commit (both must exist for git add to succeed)
    create_session_files "$config_repo" "new data"

    # Remove the remote to make push fail
    (cd "$config_repo" && git remote remove origin)

    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    local rc=0
    run_hook "$patched" || rc=$?

    assert_eq "0" "$rc" "should exit 0 even on push failure"
    assert_file_exists "$config_repo/.sync-failed" "should write .sync-failed on push failure"
    assert_file_contains "$config_repo/.sync-failed" "push" "should record push as failed stage"
}
run_test "Phase 3: push failure writes .sync-failed marker" test_push_failure_writes_sync_failed

# ── Phase 3: Dual-Remote Handling ────────────────────────────────────────────

test_dual_remote_push_to_private() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$project_dir" "$mock_home"

    # Create two remotes
    local private_remote="$TEST_TMPDIR/private.git"
    local public_remote="$TEST_TMPDIR/public.git"

    mkdir -p "$private_remote" "$public_remote"
    git init --bare -b main "$private_remote" >/dev/null 2>&1
    git init --bare -b main "$public_remote" >/dev/null 2>&1

    create_mock_config_repo "$config_repo"
    create_git_repo_main "$config_repo"

    (
        cd "$config_repo"
        git remote add origin "$public_remote"
        git remote add private "$private_remote"
        git push -u origin main >/dev/null 2>&1
        git push private main >/dev/null 2>&1
        git add -A && git commit -m "add stubs" >/dev/null 2>&1
        git push origin main >/dev/null 2>&1
        git push private main >/dev/null 2>&1
    )

    # Create .push-filter.conf specifying private remote
    echo "private_remote=private" > "$config_repo/.push-filter.conf"

    # Create files to commit (both must exist for git add to succeed)
    create_session_files "$config_repo" "new content"

    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true

    # Verify push went to private remote (has the commit)
    local private_log
    private_log=$(cd "$private_remote" && git log --oneline -1 2>/dev/null)
    assert_contains "$private_log" "Auto-sync" "private remote should have the commit"

    # Public remote should NOT have it (still at 'add stubs')
    local public_log
    public_log=$(cd "$public_remote" && git log --oneline -1 2>/dev/null)
    assert_not_contains "$public_log" "Auto-sync" "public remote should NOT have the auto-sync commit"
}
run_test "Phase 3: pushes to private remote when .push-filter.conf exists" test_dual_remote_push_to_private

test_default_push_to_origin() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$project_dir" "$mock_home"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    (cd "$config_repo" && git add -A && git commit -m "add stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    # No .push-filter.conf — should default to origin
    create_session_files "$config_repo" "content"

    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true

    # Verify origin has the commit
    local remote_log
    remote_log=$(cd "$TEST_TMPDIR/remote.git" && git log --oneline -1 2>/dev/null)
    assert_contains "$remote_log" "Auto-sync" "origin should have the commit"
}
run_test "Phase 3: defaults to origin push when no .push-filter.conf" test_default_push_to_origin

# ── Phase 3: flock blocking wait behavior ────────────────────────────────────

test_flock_waits_then_proceeds() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$project_dir" "$mock_home"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    (cd "$config_repo" && git add -A && git commit -m "add stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    echo "data" > "$config_repo/session-context.md"

    # Hold the lock briefly then release in background (simulates another session finishing)
    local lock_file="$config_repo/.sync-lock"
    (
        exec 8>"$lock_file"
        flock -n 8
        sleep 2
        flock -u 8
        exec 8>&-
    ) &
    local lock_pid=$!
    sleep 0.5

    local before_count
    before_count=$(cd "$config_repo" && git rev-list --count HEAD)

    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    local rc=0
    run_hook "$patched" || rc=$?

    wait "$lock_pid" 2>/dev/null || true

    # Hook should succeed after waiting for lock
    assert_eq "0" "$rc" "hook should succeed after lock is released"

    local after_count
    after_count=$(cd "$config_repo" && git rev-list --count HEAD)
    assert_neq "$before_count" "$after_count" "should commit after waiting for lock"
}
run_test "Phase 3: flock blocking — waits then commits" test_flock_waits_then_proceeds

# ── Phase 3: Config repo session rotation ────────────────────────────────────

test_config_repo_rotation_when_different_project() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$project_dir" "$mock_home"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"

    # Create session-context.md in config repo (separate from project)
    cat > "$config_repo/session-context.md" << 'EOF'
# Session Context
**Session Goal**: Config maintenance
- [x] Updated rules
## Key Decisions
- None
EOF

    # Track rotate calls
    cat > "$config_repo/setup/scripts/rotate-session.sh" << 'STUB'
#!/usr/bin/env bash
echo "ROTATE:$1" >> "${ROTATE_LOG:-/dev/null}"
exit 0
STUB
    chmod +x "$config_repo/setup/scripts/rotate-session.sh"

    (cd "$config_repo" && git add -A && git commit -m "add stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    export ROTATE_LOG="$TEST_TMPDIR/rotate.log"

    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true

    assert_file_exists "$ROTATE_LOG"
    local log_content
    log_content=$(<"$ROTATE_LOG")
    # Should rotate config repo as part of Phase 3 (since project != config repo)
    assert_contains "$log_content" "$config_repo" "should rotate config repo session"

    unset ROTATE_LOG
}
run_test "Phase 3: rotates config repo session when project differs" test_config_repo_rotation_when_different_project

test_config_repo_rotation_skipped_when_same_project() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$mock_home"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"

    cat > "$config_repo/session-context.md" << 'EOF'
# Session Context
**Session Goal**: Config work
- [x] Edited rules
## Key Decisions
- Test
EOF

    # Track rotate calls
    cat > "$config_repo/setup/scripts/rotate-session.sh" << 'STUB'
#!/usr/bin/env bash
echo "ROTATE:$1" >> "${ROTATE_LOG:-/dev/null}"
exit 0
STUB
    chmod +x "$config_repo/setup/scripts/rotate-session.sh"

    (cd "$config_repo" && git add -A && git commit -m "add stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    export ROTATE_LOG="$TEST_TMPDIR/rotate.log"

    # ORIGINAL_DIR == CONFIG_REPO
    local patched
    patched=$(create_patched_hook "$config_repo" "$config_repo" "$mock_home")
    run_hook "$patched" || true

    assert_file_exists "$ROTATE_LOG"
    local log_content
    log_content=$(<"$ROTATE_LOG")
    # Phase 1 rotates config_repo (since ORIGINAL_DIR == config_repo)
    # Phase 3 should NOT rotate again (condition: ORIGINAL_DIR != CONFIG_REPO)
    local rotate_count
    rotate_count=$(grep -c "ROTATE:" "$ROTATE_LOG" || true)
    assert_eq "1" "$rotate_count" "config repo should only be rotated once, not twice"

    unset ROTATE_LOG
}
run_test "Phase 3: config repo NOT rotated again when it IS the project" test_config_repo_rotation_skipped_when_same_project

# ── Phase 3: Staging patterns ───────────────────────────────────────────────

test_stages_expected_directories() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$project_dir" "$mock_home"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    (cd "$config_repo" && git add -A && git commit -m "add stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    # Create files in the directories the hook stages.
    # IMPORTANT: git add with multiple pathspecs fails atomically if any pathspec
    # doesn't exist. So we must create all directories referenced on the same
    # git add line:
    #   git add session-context.md session-history.md  (line 1)
    #   git add docs/ projects/ cross-project/         (line 2)
    #   git add global/ backlog.md registry.md ...     (line 3)
    echo "session" > "$config_repo/session-context.md"
    echo "history" > "$config_repo/session-history.md"
    echo "backlog" > "$config_repo/backlog.md"
    echo "registry" > "$config_repo/registry.md"
    echo "manifest" > "$config_repo/template-sync-manifest.md"
    mkdir -p "$config_repo/docs" "$config_repo/projects" "$config_repo/global" "$config_repo/cross-project"
    echo "doc" > "$config_repo/docs/session-log.md"
    echo "proj" > "$config_repo/projects/placeholder.md"
    echo "global" > "$config_repo/global/test.md"
    echo "inbox" > "$config_repo/cross-project/inbox.md"

    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true

    # Verify all expected files are in the commit
    local committed_files
    committed_files=$(cd "$config_repo" && git diff-tree --no-commit-id --name-only -r HEAD)
    assert_contains "$committed_files" "session-context.md"
    assert_contains "$committed_files" "session-history.md"
    assert_contains "$committed_files" "backlog.md"
    assert_contains "$committed_files" "registry.md"
    assert_contains "$committed_files" "template-sync-manifest.md"
    assert_contains "$committed_files" "docs/session-log.md"
    assert_contains "$committed_files" "global/test.md"
    assert_contains "$committed_files" "cross-project/inbox.md"
}
run_test "Phase 3: stages session, docs, global, cross-project, backlog, registry" test_stages_expected_directories

# ── Phase 3: Config repo missing ────────────────────────────────────────────

test_config_repo_missing_writes_sync_failed() {
    local config_repo="$TEST_TMPDIR/nonexistent-config-repo"
    local project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$project_dir" "$mock_home"

    # Don't create config_repo — but we need sync_fail to be able to write
    # Actually the hook does `cd "$CONFIG_REPO"` which will fail
    # and then calls sync_fail which writes to $FAIL_MARKER
    # Since config_repo doesn't exist, FAIL_MARKER dir doesn't exist either
    # The hook should handle this gracefully (exit 0 still)

    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")

    local rc=0
    bash "$patched" 2>/dev/null || rc=$?

    # Hook should exit 0 — never blocks session end
    assert_eq "0" "$rc" "hook should exit 0 even when config repo missing"
}
run_test "Phase 3: missing config repo handled gracefully" test_config_repo_missing_writes_sync_failed

# ── v1.0: Phase 3 uses deploy instead of collect (CFG-291) ───────────────────

test_phase3_calls_deploy_not_collect() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$project_dir" "$mock_home"

    create_mock_config_repo "$config_repo"

    # Replace sync.sh stub to log which command was called
    cat > "$config_repo/sync.sh" << 'STUB'
#!/usr/bin/env bash
echo "sync-called: $1" >> "$0.log"
exit 0
STUB
    chmod +x "$config_repo/sync.sh"

    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    (cd "$config_repo" && git add -A && git commit -m "add stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    create_session_files "$config_repo" "test data"

    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true

    local log="$config_repo/sync.sh.log"
    assert_file_exists "$log" "sync.sh should have been called"
    assert_not_contains "$(cat "$log")" "sync-called: collect" "Phase 3 must NOT call sync.sh collect"
    assert_contains "$(cat "$log")" "sync-called: deploy" "Phase 3 must call sync.sh deploy"
}
run_test "v1.0: Phase 3 calls deploy instead of collect" test_phase3_calls_deploy_not_collect

test_deploy_failure_in_phase3_writes_sync_failed() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$project_dir" "$mock_home"

    create_mock_config_repo "$config_repo"

    # Make sync.sh deploy fail
    cat > "$config_repo/sync.sh" << 'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    deploy) echo "fatal error in deploy"; exit 1 ;;
    *)      echo "$*" ;;
esac
STUB
    chmod +x "$config_repo/sync.sh"

    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    (cd "$config_repo" && git add -A && git commit -m "add stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    create_session_files "$config_repo" "test data"

    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    local rc=0
    run_hook "$patched" || rc=$?

    assert_eq "0" "$rc" "hook must still exit 0"
    # Deploy failure is non-fatal — logs to warnings, continues to commit+push
    assert_file_exists "$config_repo/.sync-warnings.log" "should log deploy failure to warnings"
    assert_file_contains "$config_repo/.sync-warnings.log" "deploy failed" "should mention deploy failure"
}
run_test "v1.0: deploy failure logs warning but continues" test_deploy_failure_in_phase3_writes_sync_failed

# ── Phase 4: Mobile drift log cleanup ───────────────────────────────────────

test_phase4_clears_mobile_staleness_from_drift_log() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local remote_repo="$TEST_TMPDIR/remote.git"
    local project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home"
    local mobile_repo="$TEST_TMPDIR/home/agent-fleet-mobile"
    mkdir -p "$mock_home" "$project_dir"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$remote_repo"

    # Make sync.sh check return mobile staleness warnings (so Phase 0.7 writes them)
    cat > "$config_repo/sync.sh" << 'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    deploy)  echo "mock-deploy: ok" ;;
    check)
        echo "[INFO] Checking mobile repo staleness..."
        echo "[WARN] dashboard-cache.md: mobile repo is stale (source newer than snapshot)"
        echo "[WARN] inbox.md: mobile repo is stale (source newer than snapshot)"
        echo "[WARN] 2 file(s) stale."
        ;;
    *)       echo "mock-sync: $*" ;;
esac
exit 0
STUB
    chmod +x "$config_repo/sync.sh"
    (cd "$config_repo" && git add -A && git commit -m "add stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    # Create mobile repo
    create_tracked_repo_main "$mobile_repo" "$TEST_TMPDIR/mobile-remote.git"
    mkdir -p "$mobile_repo/context"

    create_session_files "$config_repo" "test data"

    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true

    # After Phase 4 runs, mobile staleness warnings should be cleaned from drift log
    if [ -f "$config_repo/.sync-warnings.log" ]; then
        local remaining
        remaining=$(cat "$config_repo/.sync-warnings.log")
        assert_not_contains "$remaining" "mobile repo is stale" \
            "should remove mobile staleness warnings after Phase 4 refresh"
    fi
    # If file was deleted entirely (all warnings were mobile-related), that's correct too
}
run_test "Phase 4: clears mobile staleness from drift log after refresh" test_phase4_clears_mobile_staleness_from_drift_log

test_phase4_preserves_non_mobile_drift_warnings() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local remote_repo="$TEST_TMPDIR/remote.git"
    local project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home"
    local mobile_repo="$TEST_TMPDIR/home/agent-fleet-mobile"
    mkdir -p "$mock_home" "$project_dir"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$remote_repo"

    # Make sync.sh check return mixed warnings (mobile + template)
    cat > "$config_repo/sync.sh" << 'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    deploy)  echo "mock-deploy: ok" ;;
    check)
        echo "[WARN] dashboard-cache.md: mobile repo is stale (source newer than snapshot)"
        echo "[WARN] CLAUDE.md has drifted from template"
        echo "[WARN] 2 issue(s) found across propagation chains"
        ;;
    *)       echo "mock-sync: $*" ;;
esac
exit 0
STUB
    chmod +x "$config_repo/sync.sh"
    (cd "$config_repo" && git add -A && git commit -m "add stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    # Create mobile repo
    create_tracked_repo_main "$mobile_repo" "$TEST_TMPDIR/mobile-remote.git"
    mkdir -p "$mobile_repo/context"

    create_session_files "$config_repo" "test data"

    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true

    # Mobile warning should be gone but template warning preserved
    assert_file_exists "$config_repo/.sync-warnings.log" \
        "drift log should still exist with non-mobile warnings"
    assert_file_contains "$config_repo/.sync-warnings.log" "drifted from template" \
        "should preserve template drift warnings"
}
run_test "Phase 4: preserves non-mobile drift warnings" test_phase4_preserves_non_mobile_drift_warnings

# CFG-431 (a), mobile side: the real `sync.sh check` also prints the staleness
# summary "N file(s) stale. Run 'sync.sh mobile-deploy' to refresh." and the
# overall "N issue(s) found" line. The refresh fixes what they count, but the
# strip removed only the per-file lines and deleted a log only when it was
# blank — so the summaries kept the log alive and the next session still
# opened with "propagation drift detected" for drift that no longer existed.
test_phase4_removes_a_log_left_with_only_summaries() {
    local config_repo="$TEST_TMPDIR/config-repo" project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home" mobile_repo="$TEST_TMPDIR/home/agent-fleet-mobile"
    mkdir -p "$mock_home" "$project_dir"
    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    cat > "$config_repo/sync.sh" << 'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    deploy)  echo "mock-deploy: ok" ;;
    check)
        echo "[INFO] Checking mobile repo staleness..."
        echo "[WARN] dashboard-cache.md: mobile repo is stale (source newer than snapshot)"
        echo "[WARN] 1 file(s) stale. Run 'sync.sh mobile-deploy' to refresh."
        echo "[WARN] 1 issue(s) found across propagation chains"
        ;;
    *)       echo "mock-sync: $*" ;;
esac
exit 0
STUB
    chmod +x "$config_repo/sync.sh"
    (cd "$config_repo" && git add -A && git commit -m "add stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    create_tracked_repo_main "$mobile_repo" "$TEST_TMPDIR/mobile-remote.git"
    mkdir -p "$mobile_repo/context"
    local patched; patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true
    assert_file_not_exists "$config_repo/.sync-warnings.log" \
        "a log left with only the staleness and issue summaries is removed after the refresh"
}
run_test "Phase 4: a drift log left with only summary lines is removed (CFG-431)" test_phase4_removes_a_log_left_with_only_summaries

# ── Phase 5: deployment-local shim (CFG-676) ─────────────────────────────────
# The hook carries nothing deployment-specific. Whatever ONE fleet needs at
# shutdown (this repo: the VPS follower-blob credential refresh) lives in
# $CONFIG_REPO/setup/scripts/config-auto-sync-local.sh, which the hook runs as
# a subprocess after commit+push. Those steps are tested with the shim, in
# test-config-auto-sync-local.sh; here only the hook-side contract is pinned:
# absent → no-op; present → invoked once, with CONFIG_REPO and ORIGINAL_DIR in
# its environment and the auto-sync commit already pushed; failing → shutdown
# still completes cleanly.

_prep_phase5_repo() {   # <config_repo> <remote>
    create_mock_config_repo "$1"
    create_tracked_repo_main "$1" "$2"
    (cd "$1" && git add -A && git commit -m "add stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    create_session_files "$1" "test data"
}

# A fixture shim that records its environment and the repo state it sees.
_stage_recording_shim() {   # <config_repo> <log>
    cat > "$1/setup/scripts/config-auto-sync-local.sh" << EOF
#!/usr/bin/env bash
printf 'CONFIG_REPO=%s\nORIGINAL_DIR=%s\nHEAD=%s\nPUSHED=%s\nSUBJECT=%s\n' \\
    "\${CONFIG_REPO:-}" "\${ORIGINAL_DIR:-}" \\
    "\$(git -C "\${CONFIG_REPO:-.}" rev-parse HEAD 2>/dev/null)" \\
    "\$(git -C "\${CONFIG_REPO:-.}" rev-parse origin/main 2>/dev/null)" \\
    "\$(git -C "\${CONFIG_REPO:-.}" log -1 --format=%s 2>/dev/null)" >> "$2"
EOF
}

test_phase5_absent_shim_is_noop() {
    local config_repo="$TEST_TMPDIR/config-repo" project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home" rc=0
    mkdir -p "$project_dir" "$mock_home"
    _prep_phase5_repo "$config_repo" "$TEST_TMPDIR/remote.git"
    local patched; patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    RUN_HOOK_VERBOSE=1 run_hook "$patched" >/dev/null 2>"$TEST_TMPDIR/err" || rc=$?
    assert_eq "0" "$rc" "hook exits 0 without a shim (measured rc: $rc)" || return 1
    assert_file_not_exists "$config_repo/.sync-failed" "no failure marker without a shim" || return 1
    assert_file_contains "$TEST_TMPDIR/err" "Shutdown complete." "shutdown ran to completion"
}
run_test "Phase 5: no config-auto-sync-local.sh → nothing runs, shutdown completes" test_phase5_absent_shim_is_noop

test_phase5_runs_shim_after_push_with_env() {
    local config_repo="$TEST_TMPDIR/config-repo" project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home" log="$TEST_TMPDIR/shim.log"
    mkdir -p "$project_dir" "$mock_home"
    _prep_phase5_repo "$config_repo" "$TEST_TMPDIR/remote.git"
    _stage_recording_shim "$config_repo" "$log"
    local patched; patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true
    assert_file_exists "$log" "the shim ran" || return 1
    local runs; runs=$(grep -c '^CONFIG_REPO=' "$log" || true)
    assert_eq "1" "$runs" "the shim ran exactly once (measured: $runs)" || return 1
    assert_file_contains "$log" "CONFIG_REPO=$config_repo" "CONFIG_REPO is the config repo" || return 1
    assert_file_contains "$log" "ORIGINAL_DIR=$project_dir" "ORIGINAL_DIR is the project the session ran in" || return 1
    local head pushed subject
    head=$(sed -n 's/^HEAD=//p' "$log"); pushed=$(sed -n 's/^PUSHED=//p' "$log"); subject=$(sed -n 's/^SUBJECT=//p' "$log")
    assert_contains "$subject" "Auto-sync:" "the shim saw the auto-sync commit already made (subject: '$subject')" || return 1
    assert_eq "$head" "$pushed" "the shim ran AFTER the push (HEAD $head == origin/main $pushed)"
}
run_test "Phase 5: the shim runs once, after commit+push, with CONFIG_REPO and ORIGINAL_DIR set" test_phase5_runs_shim_after_push_with_env

test_phase5_failing_shim_does_not_block_shutdown() {
    local config_repo="$TEST_TMPDIR/config-repo" project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home" rc=0
    mkdir -p "$project_dir" "$mock_home"
    _prep_phase5_repo "$config_repo" "$TEST_TMPDIR/remote.git"
    printf '#!/usr/bin/env bash\necho "shim exploding" >&2\nexit 1\n' > "$config_repo/setup/scripts/config-auto-sync-local.sh"
    local patched; patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    RUN_HOOK_VERBOSE=1 run_hook "$patched" >/dev/null 2>"$TEST_TMPDIR/err" || rc=$?
    assert_eq "0" "$rc" "hook exits 0 although the shim failed (measured rc: $rc)" || return 1
    assert_file_not_exists "$config_repo/.sync-failed" "a failing shim writes no failure marker" || return 1
    assert_file_contains "$TEST_TMPDIR/err" "Shutdown complete." "shutdown still ran to completion"
}
run_test "Phase 5: a failing shim never blocks shutdown" test_phase5_failing_shim_does_not_block_shutdown

# ── CFG-634: the tail runs even when Phase 3 has nothing to commit ───────────
# Every Phase 4/5 test above seeds uncommitted session files first, so Phase 3
# always had something to stage and the tail was always reached. That is the
# one case a well-behaved session never produces: session-shutdown.md commits
# and pushes explicitly, hands the hook a clean tree, and the hook took the
# "nothing to commit" early exit — `sync_success` is `exit 0` — before the
# mobile refresh (Phase 4) and the deployment-local shim (Phase 5). Measured:
# every mobile snapshot commit ever made landed 1-3 s after a cfg Auto-sync
# commit and never otherwise; the VPS token expired on the last such day.
# These fixtures deliberately do NOT call create_session_files.

# A mobile-deploy stub that always leaves something new under context/, so a
# Phase 4 that runs is visible as a commit on the mobile remote.
_stage_mobile_deploy_stub() {   # <config_repo>
    cat > "$1/setup/scripts/mobile-deploy.sh" << 'STUB'
#!/usr/bin/env bash
target=""
while [ $# -gt 0 ]; do case "$1" in --target) target="$2"; shift 2 ;; *) shift ;; esac; done
[ -n "$target" ] || exit 0
mkdir -p "$target/context"
date +%s%N > "$target/context/snapshot.md"
STUB
    chmod +x "$1/setup/scripts/mobile-deploy.sh"
}

_prep_clean_tree_repo() {   # <config_repo> <remote>  — everything committed AND pushed
    create_mock_config_repo "$1"
    _stage_mobile_deploy_stub "$1"
    create_tracked_repo_main "$1" "$2"
    (cd "$1" && git add -A && git commit -m "add stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
}

test_phase4_runs_when_nothing_to_commit() {
    local config_repo="$TEST_TMPDIR/config-repo" project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home" mobile_repo="$TEST_TMPDIR/home/agent-fleet-mobile"
    mkdir -p "$project_dir" "$mock_home"
    _prep_clean_tree_repo "$config_repo" "$TEST_TMPDIR/remote.git"
    create_tracked_repo_main "$mobile_repo" "$TEST_TMPDIR/mobile-remote.git"
    local before; before=$(git -C "$TEST_TMPDIR/mobile-remote.git" rev-parse main)
    local patched; patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true
    local cfg_commits; cfg_commits=$(git -C "$config_repo" log origin/main..HEAD --oneline | wc -l | tr -d ' ')
    assert_eq "0" "$cfg_commits" "precondition: Phase 3 had nothing to commit (measured $cfg_commits new cfg commit(s))" || return 1
    local after; after=$(git -C "$TEST_TMPDIR/mobile-remote.git" rev-parse main)
    assert_neq "$before" "$after" "the mobile remote advanced although Phase 3 committed nothing (before $before, after $after)" || return 1
    local subject; subject=$(git -C "$TEST_TMPDIR/mobile-remote.git" log -1 --format=%s main)
    assert_contains "$subject" "mobile context snapshots" "the pushed commit is the Phase 4 snapshot commit (subject: '$subject')"
}
run_test "CFG-634: Phase 4 pushes the mobile snapshot when Phase 3 had nothing to commit" test_phase4_runs_when_nothing_to_commit

test_phase5_runs_when_nothing_to_commit() {
    local config_repo="$TEST_TMPDIR/config-repo" project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home" log="$TEST_TMPDIR/shim.log" rc=0
    mkdir -p "$project_dir" "$mock_home"
    _prep_clean_tree_repo "$config_repo" "$TEST_TMPDIR/remote.git"
    _stage_recording_shim "$config_repo" "$log"
    local patched; patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    RUN_HOOK_VERBOSE=1 run_hook "$patched" >/dev/null 2>"$TEST_TMPDIR/err" || rc=$?
    assert_eq "0" "$rc" "hook exits 0 (measured rc: $rc)" || return 1
    assert_file_exists "$log" "the shim ran although Phase 3 committed nothing" || return 1
    local runs; runs=$(grep -c '^CONFIG_REPO=' "$log" || true)
    assert_eq "1" "$runs" "the shim ran exactly once (measured: $runs)" || return 1
    assert_file_contains "$TEST_TMPDIR/err" "Shutdown complete." "shutdown still ran to completion" || return 1
    assert_file_not_exists "$config_repo/.sync-failed" "no failure marker on the clean-tree path"
}
run_test "CFG-634: Phase 5 runs the shim when Phase 3 had nothing to commit" test_phase5_runs_when_nothing_to_commit

test_phase4_and_5_run_when_config_repo_held_by_other() {
    # The other early exit on the same line: the config repo is held by a
    # DIFFERENT live session (CFG-665), so nothing is staged or committed —
    # but the mobile refresh and the local shim touch no cfg working file and
    # must still run. rotate-session.sh's exit 3 is how the hook learns the
    # repo is held when check_lock is unavailable (the harness mock lib).
    local config_repo="$TEST_TMPDIR/config-repo" project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home" mobile_repo="$TEST_TMPDIR/home/agent-fleet-mobile"
    local log="$TEST_TMPDIR/shim.log"
    mkdir -p "$project_dir" "$mock_home"
    _prep_clean_tree_repo "$config_repo" "$TEST_TMPDIR/remote.git"
    printf '#!/usr/bin/env bash\nexit 3\n' > "$config_repo/setup/scripts/rotate-session.sh"
    echo "live cfg session's context" > "$config_repo/session-context.md"
    echo "live cfg session's edit" >> "$config_repo/backlog.md"
    (cd "$config_repo" && git add -A && git commit -m "cfg state" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    echo "in-progress, must not be swept" >> "$config_repo/backlog.md"
    _stage_recording_shim "$config_repo" "$log"
    create_tracked_repo_main "$mobile_repo" "$TEST_TMPDIR/mobile-remote.git"
    local before; before=$(git -C "$TEST_TMPDIR/mobile-remote.git" rev-parse main)
    local commits_before; commits_before=$(git -C "$config_repo" rev-list --count HEAD)
    local patched; patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true
    local commits_after; commits_after=$(git -C "$config_repo" rev-list --count HEAD)
    assert_eq "$commits_before" "$commits_after" "held repo: no cfg commit (measured $commits_before -> $commits_after)" || return 1
    local after; after=$(git -C "$TEST_TMPDIR/mobile-remote.git" rev-parse main)
    assert_neq "$before" "$after" "held repo: the mobile snapshot was still pushed" || return 1
    assert_file_exists "$log" "held repo: the shim still ran"
}
run_test "CFG-634: held config repo skips the commit but Phases 4 and 5 still run" test_phase4_and_5_run_when_config_repo_held_by_other

# ── CFG-634: a failed cfg commit or push records the failure and runs the tail ─
# sync_fail is `exit 0`, and it was still how Phase 3 reported a refused push:
# the mobile refresh and the deployment-local shim were skipped on every
# shutdown whose cfg push failed. A non-fast-forward because another machine
# pushed cfg first repeats on every later shutdown, so the tail would stay dead
# exactly as long as the push did. Neither Phase 4 nor Phase 5 depends on the
# cfg push; the failure is recorded (.sync-failed survives to the final exit)
# and the hook carries on.

# Another clone pushes to the cfg remote, so this machine's next push is a
# non-fast-forward.
_advance_cfg_remote_elsewhere() {   # <remote>
    git clone -q "$1" "$TEST_TMPDIR/other-machine" \
        && (cd "$TEST_TMPDIR/other-machine" && git config user.email o@o.o && git config user.name o \
            && echo other > other.md && git add other.md && git commit -qm "other machine" && git push -q origin main)
}

test_tail_runs_when_push_of_unpushed_commits_is_rejected() {
    local config_repo="$TEST_TMPDIR/config-repo" project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home" mobile_repo="$TEST_TMPDIR/home/agent-fleet-mobile"
    local log="$TEST_TMPDIR/shim.log" rc=0
    mkdir -p "$project_dir" "$mock_home"
    _prep_clean_tree_repo "$config_repo" "$TEST_TMPDIR/remote.git"
    _stage_recording_shim "$config_repo" "$log"
    (cd "$config_repo" && git add -A && git commit -qm "shim" && git push -q origin main)
    _advance_cfg_remote_elsewhere "$TEST_TMPDIR/remote.git"
    (cd "$config_repo" && echo mine > mine.md && git add mine.md && git commit -qm "session's own commit, not yet pushed")
    create_tracked_repo_main "$mobile_repo" "$TEST_TMPDIR/mobile-remote.git"
    local before; before=$(git -C "$TEST_TMPDIR/mobile-remote.git" rev-parse main)
    local patched; patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    RUN_HOOK_VERBOSE=1 run_hook "$patched" >/dev/null 2>"$TEST_TMPDIR/err" || rc=$?
    assert_eq "0" "$rc" "hook exits 0 (measured rc: $rc)" || return 1
    assert_file_contains "$config_repo/.sync-failed" "stage=push" "precondition: the cfg push was refused and recorded" || return 1
    assert_file_contains "$config_repo/.sync-failed" "rejected" "the marker carries git's reason, not only 'push failed'" || return 1
    local after; after=$(git -C "$TEST_TMPDIR/mobile-remote.git" rev-parse main)
    assert_neq "$before" "$after" "Phase 4 still pushed the mobile snapshot" || return 1
    assert_file_exists "$log" "Phase 5 still ran the shim" || return 1
    assert_file_contains "$TEST_TMPDIR/err" "Shutdown complete." "shutdown ran to completion"
}
run_test "CFG-634: a rejected push of unpushed commits is recorded and Phases 4 and 5 still run" test_tail_runs_when_push_of_unpushed_commits_is_rejected

test_tail_runs_when_push_after_commit_is_rejected() {
    local config_repo="$TEST_TMPDIR/config-repo" project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home" mobile_repo="$TEST_TMPDIR/home/agent-fleet-mobile"
    local log="$TEST_TMPDIR/shim.log"
    mkdir -p "$project_dir" "$mock_home"
    _prep_clean_tree_repo "$config_repo" "$TEST_TMPDIR/remote.git"
    _stage_recording_shim "$config_repo" "$log"
    (cd "$config_repo" && git add -A && git commit -qm "shim" && git push -q origin main)
    _advance_cfg_remote_elsewhere "$TEST_TMPDIR/remote.git"
    echo "dirty" >> "$config_repo/backlog.md"
    create_tracked_repo_main "$mobile_repo" "$TEST_TMPDIR/mobile-remote.git"
    local before; before=$(git -C "$TEST_TMPDIR/mobile-remote.git" rev-parse main)
    local patched; patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true
    local subject; subject=$(git -C "$config_repo" log -1 --format=%s)
    assert_contains "$subject" "Auto-sync:" "precondition: Phase 3 committed" || return 1
    assert_file_contains "$config_repo/.sync-failed" "stage=push" "the refused push is recorded and the marker survives the final exit" || return 1
    local after; after=$(git -C "$TEST_TMPDIR/mobile-remote.git" rev-parse main)
    assert_neq "$before" "$after" "Phase 4 still pushed the mobile snapshot" || return 1
    assert_file_exists "$log" "Phase 5 still ran the shim"
}
run_test "CFG-634: a rejected push after the Auto-sync commit is recorded and Phases 4 and 5 still run" test_tail_runs_when_push_after_commit_is_rejected

test_tail_runs_when_commit_fails() {
    local config_repo="$TEST_TMPDIR/config-repo" project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home" log="$TEST_TMPDIR/shim.log"
    mkdir -p "$project_dir" "$mock_home"
    _prep_clean_tree_repo "$config_repo" "$TEST_TMPDIR/remote.git"
    _stage_recording_shim "$config_repo" "$log"
    (cd "$config_repo" && git add -A && git commit -qm "shim" && git push -q origin main)
    local remote_before; remote_before=$(git -C "$TEST_TMPDIR/remote.git" rev-parse main)
    printf '#!/bin/sh\nexit 1\n' > "$config_repo/.git/hooks/pre-commit"; chmod +x "$config_repo/.git/hooks/pre-commit"
    echo "dirty" >> "$config_repo/backlog.md"
    local patched; patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true
    assert_file_contains "$config_repo/.sync-failed" "stage=commit" "the refused commit is recorded" || return 1
    assert_eq "$remote_before" "$(git -C "$TEST_TMPDIR/remote.git" rev-parse main)" "nothing is pushed after a failed commit" || return 1
    assert_file_exists "$log" "Phase 5 still ran the shim"
}
run_test "CFG-634: a failed Auto-sync commit is recorded, nothing is pushed, and Phase 5 still runs" test_tail_runs_when_commit_fails

# ── CFG-634 x CFG-626: the mobile snapshot leaves only by declared policy ─────
# Since CFG-634, Phase 4 runs on every leader shutdown; before it, a clean-tree
# shutdown never reached it. The snapshot carries excerpts of EVERY registry
# project's session-context and backlog plus the registry, dashboard and inbox,
# and the leak gate only catches credential values — so a project whose content
# may not go to an external host went out on every shutdown. Until a deployment
# declares that its snapshot may leave (setup/config/mobile-deploy.conf:
# push=allow), Phase 4 refreshes the local copy and commits and pushes nothing.

test_phase4_holds_the_push_without_an_egress_policy() {
    local config_repo="$TEST_TMPDIR/config-repo" project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home" mobile_repo="$TEST_TMPDIR/home/agent-fleet-mobile" log="$TEST_TMPDIR/shim.log"
    mkdir -p "$project_dir" "$mock_home"
    _prep_clean_tree_repo "$config_repo" "$TEST_TMPDIR/remote.git"
    _stage_recording_shim "$config_repo" "$log"
    (cd "$config_repo" && git rm -q setup/config/mobile-deploy.conf && git add -A && git commit -qm "no egress policy" && git push -q origin main)
    create_tracked_repo_main "$mobile_repo" "$TEST_TMPDIR/mobile-remote.git"
    local before; before=$(git -C "$TEST_TMPDIR/mobile-remote.git" rev-parse main)
    local patched; patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true
    assert_file_exists "$mobile_repo/context/snapshot.md" "precondition: the local refresh still ran" || return 1
    assert_eq "$before" "$(git -C "$TEST_TMPDIR/mobile-remote.git" rev-parse main)" "the mobile remote did not move" || return 1
    local local_commits; local_commits=$(git -C "$mobile_repo" log --oneline | wc -l | tr -d ' ')
    assert_eq "1" "$local_commits" "nothing was committed locally either, so nothing waits to be pushed later (measured $local_commits)" || return 1
    assert_file_contains "$config_repo/.sync-warnings.log" "MOBILE_PUSH_HELD" "the next SessionStart is told why the phone snapshot is not moving" || return 1
    assert_file_exists "$log" "Phase 5 is not affected by the hold"
}
run_test "CFG-634 x CFG-626: without an egress policy the mobile snapshot is refreshed locally, never committed or pushed" test_phase4_holds_the_push_without_an_egress_policy

test_phase4_explicit_hold_is_honoured_without_a_warning() {
    local config_repo="$TEST_TMPDIR/config-repo" project_dir="$TEST_TMPDIR/project" rc=0
    local mock_home="$TEST_TMPDIR/home" mobile_repo="$TEST_TMPDIR/home/agent-fleet-mobile"
    mkdir -p "$project_dir" "$mock_home"
    _prep_clean_tree_repo "$config_repo" "$TEST_TMPDIR/remote.git"
    printf '# the owner decided\npush=hold\n' > "$config_repo/setup/config/mobile-deploy.conf"
    (cd "$config_repo" && git add -A && git commit -qm "explicit hold" && git push -q origin main)
    create_tracked_repo_main "$mobile_repo" "$TEST_TMPDIR/mobile-remote.git"
    local before; before=$(git -C "$TEST_TMPDIR/mobile-remote.git" rev-parse main)
    local patched; patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    RUN_HOOK_VERBOSE=1 run_hook "$patched" >/dev/null 2>"$TEST_TMPDIR/err" || rc=$?
    assert_eq "$before" "$(git -C "$TEST_TMPDIR/mobile-remote.git" rev-parse main)" "push=hold: the mobile remote did not move" || return 1
    assert_file_contains "$TEST_TMPDIR/err" "push=hold" "the shutdown output says the push is held and why" || return 1
    if [ -f "$config_repo/.sync-warnings.log" ]; then
        assert_not_contains "$(cat "$config_repo/.sync-warnings.log")" "MOBILE_PUSH_HELD" "a deliberate hold is not a warning" || return 1
    fi
    assert_eq "0" "$rc" "shutdown exits 0 (measured $rc)"
}
run_test "CFG-634 x CFG-626: push=hold holds the push and is not reported as a problem" test_phase4_explicit_hold_is_honoured_without_a_warning

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
