#!/usr/bin/env bash
# Tests for global/hooks/config-check.sh — SessionStart hook
source "$(dirname "$0")/test-helpers.sh"

HOOK_SCRIPT="$REPO_ROOT/global/hooks/config-check.sh"

suite_header "config-check.sh (SessionStart hook)"

# ── Helpers ──────────────────────────────────────────────────────────────────

# Create a git repo on branch "main" regardless of global git config
create_git_repo_main() {
    local path="$1"
    mkdir -p "$path"
    (
        cd "$path"
        git init -b main >/dev/null 2>&1
        git config user.email "test@test.com"
        git config user.name "Test"
        echo "init" > README.md
        git add README.md
        git commit -m "Initial commit" >/dev/null 2>&1
    )
}

# Create a tracked repo on branch "main"
create_tracked_repo_main() {
    local repo_path="$1"
    local remote_path="$2"
    local remote_name="${3:-origin}"

    mkdir -p "$remote_path"
    git init --bare -b main "$remote_path" >/dev/null 2>&1
    create_git_repo_main "$repo_path"
    (
        cd "$repo_path"
        git remote add "$remote_name" "$remote_path"
        git push -u "$remote_name" main >/dev/null 2>&1
    )
}

# Create a minimal config repo structure that _detect_config_repo() will find
create_mock_config_repo() {
    local dir="$1"
    mkdir -p "$dir/setup/scripts"
    touch "$dir/sync.sh"
    # Copy clean-permissions.sh so Check 10 can find it
    if [ -f "$REPO_ROOT/setup/scripts/clean-permissions.sh" ]; then
        cp "$REPO_ROOT/setup/scripts/clean-permissions.sh" "$dir/setup/scripts/"
    fi
    create_git_repo_main "$dir"
}

# Build a patched version of config-check.sh that:
#   - Uses a hardcoded CONFIG_REPO instead of _detect_config_repo()
#   - Runs with a controlled HOME
#   - Runs from a controlled working directory (for PROJECT_DIR = $(pwd))
#
# Instead of fragile sed on the multi-line function, we write a wrapper
# that defines _detect_config_repo first, then evals the rest of the
# original script with the function redefined.
create_patched_script() {
    local config_repo="$1"
    local mock_home="$2"
    local project_dir="$3"
    local patched="$TEST_TMPDIR/config-check-patched.sh"

    cat > "$patched" << WRAPPER_EOF
#!/usr/bin/env bash
# Patched config-check.sh for testing

# Override HOME
export HOME="$mock_home"

# Point CONFIG_CHECK_DIR to the real checks/ modules (BASH_SOURCE breaks under eval)
export CONFIG_CHECK_DIR="$REPO_ROOT/global/hooks/checks"

# cd into project dir so \$(pwd) returns what we want
cd "$project_dir"

# Pre-define _detect_config_repo so when the script defines it, ours
# has already been used. Actually — the script calls _detect_config_repo
# at definition time via CONFIG_REPO="\$(_detect_config_repo)". So we
# need to redefine it BEFORE the script runs, and then skip the script's
# definition.
#
# Strategy: use sed to remove the function body and replace the
# CONFIG_REPO assignment line, then eval.

_detect_config_repo() {
    echo "$config_repo"
}

# Read the original script, remove the _detect_config_repo function body
# (lines 6-17 approximately), and eval the rest
eval "\$(awk '
    /^_detect_config_repo\(\)/ { skip=1; next }
    skip && /^\}/ { skip=0; next }
    skip { next }
    { print }
' "$HOOK_SCRIPT")"
WRAPPER_EOF

    chmod +x "$patched"
    echo "$patched"
}

# Run the patched script. Captures stdout.
run_hook() {
    local patched="$1"
    shift
    bash "$patched" "$@" 2>/dev/null
}

# ── Tests ────────────────────────────────────────────────────────────────────

# ── 1. Sync failure detection ────────────────────────────────────────────────

test_sync_failure_detection() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    # Create CLAUDE.md as symlink so check 2 passes
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create .sync-failed marker
    cat > "$config_repo/.sync-failed" << 'EOF'
stage=collect
time=2026-03-01T10:00:00Z
detail=git push failed
EOF

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "CONFIG SYNC FAILED" "should warn about sync failure"
    assert_contains "$output" "collect" "should include stage"
    assert_contains "$output" "2026-03-01" "should include time"
    assert_contains "$output" "git push failed" "should include detail"
}
run_test "sync failure: warns with stage, time, and detail" test_sync_failure_detection

# ── 2. Symlink health check ─────────────────────────────────────────────────

test_symlink_health_broken() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"

    # Create CLAUDE.md as a regular file (NOT a symlink)
    echo "not a symlink" > "$mock_home/.claude/CLAUDE.md"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "CLAUDE.md is not symlinked" "should warn about missing symlink"
    assert_contains "$output" "sync.sh setup" "should suggest fix"
}
run_test "symlink health: warns when CLAUDE.md is not a symlink" test_symlink_health_broken

# ── 3. Config repo missing (.git absent) ────────────────────────────────────

test_config_repo_missing() {
    local config_repo="$TEST_TMPDIR/config-repo-nogit"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    # Create config repo dir but WITHOUT .git (just the dir + sync.sh)
    mkdir -p "$config_repo"
    touch "$config_repo/sync.sh"

    # symlink to avoid symlink warning dominating
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "Config repo not found" "should warn about missing .git"
    assert_contains "$output" "sync.sh setup" "should suggest fix"
}
run_test "config repo missing: warns when .git is absent" test_config_repo_missing

# ── 4. Auto-pull success ────────────────────────────────────────────────────

test_auto_pull_success() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local remote_repo="$TEST_TMPDIR/remote.git"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    # Create tracked repo with remote
    create_tracked_repo_main "$config_repo" "$remote_repo"

    # Add sync.sh so detection works
    (cd "$config_repo" && touch sync.sh && git add sync.sh && git commit -m "add sync.sh" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    # Add CLAUDE.md and set up symlink
    (cd "$config_repo" && touch CLAUDE.md && git add CLAUDE.md && git commit -m "add CLAUDE.md" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Push a change from another clone
    git clone "$remote_repo" "$TEST_TMPDIR/other" --quiet 2>/dev/null
    (cd "$TEST_TMPDIR/other" && git config user.email "test@test.com" && git config user.name "Test" && echo "new content" > foundation.md && git add foundation.md && git commit -m "update foundation" >/dev/null 2>&1 && git push --quiet 2>/dev/null)

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "Config updated from remote" "should report pulled changes"
    assert_contains "$output" "foundation.md" "should list changed files"
}
run_test "auto-pull: reports changed files on successful pull" test_auto_pull_success

# ── 5. Auto-pull failure (diverged) ─────────────────────────────────────────

test_auto_pull_diverged() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local remote_repo="$TEST_TMPDIR/remote.git"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_tracked_repo_main "$config_repo" "$remote_repo"

    (cd "$config_repo" && touch sync.sh && git add sync.sh && git commit -m "add sync.sh" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    # CLAUDE.md symlink
    (cd "$config_repo" && touch CLAUDE.md && git add CLAUDE.md && git commit -m "add CLAUDE.md" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create divergence: push from another clone, commit locally
    git clone "$remote_repo" "$TEST_TMPDIR/other" --quiet 2>/dev/null
    (cd "$TEST_TMPDIR/other" && git config user.email "test@test.com" && git config user.name "Test" && echo "remote" > remote.txt && git add remote.txt && git commit -m "remote diverge" >/dev/null 2>&1 && git push --quiet 2>/dev/null)
    (cd "$config_repo" && echo "local" > local.txt && git add local.txt && git commit -m "local diverge" >/dev/null 2>&1)

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "could not fast-forward" "should warn about divergence"
}
run_test "auto-pull failure: warns when branches have diverged" test_auto_pull_diverged

# ── 6. Unclean shutdown detection ────────────────────────────────────────────

test_unclean_shutdown_detection() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create session-context.md with a goal (simulates unrotated session)
    create_session_context "$project_dir" "Fix the deployment pipeline"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "Previous session may have ended unexpectedly" "should detect unclean shutdown"
    assert_contains "$output" "Fix the deployment pipeline" "should include the previous goal"
}
run_test "unclean shutdown: warns when session-context.md has a goal" test_unclean_shutdown_detection

# ── 7. Inbox task surfacing ──────────────────────────────────────────────────

test_inbox_task_surfacing() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/myproject"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create cross-project inbox with a task for our project
    mkdir -p "$config_repo/cross-project"
    cat > "$config_repo/cross-project/inbox.md" << 'EOF'
# Cross-Project Inbox

- [ ] **myproject**: Deploy new auth module after merge
- [ ] **otherproject**: Update API docs
EOF

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "INBOX TASKS for myproject" "should surface inbox tasks for current project"
    assert_contains "$output" "Deploy new auth module" "should include the task description"
    assert_contains "$output" "2 pending task" "should report total pending tasks"
}
run_test "inbox: surfaces tasks for current project" test_inbox_task_surfacing

test_inbox_no_tasks_for_project() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/unrelated"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create inbox with tasks for OTHER projects only
    mkdir -p "$config_repo/cross-project"
    cat > "$config_repo/cross-project/inbox.md" << 'EOF'
# Cross-Project Inbox

- [ ] **otherproject**: Update API docs
EOF

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_not_contains "$output" "INBOX TASKS for unrelated" "should NOT surface tasks for other projects"
    # But it should still mention the inbox has pending tasks
    assert_contains "$output" "1 pending task" "should mention total inbox count"
}
run_test "inbox: no project-specific tasks, but still reports total count" test_inbox_no_tasks_for_project

# ── 8. settings.json validation ──────────────────────────────────────────────

test_settings_json_missing_blocks() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create settings.json missing "hooks" and "enabledPlugins"
    mkdir -p "$mock_home/.cc-mirror/mclaude/config"
    cat > "$mock_home/.cc-mirror/mclaude/config/settings.json" << 'EOF'
{
  "permissions": {
    "allow": ["Read"]
  }
}
EOF

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "settings.json is missing critical blocks" "should warn about missing blocks"
    assert_contains "$output" "hooks" "should list missing hooks block"
    assert_contains "$output" "enabledPlugins" "should list missing enabledPlugins block"
}
run_test "settings.json: warns about missing critical blocks" test_settings_json_missing_blocks

test_settings_json_all_present() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create settings.json with all critical blocks
    mkdir -p "$mock_home/.cc-mirror/mclaude/config"
    cat > "$mock_home/.cc-mirror/mclaude/config/settings.json" << 'EOF'
{
  "permissions": { "allow": ["Read"] },
  "hooks": { "SessionStart": [] },
  "enabledPlugins": []
}
EOF

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_not_contains "$output" "settings.json is missing" "should NOT warn when all blocks present"
}
run_test "settings.json: no warning when all critical blocks present" test_settings_json_all_present

# ── 9. Serena config enforcement ─────────────────────────────────────────────

test_serena_config_fixes_dashboard() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create serena config with web_dashboard_open_on_launch: true
    mkdir -p "$mock_home/.serena"
    cat > "$mock_home/.serena/serena_config.yml" << 'EOF'
web_dashboard_open_on_launch: true
gui_log_window: true
some_other_setting: value
EOF

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    run_hook "$patched" >/dev/null

    # Verify the config was fixed
    assert_file_contains "$mock_home/.serena/serena_config.yml" "web_dashboard_open_on_launch: false" \
        "should fix web_dashboard_open_on_launch to false"
    assert_file_contains "$mock_home/.serena/serena_config.yml" "gui_log_window: false" \
        "should fix gui_log_window to false"
    assert_file_contains "$mock_home/.serena/serena_config.yml" "some_other_setting: value" \
        "should preserve other settings"
}
run_test "serena config: fixes web_dashboard_open_on_launch and gui_log_window" test_serena_config_fixes_dashboard

test_serena_config_already_correct() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create serena config already correct
    mkdir -p "$mock_home/.serena"
    cat > "$mock_home/.serena/serena_config.yml" << 'EOF'
web_dashboard_open_on_launch: false
gui_log_window: false
EOF

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    run_hook "$patched" >/dev/null

    assert_file_contains "$mock_home/.serena/serena_config.yml" "web_dashboard_open_on_launch: false" \
        "should remain false"
    assert_file_contains "$mock_home/.serena/serena_config.yml" "gui_log_window: false" \
        "should remain false"
}
run_test "serena config: no change when already correct" test_serena_config_already_correct

# ── 10. JSON output format ───────────────────────────────────────────────────

test_json_output_format() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"

    # Create a warning: CLAUDE.md not a symlink
    echo "regular file" > "$mock_home/.claude/CLAUDE.md"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    # Output should be valid JSON
    local json_valid=0
    echo "$output" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null || json_valid=1
    assert_eq "0" "$json_valid" "output should be valid JSON"

    # Should have systemMessage key
    local has_key
    has_key=$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print('yes' if 'systemMessage' in d else 'no')" 2>/dev/null)
    assert_eq "yes" "$has_key" "JSON should have systemMessage key"
}
run_test "JSON output: valid JSON with systemMessage key when warnings exist" test_json_output_format

test_json_output_contains_warning_text() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    echo "regular file" > "$mock_home/.claude/CLAUDE.md"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    # Extract the systemMessage value
    local msg
    msg=$(echo "$output" | python3 -c "import json,sys; print(json.load(sys.stdin)['systemMessage'])" 2>/dev/null)
    assert_contains "$msg" "WARNING:" "systemMessage should start with WARNING:"
    assert_contains "$msg" "CLAUDE.md" "systemMessage should contain the actual warning"
}
run_test "JSON output: systemMessage contains warning text" test_json_output_contains_warning_text

# ── 11. Clean state produces no output ───────────────────────────────────────

test_clean_state_no_output() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local remote_repo="$TEST_TMPDIR/remote.git"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    # Create a proper tracked repo so the git pull works
    create_tracked_repo_main "$config_repo" "$remote_repo"

    (cd "$config_repo" && touch sync.sh && git add sync.sh && git commit -m "add sync.sh" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    # Create CLAUDE.md as symlink
    (cd "$config_repo" && touch CLAUDE.md && git add CLAUDE.md && git commit -m "add CLAUDE.md" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # No .sync-failed, no session-context, no inbox, no settings.json, no serena config

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output rc=0
    # _FORCE_WSL=0 suppresses Check 29 (wsl.conf) which fires on real WSL machines
    output=$(_FORCE_WSL=0 run_hook "$patched") || rc=$?

    assert_eq "0" "$rc" "should exit 0"
    # git pull may output "Already up to date." — that's expected non-JSON noise.
    # The key assertion: no JSON warning output (no systemMessage).
    assert_not_contains "$output" "systemMessage" "should produce no JSON warnings when everything is clean"
    assert_not_contains "$output" "WARNING" "should produce no WARNING text when everything is clean"
}
run_test "clean state: no JSON warnings and exit 0" test_clean_state_no_output

# ── 12. Exit code is always 0 ────────────────────────────────────────────────

test_exit_code_always_zero() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    # Trigger multiple warnings
    echo "not a symlink" > "$mock_home/.claude/CLAUDE.md"
    cat > "$config_repo/.sync-failed" << 'EOF'
stage=deploy
time=2026-03-01
detail=error
EOF

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local rc=0
    run_hook "$patched" >/dev/null || rc=$?

    assert_eq "0" "$rc" "should always exit 0 even with multiple warnings"
}
run_test "exit code: always 0 even with warnings" test_exit_code_always_zero

# ── 13. Multiple warnings combined in single JSON ────────────────────────────

test_multiple_warnings_combined() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"

    # Trigger: sync failure + broken symlink
    cat > "$config_repo/.sync-failed" << 'EOF'
stage=collect
time=2026-03-01T09:00Z
detail=push failed
EOF
    echo "not a symlink" > "$mock_home/.claude/CLAUDE.md"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    # Should be single valid JSON
    local json_valid=0
    echo "$output" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null || json_valid=1
    assert_eq "0" "$json_valid" "combined output should be valid JSON"

    local msg
    msg=$(echo "$output" | python3 -c "import json,sys; print(json.load(sys.stdin)['systemMessage'])" 2>/dev/null)
    assert_contains "$msg" "CONFIG SYNC FAILED" "should contain sync failure warning"
    assert_contains "$msg" "CLAUDE.md is not symlinked" "should contain symlink warning"
}
run_test "multiple warnings: combined into single JSON systemMessage" test_multiple_warnings_combined

# ── 14. Empty session-context.md does NOT trigger warning ─────────────────────

test_empty_session_context_no_warning() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local remote_repo="$TEST_TMPDIR/remote.git"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_tracked_repo_main "$config_repo" "$remote_repo"
    (cd "$config_repo" && touch sync.sh && git add sync.sh && git commit -m "add sync.sh" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    (cd "$config_repo" && touch CLAUDE.md && git add CLAUDE.md && git commit -m "add CLAUDE.md" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create session-context.md with empty goal line
    cat > "$project_dir/session-context.md" << 'EOF'
# Session Context

## Session Info
- **Session Goal**:

## Current State
EOF

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_not_contains "$output" "Previous session may have ended unexpectedly" \
        "should not warn on empty session goal"
}
run_test "empty session goal: no unclean shutdown warning" test_empty_session_context_no_warning

# ── 15. Inbox with no pending tasks produces no inbox message ─────────────────

test_inbox_all_done() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local remote_repo="$TEST_TMPDIR/remote.git"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_tracked_repo_main "$config_repo" "$remote_repo"
    (cd "$config_repo" && touch sync.sh && git add sync.sh && git commit -m "add sync.sh" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    (cd "$config_repo" && touch CLAUDE.md && git add CLAUDE.md && git commit -m "add CLAUDE.md" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create inbox with only completed tasks
    mkdir -p "$config_repo/cross-project"
    cat > "$config_repo/cross-project/inbox.md" << 'EOF'
# Cross-Project Inbox

- [x] **project**: Already done task
EOF

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    # _FORCE_WSL=0 suppresses Check 29 (wsl.conf) which fires on real WSL machines
    output=$(_FORCE_WSL=0 run_hook "$patched")

    # git pull may output "Already up to date." — that's expected non-JSON noise.
    assert_not_contains "$output" "systemMessage" "should produce no JSON warnings when inbox is done"
    assert_not_contains "$output" "WARNING" "should produce no WARNING when inbox is done"
}
run_test "inbox: no warnings when all tasks are completed" test_inbox_all_done

# ── 16. Settings.json not present produces no warning ─────────────────────────

test_no_settings_json() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local remote_repo="$TEST_TMPDIR/remote.git"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_tracked_repo_main "$config_repo" "$remote_repo"
    (cd "$config_repo" && touch sync.sh && git add sync.sh && git commit -m "add sync.sh" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    (cd "$config_repo" && touch CLAUDE.md && git add CLAUDE.md && git commit -m "add CLAUDE.md" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # No settings.json file created at all

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_not_contains "$output" "settings.json" "should not warn when settings.json doesn't exist"
}
run_test "settings.json: no warning when file does not exist" test_no_settings_json

# ── 17. Check 10: Auto-remove permissions from project settings.local.json ────

test_permissions_block_removed() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create a project with settings.local.json containing a permissions block
    mkdir -p "$mock_home/myproject/.claude"
    cat > "$mock_home/myproject/.claude/settings.local.json" << 'EOF'
{
  "permissions": {
    "allow": [
      "Bash(foo:*)"
    ]
  },
  "enableAllProjectMcpServers": true
}
EOF

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    run_hook "$patched" >/dev/null

    # Verify permissions key was removed
    assert_file_not_contains "$mock_home/myproject/.claude/settings.local.json" '"permissions"' \
        "should remove permissions key from settings.local.json"

    # Verify other keys are preserved
    assert_file_contains "$mock_home/myproject/.claude/settings.local.json" '"enableAllProjectMcpServers"' \
        "should preserve enableAllProjectMcpServers key"
    assert_file_contains "$mock_home/myproject/.claude/settings.local.json" 'true' \
        "should preserve enableAllProjectMcpServers value"
}
run_test "check 10: settings.local.json with permissions block gets cleaned" test_permissions_block_removed

test_permissions_block_absent_untouched() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create a project with settings.local.json WITHOUT permissions
    mkdir -p "$mock_home/cleanproject/.claude"
    cat > "$mock_home/cleanproject/.claude/settings.local.json" << 'EOF'
{
  "enableAllProjectMcpServers": true,
  "mcpServers": {
    "serena": {
      "command": "serena"
    }
  }
}
EOF

    # Save original content for comparison
    local original
    original=$(cat "$mock_home/cleanproject/.claude/settings.local.json")

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    run_hook "$patched" >/dev/null

    # Verify file is unchanged
    local after
    after=$(cat "$mock_home/cleanproject/.claude/settings.local.json")
    assert_eq "$original" "$after" "settings.local.json without permissions should be untouched"
}
run_test "check 10: settings.local.json without permissions block is untouched" test_permissions_block_absent_untouched

test_permissions_removal_silent_on_success() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create a project with permissions block
    mkdir -p "$mock_home/warnproject/.claude"
    cat > "$mock_home/warnproject/.claude/settings.local.json" << 'EOF'
{
  "permissions": {
    "allow": [
      "Bash(foo:*)"
    ]
  },
  "enableAllProjectMcpServers": true
}
EOF

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    # Cleanup should have happened (permissions removed)
    assert_file_not_contains "$mock_home/warnproject/.claude/settings.local.json" '"permissions"' \
        "should remove permissions block"

    # But NO warning should be generated — successful cleanup is silent
    assert_not_contains "$output" "Auto-removed stale permissions" \
        "should NOT warn when cleanup succeeds silently"
    assert_not_contains "$output" "permissions override" \
        "should NOT mention permissions override"
}
run_test "check 10: successful permissions cleanup produces no warning" test_permissions_removal_silent_on_success

test_permissions_multiple_projects_cleaned() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create two projects with permissions blocks
    mkdir -p "$mock_home/projA/.claude"
    cat > "$mock_home/projA/.claude/settings.local.json" << 'EOF'
{
  "permissions": {
    "allow": [
      "Bash(bar:*)"
    ]
  },
  "enableAllProjectMcpServers": true
}
EOF

    mkdir -p "$mock_home/projB/.claude"
    cat > "$mock_home/projB/.claude/settings.local.json" << 'EOF'
{
  "permissions": {
    "allow": [
      "Read(*)"
    ]
  },
  "mcpServers": {
    "test": {
      "command": "test"
    }
  }
}
EOF

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    # Both should have permissions removed
    assert_file_not_contains "$mock_home/projA/.claude/settings.local.json" '"permissions"' \
        "should remove permissions from projA"
    assert_file_not_contains "$mock_home/projB/.claude/settings.local.json" '"permissions"' \
        "should remove permissions from projB"

    # Both should preserve their other keys
    assert_file_contains "$mock_home/projA/.claude/settings.local.json" '"enableAllProjectMcpServers"' \
        "should preserve enableAllProjectMcpServers in projA"
    assert_file_contains "$mock_home/projB/.claude/settings.local.json" '"mcpServers"' \
        "should preserve mcpServers in projB"

    # Successful cleanup should be silent — no warning for either project
    assert_not_contains "$output" "Auto-removed stale permissions" \
        "should NOT warn when cleanup succeeds silently"
    assert_not_contains "$output" "projA" \
        "should NOT mention projA in output"
    assert_not_contains "$output" "projB" \
        "should NOT mention projB in output"
}
run_test "check 10: multiple projects with permissions blocks both get cleaned" test_permissions_multiple_projects_cleaned

# ── 18. CLAUDE.local.md @import target validation ─────────────────────────────

test_claude_local_broken_import() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create CLAUDE.local.md with @import pointing to nonexistent file
    echo '@~/.claude/machines/NonExistent.md' > "$mock_home/CLAUDE.local.md"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    local msg
    msg=$(echo "$output" | python3 -c "import json,sys; print(json.load(sys.stdin)['systemMessage'])" 2>/dev/null)
    assert_contains "$msg" "CLAUDE.local.md" "should mention CLAUDE.local.md"
    assert_contains "$msg" "NonExistent.md" "should mention the missing target file"
}
run_test "CLAUDE.local.md: warns when @import target does not exist" test_claude_local_broken_import

test_claude_local_valid_import() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local remote_repo="$TEST_TMPDIR/remote.git"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude/machines" "$project_dir"

    create_tracked_repo_main "$config_repo" "$remote_repo"
    (cd "$config_repo" && touch sync.sh && git add sync.sh && git commit -m "add sync.sh" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    (cd "$config_repo" && touch CLAUDE.md && git add CLAUDE.md && git commit -m "add CLAUDE.md" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create valid machine file and CLAUDE.local.md pointing to it
    echo "# Steam Deck" > "$mock_home/.claude/machines/steamdeck.md"
    echo '@~/.claude/machines/steamdeck.md' > "$mock_home/CLAUDE.local.md"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_not_contains "$output" "CLAUDE.local.md" "should NOT warn when @import target exists"
}
run_test "CLAUDE.local.md: no warning when @import target exists" test_claude_local_valid_import

test_claude_local_missing_file() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local remote_repo="$TEST_TMPDIR/remote.git"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_tracked_repo_main "$config_repo" "$remote_repo"
    (cd "$config_repo" && touch sync.sh && git add sync.sh && git commit -m "add sync.sh" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    (cd "$config_repo" && touch CLAUDE.md && git add CLAUDE.md && git commit -m "add CLAUDE.md" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # No CLAUDE.local.md at all — should not warn (it's optional)

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_not_contains "$output" "CLAUDE.local.md" "should NOT warn when CLAUDE.local.md doesn't exist"
}
run_test "CLAUDE.local.md: no warning when file does not exist (optional)" test_claude_local_missing_file

# ── 19. Propagation drift warning surfacing (Check 13) ────────────────────────

test_propagation_drift_warning_surfaced() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create .sync-warnings.log with drift warnings (as SessionEnd hook would)
    cat > "$config_repo/.sync-warnings.log" << 'EOF'
sync.sh drifted (was: 51363f86, now: abcd1234)
Template: 1 file(s) drifted
EOF

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    local msg
    msg=$(echo "$output" | python3 -c "import json,sys; print(json.load(sys.stdin)['systemMessage'])" 2>/dev/null)
    assert_contains "$msg" "Propagation drift" "should surface drift warning"
    assert_contains "$msg" "drifted" "should include drift details"

    # Log file should be cleaned up after reading
    assert_file_not_exists "$config_repo/.sync-warnings.log" \
        "should remove .sync-warnings.log after surfacing"
}
run_test "check 13: surfaces propagation drift from .sync-warnings.log" test_propagation_drift_warning_surfaced

test_no_warning_without_drift_log() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local remote_repo="$TEST_TMPDIR/remote.git"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_tracked_repo_main "$config_repo" "$remote_repo"
    (cd "$config_repo" && touch sync.sh && git add sync.sh && git commit -m "add sync.sh" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    (cd "$config_repo" && touch CLAUDE.md && git add CLAUDE.md && git commit -m "add CLAUDE.md" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # No .sync-warnings.log file

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_not_contains "$output" "Propagation drift" "should NOT mention drift when no log exists"
    assert_not_contains "$output" "sync-warnings" "should NOT reference warning log file"
}
run_test "check 13: no warning when .sync-warnings.log absent" test_no_warning_without_drift_log

# ── 20. Symlink target validation ──────────────────────────────────────────────

test_symlink_wrong_target() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local stale_repo="$TEST_TMPDIR/stale-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    mkdir -p "$config_repo/global"
    touch "$config_repo/global/CLAUDE.md"

    # Create a stale repo with its own CLAUDE.md
    mkdir -p "$stale_repo/global"
    echo "stale content" > "$stale_repo/global/CLAUDE.md"

    # Symlink points to the STALE repo, not the active config repo
    ln -sf "$stale_repo/global/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "symlink points to wrong" "should warn when symlink target doesn't match config repo"
    assert_contains "$output" "sync.sh setup" "should suggest running sync.sh setup to fix"
}
skip_test "symlink target: warns when CLAUDE.md symlink points to wrong directory" "feature not yet implemented"

test_symlink_correct_target() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local remote_repo="$TEST_TMPDIR/remote.git"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_tracked_repo_main "$config_repo" "$remote_repo"
    (cd "$config_repo" && touch sync.sh && git add sync.sh && git commit -m "add sync.sh" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    mkdir -p "$config_repo/global"
    (cd "$config_repo" && mkdir -p global && touch global/CLAUDE.md && git add global/CLAUDE.md && git commit -m "add CLAUDE.md" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    # Symlink points to the CORRECT config repo
    ln -sf "$config_repo/global/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_not_contains "$output" "symlink points to wrong" "should NOT warn when symlink is correct"
    assert_not_contains "$output" "not a symlink" "should not warn about symlink when it IS a symlink"
}
run_test "symlink target: no warning when CLAUDE.md symlink points to correct directory" test_symlink_correct_target

# ── 21. Daily dependency check (once-per-day gate) ─────────────────────────────

test_dep_check_runs_when_no_marker() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local remote_repo="$TEST_TMPDIR/remote.git"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_tracked_repo_main "$config_repo" "$remote_repo"
    (cd "$config_repo" && touch sync.sh && git add sync.sh && git commit -m "add sync.sh" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    mkdir -p "$config_repo/global"
    (cd "$config_repo" && mkdir -p global && touch global/CLAUDE.md && git add global/CLAUDE.md && git commit -m "add" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    ln -sf "$config_repo/global/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # No marker file exists — check should run
    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    # Marker file should be created with today's date
    assert_file_exists "$mock_home/.claude/.dep-check-date" "should create dep-check-date marker"
    local marker_date
    marker_date=$(cat "$mock_home/.claude/.dep-check-date" 2>/dev/null)
    assert_eq "$(date +%Y-%m-%d)" "$marker_date" "marker should contain today's date"
}
skip_test "dep check: runs and creates marker when no marker exists" "feature not yet implemented"

test_dep_check_skips_when_already_ran_today() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local remote_repo="$TEST_TMPDIR/remote.git"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_tracked_repo_main "$config_repo" "$remote_repo"
    (cd "$config_repo" && touch sync.sh && git add sync.sh && git commit -m "add sync.sh" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    mkdir -p "$config_repo/global"
    (cd "$config_repo" && mkdir -p global && touch global/CLAUDE.md && git add global/CLAUDE.md && git commit -m "add" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    ln -sf "$config_repo/global/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Marker already has today's date — check should NOT run
    mkdir -p "$mock_home/.claude"
    date +%Y-%m-%d > "$mock_home/.claude/.dep-check-date"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_not_contains "$output" "Upstream dependency check" "should NOT run dep check when already done today"
}
run_test "dep check: skips when marker has today's date" test_dep_check_skips_when_already_ran_today

test_dep_check_runs_when_marker_is_yesterday() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local remote_repo="$TEST_TMPDIR/remote.git"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_tracked_repo_main "$config_repo" "$remote_repo"
    (cd "$config_repo" && touch sync.sh && git add sync.sh && git commit -m "add sync.sh" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    mkdir -p "$config_repo/global"
    (cd "$config_repo" && mkdir -p global && touch global/CLAUDE.md && git add global/CLAUDE.md && git commit -m "add" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    ln -sf "$config_repo/global/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Marker has yesterday's date — check should run
    mkdir -p "$mock_home/.claude"
    echo "2026-03-02" > "$mock_home/.claude/.dep-check-date"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    # Marker should be updated to today
    local marker_date
    marker_date=$(cat "$mock_home/.claude/.dep-check-date" 2>/dev/null)
    assert_eq "$(date +%Y-%m-%d)" "$marker_date" "marker should be updated to today's date"
}
skip_test "dep check: runs when marker has yesterday's date" "feature not yet implemented"

# ── 22. Check 14: Bash(bash:*) auto-heal in settings.json ────────────────────

test_bash_permission_auto_added() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create settings.json WITHOUT Bash(bash:*)
    mkdir -p "$mock_home/.claude"
    cat > "$mock_home/.claude/settings.json" << 'EOF'
{
  "permissions": {
    "allow": [
      "Read(*)",
      "Bash(git:*)",
      "Bash(npm:*)"
    ]
  },
  "hooks": {}
}
EOF

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    run_hook "$patched" >/dev/null

    # Verify Bash(bash:*) was added
    assert_file_contains "$mock_home/.claude/settings.json" 'Bash(bash:*)' \
        "should auto-add Bash(bash:*) to permissions.allow"

    # Verify existing permissions preserved
    assert_file_contains "$mock_home/.claude/settings.json" 'Read(*)' \
        "should preserve existing Read(*) permission"
    assert_file_contains "$mock_home/.claude/settings.json" 'Bash(git:*)' \
        "should preserve existing Bash(git:*) permission"

    # Verify valid JSON
    local json_valid=0
    python3 -c "import json; json.load(open('$mock_home/.claude/settings.json'))" 2>/dev/null || json_valid=1
    assert_eq "0" "$json_valid" "settings.json should remain valid JSON after auto-add"
}
run_test "check 14: auto-adds Bash(bash:*) when missing from settings.json" test_bash_permission_auto_added

test_bash_permission_already_present() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create settings.json WITH Bash(bash:*) already
    mkdir -p "$mock_home/.claude"
    cat > "$mock_home/.claude/settings.json" << 'EOF'
{
  "permissions": {
    "allow": [
      "Read(*)",
      "Bash(bash:*)",
      "Bash(git:*)"
    ]
  },
  "hooks": {}
}
EOF

    local original
    original=$(cat "$mock_home/.claude/settings.json")

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    run_hook "$patched" >/dev/null

    local after
    after=$(cat "$mock_home/.claude/settings.json")
    assert_eq "$original" "$after" "settings.json should be unchanged when Bash(bash:*) already present"
}
run_test "check 14: no change when Bash(bash:*) already present" test_bash_permission_already_present

test_bash_permission_no_permissions_block() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create settings.json without permissions block at all
    mkdir -p "$mock_home/.claude"
    cat > "$mock_home/.claude/settings.json" << 'EOF'
{
  "hooks": {},
  "statusLine": {}
}
EOF

    local original
    original=$(cat "$mock_home/.claude/settings.json")

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    run_hook "$patched" >/dev/null

    # Should warn about missing permissions block (Check 8 handles this),
    # but should NOT crash trying to add Bash(bash:*)
    local after
    after=$(cat "$mock_home/.claude/settings.json")
    assert_eq "$original" "$after" "settings.json should be unchanged when no permissions block exists"
}
run_test "check 14: no crash when settings.json has no permissions block" test_bash_permission_no_permissions_block

# ── 23. Check 15: tmp/ document scanner ──────────────────────────────────────

test_tmp_document_scanner_detects_files() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create project with documents in tmp/
    mkdir -p "$mock_home/myproject/tmp"
    echo "# Draft" > "$mock_home/myproject/tmp/draft-letter.md"
    echo "PDF content" > "$mock_home/myproject/tmp/report.pdf"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "Documents found in project tmp/" "should warn about documents in tmp/"
}
run_test "check 15: warns when documents found in project tmp/ dirs" test_tmp_document_scanner_detects_files

test_tmp_document_scanner_ignores_non_docs() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local remote_repo="$TEST_TMPDIR/remote.git"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_tracked_repo_main "$config_repo" "$remote_repo"
    (cd "$config_repo" && touch sync.sh && git add sync.sh && git commit -m "add sync.sh" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    (cd "$config_repo" && touch CLAUDE.md && git add CLAUDE.md && git commit -m "add CLAUDE.md" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create project with only non-document files in tmp/
    mkdir -p "$mock_home/myproject/tmp"
    echo "data" > "$mock_home/myproject/tmp/cache.json"
    echo "log" > "$mock_home/myproject/tmp/output.log"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_not_contains "$output" "Documents found in project tmp/" "should NOT warn for non-document files"
}
run_test "check 15: ignores non-document files in tmp/" test_tmp_document_scanner_ignores_non_docs

# ── 24. Check 17: Stale pending files ───────────────────────────────────────

test_stale_pending_files_warning() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Check 17 scans CONFIG_REPO/docs/ for pending files
    mkdir -p "$config_repo/docs"
    echo "old task" > "$config_repo/docs/pending-old-task.md"
    touch -d "3 days ago" "$config_repo/docs/pending-old-task.md"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "Stale pending files" "should warn about stale pending files"
    assert_contains "$output" "pending-old-task.md" "should name the stale file"
}
run_test "check 17: warns about pending files older than 2 days" test_stale_pending_files_warning

test_fresh_pending_files_no_warning() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local remote_repo="$TEST_TMPDIR/remote.git"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_tracked_repo_main "$config_repo" "$remote_repo"
    (cd "$config_repo" && touch sync.sh && git add sync.sh && git commit -m "add sync.sh" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    (cd "$config_repo" && touch CLAUDE.md && git add CLAUDE.md && git commit -m "add CLAUDE.md" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create fresh pending file (today)
    mkdir -p "$config_repo/docs"
    echo "fresh task" > "$config_repo/docs/pending-fresh-task.md"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_not_contains "$output" "Stale pending files" "should NOT warn about fresh pending files"
}
run_test "check 17: no warning for pending files less than 2 days old" test_fresh_pending_files_no_warning

test_stale_pending_with_backlog_item() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Check 17 scans CONFIG_REPO/docs/ for pending files and CONFIG_REPO/backlog.md
    mkdir -p "$config_repo/docs"
    echo "old task" > "$config_repo/docs/pending-old-task.md"
    touch -d "3 days ago" "$config_repo/docs/pending-old-task.md"
    cat > "$config_repo/backlog.md" << 'EOF'
# Backlog
- [ ] [P1] `CFG-99` **Old task**: References pending-old-task.md
EOF

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "Stale pending files" "should still warn about staleness"
    assert_not_contains "$output" "no backlog item" "should NOT say 'no backlog item' when backlog references the file"
}
run_test "check 17: stale pending file with matching backlog item — no 'no backlog' warning" test_stale_pending_with_backlog_item

test_stale_pending_without_backlog_item() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Check 17 scans CONFIG_REPO/docs/ for pending files and CONFIG_REPO/backlog.md
    mkdir -p "$config_repo/docs"
    echo "orphaned task" > "$config_repo/docs/pending-orphan.md"
    touch -d "3 days ago" "$config_repo/docs/pending-orphan.md"
    cat > "$config_repo/backlog.md" << 'EOF'
# Backlog
- [ ] [P1] `CFG-01` **Something unrelated**: nothing here
EOF

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "Stale pending files" "should warn about staleness"
    assert_contains "$output" "pending-orphan.md" "should name the orphaned file"
    # This must be LAST — it's the feature we're testing (backlog cross-check)
    assert_contains "$output" "no backlog item" "should flag missing backlog item"
}
run_test "check 17: stale pending file without backlog item — warns about missing tracking" test_stale_pending_without_backlog_item

# ── 25. Check 19: Auto-disable global enabledPlugins ────────────────────────

test_plugins_auto_disabled() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create settings.json with non-empty enabledPlugins
    mkdir -p "$mock_home/.claude"
    cat > "$mock_home/.claude/settings.json" << 'EOF'
{
  "permissions": {
    "allow": ["Read(*)", "Bash(bash:*)"]
  },
  "hooks": {},
  "enabledPlugins": {
    "voltagent-lang@voltagent-subagents": true,
    "voltagent-infra@voltagent-subagents": true,
    "code-review@claude-plugins-official": true
  }
}
EOF

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    # Verify plugins were disabled (enabledPlugins should be empty object)
    local plugins_count
    plugins_count=$(python3 -c "import json; d=json.load(open('$mock_home/.claude/settings.json')); print(len(d.get('enabledPlugins',{})))" 2>/dev/null)
    assert_eq "0" "$plugins_count" "enabledPlugins should be empty after auto-disable"

    # Verify warning was emitted
    assert_contains "$output" "enabledPlugins" "should warn about disabled plugins"

    # Verify valid JSON
    local json_valid=0
    python3 -c "import json; json.load(open('$mock_home/.claude/settings.json'))" 2>/dev/null || json_valid=1
    assert_eq "0" "$json_valid" "settings.json should remain valid JSON after plugin disable"

    # Verify other settings preserved
    assert_file_contains "$mock_home/.claude/settings.json" '"hooks"' \
        "should preserve hooks block"
    assert_file_contains "$mock_home/.claude/settings.json" '"allow"' \
        "should preserve permissions"
}
run_test "check 19: auto-disables non-empty global enabledPlugins" test_plugins_auto_disabled

test_plugins_already_empty() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create settings.json with empty enabledPlugins
    mkdir -p "$mock_home/.claude"
    cat > "$mock_home/.claude/settings.json" << 'EOF'
{
  "permissions": {
    "allow": ["Read(*)", "Bash(bash:*)"]
  },
  "hooks": {},
  "enabledPlugins": {}
}
EOF

    local original
    original=$(cat "$mock_home/.claude/settings.json")

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    local after
    after=$(cat "$mock_home/.claude/settings.json")
    assert_eq "$original" "$after" "settings.json should be unchanged when enabledPlugins is empty"
    assert_not_contains "$output" "enabledPlugins" "should NOT warn when plugins already empty"
}
run_test "check 19: no change when enabledPlugins is already empty" test_plugins_already_empty

test_plugins_no_key() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create settings.json without enabledPlugins key at all
    mkdir -p "$mock_home/.claude"
    cat > "$mock_home/.claude/settings.json" << 'EOF'
{
  "permissions": {
    "allow": ["Read(*)", "Bash(bash:*)"]
  },
  "hooks": {}
}
EOF

    local original
    original=$(cat "$mock_home/.claude/settings.json")

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    run_hook "$patched" >/dev/null

    local after
    after=$(cat "$mock_home/.claude/settings.json")
    assert_eq "$original" "$after" "settings.json should be unchanged when enabledPlugins key is missing"
}
run_test "check 19: no crash when enabledPlugins key is absent" test_plugins_no_key

# ── 26. afleet dashboard marker ─────────────────────────────────────────────

test_afleet_dash_marker_injects_message() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create the dashboard marker
    touch "$mock_home/.claude/.afleet-show-dash"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "AFLEET_DASHBOARD" "should inject dashboard message"
    assert_file_not_exists "$mock_home/.claude/.afleet-show-dash" "should delete marker after reading"
}
run_test "check 18: afleet dashboard marker injects message and deletes marker" test_afleet_dash_marker_injects_message

test_afleet_dash_no_marker_no_message() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # No marker file

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched" || true)

    assert_not_contains "$output" "AFLEET_DASHBOARD" "should not inject dashboard message when no marker"
}
run_test "check 18: no dashboard marker — no dashboard message" test_afleet_dash_no_marker_no_message

# ── 27. Persona injection (B) ────────────────────────────────────────────────

test_persona_injection_reads_active_persona() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Write active persona file
    echo "Supporter" > "$mock_home/.claude/.active-persona"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "PERSONA: Supporter" "should inject persona name from .active-persona"
}
run_test "check 20: persona injection reads .active-persona" test_persona_injection_reads_active_persona

test_persona_injection_default_bartl() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # No .active-persona file

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "PERSONA: Assistant" "should default to Assistant when no .active-persona exists"
}
run_test "check 20: persona defaults to Assistant when file missing" test_persona_injection_default_bartl

test_persona_injection_trims_whitespace() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Persona file with trailing newline and spaces
    printf "  Elsa  \n\n" > "$mock_home/.claude/.active-persona"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "PERSONA: Supporter" "should trim whitespace from persona name"
    assert_not_contains "$output" "PERSONA:   Elsa" "should not have leading spaces in persona name"
}
run_test "check 20: persona trims whitespace" test_persona_injection_trims_whitespace

# ── 28. Session-context blank detection (E) ─────────────────────────────────

test_session_context_blank_detection() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create a blank session-context.md (template — no goal)
    cat > "$project_dir/session-context.md" << 'EOF'
# Session Context

## Session Info
- **Last Updated**:
- **Machine**:
- **Working Directory**:
- **Session Goal**:

## Current State
- **Active Task**:
EOF

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "SESSION_CONTEXT: blank" "should detect blank session context"
}
run_test "check 21: detects blank session-context.md" test_session_context_blank_detection

test_session_context_active_detection() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create session-context with a goal
    create_session_context "$project_dir" "Implement hook expansion" "wsl"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "SESSION_CONTEXT: active" "should detect active session context"
    assert_contains "$output" "Implement hook expansion" "should include goal text"
}
run_test "check 21: detects active session-context.md with goal" test_session_context_active_detection

test_session_context_missing_file() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # No session-context.md at all

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "SESSION_CONTEXT: blank" "should report blank when file is missing"
}
run_test "check 21: missing session-context.md reports blank" test_session_context_missing_file

test_session_context_goal_truncated() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create session-context with a very long goal (>150 chars)
    local long_goal
    long_goal=$(printf 'A%.0s' {1..200})
    create_session_context "$project_dir" "$long_goal" "wsl"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "SESSION_CONTEXT: active" "should detect active context"
    # Extract just the SESSION_CONTEXT field value and verify truncation
    local sc_field
    sc_field=$(echo "$output" | grep -o 'SESSION_CONTEXT: active [^|]*' | head -1)
    local truncated_goal
    truncated_goal=$(printf 'A%.0s' {1..150})
    # The SC field should contain 150 A's but not 200
    assert_contains "$sc_field" "$truncated_goal" "should have 150 chars of goal"
    assert_not_contains "$sc_field" "$long_goal" "SESSION_CONTEXT should truncate long goals"
}
run_test "check 21: long session goal is truncated" test_session_context_goal_truncated

# ── 29. Handoff detection (C) ───────────────────────────────────────────────

test_handoff_detection_with_task() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create next-session-task.md with a handoff
    cat > "$project_dir/next-session-task.md" << 'EOF'
task: true
file: docs/pending-hook-expansion.md
description: Implement hook items B through F with TDD.
EOF

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "HANDOFF:" "should inject HANDOFF tag"
    assert_contains "$output" "Implement hook items" "should include description"
    assert_contains "$output" "docs/pending-hook-expansion.md" "should include file path"
}
run_test "check 22: handoff detection with task: true" test_handoff_detection_with_task

test_handoff_detection_no_task() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create next-session-task.md with task: false
    cat > "$project_dir/next-session-task.md" << 'EOF'
task: false
file:
description:
EOF

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "HANDOFF: none" "should report no handoff when task is false"
}
run_test "check 22: handoff detection with task: false" test_handoff_detection_no_task

test_handoff_detection_missing_file() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # No next-session-task.md

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "HANDOFF: none" "should report no handoff when file is missing"
}
run_test "check 22: handoff detection with missing file" test_handoff_detection_missing_file

test_handoff_description_truncated() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create next-session-task.md with very long description
    local long_desc
    long_desc=$(printf 'B%.0s' {1..300})
    cat > "$project_dir/next-session-task.md" << EOF
task: true
file: docs/pending-something.md
description: $long_desc
EOF

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "HANDOFF:" "should inject HANDOFF"
    assert_not_contains "$output" "$long_desc" "should truncate long descriptions"
}
run_test "check 22: handoff description is truncated at 200 chars" test_handoff_description_truncated

# ── 30. Pending files list (D) ──────────────────────────────────────────────

test_pending_files_list_found() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir/docs"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create pending files in project dir
    echo "stuff" > "$project_dir/docs/pending-alpha.md"
    echo "stuff" > "$project_dir/docs/pending-beta.md"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "PENDING_FILES:" "should inject PENDING_FILES"
    assert_contains "$output" "pending-alpha.md" "should list pending-alpha.md"
    assert_contains "$output" "pending-beta.md" "should list pending-beta.md"
}
run_test "check 23: pending files listed when present" test_pending_files_list_found

test_pending_files_list_none() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir/docs"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # No pending files

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "PENDING_FILES: none" "should report none when no pending files"
}
run_test "check 23: pending files reports none when empty" test_pending_files_list_none

test_pending_files_no_docs_dir() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # No docs/ directory at all

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "PENDING_FILES: none" "should report none when no docs dir"
}
run_test "check 23: pending files reports none when no docs/ dir" test_pending_files_no_docs_dir

# ── 31. Knowledge file list (F) ─────────────────────────────────────────────

test_knowledge_files_found() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir/.claude/knowledge"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create knowledge files
    echo "stuff" > "$project_dir/.claude/knowledge/api-guide.md"
    echo "stuff" > "$project_dir/.claude/knowledge/deploy.md"
    echo "stuff" > "$project_dir/.claude/rules.md"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "PROJECT_KNOWLEDGE:" "should inject PROJECT_KNOWLEDGE"
    assert_contains "$output" "api-guide.md" "should list knowledge file"
    assert_contains "$output" "deploy.md" "should list knowledge file"
    assert_contains "$output" "rules.md" "should list .claude/*.md file"
}
run_test "check 24: knowledge files listed when present" test_knowledge_files_found

test_knowledge_files_none() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # No .claude/ in project at all

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "PROJECT_KNOWLEDGE: none" "should report none when no knowledge files"
}
run_test "check 24: knowledge files reports none when empty" test_knowledge_files_none

test_knowledge_files_excludes_settings() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir/.claude"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create settings files that should be excluded
    echo "{}" > "$project_dir/.claude/settings.json"
    echo "{}" > "$project_dir/.claude/settings.local.json"
    # And one actual md file
    echo "stuff" > "$project_dir/.claude/custom-rules.md"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "PROJECT_KNOWLEDGE:" "should inject PROJECT_KNOWLEDGE"
    assert_contains "$output" "custom-rules.md" "should list md files"
    assert_not_contains "$output" "settings.json" "should exclude settings.json"
    assert_not_contains "$output" "settings.local.json" "should exclude settings.local.json"
}
run_test "check 24: knowledge files excludes settings*.json" test_knowledge_files_excludes_settings

# ── 28. TweakCC stale patch detection ────────────────────────────────────────

test_tweakcc_stale_patches_warns() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Set up TweakCC config with OLD version and changesApplied: false
    mkdir -p "$mock_home/.cc-mirror/mclaude/tweakcc"
    cat > "$mock_home/.cc-mirror/mclaude/tweakcc/config.json" << 'EOF'
{
  "ccVersion": "2.1.50",
  "changesApplied": false,
  "settings": {}
}
EOF

    # Set up installed CC with NEWER version
    mkdir -p "$mock_home/.cc-mirror/mclaude/npm/node_modules/@anthropic-ai/claude-code"
    cat > "$mock_home/.cc-mirror/mclaude/npm/node_modules/@anthropic-ai/claude-code/package.json" << 'EOF'
{
  "name": "@anthropic-ai/claude-code",
  "version": "2.1.62"
}
EOF

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "TweakCC patches stale" "should warn about stale TweakCC patches"
    assert_contains "$output" "cc-mirror tweak mclaude" "should include remediation command"
}
run_test "check 28: TweakCC stale patches warns when version mismatch + changesApplied false" test_tweakcc_stale_patches_warns

test_tweakcc_current_no_warning() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # TweakCC config matches installed version AND changesApplied: true
    mkdir -p "$mock_home/.cc-mirror/mclaude/tweakcc"
    cat > "$mock_home/.cc-mirror/mclaude/tweakcc/config.json" << 'EOF'
{
  "ccVersion": "2.1.62",
  "changesApplied": true,
  "settings": {}
}
EOF

    mkdir -p "$mock_home/.cc-mirror/mclaude/npm/node_modules/@anthropic-ai/claude-code"
    cat > "$mock_home/.cc-mirror/mclaude/npm/node_modules/@anthropic-ai/claude-code/package.json" << 'EOF'
{
  "name": "@anthropic-ai/claude-code",
  "version": "2.1.62"
}
EOF

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_not_contains "$output" "TweakCC patches stale" "should NOT warn when versions match"
}
run_test "check 28: no TweakCC warning when versions match and patches applied" test_tweakcc_current_no_warning

test_tweakcc_version_mismatch_but_applied_no_warning() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Version mismatch BUT changesApplied: true (patches still active)
    mkdir -p "$mock_home/.cc-mirror/mclaude/tweakcc"
    cat > "$mock_home/.cc-mirror/mclaude/tweakcc/config.json" << 'EOF'
{
  "ccVersion": "2.1.50",
  "changesApplied": true,
  "settings": {}
}
EOF

    mkdir -p "$mock_home/.cc-mirror/mclaude/npm/node_modules/@anthropic-ai/claude-code"
    cat > "$mock_home/.cc-mirror/mclaude/npm/node_modules/@anthropic-ai/claude-code/package.json" << 'EOF'
{
  "name": "@anthropic-ai/claude-code",
  "version": "2.1.62"
}
EOF

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_not_contains "$output" "TweakCC patches stale" "should NOT warn when changesApplied is true even with version mismatch"
}
run_test "check 28: no TweakCC warning when version mismatch but changesApplied true" test_tweakcc_version_mismatch_but_applied_no_warning

test_tweakcc_not_installed_silent() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # No TweakCC config at all — not installed
    # (don't create .cc-mirror/mclaude/tweakcc/)

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_not_contains "$output" "TweakCC" "should be silent when TweakCC is not installed"
}
run_test "check 28: silent when TweakCC is not installed" test_tweakcc_not_installed_silent

test_tweakcc_same_version_not_applied_warns() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Same version BUT changesApplied: false (patches reverted/not applied)
    mkdir -p "$mock_home/.cc-mirror/mclaude/tweakcc"
    cat > "$mock_home/.cc-mirror/mclaude/tweakcc/config.json" << 'EOF'
{
  "ccVersion": "2.1.62",
  "changesApplied": false,
  "settings": {}
}
EOF

    mkdir -p "$mock_home/.cc-mirror/mclaude/npm/node_modules/@anthropic-ai/claude-code"
    cat > "$mock_home/.cc-mirror/mclaude/npm/node_modules/@anthropic-ai/claude-code/package.json" << 'EOF'
{
  "name": "@anthropic-ai/claude-code",
  "version": "2.1.62"
}
EOF

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    # Same version but not applied — still worth a warning (patches unapplied)
    assert_not_contains "$output" "TweakCC patches stale" "should NOT warn about STALE when same version (patches just unapplied, not stale)"
}
run_test "check 28: no stale warning when same version but changesApplied false" test_tweakcc_same_version_not_applied_warns

# ── 29. wsl.conf duplicate section validation ────────────────────────────────

test_wslconf_no_warning_non_wsl() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create a wsl.conf with duplicates — but _FORCE_WSL=0 forces non-WSL
    local wsl_conf="$TEST_TMPDIR/wsl.conf"
    printf '[boot]\nsystemd=true\n[boot]\ncommand=/bin/bash\n' > "$wsl_conf"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(_FORCE_WSL=0 _WSL_CONF_PATH="$wsl_conf" run_hook "$patched")

    assert_not_contains "$output" "wsl.conf" "should NOT warn about wsl.conf on non-WSL"
}
run_test "check 29: no wsl.conf warning on non-WSL" test_wslconf_no_warning_non_wsl

test_wslconf_no_warning_clean() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Clean wsl.conf — no duplicates
    local wsl_conf="$TEST_TMPDIR/wsl.conf"
    printf '[boot]\nsystemd=true\n[interop]\nenabled=true\n' > "$wsl_conf"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(_FORCE_WSL=1 _WSL_CONF_PATH="$wsl_conf" run_hook "$patched")

    assert_not_contains "$output" "wsl.conf" "should NOT warn when wsl.conf has no duplicates"
}
run_test "check 29: no warning when wsl.conf has no duplicate sections" test_wslconf_no_warning_clean

test_wslconf_warns_on_duplicates() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # wsl.conf with duplicate [boot] section
    local wsl_conf="$TEST_TMPDIR/wsl.conf"
    printf '[boot]\nsystemd=true\n[interop]\nenabled=true\n[boot]\ncommand=/bin/bash\n' > "$wsl_conf"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(_FORCE_WSL=1 _WSL_CONF_PATH="$wsl_conf" run_hook "$patched")

    assert_contains "$output" "wsl.conf has duplicate" "should warn about duplicate sections"
    assert_contains "$output" "boot" "should name the duplicate section"
}
run_test "check 29: warns on duplicate wsl.conf sections" test_wslconf_warns_on_duplicates

test_wslconf_autofix_merges_duplicates() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # wsl.conf with duplicate [boot] — different keys + one overlapping key
    local wsl_conf="$TEST_TMPDIR/wsl.conf"
    printf '[boot]\nsystemd=true\n[interop]\nenabled=true\n[boot]\ncommand=/bin/bash\nsystemd=false\n' > "$wsl_conf"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(_FORCE_WSL=1 _WSL_CONF_PATH="$wsl_conf" run_hook "$patched")

    # After auto-fix, file should have exactly one [boot] section
    local boot_count
    boot_count=$(grep -c '^\[boot\]' "$wsl_conf")
    assert_eq "1" "$boot_count" "should have exactly one [boot] section after merge"

    # Last value wins: systemd should be false (from second [boot])
    assert_file_contains "$wsl_conf" "systemd=false" "last value should win for duplicate keys"

    # command should be preserved from the second section
    assert_file_contains "$wsl_conf" "command=/bin/bash" "unique keys from duplicate sections should be preserved"

    # [interop] should be unchanged
    assert_file_contains "$wsl_conf" '\[interop\]' "non-duplicate sections should be preserved"
    assert_file_contains "$wsl_conf" "enabled=true" "non-duplicate section keys should be preserved"
}
run_test "check 29: auto-fix merges duplicate wsl.conf sections" test_wslconf_autofix_merges_duplicates

test_wslconf_autofix_creates_backup() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # wsl.conf with duplicate [boot]
    local wsl_conf="$TEST_TMPDIR/wsl.conf"
    printf '[boot]\nsystemd=true\n[boot]\ncommand=/bin/bash\n' > "$wsl_conf"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(_FORCE_WSL=1 _WSL_CONF_PATH="$wsl_conf" run_hook "$patched")

    # Backup should exist
    local backup
    backup=$(ls "$TEST_TMPDIR"/wsl.conf.bak.* 2>/dev/null | head -1)
    assert_file_exists "$backup" "should create a backup of wsl.conf before auto-fix"

    # Backup should contain the original content (with duplicates)
    local backup_boot_count
    backup_boot_count=$(grep -c '^\[boot\]' "$backup")
    assert_eq "2" "$backup_boot_count" "backup should have original 2 [boot] sections"
}
run_test "check 29: auto-fix creates backup of wsl.conf" test_wslconf_autofix_creates_backup

test_wslconf_no_file_no_warning() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Point to a non-existent wsl.conf
    local wsl_conf="$TEST_TMPDIR/nonexistent-wsl.conf"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(_FORCE_WSL=1 _WSL_CONF_PATH="$wsl_conf" run_hook "$patched")

    assert_not_contains "$output" "wsl.conf" "should NOT warn when wsl.conf does not exist"
}
run_test "check 29: no warning when wsl.conf does not exist" test_wslconf_no_file_no_warning

test_wslconf_multiple_duplicate_sections() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # wsl.conf with duplicate [boot] AND duplicate [interop]
    local wsl_conf="$TEST_TMPDIR/wsl.conf"
    printf '[boot]\nsystemd=true\n[interop]\nenabled=true\n[boot]\ncommand=/bin/bash\n[interop]\nappendWindowsPath=false\n' > "$wsl_conf"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(_FORCE_WSL=1 _WSL_CONF_PATH="$wsl_conf" run_hook "$patched")

    assert_contains "$output" "boot" "should list boot as duplicate"
    assert_contains "$output" "interop" "should list interop as duplicate"

    # After fix, each section should appear exactly once
    local boot_count interop_count
    boot_count=$(grep -c '^\[boot\]' "$wsl_conf")
    interop_count=$(grep -c '^\[interop\]' "$wsl_conf")
    assert_eq "1" "$boot_count" "should have exactly one [boot] section after merge"
    assert_eq "1" "$interop_count" "should have exactly one [interop] section after merge"
}
run_test "check 29: handles multiple duplicate sections" test_wslconf_multiple_duplicate_sections

# ── 30. Check 2d: .setup-pending first-run detection ─────────────────────────

test_setup_pending_detected() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create .setup-pending in config repo root
    touch "$config_repo/.setup-pending"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "SETUP_PENDING" "should inject SETUP_PENDING when .setup-pending exists"
    assert_contains "$output" "first-run-refinement" "should reference first-run-refinement.md"
}
run_test "check 2d: detects .setup-pending marker and triggers first-run" test_setup_pending_detected

test_setup_pending_not_present() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # No .setup-pending file

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_not_contains "$output" "SETUP_PENDING" "should NOT inject SETUP_PENDING when marker absent"
}
run_test "check 2d: no warning when .setup-pending absent" test_setup_pending_not_present

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
