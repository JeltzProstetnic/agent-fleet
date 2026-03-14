#!/usr/bin/env bash
# Tests for inbox-archive.sh — auto-archival of completed [x] inbox items
source "$(dirname "$0")/test-helpers.sh"

ARCHIVE_SCRIPT="$REPO_ROOT/setup/scripts/inbox-archive.sh"

# Helper: create test inbox
create_inbox() {
    cat > "$TEST_TMPDIR/inbox.md" << 'INBOX'
# Cross-Project Inbox

Tasks are per-project. Each project picks up its own entry and deletes it after integrating.

## Pending

- [ ] **proj-a**: Open task one.
- [x] **proj-b**: Completed task. DONE.
- [ ] **proj-c**: Open task two with longer description that spans the line.
- [x] **proj-d**: Another completed task. DONE: verified 2026-03-10.
- [x] **proj-e**: Third completed. DONE.

- [ ] **proj-f**: Last open task.
INBOX
}

suite_header "Inbox Archive Tests"

test_strips_completed_items() {
    create_inbox
    bash "$ARCHIVE_SCRIPT" "$TEST_TMPDIR/inbox.md" "$TEST_TMPDIR/inbox-archive.md"
    assert_file_not_contains "$TEST_TMPDIR/inbox.md" '\- \[x\]' "inbox should have no [x] items" || return 1
    assert_file_contains "$TEST_TMPDIR/inbox.md" '\- \[ \]' "inbox should still have [ ] items" || return 1
}
run_test "strips completed items from inbox" test_strips_completed_items

test_preserves_open_items() {
    create_inbox
    bash "$ARCHIVE_SCRIPT" "$TEST_TMPDIR/inbox.md" "$TEST_TMPDIR/inbox-archive.md"
    assert_file_contains "$TEST_TMPDIR/inbox.md" "proj-a" || return 1
    assert_file_contains "$TEST_TMPDIR/inbox.md" "proj-c" || return 1
    assert_file_contains "$TEST_TMPDIR/inbox.md" "proj-f" || return 1
}
run_test "preserves all open items" test_preserves_open_items

test_archive_receives_completed() {
    create_inbox
    bash "$ARCHIVE_SCRIPT" "$TEST_TMPDIR/inbox.md" "$TEST_TMPDIR/inbox-archive.md"
    assert_file_contains "$TEST_TMPDIR/inbox-archive.md" "proj-b" || return 1
    assert_file_contains "$TEST_TMPDIR/inbox-archive.md" "proj-d" || return 1
    assert_file_contains "$TEST_TMPDIR/inbox-archive.md" "proj-e" || return 1
}
run_test "archive receives completed items" test_archive_receives_completed

test_archive_has_date_header() {
    create_inbox
    bash "$ARCHIVE_SCRIPT" "$TEST_TMPDIR/inbox.md" "$TEST_TMPDIR/inbox-archive.md"
    assert_file_contains "$TEST_TMPDIR/inbox-archive.md" "## Archived" "archive should have date header" || return 1
}
run_test "archive has date header" test_archive_has_date_header

test_preserves_header() {
    create_inbox
    bash "$ARCHIVE_SCRIPT" "$TEST_TMPDIR/inbox.md" "$TEST_TMPDIR/inbox-archive.md"
    assert_file_contains "$TEST_TMPDIR/inbox.md" "# Cross-Project Inbox" || return 1
    assert_file_contains "$TEST_TMPDIR/inbox.md" "## Pending" || return 1
}
run_test "preserves inbox header" test_preserves_header

test_no_completed_items_noop() {
    cat > "$TEST_TMPDIR/inbox.md" << 'INBOX'
# Cross-Project Inbox

## Pending

- [ ] **proj-a**: Open task.
INBOX
    bash "$ARCHIVE_SCRIPT" "$TEST_TMPDIR/inbox.md" "$TEST_TMPDIR/inbox-archive.md"
    # Archive should not be created if no completed items
    assert_file_not_exists "$TEST_TMPDIR/inbox-archive.md" "no archive when nothing to archive" || return 1
}
run_test "no-op when no completed items" test_no_completed_items_noop

test_appends_to_existing_archive() {
    create_inbox
    # Pre-populate archive
    cat > "$TEST_TMPDIR/inbox-archive.md" << 'ARCHIVE'
# Cross-Project Inbox — Archive

## Archived 2026-03-09

- [x] **old-proj**: Old completed task.
ARCHIVE
    bash "$ARCHIVE_SCRIPT" "$TEST_TMPDIR/inbox.md" "$TEST_TMPDIR/inbox-archive.md"
    assert_file_contains "$TEST_TMPDIR/inbox-archive.md" "old-proj" "should preserve existing archive" || return 1
    assert_file_contains "$TEST_TMPDIR/inbox-archive.md" "proj-b" "should append new items" || return 1
}
run_test "appends to existing archive" test_appends_to_existing_archive

test_multiline_completed_item() {
    cat > "$TEST_TMPDIR/inbox.md" << 'INBOX'
# Cross-Project Inbox

## Pending

- [x] **proj-a**: Completed with details.

  **What happened:** Long multi-line description
  that continues on the next indented line.

  **Resolution:** Fixed it.

- [ ] **proj-b**: Open task.
INBOX
    bash "$ARCHIVE_SCRIPT" "$TEST_TMPDIR/inbox.md" "$TEST_TMPDIR/inbox-archive.md"
    assert_file_not_contains "$TEST_TMPDIR/inbox.md" "proj-a" "completed item gone" || return 1
    assert_file_not_contains "$TEST_TMPDIR/inbox.md" "What happened" "continuation lines gone" || return 1
    assert_file_contains "$TEST_TMPDIR/inbox.md" "proj-b" "open item kept" || return 1
    assert_file_contains "$TEST_TMPDIR/inbox-archive.md" "proj-a" "archived" || return 1
    assert_file_contains "$TEST_TMPDIR/inbox-archive.md" "What happened" "continuation archived" || return 1
}
run_test "handles multi-line completed items" test_multiline_completed_item

test_reports_count() {
    create_inbox
    local output
    output=$(bash "$ARCHIVE_SCRIPT" "$TEST_TMPDIR/inbox.md" "$TEST_TMPDIR/inbox-archive.md")
    assert_contains "$output" "3" "should report number of archived items"
}
run_test "reports archived count" test_reports_count

test_empty_inbox_noop() {
    cat > "$TEST_TMPDIR/inbox.md" << 'INBOX'
# Cross-Project Inbox

## Pending

INBOX
    bash "$ARCHIVE_SCRIPT" "$TEST_TMPDIR/inbox.md" "$TEST_TMPDIR/inbox-archive.md"
    assert_file_not_exists "$TEST_TMPDIR/inbox-archive.md" || return 1
}
run_test "empty inbox is no-op" test_empty_inbox_noop

test_no_consecutive_blank_lines() {
    create_inbox
    bash "$ARCHIVE_SCRIPT" "$TEST_TMPDIR/inbox.md" "$TEST_TMPDIR/inbox-archive.md"
    # After removing [x] items, there should be no triple+ blank lines
    local triple_blanks
    triple_blanks=$(grep -cP '^\s*$' "$TEST_TMPDIR/inbox.md" || true)
    # Count consecutive blank lines — allow singles between groups, not doubles
    local consecutive
    consecutive=$(awk '/^$/{c++; if(c>2) found=1} /^./{c=0} END{print found+0}' "$TEST_TMPDIR/inbox.md")
    assert_eq "0" "$consecutive" "no triple+ consecutive blank lines"
}
run_test "no excessive blank lines after cleanup" test_no_consecutive_blank_lines

suite_summary
