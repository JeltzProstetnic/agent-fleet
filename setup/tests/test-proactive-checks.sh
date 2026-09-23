#!/usr/bin/env bash
# Tests for CFG-172 Phase 1: Proactive debt detection checks
# - MEMORY.md violation detection (added to 04-auto-fix.sh)
# - Inbox staleness detection (added to 05-stale-detection.sh)
# - Audit staleness detection (new 14-audit-staleness.sh)
source "$(dirname "$0")/test-helpers.sh"

suite_header "Proactive Debt Detection Checks (CFG-172 Phase 1)"

CHECK_04="$REPO_ROOT/global/hooks/checks/04-auto-fix.sh"
CHECK_05="$REPO_ROOT/global/hooks/checks/05-stale-detection.sh"
CHECK_14="$REPO_ROOT/global/hooks/checks/14-audit-staleness.sh"

# ── Helper: set up minimal env for check modules ────────────────────────────

setup_check_env() {
    export PROJECT_DIR="$TEST_TMPDIR/project"
    export CONFIG_REPO="$TEST_TMPDIR/config-repo"
    export SETTINGS_FILE="$TEST_TMPDIR/settings.json"
    export DEFAULT_BRANCH="main"
    export USER_HOME="$TEST_TMPDIR/home"
    export HOME="$TEST_TMPDIR/home"
    WARNINGS=""
    INBOX_MSG=""

    mkdir -p "$PROJECT_DIR"
    mkdir -p "$CONFIG_REPO/cross-project"
    mkdir -p "$CONFIG_REPO/dms/scripts"
    mkdir -p "$CONFIG_REPO/setup/scripts"
    mkdir -p "$CONFIG_REPO/.git"
    mkdir -p "$HOME/.claude"
    # Stub settings.json to prevent Check 14 (bash perm) from erroring
    echo '{"permissions":{"allow":["Bash(bash:*)"]}}' > "$SETTINGS_FILE"
    # Stub scripts that 04 calls so it doesn't error
    echo '#!/bin/bash' > "$CONFIG_REPO/setup/scripts/clean-permissions.sh"
    chmod +x "$CONFIG_REPO/setup/scripts/clean-permissions.sh"
}

# ══════════════════════════════════════════════════════════════════════════════
# Check 1: MEMORY.md violation detection (04-auto-fix.sh)
# ══════════════════════════════════════════════════════════════════════════════

# Test: Clean project (no MEMORY.md, no memory/) → no warning
test_memory_clean() {
    setup_check_env
    # No MEMORY.md or memory/ in PROJECT_DIR
    source "$CHECK_04"
    assert_not_contains "$WARNINGS" "MEMORY.md" "clean project should not warn about MEMORY.md"
    assert_not_contains "$WARNINGS" "memory/" "clean project should not warn about memory/"
}
run_test "MEMORY.md: clean project is silent" test_memory_clean

# Test: MEMORY.md exists → warning
test_memory_md_exists() {
    setup_check_env
    echo "# Auto Memory" > "$PROJECT_DIR/MEMORY.md"
    source "$CHECK_04"
    assert_contains "$WARNINGS" "MEMORY.md" "MEMORY.md should trigger warning"
    assert_contains "$WARNINGS" "fleet rules prohibit auto-memory" "warning should mention fleet rules"
}
run_test "MEMORY.md: file exists triggers warning" test_memory_md_exists

# Test: memory/ directory exists → warning
test_memory_dir_exists() {
    setup_check_env
    mkdir -p "$PROJECT_DIR/memory"
    echo "stuff" > "$PROJECT_DIR/memory/note.md"
    source "$CHECK_04"
    assert_contains "$WARNINGS" "memory/" "memory/ dir should trigger warning"
    assert_contains "$WARNINGS" "fleet rules prohibit auto-memory" "warning should mention fleet rules"
}
run_test "MEMORY.md: memory/ directory triggers warning" test_memory_dir_exists

# Test: Both MEMORY.md and memory/ → single warning mentioning both
test_memory_both() {
    setup_check_env
    echo "# Auto Memory" > "$PROJECT_DIR/MEMORY.md"
    mkdir -p "$PROJECT_DIR/memory"
    source "$CHECK_04"
    assert_contains "$WARNINGS" "MEMORY.md" "should mention MEMORY.md"
    assert_contains "$WARNINGS" "memory/" "should mention memory/"
}
run_test "MEMORY.md: both file and dir triggers warning" test_memory_both

# Test: Empty memory/ directory (still a violation) → warning
test_memory_empty_dir() {
    setup_check_env
    mkdir -p "$PROJECT_DIR/memory"
    source "$CHECK_04"
    assert_contains "$WARNINGS" "memory/" "empty memory/ dir should still trigger warning"
}
run_test "MEMORY.md: empty memory/ dir triggers warning" test_memory_empty_dir

# ══════════════════════════════════════════════════════════════════════════════
# Check 2: Inbox staleness detection (05-stale-detection.sh)
# ══════════════════════════════════════════════════════════════════════════════

# Test: Empty inbox → no warning
test_inbox_stale_empty() {
    setup_check_env
    cat > "$CONFIG_REPO/cross-project/inbox.md" << 'EOF'
# Cross-Project Inbox
## Pending
EOF
    source "$CHECK_05"
    assert_not_contains "$WARNINGS" "Cross-project inbox:" "empty inbox should not warn"
}
run_test "Inbox staleness: empty inbox is silent" test_inbox_stale_empty

# Test: Recent items only → no warning
test_inbox_stale_recent() {
    setup_check_env
    local today
    today=$(date +%Y-%m-%d)
    cat > "$CONFIG_REPO/cross-project/inbox.md" << EOF
# Cross-Project Inbox
## Pending
- [ ] **proj1**: Task one. Source: session $today.
- [ ] **proj2**: Task two. Source: session $today.
EOF
    source "$CHECK_05"
    assert_not_contains "$WARNINGS" "Cross-project inbox:" "recent items should not warn"
}
run_test "Inbox staleness: all recent items is silent" test_inbox_stale_recent

# Test: 3+ items older than 7 days → warning
test_inbox_stale_old_items() {
    setup_check_env
    local old_date="2025-01-01"
    cat > "$CONFIG_REPO/cross-project/inbox.md" << EOF
# Cross-Project Inbox
## Pending
- [ ] **proj1**: Task one. Source: session $old_date.
- [ ] **proj2**: Task two. Source: session $old_date.
- [ ] **proj3**: Task three. Source: session $old_date.
EOF
    source "$CHECK_05"
    assert_contains "$WARNINGS" "Cross-project inbox:" "3+ stale items should warn"
    assert_contains "$WARNINGS" "older than 7 days" "warning should mention 7 days"
    assert_contains "$WARNINGS" "$old_date" "warning should show oldest date"
}
run_test "Inbox staleness: 3+ old items triggers warning" test_inbox_stale_old_items

# Test: 2 old items (below threshold) → no warning
test_inbox_stale_below_threshold() {
    setup_check_env
    local old_date="2025-01-01"
    cat > "$CONFIG_REPO/cross-project/inbox.md" << EOF
# Cross-Project Inbox
## Pending
- [ ] **proj1**: Task one. Source: session $old_date.
- [ ] **proj2**: Task two. Source: session $old_date.
EOF
    source "$CHECK_05"
    assert_not_contains "$WARNINGS" "[WARN] Cross-project inbox:" "2 stale items should not warn (threshold is 3)"
}
run_test "Inbox staleness: 2 old items below threshold" test_inbox_stale_below_threshold

# Test: Mix of old and recent — only count old ones
test_inbox_stale_mixed() {
    setup_check_env
    local old_date="2025-01-01"
    local today
    today=$(date +%Y-%m-%d)
    cat > "$CONFIG_REPO/cross-project/inbox.md" << EOF
# Cross-Project Inbox
## Pending
- [ ] **proj1**: Task one. Source: session $old_date.
- [ ] **proj2**: Task two. Source: session $today.
- [ ] **proj3**: Task three. Source: session $old_date.
- [ ] **proj4**: Task four. Source: session $old_date.
EOF
    source "$CHECK_05"
    assert_contains "$WARNINGS" "3 items older than 7 days" "should count only old items"
}
run_test "Inbox staleness: mixed old/recent counts correctly" test_inbox_stale_mixed

# Test: Completed items (- [x]) should be ignored
test_inbox_stale_ignores_completed() {
    setup_check_env
    local old_date="2025-01-01"
    cat > "$CONFIG_REPO/cross-project/inbox.md" << EOF
# Cross-Project Inbox
## Pending
- [x] **proj1**: Done. Source: session $old_date.
- [x] **proj2**: Done. Source: session $old_date.
- [x] **proj3**: Done. Source: session $old_date.
EOF
    source "$CHECK_05"
    assert_not_contains "$WARNINGS" "Cross-project inbox:" "completed items should not count"
}
run_test "Inbox staleness: completed items ignored" test_inbox_stale_ignores_completed

# Test: Missing inbox file → no warning
test_inbox_stale_missing_file() {
    setup_check_env
    rm -f "$CONFIG_REPO/cross-project/inbox.md"
    source "$CHECK_05"
    assert_not_contains "$WARNINGS" "Cross-project inbox:" "missing inbox should not warn"
}
run_test "Inbox staleness: missing file is silent" test_inbox_stale_missing_file

# ══════════════════════════════════════════════════════════════════════════════
# Check 3: Audit staleness detection (14-audit-staleness.sh)
# ══════════════════════════════════════════════════════════════════════════════

# Test: Recent audit → no message
test_audit_recent() {
    setup_check_env
    # Remove any daily gate marker
    rm -f /tmp/.audit-stale-check-* 2>/dev/null || true
    echo "$(date +%Y-%m-%d)" > "$HOME/.claude/.last-audit-date"
    source "$CHECK_14"
    assert_not_contains "$INBOX_MSG" "AUDIT_DUE" "recent audit should not trigger"
}
run_test "Audit staleness: recent audit is silent" test_audit_recent

# Test: Missing marker file → audit due
test_audit_missing_marker() {
    setup_check_env
    rm -f /tmp/.audit-stale-check-* 2>/dev/null || true
    rm -f "$HOME/.claude/.last-audit-date"
    source "$CHECK_14"
    assert_contains "$INBOX_MSG" "AUDIT_DUE" "missing marker should trigger audit due"
    assert_contains "$INBOX_MSG" "lrn" "should suggest running lrn"
}
run_test "Audit staleness: missing marker triggers due" test_audit_missing_marker

# Test: Old audit date (>7 days ago) → audit due
test_audit_old_date() {
    setup_check_env
    rm -f /tmp/.audit-stale-check-* 2>/dev/null || true
    echo "2025-01-01" > "$HOME/.claude/.last-audit-date"
    source "$CHECK_14"
    assert_contains "$INBOX_MSG" "AUDIT_DUE" "old audit date should trigger"
}
run_test "Audit staleness: old date triggers due" test_audit_old_date

# Test: Daily gate prevents duplicate runs
test_audit_daily_gate() {
    setup_check_env
    rm -f /tmp/.audit-stale-check-* 2>/dev/null || true
    rm -f "$HOME/.claude/.last-audit-date"
    # First run: should fire
    source "$CHECK_14"
    assert_contains "$INBOX_MSG" "AUDIT_DUE" "first run should trigger"
    # Second run: gate file exists, should not re-fire
    INBOX_MSG=""
    source "$CHECK_14"
    assert_not_contains "$INBOX_MSG" "AUDIT_DUE" "second run same day should be gated"
    # Clean up gate file
    rm -f /tmp/.audit-stale-check-* 2>/dev/null || true
}
run_test "Audit staleness: daily gate prevents duplicates" test_audit_daily_gate

# Test: Audit 6 days ago (within window) → no message
test_audit_within_window() {
    setup_check_env
    rm -f /tmp/.audit-stale-check-* 2>/dev/null || true
    local six_days_ago
    six_days_ago=$(date -d "6 days ago" +%Y-%m-%d 2>/dev/null || date -v-6d +%Y-%m-%d 2>/dev/null)
    echo "$six_days_ago" > "$HOME/.claude/.last-audit-date"
    source "$CHECK_14"
    assert_not_contains "$INBOX_MSG" "AUDIT_DUE" "6-day-old audit should not trigger"
}
run_test "Audit staleness: 6 days old is within window" test_audit_within_window

# Summary
echo ""
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed out of $TESTS_RUN"
[ "$TESTS_FAILED" -eq 0 ] && exit 0 || exit 1
