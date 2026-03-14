#!/usr/bin/env bash
# Tests for mobile repo deployment and collection
source "$(dirname "$0")/test-helpers.sh"

MOBILE_DEPLOY="$REPO_ROOT/setup/scripts/mobile-deploy.sh"
SYNC_SCRIPT="$REPO_ROOT/sync.sh"

suite_header "Mobile Repo (mobile-deploy / mobile-collect)"

# ── Helper: create a minimal config repo mock ────────────────────────────────

setup_mock_config() {
    local config="$1"
    mkdir -p "$config/global/foundation" "$config/global/machines"
    mkdir -p "$config/cross-project"
    mkdir -p "$config/setup/scripts"
    mkdir -p "$config/setup/config"

    # Minimal foundation files
    echo "# User Profile" > "$config/global/foundation/user-profile.md"
    echo "Name: Test User" >> "$config/global/foundation/user-profile.md"
    echo "# Personas" > "$config/global/foundation/personas.md"
    echo "## Bartl" >> "$config/global/foundation/personas.md"

    # Registry
    cat > "$config/registry.md" <<'REG'
# Project Registry
| Project | Priority | Parent | Path | GitHub Remote | Machines | Type | Phase | Notes |
|---------|----------|--------|------|--------------|----------|------|-------|-------|
| alpha | P1 | — | `~/alpha` | — | test | code | active | Test project |
| beta | P2 | — | `~/beta` | — | test | code | active | Test project 2 |
REG

    # Dashboard cache
    cat > "$config/cross-project/dashboard-cache.md" <<'DASH'
# Dashboard Cache
| Project | Priority | Tasks | Size |
|---------|----------|-------|------|
| alpha | P1 | 3 open | 10M |
| beta | P2 | 1 open | 5M |
DASH

    # Inbox
    cat > "$config/cross-project/inbox.md" <<'INBOX'
# Cross-Project Inbox
## Pending
- [ ] **alpha**: Do something
INBOX

    # Machine files
    echo "# Machine: test" > "$config/global/machines/test.md"

    # Minimal sync.sh (required by defensive check in mobile-deploy.sh)
    echo '#!/usr/bin/env bash' > "$config/sync.sh"
    echo 'echo "mock sync.sh"' >> "$config/sync.sh"

    # Mobile CLAUDE.md template
    echo "# Mobile Mode" > "$config/setup/config/mobile-CLAUDE.md"
    echo "You are in MOBILE MODE." >> "$config/setup/config/mobile-CLAUDE.md"
}

# ── Helper: create mock project dirs ─────────────────────────────────────────

setup_mock_projects() {
    local home="$1"
    mkdir -p "$home/alpha" "$home/beta"

    cat > "$home/alpha/session-context.md" <<'SC'
# Session Context
## Session Info
- **Session Goal**: Build feature X
## Current State
- **Active Task**: Testing
SC

    cat > "$home/alpha/backlog.md" <<'BL'
# Backlog
- [ ] [P1] Task one
- [ ] [P2] Task two
- [x] Done task
BL

    echo "# Beta" > "$home/beta/session-context.md"
}

# ── Structure tests ──────────────────────────────────────────────────────────

test_creates_structure() {
    setup_mock_config "$TEST_TMPDIR/config"
    setup_mock_projects "$TEST_TMPDIR/home"

    bash "$MOBILE_DEPLOY" \
        --config-repo "$TEST_TMPDIR/config" \
        --target "$TEST_TMPDIR/mobile" \
        --home "$TEST_TMPDIR/home"

    assert_dir_exists "$TEST_TMPDIR/mobile"
    assert_dir_exists "$TEST_TMPDIR/mobile/context"
    assert_dir_exists "$TEST_TMPDIR/mobile/context/project-summaries"
    assert_dir_exists "$TEST_TMPDIR/mobile/inbox"
    assert_file_exists "$TEST_TMPDIR/mobile/.mobile-repo"
    assert_file_exists "$TEST_TMPDIR/mobile/CLAUDE.md"
    assert_file_exists "$TEST_TMPDIR/mobile/session-context.md"
}
run_test "mobile-deploy creates expected directory structure" test_creates_structure

test_marker_file() {
    setup_mock_config "$TEST_TMPDIR/config"
    setup_mock_projects "$TEST_TMPDIR/home"

    bash "$MOBILE_DEPLOY" \
        --config-repo "$TEST_TMPDIR/config" \
        --target "$TEST_TMPDIR/mobile" \
        --home "$TEST_TMPDIR/home"

    assert_file_exists "$TEST_TMPDIR/mobile/.mobile-repo"
    assert_file_contains "$TEST_TMPDIR/mobile/.mobile-repo" "mobile-repo"
}
run_test ".mobile-repo marker file is created" test_marker_file

# ── Context copy tests ───────────────────────────────────────────────────────

test_copies_context_files() {
    setup_mock_config "$TEST_TMPDIR/config"
    setup_mock_projects "$TEST_TMPDIR/home"

    bash "$MOBILE_DEPLOY" \
        --config-repo "$TEST_TMPDIR/config" \
        --target "$TEST_TMPDIR/mobile" \
        --home "$TEST_TMPDIR/home"

    assert_file_exists "$TEST_TMPDIR/mobile/context/user-profile.md"
    assert_file_contains "$TEST_TMPDIR/mobile/context/user-profile.md" "Test User"
    assert_file_exists "$TEST_TMPDIR/mobile/context/personas.md"
    assert_file_contains "$TEST_TMPDIR/mobile/context/personas.md" "Assistant"
    assert_file_exists "$TEST_TMPDIR/mobile/context/registry.md"
    assert_file_exists "$TEST_TMPDIR/mobile/context/dashboard-cache.md"
}
run_test "context files are copied from config repo" test_copies_context_files

test_generates_machine_index() {
    setup_mock_config "$TEST_TMPDIR/config"
    setup_mock_projects "$TEST_TMPDIR/home"

    bash "$MOBILE_DEPLOY" \
        --config-repo "$TEST_TMPDIR/config" \
        --target "$TEST_TMPDIR/mobile" \
        --home "$TEST_TMPDIR/home"

    assert_file_exists "$TEST_TMPDIR/mobile/context/machine-index.md"
    assert_file_contains "$TEST_TMPDIR/mobile/context/machine-index.md" "test.md"
}
run_test "machine index is generated from machine files" test_generates_machine_index

# ── Freshness timestamps ────────────────────────────────────────────────────

test_freshness_timestamp() {
    setup_mock_config "$TEST_TMPDIR/config"
    setup_mock_projects "$TEST_TMPDIR/home"

    bash "$MOBILE_DEPLOY" \
        --config-repo "$TEST_TMPDIR/config" \
        --target "$TEST_TMPDIR/mobile" \
        --home "$TEST_TMPDIR/home"

    # Context files should have a freshness stamp at the top
    assert_file_contains "$TEST_TMPDIR/mobile/context/user-profile.md" "Snapshot:"
}
run_test "context files get freshness timestamps" test_freshness_timestamp

# ── Project summary generation ───────────────────────────────────────────────

test_generates_project_summaries() {
    setup_mock_config "$TEST_TMPDIR/config"
    setup_mock_projects "$TEST_TMPDIR/home"

    bash "$MOBILE_DEPLOY" \
        --config-repo "$TEST_TMPDIR/config" \
        --target "$TEST_TMPDIR/mobile" \
        --home "$TEST_TMPDIR/home"

    assert_file_exists "$TEST_TMPDIR/mobile/context/project-summaries/alpha.md"
    assert_file_contains "$TEST_TMPDIR/mobile/context/project-summaries/alpha.md" "Build feature X"
    assert_file_contains "$TEST_TMPDIR/mobile/context/project-summaries/alpha.md" "Task one"
}
run_test "project summaries are generated from session-context and backlog" test_generates_project_summaries

test_summary_skips_missing_projects() {
    setup_mock_config "$TEST_TMPDIR/config"
    # Don't create project dirs — they should be skipped gracefully

    bash "$MOBILE_DEPLOY" \
        --config-repo "$TEST_TMPDIR/config" \
        --target "$TEST_TMPDIR/mobile" \
        --home "$TEST_TMPDIR/home"

    # Should still succeed, just no summaries
    assert_dir_exists "$TEST_TMPDIR/mobile/context/project-summaries"
    assert_file_not_exists "$TEST_TMPDIR/mobile/context/project-summaries/alpha.md"
}
run_test "project summary generation skips missing project directories" test_summary_skips_missing_projects

# ── Outbox tests ─────────────────────────────────────────────────────────────

test_creates_outbox() {
    setup_mock_config "$TEST_TMPDIR/config"
    setup_mock_projects "$TEST_TMPDIR/home"

    bash "$MOBILE_DEPLOY" \
        --config-repo "$TEST_TMPDIR/config" \
        --target "$TEST_TMPDIR/mobile" \
        --home "$TEST_TMPDIR/home"

    assert_file_exists "$TEST_TMPDIR/mobile/inbox/outbox.md"
    assert_file_contains "$TEST_TMPDIR/mobile/inbox/outbox.md" "Pending"
}
run_test "outbox.md is created with header" test_creates_outbox

test_preserves_existing_outbox() {
    setup_mock_config "$TEST_TMPDIR/config"
    setup_mock_projects "$TEST_TMPDIR/home"

    # First deploy
    bash "$MOBILE_DEPLOY" \
        --config-repo "$TEST_TMPDIR/config" \
        --target "$TEST_TMPDIR/mobile" \
        --home "$TEST_TMPDIR/home"

    # Add a task to outbox
    echo "- [ ] **social**: Test task from mobile" >> "$TEST_TMPDIR/mobile/inbox/outbox.md"

    # Second deploy (should preserve outbox)
    bash "$MOBILE_DEPLOY" \
        --config-repo "$TEST_TMPDIR/config" \
        --target "$TEST_TMPDIR/mobile" \
        --home "$TEST_TMPDIR/home"

    assert_file_contains "$TEST_TMPDIR/mobile/inbox/outbox.md" "Test task from mobile"
}
run_test "mobile-deploy preserves existing outbox content" test_preserves_existing_outbox

# ── Idempotency ──────────────────────────────────────────────────────────────

test_idempotent() {
    setup_mock_config "$TEST_TMPDIR/config"
    setup_mock_projects "$TEST_TMPDIR/home"

    # Run twice
    bash "$MOBILE_DEPLOY" \
        --config-repo "$TEST_TMPDIR/config" \
        --target "$TEST_TMPDIR/mobile" \
        --home "$TEST_TMPDIR/home"
    bash "$MOBILE_DEPLOY" \
        --config-repo "$TEST_TMPDIR/config" \
        --target "$TEST_TMPDIR/mobile" \
        --home "$TEST_TMPDIR/home"

    # Should still have valid structure
    assert_file_exists "$TEST_TMPDIR/mobile/.mobile-repo"
    assert_file_exists "$TEST_TMPDIR/mobile/context/user-profile.md"
    assert_file_exists "$TEST_TMPDIR/mobile/CLAUDE.md"
}
run_test "mobile-deploy is idempotent" test_idempotent

# ── Mobile-collect tests ─────────────────────────────────────────────────────

test_collect_merges_outbox() {
    setup_mock_config "$TEST_TMPDIR/config"
    setup_mock_projects "$TEST_TMPDIR/home"

    # Deploy first
    bash "$MOBILE_DEPLOY" \
        --config-repo "$TEST_TMPDIR/config" \
        --target "$TEST_TMPDIR/mobile" \
        --home "$TEST_TMPDIR/home"

    # Add tasks to outbox
    echo "- [ ] **social**: Tweet about new feature" >> "$TEST_TMPDIR/mobile/inbox/outbox.md"
    echo "- [ ] **my-project**: Review paper draft" >> "$TEST_TMPDIR/mobile/inbox/outbox.md"

    # Collect
    bash "$MOBILE_DEPLOY" --collect \
        --config-repo "$TEST_TMPDIR/config" \
        --target "$TEST_TMPDIR/mobile"

    # Tasks should appear in inbox
    assert_file_contains "$TEST_TMPDIR/config/cross-project/inbox.md" "Tweet about new feature"
    assert_file_contains "$TEST_TMPDIR/config/cross-project/inbox.md" "Review paper draft"
}
run_test "mobile-collect merges outbox tasks into inbox" test_collect_merges_outbox

test_collect_clears_outbox() {
    setup_mock_config "$TEST_TMPDIR/config"
    setup_mock_projects "$TEST_TMPDIR/home"

    # Deploy
    bash "$MOBILE_DEPLOY" \
        --config-repo "$TEST_TMPDIR/config" \
        --target "$TEST_TMPDIR/mobile" \
        --home "$TEST_TMPDIR/home"

    # Add task
    echo "- [ ] **social**: Test task" >> "$TEST_TMPDIR/mobile/inbox/outbox.md"

    # Collect
    bash "$MOBILE_DEPLOY" --collect \
        --config-repo "$TEST_TMPDIR/config" \
        --target "$TEST_TMPDIR/mobile"

    # Outbox should be cleared (header only)
    assert_file_not_contains "$TEST_TMPDIR/mobile/inbox/outbox.md" "Test task"
    assert_file_contains "$TEST_TMPDIR/mobile/inbox/outbox.md" "Pending"
}
run_test "mobile-collect clears outbox after merging" test_collect_clears_outbox

test_collect_empty_outbox() {
    setup_mock_config "$TEST_TMPDIR/config"
    setup_mock_projects "$TEST_TMPDIR/home"

    # Deploy
    bash "$MOBILE_DEPLOY" \
        --config-repo "$TEST_TMPDIR/config" \
        --target "$TEST_TMPDIR/mobile" \
        --home "$TEST_TMPDIR/home"

    # Collect with empty outbox — should succeed without error
    local rc=0
    bash "$MOBILE_DEPLOY" --collect \
        --config-repo "$TEST_TMPDIR/config" \
        --target "$TEST_TMPDIR/mobile" 2>/dev/null || rc=$?

    assert_eq "0" "$rc" "collect with empty outbox should succeed"
}
run_test "mobile-collect handles empty outbox gracefully" test_collect_empty_outbox

test_collect_preserves_existing_inbox() {
    setup_mock_config "$TEST_TMPDIR/config"
    setup_mock_projects "$TEST_TMPDIR/home"

    # Deploy
    bash "$MOBILE_DEPLOY" \
        --config-repo "$TEST_TMPDIR/config" \
        --target "$TEST_TMPDIR/mobile" \
        --home "$TEST_TMPDIR/home"

    # Add task to outbox
    echo "- [ ] **social**: New mobile task" >> "$TEST_TMPDIR/mobile/inbox/outbox.md"

    # Collect
    bash "$MOBILE_DEPLOY" --collect \
        --config-repo "$TEST_TMPDIR/config" \
        --target "$TEST_TMPDIR/mobile"

    # Original inbox tasks should still be there
    assert_file_contains "$TEST_TMPDIR/config/cross-project/inbox.md" "Do something"
    assert_file_contains "$TEST_TMPDIR/config/cross-project/inbox.md" "New mobile task"
}
run_test "mobile-collect preserves existing inbox entries" test_collect_preserves_existing_inbox

# ── Branch merging tests (CFG-32) ────────────────────────────────────────────

# Helper: create a git-initialized mobile repo with claude/* branch
setup_mobile_git_repo() {
    local target="$1"
    local config="$2"

    # Deploy first to create structure
    bash "$MOBILE_DEPLOY" \
        --config-repo "$config" \
        --target "$target" \
        --home "$TEST_TMPDIR/home"

    # Init git in the mobile repo
    git -C "$target" init -b main >/dev/null 2>&1
    git -C "$target" config user.email "test@test.com"
    git -C "$target" config user.name "Test"
    git -C "$target" add -A >/dev/null 2>&1
    git -C "$target" commit -m "Initial mobile deploy" >/dev/null 2>&1
}

test_collect_merges_claude_branches() {
    setup_mock_config "$TEST_TMPDIR/config"
    setup_mock_projects "$TEST_TMPDIR/home"
    setup_mobile_git_repo "$TEST_TMPDIR/mobile" "$TEST_TMPDIR/config"

    # Create a claude/* branch with outbox content
    git -C "$TEST_TMPDIR/mobile" checkout -b "claude/session-1" >/dev/null 2>&1
    echo "- [ ] **social**: Task from claude branch" >> "$TEST_TMPDIR/mobile/inbox/outbox.md"
    git -C "$TEST_TMPDIR/mobile" add -A >/dev/null 2>&1
    git -C "$TEST_TMPDIR/mobile" commit -m "Mobile session work" >/dev/null 2>&1
    git -C "$TEST_TMPDIR/mobile" checkout main >/dev/null 2>&1

    # Collect should merge the branch and pick up the task
    bash "$MOBILE_DEPLOY" --collect \
        --config-repo "$TEST_TMPDIR/config" \
        --target "$TEST_TMPDIR/mobile"

    assert_file_contains "$TEST_TMPDIR/config/cross-project/inbox.md" "Task from claude branch"
}
run_test "mobile-collect merges claude/* branches before collecting" test_collect_merges_claude_branches

test_collect_merges_multiple_claude_branches() {
    setup_mock_config "$TEST_TMPDIR/config"
    setup_mock_projects "$TEST_TMPDIR/home"
    setup_mobile_git_repo "$TEST_TMPDIR/mobile" "$TEST_TMPDIR/config"

    # Create first claude/* branch
    git -C "$TEST_TMPDIR/mobile" checkout -b "claude/session-1" >/dev/null 2>&1
    echo "- [ ] **social**: Task from branch 1" >> "$TEST_TMPDIR/mobile/inbox/outbox.md"
    git -C "$TEST_TMPDIR/mobile" add -A >/dev/null 2>&1
    git -C "$TEST_TMPDIR/mobile" commit -m "Session 1 work" >/dev/null 2>&1
    git -C "$TEST_TMPDIR/mobile" checkout main >/dev/null 2>&1

    # Merge first to main so second branch diverges cleanly
    git -C "$TEST_TMPDIR/mobile" merge "claude/session-1" --no-edit >/dev/null 2>&1

    # Create second claude/* branch from updated main
    git -C "$TEST_TMPDIR/mobile" checkout -b "claude/session-2" >/dev/null 2>&1
    echo "- [ ] **my-project**: Task from branch 2" >> "$TEST_TMPDIR/mobile/inbox/outbox.md"
    git -C "$TEST_TMPDIR/mobile" add -A >/dev/null 2>&1
    git -C "$TEST_TMPDIR/mobile" commit -m "Session 2 work" >/dev/null 2>&1
    git -C "$TEST_TMPDIR/mobile" checkout main >/dev/null 2>&1

    # Collect should merge both branches
    bash "$MOBILE_DEPLOY" --collect \
        --config-repo "$TEST_TMPDIR/config" \
        --target "$TEST_TMPDIR/mobile"

    assert_file_contains "$TEST_TMPDIR/config/cross-project/inbox.md" "Task from branch 1"
    assert_file_contains "$TEST_TMPDIR/config/cross-project/inbox.md" "Task from branch 2"
}
run_test "mobile-collect merges multiple claude/* branches" test_collect_merges_multiple_claude_branches

test_collect_deletes_merged_branches() {
    setup_mock_config "$TEST_TMPDIR/config"
    setup_mock_projects "$TEST_TMPDIR/home"
    setup_mobile_git_repo "$TEST_TMPDIR/mobile" "$TEST_TMPDIR/config"

    # Create a claude/* branch
    git -C "$TEST_TMPDIR/mobile" checkout -b "claude/session-1" >/dev/null 2>&1
    echo "- [ ] **social**: Branch task" >> "$TEST_TMPDIR/mobile/inbox/outbox.md"
    git -C "$TEST_TMPDIR/mobile" add -A >/dev/null 2>&1
    git -C "$TEST_TMPDIR/mobile" commit -m "Session work" >/dev/null 2>&1
    git -C "$TEST_TMPDIR/mobile" checkout main >/dev/null 2>&1

    # Collect
    bash "$MOBILE_DEPLOY" --collect \
        --config-repo "$TEST_TMPDIR/config" \
        --target "$TEST_TMPDIR/mobile"

    # Branch should be deleted after merge
    local branches
    branches=$(git -C "$TEST_TMPDIR/mobile" branch --list "claude/*" 2>/dev/null)
    assert_eq "" "$branches" "claude/* branches should be deleted after merge"
}
run_test "mobile-collect deletes claude/* branches after merging" test_collect_deletes_merged_branches

test_collect_no_branches_still_works() {
    setup_mock_config "$TEST_TMPDIR/config"
    setup_mock_projects "$TEST_TMPDIR/home"
    setup_mobile_git_repo "$TEST_TMPDIR/mobile" "$TEST_TMPDIR/config"

    # Add outbox task on main (no branches)
    echo "- [ ] **social**: Main branch task" >> "$TEST_TMPDIR/mobile/inbox/outbox.md"

    # Collect should work normally without any claude/* branches
    local rc=0
    bash "$MOBILE_DEPLOY" --collect \
        --config-repo "$TEST_TMPDIR/config" \
        --target "$TEST_TMPDIR/mobile" || rc=$?

    assert_eq "0" "$rc" "collect should succeed without claude branches"
    assert_file_contains "$TEST_TMPDIR/config/cross-project/inbox.md" "Main branch task"
}
run_test "mobile-collect works with no claude/* branches" test_collect_no_branches_still_works

test_collect_non_git_repo_still_works() {
    setup_mock_config "$TEST_TMPDIR/config"
    setup_mock_projects "$TEST_TMPDIR/home"

    # Deploy without git init (non-git mobile repo)
    bash "$MOBILE_DEPLOY" \
        --config-repo "$TEST_TMPDIR/config" \
        --target "$TEST_TMPDIR/mobile" \
        --home "$TEST_TMPDIR/home"

    # Add outbox task
    echo "- [ ] **social**: Non-git task" >> "$TEST_TMPDIR/mobile/inbox/outbox.md"

    # Collect should still work (skip branch merging)
    local rc=0
    bash "$MOBILE_DEPLOY" --collect \
        --config-repo "$TEST_TMPDIR/config" \
        --target "$TEST_TMPDIR/mobile" || rc=$?

    assert_eq "0" "$rc" "collect should succeed for non-git mobile repo"
    assert_file_contains "$TEST_TMPDIR/config/cross-project/inbox.md" "Non-git task"
}
run_test "mobile-collect works for non-git mobile repos" test_collect_non_git_repo_still_works

# ── Session-log collection tests ─────────────────────────────────────────────

test_collect_session_log() {
    setup_mock_config "$TEST_TMPDIR/config"
    setup_mock_projects "$TEST_TMPDIR/home"

    # Deploy
    bash "$MOBILE_DEPLOY" \
        --config-repo "$TEST_TMPDIR/config" \
        --target "$TEST_TMPDIR/mobile" \
        --home "$TEST_TMPDIR/home"

    # Create session-log in the correct location (inbox/session-log.md)
    cat > "$TEST_TMPDIR/mobile/inbox/session-log.md" <<'LOG'
# Mobile Session Log

Append-only log of mobile sessions. Collected by `sync.sh mobile-collect`.

<!-- Entries below, newest first -->

### 2026-03-04 12:00 UTC — mobile
**Goal:** Quick inbox task
**Completed:**
- Reviewed paper abstract
LOG

    # Collect
    bash "$MOBILE_DEPLOY" --collect \
        --config-repo "$TEST_TMPDIR/config" \
        --target "$TEST_TMPDIR/mobile"

    # Session log should be appended to config repo's mobile session log
    assert_file_exists "$TEST_TMPDIR/config/docs/mobile-session-log.md"
    assert_file_contains "$TEST_TMPDIR/config/docs/mobile-session-log.md" "Quick inbox task"
    assert_file_contains "$TEST_TMPDIR/config/docs/mobile-session-log.md" "Reviewed paper abstract"
}
run_test "mobile-collect collects session-log entries" test_collect_session_log

test_collect_clears_session_log() {
    setup_mock_config "$TEST_TMPDIR/config"
    setup_mock_projects "$TEST_TMPDIR/home"

    # Deploy
    bash "$MOBILE_DEPLOY" \
        --config-repo "$TEST_TMPDIR/config" \
        --target "$TEST_TMPDIR/mobile" \
        --home "$TEST_TMPDIR/home"

    # Create session-log with an entry
    cat > "$TEST_TMPDIR/mobile/inbox/session-log.md" <<'LOG'
# Mobile Session Log

Append-only log of mobile sessions. Collected by `sync.sh mobile-collect`.

<!-- Entries below, newest first -->

### 2026-03-04 12:00 UTC — mobile
**Goal:** Quick task
LOG

    # Collect
    bash "$MOBILE_DEPLOY" --collect \
        --config-repo "$TEST_TMPDIR/config" \
        --target "$TEST_TMPDIR/mobile"

    # Mobile session-log should be reset (entry gone, header preserved)
    assert_file_not_contains "$TEST_TMPDIR/mobile/inbox/session-log.md" "Quick task"
    assert_file_contains "$TEST_TMPDIR/mobile/inbox/session-log.md" "Mobile Session Log"
    assert_file_contains "$TEST_TMPDIR/mobile/inbox/session-log.md" "Entries below"
}
run_test "mobile-collect resets session-log after collecting" test_collect_clears_session_log

test_collect_no_session_log() {
    setup_mock_config "$TEST_TMPDIR/config"
    setup_mock_projects "$TEST_TMPDIR/home"

    # Deploy (inbox dir exists but no session-log.md)
    bash "$MOBILE_DEPLOY" \
        --config-repo "$TEST_TMPDIR/config" \
        --target "$TEST_TMPDIR/mobile" \
        --home "$TEST_TMPDIR/home"

    # Remove session-log if deploy created one
    rm -f "$TEST_TMPDIR/mobile/inbox/session-log.md"

    # Collect should succeed without session-log
    local rc=0
    bash "$MOBILE_DEPLOY" --collect \
        --config-repo "$TEST_TMPDIR/config" \
        --target "$TEST_TMPDIR/mobile" || rc=$?

    assert_eq "0" "$rc" "collect should succeed without session-log"
}
run_test "mobile-collect handles missing session-log gracefully" test_collect_no_session_log

test_collect_session_log_empty() {
    setup_mock_config "$TEST_TMPDIR/config"
    setup_mock_projects "$TEST_TMPDIR/home"

    # Deploy
    bash "$MOBILE_DEPLOY" \
        --config-repo "$TEST_TMPDIR/config" \
        --target "$TEST_TMPDIR/mobile" \
        --home "$TEST_TMPDIR/home"

    # Session-log exists but has no entries (just the header)
    cat > "$TEST_TMPDIR/mobile/inbox/session-log.md" <<'LOG'
# Mobile Session Log

Append-only log of mobile sessions. Collected by `sync.sh mobile-collect`.

<!-- Entries below, newest first -->
LOG

    # Collect should succeed and NOT create config log (no entries to collect)
    local rc=0
    bash "$MOBILE_DEPLOY" --collect \
        --config-repo "$TEST_TMPDIR/config" \
        --target "$TEST_TMPDIR/mobile" || rc=$?

    assert_eq "0" "$rc" "collect should succeed with empty session-log"
    assert_file_not_exists "$TEST_TMPDIR/config/docs/mobile-session-log.md"
}
run_test "mobile-collect skips session-log with no entries" test_collect_session_log_empty

test_collect_session_log_appends() {
    setup_mock_config "$TEST_TMPDIR/config"
    setup_mock_projects "$TEST_TMPDIR/home"

    # Deploy
    bash "$MOBILE_DEPLOY" \
        --config-repo "$TEST_TMPDIR/config" \
        --target "$TEST_TMPDIR/mobile" \
        --home "$TEST_TMPDIR/home"

    # First session entry
    cat > "$TEST_TMPDIR/mobile/inbox/session-log.md" <<'LOG'
# Mobile Session Log

<!-- Entries below, newest first -->

### 2026-03-04 12:00 UTC — mobile
**Goal:** First session
LOG

    # First collect
    bash "$MOBILE_DEPLOY" --collect \
        --config-repo "$TEST_TMPDIR/config" \
        --target "$TEST_TMPDIR/mobile"

    # Second session entry
    cat > "$TEST_TMPDIR/mobile/inbox/session-log.md" <<'LOG'
# Mobile Session Log

<!-- Entries below, newest first -->

### 2026-03-04 18:00 UTC — mobile
**Goal:** Second session
LOG

    # Second collect
    bash "$MOBILE_DEPLOY" --collect \
        --config-repo "$TEST_TMPDIR/config" \
        --target "$TEST_TMPDIR/mobile"

    # Both entries should be in the config log
    assert_file_contains "$TEST_TMPDIR/config/docs/mobile-session-log.md" "First session"
    assert_file_contains "$TEST_TMPDIR/config/docs/mobile-session-log.md" "Second session"
}
run_test "mobile-collect appends to existing mobile-session-log.md" test_collect_session_log_appends

test_collect_session_log_multiple_entries() {
    setup_mock_config "$TEST_TMPDIR/config"
    setup_mock_projects "$TEST_TMPDIR/home"

    # Deploy
    bash "$MOBILE_DEPLOY" \
        --config-repo "$TEST_TMPDIR/config" \
        --target "$TEST_TMPDIR/mobile" \
        --home "$TEST_TMPDIR/home"

    # Multiple entries in a single collect
    cat > "$TEST_TMPDIR/mobile/inbox/session-log.md" <<'LOG'
# Mobile Session Log

<!-- Entries below, newest first -->

### 2026-03-04 18:00 UTC — mobile
**Goal:** Evening review
**Completed:**
- Reviewed inbox

### 2026-03-04 12:00 UTC — mobile
**Goal:** Lunchtime check
**Completed:**
- Posted task to outbox
LOG

    # Collect
    bash "$MOBILE_DEPLOY" --collect \
        --config-repo "$TEST_TMPDIR/config" \
        --target "$TEST_TMPDIR/mobile"

    # Both entries should be collected
    assert_file_contains "$TEST_TMPDIR/config/docs/mobile-session-log.md" "Evening review"
    assert_file_contains "$TEST_TMPDIR/config/docs/mobile-session-log.md" "Lunchtime check"

    # Config log header should exist
    assert_file_contains "$TEST_TMPDIR/config/docs/mobile-session-log.md" "Mobile Session Log"
}
run_test "mobile-collect handles multiple entries in one session-log" test_collect_session_log_multiple_entries

# ── CLAUDE.md deployment ─────────────────────────────────────────────────────

test_deploys_claude_md() {
    setup_mock_config "$TEST_TMPDIR/config"
    setup_mock_projects "$TEST_TMPDIR/home"

    bash "$MOBILE_DEPLOY" \
        --config-repo "$TEST_TMPDIR/config" \
        --target "$TEST_TMPDIR/mobile" \
        --home "$TEST_TMPDIR/home"

    assert_file_exists "$TEST_TMPDIR/mobile/CLAUDE.md"
    assert_file_contains "$TEST_TMPDIR/mobile/CLAUDE.md" "MOBILE MODE"
}
run_test "CLAUDE.md is deployed from template" test_deploys_claude_md

# ── Mobile staleness detection ───────────────────────────────────────────────

test_mobile_staleness_detected_when_source_newer() {
    setup_mock_config "$TEST_TMPDIR/config"
    setup_mock_projects "$TEST_TMPDIR/home"

    # Deploy mobile repo
    bash "$MOBILE_DEPLOY" \
        --config-repo "$TEST_TMPDIR/config" \
        --target "$TEST_TMPDIR/mobile" \
        --home "$TEST_TMPDIR/home"

    # Wait a moment, then modify a source file (make it newer than the snapshot)
    sleep 1
    echo "# Updated profile" > "$TEST_TMPDIR/config/global/foundation/user-profile.md"

    # Check staleness — should detect the source is newer
    local out rc=0
    out=$(bash "$MOBILE_DEPLOY" --check-staleness \
        --config-repo "$TEST_TMPDIR/config" \
        --target "$TEST_TMPDIR/mobile" 2>&1) || rc=$?
    assert_contains "$out" "mobile repo is stale"
}
run_test "staleness detected when source is newer than mobile snapshot" test_mobile_staleness_detected_when_source_newer

test_mobile_staleness_clean_after_fresh_deploy() {
    setup_mock_config "$TEST_TMPDIR/config"
    setup_mock_projects "$TEST_TMPDIR/home"

    # Fresh deploy
    bash "$MOBILE_DEPLOY" \
        --config-repo "$TEST_TMPDIR/config" \
        --target "$TEST_TMPDIR/mobile" \
        --home "$TEST_TMPDIR/home"

    # Check staleness immediately — should be clean
    local out rc=0
    out=$(bash "$MOBILE_DEPLOY" --check-staleness \
        --config-repo "$TEST_TMPDIR/config" \
        --target "$TEST_TMPDIR/mobile" 2>&1) || rc=$?
    assert_not_contains "$out" "mobile repo is stale"
}
run_test "no staleness detected after fresh deploy" test_mobile_staleness_clean_after_fresh_deploy

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
