#!/usr/bin/env bash
# Tests for setup/scripts/clean-pending-files.sh
source "$(dirname "$0")/test-helpers.sh"

SCRIPT="$REPO_ROOT/setup/scripts/clean-pending-files.sh"

suite_header "clean-pending-files.sh (pending file cleanup)"

# ── Helpers ──────────────────────────────────────────────────────────────────

create_test_env() {
    local dir="$TEST_TMPDIR/project"
    mkdir -p "$dir/docs"
    cat > "$dir/backlog.md" << 'EOF'
# Backlog
## Open
- [ ] [P1] `CFG-31` **Mobile session fixes**: Handoff: `docs/pending-cfg31-mobile-session.md`.
- [ ] [P2] `CFG-11` **Music management**: Vision doc: `docs/pending-music-vision.md`.
EOF
    echo "$dir"
}

# ── Tests ────────────────────────────────────────────────────────────────────

test_list_mode_shows_all_pending() {
    local dir
    dir=$(create_test_env)

    echo "content" > "$dir/docs/pending-task-a.md"
    echo "content" > "$dir/docs/pending-task-b.md"
    touch -d "3 days ago" "$dir/docs/pending-task-a.md"

    local output
    output=$(bash "$SCRIPT" --list --project-dir "$dir" 2>&1)

    assert_contains "$output" "pending-task-a.md" "should list first pending file"
    assert_contains "$output" "pending-task-b.md" "should list second pending file"
}
run_test "list mode shows all pending files" test_list_mode_shows_all_pending

test_list_mode_shows_age() {
    local dir
    dir=$(create_test_env)

    echo "content" > "$dir/docs/pending-old.md"
    touch -d "5 days ago" "$dir/docs/pending-old.md"

    local output
    output=$(bash "$SCRIPT" --list --project-dir "$dir" 2>&1)

    assert_contains "$output" "5d" "should show age in days"
}
run_test "list mode shows file age" test_list_mode_shows_age

test_backlog_cross_check_tracked() {
    local dir
    dir=$(create_test_env)

    # This file IS referenced in backlog (CFG-31 references pending-cfg31-mobile-session.md)
    echo "content" > "$dir/docs/pending-cfg31-mobile-session.md"
    touch -d "3 days ago" "$dir/docs/pending-cfg31-mobile-session.md"

    local output
    output=$(bash "$SCRIPT" --list --project-dir "$dir" 2>&1)

    assert_contains "$output" "pending-cfg31-mobile-session.md" "should list the file"
    assert_contains "$output" "tracked" "should show tracked status"
}
run_test "backlog cross-check: tracked file marked as tracked" test_backlog_cross_check_tracked

test_backlog_cross_check_untracked() {
    local dir
    dir=$(create_test_env)

    # This file is NOT referenced in backlog
    echo "content" > "$dir/docs/pending-orphan.md"
    touch -d "3 days ago" "$dir/docs/pending-orphan.md"

    local output
    output=$(bash "$SCRIPT" --list --project-dir "$dir" 2>&1)

    assert_contains "$output" "pending-orphan.md" "should list the file"
    assert_contains "$output" "untracked" "should show untracked status"
}
run_test "backlog cross-check: untracked file marked as untracked" test_backlog_cross_check_untracked

test_summary_counts() {
    local dir
    dir=$(create_test_env)

    echo "x" > "$dir/docs/pending-cfg31-mobile-session.md"  # tracked
    echo "x" > "$dir/docs/pending-orphan-a.md"              # untracked
    echo "x" > "$dir/docs/pending-orphan-b.md"              # untracked
    touch -d "3 days ago" "$dir/docs/pending-cfg31-mobile-session.md"
    touch -d "3 days ago" "$dir/docs/pending-orphan-a.md"

    local output
    output=$(bash "$SCRIPT" --list --project-dir "$dir" 2>&1)

    assert_contains "$output" "3 pending" "should count total pending files"
}
run_test "summary shows correct total count" test_summary_counts

test_no_pending_files() {
    local dir
    dir=$(create_test_env)

    local output
    output=$(bash "$SCRIPT" --list --project-dir "$dir" 2>&1)

    assert_contains "$output" "No pending files" "should report no files found"
}
run_test "no pending files: clean report" test_no_pending_files

test_stale_only_flag() {
    local dir
    dir=$(create_test_env)

    echo "x" > "$dir/docs/pending-fresh.md"       # today
    echo "x" > "$dir/docs/pending-old.md"
    touch -d "3 days ago" "$dir/docs/pending-old.md"

    local output
    output=$(bash "$SCRIPT" --list --stale-only --project-dir "$dir" 2>&1)

    assert_contains "$output" "pending-old.md" "should list stale file"
    assert_not_contains "$output" "pending-fresh.md" "should NOT list fresh file"
}
run_test "stale-only flag filters to >2 day old files" test_stale_only_flag

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
