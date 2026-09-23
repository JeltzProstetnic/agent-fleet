#!/usr/bin/env bash
# Tests for config-check.sh — stale detection: tmp/ document scanner (check 15),
# stale pending files (check 17), enhanced severity thresholds
source "$(dirname "$0")/test-helpers.sh"
source "$(dirname "$0")/test-check-helpers.sh"

suite_header "config-check.sh: stale detection (checks 15, 17)"

# ── 22. Check 15: tmp/ document scanner ──────────────────────────────────────

test_tmp_document_scanner_detects_files() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create project with documents in tmp/
    mkdir -p "$mock_home/myproject/tmp"
    echo "# Draft" > "$mock_home/myproject/tmp/draft-letter.md"
    echo "PDF content" > "$mock_home/myproject/tmp/report.pdf"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "Documents found in project tmp/" "should warn about documents in tmp/"
}
run_test "check 15: warns when documents found in project tmp/ dirs" test_tmp_document_scanner_detects_files

test_tmp_document_scanner_ignores_non_docs() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local remote_repo="$TEST_TMPDIR/remote.git"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_tracked_repo_main "$config_repo" "$remote_repo"
    (cd "$config_repo" && touch sync.sh && git add sync.sh && git commit -m "add sync.sh" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    (cd "$config_repo" && touch CLAUDE.md && git add CLAUDE.md && git commit -m "add CLAUDE.md" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create project with only non-document files in tmp/
    mkdir -p "$mock_home/myproject/tmp"
    echo "data" > "$mock_home/myproject/tmp/cache.json"
    echo "log" > "$mock_home/myproject/tmp/output.log"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_not_contains "$output" "Documents found in project tmp/" "should NOT warn for non-document files"
}
run_test "check 15: ignores non-document files in tmp/" test_tmp_document_scanner_ignores_non_docs

# ── 22b. Check 15 enhancement: git-behind hint (CFG-130) ─────────────────────

test_tmp_scanner_adds_behind_hint_when_repo_behind() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local remote_repo="$TEST_TMPDIR/remote.git"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_tracked_repo_main "$config_repo" "$remote_repo"
    (cd "$config_repo" && touch sync.sh && git add sync.sh && git commit -m "add sync.sh" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    (cd "$config_repo" && touch CLAUDE.md && git add CLAUDE.md && git commit -m "add CLAUDE.md" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create a project that has docs in tmp/ AND is behind remote
    local proj_remote="$TEST_TMPDIR/proj-remote.git"
    local proj_dir="$mock_home/myproject"
    create_tracked_repo_main "$proj_dir" "$proj_remote"
    mkdir -p "$proj_dir/tmp"
    echo "# Draft" > "$proj_dir/tmp/draft.md"

    # Push a commit to remote that local doesn't have
    local clone_tmp="$TEST_TMPDIR/clone-tmp"
    git clone "$proj_remote" "$clone_tmp" >/dev/null 2>&1
    (cd "$clone_tmp" && git config user.email "test@test.com" && git config user.name "Test" && echo "new" > newfile.txt && git add newfile.txt && git commit -m "remote commit" >/dev/null 2>&1 && git push >/dev/null 2>&1)

    # Fetch so local knows about remote commits (but don't pull)
    (cd "$proj_dir" && git fetch origin >/dev/null 2>&1)

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "Documents found in project tmp/" "should still warn about tmp docs"
    assert_contains "$output" "repo behind remote" "should add behind-remote hint"
}
run_test "check 15: adds behind-remote hint when project repo is behind (CFG-130)" test_tmp_scanner_adds_behind_hint_when_repo_behind

test_tmp_scanner_no_hint_when_repo_up_to_date() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local remote_repo="$TEST_TMPDIR/remote.git"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_tracked_repo_main "$config_repo" "$remote_repo"
    (cd "$config_repo" && touch sync.sh && git add sync.sh && git commit -m "add sync.sh" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    (cd "$config_repo" && touch CLAUDE.md && git add CLAUDE.md && git commit -m "add CLAUDE.md" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create a project that has docs in tmp/ but is up to date
    local proj_remote="$TEST_TMPDIR/proj-remote2.git"
    local proj_dir="$mock_home/myproject2"
    create_tracked_repo_main "$proj_dir" "$proj_remote"
    mkdir -p "$proj_dir/tmp"
    echo "# Draft" > "$proj_dir/tmp/draft.md"
    # Repo is up to date — no hint should appear

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "Documents found in project tmp/" "should still warn about tmp docs"
    assert_not_contains "$output" "repo behind remote" "should NOT add hint when up to date"
}
run_test "check 15: no behind-remote hint when repo is up to date (CFG-130)" test_tmp_scanner_no_hint_when_repo_up_to_date

# ── 24. Check 17: Stale pending files (severity-differentiated) ─────────────

test_stale_generic_untracked_warning() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create stale pending file (3 days, no Action header, untracked)
    mkdir -p "$config_repo/docs"
    echo "old task" > "$config_repo/docs/pending-old-task.md"
    touch -d "3 days ago" "$config_repo/docs/pending-old-task.md"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "Stale pending files:" "should show generic stale warning"
    assert_contains "$output" "pending-old-task.md" "should name the stale file"
    assert_contains "$output" "no backlog item" "should flag as untracked from backlog"
}
run_test "check 17: generic stale warning for untracked >2d files" test_stale_generic_untracked_warning

test_fresh_pending_no_warning() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local remote_repo="$TEST_TMPDIR/remote.git"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_tracked_repo_main "$config_repo" "$remote_repo"
    (cd "$config_repo" && touch sync.sh && git add sync.sh && git commit -m "add sync.sh" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    (cd "$config_repo" && touch CLAUDE.md && git add CLAUDE.md && git commit -m "add CLAUDE.md" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    mkdir -p "$config_repo/docs"
    echo "fresh task" > "$config_repo/docs/pending-fresh-task.md"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_not_contains "$output" "STALE_" "should NOT warn about fresh pending files"
    assert_not_contains "$output" "Stale pending files:" "should NOT show generic stale warning"
}
run_test "check 17: no warning for pending files less than 2 days old" test_fresh_pending_no_warning

test_stale_tracked_no_warning() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Stale file, but tracked in backlog → no warning
    mkdir -p "$config_repo/docs"
    echo "old task" > "$config_repo/docs/pending-old-task.md"
    touch -d "3 days ago" "$config_repo/docs/pending-old-task.md"
    cat > "$config_repo/backlog.md" << 'EOF'
# Backlog
- [ ] [P1] `CFG-99` **Old task**: References pending-old-task.md
EOF

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_not_contains "$output" "Stale pending files:" "tracked files should not trigger generic stale warning"
    assert_not_contains "$output" "STALE_DEFER" "tracked files should not trigger STALE_DEFER"
}
run_test "check 17: tracked stale file — no warning" test_stale_tracked_no_warning

test_stale_tracked_by_header_no_warning() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Reference file with Tracked-by header but filename NOT in backlog
    mkdir -p "$config_repo/docs"
    cat > "$config_repo/docs/pending-chaos-audit.md" << 'EOF'
Action: reference
Tracked-by: CFG-196

# Chaos audit findings
EOF
    touch -d "5 days ago" "$config_repo/docs/pending-chaos-audit.md"
    cat > "$config_repo/backlog.md" << 'EOF'
# Backlog
- [ ] [P2] `CFG-196` **FMS chaos audit**: Reclassification plan
EOF

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_not_contains "$output" "no backlog item" "Tracked-by header should count as tracked"
    assert_not_contains "$output" "Stale pending files:" "reference files with Tracked-by should not trigger stale warning"
}
run_test "check 17: Tracked-by header counts as tracked — no warning" test_stale_tracked_by_header_no_warning

# CFG-496: every real pending file writes the header as an HTML comment
# (`<!-- Tracked-by: CFG-xxx -->`), not bare. The bare-form fixture above passed
# while all six live files were reported as "no backlog item" every session.
test_stale_comment_form_tracked_by() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    setup_stale_dirs "$config_repo" "$mock_home" "$project_dir" 2>/dev/null || {
        mkdir -p "$config_repo/docs" "$mock_home" "$project_dir"; }
    cat > "$config_repo/docs/pending-comment-form.md" << 'EOF'
<!-- Action: reference -->
<!-- Tracked-by: CFG-196 -->
# Handover held for context
EOF
    touch -d "9 days ago" "$config_repo/docs/pending-comment-form.md"
    cat > "$config_repo/backlog.md" << 'EOF'
# Backlog
- [ ] [P2] `CFG-196` **Still open**: work continues
EOF
    local patched output
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    output=$(run_hook "$patched")

    assert_not_contains "$output" "pending-comment-form.md" \
        "comment-form Tracked-by must count as tracked" || return 1
}
run_test "check 17: comment-form <!-- Tracked-by --> counts as tracked" test_stale_comment_form_tracked_by

test_stale_all_tracked_items_closed_is_actionable() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    setup_stale_dirs "$config_repo" "$mock_home" "$project_dir" 2>/dev/null || {
        mkdir -p "$config_repo/docs" "$mock_home" "$project_dir"; }
    cat > "$config_repo/docs/pending-all-done.md" << 'EOF'
<!-- Action: reference -->
<!-- Tracked-by: CFG-201, CFG-202 -->
# Superseded handover
EOF
    touch -d "9 days ago" "$config_repo/docs/pending-all-done.md"
    cat > "$config_repo/backlog.md" << 'EOF'
# Backlog
- [x] [P2] `CFG-201` **Done**: shipped
- [x] [P3] `CFG-202` **Done**: shipped
EOF
    local patched output
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    output=$(run_hook "$patched")

    assert_contains "$output" "pending-all-done.md" \
        "a file whose tracked items are ALL closed is the genuinely actionable case" || return 1
    assert_contains "$output" "safe to delete" \
        "the warning must say what to do, not just that the file is old" || return 1
}
run_test "check 17: all tracked items closed → safe to delete" test_stale_all_tracked_items_closed_is_actionable

test_stale_act_severity() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Action: act file, 4 days old (over 3-day threshold)
    mkdir -p "$config_repo/docs"
    printf "# Urgent\nAction: act\n\nDo this now.\n" > "$config_repo/docs/pending-urgent.md"
    touch -d "4 days ago" "$config_repo/docs/pending-urgent.md"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "STALE_ACT" "should show STALE_ACT severity tag"
    assert_contains "$output" "pending-urgent.md" "should name the file"
}
run_test "check 17: STALE_ACT for act files >3d" test_stale_act_severity

test_stale_defer_severity() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Action: defer file, 15 days old, untracked
    mkdir -p "$config_repo/docs"
    printf "# Old defer\nAction: defer\n\nOld plan.\n" > "$config_repo/docs/pending-old-defer.md"
    touch -d "15 days ago" "$config_repo/docs/pending-old-defer.md"
    cat > "$config_repo/backlog.md" << 'EOF'
# Backlog
- [ ] [P1] `CFG-01` **Unrelated**: no reference
EOF

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "STALE_DEFER" "should show STALE_DEFER severity tag"
    assert_contains "$output" "pending-old-defer.md" "should name the file"
}
run_test "check 17: STALE_DEFER for untracked defer >14d" test_stale_defer_severity

test_stale_await_severity() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Action: await-user-decision, backlog item is [x] done
    mkdir -p "$config_repo/docs"
    printf "# Decision\nAction: await-user-decision\n\nWaiting.\n" > "$config_repo/docs/pending-decision.md"
    cat > "$config_repo/backlog.md" << 'EOF'
# Backlog
- [x] [P1] `CFG-77` **Decided**: See pending-decision.md
EOF

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "STALE_AWAIT" "should show STALE_AWAIT severity tag"
    assert_contains "$output" "pending-decision.md" "should name the file"
}
run_test "check 17: STALE_AWAIT when all backlog items done" test_stale_await_severity

test_stale_await_keeps_open() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Action: await-user-decision, backlog item is [ ] open
    mkdir -p "$config_repo/docs"
    printf "# Decision\nAction: await-user-decision\n\nWaiting.\n" > "$config_repo/docs/pending-decision.md"
    cat > "$config_repo/backlog.md" << 'EOF'
# Backlog
- [ ] [P1] `CFG-77` **Still open**: See pending-decision.md
EOF

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_not_contains "$output" "STALE_AWAIT" "should NOT show STALE_AWAIT when items still open"
}
run_test "check 17: no STALE_AWAIT when backlog items still open" test_stale_await_keeps_open

# ── 27. Check 17 enhanced severity thresholds ────────────────────────────────

test_stale_act_under_3d_no_warning() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Action: act file, 2 days old (under the 3-day threshold)
    mkdir -p "$config_repo/docs"
    printf "# Task\nAction: act\n\nDo this.\n" > "$config_repo/docs/pending-recent-act.md"
    touch -d "2 days ago" "$config_repo/docs/pending-recent-act.md"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_not_contains "$output" "STALE_ACT" "should NOT show STALE_ACT for act files under 3 days old"
}
run_test "check 17: no STALE_ACT for act files under 3d" test_stale_act_under_3d_no_warning

test_stale_act_over_3d_warning() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Action: act file, 4 days old (over the 3-day threshold)
    mkdir -p "$config_repo/docs"
    printf "# Task\nAction: act\n\nDo this.\n" > "$config_repo/docs/pending-old-act.md"
    touch -d "4 days ago" "$config_repo/docs/pending-old-act.md"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "STALE_ACT" "should show STALE_ACT for act files over 3 days old"
    assert_contains "$output" "pending-old-act.md" "should name the file"
}
run_test "check 17: STALE_ACT for act files over 3d" test_stale_act_over_3d_warning

# CFG-482: real pending files write `<!-- Action: act -->`, so the bare-form-only
# parser classified every one of them as unknown and STALE_ACT never fired either.
test_stale_act_comment_form_over_3d() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    mkdir -p "$config_repo/docs"
    printf "<!-- Action: act -->\n# Task\n\nDo this.\n" > "$config_repo/docs/pending-comment-act.md"
    touch -d "4 days ago" "$config_repo/docs/pending-comment-act.md"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "STALE_ACT" "comment-form act file must trigger STALE_ACT" || return 1
    assert_contains "$output" "pending-comment-act.md" "should name the comment-form file" || return 1
}
run_test "check 17 (CFG-482): comment-form Action: act triggers STALE_ACT" test_stale_act_comment_form_over_3d

test_stale_await_age_based_over_7d() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Action: await-user-decision file, 8 days old, backlog items still open
    mkdir -p "$config_repo/docs"
    printf "# Decision\nAction: await-user-decision\n\nWaiting for user.\n" > "$config_repo/docs/pending-old-await.md"
    touch -d "8 days ago" "$config_repo/docs/pending-old-await.md"
    cat > "$config_repo/backlog.md" << 'EOF'
# Backlog
- [ ] [P1] `CFG-88` **Still open**: See pending-old-await.md
EOF

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "STALE_AWAIT" "should show STALE_AWAIT for await files over 7 days old"
    assert_contains "$output" "pending-old-await.md" "should name the file"
    assert_contains "$output" "user needs a nudge" "should include nudge hint"
}
run_test "check 17: STALE_AWAIT for await-user-decision files over 7d" test_stale_await_age_based_over_7d

test_stale_await_under_7d_open_no_warning() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Action: await-user-decision file, 5 days old (under 7d), backlog items still open
    mkdir -p "$config_repo/docs"
    printf "# Decision\nAction: await-user-decision\n\nWaiting.\n" > "$config_repo/docs/pending-recent-await.md"
    touch -d "5 days ago" "$config_repo/docs/pending-recent-await.md"
    cat > "$config_repo/backlog.md" << 'EOF'
# Backlog
- [ ] [P1] `CFG-90` **Still open**: See pending-recent-await.md
EOF

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_not_contains "$output" "STALE_AWAIT" "should NOT show STALE_AWAIT for await files under 7 days"
}
run_test "check 17: no STALE_AWAIT for await files under 7d with open items" test_stale_await_under_7d_open_no_warning

# ── 28. Check 5.4: Inbox staleness — escalation tier (CFG-243) ──────────────

test_inbox_escalate_14d_items() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create inbox with items older than 14 days
    mkdir -p "$config_repo/cross-project"
    cat > "$config_repo/cross-project/inbox.md" << 'EOF'
# Cross-Project Inbox

## Pending

- [ ] **proj-a**: Old task A. Source: scan 2026-03-01.
- [ ] **proj-b**: Old task B. Source: scan 2026-03-02.
- [ ] **proj-c**: Old task C. Source: scan 2026-03-03.
- [ ] **proj-d**: Old task D. Source: scan 2026-03-04.
EOF

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "[ESCALATE]" "should show ESCALATE tag for 14+ day items"
    assert_contains "$output" "older than 14 days" "should mention 14 days in escalation"
    assert_contains "$output" "promote to project backlogs or delete" "should suggest promotion or deletion"
}
run_test "check 5.4: ESCALATE for inbox items older than 14 days (CFG-243)" test_inbox_escalate_14d_items

test_inbox_warn_only_7_to_13d() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create inbox with items 8-13 days old (warn but no escalate)
    # Use dates relative to today
    local _d8 _d9 _d10
    _d8=$(date -d "8 days ago" +%Y-%m-%d)
    _d9=$(date -d "9 days ago" +%Y-%m-%d)
    _d10=$(date -d "10 days ago" +%Y-%m-%d)

    mkdir -p "$config_repo/cross-project"
    cat > "$config_repo/cross-project/inbox.md" << EOF
# Cross-Project Inbox

## Pending

- [ ] **proj-a**: Task A. Source: scan $_d8.
- [ ] **proj-b**: Task B. Source: scan $_d9.
- [ ] **proj-c**: Task C. Source: scan $_d10.
EOF

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "[WARN] Cross-project inbox:" "should show WARN for 7+ day items"
    assert_not_contains "$output" "[ESCALATE]" "should NOT show ESCALATE for items under 14 days"
}
run_test "check 5.4: WARN but no ESCALATE for inbox items 7-13 days old (CFG-243)" test_inbox_warn_only_7_to_13d

test_inbox_escalate_count_accuracy() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Mix: 2 items at 14+ days, 2 items at 8-13 days
    local _d8 _d10 _d20 _d25
    _d8=$(date -d "8 days ago" +%Y-%m-%d)
    _d10=$(date -d "10 days ago" +%Y-%m-%d)
    _d20=$(date -d "20 days ago" +%Y-%m-%d)
    _d25=$(date -d "25 days ago" +%Y-%m-%d)

    mkdir -p "$config_repo/cross-project"
    cat > "$config_repo/cross-project/inbox.md" << EOF
# Cross-Project Inbox

## Pending

- [ ] **proj-a**: Recent stale. Source: scan $_d8.
- [ ] **proj-b**: Recent stale. Source: scan $_d10.
- [ ] **proj-c**: Old item. Source: scan $_d20.
- [ ] **proj-d**: Very old item. Source: scan $_d25.
EOF

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    # 4 items total older than 7 days
    assert_contains "$output" "[WARN] Cross-project inbox: 4 items older than 7 days" "should count all 4 stale items"
    # 2 items older than 14 days
    assert_contains "$output" "[ESCALATE] Cross-project inbox: 2 items older than 14 days" "should count exactly 2 escalated items"
}
run_test "check 5.4: correct counts for mixed 7-13d and 14+d inbox items (CFG-243)" test_inbox_escalate_count_accuracy

test_inbox_no_escalate_checked_items() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Checked items (done) should not trigger escalation even if old
    local _d30
    _d30=$(date -d "30 days ago" +%Y-%m-%d)

    mkdir -p "$config_repo/cross-project"
    cat > "$config_repo/cross-project/inbox.md" << EOF
# Cross-Project Inbox

## Pending

- [x] **proj-a**: ~~Done task.~~ Source: scan $_d30.
- [x] **proj-b**: ~~Done task 2.~~ Source: scan $_d30.
- [x] **proj-c**: ~~Done task 3.~~ Source: scan $_d30.
EOF

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_not_contains "$output" "[WARN] Cross-project inbox:" "should NOT warn for checked items"
    assert_not_contains "$output" "[ESCALATE]" "should NOT escalate for checked items"
}
run_test "check 5.4: no ESCALATE for completed (checked) inbox items (CFG-243)" test_inbox_no_escalate_checked_items

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
