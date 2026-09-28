#!/usr/bin/env bash
# Tests for global/hooks/checks/06c-conversation-log-gap.sh
# Soft check: warns when docs/conversation-log.md lags the HEAD "Session N:" commit.
source "$(dirname "$0")/test-helpers.sh"
source "$(dirname "$0")/test-check-helpers.sh"

suite_header "config-check.sh: conversation-log gap (check 6c)"

# Helper: initialize a project as a git repo with a "Session N: ..." HEAD commit
_init_project_with_commit() {
    local dir="$1"
    local session_num="$2"
    mkdir -p "$dir/docs"
    (
        cd "$dir"
        git init -b main >/dev/null 2>&1
        git config user.email test@test
        git config user.name test
        echo content > file.txt
        git add file.txt
        git commit -m "Session ${session_num}: work" >/dev/null 2>&1
    )
}

_write_conv_log() {
    local dir="$1"
    local last_session="$2"
    cat > "$dir/docs/conversation-log.md" << EOF
# Conversation Log

## Session ${last_session} — 2026-04-01 (wsl)

Log content here.
EOF
}

# ── Case 1: no conversation-log.md → silent skip ─────────────────────────────
test_no_log_file_silent_skip() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude"
    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"
    _init_project_with_commit "$project_dir" 184
    create_mock_plugin_files "$mock_home"

    local patched output
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    output=$(run_hook "$patched")

    assert_not_contains "$output" "conversation-log" \
        "no conversation-log.md → no warning" || return 1
}
run_test "check 6c: missing conversation-log.md is silent" test_no_log_file_silent_skip

# ── Case 2: log at 180, commit at 184 → warn (gap 4) ─────────────────────────
test_gap_of_four_warns() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude"
    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"
    _init_project_with_commit "$project_dir" 184
    _write_conv_log "$project_dir" 180
    create_mock_plugin_files "$mock_home"

    local patched output
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    output=$(run_hook "$patched")

    assert_contains "$output" "conversation-log.md lags by 4 sessions" \
        "gap of 4 should produce warning" || return 1
    assert_contains "$output" "log: 180" "warning should mention log session" || return 1
    assert_contains "$output" "HEAD commit: 184" "warning should mention commit session" || return 1
}
run_test "check 6c: gap of 4 sessions produces warning" test_gap_of_four_warns

# ── Case 3: log at 184, commit at 184 → no warn ──────────────────────────────
test_no_gap_no_warn() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude"
    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"
    _init_project_with_commit "$project_dir" 184
    _write_conv_log "$project_dir" 184
    create_mock_plugin_files "$mock_home"

    local patched output
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    output=$(run_hook "$patched")

    assert_not_contains "$output" "conversation-log.md lags" \
        "no gap → no warning" || return 1
}
run_test "check 6c: no gap produces no warning" test_no_gap_no_warn

# ── Case 4: log at 184, commit at 185 (gap 1) → no warn (threshold is 2) ─────
test_gap_of_one_no_warn() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude"
    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"
    _init_project_with_commit "$project_dir" 185
    _write_conv_log "$project_dir" 184
    create_mock_plugin_files "$mock_home"

    local patched output
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    output=$(run_hook "$patched")

    assert_not_contains "$output" "conversation-log.md lags" \
        "gap of 1 stays below threshold (2)" || return 1
}
run_test "check 6c: gap of 1 stays below threshold" test_gap_of_one_no_warn

# ── Case 5: commit subject lacks "Session N:" → silent (no data to compare) ──
test_commit_without_session_prefix_silent() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir/docs"
    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"
    (
        cd "$project_dir"
        git init -b main >/dev/null 2>&1
        git config user.email t@t
        git config user.name t
        echo x > a
        git add a
        git commit -m "Fix: unrelated commit format" >/dev/null 2>&1
    )
    _write_conv_log "$project_dir" 100
    create_mock_plugin_files "$mock_home"

    local patched output
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    output=$(run_hook "$patched")

    assert_not_contains "$output" "conversation-log.md lags" \
        "unparseable commit subject → silent skip" || return 1
}
run_test "check 6c: commit without 'Session N:' prefix is silent" test_commit_without_session_prefix_silent

# ── Case 6: three-hash "### Session N" headings must be detected (seen in one project from S207) ─
_write_conv_log_3hash() {
    local dir="$1"; local last="$2"
    cat > "$dir/docs/conversation-log.md" << EOF
# Conversation Log

### Session ${last} — 2026-04-01 (wsl)

Log content here.
EOF
}
test_three_hash_heading_detected() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude"
    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"
    _init_project_with_commit "$project_dir" 184
    _write_conv_log_3hash "$project_dir" 180
    create_mock_plugin_files "$mock_home"

    local patched output
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    output=$(run_hook "$patched")

    assert_contains "$output" "conversation-log.md lags by 4 sessions" \
        "three-hash '### Session' heading must be parsed (gap 4)" || return 1
    assert_contains "$output" "log: 180" "should read the 3-hash session number" || return 1
}
run_test "check 6c: three-hash '### Session' headings detected" test_three_hash_heading_detected

# ── Case 7: MAX heading, not the FIRST (forward-chron / newest-first index) ───
_write_conv_log_multi() {
    local dir="$1"
    cat > "$dir/docs/conversation-log.md" << EOF
# Conversation Log

## Session 182 — 2026-03-30 (wsl)
## Session 183 — 2026-03-31 (wsl)
## Session 184 — 2026-04-01 (wsl)

Body content.
EOF
}
test_max_not_first_no_false_warn() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude"
    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"
    _init_project_with_commit "$project_dir" 184
    _write_conv_log_multi "$project_dir"
    create_mock_plugin_files "$mock_home"

    local patched output
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    output=$(run_hook "$patched")

    assert_not_contains "$output" "conversation-log.md lags" \
        "must take the MAX heading (184), not the first (182) → no false gap" || return 1
}
run_test "check 6c: takes max session heading, not first" test_max_not_first_no_false_warn

suite_summary
