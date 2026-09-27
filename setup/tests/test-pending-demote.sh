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

# CFG-665: the Auto-sync commit body lists every swept path. Naming a live
# handoff there records the sweep; it does not ship the work.
test_demote_ignores_auto_sync_sweep_body() {
    local project_dir="$TEST_TMPDIR/project"
    init_project_git "$project_dir"
    local ref
    ref=$(git -C "$project_dir" rev-parse HEAD)

    create_tracked_pending "$project_dir/docs" "pending-live-handoff.md" "act" \
        "(this file IS the plan)"
    create_tracked_pending "$project_dir/docs" "pending-CFG-777-notes.md" "act" "CFG-777"
    add_named_commit "$project_dir" "Auto-sync: 2026-09-25 12:00:00 UTC" \
        "Swept by the SessionEnd hook from project: 2 file(s)
  - docs/pending-live-handoff.md
  - docs/pending-CFG-777-notes.md" >/dev/null

    local output
    output=$(bash "$SCRIPT" --demote-check --since "$ref" --project-dir "$project_dir" 2>&1)

    assert_not_contains "$output" "DEMOTE: pending-live-handoff.md" \
        "a file listed in an Auto-sync sweep body is not demoted" || return 1
    assert_not_contains "$output" "DEMOTE: pending-CFG-777-notes.md" \
        "a PRN that appears only in a swept path name is not a shipped PRN"
}
run_test "demote-check: an Auto-sync sweep body is not shipped evidence (CFG-665)" test_demote_ignores_auto_sync_sweep_body

# Over-blocking control for the sweep exclusion, in the one check where commit
# citations are still evidence (--stale-check reads none since CFG-620): a real
# commit citing the file beside a sweep still demotes it, and a PRN a real
# commit ships still counts.
test_demote_real_commit_still_counts_beside_a_sweep() {
    local project_dir="$TEST_TMPDIR/project"
    init_project_git "$project_dir"
    local ref
    ref=$(git -C "$project_dir" rev-parse HEAD)

    create_tracked_pending "$project_dir/docs" "pending-live-handoff.md" "act" \
        "(this file IS the plan)"
    create_tracked_pending "$project_dir/docs" "pending-CFG-777-notes.md" "act" "CFG-777"
    add_named_commit "$project_dir" "Auto-sync: 2026-09-25 12:00:00 UTC" \
        "Swept by the SessionEnd hook from project: 2 file(s)
  - docs/pending-live-handoff.md
  - docs/pending-CFG-777-notes.md" >/dev/null
    add_named_commit "$project_dir" "docs: close the handoff" \
        "Shipped; see docs/pending-live-handoff.md" >/dev/null
    add_named_commit "$project_dir" "fix: ship CFG-777" >/dev/null

    local output
    output=$(bash "$SCRIPT" --demote-check --since "$ref" --project-dir "$project_dir" 2>&1)

    assert_contains "$output" "DEMOTE: pending-live-handoff.md" \
        "a real commit citing the file still counts beside a sweep" || return 1
    assert_contains "$output" "DEMOTE: pending-CFG-777-notes.md" \
        "a PRN a real commit ships still counts beside a sweep"
}
run_test "demote-check: a real commit still counts beside a sweep (CFG-665)" test_demote_real_commit_still_counts_beside_a_sweep

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

# ── CFG-620: a commit MENTIONING an ID is not the ID shipping ─────────────────
# get_tracked_prns reads the <!-- Tracked-by: --> comment form every real
# pending file uses, so --demote-check now sees their IDs. A commit that only
# cites an ID ("groundwork; CFG-665 itself stays open") then produced
# "DEMOTE: <file> (CFG-665 shipped …)" for MG's live action list while the
# backlog still had CFG-665 open. The backlog's own line for the ID vetoes.

create_comment_form_pending() {
    local dir="$1" name="$2" action="$3" tracked="$4"
    mkdir -p "$dir"
    printf "<!-- Action: %s -->\n<!-- Tracked-by: %s -->\n# %s\n\nContent.\n" \
        "$action" "$tracked" "$name" > "$dir/$name"
}

test_demote_open_id_mentioned_in_commit_not_flagged() {
    local project_dir="$TEST_TMPDIR/project"
    init_project_git "$project_dir"
    cat > "$project_dir/backlog.md" << 'EOF'
- [ ] [P1] `CFG-665` open item, still being worked
- [ ] [P1] `CFG-666` open item
EOF
    create_comment_form_pending "$project_dir/docs" "pending-action-list.md" "present" "CFG-665, CFG-666"
    local ref
    ref=$(git -C "$project_dir" rev-parse HEAD)
    add_named_commit "$project_dir" "Name swept files in auto-sync message" \
        "Groundwork only; CFG-665 itself stays open." >/dev/null

    local output
    output=$(bash "$SCRIPT" --demote-check --since "$ref" --project-dir "$project_dir" 2>&1)
    assert_not_contains "$output" "DEMOTE: pending-action-list.md" \
        "CFG-665 is open on its own backlog line — a commit citing it is not a ship"
}
run_test "demote-check (CFG-620): open ID merely mentioned in a commit → NOT flagged" test_demote_open_id_mentioned_in_commit_not_flagged

test_demote_closed_id_comment_form_flagged() {
    local project_dir="$TEST_TMPDIR/project"
    init_project_git "$project_dir"
    cat > "$project_dir/backlog.md" << 'EOF'
- [x] [P1] `CFG-665` shipped
EOF
    create_comment_form_pending "$project_dir/docs" "pending-shipped.md" "act" "CFG-665"
    local ref
    ref=$(git -C "$project_dir" rev-parse HEAD)
    add_named_commit "$project_dir" "fix: ship CFG-665" >/dev/null

    local output
    output=$(bash "$SCRIPT" --demote-check --since "$ref" --project-dir "$project_dir" 2>&1)
    assert_contains "$output" "DEMOTE: pending-shipped.md" \
        "committed AND closed on its own line → demote (comment-form header honoured)" || return 1
    assert_contains "$output" "CFG-665" "reason cites the ID"
}
run_test "demote-check (CFG-620): committed ID that is [x] in the backlog → DEMOTE" test_demote_closed_id_comment_form_flagged

test_demote_other_tracked_id_open_not_flagged() {
    local project_dir="$TEST_TMPDIR/project"
    init_project_git "$project_dir"
    cat > "$project_dir/backlog.md" << 'EOF'
- [x] [P1] `CFG-701` first half shipped; `CFG-702` carries the rest
- [ ] [P1] `CFG-702` second half, open
EOF
    create_comment_form_pending "$project_dir/docs" "pending-two-halves.md" "act" "CFG-701, CFG-702"
    local ref
    ref=$(git -C "$project_dir" rev-parse HEAD)
    add_named_commit "$project_dir" "fix: ship CFG-701" >/dev/null

    local output
    output=$(bash "$SCRIPT" --demote-check --since "$ref" --project-dir "$project_dir" 2>&1)
    assert_not_contains "$output" "DEMOTE: pending-two-halves.md" \
        "a file that still tracks an OPEN item is live work, whatever else shipped"
}
run_test "demote-check (CFG-620): one tracked ID shipped, another still open → NOT flagged" test_demote_other_tracked_id_open_not_flagged

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
