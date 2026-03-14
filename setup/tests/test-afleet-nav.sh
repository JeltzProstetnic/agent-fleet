#!/usr/bin/env bash
# Tests for setup/scripts/afleet-nav.sh — cross-project navigation helper
source "$(dirname "$0")/test-helpers.sh"

SCRIPT="$REPO_ROOT/setup/scripts/afleet-nav.sh"

suite_header "afleet-nav.sh (cross-project navigation)"

# ── Helpers ──────────────────────────────────────────────────────────────────

create_mock_registry() {
    local dir="$1"
    cat > "$dir/registry.md" << 'EOF'
# Project Registry

## Projects

| Project | Priority | Parent | Path | GitHub Remote | Machines | Type | Phase | Notes |
|---------|----------|--------|------|--------------|----------|------|-------|-------|
| project-alpha | P1 | — | `~/project-alpha` | `testuser/project-alpha` | dev-main, dev-office | research | active | Consciousness theory |
| cfg-agent-fleet | P1 | — | `~/cfg-agent-fleet` | `testuser/cfg-agent-fleet` | dev-main, dev-portable | meta | active | Config backbone |
| project-beta | P1 | — | `~/project-beta` | `testuser/project-beta` | dev-main | marketing | active | Twitter engagement |
| project-gamma | P2 | — | `~/project-gamma` | `testuser/project-gamma` | dev-main, dev-server | code | active | |
| infrastructure | P2 | cfg-agent-fleet | `~/infrastructure` | `testuser/infrastructure` | dev-main | infra | active | |
EOF
}

create_mock_env() {
    local config_dir="$TEST_TMPDIR/config"
    mkdir -p "$config_dir/cross-project"
    create_mock_registry "$config_dir"
    echo "$config_dir"
}

# ── 1. Help and usage ────────────────────────────────────────────────────────

test_help_shows_usage() {
    local output
    output=$(bash "$SCRIPT" --help 2>&1)
    assert_contains "$output" "Usage" "should show usage header"
    assert_contains "$output" "switch" "should document switch action"
    assert_contains "$output" "tab" "should document tab action"
    assert_contains "$output" "notify" "should document notify action"
    assert_contains "$output" "info" "should document info action"
}
run_test "--help shows usage with all actions" test_help_shows_usage

# ── 2. Missing arguments ─────────────────────────────────────────────────────

test_missing_action_exits_error() {
    local output
    local rc=0
    output=$(bash "$SCRIPT" 2>&1) || rc=$?
    assert_neq "0" "$rc" "should exit non-zero with no arguments"
    assert_contains "$output" "Usage" "should show usage on missing action"
}
run_test "missing action argument exits with error" test_missing_action_exits_error

test_missing_project_exits_error() {
    local config_dir
    config_dir=$(create_mock_env)
    local output
    local rc=0
    output=$(bash "$SCRIPT" info --config-repo "$config_dir" 2>&1) || rc=$?
    assert_neq "0" "$rc" "should exit non-zero with missing project"
    assert_contains "$output" "project" "should mention missing project in error"
}
run_test "missing project argument exits with error" test_missing_project_exits_error

# ── 3. Info action ───────────────────────────────────────────────────────────

test_info_shows_project_details() {
    local config_dir
    config_dir=$(create_mock_env)
    local output
    output=$(bash "$SCRIPT" info project-alpha --config-repo "$config_dir" 2>&1)
    assert_contains "$output" "project-alpha" "should show project name"
    assert_contains "$output" "P1" "should show priority"
    assert_contains "$output" "project-alpha" "should show path component"
    assert_contains "$output" "dev-main" "should show machines"
}
run_test "info action shows project details from registry" test_info_shows_project_details

test_info_shows_parent_project() {
    local config_dir
    config_dir=$(create_mock_env)
    local output
    output=$(bash "$SCRIPT" info infrastructure --config-repo "$config_dir" 2>&1)
    assert_contains "$output" "cfg-agent-fleet" "should show parent project"
}
run_test "info shows parent project when present" test_info_shows_parent_project

test_info_unknown_project_exits_error() {
    local config_dir
    config_dir=$(create_mock_env)
    local output
    local rc=0
    output=$(bash "$SCRIPT" info nonexistent --config-repo "$config_dir" 2>&1) || rc=$?
    assert_neq "0" "$rc" "should exit non-zero for unknown project"
    assert_contains "$output" "not found" "should say project not found"
}
run_test "info on unknown project exits with error" test_info_unknown_project_exits_error

# ── 4. Notify action ─────────────────────────────────────────────────────────

test_notify_appends_to_inbox() {
    local config_dir
    config_dir=$(create_mock_env)
    # Pre-create inbox with existing content
    cat > "$config_dir/cross-project/inbox.md" << 'EOF'
# Cross-Project Inbox

## Pending

- [ ] **project-beta**: existing task
EOF

    bash "$SCRIPT" notify project-alpha "Review the new paper draft" --config-repo "$config_dir" 2>&1
    assert_file_contains "$config_dir/cross-project/inbox.md" 'project-alpha.*Review the new paper draft' \
        "should append formatted task to inbox"
    # Existing content should still be there
    assert_file_contains "$config_dir/cross-project/inbox.md" 'existing task' \
        "should preserve existing inbox content"
}
run_test "notify action appends task to inbox file" test_notify_appends_to_inbox

test_notify_creates_inbox_if_missing() {
    local config_dir
    config_dir=$(create_mock_env)
    # Remove inbox file
    rm -f "$config_dir/cross-project/inbox.md"

    bash "$SCRIPT" notify project-gamma "Prepare release notes" --config-repo "$config_dir" 2>&1
    assert_file_exists "$config_dir/cross-project/inbox.md" "should create inbox file"
    assert_file_contains "$config_dir/cross-project/inbox.md" 'project-gamma.*Prepare release notes' \
        "should write formatted task"
}
run_test "notify creates inbox file if missing" test_notify_creates_inbox_if_missing

test_notify_missing_message_exits_error() {
    local config_dir
    config_dir=$(create_mock_env)
    local output
    local rc=0
    output=$(bash "$SCRIPT" notify project-alpha --config-repo "$config_dir" 2>&1) || rc=$?
    assert_neq "0" "$rc" "should exit non-zero when message is missing"
    assert_contains "$output" "message" "should mention missing message"
}
run_test "notify without message exits with error" test_notify_missing_message_exits_error

# ── 5. Platform detection ─────────────────────────────────────────────────────

test_platform_detect_wsl() {
    local config_dir
    config_dir=$(create_mock_env)
    # Create mock /proc/version with Microsoft string
    local mock_proc="$TEST_TMPDIR/proc"
    mkdir -p "$mock_proc"
    echo "Linux version 6.6.87.2-microsoft-standard-WSL2" > "$mock_proc/version"

    local output
    output=$(AFLEET_NAV_PROC_VERSION="$mock_proc/version" \
             AFLEET_NAV_DRY_RUN=1 \
             bash "$SCRIPT" tab project-alpha --config-repo "$config_dir" 2>&1)
    assert_contains "$output" "wt.exe" "should use Windows Terminal for WSL"
}
run_test "platform detection identifies WSL via /proc/version" test_platform_detect_wsl

test_tab_in_tmux_uses_tmux() {
    local config_dir
    config_dir=$(create_mock_env)
    # Mock: not WSL, not KDE, but tmux is active
    local mock_proc="$TEST_TMPDIR/proc"
    mkdir -p "$mock_proc"
    echo "Linux version 6.6.0-generic" > "$mock_proc/version"

    local output
    output=$(AFLEET_NAV_PROC_VERSION="$mock_proc/version" \
             AFLEET_NAV_DRY_RUN=1 \
             TMUX="/tmp/tmux-1000/default,12345,0" \
             AFLEET_NAV_HAS_QDBUS=0 \
             bash "$SCRIPT" tab project-alpha --config-repo "$config_dir" 2>&1)
    assert_contains "$output" "tmux" "should use tmux when TMUX is set"
}
run_test "tab in tmux environment uses tmux new-window" test_tab_in_tmux_uses_tmux

test_fallback_prints_manual_instructions() {
    local config_dir
    config_dir=$(create_mock_env)
    # Mock: not WSL, not KDE, not tmux
    local mock_proc="$TEST_TMPDIR/proc"
    mkdir -p "$mock_proc"
    echo "Linux version 6.6.0-generic" > "$mock_proc/version"

    local output
    output=$(AFLEET_NAV_PROC_VERSION="$mock_proc/version" \
             AFLEET_NAV_DRY_RUN=1 \
             TMUX="" \
             AFLEET_NAV_HAS_QDBUS=0 \
             bash "$SCRIPT" tab project-alpha --config-repo "$config_dir" 2>&1)
    assert_contains "$output" "manually" "should print manual instructions on fallback"
}
run_test "fallback when no platform detected prints manual instructions" test_fallback_prints_manual_instructions

# ── 6. Switch action ─────────────────────────────────────────────────────────

test_switch_includes_close_instruction() {
    local config_dir
    config_dir=$(create_mock_env)
    local mock_proc="$TEST_TMPDIR/proc"
    mkdir -p "$mock_proc"
    echo "Linux version 6.6.0-generic" > "$mock_proc/version"

    local output
    output=$(AFLEET_NAV_PROC_VERSION="$mock_proc/version" \
             AFLEET_NAV_DRY_RUN=1 \
             TMUX="" \
             AFLEET_NAV_HAS_QDBUS=0 \
             bash "$SCRIPT" switch project-alpha --config-repo "$config_dir" 2>&1)
    assert_contains "$output" "close" "switch should tell user to close current session"
}
run_test "switch action includes instruction to close current session" test_switch_includes_close_instruction

# ── 7. Unknown action ────────────────────────────────────────────────────────

test_unknown_action_exits_error() {
    local config_dir
    config_dir=$(create_mock_env)
    local output
    local rc=0
    output=$(bash "$SCRIPT" destroy project-alpha --config-repo "$config_dir" 2>&1) || rc=$?
    assert_neq "0" "$rc" "should exit non-zero for unknown action"
    assert_contains "$output" "Unknown action" "should say unknown action"
}
run_test "unknown action exits with error" test_unknown_action_exits_error

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
