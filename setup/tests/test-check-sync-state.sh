#!/usr/bin/env bash
# Tests for config-check.sh — sync state checks (01-03): sync failure, symlink health,
# config repo, auto-pull, unclean shutdown, inbox, JSON output, clean state, exit code
source "$(dirname "$0")/test-helpers.sh"
source "$(dirname "$0")/test-check-helpers.sh"

suite_header "config-check.sh: sync state (checks 01-03)"

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
    create_mock_plugin_files "$mock_home"
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
    assert_contains "$output" "total: 2" "should report total pending tasks"
}
run_test "inbox: surfaces tasks for current project" test_inbox_task_surfacing

# ── CFG-134: child-project tasks must reach the PARENT's session ─────────────
# The registry has a Parent column and check 3.2 never read it, so an item
# addressed to a child project was invisible to the only session that routinely
# runs — the parent's. `grep -c Parent registry.md` = 2: the column exists and
# was unused. CLAUDE.md already tells the parent to "report child project tasks
# to the user but don't delete them"; it just had no way to see them, and the
# instruction it does give — read the full inbox manually — costs ~100k tokens.
#
# The injection is deliberately TRUNCATED per item. Full bodies would re-import
# the CFG-515 problem into every parent session; the parent only needs enough to
# tell the user a child has mail.

_mk_registry_with_child() {   # <config_repo> <parent> <child>
    mkdir -p "$1"
    cat > "$1/registry.md" << EOF
## Projects

| Project | Priority | Parent | Path | Type |
|---------|----------|--------|------|------|
| $2 | P1 | — | ~/$2 | config |
| $3 | P3 | $2 | ~/$3 | config |
| unrelated | P3 | — | ~/unrelated | code |

## Machines
EOF
}

test_child_tasks_surface_to_parent() {
    local config_repo="$TEST_TMPDIR/cfg134a-repo" mock_home="$TEST_TMPDIR/cfg134a-home" project_dir="$TEST_TMPDIR/parentproj"
    mkdir -p "$mock_home/.claude" "$project_dir"
    create_mock_config_repo "$config_repo"; create_mock_plugin_files "$mock_home"
    touch "$config_repo/CLAUDE.md"; ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"
    _mk_registry_with_child "$config_repo" parentproj childproj
    mkdir -p "$config_repo/cross-project"
    cat > "$config_repo/cross-project/inbox.md" << 'EOF'
# Cross-Project Inbox

- [ ] **parentproj**: something for me
- [ ] **childproj**: the child needs a launcher rebuild
- [ ] **unrelated**: not my business
EOF
    local patched; patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output; output=$(run_hook "$patched")
    assert_contains "$output" "CHILD" "the parent is told a child project has inbox mail" || return 1
    assert_contains "$output" "childproj" "the child project is named" || return 1
    assert_contains "$output" "launcher rebuild" "enough of the item is carried to be reportable"
}
run_test "CFG-134: child-project tasks surface to the parent" test_child_tasks_surface_to_parent

test_child_injection_says_do_not_delete() {
    # The parent must not delete them — the child's own session does. If the
    # injection does not say so, the parent will tidy them away.
    local config_repo="$TEST_TMPDIR/cfg134b-repo" mock_home="$TEST_TMPDIR/cfg134b-home" project_dir="$TEST_TMPDIR/parentproj"
    mkdir -p "$mock_home/.claude" "$project_dir"
    create_mock_config_repo "$config_repo"; create_mock_plugin_files "$mock_home"
    touch "$config_repo/CLAUDE.md"; ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"
    _mk_registry_with_child "$config_repo" parentproj childproj
    mkdir -p "$config_repo/cross-project"
    printf '# Inbox\n\n- [ ] **childproj**: a child item\n' > "$config_repo/cross-project/inbox.md"
    local patched; patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output; output=$(run_hook "$patched")
    assert_contains "$output" "do NOT delete" "the injection states the parent must not delete child items"
}
run_test "CFG-134: child injection carries the do-not-delete rule" test_child_injection_says_do_not_delete

test_no_child_no_injection() {
    # A project with no children must pay nothing for this.
    local config_repo="$TEST_TMPDIR/cfg134c-repo" mock_home="$TEST_TMPDIR/cfg134c-home" project_dir="$TEST_TMPDIR/lonelyproj"
    mkdir -p "$mock_home/.claude" "$project_dir"
    create_mock_config_repo "$config_repo"; create_mock_plugin_files "$mock_home"
    touch "$config_repo/CLAUDE.md"; ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"
    _mk_registry_with_child "$config_repo" parentproj childproj
    mkdir -p "$config_repo/cross-project"
    printf '# Inbox\n\n- [ ] **childproj**: a child item\n' > "$config_repo/cross-project/inbox.md"
    local patched; patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output; output=$(run_hook "$patched")
    assert_not_contains "$output" "CHILD" "a childless project gets no child block at all"
}
run_test "CFG-134: no children means no injection" test_no_child_no_injection

test_child_item_body_is_bounded() {
    # Unbounded child bodies would re-import CFG-515 into every parent session.
    local config_repo="$TEST_TMPDIR/cfg134d-repo" mock_home="$TEST_TMPDIR/cfg134d-home" project_dir="$TEST_TMPDIR/parentproj"
    mkdir -p "$mock_home/.claude" "$project_dir"
    create_mock_config_repo "$config_repo"; create_mock_plugin_files "$mock_home"
    touch "$config_repo/CLAUDE.md"; ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"
    _mk_registry_with_child "$config_repo" parentproj childproj
    mkdir -p "$config_repo/cross-project"
    {
      printf '# Inbox\n\n- [ ] **childproj**: '
      head -c 4000 /dev/zero | tr '\0' 'x'
      printf 'ENDMARKER\n'
    } > "$config_repo/cross-project/inbox.md"
    local patched; patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output; output=$(run_hook "$patched")
    assert_contains "$output" "childproj" "the child is still named" || return 1
    assert_not_contains "$output" "ENDMARKER" "a 4000-char child item is truncated, not carried whole"
}
run_test "CFG-134: child item bodies are truncated" test_child_item_body_is_bounded

test_inbox_no_tasks_for_project() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/unrelated"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    create_mock_plugin_files "$mock_home"
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
    assert_contains "$output" "1 task(s) for other projects" "should mention total inbox count"
}
run_test "inbox: no project-specific tasks, but still reports total count" test_inbox_no_tasks_for_project

# ── CFG-483: the project tag was matched case-sensitively ────────────────────
# 30 items written with an all-lowercase tag were invisible to a mixed-case
# project name for up to a month — neither delivered nor reported undelivered.
# Silent data loss in the fleet's only cross-project channel.

test_inbox_tag_case_insensitive() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/sampleProject"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    create_mock_plugin_files "$mock_home"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    mkdir -p "$config_repo/cross-project"
    cat > "$config_repo/cross-project/inbox.md" << 'EOF'
# Cross-Project Inbox

- [ ] **sampleproject**: Lowercase tag — must still be delivered
- [ ] **SAMPLEPROJECT**: Uppercase tag — must still be delivered
- [ ] ** sampleProject **: Padded tag — must still be delivered
- [ ] **otherproject**: Not ours
EOF

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "INBOX TASKS for sampleProject" "case-mismatched tags must still surface" || return 1
    assert_contains "$output" "Lowercase tag" "lowercase **sampleproject** must be delivered" || return 1
    assert_contains "$output" "Uppercase tag" "uppercase **SAMPLEPROJECT** must be delivered" || return 1
    assert_contains "$output" "Padded tag" "whitespace-padded tag must be delivered" || return 1
    assert_contains "$output" "1 task(s) for other projects" "other-project count must exclude all three of ours" || return 1
}
run_test "inbox (CFG-483): project tag matched case-insensitively and whitespace-tolerantly" test_inbox_tag_case_insensitive

test_inbox_unknown_tag_warns() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/myproject"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    create_mock_plugin_files "$mock_home"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    cat > "$config_repo/registry.md" << 'EOF'
## Projects

| Project | Priority | Parent | Path |
|---------|----------|--------|------|
| myproject | P1 | — | `~/myproject` |
| otherproject | P2 | — | `~/otherproject` |
| pdp | P2 | parent | `~/parent/pdp` |
EOF

    mkdir -p "$config_repo/cross-project"
    cat > "$config_repo/cross-project/inbox.md" << 'EOF'
# Cross-Project Inbox

- [ ] **myproject**: A real task
- [ ] **OTHERPROJECT**: Case variant of a real project — must NOT warn
- [ ] **myproject (WSL)**: Machine qualifier — must NOT warn
- [ ] **myproject + otherproject**: Multi-project tag — must NOT warn
- [ ] **parent/pdp**: Parent/child notation — must NOT warn
- [ ] **new-project**: Reserved placeholder — must NOT warn
- [ ] **typoproject**: Matches no registered project under any casing
EOF

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "INBOX_UNKNOWN_TAG" "an undeliverable tag must be loud, not silent" || return 1

    local warn_field
    warn_field=$(echo "$output" | grep -oE 'INBOX_UNKNOWN_TAG:[^|"]*' | head -1)
    assert_contains "$warn_field" "typoproject" "the unknown tag must be named" || return 1
    for legit in otherproject "(wsl)" "new-project" "parent/pdp" pdp; do
        assert_not_contains "$warn_field" "$legit" \
            "legitimate tag form '$legit' must not be reported undeliverable" || return 1
    done
}
run_test "inbox (CFG-483): tag matching no registry project warns instead of vanishing" test_inbox_unknown_tag_warns

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

    # Should have additionalContext key
    local has_key
    has_key=$([ -n "$(extract_additional_context "$output")" ] && echo yes || echo no)
    assert_eq "yes" "$has_key" "JSON should have additionalContext key"
}
run_test "JSON output: valid JSON with additionalContext key when warnings exist" test_json_output_format

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

    # Extract the additionalContext value
    local msg
    msg=$(extract_additional_context "$output")
    assert_contains "$msg" "WARNING:" "additionalContext should start with WARNING:"
    assert_contains "$msg" "CLAUDE.md" "additionalContext should contain the actual warning"
}
run_test "JSON output: additionalContext contains warning text" test_json_output_contains_warning_text

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
    # Create agent-fleet-mobile dir so Check 16 doesn't fire
    mkdir -p "$mock_home/agent-fleet-mobile"

    # Create mock plugin files so Check 11 (plugin-integrity) stays silent
    create_mock_plugin_files "$mock_home"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output rc=0
    # _FORCE_WSL=0 suppresses Check 29 (wsl.conf) which fires on real WSL machines
    output=$(_FORCE_WSL=0 run_hook "$patched") || rc=$?

    assert_eq "0" "$rc" "should exit 0"
    # git pull may output "Already up to date." — that's expected non-JSON noise.
    # The key assertion: no JSON warning output (no additionalContext).
    assert_not_contains "$output" "additionalContext" "should produce no JSON warnings when everything is clean"
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
    msg=$(extract_additional_context "$output")
    assert_contains "$msg" "CONFIG SYNC FAILED" "should contain sync failure warning"
    assert_contains "$msg" "CLAUDE.md is not symlinked" "should contain symlink warning"
}
run_test "multiple warnings: combined into single JSON additionalContext" test_multiple_warnings_combined

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

    # Create agent-fleet-mobile dir so Check 16 doesn't fire
    mkdir -p "$mock_home/agent-fleet-mobile"

    # Create mock plugin files so Check 11 (plugin-integrity) stays silent
    create_mock_plugin_files "$mock_home"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    # _FORCE_WSL=0 suppresses Check 29 (wsl.conf) which fires on real WSL machines
    output=$(_FORCE_WSL=0 run_hook "$patched")

    # git pull may output "Already up to date." — that's expected non-JSON noise.
    assert_not_contains "$output" "additionalContext" "should produce no JSON warnings when inbox is done"
    assert_not_contains "$output" "WARNING" "should produce no WARNING when inbox is done"
}
run_test "inbox: no warnings when all tasks are completed" test_inbox_all_done

# ── 19. Symlink target validation ──────────────────────────────────────────────

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
# Moved to section 25 — symlink direction validation tests
# (function test_symlink_wrong_target kept above for reference, tested via new tests below)
skip_test "symlink target: warns when CLAUDE.md symlink points to wrong directory (old test)" "replaced by section 25 tests"

test_symlink_correct_target() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local remote_repo="$TEST_TMPDIR/remote.git"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_tracked_repo_main "$config_repo" "$remote_repo"
    (cd "$config_repo" && touch sync.sh && git add sync.sh && git commit -m "add sync.sh" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    mkdir -p "$config_repo/global"
    (cd "$config_repo" && mkdir -p global && printf '<!-- updates: registry.md -->\n# Config\n' > global/CLAUDE.md && git add global/CLAUDE.md && git commit -m "add CLAUDE.md" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)

    # Symlink points to the CORRECT config repo
    ln -sf "$config_repo/global/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create other coherence-tracked files with headers to avoid Check 30 noise
    mkdir -p "$config_repo/cross-project"
    echo '<!-- updates: registry.md -->' > "$config_repo/cross-project/infrastructure-strategy.md"
    echo '<!-- updates: cross-project/infrastructure-strategy.md -->' > "$config_repo/registry.md"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_not_contains "$output" "symlink points to wrong" "should NOT warn when symlink is correct"
    assert_not_contains "$output" "CLAUDE.md" "should produce no CLAUDE.md warnings"
}
run_test "symlink target: no warning when CLAUDE.md symlink points to correct directory" test_symlink_correct_target

# ── 25. Symlink direction validation (Check 2 enhancement) ───────────────────

test_symlink_wrong_target_warns() {
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
run_test "symlink direction: warns when CLAUDE.md symlink points to wrong repo" test_symlink_wrong_target_warns

test_symlink_correct_target_no_warn() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    mkdir -p "$config_repo/global"
    touch "$config_repo/global/CLAUDE.md"

    # Symlink points to the CORRECT config repo
    ln -sf "$config_repo/global/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_not_contains "$output" "symlink points to wrong" "should NOT warn when symlink points to correct repo"
}
run_test "symlink direction: no warning when CLAUDE.md points to correct repo" test_symlink_correct_target_no_warn

test_symlink_foundation_wrong_target() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local stale_repo="$TEST_TMPDIR/stale-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    mkdir -p "$config_repo/global" "$config_repo/global/foundation"
    touch "$config_repo/global/CLAUDE.md"
    touch "$config_repo/global/foundation/user-profile.md"

    # CLAUDE.md symlink is correct
    ln -sf "$config_repo/global/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # But foundation symlink points to stale repo
    # (foundation dir must NOT exist as a real dir before symlinking)
    mkdir -p "$stale_repo/global/foundation"
    echo "stale" > "$stale_repo/global/foundation/user-profile.md"
    ln -sf "$stale_repo/global/foundation" "$mock_home/.claude/foundation"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "symlink points to wrong" "should warn when foundation symlink points to wrong repo"
}
run_test "symlink direction: warns when foundation symlink points to wrong repo" test_symlink_foundation_wrong_target

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
