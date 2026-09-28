#!/usr/bin/env bash
# Tests for setup/scripts/mobile-deploy.sh
# Verifies deploy mode (file copying, structure creation, output format),
# collect mode (outbox merging, session log), and staleness checking.

source "$(dirname "$0")/test-helpers.sh"

suite_header "Mobile Deploy"

SCRIPT="$REPO_ROOT/setup/scripts/mobile-deploy.sh"

# ── Helpers ──────────────────────────────────────────────────────────────────

# Build a mock config repo with the minimum structure mobile-deploy.sh expects
setup_mock_config() {
    local config="$1"
    local user_home="${2:-$TEST_TMPDIR/home}"
    mkdir -p "$config/global/foundation" "$config/global/machines"
    mkdir -p "$config/cross-project"
    mkdir -p "$config/setup/scripts" "$config/setup/config"

    # sync.sh stub (mobile-deploy.sh validates this exists)
    echo '#!/bin/bash' > "$config/sync.sh"

    # Foundation files
    echo "# User Profile" > "$config/global/foundation/user-profile.md"
    echo "Name: Test User" >> "$config/global/foundation/user-profile.md"
    echo "# Personas" > "$config/global/foundation/personas.md"
    echo "## Persona1" >>"$config/global/foundation/personas.md"

    # Registry with projects that map to user_home
    cat > "$config/registry.md" <<REG
# Project Registry
| Project | Priority | Parent | Path | GitHub Remote | Machines | Type | Phase | Notes |
|---------|----------|--------|------|--------------|----------|------|-------|-------|
| alpha | P1 | — | \`~/alpha\` | — | test | code | active | Test project |
| beta | P2 | — | \`~/beta\` | — | test | code | active | Test project |
REG

    # Dashboard cache
    echo "# Dashboard Cache" > "$config/cross-project/dashboard-cache.md"
    echo "| Project | Tasks |" >> "$config/cross-project/dashboard-cache.md"

    # Inbox
    echo "# Cross-Project Inbox" > "$config/cross-project/inbox.md"
    echo "## Pending" >> "$config/cross-project/inbox.md"

    # Infrastructure strategy
    echo "# Infrastructure Strategy" > "$config/cross-project/infrastructure-strategy.md"

    # Machine files
    echo "# Machine: test" > "$config/global/machines/test.md"

    # Mobile CLAUDE.md template
    echo "# Mobile Mode" > "$config/setup/config/mobile-CLAUDE.md"
    echo "You are in MOBILE MODE." >> "$config/setup/config/mobile-CLAUDE.md"

    # Create mock project directories
    mkdir -p "$user_home/alpha" "$user_home/beta"
    echo "# Session" > "$user_home/alpha/session-context.md"
    echo "- **Session Goal**: Build feature" >> "$user_home/alpha/session-context.md"
    echo "# Backlog" > "$user_home/alpha/backlog.md"
    echo "- [ ] Task one" >> "$user_home/alpha/backlog.md"
}

# ── Tests: Deploy Mode — Directory Structure ───────────────────────────────

test_deploy_creates_structure() {
    local config="$TEST_TMPDIR/config"
    local target="$TEST_TMPDIR/mobile"
    local user_home="$TEST_TMPDIR/home"
    setup_mock_config "$config" "$user_home"

    bash "$SCRIPT" --config-repo "$config" --target "$target" --home "$user_home"

    assert_dir_exists "$target/context"
    assert_dir_exists "$target/context/project-summaries"
    assert_dir_exists "$target/inbox"
}
run_test "deploy creates context/ and inbox/ directories" test_deploy_creates_structure

test_deploy_creates_marker_file() {
    local config="$TEST_TMPDIR/config"
    local target="$TEST_TMPDIR/mobile"
    local user_home="$TEST_TMPDIR/home"
    setup_mock_config "$config" "$user_home"

    bash "$SCRIPT" --config-repo "$config" --target "$target" --home "$user_home"

    assert_file_exists "$target/.mobile-repo"
    assert_file_contains "$target/.mobile-repo" "mobile-repo"
}
run_test "deploy creates .mobile-repo marker" test_deploy_creates_marker_file

# ── Tests: Deploy Mode — File Copying ──────────────────────────────────────

test_deploy_copies_foundation_files() {
    local config="$TEST_TMPDIR/config"
    local target="$TEST_TMPDIR/mobile"
    local user_home="$TEST_TMPDIR/home"
    setup_mock_config "$config" "$user_home"

    bash "$SCRIPT" --config-repo "$config" --target "$target" --home "$user_home"

    assert_file_exists "$target/context/user-profile.md"
    assert_file_exists "$target/context/personas.md"
}
run_test "deploy copies foundation files" test_deploy_copies_foundation_files

test_deploy_copies_registry() {
    local config="$TEST_TMPDIR/config"
    local target="$TEST_TMPDIR/mobile"
    local user_home="$TEST_TMPDIR/home"
    setup_mock_config "$config" "$user_home"

    bash "$SCRIPT" --config-repo "$config" --target "$target" --home "$user_home"

    assert_file_exists "$target/context/registry.md"
    assert_file_contains "$target/context/registry.md" "Project Registry"
}
run_test "deploy copies registry.md" test_deploy_copies_registry

test_deploy_copies_dashboard_cache() {
    local config="$TEST_TMPDIR/config"
    local target="$TEST_TMPDIR/mobile"
    local user_home="$TEST_TMPDIR/home"
    setup_mock_config "$config" "$user_home"

    bash "$SCRIPT" --config-repo "$config" --target "$target" --home "$user_home"

    assert_file_exists "$target/context/dashboard-cache.md"
}
run_test "deploy copies dashboard-cache.md" test_deploy_copies_dashboard_cache

# ── Tests: Deploy Mode — Snapshot Stamps ───────────────────────────────────

test_deploy_adds_snapshot_stamps() {
    local config="$TEST_TMPDIR/config"
    local target="$TEST_TMPDIR/mobile"
    local user_home="$TEST_TMPDIR/home"
    setup_mock_config "$config" "$user_home"

    bash "$SCRIPT" --config-repo "$config" --target "$target" --home "$user_home"

    # Each copied file should have a snapshot timestamp comment at the top
    assert_file_contains "$target/context/user-profile.md" "<!-- Snapshot:"
    assert_file_contains "$target/context/registry.md" "<!-- Snapshot:"
}
run_test "deploy adds snapshot timestamps to copied files" test_deploy_adds_snapshot_stamps

# ── Tests: Deploy Mode — Machine Index ─────────────────────────────────────

test_deploy_generates_machine_index() {
    local config="$TEST_TMPDIR/config"
    local target="$TEST_TMPDIR/mobile"
    local user_home="$TEST_TMPDIR/home"
    setup_mock_config "$config" "$user_home"

    bash "$SCRIPT" --config-repo "$config" --target "$target" --home "$user_home"

    assert_file_exists "$target/context/machine-index.md"
    assert_file_contains "$target/context/machine-index.md" "Machine Index"
}
run_test "deploy generates machine-index.md" test_deploy_generates_machine_index

# ── Tests: Deploy Mode — Project Summaries ─────────────────────────────────

test_deploy_generates_project_summaries() {
    local config="$TEST_TMPDIR/config"
    local target="$TEST_TMPDIR/mobile"
    local user_home="$TEST_TMPDIR/home"
    setup_mock_config "$config" "$user_home"

    bash "$SCRIPT" --config-repo "$config" --target "$target" --home "$user_home"

    assert_file_exists "$target/context/project-summaries/alpha.md"
    assert_file_contains "$target/context/project-summaries/alpha.md" "# alpha"
    assert_file_contains "$target/context/project-summaries/alpha.md" "Session Context"
    assert_file_contains "$target/context/project-summaries/alpha.md" "Backlog"
}
run_test "deploy generates project summaries with session and backlog" test_deploy_generates_project_summaries

# ── Tests: Deploy Mode — CLAUDE.md ─────────────────────────────────────────

test_deploy_copies_claude_md() {
    local config="$TEST_TMPDIR/config"
    local target="$TEST_TMPDIR/mobile"
    local user_home="$TEST_TMPDIR/home"
    setup_mock_config "$config" "$user_home"

    bash "$SCRIPT" --config-repo "$config" --target "$target" --home "$user_home"

    assert_file_exists "$target/CLAUDE.md"
    assert_file_contains "$target/CLAUDE.md" "MOBILE MODE"
}
run_test "deploy copies mobile CLAUDE.md template" test_deploy_copies_claude_md

test_deploy_creates_minimal_claude_md_if_missing() {
    local config="$TEST_TMPDIR/config"
    local target="$TEST_TMPDIR/mobile"
    local user_home="$TEST_TMPDIR/home"
    setup_mock_config "$config" "$user_home"
    rm "$config/setup/config/mobile-CLAUDE.md"

    bash "$SCRIPT" --config-repo "$config" --target "$target" --home "$user_home"

    assert_file_exists "$target/CLAUDE.md"
    assert_file_contains "$target/CLAUDE.md" "MOBILE MODE"
}
run_test "deploy creates minimal CLAUDE.md when template missing" test_deploy_creates_minimal_claude_md_if_missing

# ── Tests: Deploy Mode — Outbox Preserved ──────────────────────────────────

test_deploy_preserves_existing_outbox() {
    local config="$TEST_TMPDIR/config"
    local target="$TEST_TMPDIR/mobile"
    local user_home="$TEST_TMPDIR/home"
    setup_mock_config "$config" "$user_home"

    # Create target with existing outbox
    mkdir -p "$target/inbox"
    echo "# Mobile Outbox" > "$target/inbox/outbox.md"
    echo "- [ ] Existing task from phone" >> "$target/inbox/outbox.md"

    bash "$SCRIPT" --config-repo "$config" --target "$target" --home "$user_home"

    # Outbox should NOT be overwritten
    assert_file_contains "$target/inbox/outbox.md" "Existing task from phone"
}
run_test "deploy preserves existing outbox.md" test_deploy_preserves_existing_outbox

# ── Tests: Collect Mode ───────────────────────────────────────────────────

test_collect_merges_outbox_tasks() {
    local config="$TEST_TMPDIR/config"
    local target="$TEST_TMPDIR/mobile"
    local user_home="$TEST_TMPDIR/home"
    setup_mock_config "$config" "$user_home"

    # Deploy first
    bash "$SCRIPT" --config-repo "$config" --target "$target" --home "$user_home"

    # Add tasks to outbox
    cat > "$target/inbox/outbox.md" <<'OUTBOX'
# Mobile Outbox

## Pending

- [ ] **social**: Post thread about new paper
- [ ] **alpha**: Review PR from contributor
OUTBOX

    # Run collect
    bash "$SCRIPT" --collect --config-repo "$config" --target "$target"

    # Tasks should appear in cross-project inbox
    assert_file_contains "$config/cross-project/inbox.md" "Post thread about new paper"
    assert_file_contains "$config/cross-project/inbox.md" "Review PR from contributor"
}
run_test "collect merges outbox tasks into cross-project inbox" test_collect_merges_outbox_tasks

test_collect_clears_outbox_after_merge() {
    local config="$TEST_TMPDIR/config"
    local target="$TEST_TMPDIR/mobile"
    local user_home="$TEST_TMPDIR/home"
    setup_mock_config "$config" "$user_home"
    bash "$SCRIPT" --config-repo "$config" --target "$target" --home "$user_home"

    cat > "$target/inbox/outbox.md" <<'OUTBOX'
# Mobile Outbox

## Pending

- [ ] **test**: Some task
OUTBOX

    bash "$SCRIPT" --collect --config-repo "$config" --target "$target"

    # Outbox should be reset (no tasks remaining)
    assert_file_not_contains "$target/inbox/outbox.md" "Some task"
    assert_file_contains "$target/inbox/outbox.md" "Mobile Outbox"
}
run_test "collect clears outbox after merging" test_collect_clears_outbox_after_merge

test_collect_handles_empty_outbox() {
    local config="$TEST_TMPDIR/config"
    local target="$TEST_TMPDIR/mobile"
    local user_home="$TEST_TMPDIR/home"
    setup_mock_config "$config" "$user_home"
    bash "$SCRIPT" --config-repo "$config" --target "$target" --home "$user_home"

    # Outbox with no tasks
    cat > "$target/inbox/outbox.md" <<'OUTBOX'
# Mobile Outbox

## Pending

OUTBOX

    local output
    output=$(bash "$SCRIPT" --collect --config-repo "$config" --target "$target" 2>&1)
    assert_contains "$output" "empty"
}
run_test "collect handles empty outbox gracefully" test_collect_handles_empty_outbox

# ── Tests: Config Repo Validation ──────────────────────────────────────────

test_rejects_missing_config_repo() {
    local output
    output=$(bash "$SCRIPT" --config-repo "/tmp/nonexistent-dir-999" --target "$TEST_TMPDIR/mobile" 2>&1) || true
    assert_contains "$output" "Config repo not found"
}
run_test "rejects missing config repo" test_rejects_missing_config_repo

# ── Tests: Unknown Option ─────────────────────────────────────────────────

test_unknown_option_fails() {
    local output
    output=$(bash "$SCRIPT" --bogus 2>&1) || true
    assert_contains "$output" "Unknown option"
}
run_test "unknown option fails with error" test_unknown_option_fails

suite_summary
