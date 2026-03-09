#!/usr/bin/env bash
# Tests for git-sync-check.sh
source "$(dirname "$0")/test-helpers.sh"

SYNC_SCRIPT="$REPO_ROOT/setup/scripts/git-sync-check.sh"

suite_header "git-sync-check.sh"

# ── Not a git repo ──────────────────────────────────────────────────────────

test_not_a_git_repo() {
    local out rc=0
    out=$(cd "$TEST_TMPDIR" && bash "$SYNC_SCRIPT" 2>&1) || rc=$?
    assert_eq "2" "$rc"
    assert_contains "$out" "Not a git repo"
}
run_test "exits 2 when not in a git repo" test_not_a_git_repo

# ── Path argument ───────────────────────────────────────────────────────────

test_path_argument_valid_repo() {
    create_tracked_repo "$TEST_TMPDIR/repo" "$TEST_TMPDIR/remote.git"
    local out rc=0
    out=$(bash "$SYNC_SCRIPT" --pull "$TEST_TMPDIR/repo" 2>&1) || rc=$?
    assert_eq "0" "$rc" "should succeed with path arg pointing to repo"
    assert_contains "$out" "Up to date"
}
run_test "path argument: succeeds with valid repo path" test_path_argument_valid_repo

test_path_argument_non_repo() {
    mkdir -p "$TEST_TMPDIR/notarepo"
    local out rc=0
    out=$(bash "$SYNC_SCRIPT" "$TEST_TMPDIR/notarepo" 2>&1) || rc=$?
    assert_eq "2" "$rc" "should exit 2 for non-repo path"
    assert_contains "$out" "Not a git repo"
}
run_test "path argument: exits 2 for non-repo directory" test_path_argument_non_repo

test_path_argument_nonexistent() {
    local out rc=0
    out=$(bash "$SYNC_SCRIPT" "$TEST_TMPDIR/doesnotexist" 2>&1) || rc=$?
    assert_eq "2" "$rc" "should exit 2 for nonexistent path"
    assert_contains "$out" "Not a directory"
}
run_test "path argument: exits 2 for nonexistent path" test_path_argument_nonexistent

# ── No upstream tracking ────────────────────────────────────────────────────

test_no_upstream() {
    create_git_repo "$TEST_TMPDIR/repo"
    local out rc=0
    out=$(cd "$TEST_TMPDIR/repo" && bash "$SYNC_SCRIPT" 2>&1) || rc=$?
    assert_eq "0" "$rc" "should exit 0 (skip gracefully)"
    assert_contains "$out" "No upstream"
}
run_test "skips gracefully when no upstream is set" test_no_upstream

# ── Up to date ──────────────────────────────────────────────────────────────

test_up_to_date() {
    create_tracked_repo "$TEST_TMPDIR/repo" "$TEST_TMPDIR/remote.git"
    local out rc=0
    out=$(cd "$TEST_TMPDIR/repo" && bash "$SYNC_SCRIPT" 2>&1) || rc=$?
    assert_eq "0" "$rc"
    assert_contains "$out" "Up to date"
}
run_test "reports up to date when local matches remote" test_up_to_date

# ── Behind remote (report only) ─────────────────────────────────────────────

test_behind_report() {
    create_tracked_repo "$TEST_TMPDIR/repo" "$TEST_TMPDIR/remote.git"
    # Clone another copy, commit, push → repo falls behind
    git clone "$TEST_TMPDIR/remote.git" "$TEST_TMPDIR/other" --quiet 2>/dev/null
    add_commit "$TEST_TMPDIR/other" "remote change"
    (cd "$TEST_TMPDIR/other" && git push --quiet 2>/dev/null)

    local out rc=0
    out=$(cd "$TEST_TMPDIR/repo" && bash "$SYNC_SCRIPT" 2>&1) || rc=$?
    assert_eq "1" "$rc" "should exit 1 when behind (no --pull)"
    assert_contains "$out" "BEHIND remote by 1"
    assert_contains "$out" "remote change"
}
run_test "reports behind status without pulling (exit 1)" test_behind_report

# ── Behind remote (auto-pull) ───────────────────────────────────────────────

test_behind_auto_pull() {
    create_tracked_repo "$TEST_TMPDIR/repo" "$TEST_TMPDIR/remote.git"
    git clone "$TEST_TMPDIR/remote.git" "$TEST_TMPDIR/other" --quiet 2>/dev/null
    add_commit "$TEST_TMPDIR/other" "remote change to pull"
    (cd "$TEST_TMPDIR/other" && git push --quiet 2>/dev/null)

    local out rc=0
    out=$(cd "$TEST_TMPDIR/repo" && bash "$SYNC_SCRIPT" --pull 2>&1) || rc=$?
    assert_eq "0" "$rc" "should exit 0 after successful pull"
    assert_contains "$out" "Pulled successfully"

    # Verify the commit is now local
    local log
    log=$(cd "$TEST_TMPDIR/repo" && git log --oneline -1)
    assert_contains "$log" "remote change to pull"
}
run_test "pulls successfully with --pull flag" test_behind_auto_pull

# ── Ahead of remote ─────────────────────────────────────────────────────────

test_ahead_of_remote() {
    create_tracked_repo "$TEST_TMPDIR/repo" "$TEST_TMPDIR/remote.git"
    add_commit "$TEST_TMPDIR/repo" "local unpushed change"

    local out rc=0
    out=$(cd "$TEST_TMPDIR/repo" && bash "$SYNC_SCRIPT" 2>&1) || rc=$?
    assert_eq "0" "$rc" "should exit 0 when ahead"
    assert_contains "$out" "Ahead of remote by 1"
}
run_test "reports ahead status (exit 0, no action)" test_ahead_of_remote

# ── Diverged ────────────────────────────────────────────────────────────────

test_diverged() {
    create_tracked_repo "$TEST_TMPDIR/repo" "$TEST_TMPDIR/remote.git"

    # Create divergence: push from another clone, commit locally
    git clone "$TEST_TMPDIR/remote.git" "$TEST_TMPDIR/other" --quiet 2>/dev/null
    add_commit "$TEST_TMPDIR/other" "remote diverge"
    (cd "$TEST_TMPDIR/other" && git push --quiet 2>/dev/null)
    add_commit "$TEST_TMPDIR/repo" "local diverge"

    local out rc=0
    out=$(cd "$TEST_TMPDIR/repo" && bash "$SYNC_SCRIPT" 2>&1) || rc=$?
    assert_eq "2" "$rc" "should exit 2 on diverged"
    assert_contains "$out" "DIVERGED"
}
run_test "detects diverged branches (exit 2)" test_diverged

# ── Dual-remote: only syncs with private ────────────────────────────────────

test_dual_remote_private_only() {
    # Create two bare remotes
    create_bare_repo "$TEST_TMPDIR/private.git"
    create_bare_repo "$TEST_TMPDIR/public.git"

    # Create repo with two remotes
    create_git_repo "$TEST_TMPDIR/repo"
    (
        cd "$TEST_TMPDIR/repo"
        git remote add private "$TEST_TMPDIR/private.git"
        git remote add public "$TEST_TMPDIR/public.git"
        local branch
        branch=$(git branch --show-current)
        git push -u private "$branch" --quiet 2>/dev/null
        git push public "$branch" --quiet 2>/dev/null
    )

    # Create .push-filter.conf
    cat > "$TEST_TMPDIR/repo/.push-filter.conf" <<'EOF'
private_remote=private
public_remote=public
branch=main
EOF

    # Push a change only to private (simulate divergence between remotes)
    git clone "$TEST_TMPDIR/private.git" "$TEST_TMPDIR/other" --quiet 2>/dev/null
    add_commit "$TEST_TMPDIR/other" "private-only change"
    (cd "$TEST_TMPDIR/other" && git push --quiet 2>/dev/null)

    local out rc=0
    out=$(cd "$TEST_TMPDIR/repo" && bash "$SYNC_SCRIPT" --pull 2>&1) || rc=$?
    assert_eq "0" "$rc"
    assert_contains "$out" "Dual-remote project detected"
    assert_contains "$out" "private"
}
run_test "dual-remote: syncs only with private remote" test_dual_remote_private_only

# ── Detached HEAD ───────────────────────────────────────────────────────────

test_detached_head() {
    create_tracked_repo "$TEST_TMPDIR/repo" "$TEST_TMPDIR/remote.git"
    (cd "$TEST_TMPDIR/repo" && git checkout --detach HEAD 2>/dev/null)

    local out rc=0
    out=$(cd "$TEST_TMPDIR/repo" && bash "$SYNC_SCRIPT" 2>&1) || rc=$?
    assert_eq "2" "$rc"
    assert_contains "$out" "Detached HEAD"
}
run_test "exits 2 on detached HEAD" test_detached_head

# ── Multiple commits behind ─────────────────────────────────────────────────

test_multiple_behind() {
    create_tracked_repo "$TEST_TMPDIR/repo" "$TEST_TMPDIR/remote.git"
    git clone "$TEST_TMPDIR/remote.git" "$TEST_TMPDIR/other" --quiet 2>/dev/null
    add_commit "$TEST_TMPDIR/other" "change 1"
    add_commit "$TEST_TMPDIR/other" "change 2"
    add_commit "$TEST_TMPDIR/other" "change 3"
    (cd "$TEST_TMPDIR/other" && git push --quiet 2>/dev/null)

    local out rc=0
    out=$(cd "$TEST_TMPDIR/repo" && bash "$SYNC_SCRIPT" 2>&1) || rc=$?
    assert_eq "1" "$rc"
    assert_contains "$out" "BEHIND remote by 3"
}
run_test "reports correct count when multiple commits behind" test_multiple_behind

# ── Auto-stash on dirty worktree (--pull) ────────────────────────────────────

test_dirty_worktree_auto_stash() {
    create_tracked_repo "$TEST_TMPDIR/repo" "$TEST_TMPDIR/remote.git"
    git clone "$TEST_TMPDIR/remote.git" "$TEST_TMPDIR/other" --quiet 2>/dev/null

    # Remote gets a new commit that modifies README.md
    (cd "$TEST_TMPDIR/other" && echo "remote update" >> README.md && git add README.md && git commit -m "remote README update" >/dev/null 2>&1 && git push --quiet 2>/dev/null)

    # Local has uncommitted changes to a DIFFERENT file
    echo "local dirty" > "$TEST_TMPDIR/repo/dirty-file.txt"

    local out rc=0
    out=$(cd "$TEST_TMPDIR/repo" && bash "$SYNC_SCRIPT" --pull 2>&1) || rc=$?
    assert_eq "0" "$rc" "should exit 0 after stash+pull+pop"
    assert_contains "$out" "Pulled successfully"

    # Verify dirty file still exists with its content
    assert_file_exists "$TEST_TMPDIR/repo/dirty-file.txt"
    local content
    content=$(cat "$TEST_TMPDIR/repo/dirty-file.txt")
    assert_eq "local dirty" "$content" "dirty file content should be preserved"

    # Verify the remote commit landed
    local log
    log=$(cd "$TEST_TMPDIR/repo" && git log --oneline -1)
    assert_contains "$log" "remote README update"
}
run_test "auto-stashes dirty worktree before pull, pops after" test_dirty_worktree_auto_stash

# ── Auto-stash with conflicting file ────────────────────────────────────────

test_dirty_worktree_conflict_stash() {
    create_tracked_repo "$TEST_TMPDIR/repo" "$TEST_TMPDIR/remote.git"
    git clone "$TEST_TMPDIR/remote.git" "$TEST_TMPDIR/other" --quiet 2>/dev/null

    # Remote modifies README.md
    (cd "$TEST_TMPDIR/other" && echo "remote version" > README.md && git add README.md && git commit -m "remote README" >/dev/null 2>&1 && git push --quiet 2>/dev/null)

    # Local has uncommitted changes to the SAME file (README.md)
    echo "local version" > "$TEST_TMPDIR/repo/README.md"

    local out rc=0
    out=$(cd "$TEST_TMPDIR/repo" && bash "$SYNC_SCRIPT" --pull 2>&1) || rc=$?
    assert_eq "0" "$rc" "should exit 0 — stash+pull succeeds, pop may conflict but pull worked"
    assert_contains "$out" "Pulled successfully"
}
run_test "auto-stash works even when same file modified locally and remotely" test_dirty_worktree_conflict_stash

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
