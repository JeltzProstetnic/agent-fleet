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

    # Local has uncommitted changes to a DIFFERENT file (simulates next-session-task.md)
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

# ── Clone-if-missing: registry has matching URL ────────────────────────────

test_clone_from_registry() {
    # Create a bare remote with content
    create_bare_repo "$TEST_TMPDIR/remote.git"
    git clone "$TEST_TMPDIR/remote.git" "$TEST_TMPDIR/clone-seed" --quiet 2>/dev/null
    add_commit "$TEST_TMPDIR/clone-seed" "initial content"
    (cd "$TEST_TMPDIR/clone-seed" && git push --quiet 2>/dev/null)
    rm -rf "$TEST_TMPDIR/clone-seed"

    # Create empty project dir (no .git/)
    mkdir -p "$TEST_TMPDIR/home/myproject"

    # Create mock registry with local path as repo URL
    cat > "$TEST_TMPDIR/registry.md" << EOF
| Name | P | Parent | Path | Repo | Machines | Type | Status | Notes |
|------|---|--------|------|------|----------|------|--------|-------|
| myproject | P2 | — | \`~/myproject\` | \`$TEST_TMPDIR/remote.git\` | test | code | — | Test |
EOF

    local out rc=0
    out=$(HOME="$TEST_TMPDIR/home" REGISTRY_PATH="$TEST_TMPDIR/registry.md" \
        bash "$SYNC_SCRIPT" --pull "$TEST_TMPDIR/home/myproject" 2>&1) || rc=$?
    assert_eq "0" "$rc" "should exit 0 after successful clone + sync"
    assert_contains "$out" "Cloned from registry"
}
run_test "clone-if-missing: clones when registry has matching URL" test_clone_from_registry

# ── Clone-if-missing: no match in registry ─────────────────────────────────

test_clone_no_registry_match() {
    mkdir -p "$TEST_TMPDIR/home/unknown-project"

    # Registry exists but has no matching path
    cat > "$TEST_TMPDIR/registry.md" << 'EOF'
| Name | P | Parent | Path | Repo | Machines | Type | Status | Notes |
|------|---|--------|------|------|----------|------|--------|-------|
| other | P2 | — | `~/other` | `Someone/other` | test | code | — | Test |
EOF

    local out rc=0
    out=$(HOME="$TEST_TMPDIR/home" REGISTRY_PATH="$TEST_TMPDIR/registry.md" \
        bash "$SYNC_SCRIPT" "$TEST_TMPDIR/home/unknown-project" 2>&1) || rc=$?
    assert_eq "2" "$rc" "should exit 2 when no registry match"
    assert_contains "$out" "Not a git repo"
}
run_test "clone-if-missing: exits 2 when no registry match" test_clone_no_registry_match

# ── Clone-if-missing: registry has dash (no URL) ──────────────────────────

test_clone_registry_no_url() {
    mkdir -p "$TEST_TMPDIR/home/nourl"

    cat > "$TEST_TMPDIR/registry.md" << 'EOF'
| Name | P | Parent | Path | Repo | Machines | Type | Status | Notes |
|------|---|--------|------|------|----------|------|--------|-------|
| nourl | P2 | — | `~/nourl` | — | test | code | — | No repo |
EOF

    local out rc=0
    out=$(HOME="$TEST_TMPDIR/home" REGISTRY_PATH="$TEST_TMPDIR/registry.md" \
        bash "$SYNC_SCRIPT" "$TEST_TMPDIR/home/nourl" 2>&1) || rc=$?
    assert_eq "2" "$rc" "should exit 2 when registry has no URL"
    assert_contains "$out" "Not a git repo"
}
run_test "clone-if-missing: exits 2 when registry entry has no URL" test_clone_registry_no_url

# ── Clone-if-missing: preserves existing .claude/ dir ──────────────────────

test_clone_preserves_claude_dir() {
    # Create a bare remote with content
    create_bare_repo "$TEST_TMPDIR/remote2.git"
    git clone "$TEST_TMPDIR/remote2.git" "$TEST_TMPDIR/clone-seed2" --quiet 2>/dev/null
    add_commit "$TEST_TMPDIR/clone-seed2" "project content"
    (cd "$TEST_TMPDIR/clone-seed2" && git push --quiet 2>/dev/null)
    rm -rf "$TEST_TMPDIR/clone-seed2"

    # Create project dir with pre-existing .claude/
    mkdir -p "$TEST_TMPDIR/home/preserved/.claude"
    echo '{"session":"test"}' > "$TEST_TMPDIR/home/preserved/.claude/.session-lock"

    cat > "$TEST_TMPDIR/registry.md" << EOF
| Name | P | Parent | Path | Repo | Machines | Type | Status | Notes |
|------|---|--------|------|------|----------|------|--------|-------|
| preserved | P2 | — | \`~/preserved\` | \`$TEST_TMPDIR/remote2.git\` | test | code | — | Test |
EOF

    local out rc=0
    out=$(HOME="$TEST_TMPDIR/home" REGISTRY_PATH="$TEST_TMPDIR/registry.md" \
        bash "$SYNC_SCRIPT" --pull "$TEST_TMPDIR/home/preserved" 2>&1) || rc=$?
    assert_eq "0" "$rc" "should exit 0 after clone"

    # .claude/ and its contents should still exist
    assert_file_exists "$TEST_TMPDIR/home/preserved/.claude/.session-lock"
    local content
    content=$(cat "$TEST_TMPDIR/home/preserved/.claude/.session-lock")
    assert_contains "$content" "test" "session lock content should be preserved"
}
run_test "clone-if-missing: preserves existing .claude/ directory" test_clone_preserves_claude_dir

# ── Clone-if-missing: no registry file ─────────────────────────────────────

test_clone_no_registry_file() {
    mkdir -p "$TEST_TMPDIR/home/orphan"

    local out rc=0
    out=$(HOME="$TEST_TMPDIR/home" REGISTRY_PATH="$TEST_TMPDIR/nonexistent-registry.md" \
        bash "$SYNC_SCRIPT" "$TEST_TMPDIR/home/orphan" 2>&1) || rc=$?
    assert_eq "2" "$rc" "should exit 2 when no registry file"
    assert_contains "$out" "Not a git repo"
}
run_test "clone-if-missing: exits 2 when registry file missing" test_clone_no_registry_file

# ── Clone-if-missing: unreachable remote ───────────────────────────────────

test_clone_unreachable_remote() {
    mkdir -p "$TEST_TMPDIR/home/unreachable"

    cat > "$TEST_TMPDIR/registry.md" << 'EOF'
| Name | P | Parent | Path | Repo | Machines | Type | Status | Notes |
|------|---|--------|------|------|----------|------|--------|-------|
| unreachable | P2 | — | `~/unreachable` | `/nonexistent/path/repo.git` | test | code | — | Bad URL |
EOF

    local out rc=0
    out=$(HOME="$TEST_TMPDIR/home" REGISTRY_PATH="$TEST_TMPDIR/registry.md" \
        bash "$SYNC_SCRIPT" "$TEST_TMPDIR/home/unreachable" 2>&1) || rc=$?
    assert_eq "2" "$rc" "should exit 2 when remote is unreachable"
    assert_contains "$out" "Clone failed"
}
run_test "clone-if-missing: exits 2 when remote is unreachable" test_clone_unreachable_remote

# ── Rotation-artifact recovery (agent-fleet issue #8) ────────────────────────
# The recovery that commits leftover session-rotation artifacts used to be
# nested inside the behind-remote pull branch, so it only ran when the repo had
# something to pull. Up-to-date and ahead-only repos never reached it, and every
# following session raised CONFIG_REPO_DIRTY over its predecessor's mess.
# These tests pin recovery on those two paths AND pin the guards that keep the
# refuted first attempt's regressions out: behind path untouched (1, 2, 6),
# repo-root-pinned staging (3, 5), no false success on commit failure (4),
# no mid-session commits of in-flight session state (7).

# A tracked repo carrying the session-lifecycle files. Committed state mimics a
# real repo mid-life: session-context.md has a POPULATED Session Goal.
_mk_rotation_repo() {
    local repo="$1" remote="$2"
    create_tracked_repo "$repo" "$remote"
    mkdir -p "$repo/docs"
    printf '# Session Context\n\n- **Session Goal**: previous session work\n' > "$repo/session-context.md"
    printf '# Session Log\n\n### 2026-01-01\nold entry\n' > "$repo/docs/session-log.md"
    (
        cd "$repo"
        git add session-context.md docs/session-log.md
        git commit -m "add session files" >/dev/null 2>&1
        git push --quiet 2>/dev/null
    )
}

# Put the worktree in the exact state an interrupted shutdown leaves:
# rotate-session.sh reset session-context.md to the blank template (Session
# Goal EMPTY) and appended the archive entry to docs/session-log.md, but the
# SessionEnd commit never ran.
_rotate_dirt() {
    local repo="$1"
    printf '# Session Context\n\n- **Session Goal**:\n' > "$repo/session-context.md"
    printf '\n### 2026-01-02\narchived entry\n' >> "$repo/docs/session-log.md"
}

# Tracked dirtiness only — what CONFIG_REPO_DIRTY (checks/18) reports; it filters '??'.
_tracked_dirt() {
    (cd "$1" && git status --porcelain 2>/dev/null | grep -v '^??' || true)
}

test_gh8_recovers_up_to_date() {
    _mk_rotation_repo "$TEST_TMPDIR/repo" "$TEST_TMPDIR/remote.git"
    _rotate_dirt "$TEST_TMPDIR/repo"
    printf 'deadbeef 1789369158\n' > "$TEST_TMPDIR/repo/.post-rotation-commit"

    local out rc=0
    out=$(cd "$TEST_TMPDIR/repo" && bash "$SYNC_SCRIPT" --pull 2>&1) || rc=$?
    assert_eq "0" "$rc" "should still exit 0 on an up-to-date repo" || return 1
    assert_contains "$out" "Up to date" || return 1
    assert_eq "" "$(_tracked_dirt "$TEST_TMPDIR/repo")" \
        "tracked rotation artifacts should have been committed" || return 1

    local log
    log=$(cd "$TEST_TMPDIR/repo" && git log --oneline -1)
    assert_contains "$log" "Auto-sync: recovered rotation" || return 1

    # The recovery commit must be pushed immediately (repo was in sync a moment
    # ago, so this is a plain fast-forward) — an unpushed auto-sync commit would
    # sit dangling until another machine pushes, turning the next startup into a
    # diverged one (refuted attempt, point 2).
    local remote_subject
    remote_subject=$(git -C "$TEST_TMPDIR/remote.git" log --format=%s -1 2>/dev/null)
    assert_contains "$remote_subject" "Auto-sync: recovered rotation" \
        "recovery commit should be pushed when repo was up to date" || return 1

    # The untracked marker must stay untracked: staging it would promote it to a
    # tracked file, and the next shutdown's rm -f would then surface as tracked
    # dirt manufactured by the recovery itself.
    local tracked_marker
    tracked_marker=$(cd "$TEST_TMPDIR/repo" && git ls-files .post-rotation-commit)
    assert_eq "" "$tracked_marker" "untracked marker must never be committed"
}
run_test "gh-8: recovers rotation artifacts when repo is up to date" test_gh8_recovers_up_to_date

test_gh8_recovers_ahead_only_no_push() {
    _mk_rotation_repo "$TEST_TMPDIR/repo" "$TEST_TMPDIR/remote.git"
    add_commit "$TEST_TMPDIR/repo" "local unpushed work"
    _rotate_dirt "$TEST_TMPDIR/repo"

    local out rc=0
    out=$(cd "$TEST_TMPDIR/repo" && bash "$SYNC_SCRIPT" --pull 2>&1) || rc=$?
    assert_eq "0" "$rc" "should exit 0 on an ahead-only repo" || return 1
    assert_eq "" "$(_tracked_dirt "$TEST_TMPDIR/repo")" \
        "ahead-only repo must still get its rotation artifacts recovered" || return 1
    assert_contains "$out" "Ahead of remote by 2" \
        "ahead count must reflect the recovery commit" || return 1

    local log
    log=$(cd "$TEST_TMPDIR/repo" && git log --oneline -1)
    assert_contains "$log" "Auto-sync: recovered rotation" || return 1

    # Must NOT push: the branch carries unpushed commits this script
    # deliberately leaves alone, and a push would ship them as a side effect.
    local remote_log
    remote_log=$(git -C "$TEST_TMPDIR/remote.git" log --format=%s 2>/dev/null)
    assert_not_contains "$remote_log" "local unpushed work" \
        "recovery on an ahead-only repo must not push the user's commits"
}
run_test "gh-8: recovers on ahead-only repo without pushing" test_gh8_recovers_ahead_only_no_push

# Refuted attempt, point 7: recovery must never fire on an IN-FLIGHT session.
# Mid-session, session-context.md carries a populated Session Goal (startup
# protocol step 8 fills it before any work); only a freshly rotated file has an
# empty one. A populated goal means the dirt is live session state, not leftovers.
test_gh8_midsession_inflight_untouched() {
    _mk_rotation_repo "$TEST_TMPDIR/repo" "$TEST_TMPDIR/remote.git"
    printf '# Session Context\n\n- **Session Goal**: implementing feature X\n- notes\n' \
        > "$TEST_TMPDIR/repo/session-context.md"
    printf '\n### live edit\n' >> "$TEST_TMPDIR/repo/docs/session-log.md"

    local out rc=0
    out=$(cd "$TEST_TMPDIR/repo" && bash "$SYNC_SCRIPT" --pull 2>&1) || rc=$?
    assert_eq "0" "$rc" || return 1

    local log
    log=$(cd "$TEST_TMPDIR/repo" && git log --oneline -1)
    assert_not_contains "$log" "Auto-sync: recovered rotation" \
        "in-flight session state must never be auto-committed" || return 1

    local dirt
    dirt=$(_tracked_dirt "$TEST_TMPDIR/repo")
    assert_contains "$dirt" "session-context.md" "in-flight edits must be left alone"
}
run_test "gh-8: mid-session in-flight session state is never committed" test_gh8_midsession_inflight_untouched

# Refuted attempt, points 1 + 6: with rotation dirt AND deploy-sensitive incoming
# commits, the repo must still take the BEHIND path — full incoming-changes
# report, pull, and the CFG-208 auto-deploy. (Committing before the ahead/behind
# read turned this into a diverged repo that exited before the deploy check.)
test_gh8_behind_report_and_deploy_intact() {
    _mk_rotation_repo "$TEST_TMPDIR/repo" "$TEST_TMPDIR/remote.git"
    git clone "$TEST_TMPDIR/remote.git" "$TEST_TMPDIR/other" --quiet 2>/dev/null
    (
        cd "$TEST_TMPDIR/other"
        git config user.email "test@test.com"
        git config user.name "Test"
        mkdir -p global/hooks
        echo "hook" > global/hooks/new-hook.sh
        git add global/hooks/new-hook.sh
        git commit -m "deploy-sensitive hook change" >/dev/null 2>&1
        git push --quiet 2>/dev/null
    )
    _rotate_dirt "$TEST_TMPDIR/repo"
    # Untracked deploy stub — records that CFG-208 auto-deploy actually ran
    printf '#!/usr/bin/env bash\n[ "$1" = deploy ] && touch .deploy-marker\nexit 0\n' \
        > "$TEST_TMPDIR/repo/sync.sh"
    chmod +x "$TEST_TMPDIR/repo/sync.sh"

    local out rc=0
    out=$(cd "$TEST_TMPDIR/repo" && bash "$SYNC_SCRIPT" --pull 2>&1) || rc=$?
    assert_eq "0" "$rc" || return 1
    assert_contains "$out" "BEHIND remote by 1" "incoming report must not be suppressed" || return 1
    assert_contains "$out" "Incoming changes:" || return 1
    assert_file_exists "$TEST_TMPDIR/repo/.deploy-marker" \
        "CFG-208 auto-deploy must fire for deploy-sensitive pulled paths" || return 1

    local log
    log=$(cd "$TEST_TMPDIR/repo" && git log --oneline)
    assert_contains "$log" "deploy-sensitive hook change" || return 1
    assert_eq "" "$(_tracked_dirt "$TEST_TMPDIR/repo")"
}
run_test "gh-8: behind path keeps report, pull, and CFG-208 deploy with rotation dirt" test_gh8_behind_report_and_deploy_intact

# Refuted attempt, point 2: rotation dirt conflicting with an incoming commit
# must not become a permanent exit-2 startup block, and later runs must never
# commit the conflicted file (git add on an unmerged path would mark it
# resolved WITH the conflict markers still inside).
test_gh8_conflict_never_blocks_permanently() {
    _mk_rotation_repo "$TEST_TMPDIR/repo" "$TEST_TMPDIR/remote.git"
    git clone "$TEST_TMPDIR/remote.git" "$TEST_TMPDIR/other" --quiet 2>/dev/null
    (
        cd "$TEST_TMPDIR/other"
        git config user.email "test@test.com"
        git config user.name "Test"
        printf 'remote rewrite of context\nno goal line here\n' > session-context.md
        git add session-context.md
        git commit -m "remote context change" >/dev/null 2>&1
        git push --quiet 2>/dev/null
    )
    _rotate_dirt "$TEST_TMPDIR/repo"

    local out rc=0
    out=$(cd "$TEST_TMPDIR/repo" && bash "$SYNC_SCRIPT" --pull 2>&1) || rc=$?
    assert_eq "0" "$rc" "first run: conflict falls back to stash, still exit 0" || return 1
    local log
    log=$(cd "$TEST_TMPDIR/repo" && git log --oneline)
    assert_contains "$log" "remote context change" "remote change must be pulled" || return 1

    # Two more runs over the conflicted (unmerged) worktree the stash-pop left
    rc=0; out=$(cd "$TEST_TMPDIR/repo" && bash "$SYNC_SCRIPT" --pull 2>&1) || rc=$?
    assert_eq "0" "$rc" "second run must not exit 2" || return 1
    rc=0; out=$(cd "$TEST_TMPDIR/repo" && bash "$SYNC_SCRIPT" --pull 2>&1) || rc=$?
    assert_eq "0" "$rc" "third run must not exit 2" || return 1

    log=$(cd "$TEST_TMPDIR/repo" && git log --format=%s)
    assert_not_contains "$log" "Auto-sync: recovered rotation" \
        "a conflicted worktree must never be auto-committed" || return 1
    local head_content
    head_content=$(cd "$TEST_TMPDIR/repo" && git show HEAD:session-context.md 2>/dev/null)
    assert_not_contains "$head_content" "<<<<<<<" "no conflict markers may ever be committed"
}
run_test "gh-8: conflicting rotation dirt never becomes a permanent block" test_gh8_conflict_never_blocks_permanently

# Refuted attempt, points 3 + 5: git diff prints repo-root-relative paths while
# a bare 'git add' resolves cwd-relative. From a subdirectory that mismatch
# either silently stages nothing or — worse — stages a same-named UNTRACKED
# file with user content. Recovery must pin all paths to the repo root.
test_gh8_subdir_cwd_stages_only_root_paths() {
    _mk_rotation_repo "$TEST_TMPDIR/repo" "$TEST_TMPDIR/remote.git"
    _rotate_dirt "$TEST_TMPDIR/repo"
    # Untracked same-named file with user content, in the subdirectory we run from
    printf 'irreplaceable user notes\n' > "$TEST_TMPDIR/repo/docs/session-context.md"

    local out rc=0
    out=$(cd "$TEST_TMPDIR/repo/docs" && bash "$SYNC_SCRIPT" --pull 2>&1) || rc=$?
    assert_eq "0" "$rc" || return 1
    assert_eq "" "$(_tracked_dirt "$TEST_TMPDIR/repo")" \
        "recovery must work from a subdirectory cwd, not silently no-op" || return 1

    local log committed
    log=$(cd "$TEST_TMPDIR/repo" && git log --oneline -1)
    assert_contains "$log" "Auto-sync: recovered rotation" || return 1
    committed=$(cd "$TEST_TMPDIR/repo" && git show --name-only --format= HEAD)
    assert_contains "$committed" "session-context.md" || return 1
    assert_not_contains "$committed" "docs/session-context.md" \
        "the untracked same-named user file must not be swept into the commit" || return 1

    # User file survives, untouched and still untracked
    assert_eq "irreplaceable user notes" "$(cat "$TEST_TMPDIR/repo/docs/session-context.md")" || return 1
    assert_eq "" "$(cd "$TEST_TMPDIR/repo" && git ls-files docs/session-context.md)"
}
run_test "gh-8: subdirectory cwd stages only root rotation paths" test_gh8_subdir_cwd_stages_only_root_paths

# Refuted attempt, point 4: when the commit itself fails (no git identity),
# recovery must not claim success and must not leave files staged.
test_gh8_commit_failure_no_false_success() {
    _mk_rotation_repo "$TEST_TMPDIR/repo" "$TEST_TMPDIR/remote.git"
    _rotate_dirt "$TEST_TMPDIR/repo"
    (
        cd "$TEST_TMPDIR/repo"
        git config user.useConfigOnly true
        git config --unset user.email
        git config --unset user.name
    )

    # Strip every identity source: the test harness exports GIT_AUTHOR_*/
    # GIT_COMMITTER_* (setup_test), which would let the commit succeed even
    # with user.useConfigOnly=true.
    local out rc=0
    out=$(cd "$TEST_TMPDIR/repo" && \
        env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL -u EMAIL \
            GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
            bash "$SYNC_SCRIPT" --pull 2>&1) || rc=$?
    assert_eq "0" "$rc" "a failed recovery must never block startup" || return 1
    assert_contains "$out" "WARNING" "failed recovery must be reported, not claimed as success" || return 1

    local log staged
    log=$(cd "$TEST_TMPDIR/repo" && git log --oneline -1)
    assert_not_contains "$log" "Auto-sync: recovered rotation" || return 1
    staged=$(cd "$TEST_TMPDIR/repo" && git diff --cached --name-only)
    assert_eq "" "$staged" "nothing may be left staged after a failed recovery commit" || return 1

    local dirt
    dirt=$(_tracked_dirt "$TEST_TMPDIR/repo")
    assert_contains "$dirt" "session-context.md" "artifacts stay dirty so CONFIG_REPO_DIRTY surfaces them"
}
run_test "gh-8: commit failure leaves nothing staged and no success claim" test_gh8_commit_failure_no_false_success

test_gh8_readonly_mode_never_commits() {
    _mk_rotation_repo "$TEST_TMPDIR/repo" "$TEST_TMPDIR/remote.git"
    _rotate_dirt "$TEST_TMPDIR/repo"

    local out rc=0
    out=$(cd "$TEST_TMPDIR/repo" && bash "$SYNC_SCRIPT" 2>&1) || rc=$?
    assert_eq "0" "$rc" || return 1

    local log
    log=$(cd "$TEST_TMPDIR/repo" && git log --oneline -1)
    assert_not_contains "$log" "Auto-sync: recovered rotation" \
        "report-only mode must never write" || return 1
    local dirt
    dirt=$(_tracked_dirt "$TEST_TMPDIR/repo")
    assert_contains "$dirt" "session-context.md"
}
run_test "gh-8: recovery does nothing without --pull" test_gh8_readonly_mode_never_commits

# A lone untracked marker is not worth a commit: CONFIG_REPO_DIRTY (checks/18)
# filters '??', so there is no warning to clear — while committing the marker
# would make it tracked and manufacture future dirt when it gets removed.
test_gh8_lone_untracked_marker_noop() {
    _mk_rotation_repo "$TEST_TMPDIR/repo" "$TEST_TMPDIR/remote.git"
    printf 'deadbeef 1789369158\n' > "$TEST_TMPDIR/repo/.post-rotation-commit"

    local out rc=0
    out=$(cd "$TEST_TMPDIR/repo" && bash "$SYNC_SCRIPT" --pull 2>&1) || rc=$?
    assert_eq "0" "$rc" || return 1
    assert_contains "$out" "Up to date" || return 1

    local log
    log=$(cd "$TEST_TMPDIR/repo" && git log --oneline -1)
    assert_not_contains "$log" "Auto-sync: recovered rotation" || return 1
    assert_eq "" "$(cd "$TEST_TMPDIR/repo" && git ls-files .post-rotation-commit)" || return 1
    assert_file_exists "$TEST_TMPDIR/repo/.post-rotation-commit"
}
run_test "gh-8: a lone untracked marker stays untracked" test_gh8_lone_untracked_marker_noop

test_gh8_unrelated_untracked_dont_block() {
    _mk_rotation_repo "$TEST_TMPDIR/repo" "$TEST_TMPDIR/remote.git"
    _rotate_dirt "$TEST_TMPDIR/repo"
    # Scratch files a config repo routinely carries — must not block recovery,
    # and must not be swept into the commit either.
    printf 'scratch\n' > "$TEST_TMPDIR/repo/scratch.txt"
    mkdir -p "$TEST_TMPDIR/repo/tmp" && printf 'junk\n' > "$TEST_TMPDIR/repo/tmp/junk.log"

    local out rc=0
    out=$(cd "$TEST_TMPDIR/repo" && bash "$SYNC_SCRIPT" --pull 2>&1) || rc=$?
    assert_eq "0" "$rc" || return 1
    assert_eq "" "$(_tracked_dirt "$TEST_TMPDIR/repo")" \
        "unrelated untracked files must not block recovery" || return 1

    local committed
    committed=$(cd "$TEST_TMPDIR/repo" && git show --name-only --format= HEAD)
    assert_not_contains "$committed" "scratch.txt" || return 1
    assert_not_contains "$committed" "tmp/junk.log" || return 1
    assert_file_exists "$TEST_TMPDIR/repo/scratch.txt"
}
run_test "gh-8: unrelated untracked files neither block nor enter the commit" test_gh8_unrelated_untracked_dont_block

# Dual-remote projects: the recovery push must target the PRIVATE remote only.
# The public remote is write-only via filtered-push — a raw push there would
# contaminate it with unfiltered content.
test_gh8_dual_remote_pushes_private_only() {
    create_bare_repo "$TEST_TMPDIR/private.git"
    create_bare_repo "$TEST_TMPDIR/public.git"
    create_git_repo "$TEST_TMPDIR/repo"
    (
        cd "$TEST_TMPDIR/repo"
        mkdir -p docs
        printf '# Session Context\n\n- **Session Goal**: previous session work\n' > session-context.md
        printf '# Session Log\n\n### 2026-01-01\nold entry\n' > docs/session-log.md
        git add session-context.md docs/session-log.md
        git commit -m "add session files" >/dev/null 2>&1
        git remote add private "$TEST_TMPDIR/private.git"
        git remote add public "$TEST_TMPDIR/public.git"
        local branch; branch=$(git branch --show-current)
        git push -u private "$branch" --quiet 2>/dev/null
        git push public "$branch" --quiet 2>/dev/null
    )
    cat > "$TEST_TMPDIR/repo/.push-filter.conf" <<'EOF'
private_remote=private
public_remote=public
branch=main
EOF
    _rotate_dirt "$TEST_TMPDIR/repo"

    local out rc=0
    out=$(cd "$TEST_TMPDIR/repo" && bash "$SYNC_SCRIPT" --pull 2>&1) || rc=$?
    assert_eq "0" "$rc" || return 1
    assert_eq "" "$(_tracked_dirt "$TEST_TMPDIR/repo")" || return 1

    local priv_subject pub_log
    priv_subject=$(git -C "$TEST_TMPDIR/private.git" log --format=%s -1 2>/dev/null)
    assert_contains "$priv_subject" "Auto-sync: recovered rotation" \
        "recovery commit must reach the private remote" || return 1
    pub_log=$(git -C "$TEST_TMPDIR/public.git" log --format=%s 2>/dev/null)
    assert_not_contains "$pub_log" "Auto-sync: recovered rotation" \
        "recovery must never push to the write-only public remote"
}
run_test "gh-8: dual-remote recovery pushes to the private remote only" test_gh8_dual_remote_pushes_private_only

test_gh8_tracked_work_blocks_recovery() {
    _mk_rotation_repo "$TEST_TMPDIR/repo" "$TEST_TMPDIR/remote.git"
    _rotate_dirt "$TEST_TMPDIR/repo"
    printf 'work in progress\n' >> "$TEST_TMPDIR/repo/README.md"

    local out rc=0
    out=$(cd "$TEST_TMPDIR/repo" && bash "$SYNC_SCRIPT" --pull 2>&1) || rc=$?
    assert_eq "0" "$rc" || return 1

    local log
    log=$(cd "$TEST_TMPDIR/repo" && git log --oneline -1)
    assert_not_contains "$log" "Auto-sync: recovered rotation" \
        "tracked non-rotation changes must block recovery entirely" || return 1
    local dirt
    dirt=$(_tracked_dirt "$TEST_TMPDIR/repo")
    assert_contains "$dirt" "README.md" "work in progress must be left alone"
}
run_test "gh-8: tracked work in progress blocks recovery" test_gh8_tracked_work_blocks_recovery

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
