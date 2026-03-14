#!/usr/bin/env bash
# Tests for setup/scripts/afleet.sh — unified agent fleet launcher
source "$(dirname "$0")/test-helpers.sh"

SCRIPT="$REPO_ROOT/setup/scripts/afleet.sh"

suite_header "afleet.sh (agent fleet launcher)"

# ── Helpers ──────────────────────────────────────────────────────────────────

create_mock_registry() {
    local dir="$1"
    cat > "$dir/registry.md" << 'EOF'
# Project Registry

## Projects

| Project | Priority | Parent | Path | GitHub Remote | Machines | Type | Phase | Notes |
|---------|----------|--------|------|--------------|----------|------|-------|-------|
| project-alpha | P1 | — | `~/project-alpha` | `testuser/project-alpha` | dev-main, dev-office | research | active | |
| my-config | P1 | — | `~/my-config` | `testuser/my-config` | dev-main, dev-portable | meta | active | |
| project-beta | P1 | — | `~/project-beta` | `testuser/project-beta` | dev-main | marketing | active | |
| project-gamma | P2 | — | `~/project-gamma` | `testuser/project-gamma` | dev-main, dev-server | code | active | |
| infrastructure | P2 | my-config | `~/infrastructure` | `testuser/infrastructure` | dev-main | infra | active | |
EOF
}

create_mock_env() {
    local dir="$TEST_TMPDIR/env"
    local home="$TEST_TMPDIR/home"
    mkdir -p "$dir" "$home"
    create_mock_registry "$dir"
    # Create a fake mclaude
    mkdir -p "$home/.local/bin"
    cat > "$home/.local/bin/mclaude" << 'MOCK'
#!/usr/bin/env bash
echo "MOCK_MCLAUDE_CALLED dir=$(pwd)"
MOCK
    chmod +x "$home/.local/bin/mclaude"
    echo "$dir"
}

# ── 1. Basic CLI ─────────────────────────────────────────────────────────────

test_help_flag() {
    local output
    output=$(bash "$SCRIPT" --help 2>&1)
    assert_contains "$output" "Usage" "should show usage info"
    assert_contains "$output" "afleet" "should mention afleet"
}
run_test "help flag shows usage" test_help_flag

test_list_flag() {
    local env_dir
    env_dir=$(create_mock_env)
    local output
    output=$(CONFIG_REPO="$env_dir" bash "$SCRIPT" --list 2>&1)
    assert_contains "$output" "project-alpha" "should list project-alpha"
    assert_contains "$output" "my-config" "should list my-config"
    assert_contains "$output" "project-beta" "should list project-beta"
}
run_test "list flag shows all projects" test_list_flag

# ── 2. Project detection from CWD ───────────────────────────────────────────

test_detect_project_from_claude_dir() {
    local env_dir
    env_dir=$(create_mock_env)
    local project_dir="$TEST_TMPDIR/home/myproject"
    mkdir -p "$project_dir/.claude"
    touch "$project_dir/CLAUDE.md"

    local output
    output=$(CONFIG_REPO="$env_dir" AFLEET_DRY_RUN=1 bash "$SCRIPT" --cwd "$project_dir" 2>&1)
    assert_contains "$output" "myproject" "should detect project from .claude/ dir + CLAUDE.md"
}
run_test "detects project from .claude/ directory in CWD" test_detect_project_from_claude_dir

test_detect_project_by_registry_name() {
    local env_dir
    env_dir=$(create_mock_env)
    local home="$TEST_TMPDIR/home"
    mkdir -p "$home/project-alpha"

    local output
    output=$(CONFIG_REPO="$env_dir" HOME="$home" AFLEET_DRY_RUN=1 bash "$SCRIPT" project-alpha 2>&1)
    assert_contains "$output" "project-alpha" "should find project by registry name"
}
run_test "finds project by name from registry" test_detect_project_by_registry_name

test_unknown_project_name_errors() {
    local env_dir
    env_dir=$(create_mock_env)

    local output
    local rc=0
    output=$(CONFIG_REPO="$env_dir" bash "$SCRIPT" nonexistent 2>&1) || rc=$?
    assert_contains "$output" "not found" "should report project not found"
    assert_neq "0" "$rc" "should exit non-zero"
}
run_test "unknown project name exits with error" test_unknown_project_name_errors

# ── 3. Pre-launch git sync ──────────────────────────────────────────────────

test_git_sync_check_runs() {
    local env_dir
    env_dir=$(create_mock_env)
    local home="$TEST_TMPDIR/home"
    mkdir -p "$home/my-config/.git"
    # Create mock git-sync-check.sh that writes a marker file (stdout is redirected)
    mkdir -p "$env_dir/setup/scripts"
    local marker="$TEST_TMPDIR/sync_called"
    cat > "$env_dir/setup/scripts/git-sync-check.sh" << MOCK
#!/usr/bin/env bash
echo "SYNC_CHECK_CALLED path=\$2" >> "$marker"
MOCK
    chmod +x "$env_dir/setup/scripts/git-sync-check.sh"

    CONFIG_REPO="$env_dir" HOME="$home" AFLEET_DRY_RUN=1 bash "$SCRIPT" my-config >/dev/null 2>&1 || true
    assert_file_exists "$marker" "should call git-sync-check before launch"
    assert_file_contains "$marker" "SYNC_CHECK_CALLED" "marker should contain sync call record"
}
run_test "runs git-sync-check before launching mclaude" test_git_sync_check_runs

# ── 4. Base project fallback ────────────────────────────────────────────────

test_bare_afleet_opens_base_project() {
    local env_dir
    env_dir=$(create_mock_env)
    local home="$TEST_TMPDIR/home"
    mkdir -p "$home/agent-fleet"

    local output
    output=$(CONFIG_REPO="$env_dir" HOME="$home" AFLEET_DRY_RUN=1 bash "$SCRIPT" --cwd "/tmp" 2>&1)
    assert_contains "$output" "agent-fleet" "should fall back to base project"
}
run_test "bare afleet with no project in CWD falls back to base project" test_bare_afleet_opens_base_project

test_base_project_error_when_no_fleet_dir() {
    local env_dir
    env_dir=$(create_mock_env)
    local home="$TEST_TMPDIR/home"
    # No agent-fleet directory at all

    local rc=0
    output=$(CONFIG_REPO="$env_dir" HOME="$home" AFLEET_DRY_RUN=1 bash "$SCRIPT" --cwd "/tmp" 2>&1) || rc=$?
    assert_eq "1" "$rc" "should exit 1 when no base project found"
}
run_test "bare afleet errors when no base project directory exists" test_base_project_error_when_no_fleet_dir

# ── 5. Picker mode (replaces dashboard marker) ────────────────────────────

test_dash_flag_is_picker_alias() {
    local env_dir
    env_dir=$(create_mock_env)
    local home="$TEST_TMPDIR/home"
    mkdir -p "$home/my-config" "$home/.claude"
    mkdir -p "$env_dir/cross-project"
    create_mock_dashboard_cache "$env_dir"

    # --dash is now an alias for --pick — should not create old marker file
    CONFIG_REPO="$env_dir" HOME="$home" AFLEET_DRY_RUN=1 bash "$SCRIPT" --dash < /dev/null 2>&1 || true
    assert_file_not_exists "$home/.claude/.afleet-show-dash" \
        "should NOT write old dashboard marker — picker replaces it"
}
run_test "dash flag is picker alias (no old marker)" test_dash_flag_is_picker_alias

# ── 6. Fallback triggers picker ───────────────────────────────────────────

test_explicit_project_no_picker() {
    local env_dir
    env_dir=$(create_mock_env)
    local home="$TEST_TMPDIR/home"
    mkdir -p "$home/project-alpha" "$home/.claude"

    local output
    output=$(CONFIG_REPO="$env_dir" HOME="$home" AFLEET_DRY_RUN=1 bash "$SCRIPT" project-alpha 2>&1)
    assert_not_contains "$output" "P1 CRITICAL" "explicit project should not show picker"
}
run_test "explicit project arg does not show picker" test_explicit_project_no_picker

test_cwd_detected_project_no_picker() {
    local env_dir
    env_dir=$(create_mock_env)
    local home="$TEST_TMPDIR/home"
    local project_dir="$home/myproject"
    mkdir -p "$project_dir/.claude" "$home/.claude"
    touch "$project_dir/CLAUDE.md"

    local output
    output=$(CONFIG_REPO="$env_dir" HOME="$home" AFLEET_DRY_RUN=1 bash "$SCRIPT" --cwd "$project_dir" 2>&1)
    assert_not_contains "$output" "P1 CRITICAL" "CWD project should not show picker"
}
run_test "CWD-detected project does not show picker" test_cwd_detected_project_no_picker

# ── 7. Dashboard cache parsing ─────────────────────────────────────────────

create_mock_dashboard_cache() {
    local dir="$1"
    cat > "$dir/cross-project/dashboard-cache.md" << 'EOF'
# Dashboard Cache

Last refreshed: 2026-03-09 12:00 UTC on dev-main

| Project | Priority | Parent | Path | Type | Tasks | Size | Deadline | P1Names | LastDone |
|---------|----------|--------|------|------|-------|------|----------|---------|----------|
| project-alpha | P1 | — | ~/project-alpha | research (p) | 21 open | 444M | Mar 27 | ALF-16 Fellowship | Submitted paper |
| my-config | P1 | — | ~/my-config | meta/config | 51 open | 153M |  |  | Hook expansion |
| project-beta | P1 | — | ~/project-beta | engagement | 18 open | 1.9M |  | Day 10 | Email audit |
| project-gamma | P2 | — | ~/project-gamma | code | — | — |  |  | Gallery v2 |
| project-delta | P2 | — | ~/project-delta | tooling | 15 open | 11G |  |  |  |
| infrastructure | P2 | my-config | ~/infrastructure | infra | 9 open | 27M |  |  |  |
| project-epsilon | P2 | project-alpha | ~/project-epsilon | code | — | — |  |  |  |
| agent-fleet | P3 | my-config | ~/agent-fleet | template | ~50 drift | 7.2M |  |  |  |
| project-zeta | P1 | project-delta | ~/project-delta/project-zeta | code | 10 open | 995M |  | ZET-7 deploy |  |
| project-eta | P3 | — | ~/project-eta | code | — | — |  |  |  |
| project-theta | P4 | — | ~/project-theta | media | — | — |  |  |  |
| project-iota | P5 | — | ~/project-iota | code | — | — |  |  |  |
EOF
}

create_full_mock_env() {
    local dir="$TEST_TMPDIR/env"
    local home="$TEST_TMPDIR/home"
    mkdir -p "$dir/cross-project" "$home/.local/bin" "$home/.claude"
    create_mock_registry "$dir"
    create_mock_dashboard_cache "$dir"
    # Create a fake mclaude
    cat > "$home/.local/bin/mclaude" << 'MOCK'
#!/usr/bin/env bash
echo "MOCK_MCLAUDE_CALLED dir=$(pwd)"
MOCK
    chmod +x "$home/.local/bin/mclaude"
    echo "$dir"
}

test_parse_dashboard_cache() {
    local env_dir
    env_dir=$(create_full_mock_env)

    # Source afleet.sh functions
    AFLEET_SOURCE_ONLY=1 CONFIG_REPO="$env_dir" source "$SCRIPT"

    local output
    output=$(parse_dashboard_cache)

    assert_contains "$output" "project-alpha|P1|—" "should parse project-alpha as P1"
    assert_contains "$output" "project-zeta|P1|project-delta" "should parse project-zeta as P1 with parent project-delta"
    assert_contains "$output" "infrastructure|P2|my-config" "should parse infrastructure with parent"
    assert_contains "$output" "project-theta|P4|—" "should parse P4 project"
}
run_test "parse_dashboard_cache extracts project data" test_parse_dashboard_cache

test_build_display_list_tier_grouping() {
    local env_dir
    env_dir=$(create_full_mock_env)

    AFLEET_SOURCE_ONLY=1 CONFIG_REPO="$env_dir" source "$SCRIPT"

    local cache_data
    cache_data=$(parse_dashboard_cache)

    # build_display_list outputs: label|name|type|tasks|size|priority|is_child|parent|path
    local output
    output=$(echo "$cache_data" | build_display_list)

    # Parents get numbers
    assert_contains "$output" "1|project-alpha|" "project-alpha should get number 1"
    assert_contains "$output" "2|my-config|" "cfg should get number 2"
    assert_contains "$output" "3|project-beta|" "project-beta should get number 3"

    # project-zeta is P1 child of P2 project-delta — promoted to P1 tier with own number
    assert_contains "$output" "4|project-zeta|" "project-zeta should be promoted with number 4"

    # Children of P1 parents get letters
    assert_contains "$output" "a|project-epsilon|" "project-epsilon should get letter a"
}
run_test "build_display_list assigns numbers to parents and letters to children" test_build_display_list_tier_grouping

test_build_display_list_p4p5_excluded_by_default() {
    local env_dir
    env_dir=$(create_full_mock_env)

    AFLEET_SOURCE_ONLY=1 CONFIG_REPO="$env_dir" source "$SCRIPT"

    local cache_data
    cache_data=$(parse_dashboard_cache)

    local output
    output=$(echo "$cache_data" | build_display_list)

    assert_not_contains "$output" "project-theta" "P4 should not appear by default"
    assert_not_contains "$output" "project-iota" "P5 should not appear by default"
}
run_test "build_display_list excludes P4-P5 by default" test_build_display_list_p4p5_excluded_by_default

test_build_display_list_show_all() {
    local env_dir
    env_dir=$(create_full_mock_env)

    AFLEET_SOURCE_ONLY=1 CONFIG_REPO="$env_dir" source "$SCRIPT"

    local cache_data
    cache_data=$(parse_dashboard_cache)

    local output
    output=$(echo "$cache_data" | PICKER_SHOW_ALL=1 build_display_list)

    assert_contains "$output" "project-theta" "P4 should appear with show_all"
    assert_contains "$output" "project-iota" "P5 should appear with show_all"
}
run_test "build_display_list includes P4-P5 with PICKER_SHOW_ALL" test_build_display_list_show_all

test_render_picker_has_box_drawing() {
    local env_dir
    env_dir=$(create_full_mock_env)

    AFLEET_SOURCE_ONLY=1 CONFIG_REPO="$env_dir" source "$SCRIPT"

    local cache_data
    cache_data=$(parse_dashboard_cache)
    local display_list
    display_list=$(echo "$cache_data" | build_display_list)

    local output
    output=$(echo "$display_list" | COLUMNS=100 render_picker 2>/dev/null)

    assert_contains "$output" "P1 CRITICAL" "should have P1 tier header"
    assert_contains "$output" "P2 ACTIVE" "should have P2 tier header"
    assert_contains "$output" "project-alpha" "should show project-alpha"
    assert_contains "$output" "my-config" "should show my-config"
    # Box drawing chars
    assert_contains "$output" "┌" "should have box-drawing top-left"
    assert_contains "$output" "└" "should have box-drawing bottom-left"
    assert_contains "$output" "│" "should have box-drawing vertical"
}
run_test "render_picker produces box-drawing output with tier headers" test_render_picker_has_box_drawing

test_render_picker_child_indentation() {
    local env_dir
    env_dir=$(create_full_mock_env)

    AFLEET_SOURCE_ONLY=1 CONFIG_REPO="$env_dir" source "$SCRIPT"

    local cache_data
    cache_data=$(parse_dashboard_cache)
    local display_list
    display_list=$(echo "$cache_data" | build_display_list)

    local output
    output=$(echo "$display_list" | COLUMNS=100 render_picker 2>/dev/null)

    # Children should have tree chars
    assert_contains "$output" "├─" "should have tree branch chars for children"
    assert_contains "$output" "└─" "should have tree end chars for last child"
}
run_test "render_picker shows tree characters for children" test_render_picker_child_indentation

test_resolve_selection_number() {
    local env_dir
    env_dir=$(create_full_mock_env)
    local home="$TEST_TMPDIR/home"

    AFLEET_SOURCE_ONLY=1 CONFIG_REPO="$env_dir" HOME="$home" source "$SCRIPT"

    local cache_data
    cache_data=$(parse_dashboard_cache)
    local display_list
    display_list=$(echo "$cache_data" | build_display_list)

    local result
    result=$(echo "$display_list" | resolve_selection "1")
    assert_contains "$result" "project-alpha" "selection 1 should resolve to project-alpha"

    result=$(echo "$display_list" | resolve_selection "2")
    assert_contains "$result" "my-config" "selection 2 should resolve to my-config"
}
run_test "resolve_selection maps numbers to parent projects" test_resolve_selection_number

test_resolve_selection_letter() {
    local env_dir
    env_dir=$(create_full_mock_env)
    local home="$TEST_TMPDIR/home"

    AFLEET_SOURCE_ONLY=1 CONFIG_REPO="$env_dir" HOME="$home" source "$SCRIPT"

    local cache_data
    cache_data=$(parse_dashboard_cache)
    local display_list
    display_list=$(echo "$cache_data" | build_display_list)

    local result
    result=$(echo "$display_list" | resolve_selection "a")
    assert_contains "$result" "project-epsilon" "selection 'a' should resolve to first child"
}
run_test "resolve_selection maps letters to child projects" test_resolve_selection_letter

test_resolve_selection_invalid() {
    local env_dir
    env_dir=$(create_full_mock_env)
    local home="$TEST_TMPDIR/home"

    AFLEET_SOURCE_ONLY=1 CONFIG_REPO="$env_dir" HOME="$home" source "$SCRIPT"

    local cache_data
    cache_data=$(parse_dashboard_cache)
    local display_list
    display_list=$(echo "$cache_data" | build_display_list)

    local result
    result=$(echo "$display_list" | resolve_selection "99" || echo "EMPTY")
    assert_eq "EMPTY" "$result" "invalid selection should return empty"
}
run_test "resolve_selection returns empty for invalid input" test_resolve_selection_invalid

test_promoted_child_has_parent_suffix() {
    local env_dir
    env_dir=$(create_full_mock_env)

    AFLEET_SOURCE_ONLY=1 CONFIG_REPO="$env_dir" source "$SCRIPT"

    local cache_data
    cache_data=$(parse_dashboard_cache)
    local display_list
    display_list=$(echo "$cache_data" | build_display_list)

    local output
    output=$(echo "$display_list" | COLUMNS=100 render_picker 2>/dev/null)

    # project-zeta is promoted from project-delta — should show parent hint
    assert_contains "$output" "project-delta" "promoted child project-zeta should reference parent project-delta"
}
run_test "promoted children show parent reference in display" test_promoted_child_has_parent_suffix

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
