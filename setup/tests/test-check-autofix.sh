#!/usr/bin/env bash
# Tests for config-check.sh — auto-fix checks: settings.json validation, serena config,
# permissions cleanup, Bash(bash:*) auto-heal, enabledPlugins, CC_MIRROR_SPLASH
source "$(dirname "$0")/test-helpers.sh"
source "$(dirname "$0")/test-check-helpers.sh"

suite_header "config-check.sh: auto-fix checks"

# ── 8. settings.json validation ──────────────────────────────────────────────

test_settings_json_missing_blocks() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create settings.json missing "hooks" and "enabledPlugins"
    mkdir -p "$mock_home/.cc-mirror/mclaude/config"
    cat > "$mock_home/.cc-mirror/mclaude/config/settings.json" << 'EOF'
{
  "permissions": {
    "allow": ["Read"]
  }
}
EOF

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_contains "$output" "settings.json is missing critical blocks" "should warn about missing blocks"
    assert_contains "$output" "hooks" "should list missing hooks block"
    assert_contains "$output" "enabledPlugins" "should list missing enabledPlugins block"
}
run_test "settings.json: warns about missing critical blocks" test_settings_json_missing_blocks

test_settings_json_all_present() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create settings.json with all critical blocks
    mkdir -p "$mock_home/.cc-mirror/mclaude/config"
    cat > "$mock_home/.cc-mirror/mclaude/config/settings.json" << 'EOF'
{
  "permissions": { "allow": ["Read"] },
  "hooks": { "SessionStart": [] },
  "enabledPlugins": []
}
EOF

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_not_contains "$output" "settings.json is missing" "should NOT warn when all blocks present"
}
run_test "settings.json: no warning when all critical blocks present" test_settings_json_all_present

# ── 9. Serena config enforcement ─────────────────────────────────────────────

test_serena_config_fixes_dashboard() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create serena config with web_dashboard_open_on_launch: true
    mkdir -p "$mock_home/.serena"
    cat > "$mock_home/.serena/serena_config.yml" << 'EOF'
web_dashboard_open_on_launch: true
gui_log_window: true
some_other_setting: value
EOF

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    run_hook "$patched" >/dev/null

    # Verify the config was fixed
    assert_file_contains "$mock_home/.serena/serena_config.yml" "web_dashboard_open_on_launch: false" \
        "should fix web_dashboard_open_on_launch to false"
    assert_file_contains "$mock_home/.serena/serena_config.yml" "gui_log_window: false" \
        "should fix gui_log_window to false"
    assert_file_contains "$mock_home/.serena/serena_config.yml" "some_other_setting: value" \
        "should preserve other settings"
}
run_test "serena config: fixes web_dashboard_open_on_launch and gui_log_window" test_serena_config_fixes_dashboard

test_serena_config_already_correct() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create serena config already correct
    mkdir -p "$mock_home/.serena"
    cat > "$mock_home/.serena/serena_config.yml" << 'EOF'
web_dashboard_open_on_launch: false
gui_log_window: false
EOF

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    run_hook "$patched" >/dev/null

    assert_file_contains "$mock_home/.serena/serena_config.yml" "web_dashboard_open_on_launch: false" \
        "should remain false"
    assert_file_contains "$mock_home/.serena/serena_config.yml" "gui_log_window: false" \
        "should remain false"
}
run_test "serena config: no change when already correct" test_serena_config_already_correct

# ── 16. Settings.json not present produces no warning ─────────────────────────

test_no_settings_json() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local remote_repo="$TEST_TMPDIR/remote.git"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_tracked_repo_main "$config_repo" "$remote_repo"
    (cd "$config_repo" && touch sync.sh && git add sync.sh && git commit -m "add sync.sh" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    (cd "$config_repo" && touch CLAUDE.md && git add CLAUDE.md && git commit -m "add CLAUDE.md" >/dev/null 2>&1 && git push origin main >/dev/null 2>&1)
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # No settings.json file created at all

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    assert_not_contains "$output" "settings.json" "should not warn when settings.json doesn't exist"
}
run_test "settings.json: no warning when file does not exist" test_no_settings_json

# ── 17. Check 10: Auto-remove permissions from project settings.local.json ────

test_permissions_block_removed() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create a project with settings.local.json containing a permissions block
    mkdir -p "$mock_home/myproject/.claude"
    cat > "$mock_home/myproject/.claude/settings.local.json" << 'EOF'
{
  "permissions": {
    "allow": [
      "Bash(foo:*)"
    ]
  },
  "enableAllProjectMcpServers": true
}
EOF

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    run_hook "$patched" >/dev/null

    # Verify permissions key was removed
    assert_file_not_contains "$mock_home/myproject/.claude/settings.local.json" '"permissions"' \
        "should remove permissions key from settings.local.json"

    # Verify other keys are preserved
    assert_file_contains "$mock_home/myproject/.claude/settings.local.json" '"enableAllProjectMcpServers"' \
        "should preserve enableAllProjectMcpServers key"
    assert_file_contains "$mock_home/myproject/.claude/settings.local.json" 'true' \
        "should preserve enableAllProjectMcpServers value"
}
run_test "check 10: settings.local.json with permissions block gets cleaned" test_permissions_block_removed

test_permissions_block_absent_untouched() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create a project with settings.local.json WITHOUT permissions
    mkdir -p "$mock_home/cleanproject/.claude"
    cat > "$mock_home/cleanproject/.claude/settings.local.json" << 'EOF'
{
  "enableAllProjectMcpServers": true,
  "mcpServers": {
    "serena": {
      "command": "serena"
    }
  }
}
EOF

    # Save original content for comparison
    local original
    original=$(cat "$mock_home/cleanproject/.claude/settings.local.json")

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    run_hook "$patched" >/dev/null

    # Verify file is unchanged
    local after
    after=$(cat "$mock_home/cleanproject/.claude/settings.local.json")
    assert_eq "$original" "$after" "settings.local.json without permissions should be untouched"
}
run_test "check 10: settings.local.json without permissions block is untouched" test_permissions_block_absent_untouched

test_permissions_removal_silent_on_success() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create a project with permissions block
    mkdir -p "$mock_home/warnproject/.claude"
    cat > "$mock_home/warnproject/.claude/settings.local.json" << 'EOF'
{
  "permissions": {
    "allow": [
      "Bash(foo:*)"
    ]
  },
  "enableAllProjectMcpServers": true
}
EOF

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    # Cleanup should have happened (permissions removed)
    assert_file_not_contains "$mock_home/warnproject/.claude/settings.local.json" '"permissions"' \
        "should remove permissions block"

    # But NO warning should be generated — successful cleanup is silent
    assert_not_contains "$output" "Auto-removed stale permissions" \
        "should NOT warn when cleanup succeeds silently"
    assert_not_contains "$output" "permissions override" \
        "should NOT mention permissions override"
}
run_test "check 10: successful permissions cleanup produces no warning" test_permissions_removal_silent_on_success

test_permissions_multiple_projects_cleaned() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create two projects with permissions blocks
    mkdir -p "$mock_home/projA/.claude"
    cat > "$mock_home/projA/.claude/settings.local.json" << 'EOF'
{
  "permissions": {
    "allow": [
      "Bash(bar:*)"
    ]
  },
  "enableAllProjectMcpServers": true
}
EOF

    mkdir -p "$mock_home/projB/.claude"
    cat > "$mock_home/projB/.claude/settings.local.json" << 'EOF'
{
  "permissions": {
    "allow": [
      "Read(*)"
    ]
  },
  "mcpServers": {
    "test": {
      "command": "test"
    }
  }
}
EOF

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    # Both should have permissions removed
    assert_file_not_contains "$mock_home/projA/.claude/settings.local.json" '"permissions"' \
        "should remove permissions from projA"
    assert_file_not_contains "$mock_home/projB/.claude/settings.local.json" '"permissions"' \
        "should remove permissions from projB"

    # Both should preserve their other keys
    assert_file_contains "$mock_home/projA/.claude/settings.local.json" '"enableAllProjectMcpServers"' \
        "should preserve enableAllProjectMcpServers in projA"
    assert_file_contains "$mock_home/projB/.claude/settings.local.json" '"mcpServers"' \
        "should preserve mcpServers in projB"

    # Successful cleanup should be silent — no warning for either project
    assert_not_contains "$output" "Auto-removed stale permissions" \
        "should NOT warn when cleanup succeeds silently"
    assert_not_contains "$output" "projA" \
        "should NOT mention projA in output"
    assert_not_contains "$output" "projB" \
        "should NOT mention projB in output"
}
run_test "check 10: multiple projects with permissions blocks both get cleaned" test_permissions_multiple_projects_cleaned

# ── 21. Check 14: Bash(bash:*) auto-heal in settings.json ────────────────────

test_bash_permission_auto_added() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create settings.json WITHOUT Bash(bash:*)
    mkdir -p "$mock_home/.cc-mirror/mclaude/config"
    cat > "$mock_home/.cc-mirror/mclaude/config/settings.json" << 'EOF'
{
  "permissions": {
    "allow": [
      "Read(*)",
      "Bash(git:*)",
      "Bash(npm:*)"
    ]
  },
  "hooks": {}
}
EOF

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    run_hook "$patched" >/dev/null

    # Verify Bash(bash:*) was added
    assert_file_contains "$mock_home/.cc-mirror/mclaude/config/settings.json" 'Bash(bash:*)' \
        "should auto-add Bash(bash:*) to permissions.allow"

    # Verify existing permissions preserved
    assert_file_contains "$mock_home/.cc-mirror/mclaude/config/settings.json" 'Read(*)' \
        "should preserve existing Read(*) permission"
    assert_file_contains "$mock_home/.cc-mirror/mclaude/config/settings.json" 'Bash(git:*)' \
        "should preserve existing Bash(git:*) permission"

    # Verify valid JSON
    local json_valid=0
    python3 -c "import json; json.load(open('$mock_home/.cc-mirror/mclaude/config/settings.json'))" 2>/dev/null || json_valid=1
    assert_eq "0" "$json_valid" "settings.json should remain valid JSON after auto-add"
}
run_test "check 14: auto-adds Bash(bash:*) when missing from settings.json" test_bash_permission_auto_added

test_bash_permission_already_present() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create settings.json WITH Bash(bash:*) already
    mkdir -p "$mock_home/.cc-mirror/mclaude/config"
    cat > "$mock_home/.cc-mirror/mclaude/config/settings.json" << 'EOF'
{
  "permissions": {
    "allow": [
      "Read(*)",
      "Bash(bash:*)",
      "Bash(git:*)"
    ]
  },
  "hooks": {}
}
EOF

    local original
    original=$(cat "$mock_home/.cc-mirror/mclaude/config/settings.json")

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    run_hook "$patched" >/dev/null

    local after
    after=$(cat "$mock_home/.cc-mirror/mclaude/config/settings.json")
    assert_eq "$original" "$after" "settings.json should be unchanged when Bash(bash:*) already present"
}
run_test "check 14: no change when Bash(bash:*) already present" test_bash_permission_already_present

test_bash_permission_no_permissions_block() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create settings.json without permissions block at all
    mkdir -p "$mock_home/.cc-mirror/mclaude/config"
    cat > "$mock_home/.cc-mirror/mclaude/config/settings.json" << 'EOF'
{
  "hooks": {},
  "statusLine": {}
}
EOF

    local original
    original=$(cat "$mock_home/.cc-mirror/mclaude/config/settings.json")

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    run_hook "$patched" >/dev/null

    # Should warn about missing permissions block (Check 8 handles this),
    # but should NOT crash trying to add Bash(bash:*)
    local after
    after=$(cat "$mock_home/.cc-mirror/mclaude/config/settings.json")
    assert_eq "$original" "$after" "settings.json should be unchanged when no permissions block exists"
}
run_test "check 14: no crash when settings.json has no permissions block" test_bash_permission_no_permissions_block

# ── 25. Check 19: Auto-disable global enabledPlugins ────────────────────────

test_plugins_auto_disabled() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create settings.json with non-empty enabledPlugins
    mkdir -p "$mock_home/.cc-mirror/mclaude/config"
    cat > "$mock_home/.cc-mirror/mclaude/config/settings.json" << 'EOF'
{
  "permissions": {
    "allow": ["Read(*)", "Bash(bash:*)"]
  },
  "hooks": {},
  "enabledPlugins": {
    "voltagent-lang@voltagent-subagents": true,
    "voltagent-infra@voltagent-subagents": true,
    "code-review@claude-plugins-official": true
  }
}
EOF

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    # Verify plugins were disabled (enabledPlugins should be empty object)
    local plugins_count
    plugins_count=$(python3 -c "import json; d=json.load(open('$mock_home/.cc-mirror/mclaude/config/settings.json')); print(len(d.get('enabledPlugins',{})))" 2>/dev/null)
    assert_eq "0" "$plugins_count" "enabledPlugins should be empty after auto-disable"

    # Verify warning was emitted
    assert_contains "$output" "enabledPlugins" "should warn about disabled plugins"

    # Verify valid JSON
    local json_valid=0
    python3 -c "import json; json.load(open('$mock_home/.cc-mirror/mclaude/config/settings.json'))" 2>/dev/null || json_valid=1
    assert_eq "0" "$json_valid" "settings.json should remain valid JSON after plugin disable"

    # Verify other settings preserved
    assert_file_contains "$mock_home/.cc-mirror/mclaude/config/settings.json" '"hooks"' \
        "should preserve hooks block"
    assert_file_contains "$mock_home/.cc-mirror/mclaude/config/settings.json" '"allow"' \
        "should preserve permissions"
}
run_test "check 19: auto-disables non-empty global enabledPlugins" test_plugins_auto_disabled

test_plugins_already_empty() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create settings.json with empty enabledPlugins
    mkdir -p "$mock_home/.cc-mirror/mclaude/config"
    cat > "$mock_home/.cc-mirror/mclaude/config/settings.json" << 'EOF'
{
  "permissions": {
    "allow": ["Read(*)", "Bash(bash:*)"]
  },
  "hooks": {},
  "enabledPlugins": {}
}
EOF

    local original
    original=$(cat "$mock_home/.cc-mirror/mclaude/config/settings.json")

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    local after
    after=$(cat "$mock_home/.cc-mirror/mclaude/config/settings.json")
    assert_eq "$original" "$after" "settings.json should be unchanged when enabledPlugins is empty"
    assert_not_contains "$output" "enabledPlugins" "should NOT warn when plugins already empty"
}
run_test "check 19: no change when enabledPlugins is already empty" test_plugins_already_empty

test_plugins_no_key() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create settings.json without enabledPlugins key at all
    mkdir -p "$mock_home/.cc-mirror/mclaude/config"
    cat > "$mock_home/.cc-mirror/mclaude/config/settings.json" << 'EOF'
{
  "permissions": {
    "allow": ["Read(*)", "Bash(bash:*)"]
  },
  "hooks": {}
}
EOF

    local original
    original=$(cat "$mock_home/.cc-mirror/mclaude/config/settings.json")

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    run_hook "$patched" >/dev/null

    local after
    after=$(cat "$mock_home/.cc-mirror/mclaude/config/settings.json")
    assert_eq "$original" "$after" "settings.json should be unchanged when enabledPlugins key is missing"
}
run_test "check 19: no crash when enabledPlugins key is absent" test_plugins_no_key

# ── 32. Check 32: Auto-fix CC_MIRROR_SPLASH drift ────────────────────────────

test_splash_auto_fixed() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create settings.json with CC_MIRROR_SPLASH set to "1" (injected by cc-mirror update)
    mkdir -p "$mock_home/.cc-mirror/mclaude/config"
    cat > "$mock_home/.cc-mirror/mclaude/config/settings.json" << 'EOF'
{
  "env": {
    "CC_MIRROR_SPLASH": "1",
    "CC_MIRROR_SPLASH_STYLE": "mirror",
    "CC_MIRROR_PROVIDER_LABEL": "Mirror Claude",
    "FORCE_COLOR": "1"
  },
  "permissions": {
    "allow": ["Read(*)", "Bash(bash:*)"]
  },
  "hooks": {},
  "enabledPlugins": {}
}
EOF

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    # Verify CC_MIRROR_SPLASH was set to "0"
    local splash_val
    splash_val=$(python3 -c "import json; d=json.load(open('$mock_home/.cc-mirror/mclaude/config/settings.json')); print(d.get('env',{}).get('CC_MIRROR_SPLASH','missing'))" 2>/dev/null)
    assert_eq "0" "$splash_val" "CC_MIRROR_SPLASH should be set to 0" || return 1

    # Verify other env vars preserved
    local force_color
    force_color=$(python3 -c "import json; d=json.load(open('$mock_home/.cc-mirror/mclaude/config/settings.json')); print(d.get('env',{}).get('FORCE_COLOR','missing'))" 2>/dev/null)
    assert_eq "1" "$force_color" "other env vars should be preserved" || return 1

    # Verify valid JSON
    python3 -c "import json; json.load(open('$mock_home/.cc-mirror/mclaude/config/settings.json'))" 2>/dev/null
    assert_eq "0" "$?" "settings.json should remain valid JSON"
}
run_test "check 32: auto-fixes CC_MIRROR_SPLASH=1 to 0" test_splash_auto_fixed

test_splash_already_zero() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create settings.json with CC_MIRROR_SPLASH already "0"
    mkdir -p "$mock_home/.cc-mirror/mclaude/config"
    cat > "$mock_home/.cc-mirror/mclaude/config/settings.json" << 'EOF'
{
  "env": {
    "CC_MIRROR_SPLASH": "0",
    "FORCE_COLOR": "1"
  },
  "permissions": {
    "allow": ["Read(*)", "Bash(bash:*)"]
  },
  "hooks": {},
  "enabledPlugins": {}
}
EOF

    local original
    original=$(cat "$mock_home/.cc-mirror/mclaude/config/settings.json")

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    run_hook "$patched" >/dev/null

    local after
    after=$(cat "$mock_home/.cc-mirror/mclaude/config/settings.json")
    assert_eq "$original" "$after" "settings.json should be unchanged when splash already 0"
}
run_test "check 32: no change when CC_MIRROR_SPLASH already 0" test_splash_already_zero

test_splash_no_env_block() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create settings.json without env block at all
    mkdir -p "$mock_home/.cc-mirror/mclaude/config"
    cat > "$mock_home/.cc-mirror/mclaude/config/settings.json" << 'EOF'
{
  "permissions": {
    "allow": ["Read(*)", "Bash(bash:*)"]
  },
  "hooks": {},
  "enabledPlugins": {}
}
EOF

    local original
    original=$(cat "$mock_home/.cc-mirror/mclaude/config/settings.json")

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    run_hook "$patched" >/dev/null

    local after
    after=$(cat "$mock_home/.cc-mirror/mclaude/config/settings.json")
    assert_eq "$original" "$after" "settings.json should be unchanged when no env block"
}
run_test "check 32: no crash when env block absent" test_splash_no_env_block

# ── Check 4.6: daily Claude Code update check — native (bare-binary) layout ──
# The glob "$HOME/.cc-mirror/*/npm/node_modules/@anthropic-ai/claude-code/
# package.json" matches NOTHING on a native install (<variant>/{config,native/
# claude,scripts,tweakcc,variant.json}, no npm/), so the check found no version
# and reported nothing — indistinguishable from "up to date". One downstream
# machine sat 33 releases behind. These tests are hermetic: sched-lib.sh is
# copied into the mock repo (no /tmp fallback marker), SCHED_MARKER_DIR is a
# fresh dir (the check is due), and npm is a mock on PATH (no network).

# create_native_mirror <mirror-dir> <binary-version|""> [nativeVersion] [claudeOrig]
create_native_mirror() {
    local mirror="$1" version="$2"
    local native_version="${3:-latest}"
    local claude_orig="${4:-native:${version:-latest}}"
    mkdir -p "$mirror/config" "$mirror/native" "$mirror/scripts" "$mirror/tweakcc"
    if [[ -n "$version" ]]; then
        printf '#!/bin/bash\n[[ "$1" == "--version" ]] && { echo "%s (Claude Code)"; exit 0; }\nexit 1\n' "$version" \
            > "$mirror/native/claude"
        chmod +x "$mirror/native/claude"
    fi
    cat > "$mirror/variant.json" <<EOF
{
  "name": "mclaude",
  "provider": "mirror",
  "claudeOrig": "$claude_orig",
  "binaryPath": "$mirror/native/claude",
  "configDir": "$mirror/config",
  "tweakDir": "$mirror/tweakcc",
  "nativeDir": "$mirror/native",
  "nativeVersion": "$native_version",
  "nativeVersionSource": "default",
  "nativePlatform": "linux-x64"
}
EOF
}

# Prepare config repo + mock home for a dep-check test; echoes the mock npm dir.
# Usage: mockbin=$(setup_dep_check_env "$config_repo" "$mock_home" "$project_dir" "<latest>")
setup_dep_check_env() {
    local config_repo="$1" mock_home="$2" project_dir="$3" latest="$4"
    mkdir -p "$mock_home/.claude" "$project_dir"
    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"
    cp "$REPO_ROOT/setup/scripts/sched-lib.sh" "$config_repo/setup/scripts/"
    local mockbin="$TEST_TMPDIR/mockbin"
    mkdir -p "$mockbin"
    printf '#!/usr/bin/env bash\n[[ "$1" == "view" ]] && { echo "%s"; exit 0; }\nexit 1\n' "$latest" > "$mockbin/npm"
    chmod +x "$mockbin/npm"
    echo "$mockbin"
}

run_dep_check() {
    local patched="$1" mockbin="$2"
    PATH="$mockbin:$PATH" SCHED_MARKER_DIR="$TEST_TMPDIR/sched" run_hook "$patched"
}

test_dep_check_native_layout_reports_update() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    local mockbin ctx
    mockbin=$(setup_dep_check_env "$config_repo" "$mock_home" "$project_dir" "2.1.240")
    create_native_mirror "$mock_home/.cc-mirror/mclaude" "2.1.207"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    ctx=$(extract_additional_context "$(run_dep_check "$patched" "$mockbin")")
    echo "    measured context: [$(printf '%s' "$ctx" | grep -o 'Upstream dependency check[^|]*' | head -1)]"
    assert_contains "$ctx" "Upstream dependency check: Claude Code update available: 2.1.207 → 2.1.240" \
        "native layout must surface the update via additionalContext"
}
run_test "BUG: check 4.6 native layout (no npm/): reports update available" test_dep_check_native_layout_reports_update

test_dep_check_unknown_install_is_loud() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    local mockbin ctx
    mockbin=$(setup_dep_check_env "$config_repo" "$mock_home" "$project_dir" "2.1.240")
    # A mirror dir with config only: no npm/, no native/, no variant.json.
    mkdir -p "$mock_home/.cc-mirror/mclaude/config"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    ctx=$(extract_additional_context "$(run_dep_check "$patched" "$mockbin")")
    echo "    measured context: [$(printf '%s' "$ctx" | grep -o 'Upstream dependency check[^|]*' | head -1)]"
    assert_contains "$ctx" "Upstream dependency check" "an unknown installed version must be reported, not silently skipped" || return 1
    assert_contains "$ctx" "UNKNOWN" "must say the installed version is UNKNOWN" || return 1
    assert_contains "$ctx" "$mock_home/.cc-mirror" "must name where it searched"
}
run_test "BUG: check 4.6 no version found anywhere: LOUD warning, not silence" test_dep_check_unknown_install_is_loud

test_dep_check_native_up_to_date_is_quiet() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    local mockbin ctx
    mockbin=$(setup_dep_check_env "$config_repo" "$mock_home" "$project_dir" "2.1.240")
    create_native_mirror "$mock_home/.cc-mirror/mclaude" "2.1.240"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    ctx=$(extract_additional_context "$(run_dep_check "$patched" "$mockbin")")
    echo "    measured: dep-check fragments = $(printf '%s' "$ctx" | grep -c 'Upstream dependency check' || true)"
    assert_not_contains "$ctx" "Upstream dependency check" "up to date must stay quiet" || return 1
    assert_not_contains "$ctx" "UNKNOWN"
}
run_test "check 4.6 native layout: up to date is quiet (no false UNKNOWN)" test_dep_check_native_up_to_date_is_quiet

test_dep_check_npm_layout_still_reports_update() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    local mockbin ctx
    mockbin=$(setup_dep_check_env "$config_repo" "$mock_home" "$project_dir" "2.1.240")
    local pkg="$mock_home/.cc-mirror/mclaude/npm/node_modules/@anthropic-ai/claude-code"
    mkdir -p "$pkg"
    echo '{ "name": "@anthropic-ai/claude-code", "version": "2.1.207" }' > "$pkg/package.json"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    ctx=$(extract_additional_context "$(run_dep_check "$patched" "$mockbin")")
    echo "    measured context: [$(printf '%s' "$ctx" | grep -o 'Upstream dependency check[^|]*' | head -1)]"
    assert_contains "$ctx" "Upstream dependency check: Claude Code update available: 2.1.207 → 2.1.240" \
        "npm layout must keep working"
}
run_test "check 4.6 npm layout: still reports update available (regression guard)" test_dep_check_npm_layout_still_reports_update

test_dep_check_variant_json_latest_is_not_a_version() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    local mockbin ctx
    mockbin=$(setup_dep_check_env "$config_repo" "$mock_home" "$project_dir" "2.1.240")
    # No runnable binary; variant.json only carries the requested spec "latest".
    create_native_mirror "$mock_home/.cc-mirror/mclaude" "" "latest" "native:latest"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    ctx=$(extract_additional_context "$(run_dep_check "$patched" "$mockbin")")
    echo "    measured context: [$(printf '%s' "$ctx" | grep -o 'Upstream dependency check[^|]*' | head -1)]"
    assert_contains "$ctx" "UNKNOWN" "'latest' is a spec, not a version" || return 1
    assert_not_contains "$ctx" "latest → 2.1.240" "must not compare the spec string against the registry"
}
run_test "check 4.6 variant.json nativeVersion 'latest' is not mistaken for a version" test_dep_check_variant_json_latest_is_not_a_version

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
