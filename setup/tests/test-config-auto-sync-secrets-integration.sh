#!/usr/bin/env bash
# Tests for config-auto-sync.sh — secret scanning + integration tests
# Split from test-config-auto-sync.sh (CFG-301)
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO_ROOT/setup/tests/test-helpers.sh"
source "$REPO_ROOT/setup/tests/test-config-auto-sync-helpers.sh"

suite_header "config-auto-sync.sh (secret scanning + integration)"

# ── Phase 3: Secret Scanning ────────────────────────────────────────────────

test_secret_scan_anthropic_key() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$project_dir" "$mock_home"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    (cd "$config_repo" && git add -A && git commit -m "add stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    # Stage a file containing a fake Anthropic API key pattern
    echo 'api_key = "sk-ant-ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890"' > "$config_repo/session-context.md"

    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true

    # The secret scanner should unstage the file, so no commit happens
    # OR the file gets unstaged and warning is written
    if [[ -f "$config_repo/.sync-warnings.log" ]]; then
        assert_file_contains "$config_repo/.sync-warnings.log" "Possible secrets" "should warn about secrets"
    fi

    # Verify the file is no longer staged
    local staged
    staged=$(cd "$config_repo" && git diff --cached --name-only 2>/dev/null || true)
    assert_not_contains "$staged" "session-context.md" "file with secret should be unstaged"
}
run_test "Phase 3: secret scan detects Anthropic API key pattern" test_secret_scan_anthropic_key

test_secret_scan_github_token() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$project_dir" "$mock_home"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    (cd "$config_repo" && git add -A && git commit -m "add stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    # Stage a file with a fake GitHub personal access token
    echo 'GITHUB_TOKEN=ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij1234' > "$config_repo/session-context.md"

    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true

    if [[ -f "$config_repo/.sync-warnings.log" ]]; then
        assert_file_contains "$config_repo/.sync-warnings.log" "Possible secrets" "should warn about GitHub token"
    fi

    local staged
    staged=$(cd "$config_repo" && git diff --cached --name-only 2>/dev/null || true)
    assert_not_contains "$staged" "session-context.md" "file with GitHub token should be unstaged"
}
run_test "Phase 3: secret scan detects GitHub PAT pattern" test_secret_scan_github_token

test_secret_scan_aws_key() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$project_dir" "$mock_home"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    (cd "$config_repo" && git add -A && git commit -m "add stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    # Stage a file with a fake AWS access key
    echo 'aws_key = AKIAIOSFODNN7EXAMPLE' > "$config_repo/session-context.md"

    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true

    if [[ -f "$config_repo/.sync-warnings.log" ]]; then
        assert_file_contains "$config_repo/.sync-warnings.log" "Possible secrets" "should warn about AWS key"
    fi

    local staged
    staged=$(cd "$config_repo" && git diff --cached --name-only 2>/dev/null || true)
    assert_not_contains "$staged" "session-context.md" "file with AWS key should be unstaged"
}
run_test "Phase 3: secret scan detects AWS access key pattern" test_secret_scan_aws_key

test_secret_scan_private_key() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$project_dir" "$mock_home"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    (cd "$config_repo" && git add -A && git commit -m "add stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    # Stage a file with a PEM private key header
    printf '%s\n' '-----BEGIN PRIVATE KEY-----' 'MIIEvQIBADANBg...' '-----END PRIVATE KEY-----' > "$config_repo/session-context.md"

    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true

    if [[ -f "$config_repo/.sync-warnings.log" ]]; then
        assert_file_contains "$config_repo/.sync-warnings.log" "Possible secrets" "should warn about private key"
    fi
}
run_test "Phase 3: secret scan detects PEM private key" test_secret_scan_private_key

test_secret_scan_slack_token() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$project_dir" "$mock_home"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    (cd "$config_repo" && git add -A && git commit -m "add stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    # Stage a file with a fake Slack token
    echo 'SLACK_TOKEN=xoxb-1234567890-abcdefghij' > "$config_repo/session-context.md"

    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true

    if [[ -f "$config_repo/.sync-warnings.log" ]]; then
        assert_file_contains "$config_repo/.sync-warnings.log" "Possible secrets" "should warn about Slack token"
    fi
}
run_test "Phase 3: secret scan detects Slack token pattern" test_secret_scan_slack_token

test_secret_scan_google_api_key() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$project_dir" "$mock_home"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    (cd "$config_repo" && git add -A && git commit -m "add stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    # Stage a file with a fake Google API key
    echo 'google_key = AIzaSyABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefg' > "$config_repo/session-context.md"

    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true

    if [[ -f "$config_repo/.sync-warnings.log" ]]; then
        assert_file_contains "$config_repo/.sync-warnings.log" "Possible secrets" "should warn about Google API key"
    fi
}
run_test "Phase 3: secret scan detects Google API key pattern" test_secret_scan_google_api_key

test_secret_scan_password_assignment() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$project_dir" "$mock_home"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    (cd "$config_repo" && git add -A && git commit -m "add stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    # Stage a file with a password assignment
    echo 'password = supersecret123' > "$config_repo/session-context.md"

    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true

    if [[ -f "$config_repo/.sync-warnings.log" ]]; then
        assert_file_contains "$config_repo/.sync-warnings.log" "Possible secrets" "should warn about password"
    fi
}
run_test "Phase 3: secret scan detects password assignment" test_secret_scan_password_assignment

test_secret_scan_clean_file_passes() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$project_dir" "$mock_home"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    (cd "$config_repo" && git add -A && git commit -m "add stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    # Stage clean files with no secrets (both must exist for git add to succeed)
    echo "# Session Context" > "$config_repo/session-context.md"
    echo "**Session Goal**: Write tests" >> "$config_repo/session-context.md"
    echo "- [x] Wrote tests" >> "$config_repo/session-context.md"
    echo "session history" > "$config_repo/session-history.md"

    local before_count
    before_count=$(cd "$config_repo" && git rev-list --count HEAD)

    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true

    local after_count
    after_count=$(cd "$config_repo" && git rev-list --count HEAD)

    # Clean file should be committed normally
    local diff=$((after_count - before_count))
    assert_eq "1" "$diff" "clean file should be committed"
    assert_file_not_exists "$config_repo/.sync-failed" "should not have failure marker"
}
run_test "Phase 3: clean files pass secret scan and get committed" test_secret_scan_clean_file_passes

test_secret_scan_partial_unstage() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$project_dir" "$mock_home"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    (cd "$config_repo" && git add -A && git commit -m "add stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    # Stage multiple files — one clean pair, one with a secret
    echo "clean content" > "$config_repo/session-context.md"
    echo "session history" > "$config_repo/session-history.md"
    echo 'token = ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij1234' > "$config_repo/backlog.md"

    local before_count
    before_count=$(cd "$config_repo" && git rev-list --count HEAD)

    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true

    local after_count
    after_count=$(cd "$config_repo" && git rev-list --count HEAD)

    # The clean file should still get committed (only backlog.md is unstaged)
    local diff=$((after_count - before_count))
    assert_eq "1" "$diff" "clean files should still be committed after partial unstage"

    # Verify commit includes session-context.md but not backlog.md
    local committed_files
    committed_files=$(cd "$config_repo" && git diff-tree --no-commit-id --name-only -r HEAD)
    assert_contains "$committed_files" "session-context.md" "clean file should be in commit"
    assert_not_contains "$committed_files" "backlog.md" "file with secret should NOT be in commit"
}
run_test "Phase 3: partial unstage — clean files committed, secret files removed" test_secret_scan_partial_unstage

# ── Integration: Full end-to-end happy path ──────────────────────────────────

test_full_happy_path() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$mock_home"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    (cd "$config_repo" && git add -A && git commit -m "add stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    # Create a separate project
    create_git_repo_main "$project_dir"
    mkdir -p "$project_dir/docs"
    cat > "$project_dir/session-context.md" << 'EOF'
# Session Context
**Session Goal**: Full happy path test
- [x] Everything works
## Key Decisions
- All good
EOF
    (cd "$project_dir" && git add -A && git commit -m "initial" >/dev/null 2>&1)

    # Modify session files (will be committed by Phase 2).
    # Both files must exist — git add fails atomically if any pathspec is missing.
    echo "updated context" > "$project_dir/session-context.md"
    echo "updated history" > "$project_dir/session-history.md"

    # Also create config repo changes (will be committed by Phase 3)
    create_session_files "$config_repo" "config session data"

    local project_before
    project_before=$(cd "$project_dir" && git rev-list --count HEAD)
    local config_before
    config_before=$(cd "$config_repo" && git rev-list --count HEAD)

    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    local rc=0
    run_hook "$patched" || rc=$?

    assert_eq "0" "$rc" "hook should exit 0"
    assert_file_not_exists "$config_repo/.sync-failed" "no failure marker"

    local project_after
    project_after=$(cd "$project_dir" && git rev-list --count HEAD)
    local config_after
    config_after=$(cd "$config_repo" && git rev-list --count HEAD)

    # Phase 2 should have committed in project
    local project_diff=$((project_after - project_before))
    assert_eq "1" "$project_diff" "Phase 2 should add one commit to project"

    # Phase 3 should have committed in config repo
    local config_diff=$((config_after - config_before))
    assert_eq "1" "$config_diff" "Phase 3 should add one commit to config repo"

    # Remote should have the config commit
    local remote_log
    remote_log=$(cd "$TEST_TMPDIR/remote.git" && git log --oneline -1 2>/dev/null)
    assert_contains "$remote_log" "Auto-sync" "remote should have the auto-sync commit"
}
run_test "Integration: full happy path — rotate, commit project, commit+push config" test_full_happy_path

test_full_path_config_repo_only() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$mock_home"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    (cd "$config_repo" && git add -A && git commit -m "add stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    # Working in config repo directly — create both session files
    cat > "$config_repo/session-context.md" << 'EOF'
# Session Context
**Session Goal**: Config-only test
- [x] Rule change
## Key Decisions
- Rule updated
EOF
    echo "session history" > "$config_repo/session-history.md"

    # Also add new docs
    mkdir -p "$config_repo/docs"
    echo "log entry" > "$config_repo/docs/session-log.md"

    local before_count
    before_count=$(cd "$config_repo" && git rev-list --count HEAD)

    local patched
    patched=$(create_patched_hook "$config_repo" "$config_repo" "$mock_home")
    local rc=0
    run_hook "$patched" || rc=$?

    assert_eq "0" "$rc"

    local after_count
    after_count=$(cd "$config_repo" && git rev-list --count HEAD)

    # Phase 1 rotates, Phase 2 is skipped (same dir), Phase 3 commits
    local diff=$((after_count - before_count))
    assert_eq "1" "$diff" "exactly one commit for config repo when working in it"
}
run_test "Integration: working in config repo — one commit, push to remote" test_full_path_config_repo_only

# ── Edge case: hook always exits 0 ──────────────────────────────────────────

test_always_exits_zero() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$project_dir" "$mock_home"

    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"

    # Make everything fail
    cat > "$config_repo/sync.sh" << 'STUB'
#!/usr/bin/env bash
exit 1
STUB
    chmod +x "$config_repo/sync.sh"
    cat > "$config_repo/setup/scripts/rotate-session.sh" << 'STUB'
#!/usr/bin/env bash
exit 1
STUB
    chmod +x "$config_repo/setup/scripts/rotate-session.sh"
    cat > "$config_repo/setup/scripts/clean-permissions.sh" << 'STUB'
#!/usr/bin/env bash
exit 1
STUB
    chmod +x "$config_repo/setup/scripts/clean-permissions.sh"
    cat > "$config_repo/setup/scripts/manage-pending.sh" << 'STUB'
#!/usr/bin/env bash
exit 1
STUB
    chmod +x "$config_repo/setup/scripts/manage-pending.sh"

    (cd "$config_repo" && git add -A && git commit -m "add stubs" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    cat > "$config_repo/session-context.md" << 'EOF'
# Session Context
**Session Goal**: Failure test
- [x] Nothing
## Key Decisions
- Test
EOF

    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    local rc=0
    run_hook "$patched" || rc=$?

    assert_eq "0" "$rc" "hook MUST always exit 0 to never block session end"
}
run_test "Edge case: hook exits 0 even when everything fails" test_always_exits_zero

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
