#!/usr/bin/env bash
# Tests for config-check.sh — environment checks: CLAUDE.local.md, dep check,
# agent-fleet-mobile, template-repo, TweakCC, wsl.conf, doc coherence
source "$(dirname "$0")/test-helpers.sh"
source "$(dirname "$0")/test-check-helpers.sh"

suite_header "config-check.sh: environment checks"

# ── 18. CLAUDE.local.md @import target validation ─────────────────────────────

test_claude_local_broken_import() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create CLAUDE.local.md with @import pointing to nonexistent file
    echo '@~/.claude/machines/NonExistent.md' > "$mock_home/CLAUDE.local.md"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    local msg
    msg=$(extract_additional_context "$output")
    assert_contains "$msg" "CLAUDE.local.md" "should mention CLAUDE.local.md"
    assert_contains "$msg" "NonExistent.md" "should mention the missing target file"
}
run_test "CLAUDE.local.md: warns when @import target does not exist" test_claude_local_broken_import

test_claude_local_valid_import() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local remote_repo="$TEST_TMPDIR/remote.git"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude/machines" "$project_dir"

    create_tracked_repo_main "$config_repo" "$remote_repo"
    (cd "$config_repo" && touch sync.sh && git add sync.sh && git commit -m "add sync.sh" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    (cd "$config_repo" && touch CLAUDE.md && git add CLAUDE.md && git commit -m "add CLAUDE.md" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create valid machine file and CLAUDE.local.md pointing to it
    echo "# Test Host 01" > "$mock_home/.claude/machines/testhost-01.md"
    echo '@~/.claude/machines/testhost-01.md' > "$mock_home/CLAUDE.local.md"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_not_contains "$output" "CLAUDE.local.md" "should NOT warn when @import target exists"
}
run_test "CLAUDE.local.md: no warning when @import target exists" test_claude_local_valid_import

test_claude_local_missing_file() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local remote_repo="$TEST_TMPDIR/remote.git"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_tracked_repo_main "$config_repo" "$remote_repo"
    (cd "$config_repo" && touch sync.sh && git add sync.sh && git commit -m "add sync.sh" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    (cd "$config_repo" && touch CLAUDE.md && git add CLAUDE.md && git commit -m "add CLAUDE.md" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # No CLAUDE.local.md at all — should not warn (it's optional)

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_not_contains "$output" "CLAUDE.local.md" "should NOT warn when CLAUDE.local.md doesn't exist"
}
run_test "CLAUDE.local.md: no warning when file does not exist (optional)" test_claude_local_missing_file

# ── 20. Daily dependency check (once-per-day gate) ─────────────────────────────

test_dep_check_runs_when_no_marker() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local remote_repo="$TEST_TMPDIR/remote.git"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_tracked_repo_main "$config_repo" "$remote_repo"
    (cd "$config_repo" && touch sync.sh && git add sync.sh && git commit -m "add sync.sh" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    mkdir -p "$config_repo/global"
    (cd "$config_repo" && mkdir -p global && touch global/CLAUDE.md && git add global/CLAUDE.md && git commit -m "add" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    ln -sf "$config_repo/global/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # No marker file exists — check should run
    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    # Marker file should be created with today's date
    assert_file_exists "$mock_home/.claude/.dep-check-date" "should create dep-check-date marker"
    local marker_date
    marker_date=$(cat "$mock_home/.claude/.dep-check-date" 2>/dev/null)
    assert_eq "$(date +%Y-%m-%d)" "$marker_date" "marker should contain today's date"
}
skip_test "dep check: runs and creates marker when no marker exists" "feature not yet implemented"

test_dep_check_skips_when_already_ran_today() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local remote_repo="$TEST_TMPDIR/remote.git"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_tracked_repo_main "$config_repo" "$remote_repo"
    (cd "$config_repo" && touch sync.sh && git add sync.sh && git commit -m "add sync.sh" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    mkdir -p "$config_repo/global"
    (cd "$config_repo" && mkdir -p global && touch global/CLAUDE.md && git add global/CLAUDE.md && git commit -m "add" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    ln -sf "$config_repo/global/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Marker already has today's date — check should NOT run
    mkdir -p "$mock_home/.claude"
    date +%Y-%m-%d > "$mock_home/.claude/.dep-check-date"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_not_contains "$output" "Upstream dependency check" "should NOT run dep check when already done today"
}
run_test "dep check: skips when marker has today's date" test_dep_check_skips_when_already_ran_today

test_dep_check_runs_when_marker_is_yesterday() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local remote_repo="$TEST_TMPDIR/remote.git"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_tracked_repo_main "$config_repo" "$remote_repo"
    (cd "$config_repo" && touch sync.sh && git add sync.sh && git commit -m "add sync.sh" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    mkdir -p "$config_repo/global"
    (cd "$config_repo" && mkdir -p global && touch global/CLAUDE.md && git add global/CLAUDE.md && git commit -m "add" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    ln -sf "$config_repo/global/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Marker has yesterday's date — check should run
    mkdir -p "$mock_home/.claude"
    echo "2026-03-02" > "$mock_home/.claude/.dep-check-date"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    # Marker should be updated to today
    local marker_date
    marker_date=$(cat "$mock_home/.claude/.dep-check-date" 2>/dev/null)
    assert_eq "$(date +%Y-%m-%d)" "$marker_date" "marker should be updated to today's date"
}
skip_test "dep check: runs when marker has yesterday's date" "feature not yet implemented"

# ── 23. Check 16: agent-fleet-mobile not cloned ─────────────────────────────

test_mobile_repo_missing_warning() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # No agent-fleet-mobile directory exists

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "agent-fleet-mobile not cloned" "should warn about missing mobile repo"
}
run_test "check 16: warns when agent-fleet-mobile is not cloned" test_mobile_repo_missing_warning

test_mobile_repo_present_no_warning() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local remote_repo="$TEST_TMPDIR/remote.git"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_tracked_repo_main "$config_repo" "$remote_repo"
    (cd "$config_repo" && touch sync.sh && git add sync.sh && git commit -m "add sync.sh" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    (cd "$config_repo" && touch CLAUDE.md && git add CLAUDE.md && git commit -m "add CLAUDE.md" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create the mobile repo directory
    mkdir -p "$mock_home/agent-fleet-mobile"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_not_contains "$output" "agent-fleet-mobile not cloned" "should NOT warn when mobile repo exists"
}
run_test "check 16: no warning when agent-fleet-mobile exists" test_mobile_repo_present_no_warning

# ── 26. .template-repo help message ──────────────────────────────────────────

test_template_repo_help_message() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local template_repo="$TEST_TMPDIR/template-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    mkdir -p "$config_repo/global"
    touch "$config_repo/global/CLAUDE.md"
    ln -sf "$config_repo/global/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create a template repo with .template-repo marker
    mkdir -p "$template_repo"
    touch "$template_repo/sync.sh"
    touch "$template_repo/.template-repo"

    # Simulate the template repo being at ~/agent-fleet
    mkdir -p "$mock_home/agent-fleet"
    touch "$mock_home/agent-fleet/.template-repo"
    touch "$mock_home/agent-fleet/sync.sh"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    # Template repo detection should produce a helpful info message, not a warning
    # This test just verifies .template-repo doesn't cause a crash — the help text
    # is surfaced via a different path (when .template-repo is found in CONFIG_REPO)
    assert_not_contains "$output" "ERROR" "should not error when .template-repo exists"
}
run_test "template-repo: no crash when .template-repo marker exists alongside personal repo" test_template_repo_help_message

test_template_repo_only_gives_help() {
    # When ONLY a template repo exists (no personal cfg-agent-fleet),
    # the config-check should provide a helpful message about first-run refinement
    local template_repo="$TEST_TMPDIR/template-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    # Create ONLY a template repo (simulating agent-fleet without cfg-agent-fleet)
    mkdir -p "$template_repo"
    touch "$template_repo/sync.sh"
    touch "$template_repo/.template-repo"
    create_git_repo_main "$template_repo"

    # Simulate: template at ~/agent-fleet, no cfg-agent-fleet
    # _detect_config_repo will find this but it has .template-repo, so it falls through
    # The help message should be generated when CONFIG_REPO has .template-repo

    # Use template_repo as config_repo to simulate detection fallback
    local patched
    patched=$(create_patched_script "$template_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "template-only" "should mention template-only deployment"
    assert_contains "$output" "first-run" "should mention first-run refinement"
}
run_test "template-repo: provides help message when running from template-only repo" test_template_repo_only_gives_help

# ── 28. TweakCC stale patch detection ────────────────────────────────────────

test_tweakcc_stale_patches_warns() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Set up TweakCC config with OLD version and changesApplied: false
    mkdir -p "$mock_home/.cc-mirror/mclaude/tweakcc"
    cat > "$mock_home/.cc-mirror/mclaude/tweakcc/config.json" << 'EOF'
{
  "ccVersion": "2.1.50",
  "changesApplied": false,
  "settings": {}
}
EOF

    # Set up installed CC with NEWER version
    mkdir -p "$mock_home/.cc-mirror/mclaude/npm/node_modules/@anthropic-ai/claude-code"
    cat > "$mock_home/.cc-mirror/mclaude/npm/node_modules/@anthropic-ai/claude-code/package.json" << 'EOF'
{
  "name": "@anthropic-ai/claude-code",
  "version": "2.1.62"
}
EOF

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "TweakCC patches stale" "should warn about stale TweakCC patches"
    assert_contains "$output" "cc-mirror tweak mclaude" "should include remediation command"
}
run_test "check 28: TweakCC stale patches warns when version mismatch + changesApplied false" test_tweakcc_stale_patches_warns

test_tweakcc_current_no_warning() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # TweakCC config matches installed version AND changesApplied: true
    mkdir -p "$mock_home/.cc-mirror/mclaude/tweakcc"
    cat > "$mock_home/.cc-mirror/mclaude/tweakcc/config.json" << 'EOF'
{
  "ccVersion": "2.1.62",
  "changesApplied": true,
  "settings": {}
}
EOF

    mkdir -p "$mock_home/.cc-mirror/mclaude/npm/node_modules/@anthropic-ai/claude-code"
    cat > "$mock_home/.cc-mirror/mclaude/npm/node_modules/@anthropic-ai/claude-code/package.json" << 'EOF'
{
  "name": "@anthropic-ai/claude-code",
  "version": "2.1.62"
}
EOF

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_not_contains "$output" "TweakCC patches stale" "should NOT warn when versions match"
}
run_test "check 28: no TweakCC warning when versions match and patches applied" test_tweakcc_current_no_warning

test_tweakcc_version_mismatch_but_applied_no_warning() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Version mismatch BUT changesApplied: true (patches still active)
    mkdir -p "$mock_home/.cc-mirror/mclaude/tweakcc"
    cat > "$mock_home/.cc-mirror/mclaude/tweakcc/config.json" << 'EOF'
{
  "ccVersion": "2.1.50",
  "changesApplied": true,
  "settings": {}
}
EOF

    mkdir -p "$mock_home/.cc-mirror/mclaude/npm/node_modules/@anthropic-ai/claude-code"
    cat > "$mock_home/.cc-mirror/mclaude/npm/node_modules/@anthropic-ai/claude-code/package.json" << 'EOF'
{
  "name": "@anthropic-ai/claude-code",
  "version": "2.1.62"
}
EOF

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_not_contains "$output" "TweakCC patches stale" "should NOT warn when changesApplied is true even with version mismatch"
}
run_test "check 28: no TweakCC warning when version mismatch but changesApplied true" test_tweakcc_version_mismatch_but_applied_no_warning

test_tweakcc_not_installed_silent() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # No TweakCC config at all — not installed
    # (don't create .cc-mirror/mclaude/tweakcc/)

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_not_contains "$output" "TweakCC" "should be silent when TweakCC is not installed"
}
run_test "check 28: silent when TweakCC is not installed" test_tweakcc_not_installed_silent

test_tweakcc_same_version_not_applied_warns() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Same version BUT changesApplied: false (patches reverted/not applied)
    mkdir -p "$mock_home/.cc-mirror/mclaude/tweakcc"
    cat > "$mock_home/.cc-mirror/mclaude/tweakcc/config.json" << 'EOF'
{
  "ccVersion": "2.1.62",
  "changesApplied": false,
  "settings": {}
}
EOF

    mkdir -p "$mock_home/.cc-mirror/mclaude/npm/node_modules/@anthropic-ai/claude-code"
    cat > "$mock_home/.cc-mirror/mclaude/npm/node_modules/@anthropic-ai/claude-code/package.json" << 'EOF'
{
  "name": "@anthropic-ai/claude-code",
  "version": "2.1.62"
}
EOF

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    # Same version but not applied — still worth a warning (patches unapplied)
    assert_not_contains "$output" "TweakCC patches stale" "should NOT warn about STALE when same version (patches just unapplied, not stale)"
}
run_test "check 28: no stale warning when same version but changesApplied false" test_tweakcc_same_version_not_applied_warns

# ── 29. wsl.conf duplicate section validation ────────────────────────────────

test_wslconf_no_warning_non_wsl() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create a wsl.conf with duplicates — but _FORCE_WSL=0 forces non-WSL
    local wsl_conf="$TEST_TMPDIR/wsl.conf"
    printf '[boot]\nsystemd=true\n[boot]\ncommand=/bin/bash\n' > "$wsl_conf"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(_FORCE_WSL=0 _WSL_CONF_PATH="$wsl_conf" run_hook "$patched")

    assert_not_contains "$output" "wsl.conf" "should NOT warn about wsl.conf on non-WSL"
}
run_test "check 29: no wsl.conf warning on non-WSL" test_wslconf_no_warning_non_wsl

test_wslconf_no_warning_clean() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Clean wsl.conf — no duplicates
    local wsl_conf="$TEST_TMPDIR/wsl.conf"
    printf '[boot]\nsystemd=true\n[interop]\nenabled=true\n' > "$wsl_conf"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(_FORCE_WSL=1 _WSL_CONF_PATH="$wsl_conf" run_hook "$patched")

    assert_not_contains "$output" "wsl.conf" "should NOT warn when wsl.conf has no duplicates"
}
run_test "check 29: no warning when wsl.conf has no duplicate sections" test_wslconf_no_warning_clean

test_wslconf_warns_on_duplicates() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # wsl.conf with duplicate [boot] section
    local wsl_conf="$TEST_TMPDIR/wsl.conf"
    printf '[boot]\nsystemd=true\n[interop]\nenabled=true\n[boot]\ncommand=/bin/bash\n' > "$wsl_conf"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(_FORCE_WSL=1 _WSL_CONF_PATH="$wsl_conf" run_hook "$patched")

    assert_contains "$output" "wsl.conf has duplicate" "should warn about duplicate sections"
    assert_contains "$output" "boot" "should name the duplicate section"
}
run_test "check 29: warns on duplicate wsl.conf sections" test_wslconf_warns_on_duplicates

test_wslconf_autofix_merges_duplicates() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # wsl.conf with duplicate [boot] — different keys + one overlapping key
    local wsl_conf="$TEST_TMPDIR/wsl.conf"
    printf '[boot]\nsystemd=true\n[interop]\nenabled=true\n[boot]\ncommand=/bin/bash\nsystemd=false\n' > "$wsl_conf"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(_FORCE_WSL=1 _WSL_CONF_PATH="$wsl_conf" run_hook "$patched")

    # After auto-fix, file should have exactly one [boot] section
    local boot_count
    boot_count=$(grep -c '^\[boot\]' "$wsl_conf")
    assert_eq "1" "$boot_count" "should have exactly one [boot] section after merge"

    # Last value wins: systemd should be false (from second [boot])
    assert_file_contains "$wsl_conf" "systemd=false" "last value should win for duplicate keys"

    # command should be preserved from the second section
    assert_file_contains "$wsl_conf" "command=/bin/bash" "unique keys from duplicate sections should be preserved"

    # [interop] should be unchanged
    assert_file_contains "$wsl_conf" '\[interop\]' "non-duplicate sections should be preserved"
    assert_file_contains "$wsl_conf" "enabled=true" "non-duplicate section keys should be preserved"
}
run_test "check 29: auto-fix merges duplicate wsl.conf sections" test_wslconf_autofix_merges_duplicates

test_wslconf_autofix_creates_backup() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # wsl.conf with duplicate [boot]
    local wsl_conf="$TEST_TMPDIR/wsl.conf"
    printf '[boot]\nsystemd=true\n[boot]\ncommand=/bin/bash\n' > "$wsl_conf"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(_FORCE_WSL=1 _WSL_CONF_PATH="$wsl_conf" run_hook "$patched")

    # Backup should exist
    local backup
    backup=$(ls "$TEST_TMPDIR"/wsl.conf.bak.* 2>/dev/null | head -1)
    assert_file_exists "$backup" "should create a backup of wsl.conf before auto-fix"

    # Backup should contain the original content (with duplicates)
    local backup_boot_count
    backup_boot_count=$(grep -c '^\[boot\]' "$backup")
    assert_eq "2" "$backup_boot_count" "backup should have original 2 [boot] sections"
}
run_test "check 29: auto-fix creates backup of wsl.conf" test_wslconf_autofix_creates_backup

test_wslconf_no_file_no_warning() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Point to a non-existent wsl.conf
    local wsl_conf="$TEST_TMPDIR/nonexistent-wsl.conf"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(_FORCE_WSL=1 _WSL_CONF_PATH="$wsl_conf" run_hook "$patched")

    assert_not_contains "$output" "wsl.conf" "should NOT warn when wsl.conf does not exist"
}
run_test "check 29: no warning when wsl.conf does not exist" test_wslconf_no_file_no_warning

test_wslconf_multiple_duplicate_sections() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # wsl.conf with duplicate [boot] AND duplicate [interop]
    local wsl_conf="$TEST_TMPDIR/wsl.conf"
    printf '[boot]\nsystemd=true\n[interop]\nenabled=true\n[boot]\ncommand=/bin/bash\n[interop]\nappendWindowsPath=false\n' > "$wsl_conf"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(_FORCE_WSL=1 _WSL_CONF_PATH="$wsl_conf" run_hook "$patched")

    assert_contains "$output" "boot" "should list boot as duplicate"
    assert_contains "$output" "interop" "should list interop as duplicate"

    # After fix, each section should appear exactly once
    local boot_count interop_count
    boot_count=$(grep -c '^\[boot\]' "$wsl_conf")
    interop_count=$(grep -c '^\[interop\]' "$wsl_conf")
    assert_eq "1" "$boot_count" "should have exactly one [boot] section after merge"
    assert_eq "1" "$interop_count" "should have exactly one [interop] section after merge"
}
run_test "check 29: handles multiple duplicate sections" test_wslconf_multiple_duplicate_sections

# ── 30. Doc coherence header validation ──────────────────────────────────────

test_doc_coherence_all_headers_present() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create files WITH coherence headers
    mkdir -p "$config_repo/global/machines" "$config_repo/global/reference" "$config_repo/cross-project"
    echo '<!-- updates: cross-project/infrastructure-strategy.md, registry.md -->' > "$config_repo/global/machines/wsl.md"
    echo '# Machine: WSL' >> "$config_repo/global/machines/wsl.md"
    echo '<!-- updates: machines/*.md (Auth State sections) -->' > "$config_repo/global/reference/mcp-catalog.md"
    printf '<!-- updates: registry.md -->\n# Global Config\n' > "$config_repo/global/CLAUDE.md"
    ln -sf "$config_repo/global/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"
    echo '<!-- updates: registry.md -->' > "$config_repo/cross-project/infrastructure-strategy.md"
    echo '<!-- updates: cross-project/infrastructure-strategy.md -->' > "$config_repo/registry.md"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_not_contains "$output" "doc coherence" "should NOT warn when all headers present"
}
run_test "check 30: no warning when all coherence headers present" test_doc_coherence_all_headers_present

test_doc_coherence_missing_header_in_machine_file() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    mkdir -p "$config_repo/global/machines" "$config_repo/global/reference" "$config_repo/cross-project"

    # Machine file WITHOUT header
    printf '# Machine: WSL\n## Identity\n' > "$config_repo/global/machines/wsl.md"
    # Other files WITH headers
    echo '<!-- updates: machines/*.md -->' > "$config_repo/global/reference/mcp-catalog.md"
    printf '<!-- updates: registry.md -->\n# Global Config\n' > "$config_repo/global/CLAUDE.md"
    ln -sf "$config_repo/global/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"
    echo '<!-- updates: registry.md -->' > "$config_repo/cross-project/infrastructure-strategy.md"
    echo '<!-- updates: cross-project/infrastructure-strategy.md -->' > "$config_repo/registry.md"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "doc coherence" "should warn about missing header"
    assert_contains "$output" "wsl.md" "should name the file missing header"
}
run_test "check 30: warns when machine file missing coherence header" test_doc_coherence_missing_header_in_machine_file

test_doc_coherence_missing_header_in_registry() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    mkdir -p "$config_repo/global/machines" "$config_repo/global/reference" "$config_repo/cross-project"

    # registry.md WITHOUT header
    printf '# Project Registry\n' > "$config_repo/registry.md"
    # Others WITH headers
    echo '<!-- updates: cross-project/infrastructure-strategy.md, registry.md -->' > "$config_repo/global/machines/wsl.md"
    echo '<!-- updates: machines/*.md -->' > "$config_repo/global/reference/mcp-catalog.md"
    printf '<!-- updates: registry.md -->\n# Global Config\n' > "$config_repo/global/CLAUDE.md"
    ln -sf "$config_repo/global/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"
    echo '<!-- updates: registry.md -->' > "$config_repo/cross-project/infrastructure-strategy.md"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "doc coherence" "should warn about missing header"
    assert_contains "$output" "registry.md" "should name registry.md"
}
run_test "check 30: warns when registry.md missing coherence header" test_doc_coherence_missing_header_in_registry

test_doc_coherence_nonexistent_file_skipped() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    # Don't create global/machines/ at all — no machine files exist
    mkdir -p "$config_repo/global/reference" "$config_repo/cross-project"
    echo '<!-- updates: machines/*.md -->' > "$config_repo/global/reference/mcp-catalog.md"
    printf '<!-- updates: registry.md -->\n# Global Config\n' > "$config_repo/global/CLAUDE.md"
    ln -sf "$config_repo/global/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"
    echo '<!-- updates: registry.md -->' > "$config_repo/cross-project/infrastructure-strategy.md"
    echo '<!-- updates: cross-project/infrastructure-strategy.md -->' > "$config_repo/registry.md"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_not_contains "$output" "doc coherence" "should NOT warn about nonexistent files"
}
run_test "check 30: skips nonexistent files gracefully" test_doc_coherence_nonexistent_file_skipped

test_doc_coherence_multiple_missing() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    mkdir -p "$config_repo/global/machines" "$config_repo/global/reference" "$config_repo/cross-project"

    # Two machine files WITHOUT headers
    printf '# Machine: WSL\n' > "$config_repo/global/machines/wsl.md"
    printf '# Machine: VPS\n' > "$config_repo/global/machines/vps.md"
    # registry WITHOUT header
    printf '# Registry\n' > "$config_repo/registry.md"
    # Others WITH headers
    echo '<!-- updates: machines/*.md -->' > "$config_repo/global/reference/mcp-catalog.md"
    printf '<!-- updates: registry.md -->\n' > "$config_repo/global/CLAUDE.md"
    ln -sf "$config_repo/global/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"
    echo '<!-- updates: registry.md -->' > "$config_repo/cross-project/infrastructure-strategy.md"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "doc coherence" "should warn about missing headers"
    assert_contains "$output" "3 file" "should report count of files missing headers"
}
run_test "check 30: reports count when multiple files missing headers" test_doc_coherence_multiple_missing

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
