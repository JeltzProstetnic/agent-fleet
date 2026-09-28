#!/usr/bin/env bash
# Tests for config-check.sh — state injection checks: persona, session-context,
# handoff, pending files, knowledge files, empty session-context
source "$(dirname "$0")/test-helpers.sh"
source "$(dirname "$0")/test-check-helpers.sh"

suite_header "config-check.sh: state injection checks"

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

# ── 20. Persona injection (B) ────────────────────────────────────────────────

test_persona_injection_reads_active_persona() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Write active persona file
    echo "Persona2" > "$mock_home/.claude/.active-persona"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "PERSONA: Persona2" "should inject persona name from .active-persona"
}
run_test "check 20: persona injection reads .active-persona" test_persona_injection_reads_active_persona

test_persona_injection_default_assistant() {
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
run_test "check 20: persona defaults to Assistant when file missing" test_persona_injection_default_assistant

test_persona_injection_trims_whitespace() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Persona file with trailing newline and spaces
    printf "  Persona2  \n\n" > "$mock_home/.claude/.active-persona"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "PERSONA: Persona2" "should trim whitespace from persona name"
    assert_not_contains "$output" "PERSONA:   Persona2" "should not have leading spaces in persona name"
}
run_test "check 20: persona trims whitespace" test_persona_injection_trims_whitespace

# ── 21. Session-context blank detection (E) ─────────────────────────────────

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

# ── 22. Handoff detection (C) ───────────────────────────────────────────────

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

# ── 23. Pending files list (D) ──────────────────────────────────────────────

test_pending_files_list_found() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir/docs"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create pending files in project dir with Action: headers
    printf 'Action: reference\nSome content' > "$project_dir/docs/pending-alpha.md"
    printf 'Action: defer\nOther content' > "$project_dir/docs/pending-beta.md"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "PENDING_FILES:" "should inject PENDING_FILES"
    assert_contains "$output" "pending-alpha.md (reference)" "should list pending-alpha.md with action status"
    assert_contains "$output" "pending-beta.md (defer)" "should list pending-beta.md with action status"
}
run_test "check 23: pending files listed when present" test_pending_files_list_found

test_pending_files_action_defaults_to_triage() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir/docs"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Pending file with no Action: header
    echo "just content, no action header" > "$project_dir/docs/pending-noaction.md"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "pending-noaction.md (triage)" "should default to triage when no Action: header"
}
run_test "check 23: pending files default to triage without Action header" test_pending_files_action_defaults_to_triage

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

# ── 24. Knowledge file list (F) ─────────────────────────────────────────────

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

# ── 6a.8. Onboarding tip — end/cls reminder for early sessions ─────────────

test_onboarding_tip_shown_for_new_user() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Session log with fewer than 5 sessions
    mkdir -p "$config_repo/docs"
    cat > "$config_repo/docs/session-log.md" << 'EOF'
# Session Log

## Session 49 — 2026-04-01
- Did stuff

## Session 48 — 2026-03-31
- Did other stuff
EOF

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "TIP:" "should show onboarding tip for new user"
    assert_contains "$output" "cls" "tip should mention cls"
    assert_contains "$output" "end" "tip should mention end"
}
run_test "check 6a.8: onboarding tip shown when <5 sessions" test_onboarding_tip_shown_for_new_user

test_onboarding_tip_hidden_for_experienced_user() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Session log with 5+ sessions
    mkdir -p "$config_repo/docs"
    {
        echo "# Session Log"
        for i in $(seq 1 6); do
            echo ""
            echo "## Session $i — 2026-03-0$i"
            echo "- Did stuff"
        done
    } > "$config_repo/docs/session-log.md"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_not_contains "$output" "TIP:" "should NOT show onboarding tip after 5+ sessions"
}
run_test "check 6a.8: onboarding tip hidden when >=5 sessions" test_onboarding_tip_hidden_for_experienced_user

test_onboarding_tip_shown_when_no_session_log() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # No session-log.md at all (brand new setup)

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "TIP:" "should show tip when no session-log.md exists"
}
run_test "check 6a.8: onboarding tip shown when session-log.md missing" test_onboarding_tip_shown_when_no_session_log

# ── 23b. STALE_PENDING reconciliation (stale-pending wiring) ────────────────

# Copy manage-pending.sh into the mock config repo so 06a can invoke it.
_install_manage_pending() {
    local config_repo="$1"
    mkdir -p "$config_repo/setup/scripts"
    cp "$REPO_ROOT/setup/scripts/manage-pending.sh" "$config_repo/setup/scripts/"
}

test_stale_act_routed_to_stale_pending() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir/docs"

    create_mock_config_repo "$config_repo"
    _install_manage_pending "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # A stale act file: Tracked-by PRN is closed in the project backlog.
    printf 'Action: act\nTracked-by: CFG-800\n\nShipped work.' \
        > "$project_dir/docs/pending-done-feature.md"
    {
        echo "# Backlog"
        echo "- [x] [P1] \`CFG-800\` **Done feature**: shipped"
    } > "$project_dir/backlog.md"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "STALE_PENDING:" "stale file should produce STALE_PENDING field" || return 1
    assert_contains "$output" "pending-done-feature.md" "stale file should be named" || return 1
    # The stale file must NOT appear under ACT_PENDING (it was routed away).
    local act_field
    act_field=$(echo "$output" | grep -oE 'ACT_PENDING:[^|]*' | head -1)
    assert_not_contains "$act_field" "pending-done-feature.md" \
        "stale file must be absent from ACT_PENDING"
}
run_test "check 23b: stale act file routed to STALE_PENDING, absent from ACT_PENDING" test_stale_act_routed_to_stale_pending

test_open_act_stays_in_act_pending() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir/docs"

    create_mock_config_repo "$config_repo"
    _install_manage_pending "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # A genuinely-open act file: Tracked-by PRN is still [ ] open.
    printf 'Action: act\nTracked-by: CFG-801\n\nStill working.' \
        > "$project_dir/docs/pending-open-feature.md"
    {
        echo "# Backlog"
        echo "- [ ] [P1] \`CFG-801\` **Open feature**: in progress"
    } > "$project_dir/backlog.md"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "ACT_PENDING:" "open act file should produce ACT_PENDING field" || return 1
    local act_field
    act_field=$(echo "$output" | grep -oE 'ACT_PENDING:[^|]*' | head -1)
    assert_contains "$act_field" "pending-open-feature.md" \
        "genuinely-open file must remain in ACT_PENDING" || return 1
    assert_not_contains "$output" "STALE_PENDING:" \
        "no stale files → no STALE_PENDING field"
}
run_test "check 23b: genuinely-open act file stays in ACT_PENDING, no STALE_PENDING" test_open_act_stays_in_act_pending

test_clean_path_pending_files_unchanged() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir/docs"

    create_mock_config_repo "$config_repo"
    _install_manage_pending "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Genuinely-open files (no stale evidence): a reference + a defer + an open act.
    printf 'Action: reference\nSome content' > "$project_dir/docs/pending-alpha.md"
    printf 'Action: defer\nOther content' > "$project_dir/docs/pending-beta.md"
    printf 'Action: act\nTracked-by: CFG-802\n\nopen' > "$project_dir/docs/pending-gamma.md"
    {
        echo "# Backlog"
        echo "- [ ] [P1] \`CFG-802\` **Gamma**: open"
    } > "$project_dir/backlog.md"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    # Clean-path regression guard: PENDING_FILES content byte-identical to the
    # pre-change behavior (all three files listed with their action tags).
    assert_not_contains "$output" "STALE_PENDING:" "no stale files → no STALE_PENDING field" || return 1
    local pf_field
    pf_field=$(echo "$output" | grep -oE 'PENDING_FILES:[^|]*' | head -1 | sed 's/[[:space:]]*$//')
    assert_eq "PENDING_FILES: pending-alpha.md (reference), pending-beta.md (defer), pending-gamma.md (act)" \
        "$pf_field" "PENDING_FILES content must be byte-identical on the clean path"
}
run_test "check 23b: clean path keeps PENDING_FILES byte-identical, no STALE_PENDING" test_clean_path_pending_files_unchanged

# ── CFG-620: STALE_PENDING resolves backlog state, never prose ───────────────
# Three recorded false positives came from the file's own text ("shipped",
# "commit abc1234", "deployed") being read as completion evidence while every
# Tracked-by ID was open. The exact case, in the comment form every real file
# uses: the file must stay live and no STALE_PENDING may appear.
test_stale_pending_ignores_shipped_prose_when_ids_open() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir/docs"

    create_mock_config_repo "$config_repo"
    _install_manage_pending "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    printf '<!-- Action: act -->\n<!-- Tracked-by: CFG-602, CFG-603 -->\n# lrn audit\nfix shipped (commit abcdef1) and deployed everywhere.\n' \
        > "$project_dir/docs/pending-lrn-audit.md"
    {
        echo "# Backlog"
        echo '- [ ] [P2] `CFG-602` **Open**: open'
        echo '- [?] [P2] `CFG-603` **Awaiting live proof**: not yet'
    } > "$project_dir/backlog.md"
    printf '# Session Log\n- lrn audit shipped (commit abcdef1), deployed\n' > "$project_dir/docs/session-log.md"

    local patched output act_field
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    output=$(run_hook "$patched")

    assert_not_contains "$output" "STALE_PENDING:" "open IDs → never stale, whatever the prose says" || return 1
    act_field=$(echo "$output" | grep -oE 'ACT_PENDING:[^|]*' | head -1)
    assert_contains "$act_field" "pending-lrn-audit.md" "the file stays live under ACT_PENDING"
}
run_test "check 23b (CFG-620): shipped-looking prose with open Tracked-by IDs is never STALE_PENDING" test_stale_pending_ignores_shipped_prose_when_ids_open

test_stale_pending_wording_cites_backlog_state() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir/docs"

    create_mock_config_repo "$config_repo"
    _install_manage_pending "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    printf '<!-- Action: act -->\n<!-- Tracked-by: CFG-800 -->\n\nShipped work.' \
        > "$project_dir/docs/pending-done-feature.md"
    printf '# Backlog\n- [x] [P1] `CFG-800` **Done feature**: shipped\n' > "$project_dir/backlog.md"

    local patched output stale_field
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    output=$(run_hook "$patched")

    stale_field=$(echo "$output" | grep -oE 'STALE_PENDING:[^|]*' | head -1)
    assert_contains "$stale_field" "pending-done-feature.md" || return 1
    assert_contains "$stale_field" "Tracked-by" "the finding names its evidence: backlog state of the Tracked-by IDs" || return 1
    assert_not_contains "$stale_field" "look already-shipped" "a resolved fact is not worded as a guess" || return 1
    assert_not_contains "$stale_field" "completion evidence found" "no prose evidence is claimed"
}
run_test "check 23b (CFG-620): STALE_PENDING wording cites Tracked-by state, not 'looks shipped'" test_stale_pending_wording_cites_backlog_state

# No Tracked-by at all is a different problem with a different action: the
# file stays live AND is called untracked — never "already shipped".
test_untracked_act_file_named_untracked_and_stays_live() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir/docs"

    create_mock_config_repo "$config_repo"
    _install_manage_pending "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    printf '<!-- Action: act -->\n# plan\nshuffled-bag fix shipped (commit 0114ac9)\n' \
        > "$project_dir/docs/pending-shuffled-bag-fix.md"
    printf '# Session Log\n- shuffled-bag fix shipped (commit 0114ac9)\n' > "$project_dir/docs/session-log.md"

    local patched output act_field
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    output=$(run_hook "$patched")

    assert_not_contains "$output" "STALE_PENDING:" "untracked is not stale" || return 1
    act_field=$(echo "$output" | grep -oE 'ACT_PENDING:[^|]*' | head -1)
    assert_contains "$act_field" "pending-shuffled-bag-fix.md" "still live" || return 1
    local untracked_field
    untracked_field=$(echo "$output" | grep -oE 'UNTRACKED_PENDING:[^|]*' | head -1)
    assert_contains "$untracked_field" "pending-shuffled-bag-fix.md" "named as untracked"
}
run_test "check 23b (CFG-620): act file without Tracked-by is UNTRACKED_PENDING and stays in ACT_PENDING" test_untracked_act_file_named_untracked_and_stays_live

# A supersession pointer whose target does not exist is a data-loss signal
# (the 2026-09-10 handover's successor was never created) — surfaced by name.
test_dangling_successor_surfaced() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir/docs"

    create_mock_config_repo "$config_repo"
    _install_manage_pending "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    printf '<!-- Action: reference -->\n<!-- SUPERSEDED 2026-09-11 by docs/pending-next-session-2026-09-11.md -->\n<!-- Tracked-by: CFG-433 -->\n' \
        > "$project_dir/docs/pending-next-session-2026-09-10.md"
    printf '# Backlog\n- [ ] [P1] `CFG-433` **Open**: open\n' > "$project_dir/backlog.md"

    local patched output field
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    output=$(run_hook "$patched")

    field=$(echo "$output" | grep -oE 'DANGLING_PENDING:[^|]*' | head -1)
    assert_contains "$field" "pending-next-session-2026-09-10.md" "the pointing file is named" || return 1
    assert_contains "$field" "pending-next-session-2026-09-11.md" "the missing successor is named" || return 1
    assert_not_contains "$output" "STALE_PENDING:" "not staleness"
}
run_test "check 23b (CFG-620): supersession pointer to a missing file is surfaced as DANGLING_PENDING" test_dangling_successor_surfaced

# ── CFG-482: the Action header is written as an HTML comment in practice ──────
# Every real pending file in the fleet writes `<!-- Action: x -->` so the header
# stays invisible in rendered markdown. The bare-form-only parser meant all of
# them fell through to the `triage` default and ACT_PENDING never once fired.

test_pending_files_comment_form_action() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir/docs"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    printf '<!-- Action: reference -->\n<!-- Tracked-by: CFG-900 -->\n# Held for context\n' \
        > "$project_dir/docs/pending-comment-ref.md"
    printf '<!-- Action: await-user-decision -->\n# Needs MG\n' \
        > "$project_dir/docs/pending-comment-await.md"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "pending-comment-ref.md (reference)" \
        "comment-form Action must classify as reference, not triage" || return 1
    assert_contains "$output" "pending-comment-await.md (await-user-decision)" \
        "hyphenated comment-form action must survive intact" || return 1
}
run_test "check 23 (CFG-482): comment-form Action header is parsed, not defaulted to triage" test_pending_files_comment_form_action

test_pending_comment_form_act_fires_act_pending() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir/docs"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    printf '<!-- Action: act -->\n<!-- Tracked-by: CFG-901 -->\n\nStill working.' \
        > "$project_dir/docs/pending-comment-act.md"
    {
        echo "# Backlog"
        echo '- [ ] [P1] `CFG-901` **Open**: work continues'
    } > "$project_dir/backlog.md"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "ACT_PENDING:" \
        "comment-form act file must fire the ACT_PENDING escalation channel" || return 1
    local act_field
    act_field=$(echo "$output" | grep -oE 'ACT_PENDING:[^|]*' | head -1)
    assert_contains "$act_field" "pending-comment-act.md" \
        "the comment-form act file must be named in ACT_PENDING" || return 1
}
run_test "check 23b (CFG-482): comment-form act file fires ACT_PENDING" test_pending_comment_form_act_fires_act_pending

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
