#!/usr/bin/env bash
# Tests for setup-project-roster.sh (CFG-137b)
# TDD: written before implementation
source "$(dirname "$0")/test-helpers.sh"

suite_header "Setup Project Roster"

SCRIPT="$REPO_ROOT/setup/scripts/setup-project-roster.sh"

# ── Helpers ──────────────────────────────────────────────────────────────────

# Create a mock project directory with optional CLAUDE.md content
create_mock_project() {
    local path="$1"
    local claude_content="${2:-}"
    mkdir -p "$path/.claude"
    if [[ -n "$claude_content" ]]; then
        echo "$claude_content" > "$path/CLAUDE.md"
    fi
}

# Create a mock registry.md in TEST_TMPDIR
create_mock_registry() {
    local content="$1"
    mkdir -p "$TEST_TMPDIR/cfg"
    cat > "$TEST_TMPDIR/cfg/registry.md" << EOF
# Project Registry

## Projects

| Project | Priority | Parent | Path | GitHub Remote | Machines | Type | Phase | Notes |
|---------|----------|--------|------|--------------|----------|------|-------|-------|
$content
EOF
}

# Run the script with test overrides
run_roster() {
    local project_path="$1"
    shift
    SETUP_ROSTER_REGISTRY="$TEST_TMPDIR/cfg/registry.md" \
        bash "$SCRIPT" "$project_path" "$@" 2>&1
}

# Extract a plugin value from settings.local.json
get_plugin_value() {
    local settings_file="$1"
    local plugin_key="$2"
    python3 -c "
import json
d = json.load(open('$settings_file'))
ep = d.get('enabledPlugins', {})
val = ep.get('$plugin_key', 'MISSING')
print(str(val))
" 2>/dev/null
}

# Count enabledPlugins entries
count_plugins() {
    local settings_file="$1"
    python3 -c "
import json
d = json.load(open('$settings_file'))
ep = d.get('enabledPlugins', {})
print(len(ep))
" 2>/dev/null
}

# ── Tests ─────────────────────────────────────────────────────────────────────

# Test 1: Code project gets core-dev, lang, qa-sec bundles
test_code_project_bundles() {
    create_mock_project "$TEST_TMPDIR/muse"
    create_mock_registry "| muse | P2 | — | \`~/muse\` | \`example-user/muse\` | wsl-host | code | active | Music player |"

    run_roster "$TEST_TMPDIR/muse" >/dev/null 2>&1

    local settings="$TEST_TMPDIR/muse/.claude/settings.local.json"
    assert_file_exists "$settings"
    assert_file_contains "$settings" "voltagent-core-dev@voltagent-subagents"
    assert_file_contains "$settings" "voltagent-lang@voltagent-subagents"
    assert_file_contains "$settings" "voltagent-qa-sec@voltagent-subagents"
}
run_test "code project gets core-dev, lang, qa-sec bundles" test_code_project_bundles

# Test 2: Meta/config project gets dev-exp and infra bundles
test_meta_config_project_bundles() {
    create_mock_project "$TEST_TMPDIR/cfg-agent-fleet"
    create_mock_registry "| cfg-agent-fleet | P1 | — | \`~/cfg-agent-fleet\` | \`example-user/cfg-agent-fleet\` | wsl-host | meta/config | active | Config backbone |"

    run_roster "$TEST_TMPDIR/cfg-agent-fleet" >/dev/null 2>&1

    local settings="$TEST_TMPDIR/cfg-agent-fleet/.claude/settings.local.json"
    assert_file_exists "$settings"
    assert_file_contains "$settings" "voltagent-dev-exp@voltagent-subagents"
    assert_file_contains "$settings" "voltagent-infra@voltagent-subagents"
    assert_file_not_contains "$settings" "voltagent-core-dev@voltagent-subagents"
}
run_test "meta/config project gets dev-exp and infra bundles" test_meta_config_project_bundles

# Test 3: Research+authoring project gets research and data-ai bundles
test_research_authoring_project_bundles() {
    create_mock_project "$TEST_TMPDIR/alpha"
    create_mock_registry "| alpha | P1 | — | \`~/alpha\` | \`example-user/alpha\` | wsl-host | research + authoring | active | Papers |"

    run_roster "$TEST_TMPDIR/alpha" >/dev/null 2>&1

    local settings="$TEST_TMPDIR/alpha/.claude/settings.local.json"
    assert_file_exists "$settings"
    assert_file_contains "$settings" "voltagent-research@voltagent-subagents"
    assert_file_contains "$settings" "voltagent-data-ai@voltagent-subagents"
}
run_test "research+authoring project gets research and data-ai bundles" test_research_authoring_project_bundles

# Test 4: Business/process project gets biz and research bundles
test_business_process_project_bundles() {
    create_mock_project "$TEST_TMPDIR/regulatory"
    create_mock_registry "| regulatory | P3 | acme | \`~/acme/regulatory\` | \`example-user/regulatory\` | wsl-host | business/process | discovery | RA process |"

    run_roster "$TEST_TMPDIR/regulatory" >/dev/null 2>&1

    local settings="$TEST_TMPDIR/regulatory/.claude/settings.local.json"
    assert_file_exists "$settings"
    assert_file_contains "$settings" "voltagent-biz@voltagent-subagents"
    assert_file_contains "$settings" "voltagent-research@voltagent-subagents"
}
run_test "business/process project gets biz and research bundles" test_business_process_project_bundles

# Test 5: Dry-run does not create settings.local.json
test_dry_run_no_write() {
    create_mock_project "$TEST_TMPDIR/muse"
    create_mock_registry "| muse | P2 | — | \`~/muse\` | \`example-user/muse\` | wsl-host | code | active | Music player |"

    run_roster "$TEST_TMPDIR/muse" --dry-run >/dev/null 2>&1

    assert_file_not_exists "$TEST_TMPDIR/muse/.claude/settings.local.json" \
        "dry-run should not create settings.local.json"
}
run_test "dry-run does not write settings.local.json" test_dry_run_no_write

# Test 6: Dry-run output mentions the bundles that would be applied
test_dry_run_output_shows_bundles() {
    create_mock_project "$TEST_TMPDIR/muse"
    create_mock_registry "| muse | P2 | — | \`~/muse\` | \`example-user/muse\` | wsl-host | code | active | Music |"

    local output
    output=$(run_roster "$TEST_TMPDIR/muse" --dry-run 2>&1)

    assert_contains "$output" "voltagent-core-dev"
    assert_contains "$output" "DRY RUN"
}
run_test "dry-run output shows bundles that would be applied" test_dry_run_output_shows_bundles

# Test 7: Merges into existing settings.local.json without overwriting other keys
test_merge_preserves_existing_settings() {
    create_mock_project "$TEST_TMPDIR/muse"
    create_mock_registry "| muse | P2 | — | \`~/muse\` | \`example-user/muse\` | wsl-host | code | active | Music |"

    # Pre-create settings.local.json with some other setting
    cat > "$TEST_TMPDIR/muse/.claude/settings.local.json" << 'EOF'
{
  "someOtherSetting": "preserve-me",
  "enabledPlugins": {
    "old-plugin@old-marketplace": true
  }
}
EOF

    run_roster "$TEST_TMPDIR/muse" >/dev/null 2>&1

    local settings="$TEST_TMPDIR/muse/.claude/settings.local.json"
    assert_file_contains "$settings" "preserve-me"
    assert_file_contains "$settings" "voltagent-core-dev@voltagent-subagents"
}
run_test "merges into existing settings.local.json, preserves other keys" test_merge_preserves_existing_settings

# Test 8: Idempotent — running twice produces same result (no duplicate keys)
test_idempotent() {
    create_mock_project "$TEST_TMPDIR/muse"
    create_mock_registry "| muse | P2 | — | \`~/muse\` | \`example-user/muse\` | wsl-host | code | active | Music |"

    run_roster "$TEST_TMPDIR/muse" >/dev/null 2>&1
    run_roster "$TEST_TMPDIR/muse" >/dev/null 2>&1

    local settings="$TEST_TMPDIR/muse/.claude/settings.local.json"
    local plugin_count
    plugin_count=$(count_plugins "$settings")

    # Should have exactly 3 plugins (core-dev, lang, qa-sec) — not doubled
    assert_eq "3" "$plugin_count" "idempotent: code project should have exactly 3 plugins"
}
run_test "idempotent — running twice produces exactly 3 plugins for code project" test_idempotent

# Test 9: Plugin values are set to true (boolean)
test_plugin_values_are_true() {
    create_mock_project "$TEST_TMPDIR/muse"
    create_mock_registry "| muse | P2 | — | \`~/muse\` | \`example-user/muse\` | wsl-host | code | active | Music |"

    run_roster "$TEST_TMPDIR/muse" >/dev/null 2>&1

    local settings="$TEST_TMPDIR/muse/.claude/settings.local.json"
    local val
    val=$(get_plugin_value "$settings" "voltagent-core-dev@voltagent-subagents")
    assert_eq "True" "$val" "plugin value should be boolean true"
}
run_test "plugin values are boolean true in JSON" test_plugin_values_are_true

# Test 10: --list flag prints mapping table without writing any files
test_list_flag() {
    create_mock_project "$TEST_TMPDIR/muse-list"
    create_mock_registry "| muse | P2 | — | \`~/muse\` | \`example-user/muse\` | wsl-host | code | active | Music |"

    local output
    output=$(run_roster "$TEST_TMPDIR/muse-list" --list 2>&1)

    assert_contains "$output" "code"
    assert_contains "$output" "voltagent-core-dev"
    assert_file_not_exists "$TEST_TMPDIR/muse-list/.claude/settings.local.json" \
        "--list should not write settings.local.json"
}
run_test "--list flag prints mapping table without writing" test_list_flag

# Test 11: Unknown project type gives a warning and no write
test_unknown_project_type_warns() {
    create_mock_project "$TEST_TMPDIR/unknown-proj"
    # No registry entry for this project path
    create_mock_registry "| other | P3 | — | \`~/other\` | — | wsl-host | writing | new | Stuff |"

    local output
    output=$(run_roster "$TEST_TMPDIR/unknown-proj" 2>&1)

    assert_contains "$output" "unknown" \
        "should mention unknown type when project not found in registry"
    assert_file_not_exists "$TEST_TMPDIR/unknown-proj/.claude/settings.local.json" \
        "should not write settings for unknown project type"
}
run_test "unknown project type warns and skips write" test_unknown_project_type_warns

# Test 12: Infra/config project gets infra and dev-exp bundles
test_infra_config_project_bundles() {
    create_mock_project "$TEST_TMPDIR/infrastructure"
    create_mock_registry "| infrastructure | P2 | cfg-agent-fleet | \`~/infrastructure\` | \`example-user/infrastructure\` | wsl-host | infra/config | active | VPS config |"

    run_roster "$TEST_TMPDIR/infrastructure" >/dev/null 2>&1

    local settings="$TEST_TMPDIR/infrastructure/.claude/settings.local.json"
    assert_file_exists "$settings"
    assert_file_contains "$settings" "voltagent-infra@voltagent-subagents"
    assert_file_contains "$settings" "voltagent-dev-exp@voltagent-subagents"
}
run_test "infra/config project gets infra and dev-exp bundles" test_infra_config_project_bundles

# Test 13: Tooling/integration project gets core-dev, infra, biz bundles
test_tooling_integration_project_bundles() {
    create_mock_project "$TEST_TMPDIR/acme"
    create_mock_registry "| acme | P2 | — | \`~/acme\` | \`example-user/acme\` | wsl-host | tooling/integration | active | Corporate |"

    run_roster "$TEST_TMPDIR/acme" >/dev/null 2>&1

    local settings="$TEST_TMPDIR/acme/.claude/settings.local.json"
    assert_file_exists "$settings"
    assert_file_contains "$settings" "voltagent-core-dev@voltagent-subagents"
    assert_file_contains "$settings" "voltagent-infra@voltagent-subagents"
    assert_file_contains "$settings" "voltagent-biz@voltagent-subagents"
}
run_test "tooling/integration project gets core-dev, infra, biz bundles" test_tooling_integration_project_bundles

# Test 14: settings.local.json is valid JSON after write
test_output_is_valid_json() {
    create_mock_project "$TEST_TMPDIR/muse"
    create_mock_registry "| muse | P2 | — | \`~/muse\` | \`example-user/muse\` | wsl-host | code | active | Music |"

    run_roster "$TEST_TMPDIR/muse" >/dev/null 2>&1

    local settings="$TEST_TMPDIR/muse/.claude/settings.local.json"
    local rc=0
    python3 -c "import json; json.load(open('$settings'))" 2>/dev/null || rc=$?
    assert_eq "0" "$rc" "settings.local.json should be valid JSON"
}
run_test "output settings.local.json is valid JSON" test_output_is_valid_json

# Test 15: Marketing/engagement project gets research and biz bundles
test_marketing_engagement_project_bundles() {
    create_mock_project "$TEST_TMPDIR/social"
    create_mock_registry "| social | P1 | — | \`~/social\` | \`example-user/social\` | wsl-host | marketing/engagement | active | Twitter |"

    run_roster "$TEST_TMPDIR/social" >/dev/null 2>&1

    local settings="$TEST_TMPDIR/social/.claude/settings.local.json"
    assert_file_exists "$settings"
    assert_file_contains "$settings" "voltagent-research@voltagent-subagents"
    assert_file_contains "$settings" "voltagent-biz@voltagent-subagents"
}
run_test "marketing/engagement project gets research and biz bundles" test_marketing_engagement_project_bundles

# ── CFG-220: Registry-Authoritative Roster Sync ─────────────────────────────

# Helper: create a registry with both Projects and Roster Snapshots tables
create_mock_registry_with_roster() {
    local projects_rows="$1"
    local roster_rows="$2"
    mkdir -p "$TEST_TMPDIR/cfg"
    cat > "$TEST_TMPDIR/cfg/registry.md" << EOF
# Project Registry

## Projects

| Project | Priority | Parent | Path | GitHub Remote | Machines | Type | Phase | Notes |
|---------|----------|--------|------|--------------|----------|------|-------|-------|
$projects_rows

## Roster Snapshots

Current agent rosters per project (authoritative — sync.sh deploy regenerates from this):

| Project | Bundles (enabledPlugins) | Rationale |
|---------|------------------------|-----------|
$roster_rows
EOF
}

# Test 16: Registry roster overrides type-derived bundles
test_registry_roster_overrides_type() {
    create_mock_project "$TEST_TMPDIR/alpha"
    create_mock_registry_with_roster \
        "| alpha | P1 | — | \`$TEST_TMPDIR/alpha\` | — | wsl-host | research + writing + code | active | Papers |" \
        "| alpha | research, data-ai | Custom roster |"

    run_roster "$TEST_TMPDIR/alpha" >/dev/null 2>&1

    local settings="$TEST_TMPDIR/alpha/.claude/settings.local.json"
    assert_file_exists "$settings"
    assert_file_contains "$settings" "voltagent-research@voltagent-subagents"
    assert_file_contains "$settings" "voltagent-data-ai@voltagent-subagents"
    # Type "research + writing + code" would also give core-dev and lang — those should NOT be present
    assert_file_not_contains "$settings" "voltagent-core-dev@voltagent-subagents"
    assert_file_not_contains "$settings" "voltagent-lang@voltagent-subagents"
}
run_test "registry roster overrides type-derived bundles" test_registry_roster_overrides_type

# Test 17: Registry roster REPLACES existing enabledPlugins completely
test_registry_roster_replaces_plugins() {
    create_mock_project "$TEST_TMPDIR/muse"
    create_mock_registry_with_roster \
        "| muse | P2 | — | \`$TEST_TMPDIR/muse\` | — | wsl-host | code | active | Music |" \
        "| muse | lang, core-dev, qa-sec | Code project |"

    # Pre-create with stale plugins
    cat > "$TEST_TMPDIR/muse/.claude/settings.local.json" << 'SETTINGS'
{
  "someOtherSetting": "preserve-me",
  "enabledPlugins": {
    "stale-plugin@old-marketplace": true,
    "another-stale@voltagent-subagents": true
  }
}
SETTINGS

    run_roster "$TEST_TMPDIR/muse" >/dev/null 2>&1

    local settings="$TEST_TMPDIR/muse/.claude/settings.local.json"
    # Other settings preserved
    assert_file_contains "$settings" "preserve-me"
    # New bundles present
    assert_file_contains "$settings" "voltagent-core-dev@voltagent-subagents"
    # Stale plugins GONE
    assert_file_not_contains "$settings" "stale-plugin@old-marketplace"
    assert_file_not_contains "$settings" "another-stale@voltagent-subagents"
}
run_test "registry roster replaces existing enabledPlugins completely" test_registry_roster_replaces_plugins

# Test 18: Projects without roster snapshot fall back to type mapping
test_fallback_to_type_mapping() {
    create_mock_project "$TEST_TMPDIR/newproj"
    create_mock_registry_with_roster \
        "| newproj | P3 | — | \`$TEST_TMPDIR/newproj\` | — | wsl-host | code | new | New project |" \
        "| other | research | Different project |"

    run_roster "$TEST_TMPDIR/newproj" >/dev/null 2>&1

    local settings="$TEST_TMPDIR/newproj/.claude/settings.local.json"
    assert_file_exists "$settings"
    # TYPE_BUNDLE_MAP for "code" gives core-dev, lang, qa-sec
    assert_file_contains "$settings" "voltagent-core-dev@voltagent-subagents"
    assert_file_contains "$settings" "voltagent-lang@voltagent-subagents"
    assert_file_contains "$settings" "voltagent-qa-sec@voltagent-subagents"
}
run_test "projects without roster snapshot fall back to type mapping" test_fallback_to_type_mapping

# Test 19: --all-local processes multiple local projects
test_all_local_multiple_projects() {
    create_mock_project "$TEST_TMPDIR/home/proj-a"
    create_mock_project "$TEST_TMPDIR/home/proj-b"
    create_mock_project "$TEST_TMPDIR/home/proj-c"
    create_mock_registry_with_roster \
        "| proj-a | P1 | — | \`$TEST_TMPDIR/home/proj-a\` | — | wsl-host | code | active | A |
| proj-b | P2 | — | \`$TEST_TMPDIR/home/proj-b\` | — | wsl-host | writing | active | B |
| proj-c | P3 | — | \`$TEST_TMPDIR/home/proj-c\` | — | wsl-host | infra | active | C |" \
        "| proj-a | core-dev, lang | Code project |
| proj-b | research | Writing project |
| proj-c | infra, dev-exp | Infra project |"

    SETUP_ROSTER_REGISTRY="$TEST_TMPDIR/cfg/registry.md" \
        bash "$SCRIPT" --all-local >/dev/null 2>&1

    assert_file_exists "$TEST_TMPDIR/home/proj-a/.claude/settings.local.json"
    assert_file_contains "$TEST_TMPDIR/home/proj-a/.claude/settings.local.json" "voltagent-core-dev@voltagent-subagents"
    assert_file_exists "$TEST_TMPDIR/home/proj-b/.claude/settings.local.json"
    assert_file_contains "$TEST_TMPDIR/home/proj-b/.claude/settings.local.json" "voltagent-research@voltagent-subagents"
    assert_file_exists "$TEST_TMPDIR/home/proj-c/.claude/settings.local.json"
    assert_file_contains "$TEST_TMPDIR/home/proj-c/.claude/settings.local.json" "voltagent-infra@voltagent-subagents"
}
run_test "--all-local processes multiple local projects" test_all_local_multiple_projects

# Test 20: --all-local skips non-existent project paths
test_all_local_skips_nonexistent() {
    create_mock_project "$TEST_TMPDIR/home/exists"
    create_mock_registry_with_roster \
        "| exists | P1 | — | \`$TEST_TMPDIR/home/exists\` | — | wsl-host | code | active | Exists |
| ghost | P2 | — | \`$TEST_TMPDIR/home/ghost\` | — | wsl-host | code | active | Ghost |" \
        "| exists | core-dev | Code |
| ghost | research | Missing |"

    local output
    output=$(SETUP_ROSTER_REGISTRY="$TEST_TMPDIR/cfg/registry.md" \
        bash "$SCRIPT" --all-local 2>&1)

    assert_file_exists "$TEST_TMPDIR/home/exists/.claude/settings.local.json"
    assert_file_not_exists "$TEST_TMPDIR/home/ghost/.claude/settings.local.json"
    assert_contains "$output" "ghost"
}
run_test "--all-local skips non-existent project paths" test_all_local_skips_nonexistent

# Test 21: Registry roster parses various short name formats
test_registry_parses_short_names() {
    create_mock_project "$TEST_TMPDIR/infra-proj"
    create_mock_registry_with_roster \
        "| infra-proj | P2 | — | \`$TEST_TMPDIR/infra-proj\` | — | wsl-host | infra | active | Infra |" \
        "| infra-proj | infra, dev-exp, qa-sec | Three bundles |"

    run_roster "$TEST_TMPDIR/infra-proj" >/dev/null 2>&1

    local settings="$TEST_TMPDIR/infra-proj/.claude/settings.local.json"
    local plugin_count
    plugin_count=$(count_plugins "$settings")
    assert_eq "3" "$plugin_count" "should have exactly 3 plugins from registry roster"
    assert_file_contains "$settings" "voltagent-infra@voltagent-subagents"
    assert_file_contains "$settings" "voltagent-dev-exp@voltagent-subagents"
    assert_file_contains "$settings" "voltagent-qa-sec@voltagent-subagents"
}
run_test "registry roster parses comma-separated short names into exact bundle count" test_registry_parses_short_names

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
