#!/usr/bin/env bash
# Tests for setup/scripts/manage-pending.sh — pending file lifecycle engine
source "$(dirname "$0")/test-helpers.sh"

SCRIPT="$REPO_ROOT/setup/scripts/manage-pending.sh"

suite_header "manage-pending.sh (pending file lifecycle)"

# ── Helpers ──────────────────────────────────────────────────────────────────

# Create a pending file with optional Action header and age
create_pending_file() {
    local dir="$1"       # docs/ directory
    local name="$2"      # filename (without path)
    local action="${3:-}" # action header value
    local age_days="${4:-0}" # age in days

    mkdir -p "$dir"
    local filepath="$dir/$name"

    if [[ -n "$action" ]]; then
        printf "# %s\nAction: %s\n\nContent here.\n" "$name" "$action" > "$filepath"
    else
        printf "# %s\n\nNo action header.\n" "$name" > "$filepath"
    fi

    if [[ "$age_days" -gt 0 ]]; then
        local past_ts=$(( $(date +%s) - (age_days * 86400) ))
        touch -d "@$past_ts" "$filepath"
    fi
}

# Create a backlog file with items
create_backlog() {
    local project_dir="$1"
    shift
    # Remaining args are lines to add
    {
        echo "# Backlog"
        echo ""
        for line in "$@"; do
            echo "$line"
        done
    } > "$project_dir/backlog.md"
}

# ── report mode ──────────────────────────────────────────────────────────────

test_report_lists_all_files() {
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$project_dir/docs"

    create_pending_file "$project_dir/docs" "pending-foo.md" "defer" 0
    create_pending_file "$project_dir/docs" "pending-bar.md" "act" 3
    create_pending_file "$project_dir/docs" "pending-baz.md" "" 0

    local output
    output=$(bash "$SCRIPT" report --project-dir "$project_dir" 2>&1)

    assert_contains "$output" "pending-foo.md" "should list foo"
    assert_contains "$output" "pending-bar.md" "should list bar"
    assert_contains "$output" "pending-baz.md" "should list baz"
}
run_test "report: lists all pending files" test_report_lists_all_files

test_report_shows_action_type() {
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$project_dir/docs"

    create_pending_file "$project_dir/docs" "pending-foo.md" "defer" 0
    create_pending_file "$project_dir/docs" "pending-bar.md" "act" 0

    local output
    output=$(bash "$SCRIPT" report --project-dir "$project_dir" 2>&1)

    assert_contains "$output" "defer" "should show defer action"
    assert_contains "$output" "act" "should show act action"
}
run_test "report: shows action type" test_report_shows_action_type

test_report_shows_backlog_tracking() {
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$project_dir/docs"

    create_pending_file "$project_dir/docs" "pending-foo.md" "defer" 0
    create_backlog "$project_dir" \
        "- [ ] [P2] \`CFG-10\` **Some task**: Reference pending-foo.md"

    local output
    output=$(bash "$SCRIPT" report --project-dir "$project_dir" 2>&1)

    assert_contains "$output" "tracked" "should show tracked status"
}
run_test "report: shows backlog tracking status" test_report_shows_backlog_tracking

test_report_shows_untracked() {
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$project_dir/docs"

    create_pending_file "$project_dir/docs" "pending-orphan.md" "defer" 0
    create_backlog "$project_dir" \
        "- [ ] [P2] \`CFG-10\` **Some other task**: No reference to orphan"

    local output
    output=$(bash "$SCRIPT" report --project-dir "$project_dir" 2>&1)

    assert_contains "$output" "untracked" "should show untracked status"
}
run_test "report: shows untracked files" test_report_shows_untracked

test_report_no_files() {
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$project_dir/docs"

    local output
    output=$(bash "$SCRIPT" report --project-dir "$project_dir" 2>&1)

    assert_contains "$output" "No pending files" "should report no files"
}
run_test "report: no pending files" test_report_no_files

test_report_no_docs_dir() {
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$project_dir"

    local output
    output=$(bash "$SCRIPT" report --project-dir "$project_dir" 2>&1)

    assert_contains "$output" "No pending files" "should report no files when docs/ missing"
}
run_test "report: no docs directory" test_report_no_docs_dir

# ── auto-promote ─────────────────────────────────────────────────────────────

test_auto_promote_warns_old_untracked() {
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$project_dir/docs"

    create_pending_file "$project_dir/docs" "pending-old.md" "defer" 15
    create_backlog "$project_dir" "# empty backlog"

    local output
    output=$(bash "$SCRIPT" --auto-promote --project-dir "$project_dir" 2>&1)

    assert_contains "$output" "PROMOTE" "should warn about promotion needed"
    assert_contains "$output" "pending-old.md" "should name the file"
}
run_test "auto-promote: warns on untracked defer >14d" test_auto_promote_warns_old_untracked

test_auto_promote_skips_tracked() {
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$project_dir/docs"

    create_pending_file "$project_dir/docs" "pending-tracked.md" "defer" 20
    create_backlog "$project_dir" \
        "- [ ] [P2] \`CFG-50\` **Task**: See pending-tracked.md"

    local output
    output=$(bash "$SCRIPT" --auto-promote --project-dir "$project_dir" 2>&1)

    assert_not_contains "$output" "PROMOTE" "should not warn about tracked files"
}
run_test "auto-promote: skips tracked defer files" test_auto_promote_skips_tracked

test_auto_promote_skips_young() {
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$project_dir/docs"

    create_pending_file "$project_dir/docs" "pending-new.md" "defer" 5
    create_backlog "$project_dir" "# empty backlog"

    local output
    output=$(bash "$SCRIPT" --auto-promote --project-dir "$project_dir" 2>&1)

    assert_not_contains "$output" "PROMOTE" "should not warn about young files"
}
run_test "auto-promote: skips defer files <14d" test_auto_promote_skips_young

test_auto_promote_skips_non_defer() {
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$project_dir/docs"

    create_pending_file "$project_dir/docs" "pending-urgent.md" "act" 20
    create_backlog "$project_dir" "# empty backlog"

    local output
    output=$(bash "$SCRIPT" --auto-promote --project-dir "$project_dir" 2>&1)

    assert_not_contains "$output" "PROMOTE" "should not warn about non-defer files"
}
run_test "auto-promote: skips non-defer action types" test_auto_promote_skips_non_defer

# ── auto-clean ───────────────────────────────────────────────────────────────

test_auto_clean_deletes_completed() {
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$project_dir/docs"

    create_pending_file "$project_dir/docs" "pending-done-task.md" "defer" 5
    create_backlog "$project_dir" \
        "- [x] [P2] \`CFG-77\` **Completed task**: See pending-done-task.md"

    bash "$SCRIPT" --auto-clean --project-dir "$project_dir" 2>&1

    assert_file_not_exists "$project_dir/docs/pending-done-task.md" "should delete file for completed backlog item"
}
run_test "auto-clean: deletes file when backlog item is [x]" test_auto_clean_deletes_completed

test_auto_clean_keeps_open() {
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$project_dir/docs"

    create_pending_file "$project_dir/docs" "pending-open-task.md" "defer" 5
    create_backlog "$project_dir" \
        "- [ ] [P2] \`CFG-88\` **Open task**: See pending-open-task.md"

    bash "$SCRIPT" --auto-clean --project-dir "$project_dir" 2>&1

    assert_file_exists "$project_dir/docs/pending-open-task.md" "should keep file for open backlog item"
}
run_test "auto-clean: keeps file when backlog item is [ ]" test_auto_clean_keeps_open

test_auto_clean_keeps_untracked() {
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$project_dir/docs"

    create_pending_file "$project_dir/docs" "pending-orphan.md" "defer" 5
    create_backlog "$project_dir" "# no references"

    bash "$SCRIPT" --auto-clean --project-dir "$project_dir" 2>&1

    assert_file_exists "$project_dir/docs/pending-orphan.md" "should keep untracked files (can't determine completion)"
}
run_test "auto-clean: keeps untracked files" test_auto_clean_keeps_untracked

test_auto_clean_reports_deletions() {
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$project_dir/docs"

    create_pending_file "$project_dir/docs" "pending-cleaned.md" "defer" 5
    create_backlog "$project_dir" \
        "- [x] [P1] \`CFG-99\` **Done thing**: pending-cleaned.md"

    local output
    output=$(bash "$SCRIPT" --auto-clean --project-dir "$project_dir" 2>&1)

    assert_contains "$output" "CLEANED" "should report cleanup"
    assert_contains "$output" "pending-cleaned.md" "should name the cleaned file"
}
run_test "auto-clean: reports deletions" test_auto_clean_reports_deletions

test_auto_clean_handles_multiple_backlog_refs() {
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$project_dir/docs"

    # File referenced by two backlog items — one done, one open
    create_pending_file "$project_dir/docs" "pending-multi.md" "defer" 5
    create_backlog "$project_dir" \
        "- [x] [P1] \`CFG-10\` **Part 1 done**: pending-multi.md" \
        "- [ ] [P1] \`CFG-11\` **Part 2 open**: pending-multi.md"

    bash "$SCRIPT" --auto-clean --project-dir "$project_dir" 2>&1

    assert_file_exists "$project_dir/docs/pending-multi.md" "should keep file if any referencing backlog item is open"
}
run_test "auto-clean: keeps file if any referencing backlog item is open" test_auto_clean_handles_multiple_backlog_refs

# ── dry-run ──────────────────────────────────────────────────────────────────

test_dry_run_no_deletions() {
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$project_dir/docs"

    create_pending_file "$project_dir/docs" "pending-keep-me.md" "defer" 5
    create_backlog "$project_dir" \
        "- [x] [P1] \`CFG-55\` **Done**: pending-keep-me.md"

    local output
    output=$(bash "$SCRIPT" --auto-clean --dry-run --project-dir "$project_dir" 2>&1)

    assert_file_exists "$project_dir/docs/pending-keep-me.md" "dry-run should not delete"
    assert_contains "$output" "pending-keep-me.md" "should still report"
    assert_contains "$output" "dry-run" "should indicate dry-run mode"
}
run_test "dry-run: does not delete files" test_dry_run_no_deletions

# ── combined modes ───────────────────────────────────────────────────────────

test_combined_promote_and_clean() {
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$project_dir/docs"

    # One old untracked (should promote-warn)
    create_pending_file "$project_dir/docs" "pending-old-orphan.md" "defer" 20
    # One tracked+completed (should clean)
    create_pending_file "$project_dir/docs" "pending-done.md" "defer" 3
    # One tracked+open (should keep)
    create_pending_file "$project_dir/docs" "pending-active.md" "defer" 3

    create_backlog "$project_dir" \
        "- [x] [P1] \`CFG-60\` **Done**: pending-done.md" \
        "- [ ] [P2] \`CFG-61\` **Active**: pending-active.md"

    local output
    output=$(bash "$SCRIPT" --auto-promote --auto-clean --project-dir "$project_dir" 2>&1)

    assert_contains "$output" "PROMOTE" "should warn about old orphan"
    assert_contains "$output" "CLEANED" "should clean done file"
    assert_file_not_exists "$project_dir/docs/pending-done.md" "done file deleted"
    assert_file_exists "$project_dir/docs/pending-active.md" "active file kept"
    assert_file_exists "$project_dir/docs/pending-old-orphan.md" "orphan kept (promote is warning only)"
}
run_test "combined: auto-promote + auto-clean together" test_combined_promote_and_clean

# ── edge cases ───────────────────────────────────────────────────────────────

test_no_backlog_file() {
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$project_dir/docs"

    create_pending_file "$project_dir/docs" "pending-no-backlog.md" "defer" 5

    local output
    output=$(bash "$SCRIPT" report --project-dir "$project_dir" 2>&1)

    assert_contains "$output" "untracked" "all files untracked when no backlog"
}
run_test "edge: no backlog.md file" test_no_backlog_file

test_action_header_case_insensitive() {
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$project_dir/docs"

    # Action header with mixed case
    printf "# Test\nAction: Defer\n\nContent.\n" > "$project_dir/docs/pending-case.md"

    local output
    output=$(bash "$SCRIPT" report --project-dir "$project_dir" 2>&1)

    assert_contains "$output" "defer" "should normalize action to lowercase"
}
run_test "edge: action header case insensitive" test_action_header_case_insensitive

test_backward_compat_wrapper() {
    # manage-pending.sh report should produce output similar to clean-pending-files.sh --list
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$project_dir/docs"

    create_pending_file "$project_dir/docs" "pending-compat.md" "defer" 0
    create_backlog "$project_dir" "# empty"

    local output
    output=$(bash "$SCRIPT" report --project-dir "$project_dir" 2>&1)

    # Should have a summary line with count
    assert_contains "$output" "pending file" "should show summary with count"
}
run_test "backward compat: report includes summary" test_backward_compat_wrapper

# ── summary ──────────────────────────────────────────────────────────────────
suite_summary
