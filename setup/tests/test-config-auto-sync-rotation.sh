#!/usr/bin/env bash
# Tests for config-auto-sync.sh — phases 1 and 2 (session rotation + commit)
# Split from test-config-auto-sync.sh (CFG-301)
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO_ROOT/setup/tests/test-helpers.sh"
source "$REPO_ROOT/setup/tests/test-config-auto-sync-helpers.sh"

suite_header "config-auto-sync.sh (phases 1-2: rotation + session commit)"

# ── Phase 1: Session Rotation for Current Project ───────────────────────────

test_session_rotation_current_project() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$project_dir" "$mock_home"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"

    # Create a populated session-context.md in the project
    mkdir -p "$project_dir/docs"
    cat > "$project_dir/session-context.md" << 'EOF'
# Session Context
**Session Goal**: Test rotation
- [x] Did stuff
## Key Decisions
- None
EOF

    # Track rotate-session.sh calls
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
    assert_contains "$log_content" "$project_dir" "should rotate the current project"

    unset ROTATE_LOG
}
run_test "Phase 1: rotates session for current project" test_session_rotation_current_project

test_session_rotation_skipped_when_no_context() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$project_dir" "$mock_home"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"

    # No session-context.md in project_dir

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

    # rotate should not be called for the project_dir (no session-context.md)
    if [[ -f "$ROTATE_LOG" ]]; then
        local log_content
        log_content=$(<"$ROTATE_LOG")
        assert_not_contains "$log_content" "$project_dir" "should not rotate project without session-context.md"
    fi

    unset ROTATE_LOG
}
run_test "Phase 1: skips rotation when no session-context.md" test_session_rotation_skipped_when_no_context

test_session_rotation_skipped_when_empty() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$project_dir" "$mock_home"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"

    # Create an empty session-context.md
    touch "$project_dir/session-context.md"

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

    # empty file (-s test fails) => rotation should be skipped
    if [[ -f "$ROTATE_LOG" ]]; then
        local log_content
        log_content=$(<"$ROTATE_LOG")
        assert_not_contains "$log_content" "$project_dir" "should not rotate empty session-context.md"
    fi

    unset ROTATE_LOG
}
run_test "Phase 1: skips rotation when session-context.md is empty" test_session_rotation_skipped_when_empty

test_session_rotation_failure_logged() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$project_dir/docs" "$mock_home"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"

    cat > "$project_dir/session-context.md" << 'EOF'
# Session Context
**Session Goal**: Test rotation failure
- [x] One thing
## Key Decisions
- Test
EOF

    # Make rotate-session.sh fail
    cat > "$config_repo/setup/scripts/rotate-session.sh" << 'STUB'
#!/usr/bin/env bash
exit 1
STUB
    chmod +x "$config_repo/setup/scripts/rotate-session.sh"

    (cd "$config_repo" && git add -A && git commit -m "add stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    local rc=0
    run_hook "$patched" || rc=$?

    # Should still exit 0
    assert_eq "0" "$rc" "hook should exit 0 even if rotation fails"

    # Should log warning
    assert_file_exists "$config_repo/.sync-warnings.log" "should log rotation failure"
    assert_file_contains "$config_repo/.sync-warnings.log" "rotate-session failed" "should contain rotation failure message"
}
run_test "Phase 1: rotation failure logged to .sync-warnings.log" test_session_rotation_failure_logged

# ── Phase 1/2: Rotation failure prevents Phase 2 commit ─────────────────────

test_rotation_failure_skips_commit() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$project_dir/docs" "$mock_home"

    # Make project_dir a git repo (needed for Phase 2)
    create_git_repo_main "$project_dir"
    mkdir -p "$project_dir/docs"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"

    cat > "$project_dir/session-context.md" << 'EOF'
# Session Context
**Session Goal**: Test
- [x] One
## Key Decisions
- Test
EOF
    # Stage it so there would be something to commit
    (cd "$project_dir" && git add session-context.md && git commit -m "add context" >/dev/null 2>&1)

    # Make rotate-session.sh fail
    cat > "$config_repo/setup/scripts/rotate-session.sh" << 'STUB'
#!/usr/bin/env bash
exit 1
STUB
    chmod +x "$config_repo/setup/scripts/rotate-session.sh"

    (cd "$config_repo" && git add -A && git commit -m "add stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    # Modify session-context.md so there would be something to commit if Phase 2 ran
    echo "modified" >> "$project_dir/session-context.md"

    local before_count
    before_count=$(cd "$project_dir" && git rev-list --count HEAD)

    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true

    local after_count
    after_count=$(cd "$project_dir" && git rev-list --count HEAD)

    # Phase 2 should be skipped because _ORIG_ROTATE_OK=0
    assert_eq "$before_count" "$after_count" "should NOT commit when rotation failed"
}
run_test "Phase 1/2: rotation failure prevents session commit" test_rotation_failure_skips_commit

# ── Phase 2: Session Commit in Non-Config-Repo Projects ─────────────────────

test_session_commit_separate_project() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$mock_home"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    (cd "$config_repo" && git add -A && git commit -m "add stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    # Create a separate project with its own git repo
    create_git_repo_main "$project_dir"
    mkdir -p "$project_dir/docs"

    cat > "$project_dir/session-context.md" << 'EOF'
# Session Context
**Session Goal**: Test commit
- [x] Work item
## Key Decisions
- Decision
EOF
    (cd "$project_dir" && git add session-context.md && git commit -m "initial context" >/dev/null 2>&1)

    # Modify files that Phase 2 would commit
    echo "rotated" > "$project_dir/session-context.md"
    echo "history" > "$project_dir/session-history.md"
    mkdir -p "$project_dir/docs"
    echo "log entry" > "$project_dir/docs/session-log.md"

    local before_count
    before_count=$(cd "$project_dir" && git rev-list --count HEAD)

    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true

    local after_count
    after_count=$(cd "$project_dir" && git rev-list --count HEAD)

    # Should have committed session files
    assert_neq "$before_count" "$after_count" "should commit session files in separate project"

    # Check commit message
    local msg
    msg=$(cd "$project_dir" && git log -1 --format='%s')
    assert_contains "$msg" "Auto-sync" "commit message should contain Auto-sync"
}
run_test "Phase 2: commits session files in separate project" test_session_commit_separate_project

test_session_commit_skipped_for_config_repo() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$mock_home"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    (cd "$config_repo" && git add -A && git commit -m "add stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    # Create session-context.md in the config repo itself
    cat > "$config_repo/session-context.md" << 'EOF'
# Session Context
**Session Goal**: Config work
- [x] Rule edit
## Key Decisions
- Config decision
EOF

    local before_count
    before_count=$(cd "$config_repo" && git rev-list --count HEAD)

    # Run hook with ORIGINAL_DIR = CONFIG_REPO
    local patched
    patched=$(create_patched_hook "$config_repo" "$config_repo" "$mock_home")
    run_hook "$patched" || true

    # Phase 2 should be skipped (ORIGINAL_DIR == CONFIG_REPO)
    # Phase 3 handles config repo commits separately
    # Just verify no Phase 2 "Auto-sync: session rotation" commit appears
    local msgs
    msgs=$(cd "$config_repo" && git log --oneline | head -5)
    # The only auto-sync commit should be Phase 3's, not Phase 2's "session rotation"
    local session_rotation_count
    session_rotation_count=$(echo "$msgs" | grep -c "session rotation" || true)
    assert_eq "0" "$session_rotation_count" "should not create Phase 2 session rotation commit for config repo"
}
run_test "Phase 2: skips session commit when working in config repo" test_session_commit_skipped_for_config_repo

test_session_commit_skipped_when_no_changes() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$mock_home"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    (cd "$config_repo" && git add -A && git commit -m "add stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    # Create project with already-committed session files (no changes)
    create_git_repo_main "$project_dir"
    mkdir -p "$project_dir/docs"
    echo "context" > "$project_dir/session-context.md"
    echo "history" > "$project_dir/session-history.md"
    echo "log" > "$project_dir/docs/session-log.md"
    (cd "$project_dir" && git add -A && git commit -m "add session files" >/dev/null 2>&1)

    local before_count
    before_count=$(cd "$project_dir" && git rev-list --count HEAD)

    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true

    local after_count
    after_count=$(cd "$project_dir" && git rev-list --count HEAD)

    assert_eq "$before_count" "$after_count" "should not commit when session files unchanged"
}
run_test "Phase 2: no commit when session files are unchanged" test_session_commit_skipped_when_no_changes

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
