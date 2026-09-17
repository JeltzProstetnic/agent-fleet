#!/usr/bin/env bash
# Tests for CFG-328: first-run mode (.setup-pending) suppresses non-critical checks
source "$(dirname "$0")/test-helpers.sh"
source "$(dirname "$0")/test-check-helpers.sh"

suite_header "config-check.sh: first-run mode (CFG-328)"

# ── 1. First-run mode emits info message ─────────────────────────────────────

test_first_run_emits_info() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create .setup-pending marker
    touch "$config_repo/.setup-pending"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "First-run mode" "should emit first-run info message"
    assert_contains "$output" ".setup-pending" "should mention .setup-pending marker"
}
run_test "first-run: emits info message when .setup-pending exists" test_first_run_emits_info

# ── 2. First-run mode still runs critical check 01 (sync-state) ─────────────

test_first_run_runs_sync_state() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    # Don't create symlink so check 1.2 fires
    echo "not a symlink" > "$mock_home/.claude/CLAUDE.md"

    # Create .setup-pending marker
    touch "$config_repo/.setup-pending"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "CLAUDE.md is not symlinked" \
        "should still run check 01 (sync-state) in first-run mode"
}
run_test "first-run: still runs critical check 01 (symlink health)" test_first_run_runs_sync_state

# ── 3. First-run mode still runs critical check 06a (session identity) ───────

test_first_run_runs_session_identity() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create .setup-pending marker
    touch "$config_repo/.setup-pending"

    # Set persona to verify 06a runs
    echo "TestPersona" > "$mock_home/.claude/.active-persona"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "HOSTNAME:" \
        "should still inject HOSTNAME in first-run mode (check 06a)"
    assert_contains "$output" "PERSONA: TestPersona" \
        "should still inject PERSONA in first-run mode (check 06a)"
}
run_test "first-run: still runs critical check 06a (session identity)" test_first_run_runs_session_identity

# ── 4. First-run mode suppresses plugin integrity (check 11) ────────────────

test_first_run_suppresses_plugin_integrity() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create .setup-pending marker
    touch "$config_repo/.setup-pending"

    # DON'T create plugin files — normally this triggers PLUGIN_INTEGRITY warning

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_not_contains "$output" "PLUGIN_INTEGRITY" \
        "should suppress plugin integrity check in first-run mode"
}
run_test "first-run: suppresses plugin integrity check (check 11)" test_first_run_suppresses_plugin_integrity

# ── 5. First-run mode suppresses scaling thresholds (check 13) ──────────────

test_first_run_suppresses_scaling() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create .setup-pending marker
    touch "$config_repo/.setup-pending"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_not_contains "$output" "SCALING:" \
        "should suppress scaling threshold check in first-run mode"
}
run_test "first-run: suppresses scaling thresholds (check 13)" test_first_run_suppresses_scaling

# ── 6. First-run mode suppresses backlog health (check 15b) ─────────────────

test_first_run_suppresses_backlog_health() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create .setup-pending marker
    touch "$config_repo/.setup-pending"

    # Create a backlog with P0 items that would normally trigger warning
    cat > "$project_dir/backlog.md" << 'EOF'
# Backlog
- [ ] [P0] `CFG-999` Critical item
- [ ] [P0] `CFG-998` Another critical item
EOF

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_not_contains "$output" "BACKLOG_HEALTH" \
        "should suppress backlog health check in first-run mode"
}
run_test "first-run: suppresses backlog health (check 15b)" test_first_run_suppresses_backlog_health

# ── 7. First-run mode suppresses deployed drift (check 16) ──────────────────

test_first_run_suppresses_deployed_drift() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create .setup-pending marker
    touch "$config_repo/.setup-pending"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_not_contains "$output" "DEPLOYED_DRIFT" \
        "should suppress deployed drift check in first-run mode"
}
run_test "first-run: suppresses deployed drift (check 16)" test_first_run_suppresses_deployed_drift

# ── 8. First-run mode suppresses fleet updates (check 17) ───────────────────

test_first_run_suppresses_fleet_updates() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create .setup-pending marker
    touch "$config_repo/.setup-pending"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_not_contains "$output" "FLEET_UPDATE" \
        "should suppress fleet update check in first-run mode"
}
run_test "first-run: suppresses fleet updates (check 17)" test_first_run_suppresses_fleet_updates

# ── 9. Normal mode (no .setup-pending) runs all checks ──────────────────────

test_normal_mode_runs_all_checks() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # NO .setup-pending marker
    # DON'T create plugin files — should trigger PLUGIN_INTEGRITY

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_not_contains "$output" "First-run mode" \
        "should not emit first-run message without .setup-pending"
    assert_contains "$output" "PLUGIN_INTEGRITY" \
        "should run plugin integrity check in normal mode"
}
run_test "normal mode: runs all checks (no .setup-pending)" test_normal_mode_runs_all_checks

# ── 10. First-run mode still runs check 04 (auto-fix) ───────────────────────

test_first_run_runs_autofix() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create .setup-pending marker
    touch "$config_repo/.setup-pending"

    # Create a CLAUDE.local.md with a broken @import target
    cat > "$mock_home/CLAUDE.local.md" << 'EOF'
@~/.claude/machines/nonexistent.md
EOF

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "CLAUDE.local.md @import target does not exist" \
        "should still run check 04 (auto-fix) in first-run mode"
}
run_test "first-run: still runs critical check 04 (auto-fix)" test_first_run_runs_autofix

# ── 11. First-run mode suppresses inbox/services (check 03) ─────────────────

test_first_run_suppresses_inbox() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local remote_repo="$TEST_TMPDIR/remote.git"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_tracked_repo_main "$config_repo" "$remote_repo"
    (cd "$config_repo" && touch sync.sh && git add sync.sh && git commit -m "add sync.sh" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    (cd "$config_repo" && touch CLAUDE.md && git add CLAUDE.md && git commit -m "add CLAUDE.md" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create .setup-pending marker
    touch "$config_repo/.setup-pending"

    # Create inbox with tasks — would normally trigger INBOX_TASKS
    mkdir -p "$config_repo/cross-project"
    cat > "$config_repo/cross-project/inbox.md" << 'EOF'
# Cross-Project Inbox
- [ ] **project** Task one (Source: cfg-agent-fleet 2026-03-27)
- [ ] **project** Task two (Source: cfg-agent-fleet 2026-03-27)
EOF

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_not_contains "$output" "INBOX TASKS" \
        "should suppress inbox check in first-run mode"
}
run_test "first-run: suppresses inbox/services (check 03)" test_first_run_suppresses_inbox

# ── 12. .setup-pending in PROJECT_ROOT also triggers first-run ───────────────

test_first_run_project_root_marker() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # .setup-pending in project root (= config repo git root), not config repo dir
    # In most cases PROJECT_ROOT == CONFIG_REPO, but this tests the OR condition
    touch "$config_repo/.setup-pending"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "First-run mode" \
        "should trigger first-run mode from PROJECT_ROOT .setup-pending"
}
run_test "first-run: detects .setup-pending in PROJECT_ROOT" test_first_run_project_root_marker

# ── agent-fleet GH#6: the marker has no end (defects 2 and 4) ────────────────
# First-run mode suppresses 21 of 23 SessionStart checks. Nothing anywhere
# removes `.setup-pending` — `grep -rn "rm .*setup-pending"` over the whole repo
# returns nothing; deleting it exists only as PROSE in first-run-refinement.md,
# and a step a model has to remember is exactly the kind that does not happen.
# So a machine stays in first-run mode from install until someone notices, and
# "everything was suppressed" is byte-identical to "nothing to report" — the
# same silent-empty signature the fleet already spent CFG-503, CFG-527 and
# CFG-530 chasing.
#
# Contract: first-run mode lasts exactly ONE session. The first startup sees the
# marker, arms a sibling `.setup-pending.seen`, and runs suppressed; the next
# startup finds the sibling, clears both, and the fleet is fully armed again.

test_marker_survives_the_first_session() {
    # Clearing it on sight would defeat its purpose — refinement needs its session.
    local config_repo="$TEST_TMPDIR/gh6a-repo" mock_home="$TEST_TMPDIR/gh6a-home" project_dir="$TEST_TMPDIR/gh6a-proj"
    mkdir -p "$mock_home/.claude" "$project_dir"
    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"; ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"
    touch "$config_repo/.setup-pending"

    local patched; patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output; output=$(run_hook "$patched")
    assert_contains "$output" "First-run mode" "the first startup still runs in first-run mode" || return 1
    assert_file_exists "$config_repo/.setup-pending" "the marker survives its own first session"
}
run_test "GH#6: marker survives the first session" test_marker_survives_the_first_session

test_marker_is_cleared_on_the_second_session() {
    local config_repo="$TEST_TMPDIR/gh6b-repo" mock_home="$TEST_TMPDIR/gh6b-home" project_dir="$TEST_TMPDIR/gh6b-proj"
    mkdir -p "$mock_home/.claude" "$project_dir"
    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"; ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"
    touch "$config_repo/.setup-pending"

    local patched; patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    run_hook "$patched" >/dev/null 2>&1      # session 1 — arms the sibling
    run_hook "$patched" >/dev/null 2>&1      # session 2 — must clear
    assert_file_not_exists "$config_repo/.setup-pending" "the marker is cleared after its one session" || return 1
    assert_file_not_exists "$config_repo/.setup-pending.seen" "the sibling is cleared with it, leaving no residue"
}
run_test "GH#6: marker is cleared on the second session" test_marker_is_cleared_on_the_second_session

test_full_checks_resume_after_clearing() {
    # The point of clearing it: the 21 suppressed checks must actually come back.
    local config_repo="$TEST_TMPDIR/gh6c-repo" mock_home="$TEST_TMPDIR/gh6c-home" project_dir="$TEST_TMPDIR/gh6c-proj"
    mkdir -p "$mock_home/.claude" "$project_dir"
    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"; ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"
    touch "$config_repo/.setup-pending"

    local patched; patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    run_hook "$patched" >/dev/null 2>&1
    run_hook "$patched" >/dev/null 2>&1
    local output; output=$(run_hook "$patched")     # session 3 — fully armed
    assert_not_contains "$output" "First-run mode" "first-run mode is genuinely over, not just the file gone"
}
run_test "GH#6: suppressed checks resume once the marker clears" test_full_checks_resume_after_clearing

test_config_repo_marker_emits_guidance() {
    # install.sh:48 writes the marker to CONFIG_REPO while check 1.5 reads
    # PROJECT_ROOT, which LOOKS like a gap. It is not: config-check.sh derives
    # PROJECT_ROOT from CONFIG_REPO (`git -C "$CONFIG_REPO" rev-parse
    # --show-toplevel`, falling back to CONFIG_REPO), so both names resolve to
    # the same file and the guidance does fire. Kept as a guard, because the day
    # PROJECT_ROOT starts deriving from the CWD instead, suppression would
    # silently arrive WITHOUT the instruction that explains it.
    local config_repo="$TEST_TMPDIR/gh6d-repo" mock_home="$TEST_TMPDIR/gh6d-home" project_dir="$TEST_TMPDIR/gh6d-proj"
    mkdir -p "$mock_home/.claude" "$project_dir"      # project_dir != config_repo
    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"; ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"
    touch "$config_repo/.setup-pending"               # where install.sh actually puts it

    local patched; patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output; output=$(run_hook "$patched")
    assert_contains "$output" "SETUP_PENDING" "a CONFIG_REPO marker still emits the refinement instruction"
}
run_test "GH#6: CONFIG_REPO marker emits the guidance too" test_config_repo_marker_emits_guidance

test_first_run_whitelist_resolves() {
    # GH#6 defect 4. Defect 1 of that issue was a whitelist naming a module that
    # did not exist, which silently reduced first-run mode to two checks. It was
    # fixed by accident — the file appeared later for unrelated reasons — and
    # nothing asserts it stays true. A whitelist entry that does not resolve is
    # invisible: the loop just never matches it.
    local src="$REPO_ROOT/global/hooks/config-check.sh"
    local checks_dir="$REPO_ROOT/global/hooks/checks"
    local line
    line=$(grep -n 'sync-state\.sh|' "$src" | head -1 | cut -d: -f2-)
    [[ -n "$line" ]] || { printf "    could not locate the first-run whitelist in config-check.sh\n"; return 1; }
    local names missing=""
    names=$(printf '%s' "$line" | tr -d ' )' | sed 's/^.*case.*in//' | tr '|' '\n' | grep '\.sh$')
    [[ -n "$names" ]] || { printf "    whitelist parsed to nothing — parser is stale\n"; return 1; }
    local n
    for n in $names; do
        [[ -f "$checks_dir/$n" ]] || missing="$missing $n"
    done
    assert_eq "" "$missing" "every module named in the first-run whitelist exists in checks/"
}
run_test "GH#6: first-run whitelist names only real modules" test_first_run_whitelist_resolves

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
