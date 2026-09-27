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

# CFG-482: the fleet writes the header as an HTML comment so it stays invisible
# in rendered markdown. get_action() only matched the bare form, so every real
# file reported "unknown".
test_action_header_comment_form() {
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$project_dir/docs"

    printf "<!-- Action: defer -->\n# Test\n\nContent.\n" > "$project_dir/docs/pending-comment.md"

    local output
    output=$(bash "$SCRIPT" report --project-dir "$project_dir" 2>&1)

    assert_contains "$output" "defer" "comment-form Action header must be parsed" || return 1
    assert_not_contains "$output" "unknown" "comment-form file must not report unknown action" || return 1
}
run_test "edge: comment-form <!-- Action: x --> header (CFG-482)" test_action_header_comment_form

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

# ── stale-check ──────────────────────────────────────────────────────────────

# Create a docs/session-log.md with arbitrary content lines
create_session_log() {
    local project_dir="$1"
    shift
    mkdir -p "$project_dir/docs"
    {
        echo "# Session Log"
        echo ""
        for line in "$@"; do
            echo "$line"
        done
    } > "$project_dir/docs/session-log.md"
}

# Create a Tracked-by pending file (Action + Tracked-by header)
create_tracked_pending() {
    local dir="$1"        # docs/ directory
    local name="$2"       # filename
    local action="$3"     # action header
    local tracked="$4"    # Tracked-by line value
    mkdir -p "$dir"
    printf "# %s\nAction: %s\nTracked-by: %s\n\nContent.\n" \
        "$name" "$action" "$tracked" > "$dir/$name"
}

# Init a throwaway git repo in the project dir for commit-evidence tests
init_project_git() {
    local project_dir="$1"
    mkdir -p "$project_dir"
    (
        cd "$project_dir"
        git init -b main >/dev/null 2>&1
        git config user.email "test@test.com"
        git config user.name "Test"
        echo "init" > .gitkeep
        git add .gitkeep
        git commit -m "Initial commit" >/dev/null 2>&1
    )
}

# Add a commit with an explicit message (subject + optional body) to a repo
add_named_commit() {
    local project_dir="$1"
    local subject="$2"
    local body="${3:-}"
    local filename="commit-file-$RANDOM-$RANDOM.txt"
    (
        cd "$project_dir"
        echo "change" > "$filename"
        git add "$filename"
        if [[ -n "$body" ]]; then
            git commit -m "$subject" -m "$body" >/dev/null 2>&1
        else
            git commit -m "$subject" >/dev/null 2>&1
        fi
    )
}

# (1) all Tracked-by PRNs are [x] in backlog → flagged STALE
test_stale_all_prns_closed() {
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$project_dir/docs"

    create_tracked_pending "$project_dir/docs" "pending-feature-x.md" "act" "CFG-418"
    create_backlog "$project_dir" \
        "- [x] [P1] \`CFG-418\` **Feature X**: shipped"

    local output
    output=$(bash "$SCRIPT" --stale-check --project-dir "$project_dir" 2>&1)

    assert_contains "$output" "STALE: pending-feature-x.md" "should flag file with all PRNs closed" || return 1
    assert_contains "$output" "all PRNs closed" "reason should be all PRNs closed"
}
run_test "stale-check: all Tracked-by PRNs [x] → STALE" test_stale_all_prns_closed

# (2)+(3) CFG-620: the prose heuristic is GONE. A session-log line saying
# "shipped (commit …)" or a fix commit citing the filename used to flag a
# no-PRN file as STALE — that guess was wrong every recorded time (a pending
# file documenting shipped work while tracking open work is the normal case).
# Such a file is reported as UNTRACKED — a different problem with a different
# action (file a backlog item, add the header) — never as "already shipped".
# These two tests previously asserted the STALE flag; revised, not extended.
test_stale_no_prn_session_log_shipped() {
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$project_dir/docs"

    create_tracked_pending "$project_dir/docs" "pending-rca-stage5-variety-20260607.md" "act" \
        "(file PRN-NNNN per fix when user assigns priorities)"
    create_session_log "$project_dir" \
        "## Session 99 — 2026-06-08" \
        "- S5 gradual variety decay RCA — shuffled-bag fix shipped (commit 0114ac9, 129 tests green)"

    local output
    output=$(bash "$SCRIPT" --stale-check --project-dir "$project_dir" 2>&1)

    assert_not_contains "$output" "STALE: pending-rca-stage5-variety-20260607.md" \
        "session-log prose is not completion evidence" || return 1
    assert_contains "$output" "UNTRACKED: pending-rca-stage5-variety-20260607.md" \
        "a placeholder Tracked-by is reported as untracked"
}
run_test "stale-check: no-PRN + session-log 'shipped' prose → UNTRACKED, never STALE" test_stale_no_prn_session_log_shipped

test_stale_no_prn_feat_commit_cites_file() {
    local project_dir="$TEST_TMPDIR/project"
    init_project_git "$project_dir"
    mkdir -p "$project_dir/docs"

    create_tracked_pending "$project_dir/docs" "pending-shuffled-bag-fix.md" "present" \
        "(this file IS the plan)"
    add_named_commit "$project_dir" \
        "fix(goonvid): shuffled-bag clip selection" \
        "Full RCA: docs/pending-shuffled-bag-fix.md"

    local output
    output=$(bash "$SCRIPT" --stale-check --project-dir "$project_dir" 2>&1)

    assert_not_contains "$output" "STALE: pending-shuffled-bag-fix.md" \
        "a commit citing the file is not completion evidence" || return 1
    assert_contains "$output" "UNTRACKED: pending-shuffled-bag-fix.md" \
        "no real Tracked-by → untracked"
}
run_test "stale-check: no-PRN + fix commit citing filename → UNTRACKED, never STALE" test_stale_no_prn_feat_commit_cites_file

# CFG-620 root cause: every real pending file writes `<!-- Tracked-by: … -->`,
# which the bare-form parser never matched — so every real file fell through
# to the prose heuristic. The exact false positive: open IDs in the comment
# form + a session-log line that reads as shipped.
test_stale_comment_form_tracked_by_open_not_flagged() {
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$project_dir/docs"

    printf '<!-- Action: act -->\n<!-- Tracked-by: CFG-602, CFG-603 -->\n# lrn audit\nfix shipped (commit abcdef1), deployed.\n' \
        > "$project_dir/docs/pending-lrn-audit-2026-09-15.md"
    create_backlog "$project_dir" \
        "- [ ] [P2] \`CFG-602\` **Open**: still open" \
        "- [ ] [P2] \`CFG-603\` **Open too**: still open"
    create_session_log "$project_dir" \
        "- lrn audit findings shipped (commit abcdef1), deployed to all machines"

    local output
    output=$(bash "$SCRIPT" --stale-check --project-dir "$project_dir" 2>&1)

    assert_not_contains "$output" "STALE:" "open comment-form IDs → not stale, whatever the prose says" || return 1
    assert_not_contains "$output" "UNTRACKED:" "comment-form Tracked-by IS tracking"
}
run_test "stale-check (CFG-620): comment-form Tracked-by with open IDs is never stale" test_stale_comment_form_tracked_by_open_not_flagged

test_stale_comment_form_all_closed_flagged() {
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$project_dir/docs"

    printf '<!-- Action: present -->\n<!-- Tracked-by: CFG-610, CFG-611 -->\n# done\n' \
        > "$project_dir/docs/pending-all-done.md"
    create_backlog "$project_dir" \
        "- [x] [P2] \`CFG-610\` **Done**: closed" \
        "- [x] [P3] \`CFG-611\` **Done**: closed"

    local output
    output=$(bash "$SCRIPT" --stale-check --project-dir "$project_dir" 2>&1)

    assert_contains "$output" "STALE: pending-all-done.md" || return 1
    assert_contains "$output" "CFG-610" "the closed IDs are cited as the evidence" || return 1
    assert_contains "$output" "CFG-611"
}
run_test "stale-check (CFG-620): comment-form Tracked-by, every ID [x] → STALE citing the IDs" test_stale_comment_form_all_closed_flagged

# [?] = awaiting live proof, [>] = in progress: both are OPEN for this purpose.
test_stale_question_and_progress_markers_not_closed() {
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$project_dir/docs"

    create_tracked_pending "$project_dir/docs" "pending-awaiting-proof.md" "act" "CFG-620, CFG-621"
    create_tracked_pending "$project_dir/docs" "pending-in-progress.md" "act" "CFG-622"
    create_backlog "$project_dir" \
        "- [x] [P1] \`CFG-620\` **Done**: closed" \
        "- [?] [P1] \`CFG-621\` **Awaiting live proof**: not yet" \
        "- [>] [P1] \`CFG-622\` **In progress**: running"

    local output
    output=$(bash "$SCRIPT" --stale-check --project-dir "$project_dir" 2>&1)

    assert_not_contains "$output" "STALE: pending-awaiting-proof.md" "[?] is not closed" || return 1
    assert_not_contains "$output" "STALE: pending-in-progress.md" "[>] is not closed"
}
run_test "stale-check (CFG-620): [?] and [>] items count as open" test_stale_question_and_progress_markers_not_closed

# An ID quoted inside ANOTHER closed item's text (CFG-597's closed line cites
# `CFG-695`) must not count as that ID being closed — only its own line does.
test_stale_id_cited_in_other_closed_item_not_closed() {
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$project_dir/docs"

    create_tracked_pending "$project_dir/docs" "pending-consent.md" "act" "CFG-695"
    create_backlog "$project_dir" \
        "- [x] [P0] \`CFG-597\` **CLOSED by hook**; the failure mode is tracked as \`CFG-695\`." \
        "- [ ] [P1] \`CFG-695\` **Blocked-on-consent items sit dead**: open"

    local output
    output=$(bash "$SCRIPT" --stale-check --project-dir "$project_dir" 2>&1)

    assert_not_contains "$output" "STALE: pending-consent.md" "an ID is closed only by its OWN [x] line"
}
run_test "stale-check (CFG-620): ID mentioned in another closed item's text is not closed" test_stale_id_cited_in_other_closed_item_not_closed

test_stale_mixed_closed_and_missing_not_flagged() {
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$project_dir/docs"

    create_tracked_pending "$project_dir/docs" "pending-mixed.md" "act" "CFG-630, AIW-257"
    create_backlog "$project_dir" \
        "- [x] [P1] \`CFG-630\` **Done**: closed"
    # AIW-257 lives in another project's backlog → unresolvable here → open

    local output
    output=$(bash "$SCRIPT" --stale-check --project-dir "$project_dir" 2>&1)

    assert_not_contains "$output" "STALE: pending-mixed.md" "an ID this backlog cannot resolve is not closed"
}
run_test "stale-check (CFG-620): an ID missing from this backlog keeps the file live" test_stale_mixed_closed_and_missing_not_flagged

# ── successor pointers (CFG-620, fourth instance) ─────────────────────────────
# A pending file that says it was superseded by / carried forward into another
# file must have that file exist — a dangling pointer is a data-loss signal
# that reads as tidiness. Checked for EVERY action, reference included (the
# real case was a demoted reference file).
test_dangling_successor_flagged() {
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$project_dir/docs"

    printf '<!-- Action: reference -->\n<!-- SUPERSEDED 2026-09-11 by docs/pending-next-session-2026-09-11.md, which is tagged present.\n     carried forward there verbatim. -->\n<!-- Tracked-by: CFG-433 -->\n# old\n' \
        > "$project_dir/docs/pending-next-session-2026-09-10.md"
    create_backlog "$project_dir" "- [ ] [P1] \`CFG-433\` **Open**: open"

    local output
    output=$(bash "$SCRIPT" --stale-check --project-dir "$project_dir" 2>&1)

    assert_contains "$output" "DANGLING: pending-next-session-2026-09-10.md" "missing successor is flagged" || return 1
    assert_contains "$output" "pending-next-session-2026-09-11.md" "the missing successor is named" || return 1
    assert_not_contains "$output" "STALE:" "a dangling pointer is not staleness"
}
run_test "stale-check (CFG-620): supersession pointer to a missing file → DANGLING" test_dangling_successor_flagged

test_existing_successor_and_predecessor_not_flagged() {
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$project_dir/docs"

    printf '<!-- Action: reference -->\n<!-- Superseded 2026-09-21 by docs/pending-next-session-2026-09-21b.md. -->\n' \
        > "$project_dir/docs/pending-next-session-2026-09-21.md"
    # The successor exists, and it names its (deleted) PREDECESSOR — that is fine.
    printf '<!-- Action: present -->\n<!-- Tracked-by: CFG-551 -->\n**Supersedes:** docs/pending-inbox-triage-2026-08-07.md (deleted after absorption)\n' \
        > "$project_dir/docs/pending-next-session-2026-09-21b.md"
    create_backlog "$project_dir" "- [ ] [P1] \`CFG-551\` **Open**: open"

    local output
    output=$(bash "$SCRIPT" --stale-check --project-dir "$project_dir" 2>&1)

    assert_not_contains "$output" "DANGLING:" "existing successor / missing predecessor are both fine"
}
run_test "stale-check (CFG-620): existing successor and a missing predecessor are not dangling" test_existing_successor_and_predecessor_not_flagged

# The successor must be the OBJECT of the pointer phrase. Generic prose that
# happens to contain "moved to" / "successor" and names some other, deleted
# pending file later on the same line is not a supersession pointer — reading
# it as one reports "possible data loss" for a predecessor that was resolved.
test_generic_prose_mentioning_deleted_file_not_dangling() {
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$project_dir/docs"

    cat > "$project_dir/docs/pending-handover.md" << 'EOF'
<!-- Action: reference -->
<!-- Tracked-by: CFG-700 -->
- Step 2 moved to backlog `CFG-700`; the old notes in pending-step1-notes.md were deleted once closed.
- No successor file needed; pending-old-plan.md was resolved and removed per protocol.
- Carried forward into `docs/pending-real-successor.md` verbatim.
EOF
    create_backlog "$project_dir" "- [ ] [P1] \`CFG-700\` **Open**: open"

    local output
    output=$(bash "$SCRIPT" --stale-check --project-dir "$project_dir" 2>&1)

    assert_not_contains "$output" "pending-step1-notes.md" "'moved to backlog …' does not point at a later file" || return 1
    assert_not_contains "$output" "pending-old-plan.md" "'No successor file needed; X' does not point at X" || return 1
    assert_contains "$output" "DANGLING: pending-handover.md → pending-real-successor.md" \
        "a real pointer (phrase + file, backticks and docs/ allowed) is still caught"
}
run_test "stale-check (CFG-620): generic prose naming a deleted file is not DANGLING" test_generic_prose_mentioning_deleted_file_not_dangling


# (4) TRUE NEGATIVE: act + open [ ] PRN + no shipped line → NOT flagged
test_stale_true_negative_open_prn() {
    local project_dir="$TEST_TMPDIR/project"
    init_project_git "$project_dir"
    mkdir -p "$project_dir/docs"

    create_tracked_pending "$project_dir/docs" "pending-normal-mode-config.md" "act" "PRN-1266"
    create_backlog "$project_dir" \
        "- [ ] [P2] \`PRN-1266\` **Normal mode config**: still open"
    create_session_log "$project_dir" \
        "## Session 100 — 2026-06-09" \
        "- Worked on unrelated things"

    local output
    output=$(bash "$SCRIPT" --stale-check --project-dir "$project_dir" 2>&1)

    assert_not_contains "$output" "STALE: pending-normal-mode-config.md" \
        "genuinely-open file must NOT be flagged stale"
}
run_test "stale-check: open [ ] PRN + no shipped → NOT flagged (true negative)" test_stale_true_negative_open_prn

# (5) reference/defer file with closed PRN → NOT flagged (only act/present reconcile)
test_stale_skips_non_act_present() {
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$project_dir/docs"

    create_tracked_pending "$project_dir/docs" "pending-ref-done.md" "reference" "CFG-500"
    create_tracked_pending "$project_dir/docs" "pending-defer-done.md" "defer" "CFG-501"
    create_backlog "$project_dir" \
        "- [x] [P1] \`CFG-500\` **Ref done**: closed" \
        "- [x] [P1] \`CFG-501\` **Defer done**: closed"

    local output
    output=$(bash "$SCRIPT" --stale-check --project-dir "$project_dir" 2>&1)

    assert_not_contains "$output" "STALE: pending-ref-done.md" "reference files are not reconciled" || return 1
    assert_not_contains "$output" "STALE: pending-defer-done.md" "defer files are not reconciled"
}
run_test "stale-check: reference/defer files not reconciled" test_stale_skips_non_act_present

# (6) no git/backlog/session-log present → exit 0, not flagged
test_stale_no_evidence_sources_clean() {
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$project_dir/docs"

    create_tracked_pending "$project_dir/docs" "pending-lonely.md" "act" "CFG-600"
    # No backlog.md, no session-log.md, no .git

    local rc=0
    local output
    output=$(bash "$SCRIPT" --stale-check --project-dir "$project_dir" 2>&1) || rc=$?

    assert_eq "0" "$rc" "stale-check must always exit 0 (fail-safe)" || return 1
    assert_not_contains "$output" "STALE: pending-lonely.md" \
        "no evidence sources → file treated CLEAN"
}
run_test "stale-check: no git/backlog/session-log → exit 0, not flagged" test_stale_no_evidence_sources_clean

# (7) literal PRN-NNNN placeholder not counted as a real PRN
test_stale_placeholder_prn_not_counted() {
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$project_dir/docs"

    # Tracked-by is the literal placeholder PRN-NNNN; backlog has a [x] PRN-NNNN
    # line (which must NOT count, since PRN-NNNN is a placeholder, not a real PRN).
    create_tracked_pending "$project_dir/docs" "pending-placeholder.md" "act" "PRN-NNNN"
    create_backlog "$project_dir" \
        "- [x] [P1] \`PRN-NNNN\` **Placeholder**: bogus"
    # No session-log, no git → only Signal 1 could match, and it must not.

    local output
    output=$(bash "$SCRIPT" --stale-check --project-dir "$project_dir" 2>&1)

    assert_not_contains "$output" "STALE: pending-placeholder.md" \
        "literal PRN-NNNN placeholder is not a real PRN → not flagged via Signal 1"
}
run_test "stale-check: literal PRN-NNNN placeholder not counted" test_stale_placeholder_prn_not_counted

# clean files emit nothing at all
test_stale_clean_emits_nothing() {
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$project_dir/docs"

    create_tracked_pending "$project_dir/docs" "pending-open.md" "act" "CFG-700"
    create_backlog "$project_dir" \
        "- [ ] [P1] \`CFG-700\` **Open**: still going"

    local output
    output=$(bash "$SCRIPT" --stale-check --project-dir "$project_dir" 2>&1)

    assert_not_contains "$output" "STALE:" "clean files emit no STALE line"
}
run_test "stale-check: clean files emit nothing" test_stale_clean_emits_nothing

# CFG-665: the SessionEnd hook's Auto-sync commit body lists every path it swept.
# A live, unshipped handoff swept into one is listed there — that is a record
# of the sweep, not evidence the work shipped. Counting it hid the handoff from
# ACT_PENDING at every later SessionStart (git log --all: forever).
test_stale_auto_sync_sweep_is_not_shipped_evidence() {
    local project_dir="$TEST_TMPDIR/project"
    init_project_git "$project_dir"
    mkdir -p "$project_dir/docs"
    create_tracked_pending "$project_dir/docs" "pending-live-handoff.md" "act" \
        "(this file IS the plan)"
    add_named_commit "$project_dir" "Auto-sync: 2026-09-25 12:00:00 UTC" \
        "Swept by the SessionEnd hook from project: 1 file(s)
  - docs/pending-live-handoff.md"

    local output
    output=$(bash "$SCRIPT" --stale-check --project-dir "$project_dir" 2>&1)
    assert_not_contains "$output" "STALE: pending-live-handoff.md" \
        "a file listed in an Auto-sync sweep body has not shipped"
}
run_test "stale-check: an Auto-sync commit listing the file is not shipped evidence (CFG-665)" test_stale_auto_sync_sweep_is_not_shipped_evidence

# Over-blocking control for the sweep exclusion. On fix/shutdown this asserted
# that a real commit citing an untracked file made it STALE. CFG-620 (merged
# beside it) retired commit citations as --stale-check evidence altogether:
# the backlog state of the file's own Tracked-by IDs is the only signal, and a
# file with no real Tracked-by is UNTRACKED, never STALE (see
# test_stale_no_prn_feat_commit_cites_file). The control keeps its purpose
# under that rule: a sweep beside the real evidence must not hide it. The
# commit-evidence form of this control lives in test-pending-demote.sh, where
# commit citations are still a signal.
test_stale_real_commit_still_counts_beside_a_sweep() {
    local project_dir="$TEST_TMPDIR/project"
    init_project_git "$project_dir"
    mkdir -p "$project_dir/docs"
    create_tracked_pending "$project_dir/docs" "pending-live-handoff.md" "act" \
        "(this file IS the plan)"
    create_tracked_pending "$project_dir/docs" "pending-done-work.md" "act" "CFG-777"
    create_backlog "$project_dir" "- [x] [P1] \`CFG-777\` **Done**: closed"
    add_named_commit "$project_dir" "Auto-sync: 2026-09-25 12:00:00 UTC" \
        "Swept by the SessionEnd hook from project: 2 file(s)
  - docs/pending-live-handoff.md
  - docs/pending-done-work.md"
    add_named_commit "$project_dir" "docs: close the handoff" \
        "Shipped; see docs/pending-live-handoff.md"

    local output
    output=$(bash "$SCRIPT" --stale-check --project-dir "$project_dir" 2>&1)
    assert_contains "$output" "STALE: pending-done-work.md" \
        "closed Tracked-by IDs still make a swept file STALE — the sweep hides nothing" || return 1
    assert_not_contains "$output" "STALE: pending-live-handoff.md" \
        "a commit citing an untracked file is not completion evidence (CFG-620)" || return 1
    assert_contains "$output" "UNTRACKED: pending-live-handoff.md" \
        "the untracked file is reported as untracked instead"
}
run_test "stale-check: a sweep hides no real staleness; a citing commit is not evidence (CFG-665 x CFG-620)" test_stale_real_commit_still_counts_beside_a_sweep

# ── summary ──────────────────────────────────────────────────────────────────
suite_summary
