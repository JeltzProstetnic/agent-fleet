#!/usr/bin/env bash
# Tests for setup/scripts/manage-pending.sh --demote-check mode (SessionEnd loop closer)
source "$(dirname "$0")/test-helpers.sh"

SCRIPT="$REPO_ROOT/setup/scripts/manage-pending.sh"

suite_header "manage-pending.sh --demote-check (loop closure)"

# ── Helpers ──────────────────────────────────────────────────────────────────

# Init a throwaway git repo in the project dir
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

# Add a commit with an explicit subject + optional body. Echoes the new HEAD hash.
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
        git rev-parse HEAD
    )
}

# Create a Tracked-by pending file (Action + Tracked-by header)
create_tracked_pending() {
    local dir="$1" name="$2" action="$3" tracked="$4"
    mkdir -p "$dir"
    printf "# %s\nAction: %s\nTracked-by: %s\n\nContent.\n" \
        "$name" "$action" "$tracked" > "$dir/$name"
}

# ── Tests ────────────────────────────────────────────────────────────────────

# PRN committed since ref → DEMOTE
test_demote_prn_committed_since_ref() {
    local project_dir="$TEST_TMPDIR/project"
    init_project_git "$project_dir"
    local ref
    ref=$(git -C "$project_dir" rev-parse HEAD)

    create_tracked_pending "$project_dir/docs" "pending-feature-y.md" "act" "CFG-419"
    add_named_commit "$project_dir" "feat: ship CFG-419 feature Y" >/dev/null

    local output
    output=$(bash "$SCRIPT" --demote-check --since "$ref" --project-dir "$project_dir" 2>&1)

    assert_contains "$output" "DEMOTE: pending-feature-y.md" \
        "PRN committed since ref should be demoted" || return 1
    assert_contains "$output" "CFG-419" "reason should cite the shipped PRN"
}
run_test "demote-check: PRN committed since ref → DEMOTE" test_demote_prn_committed_since_ref

# Filename cited in a commit body → DEMOTE
test_demote_filename_cited_in_body() {
    local project_dir="$TEST_TMPDIR/project"
    init_project_git "$project_dir"
    local ref
    ref=$(git -C "$project_dir" rev-parse HEAD)

    create_tracked_pending "$project_dir/docs" "pending-cache-fill.md" "present" \
        "(this file IS the plan)"
    add_named_commit "$project_dir" "perf: cache fill rework" \
        "Closes the loose end. Full RCA: docs/pending-cache-fill.md" >/dev/null

    local output
    output=$(bash "$SCRIPT" --demote-check --since "$ref" --project-dir "$project_dir" 2>&1)

    assert_contains "$output" "DEMOTE: pending-cache-fill.md" \
        "filename cited in commit body should be demoted"
}
run_test "demote-check: filename cited in commit body → DEMOTE" test_demote_filename_cited_in_body

# PRN committed BEFORE the ref → NOT flagged
test_demote_prn_committed_before_ref() {
    local project_dir="$TEST_TMPDIR/project"
    init_project_git "$project_dir"

    create_tracked_pending "$project_dir/docs" "pending-old-feature.md" "act" "CFG-420"
    # Commit the PRN, THEN take the ref (so the commit is before the ref window)
    add_named_commit "$project_dir" "feat: ship CFG-420 long ago" >/dev/null
    local ref
    ref=$(git -C "$project_dir" rev-parse HEAD)
    # An unrelated commit after the ref
    add_named_commit "$project_dir" "docs: unrelated note" >/dev/null

    local output
    output=$(bash "$SCRIPT" --demote-check --since "$ref" --project-dir "$project_dir" 2>&1)

    assert_not_contains "$output" "DEMOTE: pending-old-feature.md" \
        "PRN committed before the ref must NOT be demoted"
}
run_test "demote-check: PRN committed before ref → NOT flagged" test_demote_prn_committed_before_ref

# Open file with no matching commit → NOT flagged
test_demote_open_no_matching_commit() {
    local project_dir="$TEST_TMPDIR/project"
    init_project_git "$project_dir"
    local ref
    ref=$(git -C "$project_dir" rev-parse HEAD)

    create_tracked_pending "$project_dir/docs" "pending-still-open.md" "act" "CFG-421"
    add_named_commit "$project_dir" "feat: ship something unrelated (CFG-999)" >/dev/null

    local output
    output=$(bash "$SCRIPT" --demote-check --since "$ref" --project-dir "$project_dir" 2>&1)

    assert_not_contains "$output" "DEMOTE: pending-still-open.md" \
        "open file with no matching commit must NOT be demoted"
}
run_test "demote-check: open file, no matching commit → NOT flagged" test_demote_open_no_matching_commit

# No commits since ref → empty output, exit 0
test_demote_no_commits_since_ref() {
    local project_dir="$TEST_TMPDIR/project"
    init_project_git "$project_dir"
    local ref
    ref=$(git -C "$project_dir" rev-parse HEAD)

    create_tracked_pending "$project_dir/docs" "pending-quiet.md" "act" "CFG-422"
    # No new commits after ref

    local rc=0
    local output
    output=$(bash "$SCRIPT" --demote-check --since "$ref" --project-dir "$project_dir" 2>&1) || rc=$?

    assert_eq "0" "$rc" "demote-check must always exit 0" || return 1
    assert_not_contains "$output" "DEMOTE:" "no commits since ref → no demotions"
}
run_test "demote-check: no commits since ref → empty, exit 0" test_demote_no_commits_since_ref

# reference/defer files are NOT demoted (only act/present reconcile)
test_demote_skips_non_act_present() {
    local project_dir="$TEST_TMPDIR/project"
    init_project_git "$project_dir"
    local ref
    ref=$(git -C "$project_dir" rev-parse HEAD)

    create_tracked_pending "$project_dir/docs" "pending-ref.md" "reference" "CFG-423"
    add_named_commit "$project_dir" "feat: ship CFG-423" >/dev/null

    local output
    output=$(bash "$SCRIPT" --demote-check --since "$ref" --project-dir "$project_dir" 2>&1)

    assert_not_contains "$output" "DEMOTE: pending-ref.md" \
        "reference files are not subject to demote-check"
}
run_test "demote-check: reference files not demoted" test_demote_skips_non_act_present

# Missing .git → fail-safe, exit 0, no demotions
test_demote_no_git_failsafe() {
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$project_dir/docs"

    create_tracked_pending "$project_dir/docs" "pending-nogit.md" "act" "CFG-424"

    local rc=0
    local output
    output=$(bash "$SCRIPT" --demote-check --since "HEAD~5" --project-dir "$project_dir" 2>&1) || rc=$?

    assert_eq "0" "$rc" "demote-check must exit 0 even with no .git" || return 1
    assert_not_contains "$output" "DEMOTE:" "no .git → no demotions"
}
run_test "demote-check: missing .git → exit 0, not flagged" test_demote_no_git_failsafe

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
